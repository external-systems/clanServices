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
  coredns = import ./coredns.nix { inherit lib; };
  assertFns = import ./assertions.nix { inherit lib; };
  haproxy = import ./haproxy.nix { inherit lib; };
  nixos = import ./nixos.nix { inherit lib; };
  vars = import ./vars.nix { inherit lib; };

  mkManifestLabels = { instanceName }: {
    "app.kubernetes.io/managed-by" = "clan";
    "clan.lol/kube-cluster" = "core-component";
    "clan.lol/cluster" = instanceName;
  };
in
rec {
  inherit cidrs;

  interfaces = {
    cluster = clusterInterface;
    node = nodeInterface;
  };

  render = {
    inherit (cilium) mkCiliumValues mkCiliumManifests;
    inherit (coredns) mkCoreDNSValues mkCoreDNSManifests;
    inherit (haproxy) mkHaproxyConfig;
    inherit mkManifestLabels;
  };

  assertions = {
    inherit (assertFns) mkClusterAssertions;
  };

  # Vars generators (bare generator attrsets — the distro service merges
  # them into clan.core.vars.generators, gated by role as documented in
  # vars.nix).
  inherit vars;

  # NixOS fragment builders (PKI sync).
  inherit nixos;
}
