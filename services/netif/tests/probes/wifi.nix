# Probe (2026-11-16, proof session): N18 leftovers. Does iwd apply
# RoutePriorityOffset to the IPv6 default, and does a wired default at
# metric 100 win in both families?
{
  pkgs,
  lib,
  ...
}: let
  hostapdConf = pkgs.writeText "hostapd.conf" ''
    interface=APIF
    driver=nl80211
    ssid=cafe
    hw_mode=g
    channel=1
    wpa=2
    wpa_key_mgmt=WPA-PSK
    rsn_pairwise=CCMP
    wpa_passphrase=cafe-secret
  '';
  apSetup = pkgs.writeShellScript "ap-setup" ''
    set -eux
    export PATH=${lib.makeBinPath (with pkgs; [iproute2 iw hostapd dnsmasq coreutils gnugrep gnused procps])}:$PATH
    for _ in $(seq 100); do [ -e /sys/class/ieee80211/phy1 ] && break; sleep 0.1; done
    ip netns add ap
    iw phy phy0 set netns name ap
    ip netns exec ap ip link set lo up
    a=$(ip netns exec ap iw dev | grep -m1 -o 'wlan[0-9]*')
    ip netns exec ap sysctl -w net.ipv6.conf.all.forwarding=1
    ip netns exec ap ip addr add 192.168.77.1/24 dev "$a"
    ip netns exec ap ip addr add fd00:77::1/64 dev "$a"
    ip netns exec ap ip link set "$a" up
    sed "s/APIF/$a/" ${hostapdConf} > /run/hostapd.conf
    ip netns exec ap hostapd -B /run/hostapd.conf
    ip netns exec ap dnsmasq --pid-file=/run/dnsmasq-ap.pid --interface="$a" --bind-interfaces \
      --dhcp-range=192.168.77.50,192.168.77.99,1h --enable-ra --dhcp-range=fd00:77::,ra-stateless,64 \
      --no-resolv --no-hosts --dhcp-leasefile=/run/dnsmasq-ap.leases
  '';
in {
  name = "netif-wifi-probe";
  nodes.deck = {
    virtualisation = {
      memorySize = 2048;
      vlans = [1];
    };
    boot.kernelModules = ["mac80211_hwsim"];
    boot.extraModprobeConfig = "options mac80211_hwsim radios=2";
    environment.systemPackages = with pkgs; [iw jq];
    systemd.services.ap-setup = {
      wantedBy = ["multi-user.target"];
      before = ["iwd.service" "ifstate.service" "network-pre.target"];
      wants = ["network-pre.target"];
      after = ["systemd-modules-load.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = apSetup;
      };
    };
    services.resolved.enable = true;
    networking = {
      interfaces = lib.mkForce {};
      useDHCP = false;
      firewall.enable = false;
      wireless.iwd = {
        enable = lib.mkOverride 0 true;
        settings = {
          General.EnableNetworkConfiguration = true;
          Network = {
            NameResolvingService = "systemd";
            RoutePriorityOffset = 300;
            EnableIPv6 = true;
          };
        };
      };
      ifstate = {
        enable = true;
        settings = {
          parameters.ignore = {
            ifname = ["^wl"];
            netns = ["^ap$"];
            routes = [{dev = "^wl";}];
          };
          interfaces.eth1 = {
            addresses = ["192.168.1.1/24" "fd00:1::1/64"];
            link = {
              kind = "physical";
              state = "up";
            };
          };
          routing.routes = [
            {
              to = "0.0.0.0/0";
              via = "192.168.1.254";
              preference = 100;
            }
            {
              to = "::/0";
              via = "fd00:1::254";
              preference = 100;
            }
          ];
        };
      };
    };
  };

  testScript = ''
    import json
    def show(cmd):
        rc, out = deck.execute(cmd + " 2>&1")
        print(f"=== {cmd}\n{out}")
        return out
    def fact(name, value):
        print(f"FACT {name}: {value}")

    start_all()
    deck.wait_for_unit("multi-user.target")
    deck.wait_for_unit("iwd.service")
    show("systemctl status ap-setup --no-pager | tail -5; iw dev; ip netns exec ap iw dev")
    wl = deck.succeed("iw dev | grep -m1 -o 'wlan[0-9]*'").strip()
    deck.succeed(f"iwctl station {wl} scan || true")
    deck.wait_until_succeeds(f"iwctl station {wl} get-networks | grep cafe", timeout=60)
    print(deck.execute(f"iwctl --passphrase cafe-secret station {wl} connect cafe 2>&1")[1])
    deck.wait_until_succeeds(f"ip -4 addr show {wl} | grep 192.168.77.", timeout=60)
    deck.execute(f"timeout 60 sh -c 'until ip -6 route show default dev {wl} | grep via; do sleep 2; done'")
    show(f"ip -4 route show; ip -6 route show; ip -6 addr show {wl}; sysctl net.ipv6.conf.{wl}.accept_ra; resolvectl dns")

    v4 = json.loads(deck.succeed("ip -j -4 route show default"))
    v6 = json.loads(deck.succeed("ip -j -6 route show default"))
    for r in v4 + v6:
        print("DEFAULT", r.get("dev"), r.get("gateway"), "proto", r.get("protocol"), "metric", r.get("metric"))
    fact("wifi_v4_default_metric", [r.get("metric") for r in v4 if r["dev"] == wl])
    fact("wifi_v6_default_metric", [r.get("metric") for r in v6 if r["dev"] == wl])
    fact("wifi_v6_default_proto", [r.get("protocol") for r in v6 if r["dev"] == wl])
    fact("wired_v4_default_metric", [r.get("metric") for r in v4 if r["dev"] == "eth1"])
    fact("wired_v6_default_metric", [r.get("metric") for r in v6 if r["dev"] == "eth1"])
    fact("v4_route_get_dev", json.loads(deck.succeed("ip -j route get 198.51.100.7"))[0]["dev"])
    fact("v6_route_get_dev", json.loads(deck.succeed("ip -j -6 route get 2001:db8::7"))[0]["dev"])
    fact("wifi_accept_ra_sysctl", deck.succeed(f"sysctl -n net.ipv6.conf.{wl}.accept_ra").strip())

    deck.succeed("systemctl restart ifstate.service; systemctl restart ifstate.service")
    v4b = json.loads(deck.succeed("ip -j -4 route show default"))
    v6b = json.loads(deck.succeed("ip -j -6 route show default"))
    fact("defaults_unchanged_after_two_applies", [(r["dev"], r.get("metric")) for r in v4 + v6] == [(r["dev"], r.get("metric")) for r in v4b + v6b])

    # cable unplugged: Wi-Fi takes over with no reconfiguration
    deck.succeed("ip link set eth1 down")
    fact("unplugged_v4_route_get_dev", json.loads(deck.succeed("ip -j route get 198.51.100.7"))[0]["dev"])
    fact("unplugged_v6_route_get_dev", json.loads(deck.succeed("ip -j -6 route get 2001:db8::7"))[0]["dev"])
    print("NETIF_WIFI_PROBE_DONE")
  '';
}
