# lib/gateway: the private shared implementation of the router and
# nat-gateway services (specs/gateway.md G1). Today it holds only the
# probes of specs/gateway.md §6: throwaway VM tests that prove or
# disprove a design assumption before the code it gates. They register
# as `probe-*` suites so `vm-test` runs them; each is deleted when a
# real suite asserts what it showed.
{
  inputs,
  lib,
  ...
}: let
  kube = distro: {
    modules.${distro} = lib.modules.importApply (../../services + "/${distro}/default.nix") {inherit inputs;};
    exportInterfaces = {
      node_transport = ../node-transport-interface.nix;
      kube_cluster = ../kube-cluster/kube-cluster-interface.nix;
    };
  };
  v6only = distro: {
    imports = [(import ./tests/probes/v6only-join.nix {inherit lib inputs distro;})];
    clan = kube distro;
  };
  clat = distro: transport: device: {
    imports = [(import ./tests/probes/kube-clat.nix {inherit inputs distro transport device;})];
    clan = kube distro;
  };
  netif = lib.modules.importApply ../../services/netif/default.nix {
    ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  };
in {
  clanTests = {
    probe-nat64.imports = [./tests/probes/nat64.nix];
    probe-k3s-v6only = v6only "k3s";
    probe-rke2-v6only = v6only "rke2";
    probe-k3s-clat-fabric = clat "k3s" "fabric" false;
    probe-k3s-clat-mesh = clat "k3s" "mesh" false;
    probe-rke2-clat-fabric = clat "rke2" "fabric" false;
    probe-rke2-clat-mesh = clat "rke2" "mesh" false;
    probe-k3s-clat-fabric-device = clat "k3s" "fabric" true;
    probe-k3s-clat-mesh-device = clat "k3s" "mesh" true;
    probe-rke2-clat-fabric-device = clat "rke2" "fabric" true;
    probe-rke2-clat-mesh-device = clat "rke2" "mesh" true;
    probe-v6only-host = {
      imports = [./tests/probes/v6only-host.nix];
      clan.modules.netif = netif;
    };
    probe-dual-wan = {
      imports = [./tests/probes/dual-wan.nix];
      clan.modules.netif = netif;
    };
    probe-wan = {
      imports = [./tests/probes/wan.nix];
      clan.modules.netif = netif;
    };
    probe-router = {
      imports = [./tests/probes/router.nix];
      clan.modules.netif = netif;
    };
  };
}
