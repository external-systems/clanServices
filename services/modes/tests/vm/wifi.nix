# netif-wifi (specs/netif.md N5, N18; phase P2). A machine with a wired
# link and a Wi-Fi radio, in a NetworkManager `default` mode and an
# IfState `developer` mode. iwd owns Wi-Fi in both; netif renders its
# settings for the mode.
#
#   default    a network never seen before is joined through
#              NetworkManager (what the KDE applet and Steam do)
#   developer  iwd joins that network by itself, roams between two access
#              points, and joins another unknown network with iwctl
#   default    NetworkManager knows the network iwctl joined
#
# Wired beats Wi-Fi in both families and in both modes; with the cable
# gone Wi-Fi carries the traffic with no reconfiguration.
_: {
  name = "netif-wifi";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines.deck = {};
      instances = {
        modes = {
          module.name = "modes";
          module.input = "self";
          roles.default.machines.deck.settings.modes = {
            default.manager = "networkmanager";
            developer.manager = "ifstate";
          };
        };
        home = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.deck.settings.links.wired = {
            interface = "eth1";
            static = {
              ipv4 = ["192.168.1.1/24"];
              ipv6 = ["fd00:1::1/64"];
            };
            gateway = {
              ipv4 = "192.168.1.254";
              ipv6 = "fd00:1::254";
            };
            ra = false;
          };
        };
      };
    };
  };

  nodes.deck = {
    config,
    pkgs,
    ...
  }: {
    imports = [../../../../tests/wifi-ap.nix];
    virtualisation = {
      cores = 2;
      memorySize = 2048;
    };
    environment = {
      systemPackages = [pkgs.jq];
      etc."netif-mode".text = config.clanServices.networking.mode.name;
    };
    # the test's own management NIC is nobody's link
    networking.networkmanager.unmanaged = ["interface-name:eth0"];
    # The wired gateway does not exist in this single-machine suite. A
    # machine with a screen has the guard off anyway (N25).
    clanServices.netif.guard.enable = false;
  };

  testScript = {nodes, ...}: let
    developer = "${nodes.deck.system.build.toplevel}/specialisation/developer";
  in ''
    import json
    import os

    ${import ../../../../tests/ifstate-noop.nix}

    def boot(mode_init):
        """Boot the deck into one mode, as the boot menu does."""
        deck.shutdown()
        if mode_init:
            os.environ["QEMU_KERNEL_PARAMS"] = f"init={mode_init}"
        else:
            os.environ.pop("QEMU_KERNEL_PARAMS", None)
        deck.start()
        deck.wait_for_unit("multi-user.target", timeout=300)

    def radio():
        deck.wait_for_unit("ap-setup.service", timeout=120)
        deck.wait_for_unit("iwd.service", timeout=120)
        return deck.wait_until_succeeds("iw dev | grep -m1 -o 'wlan[0-9]*'", timeout=60).strip()

    def defaults(family, dev):
        routes = json.loads(deck.succeed(f"ip -j -{family} route show default dev {dev}"))
        return [r["metric"] for r in routes]

    def leaves_through(dev):
        for family, target in [(4, "198.51.100.7"), (6, "2001:db8::7")]:
            got = json.loads(deck.succeed(f"ip -j -{family} route get {target}"))[0]["dev"]
            assert got == dev, f"IPv{family} traffic leaves through {got}, expected {dev}"

    def on_wifi(wl, subnet, minimum):
        """Addresses, DNS and both defaults on the Wi-Fi link, behind the wired link."""
        deck.wait_until_succeeds(f"ip -4 -o addr show dev {wl} | grep -F '{subnet}' >/dev/null", timeout=120)
        deck.wait_until_succeeds(f"ip -4 route show default dev {wl} | grep via >/dev/null", timeout=60)
        v4 = defaults(4, wl)
        assert len(v4) == 1 and v4[0] >= minimum, f"IPv4 Wi-Fi default metric {v4}, expected at least {minimum}"
        assert defaults(4, "eth1") == [100], defaults(4, "eth1")

    def bssid(wl):
        return deck.succeed(f"iw dev {wl} link | awk '/Connected to/ {{print $3}}'").strip()

    try:
        deck.start()
        deck.wait_for_unit("multi-user.target", timeout=300)

        with subtest("NetworkManager mode: iwd is the backend and leaves addresses to NetworkManager (N5)"):
            assert deck.succeed("cat /etc/netif-mode").strip() == "default"
            wl = radio()
            deck.succeed("NetworkManager --print-config | grep 'wifi.backend=iwd' >/dev/null")
            deck.succeed("grep -A2 '^\\[General\\]' /etc/iwd/main.conf | grep 'EnableNetworkConfiguration=false' >/dev/null")
            deck.wait_until_succeeds(f"nmcli -t -f DEVICE,TYPE device | grep '^{wl}:wifi$' >/dev/null", timeout=60)

        with subtest("NetworkManager mode: a network never seen before is joined; wired wins (N18)"):
            deck.wait_until_succeeds("nmcli device wifi rescan; nmcli -t -f SSID device wifi list | grep '^cafe$' >/dev/null", timeout=120)
            deck.succeed("nmcli device wifi connect cafe password cafe-secret")
            on_wifi(wl, "192.168.77.", 600)
            deck.wait_until_succeeds(f"ip -6 route show default dev {wl} | grep via >/dev/null", timeout=90)
            assert all(metric >= 600 for metric in defaults(6, wl)), defaults(6, wl)
            assert defaults(6, "eth1") == [100], defaults(6, "eth1")
            deck.wait_until_succeeds(f"resolvectl dns {wl} | grep -F 192.168.77.1 >/dev/null", timeout=60)
            deck.wait_until_succeeds(f"ping -c 1 -W 2 -I {wl} 192.168.77.1", timeout=60)
            leaves_through("eth1")
            deck.succeed("nmcli device disconnect eth1")
            leaves_through(wl)
            deck.succeed("nmcli connection up netif-eth1")
            deck.wait_until_succeeds("ip -4 route show default dev eth1 | grep via >/dev/null", timeout=60)
            leaves_through("eth1")
            # the known network lands in iwd's store, which both modes share
            deck.succeed("test -s /var/lib/iwd/cafe.psk")
            print("NETIF_WIFI_NETWORKMANAGER_OK")

        with subtest("IfState mode: iwd joins the known network by itself; wired wins in both families (N5, N18)"):
            boot("${developer}/init")
            assert deck.succeed("cat /etc/netif-mode").strip() == "developer"
            deck.fail("systemctl cat NetworkManager.service")
            wl = radio()
            deck.succeed("grep 'EnableNetworkConfiguration=true' /etc/iwd/main.conf >/dev/null")
            deck.succeed("grep 'RoutePriorityOffset=300' /etc/iwd/main.conf >/dev/null")
            on_wifi(wl, "192.168.77.", 300)
            deck.wait_until_succeeds(f"ip -6 route show default dev {wl} | grep via >/dev/null", timeout=90)
            assert all(300 <= metric < 600 for metric in defaults(4, wl) + defaults(6, wl)), (defaults(4, wl), defaults(6, wl))
            assert defaults(6, "eth1") == [100], defaults(6, "eth1")
            deck.wait_until_succeeds(f"resolvectl dns {wl} | grep -F 192.168.77.1 >/dev/null", timeout=60)
            deck.wait_until_succeeds(f"ping -c 1 -W 2 -I {wl} 192.168.77.1", timeout=60)
            leaves_through("eth1")
            # IfState leaves the Wi-Fi link, its addresses and its routes alone
            deck.succeed("netif-preview | grep 'would change nothing' >/dev/null")
            assert_ifstate_noop(deck)
            deck.succeed(f"ping -c 1 -W 2 -I {wl} 192.168.77.1")
            print("NETIF_WIFI_IFSTATE_OK")

        with subtest("IfState mode: roaming to the other access point of the same network"):
            first = bssid(wl)
            points = {
                deck.succeed(f"cat /run/ap-cafe-{name}.bssid").strip(): name for name in ["a", "b"]
            }
            assert first in points, (first, points)
            deck.succeed(f"kill $(cat /run/ap-cafe-{points[first]}.pid)")
            deck.wait_until_succeeds(
                f"iw dev {wl} link | grep 'Connected to' | grep -v -F '{first}' >/dev/null", timeout=180
            )
            assert bssid(wl) in points and bssid(wl) != first, (bssid(wl), points)
            on_wifi(wl, "192.168.77.", 300)
            deck.wait_until_succeeds(f"ping -c 1 -W 2 -I {wl} 192.168.77.1", timeout=60)
            leaves_through("eth1")
            print("NETIF_WIFI_ROAM_OK")

        with subtest("IfState mode: with the cable gone Wi-Fi carries both families"):
            deck.wait_until_succeeds(f"ip -6 route show default dev {wl} | grep via >/dev/null", timeout=90)
            deck.succeed("ip link set eth1 down")
            leaves_through(wl)
            deck.succeed("ip link set eth1 up; systemctl reset-failed ifstate.service; systemctl restart ifstate.service")
            deck.wait_until_succeeds("ip -4 route show default dev eth1 | grep via >/dev/null", timeout=60)
            deck.wait_until_succeeds("ip -6 route show default dev eth1 | grep via >/dev/null", timeout=60)
            leaves_through("eth1")
            print("NETIF_WIFI_FALLBACK_OK")

        with subtest("IfState mode: another unknown network is joined with iwctl (N5)"):
            deck.succeed(f"iwctl station {wl} scan || true")
            deck.wait_until_succeeds(f"iwctl station {wl} get-networks | grep friend >/dev/null", timeout=120)
            deck.succeed(f"iwctl --passphrase friend-secret station {wl} connect friend")
            on_wifi(wl, "192.168.78.", 300)
            deck.wait_until_succeeds(f"ping -c 1 -W 2 -I {wl} 192.168.78.1", timeout=60)
            deck.succeed("test -s /var/lib/iwd/friend.psk")
            print("NETIF_WIFI_ADHOC_OK")

        with subtest("back in the NetworkManager mode: it knows the network iwctl joined (N5)"):
            boot(None)
            assert deck.succeed("cat /etc/netif-mode").strip() == "default"
            wl = radio()
            deck.wait_until_succeeds("nmcli -t -f NAME connection show | grep '^friend$' >/dev/null", timeout=120)
            deck.succeed("nmcli -t -f NAME connection show | grep '^cafe$' >/dev/null")
            # one of the two known networks comes up with nobody asking
            deck.wait_until_succeeds(f"ip -4 -o addr show dev {wl} | grep -E '192\\.168\\.7[78]\\.' >/dev/null", timeout=180)
            leaves_through("eth1")
            print("NETIF_WIFI_SHARED_OK")

        print("NETIF_WIFI_OK")
    except Exception:
        for command in [
            "cat /etc/netif-mode >&2; ip -br link >&2; ip -br addr >&2; ip route >&2; ip -6 route >&2",
            "iw dev >&2; ip netns exec ap iw dev >&2; cat /etc/iwd/main.conf >&2; ls -la /var/lib/iwd >&2",
            "systemctl --failed --no-pager >&2; systemctl status ap-setup --no-pager >&2",
            "nmcli device >&2; nmcli connection show >&2; nmcli device wifi list >&2",
            "iwctl station list >&2; iwctl known-networks list >&2",
            "journalctl -b --no-pager | grep -E 'NetworkManager|ifstate|netif|iwd|hostapd|ap-setup' | tail -n 200 >&2",
        ]:
            deck.execute(command)
        raise
  '';
}
