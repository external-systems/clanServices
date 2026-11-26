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
            # the one trusted link of the suite (N19)
            firewall.trust = true;
            zone = "private";
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
      # The lockout guard (N25) also pings an address behind the ISP, which
      # only the DHCP default route reaches.
      clanServices.netif.guard.targets = [{address = "203.0.113.1";}];
      specialisation = {
        # Only the DHCP client changes: it drops the router option, so the
        # default route goes. IfState's file stays the same.
        nogateway.configuration.environment.etc."netif/dhcpcd/eth1.conf".source = lib.mkForce (
          pkgs.writeText "netif-dhcpcd-eth1-nogateway.conf" ''
            noipv4ll
            ipv4only
            nogateway
            script /run/current-system/sw/bin/true
          ''
        );
        # The DHCP link becomes static, on a subnet whose gateway nobody is.
        static.configuration = {
          clanServices.netif.links.eth1.dhcp4 = lib.mkForce false;
          networking.ifstate.settings = {
            interfaces.eth1.addresses = lib.mkForce ["192.0.77.2/24"];
            routing.routes = [
              {
                to = "0.0.0.0/0";
                via = "192.0.77.1";
                dev = "eth1";
                preference = 100;
              }
            ];
          };
        };
      };
      # SSH opens its own port; the probe port is opened by nobody.
      services.openssh.enable = true;
      systemd.services.probe-listener = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} -m http.server 8080";
      };
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
      networking.ifstate.settings.interfaces = {
        eth2 = {
          addresses = [
            "198.51.100.1/24"
            "2001:db8:2::1/64"
          ];
          link = {
            kind = "physical";
            state = "up";
          };
        };
        # behind the ISP: client4's guard target
        far0 = {
          addresses = ["203.0.113.1/32"];
          link = {
            kind = "dummy";
            state = "up";
          };
        };
      };
      environment.systemPackages = [
        pkgs.tcpdump
        pkgs.netcat
      ];
      boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
      networking.firewall.enable = false;
      # The same server with other DNS servers: a renewal then brings a
      # changed lease.
      specialisation = {
        dns2.configuration.services.kea.dhcp4 = lib.mkForce (kea4 "192.0.2.54, 192.0.2.55");
        # dns2 with DHCPv6 leases that run out inside the test: preferred
        # 20 s, valid 40 s.
        short6.configuration.services.kea = {
          dhcp4 = lib.mkForce (kea4 "192.0.2.54, 192.0.2.55");
          dhcp6.settings = {
            preferred-lifetime = 20;
            valid-lifetime = 40;
          };
        };
      };
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
    ${import ../../../../tests/suite-lib.nix}

    def dns(machine, link):
        return machine.succeed(f"resolvectl dns {link}").split(":", 1)[1].split()

    def wait_dns(machine, link, *servers, timeout=75):
        end = time.time() + timeout
        while time.time() < end:
            current = dns(machine, link)
            if all(server in current for server in servers):
                return
            # the polling interval of this loop; `timeout` is its deadline
            time.sleep(1)
        raise AssertionError(f"{machine.name}: {link} DNS is {dns(machine, link)}, wanted {servers}")

    def wait_no_dns(machine, link, timeout=30):
        machine.wait_until_succeeds(f"out=$(resolvectl dns {link}) && test -z \"$(echo \"$out\" | cut -d: -f2- | tr -d '[:space:]')\"", timeout=timeout)

    def wait_dns_stable(machine, link, server, seconds, timeout=60):
        """DNS is on the link and stays for `seconds`: the settled state,
        not a moment between two link events."""
        end = time.time() + timeout
        while True:
            wait_dns(machine, link, server, timeout=max(1, end - time.time()))
            try:
                holds_for(machine, f"resolvectl dns {link} | grep -F {server} >/dev/null", seconds)
                return
            except Exception:
                if time.time() >= end:
                    raise

    def wait_lease_dropped(machine, interface, timeout=30):
        # dhcpcd saw the link go down: its NOCARRIER run of netif's exit
        # script removes the lease's DNS files
        machine.wait_until_succeeds(f"test ! -e /run/netif-dns/{interface}.dhcp4.dns && test ! -e /run/netif-dns/{interface}.dhcp6.dns", timeout=timeout)

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

        with subtest("versions"):
            print_versions(router, ["kernel", "ifstate", "dhcpcd", "nftables"])
            print("VERSION router dhcpcd unit:", router.succeed("grep -o 'dhcpcd-[0-9][0-9.]*' $(systemctl show -p ExecStart --value netif-dhcpcd-eth1.service | grep -o '/nix/store/[^ ;]*netif-dhcpcd-eth1' | head -n1) | head -n1").strip())
            print_versions(isp, ["kernel", "ifstate", "kea"])

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
            router.succeed("grep 'dhcpcd-10\\.[5-9]' $(systemctl show -p ExecStart --value netif-dhcpcd-eth1.service | grep -o '/nix/store/[^ ;]*netif-dhcpcd-eth1' | head -n1) >/dev/null")
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
            # the delegated prefix as a runtime file, for consumers (N16)
            router.wait_until_succeeds("grep -x '2001:db8:10[0-9a-f][0-9a-f]::/60' /run/netif/pd/eth1", timeout=30)
            router.fail("test -e /run/netif/pd/eth2")
            # what dhcpcd hands the exit script for the lease: the names
            # of the prefix and lifetime variables (as `new_<name>`)
            status, lease = observe("dhcpcd's variables for the DHCPv6 lease", router, "dhcpcd -6 -U -f /etc/netif/dhcpcd/eth1.conf eth1 | grep -E '^dhcp6_ia_(pd|na)'")
            for name in ["dhcp6_ia_pd1_prefix1=", "dhcp6_ia_pd1_prefix1_length=", "dhcp6_ia_pd1_prefix1_pltime=", "dhcp6_ia_pd1_prefix1_vltime="]:
                assert name in lease, f"dhcpcd does not export {name}: {lease}"
            print("NETIF_DHCP_PD_OK")

        with subtest("the prefix file lists the prefixes that the ISP prefers, sorted; none left removes it (N16)"):
            # The exit script alone, with the variables of a reply that kea
            # does not send: a real ISP answers a renewal with the old
            # prefix at a preferred lifetime of 0 beside the new one.
            script = router.succeed("sed -n 's/^script //p' /etc/netif/dhcpcd/eth1.conf").strip()
            assert script.startswith("/nix/store/"), script
            pd = "/run/netif/pd/pdtest"

            def reply(reason, *prefixes):
                """Run the exit script as dhcpcd would for a reply with these
                (prefix, length, preferred, valid) entries, in this order."""
                env = [f"reason={reason}", "interface=pdtest"]
                for index, (prefix, length, preferred, valid) in enumerate(prefixes, start=1):
                    name = f"new_dhcp6_ia_pd1_prefix{index}"
                    env += [f"{name}={prefix}", f"{name}_length={length}", f"{name}_pltime={preferred}", f"{name}_vltime={valid}"]
                router.succeed(f"env -i {' '.join(env)} {script}")
                return router.succeed(f"cat {pd} 2>/dev/null || echo absent").split()

            old, new, other = ("2001:db8:a000::", 56, 0, 3600), ("2001:db8:b000::", 56, 1800, 3600), ("2001:db8:9000::", 60, 1800, 3600)
            assert reply("BOUND6", (old[0], 56, 1800, 3600)) == ["2001:db8:a000::/56"]
            # a renewal that renumbers: the old prefix is no longer the delegation
            assert reply("RENEW6", old, new) == ["2001:db8:b000::/56"]
            assert reply("REBIND6", new, old) == ["2001:db8:b000::/56"]
            # two preferred prefixes: sorted, and the order of the reply does
            # not rewrite the file
            assert reply("RENEW6", new, other) == ["2001:db8:9000::/60", "2001:db8:b000::/56"]
            inode = router.succeed(f"stat -c '%i %Y' {pd}")
            assert reply("RENEW6", other, new) == ["2001:db8:9000::/60", "2001:db8:b000::/56"]
            assert router.succeed(f"stat -c '%i %Y' {pd}") == inode, "an unchanged set rewrote the file"
            # a stop, a restart or a carrier loss is not a prefix change
            for reason in ["STOP6", "STOPPED", "NOCARRIER", "RELEASE6"]:
                assert reply(reason) == ["2001:db8:9000::/60", "2001:db8:b000::/56"], reason
            # no prefix that the ISP prefers is left: the file goes
            assert reply("RENEW6", old) == ["absent"]
            assert reply("RENEW6", new) == ["2001:db8:b000::/56"]
            assert reply("RENEW6", (new[0], 56, 0, 0)) == ["absent"]
            assert reply("BOUND6", new) == ["2001:db8:b000::/56"]
            assert reply("RENEW6") == ["absent"]
            assert reply("BOUND6", new) == ["2001:db8:b000::/56"]
            assert reply("EXPIRE6") == ["absent"]
            router.fail("ls -A /run/netif/pd | grep -v '^eth1$'")
            print("NETIF_DHCP_PD_SET_OK")

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
            # The same holds across a renewal of the private lease, watched
            # for 35 s. kea4 sets 'valid-lifetime = 60' and sends no T1, so
            # dhcpcd renews at half the lease, every 30 s: 35 s outlasts one
            # renewal. The exit script rewrites the lease's DNS file on
            # RENEW, which proves the renewal happened inside the window.
            lease_stamp = "stat -c %y /run/netif-dns/eth2.dhcp4.dns"
            before_renewal = client4.succeed(lease_stamp)
            holds_for(client4, "ip -j -4 route show default | jq -e '[.[].dev] == [\"eth1\"]' >/dev/null", 35)
            assert client4.succeed(lease_stamp) != before_renewal, "the private lease did not renew within 35 s"
            v4 = json.loads(client4.succeed("ip -j -4 route show default"))
            assert [r["dev"] for r in v4] == ["eth1"], v4
            print("NETIF_DHCP_DEFAULT_OK")

        with subtest("links are untrusted unless declared trusted; SSH still answers (N19)"):
            uplink_ip = json.loads(client4.succeed("ip -j -4 addr show dev eth1 scope global"))[0]["addr_info"][0]["local"]
            private_ip = json.loads(client4.succeed("ip -j -4 addr show dev eth2 scope global"))[0]["addr_info"][0]["local"]
            client4.wait_for_unit("sshd.service", timeout=60)
            client4.wait_until_succeeds("ss -tln | grep ':8080 ' >/dev/null", timeout=60)
            trusted = client4.succeed("nft list ruleset | grep 'trusted interfaces' || true")
            assert "eth2" in trusted and "eth1" not in trusted, trusted
            # the untrusted uplink: SSH answers, an unopened port does not
            isp.succeed(f"nc -z -w 5 {uplink_ip} 22")
            isp.fail(f"nc -z -w 5 {uplink_ip} 8080")
            # the trusted private link: both answer
            isp.succeed(f"nc -z -w 5 {private_ip} 22")
            isp.succeed(f"nc -z -w 5 {private_ip} 8080")
            # the router's WAN is untrusted and still got DHCPv4, DHCPv6 and the prefix
            router_trusted = router.succeed("nft list ruleset | grep 'trusted interfaces' || true")
            assert "eth1" not in router_trusted and "eth2" not in router_trusted, router_trusted
            router.succeed("nft list ruleset | grep -E 'eth1.*546' >/dev/null")
            print("NETIF_DHCP_TRUST_OK")

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
            # the link stays down until dhcpcd dropped the lease and
            # resolved holds no DNS for it
            wait_lease_dropped(router, "eth1")
            wait_no_dns(router, "eth1")
            assert dns(router, "eth1") == [], dns(router, "eth1")
            router.send_monitor_command("set_link vlan1 on")
            wait_wan_back(new_dns)
            assert eloop_errors(router) == 0
            print("NETIF_DHCP_CARRIER_OK")

        with subtest("five down/up cycles (N16)"):
            for cycle in range(5):
                # down until dhcpcd dropped the lease, then up
                router.succeed("ip link set eth1 down")
                wait_lease_dropped(router, "eth1")
                router.succeed("ip link set eth1 up")
                wait_wan_back(new_dns)
                assert eloop_errors(router) == 0, f"cycle {cycle}"
            # the delegated prefix is still on the LAN link
            router.wait_until_succeeds("ip -6 -o addr show dev eth2 scope global | grep '2001:db8:10[0-9a-f][0-9a-f]:1::1/64' >/dev/null", timeout=60)
            print("NETIF_DHCP_FLAP_OK")

        with subtest("a static link down/up, ten fast flaps, a resolved restart (N9)"):
            router.succeed("ip link set eth2 down")
            wait_no_dns(router, "eth2")
            assert dns(router, "eth2") == []
            router.succeed("ip link set eth2 up")
            wait_dns(router, "eth2", "192.168.10.53", timeout=20)
            router.succeed("for i in $(seq 10); do ip link set eth2 down; ip link set eth2 up; done")
            # After the storm DNS must be back and stay: present on every
            # check for 6 s. No timer sets the 6 s; it is the window in
            # which a late link event in resolved or the watcher would
            # still remove the servers.
            wait_dns_stable(router, "eth2", "192.168.10.53", 6)
            router.succeed("systemctl restart systemd-resolved.service")
            wait_dns(router, "eth1", *new_dns, "2001:db8::53", timeout=30)
            wait_dns(router, "eth2", "192.168.10.53", timeout=30)
            print("NETIF_DHCP_DNS_FLAP_OK")

        with subtest("the DNS watcher and dhcpcd are restarted when they die (N31)"):
            old_watcher = router.succeed("systemctl show -p MainPID --value netif-dns.service").strip()
            router.succeed("systemctl kill -s KILL netif-dns.service")
            router.wait_until_succeeds("systemctl is-active netif-dns.service", timeout=20)
            # a new watcher process, and its `ip monitor` is running
            router.wait_until_succeeds(f"pid=$(systemctl show -p MainPID --value netif-dns.service); test \"$pid\" != 0 && test \"$pid\" != {old_watcher} && pgrep -P \"$pid\" -x ip >/dev/null", timeout=30)
            # the link is down until resolved forgot its DNS: only the new
            # watcher can bring the servers back
            router.succeed("ip link set eth2 down")
            wait_no_dns(router, "eth2")
            router.succeed("ip link set eth2 up")
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

        with subtest("the delegation is lost: the prefix file goes when the lease expires and returns with the ISP (N16)"):
            pd_file = "grep -x '2001:db8:10[0-9a-f][0-9a-f]::/60' /run/netif/pd/eth1 >/dev/null"
            lan = "ip -6 -o addr show dev eth2 scope global | grep '2001:db8:10[0-9a-f][0-9a-f]:1::1/64' >/dev/null"
            # a lease that runs out inside the test: preferred 20 s, valid 40 s
            isp.succeed("/run/booted-system/specialisation/short6/bin/switch-to-configuration test >&2")
            isp.wait_until_succeeds("ss -uln | grep ':547 ' >/dev/null", timeout=60)
            router.succeed("systemctl restart netif-dhcpcd-eth1.service")
            wait_wan_back(new_dns)
            router.wait_until_succeeds(pd_file, timeout=60)
            router.wait_until_succeeds(lan, timeout=60)
            router.wait_until_succeeds("dhcpcd -6 -U -f /etc/netif/dhcpcd/eth1.conf eth1 | grep -x \"dhcp6_ia_pd1_prefix1_vltime='\\?40'\\?\" >/dev/null", timeout=60)
            # a renewal of the short lease keeps the file as it is
            stamp = router.succeed("stat -c '%i %Y' /run/netif/pd/eth1")
            # (a renewal shows as a valid lifetime of the leased address that went up)
            def lease_left():
                infos = json.loads(router.succeed("ip -j -6 addr show dev eth1 scope global"))[0]["addr_info"]
                return max(info["valid_life_time"] for info in infos if info.get("prefixlen") == 128)

            left, renewed, deadline = lease_left(), False, time.time() + 60
            while not renewed and time.time() < deadline:
                # the polling interval of this loop; `deadline` bounds it
                time.sleep(1)
                now_left = lease_left()
                renewed, left = now_left > left, now_left
            assert renewed, "the short DHCPv6 lease was not renewed within 60 s"
            assert router.succeed("stat -c '%i %Y' /run/netif/pd/eth1") == stamp, "a renewal with the same prefix rewrote the file"
            # the ISP's DHCPv6 server goes away
            isp.succeed("systemctl stop kea-dhcp6-server.service")
            stopped = time.time()
            router.succeed(pd_file)
            took = seconds_until(router, "test ! -e /run/netif/pd/eth1", limit=90)
            observe("dhcpcd while the ISP's DHCPv6 was away", router, "journalctl -b -u netif-dhcpcd-eth1 --no-pager | tail -n 15")
            print(f"FINDING the prefix file was removed {took}s after the ISP's DHCPv6 server stopped (valid lifetime 40 s, bound 90 s)")
            assert took is not None, "the prefix file outlived the delegation"
            router.succeed("journalctl -b -u netif-dhcpcd-eth1 --no-pager | grep 'DHCPv6 lease expired' >/dev/null")
            router.wait_until_fails(lan, timeout=30)
            # DHCPv4 is not touched
            router.succeed("ip -4 -o addr show dev eth1 scope global | grep 192.0.2.1 >/dev/null")
            isp.succeed("systemctl start kea-dhcp6-server.service")
            isp.wait_until_succeeds("ss -uln | grep ':547 ' >/dev/null", timeout=60)
            back = seconds_until(router, pd_file, limit=120)
            print(f"FINDING the prefix file was back {back}s after the ISP's DHCPv6 server returned (bound 120 s), {round(time.time() - stopped, 1)}s after it stopped")
            assert back is not None, "the prefix file did not return with the delegation"
            router.wait_until_succeeds(lan, timeout=60)
            assert eloop_errors(router) == 0
            print("NETIF_DHCP_PD_LOST_OK")

        def client4_switch(name):
            system = "/run/booted-system" + (f"/specialisation/{name}" if name else "")
            return client4.execute(f"systemctl reset-failed ifstate.service netif-guard.service; {system}/bin/switch-to-configuration test 2>&1")

        def client4_lease():
            client4.wait_until_succeeds("ip -4 -o addr show dev eth1 scope global | grep 192.0.2.1 >/dev/null", timeout=90)
            client4.wait_until_succeeds("ip -4 route show default | grep 'via 192.0.2.1 dev eth1' >/dev/null", timeout=60)

        def client4_guard_log(pattern):
            client4.wait_until_succeeds(f"journalctl --sync; journalctl -b -u netif-guard.service --no-pager | grep '{pattern}' >/dev/null", timeout=30)

        with subtest("the guard: a change of the DHCP client alone is rolled back, and dropped by the next good switch (N25)"):
            client4.succeed("systemctl restart netif-guard.service")
            client4.succeed("grep -x '4 eth1' /var/lib/netif/guard/last-good-defaults")
            status, output = client4_switch("nogateway")
            print(output)
            assert status != 0, "the switch must report the failure"
            client4_guard_log("no answer from 203.0.113.1 (ping)")
            client4_guard_log("dhcpcd on eth1 goes back to the configuration that passed")
            client4_lease()
            # the unit runs the kept configuration, while this generation runs
            client4.succeed("test -e /run/netif-guard/dhcpcd/eth1.conf")
            client4.wait_until_succeeds("pgrep -af dhcpcd | grep /run/netif-guard/dhcpcd/eth1.conf >/dev/null", timeout=30)
            client4.succeed("ping -c1 -W2 203.0.113.1")
            status, output = client4_switch(None)
            assert status == 0, output
            client4.succeed("test ! -e /run/netif-guard/dhcpcd")
            client4.wait_until_succeeds("pgrep -af dhcpcd | grep /etc/netif/dhcpcd/eth1.conf >/dev/null", timeout=30)
            client4_lease()
            print("NETIF_DHCP_GUARD_KEPT_OK")

        with subtest("the guard: a DHCP link made static gets its DHCP client back on a rollback (N25)"):
            status, output = client4_switch("static")
            print(output)
            assert status != 0, "the switch must report the failure"
            client4_guard_log("no answer from 192.0.77.1 on eth1")
            client4_guard_log("this generation runs no DHCP client on eth1")
            client4.succeed("systemctl is-active netif-guard-dhcpcd-eth1.service")
            client4_lease()
            client4.fail("ip -4 addr show dev eth1 | grep 192.0.77.2 >/dev/null")
            client4.succeed("ping -c1 -W2 203.0.113.1")
            # the next good switch stops the guard's client and runs netif's
            status, output = client4_switch(None)
            assert status == 0, output
            client4.fail("systemctl is-active netif-guard-dhcpcd-eth1.service")
            client4.succeed("systemctl is-active netif-dhcpcd-eth1.service")
            client4_lease()
            client4.succeed("test \"$(pgrep -c dhcpcd)\" = 2")
            print("NETIF_DHCP_GUARD_STATIC_OK")

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
