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
  clanTests = let
    clan = {
      modules = {
        modes = module;
        inherit (self.clan.modules) netif;
      };
      # the schema file itself, as every other suite registers it
      exportInterfaces.netif = ../netif/netif-interface.nix;
    };
  in {
    netif-modes = {
      imports = [./tests/vm/default.nix];
      inherit clan;
    };
    # netif-desktop: a KDE machine in a NetworkManager and an IfState mode (N14).
    netif-desktop = {
      imports = [./tests/vm/desktop.nix];
      inherit clan;
    };
  };

  perSystem = _: {
    nix-unit.tests.modes = import ./tests/eval-tests.nix {
      inherit module lib;
      clanLib = inputs.clan-core.lib;
      netifModule = self.clan.modules.netif;
      exportInterfaces.netif = ../netif/netif-interface.nix;
    };
  };
}
