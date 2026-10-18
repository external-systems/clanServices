# Flake-parts module that declares the `clan-community.inputs` option and
# resolves each declared input into a `.outputs` flake using `lib/import-flake.nix`.
#
# This is factored out of `services/flake-module.nix` so that tests can
# exercise exactly this code path (which is where the infinite-recursion bug
# when accessing `config.clan-community.inputs.<name>.outputs` lives) without
# pulling in the full clan-core flake module.
{
  lib,
  inputs,
  ...
}:
{
  options.clan-community.inputs = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          options = {
            src = lib.mkOption {
              type = lib.types.attrs;
              description = "fetchTree-compatible attrset for the flake source.";
            };
            inputs = lib.mkOption {
              type = lib.types.attrsOf lib.types.raw;
              default = { };
              description = ''
                Override specific inputs of this flake.
                Inputs whose names match our flake's inputs are passed automatically.
                Use this to override those or to provide additional inputs.
              '';
            };
            outputs = lib.mkOption {
              type = lib.types.raw;
              readOnly = true;
              description = "Resolved flake outputs. Read-only.";
            };
          };

          # Resolve `outputs` from this entry's own `src` / `inputs` without
          # reading the parent `config.clan-community.inputs` attrset, which
          # would cause infinite recursion (the definition's keys would
          # depend on the merged value we are defining).
          config.outputs = import ./import-flake {
            inherit (config) src;
            # Auto-pass all our flake inputs, then layer explicit overrides on top.
            inputOverrides = inputs // config.inputs;
          };
        }
      )
    );
    default = { };
    description = ''
      External flake sources used by services.
      Each entry fetches the flake via fetchTree and resolves its inputs:
        - Inputs matching our flake's own inputs are passed automatically.
        - Explicit overrides in `.inputs` take precedence.
        - Remaining inputs are fetched from the remote flake.lock.
    '';
  };
}
