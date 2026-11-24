# The `nat-gateway` clan service (specs/gateway.md G1–G6, G23, G24):
# IPv4 reach for clan machines that have no IPv4.
#
#   gateway  a machine with a public IPv4: stateful NAT64 (Jool in a
#            namespace of its own), a source allowlist built from the
#            clients, a rate limit per source in two tiers, a health
#            check through the translator, and the health beacon
#            (`ipv4only.arpa` only).
#   client   an IPv6-only machine: a CLAT (Jool SIIT) that starts on the
#            first gateway, and a follower that moves it to a live one.
#
# DNS64 is not built (specs/gateway.md §14.1 point 3): every client runs
# a CLAT and uses plain IPv6 resolvers, which netif sets. The mechanism
# is lib/gateway; this file only resolves the inventory into it.
{clanLib, ...}: let
  names = import ../../lib/gateway/names.nix;

  tierType = lib: lib.types.enum ["default" "trusted"];

  limitOptions = lib: defaults: {
    newFlows = lib.mkOption {
      type = lib.types.ints.positive;
      default = defaults.newFlows;
      description = "New flows per second from one source address, above the burst.";
    };
    newFlowsBurst = lib.mkOption {
      type = lib.types.ints.positive;
      default = defaults.newFlowsBurst;
      description = "New flows one source may open at once.";
    };
    packets = lib.mkOption {
      type = lib.types.ints.positive;
      default = defaults.packets;
      description = "Packets per second from one source address, above the burst.";
    };
    packetsBurst = lib.mkOption {
      type = lib.types.ints.positive;
      default = defaults.packetsBurst;
      description = "Packets one source may send at once.";
    };
  };

  # A client's own numbers: each one that is set replaces its tier's
  # (specs/gateway.md §14.5 point 3).
  overrideOptions = lib:
    lib.genAttrs ["newFlows" "newFlowsBurst" "packets" "packetsBurst"] (name:
      lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "This client's `${name}` on every gateway; null: its tier's.";
      });

  # specs/gateway.md §14.1 point 4: the defaults chosen in round G7.
  defaultLimits = {
    default = {
      newFlows = 50;
      newFlowsBurst = 200;
      packets = 20000;
      packetsBurst = 40000;
    };
    trusted = {
      newFlows = 1000;
      newFlowsBurst = 4000;
      packets = 200000;
      packetsBurst = 400000;
    };
  };

  withoutLength = address: builtins.head (builtins.split "/" address);
  sortedNames = attrs: builtins.sort builtins.lessThan (builtins.attrNames attrs);
in {
  _class = "clan.service";
  manifest = {
    name = "nat-gateway";
    description = "IPv4 reach for IPv6-only clan machines: Jool NAT64 gateways and a CLAT on every client";
    readme = builtins.readFile ./README.md;
    categories = ["Network"];
    exports = {
      inputs = [
        "netif"
        "kube_cluster"
      ];
      out = ["nat_gateway"];
    };
  };

  roles = {
    gateway = {
      description = "A machine with a public IPv4 that translates for the clients (NAT64)";
      interface = {lib, ...}: {
        options = {
          uplinkZone = lib.mkOption {
            type = lib.types.str;
            default = "wan";
            description = "The netif zone whose links carry the public IPv4. The masquerade leaves through them.";
          };
          pool6 = lib.mkOption {
            type = lib.types.str;
            example = "2001:db8:a1:0:64::/96";
            description = "The gateway's own /96, inside a prefix routed to the machine (G4).";
          };
          address = lib.mkOption {
            type = lib.types.str;
            example = "2001:db8:a1::1";
            description = "An IPv6 address of the gateway that clients reach. The health beacon binds it (G24).";
          };
          health.targets = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "1.1.1.1"
              "8.8.8.8"
              "9.9.9.9"
            ];
            description = ''
              IPv4 addresses in different networks that the gateway
              pings through its own translator. The gateway withdraws
              its beacon only when every target fails for several rounds
              (specs/gateway.md §14.3). Give each gateway its own list.
            '';
          };
          # Set once for every gateway with the role's settings
          # (`roles.gateway.settings.limits`), or per gateway (§14.5 point 3).
          limits = {
            default = limitOptions lib defaultLimits.default;
            trusted = limitOptions lib defaultLimits.trusted;
          };
        };
      };

      perInstance = {
        instanceName,
        machine,
        roles,
        settings,
        exports,
        mkExports,
        ...
      }: {
        # SPEC.md D71: a gateway that is a kube node gets its uplink into
        # Cilium's `devices`, so its pods' IPv4 is masqueraded there
        exports = mkExports {
          nat_gateway = {
            gateway = true;
            inherit (settings) uplinkZone;
          };
        };
        nixosModule = {
          config,
          lib,
          ...
        }: let
          # Members of any kube cluster default to `trusted` (§14.1
          # point 4): every distro service exports kube_cluster facts per
          # member machine.
          clusterMembers = lib.unique (
            lib.mapAttrsToList (scope: _: (clanLib.parseScope scope).machineName) (
              lib.filterAttrs (_: value: (value.kube_cluster or null) != null) exports
            )
          );
          # The static IPv6 addresses netif declares on a client's uplink
          # zone. A SLAAC client names its addresses in `sources`.
          netifAddresses = name: zone:
            lib.concatMap (
              value:
                lib.concatMap (
                  link:
                    lib.optionals ((link.zone or null) == zone) (
                      map withoutLength (builtins.filter (lib.hasInfix ":") (link.addresses or []))
                    )
                ) (builtins.attrValues (value.netif.links or {}))
            ) (builtins.attrValues (
              clanLib.selectExports (scope: scope.serviceName == "netif" && scope.machineName == name) exports
            ));
          client = name: let
            s = roles.client.machines.${name}.settings;
          in {
            inherit name;
            overrides = lib.filterAttrs (_: value: value != null) s.limits;
            tier =
              if s.tier != null
              then s.tier
              else if lib.elem name clusterMembers
              then "trusted"
              else "default";
            sources = lib.unique ([s.clat.address] ++ s.sources ++ netifAddresses name s.uplinkZone);
          };
          clients = map client (sortedNames (roles.client.machines or {}));
          inTier = builtins.filter (c: c.overrides == {}) clients;
          tierSources = tier: lib.concatMap (c: c.sources) (builtins.filter (c: c.tier == tier) inTier);
          uplinks = config.clanServices.netif.zones.${settings.uplinkZone} or [];
        in {
          imports = [../../lib/gateway];
          assertions = [
            {
              assertion = uplinks != [];
              message = "nat-gateway/${instanceName}: machine '${machine.name}' has no netif link in zone '${settings.uplinkZone}' (uplinkZone)";
            }
          ];
          clanServices.gateway.nat64 = {
            enable = true;
            inherit (settings) pool6 address limits;
            inherit uplinks;
            allow = {
              default = tierSources "default";
              trusted = tierSources "trusted";
            };
            custom = map (c: {
              inherit (c) name sources;
              limits = settings.limits.${c.tier} // c.overrides;
            }) (builtins.filter (c: c.overrides != {}) clients);
            health.targets = settings.health.targets;
          };
        };
      };
    };

    client = {
      description = "An IPv6-only machine with a CLAT that follows a live gateway";
      interface = {lib, ...}: {
        options = {
          clat.address = lib.mkOption {
            type = lib.types.str;
            example = "2001:db8:c::c1a7";
            description = "The CLAT's own IPv6 address, from the machine's /64 (G23).";
          };
          uplinkZone = lib.mkOption {
            type = lib.types.str;
            default = "wan";
            description = "The netif zone of the machine's uplink. Its static IPv6 addresses join the gateways' allowlist.";
          };
          proxyNdp = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Answer for the CLAT address by proxy NDP on the uplink links (an advertised /64). Off when the provider routes the address to the machine.";
          };
          sources = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "More IPv6 sources (addresses or prefixes) of this machine for the gateways' allowlist, such as a SLAAC address.";
          };
          tier = lib.mkOption {
            type = lib.types.nullOr (tierType lib);
            default = null;
            description = "The gateways' rate-limit tier for this machine. null: `trusted` for a member of a kube cluster, else `default` (specs/gateway.md §14.1 point 4).";
          };
          limits = overrideOptions lib;
        };
      };

      perInstance = {
        instanceName,
        machine,
        roles,
        settings,
        mkExports,
        ...
      }: let
        gateways = sortedNames (roles.gateway.machines or {});
        gatewaySettings = name: roles.gateway.machines.${name}.settings;
      in {
        exports = mkExports {
          nat_gateway = {
            clat = {
              interface = names.clat.host;
              inherit (settings.clat) address;
            };
            inherit (settings) uplinkZone;
          };
        };
        nixosModule = {
          config,
          lib,
          ...
        }: {
          imports = [../../lib/gateway];
          assertions = [
            {
              assertion = gateways != [];
              message = "nat-gateway/${instanceName}: machine '${machine.name}' is a client of an instance without a gateway";
            }
          ];
          clanServices.gateway.clat = lib.mkIf (gateways != []) {
            enable = true;
            inherit (settings.clat) address;
            inherit ((gatewaySettings (builtins.head gateways))) pool6;
            beacons = map (name: (gatewaySettings name).address) gateways;
            proxyNdp = lib.optionals settings.proxyNdp (config.clanServices.netif.zones.${settings.uplinkZone} or []);
          };
        };
      };
    };
  };

  # One translator and one CLAT per machine: their links, namespace and
  # table have fixed names (lib/gateway/names.nix).
  perMachine = {
    instances,
    machine,
    ...
  }: {
    nixosModule = {lib, ...}: let
      inRole = role: builtins.attrNames (lib.filterAttrs (_: instance: instance.roles.${role}.machines or {} ? ${machine.name}) instances);
      gatewayIn = inRole "gateway";
      clientIn = inRole "client";
    in {
      assertions = [
        {
          assertion = lib.length gatewayIn <= 1;
          message = "nat-gateway: machine '${machine.name}' is a gateway in more than one instance (${lib.concatStringsSep ", " gatewayIn}); a machine runs one translator";
        }
        {
          assertion = lib.length clientIn <= 1;
          message = "nat-gateway: machine '${machine.name}' is a client in more than one instance (${lib.concatStringsSep ", " clientIn}); a machine runs one CLAT";
        }
        {
          assertion = gatewayIn == [] || clientIn == [];
          message = "nat-gateway: machine '${machine.name}' is both a gateway and a client; a gateway has its own IPv4 and needs no CLAT";
        }
      ];
    };
  };
}
