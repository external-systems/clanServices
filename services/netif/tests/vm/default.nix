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
              # with a policy table the gateway is that table's default
              gateway.ipv4 = "10.99.0.1";
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
          # uplink accepts RAs; this segment never carries the IPv6 default (N21)
          roles.default.settings.defaultRoute.ipv6 = false;
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
              # the machine's main-table default (N18: metric 100)
              gateway.ipv4 = "10.10.10.254";
            };
          };
        };
      };
    };
  };

  nodes.edge-1 = {
    lib,
    pkgs,
    ...
  }: {
    environment.systemPackages = [
      pkgs.yq
      pkgs.jq
    ];
    # A second generation to switch to: another address on the uplink and
    # another metric. Switching must apply it live and switching back
    # must restore the first state.
    specialisation.moved.configuration = {
      clanServices.netif.routeMetric = 150;
      networking.ifstate.settings.interfaces.eth1.addresses = lib.mkForce [
        "10.99.0.30/24"
        "fd00:99::2/64"
      ];
    };
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
    import json

    ${import ../../../../tests/ifstate-noop.nix}
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
            assert_ifstate_noop(edge_1)
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
            assert_ifstate_noop(edge_1)
            print("NETIF_IFSTATE_LIVE_OK")
        with subtest("a generation switch reconfigures the links live (U2)"):
            def main_default():
                routes = json.loads(edge_1.succeed("ip -j -4 route show default"))
                return [(r["gateway"], r["dev"], r["metric"]) for r in routes]

            assert main_default() == [("10.10.10.254", "eth4.10", 100)], main_default()
            table = json.loads(edge_1.succeed("ip -j -4 route show table 300"))
            assert [(r["dst"], r["gateway"], r["dev"]) for r in table] == [("default", "10.99.0.1", "eth1")], table
            assert edge_1.succeed("cat /proc/sys/net/ipv6/conf/eth1/ra_defrtr_metric").strip() == "100"
            assert edge_1.succeed("cat /proc/sys/net/ipv6/conf/eth4.10/ra_defrtr_metric").strip() == "100"
            assert edge_1.succeed("cat /proc/sys/net/ipv6/conf/eth4.10/accept_ra_defrtr").strip() == "0"
            assert edge_1.succeed("cat /proc/sys/net/ipv6/conf/eth1/accept_ra_defrtr").strip() == "1"
            boot_id = edge_1.succeed("cat /proc/sys/kernel/random/boot_id")
            bond_index = edge_1.succeed("cat /sys/class/net/agg0/ifindex")

            edge_1.succeed("/run/booted-system/specialisation/moved/bin/switch-to-configuration test >&2")
            edge_1.wait_until_succeeds("ip addr show eth1 | grep '10.99.0.30/24' >/dev/null", timeout=60)
            edge_1.fail("ip addr show eth1 | grep '10.99.0.2/24' >/dev/null")
            edge_1.wait_until_succeeds("ip -4 route show default | grep 'metric 150' >/dev/null", timeout=30)
            assert main_default() == [("10.10.10.254", "eth4.10", 150)], main_default()
            assert edge_1.succeed("cat /proc/sys/net/ipv6/conf/eth1/ra_defrtr_metric").strip() == "150"
            # untouched links were not recreated, and nothing rebooted
            assert edge_1.succeed("cat /sys/class/net/agg0/ifindex") == bond_index
            assert edge_1.succeed("cat /proc/sys/kernel/random/boot_id") == boot_id
            assert_ifstate_noop(edge_1)

            edge_1.succeed("/run/booted-system/bin/switch-to-configuration test >&2")
            edge_1.wait_until_succeeds("ip addr show eth1 | grep '10.99.0.2/24' >/dev/null", timeout=60)
            edge_1.fail("ip addr show eth1 | grep '10.99.0.30/24' >/dev/null")
            assert main_default() == [("10.10.10.254", "eth4.10", 100)], main_default()
            assert_ifstate_noop(edge_1)
            print("NETIF_SWITCH_OK")
        with subtest("operator tools: status, preview and the drift watch (N38, N41, N42)"):
            status = json.loads(edge_1.succeed("netif-status --json"))
            uplink = [l for l in status["links"] if l["interface"] == "eth1"][0]
            assert (uplink["instance"], uplink["link"], uplink["state"], uplink["trusted"]) == ("lan", "uplink", "UP", False), uplink
            assert "10.99.0.2/24" in uplink["addresses"], uplink
            assert status["ifstate"]["result"] == "success", status
            assert status["defaultRoutes"]["ipv4"][0]["metric"] == 100, status
            table = edge_1.succeed("netif-status")
            print(table)
            assert "dmz/dmz10" in table and "eth4.10" in table and "untrusted" in table, table

            edge_1.succeed("netif-preview | grep 'would change nothing' >/dev/null")
            # another built system: the preview names what it would change
            preview = edge_1.execute("netif-preview /run/booted-system/specialisation/moved")
            assert preview[0] == 2 and "would change:" in preview[1], preview
            edge_1.succeed("ip addr show eth1 | grep '10.99.0.2/24' >/dev/null")

            edge_1.succeed("systemctl list-timers --all | grep netif-drift.timer >/dev/null")
            edge_1.succeed("systemctl start netif-drift.service")
            assert json.loads(edge_1.succeed("netif-status --json"))["drift"] == "none"
            # someone else changes the network: the watch fails and changes nothing
            edge_1.succeed("ip addr add 10.99.0.99/24 dev eth1")
            edge_1.fail("systemctl start netif-drift.service")
            edge_1.succeed("journalctl -u netif-drift.service --no-pager | grep 'the network differs from the configuration' >/dev/null")
            edge_1.succeed("ip addr show eth1 | grep '10.99.0.99/24' >/dev/null")
            assert json.loads(edge_1.succeed("netif-status --json"))["drift"] == "DRIFT"
            edge_1.succeed("systemctl restart ifstate.service")
            edge_1.fail("ip addr show eth1 | grep '10.99.0.99/24' >/dev/null")
            edge_1.succeed("systemctl start netif-drift.service")
            assert_ifstate_noop(edge_1)
            print("NETIF_TOOLS_OK")
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
