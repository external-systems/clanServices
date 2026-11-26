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
  cidr = lib: import ../../lib/kube-cluster/cidr.nix {inherit lib;};
  ip = lib: import ../../lib/ip.nix {inherit lib;};

  tierType = lib: lib.types.enum ["default" "trusted"];

  limitOptions = lib: defaults: {
    newFlows = lib.mkOption {
      type = lib.types.ints.positive;
      default = defaults.newFlows;
      description = "New flows per second from one source /64, above the burst.";
    };
    newFlowsBurst = lib.mkOption {
      type = lib.types.ints.positive;
      default = defaults.newFlowsBurst;
      description = "New flows one source /64 may open at once.";
    };
    packets = lib.mkOption {
      type = lib.types.ints.positive;
      default = defaults.packets;
      description = "Packets per second from one source /64, above the burst.";
    };
    packetsBurst = lib.mkOption {
      type = lib.types.ints.positive;
      default = defaults.packetsBurst;
      description = "Packets one source /64 may send at once.";
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

  # specs/gateway.md §14.1 point 4: the defaults chosen in round G7;
  # `trusted.newFlows` lowered in round G11 (§17): with one pool4
  # address, burst + rate x 300 s (Jool's UDP timeout) stays under the
  # 64 435 ports of a protocol, so one source cannot fill the pool.
  defaultLimits = {
    default = {
      newFlows = 50;
      newFlowsBurst = 200;
      packets = 20000;
      packetsBurst = 40000;
    };
    trusted = {
      newFlows = 200;
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
              Public IPv4 addresses in different networks that the
              gateway pings through its own translator, one round a
              second. A round is bad when fewer than `health.quorum`
              targets answer; the gateway withdraws its beacon when
              `health.down` of the last 2 x `health.down` rounds are bad
              (specs/gateway.md §14.5 point 4). Give each gateway its
              own list.
            '';
          };
          # specs/gateway.md §17 (G11): the numbers of §14.5 point 4
          health.quorum = lib.mkOption {
            type = lib.types.ints.positive;
            default = 2;
            description = "Targets that must answer for a round to be good (all of them when fewer are set).";
          };
          health.down = lib.mkOption {
            type = lib.types.ints.positive;
            default = 30;
            description = "The beacon is withdrawn when this many of the last 2 x `down` rounds are bad.";
          };
          health.up = lib.mkOption {
            type = lib.types.ints.positive;
            default = 120;
            description = "A withdrawn or new beacon comes up when the last `up` rounds hold at most 5 % bad ones.";
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

          # specs/gateway.md §17 (G6, G9): facts across machines
          c = cidr lib;
          i = ip lib;
          asCidr = source:
            if lib.hasInfix "/" source
            then source
            else "${source}/128";
          overlaps = a: b: let
            result = builtins.tryEval (c.overlap (asCidr a) (asCidr b));
          in
            result.success && result.value;
          # A client with its own limit, or a source in both tiers: a
          # packet would meet the first rule that names it, not its own
          group = client:
            if client.overrides != {}
            then "client ${client.name}"
            else "tier ${client.tier}";
          sharing = lib.concatLists (lib.imap0 (index: a:
            lib.concatMap (b:
              lib.optional (group a != group b && lib.any (x: lib.any (overlaps x) b.sources) a.sources)
              "${a.name} (${group a}) and ${b.name} (${group b})")
            (lib.drop (index + 1) clients))
          clients);
          others = lib.filter (name: name != machine.name) (sortedNames roles.gateway.machines);
          samePool = lib.filter (name: overlaps settings.pool6 roles.gateway.machines.${name}.settings.pool6) others;
          # the beacon binds the address: one netif declares here
          normal = address: let
            n = i.normalizeAddress address;
          in
            if n == null
            then address
            else n;
          ownAddresses = map normal (lib.concatMap (link: map i.addressFromCIDR (builtins.filter (lib.hasInfix ":") link.addresses)) (builtins.attrValues config.clanServices.netif.links));
          clatAddresses = map (client: normal roles.client.machines.${client.name}.settings.clat.address) clients;
          twice = lib.unique (lib.filter (address: lib.count (other: other == address) clatAddresses > 1) clatAddresses);
        in {
          imports = [../../lib/gateway];
          assertions = [
            {
              assertion = uplinks != [];
              message = "nat-gateway/${instanceName}: machine '${machine.name}' has no netif link in zone '${settings.uplinkZone}' (uplinkZone)";
            }
            {
              assertion = samePool == [];
              message = "nat-gateway/${instanceName}: gateway '${machine.name}' has the same pool6 as (or one that overlaps that of) ${toString samePool}; each gateway translates for its own /96 (specs/gateway.md G4)";
            }
            {
              assertion = lib.elem (normal settings.address) ownAddresses;
              message = "nat-gateway/${instanceName}: the address '${settings.address}' of gateway '${machine.name}' is not a static address netif declares on the machine; the beacon binds it (specs/gateway.md G24)";
            }
            {
              assertion = twice == [];
              message = "nat-gateway/${instanceName}: clients have the same clat.address ${toString twice}; the gateways tell clients apart by it";
            }
            {
              assertion = sharing == [];
              message = "nat-gateway/${instanceName}: the sources of ${lib.concatStringsSep "; " sharing} overlap: a client with its own limit, and each tier, needs sources of its own (specs/gateway.md §17, G6)";
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
            health = {inherit (settings.health) targets quorum down up;};
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
          clat.mtu = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            description = "MTU of the CLAT's IPv4 default route. null: the smallest MTU netif sets on the uplink zone's links (1500 when none is set) less 20, the growth of a packet from IPv4 to IPv6 (specs/gateway.md §17, G12).";
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
        }: let
          netif = config.clanServices.netif;
          uplinkMtus = lib.filter (mtu: mtu != null) (map (link: (netif.links.${link} or {mtu = null;}).mtu) (netif.zones.${settings.uplinkZone} or []));
          uplinkMtu =
            if uplinkMtus == []
            then 1500
            else lib.foldl' lib.min (builtins.head uplinkMtus) uplinkMtus;
        in {
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
            beacons = map (name: {inherit ((gatewaySettings name)) address pool6;}) gateways;
            proxyNdp = lib.optionals settings.proxyNdp (netif.zones.${settings.uplinkZone} or []);
            mtu =
              if settings.clat.mtu != null
              then settings.clat.mtu
              else uplinkMtu - 20;
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
