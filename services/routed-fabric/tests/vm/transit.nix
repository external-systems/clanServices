# External transit (SPEC.md D63, round 60, R7): an externalTransit
# adjacency has one owner end (border.ownedPrefixes). Outside traffic
# crosses that one link and ends on the owner; replies go back over it
# by sourceReturn; the fabric's own traffic still crosses the link.
#
#   isp    client 192.0.2.50, not a member; the owned /24 via cloud
#    | underlay
#   cloud  spine, the upstream end; routes the owned /24 into the link
#    | rf (externalTransit)
#   home   spine, the owner: 198.51.100.0/24, 198.51.100.1 on its loopback
#    | rf
#   far    leaf on home only; 198.51.100.20 (owned, but past the owner)
{
  lib,
  inputs,
  nodes,
  ...
}: let
  fleet = name: nodes.${name}.clan.networkFacts.fabric.fleet;
  adj = name: remote: (fleet name).adjacencies.${remote};
  stable = lib.mapAttrs (name: _: {inherit (fleet name) ipv4 ipv6;}) {
    cloud = null;
    home = null;
    far = null;
  };
  inherit (fleet "home") loopback;
  public = "198.51.100.1";
  past = "198.51.100.20";
  client = "192.0.2.50";
in {
  name = "routed-fabric-transit";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        isp = {};
        cloud = {};
        home = {};
        far = {};
      };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = {
            cloud.settings.host = "192.168.1.2";
            home.settings.host = "192.168.1.3";
            far.settings.host = "192.168.1.4";
          };
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
            spine.machines = {
              cloud = {};
              home.settings = {
                border = {
                  ownedPrefixes = [
                    "198.51.100.0/24"
                    "2001:db8:100::/64"
                  ];
                  upstreamPeers = [
                    {
                      address = "192.168.1.254";
                      asn = 64500;
                    }
                  ];
                };
                adjacencies.cloud = {
                  externalTransit = true;
                  sourceReturn = true;
                };
              };
            };
            leaf.machines.far.settings.spines = ["home"];
          };
        };
      };
    };
  };

  nodes =
    lib.mapAttrs
    (_name: address: {pkgs, ...}: {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
          addresses = ["${address}/24"];
          # every member's main default is the ISP on the underlay
          routes = [
            {
              to = "0.0.0.0/0";
              via = "192.168.1.254";
            }
          ];
        })
      ];
      environment.systemPackages = [pkgs.tcpdump];
      virtualisation = {
        cores = 1;
        memorySize = 1536;
      };
    })
    {
      cloud = "192.168.1.2";
      home = "192.168.1.3";
      far = "192.168.1.4";
    }
    // {
      isp = {pkgs, ...}: {
        imports = [
          (import ../../../../tests/ifstate-vm.nix {
            ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
            addresses = ["192.168.1.254/24"];
            withBase = true;
            routes = [
              {
                to = "198.51.100.0/24";
                via = "192.168.1.2";
              }
            ];
          })
        ];
        networking.firewall.enable = false;
        environment.systemPackages = [pkgs.tcpdump];
        virtualisation = {
          cores = 1;
          memorySize = 1024;
        };
      };
    };

  testScript = ''
    fabric = [cloud, home, far]
    stable = ${builtins.toJSON stable}
    home_cloud = "${(adj "home" "cloud").interface}"
    home_far = "${(adj "home" "far").interface}"
    cloud_home = "${(adj "cloud" "home").interface}"
    far_home = "${(adj "far" "home").interface}"
    home_on_cloud_link = "${(adj "home" "cloud").ipv4}"
    far_on_home_link = "${(adj "far" "home").ipv4}"
    public, past, client = "${public}", "${past}", "${client}"


    def counter(machine, comment):
        rules = machine.succeed("nft list chain inet routed-fabric-fleet forward")
        lines = [l for l in rules.splitlines() if comment in l]
        assert lines, rules
        return sum(int(l.split("counter packets ")[1].split()[0]) for l in lines)


    def capture(taps):
        for machine, iface, direction in taps:
            unit = f"cap-{iface}-{direction}"
            machine.succeed(f"rm -f /tmp/{unit}")
            machine.succeed(f"systemd-run --unit={unit} $(command -v tcpdump) -pUni {iface} -Q {direction} -w /tmp/{unit} 'icmp and host {client}'")
        for machine, iface, direction in taps:
            machine.wait_until_succeeds(f"test -s /tmp/cap-{iface}-{direction}", timeout=20)


    def seen(machine, iface, direction, kind):
        unit = f"cap-{iface}-{direction}"
        machine.execute(f"systemctl stop {unit}")
        return machine.succeed(f"tcpdump -nr /tmp/{unit} 2>/dev/null || true").count(kind)


    try:
        start_all()
        isp.wait_for_unit("multi-user.target")
        isp.succeed(f"ip addr add {client}/32 dev lo")

        with subtest("fabric up; the transit guard is on the owner only"):
            for machine in fabric:
                machine.wait_for_unit("frr.service", timeout=180)
            for machine, sessions in [(cloud, 2), (home, 4), (far, 2)]:
                machine.wait_until_succeeds(
                    f"vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^{sessions}$' >/dev/null",
                    timeout=240,
                )
            rules = home.succeed("nft list chain inet routed-fabric-fleet forward")
            assert "externalTransit: to ownedPrefixes only" in rules and "externalTransit: ends on this border" in rules, rules
            cloud.fail("nft list ruleset | grep externalTransit >/dev/null")
            # the operator's route on the upstream end: the owned prefix into the link
            cloud.succeed(f"ip route replace 198.51.100.0/24 via {home_on_cloud_link} dev {cloud_home}")
            home.succeed(f"ip addr add {public}/32 dev ${loopback}")
            far.succeed(f"ip addr add {past}/32 dev lo")
            home.succeed(f"ip route replace {past}/32 via {far_on_home_link} dev {home_far}")

        # R7: before, the upstream end's guard (empty owned sets) dropped
        # everything the link forwarded
        with subtest("the fabric's own traffic crosses the transit link both ways"):
            for source, target in [(far, "cloud"), (cloud, "far"), (cloud, "home"), (home, "cloud")]:
                source.wait_until_succeeds(f"ping -c 2 -W 2 {stable[target]['ipv4']}", timeout=120)
                source.wait_until_succeeds(f"ping -6 -c 2 -W 2 {stable[target]['ipv6']}", timeout=120)

        with subtest("an outside client reaches the owner, and the reply returns over the link"):
            taps = [(home, home_cloud, "in"), (home, home_cloud, "out"), (home, "eth1", "out")]
            capture(taps)
            isp.succeed(f"ping -c 3 -W 2 -I {client} {public}")
            requests_in = seen(home, home_cloud, "in", "echo request")
            replies_out = seen(home, home_cloud, "out", "echo reply")
            underlay_replies = seen(home, "eth1", "out", "echo reply")
            print(f"home: requests in {requests_in}, replies over the link {replies_out}, replies on the underlay {underlay_replies}")
            # every request the link brought in is answered over the link
            assert requests_in >= 1 and replies_out == requests_in and underlay_replies == 0
            print("ROUTED_FABRIC_TRANSIT_OWNER_OK")

        with subtest("outside traffic ends on the owner: an owned address past it is dropped and counted"):
            before = counter(home, "externalTransit: ends on this border")
            capture([(far, far_home, "in")])
            isp.fail(f"ping -c 3 -W 1 -I {client} {past}")
            assert seen(far, far_home, "in", "echo request") == 0
            after = counter(home, "externalTransit: ends on this border")
            assert after >= before + 3, (before, after)
            print("ROUTED_FABRIC_TRANSIT_ENDS_OK")

        with subtest("outside traffic to an address the owner does not own is dropped and counted"):
            before = counter(home, "externalTransit: to ownedPrefixes only")
            isp.succeed(f"ip route add {stable['far']['ipv4']}/32 via 192.168.1.2")
            cloud.succeed(f"ip route get {stable['far']['ipv4']} | grep {cloud_home} >/dev/null")
            isp.fail(f"ping -c 3 -W 1 -I {client} {stable['far']['ipv4']}")
            after = counter(home, "externalTransit: to ownedPrefixes only")
            assert after >= before + 3, (before, after)

        print("ROUTED_FABRIC_TRANSIT_OK")
    except Exception:
        for machine in fabric:
            machine.execute("nft list ruleset >&2; ip rule >&2; ip route >&2; wg show >&2; vtysh -c 'show ip route' >&2")
        raise
  '';
}
