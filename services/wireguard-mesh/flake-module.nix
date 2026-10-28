{ inputs, lib, ... }:
let
  module = lib.modules.importApply ./default.nix {
    ifstateOverlay = import ../../lib/ifstate-overlay.nix;
  };
  clanLib = inputs.clan-core.lib;
in
rec {
  clan = {
    modules.wireguard-mesh = module;
    exportInterfaces.node_transport = ../../lib/node-transport-interface.nix;
  };

  perSystem = _: {
    nix-unit.tests.wireguard-mesh = import ./tests/eval-tests.nix {
      inherit module clanLib lib;
      inherit (clan) exportInterfaces;
    };
    clan.nixosTests.wireguard-mesh = {
      imports = [ ./tests/vm/default.nix ];
      inherit clan;
    };
  };
}
