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
}: let
  # Skip-to-phase switch (reference/testing.md, "Running some phases"):
  # `VM_PHASES='H16|DHCP' vm-test <suite> --remote --rebuild` runs only
  # the subtests whose name contains one of the `|`-separated words; the
  # code outside subtests (boot, helpers, the final marker) still runs.
  # Impure evaluation only (`--rebuild`); a pure evaluation reads "" and
  # leaves every suite derivation unchanged.
  phases = builtins.getEnv "VM_PHASES";
  phaseFilter = ''
    import contextlib as _phase_contextlib
    import sys as _phase_sys

    _PHASES = [word for word in ${builtins.toJSON phases}.split("|") if word]
    _phase_subtest = subtest


    class _PhaseSkipped(Exception):
        pass


    def _phase_skip_body(frame, event, arg):
        frame.f_trace = None
        raise _PhaseSkipped()


    @_phase_contextlib.contextmanager
    def _phase_filtered_subtest(name):
        if any(word in name for word in _PHASES):
            with _phase_subtest(name):
                yield
            return
        print(f"PHASE SKIPPED (VM_PHASES): {name}")
        # raise on the first line of the `with` body, swallow it here
        frame = _phase_sys._getframe(1)
        while frame.f_code.co_filename == _phase_contextlib.__file__:
            frame = frame.f_back
        previous = _phase_sys.gettrace()
        _phase_sys.settrace(lambda *_: None)
        frame.f_trace = _phase_skip_body
        try:
            yield
        except _PhaseSkipped:
            pass
        finally:
            frame.f_trace = None
            _phase_sys.settrace(previous)


    subtest = _phase_filtered_subtest
    print(f"VM_PHASES: only the subtests that name one of {_PHASES}")
  '';
in {
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
          {testScript = lib.mkIf (phases != "") (lib.mkBefore phaseFilter);}
        ];
        defaults._module.args.clan-core = inputs.clan-core;
        # suite-snapshot --pin: evaluate against a baseline copy of the
        # test directory (impure only; pure evaluation reads "").
        clan.directory = lib.mkIf (builtins.getEnv "VM_SUITE_DIR" != "") (
          lib.mkForce (builtins.storePath (builtins.getEnv "VM_SUITE_DIR"))
        );
      })
      config.clanTests;

    # Topology suites boot whole clusters (two meshed clusters plus
    # external peers), and RKE2 nodes need at least 4 GiB and 2 vCPUs
    # (more to run at a usable speed), so this repo's caps are above the
    # org defaults and leave room for larger topologies. Approved by the
    # owner, sized for euc-hel-0 (128 GiB, 36 threads).
    limits = {
      totalMemorySize = 96 * 1024;
      totalCores = 36;
    };

    # `vm-test --all --remote` runs suites side by side within this
    # budget, below euc-hel-0's 36 threads and 128 GiB so the host keeps
    # headroom and suites do not slow each other into timeouts
    # (owner-approved). A suite that fails alongside others is rerun
    # alone; passing then is a pass with a warning.
    parallel = {
      cores = 24;
      memorySize = 96 * 1024;
    };
    # A suite that hangs is stopped after 45 minutes. The longest suite
    # took 20 minutes beside others on euc-hel-0 (rke2-single and a
    # since-removed tunnel suite) and under 10 alone.
    globalTimeout = 45 * 60;

    # Evaluating every node of the multi-machine suites takes minutes and
    # gigabytes, too much for CI. Run the same checks with
    # `vm-test --check` before VM runs.
    flakeChecks.enable = false;
  };
}
