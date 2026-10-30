{ifstateOverlay}: {
  clanLib,
  directory,
  lib,
  ...
}: let
  cidr = import ../../lib/kube-cluster/cidr.nix {inherit lib;};
  fabric = import ../../lib/kube-cluster/fabric.nix {inherit lib;};
  frr = import ../../lib/kube-cluster/frr.nix {inherit lib;};
  ip = import ../../lib/ip.nix {inherit lib;};

  pairs = values:
    lib.concatMap (
      i:
        map (j: {
          first = builtins.elemAt values i;
          second = builtins.elemAt values j;
        }) (lib.range (i + 1) (builtins.length values - 1))
    ) (lib.range 0 (builtins.length values - 2));

  endpointSourceOptions = lib.types.submodule {
    options = {
      service = lib.mkOption {
        type = lib.types.str;
        description = "Service manifest name exporting peer hosts.";
      };
      instance = lib.mkOption {
        type = lib.types.str;
        description = "Service instance exporting peer hosts.";
      };
    };
  };

  adjacencyOptions = lib.types.submodule {
    options = {
      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override the remote peer hostname or address for this adjacency.";
      };
      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "Override the allocated UDP port for this adjacency.";
      };
      underlayMtu = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Override the smallest underlay MTU used for this adjacency.";
      };
      extraAllowedIPs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Deliberate routed-only prefixes added to this adjacency's ACL and FRR policy.";
      };
      externalTransit = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Permit external sources with 0/0 crypto ACLs; never installs a main-table default route.";
      };
      sourceReturn = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Route return traffic from owned prefixes through this adjacency in a separate policy table.";
      };
      sourceReturnTable = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.u32;
        default = null;
        description = "Override the source-return policy table; reserved kernel/Cilium, netif, and duplicate source-return tables are rejected.";
      };
      sourceReturnPriority = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.u32;
        default = null;
        description = "Override the source-return rule priority; values at or above 32766 and netif or duplicate source-return collisions are rejected.";
      };
      timerProfile = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "site"
            "wan"
          ]
        );
        default = null;
        description = "Override the symmetric adjacency timer profile; null selects site for equal sites and wan otherwise.";
      };
    };
  };

  roleInterface = {lib, ...}: {
    options = {
      ipv4 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Stable fabric IPv4 host address without a prefix; null reads the public node allocation.";
      };
      ipv6 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Stable fabric IPv6 host address without a prefix; null reads the public node allocation.";
      };
      loopback4Pool = lib.mkOption {
        type = lib.types.str;
        default = "198.18.0.0/17";
        description = "Member-uniform IPv4 loopback allocation pool recorded by the shared prefix generator.";
      };
      transfer4Pool = lib.mkOption {
        type = lib.types.str;
        default = "198.19.0.0/16";
        description = "Member-uniform IPv4 transfer allocation pool recorded by the shared prefix generator.";
      };
      site = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "Failure-domain site label; equal sites default to site timers and different sites to wan timers.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 51820;
        description = "Base transport UDP port published in node_transport; per-adjacency ports are allocated independently.";
      };
      portRange = lib.mkOption {
        type = lib.types.submodule {
          options = {
            start = lib.mkOption {
              type = lib.types.port;
              default = 10000;
              description = "First port available to adjacency allocation.";
            };
            end = lib.mkOption {
              type = lib.types.port;
              default = 32767;
              description = "Last port available to adjacency allocation.";
            };
          };
        };
        default = {};
        description = "Member-uniform inclusive range for allocated adjacency ports.";
      };
      underlayMtu = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1500;
        description = "Underlay MTU; WireGuard MTU is this minus the dual-stack overhead with a 1280 floor.";
      };
      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Reachable hostname or address without brackets or a port; null is outbound-only/NAT.";
      };
      endpointSources = lib.mkOption {
        type = lib.types.listOf endpointSourceOptions;
        default = [];
        description = "Ordered peer export sources used when endpoint is null.";
      };
      spines = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Leaf-only explicit subset of spine-role machines to attach to; empty attaches every spine. Must stay empty on spines.";
      };
      access = lib.mkOption {
        type = lib.types.enum [
          "member"
          "client"
          "admin"
        ];
        default = "member";
        description = "Route consumption only: member, fabric VIP client, or pod/ClusterIP admin.";
      };
      maximumPaths = lib.mkOption {
        type = lib.types.ints.positive;
        default = 8;
        description = "Maximum equal-cost paths retained for each fabric address family.";
      };
      adjacencies = lib.mkOption {
        type = lib.types.attrsOf adjacencyOptions;
        default = {};
        description = "Optional per-remote adjacency overrides keyed by remote machine name.";
      };
      border = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              ownedPrefixes = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                description = "Prefixes this border may originate and accept from upstream.";
              };
              upstreamPeers = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      address = lib.mkOption {
                        type = lib.types.str;
                        description = "Upstream BGP peer literal unzoned IPv4 or IPv6 address.";
                      };
                      asn = lib.mkOption {
                        type = lib.types.ints.between 1 4294967295;
                        description = "Upstream BGP peer ASN.";
                      };
                    };
                  }
                );
                default = [];
                description = "External BGP peers, independent of fabric spine/leaf topology.";
              };
              ndpInterfaces = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                description = "LAN interfaces on which to answer NDP for owned IPv6 prefixes.";
              };
              forwarding = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Enable external/fabric packet forwarding on this border.";
              };
            };
          }
        );
        default = null;
        description = "Optional external/upstream transit configuration; orthogonal to leaf/spine and access.";
      };
      firewall = {
        openPort = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Open allocated WireGuard UDP listen ports.";
        };
        trust = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Trust traffic arriving on routed-fabric WireGuard interfaces.";
        };
      };
    };
  };

  resolveHostValue = host:
    host.plain or (
      if host ? var
      then clanLib.getPublicValue (host.var // {default = "";})
      else throw "routed-fabric: unsupported peer host value ${builtins.toJSON host}"
    );

  endpointFromSources = {
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

  mtuFromSources = {
    exports,
    sources,
    machineName,
  }: let
    mtusForSource = source: let
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
      lib.filter (mtu: mtu != null) (map (value: value.netif.mtu or null) matches);
    values = lib.concatMap mtusForSource sources;
  in
    if values == []
    then null
    else builtins.head values;

  endpointString = host: port:
    if host == null
    then null
    else if lib.hasInfix ":" host
    then "[${host}]:${toString port}"
    else "${host}:${toString port}";

  endpointFamily = host:
    if host == null
    then null
    else if ip.isIpv4 host
    then 4
    else if ip.isIpv6 host
    then 6
    else null;

  roleFor = roles: machineName:
    if (roles.spine.machines or {}) ? ${machineName}
    then "spine"
    else if (roles.leaf.machines or {}) ? ${machineName}
    then "leaf"
    else null;

  # D59: a leaf attaches every spine by default; an explicit spines
  # subset is allowed. Spines derive their attachments symmetrically.
  attachedSpines = roles: leafName: let
    leafSettings = roles.leaf.machines.${leafName}.settings;
    allSpines = lib.sort builtins.lessThan (builtins.attrNames (roles.spine.machines or {}));
  in
    if leafSettings.spines == []
    then allSpines
    else lib.unique leafSettings.spines;

  leavesAttachedTo = roles: spineName:
    lib.sort builtins.lessThan (
      builtins.attrNames (
        lib.filterAttrs (
          name: _leaf: name != spineName && builtins.elem spineName (attachedSpines roles name)
        ) (roles.leaf.machines or {})
      )
    );

  perInstance = {
    instanceName,
    machine,
    roles,
    exports,
    mkExports,
    ...
  }: let
    allMachines = (roles.leaf.machines or {}) // (roles.spine.machines or {});
    ownRole = roleFor roles machine.name;
    ownSettings = allMachines.${machine.name}.settings;
    prefixGenerator = "routed-fabric-${instanceName}-prefixes";
    nodeGenerator = "routed-fabric-${instanceName}-node";
    adjacencyGeneratorName = remoteName: let
      endpoints = lib.sort builtins.lessThan [
        machine.name
        remoteName
      ];
    in "routed-fabric-${instanceName}-adj-${builtins.head endpoints}-${builtins.elemAt endpoints 1}";

    allocation = {
      generator,
      file,
      machineName ? null,
      generateMachine ? machine.name,
    }:
      lib.trim (
        clanLib.getPublicValue {
          inherit generator file;
          flake = directory;
          machine = machineName;
          default = throw "routed-fabric/${instanceName}: no allocation for ${
            if machineName == null
            then generateMachine
            else machineName
          } (${generator}/${file}); run: clan vars generate ${generateMachine} --generator ${generator}";
        }
      );

    addressOf = name: {
      ipv4 =
        if allMachines.${name}.settings.ipv4 != null
        then allMachines.${name}.settings.ipv4
        else
          allocation {
            generator = nodeGenerator;
            machineName = name;
            generateMachine = name;
            file = "ipv4";
          };
      ipv6 =
        if allMachines.${name}.settings.ipv6 != null
        then allMachines.${name}.settings.ipv6
        else
          allocation {
            generator = nodeGenerator;
            machineName = name;
            generateMachine = name;
            file = "ipv6";
          };
    };
    asnOf = name:
      builtins.fromJSON (
        allocation {
          generator = nodeGenerator;
          machineName = name;
          generateMachine = name;
          file = "asn";
        }
      );
    ownAddress = addressOf machine.name;
    stableHosts = lib.concatMap (
      name: let
        address = addressOf name;
      in [
        "${address.ipv4}/32"
        "${address.ipv6}/128"
      ]
    ) (builtins.attrNames allMachines);

    allExports = lib.attrValues (clanLib.selectExports (_: true) exports);
    clusterExports = builtins.filter (value: value ? kube_cluster) allExports;
    clusterList = map (value: value.kube_cluster) (
      builtins.filter (
        value: let
          facts = value.kube_cluster;
          reference = facts.network.fabric or facts.transport;
        in
          reference.service
          != null
          && reference.instance != null
          && reference.service == "routed-fabric"
          && reference.instance == instanceName
      )
      clusterExports
    );
    kubernetesMachines = lib.unique (
      lib.concatMap (facts: builtins.attrNames facts.members) clusterList
    );
    isKubernetes = name: builtins.elem name kubernetesMachines;

    prefixFile = file:
      allocation {
        generator = prefixGenerator;
        inherit file;
      };
    ulaBase = builtins.head (lib.splitString "::" (prefixFile "ula48"));
    allocationPools = [
      {
        name = "loopback4Pool";
        cidr = prefixFile "loopback4-pool";
      }
      {
        name = "transfer4Pool";
        cidr = prefixFile "transfer4-pool";
      }
      {
        name = "loopback6";
        cidr = "${ulaBase}:0::/64";
      }
      {
        name = "transfer6";
        cidr = "${ulaBase}:1::/64";
      }
    ];
    memberNames = builtins.attrNames allMachines;
    unequalPoolMembers =
      builtins.filter (
        name: let
          memberSettings = allMachines.${name}.settings;
        in
          memberSettings.loopback4Pool
          != ownSettings.loopback4Pool
          || memberSettings.transfer4Pool != ownSettings.transfer4Pool
          || memberSettings.portRange != ownSettings.portRange
      )
      memberNames;
    memberNetifExports = lib.attrValues (
      clanLib.selectExports (
        scope: scope.serviceName == "netif" && builtins.elem scope.machineName memberNames
      )
      exports
    );
    underlayCidrs = lib.unique (
      lib.concatMap (
        value: lib.concatMap (link: link.addresses) (builtins.attrValues value.netif.links)
      )
      memberNetifExports
    );
    memberClusterList =
      builtins.filter (
        facts: lib.any (name: facts.members ? ${name}) memberNames
      )
      clusterList;
    clusterCidrs = lib.unique (
      lib.concatMap (
        facts:
          [
            facts.network.podCIDRv4
            facts.network.podCIDRv6
            facts.network.serviceCIDRv4
            facts.network.serviceCIDRv6
          ]
          ++ lib.optionals facts.fabric.enabled [
            facts.fabric.ipv4Block
            facts.fabric.ipv6Block
          ]
      )
      memberClusterList
    );
    externalCidrs = underlayCidrs ++ clusterCidrs;
    externalPoolOverlaps =
      lib.concatMap (
        pool:
          map (prefix: {inherit pool prefix;}) (
            builtins.filter (other: cidr.overlap pool.cidr other) externalCidrs
          )
      )
      allocationPools;
    internalPoolOverlaps = builtins.filter (
      pair: cidr.overlap pair.first.cidr pair.second.cidr
    ) (pairs allocationPools);

    clusterRoutes = facts: let
      pools =
        lib.filterAttrs (
          _: pool: pool.delivery == "shared-bgp" || pool.delivery == "node-bgp"
        )
        facts.pools;
    in {
      hosts = [];
      vips = lib.unique (lib.concatMap (pool: pool.blocks) (builtins.attrValues pools));
      pods = [
        facts.network.podCIDRv4
        facts.network.podCIDRv6
      ];
      services = lib.optionals facts.bgp.advertiseClusterIPs [
        facts.network.serviceCIDRv4
        facts.network.serviceCIDRv6
      ];
    };
    localClusterRoutes = frr.mergeRoutes (
      map clusterRoutes (builtins.filter (facts: facts.members ? ${machine.name}) clusterList)
    );
    localRoutes =
      localClusterRoutes
      // {
        hosts = [
          "${ownAddress.ipv4}/32"
          "${ownAddress.ipv6}/128"
        ];
      };

    consumptionRoutes = name: let
      access = allMachines.${name}.settings.access;
      includePods = isKubernetes name || access == "admin";
      includeServices = access == "admin" && !isKubernetes name;
      localFacts = builtins.filter (facts: facts.members ? ${name}) clusterList;
      fullPeering = lib.all (facts: (facts.mesh.peers or null) == null) localFacts;
      selectedPeers = lib.unique (
        lib.concatMap (
          facts:
            if (facts.mesh.peers or null) == null
            then []
            else facts.mesh.peers
        )
        localFacts
      );
      accessibleFacts =
        builtins.filter (
          facts: facts.members ? ${name} || fullPeering || builtins.elem facts.name selectedPeers
        )
        clusterList;
      accessibleRoutes = frr.mergeRoutes (map clusterRoutes accessibleFacts);
    in {
      hosts = stableHosts;
      inherit (accessibleRoutes) vips;
      pods = lib.optionals includePods accessibleRoutes.pods;
      services = lib.optionals includeServices accessibleRoutes.services;
    };

    spineNames = lib.sort builtins.lessThan (builtins.attrNames (roles.spine.machines or {}));
    peerNames =
      if ownRole == "spine"
      then
        lib.unique (
          (builtins.filter (name: name != machine.name) spineNames) ++ leavesAttachedTo roles machine.name
        )
      else attachedSpines roles machine.name;

    endpointOf = name: let
      machineSettings = allMachines.${name}.settings;
    in
      if machineSettings.endpoint != null
      then machineSettings.endpoint
      else
        endpointFromSources {
          inherit exports;
          sources = machineSettings.endpointSources;
          machineName = name;
        };

    underlayMtuOf = name: let
      machineSettings = allMachines.${name}.settings;
      exportedMtu = mtuFromSources {
        inherit exports;
        sources = machineSettings.endpointSources;
        machineName = name;
      };
    in
      if exportedMtu != null
      then exportedMtu
      else machineSettings.underlayMtu;

    mkAdjacency = remoteName: let
      remoteSettings = allMachines.${remoteName}.settings;
      key = fabric.adjacencyKey instanceName machine.name remoteName;
      generator = adjacencyGeneratorName remoteName;
      allocatedPort = builtins.fromJSON (
        allocation {
          inherit generator;
          file = "port";
        }
      );
      prefixes = {
        ipv4 = allocation {
          inherit generator;
          file = "transfer4";
        };
        ipv6 = allocation {
          inherit generator;
          file = "transfer6";
        };
      };
      ordered = lib.sort builtins.lessThan [
        machine.name
        remoteName
      ];
      localIsFirst = machine.name == builtins.head ordered;
      firstAddress = {
        ipv4 = cidr.addressAt prefixes.ipv4 0;
        ipv6 = cidr.addressAtV6 prefixes.ipv6 0;
      };
      secondAddress = {
        ipv4 = cidr.addressAt prefixes.ipv4 1;
        ipv6 = cidr.addressAtV6 prefixes.ipv6 1;
      };
      localAddress =
        if localIsFirst
        then firstAddress
        else secondAddress;
      remoteAddress =
        if localIsFirst
        then secondAddress
        else firstAddress;
      localOverride = ownSettings.adjacencies.${remoteName} or {};
      remoteOverride = remoteSettings.adjacencies.${machine.name} or {};
      port =
        if (localOverride.port or null) != null
        then localOverride.port
        else if (remoteOverride.port or null) != null
        then remoteOverride.port
        else allocatedPort;
      remotePort = port;
      endpointHost =
        if (localOverride.endpoint or null) != null
        then localOverride.endpoint
        else endpointOf remoteName;
      endpoint = endpointString endpointHost remotePort;
      underlayMtu =
        if (localOverride.underlayMtu or null) != null
        then localOverride.underlayMtu
        else lib.min (underlayMtuOf machine.name) (underlayMtuOf remoteName);
      mtu = fabric.adjacencyMtu underlayMtu;
      externalTransit =
        (localOverride.externalTransit or false) || (remoteOverride.externalTransit or false);
      sourceReturn = localOverride.sourceReturn or false;
      extraAllowedIPs = localOverride.extraAllowedIPs or [];
      localEndpointHost = endpointOf machine.name;
      localFamily = endpointFamily localEndpointHost;
      remoteFamily = endpointFamily endpointHost;
      addressFamilyMismatch =
        localFamily != null && remoteFamily != null && localFamily != remoteFamily;
      hostnameEndpoint =
        (localEndpointHost != null && localFamily == null)
        || (endpointHost != null && remoteFamily == null);
      timerProfile =
        if (localOverride.timerProfile or null) != null
        then localOverride.timerProfile
        else if (remoteOverride.timerProfile or null) != null
        then remoteOverride.timerProfile
        else if ownSettings.site == remoteSettings.site
        then "site"
        else "wan";
      timerOverrideConflict =
        (localOverride.timerProfile or null)
        != null
        && (remoteOverride.timerProfile or null) != null
        && localOverride.timerProfile != remoteOverride.timerProfile;
      remoteRole = roleFor roles remoteName;
      import =
        if ownRole == "spine" && remoteRole == "spine"
        then consumptionRoutes machine.name
        else if ownRole == "spine"
        then
          (clusterRoutesFor remoteName)
          // {
            hosts = let
              address = addressOf remoteName;
            in [
              "${address.ipv4}/32"
              "${address.ipv6}/128"
            ];
          }
        else consumptionRoutes machine.name;
      export =
        if ownRole == "spine"
        then consumptionRoutes remoteName
        else localRoutes;
      cryptoRoutes = frr.mergeRoutes [
        import
        export
        {
          hosts =
            [
              "${remoteAddress.ipv4}/32"
              "${remoteAddress.ipv6}/128"
            ]
            ++ extraAllowedIPs;
          vips = [];
          pods = [];
          services = [];
        }
      ];
      allowedIPs =
        cryptoRoutes.hosts
        ++ cryptoRoutes.vips
        ++ cryptoRoutes.pods
        ++ cryptoRoutes.services
        ++ lib.optionals externalTransit [
          "0.0.0.0/0"
          "::/0"
        ];
      name = fabric.adjacencyName key;
      linkLocal = let
        hash = builtins.hashString "sha256" "${key}:${machine.name}";
      in "fe80::${builtins.substring 0 4 hash}:${builtins.substring 4 4 hash}:${builtins.substring 8 4 hash}:${builtins.substring 12 4 hash}";
      table =
        if (localOverride.sourceReturnTable or null) != null
        then localOverride.sourceReturnTable
        else 1000 + lib.mod (asnOf remoteName) 30000;
      rulePriority =
        if (localOverride.sourceReturnPriority or null) != null
        then localOverride.sourceReturnPriority
        else 10000 + lib.mod (asnOf remoteName) 20000;
    in {
      inherit
        addressFamilyMismatch
        allowedIPs
        endpoint
        export
        externalTransit
        generator
        hostnameEndpoint
        import
        key
        linkLocal
        mtu
        name
        port
        prefixes
        remoteName
        rulePriority
        sourceReturn
        table
        timerOverrideConflict
        timerProfile
        underlayMtu
        ;
      local = localAddress;
      remote = remoteAddress;
      remoteAsn = asnOf remoteName;
      nextHopSelf = ownRole == "spine";
      inherit (ownSettings) maximumPaths;
    };

    clusterRoutesFor = name:
      frr.mergeRoutes (
        [
          {
            hosts = [];
            vips = [];
            pods = [];
            services = [];
          }
        ]
        ++ map clusterRoutes (builtins.filter (facts: facts.members ? ${name}) clusterList)
      );

    adjacencies = map mkAdjacency peerNames;
    ownAsn = asnOf machine.name;
    loopbackName = "rflo${builtins.substring 0 10 (builtins.hashString "sha256" instanceName)}";
    frrConfig = frr.mkConfig {
      routerId = ownAddress.ipv4;
      sourceAddresses = ownAddress;
      localAsn = ownAsn;
      inherit adjacencies border;
      networks = localRoutes.hosts;
      extraConfig = lib.concatMapStringsSep "\n" (
        facts:
          frr.mkCilium {
            localAsn = ownAsn;
            sourceAddresses = ownAddress;
            cluster = facts;
            routes = clusterRoutes facts;
          }
      ) (builtins.filter (facts: facts.members ? ${machine.name}) clusterList);
    };
    ownSpines =
      if ownRole == "leaf"
      then attachedSpines roles machine.name
      else [];
    invalidSpines = builtins.filter (name: roleFor roles name != "spine") ownSettings.spines;
    unreachables =
      builtins.filter (
        adjacency: adjacency.endpoint == null && endpointOf machine.name == null
      )
      adjacencies;
    collidingMachines = selector:
      builtins.filter (
        name: name != machine.name && selector name == selector machine.name
      )
      memberNames;
    ipv4CollisionMachines = collidingMachines (name: (addressOf name).ipv4);
    ipv6CollisionMachines = collidingMachines (name: (addressOf name).ipv6);
    asnCollisionMachines = collidingMachines asnOf;
    transfer4CollisionPairs = builtins.filter (
      pair: pair.first.prefixes.ipv4 == pair.second.prefixes.ipv4
    ) (pairs adjacencies);
    transfer6CollisionPairs = builtins.filter (
      pair: pair.first.prefixes.ipv6 == pair.second.prefixes.ipv6
    ) (pairs adjacencies);
    portCollisionPairs = builtins.filter (
      pair: pair.first.port == pair.second.port
    ) (pairs adjacencies);
    interfaceNames = map (adjacency: adjacency.name) adjacencies;
    listenPorts = map (adjacency: adjacency.port) adjacencies;
    sourceReturns = builtins.filter (adjacency: adjacency.sourceReturn) adjacencies;
    addressFamilyMismatches = builtins.filter (adjacency: adjacency.addressFamilyMismatch) adjacencies;
    hostnameEndpoints = builtins.filter (adjacency: adjacency.hostnameEndpoint) adjacencies;
    timerOverrideConflicts = builtins.filter (adjacency: adjacency.timerOverrideConflict) adjacencies;
    inherit (ownSettings) border;

    # D58: routed-fabric is the native transport — every adjacency
    # WireGuard interface is a datapath interface keyed by its Linux
    # name. The stable loopback is also exported on every node and is the
    # uniform directRoutingDevice in the cluster-wide Cilium ConfigMap.
    transportInterfaces =
      {
        ${loopbackName} = {
          mtu = fabric.adjacencyMtu (underlayMtuOf machine.name);
        };
      }
      // lib.listToAttrs (
        map (adjacency: {
          inherit (adjacency) name;
          value = {
            inherit (adjacency) mtu;
          };
        })
        adjacencies
      );
    directRoutingDevice = loopbackName;
  in {
    exports = mkExports {
      peer.hosts = [
        {plain = ownAddress.ipv4;}
        {plain = ownAddress.ipv6;}
      ];
      node_transport = {
        schemaVersion = 2;
        inherit (ownAddress) ipv4 ipv6;
        inherit (ownSettings) port;
        instance = instanceName;
        asn = ownAsn;
        interfaces = transportInterfaces;
        inherit directRoutingDevice;
        endpoint = endpointString (endpointOf machine.name) ownSettings.port;
        datapath = {
          mode = "native";
          tunnelProtocol = null;
        };
        native.routeExchange = "local-router";
        internalLoadBalancer = true;
        nodePort = true;
      };
      routed_fabric = {
        schemaVersion = 2;
        asn = ownAsn;
        inherit (ownAddress) ipv4 ipv6;
        inherit (ownSettings) access;
        topology = ownRole;
        border = {
          enabled = border != null;
          ownedPrefixes =
            if border != null
            then border.ownedPrefixes
            else [];
        };
        loopback = loopbackName;
        adjacencies = lib.listToAttrs (
          map (adjacency: {
            name = adjacency.remoteName;
            value = {
              inherit
                (adjacency)
                allowedIPs
                endpoint
                mtu
                name
                port
                prefixes
                timerProfile
                ;
              inherit (adjacency.local) ipv4 ipv6;
            };
          })
          adjacencies
        );
      };
    };

    nixosModule = {
      config,
      pkgs,
      ...
    }: let
      generatorName = "routed-fabric-${instanceName}";
      privateKeyFile = config.clan.core.vars.generators.${generatorName}.files.privatekey.path;
      publicKeyOf = name:
        lib.trim (
          clanLib.getPublicValue {
            generator = generatorName;
            machine = name;
            file = "publickey";
            flake = config.clan.core.settings.directory;
            default = throw "routed-fabric/${instanceName}: missing public key for '${name}' (${generatorName})";
          }
        );
      ifstateInterfaces =
        {
          ${loopbackName} = {
            addresses = [
              "${ownAddress.ipv4}/32"
              "${ownAddress.ipv6}/128"
            ];
            link = {
              kind = "dummy";
              state = "up";
              mtu = transportInterfaces.${loopbackName}.mtu;
            };
          };
        }
        // lib.listToAttrs (
          map (adjacency: {
            inherit (adjacency) name;
            value = {
              addresses = [
                {
                  address = "${adjacency.local.ipv4}/31";
                  scope = "link";
                }
                {
                  address = "${adjacency.local.ipv6}/127";
                  scope = "link";
                }
                "${adjacency.linkLocal}/64"
              ];
              link = {
                kind = "wireguard";
                state = "up";
                inherit (adjacency) mtu;
              };
              wireguard = {
                private_key = "!include ${privateKeyFile}";
                listen_port = adjacency.port;
                peers.${publicKeyOf adjacency.remoteName} =
                  {
                    allowedips = adjacency.allowedIPs;
                    persistent_keepalive_interval = 25;
                  }
                  // lib.optionalAttrs (adjacency.endpoint != null) {
                    inherit (adjacency) endpoint;
                  };
              };
            };
          })
          adjacencies
        );
      ifstateRoutes =
        lib.concatMap (
          adjacency:
            lib.optionals adjacency.sourceReturn [
              {
                to = "0.0.0.0/0";
                via = adjacency.remote.ipv4;
                dev = adjacency.name;
                inherit (adjacency) table;
              }
              {
                to = "::/0";
                via = adjacency.remote.ipv6;
                dev = adjacency.name;
                inherit (adjacency) table;
              }
            ]
        )
        adjacencies;
      ifstateRules =
        lib.concatMap (
          adjacency:
            lib.optionals adjacency.sourceReturn (
              map (prefix: {
                from = prefix;
                inherit (adjacency) table;
                priority = adjacency.rulePriority;
              }) (
                if border != null
                then border.ownedPrefixes
                else []
              )
            )
        )
        adjacencies;
      netifPolicyLinks = lib.concatMap (
        instance:
          builtins.filter (link: (link.routingPolicy.table or null) != null) (
            builtins.attrValues instance.links
          )
      ) (builtins.attrValues config.clan.networkFacts.netif);
      netifPolicyTables = map (link: link.routingPolicy.table) netifPolicyLinks;
      netifRulePriorities =
        lib.concatMap (
          link:
            (lib.genList (i: link.routingPolicy.priority + i) (lib.length link.routingPolicy.from))
            ++ (lib.genList (i: link.routingPolicy.priority + 50 + i) (lib.length link.routingPolicy.to))
        )
        netifPolicyLinks;
      sourceReturnTables = map (adjacency: adjacency.table) sourceReturns;
      sourceReturnRulePriorities = map (adjacency: adjacency.rulePriority) sourceReturns;
      upstreamPeers =
        if border != null
        then border.upstreamPeers
        else [];
      upstream4 = map (peer: peer.address) (
        builtins.filter (peer: ip.isIpv4 peer.address) upstreamPeers
      );
      upstream6 = map (peer: peer.address) (
        builtins.filter (peer: ip.isIpv6 peer.address) upstreamPeers
      );
      upstreamFirewallRules =
        lib.optionalString (upstream4 != []) ''
          ip saddr { ${lib.concatStringsSep ", " upstream4} } tcp dport 179 accept
          ip saddr { ${lib.concatStringsSep ", " upstream4} } udp dport { 3784, 4784 } accept
        ''
        + lib.optionalString (upstream6 != []) ''
          ip6 saddr { ${lib.concatStringsSep ", " upstream6} } tcp dport 179 accept
          ip6 saddr { ${lib.concatStringsSep ", " upstream6} } udp dport { 3784, 4784 } accept
        '';
      otherWireguardPorts =
        lib.mapAttrsToList (name: interface: {
          inherit name;
          port = interface.wireguard.listen_port;
        }) (
          lib.filterAttrs (
            name: interface:
              !(builtins.elem name interfaceNames)
              && (interface.link.kind or null) == "wireguard"
              && (interface.wireguard.listen_port or null) != null
          )
          config.networking.ifstate.settings.interfaces
        );
      externalPortCollisions =
        lib.concatMap (
          adjacency:
            map (other: {inherit adjacency other;}) (
              builtins.filter (other: other.port == adjacency.port) otherWireguardPorts
            )
        )
        adjacencies;
    in {
      imports = [../../lib/kube-cluster/network-facts.nix];

      warnings =
        map (
          adjacency: "routed-fabric/${instanceName}: adjacency ${adjacency.key} uses a hostname endpoint; eval cannot verify a shared address family without DNS resolution"
        )
        hostnameEndpoints;

      assertions = [
        {
          assertion = ownRole == "spine" || ownSpines != [];
          message = "routed-fabric/${instanceName}: leaf '${machine.name}' must attach to at least one spine-role machine";
        }
        {
          assertion = invalidSpines == [];
          message = "routed-fabric/${instanceName}: invalid or non-spine references on '${machine.name}': ${lib.concatStringsSep ", " invalidSpines}";
        }
        {
          assertion = ownRole != "spine" || ownSettings.spines == [];
          message = "routed-fabric/${instanceName}: spine '${machine.name}' must not declare settings.spines (spine pairs and leaf attachments are derived)";
        }
        {
          assertion = unreachables == [];
          message = "routed-fabric/${instanceName}: each adjacency needs at least one reachable endpoint; missing ${
            lib.concatMapStringsSep ", " (adjacency: adjacency.key) unreachables
          }";
        }
        {
          assertion = ipv4CollisionMachines == [];
          message = "routed-fabric/${instanceName}: loopback IPv4 ${ownAddress.ipv4} on ${machine.name} collides with ${
            lib.concatStringsSep ", " ipv4CollisionMachines
          }; run: clan vars generate ${machine.name} --generator ${nodeGenerator} --regenerate";
        }
        {
          assertion = ipv6CollisionMachines == [];
          message = "routed-fabric/${instanceName}: loopback IPv6 ${ownAddress.ipv6} on ${machine.name} collides with ${
            lib.concatStringsSep ", " ipv6CollisionMachines
          }; run: clan vars generate ${machine.name} --generator ${nodeGenerator} --regenerate";
        }
        {
          assertion = asnCollisionMachines == [];
          message = "routed-fabric/${instanceName}: ASN ${toString ownAsn} on ${machine.name} collides with ${
            lib.concatStringsSep ", " asnCollisionMachines
          }; run: clan vars generate ${machine.name} --generator ${nodeGenerator} --regenerate";
        }
        {
          assertion = unequalPoolMembers == [];
          message = "routed-fabric/${instanceName}: allocation settings differ on ${
            lib.concatStringsSep ", " unequalPoolMembers
          }; set loopback4Pool, transfer4Pool, and portRange identically on every member";
        }
        {
          assertion = internalPoolOverlaps == [];
          message = "routed-fabric/${instanceName}: allocation pools overlap (${
            lib.concatMapStringsSep "; " (
              pair: "${pair.first.name}=${pair.first.cidr} with ${pair.second.name}=${pair.second.cidr}"
            )
            internalPoolOverlaps
          }); set loopback4Pool and transfer4Pool to disjoint member-uniform values";
        }
        {
          assertion = externalPoolOverlaps == [];
          message = "routed-fabric/${instanceName}: allocation pools overlap underlay or cluster CIDRs (${
            lib.concatMapStringsSep "; " (
              overlap: "${overlap.pool.name}=${overlap.pool.cidr} with ${overlap.prefix}"
            )
            externalPoolOverlaps
          }); move the conflicting prefix or set loopback4Pool/transfer4Pool away from it; for a ULA collision run: clan vars generate ${machine.name} --generator ${prefixGenerator} --regenerate";
        }
        {
          assertion = ownSettings.portRange.start <= ownSettings.portRange.end;
          message = "routed-fabric/${instanceName}: portRange.start must not exceed portRange.end; set an inclusive range such as 10000–32767 on every member";
        }
        {
          assertion = portCollisionPairs == [] && externalPortCollisions == [];
          message = "routed-fabric/${instanceName}: ${
            lib.concatStringsSep "; " (
              map (
                pair: "adjacency ${pair.first.key} port ${toString pair.first.port} collides with ${pair.second.key}; run: clan vars generate ${machine.name} --generator ${pair.first.generator} --regenerate"
              )
              portCollisionPairs
              ++ map (
                collision: "adjacency ${collision.adjacency.key} port ${toString collision.adjacency.port} collides with WireGuard interface ${collision.other.name}; run: clan vars generate ${machine.name} --generator ${collision.adjacency.generator} --regenerate"
              )
              externalPortCollisions
            )
          }";
        }
        {
          assertion = transfer4CollisionPairs == [];
          message = "routed-fabric/${instanceName}: ${
            lib.concatStringsSep "; " (
              map (
                pair: "transfer4 ${pair.first.prefixes.ipv4} on ${pair.first.key} collides with ${pair.second.key}; run: clan vars generate ${machine.name} --generator ${pair.first.generator} --regenerate"
              )
              transfer4CollisionPairs
            )
          }";
        }
        {
          assertion = transfer6CollisionPairs == [];
          message = "routed-fabric/${instanceName}: ${
            lib.concatStringsSep "; " (
              map (
                pair: "transfer6 ${pair.first.prefixes.ipv6} on ${pair.first.key} collides with ${pair.second.key}; run: clan vars generate ${machine.name} --generator ${pair.first.generator} --regenerate"
              )
              transfer6CollisionPairs
            )
          }";
        }
        {
          assertion =
            lib.length (lib.unique interfaceNames)
            == lib.length interfaceNames
            && lib.all (name: lib.stringLength name <= 15) interfaceNames;
          message = "routed-fabric/${instanceName}: adjacency interface names collide or exceed 15 characters";
        }
        {
          assertion =
            lib.all (
              adjacency: adjacency.mtu >= 1280 && adjacency.mtu <= adjacency.underlayMtu - 80
            )
            adjacencies;
          message = "routed-fabric/${instanceName}: derived WireGuard MTU violates the dual-stack underlay budget";
        }
        {
          assertion = border == null || (border.ownedPrefixes != [] && border.upstreamPeers != []);
          message = "routed-fabric/${instanceName}: border requires ownedPrefixes and upstreamPeers";
        }
        {
          assertion =
            border
            == null
            || !(builtins.elem "0.0.0.0/0" border.ownedPrefixes || builtins.elem "::/0" border.ownedPrefixes);
          message = "routed-fabric/${instanceName}: border ownedPrefixes must not contain default routes";
        }
        {
          assertion = lib.all (peer: ip.isLiteral peer.address) upstreamPeers;
          message = "routed-fabric/${instanceName}: border.upstreamPeers addresses must be literal unzoned IPv4 or IPv6 addresses";
        }
        {
          assertion = sourceReturns == [] || border != null;
          message = "routed-fabric/${instanceName}: sourceReturn requires border.ownedPrefixes";
        }
        {
          assertion = lib.all (adjacency: !(lib.elem adjacency.table ip.reservedPolicyTables)) sourceReturns;
          message = "routed-fabric/${instanceName}: source-return tables must never use reserved kernel/Cilium tables {0,200,201,253,254,255,2004,2005}";
        }
        {
          assertion =
            lib.length (lib.unique sourceReturnTables)
            == lib.length sourceReturnTables
            && lib.all (table: !(lib.elem table netifPolicyTables)) sourceReturnTables;
          message = "routed-fabric/${instanceName}: source-return tables must be unique and must not collide with same-host netif routingPolicy tables (${lib.concatStringsSep ", " (map toString netifPolicyTables)})";
        }
        {
          assertion =
            lib.all (priority: priority >= 0 && priority < 32766) sourceReturnRulePriorities
            && lib.length (lib.unique sourceReturnRulePriorities) == lib.length sourceReturnRulePriorities
            && lib.intersectLists sourceReturnRulePriorities netifRulePriorities == [];
          message = "routed-fabric/${instanceName}: source-return rule priorities must be below 32766 and unique across source-return and same-host netif rules";
        }
        {
          assertion = addressFamilyMismatches == [];
          message = "routed-fabric/${instanceName}: adjacency endpoints must share an address family when both are IP literals; mismatched ${
            lib.concatMapStringsSep ", " (adjacency: adjacency.key) addressFamilyMismatches
          }";
        }
        {
          assertion = timerOverrideConflicts == [];
          message = "routed-fabric/${instanceName}: both sides of an adjacency must select the same timerProfile; conflicting ${
            lib.concatMapStringsSep ", " (adjacency: adjacency.key) timerOverrideConflicts
          }";
        }
      ];

      clan = {
        core.vars.generators =
          {
            ${generatorName} = {
              files.privatekey = {
                owner = "root";
                group = "root";
                mode = "0400";
                restartUnits = ["ifstate.service"];
              };
              files.publickey = {
                secret = false;
                deploy = false;
              };
              runtimeInputs = [pkgs.wireguard-tools];
              script = ''
                wg genkey > "$out"/privatekey
                wg pubkey < "$out"/privatekey > "$out"/publickey
              '';
            };
            ${prefixGenerator} = {
              share = true;
              files = lib.genAttrs ["ula48" "loopback4-pool" "transfer4-pool"] (_: {
                secret = false;
                deploy = false;
              });
              validation = {
                inherit (ownSettings) loopback4Pool transfer4Pool;
              };
              runtimeInputs = [pkgs.python3];
              script = ''
                python3 - <<'PY'
                import ipaddress
                import os
                import secrets
                from pathlib import Path

                out = Path(os.environ["out"])
                ula = f"fd{secrets.randbits(40):010x}"
                (out / "ula48").write_text(f"{ula[:4]}:{ula[4:8]}:{ula[8:12]}::/48\n")
                (out / "loopback4-pool").write_text("${ownSettings.loopback4Pool}\n")
                (out / "transfer4-pool").write_text("${ownSettings.transfer4Pool}\n")
                PY
              '';
            };
            ${nodeGenerator} = {
              dependencies = [prefixGenerator];
              files = lib.genAttrs ["ipv4" "ipv6" "asn"] (_: {
                secret = false;
                deploy = false;
              });
              runtimeInputs = [pkgs.python3];
              script = ''
                python3 - <<'PY'
                import ipaddress
                import os
                import secrets
                from pathlib import Path

                inputs = Path(os.environ["in"]) / "${prefixGenerator}"
                out = Path(os.environ["out"])
                ula = ipaddress.IPv6Network((inputs / "ula48").read_text().strip())
                pool = ipaddress.IPv4Network((inputs / "loopback4-pool").read_text().strip())
                if pool.num_addresses < 4:
                    raise ValueError("loopback4Pool must contain at least four addresses")
                ipv4 = pool.network_address + 1 + secrets.randbelow(pool.num_addresses - 2)
                loopback6 = ipaddress.IPv6Network((int(ula.network_address), 64))
                ipv6 = loopback6.network_address + secrets.randbits(64)
                asn = 4200000000 + secrets.randbelow(4294967294 - 4200000000 + 1)
                (out / "ipv4").write_text(f"{ipv4}\n")
                (out / "ipv6").write_text(f"{ipv6}\n")
                (out / "asn").write_text(f"{asn}\n")
                PY
              '';
            };
          }
          // lib.listToAttrs (
            map (remoteName: {
              name = adjacencyGeneratorName remoteName;
              value = {
                share = true;
                dependencies = [prefixGenerator];
                files = lib.genAttrs ["port" "transfer4" "transfer6"] (_: {
                  secret = false;
                  deploy = false;
                });
                validation = {
                  portStart = toString ownSettings.portRange.start;
                  portEnd = toString ownSettings.portRange.end;
                };
                runtimeInputs = [pkgs.python3];
                script = ''
                  python3 - <<'PY'
                  import ipaddress
                  import os
                  import secrets
                  from pathlib import Path

                  inputs = Path(os.environ["in"]) / "${prefixGenerator}"
                  out = Path(os.environ["out"])
                  ula = ipaddress.IPv6Network((inputs / "ula48").read_text().strip())
                  pool = ipaddress.IPv4Network((inputs / "transfer4-pool").read_text().strip())
                  if pool.num_addresses < 4:
                      raise ValueError("transfer4Pool must contain at least two /31 prefixes")
                  transfer4 = ipaddress.IPv4Network((int(pool.network_address) + 2 * secrets.randbelow(pool.num_addresses // 2), 31))
                  transfer6_pool = ipaddress.IPv6Network((int(ula.network_address) + (1 << 64), 64))
                  transfer6 = ipaddress.IPv6Network((int(transfer6_pool.network_address) + 2 * secrets.randbelow(1 << 63), 127))
                  start = ${toString ownSettings.portRange.start}
                  end = ${toString ownSettings.portRange.end}
                  if start > end:
                      raise ValueError("portRange.start must not exceed portRange.end")
                  port = start + secrets.randbelow(end - start + 1)
                  (out / "port").write_text(f"{port}\n")
                  (out / "transfer4").write_text(f"{transfer4.with_prefixlen}\n")
                  (out / "transfer6").write_text(f"{transfer6.with_prefixlen}\n")
                  PY
                '';
              };
            })
            peerNames
          );
        _networkFacts = {
          schemaVersion = 2;
          forwarding = lib.mkIf (ownRole == "spine" || (border != null && border.forwarding)) true;
          node.name = machine.name;
          fabric.${instanceName} = {
            topology = ownRole;
            inherit (ownSettings) access;
            forwarding = ownRole == "spine" || (border != null && border.forwarding);
            asn = ownAsn;
            inherit (ownAddress) ipv4 ipv6;
            loopback = loopbackName;
            border = {
              enabled = border != null;
              ownedPrefixes =
                if border != null
                then border.ownedPrefixes
                else [];
              upstreamPeers =
                if border != null
                then border.upstreamPeers
                else [];
              ndpInterfaces =
                if border != null
                then border.ndpInterfaces
                else [];
            };
            adjacencies = lib.listToAttrs (
              map (adjacency: {
                name = adjacency.remoteName;
                value = {
                  interface = adjacency.name;
                  remote = adjacency.remoteName;
                  inherit (adjacency.local) ipv4 ipv6;
                  prefix4 = adjacency.prefixes.ipv4;
                  prefix6 = adjacency.prefixes.ipv6;
                  inherit
                    (adjacency)
                    port
                    mtu
                    endpoint
                    allowedIPs
                    externalTransit
                    sourceReturn
                    timerProfile
                    ;
                };
              })
              adjacencies
            );
          };
          graphs.fabric =
            map (adjacency: {
              from = machine.name;
              to = adjacency.remoteName;
              kind = "adjacency";
            })
            adjacencies;
        };
      };

      environment.systemPackages = [
        pkgs.frr
        pkgs.wireguard-tools
      ];
      networking = {
        ifstate.settings = {
          interfaces = ifstateInterfaces;
          routing = {
            routes = ifstateRoutes;
            rules = ifstateRules;
          };
          sysctl_conf = lib.mkIf (ownRole == "spine" || (border != null && border.forwarding)) ''
            net.ipv4.ip_forward = 1
            net.ipv6.conf.all.forwarding = 1
          '';
        };
        nftables.enable = true;
        firewall = {
          allowedUDPPorts = lib.optionals ownSettings.firewall.openPort listenPorts;
          interfaces = lib.listToAttrs (
            map (adjacency: {
              inherit (adjacency) name;
              value = {
                allowedTCPPorts = [179];
                allowedUDPPorts = [
                  3784
                  4784
                ];
              };
            })
            adjacencies
          );
          extraInputRules = upstreamFirewallRules;
          trustedInterfaces = lib.optionals ownSettings.firewall.trust interfaceNames;
        };
      };
      services.frr = {
        bgpd.enable = true;
        bfdd.enable = true;
        config = frrConfig;
      };
      systemd.services.frr.after = ["ifstate.service"];
      services.ndppd = lib.mkIf (border != null && border.ndpInterfaces != []) {
        enable = true;
        proxies = lib.listToAttrs (
          map (interface: {
            name = interface;
            value.rules = lib.listToAttrs (
              map (prefix: {
                name = prefix;
                value.method = "static";
              }) (builtins.filter (lib.hasInfix ":") border.ownedPrefixes)
            );
          })
          border.ndpInterfaces
        );
      };
    };
  };
in {
  _class = "clan.service";
  manifest = {
    name = "routed-fabric";
    description = "Routed spine/leaf WireGuard, eBGP/BFD, and Zebra fabric with orthogonal access and border policy";
    categories = ["Network"];
    readme = builtins.readFile ./README.md;
    exports = {
      inputs = [
        "peer"
        "netif"
        "kube_cluster"
      ];
      out = [
        "networking"
        "peer"
        "node_transport"
        "routed_fabric"
      ];
    };
  };

  roles.leaf = {
    description = "Non-transit fabric participant attached to one or more derived spines";
    interface = roleInterface;
    inherit perInstance;
  };
  roles.spine = {
    description = "Forwarding and readvertising fabric spine with next-hop-self";
    interface = roleInterface;
    inherit perInstance;
  };

  perMachine = {
    instances,
    machine,
    ...
  }: {
    nixosModule = _: let
      memberships = lib.concatMap (
        instanceName: let
          instance = instances.${instanceName};
        in
          lib.optional (
            instance.roles ? leaf && instance.roles.leaf.machines ? ${machine.name}
          ) "${instanceName}:leaf"
          ++ lib.optional (
            instance.roles ? spine && instance.roles.spine.machines ? ${machine.name}
          ) "${instanceName}:spine"
      ) (builtins.attrNames instances);
    in {
      imports = [(import ../../lib/ifstate.nix {inherit ifstateOverlay;})];

      assertions = [
        {
          assertion = lib.length memberships <= 1;
          message = "routed-fabric: machine '${machine.name}' must hold exactly one topology role in at most one instance; got ${lib.concatStringsSep ", " memberships}";
        }
      ];
    };
  };
}
