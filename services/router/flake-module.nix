{
  inputs,
  lib,
  self,
  ...
}: let
  module = ./default.nix;
in {
  clan.modules.router = module;

  perSystem = _: {
    nix-unit.tests.router = import ./tests/eval-tests.nix {
      inherit module lib;
      clanLib = inputs.clan-core.lib;
      netifModule = self.clan.modules.netif;
      exportInterfaces.netif = ../netif/netif-interface.nix;
    };
  };

  # The service on the router of gateway-router: the same proofs on the
  # code a machine runs (specs/gateway.md §5, §14.1 point 1).
  clanTests.router = {
    imports = [./tests/vm/default.nix];
    clan = {
      modules = {
        router = module;
        inherit (self.clan.modules) netif;
      };
      exportInterfaces.netif = ../netif/netif-interface.nix;
    };
  };
}
