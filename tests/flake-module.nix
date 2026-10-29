{
  lib,
  self,
  ...
}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    # Eval test coverage for clan services: every service must have a corresponding nix-unit test.
    # Every service: (`clan.modules.<moduleName>`) must have a matching `tests.systems.<system>.<moduleName>`
    # throws at eval time
    checks.coverage = let
      services = builtins.attrNames self.clan.modules;
      tests = self.tests.systems.${system};
      untested = builtins.filter (name: !(tests ? ${name}) || !builtins.isAttrs tests.${name}) services;
    in
      if untested != []
      then
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
