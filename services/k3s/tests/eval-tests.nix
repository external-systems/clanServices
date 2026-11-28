{
  lib,
  module,
  clanLib,
  exportInterfaces,
  self,
  ...
}: let
  k3sModule = module;
  kube = import ../../../lib/kube-cluster {inherit lib;};

  machineConfigs =
    lib.genAttrs
    [
      "alpha"
      "beta"
      "gamma"
      "delta"
    ]
    (_: {
      nixpkgs.hostPlatform = "x86_64-linux";
    });

  mkEvaled = inventory:
    clanLib.clan {
      self = {};
      directory = ./fixtures;
      # D71 reads the members' netif and nat_gateway exports
      exportInterfaces =
        exportInterfaces
        // {
          netif = ../../netif/netif-interface.nix;
          nat_gateway = ../../nat-gateway/nat-gateway-interface.nix;
          router = ../../router/router-interface.nix;
        };
      # Fleet-wide kube-cluster assertions (§6.2) as clan.checks — enforced
      # by clanLib.clan's checkConfig.
      imports = [kube.fleetChecksModule];
      modules = {
        fake-transport = fakeTransportModule;
        k3s = k3sModule;
        modes = ../../modes/default.nix;
        inherit (self.clan.modules) netif nat-gateway router;
      };
      machines = machineConfigs;
      inherit inventory;
    };

  # Inventory with explicit per-node addresses (no transport service).
  explicitInventory = {
    instances.k3s = {
      module.name = "k3s";
      module.input = "self";
      roles.server = {
        settings = {
          network.fabric = null;
          # Pinned id (§6.2): keeps CIDRs/clusterDNS/HAProxy ports stable.
          cilium.id = 1;
        };
        machines = {
          alpha.settings = {
            clusterInit = true;
            network = {
              ipv4 = "10.0.0.1";
              ipv6 = "fd00::1";
            };
          };
          beta.settings = {
            clusterInit = false;
            network = {
              ipv4 = "10.0.0.2";
              ipv6 = "fd00::2";
            };
          };
        };
      };
    };
  };

  explicitEvaled = mkEvaled explicitInventory;

  # Mode scoping (specs/netif.md N4, U2): a single-node cluster that
  # exists only in the machine's `kubernetes` mode.
  modesInstance = machines: {
    module.name = "modes";
    module.input = "self";
    roles.default.machines = machines;
  };
  modesSingle =
    (mkEvaled {
      instances = {
        modes = modesInstance {
          alpha.settings.modes = {
            default.manager = "networkmanager";
            kubernetes.manager = "ifstate";
          };
        };
        k3s = {
          module.name = "k3s";
          module.input = "self";
          roles.server = {
            settings = {
              network.fabric = null;
              cilium.id = 1;
            };
            machines.alpha.settings = {
              clusterInit = true;
              modes = ["kubernetes"];
              network = {
                ipv4 = "10.0.0.1";
                ipv6 = "fd00::1";
              };
            };
          };
        };
      };
    }).config.nixosConfigurations.alpha.config;
  modesVoter =
    (mkEvaled (
      lib.recursiveUpdate explicitInventory {
        instances = {
          modes = modesInstance {
            alpha.settings.modes = {
              default.manager = "ifstate";
              maintenance.manager = "ifstate";
            };
          };
          k3s.roles.server.machines.alpha.settings.modes = ["default"];
        };
      }
    )).config.nixosConfigurations.alpha.config;
  modeView = config: {
    mode = config.clanServices.networking.mode.name;
    k3s = config.services.k3s.enable;
    haproxy = config.services.haproxy.enable;
    bpffs = config.fileSystems ? "/sys/fs/bpf";
    seed = config.systemd.services ? "k3s-k3s-pki-seed";
    # what clan reads from the parent configuration stays in every mode
    generator = config.clan.core.vars.generators ? "rancher-pki-k3s";
    checks = failedAssertion config "k3s/k3s";
  };
  alphaExplicit = explicitEvaled.config.nixosConfigurations.alpha.config;

  # Inventory backed by a native node_transport instance (the fake
  # transport below; SPEC.md D72): two servers plus one agent.
  transportInventory = {
    instances = {
      mesh = {
        module.name = "fake-transport";
        module.input = "self";
        roles.node.machines = {
          alpha.settings = {
            ipv4 = "10.42.0.1";
            ipv6 = "fd10:42::1";
            asn = 4258224172;
          };
          beta.settings = {
            ipv4 = "10.42.0.2";
            ipv6 = "fd10:42::2";
            asn = 4258224173;
          };
          gamma.settings = {
            ipv4 = "10.42.0.3";
            ipv6 = "fd10:42::3";
            asn = 4258224174;
          };
        };
      };
      k3s = {
        module.name = "k3s";
        module.input = "self";
        roles.server = {
          settings = {
            network.fabric = {
              service = "fake-transport";
              instance = "mesh";
            };
            cilium.id = 1;
          };
          machines = {
            alpha.settings.clusterInit = true;
            beta.settings = {
              clusterInit = false;
              # Topology override (invariant 7): per-machine wins.
              topology.zone = "dc2";
            };
          };
        };
        roles.agent = {
          settings = {
            network.fabric = {
              service = "fake-transport";
              instance = "mesh";
            };
            cilium.id = 1;
          };
          machines.gamma = {};
        };
      };
    };
  };

  transportEvaled = mkEvaled transportInventory;
  alphaTransport = transportEvaled.config.nixosConfigurations.alpha.config;
  betaTransport = transportEvaled.config.nixosConfigurations.beta.config;
  gammaTransport = transportEvaled.config.nixosConfigurations.gamma.config;

  # distroDefaults opt-in: the service refrains from disabling the distro's
  # packaged components (D42); servicelb stays disabled in both modes.
  stockInventory = lib.recursiveUpdate explicitInventory {
    instances.k3s.roles.server.settings.distroDefaults.enable = true;
  };
  stockEvaled = mkEvaled stockInventory;
  alphaStock = stockEvaled.config.nixosConfigurations.alpha.config;

  failedAssertion = machineConfig: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) machineConfig.assertions;

  # The rendered bootstrap bundle on the clusterInit node (D40).
  bundleObjs = builtins.fromJSON alphaTransport.clan.kubeClusters.k3s.bundleJson;
  findObj = kind: name: lib.findFirst (o: o.kind == kind && o.metadata.name == name) null bundleObjs;
  ciliumConfigData = (findObj "ConfigMap" "cilium-config").data;
  agentEnv =
    (
      lib.findFirst (c: c.name == "cilium-agent") null
      (findObj "DaemonSet" "cilium").spec.template.spec.containers
    ).env;
  envValue = name: (lib.findFirst (e: e.name == name) {value = null;} agentEnv).value;

  # The rendered config.yaml (via the environment.etc source derivation is
  # not directly inspectable; the service mirrors it into the internal
  # clan.kubeClusters seam, and the nixpkgs module mirrors the join URL
  # into serverAddr and the token files into tokenFile).
  alphaRenderedConfig = alphaTransport.clan.kubeClusters.k3s.renderedDistroConfig;
  alphaStockRenderedConfig = alphaStock.clan.kubeClusters.k3s.renderedDistroConfig;

  alphaHaproxyConfig = alphaTransport.services.haproxy.config;
  gammaHaproxyConfig = gammaTransport.services.haproxy.config;

  # A cluster with two clusterInit servers should fail.
  dualInitInventory = lib.recursiveUpdate explicitInventory {
    instances.k3s.roles.server.machines.beta.settings.clusterInit = true;
  };
  dualInitEvaled = mkEvaled dualInitInventory;
  alphaDualInit = dualInitEvaled.config.nixosConfigurations.alpha.config;

  # The kube_cluster export of the transport-backed instance (per-member
  # scope; identical content on every member).
  kubeClusterExport =
    (clanLib.getExport {
        serviceName = "k3s";
        instanceName = "k3s";
        roleName = "server";
        machineName = "alpha";
      }
      transportEvaled.config.exports).kube_cluster;

  # D75: a node-bgp pool's owner reaches the export (routed-fabric lets
  # only the owner originate it)
  ownedPoolExport =
    (clanLib.getExport {
        serviceName = "k3s";
        instanceName = "k3s";
        roleName = "server";
        machineName = "alpha";
      }
      (mkEvaled (lib.recursiveUpdate transportInventory {
        instances.k3s.roles.server.settings.pools.owned = {
          blocks = ["192.0.2.128/28"];
          serviceSelector."clan.lol/pool" = "owned";
          delivery = "node-bgp";
          owner = "beta";
        };
        instances.k3s.roles.agent.settings.pools.owned = {
          blocks = ["192.0.2.128/28"];
          serviceSelector."clan.lol/pool" = "owned";
          delivery = "node-bgp";
          owner = "beta";
        };
      })).config.exports).kube_cluster.pools.owned;

  # All-or-none posture (§6.3): gamma is a cluster member but not a mesh
  # member — the cluster mixes transport-provided and manual addresses.
  postureInventory =
    transportInventory
    // {
      instances =
        transportInventory.instances
        // {
          mesh =
            transportInventory.instances.mesh
            // {
              roles.node.machines = {
                inherit (transportInventory.instances.mesh.roles.node.machines) alpha beta;
              };
            };
        };
    };
  postureEvaled = mkEvaled postureInventory;

  # D16 within one service: a second k3s instance claims alpha, which the
  # first already runs. The fleet check (clan.checks from the fleet-checks
  # module) throws at clan eval.
  dualClaimEvaled = mkEvaled (
    lib.recursiveUpdate transportInventory {
      instances.k3s-b = {
        module.name = "k3s";
        module.input = "self";
        roles.server = {
          settings = {
            network.fabric = {
              service = "fake-transport";
              instance = "mesh";
            };
            cilium.id = 2;
          };
          machines.alpha.settings.clusterInit = true;
        };
      };
    }
  );

  # --- D58: a THIRD-PARTY overlay implementing the neutral node_transport
  # schemaVersion 2 seam — k3s must consume it with NO provider branching.
  # The fake transport publishes a NATIVE profile (local-router exchange,
  # both exposure capabilities) with per-link MTUs to exercise the
  # minimum-MTU derivation.
  fakeTransportModule = {
    _class = "clan.service";
    manifest = {
      name = "fake-transport";
      description = "Third-party fake overlay transport (D58 eval fixture)";
      categories = ["System"];
      readme = "Eval fixture only: a native node_transport provider.";
      exports = {
        inputs = [];
        out = ["node_transport"];
      };
    };
    roles.node = {
      description = "Fake transport node.";
      interface = {lib, ...}: {
        options = {
          ipv4 = lib.mkOption {
            type = lib.types.str;
            description = "Node IPv4 on the fake overlay.";
          };
          ipv6 = lib.mkOption {
            type = lib.types.str;
            description = "Node IPv6 on the fake overlay.";
          };
          mtu = lib.mkOption {
            type = lib.types.ints.positive;
            default = 1500;
            description = "Underlay MTU of the fake link.";
          };
          asn = lib.mkOption {
            type = lib.types.ints.u32;
            description = "Allocated host routing ASN on the fake overlay.";
          };
        };
      };
      perInstance = {
        instanceName,
        machine,
        roles,
        mkExports,
        ...
      }: let
        allMembers = roles.node.machines;
        own = allMembers.${machine.name}.settings;
        ifaces = [
          "fk-${machine.name}-1"
          "fk-${machine.name}-2"
        ];
      in {
        exports = mkExports {
          node_transport = {
            schemaVersion = 2;
            inherit (own) ipv4 ipv6 asn;
            service = "routed-fabric";
            instance = instanceName;
            endpoint = null;
            port = 59999;
            interfaces = {
              ${builtins.head ifaces} = {
                mtu = own.mtu - 100;
              };
              ${builtins.elemAt ifaces 1} = {
                inherit (own) mtu;
              };
            };
            directRoutingDevice = builtins.head ifaces;
            native.routeExchange = "local-router";
            internalLoadBalancer = true;
            nodePort = true;
          };
        };
        nixosModule = _: {};
      };
    };
  };

  fakeInventory = {
    instances = {
      fabric = {
        module.name = "fake-transport";
        module.input = "self";
        roles.node.machines = {
          alpha.settings = {
            ipv4 = "192.168.77.1";
            ipv6 = "fd77::1";
            mtu = 1500;
            asn = 4258224172;
          };
          beta.settings = {
            ipv4 = "192.168.77.2";
            ipv6 = "fd77::2";
            mtu = 1400;
            asn = 4258224173;
          };
          gamma.settings = {
            ipv4 = "192.168.77.3";
            ipv6 = "fd77::3";
            mtu = 1500;
            asn = 4258224174;
          };
          delta.settings = {
            ipv4 = "192.168.77.4";
            ipv6 = "fd77::4";
            mtu = 1500;
            asn = 4258224175;
          };
        };
      };
      k3s-a = {
        module.name = "k3s";
        module.input = "self";
        roles.server = {
          settings = {
            network.fabric = {
              service = "fake-transport";
              instance = "fabric";
            };
            cilium.id = 1;
          };
          machines = {
            alpha.settings.clusterInit = true;
            beta.settings.clusterInit = false;
          };
        };
      };
      k3s-b = {
        module.name = "k3s";
        module.input = "self";
        roles.server = {
          settings = {
            network.fabric = {
              service = "fake-transport";
              instance = "fabric";
            };
            cilium.id = 2;
          };
          machines = {
            gamma.settings.clusterInit = true;
            delta.settings.clusterInit = false;
          };
        };
      };
    };
  };

  fakeEvaled = mkEvaled fakeInventory;

  alphaFake = fakeEvaled.config.nixosConfigurations.alpha.config;
  gammaFake = fakeEvaled.config.nixosConfigurations.gamma.config;

  fakeBundleObjs = builtins.fromJSON alphaFake.clan.kubeClusters.k3s-a.bundleJson;
  fakeFindObj = kind: name: lib.findFirst (o: o.kind == kind && o.metadata.name == name) null fakeBundleObjs;
  fakeCiliumConfigData = (fakeFindObj "ConfigMap" "cilium-config").data;
  fakeUsers = (fakeFindObj "ConfigMap" "clustermesh-remote-users").data."users.yaml";
  fakeApiserverDeploy = fakeFindObj "Deployment" "clustermesh-apiserver";
  fakeApiserverSvc = fakeFindObj "Service" "clustermesh-apiserver";
  fakeClustermeshSecret = fakeFindObj "Secret" "cilium-clustermesh";

  # SPEC.md D71: alpha and beta are nat-gateway clients with IPv6-only
  # underlays of different names; beta also has a tailnet link. gamma is
  # the gateway (it is in another cluster).
  d71Inventory = lib.recursiveUpdate fakeInventory {
    instances = {
      links = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines = {
          alpha.settings.links.wan = {
            interface = "eno1";
            zone = "wan";
            static.ipv6 = ["2001:db8:c::1/64"];
            ra = false;
          };
          beta.settings.links = {
            wan = {
              interface = "wlp2s0";
              zone = "wan";
              ra = false;
            };
            tailnet = {
              interface = "tailscale0";
              zone = "vpn";
              ra = false;
            };
          };
          gamma.settings.links.wan = {
            interface = "eth0";
            zone = "wan";
            static.ipv4 = ["198.51.100.1/24"];
            static.ipv6 = ["2001:db8:c::3/64"];
            ra = false;
          };
          # a plain dual-stack member (no nat-gateway role, no router):
          # the link of its default route
          delta.settings.links.lan = {
            interface = "enp7s0";
            zone = "lan";
            dhcp.ipv4 = true;
            ra = false;
          };
        };
      };
      nat64 = {
        module.name = "nat-gateway";
        module.input = "self";
        roles = {
          gateway.machines.gamma.settings = {
            pool6 = "2001:db8:a1:0:64::/96";
            address = "2001:db8:c::3";
          };
          client.machines = {
            alpha.settings.clat.address = "2001:db8:c::c1a7";
            beta.settings = {
              clat.address = "2001:db8:c::c1a8";
              sources = ["2001:db8:c::2"];
            };
          };
        };
      };
    };
  };
  d71Evaled = mkEvaled d71Inventory;
  d71Alpha = d71Evaled.config.nixosConfigurations.alpha.config;
  d71Devices = let
    objs = builtins.fromJSON d71Alpha.clan.kubeClusters.k3s-a.bundleJson;
  in
    (lib.findFirst (o: o.kind == "ConfigMap" && o.metadata.name == "cilium-config") null objs).data.devices;
  # gamma is a gateway in cluster k3s-b: its uplink joins devices
  d71GatewayDevices = let
    objs = builtins.fromJSON d71Evaled.config.nixosConfigurations.gamma.config.clan.kubeClusters.k3s-b.bundleJson;
  in
    (lib.findFirst (o: o.kind == "ConfigMap" && o.metadata.name == "cilium-config") null objs).data.devices;
  # delta is also a router: its WAN is its default-route link, and its
  # zone link has the name of gamma's uplink, which is a device
  d71Router = mkEvaled (lib.recursiveUpdate d71Inventory {
    instances = {
      links.roles.default.machines.delta.settings.links.inner = {
        interface = "eth0";
        zone = "inner";
        static.ipv4 = ["192.168.50.1/24"];
        ra = false;
      };
      edge = {
        module.name = "router";
        module.input = "self";
        roles.router.machines.delta.settings = {
          wanZone = "lan";
          zones.inner = {};
        };
      };
    };
  });
  # alpha's underlay address inside 10.0.0.0/8
  d71TenUnderlay = mkEvaled (lib.recursiveUpdate d71Inventory {
    instances.links.roles.default.machines.alpha.settings.links.wan.static.ipv4 = ["10.20.0.5/24"];
  });
  d71Vpn = mkEvaled (lib.recursiveUpdate d71Inventory {
    instances.k3s-a.roles.server.settings.cilium.helmValues.devices = "fk-alpha-1 fk-alpha-2 fk-beta-1 fk-beta-2 clat0 eno1 wlp2s0 tailscale0";
  });

  fakeExportOf = instanceName:
    (clanLib.getExport {
        serviceName = "k3s";
        inherit instanceName;
        roleName = "server";
        machineName =
          if instanceName == "k3s-a"
          then "alpha"
          else "gamma";
      }
      fakeEvaled.config.exports).kube_cluster;

  # The same fake fleet with one-directional selective peers: the symmetry
  # fleet check must throw at clan eval.
  fakeAsymmetricEvaled = mkEvaled {
    instances = {
      fabric = fakeInventory.instances.fabric;
      k3s-a = {
        module.name = "k3s";
        module.input = "self";
        roles.server = {
          settings = {
            network.fabric = {
              service = "fake-transport";
              instance = "fabric";
            };
            cilium.id = 1;
            mesh.peers = ["k3s-b"];
          };
          machines = {
            alpha.settings.clusterInit = true;
            beta.settings.clusterInit = false;
          };
        };
      };
      k3s-b = {
        module.name = "k3s";
        module.input = "self";
        roles.server = {
          settings = {
            network.fabric = {
              service = "fake-transport";
              instance = "fabric";
            };
            cilium.id = 2;
          };
          machines = {
            gamma.settings.clusterInit = true;
            delta.settings.clusterInit = false;
          };
        };
      };
    };
  };

  # Contradicting admin overrides on the fake transport must eval-fail
  # (D58 post-merge validation).
  fakeContradictionEvaled = mkEvaled {
    instances = {
      fabric = fakeInventory.instances.fabric;
      k3s-a = {
        module.name = "k3s";
        module.input = "self";
        roles.server = {
          settings = {
            network.fabric = {
              service = "fake-transport";
              instance = "fabric";
            };
            cilium.id = 1;
            cilium.helmValues.routingMode = "tunnel";
          };
          machines = {
            alpha.settings.clusterInit = true;
            beta.settings.clusterInit = false;
          };
        };
      };
    };
  };
in {
  test_serviceEnabled = {
    expr = alphaExplicit.services.k3s.enable;
    expected = true;
  };

  # K-A1: `packages.k3s` is the runtime and the source of the
  # distro's airgap images (one package, so their tags match).
  test_packageOverrideIsRuntime = let
    fakeImages = {
      type = "derivation";
      name = "k3s-images-test";
      outPath = "/nix/store/00000000000000000000000000000001-k3s-images-test";
    };
    fakePackage = {
      type = "derivation";
      name = "k3s-test-1.99.0";
      version = "1.99.0";
      outPath = "/nix/store/00000000000000000000000000000000-k3s-test-1.99.0";
      airgap-images-amd64-tar-zst = fakeImages;
    };
    alpha =
      (mkEvaled (lib.recursiveUpdate explicitInventory {
        instances.k3s.roles.server.settings.packages.k3s = fakePackage;
      })).config.nixosConfigurations.alpha.config;
  in {
    expr = {
      runtime = alpha.services.k3s.package.outPath;
      images = (builtins.head alpha.services.k3s.images).outPath;
    };
    expected = {
      runtime = fakePackage.outPath;
      images = fakeImages.outPath;
    };
  };

  test_roleServer = {
    expr = alphaExplicit.services.k3s.role;
    expected = "server";
  };

  test_roleAgent = {
    expr = gammaTransport.services.k3s.role;
    expected = "agent";
  };

  test_explicitNodeIpDualStack = {
    expr = alphaExplicit.services.k3s.nodeIP;
    expected = "10.0.0.1,fd00::1";
  };

  test_transportNodeIpDualStack = {
    expr = alphaTransport.services.k3s.nodeIP;
    expected = "10.42.0.1,fd10:42::1";
  };

  test_initServerHasEmptyServerAddr = {
    expr = alphaTransport.services.k3s.serverAddr;
    expected = "";
  };

  test_joinServerUsesLocalHaproxy = {
    expr = betaTransport.services.k3s.serverAddr;
    expected = "https://kubeapi-k3s.clan:7443";
  };

  test_agentUsesLocalHaproxy = {
    expr = gammaTransport.services.k3s.serverAddr;
    expected = "https://kubeapi-k3s.clan:7443";
  };

  test_generatorNamesServer = {
    expr = builtins.attrNames alphaExplicit.clan.core.vars.generators;
    expected = [
      "rancher-admin-kubeconfig-k3s"
      "rancher-agent-token-k3s"
      "rancher-clustermesh-ca-clan"
      "rancher-clustermesh-k3s"
      "rancher-haproxy-k3s"
      "rancher-pki-k3s"
      "rancher-server-token-k3s"
      "state-version"
    ];
  };

  test_generatorNamesAgentNoPki = {
    # K1: an agent gets the agent token and the haproxy healthcheck
    # material only: never the server token, the mesh material, the PKI
    # or the admin kubeconfig.
    expr = builtins.attrNames gammaTransport.clan.core.vars.generators;
    expected = [
      "rancher-agent-token-k3s"
      "rancher-haproxy-k3s"
      "state-version"
    ];
  };

  # K1: a joining server gets the server token, but the mesh material
  # stays on the clusterInit server (its secrets oneshot is the reader).
  test_generatorNamesJoiningServer = {
    expr = builtins.attrNames betaTransport.clan.core.vars.generators;
    expected = [
      "rancher-admin-kubeconfig-k3s"
      "rancher-agent-token-k3s"
      "rancher-haproxy-k3s"
      "rancher-server-token-k3s"
      "state-version"
    ];
  };

  # D58/D72: the transport derives the native routing profile.
  test_ciliumValuesNativeMode = {
    expr = {
      routing = ciliumConfigData."routing-mode";
      autoDirect = ciliumConfigData."auto-direct-node-routes";
      ciliumIptables = ciliumConfigData."install-iptables-rules";
      directDevice = ciliumConfigData."direct-routing-device";
    };
    expected = {
      routing = "native";
      autoDirect = "false";
      ciliumIptables = "true";
      directDevice = "fk-alpha-1";
    };
  };

  test_ciliumValuesKubeProxyReplacement = {
    expr = ciliumConfigData."kube-proxy-replacement";
    expected = "true";
  };

  test_ciliumValuesMtu = {
    # D58: the cluster-wide minimum interface MTU (the fake links are
    # 1500 and 1400).
    expr = ciliumConfigData."mtu";
    expected = "1400";
  };

  test_ciliumValuesApiViaLocalHaproxy = {
    expr = {
      host = envValue "KUBERNETES_SERVICE_HOST";
      port = envValue "KUBERNETES_SERVICE_PORT";
    };
    expected = {
      host = "kubeapi-k3s.clan";
      port = "7443";
    };
  };

  test_ciliumValuesClusterCidrs = {
    expr = let
      pool = findObj "CiliumPodIPPool" "default";
    in {
      v4 = pool.spec.ipv4.cidrs;
      v6 = pool.spec.ipv6.cidrs;
    };
    expected = {
      v4 = ["10.1.0.0/16"];
      v6 = ["fd10:1::/56"];
    };
  };

  # The bootstrap bundle replaces the distro manifests dir and charts
  # (D40): bundle at the clan-owned etc path, SSA oneshot on the
  # clusterInit node, and NO distro manifests/charts wiring.
  test_bootstrapBundleWiring = {
    expr = {
      bundleEtc = alphaTransport.environment.etc ? "clan-bootstrap/k3s/bundle.yaml";
      applyUnit = alphaTransport.systemd.services ? k3s-k3s-bootstrap-apply;
      oneshotRetries = let
        u = alphaTransport.systemd.services.k3s-k3s-bootstrap-apply;
      in
        u.serviceConfig.Type
        == "oneshot"
        && u.serviceConfig.Restart == "on-failure"
        # D40 (G11): bounded retries; a changed deployed bundle re-runs it
        && u.unitConfig.StartLimitBurst == 12
        && u.restartTriggers == [alphaTransport.environment.etc."clan-bootstrap/k3s/bundle.yaml".source]
        && u.after == ["k3s.service"];
      noManifests = alphaTransport.services.k3s.manifests == {};
      noCharts = alphaTransport.services.k3s.charts == {};
      agentNoBundle = !(gammaTransport.environment.etc ? "clan-bootstrap/k3s/bundle.yaml");
      agentNoUnit = !(gammaTransport.systemd.services ? k3s-k3s-bootstrap-apply);
      nonInitServerNoUnit = !(betaTransport.systemd.services ? k3s-k3s-bootstrap-apply);
    };
    expected = {
      bundleEtc = true;
      applyUnit = true;
      oneshotRetries = true;
      noManifests = true;
      noCharts = true;
      agentNoBundle = true;
      agentNoUnit = true;
      nonInitServerNoUnit = true;
    };
  };

  # The digest-alias oneshot (D26/D40 airgap): the bundle references images
  # digest-pinned; preloaded tarballs only register repo:tag, so every node
  # tags each pinned image under its name@digest alias for offline CRI
  # resolution.
  test_imageDigestAliasWiring = {
    expr = let
      unit = alphaTransport.systemd.services.kube-cluster-k3s-image-digest-aliases or null;
      aliases =
        if unit == null
        then [{alias = "";}]
        else unit.serviceConfig.ExecStart.passthru.aliases;
    in {
      serverHasUnit = unit != null;
      agentHasUnit = gammaTransport.systemd.services ? kube-cluster-k3s-image-digest-aliases;
      # 4 Cilium images + 1 clan CoreDNS, every alias in name@digest form
      aliasesPinnedDigests =
        builtins.length aliases == 5 && lib.all (a: lib.hasInfix "@sha256:" a.alias) aliases;
      afterRuntime = unit == null || unit.after == ["k3s.service"];
    };
    expected = {
      serverHasUnit = true;
      agentHasUnit = true;
      aliasesPinnedDigests = true;
      afterRuntime = true;
    };
  };

  # bootstrap.apply = false removes the oneshot (day-2 off-ramp).
  test_bootstrapApplyOffRamp = {
    expr = let
      off = mkEvaled (
        lib.recursiveUpdate explicitInventory {
          instances.k3s.roles.server.settings.bootstrap.apply = false;
        }
      );
      alphaOff = off.config.nixosConfigurations.alpha.config;
    in {
      noUnit = !(alphaOff.systemd.services ? k3s-k3s-bootstrap-apply);
      noEtc = !(alphaOff.environment.etc ? "clan-bootstrap/k3s/bundle.yaml");
    };
    expected = {
      noUnit = true;
      noEtc = true;
    };
  };

  # Minimal base disables the helm-controller (phase 3: the bundle
  # replaced helm-controller delivery); distroDefaults keeps it.
  test_helmControllerModes = {
    expr = {
      minimalDisabled = alphaRenderedConfig.disable-helm-controller or false;
      minimalAddons = alphaRenderedConfig.disable;
      stockKeeps = !(alphaStockRenderedConfig ? disable-helm-controller);
      stockAddons = alphaStockRenderedConfig.disable;
    };
    expected = {
      minimalDisabled = true;
      minimalAddons = [
        "servicelb"
        "coredns"
        "traefik"
        "local-storage"
        "metrics-server"
      ];
      stockKeeps = true;
      stockAddons = ["servicelb"];
    };
  };

  test_ciliumNodeIpamDefault = {
    expr = {
      nodeIpam = ciliumConfigData."enable-node-ipam";
      defaultLbIpam = ciliumConfigData."default-lb-service-ipam";
    };
    expected = {
      nodeIpam = "true";
      defaultLbIpam = "nodeipam";
    };
  };

  test_distroDefaultsOptInEvals = {
    expr = alphaStock.services.k3s.enable;
    expected = true;
  };

  test_haproxyEnabledEverywhere = {
    expr = {
      server = alphaTransport.services.haproxy.enable;
      agent = gammaTransport.services.haproxy.enable;
    };
    expected = {
      server = true;
      agent = true;
    };
  };

  test_haproxyPortDerivation = {
    # cilium.id = 1 -> kubeapi LB 7443 and stats 8404, with no supervisor LB.
    expr = {
      kubeapi = lib.hasInfix "bind 10.42.0.1:7443" alphaHaproxyConfig;
      kubeapi6 = lib.hasInfix "bind [fd10:42::1]:7443" alphaHaproxyConfig;
      supervisorDisabled = !(lib.hasInfix "k3s_supervisor" alphaHaproxyConfig);
      # K15: the stats page is on loopback
      stats = lib.hasInfix "bind 127.0.0.1:8404" alphaHaproxyConfig;
    };
    expected = {
      kubeapi = true;
      kubeapi6 = true;
      supervisorDisabled = true;
      stats = true;
    };
  };

  test_haproxyBackendsAllServers = {
    # alpha (server) lists itself plain and beta as backup, both families,
    # targeting the real apiserver port 6443.
    expr = {
      selfPlain = lib.hasInfix "server alpha-4 10.42.0.1:6443\n" alphaHaproxyConfig;
      peerBackup = lib.hasInfix "server beta-4 10.42.0.2:6443 backup" alphaHaproxyConfig;
      peerBackup6 = lib.hasInfix "server beta-6 [fd10:42::2]:6443 backup" alphaHaproxyConfig;
    };
    expected = {
      selfPlain = true;
      peerBackup = true;
      peerBackup6 = true;
    };
  };

  test_haproxyAgentBackupsPlain = {
    # Agents list every server plain (no backup flag).
    expr = {
      alphaPlain = lib.hasInfix "server alpha-4 10.42.0.1:6443\n" gammaHaproxyConfig;
      betaPlain = lib.hasInfix "server beta-4 10.42.0.2:6443\n" gammaHaproxyConfig;
      noBackups = !(lib.hasInfix " backup" gammaHaproxyConfig);
    };
    expected = {
      alphaPlain = true;
      betaPlain = true;
      noBackups = true;
    };
  };

  test_kubeapiFqdnPinnedToOwnAddress = {
    expr = {
      alpha = lib.hasInfix "10.42.0.1 kubeapi-k3s.clan" alphaTransport.networking.extraHosts;
      gamma = lib.hasInfix "10.42.0.3 kubeapi-k3s.clan" gammaTransport.networking.extraHosts;
    };
    expected = {
      alpha = true;
      gamma = true;
    };
  };

  test_pkiSeedInitOnly = {
    expr = {
      initHas = alphaTransport.systemd.services ? k3s-k3s-pki-seed;
      joiningServerHas = betaTransport.systemd.services ? k3s-k3s-pki-seed;
      agentHas = gammaTransport.systemd.services ? k3s-k3s-pki-seed;
      initPathWatcher = alphaTransport.systemd.paths ? k3s-k3s-pki-seed;
      joiningServerGenerator = betaTransport.clan.core.vars.generators ? rancher-pki-k3s;
    };
    expected = {
      initHas = true;
      joiningServerHas = false;
      agentHas = false;
      initPathWatcher = false;
      joiningServerGenerator = false;
    };
  };

  test_haproxyHealthcheckTls = {
    expr = {
      checkSsl = lib.hasInfix "default-server check check-ssl verify required" alphaHaproxyConfig;
      sni = lib.hasInfix "sni str(kubeapi-k3s.clan)" alphaHaproxyConfig;
      readyz = lib.hasInfix "option httpchk GET /readyz" alphaHaproxyConfig;
    };
    expected = {
      checkSsl = true;
      sni = true;
      readyz = true;
    };
  };

  test_ciliumFirewallForwarding = {
    expr = {
      nftables = alphaTransport.networking.nftables.enable;
      reversePathTransport = lib.hasInfix ''iifname "fk-alpha-1" accept'' alphaTransport.networking.firewall.extraReversePathFilterRules;
      reversePathProxy = lib.hasInfix "meta mark and 0x0f00 == 0x0200 accept" alphaTransport.networking.firewall.extraReversePathFilterRules;
      fromPods = lib.hasInfix ''iifname { "cilium*", "lxc*" } accept'' alphaTransport.networking.firewall.extraForwardRules;
      toPods = lib.hasInfix ''oifname { "cilium*", "lxc*" } accept'' alphaTransport.networking.firewall.extraForwardRules;
    };
    expected = {
      nftables = true;
      reversePathTransport = true;
      reversePathProxy = true;
      fromPods = true;
      toPods = true;
    };
  };

  test_twoClusterInitAssertion = {
    expr = failedAssertion alphaDualInit "exactly one server must set clusterInit";
    expected = true;
  };

  test_missingExplicitAddressAssertion = {
    expr = let
      bad = mkEvaled {
        instances.k3s = {
          module.name = "k3s";
          module.input = "self";
          roles.server = {
            settings = {
              network.fabric = null;
              cilium.id = 1;
            };
            machines.alpha.settings = {
              clusterInit = true;
              network = {
                ipv4 = null;
                ipv6 = "fd00::1";
              };
            };
          };
        };
      };
    in
      failedAssertion bad.config.nixosConfigurations.alpha.config "network.fabric is null";
    expected = true;
  };

  # --- kube_cluster export (§6.2) ------------------------------------------

  test_kubeClusterExport = {
    expr = {
      inherit
        (kubeClusterExport)
        schemaVersion
        name
        ciliumId
        meshGroup
        ;
      inherit (kubeClusterExport) network;
      meshPeers = kubeClusterExport.mesh.peers;
      meshPlacement = kubeClusterExport.mesh.placement;
      meshExposure = kubeClusterExport.mesh.exposure;
      inherit (kubeClusterExport) datapath;
      controlRole = kubeClusterExport.controlDomain.role;
      memberNames = builtins.attrNames kubeClusterExport.members;
      alphaMember = kubeClusterExport.members.alpha;
      betaTopology = kubeClusterExport.members.beta.topology;
      poolNames = builtins.attrNames kubeClusterExport.pools;
      gammaPool = kubeClusterExport.pools.gamma;
    };
    expected = {
      schemaVersion = 4;
      name = "k3s";
      ciliumId = 1;
      meshGroup = "mesh";
      meshPeers = null;
      meshPlacement = "voters";
      # D60: a native transport exposes the internalLoadBalancer capability
      # and the default fabric pool exists → auto resolves to the internal
      # LoadBalancer on the fabric VIP (offset 79).
      meshExposure = {
        method = "internal-load-balancer";
        nodePort = null;
        replicas = 2;
        vip4 = "172.16.1.79";
        dnsName = null;
        loadBalancerClass = "io.cilium/bgp-control-plane";
        published = ["https://172.16.1.79:2379"];
      };
      datapath = {
        routeExchange = "local-router";
        devices = [
          "fk-alpha-1"
          "fk-alpha-2"
        ];
        directRoutingDevice = "fk-alpha-1";
        mtu = 1400;
        internalLoadBalancer = true;
        nodePort = true;
      };
      network = {
        podCIDRv4 = "10.1.0.0/16";
        podCIDRv6 = "fd10:1::/56";
        # the published pod block (routed-fabric R11)
        podMaskSizeV4 = 24;
        podMaskSizeV6 = 64;
        serviceCIDRv4 = "10.2.0.0/16";
        serviceCIDRv6 = "fd10:2::/112";
        clusterDNS = "10.2.0.10";
        fabric = {
          service = "fake-transport";
          instance = "mesh";
        };
      };
      controlRole = "standalone";
      memberNames = [
        "alpha"
        "beta"
        "gamma"
      ];
      alphaMember = {
        role = "server";
        ipv4 = "10.42.0.1";
        ipv6 = "fd10:42::1";
        endpoint = null;
        interfaces = [
          "fk-alpha-1"
          "fk-alpha-2"
        ];
        mtu = 1400;
        port = 59999;
        topology = {
          region = "k3s";
          zone = "k3s";
        };
      };
      betaTopology = {
        region = "k3s";
        zone = "dc2";
      };
      poolNames = [
        "alpha"
        "beta"
        "gamma"
        "k3s-fabric"
      ];
      gammaPool = {
        blocks = [
          "10.42.0.3/32"
          "fd10:42::3/128"
        ];
        serviceSelector."clan.lol/pool" = "gamma";
        owner = null;
        scope = "per-machine";
        delivery = "node-fate-bound";
      };
    };
  };

  test_nodeBgpOwnerExported = {
    expr = {inherit (ownedPoolExport) owner delivery scope;};
    expected = {
      owner = "beta";
      delivery = "node-bgp";
      scope = "cluster-global";
    };
  };

  # Deep eval of the whole exports tree (the clan CLI trap): every leaf
  # must be defined.
  test_exportsDeepEval = {
    expr = builtins.deepSeq transportEvaled.config.exports true;
    expected = true;
  };

  # --- topology labels (invariant 7) ----------------------------------------

  test_topologyLabelsDefaultToInstanceName = {
    expr = alphaTransport.services.k3s.nodeLabel;
    expected = [
      "cluster=k3s"
      "role=server"
      "machine=alpha"
      "topology.kubernetes.io/region=k3s"
      "topology.kubernetes.io/zone=k3s"
    ];
  };

  test_topologyLabelsPerMachineOverride = {
    expr = builtins.filter (lib.hasPrefix "topology.kubernetes.io/") betaTransport.services.k3s.nodeLabel;
    expected = [
      "topology.kubernetes.io/region=k3s"
      "topology.kubernetes.io/zone=dc2"
    ];
  };

  # --- all-or-none transport posture (§6.3) ---------------------------------

  test_postureMissingMemberRejected = {
    expr = failedAssertion postureEvaled.config.nixosConfigurations.alpha.config "no export from the configured fabric source";
    expected = true;
  };

  # --- D16: one cluster per node (within the same distro service) ------------

  test_nodeInTwoClustersSameServiceThrows = {
    expr = !(builtins.tryEval (builtins.deepSeq dualClaimEvaled.config true)).success;
    expected = true;
  };

  # --- phase 5: BGP / fabric / BIRD (D9/D10/D19/D22) ---------------------------

  # The native third-party transport renders the BGP v2 resource set.
  test_bgpResourcesInBundle = {
    expr = let
      find = kind: name: lib.findFirst (o: o.kind == kind && o.metadata.name == name) null fakeBundleObjs;
      ccAlpha = find "CiliumBGPClusterConfig" "k3s-a-alpha";
      ccBeta = find "CiliumBGPClusterConfig" "k3s-a-beta";
      ccGamma = find "CiliumBGPClusterConfig" "k3s-a-gamma";
      pc = find "CiliumBGPPeerConfig" "k3s-a-alpha-frr";
      adv = find "CiliumBGPAdvertisement" "k3s-a-alpha-service-vips";
      podAdv = find "CiliumBGPAdvertisement" "k3s-a-alpha-pod-pools";
      instance = builtins.head ccAlpha.spec.bgpInstances;
      fabricPool = find "CiliumLoadBalancerIPPool" "k3s-a-fabric";
    in {
      perNode = ccAlpha != null && ccBeta != null && ccGamma == null;
      selector = ccAlpha.spec.nodeSelector.matchLabels."kubernetes.io/hostname";
      asns = {
        local = instance.localASN;
        peer = (builtins.head instance.peers).peerASN;
      };
      dialOut = (builtins.head instance.peers).peerAddress;
      noListener = !(instance ? localPort);
      podAdvType = (builtins.head podAdv.spec.advertisements).advertisementType;
      podAdvSelector = (builtins.head podAdv.spec.advertisements).selector.matchLabels;
      timers = pc.spec.timers;
      advPools = (builtins.head adv.spec.advertisements).selector.matchExpressions;
      fabricBlocks = fabricPool.spec.blocks;
      # D13 default off for ClusterIPs; pod-pool advertisement is
      # always on (native routing, D49).
      noClusterIpAdvert = find "CiliumBGPAdvertisement" "k3s-a-alpha-cluster-ips" == null;
    };
    expected = {
      perNode = true;
      selector = "alpha";
      asns = {
        local = 4255026608;
        peer = 4258224172;
      };
      dialOut = "::1";
      noListener = true;
      podAdvType = "CiliumPodIPPool";
      podAdvSelector."clan.lol/cluster" = "k3s-a";
      timers = {
        holdTimeSeconds = 9;
        keepAliveTimeSeconds = 3;
        connectRetryTimeSeconds = 5;
      };
      advPools = [
        {
          key = "clan.lol/pool";
          operator = "In";
          values = ["k3s-a-fabric"];
        }
      ];
      fabricBlocks = [
        {cidr = "172.16.1.0/24";}
        {cidr = "fd11:1::/64";}
      ];
      noClusterIpAdvert = true;
    };
  };

  # Member-facing private DNS is wholly day-2 (D22): no private CoreDNS
  # objects or offset-53 VIP appear in the bootstrap bundle.
  test_noPrivateCoreDNSInBundle = {
    expr =
      lib.all (o: o.metadata.name != "coredns-private") bundleObjs
      && !(lib.hasInfix "172.16.1.53" (builtins.toJSON bundleObjs));
    expected = true;
  };

  # D19 revised: routed-fabric owns the ONE host routing stack (FRR) — the
  # distro service renders no second routing stack or legacy loopback-link unit.
  test_noSecondRoutingStack = {
    expr = !(alphaTransport.systemd.services ? kube-cluster-k3s-bgp-link);
    expected = true;
  };

  # §6.12: disabling the fabric while leaving bgp.enable on is an eval error.
  test_bgpCouplingServiceAssertion = {
    expr = let
      bad = mkEvaled (
        lib.recursiveUpdate fakeInventory {
          instances.k3s-a.roles.server.settings.fabric.enable = false;
        }
      );
    in
      failedAssertion bad.config.nixosConfigurations.alpha.config "BGP only for node-bgp/shared-bgp pools";
    expected = true;
  };

  # D9 (round 22 PR review): a routed-fabric node ASN equal to the cluster's
  # Cilium ASN would make the Cilium→FRR `::1` session accidental iBGP. The
  # default fake fleet's allocations are disjoint and no host pin is set.
  test_bgpAsnCollisionSilentByDefault = {
    expr = {
      collision = failedAssertion alphaFake "accidental iBGP";
      hostPin = failedAssertion alphaFake "bgp.hostASN must match";
    };
    expected = {
      collision = false;
      hostPin = false;
    };
  };

  # A Cilium/host collision offers only remedies that change one side of the
  # real FRR session: a different Cilium ASN or a regenerated fabric ASN.
  test_bgpAsnCollisionCiliumPinRejected = {
    expr = let
      bad = mkEvaled (
        lib.recursiveUpdate fakeInventory {
          instances.k3s-a.roles.server.settings.bgp.ciliumASN = 4258224173;
        }
      );
      badAlpha = bad.config.nixosConfigurations.alpha.config;
    in {
      fired = failedAssertion badAlpha "accidental iBGP";
      namesCluster = failedAssertion badAlpha "kube-cluster/k3s-a";
      namesAsn = failedAssertion badAlpha "4258224173";
      namesMachine = failedAssertion badAlpha "machine(s) beta";
      namesCiliumPinFix = failedAssertion badAlpha "bgp.ciliumASN";
      namesRegenerateFix = failedAssertion badAlpha "clan vars generate beta --generator routed-fabric-fabric-asn --regenerate";
    };
    expected = {
      fired = true;
      namesCluster = true;
      namesAsn = true;
      namesMachine = true;
      namesCiliumPinFix = true;
      namesRegenerateFix = true;
    };
  };

  # FRR ignores a hostASN override, so a pin that differs from the allocated
  # transport ASN is rejected instead of silently changing Cilium's peer.
  test_bgpHostAsnPinMismatchRejected = {
    expr = let
      bad = mkEvaled (
        lib.recursiveUpdate fakeInventory {
          instances.k3s-a.roles.server.machines = {
            alpha.settings.bgp.hostASN = 4258224172;
            beta.settings.bgp.hostASN = 4255026608;
          };
        }
      );
      badAlpha = bad.config.nixosConfigurations.alpha.config;
    in {
      fired = failedAssertion badAlpha "bgp.hostASN must match the local-router transport ASN";
      namesMachine = failedAssertion badAlpha "machine beta";
      namesPin = failedAssertion badAlpha "pins 4255026608";
      namesAllocated = failedAssertion badAlpha "transport allocates 4258224173";
      namesRemoveFix = failedAssertion badAlpha "remove the bgp.hostASN pin";
      namesRegenerateFix = failedAssertion badAlpha "clan vars generate beta --generator routed-fabric-fabric-asn --regenerate";
    };
    expected = {
      fired = true;
      namesMachine = true;
      namesPin = true;
      namesAllocated = true;
      namesRemoveFix = true;
      namesRegenerateFix = true;
    };
  };

  # A pin equal to the transport allocation is a valid consistency check.
  test_bgpHostAsnPinEqualAccepted = {
    expr = let
      fixed = mkEvaled (
        lib.recursiveUpdate fakeInventory {
          instances.k3s-a.roles.server.machines = {
            alpha.settings.bgp.hostASN = 4258224172;
            beta.settings.bgp.hostASN = 4258224173;
          };
        }
      );
      fixedAlpha = fixed.config.nixosConfigurations.alpha.config;
    in {
      hostPin = failedAssertion fixedAlpha "bgp.hostASN must match";
      collision = failedAssertion fixedAlpha "accidental iBGP";
    };
    expected = {
      hostPin = false;
      collision = false;
    };
  };

  # D19 revised: the Cilium side dials the node-local FRR at `::1` in ONE
  # dual-AF session (no localPort) — the rendered bundle carries no
  # Cilium-to-Cilium peering and no per-cluster listener port.
  test_localFrrSessionShape = {
    expr = let
      find = kind: name: lib.findFirst (o: o.kind == kind && o.metadata.name == name) null fakeBundleObjs;
      instance = builtins.head (find "CiliumBGPClusterConfig" "k3s-a-alpha").spec.bgpInstances;
      peer = builtins.head instance.peers;
      pc = find "CiliumBGPPeerConfig" "k3s-a-alpha-frr";
    in {
      inherit (peer) peerASN peerAddress;
      noLocalPort = !(instance ? localPort);
      peerRef = peer.peerConfigRef.name;
      bothFamilies = map (f: f.afi) pc.spec.families;
      timers = pc.spec.timers;
    };
    expected = {
      peerASN = 4258224172;
      peerAddress = "::1";
      noLocalPort = true;
      peerRef = "k3s-a-alpha-frr";
      bothFamilies = [
        "ipv4"
        "ipv6"
      ];
      timers = {
        holdTimeSeconds = 9;
        keepAliveTimeSeconds = 3;
        connectRetryTimeSeconds = 5;
      };
    };
  };

  # A local-router transport renders the pod-route BGP plane and the
  # private fabric pool (D9, D10).
  test_kubeClusterExportBgpFabric = {
    expr = {
      inherit
        (kubeClusterExport.bgp)
        enabled
        ciliumAsn
        hostAsn
        advertiseClusterIPs
        ;
      inherit (kubeClusterExport) fabric;
      fabricPoolAbsent = !(kubeClusterExport.pools ? k3s-fabric);
    };
    expected = {
      enabled = true;
      ciliumAsn = 4240343820;
      hostAsn = 4258224172;
      advertiseClusterIPs = false;
      fabric = {
        enabled = true;
        pool = "k3s-fabric";
        ipv4Block = "172.16.1.0/24";
        ipv6Block = "fd11:1::/64";
      };
      fabricPoolAbsent = false;
    };
  };

  # --- D58: generic node_transport consumption (third-party overlay) -------

  test_fakeTransportNodeAddresses = {
    # k3s takes its node addresses from the fake provider's node_transport
    # export — no provider-name branching anywhere.
    expr = alphaFake.services.k3s.nodeIP;
    expected = "192.168.77.1,fd77::1";
  };

  test_fakeTransportDerivedProfile = {
    expr = {
      routing = fakeCiliumConfigData."routing-mode";
      autoDirect = fakeCiliumConfigData."auto-direct-node-routes";
      directDevice = fakeCiliumConfigData."direct-routing-device";
      devices = fakeCiliumConfigData."devices";
      # The minimum interface MTU wins (1400 < 1500).
      mtu = fakeCiliumConfigData."mtu";
      # Cluster-wide: the smallest member MTU (beta's 1400 underlay).
    };
    expected = {
      routing = "native";
      autoDirect = "false";
      directDevice = "fk-alpha-1";
      # Devices cover EVERY member's datapath interfaces (one cilium-config
      # serves all nodes); the MTU is the cluster-wide minimum (beta's
      # 1400-underlay link derives 1300).
      devices = "fk-alpha-1 fk-alpha-2 fk-beta-1 fk-beta-2";
      mtu = "1300";
    };
  };

  test_fakeTransportExportFacts = {
    expr = {
      a = {
        inherit (fakeExportOf "k3s-a") meshGroup datapath;
        exposure = (fakeExportOf "k3s-a").mesh.exposure;
      };
      bExposure = (fakeExportOf "k3s-b").mesh.exposure;
    };
    expected = {
      a = {
        meshGroup = "fabric";
        datapath = {
          routeExchange = "local-router";
          devices = [
            "fk-alpha-1"
            "fk-alpha-2"
          ];
          directRoutingDevice = "fk-alpha-1";
          mtu = 1300;
          internalLoadBalancer = true;
          nodePort = true;
        };
        exposure = {
          method = "internal-load-balancer";
          nodePort = null;
          replicas = 2;
          vip4 = "172.16.1.79";
          dnsName = null;
          loadBalancerClass = "io.cilium/bgp-control-plane";
          published = ["https://172.16.1.79:2379"];
        };
      };
      bExposure = {
        method = "internal-load-balancer";
        nodePort = null;
        replicas = 2;
        vip4 = "172.16.2.79";
        dnsName = null;
        loadBalancerClass = "io.cilium/bgp-control-plane";
        published = ["https://172.16.2.79:2379"];
      };
    };
  };

  # --- D60: ClusterMesh rendering across the fake overlay -------------------

  test_clustermeshBundleRendering = {
    expr = {
      replicas = fakeApiserverDeploy.spec.replicas;
      strategy = fakeApiserverDeploy.spec.strategy;
      requiredAntiAffinity =
        fakeApiserverDeploy.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution
        != [];
      svcType = fakeApiserverSvc.spec.type;
      etp = fakeApiserverSvc.spec.externalTrafficPolicy;
      class = fakeApiserverSvc.spec.loadBalancerClass;
      lbipam = fakeApiserverSvc.metadata.annotations."lbipam.cilium.io/ips";
      users = fakeUsers;
      peersKeyPresent = fakeClustermeshSecret != null;
      # K5: `data` (base64), never `stringData`
      peersEndpoints = fakeClustermeshSecret.data."k3s-b" or null;
      peersStringData = fakeClustermeshSecret ? stringData;
      clustermeshEnable = fakeCiliumConfigData."clustermesh-enable";
    };
    expected = {
      replicas = 2;
      strategy = {
        type = "RollingUpdate";
        rollingUpdate = {
          maxSurge = 0;
          maxUnavailable = 1;
        };
      };
      requiredAntiAffinity = true;
      svcType = "LoadBalancer";
      etp = "Local";
      class = "io.cilium/bgp-control-plane";
      lbipam = "172.16.1.79";
      users = "users:\n- name: remote-k3s-b\n  role: remote\n";
      peersKeyPresent = true;
      # base64 of "endpoints:\n- https://172.16.2.79:2379\n…" (coreutils base64)
      peersEndpoints = "ZW5kcG9pbnRzOgotIGh0dHBzOi8vMTcyLjE2LjIuNzk6MjM3OQp0cnVzdGVkLWNhLWZpbGU6IC92YXIvbGliL2NpbGl1bS9jbHVzdGVybWVzaC9jb21tb24tZXRjZC1jbGllbnQtY2EuY3J0CmtleS1maWxlOiAvdmFyL2xpYi9jaWxpdW0vY2x1c3Rlcm1lc2gvY29tbW9uLWV0Y2QtY2xpZW50LmtleQpjZXJ0LWZpbGU6IC92YXIvbGliL2NpbGl1bS9jbHVzdGVybWVzaC9jb21tb24tZXRjZC1jbGllbnQuY3J0";
      peersStringData = false;
      clustermeshEnable = "true";
    };
  };

  # The reverse direction: cluster b's bundle points at a's VIP.
  test_clustermeshReverseBundleRendering = {
    expr = let
      objs = builtins.fromJSON gammaFake.clan.kubeClusters.k3s-b.bundleJson;
      secret = lib.findFirst (o: o.kind == "Secret" && o.metadata.name == "cilium-clustermesh") null objs;
      users =
        (lib.findFirst (
            o: o.kind == "ConfigMap" && o.metadata.name == "clustermesh-remote-users"
          )
          null
          objs).data."users.yaml";
    in {
      endpoints = secret.data."k3s-a" or null;
      inherit users;
    };
    expected = {
      endpoints = "ZW5kcG9pbnRzOgotIGh0dHBzOi8vMTcyLjE2LjEuNzk6MjM3OQp0cnVzdGVkLWNhLWZpbGU6IC92YXIvbGliL2NpbGl1bS9jbHVzdGVybWVzaC9jb21tb24tZXRjZC1jbGllbnQtY2EuY3J0CmtleS1maWxlOiAvdmFyL2xpYi9jaWxpdW0vY2x1c3Rlcm1lc2gvY29tbW9uLWV0Y2QtY2xpZW50LmtleQpjZXJ0LWZpbGU6IC92YXIvbGliL2NpbGl1bS9jbHVzdGVybWVzaC9jb21tb24tZXRjZC1jbGllbnQuY3J0";
      users = "users:\n- name: remote-k3s-a\n  role: remote\n";
    };
  };

  # The apiserver TLS secrets oneshot consumes the clan vars material on
  # the clusterInit node (both clusters' groups share one CA generator).
  test_clustermeshSecretsUnit = {
    expr = {
      initHasUnit = alphaFake.systemd.services ? k3s-k3s-a-clustermesh-secrets;
      afterBootstrap =
        alphaFake.systemd.services.k3s-k3s-a-clustermesh-secrets.after
        == [
          "k3s.service"
          "k3s-k3s-a-bootstrap-apply.service"
        ];
      nonInitNoUnit = !(gammaFake.systemd.services ? k3s-k3s-a-clustermesh-secrets);
      caGen =
        fakeEvaled.config.nixosConfigurations.alpha.config.clan.core.vars.generators
          ? "rancher-clustermesh-ca-fabric";
    };
    expected = {
      initHasUnit = true;
      afterBootstrap = true;
      nonInitNoUnit = true;
      caGen = true;
    };
  };

  # Asymmetric selective peers: the fleet check throws at clan eval (D54).
  test_clustermeshAsymmetricPeersRejected = {
    expr = !(builtins.tryEval (builtins.deepSeq fakeAsymmetricEvaled.config true)).success;
    expected = true;
  };

  test_forwardingFact = {
    expr = alphaExplicit.clan.networkFacts.forwarding;
    expected = true;
  };
  # O7 (specs/design-gateway.md §3.5): pods are forwarded; a CLAT host
  # leaves the pod links to Cilium
  test_forwardLinksFact = {
    expr = lib.all (link: lib.elem link alphaExplicit.clan.networkFacts.forwardLinks) ["cilium*" "lxc*"];
    expected = true;
  };

  # D69: NodePorts answer on the members' node addresses only, as host
  # prefixes, never on another address of a `devices` link.
  test_nodePortAddresses = let
    entries = lib.splitString "," fakeCiliumConfigData."nodeport-addresses";
  in {
    expr = {
      hostPrefixes = lib.all (entry: lib.hasSuffix "/32" entry || lib.hasSuffix "/128" entry) entries;
      alpha = lib.elem "192.168.77.1/32" entries && lib.elem "fd77::1/128" entries;
      perMember = builtins.length entries / 2 >= 2;
    };
    expected = {
      hostPrefixes = true;
      alpha = true;
      perMember = true;
    };
  };

  # D70: with two or more members the CoreDNS replicas never share a node.
  test_coreDNSSpread = {
    expr = (fakeFindObj "Deployment" "coredns").spec.template.spec.topologySpreadConstraints;
    expected = [
      {
        labelSelector.matchLabels."k8s-app" = "kube-dns";
        maxSkew = 1;
        minDomains = 2;
        topologyKey = "kubernetes.io/hostname";
        whenUnsatisfiable = "DoNotSchedule";
      }
    ];
  };

  # The cluster's ranges reach the overlap checks (lib/ownership.nix).
  test_clusterRangesFact = let
    clusters = builtins.attrValues alphaFake.clan.networkFacts.clusters;
  in {
    expr =
      map (cluster: {
        inherit (cluster) distro ciliumId podCIDRv4 serviceCIDRv4;
      })
      clusters;
    expected = [
      {
        distro = "k3s";
        ciliumId = 1;
        podCIDRv4 = "10.1.0.0/16";
        serviceCIDRv4 = "10.2.0.0/16";
      }
    ];
  };

  # Contradicting cilium.helmValues on the fake transport eval-fail (D58).
  test_fakeTransportContradictingOverridesRejected = {
    expr = !(builtins.tryEval (builtins.deepSeq fakeContradictionEvaled.config true)).success;
    expected = true;
  };

  # N4: a single-node cluster may be limited to some of its machine's
  # modes; a voter of a cluster with other machines may not.
  test_singleNodeClusterRendersOnlyInItsModes = {
    expr = {
      default = modeView modesSingle;
      kubernetes = modeView modesSingle.specialisation.kubernetes.configuration;
    };
    expected = {
      default = {
        mode = "default";
        k3s = false;
        haproxy = false;
        bpffs = false;
        seed = false;
        generator = true;
        checks = false;
      };
      kubernetes = {
        mode = "kubernetes";
        k3s = true;
        haproxy = true;
        bpffs = true;
        seed = true;
        generator = true;
        checks = false;
      };
    };
  };
  test_voterMustBeInEveryMode = {
    expr = failedAssertion modesVoter "is an etcd voter of a cluster with other machines and must be active in every mode, but 'modes' leaves out maintenance";
    expected = true;
  };

  # SPEC.md D71: devices are rendered from facts. The CLAT link and the
  # IPv6-only underlay links of every member join the transport's links;
  # names come from netif, whatever each machine calls its link; a VPN
  # link never joins.
  test_d71RenderedDevices = {
    expr = lib.splitString " " d71Devices;
    expected = [
      "fk-alpha-1"
      "fk-alpha-2"
      "fk-beta-1"
      "fk-beta-2"
      "clat0"
      "eno1"
      "wlp2s0"
    ];
  };
  # specs/gateway.md §14.5 point 5: a gateway that is a node gets its
  # uplink (its public IPv4) into devices, and no CLAT.
  test_d71GatewayUplink = {
    expr = {
      uplink = lib.elem "eth0" (lib.splitString " " d71GatewayDevices);
      clat = lib.elem "clat0" (lib.splitString " " d71GatewayDevices);
    };
    expected = {
      uplink = true;
      clat = false;
    };
  };
  # A member's default-route link joins devices whatever its role: its
  # pods leave there, and Cilium masquerades on a devices link only
  # (specs/gateway.md §16.4).
  test_d71DefaultRouteLink = {
    expr = lib.elem "enp7s0" (lib.splitString " " d71GatewayDevices);
    expected = true;
  };
  # specs/gateway.md G25: a router's zone link is never a Cilium
  # device; the one cluster-wide list of names would make it one.
  test_d71RouterZoneLinkRefused = {
    expr = failedAssertion d71Router.config.nixosConfigurations.delta.config "'eth0' is a zone link of the router 'delta' and also a Cilium device";
    expected = true;
  };
  # specs/gateway.md §16.3: an underlay inside Cilium's fixed
  # native-routing range is refused
  # specs/gateway.md §16.3 items 1, 4, 5, 7, 12, 13
  test_g10Hardening = {
    expr = let
      peerConfig = lib.findFirst (o: o.kind == "CiliumBGPPeerConfig") null bundleObjs;
      agents = findObj "DaemonSet" "cilium";
      guard = alphaTransport.systemd.services."k3s-k3s-init-guard";
    in {
      ciliumGracefulRestart = peerConfig.spec.gracefulRestart;
      configHash = builtins.stringLength agents.spec.template.metadata.annotations."clan.lol/cilium-config-hash" > 0;
      rollout = agents.spec.updateStrategy.rollingUpdate.maxUnavailable;
      operators = (findObj "Deployment" "cilium-operator").spec.replicas;
      initGuard = {
        inherit (guard) before;
        inherit (guard) requiredBy;
        onInitOnly = !(betaTransport.systemd.services ? "k3s-k3s-init-guard");
      };
      pkiAsserted = lib.any (unit: (unit.unitConfig.AssertPathExists or null) != null) (lib.attrValues (lib.filterAttrs (name: _: lib.hasInfix "pki" name) alphaTransport.systemd.services));
      tunnel = lib.hasInfix "timeout tunnel  1h" alphaHaproxyConfig;
    };
    expected = {
      ciliumGracefulRestart = {
        enabled = true;
        restartTimeSeconds = 120;
      };
      configHash = true;
      rollout = 1;
      operators = 2;
      initGuard = {
        before = ["k3s.service"];
        requiredBy = ["k3s.service"];
        onInitOnly = true;
      };
      pkiAsserted = true;
      tunnel = true;
    };
  };
  test_underlayInNativeRoutingRange = {
    expr = failedAssertion d71TenUnderlay.config.nixosConfigurations.alpha.config "10.20.0.5/24 of 'alpha'";
    expected = true;
  };
  test_d71VpnLinkRefused = {
    expr = failedAssertion d71Vpn.config.nixosConfigurations.alpha.config "'tailscale0' is a VPN link";
    expected = true;
  };
  test_d71NoVpnByDefault = {
    expr = lib.any (item: !item.assertion && lib.hasInfix "VPN link" item.message) d71Alpha.assertions;
    expected = false;
  };
  # specs/gateway.md §14.1 point 4: a gateway trusts the members of a
  # kube cluster by default.
  test_clusterMembersTrusted = {
    expr = d71Evaled.config.nixosConfigurations.gamma.config.clanServices.gateway.nat64.allow;
    expected = {
      default = [];
      trusted = [
        "2001:db8:c::c1a7"
        "2001:db8:c::1"
        "2001:db8:c::c1a8"
        "2001:db8:c::2"
      ];
    };
  };

  # --- Round G11 kube hardening -------------------------------------------

  # K2: manual addresses: the cluster ports from members and pods, etcd
  # from the servers, no blanket pod accept, no trusted fabric link.
  test_firewallManualBySource = let
    rules = alphaExplicit.networking.firewall.extraInputRules;
  in {
    expr = {
      cluster = lib.hasInfix "ip saddr { 10.0.0.1, 10.0.0.2, 10.1.0.0/16 } tcp dport { 6443, 7443, 10250, 4240 } accept" rules;
      cluster6 = lib.hasInfix "ip6 saddr { fd00::1, fd00::2, fd10:1::/56 } tcp dport { 6443, 7443, 10250, 4240 } accept" rules;
      etcd = lib.hasInfix "ip saddr { 10.0.0.1, 10.0.0.2 } tcp dport { 2379, 2380, 2381 } accept" rules;
      noBlanketPodAccept = !(lib.hasInfix ''iifname { "cilium*", "lxc*" } accept'' rules);
      noGuard = !(lib.hasInfix "iifname" rules);
      trusted = alphaExplicit.networking.firewall.trustedInterfaces;
    };
    expected = {
      cluster = true;
      cluster6 = true;
      etcd = true;
      noBlanketPodAccept = true;
      noGuard = true;
      trusted = [
        "cilium_host"
        "cilium_net"
        "lo"
      ];
    };
  };

  # K2: a fabric agent opens no etcd and no API port, only on its fabric
  # links and local pod links, and does not trust the fabric links.
  test_firewallFabricAgent = let
    rules = gammaTransport.networking.firewall.extraInputRules;
  in {
    expr = {
      noEtcd = !(lib.hasInfix "2379" rules);
      ports = lib.hasInfix "tcp dport { 7443, 10250, 4240 } accept" rules;
      guard = lib.hasInfix ''iifname { "fk-gamma-1", "fk-gamma-2", "lxc*", "cilium*" } ip saddr'' rules;
      trusted = gammaTransport.networking.firewall.trustedInterfaces;
    };
    expected = {
      noEtcd = true;
      ports = true;
      guard = true;
      trusted = [
        "cilium_host"
        "cilium_net"
        "lo"
      ];
    };
  };

  # L1 (specs/design-kube.md §3.3): on a fabric, a pod or Service
  # address is reached only over the fabric links, the pod links and
  # loopback; any other link is dropped and counted. A manual-address
  # node has no named fabric link and renders no table.
  test_kubeIngressTable = let
    content = gammaTransport.networking.nftables.tables."kube-k3s".content;
  in {
    expr = {
      hook = lib.hasInfix "type filter hook prerouting priority raw; policy accept;" content;
      inside = lib.hasInfix ''iifname { "fk-gamma-1", "fk-gamma-2", "lo", "cilium*", "lxc*" } accept'' content;
      drop4 = lib.hasInfix ''ip daddr { 10.1.0.0/16, 10.2.0.0/16 } counter drop comment "outside to the cluster's pods and Services"'' content;
      drop6 = lib.hasInfix ''ip6 daddr { fd10:1::/56, fd10:2::/112 } counter drop comment "outside to the cluster's pods and Services"'' content;
      manual = alphaExplicit.networking.nftables.tables ? "kube-k3s";
    };
    expected = {
      hook = true;
      inside = true;
      drop4 = true;
      drop6 = true;
      manual = false;
    };
  };

  # K3: the init guard waits for IfState and FRR, dials the other
  # servers (plain addresses), and names its override file.
  test_initGuardWaitsForFabric = let
    guard = alphaTransport.systemd.services.k3s-k3s-init-guard;
  in {
    expr = {
      afterFabric = lib.all (u: lib.elem u guard.after) [
        "ifstate.service"
        "frr.service"
      ];
      peers = guard.environment.INIT_GUARD_PEERS;
      override = guard.environment.INIT_GUARD_OVERRIDE;
    };
    expected = {
      afterFabric = true;
      peers = "10.42.0.2";
      override = "/var/lib/rancher/k3s/server/allow-new-cluster-k3s";
    };
  };

  # K7: two servers are refused; one is fine.
  test_twoServersRefused = {
    expr = {
      two = failedAssertion alphaExplicit "two servers is refused";
      one = failedAssertion modesSingle "two servers is refused";
    };
    expected = {
      two = true;
      one = false;
    };
  };

  # K11: the instance name is Cilium's cluster-name (at most 32 chars).
  test_longInstanceNameRefused = {
    expr = let
      bad = mkEvaled {
        instances.a-cluster-name-that-is-longer-than-32 = {
          module.name = "k3s";
          module.input = "self";
          roles.server = {
            settings = {
              network.fabric = null;
              cilium.id = 1;
            };
            machines.alpha.settings = {
              clusterInit = true;
              network = {
                ipv4 = "10.0.0.1";
                ipv6 = "fd00::1";
              };
            };
          };
        };
      };
    in
      failedAssertion bad.config.nixosConfigurations.alpha.config "the instance name is the Cilium cluster name";
    expected = true;
  };

  # K14: configOverrides cannot carry a token or replace a rendered key.
  test_configOverridesDenied = let
    evaled = mkEvaled (
      lib.recursiveUpdate explicitInventory {
        instances.k3s.roles.server.settings.configOverrides = {
          token = "in-the-store";
          tls-san = ["elsewhere"];
          kubelet-arg = ["max-pods=200"];
        };
      }
    );
    alpha = evaled.config.nixosConfigurations.alpha.config;
  in {
    expr = {
      denied = failedAssertion alpha "configOverrides may not set tls-san, token:";
      allowed = alpha.clan.kubeClusters.k3s.renderedDistroConfig.kubelet-arg;
    };
    expected = {
      denied = true;
      allowed = ["max-pods=200"];
    };
  };

  # K15: the stats page is read-only on loopback; the health check
  # verifies the kubeapi FQDN.
  test_haproxyStatsLoopbackVerifyhost = {
    expr = {
      loopback = lib.hasInfix "bind 127.0.0.1:8404" alphaHaproxyConfig;
      noUserlist = !(lib.hasInfix "userlist" alphaHaproxyConfig);
      verifyhost = lib.hasInfix "verify required verifyhost kubeapi-k3s.clan" alphaHaproxyConfig;
    };
    expected = {
      loopback = true;
      noUserlist = true;
      verifyhost = true;
    };
  };

  # K9: Secrets are encrypted at rest in etcd on every k3s server (rke2
  # does it by default).
  test_secretsEncryption = {
    expr = {
      init = alphaRenderedConfig.secrets-encryption;
      joining = betaTransport.clan.kubeClusters.k3s.renderedDistroConfig.secrets-encryption;
      agent = gammaTransport.clan.kubeClusters.k3s.renderedDistroConfig ? secrets-encryption;
    };
    expected = {
      init = true;
      joining = true;
      agent = false;
    };
  };
}
