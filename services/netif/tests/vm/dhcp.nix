# netif-dhcp: dhcpcd under netif (specs/netif.md N9, N16, N31–N34).
#
#   isp  ── vlan 1 ──  router (wan: DHCPv4 + DHCPv6 + prefix delegation)
#                 └──  client4 (uplink: DHCPv4 only)
#   router ── vlan 2 ── (lan: static, gets a subnet of the delegated prefix)
#   isp  ── vlan 3 ──  client4 (private: DHCPv4 and RAs, no default route; N21)
#
# The isp node is a fixture: kea for DHCPv4 and DHCPv6, radvd, and it
# forwards IPv6 (§7: a node that sends RAs must forward).
{
  inputs,
  lib,
  ...
}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  noopHelper = import ../../../../tests/ifstate-noop.nix;

  kea4 = dns: {
    enable = true;
    settings = {
      interfaces-config = {
        interfaces = [
          "eth1"
          "eth2"
        ];
        service-sockets-max-retries = 30;
        service-sockets-retry-wait-time = 1000;
      };
      lease-database = {
        type = "memfile";
        persist = false;
      };
      # A short lease, so a renewal happens inside the test.
      valid-lifetime = 60;
      subnet4 = [
        {
          id = 1;
          subnet = "192.0.2.0/24";
          interface = "eth1";
          pools = [{pool = "192.0.2.100 - 192.0.2.150";}];
          option-data = [
            {
              name = "routers";
              data = "192.0.2.1";
            }
            {
              name = "domain-name-servers";
              data = dns;
            }
            {
              name = "domain-name";
              data = "isp.test";
            }
          ];
        }
        # The private network: the server offers a router and a classless
        # default too, and a link with 'defaultRoute.ipv4 = false' must
        # take neither (N21).
        {
          id = 2;
          subnet = "198.51.100.0/24";
          interface = "eth2";
          pools = [{pool = "198.51.100.100 - 198.51.100.150";}];
          option-data = [
            {
              name = "routers";
              data = "198.51.100.1";
            }
            {
              name = "domain-name-servers";
              data = "198.51.100.53";
            }
            {
              # 10.50.0.0/16 via 198.51.100.1 and a default via 198.51.100.1
              name = "classless-static-route";
              csv-format = false;
              data = "100A32C633640100C6336401";
            }
          ];
        }
      ];
    };
  };
in {
  name = "netif-dhcp";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        router = {};
        client4 = {};
        isp = {};
      };
      instances = {
        wan = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines = {
            router.settings.links.wan = {
              interface = "eth1";
              dhcp = {
                ipv4 = true;
                ipv6 = true;
                prefixDelegation = {
                  enable = true;
                  hint = 60;
                  assign = [
                    {
                      instance = "lan";
                      link = "lan";
                      subnet = 1;
                    }
                  ];
                };
              };
            };
            client4.settings.links.uplink = {
              interface = "eth1";
              dhcp.ipv4 = true;
            };
          };
        };
        lan = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.router.settings.links.lan = {
            interface = "eth2";
            static.ipv4 = ["192.168.10.1/24"];
            nameservers = ["192.168.10.53"];
            # a router does not take a default from its own LAN (N21)
            ra = false;
          };
        };
        private = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.client4.settings.links.private = {
            interface = "eth2";
            dhcp.ipv4 = true;
            defaultRoute = {
              ipv4 = false;
              ipv6 = false;
            };
          };
        };
      };
    };
  };

  nodes = {
    router = {pkgs, ...}: {
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [
          1
          2
        ];
      };
      environment.systemPackages = [pkgs.jq];
      # Records what "online" meant when network-online.target was reached.
      systemd.services.online-probe = {
        wantedBy = ["multi-user.target"];
        wants = ["network-online.target"];
        after = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = "${lib.getExe' pkgs.iproute2 "ip"} -4 -o addr show dev eth1 scope global > /run/online-probe";
      };
    };
    client4 = {pkgs, ...}: {
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [
          1
          3
        ];
      };
      environment.systemPackages = [pkgs.jq];
    };
    isp = {pkgs, ...}: {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          inherit ifstateOverlay;
          addresses = [
            "192.0.2.1/24"
            "2001:db8::1/64"
          ];
          withBase = true;
        })
      ];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [
          1
          3
        ];
      };
      networking.ifstate.settings.interfaces.eth2 = {
        addresses = [
          "198.51.100.1/24"
          "2001:db8:2::1/64"
        ];
        link = {
          kind = "physical";
          state = "up";
        };
      };
      environment.systemPackages = [pkgs.tcpdump];
      boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
      networking.firewall.enable = false;
      # The same server with other DNS servers: a renewal then brings a
      # changed lease.
      specialisation.dns2.configuration.services.kea.dhcp4 = lib.mkForce (kea4 "192.0.2.54, 192.0.2.55");
      services = {
        kea = {
          dhcp4 = kea4 "192.0.2.53";
          dhcp6 = {
            enable = true;
            settings = {
              interfaces-config = {
                interfaces = ["eth1"];
                service-sockets-max-retries = 30;
                service-sockets-retry-wait-time = 1000;
              };
              lease-database = {
                type = "memfile";
                persist = false;
              };
              subnet6 = [
                {
                  id = 1;
                  subnet = "2001:db8::/64";
                  interface = "eth1";
                  pools = [{pool = "2001:db8::100-2001:db8::1ff";}];
                  pd-pools = [
                    {
                      prefix = "2001:db8:1000::";
                      prefix-len = 48;
                      delegated-len = 60;
                    }
                  ];
                  option-data = [
                    {
                      name = "dns-servers";
                      data = "2001:db8::53";
                    }
                    {
                      name = "domain-search";
                      data = "v6.isp.test";
                    }
                  ];
                }
              ];
            };
          };
        };
        radvd = {
          enable = true;
          config = ''
            interface eth1 {
              AdvSendAdvert on;
              AdvManagedFlag on;
              AdvOtherConfigFlag on;
              prefix 2001:db8::/64 { AdvAutonomous off; };
            };
            interface eth2 {
              AdvSendAdvert on;
              prefix 2001:db8:2::/64 { };
            };
          '';
        };
      };
    };
  };

  testScript = ''
    import json
    import time

    ${noopHelper}

    def dns(machine, link):
        return machine.succeed(f"resolvectl dns {link}").split(":", 1)[1].split()

    def wait_dns(machine, link, *servers, timeout=75):
        end = time.time() + timeout
        while time.time() < end:
            current = dns(machine, link)
            if all(server in current for server in servers):
                return
            time.sleep(1)
        raise AssertionError(f"{machine.name}: {link} DNS is {dns(machine, link)}, wanted {servers}")

    def eloop_errors(machine):
        return int(machine.succeed("journalctl -b --no-pager | grep -c eloop_event_add || true").strip())

    def wait_leases(machine=None):
        m = machine or router
        m.wait_until_succeeds("ip -4 -o addr show dev eth1 scope global | grep 192.0.2.1 >/dev/null", timeout=90)
        m.wait_until_succeeds("ip -4 route show default | grep 'via 192.0.2.1 dev eth1' >/dev/null", timeout=30)

    def wait_wan_back(new_dns):
        wait_leases()
        wait_dns(router, "eth1", *new_dns, "2001:db8::53")
        router.wait_until_succeeds("ip -6 -o addr show dev eth1 scope global | grep 2001:db8::1 >/dev/null", timeout=60)
        router.wait_until_succeeds("ip -6 route show default | grep 'via fe80::.*dev eth1' >/dev/null", timeout=30)

    try:
        print("builder loadavg at start:", open("/proc/loadavg").read().strip())
        start_all()
        isp.wait_for_unit("kea-dhcp4-server.service", timeout=120)
        isp.wait_for_unit("kea-dhcp6-server.service", timeout=120)
        isp.wait_for_unit("radvd.service", timeout=120)
        isp.wait_until_succeeds("ss -uln | grep ':547 ' >/dev/null", timeout=60)

        with subtest("leases: DHCPv4, DHCPv6 and the RA default"):
            router.wait_for_unit("multi-user.target", timeout=180)
            router.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
            wait_leases()
            router.wait_until_succeeds("ip -6 -o addr show dev eth1 scope global | grep '2001:db8::1[0-9a-f][0-9a-f]/128' >/dev/null", timeout=90)
            router.wait_until_succeeds("ip -6 route show default | grep 'via fe80::.*dev eth1 proto ra' >/dev/null", timeout=60)
            # the kernel handles RAs, dhcpcd handles leases (N16)
            v4 = json.loads(router.succeed("ip -j -4 route show default"))
            assert [(r["dev"], r["protocol"], r["metric"]) for r in v4] == [("eth1", "dhcp", 100)], v4
            print("observed route protocols:", sorted({r["protocol"] for r in json.loads(router.succeed("ip -j route show table all")) + json.loads(router.succeed("ip -j -6 route show table all"))}))
            router.fail("ip -4 addr show | grep 169.254. >/dev/null")
            router.fail("journalctl -b --no-pager | grep -i 'using IPv4LL' >/dev/null")
            print("NETIF_DHCP_LEASES_OK")

        with subtest("one supervised dhcpcd per DHCP link, with netif's config"):
            router.succeed("systemctl is-active netif-dhcpcd-eth1.service")
            router.fail("systemctl cat netif-dhcpcd-eth2.service")
            router.succeed("test \"$(pgrep -c dhcpcd)\" = 1")
            router.succeed("systemctl show -p ExecStart netif-dhcpcd-eth1.service | grep 'dhcpcd-10\\.[5-9]' >/dev/null")
            router.succeed("grep -x noipv6rs /etc/netif/dhcpcd/eth1.conf && grep -x noipv4ll /etc/netif/dhcpcd/eth1.conf")
            # no stock dhcpcd hook ran: resolv.conf is resolved's stub
            router.succeed("readlink -f /etc/resolv.conf | grep systemd/resolve >/dev/null")
            router.fail("systemctl is-active dhcpcd.service")
            router.fail("systemctl is-active systemd-networkd.service")
            print("NETIF_DHCP_UNIT_OK")

        with subtest("online means a DHCP address (N32)"):
            router.succeed("systemctl is-active netif-online.service")
            router.succeed("grep 192.0.2.1 /run/online-probe")
            router.fail("journalctl -u netif-online --no-pager | grep 'no DHCP address' >/dev/null")
            print("NETIF_DHCP_ONLINE_OK")

        with subtest("per-link DNS in resolved after boot (N9)"):
            wait_dns(router, "eth1", "192.0.2.53", "2001:db8::53")
            wait_dns(router, "eth2", "192.168.10.53")
            domains = router.succeed("resolvectl domain eth1")
            assert "isp.test" in domains and "v6.isp.test" in domains, domains
            assert "192.0.2.53" not in dns(router, "eth2")
            print("NETIF_DHCP_DNS_BOOT_OK")

        with subtest("prefix delegation: a /64 of the delegated /60 on the LAN link (N16)"):
            router.wait_until_succeeds("ip -6 -o addr show dev eth2 scope global | grep '2001:db8:10[0-9a-f][0-9a-f]:1::1/64' >/dev/null", timeout=60)
            router.succeed("grep '^ia_pd [0-9]*/::/60 eth2/1/64$' /etc/netif/dhcpcd/eth1.conf")
            print("NETIF_DHCP_PD_OK")

        with subtest("a DHCPv4-only link: lease, DNS, IPv6 left to the kernel (N16)"):
            client4.wait_for_unit("multi-user.target", timeout=180)
            wait_leases(client4)
            wait_dns(client4, "eth1", "192.0.2.53")
            client4.succeed("grep -x ipv4only /etc/netif/dhcpcd/eth1.conf")
            assert client4.succeed("cat /proc/sys/net/ipv6/conf/eth1/addr_gen_mode").strip() == "0"
            assert router.succeed("cat /proc/sys/net/ipv6/conf/eth2/addr_gen_mode").strip() == "0"
            client4.fail("ip -6 -o addr show dev eth1 scope global | grep /128 >/dev/null")
            print("NETIF_DHCP_IPV4ONLY_OK")

        with subtest("one default per family, at netif's metric (N18, N21)"):
            # the private link: lease, classless route and DNS, no default
            client4.wait_until_succeeds("ip -4 -o addr show dev eth2 scope global | grep 198.51.100.1 >/dev/null", timeout=90)
            client4.wait_until_succeeds("ip -4 route show 10.50.0.0/16 | grep 'via 198.51.100.1 dev eth2 proto dhcp' >/dev/null", timeout=30)
            client4.succeed("grep -x nogateway /etc/netif/dhcpcd/eth2.conf")
            client4.fail("grep -x nogateway /etc/netif/dhcpcd/eth1.conf")
            wait_dns(client4, "eth2", "198.51.100.53")
            # RAs on the private link give a prefix and an address, no router
            client4.wait_until_succeeds("ip -6 -o addr show dev eth2 scope global | grep 2001:db8:2: >/dev/null", timeout=60)
            assert client4.succeed("cat /proc/sys/net/ipv6/conf/eth2/accept_ra_defrtr").strip() == "0"
            client4.wait_until_succeeds("ip -6 route show default | grep 'dev eth1 proto ra' >/dev/null", timeout=60)
            for machine in [client4, router]:
                v4 = json.loads(machine.succeed("ip -j -4 route show default"))
                assert [(r["dev"], r["protocol"], r["metric"]) for r in v4] == [("eth1", "dhcp", 100)], v4
                v6 = json.loads(machine.succeed("ip -j -6 route show default"))
                assert [(r["dev"], r["protocol"], r["metric"]) for r in v6] == [("eth1", "ra", 100)], v6
            # the same holds after the private lease renews (60 s lease)
            time.sleep(35)
            v4 = json.loads(client4.succeed("ip -j -4 route show default"))
            assert [r["dev"] for r in v4] == ["eth1"], v4
            print("NETIF_DHCP_DEFAULT_OK")

        with subtest("a reapply changes nothing (invariant 5)"):
            assert_ifstate_noop(router)
            assert_ifstate_noop(client4)
            wait_dns(router, "eth1", "192.0.2.53", "2001:db8::53", timeout=10)
            wait_dns(router, "eth2", "192.168.10.53", timeout=10)
            router.succeed("test \"$(pgrep -c dhcpcd)\" = 1")
            print("NETIF_DHCP_NOOP_OK")

        with subtest("a renewal with changed DNS servers reaches resolved (N9)"):
            isp.succeed("/run/current-system/specialisation/dns2/bin/switch-to-configuration test >&2")
            isp.wait_for_unit("kea-dhcp4-server.service")
            wait_dns(router, "eth1", "192.0.2.54", "192.0.2.55", "2001:db8::53", timeout=90)
            assert "192.0.2.53" not in dns(router, "eth1")
            print("NETIF_DHCP_RENEW_OK")

        new_dns = ["192.0.2.54", "192.0.2.55"]

        with subtest("a real carrier loss: both protocols, DNS and the RA default return (N16)"):
            router.send_monitor_command("set_link vlan1 off")
            router.wait_until_succeeds("test \"$(cat /sys/class/net/eth1/carrier)\" = 0", timeout=20)
            time.sleep(4)
            assert dns(router, "eth1") == [], dns(router, "eth1")
            router.send_monitor_command("set_link vlan1 on")
            wait_wan_back(new_dns)
            assert eloop_errors(router) == 0
            print("NETIF_DHCP_CARRIER_OK")

        with subtest("five down/up cycles (N16)"):
            for cycle in range(5):
                router.succeed("ip link set eth1 down; sleep 3; ip link set eth1 up")
                wait_wan_back(new_dns)
                assert eloop_errors(router) == 0, f"cycle {cycle}"
            # the delegated prefix is still on the LAN link
            router.wait_until_succeeds("ip -6 -o addr show dev eth2 scope global | grep '2001:db8:10[0-9a-f][0-9a-f]:1::1/64' >/dev/null", timeout=60)
            print("NETIF_DHCP_FLAP_OK")

        with subtest("a static link down/up, ten fast flaps, a resolved restart (N9)"):
            router.succeed("ip link set eth2 down; sleep 2")
            assert dns(router, "eth2") == []
            router.succeed("ip link set eth2 up")
            wait_dns(router, "eth2", "192.168.10.53", timeout=20)
            router.succeed("for i in $(seq 10); do ip link set eth2 down; ip link set eth2 up; done")
            time.sleep(6)
            wait_dns(router, "eth2", "192.168.10.53", timeout=5)
            router.succeed("systemctl restart systemd-resolved.service")
            wait_dns(router, "eth1", *new_dns, "2001:db8::53", timeout=30)
            wait_dns(router, "eth2", "192.168.10.53", timeout=30)
            print("NETIF_DHCP_DNS_FLAP_OK")

        with subtest("the DNS watcher and dhcpcd are restarted when they die (N31)"):
            router.succeed("systemctl kill -s KILL netif-dns.service")
            router.wait_until_succeeds("systemctl is-active netif-dns.service", timeout=20)
            router.succeed("ip link set eth2 down; sleep 1; ip link set eth2 up")
            wait_dns(router, "eth2", "192.168.10.53", timeout=20)
            router.succeed("systemctl kill -s KILL netif-dhcpcd-eth1.service")
            router.wait_until_succeeds("systemctl is-active netif-dhcpcd-eth1.service && test \"$(systemctl show -p NRestarts --value netif-dhcpcd-eth1.service)\" -ge 1", timeout=30)
            wait_wan_back(new_dns)
            router.succeed("test \"$(pgrep -c dhcpcd)\" = 1")
            print("NETIF_DHCP_SUPERVISED_OK")

        with subtest("stopping the unit removes the lease; the reapply still changes nothing"):
            router.succeed("systemctl stop netif-dhcpcd-eth1.service")
            router.wait_until_fails("ip -4 -o addr show dev eth1 scope global | grep 192.0.2. >/dev/null", timeout=20)
            assert dns(router, "eth1") == [], dns(router, "eth1")
            router.succeed("systemctl start netif-dhcpcd-eth1.service")
            wait_wan_back(new_dns)
            assert_ifstate_noop(router)
            print("NETIF_DHCP_RA_IFSTATE_OK")

        print("builder loadavg at end:", open("/proc/loadavg").read().strip())
        print("NETIF_DHCP_OK")
    except Exception:
        for machine in [router, client4, isp]:
            for command in [
                "ip -br addr >&2",
                "ip route show table all >&2; ip -6 route show table all >&2",
                "resolvectl dns >&2; ls -l /run/netif-dns >&2",
                "systemctl status 'netif-*' --no-pager -l >&2",
                "journalctl -b --no-pager | grep -E 'dhcpcd|ifstate|netif' | tail -n 200 >&2",
                "journalctl -u kea-dhcp4-server -u kea-dhcp6-server -u radvd --no-pager -l | tail -n 60 >&2",
            ]:
                machine.execute(command)
        raise
  '';
}
