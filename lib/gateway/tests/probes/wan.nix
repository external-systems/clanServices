# Probe PR5 (specs/gateway.md §6; specs/netif.md N43, N44).
#
#   isp eth1 ── vlan 1 ── router `wan`   (found by its permanent MAC, presents another MAC)
#   isp eth2.0 ─ vlan 2 ── router `wan0` (the ISP speaks only frames tagged with VLAN 0)
#
# Questions:
#   - A physical link found by its permanent MAC that presents another
#     MAC: does IfState set it before DHCP starts, does the DHCP server
#     see it, does it survive an apply and a reboot? (N43)
#   - VLAN 0: can IfState render a VLAN child with id 0, does DHCP run
#     over it, and what happens without it? (N44)
#
# Lines that start with FINDING are the result.
{inputs, ...}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  # the driver's MAC for node 2 (router) on vlan 1
  permanent = "52:54:00:12:01:02";
  presented = "02:00:5e:10:00:01";

  sockets = interfaces: {
    inherit interfaces;
    service-sockets-max-retries = 30;
    service-sockets-retry-wait-time = 1000;
  };
  memfile = {
    type = "memfile";
    persist = false;
  };
in {
  name = "probe-wan";

  clan = {
    directory = ./.;
    test.useContainers = false;
    inventory = {
      machines = {
        isp = {};
        router = {};
      };
      instances.wan = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.router.settings.links = {
          wan = {
            match.mac = permanent;
            zone = "wan";
            dhcp = {
              ipv4 = true;
              ipv6 = true;
            };
            mac = presented;
          };
          ont = {
            interface = "eth2";
            ra = false;
          };
          wan0 = {
            vlan = {
              id = 0;
              parent = "ont";
            };
            # a VLAN child does not inherit the parent's MAC
            mac = "02:00:5e:10:00:02";
            zone = "wan";
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
      environment.systemPackages = [
        pkgs.jq
        pkgs.tcpdump
        pkgs.ethtool
      ];
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
          2
        ];
      };
      environment.systemPackages = [pkgs.tcpdump];
      boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
      networking = {
        firewall.enable = false;
        ifstate.settings.interfaces = {
          eth2.link = {
            kind = "physical";
            state = "up";
          };
          "eth2.0" = {
            addresses = ["198.51.100.1/24"];
            link = {
              kind = "vlan";
              link = "eth2";
              vlan_id = 0;
              state = "up";
            };
          };
        };
      };
      services = {
        kea = {
          dhcp4 = {
            enable = true;
            settings = {
              interfaces-config = sockets [
                "eth1"
                "eth2.0"
              ];
              lease-database = memfile;
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
                      data = "192.0.2.1";
                    }
                  ];
                }
                {
                  id = 2;
                  subnet = "198.51.100.0/24";
                  interface = "eth2.0";
                  pools = [{pool = "198.51.100.100 - 198.51.100.150";}];
                  option-data = [
                    {
                      name = "domain-name-servers";
                      data = "198.51.100.1";
                    }
                  ];
                }
              ];
            };
          };
          dhcp6 = {
            enable = true;
            settings = {
              interfaces-config = sockets ["eth1"];
              lease-database = memfile;
              subnet6 = [
                {
                  id = 1;
                  subnet = "2001:db8::/64";
                  interface = "eth1";
                  pools = [{pool = "2001:db8::100-2001:db8::1ff";}];
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
          '';
        };
      };
    };
  };

  testScript = ''
    def observe(label, machine, cmd):
        status, out = machine.execute(cmd + " 2>&1")
        print(f"FINDING {label}: rc={status}\n{out.rstrip()}")
        return status, out.strip()

    def mac_checks(tag):
        router.wait_until_succeeds("ip -4 -o addr show dev wan scope global | grep 192.0.2.1 >/dev/null", timeout=120)
        router.wait_until_succeeds("ip -6 -o addr show dev wan scope global | grep '2001:db8::1' >/dev/null", timeout=120)
        observe(f"{tag}: the link", router, "ip -d link show wan | head -3; echo permanent: $(ethtool -P wan); cat /sys/class/net/wan/address")
        observe(f"{tag}: addresses", router, "ip -br addr")
        observe(f"{tag}: what the ISP sees", isp, "ip neigh show dev eth1; journalctl -u kea-dhcp4-server --no-pager | grep -i 'hwaddr\\|lease4_alloc\\|DHCP4_LEASE_ALLOC' | tail -4; journalctl -u kea-dhcp6-server --no-pager | grep -i 'duid\\|LEASE_ALLOC' | tail -4")
        observe(f"{tag}: journal order (IfState, then dhcpcd)", router, "journalctl -b --no-pager -u ifstate -u netif-dhcpcd-wan | grep -i 'address\\|starting\\|started\\|soliciting\\|leased\\|DUID' | head -14")
        observe(f"{tag}: ifstatecli check", router, "ifstatecli check | grep -v ' ok$\\|^$\\|= '")

    start_all()
    isp.wait_for_unit("multi-user.target", timeout=300)
    router.wait_for_unit("multi-user.target", timeout=300)
    isp.wait_until_succeeds("ss -uln | grep ':547 ' >/dev/null", timeout=60)

    with subtest("N43: a physical link that presents another MAC"):
        mac_checks("first boot")
        assert router.succeed("cat /sys/class/net/wan/address").strip() == "${presented}"
        router.succeed("systemctl restart ifstate.service")
        mac_checks("after an apply")
        first = router.succeed("ip -4 -o addr show dev wan scope global").split()[3]
        router.shutdown()
        router.start()
        router.wait_for_unit("multi-user.target", timeout=300)
        mac_checks("after a reboot")
        second = router.succeed("ip -4 -o addr show dev wan scope global").split()[3]
        print(f"FINDING lease before the reboot {first}, after {second}")
        assert router.succeed("cat /sys/class/net/wan/address").strip() == "${presented}"
        print("PROBE_WAN_MAC_OK")

    with subtest("N44: DHCP over a VLAN 0 child"):
        observe("ISP side", isp, "ip -d link show eth2.0; ip -br addr")
        observe("router side", router, "ip -d link show eth2.0; ip -br addr show eth2.0; systemctl list-units 'netif-dhcpcd*' --no-legend; cat /etc/ifstate/ifstate.yaml 2>/dev/null | grep -B4 -A6 vlan_id")
        status, _ = router.execute("timeout 120 sh -c 'until ip -4 -o addr show dev eth2.0 scope global | grep 198.51.100.1 >/dev/null; do sleep 1; done'")
        print(f"FINDING a DHCPv4 lease over the VLAN 0 child: rc={status}")
        isp.execute("tcpdump -i eth2 -e -n -c 6 'icmp or arp or (vlan and (icmp or arp))' > /tmp/tags.txt 2>&1 &")
        observe("ping over VLAN 0", router, "sleep 1; ping -c2 -W2 198.51.100.1")
        observe("the frames on the ISP's port", isp, "sleep 2; cat /tmp/tags.txt")

    with subtest("N44: the same port without a VLAN 0 child"):
        router.succeed("systemctl stop netif-dhcpcd-eth2.0.service; ip link del eth2.0; ip addr add 198.51.100.3/24 dev eth2")
        isp.execute("tcpdump -i eth2 -e -n -c 6 'icmp or arp or (vlan and (icmp or arp))' > /tmp/untagged.txt 2>&1 &")
        router.execute("tcpdump -i eth2 -e -n -c 6 'icmp or arp or (vlan and (icmp or arp))' > /tmp/untagged.txt 2>&1 &")
        observe("router pings the ISP untagged", router, "sleep 1; ping -c2 -W2 198.51.100.1")
        observe("ISP pings the router, tagged with VLAN 0", isp, "ping -c2 -W2 198.51.100.3")
        observe("frames on the ISP's port", isp, "sleep 2; cat /tmp/untagged.txt")
        observe("frames on the router's port", router, "cat /tmp/untagged.txt")

    print("PROBE_WAN_OK")
  '';
}
