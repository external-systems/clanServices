# Simulated Wi-Fi for VM suites (specs/netif.md N5, §7): mac80211_hwsim
# radios on the machine under test, with the access points in a foreign
# network namespace `ap`. One radio stays in the root namespace: the
# client.
#
#   cafe     two access points with one SSID on one bridge, so a client
#            can roam between them; DHCPv4, router advertisements, DNS
#   friend   a second network on its own subnet
#
# Passphrases are `<ssid>-secret`. /run/ap-cafe-{a,b}.{pid,bssid} name
# each cafe access point.
{
  lib,
  pkgs,
  ...
}: let
  hostapdConf = ssid: bridge:
    pkgs.writeText "hostapd-${ssid}.conf" ''
      interface=APIF
      driver=nl80211
      ${lib.optionalString (bridge != null) "bridge=${bridge}"}
      ssid=${ssid}
      hw_mode=g
      channel=1
      wpa=2
      wpa_key_mgmt=WPA-PSK
      rsn_pairwise=CCMP
      wpa_passphrase=${ssid}-secret
    '';
  apSetup = pkgs.writeShellScript "ap-setup" ''
    set -eux
    export PATH=${lib.makeBinPath (with pkgs; [bash iproute2 iw hostapd dnsmasq coreutils gnugrep gnused procps])}:$PATH
    for _ in $(seq 100); do [ -e /sys/class/ieee80211/phy3 ] && break; sleep 0.1; done
    ip netns add ap
    ip netns exec ap ip link set lo up
    ip netns exec ap sysctl -w net.ipv6.conf.all.forwarding=1
    ip netns exec ap ip link add br-cafe type bridge
    ip netns exec ap ip addr add 192.168.77.1/24 dev br-cafe
    ip netns exec ap ip addr add fd00:77::1/64 dev br-cafe
    ip netns exec ap ip link set br-cafe up

    start() { # phy name ssid-conf
      iw phy "$1" set netns name ap
      a=$(ip netns exec ap bash -c 'for i in /sys/class/net/wlan*; do [ "$(cat "$i/phy80211/name")" = "$0" ] && basename "$i"; done' "$1")
      ip netns exec ap ip link set "$a" up
      sed "s/APIF/$a/" "$3" > "/run/hostapd-$2.conf"
      ip netns exec ap hostapd -B -P "/run/ap-$2.pid" "/run/hostapd-$2.conf"
      ip netns exec ap cat "/sys/class/net/$a/address" > "/run/ap-$2.bssid"
      echo "$a"
    }
    start phy0 cafe-a ${hostapdConf "cafe" "br-cafe"}
    start phy1 cafe-b ${hostapdConf "cafe" "br-cafe"}
    friend=$(start phy2 friend ${hostapdConf "friend" null} | tail -n1)
    ip netns exec ap ip addr add 192.168.78.1/24 dev "$friend"

    ip netns exec ap dnsmasq --pid-file=/run/dnsmasq-cafe.pid --interface=br-cafe --bind-interfaces \
      --dhcp-range=192.168.77.50,192.168.77.99,1h --enable-ra --dhcp-range=fd00:77::,ra-stateless,64 \
      --dhcp-option=option:dns-server,192.168.77.1 \
      --no-resolv --no-hosts --dhcp-leasefile=/run/dnsmasq-cafe.leases
    ip netns exec ap dnsmasq --pid-file=/run/dnsmasq-friend.pid --interface="$friend" --bind-interfaces --port=0 \
      --dhcp-range=192.168.78.50,192.168.78.99,1h \
      --no-resolv --no-hosts --dhcp-leasefile=/run/dnsmasq-friend.leases
  '';
in {
  boot = {
    kernelModules = ["mac80211_hwsim"];
    extraModprobeConfig = "options mac80211_hwsim radios=4";
  };
  environment.systemPackages = [pkgs.iw];
  # qemu-vm switches wireless off with mkVMOverride.
  networking.wireless.iwd.enable = lib.mkOverride 0 true;
  # The access points' namespace is not IfState's to delete (N6).
  clanServices.networking.owners.access-point.netns = ["^ap$"];
  systemd.services.ap-setup = {
    wantedBy = ["multi-user.target"];
    before = [
      "iwd.service"
      "ifstate.service"
      "NetworkManager.service"
      "network-pre.target"
    ];
    wants = ["network-pre.target"];
    after = ["systemd-modules-load.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = apSetup;
    };
  };
}
