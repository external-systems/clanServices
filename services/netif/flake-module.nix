{
  inputs,
  lib,
  ...
}: let
  module = lib.modules.importApply ./default.nix {
    ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  };
  clanLib = inputs.clan-core.lib;
in rec {
  clan = {
    modules.netif = module;
    exportInterfaces.netif = ./netif-interface.nix;
  };

  perSystem = {system, ...}: {
    # Probes (specs/netif.md N40): findings no suite asserts yet. Outside
    # `checks` and `vmTests`; run one with `nix build .#netifProbes.<name>`.
    legacyPackages.netifProbes = let
      probePkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [inputs.org-pkgs.overlays.ifstate];
      };
    in
      lib.genAttrs ["vmhost" "guard" "wifi"] (
        probe: probePkgs.testers.runNixOSTest (import (./tests/probes + "/${probe}.nix"))
      )
      // {
        modes-eval = import ./tests/probes/modes-eval.nix {
          inherit (inputs) nixpkgs;
          ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
        };
      };

    nix-unit.tests.netif = import ./tests/eval-tests.nix {
      inherit
        module
        clanLib
        lib
        ;
      inherit (clan) exportInterfaces;
    };
  };

  clanTests = {
    netif = {
      imports = [./tests/vm/default.nix];
      inherit clan;
    };
    netif-dhcp = {
      imports = [./tests/vm/dhcp.nix];
      inherit clan;
    };
    netif-match = {
      imports = [./tests/vm/match.nix];
      inherit clan;
    };
    netif-containers = {
      imports = [./tests/vm/containers.nix];
      inherit clan;
    };
    netif-registry = {
      imports = [./tests/vm/registry.nix];
      inherit clan;
    };
  };
}
