# netif-match (specs/netif.md P3a). A physical link found by permanent
# MAC comes up under its logical name, whatever the kernel called it;
# a declared NIC that does not exist fails ifstate.service loudly.
_: let
  # QEMU's deterministic MAC for VLAN 1 on node 1 (the only node).
  mac = "52:54:00:12:01:01";
in {
  name = "netif-match";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines.edge = {};
      instances.uplink = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.edge.settings.links.wan = {
          match.mac = mac;
          static.ipv4 = ["10.88.0.1/24"];
        };
      };
    };
  };

  nodes.edge = {
    virtualisation = {
      cores = 1;
      memorySize = 1024;
    };
    # A physical NIC that is not there: IfState 2.5.1 only warns, netif's
    # post-apply check must fail the unit.
    specialisation.missing.configuration.networking.ifstate.settings.interfaces.ghost = {
      identify.perm_address = "02:de:ad:be:ef:00";
      link = {
        kind = "physical";
        state = "up";
      };
    };
  };

  testScript = ''
    try:
        start_all()
        with subtest("NIC found by permanent MAC under its logical name"):
            # Result is "success" before a unit ever ran: wait for the exit.
            edge.wait_until_succeeds("test $(systemctl show -p ExecMainExitTimestampMonotonic --value ifstate.service) != 0", timeout=120)
            edge.succeed("test $(systemctl show -p Result --value ifstate.service) = success")
            edge.succeed("ip addr show wan | grep '10.88.0.1/24' >/dev/null")
            edge.succeed("test \"$(cat /sys/class/net/wan/address)\" = '${mac}'")
            edge.fail("ip link show eth1")
            edge.succeed("systemctl restart ifstate.service")
            edge.succeed("test $(systemctl show -p Result --value ifstate.service) = success")
            edge.succeed("ip addr show wan | grep '10.88.0.1/24' >/dev/null")
            edge.succeed("ifstatecli --config /etc/ifstate/ifstate.yaml check")
            print("NETIF_MATCH_MAC_OK")

        with subtest("a missing NIC fails ifstate.service loudly"):
            edge.execute("/run/current-system/specialisation/missing/bin/switch-to-configuration test >&2")
            edge.fail("systemctl start ifstate.service")
            edge.succeed("systemctl is-failed ifstate.service")
            edge.succeed("journalctl -b -u ifstate.service --no-pager | grep 'declared physical links missing after IfState apply: ghost' >/dev/null")
            # The rest of the configuration still applied.
            edge.succeed("ip addr show wan | grep '10.88.0.1/24' >/dev/null")
            print("NETIF_MATCH_MISSING_LOUD_OK")

        with subtest("back to the parent configuration"):
            edge.execute("/run/booted-system/bin/switch-to-configuration test >&2")
            edge.succeed("systemctl reset-failed ifstate.service")
            edge.succeed("systemctl start ifstate.service")
            edge.succeed("test $(systemctl show -p Result --value ifstate.service) = success")

        print("NETIF_MATCH_OK")
    except Exception:
        for command in [
            "ip -br link >&2; ip -br addr >&2",
            "cat /etc/ifstate/ifstate.yaml >&2",
            "journalctl -b -u ifstate.service --no-pager | tail -n 120 >&2",
        ]:
            edge.execute(command)
        raise
  '';
}
