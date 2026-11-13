{
  inputs,
  lib,
  ...
}: let
  module = lib.modules.importApply ./default.nix {
    ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  };
  clanLib = inputs.clan-core.lib;
in rec {
  clan = {
    modules.netif = module;
    exportInterfaces.netif = ./netif-interface.nix;
  };

  perSystem = _: {
    nix-unit.tests.netif = import ./tests/eval-tests.nix {
      inherit
        module
        clanLib
        lib
        ;
      inherit (clan) exportInterfaces;
    };
  };

  clanTests = {
    netif = {
      imports = [./tests/vm/default.nix];
      inherit clan;
    };
    netif-dhcp = {
      imports = [./tests/vm/dhcp.nix];
      inherit clan;
    };
  };
}
