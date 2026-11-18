{
  module,
  netifModule,
  exportInterfaces,
  clanLib,
  lib,
  ...
}: let
  machineConfigs = lib.genAttrs ["deck" "server" "plain"] (_: {
    nixpkgs.hostPlatform = "x86_64-linux";
  });

  netif = {
    module.name = "netif";
    module.input = "self";
  };

  baseInventory = {
    instances = {
      modes = {
        module.name = "modes";
        module.input = "self";
        roles.default.machines = {
          # U1: NetworkManager by default, IfState in a developer mode.
          deck.settings.modes = {
            default.manager = "networkmanager";
            developer.manager = "ifstate";
          };
          # U10: a server by default, a gaming mode beside it.
          server.settings.modes = {
            default.manager = "ifstate";
            gaming.manager = "networkmanager";
          };
        };
      };
      # Wired links that exist in every mode.
      home =
        netif
        // {
          roles.default.machines = {
            deck.settings.links.eth = {
              interface = "enp1s0";
              dhcp.ipv4 = true;
            };
            server.settings.links.eth = {
              interface = "enp1s0";
              mtu = 1500;
              static.ipv4 = ["192.0.2.10/24"];
              gateway.ipv4 = "192.0.2.1";
              nameservers = ["192.0.2.53"];
              routes = [
                {
                  destination = "10.42.0.0/16";
                  gateway = "192.0.2.254";
                }
              ];
            };
            plain.settings.links.eth = {
              interface = "enp1s0";
              static.ipv4 = ["192.0.2.20/24"];
            };
          };
        };
      # Only an IfState mode can render this: scoped to it (N4).
      lab =
        netif
        // {
          roles.default.machines.deck.settings = {
            modes = ["developer"];
            defaultRoute.ipv6 = false;
            links = {
              trunk.interface = "enp2s0";
              lab10 = {
                vlan = {
                  id = 10;
                  parent = "trunk";
                };
                static.ipv4 = ["10.10.10.2/24"];
              };
            };
          };
        };
    };
  };

  mkEvaledWith = machines: inventory:
    clanLib.clan {
      self = {};
      directory = ./.;
      inherit exportInterfaces machines inventory;
      modules = {
        modes = module;
        netif = netifModule;
      };
    };
  mkEvaled = mkEvaledWith machineConfigs;
  machine = eval: name: eval.config.nixosConfigurations.${name}.config;

  evaled = mkEvaled baseInventory;
  deck = machine evaled "deck";
  deckDeveloper = deck.specialisation.developer.configuration;
  server = machine evaled "server";
  serverGaming = server.specialisation.gaming.configuration;
  plain = machine evaled "plain";

  # A hot-plugged wired link (N12): an owner and a DHCP client in the
  # IfState mode, nothing in the NetworkManager mode.
  hotplugDeck = patterns:
    machine (mkEvaledWith (
        machineConfigs
        // {
          deck = {
            nixpkgs.hostPlatform = "x86_64-linux";
            clanServices.netif.hotplug.interfaces = patterns;
          };
        }
      )
      baseInventory) "deck";
  dockDeck = hotplugDeck ["^enx"];
  hotplugView = config: {
    owner = config.clanServices.networking.owners.wired-hotplug.interfaces or [];
    unit = config.systemd.services ? "netif-hotplug@";
    udev = lib.hasInfix ''NAME=="enx*"'' config.services.udev.extraRules;
    unmanaged = lib.elem "interface-name:enx*" config.networking.networkmanager.unmanaged;
  };

  failedAssertion = config: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) config.assertions;
  # Only this repo's assertions: a bare test machine fails NixOS's own
  # (no root file system, no boot loader).
  ours = message: lib.any (needle: lib.hasInfix needle message) ["netif" "clanServices" "modes/"];
  clean = config: lib.all (item: item.assertion || !(ours item.message)) config.assertions;
  view = config: {
    inherit (config.clanServices.networking) mode;
    ifstate = config.networking.ifstate.enable;
    networkmanager = config.networking.networkmanager.enable;
    children = builtins.attrNames config.specialisation;
    clean = clean config;
  };

  unscopedDeck = machine (mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.lab.roles.default.machines.deck.settings.modes = lib.mkForce [];
    }
  )) "deck";
  unknownModeDeck = machine (mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.lab.roles.default.machines.deck.settings.modes = lib.mkForce ["kubernetes"];
    }
  )) "deck";
  noDefaultDeck = machine (mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.modes.roles.default.machines.deck.settings.modes = lib.mkForce {developer.manager = "ifstate";};
    }
  )) "deck";
  tailscaleDeck = machine (mkEvaledWith (
      machineConfigs
      // {
        deck = {
          nixpkgs.hostPlatform = "x86_64-linux";
          services.tailscale.enable = true;
          networking.wireless.iwd.enable = true;
        };
      }
    )
    baseInventory) "deck";
in {
  mechanism = {
    # One manager per configuration (N2); every mode but 'default' is a
    # specialisation, and nothing nests (N3, N24).
    test_deckModes = {
      expr = {
        default = view deck;
        developer = view deckDeveloper;
      };
      expected = {
        default = {
          mode = {
            name = "default";
            manager = "networkmanager";
          };
          ifstate = false;
          networkmanager = true;
          children = ["developer"];
          clean = true;
        };
        developer = {
          mode = {
            name = "developer";
            manager = "ifstate";
          };
          ifstate = true;
          networkmanager = false;
          children = [];
          clean = true;
        };
      };
    };
    test_serverModes = {
      expr = {
        default = view server;
        gaming = view serverGaming;
      };
      expected = {
        default = {
          mode = {
            name = "default";
            manager = "ifstate";
          };
          ifstate = true;
          networkmanager = false;
          children = ["gaming"];
          clean = true;
        };
        gaming = {
          mode = {
            name = "gaming";
            manager = "networkmanager";
          };
          ifstate = false;
          networkmanager = true;
          children = [];
          clean = true;
        };
      };
    };
    # A machine the modes service does not list has one IfState mode.
    test_noEntryIsOneIfstateMode = {
      expr = view plain;
      expected = {
        mode = {
          name = "default";
          manager = "ifstate";
        };
        ifstate = true;
        networkmanager = false;
        children = [];
        clean = true;
      };
    };
    test_defaultModeRequired = {
      expr = failedAssertion noDefaultDeck "declares modes without 'default'";
      expected = true;
    };
  };

  netifRendering = {
    test_hotplugOwnerOnlyInIfstateMode = {
      expr = {
        default = hotplugView dockDeck;
        developer = hotplugView dockDeck.specialisation.developer.configuration;
      };
      expected = {
        default = {
          owner = [];
          unit = false;
          udev = false;
          unmanaged = false;
        };
        developer = {
          owner = ["^enx"];
          unit = true;
          udev = true;
          unmanaged = false;
        };
      };
    };
    test_hotplugPatternMustBeAPrefix = {
      expr = failedAssertion (hotplugDeck ["enx.*"]).specialisation.developer.configuration "takes plain name prefixes";
      expected = true;
    };
    # A wired link netif does not declare sits behind netif's own (N18).
    test_networkManagerAdhocWiredMetric = {
      expr = deck.networking.networkmanager.settings.connection-netif-adhoc-wired;
      expected = {
        match-device = "type:ethernet";
        "ipv4.route-metric" = 200;
        "ipv6.route-metric" = 200;
      };
    };
    # A NetworkManager mode: one profile per plain wired link, iwd as
    # the Wi-Fi backend, and none of what runs beside IfState.
    test_networkManagerModeProfiles = {
      expr = {
        profiles = builtins.attrNames deck.networking.networkmanager.ensureProfiles.profiles;
        inherit (deck.networking.networkmanager.ensureProfiles.profiles.netif-enp1s0) connection ipv4;
        wifi = deck.networking.networkmanager.wifi.backend;
        dns = deck.networking.networkmanager.dns;
        noAutoDefault = deck.networking.networkmanager.settings.main.no-auto-default;
        inherit (deck.networking.networkmanager) unmanaged;
        resolved = deck.services.resolved.enable;
        besideIfstate = lib.filter (name: lib.hasPrefix "netif-" name || name == "ifstate") (builtins.attrNames deck.systemd.services);
        tools = lib.filter (lib.hasPrefix "netif-") (map lib.getName deck.environment.systemPackages);
      };
      expected = {
        profiles = ["netif-enp1s0"];
        connection = {
          id = "netif-enp1s0";
          type = "ethernet";
          interface-name = "enp1s0";
          autoconnect = "true";
          autoconnect-priority = "10";
        };
        ipv4 = {
          method = "auto";
          route-metric = "100";
          never-default = "false";
        };
        wifi = "iwd";
        dns = "systemd-resolved";
        # no automatic profile on netif's link; the developer mode's
        # trunk NIC is left alone
        noAutoDefault = "enp1s0";
        unmanaged = ["interface-name:enp2s0"];
        resolved = true;
        besideIfstate = [];
        tools = [];
      };
    };
    test_networkManagerStaticProfile = {
      expr = {
        inherit (serverGaming.networking.networkmanager.ensureProfiles.profiles.netif-enp1s0) ipv4 ethernet;
        v6 = serverGaming.networking.networkmanager.ensureProfiles.profiles.netif-enp1s0.ipv6.method;
      };
      expected = {
        ipv4 = {
          method = "manual";
          address1 = "192.0.2.10/24,192.0.2.1";
          route1 = "10.42.0.0/16,192.0.2.254";
          dns = "192.0.2.53;";
          route-metric = "100";
          never-default = "false";
        };
        ethernet.mtu = "1500";
        # router advertisements are accepted unless 'ra = false'
        v6 = "auto";
      };
    };
    # The IfState mode of the same machine: IfState, dhcpcd, the scoped
    # instance's VLAN, and no NetworkManager profile.
    test_ifstateModeOfTheSameMachine = {
      expr = {
        interfaces = builtins.attrNames deckDeveloper.networking.ifstate.settings.interfaces;
        dhcpcd = deckDeveloper.systemd.services ? netif-dhcpcd-enp1s0;
        guard = deckDeveloper.systemd.services ? netif-guard;
        links = builtins.attrNames deckDeveloper.clanServices.netif.links;
      };
      expected = {
        interfaces = [
          "enp1s0"
          "enp2s0"
          "enp2s0.10"
        ];
        dhcpcd = true;
        guard = true;
        links = [
          "enp1s0"
          "enp2s0"
          "enp2s0.10"
        ];
      };
    };
    # Mode scoping (N4): the scoped instance renders nothing in the
    # default mode, and its facts stay.
    test_scopedInstanceOnlyInItsMode = {
      expr = {
        defaultLinks = builtins.attrNames deck.clanServices.netif.links;
        defaultIfstate = builtins.attrNames deck.networking.ifstate.settings.interfaces;
        factsStay = builtins.attrNames deck.clan.networkFacts.netif;
      };
      expected = {
        defaultLinks = ["enp1s0"];
        defaultIfstate = ["enp1s0"];
        factsStay = [
          "home"
          "lab"
        ];
      };
    };
    # A VLAN in a NetworkManager mode is an error that says what to do.
    test_ifstateOnlyObjectsRejectedInNetworkManagerMode = {
      expr = {
        rejected = failedAssertion unscopedDeck "mode 'default' uses NetworkManager, which renders plain wired links only";
        names = failedAssertion unscopedDeck "enp2s0.10";
        developerFine = clean unscopedDeck.specialisation.developer.configuration;
      };
      expected = {
        rejected = true;
        names = true;
        developerFine = true;
      };
    };
    test_unknownModeRejected = {
      expr = failedAssertion unknownModeDeck "limits this instance to mode(s) it does not have: kubernetes";
      expected = true;
    };
    # Registry owners are unmanaged in a NetworkManager mode; iwd is
    # not, NetworkManager drives it (N2, N5).
    test_ownersUnmanagedInNetworkManagerMode = {
      expr = {
        default = tailscaleDeck.networking.networkmanager.unmanaged;
        developer = tailscaleDeck.specialisation.developer.configuration.networking.ifstate.settings.parameters.ignore.ifname;
        clean = clean tailscaleDeck;
      };
      expected = {
        default = [
          "interface-name:tailscale*"
          "interface-name:enp2s0" # the developer mode's NIC (N4)
        ];
        developer = [
          "^wl"
          "^tailscale"
        ];
        clean = true;
      };
    };
  };
}
