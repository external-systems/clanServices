{
  lib,
  module,
  clanLib,
  exportInterfaces,
  ...
}:
let
  fabric = import ../../../lib/kube-cluster/fabric.nix { inherit lib; };

  machineConfigs = lib.genAttrs [ "hub-a" "hub-b" "client" "admin" "node-a" ] (_: {
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
        {
          exports = mkExports {
            kube_cluster = {
              schemaVersion = 3;
              name = instanceName;
              ciliumId = 1;
              network = {
                podCIDRv4 = "10.1.0.0/16";
                podCIDRv6 = "fd10:1::/56";
                serviceCIDRv4 = "10.2.0.0/16";
                serviceCIDRv6 = "fd10:2::/112";
                clusterDNS = "10.2.0.10";
                fabric = {
                  service = "routed-fabric";
                  instance = "fleet";
                };
              };
              members.node-a = {
                role = "server";
                ipv4 = "192.168.77.4";
                ipv6 = "fd77::4";
              };
              pools.fabric = {
                scope = "cluster-global";
                delivery = "shared-bgp";
                blocks = [
                  "172.16.1.0/24"
                  "fd11:1::/64"
                ];
              };
              bgp = {
                enabled = true;
                ciliumAsn = 4200000001;
                hostAsn = fabric.nodeAsn "fleet" "node-a";
                advertiseClusterIPs = true;
              };
            };
          };
        };
    };
  };

  baseInventory = {
    instances = {
      fleet = {
        module.name = "routed-fabric";
        module.input = "self";
        roles = {
          hub.machines = {
            hub-a.settings = {
              ipv4 = "192.168.77.1";
              ipv6 = "fd77::1";
              endpoint = "hub-a.test";
              hubs = [ "hub-b" ];
            };
            hub-b.settings = {
              ipv4 = "192.168.77.2";
              ipv6 = "fd77::2";
              endpoint = "hub-b.test";
              hubs = [ "hub-a" ];
            };
          };
          member.machines = {
            client.settings = {
              ipv4 = "192.168.77.10";
              ipv6 = "fd77::10";
              access = "client";
              hubs = [
                "hub-a"
                "hub-b"
              ];
            };
            admin.settings = {
              ipv4 = "192.168.77.11";
              ipv6 = "fd77::11";
              access = "admin";
              endpoint = "admin.test";
              hubs = [ "hub-a" ];
            };
            node-a.settings = {
              ipv4 = "192.168.77.4";
              ipv6 = "fd77::4";
              hubs = [ "hub-a" ];
            };
          };
        };
      };
      cluster-a = {
        module.name = "k3s";
        module.input = "self";
        roles.default.machines.node-a = { };
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
  hub = configs.hub-a.config;
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

  noHub = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.member.machines.client.settings.hubs = [ ];
    }
  );
  badHub = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.member.machines.client.settings.hubs = [ "admin" ];
    }
  );
  oneWayHubs = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.hub.machines.hub-b.settings.hubs = [ ];
    }
  );
  portEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.member.machines.client.settings.adjacencies.hub-a.port = 52820;
    }
  );
  portClient = portEval.config.nixosConfigurations.client.config;
  portHub = portEval.config.nixosConfigurations.hub-a.config;

  mtuEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances = {
        underlay = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines = {
            hub-a.settings = {
              endpoint = "hub-a.test";
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
          hub.machines.hub-a.settings.endpointSources = [
            {
              service = "netif";
              instance = "underlay";
            }
          ];
          member.machines.client.settings.endpointSources = [
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
      instances.fleet.roles.hub.machines.hub-a.settings = {
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
  borderHub = borderEval.config.nixosConfigurations.hub-a.config;
  borderClient = borderEval.config.nixosConfigurations.client.config;

  duplicateMembership = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.other = {
        module.name = "routed-fabric";
        module.input = "self";
        roles = {
          hub.machines.hub-a.settings.endpoint = "hub-a.test";
          member.machines.client.settings.hubs = [ "hub-a" ];
        };
      };
    }
  );
in
{
  rendering = {
    test_oneInterfacePerAdjacency = {
      expr = {
        client = builtins.length (builtins.attrNames (netdevsFor client));
        hub = builtins.length (builtins.attrNames (netdevsFor hub));
      };
      expected = {
        client = 2;
        hub = 4;
      };
    };
    test_namesPortsAndMtu = {
      expr = map (
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
      ) (builtins.attrValues (netdevsFor client));
      expected = [
        {
          nameLength = 15;
          peerCount = 1;
          MTUBytes = 1404;
          ListenPort = 59667;
          allowedDefaultAclOnly = true;
        }
        {
          nameLength = 15;
          peerCount = 1;
          MTUBytes = 1404;
          ListenPort = 58417;
          allowedDefaultAclOnly = true;
        }
      ];
    };
    test_adjacencyPortOverride = {
      expr =
        let
          key = fabric.adjacencyKey "fleet" "client" "hub-a";
          unit = "50-routed-fabric-fleet-${fabric.adjacencyName key}";
        in
        map (config: config.systemd.network.netdevs.${unit}.wireguardConfig.ListenPort) [
          portClient
          portHub
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
    test_wireguardLinkLocalAddressing = {
      expr =
        let
          networks = builtins.attrValues (
            lib.filterAttrs (
              name: _: lib.hasPrefix "50-routed-fabric-fleet-rf" name && name != "50-routed-fabric-fleet-loopback"
            ) hub.systemd.network.networks
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
        addresses = hub.systemd.network.networks."50-routed-fabric-fleet-loopback".address;
        bgpd = hub.services.frr.bgpd.enable;
        bfdd = hub.services.frr.bfdd.enable;
        bfd = lib.hasInfix "bfd" hub.services.frr.config;
        originatesStable =
          lib.hasInfix "network 192.168.77.1/32" hub.services.frr.config
          && lib.hasInfix "network fd77::1/128" hub.services.frr.config;
        nextHopSelf = lib.hasInfix "next-hop-self" hub.services.frr.config;
        memberNextHopSelf = lib.hasInfix "next-hop-self" client.services.frr.config;
        ibgp = lib.hasInfix "route-reflector" hub.services.frr.config;
        preferredSource =
          lib.hasInfix "set src 192.168.77.1" hub.services.frr.config
          && lib.hasInfix "set src fd77::1" hub.services.frr.config
          && lib.hasInfix "ip protocol bgp route-map rf_source4" hub.services.frr.config
          && lib.hasInfix "ipv6 protocol bgp route-map rf_source6" hub.services.frr.config;
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
        memberNextHopSelf = false;
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
      };
      expected = {
        peer = true;
        extendedNextHop = true;
        bfd = false;
        nextHopRewrite = true;
        podPolicy = true;
        vipPolicy = true;
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
    test_hubReadvertisesWithAclParity = {
      expr = {
        vip = lib.hasInfix "172.16.1.0/24" (builtins.toJSON (allowedFor hub));
        pod = lib.hasInfix "10.1.0.0/16" (builtins.toJSON (allowedFor hub));
        policy = lib.hasInfix "172.16.1.0/24 ge 32 le 32" hub.services.frr.config;
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
          ) borderHub.systemd.network.networks;
          sourceRoutes = lib.concatMap (network: network.routes) (builtins.attrValues sourceNetworks);
        in
        {
          hubDefaultAcl = lib.hasInfix "0.0.0.0/0" (builtins.toJSON (allowedFor borderHub));
          peerDefaultAcl = lib.hasInfix "::/0" (builtins.toJSON (allowedFor borderClient));
          upstream = lib.hasInfix "neighbor 203.0.113.1 remote-as 64500" borderHub.services.frr.config;
          policyTables = lib.unique (map (route: route.Table) sourceRoutes);
          mainTables = lib.unique (
            map (route: route.Table or 254) (
              lib.concatMap (network: network.routes) (
                builtins.attrValues (
                  lib.filterAttrs (_: network: network.routingPolicyRules == [ ]) borderHub.systemd.network.networks
                )
              )
            )
          );
        };
      expected = {
        hubDefaultAcl = true;
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
    test_nodeTransportAndFabric = {
      expr =
        let
          exported = clanLib.getExport {
            serviceName = "routed-fabric";
            instanceName = "fleet";
            roleName = "member";
            machineName = "client";
          } evaled.config.exports;
        in
        {
          transportVersion = exported.node_transport.schemaVersion;
          fabricVersion = exported.routed_fabric.schemaVersion;
          role = exported.routed_fabric.topology;
          access = exported.routed_fabric.access;
          adjacencyCount = builtins.length (builtins.attrNames exported.routed_fabric.adjacencies);
        };
      expected = {
        transportVersion = 2;
        fabricVersion = 1;
        role = "member";
        access = "client";
        adjacencyCount = 2;
      };
    };
    test_networkFactsDeepEvalAndParity = {
      expr = {
        deep = builtins.deepSeq client.clan.networkFacts true;
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
        node = "client";
        role = "member";
        access = "client";
        adjacencies = 2;
        graphEdges = 2;
      };
    };
  };

  validation = {
    test_memberNeedsHub = {
      expr = failedAssertion noHub.config.nixosConfigurations.client.config "must name at least one hub";
      expected = true;
    };
    test_hubRoleReference = {
      expr = failedAssertion badHub.config.nixosConfigurations.client.config "invalid or non-hub references";
      expected = true;
    };
    test_mutualHubHub = {
      expr = failedAssertion oneWayHubs.config.nixosConfigurations.hub-a.config "must be mutual";
      expected = true;
    };
    test_oneFabricMembership = {
      expr = failedAssertion duplicateMembership.config.nixosConfigurations.client.config "at most one instance";
      expected = true;
    };
  };
}
