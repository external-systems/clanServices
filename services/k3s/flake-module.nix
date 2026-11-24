{
  self,
  inputs,
  lib,
  ...
}: let
  module = lib.modules.importApply ./default.nix {inherit inputs;};
  clanLib = inputs.clan-core.lib;
in rec {
  clan = {
    modules.k3s = module;
    exportInterfaces = {
      # D58/D72: the NEUTRAL node_transport schemaVersion 2 seam that a
      # native transport provider (routed-fabric, or any third-party
      # router) exports. k3s consumes ONLY this export.
      node_transport = ../../lib/node-transport-interface.nix;
      kube_cluster = ../../lib/kube-cluster/kube-cluster-interface.nix;
    };
  };

  perSystem = _: {
    nix-unit.tests.k3s = import ./tests/eval-tests.nix {
      inherit
        lib
        clanLib
        module
        self
        inputs
        ;
      inherit (clan) exportInterfaces;
    };
  };

  clanTests = {
    k3s-single = {
      imports = [./tests/vm/single.nix];
      inherit clan;
    };
    k3s-join = {
      imports = [./tests/vm/join.nix];
      inherit clan;
    };
    # The join suite on an underlay that netif renders (specs/netif.md N14).
    k3s-join-netif = {
      imports = [./tests/vm/join-netif.nix];
      clan =
        clan
        // {
          modules = clan.modules // {inherit (self.clan.modules) netif;};
          exportInterfaces = clan.exportInterfaces // {netif = ../netif/netif-interface.nix;};
        };
    };
    k3s-ha = {
      imports = [./tests/vm/ha.nix];
      inherit clan;
    };
    # FRR failure on a cluster node: bgpd crash, refused bad reload (D72).
    k3s-frr-failure = {
      imports = [./tests/vm/frr-failure.nix];
      inherit clan;
    };
    k3s-data-plane = {
      imports = [(import ./tests/vm/data-plane.nix {inherit inputs;})];
      inherit clan;
    };
    k3s-data-plane-netif = {
      imports = [(import ./tests/vm/data-plane-netif.nix {inherit inputs;})];
      clan =
        clan
        // {
          modules = clan.modules // {inherit (self.clan.modules) netif;};
          exportInterfaces = clan.exportInterfaces // {netif = ../netif/netif-interface.nix;};
        };
    };
    # A single-node cluster that exists in one mode of its machine (N4, U2).
    k3s-modes = {
      imports = [./tests/vm/modes.nix];
      clan =
        clan
        // {
          modules = clan.modules // {inherit (self.clan.modules) netif modes;};
          exportInterfaces = clan.exportInterfaces // {netif = ../netif/netif-interface.nix;};
        };
    };
    k3s-clustermesh = {
      imports = [./tests/vm/clustermesh.nix];
      inherit clan;
    };
    # ClusterMesh with node-port exposure (D60), native routing.
    k3s-clustermesh-nodeport = {
      imports = [./tests/vm/clustermesh-nodeport.nix];
      inherit clan;
    };
    k3s-clustermesh-external = {
      imports = [./tests/vm/clustermesh-external.nix];
      inherit clan;
    };
    k3s-clustermesh-selective = {
      imports = [./tests/vm/clustermesh-selective.nix];
      inherit clan;
    };
  };
}
