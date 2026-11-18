# netif-registry (specs/netif.md N6, N7, N11; phase P1). One IfState
# machine runs netif, Tailscale against an offline Headscale, and iwd on
# a mac80211_hwsim radio whose access point lives in a foreign netns.
# The ownership registry must keep IfState away from all of them across
# reapplies, and IfState must converge before network-online.target.
_: let
  headscale = import ../../../../tests/headscale-vm.nix {};
in {
  name = "netif-registry";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        headscale = {};
        laptop = {};
        peer = {};
      };
      instances.lan = {
        module.name = "netif";
        module.input = "self";
        # Node order (headscale, laptop, peer) gives laptop 192.168.1.2.
        roles.default.machines.laptop.settings.links.uplink = {
          interface = "eth1";
          static.ipv4 = ["192.168.1.2/24"];
        };
      };
    };
  };

  nodes = {
    headscale = {
      imports = [headscale.server];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
      };
      networking.firewall.enable = false;
    };

    peer = {
      imports = [headscale.client];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
      };
      networking.firewall.enable = false;
      services.tailscale.enable = true;
    };

    laptop = {
      lib,
      pkgs,
      ...
    }: let
      hostapdConf = ssid: channel:
        pkgs.writeText "hostapd-${ssid}.conf" ''
          interface=PLACEHOLDER
          driver=nl80211
          ssid=${ssid}
          hw_mode=g
          channel=${toString channel}
          wpa=2
          wpa_key_mgmt=WPA-PSK
          rsn_pairwise=CCMP
          wpa_passphrase=${ssid}-secret
        '';
      # The access point's radio moves into netns "ap", a namespace
      # IfState must not delete; only the client radio stays visible.
      apSetup = pkgs.writeShellScript "ap-setup" ''
        set -eux
        export PATH=${lib.makeBinPath (with pkgs; [iproute2 iw hostapd dnsmasq coreutils gnugrep gnused])}:$PATH
        for _ in $(seq 100); do [ -e /sys/class/ieee80211/phy1 ] && break; sleep 0.1; done
        ip netns add ap
        iw phy phy0 set netns name ap
        ip netns exec ap ip link set lo up
        ap=$(ip netns exec ap iw dev | grep -m1 -o 'wlan[0-9]*')
        ip netns exec ap ip addr add 192.168.77.1/24 dev "$ap"
        ip netns exec ap ip link set "$ap" up
        sed "s/^interface=.*/interface=$ap/" ${hostapdConf "cafe" 1} > /run/hostapd-cafe.conf
        ip netns exec ap hostapd -B -P /run/hostapd-cafe.pid /run/hostapd-cafe.conf
        ip netns exec ap dnsmasq --pid-file=/run/dnsmasq-ap.pid --interface="$ap" \
          --bind-interfaces --dhcp-range=192.168.77.50,192.168.77.99,1h --dhcp-leasefile=/run/dnsmasq-ap.leases --no-resolv --no-hosts
      '';
    in {
      imports = [headscale.client];
      virtualisation = {
        cores = 2;
        memorySize = 1536;
      };
      boot = {
        kernelModules = ["mac80211_hwsim"];
        extraModprobeConfig = "options mac80211_hwsim radios=2";
      };
      environment.systemPackages = with pkgs; [
        iw
        yq-go
      ];
      networking = {
        # qemu-vm switches wireless off with mkVMOverride.
        wireless.iwd = {
          enable = lib.mkOverride 0 true;
          settings = {
            General.EnableNetworkConfiguration = true;
            Network.NameResolvingService = "systemd";
          };
        };
        firewall.checkReversePath = "loose";
      };
      services = {
        resolved.enable = true;
        tailscale.enable = true;
      };
      # A hand-declared owner: the access point's namespace. Without it
      # IfState deletes the netns and the AP radio falls back into the
      # root namespace.
      clanServices.networking.owners.access-point.netns = ["^ap$"];
      systemd.services.ap-setup = {
        wantedBy = ["multi-user.target"];
        before = [
          "iwd.service"
          "ifstate.service"
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
    };
  };

  testScript = ''
    ${import ../../../../tests/ifstate-noop.nix}
    def snapshot():
        return laptop.succeed(
            "ip -br link | sort; ip rule; ip route show table 52; "
            "ip -6 route show table 52; ip -4 -br addr show wlan1; ip netns list"
        )

    try:
        start_all()
        headscale.wait_for_unit("headscale.service", timeout=120)
        headscale.wait_for_open_port(443)
        headscale.succeed("headscale users create test")
        authkey = headscale.succeed("headscale preauthkeys -u 1 create --reusable").strip().splitlines()[-1]
        up = f"tailscale up --login-server https://headscale --auth-key {authkey}"
        peer.wait_for_unit("tailscaled.service")
        peer.succeed(up)
        peer_ip = peer.wait_until_succeeds("tailscale ip -4").strip()

        with subtest("IfState converges before network-online.target"):
            laptop.wait_for_unit("network-online.target", timeout=180)
            laptop.succeed("test $(systemctl show -p Result --value ifstate.service) = success")
            ifstate_done = int(laptop.succeed("systemctl show -p ExecMainExitTimestampMonotonic --value ifstate.service"))
            online = int(laptop.succeed("systemctl show -p ActiveEnterTimestampMonotonic --value network-online.target"))
            assert 0 < ifstate_done <= online, f"ifstate exited at {ifstate_done}, network-online at {online}"
            laptop.succeed("systemctl show -p After --value tailscaled.service | grep network-online.target >/dev/null")
            laptop.succeed("systemctl show -p Wants --value tailscaled.service | grep network-online.target >/dev/null")
            laptop.succeed("ip addr show eth1 | grep '192.168.1.2/24' >/dev/null")
            print("NETIF_REGISTRY_ORDER_OK")

        with subtest("Tailscale and iwd Wi-Fi come up beside IfState"):
            laptop.wait_for_unit("tailscaled.service")
            laptop.succeed(up)
            laptop.wait_until_succeeds(f"tailscale ping {peer_ip}", timeout=90)
            laptop.wait_for_unit("iwd.service")
            laptop.succeed("iwctl station wlan1 scan")
            laptop.wait_until_succeeds("iwctl station wlan1 get-networks | grep cafe >/dev/null", timeout=60)
            laptop.succeed("iwctl --passphrase cafe-secret station wlan1 connect cafe")
            laptop.wait_until_succeeds("ip -4 addr show wlan1 | grep '192.168.77.' >/dev/null", timeout=60)
            laptop.wait_until_succeeds("ping -c1 -W2 192.168.77.1", timeout=30)
            laptop.succeed("ip rule | grep -E '^5270:' >/dev/null")
            laptop.succeed("ip netns list | grep '^ap' >/dev/null")
            laptop.fail("ip link show wlan0")
            print("NETIF_REGISTRY_OWNERS_UP_OK")

        with subtest("two IfState applies leave registry owners alone"):
            before = snapshot()
            for _ in range(2):
                laptop.succeed("systemctl restart ifstate.service")
                laptop.succeed("test $(systemctl show -p Result --value ifstate.service) = success")
            after = snapshot()
            assert before == after, f"IfState reapply changed owned state:\n{before}\n---\n{after}"
            assert_ifstate_noop(laptop)
            laptop.succeed("ip netns list | grep '^ap' >/dev/null")
            laptop.succeed("ping -c1 -W2 192.168.77.1")
            laptop.succeed(f"tailscale ping {peer_ip}")
            print("NETIF_REGISTRY_REAPPLY_OK")

        with subtest("without the registry IfState would remove them"):
            owned = laptop.succeed("ifstatecli --config /etc/ifstate/ifstate.yaml check 2>&1")
            laptop.succeed("yq 'del(.parameters.ignore)' /etc/ifstate/ifstate.yaml > /tmp/no-registry.yaml")
            bare = laptop.succeed("ifstatecli --config /tmp/no-registry.yaml check 2>&1")
            print(f"=== with registry\n{owned}\n=== without registry\n{bare}")
            for name in ["tailscale0", "wlan1", "#5270"]:
                assert name not in owned, f"{name} touched with the registry"
                assert name in bare, f"{name} untouched without the registry"
            print("NETIF_REGISTRY_CONTROL_OK")

        print("NETIF_REGISTRY_OK")
    except Exception:
        for command in [
            "ip -br addr >&2; ip -br link >&2",
            "ip rule >&2; ip route show table all >&2",
            "ip netns list >&2; cat /etc/ifstate/ifstate.yaml >&2",
            "systemctl list-units --failed >&2",
            "journalctl -b -u ifstate.service -u ap-setup.service -u iwd.service -u tailscaled.service --no-pager | tail -n 200 >&2",
        ]:
            laptop.execute(command)
        raise
  '';
}
