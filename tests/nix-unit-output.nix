{
  config,
  lib,
  flake-parts-lib,
  ...
}: {
  options.perSystem = flake-parts-lib.mkPerSystemOption {
    options.nix-unit.tests = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Nix-unit tests exposed for this system";
    };
  };

  config.flake.tests.systems = lib.mapAttrs (_: systemConfig: systemConfig.nix-unit.tests) config.allSystems;
}
