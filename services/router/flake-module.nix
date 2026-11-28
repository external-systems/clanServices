{
  inputs,
  lib,
  self,
  ...
}: let
  module = lib.modules.importApply ./default.nix {clanLib = inputs.clan-core.lib;};
in {
  clan = {
    modules.router = module;
    exportInterfaces.router = ./router-interface.nix;
  };

  perSystem = _: {
    nix-unit.tests.router = import ./tests/eval-tests.nix {
      inherit module lib;
      clanLib = inputs.clan-core.lib;
      netifModule = self.clan.modules.netif;
      exportInterfaces = {
        netif = ../netif/netif-interface.nix;
        router = ./router-interface.nix;
      };
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
      exportInterfaces = {
        netif = ../netif/netif-interface.nix;
        router = ./router-interface.nix;
      };
    };
  };

  clanTests.hostile-router = {
    imports = [./tests/vm/hostile.nix];
    clan = {
      modules = {
        router = module;
        inherit (self.clan.modules) netif;
      };
      exportInterfaces = {
        netif = ../netif/netif-interface.nix;
        router = ./router-interface.nix;
      };
    };
  };
}
