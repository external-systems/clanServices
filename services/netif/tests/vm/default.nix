_: {
  name = "netif";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines.edge-1 = {};

      instances = {
        lan = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.edge-1.settings = {
            endpoint = "edge-1";
            links.uplink = {
              interface = "eth1";
              mtu = 1400;
              static = {
                ipv4 = ["10.99.0.2/24"];
                ipv6 = ["fd00:99::2/64"];
              };
              endpoint = true;
              routingPolicy = {
                table = 300;
                from = ["10.99.0.2/32"];
              };
            };
          };
        };

        dmz = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.edge-1.settings.links = {
            nic0.interface = "eth2";
            nic1.interface = "eth3";
            agg0 = {
              bond.members = [
                "nic0"
                "nic1"
              ];
              static.ipv4 = ["10.20.0.1/24"];
            };
            virbr0 = {
              kind = "bridge";
              static.ipv4 = ["10.30.0.1/24"];
            };
            trunk.interface = "eth4";
            dmz10 = {
              vlan = {
                id = 10;
                parent = "trunk";
              };
              static = {
                ipv4 = ["10.10.10.1/24"];
                ipv6 = ["fd00:10::1/64"];
              };
            };
          };
        };
      };
    };
  };

  nodes.edge-1 = {pkgs, ...}: {
    environment.systemPackages = [pkgs.yq];
    virtualisation = {
      cores = 1;
      memorySize = 1536;
      vlans = [
        1
        2
        3
        4
      ];
    };
  };

  testScript = ''
    try:
        start_all()
        with subtest("static links render through IfState"):
            edge_1.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
            edge_1.wait_until_succeeds("ip link show agg0 && ip link show virbr0 && ip link show eth4.10", timeout=120)
            edge_1.wait_until_succeeds(
                "ip addr show eth1 | grep '10.99.0.2/24' >/dev/null && "
                "ip addr show eth1 | grep 'fd00:99::2/64' >/dev/null && "
                "ip addr show agg0 | grep '10.20.0.1/24' >/dev/null && "
                "ip addr show virbr0 | grep '10.30.0.1/24' >/dev/null && "
                "ip addr show eth4.10 | grep '10.10.10.1/24' >/dev/null && "
                "ip addr show eth4.10 | grep 'fd00:10::1/64' >/dev/null && "
                "ip rule show | grep 'from 10.99.0.2 lookup 300' >/dev/null",
                timeout=120,
            )
            edge_1.succeed("ip addr show eth1 | grep '10.99.0.2/24' >/dev/null")
            edge_1.succeed("ip addr show eth1 | grep 'fd00:99::2/64' >/dev/null")
            edge_1.succeed("ip link show eth1 | grep 'mtu 1400' >/dev/null")
            edge_1.succeed("ip -d link show agg0 | grep 'bond' >/dev/null")
            edge_1.succeed("ip -d link show virbr0 | grep 'bridge' >/dev/null")
            edge_1.succeed("ip -d link show eth4.10 | grep 'vlan.*id 10' >/dev/null")
            edge_1.succeed("ip addr show agg0 | grep '10.20.0.1/24' >/dev/null")
            edge_1.succeed("ip addr show virbr0 | grep '10.30.0.1/24' >/dev/null")
            edge_1.succeed("ip addr show eth4.10 | grep '10.10.10.1/24' >/dev/null")
            edge_1.succeed("ip addr show eth4.10 | grep 'fd00:10::1/64' >/dev/null")
            edge_1.succeed("ip rule show | grep 'from 10.99.0.2 lookup 300' >/dev/null")
            edge_1.succeed("test -f /etc/ifstate/ifstate.yaml")
            edge_1.succeed("ifstatecli --config /etc/ifstate/ifstate.yaml check")
            edge_1.fail("systemctl is-active systemd-networkd.service")

        # Apply a changed address live: no reboot and no loss of the other links.
        with subtest("live address change without reboot"):
            edge_1.succeed("cp /etc/ifstate/ifstate.yaml /tmp/netif-live.yaml && chmod u+w /tmp/netif-live.yaml")
            edge_1.succeed("yq -y -i '.interfaces.eth1.addresses[0] = \"10.99.0.20/24\"' /tmp/netif-live.yaml")
            edge_1.succeed("ifstatecli --config /tmp/netif-live.yaml apply")
            edge_1.succeed("ip addr show eth1 | grep '10.99.0.20/24' >/dev/null")
            edge_1.fail("ip addr show eth1 | grep '10.99.0.2/24' >/dev/null")
            edge_1.succeed("ip addr show virbr0 | grep '10.30.0.1/24' >/dev/null")
            edge_1.succeed("ip addr show eth4.10 | grep '10.10.10.1/24' >/dev/null")
            edge_1.succeed("ifstatecli --config /tmp/netif-live.yaml check")
            edge_1.succeed("ifstatecli --config /etc/ifstate/ifstate.yaml apply")
            edge_1.succeed("ip addr show eth1 | grep '10.99.0.2/24' >/dev/null")
            edge_1.succeed("ifstatecli --config /etc/ifstate/ifstate.yaml check")
            print("NETIF_IFSTATE_LIVE_OK")
        print("NETIF_OK")
    except Exception:
        for command in [
            "ip -br addr >&2",
            "ip -d link >&2",
            "ip rule >&2; ip route show table all >&2",
            "journalctl -u ifstate.service --no-pager -l | tail -n 120 >&2",
        ]:
            edge_1.execute(command)
        raise
  '';
}
