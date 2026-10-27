{
  lib,
  inputs,
  pkgs,
}:
let
  kube = import ../default.nix { inherit lib; };
  clanLib = inputs.clan-core.lib;
  cidr = import ../cidr.nix { inherit lib; };

  # Minimal valid cluster settings for rendering tests.
  domain = "example.org";
  baseConfig = {
    inherit domain;
    network = {
      fabric = null;
      podCIDRv4 = null;
      podCIDRv6 = null;
      serviceCIDRv4 = null;
      serviceCIDRv6 = null;
    };
    cilium = {
      id = 1;
      helmValues = { };
    };
    meshGroup = null;
    pools = { };
    distroDefaults.enable = false;
    coredns = {
      rewrites = [ ];
      helmValues = { };
    };
    packages = {
      images = [ ];
    };
  };

  # Evaluate the cluster interface so option defaults are applied.
  evalSettings =
    extraConfig:
    (lib.evalModules {
      modules = [
        kube.interfaces.cluster
        (_: {
          config = lib.recursiveUpdate baseConfig (lib.recursiveUpdate { fabric.enable = true; } extraConfig);
        })
      ];
    }).config;

  baseSettings = evalSettings { fabric.enable = true; };

  # Native transport device facts: EVERY datapath interface, smallest
  # interface MTU (D58 — the derived profile MTU; VXLAN subtracts 50).
  transportFacts = {
    interfaces = [
      "wg-fleet-1"
      "wg-fleet-2"
    ];
    directRoutingDevice = "wg-fleet-1";
    mtu = 1404;
    mode = "native";
    tunnelProtocol = null;
  };

  # The same facts via the generic resolver (profile validation, D58).
  nativeProfile = kube.transport.resolve {
    instanceName = "test";
    machineName = "node-1";
    transport = {
      schemaVersion = 2;
      ipv4 = "10.0.0.1";
      ipv6 = "fd00::1";
      instance = "fleet";
      endpoint = null;
      port = 51820;
      interfaces = {
        "wg-fleet-1" = {
          mtu = 1404;
        };
        "wg-fleet-2" = {
          mtu = 1420;
        };
      };
      directRoutingDevice = "wg-fleet-1";
      datapath = {
        mode = "native";
        tunnelProtocol = null;
      };
      native.routeExchange = "local-router";
      internalLoadBalancer = true;
      nodePort = true;
    };
  };

  tunnelProfile = kube.transport.resolve {
    instanceName = "test";
    machineName = "node-1";
    transport = {
      schemaVersion = 2;
      ipv4 = "10.0.0.1";
      ipv6 = "fd00::1";
      instance = "mesh";
      endpoint = null;
      port = 51820;
      interfaces = {
        "wg-mesh" = {
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

  instanceName = "test";

  ciliumValues = kube.render.mkCiliumValues {
    settings = baseSettings;
    inherit transportFacts instanceName;
    k8sServiceHost = "kubeapi-test.example.org";
    k8sServicePort = 6443;
  };

  # --- Bundle rendering (D26/D40) --------------------------------------

  ciliumVersions = import (inputs.pkgs + "/pkgs/cilium/versions.nix");
  baseManifest = inputs.pkgs + "/manifests/cilium/${ciliumVersions.chartVersion}.yaml";

  corednsVersions = import (inputs.pkgs + "/pkgs/coredns/versions.nix");

  members = [
    {
      machineName = "node-1";
      ipv4 = "10.0.0.1";
      ipv6 = "fd00::1";
      poolBlocks = [ ];
    }
    {
      machineName = "node-2";
      ipv4 = "10.0.0.2";
      ipv6 = "fd00::2";
      poolBlocks = [ "192.168.9.0/24" ];
    }
  ];

  # ClusterMesh members (placement selection needs role + settings).
  meshMembers = [
    {
      machineName = "node-1";
      role = "server";
      ipv4 = "10.0.0.1";
      ipv6 = "fd00::1";
      settings = {
        nodeLabels = { };
        topology = {
          region = null;
          zone = null;
        };
      };
    }
    {
      machineName = "node-2";
      role = "server";
      ipv4 = "10.0.0.2";
      ipv6 = "fd00::2";
      settings = {
        nodeLabels = { };
        topology = {
          region = null;
          zone = null;
        };
      };
    }
  ];

  manifestLabels = kube.render.mkManifestLabels { inherit instanceName; };

  # The ClusterMesh resolution seam the distro services use (D60). The
  # fixture transport exposes BOTH capabilities (routed-fabric-like);
  # exposure follows the settings (auto → internal-load-balancer when the
  # fabric pool renders, else node-port).
  mkTestMesh =
    {
      settings,
      peers ? { },
    }:
    kube.mesh.resolve {
      inherit
        instanceName
        settings
        peers
        ;
      ciliumId = 1;
      domain = "example.org";
      members = meshMembers;
      transport = {
        internalLoadBalancer = true;
        nodePort = true;
      };
      fabricBlocks =
        if settings.fabric.enable then
          kube.bgp.fabricBlocks {
            ciliumId = 1;
            inherit settings;
          }
        else
          null;
    };

  mkTestBundle =
    settings:
    let
      # The same data-plane resolution seam the distro services use
      # (D9/D10/D19/D49).
      dp = kube.resolveDataPlane {
        inherit settings instanceName members;
        ciliumId = 1;
      };
    in
    kube.render.mkBundle {
      inherit
        pkgs
        settings
        instanceName
        manifestLabels
        baseManifest
        ;
      kubenixSrc = inputs.kubenix;
      profile = kube.render.mkCiliumValues {
        inherit settings transportFacts instanceName;
        k8sServiceHost = "kubeapi-test.example.org";
        k8sServicePort = 6443;
      };
      pools = kube.render.resolvePools {
        inherit settings members;
        extraPools = lib.optionalAttrs (dp.fabricPool != null) { ${dp.fabricPool.name} = dp.fabricPool; };
      };
      podIPCidr = "10.1.0.0/16,fd10:1::/56";
      clusterDNS = "10.2.0.10";
      coreDNSImage = "${corednsVersions.repo}:${corednsVersions.tag}@${corednsVersions.digest}";
      k8sServiceHost = "kubeapi-test.example.org";
      bgp = dp.bgpBundle;
      mesh = mkTestMesh { inherit settings; };
    };

  bundle = mkTestBundle baseSettings;
  bundleAgain = mkTestBundle baseSettings;
  bundleObjects = builtins.fromJSON bundle.json;

  findObj =
    kind: name: lib.findFirst (o: o.kind == kind && o.metadata.name == name) null bundleObjects;

  ciliumConfig = (findObj "ConfigMap" "cilium-config").data;

  # A bundle whose helmValues violate invariants must throw at eval.
  violatingBundle = mkTestBundle (evalSettings {
    cilium.helmValues.gatewayAPI.enabled = true;
  });
  violatingThrew =
    !(builtins.tryEval (builtins.deepSeq violatingBundle.json violatingBundle.json)).success;

  ipamKubernetesBundle = mkTestBundle (evalSettings {
    cilium.helmValues.ipam.mode = "kubernetes";
  });
  ipamKubernetesOk =
    (builtins.tryEval (builtins.deepSeq ipamKubernetesBundle.json ipamKubernetesBundle.json)).success;

  unknownKeyBundle = mkTestBundle (evalSettings {
    cilium.helmValues.hubble.relay.enabled = true;
  });
  unknownKeyThrew =
    !(builtins.tryEval (builtins.deepSeq unknownKeyBundle.json unknownKeyBundle.json)).success;

  bundleWithPools = mkTestBundle (evalSettings {
    pools.ingress = {
      blocks = [
        "203.0.113.0/28"
        "fd20:99::/64"
      ];
      serviceSelector."clan.lol/pool" = "ingress";
      delivery = "external-class";
    };
    coredns.rewrites = [ "name suffix svc.test.example.org svc.cluster.local answer auto" ];
  });

  # D46: distroDefaults=true keeps the distro's stock CoreDNS for
  # cluster.local; the bundle skips its own (mode-exclusive) and renders
  # the legacy coredns-custom ConfigMap for the stock Corefile's import.
  bundleStock = mkTestBundle (evalSettings {
    distroDefaults.enable = true;
    coredns.rewrites = [ "name foo.test.example.org kubernetes.default.svc.cluster.local" ];
  });
  bundleStockObjects = builtins.fromJSON bundleStock.json;

  # Assertion helpers.
  failedAssertion =
    assertions: needle: lib.any (item: !item.assertion && lib.hasInfix needle item.message) assertions;

  # A fake package for the generator tests.
  fakePackage = lib.warn "fake package used for assertion test" (
    builtins.derivation {
      name = "fake";
      system = "x86_64-linux";
      builder = "/bin/sh";
      args = [
        "-c"
        "echo ok > $out"
      ];
    }
  );

  # One-member role list for assertion tests.
  oneServer = [
    {
      machineName = "alpha";
      role = "server";
      settings = {
        clusterInit = true;
        network = {
          ipv4 = "10.0.0.1";
          ipv6 = "fd00::1";
        };
      };
    }
  ];

  # Two-member role list (server + agent) for the parity tests.
  parityMembers = [
    {
      machineName = "alpha";
      role = "server";
      settings = {
        clusterInit = true;
        network = {
          ipv4 = "10.0.0.1";
          ipv6 = "fd00::1";
        };
      };
    }
    {
      machineName = "beta";
      role = "agent";
      settings = {
        clusterInit = false;
        network = {
          ipv4 = "10.0.0.2";
          ipv6 = "fd00::2";
        };
      };
    }
  ];

  # Hand-built kube_cluster exports for the fleet checks (the applied
  # exports tree shape: scope string -> { kube_cluster = { ... }; }).
  # schemaVersion 4 shape (D58/D60): datapath facts + mesh facts.
  mkKubeExport =
    {
      name,
      ciliumId,
      meshGroup ? "clan",
      fabricService ? "routed-fabric",
      fabricInstance ? "fleet",
      meshPeers ? null,
      datapathMode ? "native",
      tunnelProtocol ? null,
      maxConnectedClusters ? 255,
      exposure ? {
        method = "internal-load-balancer";
        nodePort = null;
        replicas = 2;
        vip4 = "172.16.${toString ciliumId}.79";
        dnsName = null;
        loadBalancerClass = "io.cilium/bgp-control-plane";
        published = [ "https://172.16.${toString ciliumId}.79:2379" ];
      },
      podCIDRv4 ? "10.1.0.0/16",
      podCIDRv6 ? "fd10:1::/56",
      serviceCIDRv4 ? "10.2.0.0/16",
      serviceCIDRv6 ? "fd10:2::/112",
    }:
    {
      inherit name ciliumId meshGroup;
      network = {
        inherit
          podCIDRv4
          podCIDRv6
          serviceCIDRv4
          serviceCIDRv6
          ;
        clusterDNS = "10.2.0.10";
        fabric = {
          service = fabricService;
          instance = fabricInstance;
        };
      };
      datapath = {
        mode = datapathMode;
        inherit tunnelProtocol;
        routeExchange = if datapathMode == "native" then "local-router" else null;
        devices = [ "wg-fleet-1" ];
        directRoutingDevice = "wg-fleet-1";
        mtu = 1404;
        internalLoadBalancer = true;
        nodePort = true;
      };
      mesh = {
        peers = meshPeers;
        inherit
          maxConnectedClusters
          exposure
          ;
        placement = "voters";
      };
      controlDomain.role = "standalone";
      members = { };
      pools = { };
      schemaVersion = 4;
    };

  # Two clusters (rke2/prod + k3s/prod2), alpha shared → D16 violation;
  # distinct names/ids/CIDRs otherwise.
  fleetExportsOverlap = {
    "rke2:prod:server:alpha".kube_cluster = mkKubeExport {
      name = "prod";
      ciliumId = 1;
    };
    "k3s:prod2:server:alpha".kube_cluster = mkKubeExport {
      name = "prod2";
      ciliumId = 2;
      podCIDRv4 = "10.3.0.0/16";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  fleetExportsIdCollision = {
    "rke2:prod:server:alpha".kube_cluster = mkKubeExport {
      name = "prod";
      ciliumId = 5;
    };
    "k3s:staging:server:beta".kube_cluster = mkKubeExport {
      name = "staging";
      ciliumId = 5;
      podCIDRv4 = "10.3.0.0/16";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  # Same name claimed by two instances (different ids/CIDRs).
  fleetExportsNameCollision = {
    "rke2:prod:server:alpha".kube_cluster = mkKubeExport {
      name = "prod";
      ciliumId = 1;
    };
    "k3s:prod:server:beta".kube_cluster = mkKubeExport {
      name = "prod";
      ciliumId = 2;
      podCIDRv4 = "10.3.0.0/16";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  # Same group, overlapping pod CIDRs (different ids, explicit CIDRs).
  fleetExportsCidrOverlap = {
    "rke2:prod:server:alpha".kube_cluster = mkKubeExport {
      name = "prod";
      ciliumId = 1;
    };
    "k3s:staging:server:beta".kube_cluster = mkKubeExport {
      name = "staging";
      ciliumId = 2;
      podCIDRv4 = "10.1.128.0/17";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  # Same overlap but DIFFERENT mesh groups → allowed.
  fleetExportsCidrSeparateGroups = {
    "rke2:prod:server:alpha".kube_cluster = mkKubeExport {
      name = "prod";
      ciliumId = 1;
    };
    "k3s:staging:server:beta".kube_cluster = mkKubeExport {
      name = "staging";
      ciliumId = 2;
      meshGroup = "other";
      podCIDRv4 = "10.1.128.0/17";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  # Same group, different transport instances → rejected.
  fleetExportsTransportMixed = {
    "rke2:prod:server:alpha".kube_cluster = mkKubeExport {
      name = "prod";
      ciliumId = 1;
    };
    "k3s:staging:server:beta".kube_cluster = mkKubeExport {
      name = "staging";
      ciliumId = 2;
      fabricInstance = "fleet-b";
      podCIDRv4 = "10.3.0.0/16";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  fleetChecksPass = kube.mkFleetChecks clanLib fleetExportsSeparateGroupsPass;
  fleetExportsSeparateGroupsPass = fleetExportsCidrSeparateGroups;

  # --- BGP / fabric fixtures (D9/D10/D19/D49/D55) --------------------------

  findObjKind =
    objects: kind: name:
    lib.findFirst (o: o.kind == kind && o.metadata.name == name) null objects;

  # D13 opt-in on (ClusterIP); pod-pool advertisements are always on.
  bundleD13Objects =
    builtins.fromJSON
      (mkTestBundle (evalSettings {
        bgp.advertiseClusterIPs = true;
      })).json;

  # BGP off: fabric off + bgp.enable=false (the consistent pair). The
  # fabric pool is gone, so auto exposure resolves to node-port (D60).
  bundleNoBgpObjects =
    builtins.fromJSON
      (mkTestBundle (evalSettings {
        fabric.enable = false;
        bgp.enable = false;
      })).json;

  # node-port exposure bundle (explicit; no pool draw).
  bundleNodePortObjects =
    builtins.fromJSON
      (mkTestBundle (evalSettings {
        fabric.enable = false;
        bgp.enable = false;
        mesh.exposure = "node-port";
      })).json;

  # External exposure bundle (no internal capability needed, D60).
  bundleExternalObjects =
    builtins.fromJSON
      (mkTestBundle (evalSettings {
        mesh.exposure = "external-load-balancer";
        mesh.external = {
          loadBalancerClass = "cloud.example/mesh-lb";
          dnsName = "mesh.test.example.org";
          annotations."external-dns.alpha.kubernetes.io/hostname" = "mesh.test.example.org";
        };
      })).json;

  # BGP ASN collision via the export facts (phase-5 schema).
  fleetExportsAsnCollision = {
    "rke2:prod:server:alpha".kube_cluster =
      (mkKubeExport {
        name = "prod";
        ciliumId = 1;
      })
      // {
        bgp = {
          enabled = true;
          ciliumAsn = 4200000001;
          hostAsn = 4200000002;
        };
      };
    "k3s:staging:server:beta".kube_cluster =
      (mkKubeExport {
        name = "staging";
        ciliumId = 2;
        podCIDRv4 = "10.3.0.0/16";
        podCIDRv6 = "fd10:3::/56";
        serviceCIDRv4 = "10.4.0.0/16";
        serviceCIDRv6 = "fd10:4::/112";
      })
      // {
        bgp = {
          enabled = true;
          ciliumAsn = 4200000001;
          hostAsn = 4200000003;
        };
      };
  };

  # A routed-fabric border export plus a cluster exporting a shared-bgp
  # fabric pool.
  mkRouterPrefixExports = borderOwnedPrefixes: {
    "rke2:prod:server:alpha".kube_cluster =
      (mkKubeExport {
        name = "prod";
        ciliumId = 1;
      })
      // {
        pools.fabric = {
          scope = "cluster-global";
          delivery = "shared-bgp";
          blocks = [
            "172.16.1.0/24"
            "fd11:1::/64"
          ];
          serviceSelector = { };
        };
      };
    "routed-fabric:fleet:member:gw1".routed_fabric = {
      border = {
        enabled = true;
        ownedPrefixes = borderOwnedPrefixes;
      };
    };
  };

  # --- ClusterMesh + transport fixtures (D58/D60) --------------------------

  apiserverDeploy = findObj "Deployment" "clustermesh-apiserver";
  apiserverService = findObj "Service" "clustermesh-apiserver";
  remoteUsers = (findObj "ConfigMap" "clustermesh-remote-users").data."users.yaml";

  meshThrows =
    extraMesh:
    !(builtins.tryEval (
      builtins.deepSeq (mkTestMesh { settings = evalSettings { mesh = extraMesh; }; }) true
    )).success;

  meshThrowsWithTransport =
    extraMesh: transport:
    !(builtins.tryEval (
      builtins.deepSeq (kube.mesh.resolve {
        inherit instanceName transport;
        settings = evalSettings { mesh = extraMesh; };
        ciliumId = 1;
        domain = "example.org";
        members = meshMembers;
        peers = { };
        fabricBlocks = null;
      }) true
    )).success;

  transportThrows =
    transport:
    !(builtins.tryEval (
      builtins.deepSeq (kube.transport.resolve {
        inherit instanceName;
        machineName = "node-1";
        inherit transport;
      }) true
    )).success;

  ciliumThrows =
    helmValues:
    !(builtins.tryEval (
      builtins.deepSeq (kube.render.mkCiliumValues {
        settings = evalSettings {
          cilium.helmValues = helmValues;
        };
        transportFacts = {
          interfaces = [ "wg-fleet-1" ];
          directRoutingDevice = "wg-fleet-1";
          mtu = 1404;
          mode = "native";
          tunnelProtocol = null;
        };
        inherit instanceName;
        k8sServiceHost = "kubeapi-test.example.org";
      }) true
    )).success;

  # The VXLAN profile renders the tunnel cilium-config keys.
  tunnelBundle =
    let
      settings = baseSettings;
      dp = kube.resolveDataPlane {
        inherit settings instanceName members;
        ciliumId = 1;
      };
    in
    builtins.fromJSON
      (kube.render.mkBundle {
        inherit
          pkgs
          settings
          instanceName
          manifestLabels
          baseManifest
          ;
        kubenixSrc = inputs.kubenix;
        profile = kube.render.mkCiliumValues {
          inherit settings instanceName;
          transportFacts = {
            interfaces = [ "wg-mesh" ];
            directRoutingDevice = "wg-mesh";
            inherit (tunnelProfile) mtu;
            mode = "tunnel";
            tunnelProtocol = "vxlan";
          };
          k8sServiceHost = "kubeapi-test.example.org";
          k8sServicePort = 6443;
        };
        pools = kube.render.resolvePools {
          inherit settings members;
          extraPools = lib.optionalAttrs (dp.fabricPool != null) { ${dp.fabricPool.name} = dp.fabricPool; };
        };
        podIPCidr = "10.1.0.0/16,fd10:1::/56";
        clusterDNS = "10.2.0.10";
        coreDNSImage = "${corednsVersions.repo}:${corednsVersions.tag}@${corednsVersions.digest}";
        k8sServiceHost = "kubeapi-test.example.org";
        bgp = dp.bgpBundle;
        mesh = mkTestMesh { inherit settings; };
      }).json;

  # Uniformity: mixed datapath mode / maxConnectedClusters inside one
  # group is rejected; identical members pass.
  fleetExportsMixedMode = {
    "rke2:prod:server:alpha".kube_cluster = mkKubeExport {
      name = "prod";
      ciliumId = 1;
    };
    "k3s:staging:server:beta".kube_cluster = mkKubeExport {
      name = "staging";
      ciliumId = 2;
      datapathMode = "tunnel";
      tunnelProtocol = "vxlan";
      podCIDRv4 = "10.3.0.0/16";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  fleetExportsSameGroupMccBase = {
    "rke2:prod:server:alpha".kube_cluster = mkKubeExport {
      name = "prod";
      ciliumId = 1; # default maxConnectedClusters = 255
    };
    "k3s:staging:server:beta".kube_cluster = mkKubeExport {
      name = "staging";
      ciliumId = 2;
      maxConnectedClusters = 511;
      podCIDRv4 = "10.3.0.0/16";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  # Selective peers: symmetric A↔B passes; one-directional is rejected;
  # unknown peers are rejected.
  fleetExportsSelectiveOk = {
    "rke2:prod:server:alpha".kube_cluster =
      (mkKubeExport {
        name = "prod";
        ciliumId = 1;
      })
      // {
        mesh.peers = [ "staging" ];
      };
    "k3s:staging:server:beta".kube_cluster = mkKubeExport {
      name = "staging";
      ciliumId = 2;
      meshPeers = [ "prod" ];
      podCIDRv4 = "10.3.0.0/16";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  fleetExportsSelectiveAsymmetric = {
    "rke2:prod:server:alpha".kube_cluster =
      (mkKubeExport {
        name = "prod";
        ciliumId = 1;
      })
      // {
        mesh.peers = [ "staging" ];
      };
    "k3s:staging:server:beta".kube_cluster = mkKubeExport {
      name = "staging";
      ciliumId = 2;
      meshPeers = [ "other" ];
      podCIDRv4 = "10.3.0.0/16";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  # NodePort collision fleet check: two clusters claiming the same machine
  # with the same NodePort (machine-level claims, D60).
  fleetExportsNodePortCollision = {
    "rke2:prod:server:alpha".kube_cluster =
      (mkKubeExport {
        name = "prod";
        ciliumId = 1;
      })
      // {
        mesh.exposure = {
          method = "node-port";
          nodePort = 32379;
          replicas = 1;
          vip4 = null;
          dnsName = null;
          loadBalancerClass = null;
          published = [ "https://10.0.0.1:32379" ];
        };
      };
    "k3s:prod2:server:alpha".kube_cluster = mkKubeExport {
      name = "prod2";
      ciliumId = 2;
      exposure = {
        method = "node-port";
        nodePort = 32379;
        replicas = 1;
        vip4 = null;
        dnsName = null;
        loadBalancerClass = null;
        published = [ "https://10.0.0.1:32379" ];
      };
      podCIDRv4 = "10.3.0.0/16";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  # VIP collision fleet check: explicit fabric block pins colliding at
  # offset 79 across clusters.
  fleetExportsVipCollision = {
    "rke2:prod:server:alpha".kube_cluster =
      (mkKubeExport {
        name = "prod";
        ciliumId = 1;
      })
      // {
        mesh.exposure.vip4 = "172.16.7.79";
        mesh.exposure.published = [ "https://172.16.7.79:2379" ];
      };
    "k3s:staging:server:beta".kube_cluster = mkKubeExport {
      name = "staging";
      ciliumId = 2;
      exposure = {
        method = "internal-load-balancer";
        nodePort = null;
        replicas = 1;
        vip4 = "172.16.7.79";
        dnsName = null;
        loadBalancerClass = "io.cilium/bgp-control-plane";
        published = [ "https://172.16.7.79:2379" ];
      };
      podCIDRv4 = "10.3.0.0/16";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  # --- Mesh vars generators (D60) ------------------------------------------

  meshCaGen = kube.vars.mkMeshCaGenerator {
    pkgs = fakePackage;
    group = "clan";
  };
  meshCertGen = kube.vars.mkMeshCertGenerator {
    pkgs = fakePackage;
    instanceName = "test";
    group = "clan";
    sans = {
      dns = [
        "test.mesh.example.org"
        "mesh.example.org"
      ];
      ip = [
        "172.16.1.79"
        "10.0.0.1"
      ];
    };
  };
in
{
  test_ciliumValues_nativeAndMtu = {
    expr = {
      inherit (ciliumValues)
        routingMode
        autoDirectNodeRoutes
        kubeProxyReplacement
        MTU
        devices
        ;
      ciliumIptables = ciliumValues.extraConfig."install-iptables-rules";
      inherit (ciliumValues.cluster) name id;
    };
    expected = {
      routingMode = "native";
      autoDirectNodeRoutes = false;
      kubeProxyReplacement = true;
      MTU = 1404;
      devices = "wg-fleet-1 wg-fleet-2";
      ciliumIptables = true;
      name = "test";
      id = 1;
    };
  };

  test_ciliumValues_nodeIpamOnByDefault = {
    expr = {
      inherit (ciliumValues) defaultLBServiceIPAM;
      inherit (ciliumValues.nodeIPAM) enabled;
    };
    expected = {
      defaultLBServiceIPAM = "nodeipam";
      enabled = true;
    };
  };

  test_ciliumValues_gatewayAndIngressPermanentlyOff = {
    expr = {
      inherit (ciliumValues.gatewayAPI) enabled;
      ingress = ciliumValues.ingressController.enabled;
    };
    expected = {
      enabled = false;
      ingress = false;
    };
  };

  # --- bundle tests -----------------------------------------------------

  # Two independent evals of the same inputs produce identical bytes.
  test_bundleDeterministic = {
    expr = bundle.json == bundleAgain.json;
    expected = true;
  };

  # The singleton ClusterMesh Deployment mounts this ConfigMap even though
  # the chart omits it while clustermesh.config is disabled.
  test_bundleSingletonClusterMeshUsers = {
    expr = (findObj "ConfigMap" "clustermesh-remote-users").data."users.yaml";
    expected = "users:\n";
  };

  # Post-merge invariant validation (§6.4): gatewayAPI.enabled=true throws.
  test_bundleInvariantGatewayApiThrows = {
    expr = violatingThrew;
    expected = true;
  };

  # ipam.mode=kubernetes is an allowed explicit override (D41).
  test_bundleIpamKubernetesAllowed = {
    expr = ipamKubernetesOk;
    expected = true;
  };

  # helmValues keys with no layer-2 translation throw instead of being
  # silently dropped.
  test_bundleUnknownHelmValueThrows = {
    expr = unknownKeyThrew;
    expected = true;
  };

  # Node IPAM (D41) is patched into the rendered cilium-config ConfigMap.
  test_bundleNodeIpamInConfigMap = {
    expr = {
      inherit (ciliumConfig) enable-node-ipam default-lb-service-ipam;
    };
    expected = {
      enable-node-ipam = "true";
      default-lb-service-ipam = "nodeipam";
    };
  };

  # Per-cluster identity + KPR endpoint land in the bundle. The agent
  # container is named "cilium-agent" in the committed base manifest.
  test_bundleClusterIdentityAndKpr = {
    expr =
      let
        ds = findObj "DaemonSet" "cilium";
        agentContainer = lib.findFirst (c: c.name == "cilium-agent") null ds.spec.template.spec.containers;
        envHost =
          (lib.findFirst (e: e.name == "KUBERNETES_SERVICE_HOST") { value = null; } agentContainer.env).value;
        envPort =
          (lib.findFirst (e: e.name == "KUBERNETES_SERVICE_PORT") { value = null; } agentContainer.env).value;
      in
      {
        inherit (ciliumConfig)
          cluster-name
          cluster-id
          routing-mode
          auto-direct-node-routes
          direct-routing-device
          install-iptables-rules
          ;
        # The native base chart still emits the inert tunnel-protocol
        # template key; the datapath signal is routing-mode + no
        # cilium_vxlan device (probe lesson), so only routing-mode is
        # asserted here.
        inherit envHost envPort;
      };
    expected = {
      cluster-name = "test";
      cluster-id = "1";
      routing-mode = "native";
      auto-direct-node-routes = "false";
      direct-routing-device = "wg-fleet-1";
      install-iptables-rules = "true";
      envHost = "kubeapi-test.example.org";
      envPort = "6443";
    };
  };

  # The dual-stack pod CIDRs land in the default CiliumPodIPPool.
  test_bundlePodIPPool = {
    expr =
      let
        p = findObj "CiliumPodIPPool" "default";
      in
      {
        v4 = p.spec.ipv4.cidrs;
        v6 = p.spec.ipv6.cidrs;
      };
    expected = {
      v4 = [ "10.1.0.0/16" ];
      v6 = [ "fd10:1::/56" ];
    };
  };

  # Auto per-machine node pools (join /32+/128 + poolBlocks) and declared
  # cluster-global pools render as CiliumLoadBalancerIPPool CRs (D8).
  test_bundlePools = {
    expr =
      let
        objects = builtins.fromJSON bundleWithPools.json;
        find = kind: name: lib.findFirst (o: o.kind == kind && o.metadata.name == name) null objects;
        node1 = find "CiliumLoadBalancerIPPool" "node-1";
        node2 = find "CiliumLoadBalancerIPPool" "node-2";
        ingress = find "CiliumLoadBalancerIPPool" "ingress";
      in
      {
        node1Blocks = node1.spec.blocks;
        node2Blocks = node2.spec.blocks;
        node1Selector = node1.spec.serviceSelector.matchLabels;
        ingressBlocks = ingress.spec.blocks;
        ingressSelector = ingress.spec.serviceSelector.matchLabels;
      };
    expected = {
      node1Blocks = [
        { cidr = "10.0.0.1/32"; }
        { cidr = "fd00::1/128"; }
      ];
      node2Blocks = [
        { cidr = "10.0.0.2/32"; }
        { cidr = "fd00::2/128"; }
        { cidr = "192.168.9.0/24"; }
      ];
      node1Selector."clan.lol/pool" = "node-1";
      ingressBlocks = [
        { cidr = "203.0.113.0/28"; }
        { cidr = "fd20:99::/64"; }
      ];
      ingressSelector."clan.lol/pool" = "ingress";
    };
  };

  # D46: the uniform clan CoreDNS renders in the minimal base — Service
  # pinned to the derived clusterDNS IP, rewrites folded into the Corefile,
  # digest-pinned image.
  test_bundleCoreDNSMinimal = {
    expr =
      let
        objects = builtins.fromJSON bundleWithPools.json;
        deploy = lib.findFirst (o: o.kind == "Deployment" && o.metadata.name == "coredns") null objects;
        svc = lib.findFirst (o: o.kind == "Service" && o.metadata.name == "kube-dns") null objects;
        cm = lib.findFirst (o: o.kind == "ConfigMap" && o.metadata.name == "coredns") null objects;
        sa = lib.findFirst (o: o.kind == "ServiceAccount" && o.metadata.name == "coredns") null objects;
        crb = lib.findFirst (
          o: o.kind == "ClusterRoleBinding" && o.metadata.name == "coredns"
        ) null objects;
        container = lib.findFirst (c: c.name == "coredns") null deploy.spec.template.spec.containers;
        legacyCm = lib.findFirst (
          o: o.kind == "ConfigMap" && o.metadata.name == "coredns-custom"
        ) null objects;
      in
      {
        deployPresent = deploy != null;
        saPresent = sa != null;
        crbPresent = crb != null;
        clusterIP = svc.spec.clusterIP;
        rewriteFolded = lib.hasInfix "rewrite name suffix svc.test.example.org svc.cluster.local answer auto" cm.data.Corefile;
        clusterLocalZone = lib.hasInfix "kubernetes cluster.local in-addr.arpa ip6.arpa" cm.data.Corefile;
        imageDigestPinned = lib.hasInfix "@sha256:" container.image;
        # minimal mode: the legacy distro-import ConfigMap is NOT rendered
        # (rewrites fold into the clan Corefile)
        legacyAbsent = legacyCm == null;
        replicas = deploy.spec.replicas;
        dnsPolicy = deploy.spec.template.spec.dnsPolicy;
      };
    expected = {
      deployPresent = true;
      saPresent = true;
      crbPresent = true;
      clusterIP = "10.2.0.10";
      rewriteFolded = true;
      clusterLocalZone = true;
      imageDigestPinned = true;
      legacyAbsent = true;
      replicas = 2;
      dnsPolicy = "Default";
    };
  };

  # D46 mode exclusivity: distroDefaults=true keeps the distro CoreDNS —
  # the bundle renders NO cluster.local CoreDNS (Deployment/Service) and
  # keeps the legacy coredns-custom ConfigMap for the stock Corefile's
  # import path.
  test_bundleCoreDNSSkippedUnderDistroDefaults = {
    expr =
      let
        deploy = lib.findFirst (
          o: o.kind == "Deployment" && o.metadata.name == "coredns"
        ) null bundleStockObjects;
        svc = lib.findFirst (
          o: o.kind == "Service" && o.metadata.name == "kube-dns"
        ) null bundleStockObjects;
        legacyCm = lib.findFirst (
          o: o.kind == "ConfigMap" && o.metadata.name == "coredns-custom"
        ) null bundleStockObjects;
      in
      {
        deployAbsent = deploy == null;
        svcAbsent = svc == null;
        legacyContent = legacyCm.data."test.override" or null;
      };
    expected = {
      deployAbsent = true;
      svcAbsent = true;
      legacyContent = "rewrite name foo.test.example.org kubernetes.default.svc.cluster.local";
    };
  };

  # Every object carries the §6.11 manifest labels incl. config-hash.
  test_bundleManifestLabelsEverywhere = {
    expr = lib.all (
      o:
      let
        l = o.metadata.labels or { };
      in
      (l."app.kubernetes.io/managed-by" or null) == "clan"
      && (l."clan.lol/cluster" or null) == instanceName
      && l ? "clan.lol/component"
      && l ? "clan.lol/config-hash"
    ) bundleObjects;
    expected = true;
  };

  # Kubernetes label VALUES cap at 63 bytes — a full sha256 hex (64 chars)
  # is rejected by the apiserver ("must be no more than 63 bytes"). The
  # config-hash label carries a 32-hex-char prefix; the bundle's configHash
  # output stays full-length. Every label value on every object must fit.
  test_bundleLabelValuesFitKubernetes = {
    expr = {
      tooLong = lib.concatMap (
        o:
        map (kv: "${o.kind}/${o.metadata.name}:${kv.name}") (
          lib.filter (kv: builtins.stringLength kv.value > 63) (lib.attrsToList (o.metadata.labels or { }))
        )
      ) bundleObjects;
      hashLabel = (builtins.head bundleObjects).metadata.labels."clan.lol/config-hash";
    };
    expected = {
      tooLong = [ ];
      hashLabel = builtins.substring 0 32 bundle.configHash;
    };
  };

  # Every container in every pod template carries a non-empty image: a
  # named-container patch keyed on the wrong name silently APPENDS an
  # imageless phantom container that the apiserver rejects
  # (spec.template.spec.containers[i].image is Required). The cilium-agent
  # container must exist exactly once and carry the KPR endpoint env — and
  # so must the API-talking init containers (config runs cilium-dbg
  # build-config against the API; clean-cilium-state runs the cleanup
  # client), exactly as the chart renders them when k8sServiceHost is set.
  test_bundleContainersHaveImages = {
    expr =
      let
        imageless = lib.concatMap (
          o:
          let
            t = o.spec.template.spec or null;
          in
          if t == null then
            [ ]
          else
            map (c: "${o.kind}/${o.metadata.name}:${c.name or "?"}") (
              lib.filter (c: (c.image or "") == "") ((t.containers or [ ]) ++ (t.initContainers or [ ]))
            )
        ) bundleObjects;
        ds = findObj "DaemonSet" "cilium";
        agentContainers = lib.filter (c: c.name == "cilium-agent") ds.spec.template.spec.containers;
        agentEnv = map (e: e.name) (builtins.head agentContainers).env;
        initEnvs = map (c: map (e: e.name) c.env) (
          lib.filter (
            c:
            lib.elem c.name [
              "config"
              "clean-cilium-state"
            ]
          ) ds.spec.template.spec.initContainers
        );
      in
      {
        inherit imageless;
        agentContainerCount = builtins.length agentContainers;
        agentHasKprEnv = lib.all (e: lib.elem e agentEnv) [
          "KUBERNETES_SERVICE_HOST"
          "KUBERNETES_SERVICE_PORT"
        ];
        initKprEnvCount = builtins.length (lib.filter (lib.elem "KUBERNETES_SERVICE_HOST") initEnvs);
      };
    expected = {
      imageless = [ ];
      agentContainerCount = 1;
      agentHasKprEnv = true;
      initKprEnvCount = 2;
    };
  };

  # Every container image reference in the bundle is digest-pinned: the
  # artifact-flake Cilium images plus the clan CoreDNS image (D46). The
  # validateBundle check enforces that the committed base manifest's
  # references survive unchanged.
  test_bundleImagesPinned = {
    expr =
      let
        imageStringsOf =
          v:
          if builtins.isAttrs v then
            lib.concatMap (kv: imageStringsOf kv.value) (lib.attrsToList v)
          else if builtins.isList v then
            lib.concatMap imageStringsOf v
          else if
            builtins.isString v
            && (lib.hasPrefix "quay.io/cilium/" v || lib.hasPrefix "registry.k8s.io/coredns/" v)
          then
            [ v ]
          else
            [ ];
        images = lib.unique (lib.concatMap imageStringsOf bundleObjects);
      in
      {
        count = builtins.length images;
        allDigestPinned = lib.all (i: lib.hasInfix "@sha256:" i) images;
      };
    expected = {
      count = 5;
      allDigestPinned = true;
    };
  };

  # The mkLBService helper pins ETP Local + the LB-IPAM class (invariants
  # 5/6) for clan-rendered external-facing Services.
  test_mkLBService = {
    expr = kube.render.mkLBService {
      name = "probe";
      namespace = "kube-system";
      inherit manifestLabels;
      ports = [
        {
          port = 80;
          targetPort = 8080;
        }
      ];
      selector.app = "probe";
    };
    expected = {
      apiVersion = "v1";
      kind = "Service";
      metadata = {
        name = "probe";
        namespace = "kube-system";
        labels = manifestLabels;
      };
      spec = {
        type = "LoadBalancer";
        externalTrafficPolicy = "Local";
        loadBalancerClass = "io.cilium/bgp-control-plane";
        ports = [
          {
            port = 80;
            targetPort = 8080;
          }
        ];
        selector.app = "probe";
      };
    };
  };

  # Pool assertions (D8): overlap, scope⇒mode, floating coverage, name
  # collisions with auto node pools.
  test_poolOverlapAssertion = {
    expr = failedAssertion (kube.assertions.mkPoolAssertions {
      inherit instanceName members;
      ciliumId = 1;
      settings = evalSettings {
        pools.bad = {
          blocks = [ "10.0.0.1/32" ];
          serviceSelector."clan.lol/pool" = "bad";
          delivery = "external-class";
        };
      };
    }) "overlapping pool blocks";
    expected = true;
  };

  test_poolScopeModeAssertion = {
    expr = failedAssertion (kube.assertions.mkPoolAssertions {
      inherit instanceName members;
      ciliumId = 1;
      settings = evalSettings {
        pools.bound = {
          blocks = [ "198.51.100.0/28" ];
          serviceSelector."clan.lol/pool" = "bound";
          delivery = "node-fate-bound";
        };
      };
    }) "node-fate-bound delivery is per-machine scope";
    expected = true;
  };

  test_poolFloatingCoverageAssertion = {
    expr = failedAssertion (kube.assertions.mkPoolAssertions {
      inherit instanceName members;
      ciliumId = 1;
      settings = evalSettings {
        pools.float = {
          blocks = [ "198.51.100.16/28" ];
          serviceSelector."clan.lol/pool" = "float";
          delivery = "floating";
          candidates = [
            "node-1"
            "not-a-member"
          ];
        };
      };
    }) "floating pools need a non-empty candidate set";
    expected = true;
  };

  test_poolNameCollisionAssertion = {
    expr = failedAssertion (kube.assertions.mkPoolAssertions {
      inherit instanceName members;
      ciliumId = 1;
      settings = evalSettings {
        pools.node-1 = {
          blocks = [ "198.51.100.32/28" ];
          serviceSelector."clan.lol/pool" = "node-1";
          delivery = "shared-bgp";
        };
      };
    }) "collide with auto per-machine node pools";
    expected = true;
  };

  test_distroDefaultsOffByDefault = {
    expr = baseSettings.distroDefaults.enable;
    expected = false;
  };

  test_distroDefaultsOptIn = {
    expr = (evalSettings { distroDefaults.enable = true; }).distroDefaults.enable;
    expected = true;
  };

  test_bootstrapApplyOnByDefault = {
    expr = baseSettings.bootstrap.apply;
    expected = true;
  };

  test_missingClusterInitAssertion = {
    expr =
      let
        assertions = kube.assertions.mkClusterAssertions {
          inherit instanceName transportFacts;
          settings = baseSettings;
          roleMembers = [
            {
              machineName = "alpha";
              role = "server";
              settings = {
                clusterInit = false;
                network = {
                  ipv4 = "10.0.0.1";
                  ipv6 = "fd00::1";
                };
              };
            }
          ];
        };
      in
      failedAssertion assertions "exactly one server must set clusterInit";
    expected = true;
  };

  test_missingTransportAddressesAssertion = {
    expr =
      let
        assertions = kube.assertions.mkClusterAssertions {
          inherit instanceName;
          settings = baseSettings;
          transportFacts = null;
          roleMembers = [
            {
              machineName = "alpha";
              role = "server";
              settings = {
                clusterInit = true;
                network = {
                  ipv4 = null;
                  ipv6 = "fd00::1";
                };
              };
            }
          ];
        };
      in
      failedAssertion assertions "network.fabric is null";
    expected = true;
  };

  test_uniqueAddressesAssertion = {
    expr =
      let
        assertions = kube.assertions.mkClusterAssertions {
          inherit instanceName;
          settings = baseSettings;
          transportFacts = null;
          roleMembers = [
            {
              machineName = "alpha";
              role = "server";
              settings = {
                clusterInit = true;
                network = {
                  ipv4 = "10.0.0.1";
                  ipv6 = "fd00::1";
                };
              };
            }
            {
              machineName = "beta";
              role = "agent";
              settings = {
                clusterInit = false;
                network = {
                  ipv4 = "10.0.0.1";
                  ipv6 = "fd00::1";
                };
              };
            }
          ];
        };
      in
      failedAssertion assertions "unique IPv4";
    expected = true;
  };

  test_tokenGeneratorNames = {
    expr =
      let
        tokens = kube.vars.mkTokenGenerators {
          pkgs = {
            openssl = fakePackage;
          };
          inherit instanceName;
        };
      in
      builtins.attrNames tokens;
    expected = [
      "rancher-agent-token-test"
      "rancher-server-token-test"
    ];
  };

  test_pkiGenerator = {
    expr =
      let
        pki = kube.vars.mkPkiGenerator {
          pkgs = {
            openssl = fakePackage;
            coreutils = fakePackage;
            gawk = fakePackage;
          };
          inherit instanceName;
        };
        gen = pki."rancher-pki-${instanceName}";
      in
      {
        inherit (gen) share;
        secretFiles = builtins.sort builtins.lessThan (
          lib.filter (n: gen.files.${n}.secret or true) (builtins.attrNames gen.files)
        );
        publicFiles = builtins.sort builtins.lessThan (
          lib.filter (n: !(gen.files.${n}.secret or true)) (builtins.attrNames gen.files)
        );
      };
    expected = {
      share = true;
      secretFiles = [
        "client-ca.key"
        "etcd-peer-ca.key"
        "etcd-server-ca.key"
        "intermediate-ca.key"
        "request-header-ca.key"
        "root-ca.key"
        "server-ca.key"
        "service.key"
      ];
      publicFiles = [
        "ca-hash"
        "client-ca.crt"
        "etcd-peer-ca.crt"
        "etcd-server-ca.crt"
        "intermediate-ca.pem"
        "request-header-ca.crt"
        "root-ca.pem"
        "server-ca.crt"
      ];
    };
  };

  test_haproxyGenerator = {
    expr =
      let
        gen =
          (kube.vars.mkHaproxyGenerator {
            pkgs = {
              openssl = fakePackage;
              coreutils = fakePackage;
            };
            inherit instanceName;
          })."rancher-haproxy-${instanceName}";
      in
      {
        inherit (gen) share dependencies;
        clientPem = gen.files."kubeapi-client.pem" // {
          # runtime-only attrs are fine to compare here
        };
        caCrtPublic = !(gen.files."kubeapi-ca.crt".secret or true);
      };
    expected = {
      share = true;
      dependencies = [ "rancher-pki-test" ];
      clientPem = {
        owner = "haproxy";
        group = "haproxy";
        mode = "0400";
        restartUnits = [ "haproxy.service" ];
      };
      caCrtPublic = true;
    };
  };

  test_adminKubeconfigGeneratorServerUrl = {
    expr =
      let
        gen =
          (kube.vars.mkAdminKubeconfigGenerator {
            pkgs = {
              openssl = fakePackage;
              coreutils = fakePackage;
            };
            inherit instanceName;
            server = "https://kubeapi-test.example.org:7443";
          })."rancher-admin-kubeconfig-${instanceName}";
      in
      {
        inherit (gen) share dependencies;
        hasServerUrl = lib.hasInfix "server: https://kubeapi-test.example.org:7443" gen.script;
      };
    expected = {
      share = true;
      dependencies = [ "rancher-pki-test" ];
      hasServerUrl = true;
    };
  };

  test_haproxyConfigRender = {
    expr =
      let
        cfg = kube.render.mkHaproxyConfig {
          inherit instanceName;
          nodeIPv4 = "192.168.77.1";
          nodeIPv6 = "fd00:77::1";
          backends = [
            {
              name = "alpha";
              ipv4 = "192.168.77.1";
              ipv6 = "fd00:77::1";
              backup = false;
            }
            {
              name = "beta";
              ipv4 = "192.168.77.2";
              ipv6 = "fd00:77::2";
              backup = true;
            }
          ];
          lbKubeapiPort = 7443;
          caCrtPath = "/run/secrets/shared/rancher-haproxy-test/kubeapi-ca.crt";
          clientPemPath = "/run/secrets/shared/rancher-haproxy-test/kubeapi-client.pem";
          statsPasswordHash = "$6$testhash";
          healthCheckSni = "kubeapi-test.example.org";
        };
      in
      {
        bindsKubeapiLb = lib.hasInfix "bind 192.168.77.1:7443" cfg;
        bindsSupervisorLb = lib.hasInfix "bind 192.168.77.1:8443" cfg;
        bindsStats = lib.hasInfix "bind [fd00:77::1]:8404" cfg;
        backupFlag = lib.hasInfix "server beta-4 192.168.77.2:6443 backup" cfg;
        noBackupOnSelf = !(lib.hasInfix "server alpha-4 192.168.77.1:6443 backup" cfg);
        supervisorTargets9345 = lib.hasInfix "server beta-6 [fd00:77::2]:9345 backup" cfg;
        checkSslDataStaysRaw = lib.hasInfix "default-server check check-ssl verify required" cfg;
        supervisorChecksRealApiPort = lib.hasInfix "default-server check check-ssl port 6443" cfg;
        sni = lib.hasInfix "sni str(kubeapi-test.example.org)" cfg;
      };
    expected = {
      bindsKubeapiLb = true;
      bindsSupervisorLb = true;
      bindsStats = true;
      backupFlag = true;
      noBackupOnSelf = true;
      supervisorTargets9345 = true;
      checkSslDataStaysRaw = true;
      supervisorChecksRealApiPort = true;
      sni = true;
    };
  };

  test_pkiSyncFragment = {
    expr =
      let
        frag = kube.nixos.mkPkiSync {
          pkgs = {
            coreutils = "/nix/store/fake-coreutils";
            writeShellScript = name: text: "script:${name}:${text}";
          };
          pkiGenerator.files = {
            "server-ca.crt".path = "/run/secrets/shared/rancher-pki-test/server-ca.crt";
            "server-ca.key".path = "/run/secrets/shared/rancher-pki-test/server-ca.key";
            "client-ca.crt".path = "/run/secrets/shared/rancher-pki-test/client-ca.crt";
            "client-ca.key".path = "/run/secrets/shared/rancher-pki-test/client-ca.key";
            "request-header-ca.crt".path = "/run/secrets/shared/rancher-pki-test/request-header-ca.crt";
            "request-header-ca.key".path = "/run/secrets/shared/rancher-pki-test/request-header-ca.key";
            "etcd-peer-ca.crt".path = "/run/secrets/shared/rancher-pki-test/etcd-peer-ca.crt";
            "etcd-peer-ca.key".path = "/run/secrets/shared/rancher-pki-test/etcd-peer-ca.key";
            "etcd-server-ca.crt".path = "/run/secrets/shared/rancher-pki-test/etcd-server-ca.crt";
            "etcd-server-ca.key".path = "/run/secrets/shared/rancher-pki-test/etcd-server-ca.key";
            "service.key".path = "/run/secrets/shared/rancher-pki-test/service.key";
          };
          tlsDir = "/var/lib/rancher/rke2/server/tls";
          beforeUnit = "rke2-server.service";
          namePrefix = "rke2-test";
        };
        unit = frag.systemd.services."rke2-test-pki-sync-tls";
      in
      {
        pathUnit = frag.systemd.paths."rke2-test-pki-sync-tls".pathConfig.PathChanged;
        inherit (unit) before requiredBy;
        condition = unit.unitConfig.ConditionPathExists;
        syncsTlsDir = lib.hasInfix "TLS_DIR=\"/var/lib/rancher/rke2/server/tls\"" unit.serviceConfig.ExecStart;
        syncsEtcdCas = lib.hasInfix "$TLS_DIR/etcd/peer-ca.crt" unit.serviceConfig.ExecStart;
      };
    expected = {
      pathUnit = [ "/run/secrets/shared/rancher-pki-test/server-ca.key" ];
      before = [ "rke2-server.service" ];
      requiredBy = [ "rke2-server.service" ];
      condition = "/run/secrets/shared/rancher-pki-test/server-ca.key";
      syncsTlsDir = true;
      syncsEtcdCas = true;
    };
  };

  test_manifestLabels = {
    expr = kube.render.mkManifestLabels { inherit instanceName; };
    expected = {
      "app.kubernetes.io/managed-by" = "clan";
      "clan.lol/kube-cluster" = "core-component";
      "clan.lol/cluster" = "test";
      "clan.lol/component" = "bootstrap";
    };
  };

  # --- hashed cilium ids (§6.2) -------------------------------------------

  # The hash contract is pinned: changing the hash function is a
  # fleet-breaking change and must be deliberate.
  test_hashCiliumIdPinnedValues = {
    expr = {
      foo = kube.hashCiliumId "foo";
      k3s = kube.hashCiliumId "k3s";
      rke2 = kube.hashCiliumId "rke2";
      test = kube.hashCiliumId "test";
      alpha = kube.hashCiliumId "alpha";
      borg = kube.hashCiliumId "borg";
      prod = kube.hashCiliumId "prod";
      staging = kube.hashCiliumId "staging";
    };
    expected = {
      foo = 83;
      k3s = 7;
      rke2 = 39;
      test = 68;
      alpha = 106;
      borg = 94;
      prod = 10;
      staging = 96;
    };
  };

  test_resolveCiliumId = {
    expr = {
      explicit = kube.resolveCiliumId {
        instanceName = "test";
        settings = evalSettings { cilium.id = 42; };
      };
      hashed = kube.resolveCiliumId {
        instanceName = "test";
        settings = evalSettings { cilium.id = lib.mkForce null; };
      };
    };
    expected = {
      explicit = 42;
      hashed = 68;
    };
  };

  # null id is the interface default (hashed resolution happens at use).
  test_ciliumIdDefaultNull = {
    expr = (evalSettings { cilium.id = null; }).cilium.id;
    expected = null;
  };

  test_resolveCidrsDerived = {
    expr = kube.render.resolveCidrs {
      settings = baseSettings;
      ciliumId = 1;
    };
    expected = {
      clusterCidr = "10.1.0.0/16,fd10:1::/56";
      serviceCidr = "10.2.0.0/16,fd10:2::/112";
      clusterDNS = "10.2.0.10";
      podCIDRv4 = "10.1.0.0/16";
      podCIDRv6 = "fd10:1::/56";
      serviceCIDRv4 = "10.2.0.0/16";
      serviceCIDRv6 = "fd10:2::/112";
    };
  };

  # clusterDNS follows an explicit service v4 CIDR (10th address) — the
  # >127 path, where the id-derived DNS address would overflow the /8.
  test_resolveCidrsExplicitServiceDns = {
    expr =
      (kube.render.resolveCidrs {
        settings = evalSettings {
          network.podCIDRv4 = "172.16.0.0/16";
          network.serviceCIDRv4 = "172.17.0.0/16";
        };
        ciliumId = 200;
      }).clusterDNS;
    expected = "172.17.0.10";
  };

  # Explicit ids above 127 require explicit v4 CIDRs (§6.2).
  test_idAbove127RequiresCidrs = {
    expr = failedAssertion (kube.assertions.mkClusterAssertions {
      inherit instanceName;
      settings = evalSettings { cilium.id = 200; };
      roleMembers = oneServer;
    }) "above 127";
    expected = true;
  };

  test_idAbove127WithCidrsAccepted = {
    expr = failedAssertion (kube.assertions.mkClusterAssertions {
      inherit instanceName;
      settings = evalSettings {
        cilium.id = 200;
        network.podCIDRv4 = "10.200.0.0/16";
        network.serviceCIDRv4 = "10.201.0.0/16";
      };
      roleMembers = oneServer;
    }) "above 127";
    expected = false;
  };

  test_nativeRoutingCidrContainment = {
    expr =
      map
        (
          settings:
          failedAssertion (kube.assertions.mkClusterAssertions {
            inherit instanceName settings;
            roleMembers = oneServer;
          }) "NativeRoutingCIDR"
        )
        [
          (evalSettings { network.podCIDRv4 = "172.16.0.0/16"; })
          (evalSettings { network.podCIDRv6 = "fd20::/56"; })
          (evalSettings {
            network.podCIDRv4 = "10.200.0.0/16";
            network.podCIDRv6 = "fd10:200::/56";
          })
        ];
    expected = [
      true
      true
      false
    ];
  };

  test_manualClusterBgpRequiresFabric = {
    expr =
      map
        (
          settings:
          failedAssertion (kube.assertions.mkClusterAssertions {
            inherit instanceName settings;
            roleMembers = oneServer;
          }) "requires network.fabric"
        )
        [
          baseSettings
          (evalSettings {
            fabric.enable = false;
            bgp.enable = false;
          })
        ];
    expected = [
      true
      false
    ];
  };

  # All members must resolve the same id — per-member pin drift rejected.
  test_memberIdDriftRejected = {
    expr = failedAssertion (kube.assertions.mkClusterAssertions {
      inherit instanceName;
      settings = baseSettings;
      roleMembers = [
        {
          machineName = "alpha";
          role = "server";
          settings = {
            clusterInit = true;
            cilium.id = 70;
            network = {
              ipv4 = "10.0.0.1";
              ipv6 = "fd00::1";
            };
          };
        }
      ];
    }) "same cilium.id";
    expected = true;
  };

  # --- topology labels (invariant 7) --------------------------------------

  test_topologyEmptyRejected = {
    expr = failedAssertion (kube.assertions.mkClusterAssertions {
      inherit instanceName;
      settings = baseSettings;
      roleMembers = [
        {
          machineName = "alpha";
          role = "server";
          settings = {
            clusterInit = true;
            network = {
              ipv4 = "10.0.0.1";
              ipv6 = "fd00::1";
            };
            topology.region = "";
          };
        }
      ];
    }) "topology.region/zone must be non-empty";
    expected = true;
  };

  test_topologyNullAndOverrideAccepted = {
    expr = failedAssertion (kube.assertions.mkClusterAssertions {
      inherit instanceName;
      settings = baseSettings;
      roleMembers = [
        {
          machineName = "alpha";
          role = "server";
          settings = {
            clusterInit = true;
            network = {
              ipv4 = "10.0.0.1";
              ipv6 = "fd00::1";
            };
            topology.region = "hel1";
          };
        }
      ];
    }) "topology.region/zone must be non-empty";
    expected = false;
  };

  # --- all-or-none fabric posture (§6.3) ----------------------------------

  test_postureMixedRejected = {
    expr = failedAssertion (kube.assertions.mkClusterAssertions {
      inherit instanceName;
      settings = baseSettings;
      roleMembers = [
        {
          machineName = "alpha";
          role = "server";
          settings = {
            clusterInit = true;
            network = {
              fabric = {
                service = "routed-fabric";
                instance = "fleet";
              };
              ipv4 = "10.0.0.1";
              ipv6 = "fd00::1";
            };
          };
        }
        {
          machineName = "beta";
          role = "agent";
          settings = {
            clusterInit = false;
            network = {
              fabric = null;
              ipv4 = "10.0.0.2";
              ipv6 = "fd00::2";
            };
          };
        }
      ];
    }) "all-or-none fabric posture";
    expected = true;
  };

  test_postureMissingFactsRejected = {
    expr = failedAssertion (kube.assertions.mkClusterAssertions {
      inherit instanceName;
      settings = baseSettings;
      transportFacts = {
        alpha = {
          ipv4 = "10.42.0.1";
          ipv6 = "fd10:42::1";
        };
      };
      roleMembers = [
        {
          machineName = "alpha";
          role = "server";
          settings = {
            clusterInit = true;
            network.fabric = {
              service = "routed-fabric";
              instance = "fleet";
            };
          };
        }
        {
          machineName = "beta";
          role = "agent";
          settings = {
            clusterInit = false;
            network.fabric = {
              service = "routed-fabric";
              instance = "fleet";
            };
          };
        }
      ];
    }) "no export from the configured fabric source";
    expected = true;
  };

  test_postureUniformAccepted = {
    expr = failedAssertion (kube.assertions.mkClusterAssertions {
      inherit instanceName;
      settings = baseSettings;
      transportFacts = {
        alpha = {
          ipv4 = "10.42.0.1";
          ipv6 = "fd10:42::1";
        };
        beta = {
          ipv4 = "10.42.0.2";
          ipv6 = "fd10:42::2";
        };
      };
      roleMembers = [
        {
          machineName = "alpha";
          role = "server";
          settings = {
            clusterInit = true;
            network.fabric = {
              service = "routed-fabric";
              instance = "fleet";
            };
          };
        }
        {
          machineName = "beta";
          role = "agent";
          settings = {
            clusterInit = false;
            network.fabric = {
              service = "routed-fabric";
              instance = "fleet";
            };
          };
        }
      ];
    }) "fabric posture";
    expected = false;
  };

  # --- cross-role parity (per-machine cluster-level settings) ---------------

  test_parityUniformAccepted = {
    expr = failedAssertion (kube.assertions.mkClusterAssertions {
      inherit instanceName;
      settings = baseSettings;
      transportFacts = null;
      roleMembers = parityMembers;
      roleSettings = [
        {
          name = "server/alpha";
          settings = baseSettings;
        }
        {
          name = "agent/beta";
          settings = baseSettings;
        }
      ];
    }) "identical across all machines";
    expected = false;
  };

  # Per-machine overrides are covered: a drifted machine is named
  # "<role>/<machine>" in the message.
  test_parityMachineDriftRejected = {
    expr =
      let
        assertions = kube.assertions.mkClusterAssertions {
          inherit instanceName;
          settings = baseSettings;
          transportFacts = null;
          roleMembers = parityMembers;
          roleSettings = [
            {
              name = "server/alpha";
              settings = baseSettings;
            }
            {
              name = "agent/beta";
              settings = evalSettings { cilium.id = 2; };
            }
          ];
        };
        driftAssertion = lib.findFirst (
          item: !item.assertion && lib.hasInfix "identical across all machines" item.message
        ) null assertions;
      in
      {
        fires = driftAssertion != null;
        namesMember = driftAssertion != null && lib.hasInfix "agent/beta" driftAssertion.message;
      };
    expected = {
      fires = true;
      namesMember = true;
    };
  };

  test_parityFabricSettingsDriftRejected = {
    expr = failedAssertion (kube.assertions.mkClusterAssertions {
      inherit instanceName;
      settings = baseSettings;
      transportFacts = null;
      roleMembers = parityMembers;
      roleSettings = [
        {
          name = "server/alpha";
          settings = baseSettings;
        }
        {
          name = "agent/beta";
          settings = evalSettings { fabric.enable = false; };
        }
      ];
    }) "identical across all machines";
    expected = true;
  };

  # --- fleet checks (§6.2, D16/D33) ----------------------------------------

  test_fleetChecksCleanTreePasses = {
    expr = lib.mapAttrs (_: c: c.assertion) fleetChecksPass;
    expected = {
      kube-cluster-meshed-cidr-overlap = true;
      kube-cluster-mesh-group-fabric = true;
      kube-cluster-mesh-group-uniformity = true;
      kube-cluster-mesh-nodeport-collisions = true;
      kube-cluster-mesh-peers = true;
      kube-cluster-mesh-vip-collisions = true;
      kube-cluster-node-in-two-clusters = true;
      kube-cluster-shared-bgp-border-prefixes = true;
      kube-cluster-unique-bgp-asns = true;
      kube-cluster-unique-cilium-ids = true;
      kube-cluster-unique-names = true;
    };
  };

  test_fleetCheckNodeInTwoClusters = {
    expr =
      let
        check = (kube.mkFleetChecks clanLib fleetExportsOverlap).kube-cluster-node-in-two-clusters;
      in
      {
        inherit (check) assertion;
        namesMachine = lib.hasInfix "alpha" check.message;
        namesBoth = lib.hasInfix "rke2/prod" check.message && lib.hasInfix "k3s/prod2" check.message;
      };
    expected = {
      assertion = false;
      namesMachine = true;
      namesBoth = true;
    };
  };

  test_fleetCheckIdCollision = {
    expr =
      let
        check = (kube.mkFleetChecks clanLib fleetExportsIdCollision).kube-cluster-unique-cilium-ids;
      in
      {
        inherit (check) assertion;
        namesInstances = lib.hasInfix "rke2/prod" check.message && lib.hasInfix "k3s/staging" check.message;
      };
    expected = {
      assertion = false;
      namesInstances = true;
    };
  };

  test_fleetCheckNameCollision = {
    expr =
      let
        check = (kube.mkFleetChecks clanLib fleetExportsNameCollision).kube-cluster-unique-names;
      in
      {
        inherit (check) assertion;
        namesInstances = lib.hasInfix "rke2/prod" check.message && lib.hasInfix "k3s/prod" check.message;
      };
    expected = {
      assertion = false;
      namesInstances = true;
    };
  };

  test_fleetCheckMeshedCidrOverlap = {
    expr =
      let
        check = (kube.mkFleetChecks clanLib fleetExportsCidrOverlap).kube-cluster-meshed-cidr-overlap;
      in
      {
        inherit (check) assertion;
        namesInstances = lib.hasInfix "rke2/prod" check.message && lib.hasInfix "k3s/staging" check.message;
      };
    expected = {
      assertion = false;
      namesInstances = true;
    };
  };

  # The same CIDR overlap in SEPARATE mesh groups is allowed (the trust
  # domains never route into each other).
  test_fleetCheckSeparateGroupsAllowOverlap = {
    expr =
      (kube.mkFleetChecks clanLib fleetExportsCidrSeparateGroups)
      .kube-cluster-meshed-cidr-overlap.assertion;
    expected = true;
  };

  test_fleetCheckMeshGroupFabricConsistency = {
    expr =
      let
        check = (kube.mkFleetChecks clanLib fleetExportsTransportMixed).kube-cluster-mesh-group-fabric;
      in
      {
        inherit (check) assertion;
        namesInstances = lib.hasInfix "fleet-b" check.message;
      };
    expected = {
      assertion = false;
      namesInstances = true;
    };
  };

  # The bootstrap-apply oneshot (D40): etc path + SSA apply + retry.
  test_bootstrapApplyFragment = {
    expr =
      let
        frag = kube.mkBootstrapApply {
          pkgs = {
            kubectl = "/nix/store/fake-kubectl";
            coreutils = "/nix/store/fake-coreutils";
            writeShellScript = name: text: "script:${name}:${text}";
          };
          inherit instanceName;
          namePrefix = "k3s";
          serverUnit = "k3s.service";
          kubeconfigPath = "/etc/rancher/k3s/k3s.yaml";
          bundle = "/nix/store/fake-bundle.yaml";
        };
        unit = frag.systemd.services."k3s-test-bootstrap-apply";
      in
      {
        etcPath = frag.environment.etc ? "clan-bootstrap/test/bundle.yaml";
        inherit (unit) after requires;
        inherit (unit.serviceConfig) Type RemainAfterExit Restart;
        noStartLimit = unit.unitConfig.StartLimitIntervalSec == 0;
        ssaApply = lib.hasInfix "kubectl apply --server-side --field-manager=clan-bootstrap" unit.serviceConfig.ExecStart;
        waitsReadyz = lib.hasInfix "get --raw=/readyz" unit.serviceConfig.ExecStart;
      };
    expected = {
      etcPath = true;
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      noStartLimit = true;
      ssaApply = true;
      waitsReadyz = true;
    };
  };

  # --- BGP / fabric / private CoreDNS -------------------------------------

  # The ASN derivation contract is pinned: changing the hash is a
  # fleet-breaking change and must be deliberate (same discipline as
  # test_hashCiliumIdPinnedValues).
  test_hashBgpAsnsPinnedValues = {
    expr = {
      foo = kube.bgp.hashBgpAsns "foo";
      k3s = kube.bgp.hashBgpAsns "k3s";
      rke2 = kube.bgp.hashBgpAsns "rke2";
      test = kube.bgp.hashBgpAsns "test";
      prod = kube.bgp.hashBgpAsns "prod";
    };
    expected = {
      foo = {
        cilium = 4260531340;
        host = 4240043293;
      };
      k3s = {
        cilium = 4240343820;
        host = 4202640987;
      };
      rke2 = {
        cilium = 4200812391;
        host = 4253360446;
      };
      test = {
        cilium = 4250252234;
        host = 4238856295;
      };
      prod = {
        cilium = 4227504799;
        host = 4203270962;
      };
    };
  };

  # Deterministic, inside the RFC 6996 private 32-bit range, cilium != host.
  test_hashBgpAsnsRangeDeterminism = {
    expr =
      let
        names = [
          "a"
          "b"
          "cluster-1"
          "prod-eu"
          "x"
          "k3s"
          "rke2"
          "staging"
        ];
        asns = map kube.bgp.hashBgpAsns names;
        inRange = a: a >= 4200000000 && a <= 4294967294;
      in
      {
        deterministic = kube.bgp.hashBgpAsns "k3s" == kube.bgp.hashBgpAsns "k3s";
        allInRange = lib.all (a: inRange a.cilium && inRange a.host) asns;
        distinct = lib.all (a: a.cilium != a.host) asns;
      };
    expected = {
      deterministic = true;
      allInRange = true;
      distinct = true;
    };
  };

  # Explicit pins win over the hashed defaults (collision escape hatch).
  test_resolveBgpAsnsOverride = {
    expr = kube.bgp.resolveBgpAsns {
      instanceName = "test";
      settings = evalSettings {
        bgp.ciliumASN = 4290000001;
      };
    };
    expected = {
      cilium = 4290000001;
      host = 4238856295;
    };
  };

  # D10: the fabric pool derives from the resolved cilium id, stays inside
  # 172.16/12 + fd11::/16, and is a cluster-global shared-bgp pool.
  test_fabricPoolDerived = {
    expr = kube.bgp.mkFabricPool {
      instanceName = "test";
      ciliumId = 1;
      settings = baseSettings;
    };
    expected = {
      name = "test-fabric";
      blocks = [
        "172.16.1.0/24"
        "fd11:1::/64"
      ];
      serviceSelector."clan.lol/pool" = "test-fabric";
      delivery = "shared-bgp";
      owner = null;
      candidates = [ ];
    };
  };

  test_fabricPoolOverrideAndDisabled = {
    expr = {
      custom =
        (kube.bgp.mkFabricPool {
          instanceName = "test";
          ciliumId = 1;
          settings = evalSettings {
            fabric.ipv4Block = "100.64.7.0/24";
            fabric.ipv6Block = "fd12:7::/64";
          };
        }).blocks;
      disabled = kube.bgp.mkFabricPool {
        instanceName = "test";
        ciliumId = 1;
        settings = evalSettings {
          fabric.enable = false;
        };
      };
    };
    expected = {
      custom = [
        "100.64.7.0/24"
        "fd12:7::/64"
      ];
      disabled = null;
    };
  };

  # The internal ClusterMesh IPv4 VIP is pinned at host offset 79 of the
  # fabric pool's IPv4 block (D10 round 17/D60 amended 2026-10-26).
  test_meshVips = {
    expr = kube.mesh.meshVips {
      ciliumId = 1;
      settings = baseSettings;
    };
    expected.ipv4 = "172.16.1.79";
  };

  # Each node has one local session and selects common pod/shared routes;
  # node-bgp advertisements are rendered only for their owner (D8/D49).
  test_bundleBgpResources = {
    expr =
      let
        cc1 = findObj "CiliumBGPClusterConfig" "test-node-1";
        cc2 = findObj "CiliumBGPClusterConfig" "test-node-2";
        pc = findObj "CiliumBGPPeerConfig" "test-node-1-frr";
        adv = findObj "CiliumBGPAdvertisement" "test-node-1-service-vips";
        podAdv = findObj "CiliumBGPAdvertisement" "test-node-1-pod-pools";
        instance = builtins.head cc1.spec.bgpInstances;
        peer = builtins.head instance.peers;
      in
      {
        cc1Selector = cc1.spec.nodeSelector.matchLabels;
        cc2Present = cc2 != null;
        inherit (instance) localASN;
        inherit (peer) peerASN peerAddress;
        noLocalPort = !(instance ? localPort);
        timers = pc.spec.timers;
        families = map (f: f.afi) pc.spec.families;
        advertLabels = pc.spec.families;
        advType = (builtins.head adv.spec.advertisements).advertisementType;
        advAddresses = (builtins.head adv.spec.advertisements).service.addresses;
        advSelector = (builtins.head adv.spec.advertisements).selector.matchExpressions;
        advMatchedByPeer =
          (builtins.head pc.spec.families).advertisements.matchLabels
          == lib.intersectAttrs adv.metadata.labels (builtins.head pc.spec.families)
          .advertisements.matchLabels;
        advLabelValue = adv.metadata.labels."clan.lol/bgp-advertisement-node";
        podAdvType = (builtins.head podAdv.spec.advertisements).advertisementType;
        podAdvSelector = (builtins.head podAdv.spec.advertisements).selector.matchLabels;
        advertisementNames = builtins.sort builtins.lessThan (
          map (o: o.metadata.name) (builtins.filter (o: o.kind == "CiliumBGPAdvertisement") bundleObjects)
        );
        cmBgp = ciliumConfig."enable-bgp-control-plane";
      };
    expected = {
      cc1Selector."kubernetes.io/hostname" = "node-1";
      cc2Present = true;
      localASN = 4250252234;
      peerASN = 4238856295;
      peerAddress = "::1";
      noLocalPort = true;
      timers = {
        holdTimeSeconds = 9;
        keepAliveTimeSeconds = 3;
        connectRetryTimeSeconds = 5;
      };
      families = [
        "ipv4"
        "ipv6"
      ];
      advertLabels = [
        {
          afi = "ipv4";
          safi = "unicast";
          advertisements.matchLabels."clan.lol/bgp-advertisement-node" = "node-1";
        }
        {
          afi = "ipv6";
          safi = "unicast";
          advertisements.matchLabels."clan.lol/bgp-advertisement-node" = "node-1";
        }
      ];
      advType = "Service";
      advAddresses = [ "LoadBalancerIP" ];
      advSelector = [
        {
          key = "clan.lol/pool";
          operator = "In";
          values = [ "test-fabric" ];
        }
      ];
      advMatchedByPeer = true;
      advLabelValue = "node-1";
      podAdvType = "CiliumPodIPPool";
      podAdvSelector."clan.lol/cluster" = "test";
      advertisementNames = [
        "test-node-1-pod-pools"
        "test-node-1-service-vips"
        "test-node-2-pod-pools"
        "test-node-2-service-vips"
      ];
      cmBgp = "true";
    };
  };

  test_bundleBgpNodeBgpPoolSelector = {
    expr =
      let
        objects =
          builtins.fromJSON
            (mkTestBundle (evalSettings {
              pools."pub-v4" = {
                blocks = [ "198.51.100.0/28" ];
                serviceSelector."clan.lol/pool" = "pub-v4";
                delivery = "node-bgp";
                owner = "node-1";
              };
            })).json;
        find = kind: name: lib.findFirst (o: o.kind == kind && o.metadata.name == name) null objects;
        ownerAdv = find "CiliumBGPAdvertisement" "test-node-1-node-vips";
        otherOwnerAdv = find "CiliumBGPAdvertisement" "test-node-2-node-vips";
        sharedAdv = find "CiliumBGPAdvertisement" "test-node-1-service-vips";
      in
      {
        ownerPools = (builtins.head ownerAdv.spec.advertisements).selector.matchExpressions;
        ownerOnly = otherOwnerAdv == null;
        sharedPools = (builtins.head sharedAdv.spec.advertisements).selector.matchExpressions;
      };
    expected = {
      ownerPools = [
        {
          key = "clan.lol/pool";
          operator = "In";
          values = [ "pub-v4" ];
        }
      ];
      ownerOnly = true;
      sharedPools = [
        {
          key = "clan.lol/pool";
          operator = "In";
          values = [ "test-fabric" ];
        }
      ];
    };
  };

  # The fabric pool renders as a CiliumLoadBalancerIPPool by default (D10).
  test_bundleFabricPool = {
    expr =
      let
        p = findObj "CiliumLoadBalancerIPPool" "test-fabric";
      in
      {
        inherit (p.spec) blocks;
        selector = p.spec.serviceSelector.matchLabels;
      };
    expected = {
      blocks = [
        { cidr = "172.16.1.0/24"; }
        { cidr = "fd11:1::/64"; }
      ];
      selector."clan.lol/pool" = "test-fabric";
    };
  };

  # §6.12: no BGP pools (fabric off, none declared) + bgp.enable = false ⇒
  # no BGP resources. D41 keeps the explicit-pool LB-IPAM class registered.
  # The ClusterMesh apiserver still renders (node-port exposure — the
  # fabric pool is off, D60).
  test_bundleNoBgpWithoutSharedBgp = {
    expr =
      let
        bgpKinds = builtins.filter (o: lib.hasPrefix "CiliumBGP" o.kind) bundleNoBgpObjects;
        cm = (findObjKind bundleNoBgpObjects "ConfigMap" "cilium-config").data;
        fabricPool = findObjKind bundleNoBgpObjects "CiliumLoadBalancerIPPool" "test-fabric";
        apiserver = findObjKind bundleNoBgpObjects "Deployment" "clustermesh-apiserver";
        apiserverSvc = findObjKind bundleNoBgpObjects "Service" "clustermesh-apiserver";
      in
      {
        bgpResourceCount = builtins.length bgpKinds;
        flag = cm."enable-bgp-control-plane";
        fabricPoolAbsent = fabricPool == null;
        apiserverNodePort = apiserver != null && apiserverSvc.spec.type == "NodePort";
      };
    expected = {
      bgpResourceCount = 0;
      flag = "true";
      fabricPoolAbsent = true;
      apiserverNodePort = true;
    };
  };

  # D13 opt-in renders the ClusterIP advertisement on top of the always-on
  # pod-pool + Service-VIP advertisements.
  test_bundleBgpD13OptIn = {
    expr = builtins.sort builtins.lessThan (
      map (o: o.metadata.name) (builtins.filter (o: o.kind == "CiliumBGPAdvertisement") bundleD13Objects)
    );
    expected = [
      "test-node-1-cluster-ips"
      "test-node-1-pod-pools"
      "test-node-1-service-vips"
      "test-node-2-cluster-ips"
      "test-node-2-pod-pools"
      "test-node-2-service-vips"
    ];
  };

  # §6.12 coupling: bgp.enable must equal "shared-bgp pools exist".
  test_bgpCouplingAssertions = {
    expr = {
      # fabric off but bgp still enabled → error
      fabricOffBgpOn = failedAssertion (kube.assertions.mkPoolAssertions {
        inherit instanceName members;
        ciliumId = 1;
        settings = evalSettings {
          fabric.enable = false;
        };
      }) "BGP only for node-bgp/shared-bgp pools";
      # declared shared-bgp pool with BGP disabled → error
      poolWithoutBgp = failedAssertion (kube.assertions.mkPoolAssertions {
        inherit instanceName members;
        ciliumId = 1;
        settings = evalSettings {
          fabric.enable = false;
          bgp.enable = false;
          pools.public = {
            blocks = [ "203.0.113.0/28" ];
            serviceSelector."clan.lol/pool" = "public";
            delivery = "shared-bgp";
          };
        };
      }) "such pools require BGP";
      # defaults (fabric on, bgp on) → no coupling failure
      defaultsOk = failedAssertion (kube.assertions.mkPoolAssertions {
        inherit instanceName members;
        ciliumId = 1;
        settings = baseSettings;
      }) "BGP";
    };
    expected = {
      fabricOffBgpOn = true;
      poolWithoutBgp = true;
      defaultsOk = false;
    };
  };

  # Fabric/pool blocks may not overlap the pod/service CIDRs
  # (reservedCidrs), and tiny fabric blocks are rejected (the offset-79
  # ClusterMesh VIPs need at least 128 v4 addresses, D10 round 17).
  test_fabricReservedOverlapAndSize = {
    expr = {
      overlap = failedAssertion (kube.assertions.mkPoolAssertions {
        inherit instanceName members;
        ciliumId = 1;
        reservedCidrs = [ "10.1.0.0/16" ];
        settings = evalSettings {
          fabric.ipv4Block = "10.1.64.0/24";
        };
      }) "pod/service CIDRs";
      tooSmall = failedAssertion (kube.assertions.mkPoolAssertions {
        inherit instanceName members;
        ciliumId = 1;
        settings = evalSettings {
          fabric.ipv4Block = "172.16.1.0/26";
        };
      }) "at least 128 addresses";
      fitsAt25 =
        !(failedAssertion (kube.assertions.mkPoolAssertions {
          inherit instanceName members;
          ciliumId = 1;
          settings = evalSettings {
            fabric.ipv4Block = "172.16.1.0/25";
          };
        }) "at least 128 addresses");
    };
    expected = {
      overlap = true;
      tooSmall = true;
      fitsAt25 = true;
    };
  };

  # --- ClusterMesh apiserver rendering (D60) -------------------------------

  test_bundleContainsNoPrivateKeyMaterial = {
    expr = !(lib.hasInfix "PRIVATE KEY-----" (builtins.toJSON bundleObjects));
    expected = true;
  };

  # The default bundle (fabric pool on, auto exposure) renders the
  # internal-load-balancer exposure: pinned offset-79 VIPs projected via
  # lbipam, the BGP class, ETP Local, and the D60 placement shape.
  test_clustermeshInternalLbExposure = {
    expr = {
      deploy = {
        replicas = apiserverDeploy.spec.replicas;
        strategy = apiserverDeploy.spec.strategy;
        requiredAntiAffinity =
          apiserverDeploy.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution
          != [ ];
        nodeSelector = apiserverDeploy.spec.template.spec.nodeSelector;
      };
      svc = {
        type = apiserverService.spec.type;
        inherit (apiserverService.spec) externalTrafficPolicy loadBalancerClass;
        annotations = apiserverService.metadata.annotations;
        poolLabel = apiserverService.metadata.labels."clan.lol/pool";
        ipPolicy = apiserverService.spec.ipFamilyPolicy;
        hasNodePort = apiserverService.spec.ports ? nodePort;
      };
      usersEmptySingleton = remoteUsers == "users:\n";
      clustermeshEnable = ciliumConfig."clustermesh-enable";
      maxConn = ciliumConfig."max-connected-clusters";
    };
    expected = {
      deploy = {
        replicas = 2; # min(3, eligible) — two fixture servers
        strategy = {
          type = "RollingUpdate";
          rollingUpdate = {
            maxSurge = 0;
            maxUnavailable = 1;
          };
        };
        requiredAntiAffinity = true;
        nodeSelector = {
          "kubernetes.io/os" = "linux";
          cluster = "test";
          role = "server";
        };
      };
      svc = {
        type = "LoadBalancer";
        externalTrafficPolicy = "Local";
        loadBalancerClass = "io.cilium/bgp-control-plane";
        annotations."lbipam.cilium.io/ips" = "172.16.1.79";
        poolLabel = "test-fabric";
        ipPolicy = "SingleStack";
        hasNodePort = false;
      };
      usersEmptySingleton = true;
      clustermeshEnable = "true";
      maxConn = "255";
    };
  };

  # Node-port exposure: NodePort service on the default port 32379, ETP
  # Local, replicas = selected node count, per-machine node affinity, no
  # loadBalancerClass (the apiserver rejects it on NodePort services).
  test_clustermeshNodePortExposure = {
    expr =
      let
        d = findObjKind bundleNodePortObjects "Deployment" "clustermesh-apiserver";
        s = findObjKind bundleNodePortObjects "Service" "clustermesh-apiserver";
        terms =
          d.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms;
      in
      {
        replicas = d.spec.replicas;
        machineAffinity = lib.flatten (
          map (t: map (e: e.key + ":" + builtins.concatStringsSep "," e.values) t.matchExpressions) terms
        );
        type = s.spec.type;
        etp = s.spec.externalTrafficPolicy;
        nodePort = lib.head (map (port: port.nodePort) s.spec.ports);
        hasClass = s.spec ? loadBalancerClass;
      };
    expected = {
      replicas = 2;
      machineAffinity = [ "machine:node-1,node-2" ];
      type = "NodePort";
      etp = "Local";
      nodePort = 32379;
      hasClass = false;
    };
  };

  # External exposure wins on every overlay: explicit non-clan class +
  # dnsName (DNS only), provider annotations, no internal capability or
  # pool draw needed, ETP Local.
  test_clustermeshExternalExposure = {
    expr =
      let
        d = findObjKind bundleExternalObjects "Deployment" "clustermesh-apiserver";
        s = findObjKind bundleExternalObjects "Service" "clustermesh-apiserver";
      in
      {
        type = s.spec.type;
        etp = s.spec.externalTrafficPolicy;
        class = s.spec.loadBalancerClass;
        dnsAnnotation = s.metadata.annotations."external-dns.alpha.kubernetes.io/hostname";
        noLbipam = !(s.metadata.annotations ? "lbipam.cilium.io/ips");
        replicas = d.spec.replicas;
      };
    expected = {
      type = "LoadBalancer";
      etp = "Local";
      class = "cloud.example/mesh-lb";
      dnsAnnotation = "mesh.test.example.org";
      noLbipam = true;
      replicas = 2;
    };
  };

  # The peer remote configs: one cilium-clustermesh + cilium-kvstoremesh
  # secret entry per peered cluster, endpoints = the peer's published set;
  # the etcd users file gets one remote-<cluster> user per peer.
  test_clustermeshPeerRendering = {
    expr =
      let
        peer = {
          name = "peer-b";
          mesh.exposure.published = [
            "https://172.16.2.79:2379"
          ];
        };
        meshWithPeer = mkTestMesh {
          settings = baseSettings;
          peers = {
            peer-b = peer;
          };
        };
        meshSelective = mkTestMesh {
          settings = evalSettings { mesh.peers = [ "peer-b" ]; };
          peers = {
            peer-b = peer;
            peer-c = peer // {
              name = "peer-c";
            };
          };
        };
      in
      {
        resolvedPeers = meshWithPeer.peerConfigs;
        selectivePeers = meshSelective.peerConfigs;
        singletonPeers = (mkTestMesh { settings = baseSettings; }).peerConfigs;
        users = kube.mesh.remoteUsersYaml meshWithPeer.peerConfigs;
        singletonUsers = kube.mesh.remoteUsersYaml [ ];
        missingPeerSkipped =
          (mkTestMesh {
            settings = baseSettings;
            peers = {
              peer-b = {
                name = "peer-b";
              };
            };
          }).peerConfigs;
        remoteConfig = kube.mesh.remoteClusterConfig {
          endpoints = [ "https://10.0.0.1:32379" ];
        };
      };
    expected = {
      resolvedPeers = [
        {
          name = "peer-b";
          endpoints = [
            "https://172.16.2.79:2379"
          ];
        }
      ];
      selectivePeers = [
        {
          name = "peer-b";
          endpoints = [
            "https://172.16.2.79:2379"
          ];
        }
      ];
      singletonPeers = [ ];
      users = "users:\n- name: remote-peer-b\n  role: remote\n";
      singletonUsers = "users:\n";
      missingPeerSkipped = [ ];
      remoteConfig = "endpoints:\n- https://10.0.0.1:32379\ntrusted-ca-file: /var/lib/cilium/clustermesh/common-etcd-client-ca.crt\nkey-file: /var/lib/cilium/clustermesh/common-etcd-client.key\ncert-file: /var/lib/cilium/clustermesh/common-etcd-client.crt";
    };
  };

  # --- ClusterMesh negatives (D60) -----------------------------------------

  test_clustermeshPlacementNegatives = {
    expr = {
      # replicas on node-port is FORBIDDEN (no replica knob).
      replicasOnNodePort = meshThrows {
        exposure = "node-port";
        replicas = 2;
      };
      # replicas beyond the eligible count.
      tooManyReplicas = meshThrows {
        replicas = 3; # only two fixture servers
      };
      # zero-match label placement.
      zeroMatchLabels = meshThrows {
        placement = "labels";
        placementLabels.disk = "nvme";
      };
      # empty selector with placement = labels.
      emptyLabels = meshThrows {
        placement = "labels";
      };
    };
    expected = {
      replicasOnNodePort = true;
      tooManyReplicas = true;
      zeroMatchLabels = true;
      emptyLabels = true;
    };
  };

  test_clustermeshExposureNegatives = {
    expr = {
      # explicit internal-load-balancer without the capability.
      internalNotCapable = meshThrowsWithTransport { exposure = "internal-load-balancer"; } {
        internalLoadBalancer = false;
        nodePort = true;
      };
      # external without a non-clan class.
      externalNoClass = meshThrows {
        exposure = "external-load-balancer";
      };
      # external with a clan class.
      externalClanClass = meshThrows {
        exposure = "external-load-balancer";
        mesh.external = {
          loadBalancerClass = "io.cilium/bgp-control-plane";
          dnsName = "mesh.test.example.org";
        };
      };
      # external without a dnsName.
      externalNoDns = meshThrows {
        exposure = "external-load-balancer";
        mesh.external.loadBalancerClass = "cloud.example/mesh-lb";
      };
      # external with a LITERAL IP dnsName (DNS only).
      externalIpDns = meshThrows {
        exposure = "external-load-balancer";
        mesh.external = {
          loadBalancerClass = "cloud.example/mesh-lb";
          dnsName = "203.0.113.10";
        };
      };
      # explicit internal LB without the fabric pool.
      internalNoPool = meshThrowsWithTransport { exposure = "internal-load-balancer"; } {
        internalLoadBalancer = true;
        nodePort = true;
      };
    };
    expected = {
      internalNotCapable = true;
      externalNoClass = true;
      externalClanClass = true;
      externalNoDns = true;
      externalIpDns = true;
      internalNoPool = true;
    };
  };

  # VIP containment: a /25 fabric block still holds offset 79; a block
  # where offset 79 falls outside the network rejects (explicit pins are
  # the escape hatch).
  test_clustermeshVipContainment = {
    expr = {
      ok =
        (mkTestMesh {
          settings = evalSettings {
            fabric.ipv4Block = "172.16.1.128/25";
          };
        }).vip4 == "172.16.1.207";
      outside =
        !(builtins.tryEval (
          builtins.deepSeq (mkTestMesh {
            settings = evalSettings {
              fabric.ipv4Block = "172.16.1.128/26";
            };
          }) true
        )).success;
    };
    expected = {
      ok = true;
      outside = true;
    };
  };

  # --- Generic node_transport consumption (D58) ----------------------------

  test_transportProfileDerivation = {
    expr = {
      nativeMtu = nativeProfile.mtu;
      nativeMode = nativeProfile.mode;
      nativeDevices = nativeProfile.interfaces;
      tunnelMtu = tunnelProfile.mtu;
      tunnelProto = tunnelProfile.tunnelProtocol;
      tunnelNative = tunnelProfile.routeExchange;
    };
    expected = {
      nativeMtu = 1404; # minimum interface MTU, no VXLAN subtraction
      nativeMode = "native";
      nativeDevices = [
        "wg-fleet-1"
        "wg-fleet-2"
      ];
      tunnelMtu = 1370; # 1420 - 50 (VXLAN)
      tunnelProto = "vxlan";
      tunnelNative = null;
    };
  };

  test_transportUnsupportedProfiles = {
    expr = {
      badVersion = transportThrows {
        schemaVersion = 1;
        ipv4 = "10.0.0.1";
        ipv6 = "fd00::1";
        instance = "fleet";
        endpoint = null;
        port = 51820;
        interfaces.wg0.mtu = 1400;
        directRoutingDevice = "wg0";
        datapath.mode = "native";
        datapath.tunnelProtocol = null;
        native.routeExchange = "local-router";
        internalLoadBalancer = true;
        nodePort = true;
      };
      badMode = transportThrows {
        schemaVersion = 2;
        ipv4 = "10.0.0.1";
        ipv6 = "fd00::1";
        instance = "fleet";
        endpoint = null;
        port = 51820;
        interfaces.wg0.mtu = 1400;
        directRoutingDevice = "wg0";
        datapath.mode = "ptp";
        datapath.tunnelProtocol = null;
        native.routeExchange = "local-router";
        internalLoadBalancer = true;
        nodePort = true;
      };
      nativeWithTunnel = transportThrows {
        schemaVersion = 2;
        ipv4 = "10.0.0.1";
        ipv6 = "fd00::1";
        instance = "fleet";
        endpoint = null;
        port = 51820;
        interfaces.wg0.mtu = 1400;
        directRoutingDevice = "wg0";
        datapath.mode = "native";
        datapath.tunnelProtocol = "vxlan";
        native.routeExchange = "local-router";
        internalLoadBalancer = true;
        nodePort = true;
      };
      tunnelWithRouteExchange = transportThrows {
        schemaVersion = 2;
        ipv4 = "10.0.0.1";
        ipv6 = "fd00::1";
        instance = "fleet";
        endpoint = null;
        port = 51820;
        interfaces.wg0.mtu = 1400;
        directRoutingDevice = "wg0";
        datapath.mode = "tunnel";
        datapath.tunnelProtocol = "vxlan";
        native.routeExchange = "local-router";
        internalLoadBalancer = false;
        nodePort = true;
      };
      badRouteExchange = transportThrows {
        schemaVersion = 2;
        ipv4 = "10.0.0.1";
        ipv6 = "fd00::1";
        instance = "fleet";
        endpoint = null;
        port = 51820;
        interfaces.wg0.mtu = 1400;
        directRoutingDevice = "wg0";
        datapath.mode = "native";
        datapath.tunnelProtocol = null;
        native.routeExchange = "local-bgp";
        internalLoadBalancer = true;
        nodePort = true;
      };
      badDirectDevice = transportThrows {
        schemaVersion = 2;
        ipv4 = "10.0.0.1";
        ipv6 = "fd00::1";
        instance = "fleet";
        endpoint = null;
        port = 51820;
        interfaces.wg0.mtu = 1400;
        directRoutingDevice = "wg-other";
        datapath.mode = "native";
        datapath.tunnelProtocol = null;
        native.routeExchange = "local-router";
        internalLoadBalancer = true;
        nodePort = true;
      };
      emptyInterfaces = transportThrows {
        schemaVersion = 2;
        ipv4 = "10.0.0.1";
        ipv6 = "fd00::1";
        instance = "fleet";
        endpoint = null;
        port = 51820;
        interfaces = { };
        directRoutingDevice = "wg0";
        datapath.mode = "native";
        datapath.tunnelProtocol = null;
        native.routeExchange = "local-router";
        internalLoadBalancer = true;
        nodePort = true;
      };
    };
    expected = {
      badVersion = true;
      badMode = true;
      nativeWithTunnel = true;
      tunnelWithRouteExchange = true;
      badRouteExchange = true;
      badDirectDevice = true;
      emptyInterfaces = true;
    };
  };

  # Admin cilium.helmValues cannot contradict the transport-derived profile
  test_ciliumHelmValuesContradictions = {
    expr = {
      routingMode = ciliumThrows {
        routingMode = "tunnel";
      };
      mtu = ciliumThrows {
        MTU = 1500;
      };
      directDevice = ciliumThrows {
        nodePort.directRoutingDevice = "eth0";
      };
      devices = ciliumThrows {
        devices = "eth0";
      };
      disableMesh = ciliumThrows {
        clusterMesh.enable = false;
      };
      maxConnDrift = ciliumThrows {
        clusterMesh.maxConnectedClusters = 511;
      };
      # Compatible overrides stay fine (devices superset).
      devicesSupersetOk =
        (builtins.tryEval (
          builtins.deepSeq (kube.render.mkCiliumValues {
            settings = evalSettings {
              cilium.helmValues.devices = "wg-fleet-1 eth1";
            };
            transportFacts = {
              interfaces = [ "wg-fleet-1" ];
              directRoutingDevice = "wg-fleet-1";
              mtu = 1404;
              mode = "native";
              tunnelProtocol = null;
            };
            inherit instanceName;
            k8sServiceHost = "kubeapi-test.example.org";
          }) true
        )).success;
    };
    expected = {
      routingMode = true;
      mtu = true;
      directDevice = true;
      devices = true;
      disableMesh = true;
      maxConnDrift = true;
      devicesSupersetOk = true;
    };
  };

  # The VXLAN profile renders the tunnel cilium-config keys.
  test_tunnelProfileBundle = {
    expr =
      let
        cm = (findObjKind tunnelBundle "ConfigMap" "cilium-config").data;
      in
      {
        routing = cm."routing-mode";
        proto = cm."tunnel-protocol";
        nativeCidrV4 = cm."ipv4-native-routing-cidr";
        mtu = cm."mtu";
        autoDirect = cm."auto-direct-node-routes";
      };
    expected = {
      routing = "tunnel";
      proto = "vxlan";
      nativeCidrV4 = "";
      mtu = "1370";
      autoDirect = "false";
    };
  };

  # --- ClusterMesh fleet checks (D54/D60) ----------------------------------

  test_clustermeshFleetChecks = {
    expr = {
      # Mixed datapath mode inside one group.
      mixedMode =
        let
          checks = kube.mkFleetChecks clanLib fleetExportsMixedMode;
        in
        !checks."kube-cluster-mesh-group-uniformity".assertion;
      # Mixed maxConnectedClusters inside one group.
      mixedMcc =
        let
          checks = kube.mkFleetChecks clanLib fleetExportsSameGroupMccBase;
        in
        !checks."kube-cluster-mesh-group-uniformity".assertion;
      # Symmetric selective peers pass.
      selectiveOk =
        let
          checks = kube.mkFleetChecks clanLib fleetExportsSelectiveOk;
        in
        checks."kube-cluster-mesh-peers".assertion;
      # One-directional selective peering is rejected.
      asymmetric =
        let
          checks = kube.mkFleetChecks clanLib fleetExportsSelectiveAsymmetric;
        in
        !checks."kube-cluster-mesh-peers".assertion;
      unknownPeers =
        let
          checks = kube.mkFleetChecks clanLib fleetExportsSelectiveAsymmetric;
        in
        lib.any (p: lib.hasInfix "unknown peer 'other'" p) [
          checks."kube-cluster-mesh-peers".message
        ];
      basePass =
        let
          checks = kube.mkFleetChecks clanLib fleetExportsSeparateGroupsPass;
        in
        checks."kube-cluster-mesh-group-uniformity".assertion
        && checks."kube-cluster-mesh-peers".assertion
        && checks."kube-cluster-mesh-nodeport-collisions".assertion
        && checks."kube-cluster-mesh-vip-collisions".assertion;
    };
    expected = {
      mixedMode = true;
      mixedMcc = true;
      selectiveOk = true;
      asymmetric = true;
      unknownPeers = true;
      basePass = true;
    };
  };

  test_clustermeshCollisionFleetChecks = {
    expr = {
      nodePort =
        !(kube.mkFleetChecks clanLib fleetExportsNodePortCollision)
        ."kube-cluster-mesh-nodeport-collisions".assertion;
      vip =
        !(kube.mkFleetChecks clanLib fleetExportsVipCollision)."kube-cluster-mesh-vip-collisions".assertion;
      distinctOk =
        let
          checks = kube.mkFleetChecks clanLib fleetExportsOverlap;
        in
        checks."kube-cluster-mesh-nodeport-collisions".assertion
        && checks."kube-cluster-mesh-vip-collisions".assertion;
    };
    expected = {
      nodePort = true;
      vip = true;
      distinctOk = true;
    };
  };

  # --- Mesh vars generators (D60) ------------------------------------------

  test_meshVarsGenerators = {
    expr = {
      caFiles = builtins.attrNames meshCaGen."rancher-clustermesh-ca-clan".files;
      certFiles = builtins.attrNames meshCertGen."rancher-clustermesh-test".files;
      caShare = meshCaGen."rancher-clustermesh-ca-clan".share;
      certShare = meshCertGen."rancher-clustermesh-test".share;
      certDeps = meshCertGen."rancher-clustermesh-test".dependencies;
      certValidation = meshCertGen."rancher-clustermesh-test".validation.endpoints;
      caSecretDeploy =
        meshCaGen."rancher-clustermesh-ca-clan".files."ca.key".secret
        && !meshCaGen."rancher-clustermesh-ca-clan".files."ca.key".deploy;
      certFilesDeploy = lib.all (file: file.deploy or true) (
        builtins.attrValues meshCertGen."rancher-clustermesh-test".files
      );
      # The remote cert CN is the etcd user remote clusters dial with.
      remoteCn = lib.hasInfix "CN=remote-test" meshCertGen."rancher-clustermesh-test".script;
      sanInServer =
        lib.hasInfix
          "subjectAltName=IP:172.16.1.79,IP:10.0.0.1,DNS:test.mesh.example.org,DNS:mesh.example.org"
          meshCertGen."rancher-clustermesh-test".script;
    };
    expected = {
      caFiles = [
        "ca.crt"
        "ca.key"
      ];
      certFiles = [
        "admin.crt"
        "admin.key"
        "ca.crt"
        "local.crt"
        "local.key"
        "remote.crt"
        "remote.key"
        "server.crt"
        "server.key"
      ];
      caShare = true;
      certShare = true;
      certDeps = [ "rancher-clustermesh-ca-clan" ];
      certValidation = builtins.toJSON {
        dns = [
          "test.mesh.example.org"
          "mesh.example.org"
        ];
        ip = [
          "172.16.1.79"
          "10.0.0.1"
        ];
      };
      caSecretDeploy = true;
      certFilesDeploy = true;
      remoteCn = true;
      sanInServer = true;
    };
  };

  # D8: node-bgp pools require an owner that is a cluster member.
  test_nodeBgpOwnerAssertion = {
    expr = {
      missing = failedAssertion (kube.assertions.mkPoolAssertions {
        inherit instanceName members;
        ciliumId = 1;
        settings = evalSettings {
          pools."pub-v4" = {
            blocks = [ "198.51.100.0/28" ];
            serviceSelector."clan.lol/pool" = "pub-v4";
            delivery = "node-bgp";
          };
        };
      }) "node-bgp pools need an owner";
      outsider = failedAssertion (kube.assertions.mkPoolAssertions {
        inherit instanceName members;
        ciliumId = 1;
        settings = evalSettings {
          pools."pub-v4" = {
            blocks = [ "198.51.100.0/28" ];
            serviceSelector."clan.lol/pool" = "pub-v4";
            delivery = "node-bgp";
            owner = "not-a-member";
          };
        };
      }) "node-bgp pools need an owner";
      memberOk = failedAssertion (kube.assertions.mkPoolAssertions {
        inherit instanceName members;
        ciliumId = 1;
        settings = evalSettings {
          pools."pub-v4" = {
            blocks = [ "198.51.100.0/28" ];
            serviceSelector."clan.lol/pool" = "pub-v4";
            delivery = "node-bgp";
            owner = "node-1";
          };
        };
      }) "node-bgp pools need an owner";
    };
    expected = {
      missing = true;
      outsider = true;
      memberOk = false;
    };
  };

  # Fleet check: ASN collisions across clusters are eval errors.
  test_fleetCheckAsnCollision = {
    expr =
      let
        check = (kube.mkFleetChecks clanLib fleetExportsAsnCollision).kube-cluster-unique-bgp-asns;
      in
      {
        inherit (check) assertion;
        namesBoth = lib.hasInfix "rke2/prod" check.message && lib.hasInfix "k3s/staging" check.message;
      };
    expected = {
      assertion = false;
      namesBoth = true;
    };
  };

  # D8: shared-bgp ⊆ border-owned prefixes — fires once routed-fabric
  # router export exists (campaign-B contract), vacuous before.
  test_fleetCheckRouterPrefixes = {
    expr = {
      covered =
        (kube.mkFleetChecks clanLib (mkRouterPrefixExports [
          "172.16.0.0/12"
          "fd11::/16"
        ])).kube-cluster-shared-bgp-border-prefixes.assertion;
      uncovered =
        (kube.mkFleetChecks clanLib (mkRouterPrefixExports [ "172.20.0.0/16" ]))
        .kube-cluster-shared-bgp-border-prefixes.assertion;
      vacuous =
        (kube.mkFleetChecks clanLib fleetExportsSeparateGroupsPass)
        .kube-cluster-shared-bgp-border-prefixes.assertion;
      namesCluster =
        lib.hasInfix "rke2/prod"
          (kube.mkFleetChecks clanLib (mkRouterPrefixExports [ "172.20.0.0/16" ]))
          .kube-cluster-shared-bgp-border-prefixes.message;
    };
    expected = {
      covered = true;
      uncovered = false;
      vacuous = true;
      namesCluster = true;
    };
  };

  # cidr.nix phase-5 helpers.
  test_cidrContainsAndV6 = {
    expr = {
      sub4 = cidr.contains "172.16.0.0/12" "172.16.1.5/32";
      super4 = cidr.contains "172.16.1.0/24" "172.16.0.0/12";
      crossFamily = cidr.contains "10.0.0.0/8" "fd11::/16";
      sub6 = cidr.contains "fd11::/16" "fd11:1::5/128";
      v6at = cidr.addressAtV6 "fd11:1::/64" 83;
      v6carry = cidr.addressAtV6 "fd11:1::/64" 65537;
    };
    expected = {
      sub4 = true;
      super4 = false;
      crossFamily = false;
      sub6 = true;
      v6at = "fd11:1:0:0:0:0:0:53";
      v6carry = "fd11:1:0:0:0:0:1:1";
    };
  };
}
