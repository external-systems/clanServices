# lib/gateway: the private shared implementation of the router and
# nat-gateway services (specs/gateway.md G1): the modules are
# default.nix and its imports. This file registers the suites that still
# run on fixtures (the frozen DNS64 design, dual WAN, the WAN link,
# IPv6-only hosts and clusters) and the <distro>-clat suites, which run
# on the services. The services' own suites are registered in
# services/nat-gateway and services/router.
{
  inputs,
  lib,
  self,
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
    imports = [(import ./tests/vm/v6only-join.nix {inherit lib inputs distro;})];
    clan = kube distro;
  };
  # mapped = false: the decided design of specs/gateway.md G5 (the CLAT
  # link is a Cilium device). true: the documented alternative.
  clat = distro: mapped: {
    imports = [
      (import ./tests/vm/kube-clat.nix {
        inherit inputs distro mapped;
        # the decided design runs on the services (§14.1 point 1); the
        # documented alternative keeps its fixtures
        service = !mapped;
      })
    ];
    clan =
      if mapped
      then kube distro
      else {
        modules =
          (kube distro).modules
          // {
            inherit (self.clan.modules) netif nat-gateway;
          };
        exportInterfaces =
          (kube distro).exportInterfaces
          // {
            netif = ../../services/netif/netif-interface.nix;
            nat_gateway = ../../services/nat-gateway/nat-gateway-interface.nix;
          };
      };
  };
  netif = lib.modules.importApply ../../services/netif/default.nix {
    ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  };
in {
  clanTests = {
    gateway-nat64.imports = [./tests/vm/nat64.nix];
    k3s-v6only = v6only "k3s";
    rke2-v6only = v6only "rke2";
    k3s-clat = clat "k3s" false;
    rke2-clat = clat "rke2" false;
    k3s-clat-mapped = clat "k3s" true;
    netif-v6only = {
      imports = [./tests/vm/v6only-host.nix];
      clan.modules.netif = netif;
    };
    gateway-dual-wan = {
      imports = [./tests/vm/dual-wan.nix];
      clan.modules.netif = netif;
    };
    gateway-wan = {
      imports = [./tests/vm/wan.nix];
      clan.modules.netif = netif;
    };
  };
}
