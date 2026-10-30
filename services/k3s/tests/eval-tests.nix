{
  lib,
  module,
  clanLib,
  exportInterfaces,
  inputs,
  ...
}: let
  k3sModule = module;
  wgModule = lib.modules.importApply ../../wireguard-mesh/default.nix {
    ifstateOverlay = inputs.pkgs.overlays.ifstate;
  };
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
      inherit exportInterfaces;
      # Fleet-wide kube-cluster assertions (§6.2) as clan.checks — enforced
      # by clanLib.clan's checkConfig.
      imports = [kube.fleetChecksModule];
      modules = {
        wireguard-mesh = wgModule;
        fake-transport = fakeTransportModule;
        k3s = k3sModule;
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
  alphaExplicit = explicitEvaled.config.nixosConfigurations.alpha.config;

  # Inventory backed by a real wireguard-mesh instance: two servers plus
  # one agent.
  transportInventory = {
    instances = {
      mesh = {
        module.name = "wireguard-mesh";
        module.input = "self";
        roles.peer = {
          settings.endpointSources = [];
          machines = {
            alpha.settings = {
              ipv4 = "10.42.0.1";
              ipv6 = "fd10:42::1";
              endpoint = "alpha";
            };
            beta.settings = {
              ipv4 = "10.42.0.2";
              ipv6 = "fd10:42::2";
              endpoint = "beta";
            };
            gamma.settings = {
              ipv4 = "10.42.0.3";
              ipv6 = "fd10:42::3";
              endpoint = "gamma";
            };
          };
        };
      };
      k3s = {
        module.name = "k3s";
        module.input = "self";
        roles.server = {
          settings = {
            network.fabric = {
              service = "wireguard-mesh";
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
              service = "wireguard-mesh";
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
              roles.peer.machines = {
                inherit (transportInventory.instances.mesh.roles.peer.machines) alpha beta;
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
              service = "wireguard-mesh";
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
            datapath = {
              mode = "native";
              tunnelProtocol = null;
            };
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
    # Agents get the join tokens, the haproxy healthcheck material, and
    # the mesh material (CA + apiserver leaf set — SANs are eval-computed),
    # but NEVER the PKI / admin kubeconfig generators.
    expr = builtins.attrNames gammaTransport.clan.core.vars.generators;
    expected = [
      "rancher-agent-token-k3s"
      "rancher-clustermesh-ca-mesh"
      "rancher-clustermesh-k3s"
      "rancher-haproxy-k3s"
      "rancher-server-token-k3s"
      "state-version"
      "wireguard-mesh-mesh"
    ];
  };

  # D58: the wireguard-mesh transport derives the VXLAN tunnel profile.
  test_ciliumValuesNativeMode = {
    expr = {
      routing = ciliumConfigData."routing-mode";
      tunnel = ciliumConfigData."tunnel-protocol";
      autoDirect = ciliumConfigData."auto-direct-node-routes";
      ciliumIptables = ciliumConfigData."install-iptables-rules";
      directDevice = ciliumConfigData."direct-routing-device";
    };
    expected = {
      routing = "tunnel";
      tunnel = "vxlan";
      autoDirect = "false";
      ciliumIptables = "true";
      directDevice = "wg-mesh";
    };
  };

  test_ciliumValuesKubeProxyReplacement = {
    expr = ciliumConfigData."kube-proxy-replacement";
    expected = "true";
  };

  test_ciliumValuesMtu = {
    # D58: VXLAN tunnel mode = minimum interface MTU minus 50.
    expr = ciliumConfigData."mtu";
    expected = "1370";
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
        && u.unitConfig.StartLimitIntervalSec == 0
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
      stats = lib.hasInfix "bind 10.42.0.1:8404" alphaHaproxyConfig;
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
      reversePathTransport = lib.hasInfix ''iifname "wg-mesh" accept'' alphaTransport.networking.firewall.extraReversePathFilterRules;
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
      # D60: wireguard-mesh exposes no internalLoadBalancer capability and
      # no fabric pool → auto resolves to node-port with the default port.
      meshExposure = {
        method = "node-port";
        nodePort = 32379;
        replicas = 2;
        vip4 = null;
        dnsName = null;
        loadBalancerClass = null;
        published = [
          "https://10.42.0.1:32379"
          "https://10.42.0.2:32379"
        ];
      };
      datapath = {
        mode = "tunnel";
        tunnelProtocol = "vxlan";
        routeExchange = null;
        devices = ["wg-mesh"];
        directRoutingDevice = "wg-mesh";
        mtu = 1370;
        internalLoadBalancer = false;
        nodePort = true;
      };
      network = {
        podCIDRv4 = "10.1.0.0/16";
        podCIDRv6 = "fd10:1::/56";
        serviceCIDRv4 = "10.2.0.0/16";
        serviceCIDRv6 = "fd10:2::/112";
        clusterDNS = "10.2.0.10";
        fabric = {
          service = "wireguard-mesh";
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
        endpoint = "alpha:51820";
        interfaces = ["wg-mesh"];
        mtu = 1370;
        port = 51820;
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

  # Tunnel transports render no pod-route BGP plane or private fabric pool.
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
      enabled = false;
      ciliumAsn = 4240343820;
      hostAsn = 4202640987;
      advertiseClusterIPs = false;
      fabric = {
        enabled = false;
        pool = "";
        ipv4Block = null;
        ipv6Block = null;
      };
      fabricPoolAbsent = true;
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
      # Native mode: the minimum interface MTU wins (1400 < 1500), no
      # VXLAN subtraction.
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
          mode = "native";
          tunnelProtocol = null;
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
      peersEndpoints = fakeClustermeshSecret.stringData."k3s-b" or null;
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
      peersEndpoints = "endpoints:\n- https://172.16.2.79:2379\ntrusted-ca-file: /var/lib/cilium/clustermesh/common-etcd-client-ca.crt\nkey-file: /var/lib/cilium/clustermesh/common-etcd-client.key\ncert-file: /var/lib/cilium/clustermesh/common-etcd-client.crt";
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
      endpoints = secret.stringData."k3s-a" or null;
      inherit users;
    };
    expected = {
      endpoints = "endpoints:\n- https://172.16.1.79:2379\ntrusted-ca-file: /var/lib/cilium/clustermesh/common-etcd-client-ca.crt\nkey-file: /var/lib/cilium/clustermesh/common-etcd-client.key\ncert-file: /var/lib/cilium/clustermesh/common-etcd-client.crt";
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

  # Contradicting cilium.helmValues on the fake transport eval-fail (D58).
  test_fakeTransportContradictingOverridesRejected = {
    expr = !(builtins.tryEval (builtins.deepSeq fakeContradictionEvaled.config true)).success;
    expected = true;
  };
}
