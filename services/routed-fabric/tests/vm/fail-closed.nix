# routed-fabric-fail-closed: a member that boots without its guard
# table (design-routed-fabric §3.10, I14; SPEC.md D75). A unit deletes
# the leaf's guard table right after nftables.service loaded it, which
# stands in for a load that failed. FRR must not run, the kernel must
# hold no BGP route, a fabric address must answer "No route to host"
# (the unreachable aggregates), and FRR must start by itself once the
# table loads, also after the unit's start-limit window.
#
#   hub   spine      leaf  leaf on hub, boots without its guard
{
  lib,
  inputs,
  nodes,
  ...
}: let
  fleet = name: nodes.${name}.clan.networkFacts.fabric.fleet;
  members = {
    hub = "192.168.1.1";
    leaf = "192.168.1.2";
  };
  stable = lib.mapAttrs (name: _: {inherit (fleet name) ipv4 ipv6;}) members;
in {
  name = "routed-fabric-fail-closed";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = lib.mapAttrs (_: _: {}) members;

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = lib.mapAttrs (_: host: {settings = {inherit host;};}) members;
        };

        fleet = {
          module.name = "routed-fabric";
          module.input = "self";
          roles = {
            spine.settings = {
              site = "lab";
              endpointSources = [
                {
                  service = "clan-core/internet";
                  instance = "underlay";
                }
              ];
            };
            leaf.settings.site = "lab";
            spine.machines.hub = {};
            leaf.machines.leaf = {};
          };
        };
      };
    };
  };

  nodes =
    lib.mapAttrs
    (name: address: {
      lib,
      pkgs,
      ...
    }: {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
          addresses = ["${address}/24"];
        })
      ];
      # the guard is gone before FRR starts, as after a failed load
      systemd.services.drop-guard = lib.mkIf (name == "leaf") {
        wantedBy = ["multi-user.target"];
        after = ["nftables.service"];
        before = ["frr.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.nftables}/bin/nft delete table inet routed-fabric-fleet";
        };
      };
      virtualisation = {
        cores = 1;
        memorySize = 1536;
      };
    })
    members;

  testScript = ''
    stable = ${builtins.toJSON stable}

    ${import ../../../../tests/suite-lib.nix}

    start_all()
    hub.wait_for_unit("frr.service", timeout=180)
    leaf.wait_for_unit("drop-guard.service", timeout=180)
    leaf.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=180)

    with state_dump_on_failure([hub, leaf]):
        with subtest("boot without the guard: FRR does not run, no BGP route, no session"):
            leaf.succeed("sleep 30")
            guard = leaf.execute("nft list table inet routed-fabric-fleet >/dev/null 2>&1")[0] == 0
            state = leaf.execute("systemctl is-active frr")[1].strip()
            daemons = leaf.succeed("pgrep -c -x 'bgpd|zebra|bfdd' || true").strip()
            routes = leaf.succeed("ip route show proto bgp | wc -l; ip -6 route show proto bgp | wc -l").split()
            sessions = hub.succeed("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' || true").strip()
            links = leaf.succeed("wg show interfaces").split()
            print(f"leaf 30 s after boot: guard table present={guard}; frr is {state}; routing daemons {daemons}; kernel BGP routes v4/v6 {routes}; hub sessions {sessions}; WireGuard links {len(links)}")
            # the WireGuard link is up: only the missing guard keeps FRR down
            assert links, "the leaf has no WireGuard link, so the subtest proves nothing"
            assert not guard, "the guard table is present"
            assert state != "active" and daemons == "0", f"FRR runs without the guard: {state}, {daemons} daemons"
            assert routes == ["0", "0"], f"kernel BGP routes without the guard: {routes}"
            assert sessions == "0", f"the hub has {sessions} sessions with a leaf that has no guard"

        with subtest("the unreachable aggregates answer a fabric address at once"):
            unreachable = leaf.succeed("ip route show type unreachable; ip -6 route show type unreachable")
            print("unreachable routes on leaf: " + " | ".join(unreachable.splitlines()))
            assert len(unreachable.splitlines()) >= 3, unreachable
            for address in (stable["hub"]["ipv4"], stable["hub"]["ipv6"]):
                code, out = leaf.execute(f"ping -c 1 -W 1 {address} 2>&1")
                print(f"ping {address}: rc={code} {out.strip()}")
                assert code != 0 and ("unreachable" in out.lower() or "no route" in out.lower()), out

        with subtest("FRR keeps waiting past the start-limit window (200 s)"):
            leaf.succeed("sleep 200")
            state = leaf.execute("systemctl is-active frr")[1].strip()
            result = leaf.succeed("systemctl show -p Result --value frr").strip()
            restarts = leaf.succeed("systemctl show -p NRestarts --value frr").strip()
            print(f"230 s after boot: frr is {state}, Result={result}, NRestarts={restarts}")
            assert result != "start-limit-hit", "FRR hit its start limit and would never come back"
            assert state in ("activating", "failed", "inactive"), state

        with subtest("the guard loads: FRR starts by itself and the fabric comes up"):
            leaf.succeed("systemctl reload nftables")
            leaf.succeed("nft list table inet routed-fabric-fleet >/dev/null")
            recovered = seconds_until(leaf, "systemctl is-active frr | grep '^active$'", limit=180)
            print(f"frr active {recovered} s after the guard loaded")
            assert recovered is not None, "FRR did not start after the guard loaded"
            hub.wait_until_succeeds("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^2$' >/dev/null", timeout=240)
            leaf.wait_until_succeeds(f"ping -c 2 -W 2 {stable['hub']['ipv4']}", timeout=120)
            leaf.wait_until_succeeds(f"ping -6 -c 2 -W 2 {stable['hub']['ipv6']}", timeout=120)

    print("ROUTED_FABRIC_FAIL_CLOSED_OK")
  '';
}
