{
  description = "External Systems custom clan services";

  inputs = {
    nixpkgs.follows = "pkgs/nixpkgs";
    flake-parts.follows = "pkgs/flake-parts";
    data-mesher.follows = "clan-core/data-mesher";
    disko.follows = "clan-core/disko";
    nix-darwin.follows = "clan-core/nix-darwin";
    nix-select.follows = "clan-core/nix-select";
    sops-nix.follows = "clan-core/sops-nix";
    systems.follows = "clan-core/systems";

    clan-core = {
      url = "https://git.clan.lol/clan/clan-core/archive/main.tar.gz";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        treefmt-nix.follows = "treefmt-nix";
        flake-parts.follows = "flake-parts";
      };
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Artifact and shared-input authority: distro runtimes, IfState, the
    # committed Cilium base manifest, and per-system airgap image tarballs.
    pkgs.url = "github:external-systems/pkgs";

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
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [
        inputs.flake-parts.flakeModules.partitions
        inputs.clan-core.flakeModules.default
        ./tests/clan-nixos-test.nix
        ./overlays.nix
        ./services/flake-module.nix
        ./lib/kube-cluster/flake-module.nix
      ];

      partitionedAttrs = {
        apps = "dev";
        checks = "dev";
        devShells = "dev";
        formatter = "dev";
        packages = "dev";
        tests = "dev";
      };

      partitions.dev =
        {module = ./dev/flake-module.nix;}
        // (
          if inputs ? nix-unit
          then {
            # The offline nix-unit wrapper supplies dev inputs directly.
            extraInputs = {
              inherit
                (inputs)
                dev-flake-parts
                dev-nixpkgs
                dev-treefmt-nix
                nix-unit
                presenting
                ;
            };
          }
          else {extraInputsFlake = ./dev;}
        );
    };
}
