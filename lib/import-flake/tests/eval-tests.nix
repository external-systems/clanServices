# Eval tests for import-flake and inputs-module
#
# Each test is an attrset { expr; expected; } — same shape as nix-unit.
# The test runner (tests/flake-module.nix) forces every assertion at
# Nix eval time, so no network access is needed during the build.
{
  lib,
  inputs,
}:
let
  importFlake = import ../default.nix;

  storeFixture =
    name:
    toString (
      builtins.path {
        inherit name;
        path = ./. + "/${name}";
      }
    );

  fixturePath = storeFixture "fixture-flake";
  fixtureNarHash = "sha256-Hv7dUzb7pnuh2GcV85Ho4Y3WYcFL3N0VvAUsOuxmOUA=";

  fixtureSrc = {
    type = "path";
    path = fixturePath;
    narHash = fixtureNarHash;
  };

  # Helper: evaluate the inputs-module with a given set of extra modules.
  evalInputsModule =
    extraModules:
    lib.evalModules {
      modules = [
        ../../inputs-module.nix
        { _module.args = { inherit inputs; }; }
      ]
      ++ extraModules;
    };
in
{
  # ── import-flake ─────────────────────────────────────────────────────

  # Basic: importing a flake with no inputs produces the expected outputs.
  test_import_flake_basic_outputs = {
    expr =
      let
        flake = importFlake { src = fixtureSrc; };
      in
      flake.nixosModules.hello {
        inherit lib;
        config = { };
        options = { };
        pkgs = { };
      };
    expected = {
      environment.etc."hello-from-fixture".text = "hi from the fixture flake";
    };
  };

  # Verify outPath and sourceInfo are set on the imported flake.
  test_import_flake_has_metadata =
    let
      flake = importFlake { src = fixtureSrc; };
    in
    {
      expr = {
        hasOutPath = builtins.hasAttr "outPath" flake;
        hasSourceInfo = builtins.hasAttr "sourceInfo" flake;
        hasInputs = builtins.hasAttr "inputs" flake;
      };
      expected = {
        hasOutPath = true;
        hasSourceInfo = true;
        hasInputs = true;
      };
    };

  # A flake with no inputs should have an empty inputs attrset.
  test_import_flake_no_inputs =
    let
      flake = importFlake { src = fixtureSrc; };
    in
    {
      expr = flake.inputs;
      expected = { };
    };

  # Passing inputOverrides for inputs that don't exist in the remote flake
  # should not cause errors — they are simply ignored.
  test_import_flake_extra_overrides_ignored =
    let
      flake = importFlake {
        src = fixtureSrc;
        inputOverrides = {
          nonexistent = "should be ignored";
        };
      };
    in
    {
      expr = flake.inputs;
      expected = { };
    };

  # ── inputs-module ────────────────────────────────────────────────────

  # The `.outputs` attribute resolves to a valid flake with the expected module.
  test_inputs_module_resolves_outputs = {
    expr =
      let
        evaled = evalInputsModule [
          { clan-community.inputs.fixture.src = fixtureSrc; }
        ];
        fixture = evaled.config.clan-community.inputs.fixture.outputs;
      in
      {
        hasNixosModules = builtins.hasAttr "nixosModules" fixture;
        hasHello = builtins.hasAttr "hello" (fixture.nixosModules or { });
      };
    expected = {
      hasNixosModules = true;
      hasHello = true;
    };
  };

  # Default value for clan-community.inputs is empty.
  test_inputs_module_default_empty = {
    expr =
      let
        evaled = evalInputsModule [ ];
      in
      evaled.config.clan-community.inputs;
    expected = { };
  };

  # Multiple inputs can be declared independently.
  test_inputs_module_multiple_inputs = {
    expr =
      let
        evaled = evalInputsModule [
          {
            clan-community.inputs.first.src = fixtureSrc;
            clan-community.inputs.second.src = fixtureSrc;
          }
        ];
        cfg = evaled.config.clan-community.inputs;
      in
      {
        hasFirst = builtins.hasAttr "first" cfg;
        hasSecond = builtins.hasAttr "second" cfg;
        firstHasOutputs = builtins.hasAttr "outputs" cfg.first;
        secondHasOutputs = builtins.hasAttr "outputs" cfg.second;
      };
    expected = {
      hasFirst = true;
      hasSecond = true;
      firstHasOutputs = true;
      secondHasOutputs = true;
    };
  };

  # Explicit input overrides in the module are passed through to import-flake.
  # Since fixture-flake has no inputs, this just verifies no crash occurs.
  test_inputs_module_with_explicit_overrides = {
    expr =
      let
        evaled = evalInputsModule [
          {
            clan-community.inputs.fixture = {
              src = fixtureSrc;
              inputs.some-dep = "override-value";
            };
          }
        ];
        fixture = evaled.config.clan-community.inputs.fixture.outputs;
      in
      builtins.hasAttr "nixosModules" fixture;
    expected = true;
  };

  # Verify that the resolved flake output matches what a direct call
  # to import-flake produces — inputs-module is a thin wrapper.
  test_inputs_module_output_matches_direct = {
    expr =
      let
        direct = importFlake {
          src = fixtureSrc;
          inputOverrides = inputs;
        };
        evaled = evalInputsModule [
          { clan-community.inputs.fixture.src = fixtureSrc; }
        ];
        viaModule = evaled.config.clan-community.inputs.fixture.outputs;
      in
      {
        # Both resolve to the same store path
        sameOutPath = direct.outPath == viaModule.outPath;
        # Both expose the same module
        sameModuleOutput =
          (direct.nixosModules.hello {
            inherit lib;
            config = { };
            options = { };
            pkgs = { };
          }) == (viaModule.nixosModules.hello {
            inherit lib;
            config = { };
            options = { };
            pkgs = { };
          });
      };
    expected = {
      sameOutPath = true;
      sameModuleOutput = true;
    };
  };

  # Regression: resolving a nixosModule from `.outputs` and calling it must
  # not trigger infinite recursion. The bug was in the inputs option's lazy
  # resolution — accessing `.outputs` on any entry would recurse.
  test_inputs_module_import_resolved_nixos_module = {
    expr =
      let
        evaled = evalInputsModule [
          { clan-community.inputs.fixture.src = fixtureSrc; }
        ];
        resolvedModule = evaled.config.clan-community.inputs.fixture.outputs.nixosModules.hello;
        # Call the module function directly — no need for a full NixOS eval.
        moduleResult = resolvedModule {
          inherit lib;
          config = { };
          options = { };
          pkgs = { };
        };
      in
      moduleResult.environment.etc."hello-from-fixture".text;
    expected = "hi from the fixture flake";
  };

  # Two inputs declared simultaneously must not cause infinite recursion
  # even though both are resolved from the same config attrset.
  test_inputs_module_independent_inputs_no_cycle = {
    expr =
      let
        evaled = evalInputsModule [
          {
            clan-community.inputs.a.src = fixtureSrc;
            clan-community.inputs.b.src = fixtureSrc;
          }
        ];
        # Force both .outputs — if the option implementation accidentally
        # reads the full `config.clan-community.inputs` attrset while
        # defining an entry, this would loop.
        aOut = evaled.config.clan-community.inputs.a.outputs;
        bOut = evaled.config.clan-community.inputs.b.outputs;
      in
      {
        aHasModules = builtins.hasAttr "nixosModules" aOut;
        bHasModules = builtins.hasAttr "nixosModules" bOut;
      };
    expected = {
      aHasModules = true;
      bHasModules = true;
    };
  };

  # Cyclic dependency: flake A depends on B and B depends on A.
  # Nix's lazy evaluation allows this as long as we don't force an
  # actual infinite chain through the outputs. Each flake exposes its
  # own `greeting` (no deps) and the other's `greeting` (one hop).
  test_import_flake_cyclic_deps = {
    expr =
      let
        fixtureSrcA = {
          type = "path";
          path = storeFixture "fixture-a";
          narHash = "sha256-hKSz+PwGtbKkWJNdqAcr/rfNkpYENDrZILGn6CZOL6g=";
        };
        fixtureSrcB = {
          type = "path";
          path = storeFixture "fixture-b";
          narHash = "sha256-JToJ5TVuUj/xa2jFSgy0onGvpzQC3ZOV91wRyrkm7T0=";
        };
        # Wire the cycle: A gets B, B gets A.
        aFlake = importFlake {
          src = fixtureSrcA;
          inputOverrides = {
            b = bFlake;
          };
        };
        bFlake = importFlake {
          src = fixtureSrcB;
          inputOverrides = {
            a = aFlake;
          };
        };
      in
      {
        aGreeting = aFlake.greeting;
        bGreeting = bFlake.greeting;
        # One hop across the cycle: A reads B's greeting and vice versa.
        aBGreeting = aFlake.bGreeting;
        bAGreeting = bFlake.aGreeting;
      };
    expected = {
      aGreeting = "hello from a";
      bGreeting = "hello from b";
      aBGreeting = "hello from b";
      bAGreeting = "hello from a";
    };
  };
}
