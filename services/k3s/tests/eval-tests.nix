{
  lib,
  module,
  clanLib,
  exportInterfaces,
  ...
}:
let
  k3sModule = module;
  wgModule = ../../wireguard-mesh/default.nix;
  kube = import ../../../lib/kube-cluster { inherit lib; };

  machineConfigs = lib.genAttrs [ "alpha" "beta" "gamma" ] (_: {
    nixpkgs.hostPlatform = "x86_64-linux";
  });

  mkEvaled =
    inventory:
    clanLib.clan {
      self = { };
      directory = ./fixtures;
      inherit exportInterfaces;
      # Fleet-wide kube-cluster assertions (§6.2) as clan.checks — enforced
      # by clanLib.clan's checkConfig.
      imports = [ kube.fleetChecksModule ];
      modules = {
        wireguard-mesh = wgModule;
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
          network.transport = null;
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
          settings.endpointSources = [ ];
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
            network.transport = {
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
            network.transport = {
              service = "wireguard-mesh";
              instance = "mesh";
            };
            cilium.id = 1;
          };
          machines.gamma = { };
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

  failedAssertion =
    machineConfig: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) machineConfig.assertions;

  # The rendered bootstrap bundle on the clusterInit node (D40).
  bundleObjs = builtins.fromJSON alphaTransport.clan.kubeClusters.k3s.bundleJson;
  findObj = kind: name: lib.findFirst (o: o.kind == kind && o.metadata.name == name) null bundleObjs;
  ciliumConfigData = (findObj "ConfigMap" "cilium-config").data;
  agentEnv =
    (lib.findFirst (c: c.name == "cilium") null
      (findObj "DaemonSet" "cilium").spec.template.spec.containers
    ).env;
  envValue = name: (lib.findFirst (e: e.name == name) { value = null; } agentEnv).value;

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
    } transportEvaled.config.exports).kube_cluster;

  # All-or-none posture (§6.3): gamma is a cluster member but not a mesh
  # member — the cluster mixes transport-provided and manual addresses.
  postureInventory = transportInventory // {
    instances = transportInventory.instances // {
      mesh = transportInventory.instances.mesh // {
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
            network.transport = {
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
in
{
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
      "rancher-haproxy-k3s"
      "rancher-pki-k3s"
      "rancher-server-token-k3s"
      "state-version"
    ];
  };

  test_generatorNamesAgentNoPki = {
    # Agents get the join tokens and the haproxy healthcheck material, but
    # NEVER the PKI / admin kubeconfig generators.
    expr = builtins.attrNames gammaTransport.clan.core.vars.generators;
    expected = [
      "rancher-agent-token-k3s"
      "rancher-haproxy-k3s"
      "rancher-server-token-k3s"
      "state-version"
      "wireguard-mesh-mesh"
    ];
  };

  test_ciliumValuesTunnelMode = {
    expr = ciliumConfigData."routing-mode";
    expected = "tunnel";
  };

  test_ciliumValuesKubeProxyReplacement = {
    expr = ciliumConfigData."kube-proxy-replacement";
    expected = "true";
  };

  test_ciliumValuesMtu = {
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
    expr =
      let
        pool = findObj "CiliumPodIPPool" "default";
      in
      {
        v4 = pool.spec.ipv4.cidrs;
        v6 = pool.spec.ipv6.cidrs;
      };
    expected = {
      v4 = [ "10.1.0.0/16" ];
      v6 = [ "fd10:1::/56" ];
    };
  };

  # The bootstrap bundle replaces the distro manifests dir and charts
  # (D40): bundle at the clan-owned etc path, SSA oneshot on the
  # clusterInit node, and NO distro manifests/charts wiring.
  test_bootstrapBundleWiring = {
    expr = {
      bundleEtc = alphaTransport.environment.etc ? "clan-bootstrap/k3s/bundle.yaml";
      applyUnit = alphaTransport.systemd.services ? k3s-k3s-bootstrap-apply;
      oneshotRetries =
        let
          u = alphaTransport.systemd.services.k3s-k3s-bootstrap-apply;
        in
        u.serviceConfig.Type == "oneshot"
        && u.serviceConfig.Restart == "on-failure"
        && u.unitConfig.StartLimitIntervalSec == 0
        && u.after == [ "k3s.service" ];
      noManifests = alphaTransport.services.k3s.manifests == { };
      noCharts = alphaTransport.services.k3s.charts == { };
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

  # bootstrap.apply = false removes the oneshot (day-2 off-ramp).
  test_bootstrapApplyOffRamp = {
    expr =
      let
        off = mkEvaled (
          lib.recursiveUpdate explicitInventory {
            instances.k3s.roles.server.settings.bootstrap.apply = false;
          }
        );
        alphaOff = off.config.nixosConfigurations.alpha.config;
      in
      {
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
      stockAddons = [ "servicelb" ];
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
    expr =
      let
        bad = mkEvaled {
          instances.k3s = {
            module.name = "k3s";
            module.input = "self";
            roles.server = {
              settings = {
                network.transport = null;
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
      failedAssertion bad.config.nixosConfigurations.alpha.config "network.transport is null";
    expected = true;
  };

  # --- kube_cluster export (§6.2) ------------------------------------------

  test_kubeClusterExport = {
    expr = {
      inherit (kubeClusterExport)
        schemaVersion
        name
        ciliumId
        meshGroup
        ;
      inherit (kubeClusterExport) network transport;
      controlRole = kubeClusterExport.controlDomain.role;
      memberNames = builtins.attrNames kubeClusterExport.members;
      alphaMember = kubeClusterExport.members.alpha;
      betaTopology = kubeClusterExport.members.beta.topology;
      poolNames = builtins.attrNames kubeClusterExport.pools;
      gammaPool = kubeClusterExport.pools.gamma;
    };
    expected = {
      schemaVersion = 1;
      name = "k3s";
      ciliumId = 1;
      meshGroup = "clan";
      network = {
        podCIDRv4 = "10.1.0.0/16";
        podCIDRv6 = "fd10:1::/56";
        serviceCIDRv4 = "10.2.0.0/16";
        serviceCIDRv6 = "fd10:2::/112";
        clusterDNS = "10.2.0.10";
      };
      transport = {
        service = "wireguard-mesh";
        instance = "mesh";
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
        interface = "wg-mesh";
        mtu = 1420;
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
    expr = failedAssertion postureEvaled.config.nixosConfigurations.alpha.config "no export from the configured node_transport source";
    expected = true;
  };

  # --- D16: one cluster per node (within the same distro service) ------------

  test_nodeInTwoClustersSameServiceThrows = {
    expr = !(builtins.tryEval (builtins.deepSeq dualClaimEvaled.config true)).success;
    expected = true;
  };
}
