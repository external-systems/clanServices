{ inputs, lib, ... }:
let
  module = ./default.nix;
  clanLib = inputs.clan-core.lib;
in
rec {
  clan = {
    modules.wireguard-mesh = module;
    exportInterfaces.node_transport = ./node-transport-interface.nix;
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
