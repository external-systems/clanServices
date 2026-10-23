{ lib }:
let
  # Pod/service CIDR derivation from the Cilium cluster id.
  # Multiple clusters can share one transport when their ids differ.
  cidrs = id: {
    clusterCidr = "10.${toString (id * 2 - 1)}.0.0/16,fd10:${toString (id * 2 - 1)}::/56";
    serviceCidr = "10.${toString (id * 2)}.0.0/16,fd10:${toString (id * 2)}::/112";
    clusterDNS = "10.${toString (id * 2)}.0.10";
  };

  clusterInterface = import ./cluster-interface.nix;
  nodeInterface = import ./node-interface.nix;

  cilium = import ./cilium.nix { inherit lib cidrs; };
  assertFns = import ./assertions.nix { inherit lib; };
  bundle = import ./bundle.nix { inherit lib; };
  bootstrap = import ./bootstrap.nix { };
  haproxy = import ./haproxy.nix { inherit lib; };
  nixos = import ./nixos.nix { inherit lib; };
  vars = import ./vars.nix { inherit lib; };

  # §6.11 manifest labels: on every clan-rendered object, never in
  # selectors. bundle.nix adds clan.lol/config-hash per object at the end
  # of the render.
  mkManifestLabels =
    {
      instanceName,
      component ? "bootstrap",
    }:
    {
      "app.kubernetes.io/managed-by" = "clan";
      "clan.lol/kube-cluster" = "core-component";
      "clan.lol/cluster" = instanceName;
      "clan.lol/component" = component;
    };

  # Resolve the full pool set for a cluster (D8): the auto per-machine
  # node-named pools (join-address /32+/128 + declared poolBlocks, always
  # node-fate-bound) plus the declared cluster-global pools.
  # members: [ { machineName, ipv4, ipv6, poolBlocks } ].
  # Returns an attrset: pool name -> { blocks, serviceSelector }.
  resolvePools =
    { settings, members }:
    lib.listToAttrs (
      map (m: {
        name = m.machineName;
        value = {
          blocks = [
            "${m.ipv4}/32"
            "${m.ipv6}/128"
          ]
          ++ m.poolBlocks;
          serviceSelector."clan.lol/pool" = m.machineName;
        };
      }) members
    )
    // lib.mapAttrs (_: p: { inherit (p) blocks serviceSelector; }) settings.pools;
in
rec {
  inherit cidrs;

  interfaces = {
    cluster = clusterInterface;
    node = nodeInterface;
  };

  render = {
    inherit (cilium) mkCiliumValues resolveCidrs;
    inherit (bundle)
      mkBundle
      mkLBService
      mkCoreDNSResources
      validateBundle
      unsupportedHelmValues
      ;
    inherit (haproxy) mkHaproxyConfig;
    inherit mkManifestLabels resolvePools;
  };

  assertions = {
    inherit (assertFns) mkClusterAssertions mkPoolAssertions;
  };

  # Bootstrap-apply oneshot fragment (D40).
  inherit (bootstrap) mkBootstrapApply;

  # Vars generators (bare generator attrsets — the distro service merges
  # them into clan.core.vars.generators, gated by role as documented in
  # vars.nix).
  inherit vars;

  # NixOS fragment builders (PKI sync).
  inherit nixos;
}
