{ lib, ... }:
let
  fabric = import ../../../../lib/kube-cluster/fabric.nix { inherit lib; };
  hubTransfer = (fabric.transferAddresses "fleet" "beta" "hub-a").localSecond;
in
{
  name = "routed-fabric";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        hub-a = { };
        alpha = { };
        beta = { };
        gamma = { };
      };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = {
            hub-a.settings.host = "hub-a";
            alpha.settings.host = "alpha";
            beta.settings.host = "beta";
            gamma.settings.host = "gamma";
          };
        };

        fleet = {
          module.name = "routed-fabric";
          module.input = "self";
          roles = {
            hub.machines.hub-a.settings = {
              ipv4 = "192.168.77.1";
              ipv6 = "fd77::1";
              endpointSources = [
                {
                  service = "clan-core/internet";
                  instance = "underlay";
                }
              ];
            };
            member.machines = {
              alpha.settings = {
                ipv4 = "192.168.77.2";
                ipv6 = "fd77::2";
                hubs = [ "hub-a" ];
              };
              beta.settings = {
                ipv4 = "192.168.77.3";
                ipv6 = "fd77::3";
                hubs = [ "hub-a" ];
              };
              gamma.settings = {
                ipv4 = "192.168.77.4";
                ipv6 = "fd77::4";
                hubs = [ "hub-a" ];
              };
            };
          };
        };
      };
    };
  };

  nodes =
    let
      resources = {
        virtualisation = {
          cores = 1;
          memorySize = 1536;
        };
      };
    in
    {
      hub-a = resources;
      alpha = resources;
      beta = resources;
      gamma = resources;
    };

  testScript = ''
    machines = [hub_a, alpha, beta, gamma]
    stable = {
        "hub-a": ("192.168.77.1", "fd77::1"),
        "alpha": ("192.168.77.2", "fd77::2"),
        "beta": ("192.168.77.3", "fd77::3"),
        "gamma": ("192.168.77.4", "fd77::4"),
    }


    def dump(machine):
        for command in [
            "ip -br addr >&2",
            "ip route >&2; ip -6 route >&2",
            "ip rule >&2",
            "ip route get 192.168.77.3 from 192.168.77.2 >&2 || true",
            "ip -6 route get fd77::3 from fd77::2 >&2 || true",
            "sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding >&2",
            "nft list ruleset >&2",
            "wg show >&2",
            "vtysh -c 'show bgp summary' >&2",
            "vtysh -c 'show bfd peers brief' >&2",
            "vtysh -c 'show ip route' >&2; vtysh -c 'show ipv6 route' >&2",
            "journalctl -u frr --no-pager -l | tail -n 100 >&2",
            "journalctl -u systemd-networkd --no-pager -l | tail -n 80 >&2",
        ]:
            machine.execute(command)


    try:
        start_all()
        for machine in machines:
            machine.wait_for_unit("systemd-networkd.service", timeout=120)
            machine.wait_for_unit("frr.service", timeout=180)
            machine.wait_until_succeeds("wg show interfaces | grep -q '^rf'", timeout=120)
            machine.fail("ip route show | grep '^default' | grep -q 'rf'")
            machine.fail("ip -6 route show | grep '^default' | grep -q 'rf'")

        for member in [alpha, beta, gamma]:
            member.wait_until_succeeds("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep -q '^2$'", timeout=240)
            member.wait_until_succeeds("vtysh -c 'show bfd peers brief' | grep -c ' up ' | grep -q '^2$'", timeout=240)

        hub_a.wait_until_succeeds("wg show interfaces | wc -w | grep -q '^3$'", timeout=60)
        hub_a.wait_until_succeeds("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep -q '^6$'", timeout=240)
        hub_a.wait_until_succeeds("vtysh -c 'show bfd peers brief' | grep -c ' up ' | grep -q '^6$'", timeout=240)

        for source in machines:
            for target in machines:
                if source.name == target.name:
                    continue
                ipv4, ipv6 = stable[target.name]
                source.wait_until_succeeds(f"ping -c 2 -W 2 {ipv4}", timeout=120)
                source.wait_until_succeeds(f"ping -6 -c 2 -W 2 {ipv6}", timeout=120)

        for machine in machines:
            handshakes = machine.succeed("wg show all latest-handshakes").strip().splitlines()
            assert handshakes and all(int(line.split()[-1]) > 0 for line in handshakes), handshakes
            machine.succeed("ip link show | grep -q 'mtu 1404'")
            machine.fail("vtysh -c 'show ip route' | grep -q 'r>'")
            machine.fail("vtysh -c 'show ipv6 route' | grep -q 'r>'")

        beta.succeed("ip route show 192.168.77.2 | grep -q 'via ${hubTransfer.ipv4}'")
        beta.succeed("ip route show 192.168.77.2 | grep -q 'src 192.168.77.3'")
        beta.succeed("ip -6 route show fd77::2 | grep -Eq 'via fe80::.* dev rf'")
        beta.succeed("ip -6 route show fd77::2 | grep -q 'src fd77::3'")
        beta.wait_until_succeeds("ping -M do -c 1 -W 2 -s 1376 192.168.77.1", timeout=60)
        beta.fail("ping -M do -c 1 -W 2 -s 1377 192.168.77.1")
        beta.wait_until_succeeds("ping -M do -c 1 -W 2 -s 1356 fd77::1", timeout=60)
        beta.fail("ping -M do -c 1 -W 2 -s 1357 fd77::1")
        print("ROUTED_FABRIC_TRANSPORT_OK")
    except Exception:
        for machine in machines:
            try:
                dump(machine)
            except Exception:
                pass
        raise
  '';
}
