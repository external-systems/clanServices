{
  inputs,
  lib,
  self,
  ...
}: let
  module = lib.modules.importApply ./default.nix {clanLib = inputs.clan-core.lib;};
  exportInterfaces = {
    netif = ../netif/netif-interface.nix;
    nat_gateway = ./nat-gateway-interface.nix;
    kube_cluster = ../../lib/kube-cluster/kube-cluster-interface.nix;
  };
in {
  clan = {
    modules.nat-gateway = module;
    exportInterfaces.nat_gateway = ./nat-gateway-interface.nix;
  };

  perSystem = _: {
    nix-unit.tests.nat-gateway = import ./tests/eval-tests.nix {
      inherit module lib exportInterfaces;
      clanLib = inputs.clan-core.lib;
      netifModule = self.clan.modules.netif;
    };
  };

  # The service on two gateways and four machines beside them, in two
  # suites on one topology (specs/gateway.md §5): what the translator
  # does, and what it does when something fails (§14.5 point 4).
  clanTests = lib.genAttrs' ["function" "failover"] (phases:
    lib.nameValuePair (
      if phases == "function"
      then "nat-gateway"
      else "nat-gateway-${phases}"
    ) {
      imports = [(import ./tests/vm/default.nix {inherit phases;})];
      clan = {
        modules = {
          nat-gateway = module;
          inherit (self.clan.modules) netif;
        };
        inherit exportInterfaces;
      };
    });
}
