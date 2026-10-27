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
    exportInterfaces = {
      # D58: the NEUTRAL node_transport schemaVersion 2 seam, shared by
      # every transport provider (routed-fabric, wireguard-mesh, and any
      # third-party overlay). k3s consumes ONLY this export.
      node_transport = ../../lib/node-transport-interface.nix;
      kube_cluster = ../../lib/kube-cluster/kube-cluster-interface.nix;
    };
  };

  perSystem = _: {
    nix-unit.tests.k3s = import ./tests/eval-tests.nix {
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
      k3s-clustermesh = {
        imports = [ ./tests/vm/clustermesh.nix ];
        inherit clan;
      };
      k3s-clustermesh-tunnel = {
        imports = [ ./tests/vm/clustermesh-tunnel.nix ];
        inherit clan;
      };
      k3s-clustermesh-external = {
        imports = [ ./tests/vm/clustermesh-external.nix ];
        inherit clan;
      };
      k3s-clustermesh-external-native = {
        imports = [ ./tests/vm/clustermesh-external-native.nix ];
        inherit clan;
      };
      k3s-clustermesh-selective = {
        imports = [ ./tests/vm/clustermesh-selective.nix ];
        inherit clan;
      };
      k3s-clustermesh-selective-tunnel = {
        imports = [ ./tests/vm/clustermesh-selective-tunnel.nix ];
        inherit clan;
      };
    };
  };
}
