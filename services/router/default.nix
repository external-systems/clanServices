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
{clanLib, ...}: let
  cidr = lib: import ../../lib/kube-cluster/cidr.nix {inherit lib;};
in {
  _class = "clan.service";
  manifest = {
    name = "router";
    description = "The edge of a LAN: zones with default deny, NAT44, DHCPv4, router advertisements from the delegated prefix, a resolver per zone";
    readme = builtins.readFile ./README.md;
    categories = ["Network"];
    exports = {
      # the machine's fabric address, when it is on a fabric (G25)
      inputs = ["node_transport"];
      out = ["router"];
    };
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
              hostPorts = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "The zone may reach the ports this machine opens to everyone (`networking.firewall.allowedTCPPorts` and the like), such as a fabric's WireGuard ports. For a zone that holds other cluster nodes (G25).";
              };
              fabric = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "The zone's hosts may reach a fabric's addresses (members, pods) through this machine: its links are declared inside the fabric (`clan.networkFacts.fabricInside`, SPEC.md D73). Off: routed-fabric's guard drops every packet from the zone to a fabric address or into a fabric link.";
              };
            };
          });
        };
        wanPorts = {
          tcp = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [];
            example = [22];
            description = "TCP ports of the router itself that the WAN may reach. Empty: nothing inbound (invariant 3). Name 22 here when deploys arrive over the WAN.";
          };
          udp = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [];
            description = "UDP ports of the router itself that the WAN may reach, such as a fabric's WireGuard port towards a remote site.";
          };
        };
        # G25: the machine's links in no zone (a fabric's WireGuard
        # links, Cilium's links). The machine's own firewall judges
        # what stays among them. They always reach the WAN. A zone
        # exchanges flows with them only when it is named here.
        unzoned.source = lib.genAttrs ["ipv4" "ipv6"] (family:
          lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              The ${family} source address a zone's flow gets on the
              unzoned side. null: the machine's own fabric address when
              it is on a fabric (read from the fabric's export; the
              fabric's WireGuard accepts cluster addresses only), else
              the outgoing link's address (masquerade).
            '';
          });
        unzoned.zones = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = ["home"];
          description = ''
            Zones that exchange flows with the unzoned links, such as a
            cluster's pods and services on a router that is a node. Both
            directions: Cilium sends a pod's packets straight out of the
            zone's link, past the router's table, so the router cannot
            tell who opened a flow. Narrow it with a Cilium network
            policy.
          '';
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
      exports,
      mkExports,
      ...
    }: {
      # SPEC.md D71: a router that is a kube node gets its WAN into
      # Cilium's `devices`, so its pods are masqueraded there
      exports = mkExports {
        router = {
          inherit (settings) wanZone;
          zones = builtins.attrNames settings.zones;
        };
      };
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
        # The network of an address with its length, IPv6 printed short
        # (specs/gateway.md §17: the WAN's spoofed-source rule).
        network = address: let
          p = c.parse address;
          length = lib.last (lib.splitString "/" address);
          hex = map (group: lib.toLower (lib.toHexString group)) p.start;
          zeros = i:
            if i < 8 && builtins.elemAt p.start i == 0
            then 1 + zeros (i + 1)
            else 0;
          best =
            lib.foldl' (a: b:
              if b.length > a.length
              then b
              else a) {
              start = 0;
              length = 0;
            } (lib.genList (i: {
                start = i;
                length = zeros i;
              })
              8);
          v6 =
            if best.length < 2
            then lib.concatStringsSep ":" hex
            else lib.concatStringsSep ":" (lib.take best.start hex) + "::" + lib.concatStringsSep ":" (lib.drop (best.start + best.length) hex);
        in
          if p.family == 4
          then "${c.v4ToString p.start}/${length}"
          else "${v6}/${length}";
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
          inherit (zone) internet allowTo ssh hostPorts fabric;
          prefixes = map network (builtins.filter (lib.hasInfix "/") addresses);
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
        # G25: the machine's own address on a fabric, from the fabric's
        # export; an address the owner names wins
        fabric = builtins.filter (value: value != null) (
          map (value: value.node_transport or null) (
            builtins.attrValues (clanLib.selectExports (scope: scope.machineName == machine.name) exports)
          )
        );
        fabricAddress = family: lib.findFirst (address: address != null) null (map (value: value.${family} or null) fabric);
        source = lib.genAttrs ["ipv4" "ipv6"] (
          family:
            if settings.unzoned.source.${family} != null
            then settings.unzoned.source.${family}
            else fabricAddress family
        );
        # the hook advertises a /64 per zone (router-prefix.py)
        notA64 = builtins.filter (entry: lib.elem entry.interface zoneLinks && entry.length != 64) assigned;
        zoneLinks = lib.concatMap (name: netif.zones.${name} or []) (builtins.attrNames settings.zones);
        # a zone's addresses, DHCPv4 and resolver come from one link
        several = builtins.filter (name: lib.length (netif.zones.${name} or []) > 1) (builtins.attrNames settings.zones);
        # a LAN host must not configure the router by an advertisement
        listening = builtins.filter (link: netif.links.${link}.ra) zoneLinks;
        # the router's own IPv4 address inside the pool kea leases from
        inPool = builtins.filter (name: let
          zone = resolved.${name};
          first = builtins.head zone.interfaces;
          v4 = lib.findFirst (a: !(lib.hasInfix ":" a)) null (netif.links.${first} or {addresses = [];}).addresses;
          net = c.parse v4;
          own = (c.parse "${withoutLength v4}/32").start;
        in
          zone.dhcp4 != null && own >= net.start + (net.end - net.start + 1) / 2 && own < net.end) (builtins.attrNames resolved);
        resolved = lib.mapAttrs resolve (lib.filterAttrs (name: _: (netif.zones.${name} or []) != []) settings.zones);
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
            assertion = notA64 == [];
            message = "router/${instanceName}: netif assigns a delegated subnet that is not a /64 to the zone link(s) ${toString (map (entry: entry.interface) notA64)}; a zone is one /64";
          }
          {
            assertion = several == [];
            message = "router/${instanceName}: zone(s) ${toString several} have more than one netif link; a zone is one link (put the ports in a bridge)";
          }
          {
            assertion = listening == [];
            message = "router/${instanceName}: the zone link(s) ${toString listening} accept router advertisements; set 'ra = false' on the netif link (the router advertises there, it does not listen)";
          }
          {
            assertion = inPool == [];
            message = "router/${instanceName}: in zone(s) ${toString inPool} the router's own IPv4 address is in the upper half of the subnet, which is the DHCPv4 pool; give the router an address in the lower half";
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
          inherit (settings) domain pref64 servicePrefix wanPorts;
          unzoned = {
            inherit (settings.unzoned) zones;
            inherit source;
          };
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
