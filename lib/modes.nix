# Modes (specs/netif.md N3, N24). A machine has one or more modes; each
# has exactly one network manager. The mode `default` is the parent
# configuration; every other mode is a NixOS specialisation, picked in
# the boot menu. Nothing switches modes at run time.
#
# The `modes` clan service fills `clanServices.networking.modes`. Every
# other module reads the read-only `clanServices.networking.mode`.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.clanServices.networking;
  manager = types.enum [
    "ifstate"
    "networkmanager"
  ];
in {
  key = "clanServices:lib/modes.nix";

  options.clanServices.networking = {
    modes = mkOption {
      default = {};
      example = {
        default.manager = "networkmanager";
        developer.manager = "ifstate";
      };
      description = ''
        The machine's modes and the network manager of each. 'default'
        is the parent configuration; a machine with no entry has the
        one mode 'default' with IfState. Set by the 'modes' clan
        service.
      '';
      type = types.attrsOf (
        types.submodule {
          options.manager = mkOption {
            type = manager;
            description = "The one network manager of this mode.";
          };
        }
      );
    };
    # A read-only option cannot differ between the parent and a
    # specialisation, so each specialisation sets this one instead.
    currentMode = mkOption {
      type = types.str;
      default = "default";
      internal = true;
      description = "The mode this configuration is. Set only by this module, in each specialisation.";
    };
    mode = mkOption {
      readOnly = true;
      description = "The mode this configuration is and its network manager. Modules gate on it; nothing else defines specialisations for networking purposes.";
      type = types.submodule {
        options = {
          name = mkOption {type = types.str;};
          manager = mkOption {type = manager;};
        };
      };
    };
  };

  config = {
    clanServices.networking.mode = {
      name = cfg.currentMode;
      manager = cfg.modes.${cfg.currentMode}.manager or "ifstate";
    };

    # A specialisation inherits the parent's modules and NixOS clears its
    # own specialisation set, so nothing nests.
    specialisation = lib.mkIf (cfg.currentMode == "default") (
      lib.mapAttrs (name: _: {configuration.clanServices.networking.currentMode = name;}) (
        removeAttrs cfg.modes ["default"]
      )
    );
  };
}
