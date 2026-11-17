# Probe (2026-11-16, proof session): N24. A `modes` module
# that creates specialisations and a read-only mode option, against a base
# shaped like lib/ifstate.nix. No VM: `nix eval --json .#netifProbes.modes-eval`.
{
  nixpkgs,
  ifstateOverlay,
}: let
  lib = import "${nixpkgs}/lib";

  modesModule = {
    config,
    lib,
    ...
  }: let
    cfg = config.clanServices.networking;
  in {
    options.clanServices.networking = {
      modes = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options.manager = lib.mkOption {type = lib.types.enum ["ifstate" "networkmanager"];};
        });
        default.default.manager = "ifstate";
      };
      # Set only by the modes service, once per configuration.
      currentMode = lib.mkOption {
        type = lib.types.str;
        default = "default";
        internal = true;
      };
      mode = lib.mkOption {
        readOnly = true;
        type = lib.types.attrs;
      };
    };
    config = {
      clanServices.networking.mode = {
        name = cfg.currentMode;
        inherit (cfg.modes.${cfg.currentMode}) manager;
      };
      specialisation = lib.mkIf (cfg.currentMode == "default") (
        lib.mapAttrs (name: _: {configuration.clanServices.networking.currentMode = name;})
        (removeAttrs cfg.modes ["default"])
      );
    };
  };

  # The shared base, made conditional on the manager (today it is unconditional).
  baseModule = {
    config,
    lib,
    ...
  }: let
    ifstate = config.clanServices.networking.mode.manager == "ifstate";
  in {
    networking = {
      ifstate.enable = ifstate;
      interfaces = lib.mkForce {};
      useDHCP = lib.mkForce false;
      useNetworkd = lib.mkForce false;
      networkmanager.enable = lib.mkForce (!ifstate);
      ifstate.settings.interfaces = lib.mkIf ifstate {
        eth1.link = {
          kind = "physical";
          state = "up";
        };
      };
    };
    systemd.network.enable = lib.mkForce false;
    # A consumer gating on the mode name (what k3s or home would do).
    services.openssh.enable = lib.mkIf (config.clanServices.networking.mode.name == "kubernetes") true;
  };

  machine = modes:
    import "${nixpkgs}/nixos/lib/eval-config.nix" {
      system = "x86_64-linux";
      modules = [
        modesModule
        baseModule
        {
          nixpkgs.overlays = [ifstateOverlay];
          clanServices.networking.modes = modes;
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "/dev/x";
            fsType = "ext4";
          };
          system.stateVersion = "26.05";
        }
      ];
    };
  view = c: {
    inherit (c.clanServices.networking) mode;
    ifstate = c.networking.ifstate.enable;
    networkmanager = c.networking.networkmanager.enable;
    ssh = c.services.openssh.enable;
    children = builtins.attrNames c.specialisation;
    assertionsOk = builtins.all (a: a.assertion) c.assertions;
    failed = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  };
  report = modes: let
    m = machine modes;
  in
    {default = view m.config;}
    // lib.mapAttrs (_: s: view s.configuration) m.config.specialisation;
in {
  # Deck: NetworkManager by default, IfState in developer and kubernetes.
  deck = report {
    default.manager = "networkmanager";
    developer.manager = "ifstate";
    kubernetes.manager = "ifstate";
  };
  # U10 the other way: a server by default, a gaming mode beside it.
  server = report {
    default.manager = "ifstate";
    gaming.manager = "networkmanager";
  };
  # No entry at all.
  plain = report {default.manager = "ifstate";};
  # Both toplevels build as derivations (drvPath forces the whole system).
  deckToplevel =
    builtins.substring 0 20
    (machine {
      default.manager = "networkmanager";
      developer.manager = "ifstate";
    }).config.system.build.toplevel.drvPath;
}
