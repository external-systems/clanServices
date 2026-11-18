# netif-hotplug (specs/netif.md N12, N18; phase P2). An IfState machine
# gets a second wired NIC while it runs, the way a USB-C dock arrives:
# QEMU hot-plugs a USB network adapter. The `wired-hotplug` owner must bring it up by DHCP
# behind the declared link, IfState must leave it alone, and unplugging
# must leave nothing behind.
#
#   deck eth1 (declared, static) ── vlan 1 ── gw
#   deck dock (hot-plugged, USB) ── vlan 2 ── gw (DHCPv4, router advertisements)
{inputs, ...}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
in {
  name = "netif-hotplug";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        deck = {};
        gw = {};
      };
      instances.home = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.deck.settings.links.wired = {
          interface = "eth1";
          static = {
            ipv4 = ["192.168.1.1/24"];
            ipv6 = ["fd00:1::1/64"];
          };
          gateway = {
            ipv4 = "192.168.1.2";
            ipv6 = "fd00:1::2";
          };
          ra = false;
          nameservers = ["192.168.1.2"];
        };
      };
    };
  };

  nodes = {
    deck = {pkgs, ...}: {
      virtualisation = {
        cores = 1;
        memorySize = 1536;
        # the second NIC arrives later, on this USB controller
        vlans = [1];
        qemu.options = ["-device qemu-xhci,id=xhci"];
      };
      environment.systemPackages = [pkgs.jq];
      # The test VM keeps kernel names, and the kernel calls a USB
      # adapter eth2 or usb0 by its MAC address. On hardware this is
      # '^enx' or the dock's USB path prefix.
      clanServices.netif.hotplug.interfaces = [
        "^eth2"
        "^usb"
      ];
    };

    gw = {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          inherit ifstateOverlay;
          addresses = [
            "192.168.1.2/24"
            "fd00:1::2/64"
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
      networking = {
        firewall.enable = false;
        ifstate.settings = {
          interfaces.eth2 = {
            addresses = [
              "198.51.100.1/24"
              "fd00:2::1/64"
            ];
            link = {
              kind = "physical";
              state = "up";
            };
          };
          # a router that sends advertisements must forward (§7)
          sysctl_conf = ''
            net.ipv6.conf.all.forwarding = 1
          '';
        };
      };
      services = {
        radvd = {
          enable = true;
          config = ''
            interface eth2 {
              AdvSendAdvert on;
              MinRtrAdvInterval 3;
              MaxRtrAdvInterval 5;
              prefix fd00:2::/64 { };
            };
          '';
        };
        kea.dhcp4 = {
          enable = true;
          settings = {
            interfaces-config = {
              interfaces = ["eth2"];
              service-sockets-max-retries = 30;
              service-sockets-retry-wait-time = 1000;
            };
            lease-database = {
              type = "memfile";
              persist = false;
            };
            valid-lifetime = 600;
            subnet4 = [
              {
                id = 1;
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
                ];
              }
            ];
          };
        };
      };
    };
  };

  testScript = ''
    import json
    import os

    ${import ../../../../tests/ifstate-noop.nix}

    def plug():
        """A NIC on the second VLAN appears, as a dock does."""
        sock = os.environ["QEMU_VDE_SOCKET_2"]
        print(deck.send_monitor_command(f"netdev_add vde,id=dock,sock={sock}"))
        print(deck.send_monitor_command("device_add usb-net,netdev=dock,id=dock0,bus=xhci.0,mac=52:54:00:12:02:09"))
        return deck.wait_until_succeeds(
            "ip -o link show | grep -o -E '(eth2|usb[0-9]+)' | head -n1 | grep .", timeout=60
        ).strip()

    def unplug(dock):
        print(deck.send_monitor_command("device_del dock0"))
        deck.wait_until_fails(f"ip link show {dock}", timeout=60)
        print(deck.send_monitor_command("netdev_del dock"))

    def defaults(family):
        routes = json.loads(deck.succeed(f"ip -j -{family} route show default"))
        return sorted((r["dev"], r["metric"]) for r in routes)

    def leaves_through(dev):
        for family, target in [(4, "203.0.113.7"), (6, "2001:db8::7")]:
            got = json.loads(deck.succeed(f"ip -j -{family} route get {target}"))[0]["dev"]
            assert got == dev, f"IPv{family} traffic leaves through {got}, expected {dev}"

    def docked(dock):
        deck.wait_until_succeeds(f"systemctl is-active netif-hotplug@{dock}.service", timeout=60)
        deck.wait_until_succeeds(f"ip -4 -o addr show dev {dock} | grep -F '198.51.100.1' >/dev/null", timeout=120)
        deck.wait_until_succeeds(f"ip -6 route show default dev {dock} | grep via >/dev/null", timeout=60)
        # behind the declared link in both families (N18)
        assert defaults(4) == [("eth1", 100), (dock, 200)], defaults(4)
        assert defaults(6) == [("eth1", 100), (dock, 200)], defaults(6)
        leaves_through("eth1")
        deck.wait_until_succeeds(f"resolvectl dns {dock} | grep -F 198.51.100.53 >/dev/null", timeout=60)
        deck.succeed(f"ping -c 1 -W 2 -I {dock} 198.51.100.1")
        deck.wait_until_succeeds("ping -6 -c 1 -W 2 fd00:2::1", timeout=60)

    def undocked(dock):
        deck.wait_until_fails(f"systemctl is-active netif-hotplug@{dock}.service", timeout=60)
        assert defaults(4) == [("eth1", 100)], defaults(4)
        assert defaults(6) == [("eth1", 100)], defaults(6)
        assert deck.succeed("systemctl --failed --no-legend --plain").strip() == "", "a unit failed"
        deck.succeed(f"test -z \"$(ls /run/netif-dns/ | grep {dock})\"")
        deck.succeed("ping -c 1 -W 2 192.168.1.2")

    try:
        start_all()
        gw.wait_for_unit("kea-dhcp4-server.service", timeout=120)
        gw.wait_for_unit("radvd.service", timeout=120)
        deck.wait_for_unit("multi-user.target", timeout=180)
        deck.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
        deck.wait_until_succeeds("systemctl show -p ActiveState --value netif-guard.service | grep '^active$' >/dev/null", timeout=60)

        with subtest("before the dock: one link, one default per family"):
            deck.fail("ip -o link show | grep -E '(eth2|usb[0-9]+)' >/dev/null")
            assert defaults(4) == [("eth1", 100)], defaults(4)
            assert defaults(6) == [("eth1", 100)], defaults(6)
            assert_ifstate_noop(deck)

        with subtest("the dock is plugged in: DHCP, advertisements and DNS, behind the declared link (N12, N18)"):
            dock = plug()
            docked(dock)
            print("NETIF_HOTPLUG_PLUG_OK")

        with subtest("IfState leaves the hot-plugged link alone (N6)"):
            deck.succeed("netif-preview | grep 'would change nothing' >/dev/null")
            deck.succeed("systemctl start netif-drift.service")
            assert_ifstate_noop(deck)
            # the reapply did not reset the dock's metric for advertised
            # routes: the next advertisement installs the default at 200 again
            assert deck.succeed(f"sysctl -n net.ipv6.conf.{dock}.ra_defrtr_metric").strip() == "200"
            deck.succeed(f"ip -6 route flush default dev {dock}")
            deck.wait_until_succeeds(f"ip -6 route show default dev {dock} | grep via >/dev/null", timeout=60)
            docked(dock)
            print("NETIF_HOTPLUG_REAPPLY_OK")

        with subtest("the declared link loses its cable: the dock carries both families"):
            deck.succeed("ip link set eth1 down")
            leaves_through(dock)
            deck.succeed("ping -c 1 -W 2 198.51.100.1")
            deck.succeed("ip link set eth1 up; systemctl reset-failed ifstate.service; systemctl restart ifstate.service")
            deck.wait_until_succeeds("ip -6 route show default dev eth1 | grep via >/dev/null", timeout=60)
            docked(dock)
            print("NETIF_HOTPLUG_FALLBACK_OK")

        with subtest("the DHCP client is supervised: killed, it comes back with the lease"):
            deck.succeed(f"systemctl kill -s KILL netif-hotplug@{dock}.service")
            docked(dock)

        with subtest("unplugged: the client stops, nothing is left behind"):
            unplug(dock)
            undocked(dock)
            assert_ifstate_noop(deck)
            print("NETIF_HOTPLUG_UNPLUG_OK")

        with subtest("plugged in again: the same result"):
            dock = plug()
            docked(dock)
            unplug(dock)
            undocked(dock)
            print("NETIF_HOTPLUG_AGAIN_OK")

        print("NETIF_HOTPLUG_OK")
    except Exception:
        for command in [
            "ip -br link >&2; ip -br addr >&2; ip route >&2; ip -6 route >&2",
            "systemctl --failed --no-pager >&2; systemctl status 'netif-hotplug@*' --no-pager >&2",
            "for l in /sys/class/net/*; do udevadm info $l >&2; done; lsusb >&2 || true; dmesg | tail -n 40 >&2",
            "ifstatecli --config /etc/ifstate/ifstate.yaml check >&2 || true",
            "journalctl -b --no-pager | grep -E 'ifstate|netif|dhcpcd|udev' | tail -n 150 >&2",
        ]:
            deck.execute(command)
        raise
  '';
}
