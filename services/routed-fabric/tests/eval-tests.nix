{
  lib,
  module,
  clanLib,
  inputs,
  exportInterfaces,
  ...
}:
let
  fabric = import ../../../lib/kube-cluster/fabric.nix { inherit lib; };

  machineConfigs = lib.genAttrs [ "spine-a" "spine-b" "client" "admin" "node-a" ] (_: {
    nixpkgs.hostPlatform = "x86_64-linux";
  });

  clusterModule = {
    _class = "clan.service";
    manifest = {
      name = "k3s";
      description = "Eval-only cluster export fixture";
      readme = "Cluster export fixture for routed-fabric tests.";
      exports.out = [ "kube_cluster" ];
    };
    roles.default = {
      description = "Publish one cluster's non-secret facts";
      perInstance =
        { instanceName, mkExports, ... }:
        let
          second = instanceName == "cluster-b";
          member = if second then "spine-b" else "node-a";
        in
        {
          exports = mkExports {
            kube_cluster = {
              schemaVersion = 3;
              name = instanceName;
              ciliumId = if second then 2 else 1;
              network = {
                podCIDRv4 = if second then "10.3.0.0/16" else "10.1.0.0/16";
                podCIDRv6 = if second then "fd10:3::/56" else "fd10:1::/56";
                serviceCIDRv4 = if second then "10.4.0.0/16" else "10.2.0.0/16";
                serviceCIDRv6 = if second then "fd10:4::/112" else "fd10:2::/112";
                clusterDNS = if second then "10.4.0.10" else "10.2.0.10";
                fabric = {
                  service = "routed-fabric";
                  instance = "fleet";
                };
              };
              members.${member} = {
                role = "server";
                ipv4 = if second then "192.168.77.2" else "192.168.77.4";
                ipv6 = if second then "fd77::2" else "fd77::4";
              };
              pools.fabric = {
                scope = "cluster-global";
                delivery = "shared-bgp";
                blocks = [
                  (if second then "172.16.2.0/24" else "172.16.1.0/24")
                  (if second then "fd11:2::/64" else "fd11:1::/64")
                ];
              };
              bgp = {
                enabled = true;
                ciliumAsn = if second then 4200000002 else 4200000001;
                hostAsn = fabric.nodeAsn "fleet" member;
                advertiseClusterIPs = true;
              };
            };
          };
        };
    };
  };

  # D59 shape: two spines whose pair is derived automatically, leaves
  # attaching every spine by default, one explicit single-homed leaf.
  baseInventory = {
    instances = {
      fleet = {
        module.name = "routed-fabric";
        module.input = "self";
        roles = {
          spine.machines = {
            spine-a.settings = {
              ipv4 = "192.168.77.1";
              ipv6 = "fd77::1";
              endpoint = "spine-a.test";
            };
            spine-b.settings = {
              ipv4 = "192.168.77.2";
              ipv6 = "fd77::2";
              endpoint = "spine-b.test";
            };
          };
          leaf.machines = {
            client.settings = {
              ipv4 = "192.168.77.10";
              ipv6 = "fd77::10";
              access = "client";
            };
            admin.settings = {
              ipv4 = "192.168.77.11";
              ipv6 = "fd77::11";
              access = "admin";
              endpoint = "admin.test";
              spines = [ "spine-a" ];
            };
            node-a.settings = {
              ipv4 = "192.168.77.4";
              ipv6 = "fd77::4";
            };
          };
        };
      };
      cluster-a = {
        module.name = "k3s";
        module.input = "self";
        roles.default.machines.node-a = { };
      };
      cluster-b = {
        module.name = "k3s";
        module.input = "self";
        roles.default.machines.spine-b = { };
      };
    };
  };

  mkEvaled =
    inventory:
    clanLib.clan {
      self = { };
      directory = ./fixtures;
      inherit exportInterfaces;
      modules = {
        routed-fabric = module;
        netif = ../../netif/default.nix;
        k3s = clusterModule;
      };
      machines = machineConfigs;
      inherit inventory;
    };

  evaled = mkEvaled baseInventory;
  configs = evaled.config.nixosConfigurations;
  client = configs.client.config;
  admin = configs.admin.config;
  spine = configs.spine-a.config;
  spineB = configs.spine-b.config;
  node = configs.node-a.config;

  failedAssertion =
    config: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) config.assertions;
  netdevsFor =
    config:
    lib.filterAttrs (
      name: _: lib.hasPrefix "50-routed-fabric-fleet-rf" name
    ) config.systemd.network.netdevs;
  allowedFor =
    config:
    map (netdev: (builtins.head netdev.wireguardPeers).AllowedIPs) (
      builtins.attrValues (netdevsFor config)
    );

  withoutSpines = mkEvaled (
    baseInventory
    // {
      instances = baseInventory.instances // {
        fleet = baseInventory.instances.fleet // {
          roles = baseInventory.instances.fleet.roles // {
            spine.machines = { };
          };
        };
      };
    }
  );
  badSpine = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.leaf.machines.client.settings.spines = [ "admin" ];
    }
  );
  spineDeclaresSpines = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.spine.machines.spine-a.settings.spines = [ "spine-b" ];
    }
  );
  portEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.leaf.machines.client.settings.adjacencies.spine-a.port = 52820;
    }
  );
  portClient = portEval.config.nixosConfigurations.client.config;
  portSpine = portEval.config.nixosConfigurations.spine-a.config;

  mtuEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances = {
        underlay = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines = {
            spine-a.settings = {
              endpoint = "spine-a.test";
              links.wan = {
                interface = "enp1s0f0np0";
                mtu = 1400;
                static.ipv4 = [ "203.0.113.2/30" ];
                endpoint = true;
              };
            };
            client.settings = {
              endpoint = "client.test";
              links.wan = {
                interface = "enp1s0f1np1";
                mtu = 1400;
                static.ipv4 = [ "198.51.100.2/30" ];
                endpoint = true;
              };
            };
          };
        };
        fleet.roles = {
          spine.machines.spine-a.settings.endpointSources = [
            {
              service = "netif";
              instance = "underlay";
            }
          ];
          leaf.machines.client.settings.endpointSources = [
            {
              service = "netif";
              instance = "underlay";
            }
          ];
        };
      };
    }
  );
  mtuClient = mtuEval.config.nixosConfigurations.client.config;

  borderEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.spine.machines.spine-a.settings = {
        border = {
          ownedPrefixes = [
            "172.16.0.0/12"
            "fd11::/16"
          ];
          upstreamPeers = [
            {
              address = "203.0.113.1";
              asn = 64500;
            }
          ];
        };
        adjacencies.client = {
          externalTransit = true;
          sourceReturn = true;
        };
      };
    }
  );
  borderSpine = borderEval.config.nixosConfigurations.spine-a.config;
  borderClient = borderEval.config.nixosConfigurations.client.config;

  duplicateMembership = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.other = {
        module.name = "routed-fabric";
        module.input = "self";
        roles = {
          spine.machines.spine-a.settings.endpoint = "spine-a.test";
          leaf.machines.client.settings = { };
        };
      };
    }
  );

  # Endpoint derivation through an export source (the clan-core internet
  # underlay): spines dial each other's underlay hosts; leaves stay
  # outbound-only, so spine-side leaf peers render no Endpoint.
  endpointSourcesEval = clanLib.clan {
    self = { };
    directory = ./fixtures;
    inherit exportInterfaces;
    modules = {
      routed-fabric = module;
      internet = inputs.clan-core + "/clanServices/internet";
    };
    machines = machineConfigs;
    inventory = {
      instances = {
        underlay = {
          module.name = "internet";
          module.input = "self";
          roles.default.machines = {
            spine-a.settings.host = "192.168.1.4";
            spine-b.settings.host = "192.168.1.5";
            client.settings.host = "192.168.1.10";
            admin.settings.host = "192.168.1.11";
            node-a.settings.host = "192.168.1.12";
          };
        };
        fleet = baseInventory.instances.fleet // {
          roles = {
            spine.machines = {
              spine-a.settings = {
                ipv4 = "192.168.77.1";
                ipv6 = "fd77::1";
                endpointSources = [
                  {
                    service = "clan-core/internet";
                    instance = "underlay";
                  }
                ];
              };
              spine-b.settings = {
                ipv4 = "192.168.77.2";
                ipv6 = "fd77::2";
                endpointSources = [
                  {
                    service = "clan-core/internet";
                    instance = "underlay";
                  }
                ];
              };
            };
            leaf.machines = {
              client.settings = {
                ipv4 = "192.168.77.10";
                ipv6 = "fd77::10";
              };
              admin.settings = {
                ipv4 = "192.168.77.11";
                ipv6 = "fd77::11";
                spines = [ "spine-a" ];
              };
              node-a.settings = {
                ipv4 = "192.168.77.4";
                ipv6 = "fd77::4";
              };
            };
          };
        };
      };
    };
  };
  endpointSpineA = endpointSourcesEval.config.nixosConfigurations.spine-a.config;
  endpointSpineB = endpointSourcesEval.config.nixosConfigurations.spine-b.config;
  endpointClient = endpointSourcesEval.config.nixosConfigurations.client.config;
  spineSpineKey = fabric.adjacencyKey "fleet" "spine-a" "spine-b";
  spineSpineUnit = "50-routed-fabric-fleet-${fabric.adjacencyName spineSpineKey}";
  peerEndpoint =
    config: unit:
    let
      netdev = config.systemd.network.netdevs.${unit};
    in
    (builtins.head netdev.wireguardPeers).Endpoint or null;
in
{
  rendering = {
    test_oneInterfacePerAdjacency = {
      expr = {
        dualHomedLeaf = builtins.length (builtins.attrNames (netdevsFor client));
        singleHomedLeaf = builtins.length (builtins.attrNames (netdevsFor admin));
        spineA = builtins.length (builtins.attrNames (netdevsFor spine));
        spineB = builtins.length (builtins.attrNames (netdevsFor spineB));
      };
      expected = {
        dualHomedLeaf = 2;
        singleHomedLeaf = 1;
        spineA = 4;
        spineB = 3;
      };
    };
    test_derivedSpinePairAdjacency = {
      expr =
        let
          remoteNames =
            builtins.attrNames
              (clanLib.getExport {
                serviceName = "routed-fabric";
                instanceName = "fleet";
                roleName = "spine";
                machineName = "spine-a";
              } evaled.config.exports).routed_fabric.adjacencies;
        in
        {
          # The spine<->spine adjacency exists with no settings on either side.
          spinePairOnA = builtins.elem "spine-b" remoteNames;
          spinePairOnB = builtins.elem "spine-a" (
            builtins.attrNames
              (clanLib.getExport {
                serviceName = "routed-fabric";
                instanceName = "fleet";
                roleName = "spine";
                machineName = "spine-b";
              } evaled.config.exports).routed_fabric.adjacencies
          );
          noLeafLeaf =
            !(builtins.elem "client" (
              builtins.attrNames
                (clanLib.getExport {
                  serviceName = "routed-fabric";
                  instanceName = "fleet";
                  roleName = "leaf";
                  machineName = "admin";
                } evaled.config.exports).routed_fabric.adjacencies
            ));
        };
      expected = {
        spinePairOnA = true;
        spinePairOnB = true;
        noLeafLeaf = true;
      };
    };
    test_namesPortsAndMtu = {
      expr = lib.sortOn (entry: entry.ListenPort) (
        map (
          netdev:
          let
            peer = builtins.head netdev.wireguardPeers;
          in
          {
            nameLength = lib.stringLength netdev.netdevConfig.Name;
            peerCount = builtins.length netdev.wireguardPeers;
            inherit (netdev.netdevConfig) MTUBytes;
            inherit (netdev.wireguardConfig) ListenPort;
            allowedDefaultAclOnly = !(lib.hasInfix "0.0.0.0/0" (builtins.toJSON peer.AllowedIPs));
          }
        ) (builtins.attrValues (netdevsFor client))
      );
      expected = [
        {
          nameLength = 15;
          peerCount = 1;
          MTUBytes = 1404;
          ListenPort = 52679;
          allowedDefaultAclOnly = true;
        }
        {
          nameLength = 15;
          peerCount = 1;
          MTUBytes = 1404;
          ListenPort = 54843;
          allowedDefaultAclOnly = true;
        }
      ];
    };
    test_adjacencyPortOverride = {
      expr =
        let
          key = fabric.adjacencyKey "fleet" "client" "spine-a";
          unit = "50-routed-fabric-fleet-${fabric.adjacencyName key}";
        in
        map (config: config.systemd.network.netdevs.${unit}.wireguardConfig.ListenPort) [
          portClient
          portSpine
        ];
      expected = [
        52820
        52820
      ];
    };
    test_netifExportMtuDerivation = {
      expr = map (netdev: netdev.netdevConfig.MTUBytes) (builtins.attrValues (netdevsFor mtuClient));
      expected = [
        1304
        1304
      ];
    };
    test_endpointSourcesResolution = {
      expr =
        let
          leafUnits = lib.filterAttrs (
            n: _: lib.hasPrefix "50-routed-fabric-fleet-rf" n && n != spineSpineUnit
          ) endpointSpineA.systemd.network.netdevs;
        in
        {
          spinePairOnA = peerEndpoint endpointSpineA spineSpineUnit;
          spinePairOnB = peerEndpoint endpointSpineB spineSpineUnit;
          leafPeersOnSpineHaveNoEndpoint = lib.all (
            netdev: (builtins.head netdev.wireguardPeers).Endpoint or null == null
          ) (builtins.attrValues leafUnits);
          dualHomedLeafDialsBothSpines =
            (peerEndpoint endpointClient "50-routed-fabric-fleet-rfd0d91d1f47a84" == "192.168.1.4:52679")
            && (peerEndpoint endpointClient "50-routed-fabric-fleet-rfaa5538a64228d" == "192.168.1.5:54843");
        };
      expected = {
        spinePairOnA = "192.168.1.5:55962";
        spinePairOnB = "192.168.1.4:55962";
        leafPeersOnSpineHaveNoEndpoint = true;
        dualHomedLeafDialsBothSpines = true;
      };
    };
    test_wireguardLinkLocalAddressing = {
      expr =
        let
          networks = builtins.attrValues (
            lib.filterAttrs (
              name: _: lib.hasPrefix "50-routed-fabric-fleet-rf" name && name != "50-routed-fabric-fleet-loopback"
            ) spine.systemd.network.networks
          );
        in
        {
          linkLocal = lib.all (
            network:
            lib.any (address: lib.hasPrefix "fe80::" address && lib.hasSuffix "/64" address) network.address
          ) networks;
          transferScope = lib.all (
            network: lib.all (address: address.Scope == "link") network.addresses
          ) networks;
        };
      expected = {
        linkLocal = true;
        transferScope = true;
      };
    };
    test_loopbackAndIntegratedFrr = {
      expr = {
        addresses = spine.systemd.network.networks."50-routed-fabric-fleet-loopback".address;
        bgpd = spine.services.frr.bgpd.enable;
        bfdd = spine.services.frr.bfdd.enable;
        bfd = lib.hasInfix "bfd" spine.services.frr.config;
        originatesStable =
          lib.hasInfix "network 192.168.77.1/32" spine.services.frr.config
          && lib.hasInfix "network fd77::1/128" spine.services.frr.config;
        nextHopSelf = lib.hasInfix "next-hop-self" spine.services.frr.config;
        leafNextHopSelf = lib.hasInfix "next-hop-self" client.services.frr.config;
        ibgp = lib.hasInfix "route-reflector" spine.services.frr.config;
        preferredSource =
          lib.hasInfix "set src 192.168.77.1" spine.services.frr.config
          && lib.hasInfix "set src fd77::1" spine.services.frr.config
          && lib.hasInfix "ip protocol bgp route-map rf_source4" spine.services.frr.config
          && lib.hasInfix "ipv6 protocol bgp route-map rf_source6" spine.services.frr.config;
      };
      expected = {
        addresses = [
          "192.168.77.1/32"
          "fd77::1/128"
        ];
        bgpd = true;
        bfdd = true;
        bfd = true;
        originatesStable = true;
        nextHopSelf = true;
        preferredSource = true;
        leafNextHopSelf = false;
        ibgp = false;
      };
    };
    test_localCiliumFrr = {
      expr = {
        peer = lib.hasInfix "neighbor ::1 remote-as 4200000001" node.services.frr.config;
        extendedNextHop = lib.hasInfix "neighbor ::1 capability extended-nexthop" node.services.frr.config;
        bfd = lib.hasInfix "neighbor ::1 bfd" node.services.frr.config;
        nextHopRewrite =
          lib.hasInfix "set ip next-hop 192.168.77.4" node.services.frr.config
          && lib.hasInfix "set ipv6 next-hop global fd77::4" node.services.frr.config;
        podPolicy = lib.hasInfix "10.1.0.0/16 ge 24 le 24" node.services.frr.config;
        vipPolicy = lib.hasInfix "172.16.1.0/24 ge 32 le 32" node.services.frr.config;
        secondClusterPeer = lib.hasInfix "neighbor ::1 remote-as 4200000002" evaled.config.nixosConfigurations.spine-b.config.services.frr.config;
        secondClusterPods = lib.hasInfix "10.3.0.0/16 ge 24 le 24" node.services.frr.config;
      };
      expected = {
        peer = true;
        extendedNextHop = true;
        bfd = false;
        nextHopRewrite = true;
        podPolicy = true;
        vipPolicy = true;
        secondClusterPeer = true;
        secondClusterPods = true;
      };
    };
  };

  policy = {
    test_clientVipsOnly = {
      expr = {
        text = builtins.toJSON (allowedFor client);
        pods = lib.hasInfix "10.1.0.0/16" (builtins.toJSON (allowedFor client));
        services = lib.hasInfix "10.2.0.0/16" (builtins.toJSON (allowedFor client));
      };
      expected = {
        text = builtins.toJSON (allowedFor client);
        pods = false;
        services = false;
      };
    };
    test_adminPodsAndServices = {
      expr =
        let
          text = builtins.toJSON (allowedFor admin);
        in
        {
          pods = lib.hasInfix "10.1.0.0/16" text;
          services = lib.hasInfix "10.2.0.0/16" text;
        };
      expected = {
        pods = true;
        services = true;
      };
    };
    test_kubernetesLocalAdvertisements = {
      expr =
        let
          text = builtins.toJSON (allowedFor node);
        in
        {
          pods = lib.hasInfix "10.1.0.0/16" text;
          services = lib.hasInfix "10.2.0.0/16" text;
        };
      expected = {
        pods = true;
        services = true;
      };
    };
    test_spineReadvertisesWithAclParity = {
      expr = {
        vip = lib.hasInfix "172.16.1.0/24" (builtins.toJSON (allowedFor spine));
        pod = lib.hasInfix "10.1.0.0/16" (builtins.toJSON (allowedFor spine));
        policy = lib.hasInfix "172.16.1.0/24 ge 32 le 32" spine.services.frr.config;
      };
      expected = {
        vip = true;
        pod = true;
        policy = true;
      };
    };
    test_borderCryptoAclAndSourceReturn = {
      expr =
        let
          sourceNetworks = lib.filterAttrs (
            _: network: network.routingPolicyRules != [ ]
          ) borderSpine.systemd.network.networks;
          sourceRoutes = lib.concatMap (network: network.routes) (builtins.attrValues sourceNetworks);
        in
        {
          spineDefaultAcl = lib.hasInfix "0.0.0.0/0" (builtins.toJSON (allowedFor borderSpine));
          peerDefaultAcl = lib.hasInfix "::/0" (builtins.toJSON (allowedFor borderClient));
          upstream = lib.hasInfix "neighbor 203.0.113.1 remote-as 64500" borderSpine.services.frr.config;
          policyTables = lib.unique (map (route: route.Table) sourceRoutes);
          mainTables = lib.unique (
            map (route: route.Table or 254) (
              lib.concatMap (network: network.routes) (
                builtins.attrValues (
                  lib.filterAttrs (_: network: network.routingPolicyRules == [ ]) borderSpine.systemd.network.networks
                )
              )
            )
          );
        };
      expected = {
        spineDefaultAcl = true;
        peerDefaultAcl = true;
        upstream = true;
        policyTables = [ 39681 ];
        mainTables = [ ];
      };
    };
  };

  exports = {
    test_deepEval = {
      expr = builtins.deepSeq evaled.config.exports true;
      expected = true;
    };
    test_nodeTransportNativeProfile = {
      expr =
        let
          exported = clanLib.getExport {
            serviceName = "routed-fabric";
            instanceName = "fleet";
            roleName = "leaf";
            machineName = "client";
          } evaled.config.exports;
          transport = exported.node_transport;
        in
        {
          transportVersion = transport.schemaVersion;
          fabricVersion = exported.routed_fabric.schemaVersion;
          role = exported.routed_fabric.topology;
          access = exported.routed_fabric.access;
          adjacencyCount = builtins.length (builtins.attrNames exported.routed_fabric.adjacencies);
          mode = transport.datapath.mode;
          tunnelProtocol = transport.datapath.tunnelProtocol;
          routeExchange = transport.native.routeExchange;
          inherit (transport) internalLoadBalancer nodePort;
          interfacesKeyedByLinuxName = lib.all (
            name:
            name == exported.routed_fabric.loopback || (lib.hasPrefix "rf" name && lib.stringLength name == 15)
          ) (builtins.attrNames transport.interfaces);
          directRoutingDeviceNamesInterface = builtins.elem transport.directRoutingDevice (
            builtins.attrNames transport.interfaces
          );
          directRoutingDeviceIsStableLoopback =
            transport.directRoutingDevice == exported.routed_fabric.loopback;
          everyInterfaceHasMtu = lib.all (iface: iface.mtu == 1404) (
            builtins.attrValues transport.interfaces
          );
        };
      expected = {
        transportVersion = 2;
        fabricVersion = 2;
        role = "leaf";
        access = "client";
        adjacencyCount = 2;
        mode = "native";
        tunnelProtocol = null;
        routeExchange = "local-router";
        internalLoadBalancer = true;
        nodePort = true;
        interfacesKeyedByLinuxName = true;
        directRoutingDeviceNamesInterface = true;
        directRoutingDeviceIsStableLoopback = true;
        everyInterfaceHasMtu = true;
      };
    };
    test_networkFactsDeepEvalAndParity = {
      expr = {
        deep = builtins.deepSeq client.clan.networkFacts true;
        schemaVersion = client.clan.networkFacts.schemaVersion;
        node = client.clan.networkFacts.node.name;
        role = client.clan.networkFacts.fabric.fleet.topology;
        access = client.clan.networkFacts.fabric.fleet.access;
        adjacencies = builtins.length (
          builtins.attrNames client.clan.networkFacts.fabric.fleet.adjacencies
        );
        graphEdges = builtins.length client.clan.networkFacts.graphs.fabric;
      };
      expected = {
        deep = true;
        schemaVersion = 2;
        node = "client";
        role = "leaf";
        access = "client";
        adjacencies = 2;
        graphEdges = 2;
      };
    };
  };

  validation = {
    test_leafNeedsSpine = {
      expr = failedAssertion withoutSpines.config.nixosConfigurations.client.config "must attach to at least one spine";
      expected = true;
    };
    test_leafSpineRoleReference = {
      expr = failedAssertion badSpine.config.nixosConfigurations.client.config "invalid or non-spine references";
      expected = true;
    };
    test_spineMustNotDeclareSpines = {
      expr = failedAssertion spineDeclaresSpines.config.nixosConfigurations.spine-a.config "must not declare settings.spines";
      expected = true;
    };
    test_oneFabricMembership = {
      expr = failedAssertion duplicateMembership.config.nixosConfigurations.client.config "at most one instance";
      expected = true;
    };
  };
}
