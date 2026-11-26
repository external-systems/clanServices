# The build-time FRR config check (lib/frr-check.nix, SPEC.md D72)
# checks itself: every block the routed-fabric renderer writes passes
# `vtysh --dryrun` against the pinned FRR, and a line FRR rejects fails
# the build. A FRR bump that drops a command the renderer emits fails
# here, not on a deploy.
{lib, ...}: {
  perSystem = {pkgs, ...}: let
    frr = import ../lib/kube-cluster/frr.nix {inherit lib;};
    check = import ../lib/frr-conf-check.nix {inherit pkgs;};
    routes = {
      hosts = ["192.0.2.2/32" "2001:db8::2/128"];
      vips = ["198.51.100.0/24" "2001:db8:100::/64"];
      pods = [
        {
          cidr = "10.42.0.0/16";
          mask = 24;
        }
        {
          cidr = "fd42::/56";
          mask = 64;
        }
      ];
      services = ["10.43.0.0/16" "fd43::/112"];
      extra = ["203.0.113.0/24" "2001:db8:ff::/48"];
    };
    noRoutes = {
      hosts = [];
      vips = [];
      pods = [];
      services = [];
      extra = [];
    };
    adjacency = key: timerProfile: index: {
      inherit key timerProfile;
      remote = {
        ipv4 = "192.0.2.${toString index}";
        ipv6 = "2001:db8::${toString index}";
      };
      remoteAsn = 4200000000 + index;
      nextHopSelf = timerProfile == "site";
      maximumPaths = 8;
      import = routes;
      export = noRoutes;
    };
    sourceAddresses = {
      ipv4 = "192.0.2.1";
      ipv6 = "2001:db8::1";
    };
    # A spine with a site and a WAN adjacency, a border with upstreams in
    # both families, and a Cilium peer: every renderer branch.
    rendered = pkgs.writeText "frr.conf" (frr.mkConfig {
      routerId = sourceAddresses.ipv4;
      inherit sourceAddresses;
      localAsn = 4200000001;
      adjacencies = [
        (adjacency "spine-a:leaf-a" "site" 2)
        (adjacency "spine-a:spine-b" "wan" 3)
      ];
      networks = ["192.0.2.1/32" "2001:db8::1/128"];
      maximumPaths = 16;
      border = {
        ownedPrefixes = ["198.51.100.0/24" "2001:db8:100::/48"];
        upstreamPeers = [
          {
            address = "203.0.113.1";
            asn = 64496;
            acceptedPrefixes = ["0.0.0.0/0" "192.0.2.0/24 le 28"];
            ttlSecurity = true;
          }
          {
            address = "2001:db8:ffff::1";
            asn = 64496;
          }
        ];
      };
      extraConfig = frr.mkCilium {
        localAsn = 4200000001;
        inherit sourceAddresses routes;
        cluster = {
          name = "alpha";
          bgp.ciliumAsn = 4200001000;
        };
      };
    });
    broken = pkgs.writeText "frr.conf" ''
      router bgp 65001
       neighbor 192.0.2.2 remote-as external
      this-is-not-an-frr-command
    '';
    refused = pkgs.testers.testBuildFailure (check {
      name = "frr-conf-check-broken";
      conf = broken;
    });
  in {
    checks.frr-conf = pkgs.runCommand "frr-conf" {} ''
      # the renderer's output passes
      test -e ${check {conf = rendered;}}
      # a line FRR rejects fails the build and names the line
      grep -F 'this-is-not-an-frr-command' ${refused}/testBuildFailure.log >/dev/null
      test "$(cat ${refused}/testBuildFailure.exit)" = 1
      touch $out
    '';
  };
}
