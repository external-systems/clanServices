# nix-unit eval tests for the fleet-routing clanService (D11/D13/D22/D33).
# Throwaway clans with a REAL k3s cluster instance + mesh, so export
# consumption (node_transport + kube_cluster) is exercised end to end.
{
  lib,
  module,
  clanLib,
  exportInterfaces,
  self,
  inputs,
  ...
}:
let
  fleetModule = module;
  k3sModule = lib.modules.importApply ../../k3s/default.nix { inherit self inputs; };
  wgModule = ../../wireguard-mesh/default.nix;
  kube = import ../../../lib/kube-cluster { inherit lib; };

  fleetAsn = kube.bgp.hashAsn "fleet-routing-bird" "fleet";

  machineConfigs = lib.genAttrs [ "alpha" "beta" "client" "admin" "router" ] (_: {
    nixpkgs.hostPlatform = "x86_64-linux";
  });

  mkEvaled =
    inventory:
    clanLib.clan {
      self = { };
      directory = ./fixtures;
      inherit exportInterfaces;
      # Fleet-wide kube-cluster assertions (§6.2) as clan.checks — incl.
      # the campaign-A shared-bgp ⊆ router-prefixes check that the router
      # role's export now activates.
      imports = [ kube.fleetChecksModule ];
      modules = {
        wireguard-mesh = wgModule;
        k3s = k3sModule;
        fleet-routing = fleetModule;
      };
      machines = machineConfigs;
      inherit inventory;
    };

  meshPeers = {
    alpha.settings = {
      ipv4 = "192.168.77.1";
      ipv6 = "fd00:77::1";
      endpoint = "alpha.test";
    };
    beta.settings = {
      ipv4 = "192.168.77.2";
      ipv6 = "fd00:77::2";
      endpoint = "beta.test";
    };
    client.settings = {
      ipv4 = "192.168.77.10";
      ipv6 = "fd00:77::10";
      endpoint = "client.test";
    };
    admin.settings = {
      ipv4 = "192.168.77.11";
      ipv6 = "fd00:77::11";
      endpoint = "admin.test";
    };
    router.settings = {
      ipv4 = "192.168.77.12";
      ipv6 = "fd00:77::12";
      endpoint = "router.test";
    };
  };

  fleetRoleSettings = {
    mesh = {
      service = "wireguard-mesh";
      instance = "mesh";
    };
    clusters = [
      {
        service = "k3s";
        instance = "k3s";
      }
    ];
  };

  # Cluster-level k3s settings — identical on every machine (cross-role
  # parity is eval-asserted per machine).
  clusterSettings = {
    # The legacy fleet-routing tests exercise the node_transport
    # compatibility view of the fabric reference (routed-fabric itself is
    # a separate in-progress branch).
    network.fabric = {
      service = "wireguard-mesh";
      instance = "mesh";
    };
    cilium.id = 1;
    fabric.coredns = {
      wildcardAddress = "172.16.1.200";
      svcZone = true;
      podZone = true;
    };
    bgp = {
      # advertiseClusterIPs stays a D13 opt-in; pod-pool advertisements
      # are unconditional in the new contract (D49).
      advertiseClusterIPs = true;
    };
  };

  baseInventory = {
    meta.domain = "test.clan";

    instances = {
      mesh = {
        module.name = "wireguard-mesh";
        module.input = "self";
        roles.peer.machines = meshPeers;
      };

      k3s = {
        module.name = "k3s";
        module.input = "self";
        roles.server.machines.alpha.settings = clusterSettings // {
          clusterInit = true;
        };
        roles.agent.machines.beta.settings = clusterSettings;
      };

      fleet = {
        module.name = "fleet-routing";
        module.input = "self";
        roles = {
          client.machines.client.settings = fleetRoleSettings;
          admin.machines.admin.settings = fleetRoleSettings;
          router.machines.router.settings = fleetRoleSettings // {
            prefixes = [
              "172.16.0.0/12"
              "fd11::/16"
            ];
          };
        };
      };
    };
  };

  evaled = mkEvaled baseInventory;
  clientCfg = evaled.config.nixosConfigurations.client.config;
  adminCfg = evaled.config.nixosConfigurations.admin.config;
  routerCfg = evaled.config.nixosConfigurations.router.config;

  clientFragment = clientCfg.clan.bird.fragments."fleet-routing-fleet".config;
  adminFragment = adminCfg.clan.bird.fragments."fleet-routing-fleet".config;
  routerFragment = routerCfg.clan.bird.fragments."fleet-routing-fleet".config;

  countInfix = needle: text: builtins.length (lib.splitString needle text) - 1;

  routedInterfaceName =
    fleetInstance: service: clusterInstance: member:
    let
      key = "${fleetInstance}:${service}:${clusterInstance}:${member}";
    in
    "fr${builtins.substring 0 4 (kube.bgp.birdSym fleetInstance)}-${
      builtins.substring 0 8 (builtins.hashString "sha256" key)
    }";

  routedNetdev = fleetInstance: name: "40-fleet-routing-${fleetInstance}-${name}";

  failedAssertion =
    machineConfig: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) machineConfig.assertions;

  # Dual-role (D33): beta is a cluster agent AND the fleet admin.
  dualRoleEvaled = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.admin.machines.beta.settings = fleetRoleSettings;
    }
  );
  betaDual = dualRoleEvaled.config.nixosConfigurations.beta.config;

  # Two instances with the same visible name prefix must not merge any of
  # their per-member interfaces; the long name also exercises the 15-char cap.
  secondFleetInstance = "fleet-with-a-very-long-instance-name";
  multiInstanceEvaled = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.${secondFleetInstance} = {
        module.name = "fleet-routing";
        module.input = "self";
        roles.client.machines.client.settings = fleetRoleSettings;
      };
    }
  );
  multiClient = multiInstanceEvaled.config.nixosConfigurations.client.config;

  # Negative: router prefixes don't cover the cluster's fabric pool. The
  # fleet-wide check throws the whole clan eval (clan.checks); the
  # role-level assertion is inspected via a clan WITHOUT the fleet-checks
  # module (otherwise checkConfig throws first).
  escapeEvaled = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.router.machines.router.settings.prefixes = [ "172.20.0.0/16" ];
    }
  );
  mkEvaledNoFleetChecks =
    inventory:
    clanLib.clan {
      self = { };
      directory = ./fixtures;
      inherit exportInterfaces;
      modules = {
        wireguard-mesh = wgModule;
        k3s = k3sModule;
        fleet-routing = fleetModule;
      };
      machines = machineConfigs;
      inherit inventory;
    };
  escapeNoChecks = mkEvaledNoFleetChecks (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.router.machines.router.settings.prefixes = [ "172.20.0.0/16" ];
    }
  );

  # Negative: fleet role on a machine that never joined the mesh.
  noMeshEvaled = mkEvaled (
    baseInventory
    // {
      instances = baseInventory.instances // {
        mesh = baseInventory.instances.mesh // {
          roles.peer.machines = lib.filterAttrs (n: _: n != "client") meshPeers;
        };
      };
    }
  );

  # Negative: a routed cluster member has no endpoint for the additional
  # point-to-point session (the ordinary mesh still has other endpoints).
  noRoutedEndpointEvaled = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mesh.roles.peer.machines.alpha.settings.endpoint = null;
    }
  );

  # Negative: one machine in two roles of the same instance.
  doubleRoleEvaled = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.admin.machines.client.settings = fleetRoleSettings;
    }
  );

  # Negative: consuming a cluster that isn't in the inventory.
  missingClusterEvaled = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.fleet.roles.client.machines.client.settings.clusters = [
        {
          service = "k3s";
          instance = "nope";
        }
      ];
    }
  );

  routerExport =
    (clanLib.getExport {
      serviceName = "fleet-routing";
      instanceName = "fleet";
      roleName = "router";
      machineName = "router";
    } evaled.config.exports).fleet_routing;
in
{
  # --- client role -----------------------------------------------------------

  test_clientBirdFragment = {
    expr = {
      # one passive protocol per cluster member per family (alpha/beta × 4/6)
      protocols = countInfix "protocol bgp fr_fleet_k3s_k3s_" clientFragment;
      kernelMerge = countInfix "merge paths on;" clientFragment;
      vipFilter4 = lib.hasInfix "if net ~ [ 172.16.1.0/24{32,32} ] then accept;" clientFragment;
      vipFilter6 = lib.hasInfix "if net ~ [ fd11:1::/64{128,128} ] then accept;" clientFragment;
      listensOnOwnMesh = lib.hasInfix "local 192.168.77.10 port 179 as ${toString fleetAsn};" clientFragment;
      passiveStrict = lib.hasInfix "passive on;\n  strict bind on;" clientFragment;
      timers = lib.hasInfix "hold time 9;\n  keepalive time 3;\n  connect retry time 5;" clientFragment;
      peerAsn = lib.hasInfix "neighbor 192.168.77.1 as ${toString (kube.bgp.hashBgpAsns "k3s").host};" clientFragment;
      # D13 stays off for client even though the cluster opted in
      noPods = !(lib.hasInfix "10.1.0.0/16" clientFragment);
      gatewayIPv6 = lib.hasInfix "fr_fleet_k3s_k3s_alpha6\" then { onlink = false; accept; }" clientFragment;
      directIPv4Unchanged = lib.hasInfix "fr_fleet_k3s_k3s_alpha4\" then accept;" clientFragment;
      kernelImportNone = countInfix "import none;" clientFragment;
      routerId = clientCfg.clan.bird.routerId;
      birdEnabled = clientCfg.services.bird.enable;
      fragmentKey = clientCfg.clan.bird.fragments ? fleet-routing-fleet;
    };
    expected = {
      protocols = 4;
      kernelMerge = 2;
      vipFilter4 = true;
      vipFilter6 = true;
      listensOnOwnMesh = true;
      passiveStrict = true;
      timers = true;
      peerAsn = true;
      noPods = true;
      gatewayIPv6 = true;
      directIPv4Unchanged = true;
      kernelImportNone = 2;
      routerId = "192.168.77.10";
      birdEnabled = true;
      fragmentKey = true;
    };
  };

  test_clientRoutedWireguard = {
    expr =
      map
        (
          member:
          let
            name = routedInterfaceName "fleet" "k3s" "k3s" member;
            key = routedNetdev "fleet" name;
            netdev = clientCfg.systemd.network.netdevs.${key};
            network = clientCfg.systemd.network.networks.${key};
            peer = builtins.head netdev.wireguardPeers;
            mainPeer = lib.findFirst (
              p: p.Endpoint or null == "${member}.test:51820"
            ) null clientCfg.systemd.network.netdevs."40-wireguard-mesh-mesh".wireguardPeers;
          in
          {
            inherit name;
            nameLength = builtins.stringLength name;
            inherit (netdev.netdevConfig) Kind MTUBytes;
            privateKeyMatches =
              netdev.wireguardConfig.PrivateKeyFile
              == clientCfg.clan.core.vars.generators."wireguard-mesh-mesh".files.privatekey.path;
            ephemeralListen = !(netdev.wireguardConfig ? ListenPort);
            peerCount = builtins.length netdev.wireguardPeers;
            endpoint = peer.Endpoint;
            publicKeyMatches = peer.PublicKey == mainPeer.PublicKey;
            allowedIPs = peer.AllowedIPs;
            mainAllowedIPs = mainPeer.AllowedIPs;
            addresses = network.address;
            inherit (network) routes;
            matchName = network.matchConfig.Name;
            route4 = lib.hasInfix "route 192.168.77.${if member == "alpha" then "1" else "2"}/32 via 192.168.77.${if member == "alpha" then "1" else "2"} dev \"${name}\" onlink;" clientFragment;
            route6 = lib.hasInfix "route fd00:77::${if member == "alpha" then "1" else "2"}/128 via fd00:77::${if member == "alpha" then "1" else "2"} dev \"${name}\" onlink;" clientFragment;
          }
        )
        [
          "alpha"
          "beta"
        ];
    expected =
      map
        (
          member:
          let
            name = routedInterfaceName "fleet" "k3s" "k3s" member;
            member4 = if member == "alpha" then "192.168.77.1" else "192.168.77.2";
            member6 = if member == "alpha" then "fd00:77::1" else "fd00:77::2";
          in
          {
            inherit name;
            nameLength = 15;
            Kind = "wireguard";
            MTUBytes = 1420;
            privateKeyMatches = true;
            ephemeralListen = true;
            peerCount = 1;
            endpoint = "${member}.test:51820";
            publicKeyMatches = true;
            allowedIPs = [
              "${member4}/32"
              "${member6}/128"
              "172.16.1.0/24"
              "fd11:1::/64"
            ];
            mainAllowedIPs = [
              "${member4}/32"
              "${member6}/128"
            ];
            addresses = [
              "192.168.77.10/32"
              "fd00:77::10/128"
            ];
            routes = [
              {
                Destination = "${member4}/32";
                Metric = 2048;
              }
              {
                Destination = "${member6}/128";
                Metric = 2048;
              }
            ];
            matchName = name;
            route4 = true;
            route6 = true;
          }
        )
        [
          "alpha"
          "beta"
        ];
  };

  test_clientDnsStub = {
    expr = {
      resolved = clientCfg.services.resolved.enable;
      net = clientCfg.services.resolved.settings.Resolve;
      ordinaryMeshHasDns =
        clientCfg.systemd.network.networks."40-wireguard-mesh-mesh".networkConfig ? DNS;
    };
    expected = {
      resolved = true;
      net = {
        DNS = [
          "172.16.1.53"
          "fd11:1:0:0:0:0:0:53"
        ];
        # D22 default for client: ONLY the instance zone.
        Domains = [ "~k3s.test.clan" ];
        DNSOverTLS = false;
        DNSSEC = false;
      };
      ordinaryMeshHasDns = false;
    };
  };

  # --- admin role ------------------------------------------------------------

  test_adminAddsZonesAndPodRoutes = {
    expr = {
      domains = adminCfg.services.resolved.settings.Resolve.Domains;
      podBranch = lib.hasInfix "if net ~ [ 10.1.0.0/16{24,24} ] then accept;" adminFragment;
      podBranch6 = lib.hasInfix "if net ~ [ fd10:1::/56{64,64} ] then accept;" adminFragment;
      svcBranch = lib.hasInfix "if net ~ [ 10.2.0.0/16{32,32} ] then accept;" adminFragment;
      svcBranch6 = lib.hasInfix "if net ~ [ fd10:2::/112{128,128} ] then accept;" adminFragment;
    };
    expected = {
      domains = [
        "~k3s.test.clan"
        "~k3s.svc.test.clan"
        "~k3s.pods.test.clan"
      ];
      podBranch = true;
      podBranch6 = true;
      svcBranch = true;
      svcBranch6 = true;
    };
  };

  test_adminRoutedAllowedIPs = {
    expr =
      map
        (
          member:
          let
            name = routedInterfaceName "fleet" "k3s" "k3s" member;
            netdev = adminCfg.systemd.network.netdevs.${routedNetdev "fleet" name};
          in
          (builtins.head netdev.wireguardPeers).AllowedIPs
        )
        [
          "alpha"
          "beta"
        ];
    expected = [
      [
        "192.168.77.1/32"
        "fd00:77::1/128"
        "172.16.1.0/24"
        "fd11:1::/64"
        "10.1.0.0/16"
        "fd10:1::/56"
        "10.2.0.0/16"
        "fd10:2::/112"
      ]
      [
        "192.168.77.2/32"
        "fd00:77::2/128"
        "172.16.1.0/24"
        "fd11:1::/64"
        "10.1.0.0/16"
        "fd10:1::/56"
        "10.2.0.0/16"
        "fd10:2::/112"
      ]
    ];
  };

  # --- router role -----------------------------------------------------------

  test_routerRole = {
    expr = {
      export = {
        inherit (routerExport) asn routerPrefixes schemaVersion;
      };
      outFilter = lib.hasInfix "if net ~ [ 172.16.0.0/12 ] then accept;" routerFragment;
      outFilter6 = lib.hasInfix "if net ~ [ fd11::/16 ] then accept;" routerFragment;
      vipOnly = lib.hasInfix "if net ~ [ 172.16.1.0/24{32,32} ] then accept;" routerFragment;
      noPods = !(lib.hasInfix "10.1.0.0/16" routerFragment);
      forwarding4 = routerCfg.boot.kernel.sysctl."net.ipv4.ip_forward";
      forwarding6 = routerCfg.boot.kernel.sysctl."net.ipv6.conf.all.forwarding";
      firewall4179 = lib.hasInfix "tcp dport 4179 drop" routerCfg.networking.firewall.extraInputRules;
      ndppdOff = !routerCfg.services.ndppd.enable;
    };
    expected = {
      export = {
        asn = fleetAsn;
        routerPrefixes = [
          "172.16.0.0/12"
          "fd11::/16"
        ];
        schemaVersion = 1;
      };
      outFilter = true;
      outFilter6 = true;
      vipOnly = true;
      noPods = true;
      forwarding4 = true;
      forwarding6 = true;
      firewall4179 = true;
      ndppdOff = true;
    };
  };

  # The campaign-A fleet check goes live with a router in the inventory:
  # the base inventory passes (pools ⊆ prefixes)...
  test_fleetCheckPassesWithRouter = {
    expr =
      (kube.mkFleetChecks clanLib evaled.config.exports)
      .kube-cluster-shared-bgp-border-prefixes.assertion;
    expected = true;
  };

  # ...and the whole clan evals clean (clan.checks included).
  test_baseInventoryEvals = {
    expr = builtins.deepSeq evaled.config.checks true;
    expected = true;
  };

  # --- dual role (D33: cluster member + fleet admin) --------------------------

  test_dualRoleMerges = {
    expr = {
      evals = builtins.deepSeq dualRoleEvaled.config.checks true;
      # D19 revised: the distro services render NO cluster BIRD fragment —
      # only the legacy fleet-routing fragment remains (until 5R3 deletes
      # this service outright).
      clusterFragmentAbsent = !(betaDual.clan.bird.fragments ? kube-cluster-k3s);
      fleetFragmentPresent = betaDual.clan.bird.fragments ? fleet-routing-fleet;
      oneBird = betaDual.services.bird.enable;
      # both services set the router id to the same mesh IPv4 — merges.
      routerId = betaDual.clan.bird.routerId;
      # assembled config carries the fleet fragment and ONE device protocol
      assembledDeviceCount = countInfix "protocol device" betaDual.services.bird.config;
      assembledFleetOnly =
        lib.hasInfix "# ---- fragment fleet-routing-fleet ----" betaDual.services.bird.config
        && !(lib.hasInfix "# ---- fragment kube-cluster-k3s ----" betaDual.services.bird.config);
      routedKeys = builtins.attrNames (
        lib.filterAttrs (
          name: _: lib.hasPrefix "40-fleet-routing-fleet-" name
        ) betaDual.systemd.network.netdevs
      );
      selfIgpUsesMesh =
        lib.hasInfix "route 192.168.77.2/32 via 192.168.77.2 dev \"wg-mesh\" onlink;"
          betaDual.clan.bird.fragments."fleet-routing-fleet".config;
      remoteIgpUsesRouted = lib.hasInfix "route 192.168.77.1/32 via 192.168.77.1 dev \"${
        routedInterfaceName "fleet" "k3s" "k3s" "alpha"
      }\" onlink;" betaDual.clan.bird.fragments."fleet-routing-fleet".config;
      kernelExportOnlyFleet =
        countInfix "if proto = \"fr_fleet_k3s_k3s_"
          betaDual.clan.bird.fragments."fleet-routing-fleet".config == 4
        && !(lib.hasInfix "proto = \"k3s_cilium\""
          betaDual.clan.bird.fragments."fleet-routing-fleet".config
        );
    };
    expected = {
      evals = true;
      clusterFragmentAbsent = true;
      fleetFragmentPresent = true;
      oneBird = true;
      routerId = "192.168.77.2";
      assembledDeviceCount = 1;
      assembledFleetOnly = true;
      routedKeys = [
        (routedNetdev "fleet" (routedInterfaceName "fleet" "k3s" "k3s" "alpha"))
      ];
      selfIgpUsesMesh = true;
      remoteIgpUsesRouted = true;
      kernelExportOnlyFleet = true;
    };
  };

  test_multiInstanceRoutedNamesDoNotCollide =
    let
      fleetInstances = [
        "fleet"
        secondFleetInstance
      ];
      members = [
        "alpha"
        "beta"
      ];
      expectedNames = lib.sort builtins.lessThan (
        lib.concatMap (
          fleetInstance: map (member: routedInterfaceName fleetInstance "k3s" "k3s" member) members
        ) fleetInstances
      );
      routed = lib.filterAttrs (
        name: _: lib.hasPrefix "40-fleet-routing-" name
      ) multiClient.systemd.network.netdevs;
      names = map (key: routed.${key}.netdevConfig.Name) (builtins.attrNames routed);
    in
    {
      expr = {
        evals = builtins.deepSeq multiInstanceEvaled.config.checks true;
        netdevCount = builtins.length (builtins.attrNames routed);
        names = lib.sort builtins.lessThan names;
        uniqueNames = lib.length (lib.unique names) == lib.length names;
        allShort = lib.all (name: builtins.stringLength name <= 15) names;
        mainMeshPeers =
          builtins.length
            multiClient.systemd.network.netdevs."40-wireguard-mesh-mesh".wireguardPeers;
      };
      expected = {
        evals = true;
        netdevCount = 4;
        names = expectedNames;
        uniqueNames = true;
        allShort = true;
        mainMeshPeers = 4;
      };
    };

  # --- negatives --------------------------------------------------------------

  test_routerPrefixesEscapeRejected = {
    expr = {
      roleAssertion = failedAssertion escapeNoChecks.config.nixosConfigurations.router.config "escape this router's prefixes";
      # the fleet-wide check (campaign A) throws the whole clan eval
      fleetCheckThrows = !(builtins.tryEval (builtins.deepSeq escapeEvaled.config true)).success;
    };
    expected = {
      roleAssertion = true;
      fleetCheckThrows = true;
    };
  };

  test_meshMembershipRequired = {
    expr = failedAssertion noMeshEvaled.config.nixosConfigurations.client.config "no node_transport export";
    expected = true;
  };

  test_routedEndpointRequired = {
    expr = failedAssertion noRoutedEndpointEvaled.config.nixosConfigurations.client.config "every remote cluster member needs a reachable node_transport endpoint";
    expected = true;
  };

  test_doubleRoleRejected = {
    expr = failedAssertion doubleRoleEvaled.config.nixosConfigurations.client.config "multiple roles in one instance";
    expected = true;
  };

  test_missingClusterRejected = {
    expr = failedAssertion missingClusterEvaled.config.nixosConfigurations.client.config "no kube_cluster export";
    expected = true;
  };

  test_exportsDeepEval = {
    expr = builtins.deepSeq evaled.config.exports true;
    expected = true;
  };
}
