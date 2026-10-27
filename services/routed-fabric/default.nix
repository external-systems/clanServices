{
  clanLib,
  lib,
  ...
}:
let
  fabric = import ../../lib/kube-cluster/fabric.nix { inherit lib; };
  frr = import ../../lib/kube-cluster/frr.nix { inherit lib; };

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
        description = "Override the deterministic UDP port for this adjacency.";
      };
      underlayMtu = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Override the smallest underlay MTU used for this adjacency.";
      };
      extraAllowedIPs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
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
    };
  };

  roleInterface =
    { lib, ... }:
    {
      options = {
        ipv4 = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Stable fabric IPv4 host address without a prefix; null derives it deterministically.";
        };
        ipv6 = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Stable fabric IPv6 host address without a prefix; null derives it deterministically.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 51820;
          description = "Base UDP port from which deterministic per-adjacency listen ports derive.";
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
          default = [ ];
          description = "Ordered peer export sources used when endpoint is null.";
        };
        spines = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
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
          default = { };
          description = "Optional per-remote adjacency overrides keyed by remote machine name.";
        };
        border = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                ownedPrefixes = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Prefixes this border may originate and accept from upstream.";
                };
                upstreamPeers = lib.mkOption {
                  type = lib.types.listOf (
                    lib.types.submodule {
                      options = {
                        address = lib.mkOption {
                          type = lib.types.str;
                          description = "Upstream BGP peer address.";
                        };
                        asn = lib.mkOption {
                          type = lib.types.ints.between 1 4294967295;
                          description = "Upstream BGP peer ASN.";
                        };
                      };
                    }
                  );
                  default = [ ];
                  description = "External BGP peers, independent of fabric spine/leaf topology.";
                };
                ndpInterfaces = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
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
            description = "Open deterministic WireGuard UDP listen ports.";
          };
          trust = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Trust traffic arriving on routed-fabric WireGuard interfaces.";
          };
        };
      };
    };

  resolveHostValue =
    host:
    host.plain or (
      if host ? var then
        clanLib.getPublicValue (host.var // { default = ""; })
      else
        throw "routed-fabric: unsupported peer host value ${builtins.toJSON host}"
    );

  endpointFromSources =
    {
      exports,
      sources,
      machineName,
    }:
    let
      hostsForSource =
        source:
        let
          matches = lib.attrValues (
            clanLib.selectExports (
              scope:
              scope.serviceName == source.service
              && scope.instanceName == source.instance
              && scope.machineName == machineName
            ) exports
          );
        in
        lib.concatMap (value: value.peer.hosts or [ ]) matches;
      values = lib.filter (value: value != "" && value != null) (
        map (host: lib.trim (resolveHostValue host)) (lib.concatMap hostsForSource sources)
      );
    in
    if values == [ ] then null else builtins.head values;

  mtuFromSources =
    {
      exports,
      sources,
      machineName,
    }:
    let
      mtusForSource =
        source:
        let
          matches = lib.attrValues (
            clanLib.selectExports (
              scope:
              scope.serviceName == source.service
              && scope.instanceName == source.instance
              && scope.machineName == machineName
            ) exports
          );
        in
        lib.filter (mtu: mtu != null) (map (value: value.netif.mtu or null) matches);
      values = lib.concatMap mtusForSource sources;
    in
    if values == [ ] then null else builtins.head values;

  endpointString =
    host: port:
    if host == null then
      null
    else if lib.hasInfix ":" host then
      "[${host}]:${toString port}"
    else
      "${host}:${toString port}";

  roleFor =
    roles: machineName:
    if (roles.spine.machines or { }) ? ${machineName} then
      "spine"
    else if (roles.leaf.machines or { }) ? ${machineName} then
      "leaf"
    else
      null;

  # D59: a leaf attaches every spine by default; an explicit spines
  # subset is allowed. Spines derive their attachments symmetrically.
  attachedSpines =
    roles: leafName:
    let
      leafSettings = roles.leaf.machines.${leafName}.settings;
      allSpines = lib.sort builtins.lessThan (builtins.attrNames (roles.spine.machines or { }));
    in
    if leafSettings.spines == [ ] then allSpines else lib.unique leafSettings.spines;

  leavesAttachedTo =
    roles: spineName:
    lib.sort builtins.lessThan (
      builtins.attrNames (
        lib.filterAttrs (
          name: leaf: name != spineName && builtins.elem spineName (attachedSpines roles name)
        ) (roles.leaf.machines or { })
      )
    );

  perInstance =
    {
      instanceName,
      machine,
      roles,
      exports,
      mkExports,
      ...
    }:
    let
      allMachines = (roles.leaf.machines or { }) // (roles.spine.machines or { });
      ownRole = roleFor roles machine.name;
      ownSettings = allMachines.${machine.name}.settings;

      addressOf = name: {
        ipv4 =
          if allMachines.${name}.settings.ipv4 != null then
            allMachines.${name}.settings.ipv4
          else
            fabric.stableIpv4 instanceName name;
        ipv6 =
          if allMachines.${name}.settings.ipv6 != null then
            allMachines.${name}.settings.ipv6
          else
            fabric.stableIpv6 instanceName name;
      };
      ownAddress = addressOf machine.name;
      stableHosts = lib.concatMap (
        name:
        let
          address = addressOf name;
        in
        [
          "${address.ipv4}/32"
          "${address.ipv6}/128"
        ]
      ) (builtins.attrNames allMachines);

      allExports = lib.attrValues (clanLib.selectExports (_: true) exports);
      clusterExports = builtins.filter (value: value ? kube_cluster) allExports;
      clusterList = map (value: value.kube_cluster) (
        builtins.filter (
          value:
          let
            facts = value.kube_cluster;
            reference = facts.network.fabric or facts.transport;
          in
          reference.service != null
          && reference.instance != null
          && reference.service == "routed-fabric"
          && reference.instance == instanceName
        ) clusterExports
      );
      kubernetesMachines = lib.unique (
        lib.concatMap (facts: builtins.attrNames facts.members) clusterList
      );
      isKubernetes = name: builtins.elem name kubernetesMachines;

      clusterRoutes =
        facts:
        let
          pools = lib.filterAttrs (
            _: pool: pool.delivery == "shared-bgp" || pool.delivery == "node-bgp"
          ) facts.pools;
        in
        {
          hosts = [ ];
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
      localRoutes = localClusterRoutes // {
        hosts = [
          "${ownAddress.ipv4}/32"
          "${ownAddress.ipv6}/128"
        ];
      };

      consumptionRoutes =
        name:
        let
          access = allMachines.${name}.settings.access;
          includePods = isKubernetes name || access == "admin";
          includeServices = access == "admin" && !isKubernetes name;
          localFacts = builtins.filter (facts: facts.members ? ${name}) clusterList;
          fullPeering = lib.all (facts: (facts.mesh.peers or null) == null) localFacts;
          selectedPeers = lib.unique (
            lib.concatMap (
              facts: if (facts.mesh.peers or null) == null then [ ] else facts.mesh.peers
            ) localFacts
          );
          accessibleFacts = builtins.filter (
            facts: facts.members ? ${name} || fullPeering || builtins.elem facts.name selectedPeers
          ) clusterList;
          accessibleRoutes = frr.mergeRoutes (map clusterRoutes accessibleFacts);
        in
        {
          hosts = stableHosts;
          inherit (accessibleRoutes) vips;
          pods = lib.optionals includePods accessibleRoutes.pods;
          services = lib.optionals includeServices accessibleRoutes.services;
        };

      spineNames = lib.sort builtins.lessThan (builtins.attrNames (roles.spine.machines or { }));
      peerNames =
        if ownRole == "spine" then
          lib.unique (
            (builtins.filter (name: name != machine.name) spineNames) ++ leavesAttachedTo roles machine.name
          )
        else
          attachedSpines roles machine.name;

      endpointOf =
        name:
        let
          machineSettings = allMachines.${name}.settings;
        in
        if machineSettings.endpoint != null then
          machineSettings.endpoint
        else
          endpointFromSources {
            inherit exports;
            sources = machineSettings.endpointSources;
            machineName = name;
          };

      underlayMtuOf =
        name:
        let
          machineSettings = allMachines.${name}.settings;
          exportedMtu = mtuFromSources {
            inherit exports;
            sources = machineSettings.endpointSources;
            machineName = name;
          };
        in
        if exportedMtu != null then exportedMtu else machineSettings.underlayMtu;

      mkAdjacency =
        remoteName:
        let
          remoteSettings = allMachines.${remoteName}.settings;
          transfer = fabric.transferAddresses instanceName machine.name remoteName;
          localIsFirst =
            transfer.ordered == lib.sort builtins.lessThan [
              machine.name
              remoteName
            ]
            && machine.name == builtins.head transfer.ordered;
          localAddress = if localIsFirst then transfer.localFirst else transfer.localSecond;
          remoteAddress = if localIsFirst then transfer.localSecond else transfer.localFirst;
          inherit (transfer) key;
          localOverride = ownSettings.adjacencies.${remoteName} or { };
          remoteOverride = remoteSettings.adjacencies.${machine.name} or { };
          port =
            if (localOverride.port or null) != null then
              localOverride.port
            else if (remoteOverride.port or null) != null then
              remoteOverride.port
            else
              fabric.adjacencyPort ownSettings.port key;
          remotePort =
            if (localOverride.port or null) != null then
              localOverride.port
            else if (remoteOverride.port or null) != null then
              remoteOverride.port
            else
              fabric.adjacencyPort remoteSettings.port key;
          endpointHost =
            if (localOverride.endpoint or null) != null then localOverride.endpoint else endpointOf remoteName;
          endpoint = endpointString endpointHost remotePort;
          underlayMtu =
            if (localOverride.underlayMtu or null) != null then
              localOverride.underlayMtu
            else
              lib.min (underlayMtuOf machine.name) (underlayMtuOf remoteName);
          mtu = fabric.adjacencyMtu underlayMtu;
          externalTransit =
            (localOverride.externalTransit or false) || (remoteOverride.externalTransit or false);
          sourceReturn = localOverride.sourceReturn or false;
          extraAllowedIPs = localOverride.extraAllowedIPs or [ ];
          remoteRole = roleFor roles remoteName;
          import =
            if ownRole == "spine" && remoteRole == "spine" then
              consumptionRoutes machine.name
            else if ownRole == "spine" then
              (clusterRoutesFor remoteName)
              // {
                hosts =
                  let
                    address = addressOf remoteName;
                  in
                  [
                    "${address.ipv4}/32"
                    "${address.ipv6}/128"
                  ];
              }
            else
              consumptionRoutes machine.name;
          export = if ownRole == "spine" then consumptionRoutes remoteName else localRoutes;
          cryptoRoutes = frr.mergeRoutes [
            import
            export
            {
              hosts = [
                "${remoteAddress.ipv4}/32"
                "${remoteAddress.ipv6}/128"
              ]
              ++ extraAllowedIPs;
              vips = [ ];
              pods = [ ];
              services = [ ];
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
          linkLocal =
            let
              hash = builtins.hashString "sha256" "${key}:${machine.name}";
            in
            "fe80::${builtins.substring 0 4 hash}:${builtins.substring 4 4 hash}:${builtins.substring 8 4 hash}:${builtins.substring 12 4 hash}";
          table = 200 + lib.mod (fabric.nodeAsn instanceName remoteName) 40000;
        in
        {
          inherit
            allowedIPs
            endpoint
            export
            externalTransit
            import
            key
            linkLocal
            mtu
            name
            port
            remoteName
            sourceReturn
            table
            underlayMtu
            ;
          local = localAddress;
          remote = remoteAddress;
          remoteAsn = fabric.nodeAsn instanceName remoteName;
          nextHopSelf = ownRole == "spine";
          inherit (ownSettings) maximumPaths;
          inherit (transfer) prefixes;
        };

      clusterRoutesFor =
        name:
        frr.mergeRoutes (
          [
            {
              hosts = [ ];
              vips = [ ];
              pods = [ ];
              services = [ ];
            }
          ]
          ++ map clusterRoutes (builtins.filter (facts: facts.members ? ${name}) clusterList)
        );

      adjacencies = map mkAdjacency peerNames;
      ownAsn = fabric.nodeAsn instanceName machine.name;
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
      ownSpines = if ownRole == "leaf" then attachedSpines roles machine.name else [ ];
      invalidSpines = builtins.filter (name: roleFor roles name != "spine") ownSettings.spines;
      unreachables = builtins.filter (
        adjacency: adjacency.endpoint == null && endpointOf machine.name == null
      ) adjacencies;
      allAddresses = lib.concatMap (
        name:
        let
          address = addressOf name;
        in
        [
          address.ipv4
          address.ipv6
        ]
      ) (builtins.attrNames allMachines);
      interfaceNames = map (adjacency: adjacency.name) adjacencies;
      listenPorts = map (adjacency: adjacency.port) adjacencies;
      sourceReturns = builtins.filter (adjacency: adjacency.sourceReturn) adjacencies;
      inherit (ownSettings) border;

      # D58: routed-fabric is the native transport — every adjacency
      # WireGuard interface is a datapath interface keyed by its Linux
      # name. The stable loopback is also exported on every node and is the
      # uniform directRoutingDevice in the cluster-wide Cilium ConfigMap.
      transportInterfaces = {
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
        }) adjacencies
      );
      directRoutingDevice = loopbackName;
    in
    {
      exports = mkExports {
        peer.hosts = [
          { plain = ownAddress.ipv4; }
          { plain = ownAddress.ipv6; }
        ];
        node_transport = {
          schemaVersion = 2;
          inherit (ownAddress) ipv4 ipv6;
          inherit (ownSettings) port;
          instance = instanceName;
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
            ownedPrefixes = if border != null then border.ownedPrefixes else [ ];
          };
          loopback = loopbackName;
          adjacencies = lib.listToAttrs (
            map (adjacency: {
              name = adjacency.remoteName;
              value = {
                inherit (adjacency)
                  allowedIPs
                  endpoint
                  mtu
                  name
                  port
                  prefixes
                  ;
                inherit (adjacency.local) ipv4 ipv6;
              };
            }) adjacencies
          );
        };
      };

      nixosModule =
        { config, pkgs, ... }:
        let
          generatorName = "routed-fabric-${instanceName}";
          privateKeyFile = config.clan.core.vars.generators.${generatorName}.files.privatekey.path;
          publicKeyOf =
            name:
            lib.trim (
              clanLib.getPublicValue {
                generator = generatorName;
                machine = name;
                file = "publickey";
                flake = config.clan.core.settings.directory;
                default = throw "routed-fabric/${instanceName}: missing public key for '${name}' (${generatorName})";
              }
            );
          unitName = adjacency: "50-routed-fabric-${instanceName}-${adjacency.name}";
          wireguardNetdevs = lib.listToAttrs (
            map (adjacency: {
              name = unitName adjacency;
              value = {
                netdevConfig = {
                  Kind = "wireguard";
                  Name = adjacency.name;
                  MTUBytes = adjacency.mtu;
                };
                wireguardConfig = {
                  PrivateKeyFile = privateKeyFile;
                  ListenPort = adjacency.port;
                };
                wireguardPeers = [
                  (
                    {
                      PublicKey = publicKeyOf adjacency.remoteName;
                      AllowedIPs = adjacency.allowedIPs;
                      PersistentKeepalive = 25;
                    }
                    // lib.optionalAttrs (adjacency.endpoint != null) { Endpoint = adjacency.endpoint; }
                  )
                ];
              };
            }) adjacencies
          );
          wireguardNetworks = lib.listToAttrs (
            map (adjacency: {
              name = unitName adjacency;
              value = {
                matchConfig.Name = adjacency.name;
                networkConfig.LinkLocalAddressing = "no";
                address = [ "${adjacency.linkLocal}/64" ];
                addresses = [
                  {
                    Address = "${adjacency.local.ipv4}/31";
                    Scope = "link";
                  }
                  {
                    Address = "${adjacency.local.ipv6}/127";
                    Scope = "link";
                  }
                ];
                routes = lib.optionals adjacency.sourceReturn [
                  {
                    Destination = "0.0.0.0/0";
                    Gateway = adjacency.remote.ipv4;
                    Table = adjacency.table;
                  }
                  {
                    Destination = "::/0";
                    Gateway = adjacency.remote.ipv6;
                    Table = adjacency.table;
                  }
                ];
                routingPolicyRules = lib.optionals adjacency.sourceReturn (
                  map (prefix: {
                    From = prefix;
                    Table = adjacency.table;
                  }) (if border != null then border.ownedPrefixes else [ ])
                );
              };
            }) adjacencies
          );
        in
        {
          imports = [ ../../lib/kube-cluster/network-facts.nix ];

          assertions = [
            {
              assertion = ownRole == "spine" || ownSpines != [ ];
              message = "routed-fabric/${instanceName}: leaf '${machine.name}' must attach to at least one spine-role machine";
            }
            {
              assertion = invalidSpines == [ ];
              message = "routed-fabric/${instanceName}: invalid or non-spine references on '${machine.name}': ${lib.concatStringsSep ", " invalidSpines}";
            }
            {
              assertion = ownRole != "spine" || ownSettings.spines == [ ];
              message = "routed-fabric/${instanceName}: spine '${machine.name}' must not declare settings.spines (spine pairs and leaf attachments are derived)";
            }
            {
              assertion = unreachables == [ ];
              message = "routed-fabric/${instanceName}: each adjacency needs at least one reachable endpoint; missing ${
                lib.concatMapStringsSep ", " (adjacency: adjacency.key) unreachables
              }";
            }
            {
              assertion = lib.length (lib.unique allAddresses) == lib.length allAddresses;
              message = "routed-fabric/${instanceName}: stable host addresses must be unique";
            }
            {
              assertion =
                lib.length (lib.unique interfaceNames) == lib.length interfaceNames
                && lib.all (name: lib.stringLength name <= 15) interfaceNames;
              message = "routed-fabric/${instanceName}: adjacency interface names collide or exceed 15 characters";
            }
            {
              assertion = lib.length (lib.unique listenPorts) == lib.length listenPorts;
              message = "routed-fabric/${instanceName}: adjacency listen ports collide";
            }
            {
              assertion = lib.all (
                adjacency: adjacency.mtu >= 1280 && adjacency.mtu <= adjacency.underlayMtu - 80
              ) adjacencies;
              message = "routed-fabric/${instanceName}: derived WireGuard MTU violates the dual-stack underlay budget";
            }
            {
              assertion = border == null || (border.ownedPrefixes != [ ] && border.upstreamPeers != [ ]);
              message = "routed-fabric/${instanceName}: border requires ownedPrefixes and upstreamPeers";
            }
            {
              assertion =
                border == null
                || !(builtins.elem "0.0.0.0/0" border.ownedPrefixes || builtins.elem "::/0" border.ownedPrefixes);
              message = "routed-fabric/${instanceName}: border ownedPrefixes must not contain default routes";
            }
            {
              assertion = sourceReturns == [ ] || border != null;
              message = "routed-fabric/${instanceName}: sourceReturn requires border.ownedPrefixes";
            }
          ];

          clan = {
            core.vars.generators.${generatorName} = {
              files.privatekey = {
                owner = "systemd-network";
                group = "systemd-network";
                mode = "0400";
                restartUnits = [ "systemd-networkd.service" ];
              };
              files.publickey = {
                secret = false;
                deploy = false;
              };
              runtimeInputs = [ pkgs.wireguard-tools ];
              script = ''
                wg genkey > "$out"/privatekey
                wg pubkey < "$out"/privatekey > "$out"/publickey
              '';
            };
            _networkFacts = {
              schemaVersion = 2;
              node.name = machine.name;
              fabric.${instanceName} = {
                topology = ownRole;
                inherit (ownSettings) access;
                asn = ownAsn;
                inherit (ownAddress) ipv4 ipv6;
                loopback = loopbackName;
                border = {
                  enabled = border != null;
                  ownedPrefixes = if border != null then border.ownedPrefixes else [ ];
                  upstreamPeers = if border != null then border.upstreamPeers else [ ];
                  ndpInterfaces = if border != null then border.ndpInterfaces else [ ];
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
                      inherit (adjacency)
                        port
                        mtu
                        endpoint
                        allowedIPs
                        externalTransit
                        sourceReturn
                        ;
                    };
                  }) adjacencies
                );
              };
              graphs.fabric = map (adjacency: {
                from = machine.name;
                to = adjacency.remoteName;
                kind = "adjacency";
              }) adjacencies;
            };
          };

          environment.systemPackages = [
            pkgs.frr
            pkgs.wireguard-tools
          ];
          networking = {
            useNetworkd = true;
            nftables.enable = true;
            networkmanager.unmanaged = [ loopbackName ] ++ interfaceNames;
            firewall = {
              allowedTCPPorts = [ 179 ];
              allowedUDPPorts = lib.optionals ownSettings.firewall.openPort listenPorts ++ [
                3784
                4784
              ];
              trustedInterfaces = lib.optionals ownSettings.firewall.trust interfaceNames;
            };
          };
          services.frr = {
            bgpd.enable = true;
            bfdd.enable = true;
            config = frrConfig;
          };
          boot.kernel.sysctl = lib.mkMerge [
            (lib.mkIf (ownRole == "spine" || (border != null && border.forwarding)) {
              "net.ipv4.ip_forward" = lib.mkDefault true;
              "net.ipv6.conf.all.forwarding" = lib.mkDefault true;
            })
          ];
          systemd = {
            network = {
              enable = true;
              netdevs = wireguardNetdevs // {
                "50-routed-fabric-${instanceName}-loopback" = {
                  netdevConfig = {
                    Kind = "dummy";
                    Name = loopbackName;
                  };
                };
              };
              networks = wireguardNetworks // {
                "50-routed-fabric-${instanceName}-loopback" = {
                  matchConfig.Name = loopbackName;
                  address = [
                    "${ownAddress.ipv4}/32"
                    "${ownAddress.ipv6}/128"
                  ];
                };
              };
            };
          };
          services.ndppd = lib.mkIf (border != null && border.ndpInterfaces != [ ]) {
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
              }) border.ndpInterfaces
            );
          };
        };
    };
in
{
  _class = "clan.service";
  manifest = {
    name = "routed-fabric";
    description = "Routed spine/leaf WireGuard, eBGP/BFD, and Zebra fabric with orthogonal access and border policy";
    categories = [ "Network" ];
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

  perMachine =
    { instances, machine, ... }:
    {
      nixosModule =
        _:
        let
          memberships = lib.concatMap (
            instanceName:
            let
              instance = instances.${instanceName};
            in
            lib.optional (
              instance.roles ? leaf && instance.roles.leaf.machines ? ${machine.name}
            ) "${instanceName}:leaf"
            ++ lib.optional (
              instance.roles ? spine && instance.roles.spine.machines ? ${machine.name}
            ) "${instanceName}:spine"
          ) (builtins.attrNames instances);
        in
        {
          assertions = [
            {
              assertion = lib.length memberships <= 1;
              message = "routed-fabric: machine '${machine.name}' must hold exactly one topology role in at most one instance; got ${lib.concatStringsSep ", " memberships}";
            }
          ];
        };
    };
}
