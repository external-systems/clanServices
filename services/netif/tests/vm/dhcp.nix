{inputs, ...}: let
  ifstateOverlay = inputs.pkgs.overlays.ifstate;
in {
  name = "netif-dhcp";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        client = {};
        server = {};
      };
      instances.dhcp = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.client.settings.links.uplink = {
          interface = "eth1";
          dhcp.ipv4 = true;
          ra = true;
        };
      };
    };
  };

  nodes = {
    client.virtualisation = {
      cores = 1;
      memorySize = 1024;
    };
    server = {...}: {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          inherit ifstateOverlay;
          addresses = [
            "10.99.0.1/24"
            "fd00:99::1/64"
          ];
          withBase = true;
        })
      ];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
      };
      networking.firewall = {
        allowedTCPPorts = [53];
        allowedUDPPorts = [
          53
          67
          547
        ];
      };
      services = {
        dnsmasq = {
          enable = true;
          settings = {
            interface = "eth1";
            bind-interfaces = true;
            dhcp-range = "10.99.0.50,10.99.0.60,255.255.255.0,12h";
            dhcp-option = [
              "3,10.99.0.1"
              "6,10.99.0.1"
            ];
          };
        };
        radvd = {
          enable = true;
          config = ''
            interface eth1 {
              AdvSendAdvert on;
              prefix fd00:99::/64;
            };
          '';
        };
      };
    };
  };

  testScript = ''
    try:
        start_all()
        server.wait_for_unit("dnsmasq.service", timeout=120)
        server.wait_for_unit("radvd.service", timeout=120)
        client.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep -q '^success$'", timeout=120)
        client.wait_until_succeeds("ip addr show eth1 | grep -q '10.99.0.5[0-9]/24'", timeout=120)
        client.wait_until_succeeds("ip route show default | grep -q 'via 10.99.0.1'", timeout=60)
        client.wait_until_succeeds("ip -6 addr show eth1 | grep -q 'fd00:99::.*dynamic'", timeout=120)
        client.wait_until_succeeds("ip -6 route show default | grep -q 'via fe80::'", timeout=60)
        client.succeed("systemctl start ifstate.service")
        client.succeed("pgrep -fc 'dhcpcd.* eth1( |$)' | grep -qx 1")
        client.succeed("ifstatecli --config /etc/ifstate/ifstate.yaml check")
        client.fail("systemctl is-active systemd-networkd.service")
        print("NETIF_DHCP_RA_IFSTATE_OK")
    except Exception:
        for machine in [client, server]:
            for command in [
                "ip -br addr >&2",
                "ip route show table all >&2; ip -6 route show table all >&2",
                "journalctl -u ifstate.service --no-pager -l | tail -n 100 >&2",
                "ps -ef >&2; find /run/libifstate /run/dhcpcd* -maxdepth 6 -type f -print -exec cat {} \; >&2 || true",
                "journalctl -b --no-pager | grep -E 'dhcpcd|ifstate' | tail -n 200 >&2",
                "journalctl -u dnsmasq.service --no-pager -l | tail -n 60 >&2",
                "journalctl -u radvd.service --no-pager -l | tail -n 60 >&2",
            ]:
                machine.execute(command)
        raise
  '';
}
