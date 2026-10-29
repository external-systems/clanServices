{
  inputs,
  lib,
  self,
  ...
}: let
  module = lib.modules.importApply ./default.nix {
    ifstateOverlay = inputs.pkgs.overlays.ifstate;
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
    clan.nixosTests.routed-fabric = {
      imports = [./tests/vm/default.nix];
      inherit clan;
    };
  };
}
