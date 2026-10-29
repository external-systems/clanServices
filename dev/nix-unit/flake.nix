{
  description = "Offline nix-unit view of clanServices with development inputs";

  inputs = {
    clanServices = {
      url = "path:../..";
      flake = false;
    };
    nixpkgs.follows = "pkgs/nixpkgs";
    flake-parts.follows = "pkgs/flake-parts";
    data-mesher.follows = "clan-core/data-mesher";
    disko.follows = "clan-core/disko";
    nix-darwin.follows = "clan-core/nix-darwin";
    nix-select.follows = "clan-core/nix-select";
    sops-nix.follows = "clan-core/sops-nix";
    systems.follows = "clan-core/systems";

    clan-core = {
      url = "https://git.clan.lol/clan/clan-core/archive/06f8e420826646b1b43afe3b15cf8ae6852dc996.tar.gz";
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

    pkgs.url = "github:external-systems/pkgs";

    kubenix = {
      url = "github:hall/kubenix/6a37ce99125b068a7da9eb7bebd29898ed043eb5";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
        treefmt-nix.follows = "treefmt-nix";
      };
    };

    dev-nixpkgs.url = "github:NixOS/nixpkgs/31ecbaca1bdefa45dffc409f0250bd8039ea0010";
    dev-flake-parts = {
      url = "github:hercules-ci/flake-parts/024633cd702b10285db5cb19b40ad48d2399ba60";
      inputs.nixpkgs-lib.follows = "dev-nixpkgs";
    };
    dev-treefmt-nix = {
      url = "github:numtide/treefmt-nix/0d6d739a833ba9a9c93034862e4a7b061a062a1c";
      inputs.nixpkgs.follows = "dev-nixpkgs";
    };

    nix-unit = {
      url = "github:nix-community/nix-unit/b3d16367c54621fd073aa8c1dd510042f771f624";
      inputs = {
        nixpkgs.follows = "dev-nixpkgs";
        treefmt-nix.follows = "dev-treefmt-nix";
      };
    };

    presenting = {
      url = "github:external-systems/presenting/38c4535cb9080fdab2900da88442440181062d92";
      inputs = {
        nixpkgs.follows = "dev-nixpkgs";
        flake-parts.follows = "dev-flake-parts";
      };
    };
  };

  outputs = inputs: (import (inputs.clanServices.outPath + "/flake.nix")).outputs inputs;
}
