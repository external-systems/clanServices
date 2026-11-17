{ifstateOverlay}: {
  clanLib,
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  ip = import ../../lib/ip.nix {inherit lib;};

  # ---------------------------------------------------------------------
  # Link resolution (D50/D53): derive kind + interface names and the
  # effective per-link values (site/segment defaults merged with per-link
  # overrides). Shared by the perInstance renderer, the exports, and the
  # perMachine cross-instance assertions so all three cannot drift.
  # ---------------------------------------------------------------------

  linkIndicators = link: {
    vlan = link.vlan.id != null;
    bond = link.bond.members != [] || link.bond.mode != null;
    bridge = link.bridge.members != [];
  };

  resolveKind = link:
    if link.kind != null
    then link.kind
    else let
      ind = linkIndicators link;
    in
      if ind.vlan
      then "vlan"
      else if ind.bond
      then "bond"
      else if ind.bridge
      then "bridge"
      else "physical";

  # A physical link consumed as a bond/bridge member must carry no
  # addressing of its own: the bond/bridge owns the datapath.
  hasAddressing = link:
    link.static.ipv4
    != []
    || link.static.ipv6 != []
    || link.dhcp.ipv4 != null
    || link.dhcp.ipv6 != null
    || link.gateway.ipv4 != null
    || link.gateway.ipv6 != null
    || link.routes != []
    || link.nameservers != [];

  # Resolve every link of one machine in one instance. `site` is the
  # machine's merged top-level settings (the segment defaults).
  resolveLinks = site: links: let
    kinds = lib.mapAttrs (_: resolveKind) links;
    # Every bond/bridge member claim in this instance.
    memberClaims = lib.concatLists (
      lib.mapAttrsToList (
        logical: link: let
          kind = kinds.${logical};
        in
          lib.optionals (kind == "bond" || kind == "bridge") (
            map (member: {
              inherit member logical;
            }) (link.bond.members ++ link.bridge.members)
          )
      )
      links
    );
    resolveInterface = logical: link: let
      kind = kinds.${logical};
    in
      if link.interface != null
      then link.interface
      else if kind == "vlan"
      then let
        parent = link.vlan.parent;
      in
        if parent == null || !(links ? ${parent}) || kinds.${parent} == "vlan"
        then
          # Unresolvable parents are reported by the assertions below;
          # keep evaluation going so the failure is a clean assertion.
          "${logical}-unresolved"
        else "${resolveInterface parent links.${parent}}.${toString link.vlan.id}"
      else
        # bond/bridge derive their netdev name from the logical link
        # name; physical links must set 'interface' (asserted below).
        logical;
  in
    lib.mapAttrs (
      logical: link: let
        kind = kinds.${logical};
      in {
        inherit logical kind;
        interface = resolveInterface logical link;
        memberOf = let
          claims = lib.filter (claim: claim.member == logical) memberClaims;
        in
          if claims == []
          then null
          else (builtins.head claims).logical;
        members =
          if kind == "bond" || kind == "bridge"
          then link.bond.members ++ link.bridge.members
          else [];
        mtu =
          if link.mtu != null
          then link.mtu
          else site.mtu;
        dhcp4 =
          if link.dhcp.ipv4 != null
          then link.dhcp.ipv4
          else site.dhcp.ipv4;
        dhcp6 =
          if link.dhcp.ipv6 != null
          then link.dhcp.ipv6
          else site.dhcp.ipv6;
        static4 = link.static.ipv4;
        static6 = link.static.ipv6;
        gateway4 =
          if link.gateway.ipv4 != null
          then link.gateway.ipv4
          else site.gateway.ipv4;
        gateway6 =
          if link.gateway.ipv6 != null
          then link.gateway.ipv6
          else site.gateway.ipv6;
        inherit (link.gateway) onLink;
        nameservers =
          if link.nameservers != []
          then link.nameservers
          else site.nameservers;
        trust =
          if link.firewall.trust != null
          then link.firewall.trust
          else if site.firewall.trust != null
          then site.firewall.trust
          else false;
        inherit (link) zone;
        inherit
          (link)
          routes
          ra
          endpoint
          ;
        policy = link.routingPolicy;
        default4 =
          if link.defaultRoute.ipv4 != null
          then link.defaultRoute.ipv4
          else site.defaultRoute.ipv4;
        default6 =
          if link.defaultRoute.ipv6 != null
          then link.defaultRoute.ipv6
          else site.defaultRoute.ipv6;
        inherit (link.dhcp) prefixDelegation;
        requiredForOnline =
          if link.requiredForOnline != null
          then link.requiredForOnline
          else true;
      }
    )
    links;

  # Default-route ownership per address family (N21): the link may own
  # the main-table default ('defaultRoute') and has a source for one. The
  # sources are a static gateway outside a policy table, a DHCPv4 lease,
  # and a router advertisement. A bond or bridge member carries no
  # addressing, so it is never a source.
  v4Default = r:
    r.memberOf == null && r.default4 && (r.dhcp4 || (r.gateway4 != null && r.policy.table == null));
  v6Default = r:
    r.memberOf == null && r.default6 && (r.ra || (r.gateway6 != null && r.policy.table == null));

  # IPv4/IPv6 split helpers for export facts and endpoint selection.
  # Exported endpoints are bare host addresses: static inventory values
  # carry prefix lengths that must be stripped before dialing.
  isV6 = addr: lib.hasInfix ":" addr;
  stripPrefix = addr: builtins.head (lib.splitString "/" addr);
  mapOrNull = f: x:
    if x == null
    then null
    else f x;
  firstV4 = addrs: mapOrNull stripPrefix (lib.findFirst (addr: !isV6 addr) null addrs);
  firstV6 = addrs: mapOrNull stripPrefix (lib.findFirst isV6 null addrs);

  # Endpoint discovery (D47/D51): explicit endpoint wins, then ordered
  # peer exports (endpointSources), like wireguard-mesh.
  resolveHostValue = hostItem:
    hostItem.plain or (
      if hostItem ? var
      then clanLib.getPublicValue (hostItem.var // {default = "";})
      else throw "netif: unknown peer host value: ${builtins.toJSON hostItem}"
    );

  resolveEndpoint = {
    exports,
    sources,
    machineName,
  }: let
    hostsForSource = source: let
      matches = lib.attrValues (
        clanLib.selectExports (
          scope:
            scope.serviceName
            == source.service
            && scope.instanceName == source.instance
            && scope.machineName == machineName
        )
        exports
      );
    in
      lib.concatMap (value: value.peer.hosts or []) matches;
    values = lib.filter (value: value != "" && value != null) (
      map (host: lib.trim (resolveHostValue host)) (lib.concatMap hostsForSource sources)
    );
  in
    if values == []
    then null
    else builtins.head values;

  linkOptions = {
    interface = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Physical interface name. Required for physical links; derived
        for VLAN children ('<parent>.<id>') and bond/bridge netdevs
        (the logical link name) when null.
      '';
      example = "enp1s0f0np0";
    };
    match.mac = mkOption {
      type = types.nullOr (types.strMatching "([0-9a-f]{2}:){5}[0-9a-f]{2}");
      default = null;
      description = ''
        Find a physical NIC by its permanent MAC address (lower-case,
        colon-separated) instead of its kernel name. IfState renames
        the NIC to the logical link name, which must then be at most 15
        characters. Set exactly one of 'interface' and 'match.mac'.
      '';
      example = "52:54:00:12:01:02";
    };
    extraSettings = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      description = ''
        IfState interface settings merged into this link's rendered
        interface (checked passthrough). IfState's schema validates them
        at build time; setting a key netif already renders for the link
        is an eval error.
      '';
      example = {
        ethtool.features.rx-checksum = false;
      };
    };
    kind = mkOption {
      type = types.nullOr (
        types.enum [
          "physical"
          "vlan"
          "bond"
          "bridge"
        ]
      );
      default = null;
      description = ''
        Link kind. Null derives it: 'vlan.id' set → VLAN,
        'bond.members'/'bond.mode' set → bond, 'bridge.members' set →
        bridge, otherwise physical. Set it explicitly to declare an
        empty bridge (provider-MAC plumbing).
      '';
    };
    vlan = {
      id = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "802.1Q VLAN id (set together with 'vlan.parent').";
      };
      parent = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Logical name of the parent link in this instance (a physical,
          bond, or bridge link). IfState attaches the VLAN child to that
          parent's resolved Linux interface.
        '';
      };
    };
    bond = {
      mode = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Bond mode (IfState bond_mode); defaults to 802.3ad when the
          link is a bond. Setting a mode without members is an error.
        '';
        example = "active-backup";
      };
      members = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Logical names of physical links that are this bond's members.
          Member links must carry no addressing of their own.
        '';
      };
    };
    bridge = {
      members = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Logical names of physical links that are this bridge's members.
          Provider-MAC attachment for day-2 KubeVirt is bridge plumbing;
          members may be empty when interfaces attach at runtime.
        '';
      };
    };
    static = {
      ipv4 = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Static IPv4 addresses with prefix length ('192.0.2.10/24').";
      };
      ipv6 = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Static IPv6 addresses with prefix length ('2001:db8::10/64').";
      };
    };
    dhcp = {
      ipv4 = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          DHCPv4 on this link (dynamic address, default route, and DNS
          from the lease). Null inherits the segment default.
        '';
      };
      ipv6 = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "DHCPv6 on this link. Null inherits the segment default.";
      };
      prefixDelegation = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Ask the DHCPv6 server on this link for a delegated prefix
            (needs 'dhcp.ipv6'). The prefix exists only at runtime;
            netif never writes it into the configuration.
          '';
        };
        hint = mkOption {
          type = types.ints.between 48 64;
          default = 56;
          description = "Requested length of the delegated prefix.";
        };
        assign = mkOption {
          type = types.listOf (
            types.submodule {
              options = {
                instance = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "netif instance of the target link; null means this instance.";
                };
                link = mkOption {
                  type = types.str;
                  description = "Logical name of the link that gets a subnet of the delegated prefix.";
                };
                subnet = mkOption {
                  type = types.ints.unsigned;
                  description = "Subnet id inside the delegated prefix.";
                };
                length = mkOption {
                  type = types.ints.between 48 64;
                  default = 64;
                  description = "Prefix length assigned to the target link.";
                };
              };
            }
          );
          default = [];
          description = "Links of this machine that each get one subnet of the delegated prefix.";
        };
      };
    };
    requiredForOnline = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = ''
        Whether 'network-online.target' waits for a DHCP address on this
        link (up to 'clanServices.netif.onlineTimeout' seconds). Null
        means yes for a DHCP link. Static links never delay "online".
      '';
    };
    ra = mkOption {
      type = types.bool;
      default = true;
      description = "Accept IPv6 router advertisements on this link (IfState ipv6.accept_ra/autoconf).";
    };
    defaultRoute = {
      ipv4 = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Whether this link may install a main-table IPv4 default route,
          from a static gateway or a DHCPv4 lease. With false the lease,
          its address and its classless routes stay, and the router
          option is dropped (dhcpcd 'nogateway'); a static gateway is
          still used by the link's routes and policy table. Null inherits
          the segment default (true). One link per machine may own the
          default (specs/netif.md N21).
        '';
      };
      ipv6 = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Whether this link may install a main-table IPv6 default route,
          from a static gateway or a router advertisement. With false,
          advertisements still give prefixes and addresses, and no
          default router ('accept_ra_defrtr = 0'). Null inherits the
          segment default (true). Every link with 'ra = true' is a source
          of a default, so on a machine with several links all but one
          set this to false, or 'ra = false' (specs/netif.md N21).
        '';
      };
    };
    gateway = {
      ipv4 = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          IPv4 default gateway for this link's segment (also rendered as
          an on-link gateway route with 'gateway.onLink'). Null inherits
          the segment default.
        '';
      };
      ipv6 = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          IPv6 default gateway for this link's segment (often a
          link-local address). Null inherits the segment default.
        '';
      };
      onLink = mkOption {
        type = types.bool;
        default = false;
        description = ''
          The gateway is not on any connected subnet of this link
          (rendered with onlink = true, e.g. a /32 on an L3-only
          segment).
        '';
      };
    };
    mtu = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Per-link MTU; null inherits the segment default.";
    };
    nameservers = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        DNS servers for this link, set on the link in systemd-resolved
        by 'netif-dns.service'. When empty, the segment default
        'nameservers' apply. DHCP leases add their own servers.
      '';
    };
    routes = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            destination = mkOption {
              type = types.str;
              description = "Route destination CIDR.";
              example = "10.20.0.0/24";
            };
            gateway = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Route gateway (null for a directly connected route).";
            };
            onLink = mkOption {
              type = types.bool;
              default = false;
              description = "Render the route gateway with onlink = true.";
            };
          };
        }
      );
      default = [];
      description = "Static routes on this link (main table unless 'routingPolicy.table' is set).";
    };
    routingPolicy = {
      table = mkOption {
        type = types.nullOr types.ints.u32;
        default = null;
        description = ''
          Underlay policy-routing table for this link (netif owns underlay
          policy routing; routed-fabric owns fabric policy, D53). Null =
          no policy routing; gateways land in the main table. Kernel and
          Cilium tables {0,200,201,253,254,255,2004,2005} are reserved.
        '';
        example = 300;
      };
      from = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Source CIDRs selecting 'routingPolicy.table' ('ip rule from <cidr> lookup <table>').";
      };
      to = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Destination CIDRs selecting 'routingPolicy.table' (rendered at priority + 50).";
      };
      priority = mkOption {
        type = types.int;
        default = 100;
        description = "ip-rule priority for 'routingPolicy.from' rules.";
      };
    };
    firewall = {
      trust = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Add this link to networking.firewall.trustedInterfaces, which
          opens every port on it. Null inherits the segment default,
          and a link is untrusted unless one of the two says otherwise
          (specs/netif.md N19). Services open their own ports; trust a
          link only on a private segment.
        '';
      };
    };
    zone = mkOption {
      type = types.nullOr (types.strMatching "[a-z][a-z0-9-]*");
      default = null;
      example = "wan";
      description = ''
        A label for consumers such as a router module ('wan', 'lan',
        'mgmt'). netif gives it no meaning; it publishes it with the
        link's resolved interface name in
        'clanServices.networking.links', 'clanServices.netif.zones',
        'clan.networkFacts' and the export (specs/netif.md N10).
      '';
    };
    endpoint = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Export this link's static addresses as peer hosts for fabric
        endpoint discovery (routed-fabric WireGuard endpoints). Requires
        static addressing.
      '';
    };
  };

  # Per-link sanity assertions. `resolved` is the output of resolveLinks
  # for this machine+instance; `links` the raw link settings.
  linkAssertions = instanceName: machineName: links: resolved: let
    memberClaims = lib.concatLists (
      lib.mapAttrsToList (
        logical: r:
          map (member: {
            inherit logical member;
          })
          r.members
      ) (lib.filterAttrs (_: r: r.members != []) resolved)
    );
    claimCounts =
      lib.foldl' (
        acc: claim: acc // {${claim.member} = (acc.${claim.member} or 0) + 1;}
      ) {}
      memberClaims;
    duplicatedMembers = lib.attrNames (lib.filterAttrs (_: count: count > 1) claimCounts);
  in
    lib.concatLists (
      lib.mapAttrsToList (
        logical: link: let
          r = resolved.${logical};
          ind = linkIndicators link;
          indicatorCount = lib.count lib.id (lib.attrValues ind);
          inherit (r) memberOf;
          parent =
            if r.kind == "vlan" && link.vlan.parent != null && links ? ${link.vlan.parent}
            then resolved.${link.vlan.parent}
            else null;
        in [
          {
            assertion = indicatorCount <= 1;
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' sets more than one link kind indicator (vlan/bond/bridge); exactly one kind is allowed";
          }
          {
            assertion =
              link.kind
              == null
              || (link.kind == "vlan" && ind.vlan)
              || (link.kind == "bond" && (link.bond.members != [] || link.bond.mode != null))
              || link.kind == "bridge"
              || (link.kind == "physical" && indicatorCount == 0);
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' has kind '${link.kind}' that does not match its configuration (vlan.id/bond.members/bridge.members indicators)";
          }
          {
            assertion = r.kind != "physical" || (link.interface != null) != (link.match.mac != null);
            message = "netif/${instanceName}: physical link '${logical}' of machine '${machineName}' must set exactly one of 'interface' and 'match.mac'";
          }
          {
            assertion = link.match.mac == null || r.kind == "physical";
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' sets 'match.mac' but is not a physical link";
          }
          {
            assertion = link.match.mac == null || lib.stringLength logical <= 15;
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' uses 'match.mac', so its logical name becomes the interface name and must be at most 15 characters";
          }
          {
            assertion = r.kind != "vlan" || (link.vlan.id != null && link.vlan.id >= 0 && link.vlan.id <= 4094);
            message = "netif/${instanceName}: VLAN link '${logical}' of machine '${machineName}' must set 'vlan.id' between 0 and 4094";
          }
          {
            assertion =
              r.kind
              != "vlan"
              || (
                link.vlan.parent
                != null
                && links ? ${link.vlan.parent}
                && parent.kind != "vlan"
                && parent.memberOf == null
              );
            message = "netif/${instanceName}: VLAN link '${logical}' of machine '${machineName}' must name an existing physical, bond, or bridge 'vlan.parent' link in instance '${instanceName}'";
          }
          {
            assertion = r.kind != "bond" || r.members != [];
            message = "netif/${instanceName}: bond link '${logical}' of machine '${machineName}' must declare at least one 'bond.members' entry";
          }
          {
            assertion =
              r.kind
              != "bond"
              || lib.all (member: links ? ${member} && resolved.${member}.kind == "physical") r.members;
            message = "netif/${instanceName}: bond link '${logical}' of machine '${machineName}' references a 'bond.members' entry that is not a physical link declared in instance '${instanceName}'";
          }
          {
            assertion =
              r.kind
              != "bridge"
              || lib.all (member: links ? ${member} && resolved.${member}.kind == "physical") r.members;
            message = "netif/${instanceName}: bridge link '${logical}' of machine '${machineName}' references a 'bridge.members' entry that is not a physical link declared in instance '${instanceName}'";
          }
          {
            assertion = memberOf == null || !hasAddressing link;
            message = "netif/${instanceName}: member link '${logical}' of machine '${machineName}' is consumed by '${memberOf}' and must not set addresses, DHCP, gateways, routes, or nameservers";
          }
          {
            assertion = !(lib.elem logical duplicatedMembers);
            message = "netif/${instanceName}: machine '${machineName}' claims physical link '${logical}' as a bond/bridge member more than once (a member belongs to exactly one bond or bridge)";
          }
          {
            assertion = !r.dhcp4 || r.static4 == [];
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' sets both 'dhcp.ipv4' and static IPv4 addresses; exactly one addressing mode per family is allowed";
          }
          {
            assertion = !r.dhcp6 || r.static6 == [];
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' sets both 'dhcp.ipv6' and static IPv6 addresses; exactly one addressing mode per family is allowed";
          }
          {
            assertion = !r.prefixDelegation.enable || r.dhcp6;
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' enables 'dhcp.prefixDelegation' without 'dhcp.ipv6 = true'; a prefix is delegated over DHCPv6 (N16)";
          }
          {
            assertion = r.prefixDelegation.enable || r.prefixDelegation.assign == [];
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' sets 'dhcp.prefixDelegation.assign' without 'dhcp.prefixDelegation.enable = true' (N16)";
          }
          {
            assertion = let
              ids = map (a: a.subnet) r.prefixDelegation.assign;
            in
              lib.length ids == lib.length (lib.unique ids);
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' assigns one subnet id of its delegated prefix twice; subnet ids are unique per delegating link (N16)";
          }
          {
            assertion = lib.all (a: a.length >= r.prefixDelegation.hint && a.subnet < ip.pow2 (a.length - r.prefixDelegation.hint)) r.prefixDelegation.assign;
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' assigns a subnet that does not fit in its delegated prefix: each 'subnet' must be below 2^(length - hint) (N16)";
          }
          {
            assertion = !r.endpoint || (r.static4 != [] || r.static6 != []);
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' sets 'endpoint = true' without static addresses; fabric endpoint discovery requires at least one static IPv4 or IPv6 address";
          }
          {
            assertion =
              builtins.match "[A-Za-z0-9_.:-]+" r.interface != null && lib.stringLength r.interface <= 15;
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' resolves to interface name '${r.interface}', which is invalid or exceeds the 15-character kernel limit; set an explicit shorter 'interface'";
          }
          {
            assertion = r.policy.table == null || !(lib.elem r.policy.table ip.reservedPolicyTables);
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' must not use reserved kernel/Cilium routingPolicy table ${toString r.policy.table} (reserved: 0,200,201,253,254,255,2004,2005)";
          }
          {
            assertion = r.policy.table == null || r.policy.from != [] || r.policy.to != [];
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' sets 'routingPolicy.table' without any 'routingPolicy.from' or 'routingPolicy.to' selector";
          }
          {
            assertion =
              r.policy.table
              == null
              || !lib.any (
                cidr:
                  lib.elem cidr [
                    "0.0.0.0/0"
                    "::/0"
                  ]
              ) (r.policy.from ++ r.policy.to);
            message = "netif/${instanceName}: link '${logical}' of machine '${machineName}' must not use default-route catch-alls (0.0.0.0/0, ::/0) in routingPolicy.from/to — the rule sits above main and matches every packet (blackhole, live-verified in the fleet lan service)";
          }
        ]
      )
      links
    );
in {
  _class = "clan.service";
  manifest = {
    name = "netif";
    description = "Inventory-owned core host networking: multi-link, multi-instance segments rendered with IfState";
    categories = ["Network"];
    readme = builtins.readFile ./README.md;
    exports = {
      inputs = ["peer"];
      out = [
        "networking"
        "peer"
        "netif"
      ];
    };
  };

  # Instance-scope networking priority: the direct underlay is tried
  # before VPN overlays (wireguard-mesh uses 1000, clan-core internet 2000).
  exports =
    lib.mapAttrs' (instanceName: _: {
      name = clanLib.buildScopeKey {
        inherit instanceName;
        serviceName = config.manifest.name;
      };
      value.networking.priority = 1100;
    })
    config.instances;

  roles.default = {
    description = "Machine attached to this network segment (one or more physical, VLAN, bond, or bridge links)";
    interface = _: {
      options = {
        endpoint = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "edge.example.net";
          description = ''
            Explicit externally reachable address of this machine,
            exported first in 'peer.hosts' and as the 'netif' export's
            endpoint. Use when a DNS name or stable public address is
            preferred over link addresses.
          '';
        };
        endpointSources = mkOption {
          type = types.listOf (
            types.submodule {
              options = {
                service = mkOption {
                  type = types.str;
                  description = "The exporting service's manifest name.";
                };
                instance = mkOption {
                  type = types.str;
                  description = "The exporting service instance name.";
                };
              };
            }
          );
          default = [];
          example = [
            {
              service = "netif";
              instance = "uplink-a";
            }
          ];
          description = ''
            Ordered export sources whose 'peer.hosts' values provide
            this machine's endpoint (first match wins). Use netif peer
            exports for automatic fabric endpoint selection with
            explicit per-machine overrides.
          '';
        };
        targetHost = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Export this machine as its own clan deploy target
            (clan.core.networking.targetHost). The address resolves from
            the explicit 'endpoint', then 'endpointSources', then the
            first endpoint-enabled link's static address. At most one
            netif instance per machine should set this.
          '';
        };
        targetUser = mkOption {
          type = types.str;
          default = "root";
          description = ''
            SSH user prefixed to the exported deploy target. The fleet
            sets "deploy" when the deploy key is authorized only on the
            deploy user.
          '';
        };
        mtu = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Segment-default MTU applied to links that do not set 'mtu'.";
        };
        nameservers = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Segment-default DNS servers applied to links that do not set 'nameservers'.";
        };
        dhcp = {
          ipv4 = mkOption {
            type = types.bool;
            default = false;
            description = "Segment default: acquire IPv4 addresses by DHCPv4.";
          };
          ipv6 = mkOption {
            type = types.bool;
            default = false;
            description = "Segment default: acquire IPv6 addresses by DHCPv6.";
          };
        };
        gateway = {
          ipv4 = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Segment-default IPv4 gateway applied to links that do not set 'gateway.ipv4'.";
          };
          ipv6 = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Segment-default IPv6 gateway applied to links that do not set 'gateway.ipv6'.";
          };
        };
        defaultRoute = {
          ipv4 = mkOption {
            type = types.bool;
            default = true;
            description = "Segment default for per-link 'defaultRoute.ipv4': false on a segment that never carries the host's IPv4 default route.";
          };
          ipv6 = mkOption {
            type = types.bool;
            default = true;
            description = "Segment default for per-link 'defaultRoute.ipv6': false on a segment that never carries the host's IPv6 default route.";
          };
        };
        firewall = {
          trust = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = ''
              Segment default for per-link 'firewall.trust'. Null means
              untrusted; set true on a private segment whose links may
              reach every port (specs/netif.md N19).
            '';
          };
        };
        links = mkOption {
          type = types.attrsOf (types.submodule {options = linkOptions;});
          default = {};
          description = ''
            Logical links of this machine in this segment. Attrset keys
            are unique per-machine logical names; physical links name
            their 'interface', VLAN children name a 'vlan.parent' link,
            and bonds/bridges name physical 'members'. A machine may
            join several netif instances (multi-NIC routers, public +
            private attachments, D53).
          '';
        };
      };
    };

    perInstance = {
      instanceName,
      settings,
      machine,
      exports,
      mkExports,
      ...
    }: let
      resolved = resolveLinks settings settings.links;

      machineEndpoint =
        if settings.endpoint != null
        then settings.endpoint
        else
          resolveEndpoint {
            inherit exports;
            sources = settings.endpointSources;
            machineName = machine.name;
          };

      # Endpoint-enabled links contribute their static addresses for
      # fabric endpoint discovery (routed-fabric dials these).
      linkHosts = lib.concatLists (
        lib.mapAttrsToList (
          _: r:
            lib.optionals r.endpoint (
              lib.optional (firstV4 r.static4 != null) {plain = firstV4 r.static4;}
              ++ lib.optional (firstV6 r.static6 != null) {plain = firstV6 r.static6;}
            )
        )
        resolved
      );
      hosts = lib.unique (
        lib.optional (machineEndpoint != null) {plain = machineEndpoint;} ++ linkHosts
      );

      # Deploy-target resolution: explicit endpoint, then
      # endpointSources, then the first (alphabetical) endpoint-enabled
      # link's static address (IPv4 preferred).
      targetHostAddr =
        if machineEndpoint != null
        then machineEndpoint
        else let
          endpointLinks = lib.attrValues (lib.filterAttrs (_: r: r.endpoint) resolved);
          first = lib.findFirst (_: true) null endpointLinks;
        in
          if first == null
          then null
          else if firstV4 first.static4 != null
          then firstV4 first.static4
          else firstV6 first.static6;

      targetHostValue =
        if targetHostAddr == null
        then null
        else if isV6 targetHostAddr
        then "${settings.targetUser}@[${targetHostAddr}]"
        else "${settings.targetUser}@${targetHostAddr}";

      mtus = lib.filter (mtu: mtu != null) (lib.catAttrs "mtu" (lib.attrValues resolved));
      minMtu =
        if mtus == []
        then null
        else
          builtins.foldl' (acc: m:
            if m < acc
            then m
            else acc) (builtins.head mtus)
          mtus;

      # The interface netif renders for one link, before extraSettings.
      mkIfstateBase = forwarding: logical: r: let
        link = settings.links.${logical};
      in
        {
          addresses = r.static4 ++ r.static6;
          link =
            {
              inherit (r) kind;
              state = "up";
            }
            // lib.optionalAttrs (r.mtu != null) {inherit (r) mtu;}
            // lib.optionalAttrs (r.memberOf != null) {
              master = resolved.${r.memberOf}.interface;
            }
            // lib.optionalAttrs (r.kind == "vlan") {
              link = resolved.${link.vlan.parent}.interface;
              vlan_id = link.vlan.id;
            }
            // lib.optionalAttrs (r.kind == "bond") {
              bond_mode =
                if link.bond.mode != null
                then link.bond.mode
                else "802.3ad";
              bond_miimon = 100;
            };
          sysctl.ipv6 = {
            accept_ra =
              if r.ra
              then
                if forwarding
                then 2
                else 1
              else 0;
            autoconf =
              if r.ra
              then 1
              else 0;
            # Prefixes and addresses from an RA, but no default router,
            # when the link may not own the IPv6 default (N21).
            accept_ra_defrtr =
              if r.ra && r.default6
              then 1
              else 0;
          };
        }
        // lib.optionalAttrs (link.match.mac != null) {
          identify.perm_address = link.match.mac;
        };

      mkIfstateInterfaces = forwarding:
        lib.mapAttrs' (
          logical: r:
            lib.nameValuePair r.interface (
              lib.recursiveUpdate (mkIfstateBase forwarding logical r) settings.links.${logical}.extraSettings
            )
        )
        resolved;

      # A path collides when it, or a prefix of it that is a leaf, is
      # already rendered.
      collides = base: path:
        lib.any (
          n: let
            prefix = lib.take n path;
          in
            lib.hasAttrByPath prefix base && (n == lib.length path || !builtins.isAttrs (lib.getAttrFromPath prefix base))
        ) (lib.range 1 (lib.length path));
      # Leaf paths of extraSettings that netif already renders.
      leafPaths = prefix: value:
        if builtins.isAttrs value && value != {}
        then lib.concatLists (lib.mapAttrsToList (key: leafPaths (prefix ++ [key])) value)
        else [prefix];
      extraSettingsCollisions = lib.concatLists (
        lib.mapAttrsToList (
          logical: r: let
            base = mkIfstateBase false logical r;
          in
            map (path: "${logical}: ${lib.concatStringsSep "." path}") (
              builtins.filter (collides base) (leafPaths [] settings.links.${logical}.extraSettings)
            )
        )
        resolved
      );

      # A main-table default carries netif's metric (N18); a default in
      # a policy table is alone there and needs none.
      mkIfstateRoutes = metric:
        lib.concatLists (
          lib.mapAttrsToList (
            _: r: let
              hasPolicy = r.policy.table != null;
              defaultVia = to: via:
                {
                  inherit to via;
                  dev = r.interface;
                }
                // (
                  if hasPolicy
                  then {table = r.policy.table;}
                  else {preference = metric;}
                )
                // lib.optionalAttrs r.onLink {onlink = true;};
              gatewayRoutes =
                lib.optional (!r.dhcp4 && r.gateway4 != null && (hasPolicy || r.default4)) (
                  defaultVia "0.0.0.0/0" r.gateway4
                )
                ++ lib.optional (r.gateway6 != null && (!r.dhcp6 || r.static6 != []) && (hasPolicy || r.default6)) (
                  defaultVia "::/0" r.gateway6
                );
              staticRoutes =
                map (
                  route:
                    {
                      to = route.destination;
                      dev = r.interface;
                    }
                    // lib.optionalAttrs (route.gateway != null) {via = route.gateway;}
                    // lib.optionalAttrs (route.gateway != null && (route.onLink || r.onLink)) {
                      onlink = true;
                    }
                )
                r.routes;
            in
              gatewayRoutes ++ staticRoutes
          )
          resolved
        );

      ifstateRules = lib.concatLists (
        lib.mapAttrsToList (
          _: r:
            lib.optionals (r.policy.table != null) (
              (lib.imap0 (i: cidr: {
                  from = cidr;
                  table = r.policy.table;
                  priority = r.policy.priority + i;
                })
                r.policy.from)
              ++ (lib.imap0 (i: cidr: {
                  to = cidr;
                  table = r.policy.table;
                  priority = r.policy.priority + 50 + i;
                })
                r.policy.to)
            )
        )
        resolved
      );

      exportedPrefixDelegation = r: {
        inherit (r.prefixDelegation) enable hint;
        assign =
          map (a: {
            instance =
              if a.instance == null
              then instanceName
              else a.instance;
            inherit (a) link subnet length;
          })
          r.prefixDelegation.assign;
        dynamic = true;
      };
      trustedInterfaces = lib.catAttrs "interface" (
        lib.attrValues (lib.filterAttrs (_: r: r.trust) resolved)
      );
    in {
      exports = mkExports {
        peer.user = settings.targetUser;
        peer.hosts = hosts;
        netif = {
          schemaVersion = 1;
          endpoint = machineEndpoint;
          mtu = minMtu;
          links =
            lib.mapAttrs (_: r: {
              inherit
                (r)
                kind
                interface
                mtu
                nameservers
                endpoint
                ra
                dhcp4
                dhcp6
                gateway4
                gateway6
                routes
                ;
              addresses = r.static4 ++ r.static6;
              gatewayInMain = v4Default r || v6Default r;
              defaultRoute = {
                ipv4 = v4Default r;
                ipv6 = v6Default r;
              };
              prefixDelegation = exportedPrefixDelegation r;
              inherit (r) zone;
              trusted = r.trust;
            })
            resolved;
        };
      };

      nixosModule = {
        config,
        lib,
        ...
      }: let
        forwarding = config.clan.networkFacts.forwarding;
        ifstateInterfaces = mkIfstateInterfaces forwarding;
        ifstateRoutes = mkIfstateRoutes config.clanServices.netif.routeMetric;
      in {
        imports = [../../lib/kube-cluster/network-facts.nix];

        assertions =
          [
            {
              assertion = !settings.targetHost || targetHostValue != null;
              message = "netif/${instanceName}: machine '${machine.name}' sets 'targetHost = true' but no deploy address resolves; set 'endpoint', matching 'endpointSources', or an endpoint-enabled link with static addresses";
            }
          ]
          ++ linkAssertions instanceName machine.name settings.links resolved
          ++ [
            {
              assertion = extraSettingsCollisions == [];
              message = "netif/${instanceName}: machine '${machine.name}' sets extraSettings that netif already renders: ${lib.concatStringsSep ", " extraSettingsCollisions}; use the link option instead";
            }
          ];

        networking = {
          ifstate.settings = {
            interfaces = ifstateInterfaces;
            routing = {
              routes = ifstateRoutes;
              rules = ifstateRules;
            };
          };
          nftables.enable = lib.mkDefault true;
          firewall.trustedInterfaces = trustedInterfaces;
        };

        clan = {
          core.networking.targetHost = lib.mkIf (settings.targetHost && targetHostValue != null) (
            lib.mkDefault targetHostValue
          );
          _networkFacts = {
            schemaVersion = 2;
            node.name = machine.name;
            netif.${instanceName} = {
              endpoint = machineEndpoint;
              mtu = minMtu;
              links =
                lib.mapAttrs (_: r: {
                  inherit
                    (r)
                    kind
                    interface
                    mtu
                    nameservers
                    endpoint
                    ra
                    dhcp4
                    dhcp6
                    gateway4
                    gateway6
                    routes
                    ;
                  addresses = r.static4 ++ r.static6;
                  gatewayInMain = v4Default r || v6Default r;
                  defaultRoute = {
                    ipv4 = v4Default r;
                    ipv6 = v6Default r;
                  };
                  prefixDelegation = exportedPrefixDelegation r;
                  routingPolicy = r.policy;
                  trusted = r.trust;
                  inherit (r) zone;
                })
                resolved;
            };
            graphs.underlay =
              lib.mapAttrsToList (_: r: {
                from = machine.name;
                to = r.interface;
                kind = "link";
              })
              resolved;
          };
        };
      };
    };
  };

  # Cross-instance coherence (D53): unique link ownership, one default
  # route per address family, and non-conflicting DNS.
  perMachine = {
    instances,
    machine,
    ...
  }: let
    memberships =
      lib.filterAttrs (
        _: instance: instance.roles ? default && instance.roles.default.machines ? ${machine.name}
      )
      instances;

    # instanceName -> resolved links of this machine in that instance.
    resolvedByInstance =
      lib.mapAttrs (
        _: instance: let
          settings = instance.roles.default.machines.${machine.name}.settings;
        in
          resolveLinks settings settings.links
      )
      memberships;

    allResolved = lib.concatLists (
      lib.mapAttrsToList (_: resolved: lib.attrValues resolved) resolvedByInstance
    );

    interfacesWithOwners = lib.concatLists (
      lib.mapAttrsToList (
        instanceName: resolved:
          map (r: {
            inherit (r) interface;
            inherit instanceName;
          }) (lib.attrValues resolved)
      )
      resolvedByInstance
    );
    interfaceClaimCounts =
      lib.foldl' (
        acc: o: acc // {${o.interface} = (acc.${o.interface} or 0) + 1;}
      ) {}
      interfacesWithOwners;
    interfaceDuplicates = lib.attrNames (lib.filterAttrs (_: count: count > 1) interfaceClaimCounts);

    v4Defaults = lib.filter v4Default allResolved;
    v6Defaults = lib.filter v6Default allResolved;

    policyTableClaims = lib.concatLists (
      lib.mapAttrsToList (
        instanceName: resolved:
          lib.concatMap (
            r:
              lib.optional (r.policy.table != null) {
                inherit instanceName;
                inherit (r) logical;
                value = r.policy.table;
              }
          ) (lib.attrValues resolved)
      )
      resolvedByInstance
    );
    rulePriorityClaims = lib.concatLists (
      lib.mapAttrsToList (
        instanceName: resolved:
          lib.concatMap (
            r:
              lib.optionals (r.policy.table != null) (
                map (priority: {
                  inherit instanceName;
                  inherit (r) logical;
                  value = priority;
                }) (
                  (lib.genList (i: r.policy.priority + i) (lib.length r.policy.from))
                  ++ (lib.genList (i: r.policy.priority + 50 + i) (lib.length r.policy.to))
                )
              )
          ) (lib.attrValues resolved)
      )
      resolvedByInstance
    );
    crossInstanceDuplicates = claims:
      lib.attrNames (
        lib.filterAttrs (
          _: entries: lib.length (lib.unique (map (entry: entry.instanceName) entries)) > 1
        ) (lib.groupBy (entry: toString entry.value) claims)
      );
    policyTableDuplicates = crossInstanceDuplicates policyTableClaims;
    rulePriorityDuplicates = crossInstanceDuplicates rulePriorityClaims;

    # Prefix delegation targets, resolved across instances (N16).
    pdClaims = lib.concatLists (
      lib.mapAttrsToList (
        instanceName: resolved:
          lib.concatMap (
            r:
              map (a: let
                targetInstance =
                  if a.instance == null
                  then instanceName
                  else a.instance;
                target = resolvedByInstance.${targetInstance}.${a.link} or null;
              in {
                from = "${instanceName}/${r.logical}";
                to = "${targetInstance}/${a.link}";
                exists = target != null;
                self = targetInstance == instanceName && a.link == r.logical;
                interface =
                  if target == null
                  then "unresolved"
                  else target.interface;
                inherit (a) subnet length;
              })
              r.prefixDelegation.assign
          ) (lib.attrValues resolved)
      )
      resolvedByInstance
    );
    pdMissing = map (c: "${c.from} -> ${c.to}") (lib.filter (c: !c.exists) pdClaims);
    pdSelf = map (c: c.from) (lib.filter (c: c.self) pdClaims);
    pdTwice = lib.attrNames (
      lib.filterAttrs (_: claims: lib.length (lib.unique (map (c: c.from) claims)) > 1) (lib.groupBy (c: c.to) pdClaims)
    );

    # What runs beside IfState (host.nix), keyed by interface name.
    hostLinks = lib.listToAttrs (
      lib.concatLists (
        lib.mapAttrsToList (
          instanceName: resolved:
            map (
              r:
                lib.nameValuePair r.interface {
                  instance = instanceName;
                  inherit
                    (r)
                    logical
                    dhcp4
                    dhcp6
                    nameservers
                    requiredForOnline
                    default4
                    kind
                    zone
                    ;
                  prefixDelegation = {
                    inherit (r.prefixDelegation) enable hint;
                    assign = map (c: {inherit (c) interface subnet length;}) (
                      lib.filter (c: c.from == "${instanceName}/${r.logical}") pdClaims
                    );
                  };
                }
            ) (lib.filter (r: r.memberOf == null) (lib.attrValues resolved))
        )
        resolvedByInstance
      )
    );
  in {
    nixosModule = _: {
      imports = [
        (import ../../lib/ifstate.nix {inherit ifstateOverlay;})
        ./host.nix
      ];

      clanServices.netif.links = hostLinks;

      assertions = [
        {
          assertion = interfaceDuplicates == [];
          message = "netif: machine '${machine.name}' has links resolving to the same interface across netif instances: ${lib.concatStringsSep ", " interfaceDuplicates} (a link is owned by exactly one instance, D53)";
        }
        {
          assertion = lib.length v4Defaults <= 1;
          message = "netif: machine '${machine.name}' may install more than one IPv4 default route (links: ${
            lib.concatStringsSep ", " (map (r: r.logical) v4Defaults)
          }); one link may own it: set 'defaultRoute.ipv4 = false' on the others (N21)";
        }
        {
          assertion = lib.length v6Defaults <= 1;
          message = "netif: machine '${machine.name}' may install more than one IPv6 default route (links: ${
            lib.concatStringsSep ", " (map (r: r.logical) v6Defaults)
          }); a link with 'ra = true' or a static IPv6 gateway is a source of a default. One link may own it: set 'defaultRoute.ipv6 = false' (or 'ra = false') on the others (N21)";
        }
        {
          assertion = pdMissing == [];
          message = "netif: machine '${machine.name}' assigns a delegated prefix to a link that does not exist on it: ${lib.concatStringsSep ", " pdMissing} (N16)";
        }
        {
          assertion = pdSelf == [];
          message = "netif: machine '${machine.name}' assigns a delegated prefix to the link that requests it: ${lib.concatStringsSep ", " pdSelf}; assign it to another link (N16)";
        }
        {
          assertion = pdTwice == [];
          message = "netif: machine '${machine.name}' has links that receive a delegated prefix from more than one link: ${lib.concatStringsSep ", " pdTwice} (N16)";
        }
        {
          assertion = policyTableDuplicates == [];
          message = "netif: machine '${machine.name}' has cross-instance routingPolicy table collisions: ${lib.concatStringsSep ", " policyTableDuplicates}";
        }
        {
          assertion = rulePriorityDuplicates == [];
          message = "netif: machine '${machine.name}' has cross-instance routingPolicy rule-priority collisions: ${lib.concatStringsSep ", " rulePriorityDuplicates}";
        }
      ];
    };
  };
}
