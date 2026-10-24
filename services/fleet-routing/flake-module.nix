{
  self,
  inputs,
  lib,
  ...
}:
let
  module = ./default.nix;
  clanLib = inputs.clan-core.lib;
in
rec {
  clan = {
    modules.fleet-routing = module;
    exportInterfaces = {
      node_transport = ../wireguard-mesh/node-transport-interface.nix;
      kube_cluster = ../../lib/kube-cluster/kube-cluster-interface.nix;
      fleet_routing = ./fleet-routing-interface.nix;
    };
  };

  perSystem = _: {
    nix-unit.tests.fleet-routing = import ./tests/eval-tests.nix {
      inherit
        lib
        clanLib
        module
        self
        inputs
        ;
      inherit (clan) exportInterfaces;
    };
    clan.nixosTests.fleet-routing = {
      imports = [ (import ./tests/vm/fleet-routing.nix { inherit self inputs; }) ];
      inherit clan;
    };
  };
}
