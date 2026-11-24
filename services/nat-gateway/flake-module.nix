{
  inputs,
  lib,
  self,
  ...
}: let
  module = lib.modules.importApply ./default.nix {clanLib = inputs.clan-core.lib;};
  exportInterfaces = {
    netif = ../netif/netif-interface.nix;
    nat_gateway = ./nat-gateway-interface.nix;
    kube_cluster = ../../lib/kube-cluster/kube-cluster-interface.nix;
  };
in {
  clan = {
    modules.nat-gateway = module;
    exportInterfaces.nat_gateway = ./nat-gateway-interface.nix;
  };

  perSystem = _: {
    nix-unit.tests.nat-gateway = import ./tests/eval-tests.nix {
      inherit module lib exportInterfaces;
      clanLib = inputs.clan-core.lib;
      netifModule = self.clan.modules.netif;
    };
  };

  # The service on two gateways and a client, ported from the fixture
  # suite gateway-nat64 (specs/gateway.md §5, §14.1 point 1).
  clanTests.nat-gateway = {
    imports = [./tests/vm/default.nix];
    clan = {
      modules = {
        nat-gateway = module;
        inherit (self.clan.modules) netif;
      };
      inherit exportInterfaces;
    };
  };
}
