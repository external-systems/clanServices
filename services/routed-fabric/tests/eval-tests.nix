{
  lib,
  module,
  clanLib,
  inputs,
  exportInterfaces,
  ...
}: let
  fabric = import ../../../lib/kube-cluster/fabric.nix {inherit lib;};

  machineConfigs = lib.genAttrs ["spine-a" "spine-b" "client" "admin" "node-a"] (_: {
    nixpkgs.hostPlatform = "x86_64-linux";
  });

  clusterModule = {
    _class = "clan.service";
    manifest = {
      name = "k3s";
      description = "Eval-only cluster export fixture";
      readme = "Cluster export fixture for routed-fabric tests.";
      exports.out = ["kube_cluster"];
    };
    roles.default = {
      description = "Publish one cluster's non-secret facts";
      perInstance = {
        instanceName,
        mkExports,
        ...
      }: let
        second = instanceName == "cluster-b";
        member =
          if second
          then "spine-b"
          else "node-a";
      in {
        exports = mkExports {
          kube_cluster = {
            schemaVersion = 3;
            name = instanceName;
            ciliumId =
              if second
              then 2
              else 1;
            network = {
              podCIDRv4 =
                if second
                then "10.3.0.0/16"
                else "10.1.0.0/16";
              podCIDRv6 =
                if second
                then "fd10:3::/56"
                else "fd10:1::/56";
              serviceCIDRv4 =
                if second
                then "10.4.0.0/16"
                else "10.2.0.0/16";
              serviceCIDRv6 =
                if second
                then "fd10:4::/112"
                else "fd10:2::/112";
              clusterDNS =
                if second
                then "10.4.0.10"
                else "10.2.0.10";
              fabric = {
                service = "routed-fabric";
                instance = "fleet";
              };
            };
            members.${member} = {
              role = "server";
              ipv4 =
                if second
                then "192.168.77.2"
                else "192.168.77.4";
              ipv6 =
                if second
                then "fd77::2"
                else "fd77::4";
            };
            pools.fabric = {
              scope = "cluster-global";
              delivery = "shared-bgp";
              blocks = [
                (
                  if second
                  then "172.16.2.0/24"
                  else "172.16.1.0/24"
                )
                (
                  if second
                  then "fd11:2::/64"
                  else "fd11:1::/64"
                )
              ];
            };
            bgp = {
              enabled = true;
              ciliumAsn =
                if second
                then 4200000002
                else 4200000001;
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
              endpoint = "192.0.2.1";
            };
            spine-b.settings = {
              ipv4 = "192.168.77.2";
              ipv6 = "fd77::2";
              endpoint = "192.0.2.2";
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
              endpoint = "192.0.2.11";
              spines = ["spine-a"];
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
        roles.default.machines.node-a = {};
      };
      cluster-b = {
        module.name = "k3s";
        module.input = "self";
        roles.default.machines.spine-b = {};
      };
    };
  };

  mkEvaledWith = machines: inventory:
    clanLib.clan {
      self = {};
      directory = ./fixtures;
      inherit exportInterfaces machines;
      modules = {
        routed-fabric = module;
        netif = lib.modules.importApply ../../netif/default.nix {
          ifstateOverlay = inputs.pkgs.overlays.ifstate;
        };
        wireguard-mesh = lib.modules.importApply ../../wireguard-mesh/default.nix {
          ifstateOverlay = inputs.pkgs.overlays.ifstate;
        };
        k3s = clusterModule;
      };
      inherit inventory;
    };

  mkEvaled = mkEvaledWith machineConfigs;

  evaled = mkEvaled baseInventory;
  configs = evaled.config.nixosConfigurations;
  client = configs.client.config;
  admin = configs.admin.config;
  spine = configs.spine-a.config;
  spineB = configs.spine-b.config;
  node = configs.node-a.config;

  failedAssertion = config: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) config.assertions;
  interfacesFor = config:
    lib.filterAttrs (
      name: _: lib.hasPrefix "rf" name && !lib.hasPrefix "rflo" name
    )
    config.networking.ifstate.settings.interfaces;
  allowedFor = config:
    map (interface: (builtins.head (lib.attrValues interface.wireguard.peers)).allowedips) (
      builtins.attrValues (interfacesFor config)
    );

  withoutSpines = mkEvaled (
    baseInventory
    // {
      instances =
        baseInventory.instances
        // {
          fleet =
            baseInventory.instances.fleet
            // {
              roles =
                baseInventory.instances.fleet.roles
                // {
                  spine.machines = {};
                };
            };
        };
    }
  );
  badSpine = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.leaf.machines.client.settings.spines = ["admin"];
    }
  );
  spineDeclaresSpines = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.spine.machines.spine-a.settings.spines = ["spine-b"];
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
              endpoint = "203.0.113.2";
              links.wan = {
                interface = "enp1s0f0np0";
                mtu = 1400;
                static.ipv4 = ["203.0.113.2/30"];
                endpoint = true;
              };
            };
            client.settings = {
              endpoint = "198.51.100.2";
              links.wan = {
                interface = "enp1s0f1np1";
                mtu = 1400;
                static.ipv4 = ["198.51.100.2/30"];
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

  borderInventory = lib.recursiveUpdate baseInventory {
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
  };
  borderEval = mkEvaled borderInventory;
  borderSpine = borderEval.config.nixosConfigurations.spine-a.config;
  borderClient = borderEval.config.nixosConfigurations.client.config;

  duplicateMembership = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.other = {
        module.name = "routed-fabric";
        module.input = "self";
        roles = {
          spine.machines.spine-a.settings.endpoint = "192.0.2.1";
          leaf.machines.client.settings = {};
        };
      };
    }
  );

  # Endpoint derivation through an export source (the clan-core internet
  # underlay): spines dial each other's underlay hosts; leaves stay
  # outbound-only, so spine-side leaf peers render no Endpoint.
  endpointSourcesEval = clanLib.clan {
    self = {};
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
        fleet =
          baseInventory.instances.fleet
          // {
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
                  spines = ["spine-a"];
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
  spineSpineInterface = fabric.adjacencyName spineSpineKey;
  peerEndpoint = config: interfaceName: let
    interface = config.networking.ifstate.settings.interfaces.${interfaceName};
  in
    (builtins.head (lib.attrValues interface.wireguard.peers)).endpoint or null;

  afMismatchEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.spine.machines.spine-b.settings.endpoint = "2001:db8::2";
    }
  );
  hostnameEndpointEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.spine.machines.spine-a.settings.endpoint = "spine-a.test";
    }
  );
  wanInventory = lib.recursiveUpdate baseInventory {
    instances.fleet.roles.spine.machines.spine-a.settings.site = "helsinki";
    instances.fleet.roles.spine.machines.spine-b.settings.site = "texas";
  };
  wanEval = mkEvaled wanInventory;
  timerOverrideEval = mkEvaled (
    lib.recursiveUpdate wanInventory {
      instances.fleet.roles.spine.machines.spine-a.settings.adjacencies.spine-b.timerProfile = "site";
    }
  );
  timerConflictEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.spine.machines.spine-a.settings.adjacencies.spine-b.timerProfile = "site";
      instances.fleet.roles.spine.machines.spine-b.settings.adjacencies.spine-a.timerProfile = "wan";
    }
  );
  derivedSourceReturnTable = 1000 + lib.mod (fabric.nodeAsn "fleet" "client") 30000;
  derivedSourceReturnPriority = 10000 + lib.mod (fabric.nodeAsn "fleet" "client") 20000;
  sourceReturnReservedEvals = lib.genAttrs (map toString [0 200 201 253 254 255 2004 2005]) (
    table:
      mkEvaled (
        lib.recursiveUpdate borderInventory {
          instances.fleet.roles.spine.machines.spine-a.settings.adjacencies.client.sourceReturnTable = builtins.fromJSON table;
        }
      )
  );
  sourceReturnDuplicateEval = mkEvaled (
    lib.recursiveUpdate borderInventory {
      instances.fleet.roles.spine.machines.spine-a.settings.adjacencies = {
        client.sourceReturnTable = 40500;
        spine-b = {
          sourceReturn = true;
          sourceReturnTable = 40500;
        };
      };
    }
  );
  sourceReturnNetifPriorityCollisionEval = mkEvaled (
    lib.recursiveUpdate borderInventory {
      instances.underlay-netif = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.spine-a.settings.links.wan = {
          interface = "enp1s0";
          static.ipv4 = ["203.0.113.2/30"];
          routingPolicy = {
            table = 40000;
            from = ["203.0.113.2/32"];
            priority = derivedSourceReturnPriority;
          };
        };
      };
    }
  );
  upstreamHostnameEval = mkEvaled (
    lib.recursiveUpdate borderInventory {
      instances.fleet.roles.spine.machines.spine-a.settings.border.upstreamPeers = [
        {
          address = "upstream.example.net";
          asn = 64500;
        }
      ];
    }
  );
  upstreamZonedEval = mkEvaled (
    lib.recursiveUpdate borderInventory {
      instances.fleet.roles.spine.machines.spine-a.settings.border.upstreamPeers = [
        {
          address = "fe80::1%eth0";
          asn = 64500;
        }
      ];
    }
  );
  targetHostOverrideEval =
    mkEvaledWith (
      machineConfigs
      // {
        client = {
          nixpkgs.hostPlatform = "x86_64-linux";
          clan.core.networking.targetHost = "root@[fd77:0:0::10]:22";
        };
      }
    )
    baseInventory;
  sourceReturnPinEval = mkEvaled (
    lib.recursiveUpdate borderInventory {
      instances.fleet.roles.spine.machines.spine-a.settings.adjacencies.client.sourceReturnTable = 40500;
    }
  );
  sourceReturnNetifCollisionEval = mkEvaled (
    lib.recursiveUpdate borderInventory {
      instances.underlay-netif = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.spine-a.settings.links.wan = {
          interface = "enp1s0";
          static.ipv4 = ["203.0.113.2/30"];
          routingPolicy = {
            table = derivedSourceReturnTable;
            from = ["203.0.113.2/32"];
          };
        };
      };
    }
  );
  forwardingNetifEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.underlay-netif = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.spine-a.settings.links.wan = {
          interface = "enp1s0";
          dhcp.ipv4 = true;
        };
      };
    }
  );
  nonForwardingBorderNetifEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.leaf.machines.client.settings.border = {
        ownedPrefixes = ["172.16.0.0/12"];
        upstreamPeers = [
          {
            address = "203.0.113.1";
            asn = 64500;
          }
        ];
        forwarding = false;
      };
      instances.underlay-netif = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.client.settings.links.wan = {
          interface = "enp1s0";
          dhcp.ipv4 = true;
        };
      };
    }
  );
  reservedPortsEval =
    mkEvaledWith (
      machineConfigs
      // {
        client = {
          nixpkgs.hostPlatform = "x86_64-linux";
          clan.core.networking.reservedPorts = [
            "30000-32767"
            "51820"
          ];
        };
      }
    )
    baseInventory;
  deployInstance = endpoint: {
    module.name = "netif";
    module.input = "self";
    roles.default.machines.client.settings = {
      inherit endpoint;
      targetHost = true;
    };
  };
  meshInstance = port: {
    module.name = "wireguard-mesh";
    module.input = "self";
    roles.peer.machines.client.settings = {
      inherit port;
      ipv4 = "10.42.0.1";
      ipv6 = "fd42::1";
      endpoint = "192.0.2.10";
    };
  };
  targetHostFabricEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.deploy = deployInstance "192.168.77.10";
    }
  );
  clientTransfer = client.clan.networkFacts.fabric.fleet.adjacencies.spine-a.ipv4;
  targetHostTransferEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.deploy = deployInstance clientTransfer;
    }
  );
  targetHostTunnelEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.deploy = deployInstance "10.42.0.1";
      instances.mesh = meshInstance 51820;
    }
  );
  meshPortCollisionEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mesh = meshInstance 52679;
    }
  );
in {
  rendering = {
    test_bgpBfdExposureIsScoped = {
      expr = {
        globalTcp = spine.networking.firewall.allowedTCPPorts;
        globalBfd = lib.any (port: lib.elem port spine.networking.firewall.allowedUDPPorts) [3784 4784];
        perInterface = lib.all (
          interface:
            interface.allowedTCPPorts
            == [179]
            && interface.allowedUDPPorts == [3784 4784]
        ) (builtins.attrValues spine.networking.firewall.interfaces);
        noUpstreamByDefault = spine.networking.firewall.extraInputRules == "";
        upstreamRule = borderSpine.networking.firewall.extraInputRules;
      };
      expected = {
        globalTcp = [];
        globalBfd = false;
        perInterface = true;
        noUpstreamByDefault = true;
        upstreamRule = ''
          ip saddr { 203.0.113.1 } tcp dport 179 accept
          ip saddr { 203.0.113.1 } udp dport { 3784, 4784 } accept
        '';
      };
    };
    test_wireguardPortsReserved = {
      expr = client.boot.kernel.sysctl."net.ipv4.ip_local_reserved_ports";
      expected = "52679,54843";
    };
    test_additionalPortsMergeWithWireguardReservations = {
      expr = reservedPortsEval.config.nixosConfigurations.client.config.boot.kernel.sysctl."net.ipv4.ip_local_reserved_ports";
      expected = "30000-32767,51820,52679,54843";
    };
    test_forwardingNetifAcceptsRouterAdvertisements = {
      expr = forwardingNetifEval.config.nixosConfigurations.spine-a.config.networking.ifstate.settings.interfaces.enp1s0.sysctl.ipv6.accept_ra;
      expected = 2;
    };
    test_nonForwardingBorderUsesHostRouterAdvertisementMode = {
      expr = nonForwardingBorderNetifEval.config.nixosConfigurations.client.config.networking.ifstate.settings.interfaces.enp1s0.sysctl.ipv6.accept_ra;
      expected = 1;
    };
    test_stabilityProfilesAndRecovery = {
      expr = let
        wanConfig = wanEval.config.nixosConfigurations.spine-a.config.services.frr.config;
        borderConfig = borderSpine.services.frr.config;
      in {
        siteBfd = lib.hasInfix "profile site" spine.services.frr.config;
        siteTimers = lib.hasInfix "timers 3 9" spine.services.frr.config;
        siteDefaultsImplicit = !(lib.hasInfix "receive-interval 300" spine.services.frr.config);
        plainBfd = lib.hasInfix " bfd\n" spine.services.frr.config;
        wanBfd = lib.hasInfix "bfd profile wan" wanConfig;
        wanTimers = lib.hasInfix "timers 10 30" wanConfig;
        delayOpen = lib.hasInfix "timers delayopen 5" wanConfig;
        prefixRestart = lib.hasInfix "maximum-prefix 4096 restart 10" wanConfig;
        upstreamWan = lib.hasInfix "neighbor 203.0.113.1 bfd profile wan" borderConfig;
        upstreamPlainBfd = lib.hasInfix "neighbor 203.0.113.1 bfd\n" borderConfig;
        upstreamTimers = lib.hasInfix "neighbor 203.0.113.1 timers 10 30" borderConfig;
        upstreamDelayOpen = lib.hasInfix "neighbor 203.0.113.1 timers delayopen 5" borderConfig;
      };
      expected = {
        siteBfd = true;
        siteTimers = true;
        siteDefaultsImplicit = true;
        plainBfd = true;
        wanBfd = true;
        wanTimers = true;
        delayOpen = true;
        prefixRestart = true;
        upstreamWan = true;
        upstreamPlainBfd = true;
        upstreamTimers = true;
        upstreamDelayOpen = true;
      };
    };
    test_adjacencyTimerOverride = {
      expr = timerOverrideEval.config.nixosConfigurations.spine-a.config.clan.networkFacts.fabric.fleet.adjacencies.spine-b.timerProfile;
      expected = "site";
    };
    test_oneInterfacePerAdjacency = {
      expr = {
        dualHomedLeaf = builtins.length (builtins.attrNames (interfacesFor client));
        singleHomedLeaf = builtins.length (builtins.attrNames (interfacesFor admin));
        spineA = builtins.length (builtins.attrNames (interfacesFor spine));
        spineB = builtins.length (builtins.attrNames (interfacesFor spineB));
      };
      expected = {
        dualHomedLeaf = 2;
        singleHomedLeaf = 1;
        spineA = 4;
        spineB = 3;
      };
    };
    test_derivedSpinePairAdjacency = {
      expr = let
        remoteNames =
          builtins.attrNames
          (clanLib.getExport {
              serviceName = "routed-fabric";
              instanceName = "fleet";
              roleName = "spine";
              machineName = "spine-a";
            }
            evaled.config.exports).routed_fabric.adjacencies;
      in {
        # The spine<->spine adjacency exists with no settings on either side.
        spinePairOnA = builtins.elem "spine-b" remoteNames;
        spinePairOnB = builtins.elem "spine-a" (
          builtins.attrNames
          (clanLib.getExport {
              serviceName = "routed-fabric";
              instanceName = "fleet";
              roleName = "spine";
              machineName = "spine-b";
            }
            evaled.config.exports).routed_fabric.adjacencies
        );
        noLeafLeaf =
          !(builtins.elem "client" (
            builtins.attrNames
            (clanLib.getExport {
                serviceName = "routed-fabric";
                instanceName = "fleet";
                roleName = "leaf";
                machineName = "admin";
              }
              evaled.config.exports).routed_fabric.adjacencies
          ));
      };
      expected = {
        spinePairOnA = true;
        spinePairOnB = true;
        noLeafLeaf = true;
      };
    };
    test_namesPortsAndMtu = {
      expr = lib.sortOn (entry: entry.listenPort) (
        lib.mapAttrsToList (
          name: interface: let
            peer = builtins.head (lib.attrValues interface.wireguard.peers);
          in {
            nameLength = lib.stringLength name;
            peerCount = builtins.length (lib.attrValues interface.wireguard.peers);
            inherit (interface.link) mtu;
            listenPort = interface.wireguard.listen_port;
            allowedDefaultAclOnly = !(lib.hasInfix "0.0.0.0/0" (builtins.toJSON peer.allowedips));
          }
        ) (interfacesFor client)
      );
      expected = [
        {
          nameLength = 15;
          peerCount = 1;
          mtu = 1404;
          listenPort = 52679;
          allowedDefaultAclOnly = true;
        }
        {
          nameLength = 15;
          peerCount = 1;
          mtu = 1404;
          listenPort = 54843;
          allowedDefaultAclOnly = true;
        }
      ];
    };
    test_adjacencyPortOverride = {
      expr = let
        key = fabric.adjacencyKey "fleet" "client" "spine-a";
        interfaceName = fabric.adjacencyName key;
      in
        map (config: config.networking.ifstate.settings.interfaces.${interfaceName}.wireguard.listen_port) [
          portClient
          portSpine
        ];
      expected = [
        52820
        52820
      ];
    };
    test_netifExportMtuDerivation = {
      expr = map (interface: interface.link.mtu) (builtins.attrValues (interfacesFor mtuClient));
      expected = [
        1304
        1304
      ];
    };
    test_netifAndFabricShareIfstateBase = {
      expr = {
        version = mtuClient.networking.ifstate.package.version;
        networkd = mtuClient.systemd.network.enable;
        useNetworkd = mtuClient.networking.useNetworkd;
      };
      expected = {
        version = "2.5.1";
        networkd = false;
        useNetworkd = false;
      };
    };
    test_endpointSourcesResolution = {
      expr = let
        leafInterfaces =
          lib.filterAttrs (
            n: _: lib.hasPrefix "rf" n && !lib.hasPrefix "rflo" n && n != spineSpineInterface
          )
          endpointSpineA.networking.ifstate.settings.interfaces;
      in {
        spinePairOnA = peerEndpoint endpointSpineA spineSpineInterface;
        spinePairOnB = peerEndpoint endpointSpineB spineSpineInterface;
        leafPeersOnSpineHaveNoEndpoint = lib.all (
          interface: (builtins.head (lib.attrValues interface.wireguard.peers)).endpoint or null == null
        ) (builtins.attrValues leafInterfaces);
        dualHomedLeafDialsBothSpines =
          (peerEndpoint endpointClient "rfd0d91d1f47a84" == "192.168.1.4:52679")
          && (peerEndpoint endpointClient "rfaa5538a64228d" == "192.168.1.5:54843");
      };
      expected = {
        spinePairOnA = "192.168.1.5:55962";
        spinePairOnB = "192.168.1.4:55962";
        leafPeersOnSpineHaveNoEndpoint = true;
        dualHomedLeafDialsBothSpines = true;
      };
    };
    test_wireguardLinkLocalAddressing = {
      expr = let
        interfaces = builtins.attrValues (interfacesFor spine);
      in {
        linkLocal =
          lib.all (
            interface:
              lib.any (
                address: builtins.isString address && lib.hasPrefix "fe80::" address && lib.hasSuffix "/64" address
              )
              interface.addresses
          )
          interfaces;
        transferScope =
          lib.all (
            interface:
              lib.all (address: address.scope == "link") (builtins.filter builtins.isAttrs interface.addresses)
          )
          interfaces;
      };
      expected = {
        linkLocal = true;
        transferScope = true;
      };
    };
    test_loopbackAndIntegratedFrr = {
      expr = {
        addresses =
          spine.networking.ifstate.settings.interfaces.${spine.clan.networkFacts.fabric.fleet.loopback}.addresses;
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
      expr = let
        text = builtins.toJSON (allowedFor admin);
      in {
        pods = lib.hasInfix "10.1.0.0/16" text;
        services = lib.hasInfix "10.2.0.0/16" text;
      };
      expected = {
        pods = true;
        services = true;
      };
    };
    test_kubernetesLocalAdvertisements = {
      expr = let
        text = builtins.toJSON (allowedFor node);
      in {
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
      expr = let
        sourceRoutes = borderSpine.networking.ifstate.settings.routing.routes;
        sourceRules = borderSpine.networking.ifstate.settings.routing.rules;
      in {
        spineDefaultAcl = lib.hasInfix "0.0.0.0/0" (builtins.toJSON (allowedFor borderSpine));
        peerDefaultAcl = lib.hasInfix "::/0" (builtins.toJSON (allowedFor borderClient));
        upstream = lib.hasInfix "neighbor 203.0.113.1 remote-as 64500" borderSpine.services.frr.config;
        policyTables = lib.unique (map (route: route.table) sourceRoutes);
        rulePriorities = lib.unique (map (rule: rule.priority) sourceRules);
        mainTables = lib.unique (
          map (route: route.table or "main") (
            builtins.filter (route: (route.table or "main") == "main") sourceRoutes
          )
        );
      };
      expected = {
        spineDefaultAcl = true;
        peerDefaultAcl = true;
        upstream = true;
        policyTables = [derivedSourceReturnTable];
        rulePriorities = [derivedSourceReturnPriority];
        mainTables = [];
      };
    };
  };

  exports = {
    test_deepEval = {
      expr = builtins.deepSeq evaled.config.exports true;
      expected = true;
    };
    test_nodeTransportNativeProfile = {
      expr = let
        exported =
          clanLib.getExport {
            serviceName = "routed-fabric";
            instanceName = "fleet";
            roleName = "leaf";
            machineName = "client";
          }
          evaled.config.exports;
        transport = exported.node_transport;
      in {
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
    test_literalAddressFamilyMismatchRejected = {
      expr = failedAssertion afMismatchEval.config.nixosConfigurations.spine-a.config "must share an address family";
      expected = true;
    };
    test_hostnameEndpointWarns = {
      expr = {
        warning =
          lib.any (
            message: lib.hasInfix "uses a hostname endpoint" message
          )
          hostnameEndpointEval.config.nixosConfigurations.spine-a.config.warnings;
        literalBaseWarnings = client.warnings;
      };
      expected = {
        warning = true;
        literalBaseWarnings = [];
      };
    };
    test_conflictingTimerProfilesRejected = {
      expr = failedAssertion timerConflictEval.config.nixosConfigurations.spine-a.config "must select the same timerProfile";
      expected = true;
    };
    test_sourceReturnReservedTablesRejected = {
      expr = lib.all (
        eval: failedAssertion eval.config.nixosConfigurations.spine-a.config "reserved kernel/Cilium tables"
      ) (builtins.attrValues sourceReturnReservedEvals);
      expected = true;
    };
    test_sourceReturnDuplicateTableRejected = {
      expr = failedAssertion sourceReturnDuplicateEval.config.nixosConfigurations.spine-a.config "source-return tables must be unique";
      expected = true;
    };
    test_sourceReturnNetifCollisionRejected = {
      expr = failedAssertion sourceReturnNetifCollisionEval.config.nixosConfigurations.spine-a.config "must not collide with same-host netif";
      expected = true;
    };
    test_sourceReturnNetifPriorityCollisionRejected = {
      expr = failedAssertion sourceReturnNetifPriorityCollisionEval.config.nixosConfigurations.spine-a.config "unique across source-return and same-host netif rules";
      expected = true;
    };
    test_sourceReturnPinAccepted = {
      expr = let
        config = sourceReturnPinEval.config.nixosConfigurations.spine-a.config;
      in {
        collision = failedAssertion config "source-return";
        tables = lib.unique (map (route: route.table) config.networking.ifstate.settings.routing.routes);
        priorities = lib.unique (map (rule: rule.priority) config.networking.ifstate.settings.routing.rules);
      };
      expected = {
        collision = false;
        tables = [40500];
        priorities = [derivedSourceReturnPriority];
      };
    };
    test_nonLiteralUpstreamPeersRejected = {
      expr = {
        hostname = failedAssertion upstreamHostnameEval.config.nixosConfigurations.spine-a.config "literal unzoned IPv4 or IPv6";
        zoned = failedAssertion upstreamZonedEval.config.nixosConfigurations.spine-a.config "literal unzoned IPv4 or IPv6";
      };
      expected = {
        hostname = true;
        zoned = true;
      };
    };
    test_targetHostFabricAddressRejected = {
      expr = failedAssertion targetHostFabricEval.config.nixosConfigurations.client.config "keep the deploy target on the underlay";
      expected = true;
    };
    test_targetHostTransferAddressRejected = {
      expr = failedAssertion targetHostTransferEval.config.nixosConfigurations.client.config "keep the deploy target on the underlay";
      expected = true;
    };
    test_targetHostTunnelAddressRejected = {
      expr = failedAssertion targetHostTunnelEval.config.nixosConfigurations.client.config "keep the deploy target on the underlay";
      expected = true;
    };
    test_finalNormalizedTargetHostOverrideRejected = {
      expr = failedAssertion targetHostOverrideEval.config.nixosConfigurations.client.config "keep the deploy target on the underlay";
      expected = true;
    };
    test_meshRoutedFabricPortCollisionRejected = {
      expr = failedAssertion meshPortCollisionEval.config.nixosConfigurations.client.config "listen-port clashes with routed-fabric: 52679";
      expected = true;
    };
  };
}
