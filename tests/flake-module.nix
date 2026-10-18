{
  inputs,
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    {

      # Eval tests for lib/import-flake and lib/inputs-module.
      # Each test has { expr; expected; } — we assert equality at eval time.
      checks.eval-tests-import-flake =
        let
          tests = import ../lib/import-flake/tests/eval-tests.nix { inherit lib inputs; };
          # Force every test assertion at Nix eval time.
          results = lib.mapAttrs (
            name: test:
            let
              pass = test.expr == test.expected;
            in
            if pass then
              "pass"
            else
              throw "eval test '${name}' failed:\n  expr:     ${builtins.toJSON test.expr}\n  expected: ${builtins.toJSON test.expected}"
          ) tests;
          # Concatenate results into a single string to embed in the drv.
          summary = lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: status: "  ${name}: ${status}") results
          );
        in
        pkgs.runCommand "eval-tests-import-flake" { inherit summary; } ''
          echo "All import-flake eval tests passed:"
          echo "$summary"
          echo ""
          echo "${toString (builtins.length (builtins.attrNames tests))} tests passed."
          touch $out
        '';

      # Eval test coverage for clan services: every service must have a corresponding nix-unit test.
      # Every service: (`clan.modules.<moduleName>`) must have a matching `tests.systems.<system>.<moduleName>`
      # throws at eval time
      checks.coverage =
        let
          services = builtins.attrNames self.clan.modules;
          tests = self.tests.systems.${system};
          untested = builtins.filter (name: !(tests ? ${name}) || !builtins.isAttrs tests.${name}) services;
        in
        if untested != [ ] then
          throw ''
            Missing nix-unit tests for the following clan services on ${system}:
            ${lib.concatMapStringsSep "\n" (n: "  - ${n}") untested}

            Every service in `clan.modules` must have a nix-unit test registered at
            `tests.systems.${system}.<moduleName>`. See services/wifi for an example.
          ''
        else
          pkgs.runCommand "service-test-coverage-${system}"
            {
              covered = lib.concatMapStringsSep "\n" (n: "  - ${n}") services;
            }
            ''
              echo "All ${toString (builtins.length services)} clan services have nix-unit tests on ${system}:"
              echo "$covered"
              touch $out
            '';
    };
}
