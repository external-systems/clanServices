{
  lib,
  flake-parts-lib,
  inputs,
  ...
}: let
  inherit (lib) mkOption types;
  inherit (flake-parts-lib) mkPerSystemOption;
  nixosLib = import (inputs.nixpkgs + "/nixos/lib") {};
in {
  options.perSystem = mkPerSystemOption (
    {
      config,
      pkgs,
      ...
    }: let
      cfg = config.clan.nixosTests;
      tests =
        lib.mapAttrs (
          _name: testModule:
            nixosLib.runTest (
              {...}: {
                _module.args.inputs = inputs;

                imports = [
                  inputs.clan-core.modules.nixosTest.clanTest
                  testModule
                ];

                hostPkgs = pkgs;

                defaults._module.args.clan-core = inputs.clan-core;
              }
            )
        )
        cfg;
    in {
      options.clan.nixosTests = mkOption {
        description = "Unstable interface! Clan NixOS tests configuration";
        type = types.attrsOf types.unspecified;
        default = {};
      };

      config.legacyPackages.vmTests = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux tests;
    }
  );
}
