{
  lib,
  inputs,
  nodes,
  ...
}: let
  addresses = lib.mapAttrs (_: node: {
    inherit (node.clan.networkFacts.mesh.mesh) ipv4 ipv6;
  }) (lib.getAttrs ["alpha" "beta" "gamma"] nodes);
in {
  name = "wireguard-mesh";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        alpha = {};
        beta = {};
        gamma = {};
      };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = {
            alpha.settings.host = "alpha";
            beta.settings.host = "beta";
            gamma.settings.host = "gamma";
          };
        };

        mesh = {
          module.name = "wireguard-mesh";
          module.input = "self";
          roles.peer = {
            settings.endpointSources = [
              {
                service = "clan-core/internet";
                instance = "underlay";
              }
            ];
            machines = {
              alpha = {};
              beta = {};
              gamma = {};
            };
          };
        };
      };
    };
  };

  nodes = lib.genAttrs ["alpha" "beta" "gamma"] (name: {
    imports = [
      (import ../../../../tests/ifstate-vm.nix {
        ifstateOverlay = inputs.pkgs.overlays.ifstate;
        addresses = [
          "192.168.1.${
            toString
            {
              alpha = 1;
              beta = 2;
              gamma = 3;
            }
              .${
              name
            }
          }/24"
        ];
      })
    ];
  });

  testScript = ''
    import json

    machines = [alpha, beta, gamma]
    addresses = ${builtins.toJSON addresses}


    def fail_dump(machine):
        for command in [
            "ip -br addr",
            "ip route show",
            "ip -6 route show",
            "wg show wg-mesh",
            "systemctl status ifstate.service --no-pager -l | tail -30",
            "journalctl -u ifstate.service --no-pager | tail -60",
        ]:
            machine.execute(command + " >&2")


    try:
        start_all()
        print("ALLOCATIONS " + json.dumps(addresses, sort_keys=True))

        for machine in machines:
            machine.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep -q '^success$'", timeout=120)
            machine.wait_until_succeeds("ip link show wg-mesh", timeout=60)
            allocated = addresses[machine.name]
            ipv4, ipv6 = allocated["ipv4"], allocated["ipv6"]
            machine.succeed(f"ip -br addr show wg-mesh | grep -F '{ipv4}/32'")
            machine.succeed(f"ip -br addr show wg-mesh | grep -F '{ipv6}/128'")
            peers = machine.succeed("wg show wg-mesh peers").strip().splitlines()
            assert len(peers) == 2, f"{machine.name} has {len(peers)} peers instead of 2"
        print("WIREGUARD_MESH_ALLOCATED_OK")

        for source in machines:
            for target in machines:
                if source.name == target.name:
                    continue
                allocated = addresses[target.name]
                ipv4, ipv6 = allocated["ipv4"], allocated["ipv6"]
                source.wait_until_succeeds(f"ping -c2 -W2 {ipv4}", timeout=120)
                source.wait_until_succeeds(f"ping -6 -c2 -W2 {ipv6}", timeout=120)

        for machine in machines:
            handshakes = machine.succeed("wg show wg-mesh latest-handshakes").strip().splitlines()
            assert len(handshakes) == 2, f"{machine.name} has incomplete handshake state: {handshakes}"
            assert all(int(line.split()[-1]) > 0 for line in handshakes), (
                f"{machine.name} has a zero handshake: {handshakes}"
            )

        alpha.succeed("getent ahosts beta.mesh | grep -Eq '^${addresses.beta.ipv4}( |$)'")
        alpha.succeed("getent ahosts beta.mesh | grep -Eq '^${addresses.beta.ipv6}( |$)'")
        alpha.wait_until_succeeds("ping -c2 -W2 beta.mesh", timeout=60)

        for machine in machines:
            code, _ = machine.execute("systemctl list-unit-files | grep -Eq '^(k3s|rke2)'")
            assert code != 0, f"{machine.name} unexpectedly contains a Kubernetes service"
        print("WIREGUARD_MESH_OK")
    except Exception:
        for machine in machines:
            fail_dump(machine)
        raise
  '';
}
