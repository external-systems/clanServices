# The `router` clan service (specs/gateway.md G1, G8, G11, G12, G14,
# G15, G20, G22): the edge of a LAN with one WAN. Every device in a zone
# learns everything from DHCPv4 and router advertisements.
#
# netif owns the links (invariant 1). Each zone of this service is a
# netif zone label: the service reads the zone's links, their static
# addresses (the router's address in the zone, its resolver address)
# and the subnet id netif assigns from the delegated prefix (N16), so no
# fact is written twice. The mechanism is lib/gateway/router.nix.
#
# Frozen (§14.1 point 2), not built: IPv6-mostly (G9; `pref64` is only
# the advertisement), a second WAN (G16), several routers (G17), flow
# records (G19).
_: let
  cidr = lib: import ../../lib/kube-cluster/cidr.nix {inherit lib;};
in {
  _class = "clan.service";
  manifest = {
    name = "router";
    description = "The edge of a LAN: zones with default deny, NAT44, DHCPv4, router advertisements from the delegated prefix, a resolver per zone";
    readme = builtins.readFile ./README.md;
    categories = ["Network"];
  };

  roles.router = {
    description = "A machine that routes between its netif zones and one WAN";
    interface = {lib, ...}: {
      options = {
        wanZone = lib.mkOption {
          type = lib.types.str;
          default = "wan";
          description = "The netif zone of the WAN link. Exactly one link.";
        };
        zones = lib.mkOption {
          description = "LAN zones by netif zone label (G11). Default deny between them.";
          default = {};
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              internet = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "The zone may reach the WAN.";
              };
              allowTo = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                description = "Other zones this zone may open flows to. Replies pass.";
              };
              dhcp = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Serve DHCPv4 in the zone: the upper half of the zone's IPv4 subnet.";
              };
              ssh = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "The zone may reach the router's SSH (deploys).";
              };
            };
          });
        };
        domain = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "The search domain: DHCPv4 option 119 and DNSSL.";
        };
        pref64 = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "A NAT64 prefix to advertise (PREF64). Only the advertisement: IPv6-mostly is frozen (G9).";
        };
        dns = {
          upstream = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "tls://1.1.1.1"
              "tls://1.0.0.1"
              "tls://2606:4700:4700::1111"
            ];
            description = "Upstream resolvers. `tls://` ones are reached over TLS (G14).";
          };
          tlsServerName = lib.mkOption {
            type = lib.types.str;
            default = "cloudflare-dns.com";
            description = "The TLS name of the `tls://` upstreams.";
          };
          blocklist = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "A hosts file of blocked names (G14). The HaGeZi package is not in org-pkgs yet.";
          };
          records = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = "Static records: name to address.";
          };
        };
        servicePrefix = {
          subnet = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "The subnet id of the delegated prefix kept for Kubernetes Services (G20). No link gets it.";
          };
          stable = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "fd00:10:5::/64";
            description = "The stable /64 (of the ULA) the public service /64 is rewritten to (G20, `translated`).";
          };
          expose = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                address = lib.mkOption {
                  type = lib.types.str;
                  description = "A stable address of the service /64.";
                };
                protocol = lib.mkOption {type = lib.types.enum ["tcp" "udp"];};
                ports = lib.mkOption {type = lib.types.listOf lib.types.port;};
              };
            });
            default = [];
            description = "Pinholes from the WAN into the service /64 (invariant 7). Empty: none.";
          };
        };
      };
    };

    perInstance = {
      instanceName,
      machine,
      settings,
      ...
    }: {
      nixosModule = {
        config,
        lib,
        ...
      }: let
        c = cidr lib;
        netif = config.clanServices.netif;
        wanLinks = netif.zones.${settings.wanZone} or [];
        wan = builtins.head wanLinks;
        assigned = (netif.links.${wan} or {prefixDelegation.assign = [];}).prefixDelegation.assign;
        withoutLength = address: builtins.head (lib.splitString "/" address);
        resolve = name: zone: let
          links = netif.zones.${name} or [];
          first = builtins.head links;
          inherit ((netif.links.${first} or {addresses = [];})) addresses;
          v4 = lib.findFirst (a: !(lib.hasInfix ":" a)) null addresses;
          v6 = lib.findFirst (a: lib.hasInfix ":" a) null addresses;
          parsed = c.parse v4;
          size = parsed.end - parsed.start + 1;
          length = lib.last (lib.splitString "/" v4);
          ids = map (entry: entry.subnet) (builtins.filter (entry: entry.interface == first) assigned);
        in {
          interfaces = links;
          inherit (zone) internet allowTo ssh;
          subnet =
            if ids == []
            then null
            else builtins.head ids;
          dns = {
            ipv4 =
              if v4 == null
              then null
              else withoutLength v4;
            ipv6 =
              if v6 == null
              then null
              else withoutLength v6;
          };
          dhcp4 =
            if zone.dhcp && v4 != null
            then {
              subnet = "${c.v4ToString parsed.start}/${length}";
              router = withoutLength v4;
              pool = "${c.v4ToString (parsed.start + size / 2)} - ${c.v4ToString (parsed.end - 1)}";
            }
            else null;
        };
        missing = builtins.filter (name: (netif.zones.${name} or []) == []) (builtins.attrNames settings.zones);
        tls = lib.any (lib.hasPrefix "tls://") settings.dns.upstream;
      in {
        imports = [../../lib/gateway];
        assertions = [
          {
            assertion = lib.length wanLinks == 1;
            message = "router/${instanceName}: machine '${machine.name}' needs exactly one netif link in zone '${settings.wanZone}'; got ${toString wanLinks} (one WAN; a second is G16, frozen)";
          }
          {
            assertion = missing == [];
            message = "router/${instanceName}: machine '${machine.name}' has no netif link in zone(s) ${toString missing}";
          }
          {
            # G20: no link gets the service prefix (the role of netif N16 `reserve`)
            assertion = settings.servicePrefix.subnet == null || !(lib.elem settings.servicePrefix.subnet (map (entry: entry.subnet) assigned));
            message = "router/${instanceName}: servicePrefix.subnet ${toString settings.servicePrefix.subnet} is also assigned to a link by netif's prefixDelegation.assign (specs/gateway.md G20)";
          }
          {
            assertion = !(settings.zones ? ${settings.wanZone});
            message = "router/${instanceName}: the WAN zone '${settings.wanZone}' is not a LAN zone";
          }
        ];
        clanServices.gateway.router = lib.mkIf (lib.length wanLinks == 1 && missing == []) {
          enable = true;
          inherit wan;
          zones = lib.mapAttrs resolve settings.zones;
          inherit (settings) domain pref64 servicePrefix;
          dns = {
            inherit (settings.dns) blocklist records upstream;
            forwardOptions = lib.optional tls "tls_servername ${settings.dns.tlsServerName}";
          };
        };
      };
    };
  };

  # One router per machine: its units, tables and runtime files have
  # fixed names.
  perMachine = {
    instances,
    machine,
    ...
  }: {
    nixosModule = {lib, ...}: let
      mine = builtins.attrNames (lib.filterAttrs (_: instance: instance.roles.router.machines or {} ? ${machine.name}) instances);
    in {
      assertions = [
        {
          assertion = lib.length mine <= 1;
          message = "router: machine '${machine.name}' is a router in more than one instance (${lib.concatStringsSep ", " mine})";
        }
      ];
    };
  };
}
