# netif-match (specs/netif.md P3a). A physical link found by permanent
# MAC comes up under its logical name, whatever the kernel called it;
# a declared NIC that does not exist fails ifstate.service loudly.
# A NIC found by its udev path (N26) is renamed by udev before IfState
# runs: the way a cloud NIC is matched, whose MAC is not known up front.
_: let
  # QEMU's deterministic MAC for VLAN 1 on node 1 (the only node).
  mac = "52:54:00:12:01:01";
  # A virtio NIC in a fixed PCI slot, like a cloud provider's second NIC.
  cloudSlot = "18"; # free on q35 (1a, 1d and 1f are the chipset's)
  cloudPath = "pci-0000:00:${cloudSlot}.0";
  cloudMac = "52:54:00:aa:bb:cc";
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
      instances.private = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.edge.settings.links.cloud1 = {
          match.path = cloudPath;
          static.ipv4 = ["10.89.0.1/24"];
          defaultRoute.ipv6 = false;
          # published for tunnels, never set on the link (N17)
          pathMtu = 1460;
        };
      };
    };
  };

  nodes.edge = {
    virtualisation.qemu.options = [
      "-netdev user,id=cloud,restrict=on"
      "-device virtio-net-pci,netdev=cloud,addr=0x${cloudSlot},mac=${cloudMac}"
    ];
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
    ${import ../../../../tests/ifstate-noop.nix}
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
            assert_ifstate_noop(edge)
            print("NETIF_MATCH_MAC_OK")

        with subtest("NIC found by udev path under its logical name (N26)"):
            edge.succeed("udevadm info -q property /sys/class/net/cloud1 | grep -x 'ID_PATH=${cloudPath}' >/dev/null")
            edge.succeed("test \"$(cat /sys/class/net/cloud1/address)\" = '${cloudMac}'")
            edge.succeed("ip addr show cloud1 | grep '10.89.0.1/24' >/dev/null")
            edge.succeed("test -e /etc/systemd/network/10-netif-cloud1.link")
            # udev renamed it, not IfState: no identify in the rendered config
            edge.fail("grep -A6 '^  cloud1:' /etc/ifstate/ifstate.yaml | grep identify >/dev/null")
            edge.fail("ip link show eth2")
            edge.fail("systemctl is-active systemd-networkd.service")
            # the path MTU is a published fact; the link keeps its MTU
            edge.succeed("ip link show cloud1 | grep 'mtu 1500' >/dev/null")
            print("NETIF_MATCH_PATH_OK")

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
