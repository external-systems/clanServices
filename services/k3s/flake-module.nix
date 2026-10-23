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
    modules.k3s = module;
    exportInterfaces.node_transport = ../wireguard-mesh/node-transport-interface.nix;
  };

  perSystem = _: {
    nix-unit.tests.k3s = import ./tests/eval-tests.nix {
      inherit lib clanLib module;
      inherit (clan) exportInterfaces;
    };
    clan.nixosTests = {
      k3s-single = {
        imports = [ ./tests/vm/single.nix ];
        inherit clan;
      };
      k3s-join = {
        imports = [ ./tests/vm/join.nix ];
        inherit clan;
      };
      k3s-ha = {
        imports = [ ./tests/vm/ha.nix ];
        inherit clan;
      };
      k3s-data-plane = {
        imports = [ (import ./tests/vm/data-plane.nix { inherit inputs; }) ];
        inherit clan;
      };
    };
  };
}
