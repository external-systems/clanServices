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

  mkEvaled = inventory:
    clanLib.clan {
      self = {};
      directory = ./fixtures;
      inherit exportInterfaces;
      modules.wireguard-mesh = module;
      machines = machineConfigs;
      inherit inventory;
    };

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

  # Derived mesh addresses (§6.3): no explicit ipv4/ipv6 — deterministic
  # from the mesh instance + machine name.
  derivedInventory =
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
  derivedEval = mkEvaled derivedInventory;
  alphaDerived = derivedEval.config.nixosConfigurations.alpha.config;
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
    # §6.3: mesh addresses derive deterministically from the mesh
    # instance + machine name when unset (pinned hash contract).
    test_derivedMeshAddresses = {
      expr = alphaDerived.networking.ifstate.settings.interfaces.wg-mesh.addresses;
      expected = [
        "192.168.49.19/32"
        "fd77:3131:676a:8ad7::516b/128"
      ];
    };
    test_derivedMeshPeerRoutes = {
      expr = map (route: route.to) alphaDerived.networking.ifstate.settings.routing.routes;
      expected = [
        "192.168.32.0/32"
        "fd77:2003:1148:a2fe::7e93/128"
        "192.168.160.8/32"
        "fd77:a087:a89c:dc45::22e2/128"
      ];
    };
    test_derivedMeshExport = {
      expr =
        (clanLib.getExport {
            serviceName = "wireguard-mesh";
            instanceName = "mesh";
            roleName = "peer";
            machineName = "alpha";
          }
          derivedEval.config.exports).node_transport.ipv6;
      expected = "fd77:3131:676a:8ad7::516b";
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
    generator = alpha.clan.core.vars.generators."wireguard-mesh-mesh";
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
  };

  validation = {
    test_duplicateAddressesRejected = {
      expr = failedAssertion duplicateEval.config.nixosConfigurations.alpha.config "mesh IPv4 addresses must be unique";
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
