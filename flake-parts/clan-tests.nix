# Clan service VM suites on the org runner (org-pkgs flakeModules.vmTests).
# Each service's flake-module.nix registers its suites in `clanTests`;
# this module wraps every one in clan-core's clanTest (inventory, vars,
# the clan-core module argument) and hands it to vmTests.tests, so they
# land in legacyPackages.<system>.vmTests and run with `vm-test`.
{
  config,
  inputs,
  lib,
  ...
}: {
  options.clanTests = lib.mkOption {
    type = lib.types.attrsOf lib.types.deferredModule;
    default = {};
    description = ''
      Clan VM suites by name: clanTest modules (`clan`, `nodes`,
      `testScript`) that become `vmTests.tests.<name>`.
    '';
  };

  config.vmTests = {
    # No vm-tests/ directory: every suite lives next to its service.
    dir = null;

    tests =
      lib.mapAttrs (_: test: {
        imports = [
          inputs.clan-core.modules.nixosTest.clanTest
          test
        ];
        defaults._module.args.clan-core = inputs.clan-core;
      })
      config.clanTests;

    # Topology suites boot whole clusters (two meshed clusters plus
    # external peers), so they need more than the org defaults. Approved
    # by the owner for this repo, sized for euc-hel-0 (128 GiB, 36
    # threads), which runs one suite at a time: `vm-test --all --serial
    # --remote`, never plain --all.
    limits = {
      totalMemorySize = 96 * 1024;
      totalCores = 36;
    };
    globalTimeout = 2 * 60 * 60;

    # Evaluating every node of 24 multi-machine suites takes minutes and
    # gigabytes, too much for CI. Run the same checks with
    # `vm-test --check` before VM runs.
    flakeChecks.enable = false;
  };
}
