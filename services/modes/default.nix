# The `modes` clan service (specs/netif.md N24): per machine, the list
# of network modes and the manager of each. The mechanism (the
# specialisations and the read-only mode option) is lib/modes.nix, which
# the shared networking base imports too.
_: {
  _class = "clan.service";
  manifest = {
    name = "modes";
    description = "Network modes per machine: one network manager per mode, every mode but 'default' a boot-menu specialisation";
    readme = builtins.readFile ./README.md;
    categories = ["Network"];
  };

  roles.default = {
    description = "Machine with one or more network modes";
    interface = {lib, ...}: {
      options.modes = lib.mkOption {
        default = {default.manager = "ifstate";};
        example = {
          default.manager = "networkmanager";
          developer.manager = "ifstate";
        };
        description = ''
          Mode name to its network manager. 'default' is the parent
          configuration and must be present; every other name becomes
          'specialisation.<name>', switched to by rebooting.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.manager = lib.mkOption {
              type = lib.types.enum [
                "ifstate"
                "networkmanager"
              ];
              description = "The one network manager of this mode.";
            };
          }
        );
      };
    };

    perInstance = {
      instanceName,
      settings,
      machine,
      ...
    }: {
      nixosModule = {lib, ...}: {
        imports = [../../lib/modes.nix];

        assertions = [
          {
            assertion = settings.modes ? default;
            message = "modes/${instanceName}: machine '${machine.name}' declares modes without 'default'; 'default' is the configuration the machine boots into and must name its manager (N24)";
          }
          {
            assertion = lib.all (name: builtins.match "[a-z][a-z0-9-]*" name != null) (builtins.attrNames settings.modes);
            message = "modes/${instanceName}: machine '${machine.name}' has a mode name that is not lower-case letters, digits and '-': ${lib.concatStringsSep ", " (builtins.attrNames settings.modes)}; the name becomes a boot-menu entry (N24)";
          }
        ];

        clanServices.networking.modes = settings.modes;
      };
    };
  };

  # One mode list per machine: a second instance would define it twice.
  perMachine = {
    instances,
    machine,
    ...
  }: {
    nixosModule = {lib, ...}: let
      mine = lib.filterAttrs (_: instance: instance.roles.default.machines ? ${machine.name}) instances;
    in {
      assertions = [
        {
          assertion = lib.length (builtins.attrNames mine) <= 1;
          message = "modes: machine '${machine.name}' is in more than one modes instance (${lib.concatStringsSep ", " (builtins.attrNames mine)}); a machine has one mode list (N24)";
        }
      ];
    };
  };
}
