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

    # Cilium chart (rke2-charts packaging) — the only in-cluster chart the
    # cluster services consume; matches the nixpkgs rke2 airgap image bundle.
    cilium-chart = {
      url = "https://rke2-charts.rancher.io/assets/rke2-cilium/rke2-cilium-1.19.601.tgz";
      flake = false;
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
        {
          nix-unit.inputs = inputs;

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
