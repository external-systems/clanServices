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
      # D58: the NEUTRAL node_transport schemaVersion 2 seam, shared by
      # every transport provider (routed-fabric, wireguard-mesh, and any
      # third-party overlay). k3s consumes ONLY this export.
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
    k3s-ha-fabric = {
      imports = [./tests/vm/ha-fabric.nix];
      inherit clan;
    };
    k3s-data-plane = {
      imports = [(import ./tests/vm/data-plane.nix {inherit inputs;})];
      inherit clan;
    };
    k3s-data-plane-tunnel = {
      imports = [(import ./tests/vm/data-plane-tunnel.nix {inherit inputs;})];
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
    # The same contract with the cluster on the routed fabric (native routing).
    k3s-modes-fabric = {
      imports = [./tests/vm/modes-fabric.nix];
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
    k3s-clustermesh-tunnel = {
      imports = [./tests/vm/clustermesh-tunnel.nix];
      inherit clan;
    };
    k3s-clustermesh-external = {
      imports = [./tests/vm/clustermesh-external.nix];
      inherit clan;
    };
    k3s-clustermesh-external-native = {
      imports = [./tests/vm/clustermesh-external-native.nix];
      inherit clan;
    };
    k3s-clustermesh-selective = {
      imports = [./tests/vm/clustermesh-selective.nix];
      inherit clan;
    };
    k3s-clustermesh-selective-tunnel = {
      imports = [./tests/vm/clustermesh-selective-tunnel.nix];
      inherit clan;
    };
  };
}
