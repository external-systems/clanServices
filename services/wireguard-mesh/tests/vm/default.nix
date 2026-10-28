{ lib, ... }:
{
  name = "wireguard-mesh";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        alpha = { };
        beta = { };
        gamma = { };
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
              alpha.settings = {
                ipv4 = "192.168.77.1";
                ipv6 = "fd00:77::1";
              };
              beta.settings = {
                ipv4 = "192.168.77.2";
                ipv6 = "fd00:77::2";
              };
              gamma.settings = {
                ipv4 = "192.168.77.3";
                ipv6 = "fd00:77::3";
              };
            };
          };
        };
      };
    };
  };

  nodes = lib.genAttrs [ "alpha" "beta" "gamma" ] (name: {
    imports = [
      (import ../../../../tests/ifstate-vm.nix {
        ifstateOverlay = import ../../../../lib/ifstate-overlay.nix;
        addresses = [
          "192.168.1.${
            toString
              {
                alpha = 1;
                beta = 2;
                gamma = 3;
              }
              .${name}
          }/24"
        ];
      })
    ];
  });

  testScript = ''
    machines = [alpha, beta, gamma]
    addresses = {
        "alpha": ("192.168.77.1", "fd00:77::1"),
        "beta": ("192.168.77.2", "fd00:77::2"),
        "gamma": ("192.168.77.3", "fd00:77::3"),
    }


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

        for machine in machines:
            machine.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep -q '^success$'", timeout=120)
            machine.wait_until_succeeds("ip link show wg-mesh", timeout=60)
            ipv4, ipv6 = addresses[machine.name]
            machine.succeed(f"ip -br addr show wg-mesh | grep -q '{ipv4}/32'")
            machine.succeed(f"ip -br addr show wg-mesh | grep -q '{ipv6}/128'")
            peers = machine.succeed("wg show wg-mesh peers").strip().splitlines()
            assert len(peers) == 2, f"{machine.name} has {len(peers)} peers instead of 2"

        for source in machines:
            for target in machines:
                if source.name == target.name:
                    continue
                ipv4, ipv6 = addresses[target.name]
                source.wait_until_succeeds(f"ping -c2 -W2 {ipv4}", timeout=120)
                source.wait_until_succeeds(f"ping -6 -c2 -W2 {ipv6}", timeout=120)

        for machine in machines:
            handshakes = machine.succeed("wg show wg-mesh latest-handshakes").strip().splitlines()
            assert len(handshakes) == 2, f"{machine.name} has incomplete handshake state: {handshakes}"
            assert all(int(line.split()[-1]) > 0 for line in handshakes), (
                f"{machine.name} has a zero handshake: {handshakes}"
            )

        alpha.succeed("getent ahosts beta.mesh | grep -q '192.168.77.2'")
        alpha.succeed("getent ahosts beta.mesh | grep -q 'fd00:77::2'")
        alpha.wait_until_succeeds("ping -c2 -W2 beta.mesh", timeout=60)

        for machine in machines:
            code, _ = machine.execute("systemctl list-unit-files | grep -Eq '^(k3s|rke2)'")
            assert code != 0, f"{machine.name} unexpectedly contains a Kubernetes service"
    except Exception:
        for machine in machines:
            fail_dump(machine)
        raise
  '';
}
