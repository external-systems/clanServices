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
    modules.rke2 = module;
    exportInterfaces = {
      # D58/D72: the NEUTRAL node_transport schemaVersion 2 seam that a
      # native transport provider (routed-fabric, or any third-party
      # router) exports. rke2 consumes ONLY this export.
      node_transport = ../../lib/node-transport-interface.nix;
      kube_cluster = ../../lib/kube-cluster/kube-cluster-interface.nix;
    };
  };

  perSystem = _: {
    nix-unit.tests.rke2 = import ./tests/eval-tests.nix {
      inherit
        lib
        clanLib
        module
        inputs
        self
        ;
      inherit (clan) exportInterfaces;
    };
  };

  clanTests = {
    rke2-single = {
      imports = [./tests/vm/single.nix];
      inherit clan;
    };
    rke2-join = {
      imports = [./tests/vm/join.nix];
      inherit clan;
    };
    # Hostile actors against the cluster: an outsider on the node LAN,
    # a fabric leaf outside the cluster, a pod, a local user
    # (specs/design-kube.md §6). Every verdict has a positive control.
    rke2-hostile = {
      imports = [./tests/vm/hostile.nix];
      inherit clan;
    };
    # The join suite on an underlay that netif renders (specs/netif.md N14).
    rke2-join-netif = {
      imports = [./tests/vm/join-netif.nix];
      clan =
        clan
        // {
          modules = clan.modules // {inherit (self.clan.modules) netif;};
          exportInterfaces = clan.exportInterfaces // {netif = ../netif/netif-interface.nix;};
        };
    };
    rke2-ha = {
      imports = [./tests/vm/ha.nix];
      inherit clan;
    };
    rke2-data-plane = {
      imports = [(import ./tests/vm/data-plane.nix {inherit inputs;})];
      inherit clan;
    };
    rke2-data-plane-netif = {
      imports = [(import ./tests/vm/data-plane-netif.nix {inherit inputs;})];
      clan =
        clan
        // {
          modules = clan.modules // {inherit (self.clan.modules) netif;};
          exportInterfaces = clan.exportInterfaces // {netif = ../netif/netif-interface.nix;};
        };
    };
    rke2-clustermesh = {
      imports = [./tests/vm/clustermesh.nix];
      inherit clan;
    };
    # ClusterMesh with node-port exposure (D60), native routing.
    rke2-clustermesh-nodeport = {
      imports = [./tests/vm/clustermesh-nodeport.nix];
      inherit clan;
    };
    rke2-clustermesh-external = {
      imports = [./tests/vm/clustermesh-external.nix];
      inherit clan;
    };
    rke2-clustermesh-selective = {
      imports = [./tests/vm/clustermesh-selective.nix];
      inherit clan;
    };
  };
}
