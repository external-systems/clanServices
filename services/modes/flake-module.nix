{
  inputs,
  lib,
  self,
  ...
}: let
  module = ./default.nix;
in {
  clan.modules.modes = module;

  # netif-modes boots one machine into each of its modes (N2, N3, N24).
  clanTests.netif-modes = {
    imports = [./tests/vm/default.nix];
    clan = {
      modules = {
        modes = module;
        inherit (self.clan.modules) netif;
      };
      inherit (self.clan) exportInterfaces;
    };
  };

  perSystem = _: {
    nix-unit.tests.modes = import ./tests/eval-tests.nix {
      inherit module lib;
      clanLib = inputs.clan-core.lib;
      netifModule = self.clan.modules.netif;
      exportInterfaces = self.clan.exportInterfaces;
    };
  };
}
