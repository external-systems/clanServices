# netif-vmhost (specs/netif.md N23, N37; phase P7). A VM host's bridges:
#
#   host br0 (member nic2, found by MAC; guest ports) ── vlan 2 ── peer
#   host br1 (member: VLAN 100 on eth3)               ── vlan 3 ── peer (VLAN 100)
#   host br2 (no member, explicit MAC)
#
# Guests are simulated: a veth into a named namespace, a tap device and
# dummy links, attached to the bridges by hand the way a hypervisor does.
_: let
  noopHelper = import ../../../../tests/ifstate-noop.nix;
  # QEMU's deterministic MAC for VLAN 2 on node 1 (host).
  hostMac = "52:54:00:12:02:01";
  explicitMac = "02:00:00:00:00:22";
in {
  name = "netif-vmhost";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        host = {};
        peer = {};
      };
      instances = {
        lan = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.host.settings.links.uplink = {
            interface = "eth1";
            static.ipv4 = ["192.168.1.1/24"];
          };
        };
        guests = {
          module.name = "netif";
          module.input = "self";
          # the guest segments never carry the host's default route (N21)
          roles.default.settings.defaultRoute.ipv6 = false;
          roles.default.machines = {
            host.settings.links = {
              nic2.match.mac = hostMac;
              br0 = {
                bridge = {
                  members = ["nic2"];
                  guestPorts = true;
                };
                static.ipv4 = ["192.168.2.1/24"];
              };
              trunk.interface = "eth3";
              v100.vlan = {
                id = 100;
                parent = "trunk";
              };
              br1 = {
                bridge.members = ["v100"];
                static.ipv4 = ["192.168.3.1/24"];
              };
              br2 = {
                kind = "bridge";
                mac = explicitMac;
              };
            };
            peer.settings.links = {
              p2 = {
                interface = "eth1";
                static.ipv4 = ["192.168.2.2/24"];
              };
              ptrunk.interface = "eth2";
              pv100 = {
                vlan = {
                  id = 100;
                  parent = "ptrunk";
                };
                static.ipv4 = ["192.168.3.2/24"];
              };
            };
          };
        };
      };
    };
  };

  nodes = {
    host = {pkgs, ...}: {
      virtualisation = {
        cores = 1;
        memorySize = 1536;
        vlans = [
          1
          2
          3
        ];
      };
      environment.systemPackages = [
        pkgs.jq
        pkgs.ethtool
      ];
      clanServices.networking.owners = {
        # what libvirtd or Incus switches on: ^tap, ^vnet
        vm.enable = true;
        # a guest in a named namespace is owned like any other (N8)
        guests.netns = ["^guest"];
      };
    };
    peer.virtualisation = {
      cores = 1;
      memorySize = 1024;
      vlans = [
        2
        3
      ];
    };
  };

  testScript = ''
    import json

    ${noopHelper}

    GUEST_FILE = "/run/netif/guest-ports.yaml"

    def link(name):
        return json.loads(host.succeed(f"ip -d -j link show '{name}'"))[0]

    def guest(name, port, address):
        """A guest the way a hypervisor makes one: a namespace and a port on br0."""
        host.succeed(
            f"ip netns add {name} && ip link add {port} type veth peer name eth0 netns {name} && "
            f"ip link set {port} master br0 up && ip -n {name} addr add {address}/24 dev eth0 && "
            f"ip -n {name} link set eth0 up && ip -n {name} link set lo up"
        )

    def reapply(times=1):
        for _ in range(times):
            # this suite restarts faster than systemd's start limit allows
            host.succeed("systemctl reset-failed ifstate.service; systemctl restart ifstate.service")

    try:
        start_all()
        host.wait_for_unit("multi-user.target", timeout=180)
        peer.wait_for_unit("multi-user.target", timeout=180)
        host.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)

        with subtest("a bridge over one NIC found by MAC takes that NIC's MAC (N23)"):
            assert link("br0")["address"] == "${hostMac}", link("br0")
            assert host.succeed("ethtool -P nic2").split()[-1] == "${hostMac}"
            assert link("nic2")["master"] == "br0"
            peer.wait_until_succeeds("ping -c2 -W2 192.168.2.1", timeout=60)
            peer.succeed("ip neigh show 192.168.2.1 | grep '${hostMac}' >/dev/null")
            reapply()
            assert link("br0")["address"] == "${hostMac}"
            print("NETIF_VMHOST_MAC_OK")

        with subtest("an explicit MAC on a bridge (N23)"):
            assert link("br2")["address"] == "${explicitMac}", link("br2")

        with subtest("a bridge over a VLAN carries traffic (N23)"):
            assert link("eth3.100")["master"] == "br1"
            peer.wait_until_succeeds("ping -c2 -W2 192.168.3.1", timeout=60)
            print("NETIF_VMHOST_VLAN_OK")

        with subtest("no guest yet: the include exists and matches nothing"):
            host.succeed("grep -- \"- !include '/run/netif/guest-ports.yaml'\" /etc/ifstate/ifstate.yaml >/dev/null")
            assert host.succeed(f"cat {GUEST_FILE}").strip() == '"^$"'
            assert_ifstate_noop(host)

        with subtest("guest ports on a guest-ports bridge survive reapplies (N23)"):
            guest("guest1", "gp0", "192.168.2.50")
            # a tap device, as libvirt makes them, and a port with a dot in its name
            host.succeed("ip tuntap add dev tap0 mode tap && ip link set tap0 master br0 up")
            host.succeed("ip link add gx.1 type dummy && ip link set gx.1 master br0 up")
            # a name with a regex character: escaped, not a broken regex (N-A12)
            host.succeed("ip link add 'gp(1' type dummy && ip link set 'gp(1' master br0 up")
            peer.wait_until_succeeds("ping -c1 -W2 192.168.2.50", timeout=30)
            reapply(2)
            listed = host.succeed(f"cat {GUEST_FILE}").strip()
            print("guest ports regex:", listed)
            # the file is a YAML double-quoted string: the regex's \. is written \\.
            assert "gp0" in listed and "tap0" in listed and "gx\\\\.1" in listed and "gp\\\\(1" in listed and "nic2" not in listed, listed
            for port in ["gp0", "tap0", "gx.1", "gp(1"]:
                assert link(port)["master"] == "br0", link(port)
            assert "UP" in link("gp0")["flags"]
            host.succeed("ip netns list | grep '^guest1' >/dev/null")
            peer.succeed("ping -c2 -W2 192.168.2.50")
            assert_ifstate_noop(host)
            peer.succeed("ping -c2 -W2 192.168.2.50")
            print("NETIF_VMHOST_GUEST_PORTS_OK")

        with subtest("a port on a bridge without guestPorts is removed"):
            host.succeed("ip link add stray0 type dummy && ip link set stray0 master br1 up")
            reapply()
            host.fail("ip link show stray0")
            # the guest bridge was not touched by that
            assert link("gp0")["master"] == "br0"
            print("NETIF_VMHOST_PLAIN_BRIDGE_OK")

        with subtest("a guest that left: the next apply shrinks the list"):
            host.succeed("ip link del gp0 && ip netns del guest1")
            reapply()
            listed = host.succeed(f"cat {GUEST_FILE}").strip()
            assert "gp0" not in listed and "tap0" in listed, listed
            host.succeed("ip link del tap0 && ip link del gx.1 && ip link del 'gp(1'")
            reapply()
            assert host.succeed(f"cat {GUEST_FILE}").strip() == '"^$"'
            print("NETIF_VMHOST_SHRINK_OK")

        with subtest("a guest port that disappears during an apply fails the unit loudly (N37)"):
            host.succeed("ip link add zz0 type dummy && ip link set zz0 master br0 up")
            # remove the port the moment the pre-apply step has listed it
            host.succeed("(until grep -s zz0 /run/netif/guest-ports.list >/dev/null; do sleep 0.02; done; ip link del zz0) >/dev/null 2>&1 &")
            host.succeed("systemctl reset-failed ifstate.service")
            host.fail("systemctl restart ifstate.service")
            host.succeed("journalctl -b -u ifstate.service --no-pager | grep 'gone or detached: zz0(br0)' >/dev/null")
            reapply()
            host.succeed("test $(systemctl show -p Result --value ifstate.service) = success")
            print("NETIF_VMHOST_CHECK_OK")

        with subtest("the tools on a VM host (N41)"):
            status = json.loads(host.succeed("netif-status --json"))
            bridge = [l for l in status["links"] if l["interface"] == "br0"][0]
            assert (bridge["kind"], bridge["state"]) == ("bridge", "UP") and "192.168.2.1/24" in bridge["addresses"], bridge
            host.succeed("netif-preview | grep 'would change nothing' >/dev/null")
            host.succeed("systemctl start netif-drift.service")
            assert_ifstate_noop(host)
            assert_ifstate_noop(peer)

        print("NETIF_VMHOST_OK")
    except Exception:
        for machine in [host, peer]:
            for command in [
                "ip -br link >&2; ip -br addr >&2; ip netns list >&2",
                "bridge link >&2",
                "cat /run/netif/guest-ports.yaml /run/netif/guest-ports.list >&2",
                "sed -n '/^parameters:/,$p' /etc/ifstate/ifstate.yaml >&2",
                "journalctl -b -u ifstate.service --no-pager | tail -n 120 >&2",
            ]:
                machine.execute(command)
        raise
  '';
}
