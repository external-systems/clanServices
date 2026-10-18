{
  self,
  inputs,
  lib,
  ...
}:
let
  module = lib.modules.importApply ./default.nix { inherit self inputs; };
  clanLib = inputs.clan-core.lib;
in
rec {
  clan = {
    modules.rke2 = module;
    exportInterfaces.node_transport = ../wireguard-mesh/node-transport-interface.nix;
  };

  perSystem = _: {
    nix-unit.tests.rke2 = import ./tests/eval-tests.nix {
      inherit lib clanLib module;
      inherit (clan) exportInterfaces;
    };
    clan.nixosTests = {
      rke2-single = {
        imports = [ ./tests/vm/single.nix ];
        inherit clan;
      };
      rke2-join = {
        imports = [ ./tests/vm/join.nix ];
        inherit clan;
      };
      rke2-ha = {
        imports = [ ./tests/vm/ha.nix ];
        inherit clan;
      };
    };
  };
}
