{
  description = "Development-only inputs for clanServices";

  inputs = {
    dev-nixpkgs.url = "github:NixOS/nixpkgs";
    dev-flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "dev-nixpkgs";
    };
    dev-treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "dev-nixpkgs";
    };

    nix-unit = {
      url = "github:nix-community/nix-unit";
      inputs = {
        nixpkgs.follows = "dev-nixpkgs";
        treefmt-nix.follows = "dev-treefmt-nix";
      };
    };

    presenting = {
      url = "github:external-systems/presenting";
      inputs = {
        nixpkgs.follows = "dev-nixpkgs";
        flake-parts.follows = "dev-flake-parts";
      };
    };
  };

  outputs = _: {};
}
