{
  description = "External Systems custom clan services";

  inputs = {
    nixpkgs.follows = "clan-core/nixpkgs";
    data-mesher.follows = "clan-core/data-mesher";
    disko.follows = "clan-core/disko";
    nix-darwin.follows = "clan-core/nix-darwin";
    nix-select.follows = "clan-core/nix-select";
    sops-nix.follows = "clan-core/sops-nix";
    systems.follows = "clan-core/systems";

    clan-core = {
      url = "https://git.clan.lol/clan/clan-core/archive/main.tar.gz";
      inputs = {
        treefmt-nix.follows = "treefmt-nix";
        flake-parts.follows = "flake-parts";
      };
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Artifact flake: distro runtimes, the Cilium chart + committed inflated
    # base manifest (manifests/cilium/<version>.yaml, D26 layer 1), and the
    # digest-pinned Cilium airgap image tarballs for hermetic VM tests.
    pkgs = {
      url = "github:external-systems/pkgs/41b9486bcef705130d980b96a193733ce93b13f3";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
      };
    };

    # Kubenix renders the bootstrap bundle (D26 layer 2): the committed base
    # manifest is imported as source (pure Nix YAML subset parser, zero IFD)
    # into the typed resource tree; per-cluster variation merges on top.
    # Helm inflation (renderChart) is never used here — update-time only,
    # in the artifact flake.
    kubenix = {
      url = "github:hall/kubenix/6a37ce99125b068a7da9eb7bebd29898ed043eb5";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
        treefmt-nix.follows = "treefmt-nix";
      };
    };

    nix-unit = {
      url = "github:nix-community/nix-unit";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        treefmt-nix.follows = "treefmt-nix";
      };
    };
    nix-github-actions = {
      url = "github:nix-community/nix-github-actions";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # MkDocs site + reveal.js slides for the spec/docs (see documentation/).
    presenting = {
      url = "github:external-systems/presenting";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
      };
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      debug = true;

      imports = [
        inputs.nix-unit.modules.flake.default
        (
          { lib, ... }:
          {
            # For debugging the flake
            flake.options.flake = lib.mkOption { default = self; };
          }
        )
        inputs.clan-core.flakeModules.default
        inputs.clan-core.flakeModules.testModule
        ./formatter.nix
        ./services/flake-module.nix
        ./lib/kube-cluster/flake-module.nix
        ./tests/flake-module.nix
        ./documentation/module.nix
      ];

      perSystem =
        { pkgs, ... }:
        let
          # The nix-unit check re-evaluates this flake in a network-less
          # sandbox with each direct input overridden to its store path.
          # Overriding `pkgs` to a path makes Nix re-resolve the pkgs
          # flake's OWN lock transitively (its nixpkgs/flake-parts/
          # import-tree), so those get explicit nested overrides pointing
          # at our already-fetched equivalents (identical revisions).
          # Same for `presenting` (mkdocs-flake/reveal-js/import-tree).
          lock = builtins.fromJSON (builtins.readFile ./flake.lock);
          # Resolve the pkgs flake's import-tree through the flattened lock
          # (node name via pkgs' inputs map, so lock renumbering is safe).
          pkgsImportTree = builtins.fetchTree lock.nodes.${lock.nodes.pkgs.inputs."import-tree"}.locked;
          presentingMkdocsFlake =
            builtins.fetchTree
              lock.nodes.${lock.nodes.presenting.inputs."mkdocs-flake"}.locked;
          presentingRevealJs =
            builtins.fetchTree
              lock.nodes.${lock.nodes.presenting.inputs."reveal-js"}.locked;
          presentingImportTree =
            builtins.fetchTree
              lock.nodes.${lock.nodes.presenting.inputs."import-tree"}.locked;
          kubenixImportTree = builtins.fetchTree lock.nodes.${lock.nodes.kubenix.inputs."import-tree"}.locked;
          kubenixDevshell = builtins.fetchTree lock.nodes.${lock.nodes.kubenix.inputs."devshell"}.locked;
          kubenixFlakeCompat =
            builtins.fetchTree
              lock.nodes.${lock.nodes.kubenix.inputs."flake-compat"}.locked;
          kubenixSystems = builtins.fetchTree lock.nodes.${lock.nodes.kubenix.inputs."systems"}.locked;
        in
        {
          nix-unit.inputs = inputs // {
            "pkgs/nixpkgs" = inputs.nixpkgs;
            "pkgs/flake-parts" = inputs.flake-parts;
            "pkgs/import-tree" = pkgsImportTree;
            "presenting/mkdocs-flake" = presentingMkdocsFlake;
            "presenting/reveal-js" = presentingRevealJs;
            "presenting/import-tree" = presentingImportTree;
            "kubenix/import-tree" = kubenixImportTree;
            "kubenix/devshell" = kubenixDevshell;
            "kubenix/flake-compat" = kubenixFlakeCompat;
            "kubenix/systems" = kubenixSystems;
          };

          devShells.default = pkgs.mkShell {
            # bash/jq/git are what scripts/update-pins.sh needs; the CI runner
            # image is a bare nix container that provides none of them.
            packages = [
              pkgs.treefmt
              pkgs.bash
              pkgs.jq
              pkgs.git
            ];
          };
        };
    };
}
