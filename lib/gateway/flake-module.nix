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
  netif = lib.modules.importApply ../../services/netif/default.nix {
    ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  };
in {
  clanTests = {
    probe-nat64.imports = [./tests/probes/nat64.nix];
    probe-router = {
      imports = [./tests/probes/router.nix];
      clan.modules.netif = netif;
    };
  };
}
