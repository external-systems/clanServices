# Proof tools for test refactors (subtests, grep rewrites, shared k3s/rke2
# bodies): `nix run .#suite-snapshot -- BASE` before editing, then
# `nix run .#suite-snapshot -- AFTER --pin BASE` and
# `nix run .#suite-compare -- BASE AFTER`. See reference/testing.md.
_: {
  perSystem = {
    lib,
    pkgs,
    ...
  }: let
    suite-snapshot = pkgs.writeShellApplication {
      name = "suite-snapshot";
      runtimeInputs = [pkgs.coreutils pkgs.findutils pkgs.git];
      text = builtins.readFile ../scripts/suite-snapshot.sh;
    };
    suite-compare = pkgs.writeShellApplication {
      name = "suite-compare";
      text = ''exec ${lib.getExe pkgs.python3} ${../scripts/suite-compare.py} "$@"'';
    };
  in {
    apps = {
      suite-snapshot = {
        type = "app";
        program = lib.getExe suite-snapshot;
        meta.description = "Snapshot VM suites' node derivations and rendered test scripts";
      };
      suite-compare = {
        type = "app";
        program = lib.getExe suite-compare;
        meta.description = "Prove a VM-suite refactor faithful against a baseline snapshot";
      };
    };
  };
}
