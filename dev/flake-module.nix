{
  inputs,
  self,
  ...
}: {
  imports = [
    ../formatter.nix
    ../tests/flake-module.nix
    ../tests/vm-test-app.nix
    ../documentation/module.nix
  ];

  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # The nix-unit check re-evaluates this flake in a network-less sandbox
    # with each direct input overridden to its store path. Nested overrides
    # keep those evaluations on the already-fetched locked inputs.
    rootLock = builtins.fromJSON (builtins.readFile ../flake.lock);
    devLock = builtins.fromJSON (builtins.readFile ./flake.lock);
    overrideArg = name: value: "--override-input ${lib.escapeShellArg name} ${lib.escapeShellArg "${value}"}";
    pkgsImportTree = builtins.fetchTree rootLock.nodes.${rootLock.nodes.pkgs.inputs."import-tree"}.locked;
    presentingMkdocsFlake =
      builtins.fetchTree devLock.nodes.${devLock.nodes.presenting.inputs."mkdocs-flake"}.locked;
    presentingRevealJs =
      builtins.fetchTree devLock.nodes.${devLock.nodes.presenting.inputs."reveal-js"}.locked;
    presentingImportTree =
      builtins.fetchTree devLock.nodes.${devLock.nodes.presenting.inputs."import-tree"}.locked;
    kubenixImportTree =
      builtins.fetchTree rootLock.nodes.${rootLock.nodes.kubenix.inputs."import-tree"}.locked;
    kubenixDevshell =
      builtins.fetchTree rootLock.nodes.${rootLock.nodes.kubenix.inputs."devshell"}.locked;
    kubenixFlakeCompat =
      builtins.fetchTree rootLock.nodes.${rootLock.nodes.kubenix.inputs."flake-compat"}.locked;
    kubenixSystems =
      builtins.fetchTree rootLock.nodes.${rootLock.nodes.kubenix.inputs."systems"}.locked;
    nestedInputs = {
      "clan-core/nixpkgs" = inputs.nixpkgs;
      "clan-core/flake-parts" = inputs.flake-parts;
      "clan-core/treefmt-nix" = inputs.treefmt-nix;
      "pkgs/nixpkgs" = inputs.nixpkgs;
      "pkgs/flake-parts" = inputs.flake-parts;
      "pkgs/flake-parts/nixpkgs-lib" = inputs.nixpkgs;
      "pkgs/import-tree" = pkgsImportTree;
      "flake-parts/nixpkgs-lib" = inputs.nixpkgs;
      "presenting/mkdocs-flake" = presentingMkdocsFlake;
      "presenting/reveal-js" = presentingRevealJs;
      "presenting/import-tree" = presentingImportTree;
      "kubenix/import-tree" = kubenixImportTree;
      "kubenix/devshell" = kubenixDevshell;
      "kubenix/flake-compat" = kubenixFlakeCompat;
      "kubenix/systems" = kubenixSystems;
    };
    clanServicesInputs = {
      inherit
        (inputs)
        clan-core
        data-mesher
        disko
        flake-parts
        kubenix
        nix-darwin
        nix-select
        nixpkgs
        pkgs
        sops-nix
        systems
        treefmt-nix
        ;
    };
    forClanServices = attrs:
      lib.mapAttrs' (name: value: lib.nameValuePair "clanServices/${name}" value) attrs;
    nixUnitInputs =
      inputs
      // nestedInputs
      // {clanServices = self;}
      // forClanServices clanServicesInputs
      // forClanServices nestedInputs;
  in {
    # Re-evaluate through a dev-only wrapper whose direct inputs include the
    # partition inputs. The stock runner can then override every input in its
    # network-less sandbox without resolving the development subflake again.
    checks.nix-unit =
      pkgs.runCommand "nix-unit-check" {
        nativeBuildInputs = [inputs.nix-unit.packages.${pkgs.stdenv.hostPlatform.system}.default];
      } ''
        export HOME="$(realpath .)"
        unset NIX_STORE
        export NIX_STORE_DIR=${builtins.storeDir}
        export NIX_REMOTE="$HOME/storedata"
        nix-unit \
          --show-trace \
          --extra-experimental-features "flakes pipe-operators" \
          --accept-flake-config \
          ${lib.concatStringsSep "\\\n  " (lib.mapAttrsToList overrideArg nixUnitInputs)} \
          --flake ${./nix-unit}#tests.systems.${pkgs.stdenv.hostPlatform.system}
        touch $out
      '';

    devShells.default = pkgs.mkShell {
      # bash/jq/git are what scripts/update-pins.sh needs; the CI runner
      # image is a bare nix container that provides none of them.
      packages = [
        config.treefmt.build.wrapper
        pkgs.bash
        pkgs.jq
        pkgs.git
      ];
    };
  };
}
