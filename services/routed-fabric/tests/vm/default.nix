{ lib, ... }:
{
  name = "routed-fabric";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        spine-a = { };
        spine-b = { };
        alpha = { };
        beta = { };
        gamma = { };
      };

      instances = {
        underlay = {
          module.name = "internet";
          # Literal VM-LAN addresses: single-label hostnames race LLMNR
          # against the fabric loopback bring-up in the hermetic test (a
          # spine's WG endpoint can resolve to the peer's fabric address
          # and blackhole); IPs keep the underlay resolution-free.
          roles.default.machines = {
            spine-a.settings.host = "192.168.1.4";
            spine-b.settings.host = "192.168.1.5";
            alpha.settings.host = "192.168.1.1";
            beta.settings.host = "192.168.1.2";
            gamma.settings.host = "192.168.1.3";
          };
        };

        # D59: two spines with an automatically derived spine<->spine
        # pair; alpha/beta attach every spine by default; gamma is an
        # explicit single-homed leaf proving spine<->spine readvertisement.
        fleet = {
          module.name = "routed-fabric";
          module.input = "self";
          roles = {
            spine.machines = {
              spine-a.settings = {
                ipv4 = "192.168.77.1";
                ipv6 = "fd77::1";
                endpointSources = [
                  {
                    service = "clan-core/internet";
                    instance = "underlay";
                  }
                ];
              };
              spine-b.settings = {
                ipv4 = "192.168.77.2";
                ipv6 = "fd77::2";
                endpointSources = [
                  {
                    service = "clan-core/internet";
                    instance = "underlay";
                  }
                ];
              };
            };
            leaf.machines = {
              alpha.settings = {
                ipv4 = "192.168.77.3";
                ipv6 = "fd77::3";
              };
              beta.settings = {
                ipv4 = "192.168.77.4";
                ipv6 = "fd77::4";
              };
              gamma.settings = {
                ipv4 = "192.168.77.5";
                ipv6 = "fd77::5";
                spines = [ "spine-a" ];
              };
            };
          };
        };
      };
    };
  };

  nodes =
    lib.mapAttrs
      (name: address: { pkgs, ... }: {
        environment.systemPackages = [ pkgs.tcpdump ];
        imports = [
          (import ../../../../tests/ifstate-vm.nix {
            ifstateOverlay = import ../../../../lib/ifstate-overlay.nix;
            addresses = [ "${address}/24" ];
          })
        ];
        virtualisation = {
          cores = 1;
          memorySize = 1536;
        };
      })
      {
        spine-a = "192.168.1.4";
        spine-b = "192.168.1.5";
        alpha = "192.168.1.1";
        beta = "192.168.1.2";
        gamma = "192.168.1.3";
      };

  testScript = ''
    machines = [spine_a, spine_b, alpha, beta, gamma]
    stable = {
        "spine-a": ("192.168.77.1", "fd77::1"),
        "spine-b": ("192.168.77.2", "fd77::2"),
        "alpha": ("192.168.77.3", "fd77::3"),
        "beta": ("192.168.77.4", "fd77::4"),
        "gamma": ("192.168.77.5", "fd77::5"),
    }
    # One WireGuard interface per derived adjacency, two BGP sessions
    # (v4 + v6 transfer neighbors) and two BFD peers per adjacency.
    adjacency_counts = {
        "spine-a": 4,  # spine-b + alpha + beta + gamma
        "spine-b": 3,  # spine-a + alpha + beta
        "alpha": 2,
        "beta": 2,
        "gamma": 1,  # explicit single-homed leaf
    }


    def dump(machine):
        for command in [
            "ip -br addr >&2",
            "ip route >&2; ip -6 route >&2",
            "ip rule >&2",
            "ip route get 192.168.77.3 from 192.168.77.4 >&2 || true",
            "ip -6 route get fd77::3 from fd77::4 >&2 || true",
            "ip route get 192.168.77.5 from 192.168.77.2 >&2 || true",
            "ip route get 192.168.77.2 from 192.168.77.5 >&2 || true",
            "ifstatecli check >&2 || true",
            "cat /tmp/ping.cap >&2 || true",
            "sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding >&2",
            "nft list ruleset >&2",
            "wg show >&2",
            "vtysh -c 'show bgp summary' >&2",
            "vtysh -c 'show bfd peers brief' >&2",
            "vtysh -c 'show ip route' >&2; vtysh -c 'show ipv6 route' >&2",
            "journalctl -u frr --no-pager -l | tail -n 100 >&2",
            "journalctl -u ifstate.service --no-pager -l | tail -n 80 >&2",
        ]:
            machine.execute(command)


    def rib(machine, path):
        machine.succeed(
            "vtysh -c 'show ip route' | sed -E 's/, (XX|[0-9]{2,}):[0-9]{2}:[0-9]{2}$//' > %s" % path
        )


    try:
        start_all()
        for machine in machines:
            machine.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep -q '^success$'", timeout=120)
            machine.wait_for_unit("frr.service", timeout=180)
            expected = adjacency_counts[machine.name]
            machine.wait_until_succeeds(
                f"test \"$(wg show interfaces | wc -w)\" -eq {expected}", timeout=120
            )
            machine.fail("ip route show | grep '^default' | grep -q 'rf'")
            machine.fail("ip -6 route show | grep '^default' | grep -q 'rf'")

        for machine in machines:
            expected = adjacency_counts[machine.name]
            sessions = 2 * expected
            machine.wait_until_succeeds(
                f"vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep -q '^{sessions}$'",
                timeout=240,
            )
            machine.wait_until_succeeds(
                f"vtysh -c 'show bfd peers brief' | grep -c ' up ' | grep -q '^{sessions}$'",
                timeout=240,
            )

        for machine in [spine_b, spine_a, gamma]:
            machine.execute("tcpdump -ni any 'host 192.168.77.2 or host 192.168.77.5' > /tmp/ping.cap 2>&1 &")
        for source in machines:
            for target in machines:
                if source.name == target.name:
                    continue
                ipv4, ipv6 = stable[target.name]
                source.wait_until_succeeds(f"ping -c 2 -W 2 {ipv4}", timeout=120)
                source.wait_until_succeeds(f"ping -6 -c 2 -W 2 {ipv6}", timeout=120)
        for machine in [spine_b, spine_a, gamma]:
            machine.execute("pkill tcpdump || true")

        for machine in machines:
            handshakes = machine.succeed("wg show all latest-handshakes").strip().splitlines()
            assert handshakes and all(int(line.split()[-1]) > 0 for line in handshakes), handshakes
            machine.succeed("ip link show | grep -q 'mtu 1404'")
            machine.fail("vtysh -c 'show ip route' | grep -q 'r>'")
            machine.fail("vtysh -c 'show ipv6 route' | grep -q 'r>'")

        # Leaf ECMP: beta reaches alpha through both spines.
        beta.succeed("ip route show 192.168.77.3 | grep -q 'via 100.110.157.53'")
        beta.succeed("ip route show 192.168.77.3 | grep -q 'via 100.166.181.145'")
        beta.succeed("ip route show 192.168.77.3 | grep -q 'src 192.168.77.4'")
        beta.succeed("ip -6 route show fd77::3 | grep -Eq 'via fe80::.* dev rf'")
        beta.succeed("ip -6 route show fd77::3 | grep -q 'src fd77::4'")
        # Spine<->spine readvertisement with next-hop-self: spine-b reaches
        # the single-homed gamma only through spine-a.
        spine_b.succeed("ip route show 192.168.77.5 | grep -q 'via 100.64.231.32'")
        spine_a.succeed("ip route show 192.168.77.5 | grep -q 'via 100.65.139.74'")
        beta.wait_until_succeeds("ping -M do -c 1 -W 2 -s 1376 192.168.77.1", timeout=60)
        beta.fail("ping -M do -c 1 -W 2 -s 1377 192.168.77.1")
        beta.wait_until_succeeds("ping -M do -c 1 -W 2 -s 1356 fd77::1", timeout=60)
        beta.fail("ping -M do -c 1 -W 2 -s 1357 fd77::1")
        print("ROUTED_FABRIC_TRANSPORT_OK")

        # Spine HA: FRR reload/restart keep the RIB/FIB stable across a
        # single-spine failure and recovery.
        rib(beta, "/tmp/rib.before")
        beta.succeed("ip route show > /tmp/fib.before")

        # Reload is daemon-preserving (FRR 10.7 probe, SPEC.md D19): the
        # local RIB must not move.
        rib(spine_a, "/tmp/rib.spine-a.before")
        spine_a.succeed("systemctl reload frr")
        rib(spine_a, "/tmp/rib.spine-a.after")
        spine_a.succeed("diff -u /tmp/rib.spine-a.before /tmp/rib.spine-a.after")

        # Fail spine-b; dual-homed leaves lose one ECMP leg and converge on
        # spine-a, and traffic to/from the single-homed leaf keeps flowing.
        spine_b.succeed("systemctl stop frr")
        beta.wait_until_succeeds(
            "test \"$(ip route show 192.168.77.3 | grep -c 'via ')\" -eq 1", timeout=120
        )
        beta.succeed("ip route show 192.168.77.3 | grep -q 'via 100.110.157.53'")
        alpha.succeed("ip route show 192.168.77.5 | grep -q 'via 100.185.127.95'")
        for source in [alpha, beta, gamma]:
            for target in [alpha, beta, gamma]:
                if source.name == target.name:
                    continue
                ipv4, ipv6 = stable[target.name]
                source.wait_until_succeeds(f"ping -c 2 -W 2 {ipv4}", timeout=120)
                source.wait_until_succeeds(f"ping -6 -c 2 -W 2 {ipv6}", timeout=120)
        spine_a.wait_until_succeeds(
            "vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep -q '^6$'",
            timeout=120,
        )

        # Recover spine-b; then a full restart must re-converge to the
        # exact pre-failure RIB/FIB.
        spine_b.succeed("systemctl start frr")
        beta.wait_until_succeeds(
            "test \"$(ip route show 192.168.77.3 | grep -c 'via ')\" -eq 2", timeout=240
        )
        spine_b.wait_until_succeeds(
            "vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep -q '^6$'",
            timeout=240,
        )
        spine_b.succeed("systemctl restart frr")
        spine_b.wait_until_succeeds(
            "vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep -q '^6$'",
            timeout=240,
        )
        beta.wait_until_succeeds(
            "test \"$(ip route show 192.168.77.3 | grep -c 'via ')\" -eq 2", timeout=240
        )
        rib(beta, "/tmp/rib.after")
        beta.succeed("ip route show > /tmp/fib.after")
        beta.succeed("diff -u /tmp/rib.before /tmp/rib.after")
        beta.succeed("diff -u /tmp/fib.before /tmp/fib.after")
        print("ROUTED_FABRIC_SPINE_HA_OK")
    except Exception:
        for machine in machines:
            try:
                dump(machine)
            except Exception:
                pass
        raise
  '';
}
