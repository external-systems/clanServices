# nix-unit eval tests. Every service and lib registers its suite in
# perSystem `nix-unit.tests.<name>`; they are exposed as
# `tests.systems.<system>` and run by `checks.nix-unit`.
{
  config,
  lib,
  flake-parts-lib,
  self,
  ...
}: {
  options.perSystem = flake-parts-lib.mkPerSystemOption {
    options.nix-unit.tests = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "nix-unit tests exposed for this system.";
    };
  };

  config = {
    flake.tests.systems = lib.mapAttrs (_: systemConfig: systemConfig.nix-unit.tests) config.allSystems;

    perSystem = {pkgs, ...}: let
      # nix-unit re-evaluates the flake in a network-less sandbox: every
      # locked input is passed as an --override-input store path. The
      # paths are walked from flake.lock, so new inputs need no edit here.
      lock = builtins.fromJSON (builtins.readFile ../flake.lock);
      # A node's inputs: strings name lock nodes, lists are follows (an
      # input path from the root), which the override of the target covers.
      ownInputs = node: lib.filterAttrs (_: isString) (lock.nodes.${node}.inputs or {});
      inherit (builtins) isString;
      overridesOf = prefix: node:
        lib.concatLists (lib.mapAttrsToList (name: child: let
          path = prefix ++ [name];
        in
          [
            {
              name = lib.concatStringsSep "/" path;
              value = fetchTree lock.nodes.${child}.locked;
            }
          ]
          ++ overridesOf path child) (ownInputs node));
      overrides = overridesOf [] lock.root;
      overrideArg = o: "--override-input ${lib.escapeShellArg o.name} ${lib.escapeShellArg "${o.value}"}";
    in {
      checks.nix-unit =
        pkgs.runCommand "nix-unit-check" {
          nativeBuildInputs = [pkgs.nix-unit];
        } ''
          export HOME="$(realpath .)"
          unset NIX_STORE
          export NIX_STORE_DIR=${builtins.storeDir}
          export NIX_REMOTE="$HOME/storedata"
          nix-unit \
            --show-trace \
            --extra-experimental-features "flakes pipe-operators" \
            --accept-flake-config \
            ${lib.concatMapStringsSep " \\\n  " overrideArg overrides} \
            --flake ${self}#tests.systems.${pkgs.stdenv.hostPlatform.system}
          touch $out
        '';
    };
  };
}
