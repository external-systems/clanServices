{
  lib,
  module,
  clanLib,
  inputs,
  exportInterfaces,
  ...
}: let
  fabric = import ../../../lib/kube-cluster/fabric.nix {inherit lib;};
  ip = import ../../../lib/ip.nix {inherit lib;};
  nodeAsn = machine:
    builtins.fromJSON (
      lib.trim (builtins.readFile ./fixtures/vars/per-machine/${machine}/routed-fabric-fleet-asn/asn/value)
    );

  machineConfigs =
    lib.genAttrs [
      "spine-a"
      "spine-b"
      "client"
      "admin"
      "node-a"
      "dup4-a"
      "dup4-b"
      "dup6-a"
      "dup6-b"
      "asn-a"
      "asn-b"
      "port-spine"
      "port-a"
      "port-b"
      "transfer-spine"
      "transfer-a"
      "transfer-b"
      "isolated-a"
      "isolated-b"
      "overlap-a"
      "overlap-b"
    ] (_: {
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
                if instanceName == "cluster-overlap"
                then "198.18.0.0/16"
                else if second
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
              hostAsn = nodeAsn member;
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

  mkEvaledAt = directory: machines: inventory:
    clanLib.clan {
      self = {};
      inherit directory exportInterfaces machines;
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

  mkEvaledWith = mkEvaledAt ./fixtures;
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
  allocatedEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.leaf.machines.client.settings = {
        ipv4 = null;
        ipv6 = null;
      };
    }
  );
  allocatedClient = allocatedEval.config.nixosConfigurations.client.config;

  pairInventory = {
    instanceName ? "fleet",
    spine ? "spine-a",
    leaf ? "client",
    spineSettings ? {},
    leafSettings ? {},
    extraInstances ? {},
  }: {
    instances =
      {
        ${instanceName} = {
          module.name = "routed-fabric";
          module.input = "self";
          roles = {
            spine.machines.${spine}.settings = {endpoint = "192.0.2.1";} // spineSettings;
            leaf.machines.${leaf}.settings = leafSettings;
          };
        };
      }
      // extraInstances;
  };
  allocationEval = mkEvaled (pairInventory {});
  duplicateIpv4Eval = mkEvaled (pairInventory {
    spine = "dup4-a";
    leaf = "dup4-b";
  });
  duplicateIpv6Eval = mkEvaled (pairInventory {
    spine = "dup6-a";
    leaf = "dup6-b";
  });
  duplicateAsnEval = mkEvaled (pairInventory {
    spine = "asn-a";
    leaf = "asn-b";
  });
  duplicatePortInventory = {
    instances.fleet = {
      module.name = "routed-fabric";
      module.input = "self";
      roles = {
        spine.machines.port-spine.settings.endpoint = "192.0.2.1";
        leaf.machines = {
          port-a = {};
          port-b = {};
        };
      };
    };
  };
  duplicatePortEval = mkEvaled duplicatePortInventory;
  duplicateTransferInventory = {
    instances.fleet = {
      module.name = "routed-fabric";
      module.input = "self";
      roles = {
        spine.machines.transfer-spine.settings.endpoint = "192.0.2.1";
        leaf.machines = {
          transfer-a = {};
          transfer-b = {};
        };
      };
    };
  };
  duplicateTransferEval = mkEvaled duplicateTransferInventory;
  unrelatedTransferEval = mkEvaled {
    instances.fleet = {
      module.name = "routed-fabric";
      module.input = "self";
      roles = {
        spine.machines = {
          spine-a.settings.endpoint = "192.0.2.1";
          spine-b.settings.endpoint = "192.0.2.2";
        };
        leaf.machines = {
          isolated-a.settings.spines = ["spine-a"];
          isolated-b.settings.spines = ["spine-b"];
        };
      };
    };
  };
  missingNodeEval = mkEvaledAt ./fixtures-missing-node machineConfigs (pairInventory {});
  missingAdjacencyEval = mkEvaledAt ./fixtures-missing-adj machineConfigs (pairInventory {});
  unequalPoolEval = mkEvaled (pairInventory {
    leafSettings.loopback4Pool = "198.18.64.0/18";
  });
  unequalPortRangeEval = mkEvaled (pairInventory {
    leafSettings.portRange.start = 20000;
  });
  internalPoolOverlapEval = mkEvaled (pairInventory {
    instanceName = "overlap";
    spine = "overlap-a";
    leaf = "overlap-b";
  });
  invalidPortRangeEval = mkEvaled (pairInventory {
    spineSettings.portRange = {
      start = 30000;
      end = 20000;
    };
    leafSettings.portRange = {
      start = 30000;
      end = 20000;
    };
  });
  membershipDriftEval = mkEvaled (pairInventory {
    instanceName = "overlap";
    spine = "overlap-a";
    leaf = "overlap-b";
    spineSettings.loopback4Pool = "198.18.64.0/18";
    leafSettings.loopback4Pool = "198.18.64.0/18";
  });
  transferPoolDriftEval = mkEvaled (pairInventory {
    spineSettings.transfer4Pool = "198.19.128.0/17";
    leafSettings.transfer4Pool = "198.19.128.0/17";
  });
  poolEvalWithLoopback = value:
    mkEvaled (pairInventory {
      instanceName = "overlap";
      spine = "overlap-a";
      leaf = "overlap-b";
      spineSettings.loopback4Pool = value;
      leafSettings.loopback4Pool = value;
    });
  canonicalPoolEval = poolEvalWithLoopback "198.18.0.1/17";
  malformedPoolEvals = map poolEvalWithLoopback [
    "198.18.0.0"
    "198.18.0.0/33"
    "not-a-cidr"
    "198.18.0.1/17"
  ];
  reservedPortRangeEval = mkEvaledWith (
    machineConfigs
    // {
      spine-a = {
        nixpkgs.hostPlatform = "x86_64-linux";
        clanServices.networking.reservedPorts = ["20000-21000"];
      };
    }
  ) (pairInventory {});
  nodePortRangeEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.spine.settings.portRange = {
        start = 31000;
        end = 32000;
      };
      instances.fleet.roles.leaf.settings.portRange = {
        start = 31000;
        end = 32000;
      };
    }
  );
  explicitForeignPoolEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.leaf.machines.client.settings.ipv4 = "198.18.128.1";
      instances.mesh = meshInstance 51822;
    }
  );
  crossServicePoolEval = mkEvaled (pairInventory {
    extraInstances.cross = {
      module.name = "wireguard-mesh";
      module.input = "self";
      roles.peer.machines.client.settings = {
        ipv4 = "10.42.0.1";
        ipv6 = "fd42::1";
        port = 51822;
        endpoint = "192.0.2.10";
      };
    };
  });
  netifPoolOverlapEval = mkEvaled (pairInventory {
    extraInstances.underlay = {
      module.name = "netif";
      module.input = "self";
      roles.default.machines.spine-a.settings.links.wan = {
        interface = "enp1s0";
        static.ipv4 = ["198.18.0.1/32"];
      };
    };
  });
  ulaPoolOverlapEval = mkEvaled (pairInventory {
    extraInstances.underlay = {
      module.name = "netif";
      module.input = "self";
      roles.default.machines.spine-a.settings.links.wan = {
        interface = "enp1s0";
        static.ipv6 = ["fd64:6464:6464::1/64"];
      };
    };
  });
  kubePoolOverlapEval = mkEvaled (
    baseInventory
    // {
      instances =
        (removeAttrs baseInventory.instances ["cluster-a"])
        // {
          cluster-overlap = baseInventory.instances.cluster-a;
        };
    }
  );

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
  derivedSourceReturnTable = 1000 + lib.mod (nodeAsn "client") 30000;
  derivedSourceReturnPriority = 10000 + lib.mod (nodeAsn "client") 20000;
  sourceReturnReservedEvals = lib.genAttrs (map toString ip.reservedPolicyTables) (
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
  sourceReturnDuplicatePriorityEval = mkEvaled (
    lib.recursiveUpdate borderInventory {
      instances.fleet.roles.spine.machines.spine-a.settings.adjacencies = {
        client = {
          sourceReturnTable = 40500;
          sourceReturnPriority = 12345;
        };
        spine-b = {
          sourceReturn = true;
          sourceReturnTable = 40501;
          sourceReturnPriority = 12345;
        };
      };
    }
  );
  sourceReturnPriorityRangeEval = mkEvaled (
    lib.recursiveUpdate borderInventory {
      instances.fleet.roles.spine.machines.spine-a.settings.adjacencies.client.sourceReturnPriority = 32766;
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
      instances.fleet.roles.spine.machines.spine-a.settings.adjacencies.client = {
        sourceReturnTable = 40500;
        sourceReturnPriority = 12345;
      };
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
          clanServices.networking.reservedPorts = [
            "30000-32767"
            "51820"
          ];
        };
      }
    ) (lib.recursiveUpdate baseInventory {
      instances = {
        underlay-netif = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.client.settings.links.wan = {
            interface = "enp1s0";
            static.ipv4 = ["192.0.2.10/32"];
          };
        };
        mesh = meshInstance 51822;
      };
    });
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
      instances.mesh = meshInstance 20001;
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
      expected = "20001,20002";
    };
    test_sharedIfstateModuleDeduplicatesAndMergesReservations = {
      expr = reservedPortsEval.config.nixosConfigurations.client.config.boot.kernel.sysctl."net.ipv4.ip_local_reserved_ports";
      expected = "30000-32767,51820,20001,20002,51822";
    };
    test_publicNodeAllocation = {
      expr = {
        inherit (allocatedClient.clan.networkFacts.fabric.fleet) ipv4 ipv6 asn;
      };
      expected = {
        ipv4 = "198.18.0.10";
        ipv6 = "fd64:6464:6464::10";
        asn = 4200000010;
      };
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
          listenPort = 20001;
          allowedDefaultAclOnly = true;
        }
        {
          nameLength = 15;
          peerCount = 1;
          mtu = 1404;
          listenPort = 20002;
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
          (peerEndpoint endpointClient "rfd0d91d1f47a84" == "192.168.1.4:20001")
          && (peerEndpoint endpointClient "rfaa5538a64228d" == "192.168.1.5:20002");
      };
      expected = {
        spinePairOnA = "192.168.1.5:20006";
        spinePairOnB = "192.168.1.4:20006";
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

  vars = let
    generators = client.clan.core.vars.generators;
    spineGenerators = spine.clan.core.vars.generators;
    adjacencyGenerators = client.clan.networkFacts.fabric.fleet.adjacencies.spine-a.generator;
    portGenerator = builtins.elemAt adjacencyGenerators 0;
    transfer4Generator = builtins.elemAt adjacencyGenerators 1;
    transfer6Generator = builtins.elemAt adjacencyGenerators 2;
    declaration = set: name: let
      generator = set.${name};
    in {
      inherit (generator) share script;
      dependencies = generator.dependencies or [];
      validation = generator.validation or {};
      files = lib.mapAttrs (_: file: {inherit (file) secret deploy;}) generator.files;
    };
    poolGeneratorNames = [
      "routed-fabric-fleet-loopback4-pool"
      "routed-fabric-fleet-transfer4-pool"
    ];
    allocationNames =
      [
        "routed-fabric-fleet-ula"
        "routed-fabric-fleet-node4"
        "routed-fabric-fleet-node6"
        "routed-fabric-fleet-asn"
      ]
      ++ poolGeneratorNames
      ++ adjacencyGenerators;
  in {
    test_allocationFilesArePublicAndNotDeployed = {
      expr =
        lib.all (
          name:
            lib.all (file: !file.secret && !file.deploy) (
              builtins.attrValues generators.${name}.files
            )
        )
        allocationNames;
      expected = true;
    };
    test_sharedGeneratorsAndDependencies = {
      expr = {
        ulaShared = generators.routed-fabric-fleet-ula.share;
        ulaValidation = generators.routed-fabric-fleet-ula.validation or {};
        poolRecordsShared = lib.all (name: generators.${name}.share) poolGeneratorNames;
        poolRecordsByteIdentical = lib.all (name: declaration generators name == declaration spineGenerators name) poolGeneratorNames;
        poolRecordValidation = {
          loopback = generators.routed-fabric-fleet-loopback4-pool.validation;
          transfer = generators.routed-fabric-fleet-transfer4-pool.validation;
        };
        adjacencyShared = lib.all (name: generators.${name}.share) adjacencyGenerators;
        adjacencyByteIdentical = lib.all (name: declaration generators name == declaration spineGenerators name) adjacencyGenerators;
        node4Dependencies = generators.routed-fabric-fleet-node4.dependencies;
        node6Dependencies = generators.routed-fabric-fleet-node6.dependencies;
        portDependencies = generators.${portGenerator}.dependencies or [];
        portValidation = generators.${portGenerator}.validation;
        transfer4Dependencies = generators.${transfer4Generator}.dependencies;
        transfer6Dependencies = generators.${transfer6Generator}.dependencies;
      };
      expected = {
        ulaShared = true;
        ulaValidation = null;
        poolRecordsShared = true;
        poolRecordsByteIdentical = true;
        poolRecordValidation = {
          loopback.pool = "198.18.0.0/17";
          transfer.pool = "198.19.0.0/16";
        };
        adjacencyShared = true;
        adjacencyByteIdentical = true;
        node4Dependencies = ["routed-fabric-fleet-loopback4-pool"];
        node6Dependencies = ["routed-fabric-fleet-ula"];
        portDependencies = [];
        portValidation = {
          portStart = "10000";
          portEnd = "29999";
        };
        transfer4Dependencies = ["routed-fabric-fleet-transfer4-pool"];
        transfer6Dependencies = ["routed-fabric-fleet-ula"];
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
    test_sourceReturnDuplicatePriorityRejected = {
      expr = failedAssertion sourceReturnDuplicatePriorityEval.config.nixosConfigurations.spine-a.config "unique across source-return and same-host netif rules";
      expected = true;
    };
    test_sourceReturnPriorityAtMainRejected = {
      expr = failedAssertion sourceReturnPriorityRangeEval.config.nixosConfigurations.spine-a.config "below 32766";
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
    test_sourceReturnPinsAccepted = {
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
        priorities = [12345];
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
      expr = failedAssertion meshPortCollisionEval.config.nixosConfigurations.client.config "listen-port clashes with routed-fabric: 20001";
      expected = true;
    };
    test_allocationPositive = {
      expr = {
        collisions = failedAssertion allocationEval.config.nixosConfigurations.spine-a.config "collides with";
        pools = failedAssertion allocationEval.config.nixosConfigurations.spine-a.config "allocation pools overlap";
      };
      expected = {
        collisions = false;
        pools = false;
      };
    };
    test_completeAllocationTwinAccepted = {
      expr =
        builtins.deepSeq {
          inherit (allocationEval.config.nixosConfigurations.client.config.clan.networkFacts.fabric.fleet) ipv4;
          transfer4 = allocationEval.config.nixosConfigurations.client.config.clan.networkFacts.fabric.fleet.adjacencies.spine-a.prefix4;
        }
        true;
      expected = true;
    };
    test_missingNodeVarRejected = {
      expr =
        !(builtins.tryEval (
          builtins.deepSeq missingNodeEval.config.nixosConfigurations.client.config.clan.networkFacts.fabric.fleet.ipv4 true
        )).success;
      expected = true;
    };
    test_missingAdjacencyVarRejected = {
      expr =
        !(builtins.tryEval (
          builtins.deepSeq missingAdjacencyEval.config.nixosConfigurations.client.config.clan.networkFacts.fabric.fleet.adjacencies.spine-a.prefix4 true
        )).success;
      expected = true;
    };
    test_duplicateLoopbackIpv4Rejected = {
      expr = failedAssertion duplicateIpv4Eval.config.nixosConfigurations.dup4-a.config "loopback IPv4 198.18.0.40 collides on owners dup4-a, dup4-b; regenerate the newer machine: clan vars generate <newer-machine> --generator routed-fabric-fleet-node4 --regenerate";
      expected = true;
    };
    test_duplicateLoopbackIpv6Rejected = {
      expr = failedAssertion duplicateIpv6Eval.config.nixosConfigurations.dup6-a.config "loopback IPv6 fd64:6464:6464::50 collides on owners dup6-a, dup6-b; regenerate the newer machine: clan vars generate <newer-machine> --generator routed-fabric-fleet-node6 --regenerate";
      expected = true;
    };
    test_duplicateAsnRejected = {
      expr = failedAssertion duplicateAsnEval.config.nixosConfigurations.asn-a.config "ASN 4200000060 collides on owners asn-a, asn-b; regenerate the newer machine: clan vars generate <newer-machine> --generator routed-fabric-fleet-asn --regenerate";
      expected = true;
    };
    test_duplicatePortOnOneHostRejected = {
      expr = failedAssertion duplicatePortEval.config.nixosConfigurations.port-spine.config "port 20700 collides on owners fleet:port-a:port-spine and fleet:port-b:port-spine; regenerate the newer machine: clan vars generate <newer-machine>";
      expected = true;
    };
    test_duplicateTransferOnOneHostRejected = {
      expr = let
        config = duplicateTransferEval.config.nixosConfigurations.transfer-spine.config;
      in {
        ipv4 = failedAssertion config "transfer4 198.19.8.0/31 collides on owners fleet:transfer-a:transfer-spine and fleet:transfer-b:transfer-spine; regenerate the newer machine: clan vars generate <newer-machine>";
        ipv6 = failedAssertion config "transfer6 fd64:6464:6464:1:800::/127 collides on owners fleet:transfer-a:transfer-spine and fleet:transfer-b:transfer-spine; regenerate the newer machine: clan vars generate <newer-machine>";
      };
      expected = {
        ipv4 = true;
        ipv6 = true;
      };
    };
    test_duplicateTransferOnUnrelatedHostsAccepted = {
      expr = {
        ipv4 = failedAssertion unrelatedTransferEval.config.nixosConfigurations.spine-a.config "transfer4";
        ipv6 = failedAssertion unrelatedTransferEval.config.nixosConfigurations.spine-b.config "transfer6";
      };
      expected = {
        ipv4 = false;
        ipv6 = false;
      };
    };
    test_unequalPoolsRejected = {
      expr = failedAssertion unequalPoolEval.config.nixosConfigurations.spine-a.config "allocation settings differ on client; set loopback4Pool, transfer4Pool, and portRange identically on every member";
      expected = true;
    };
    test_unequalPortRangeRejected = {
      expr = failedAssertion unequalPortRangeEval.config.nixosConfigurations.spine-a.config "allocation settings differ on client; set loopback4Pool, transfer4Pool, and portRange identically on every member";
      expected = true;
    };
    test_internalPoolOverlapRejected = {
      expr = failedAssertion internalPoolOverlapEval.config.nixosConfigurations.overlap-a.config "allocation pools overlap (loopback4Pool=198.19.0.0/16 with transfer4Pool=198.19.0.0/16); set loopback4Pool and transfer4Pool to disjoint member-uniform values";
      expected = true;
    };
    test_netifPoolOverlapRejected = {
      expr = failedAssertion netifPoolOverlapEval.config.nixosConfigurations.spine-a.config "loopback4Pool=198.18.0.0/17 with 198.18.0.1/32";
      expected = true;
    };
    test_ulaPoolOverlapRejected = {
      expr = failedAssertion ulaPoolOverlapEval.config.nixosConfigurations.spine-a.config "loopback6=fd64:6464:6464:0::/64 with fd64:6464:6464::1/64";
      expected = true;
    };
    test_kubePoolOverlapRejected = {
      expr = failedAssertion kubePoolOverlapEval.config.nixosConfigurations.node-a.config "loopback4Pool=198.18.0.0/17 with 198.18.0.0/16";
      expected = true;
    };
    test_invalidPortRangeRejected = {
      expr = failedAssertion invalidPortRangeEval.config.nixosConfigurations.spine-a.config "portRange.start must not exceed portRange.end; set an inclusive range such as 10000–29999 on every member";
      expected = true;
    };
    test_allocatedValueOutsidePoolRejected = {
      expr = failedAssertion membershipDriftEval.config.nixosConfigurations.overlap-a.config "overlap-a/ipv4=198.19.0.10 outside loopback4Pool=198.18.64.0/18";
      expected = true;
    };
    test_recordedLoopbackPoolDriftNamesOnlyLoopbackGenerator = {
      expr = let
        config = membershipDriftEval.config.nixosConfigurations.overlap-a.config;
      in {
        own = failedAssertion config "routed-fabric/overlap: recorded loopback4Pool differs from settings; run: clan vars generate overlap-a --generator routed-fabric-overlap-loopback4-pool --regenerate to update the record, then regenerate routed-fabric-overlap-node4 to re-roll only unpinned IPv4 loopbacks";
        other = failedAssertion config "--generator routed-fabric-overlap-transfer4-pool --regenerate";
      };
      expected = {
        own = true;
        other = false;
      };
    };
    test_recordedTransferPoolDriftNamesOnlyTransferGenerator = {
      expr = let
        config = transferPoolDriftEval.config.nixosConfigurations.spine-a.config;
      in {
        own = failedAssertion config "routed-fabric/fleet: recorded transfer4Pool differs from settings; run: clan vars generate spine-a --generator routed-fabric-fleet-transfer4-pool --regenerate to update the record, then regenerate each adjacency -transfer4 generator to re-roll only transfer4 prefixes";
        other = failedAssertion config "--generator routed-fabric-fleet-loopback4-pool --regenerate";
      };
      expected = {
        own = true;
        other = false;
      };
    };
    test_nonCanonicalPoolRejected = {
      expr = failedAssertion canonicalPoolEval.config.nixosConfigurations.overlap-a.config "must be canonical IPv4 CIDRs with host bits clear";
      expected = true;
    };
    test_malformedPoolsProduceCanonicalAssertion = {
      expr =
        lib.all (
          eval: failedAssertion eval.config.nixosConfigurations.overlap-a.config "must be canonical IPv4 CIDRs with host bits clear"
        )
        malformedPoolEvals;
      expected = true;
    };
    test_reservedPortRangeRejected = {
      expr = failedAssertion reservedPortRangeEval.config.nixosConfigurations.spine-a.config "portRange 10000-29999 overlaps reserved or Kubernetes NodePort ranges";
      expected = true;
    };
    test_kubernetesNodePortRangeRejected = {
      expr = failedAssertion nodePortRangeEval.config.nixosConfigurations.spine-b.config "portRange 31000-32000 overlaps reserved or Kubernetes NodePort ranges";
      expected = true;
    };
    test_crossServicePoolOverlapRejected = {
      expr = failedAssertion crossServicePoolEval.config.nixosConfigurations.client.config "allocation pools overlap across instances/services on one host";
      expected = true;
    };
    test_explicitAddressInForeignPoolRejected = {
      expr = failedAssertion explicitForeignPoolEval.config.nixosConfigurations.client.config "ipv4=198.18.128.1/32 overlaps wireguard-mesh/mesh/ipv4Pool=198.18.128.0/17";
      expected = true;
    };
    test_explicitOverridesBeatVars = {
      expr = {
        inherit (client.clan.networkFacts.fabric.fleet) ipv4 ipv6;
        port = portClient.clan.networkFacts.fabric.fleet.adjacencies.spine-a.port;
        collision = failedAssertion portClient "collides with";
      };
      expected = {
        ipv4 = "192.168.77.10";
        ipv6 = "fd77::10";
        port = 52820;
        collision = false;
      };
    };
  };
}
