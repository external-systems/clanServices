{
  module,
  clanLib,
  exportInterfaces,
  lib,
  ...
}: let
  machineConfigs = lib.genAttrs ["alpha" "beta" "gamma"] (_: {
    nixpkgs.hostPlatform = "x86_64-linux";
  });

  netifModule = {
    _class = "clan.service";
    manifest = {
      name = "netif";
      description = "Eval-only underlay export fixture";
      readme = "Underlay export fixture.";
      exports.out = ["netif"];
    };
    roles.default = {
      description = "Publish overlapping underlay prefixes";
      perInstance = {
        instanceName,
        mkExports,
        ...
      }: {
        exports = mkExports {
          netif.links.wan.addresses =
            if instanceName == "underlay-v6"
            then ["fd66:6666:6666::1/64"]
            else ["198.18.128.1/32"];
        };
      };
    };
  };

  clusterModule = {
    _class = "clan.service";
    manifest = {
      name = "k3s";
      description = "Eval-only cluster export fixture";
      readme = "Cluster export fixture.";
      exports.out = ["kube_cluster"];
    };
    roles.default = {
      description = "Publish overlapping cluster prefixes";
      perInstance = {
        instanceName,
        mkExports,
        ...
      }: {
        exports = mkExports {
          kube_cluster = {
            schemaVersion = 3;
            name = instanceName;
            ciliumId = 1;
            network = {
              podCIDRv4 = "198.18.128.0/17";
              podCIDRv6 = "fd10:1::/56";
              serviceCIDRv4 = "10.2.0.0/16";
              serviceCIDRv6 = "fd10:2::/112";
              clusterDNS = "10.2.0.10";
              fabric = {
                service = "wireguard-mesh";
                instance = "mesh";
              };
            };
            members.alpha = {
              role = "server";
              ipv4 = "192.168.77.1";
              ipv6 = "fd00:77::1";
            };
            pools = {};
            bgp = {
              enabled = false;
              ciliumAsn = 4200000001;
              hostAsn = 4200000002;
              advertiseClusterIPs = false;
            };
          };
        };
      };
    };
  };

  baseInventory = {
    instances = {
      underlay = {
        module.name = "internet";
        roles.default.machines = {
          alpha.settings.host = "alpha.example.net";
          beta.settings.host = "2001:db8::2";
          gamma.settings.host = "gamma.example.net";
        };
      };

      mesh = {
        module.name = "wireguard-mesh";
        module.input = "self";
        roles.peer = {
          settings.endpointSources = [
            {
              service = "clan-core/internet";
              instance = "underlay";
            }
          ];
          machines = {
            alpha.settings = {
              ipv4 = "10.42.0.1";
              ipv6 = "fd10:42::1";
            };
            beta.settings = {
              ipv4 = "192.168.77.2";
              ipv6 = "fd00:77::2";
              port = 51821;
              extraAllowedIPs = ["10.77.10.0/24"];
            };
            gamma.settings = {
              ipv4 = "192.168.77.3";
              ipv6 = "fd00:77::3";
            };
          };
        };
      };
    };
  };

  mkEvaledAt = directory: inventory:
    clanLib.clan {
      self = {};
      inherit directory;
      exportInterfaces =
        exportInterfaces
        // {
          netif = ../../netif/netif-interface.nix;
          kube_cluster = ../../../lib/kube-cluster/kube-cluster-interface.nix;
        };
      modules = {
        wireguard-mesh = module;
        netif = netifModule;
        k3s = clusterModule;
      };
      machines = machineConfigs;
      inherit inventory;
    };

  mkEvaled = mkEvaledAt ./fixtures;
  evaled = mkEvaled baseInventory;
  alpha = evaled.config.nixosConfigurations.alpha.config;
  alphaIfstate = alpha.networking.ifstate.settings;
  alphaInterface = alphaIfstate.interfaces.wg-mesh;
  alphaPeers = lib.attrValues alphaInterface.wireguard.peers;

  memberExport = machineName:
    clanLib.getExport {
      serviceName = "wireguard-mesh";
      instanceName = "mesh";
      roleName = "peer";
      inherit machineName;
    }
    evaled.config.exports;

  instanceExports = lib.attrValues (
    clanLib.selectExports (
      scope:
        scope.serviceName == "wireguard-mesh" && scope.instanceName == "mesh" && scope.machineName == ""
    )
    evaled.config.exports
  );

  failedAssertion = machineConfig: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) machineConfig.assertions;

  duplicateEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mesh.roles.peer.machines.beta.settings.ipv4 = "10.42.0.1";
    }
  );
  unequalPoolEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mesh.roles.peer.machines.beta.settings.ipv4Pool = "198.18.64.0/18";
    }
  );
  missingNodeEval = mkEvaledAt ./fixtures-missing-node allocatedInventory;
  missingPrefixEval = mkEvaledAt ./fixtures-missing-prefix allocatedInventory;
  netifPoolOverlapEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.underlay-v4 = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.alpha = {};
      };
    }
  );
  ulaPoolOverlapEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.underlay-v6 = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.alpha = {};
      };
    }
  );
  kubePoolOverlapEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.cluster = {
        module.name = "k3s";
        module.input = "self";
        roles.default.machines.alpha = {};
      };
    }
  );

  noEndpointEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mesh.roles.peer.settings.endpointSources = [];
    }
  );
  pairWithoutEndpointEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mesh.roles.peer.settings.endpointSources = [];
      instances.mesh.roles.peer.machines.alpha.settings.endpoint = "alpha.example.net";
    }
  );
  overlappingAllowedIPsEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mesh.roles.peer.machines.gamma.settings.extraAllowedIPs = ["10.77.0.0/16"];
    }
  );
  localOverlappingAllowedIPsEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mesh.roles.peer.machines.alpha.settings.extraAllowedIPs = ["10.77.0.0/16"];
    }
  );

  interfaceCollisionEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.other = {
        module.name = "wireguard-mesh";
        module.input = "self";
        roles.peer.machines.alpha.settings = {
          ipv4 = "192.168.78.1";
          ipv6 = "fd00:78::1";
          interface = "wg-mesh";
          port = 51820;
          endpoint = "alpha.example.net";
        };
      };
    }
  );

  portCollisionEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.other = {
        module.name = "wireguard-mesh";
        module.input = "self";
        roles.peer.machines.alpha.settings = {
          ipv4 = "192.168.78.1";
          ipv6 = "fd00:78::1";
          endpoint = "alpha.example.net";
        };
      };
    }
  );

  # No explicit addresses: values come from committed public allocation fixtures.
  allocatedInventory =
    baseInventory
    // {
      instances =
        baseInventory.instances
        // {
          mesh =
            baseInventory.instances.mesh
            // {
              roles.peer.machines = lib.genAttrs ["alpha" "beta" "gamma"] (_: {
                settings = {};
              });
            };
        };
    };
  allocatedEval = mkEvaled allocatedInventory;
  alphaAllocated = allocatedEval.config.nixosConfigurations.alpha.config;
  membershipDriftEval = mkEvaled (
    lib.recursiveUpdate allocatedInventory {
      instances.mesh.roles.peer.settings.ipv4Pool = "198.18.64.0/18";
    }
  );
  canonicalPoolEval = mkEvaled (
    lib.recursiveUpdate allocatedInventory {
      instances.mesh.roles.peer.settings.ipv4Pool = "198.18.128.1/17";
    }
  );
  explicitForeignPoolEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mesh.roles.peer.machines.alpha.settings.ipv4 = "198.18.128.1";
      instances.other = {
        module.name = "wireguard-mesh";
        module.input = "self";
        roles.peer.machines.alpha.settings = {
          ipv4 = "192.168.78.1";
          ipv6 = "fd00:78::1";
          port = 51830;
          endpoint = "alpha.example.net";
        };
      };
    }
  );
in {
  rendering = {
    test_ifstateOnly = {
      expr = {
        enabled = alpha.networking.ifstate.enable;
        version = alpha.networking.ifstate.package.version;
        networkd = alpha.systemd.network.enable;
        useNetworkd = alpha.networking.useNetworkd;
      };
      expected = {
        enabled = true;
        version = "2.5.1";
        networkd = false;
        useNetworkd = false;
      };
    };
    test_interfaceKindAndMtu = {
      expr = {
        inherit (alphaInterface.link) kind mtu;
      };
      expected = {
        kind = "wireguard";
        mtu = 1420;
      };
    };
    test_dualStackHostAddresses = {
      expr = alphaInterface.addresses;
      expected = [
        "10.42.0.1/32"
        "fd10:42::1/128"
      ];
    };
    test_fullMesh = {
      expr = builtins.length alphaPeers;
      expected = 2;
    };
    test_endpointSourcesAndPerPeerPort = {
      expr = map (peer: peer.endpoint) alphaPeers;
      expected = [
        "[2001:db8::2]:51821"
        "gamma.example.net:51820"
      ];
    };
    test_allowedIPs = {
      expr = map (peer: peer.allowedips) alphaPeers;
      expected = [
        [
          "192.168.77.2/32"
          "fd00:77::2/128"
          "10.77.10.0/24"
        ]
        [
          "192.168.77.3/32"
          "fd00:77::3/128"
        ]
      ];
    };
    test_peerRoutes = {
      expr = map (route: route.to) alphaIfstate.routing.routes;
      expected = [
        "192.168.77.2/32"
        "fd00:77::2/128"
        "10.77.10.0/24"
        "192.168.77.3/32"
        "fd00:77::3/128"
      ];
    };
    test_persistentKeepalive = {
      expr = map (peer: peer.persistent_keepalive_interval) alphaPeers;
      expected = [
        25
        25
      ];
    };
    test_publicKeysAreTrimmed = {
      expr = builtins.attrNames alphaInterface.wireguard.peers;
      expected = [
        "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
        "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC="
      ];
    };
    test_meshHostnames = {
      expr = lib.concatStringsSep "\n" (
        lib.filter (line: lib.hasInfix "beta.mesh" line) (lib.splitString "\n" alpha.networking.extraHosts)
      );
      expected = "192.168.77.2 beta.mesh\nfd00:77::2 beta.mesh";
    };
    test_firewallDefaults = {
      expr = {
        udpPortOpen = lib.elem 51820 alpha.networking.firewall.allowedUDPPorts;
        interfaceTrusted = lib.elem "wg-mesh" alpha.networking.firewall.trustedInterfaces;
      };
      expected = {
        udpPortOpen = true;
        interfaceTrusted = true;
      };
    };
    test_listenPortReserved = {
      expr = alpha.boot.kernel.sysctl."net.ipv4.ip_local_reserved_ports";
      expected = "51820";
    };
    test_allocatedMeshAddresses = {
      expr = alphaAllocated.networking.ifstate.settings.interfaces.wg-mesh.addresses;
      expected = [
        "198.18.128.1/32"
        "fd66:6666:6666::1/128"
      ];
    };
    test_allocatedMeshPeerRoutes = {
      expr = map (route: route.to) alphaAllocated.networking.ifstate.settings.routing.routes;
      expected = [
        "198.18.128.2/32"
        "fd66:6666:6666::2/128"
        "198.18.128.3/32"
        "fd66:6666:6666::3/128"
      ];
    };
    test_allocatedMeshExport = {
      expr =
        (clanLib.getExport {
            serviceName = "wireguard-mesh";
            instanceName = "mesh";
            roleName = "peer";
            machineName = "alpha";
          }
          allocatedEval.config.exports).node_transport.ipv6;
      expected = "fd66:6666:6666::1";
    };
  };

  exports = {
    test_nodeTransport = {
      expr = (memberExport "alpha").node_transport;
      expected = {
        schemaVersion = 2;
        ipv4 = "10.42.0.1";
        ipv6 = "fd10:42::1";
        instance = "mesh";
        asn = null;
        endpoint = "alpha.example.net:51820";
        port = 51820;
        interfaces = {
          wg-mesh = {
            mtu = 1420;
          };
        };
        directRoutingDevice = "wg-mesh";
        datapath = {
          mode = "tunnel";
          tunnelProtocol = "vxlan";
        };
        native.routeExchange = null;
        internalLoadBalancer = false;
        nodePort = true;
      };
    };
    test_standardPeer = {
      expr = (memberExport "alpha").peer.hosts;
      expected = [{plain = "alpha.mesh";}];
    };
    test_standardPeerPortIsNotWireGuard = {
      expr = (memberExport "alpha").peer.port;
      expected = 22;
    };
    test_networkPriority = {
      expr = (builtins.head instanceExports).networking.priority;
      expected = 1000;
    };
  };

  vars = let
    generators = alpha.clan.core.vars.generators;
    generator = generators."wireguard-mesh-mesh";
  in {
    test_files = {
      expr = builtins.attrNames generator.files;
      expected = [
        "privatekey"
        "publickey"
      ];
    };
    test_secretAndDeployment = {
      expr = {
        privateSecret = generator.files.privatekey.secret;
        publicSecret = generator.files.publickey.secret;
        publicDeploy = generator.files.publickey.deploy;
      };
      expected = {
        privateSecret = true;
        publicSecret = false;
        publicDeploy = false;
      };
    };
    test_privateKeyOwnership = {
      expr = {
        inherit (generator.files.privatekey) owner group mode;
      };
      expected = {
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };
    test_allocationFilesArePublicAndNotDeployed = {
      expr =
        lib.all (
          name:
            lib.all (file: !file.secret && !file.deploy) (
              builtins.attrValues generators.${name}.files
            )
        ) [
          "wireguard-mesh-mesh-ula"
          "wireguard-mesh-mesh-prefixes"
          "wireguard-mesh-mesh-node4"
          "wireguard-mesh-mesh-node6"
        ];
      expected = true;
    };
    test_allocationGeneratorScopeAndDependencies = {
      expr = {
        ulaShared = generators.wireguard-mesh-mesh-ula.share;
        ulaValidation = generators.wireguard-mesh-mesh-ula.validation or {};
        shared = generators.wireguard-mesh-mesh-prefixes.share;
        node4Dependencies = generators.wireguard-mesh-mesh-node4.dependencies;
        node6Dependencies = generators.wireguard-mesh-mesh-node6.dependencies;
      };
      expected = {
        ulaShared = true;
        ulaValidation = null;
        shared = true;
        node4Dependencies = ["wireguard-mesh-mesh-prefixes"];
        node6Dependencies = ["wireguard-mesh-mesh-ula"];
      };
    };
  };

  validation = {
    test_duplicateAddressesRejected = {
      expr = failedAssertion duplicateEval.config.nixosConfigurations.alpha.config "mesh IPv4 10.42.0.1 collides on owners alpha, beta; regenerate the newer machine: clan vars generate <newer-machine> --generator wireguard-mesh-mesh-node4 --regenerate";
      expected = true;
    };
    test_unequalPoolsRejected = {
      expr = failedAssertion unequalPoolEval.config.nixosConfigurations.alpha.config "ipv4Pool differs on beta; set ipv4Pool identically on every member";
      expected = true;
    };
    test_missingNodeVarRejected = {
      expr =
        !(builtins.tryEval (
          builtins.deepSeq missingNodeEval.config.nixosConfigurations.alpha.config.networking.ifstate.settings.interfaces.wg-mesh.addresses true
        )).success;
      expected = true;
    };
    test_missingSharedPrefixRejected = {
      expr =
        !(builtins.tryEval (
          failedAssertion missingPrefixEval.config.nixosConfigurations.alpha.config "wireguard-mesh/mesh: allocation pools overlap"
        )).success;
      expected = true;
    };
    test_disjointPoolsAccepted = {
      expr = failedAssertion alpha "allocation pools overlap";
      expected = false;
    };
    test_allocatedValueOutsidePoolRejected = {
      expr = failedAssertion membershipDriftEval.config.nixosConfigurations.alpha.config "alpha/ipv4=198.18.128.1 outside ipv4Pool=198.18.64.0/18";
      expected = true;
    };
    test_recordedPoolDriftRejected = {
      expr = failedAssertion membershipDriftEval.config.nixosConfigurations.alpha.config "recorded ipv4Pool differs from the setting; run: clan vars generate alpha --generator wireguard-mesh-mesh-prefixes --regenerate to update the record, then regenerate wireguard-mesh-mesh-node4 on each machine to re-roll only unpinned IPv4 addresses. ULA and IPv6 are unchanged";
      expected = true;
    };
    test_nonCanonicalPoolRejected = {
      expr = failedAssertion canonicalPoolEval.config.nixosConfigurations.alpha.config "ipv4Pool must be a canonical IPv4 CIDR with host bits clear";
      expected = true;
    };
    test_crossInstancePoolOverlapRejected = {
      expr = failedAssertion interfaceCollisionEval.config.nixosConfigurations.alpha.config "allocation pools overlap across instances/services on one host";
      expected = true;
    };
    test_explicitAddressInForeignPoolRejected = {
      expr = failedAssertion explicitForeignPoolEval.config.nixosConfigurations.alpha.config "ipv4=198.18.128.1/32 overlaps wireguard-mesh/other/ipv4Pool=198.18.128.0/17";
      expected = true;
    };
    test_netifPoolOverlapRejected = {
      expr = failedAssertion netifPoolOverlapEval.config.nixosConfigurations.alpha.config "ipv4Pool=198.18.128.0/17 with 198.18.128.1/32";
      expected = true;
    };
    test_ulaPoolOverlapRejected = {
      expr = failedAssertion ulaPoolOverlapEval.config.nixosConfigurations.alpha.config "loopback6=fd66:6666:6666:0::/64 with fd66:6666:6666::1/64";
      expected = true;
    };
    test_kubePoolOverlapRejected = {
      expr = failedAssertion kubePoolOverlapEval.config.nixosConfigurations.alpha.config "ipv4Pool=198.18.128.0/17 with 198.18.128.0/17";
      expected = true;
    };
    test_missingEndpointsRejected = {
      expr = failedAssertion noEndpointEval.config.nixosConfigurations.alpha.config "every member pair needs an endpoint";
      expected = true;
    };
    test_pairWithoutEndpointRejected = {
      expr = failedAssertion pairWithoutEndpointEval.config.nixosConfigurations.beta.config "unreachable from 'beta' to gamma";
      expected = true;
    };
    test_overlappingExtraAllowedIPsRejected = {
      expr = failedAssertion overlappingAllowedIPsEval.config.nixosConfigurations.alpha.config "extraAllowedIPs overlap between peers";
      expected = true;
    };
    test_localExtraAllowedIPsOverlapRejected = {
      expr = failedAssertion localOverlappingAllowedIPsEval.config.nixosConfigurations.beta.config "alpha=10.77.0.0/16 overlaps beta=10.77.10.0/24";
      expected = true;
    };
    test_disjointExtraAllowedIPsAccepted = {
      expr = failedAssertion alpha "extraAllowedIPs overlap";
      expected = false;
    };
    test_interfaceCollisionRejected = {
      expr = failedAssertion interfaceCollisionEval.config.nixosConfigurations.alpha.config "duplicate interface names";
      expected = true;
    };
    test_portCollisionRejected = {
      expr = failedAssertion portCollisionEval.config.nixosConfigurations.alpha.config "duplicate WireGuard listen ports";
      expected = true;
    };
    test_ciliumAddressSpaceIsNotSpecial = {
      expr = failedAssertion alpha "Cilium";
      expected = false;
    };
  };
}
