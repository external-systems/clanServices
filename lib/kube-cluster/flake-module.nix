{
  lib,
  inputs,
  ...
}: let
  kube = import ./default.nix {inherit lib;};
in {
  # Fleet-wide kube-cluster assertions (§6.2): computed from the
  # kube_cluster exports as clan.checks. Vacuous for this flake's own
  # (inventory-less) clan; consumers wire the same module into their clan
  # (`clan.imports`), and the eval-test throwaway clans import it too.
  clan.imports = [kube.fleetChecksModule];

  perSystem = {pkgs, ...}: {
    nix-unit.tests.kube-cluster = import ./tests/eval-tests.nix {
      inherit lib inputs pkgs;
    };
  };
}
