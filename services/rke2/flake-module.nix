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
    exportInterfaces = {
      # D58: the NEUTRAL node_transport schemaVersion 2 seam, shared by
      # every transport provider (routed-fabric, wireguard-mesh, and any
      # third-party overlay). rke2 consumes ONLY this export.
      node_transport = ../../lib/node-transport-interface.nix;
      kube_cluster = ../../lib/kube-cluster/kube-cluster-interface.nix;
    };
  };

  perSystem = _: {
    nix-unit.tests.rke2 = import ./tests/eval-tests.nix {
      inherit
        lib
        clanLib
        module
        self
        inputs
        ;
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
      rke2-data-plane = {
        imports = [ (import ./tests/vm/data-plane.nix { inherit inputs; }) ];
        inherit clan;
      };
      rke2-clustermesh = {
        imports = [ ./tests/vm/clustermesh.nix ];
        inherit clan;
      };
      rke2-clustermesh-tunnel = {
        imports = [ ./tests/vm/clustermesh-tunnel.nix ];
        inherit clan;
      };
      rke2-clustermesh-external = {
        imports = [ ./tests/vm/clustermesh-external.nix ];
        inherit clan;
      };
      rke2-clustermesh-external-native = {
        imports = [ ./tests/vm/clustermesh-external-native.nix ];
        inherit clan;
      };
      rke2-clustermesh-selective = {
        imports = [ ./tests/vm/clustermesh-selective.nix ];
        inherit clan;
      };
      rke2-clustermesh-selective-tunnel = {
        imports = [ ./tests/vm/clustermesh-selective-tunnel.nix ];
        inherit clan;
      };
    };
  };
}
