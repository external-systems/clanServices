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
    # Re-evaluate the root tests output in a network-less sandbox with every
    # direct input overridden to its store path. Nested overrides keep the
    # already-fetched locked inputs reachable without a wrapper flake.
    rootLock = builtins.fromJSON (builtins.readFile ../flake.lock);
    overrideArg = name: value: "--override-input ${lib.escapeShellArg name} ${lib.escapeShellArg "${value}"}";
    pkgsImportTree = fetchTree rootLock.nodes.${rootLock.nodes.pkgs.inputs."import-tree"}.locked;
    kubenixImportTree =
      fetchTree rootLock.nodes.${rootLock.nodes.kubenix.inputs."import-tree"}.locked;
    kubenixDevshell =
      fetchTree rootLock.nodes.${rootLock.nodes.kubenix.inputs."devshell"}.locked;
    kubenixFlakeCompat =
      fetchTree rootLock.nodes.${rootLock.nodes.kubenix.inputs."flake-compat"}.locked;
    kubenixSystems =
      fetchTree rootLock.nodes.${rootLock.nodes.kubenix.inputs."systems"}.locked;
    nixUnitInputs =
      lib.getAttrs [
        "clan-core"
        "flake-parts"
        "kubenix"
        "nixpkgs"
        "pkgs"
        "treefmt-nix"
      ]
      inputs
      // {
        "clan-core/data-mesher" = inputs.clan-core.inputs.data-mesher;
        "clan-core/disko" = inputs.clan-core.inputs.disko;
        "clan-core/nix-darwin" = inputs.clan-core.inputs.nix-darwin;
        "clan-core/nix-select" = inputs.clan-core.inputs.nix-select;
        "clan-core/sops-nix" = inputs.clan-core.inputs.sops-nix;
        "clan-core/systems" = inputs.clan-core.inputs.systems;
        "clan-core/nixpkgs" = inputs.nixpkgs;
        "clan-core/flake-parts" = inputs.flake-parts;
        "clan-core/treefmt-nix" = inputs.treefmt-nix;
        "pkgs/nixpkgs" = inputs.nixpkgs;
        "pkgs/flake-parts" = inputs.flake-parts;
        "pkgs/flake-parts/nixpkgs-lib" = inputs.nixpkgs;
        "pkgs/import-tree" = pkgsImportTree;
        "flake-parts/nixpkgs-lib" = inputs.nixpkgs;
        "kubenix/import-tree" = kubenixImportTree;
        "kubenix/devshell" = kubenixDevshell;
        "kubenix/flake-compat" = kubenixFlakeCompat;
        "kubenix/systems" = kubenixSystems;
      };
  in {
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
          --flake ${self}#tests.systems.${pkgs.stdenv.hostPlatform.system}
        touch $out
      '';

    devShells.default = pkgs.mkShell {
      # Support update scripts and CI runners whose images provide no tools.
      packages = [
        config.treefmt.build.wrapper
        pkgs.bash
        pkgs.jq
        pkgs.git
      ];
    };
  };
}
