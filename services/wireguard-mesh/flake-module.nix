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
    modules.wireguard-mesh = module;
    exportInterfaces.node_transport = ../../lib/node-transport-interface.nix;
  };

  perSystem = _: {
    nix-unit.tests.wireguard-mesh = import ./tests/eval-tests.nix {
      inherit module clanLib lib;
      inherit (clan) exportInterfaces;
    };
  };

  clanTests.wireguard-mesh = {
    imports = [./tests/vm/default.nix];
    inherit clan;
  };
}
