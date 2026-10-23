{
  module,
  clanLib,
  exportInterfaces,
  lib,
  ...
}:
let
  machineConfigs = lib.genAttrs [ "alpha" "beta" "gamma" ] (_: {
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
              extraAllowedIPs = [ "10.77.10.0/24" ];
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

  mkEvaled =
    inventory:
    clanLib.clan {
      self = { };
      directory = ./fixtures;
      inherit exportInterfaces;
      modules.wireguard-mesh = module;
      machines = machineConfigs;
      inherit inventory;
    };

  evaled = mkEvaled baseInventory;
  alpha = evaled.config.nixosConfigurations.alpha.config;
  alphaNetdev = alpha.systemd.network.netdevs."40-wireguard-mesh-mesh";
  alphaNetwork = alpha.systemd.network.networks."40-wireguard-mesh-mesh";
  alphaPeers = alphaNetdev.wireguardPeers;

  memberExport =
    machineName:
    clanLib.getExport {
      serviceName = "wireguard-mesh";
      instanceName = "mesh";
      roleName = "peer";
      inherit machineName;
    } evaled.config.exports;

  instanceExports = lib.attrValues (
    clanLib.selectExports (
      scope:
      scope.serviceName == "wireguard-mesh" && scope.instanceName == "mesh" && scope.machineName == ""
    ) evaled.config.exports
  );

  failedAssertion =
    machineConfig: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) machineConfig.assertions;

  duplicateEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mesh.roles.peer.machines.beta.settings.ipv4 = "10.42.0.1";
    }
  );

  noEndpointEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mesh.roles.peer.settings.endpointSources = [ ];
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
          port = 51822;
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
  derivedInventory = baseInventory // {
    instances = baseInventory.instances // {
      mesh = baseInventory.instances.mesh // {
        roles.peer.machines = lib.genAttrs [ "alpha" "beta" "gamma" ] (_: {
          settings = { };
        });
      };
    };
  };
  derivedEval = mkEvaled derivedInventory;
  alphaDerived = derivedEval.config.nixosConfigurations.alpha.config;
in
{
  rendering = {
    test_derivedInterface = {
      expr = alphaNetdev.netdevConfig.Name;
      expected = "wg-mesh";
    };
    test_netdevKindAndMtu = {
      expr = {
        inherit (alphaNetdev.netdevConfig) Kind MTUBytes;
      };
      expected = {
        Kind = "wireguard";
        MTUBytes = 1420;
      };
    };
    test_dualStackHostAddresses = {
      expr = alphaNetwork.address;
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
      expr = map (peer: peer.Endpoint) alphaPeers;
      expected = [
        "[2001:db8::2]:51821"
        "gamma.example.net:51820"
      ];
    };
    test_allowedIPs = {
      expr = map (peer: peer.AllowedIPs) alphaPeers;
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
      expr = map (route: route.Destination) alphaNetwork.routes;
      expected = [
        "192.168.77.2/32"
        "fd00:77::2/128"
        "10.77.10.0/24"
        "192.168.77.3/32"
        "fd00:77::3/128"
      ];
    };
    test_persistentKeepalive = {
      expr = map (peer: peer.PersistentKeepalive) alphaPeers;
      expected = [
        25
        25
      ];
    };
    test_publicKeysAreTrimmed = {
      expr = map (peer: peer.PublicKey) alphaPeers;
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
    # §6.3: mesh addresses derive deterministically from the mesh
    # instance + machine name when unset (pinned hash contract).
    test_derivedMeshAddresses = {
      expr = alphaDerived.systemd.network.networks."40-wireguard-mesh-mesh".address;
      expected = [
        "192.168.49.19/32"
        "fd77:3131:676a:8ad7::516b/128"
      ];
    };
    test_derivedMeshPeerRoutes = {
      expr = map (
        route: route.Destination
      ) alphaDerived.systemd.network.networks."40-wireguard-mesh-mesh".routes;
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
        } derivedEval.config.exports).node_transport.ipv6;
      expected = "fd77:3131:676a:8ad7::516b";
    };
  };

  exports = {
    test_nodeTransport = {
      expr = (memberExport "alpha").node_transport;
      expected = {
        ipv4 = "10.42.0.1";
        ipv6 = "fd10:42::1";
        interface = "wg-mesh";
        port = 51820;
        mtu = 1420;
        endpoint = "alpha.example.net:51820";
        instance = "mesh";
        # Topology is a cluster-node concept (kube_cluster export);
        # wireguard-mesh leaves the pass-through fields null.
        topology = {
          region = null;
          zone = null;
        };
      };
    };
    test_standardPeer = {
      expr = (memberExport "alpha").peer.hosts;
      expected = [ { plain = "alpha.mesh"; } ];
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

  vars =
    let
      generator = alpha.clan.core.vars.generators."wireguard-mesh-mesh";
    in
    {
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
          owner = "systemd-network";
          group = "systemd-network";
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
      expr = failedAssertion noEndpointEval.config.nixosConfigurations.alpha.config "needs at least one explicit endpoint";
      expected = true;
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
