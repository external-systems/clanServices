{
  inputs,
  lib,
  self,
  ...
}: let
  module = lib.modules.importApply ./default.nix {
    ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  };
  clanLib = inputs.clan-core.lib;
in rec {
  clan = {
    modules.routed-fabric = module;
    exportInterfaces = {
      node_transport = ../../lib/node-transport-interface.nix;
      netif = ../netif/netif-interface.nix;
      kube_cluster = ../../lib/kube-cluster/kube-cluster-interface.nix;
      routed_fabric = ./routed-fabric-interface.nix;
    };
  };

  perSystem = _: {
    nix-unit.tests.routed-fabric = import ./tests/eval-tests.nix {
      inherit
        clanLib
        inputs
        lib
        module
        self
        ;
      inherit (clan) exportInterfaces;
    };
  };

  clanTests = {
    routed-fabric = {
      imports = [./tests/vm/default.nix];
      inherit clan;
    };
    # R7: external transit ends on its owner (SPEC.md D63, round 60)
    routed-fabric-transit = {
      imports = [./tests/vm/transit.nix];
      inherit clan;
    };
    # D73: a hostile actor against the guard and the link contracts
    hostile-fabric = {
      imports = [./tests/vm/hostile.nix];
      inherit clan;
    };
    routed-fabric-netif = {
      imports = [./tests/vm/netif.nix];
      clan = clan // {modules = clan.modules // {inherit (self.clan.modules) netif;};};
    };
  };
}
