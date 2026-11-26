{lib}: let
  # A route set: `hosts` exact host routes (/32, /128), `vips` host
  # routes out of LB pool blocks, `pods` per-node pod blocks
  # ({ cidr; mask; }: the block and the length of one node's route,
  # kube_cluster network.podMaskSizeV4/V6), `services` ClusterIP host
  # routes, `extra` exact prefixes an adjacency carries on purpose
  # (adjacencies.<remote>.extraAllowedIPs).
  emptyRoutes = {
    hosts = [];
    vips = [];
    pods = [];
    services = [];
    extra = [];
  };

  isV6 = lib.hasInfix ":";

  byFamily = blocks: {
    v4 = builtins.filter (block: !(isV6 block)) blocks;
    v6 = builtins.filter isV6 blocks;
  };

  ofFamily = family: blocks:
    builtins.filter (
      block:
        if family == 4
        then !(isV6 block)
        else isV6 block
    )
    blocks;

  symbol = value: "rf_${builtins.substring 0 16 (builtins.hashString "sha256" value)}";

  # A fabric session past this many prefixes logs a warning and stays up
  # (`warning-only`): a session reset would take the node's loopback, its
  # API and etcd with it.
  routeLimit = 4096;

  hostLength = family:
    if family == 4
    then 32
    else 128;

  # The host routes of a set, apart: one prefix-list per distinct host
  # set, shared by every session that carries it (R10).
  hostEntries = {
    routes,
    family,
  }: let
    len = toString (hostLength family);
  in
    map (block: "${block} ge ${len} le ${len}") (ofFamily family routes.hosts);

  restEntries = {
    routes,
    family,
  }: let
    len = toString (hostLength family);
    pods = builtins.filter (pod: ofFamily family [pod.cidr] != []) routes.pods;
  in
    map (block: "${block} ge ${len} le ${len}") (ofFamily family routes.vips)
    ++ map (pod: "${pod.cidr} ge ${toString pod.mask} le ${toString pod.mask}") pods
    ++ map (block: "${block} ge ${len} le ${len}") (ofFamily family routes.services)
    ++ ofFamily family (routes.extra or []);

  prefixEntries = args: hostEntries args ++ restEntries args;

  command = family:
    if family == 4
    then "ip"
    else "ipv6";

  renderPrefixList = {
    name,
    entries,
    family,
  }:
    if entries == []
    then "${command family} prefix-list ${name} seq 5 deny any"
    else
      lib.concatStringsSep "\n" (
        lib.imap1 (
          index: entry: "${command family} prefix-list ${name} seq ${toString (index * 5)} permit ${entry}"
        )
        entries
      );

  mkPrefixList = {
    name,
    routes,
    family,
  }:
    renderPrefixList {
      inherit name family;
      entries = prefixEntries {inherit routes family;};
    };

  # A prefix-list named after what it holds: equal lists share one name
  # and are rendered once (mkConfig).
  sharedList = family: entries: {
    name = "rf_p${toString family}_${builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON entries))}";
    text = renderPrefixList {
      inherit family entries;
      name = "rf_p${toString family}_${builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON entries))}";
    };
  };

  setClauses = {
    family,
    nextHop ? null,
    noExport ? false,
  }:
    lib.optional (nextHop != null) " set ${
      if family == 4
      then "ip next-hop"
      else "ipv6 next-hop global"
    } ${nextHop}"
    ++ lib.optional noExport " set community no-export additive";

  mkRouteMap = {
    name,
    prefixList,
    family,
    nextHop ? null,
    # a leaf never passes on what it learned from the fabric: NO_EXPORT
    # keeps the route off every other (eBGP) session
    noExport ? false,
  }: ''
    route-map ${name} permit 10
     match ${command family} address prefix-list ${prefixList}
    ${lib.concatStringsSep "\n" (setClauses {inherit family nextHop noExport;})}
    exit
  '';

  # One direction of one session in one family: the host routes and the
  # rest in two shared prefix-lists, one route-map entry each.
  mkPolicy = {
    name,
    routes,
    family,
    noExport ? false,
  }: let
    hosts = hostEntries {inherit routes family;};
    rest = restEntries {inherit routes family;};
    lists = lib.optional (hosts != []) (sharedList family hosts) ++ lib.optional (rest != []) (sharedList family rest);
    used =
      if lists == []
      then [(sharedList family [])]
      else lists;
    sets = lib.concatStringsSep "\n" (setClauses {inherit family noExport;});
  in {
    lists = used;
    text = lib.concatStrings (
      lib.imap1 (index: list: ''
        route-map ${name} permit ${toString (index * 10)}
         match ${command family} address prefix-list ${list.name}
        ${sets}
        exit
      '')
      used
    );
  };

  # `timers connect` (10) outlasts `timers delayopen` (5): FRR 10.7.1
  # aborts when ConnectRetry expires while DelayOpen runs
  # (bgp_fsm.c bgp_connect_timer, "assertion (!connection->t_read)";
  # upstream-facts.md). Equal timers made that a race at every connect.
  mkNeighbor = {
    adjacency,
    localAsn,
  }: let
    name = symbol adjacency.key;
    policies = {
      in4 = mkPolicy {
        name = "${name}_rin4";
        routes = adjacency.import;
        family = 4;
        noExport = adjacency.leaf or false;
      };
      in6 = mkPolicy {
        name = "${name}_rin6";
        routes = adjacency.import;
        family = 6;
        noExport = adjacency.leaf or false;
      };
      out4 = mkPolicy {
        name = "${name}_rout4";
        routes = adjacency.export;
        family = 4;
      };
      out6 = mkPolicy {
        name = "${name}_rout6";
        routes = adjacency.export;
        family = 6;
      };
    };
    bgpTimers =
      if adjacency.timerProfile == "wan"
      then "10 30"
      else "3 9";
    mkAf = {
      family,
      peer,
      rmIn,
      rmOut,
    }: ''
      address-family ipv${toString family} unicast
       neighbor ${peer} activate
       neighbor ${peer} route-map ${rmIn} in
       neighbor ${peer} route-map ${rmOut} out
       neighbor ${peer} maximum-prefix ${toString routeLimit} warning-only
       ${lib.optionalString adjacency.nextHopSelf " neighbor ${peer} next-hop-self"}
      exit-address-family
    '';
  in {
    lists = lib.concatMap (policy: policy.lists) (builtins.attrValues policies);
    text = ''
      ${policies.in4.text}
      ${policies.in6.text}
      ${policies.out4.text}
      ${policies.out6.text}
      router bgp ${toString localAsn}
       neighbor ${adjacency.remote.ipv4} remote-as ${toString adjacency.remoteAsn}
       neighbor ${adjacency.remote.ipv4} description ${adjacency.key}
       neighbor ${adjacency.remote.ipv4} bfd
       neighbor ${adjacency.remote.ipv4} bfd profile ${adjacency.timerProfile}
       neighbor ${adjacency.remote.ipv4} bfd check-control-plane-failure
       neighbor ${adjacency.remote.ipv4} timers ${bgpTimers}
       neighbor ${adjacency.remote.ipv4} timers connect 10
       neighbor ${adjacency.remote.ipv4} timers delayopen 5
       neighbor ${adjacency.remote.ipv6} remote-as ${toString adjacency.remoteAsn}
       neighbor ${adjacency.remote.ipv6} description ${adjacency.key}
       neighbor ${adjacency.remote.ipv6} bfd
       neighbor ${adjacency.remote.ipv6} bfd profile ${adjacency.timerProfile}
       neighbor ${adjacency.remote.ipv6} bfd check-control-plane-failure
       neighbor ${adjacency.remote.ipv6} timers ${bgpTimers}
       neighbor ${adjacency.remote.ipv6} timers connect 10
       neighbor ${adjacency.remote.ipv6} timers delayopen 5
      ${mkAf {
        family = 4;
        peer = adjacency.remote.ipv4;
        rmIn = "${name}_rin4";
        rmOut = "${name}_rout4";
      }}
      ${mkAf {
        family = 6;
        peer = adjacency.remote.ipv6;
        rmIn = "${name}_rin6";
        rmOut = "${name}_rout6";
      }}
    '';
  };
  mkCilium = {
    localAsn,
    sourceAddresses,
    cluster,
    routes,
  }: let
    name = symbol "cilium:${cluster.name}";
    in4 = "${name}_in4";
    in6 = "${name}_in6";
    out4 = "${name}_out4";
    out6 = "${name}_out6";
    rmIn4 = "${name}_rin4";
    rmIn6 = "${name}_rin6";
    rmOut4 = "${name}_rout4";
    rmOut6 = "${name}_rout6";
  in ''
    ${mkPrefixList {
      name = in4;
      inherit routes;
      family = 4;
    }}
    ${mkPrefixList {
      name = in6;
      inherit routes;
      family = 6;
    }}
    ${mkPrefixList {
      name = out4;
      routes = emptyRoutes;
      family = 4;
    }}
    ${mkPrefixList {
      name = out6;
      routes = emptyRoutes;
      family = 6;
    }}
    ${mkRouteMap {
      name = rmIn4;
      prefixList = in4;
      family = 4;
      nextHop = sourceAddresses.ipv4;
    }}
    ${mkRouteMap {
      name = rmIn6;
      prefixList = in6;
      family = 6;
      nextHop = sourceAddresses.ipv6;
    }}
    ${mkRouteMap {
      name = rmOut4;
      prefixList = out4;
      family = 4;
    }}
    ${mkRouteMap {
      name = rmOut6;
      prefixList = out6;
      family = 6;
    }}
    router bgp ${toString localAsn}
     neighbor ::1 remote-as ${toString cluster.bgp.ciliumAsn}
     neighbor ::1 description cilium-${cluster.name}
     neighbor ::1 capability extended-nexthop
     neighbor ::1 timers 3 9
     neighbor ::1 timers connect 5
     address-family ipv4 unicast
      neighbor ::1 activate
      neighbor ::1 route-map ${rmIn4} in
      neighbor ::1 route-map ${rmOut4} out
      neighbor ::1 maximum-prefix ${toString routeLimit} warning-only
     exit-address-family
     address-family ipv6 unicast
      neighbor ::1 activate
      neighbor ::1 route-map ${rmIn6} in
      neighbor ::1 route-map ${rmOut6} out
      neighbor ::1 maximum-prefix ${toString routeLimit} warning-only
     exit-address-family
  '';
in rec {
  inherit
    byFamily
    emptyRoutes
    mkCilium
    mkNeighbor
    mkPrefixList
    mkRouteMap
    prefixEntries
    routeLimit
    symbol
    ;

  mergeRoutes = routes: {
    hosts = lib.unique (lib.concatMap (route: route.hosts) routes);
    vips = lib.unique (lib.concatMap (route: route.vips) routes);
    pods = lib.unique (lib.concatMap (route: route.pods) routes);
    services = lib.unique (lib.concatMap (route: route.services) routes);
    extra = lib.unique (lib.concatMap (route: route.extra or []) routes);
  };

  # Upstream sessions of a border (R9): out, the owned prefixes; in, only
  # what the peer's `acceptedPrefixes` names (nothing by default: the
  # fabric never needs an upstream's routes to reach its own space, and
  # its own space coming back from outside is a hijack). `ttlSecurity`
  # (GTSM, RFC 5082) when both ends set it.
  mkBorder = {
    localAsn,
    border,
  }: let
    families = byFamily border.ownedPrefixes;
    name = symbol "border:${toString localAsn}";
    mkFamily = {
      family,
      prefixes,
      peers,
    }: let
      suffix = toString family;
      length = hostLength family;
      list = "${name}_border${suffix}";
      routeMap = "${name}_border_map${suffix}";
      peerIn = peer: "${symbol "border-in:${peer.address}"}_in${suffix}";
    in
      lib.optionalString (peers != []) ''
        ${lib.concatStringsSep "\n" (
          lib.imap1 (
            index: prefix: "${command family} prefix-list ${list} seq ${toString (index * 5)} permit ${prefix} le ${toString length}"
          )
          prefixes
        )}
        route-map ${routeMap} permit 10
         match ${command family} address prefix-list ${list}
        exit
        ${lib.concatMapStringsSep "\n" (peer: ''
            ${renderPrefixList {
              name = peerIn peer;
              inherit family;
              entries = peer.acceptedPrefixes or [];
            }}
            route-map ${peerIn peer} permit 10
             match ${command family} address prefix-list ${peerIn peer}
            exit
            router bgp ${toString localAsn}
             neighbor ${peer.address} remote-as ${toString peer.asn}
             neighbor ${peer.address} description border-upstream
             neighbor ${peer.address} bfd
             neighbor ${peer.address} bfd profile wan
             neighbor ${peer.address} timers 10 30
             neighbor ${peer.address} timers connect 10
             neighbor ${peer.address} timers delayopen 5
             ${lib.optionalString (peer.ttlSecurity or false) "neighbor ${peer.address} ttl-security hops 1"}
             address-family ipv${suffix} unicast
              neighbor ${peer.address} activate
              neighbor ${peer.address} route-map ${peerIn peer} in
              neighbor ${peer.address} route-map ${routeMap} out
              neighbor ${peer.address} next-hop-self
              neighbor ${peer.address} maximum-prefix ${toString routeLimit} restart 10
             exit-address-family
          '')
          peers}
      '';
  in
    lib.optionalString (border != null) (
      mkFamily {
        family = 4;
        prefixes = families.v4;
        peers = builtins.filter (peer: !(isV6 peer.address)) border.upstreamPeers;
      }
      + mkFamily {
        family = 6;
        prefixes = families.v6;
        peers = builtins.filter (peer: isV6 peer.address) border.upstreamPeers;
      }
    );

  # Graceful restart (specs/gateway.md §16.3 point 2): a restart of bgpd
  # alone keeps this node's routes at its peers (they hold them as stale
  # for restart-time) and in its own kernel (zebra -r -K, set by
  # routed-fabric). A restart of all of FRR does not: bfdd goes too, and
  # `check-control-plane-failure` makes the peers drop the node at once,
  # as for a dead node (upstream-facts.md, FRR). A deploy reloads FRR
  # and restarts nothing (nixpkgs `reloadIfChanged`).
  mkConfig = {
    routerId,
    sourceAddresses,
    localAsn,
    adjacencies,
    networks ? [],
    border ? null,
    extraConfig ? "",
    maximumPaths ? 8,
  }: let
    familyNetworks = byFamily networks;
    neighbors = map (adjacency: mkNeighbor {inherit adjacency localAsn;}) adjacencies;
    lists = lib.attrValues (
      lib.listToAttrs (
        map (list: lib.nameValuePair list.name list.text) (lib.concatMap (neighbor: neighbor.lists) neighbors)
      )
    );
  in ''
    frr defaults datacenter
    allow-reserved-ranges
    bfd
     profile site
     !
     profile wan
      detect-multiplier 5
      receive-interval 1000
      transmit-interval 1000
     !
    !
    ip prefix-list rf_source4 seq 5 permit any
    ipv6 prefix-list rf_source6 seq 5 permit any
    route-map rf_source4 permit 10
     match ip address prefix-list rf_source4
     set src ${sourceAddresses.ipv4}
    exit
    route-map rf_source6 permit 10
     match ipv6 address prefix-list rf_source6
     set src ${sourceAddresses.ipv6}
    exit
    ip protocol bgp route-map rf_source4
    ipv6 protocol bgp route-map rf_source6
    ${lib.concatStringsSep "\n" lists}
    router bgp ${toString localAsn}
     bgp router-id ${routerId}
     bgp graceful-restart
     bgp graceful-restart preserve-fw-state
     bgp graceful-restart restart-time 60
     bgp graceful-restart stalepath-time 60
     bgp graceful-restart select-defer-time 0
     no bgp default ipv4-unicast
     bgp ebgp-requires-policy
     bgp bestpath as-path multipath-relax
     bgp allow-martian-nexthop
     use-underlays-nexthop-weight
     address-family ipv4 unicast
      ${lib.concatMapStringsSep "\n " (network: "network ${network}") familyNetworks.v4}
      maximum-paths ${toString maximumPaths}
     exit-address-family
     address-family ipv6 unicast
      ${lib.concatMapStringsSep "\n " (network: "network ${network}") familyNetworks.v6}
      maximum-paths ${toString maximumPaths}
     exit-address-family
    ${lib.concatMapStringsSep "\n" (neighbor: neighbor.text) neighbors}
    ${mkBorder {inherit localAsn border;}}
    ${extraConfig}
  '';
}
