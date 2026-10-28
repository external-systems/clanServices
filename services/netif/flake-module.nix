{ inputs, lib, ... }:
let
  module = lib.modules.importApply ./default.nix {
    ifstateOverlay = import ../../lib/ifstate-overlay.nix;
  };
  clanLib = inputs.clan-core.lib;
in
rec {
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
    clan.nixosTests = {
      netif = {
        imports = [ ./tests/vm/default.nix ];
        inherit clan;
      };
      netif-dhcp = {
        imports = [ ./tests/vm/dhcp.nix ];
        inherit clan;
      };
    };
  };
}
