{lib}: let
  emptyRoutes = {
    hosts = [];
    vips = [];
    pods = [];
    services = [];
  };

  byFamily = blocks: {
    v4 = builtins.filter (block: !(lib.hasInfix ":" block)) blocks;
    v6 = builtins.filter (lib.hasInfix ":") blocks;
  };

  symbol = value: "rf_${builtins.substring 0 16 (builtins.hashString "sha256" value)}";

  prefixEntries = {
    routes,
    family,
  }: let
    len =
      if family == 4
      then 32
      else 128;
    podLen =
      if family == 4
      then 24
      else 64;
    blocks = byFamily routes.vips;
    pods = byFamily routes.pods;
    services = byFamily routes.services;
    hosts = byFamily routes.hosts;
    selected =
      if family == 4
      then blocks.v4
      else blocks.v6;
    selectedPods =
      if family == 4
      then pods.v4
      else pods.v6;
    selectedServices =
      if family == 4
      then services.v4
      else services.v6;
    selectedHosts =
      if family == 4
      then hosts.v4
      else hosts.v6;
    exact = map (block: "${block} ge ${toString len} le ${toString len}") selected;
    podEntries = map (block: "${block} ge ${toString podLen} le ${toString podLen}") selectedPods;
    serviceEntries = map (block: "${block} ge ${toString len} le ${toString len}") selectedServices;
    hostEntries = map (block: "${block} ge ${toString len} le ${toString len}") selectedHosts;
  in
    hostEntries ++ exact ++ podEntries ++ serviceEntries;

  mkPrefixList = {
    name,
    routes,
    family,
  }: let
    entries = prefixEntries {inherit routes family;};
    command =
      if family == 4
      then "ip"
      else "ipv6";
  in
    if entries == []
    then "${command} prefix-list ${name} seq 5 deny any"
    else
      lib.concatStringsSep "\n" (
        lib.imap1 (
          index: entry: "${command} prefix-list ${name} seq ${toString (index * 5)} permit ${entry}"
        )
        entries
      );

  mkRouteMap = {
    name,
    prefixList,
    family,
    nextHop ? null,
  }: ''
    route-map ${name} permit 10
     match ${
      if family == 4
      then "ip"
      else "ipv6"
    } address prefix-list ${prefixList}
    ${
      lib.optionalString (nextHop != null)
      " set ${
        if family == 4
        then "ip next-hop"
        else "ipv6 next-hop global"
      } ${nextHop}"
    }
    exit
  '';

  mkNeighbor = {
    adjacency,
    localAsn,
  }: let
    name = symbol adjacency.key;
    in4 = "${name}_in4";
    in6 = "${name}_in6";
    out4 = "${name}_out4";
    out6 = "${name}_out6";
    rmIn4 = "${name}_rin4";
    rmIn6 = "${name}_rin6";
    rmOut4 = "${name}_rout4";
    rmOut6 = "${name}_rout6";
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
       neighbor ${peer} maximum-prefix 4096 restart 10
       ${lib.optionalString adjacency.nextHopSelf " neighbor ${peer} next-hop-self"}
       maximum-paths ${toString adjacency.maximumPaths}
      exit-address-family
    '';
  in ''
    ${mkPrefixList {
      name = in4;
      routes = adjacency.import;
      family = 4;
    }}
    ${mkPrefixList {
      name = in6;
      routes = adjacency.import;
      family = 6;
    }}
    ${mkPrefixList {
      name = out4;
      routes = adjacency.export;
      family = 4;
    }}
    ${mkPrefixList {
      name = out6;
      routes = adjacency.export;
      family = 6;
    }}
    ${mkRouteMap {
      name = rmIn4;
      prefixList = in4;
      family = 4;
    }}
    ${mkRouteMap {
      name = rmIn6;
      prefixList = in6;
      family = 6;
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
     neighbor ${adjacency.remote.ipv4} remote-as ${toString adjacency.remoteAsn}
     neighbor ${adjacency.remote.ipv4} description ${adjacency.key}
     neighbor ${adjacency.remote.ipv4} bfd profile ${adjacency.timerProfile}
     neighbor ${adjacency.remote.ipv4} timers ${bgpTimers}
     neighbor ${adjacency.remote.ipv4} timers connect 5
     neighbor ${adjacency.remote.ipv4} timers delayopen 5
     neighbor ${adjacency.remote.ipv6} remote-as ${toString adjacency.remoteAsn}
     neighbor ${adjacency.remote.ipv6} description ${adjacency.key}
     neighbor ${adjacency.remote.ipv6} bfd profile ${adjacency.timerProfile}
     neighbor ${adjacency.remote.ipv6} timers ${bgpTimers}
     neighbor ${adjacency.remote.ipv6} timers connect 5
     neighbor ${adjacency.remote.ipv6} timers delayopen 5
    ${mkAf {
      family = 4;
      peer = adjacency.remote.ipv4;
      rmIn = rmIn4;
      rmOut = rmOut4;
    }}
    ${mkAf {
      family = 6;
      peer = adjacency.remote.ipv6;
      rmIn = rmIn6;
      rmOut = rmOut6;
    }}
  '';
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
      neighbor ::1 maximum-prefix 4096 restart 10
     exit-address-family
     address-family ipv6 unicast
      neighbor ::1 activate
      neighbor ::1 route-map ${rmIn6} in
      neighbor ::1 route-map ${rmOut6} out
      neighbor ::1 maximum-prefix 4096 restart 10
     exit-address-family
  '';
in rec {
  inherit
    byFamily
    mkCilium
    mkNeighbor
    mkPrefixList
    mkRouteMap
    prefixEntries
    symbol
    ;

  emptyRoutes = {
    hosts = [];
    vips = [];
    pods = [];
    services = [];
  };

  mergeRoutes = routes: {
    hosts = lib.unique (lib.concatMap (route: route.hosts) routes);
    vips = lib.unique (lib.concatMap (route: route.vips) routes);
    pods = lib.unique (lib.concatMap (route: route.pods) routes);
    services = lib.unique (lib.concatMap (route: route.services) routes);
  };

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
      command =
        if family == 4
        then "ip"
        else "ipv6";
      length =
        if family == 4
        then 32
        else 128;
      list = "${name}_border${suffix}";
      routeMap = "${name}_border_map${suffix}";
    in
      lib.optionalString (peers != []) ''
        ${lib.concatStringsSep "\n" (
          lib.imap1 (
            index: prefix: "${command} prefix-list ${list} seq ${toString (index * 5)} permit ${prefix} le ${toString length}"
          )
          prefixes
        )}
        route-map ${routeMap} permit 10
         match ${command} address prefix-list ${list}
        exit
        ${lib.concatMapStringsSep "\n" (peer: ''
            router bgp ${toString localAsn}
             neighbor ${peer.address} remote-as ${toString peer.asn}
             neighbor ${peer.address} description border-upstream
             neighbor ${peer.address} bfd
             neighbor ${peer.address} timers 3 9
             neighbor ${peer.address} timers connect 5
             address-family ipv${suffix} unicast
              neighbor ${peer.address} activate
              neighbor ${peer.address} route-map ${routeMap} in
              neighbor ${peer.address} route-map ${routeMap} out
              neighbor ${peer.address} next-hop-self
              neighbor ${peer.address} maximum-prefix 4096 restart 10
             exit-address-family
          '')
          peers}
      '';
  in
    lib.optionalString (border != null) (
      mkFamily {
        family = 4;
        prefixes = families.v4;
        peers = builtins.filter (peer: !(lib.hasInfix ":" peer.address)) border.upstreamPeers;
      }
      + mkFamily {
        family = 6;
        prefixes = families.v6;
        peers = builtins.filter (peer: lib.hasInfix ":" peer.address) border.upstreamPeers;
      }
    );

  mkConfig = {
    routerId,
    sourceAddresses,
    localAsn,
    adjacencies,
    networks ? [],
    border ? null,
    extraConfig ? "",
  }: let
    familyNetworks = byFamily networks;
  in ''
    frr defaults datacenter
    allow-reserved-ranges
    bfd
     profile site
      detect-multiplier 3
      receive-interval 300
      transmit-interval 300
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
    router bgp ${toString localAsn}
     bgp router-id ${routerId}
     no bgp default ipv4-unicast
     bgp ebgp-requires-policy
     bgp bestpath as-path multipath-relax
     bgp allow-martian-nexthop
     address-family ipv4 unicast
      ${lib.concatMapStringsSep "\n " (network: "network ${network}") familyNetworks.v4}
      maximum-paths 8
     exit-address-family
     address-family ipv6 unicast
      ${lib.concatMapStringsSep "\n " (network: "network ${network}") familyNetworks.v6}
      maximum-paths 8
     exit-address-family
    ${lib.concatMapStringsSep "\n" (adjacency: mkNeighbor {inherit adjacency localAsn;}) adjacencies}
    ${mkBorder {inherit localAsn border;}}
    ${extraConfig}
  '';
}
