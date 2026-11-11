{
  inputs,
  lib,
  ...
}: let
  module = ./default.nix;
in {
  clan.modules.remote-builder = module;

  perSystem = _: {
    nix-unit.tests.remote-builder = import ./tests/eval-tests.nix {
      inherit module lib;
      clanLib = inputs.clan-core.lib;
    };
  };
}
