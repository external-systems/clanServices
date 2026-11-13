{
  description = "External Systems clan services: k3s, rke2, netif, routed-fabric, wireguard-mesh, remote-builder";

  inputs = {
    # Shared-input and artifact authority: nixpkgs, flake-parts and
    # import-tree, the IfState and Kubernetes overlays, the committed
    # Cilium base manifest and per-system airgap image tarballs (D62).
    # Named org-pkgs, never pkgs: `pkgs` is the nixpkgs package set.
    org-pkgs.url = "github:external-systems/pkgs";
    nixpkgs.follows = "org-pkgs/nixpkgs";
    flake-parts.follows = "org-pkgs/flake-parts";
    import-tree.follows = "org-pkgs/import-tree";

    clan-core = {
      url = "https://git.clan.lol/clan/clan-core/archive/main.tar.gz";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
        treefmt-nix.follows = "org-pkgs/treefmt-nix";
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
        treefmt-nix.follows = "org-pkgs/treefmt-nix";
        import-tree.follows = "import-tree";
      };
    };
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      # Exposes debug.options / currentSystem.options, which nixd
      # (.vscode/settings.json) reads for flake-parts option hints.
      debug = true;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [
        # treefmt, docs + slides, VM tests and the vm-test runner,
        # lock-sync: everything from pkgs.
        inputs.org-pkgs.flakeModules.default
        inputs.clan-core.flakeModules.default
        (inputs.import-tree ./flake-parts)
        # Service and lib directories mix flake-parts modules with plain
        # Nix (service modules, tests, fixtures), so they keep explicit
        # flake-module.nix entry points instead of import-tree.
        ./services/flake-module.nix
        ./lib/kube-cluster/flake-module.nix
      ];
    };
}
