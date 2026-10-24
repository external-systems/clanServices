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
  rke2Module = module;
  k3sModule = lib.modules.importApply ../../k3s/default.nix { inherit self inputs; };
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
        rke2 = rke2Module;
        k3s = k3sModule;
      };
      machines = machineConfigs;
      inherit inventory;
    };

  # Inventory with explicit per-node addresses (no transport service).
  explicitInventory = {
    instances.rke2 = {
      module.name = "rke2";
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
      rke2 = {
        module.name = "rke2";
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
  # packaged components (D42).
  stockInventory = lib.recursiveUpdate explicitInventory {
    instances.rke2.roles.server.settings.distroDefaults.enable = true;
  };
  stockEvaled = mkEvaled stockInventory;
  alphaStock = stockEvaled.config.nixosConfigurations.alpha.config;

  failedAssertion =
    machineConfig: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) machineConfig.assertions;

  # The rendered bootstrap bundle on the clusterInit node (D40).
  bundleObjs = builtins.fromJSON alphaTransport.clan.kubeClusters.rke2.bundleJson;
  findObj = kind: name: lib.findFirst (o: o.kind == kind && o.metadata.name == name) null bundleObjs;
  ciliumConfigData = (findObj "ConfigMap" "cilium-config").data;
  agentEnv =
    (lib.findFirst (c: c.name == "cilium-agent") null
      (findObj "DaemonSet" "cilium").spec.template.spec.containers
    ).env;
  envValue = name: (lib.findFirst (e: e.name == name) { value = null; } agentEnv).value;

  # The rendered config.yaml (via the environment.etc source derivation is
  # not directly inspectable; the service mirrors it into the internal
  # clan.kubeClusters seam, and the nixpkgs module mirrors the join URL
  # into serverAddr and the token files into tokenFile).
  alphaRenderedConfig = alphaTransport.clan.kubeClusters.rke2.renderedDistroConfig;
  alphaStockRenderedConfig = alphaStock.clan.kubeClusters.rke2.renderedDistroConfig;

  alphaHaproxyConfig = alphaTransport.services.haproxy.config;
  gammaHaproxyConfig = gammaTransport.services.haproxy.config;

  # A cluster with two clusterInit servers should fail.
  dualInitInventory = lib.recursiveUpdate explicitInventory {
    instances.rke2.roles.server.machines.beta.settings.clusterInit = true;
  };
  dualInitEvaled = mkEvaled dualInitInventory;
  alphaDualInit = dualInitEvaled.config.nixosConfigurations.alpha.config;

  # The kube_cluster export of the transport-backed instance (per-member
  # scope; identical content on every member).
  kubeClusterExport =
    (clanLib.getExport {
      serviceName = "rke2";
      instanceName = "rke2";
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

  # D16 cross-service: a k3s instance claims alpha, which the rke2
  # instance already runs. The fleet check (clan.checks from the
  # fleet-checks module) throws at clan eval.
  dualClaimEvaled = mkEvaled (
    lib.recursiveUpdate transportInventory {
      instances.k3s2 = {
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
    expr = alphaExplicit.services.rke2.enable;
    expected = true;
  };

  test_roleServer = {
    expr = alphaExplicit.services.rke2.role;
    expected = "server";
  };

  test_roleAgent = {
    expr = gammaTransport.services.rke2.role;
    expected = "agent";
  };

  test_explicitNodeIpDualStack = {
    expr = alphaExplicit.services.rke2.nodeIP;
    expected = "10.0.0.1,fd00::1";
  };

  test_transportNodeIpDualStack = {
    expr = alphaTransport.services.rke2.nodeIP;
    expected = "10.42.0.1,fd10:42::1";
  };

  test_initServerHasEmptyServerAddr = {
    expr = alphaTransport.services.rke2.serverAddr;
    expected = "";
  };

  test_joinServerUsesLocalHaproxy = {
    expr = betaTransport.services.rke2.serverAddr;
    expected = "https://kubeapi-rke2.clan:8443";
  };

  test_agentUsesLocalHaproxy = {
    expr = gammaTransport.services.rke2.serverAddr;
    expected = "https://kubeapi-rke2.clan:8443";
  };

  test_generatorNamesServer = {
    expr = builtins.attrNames alphaExplicit.clan.core.vars.generators;
    expected = [
      "rancher-admin-kubeconfig-rke2"
      "rancher-agent-token-rke2"
      "rancher-haproxy-rke2"
      "rancher-pki-rke2"
      "rancher-server-token-rke2"
      "state-version"
    ];
  };

  test_generatorNamesAgentNoPki = {
    # Agents get the join tokens and the haproxy healthcheck material, but
    # NEVER the PKI / admin kubeconfig generators.
    expr = builtins.attrNames gammaTransport.clan.core.vars.generators;
    expected = [
      "rancher-agent-token-rke2"
      "rancher-haproxy-rke2"
      "rancher-server-token-rke2"
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
      host = "kubeapi-rke2.clan";
      port = "7443";
    };
  };

  # The bootstrap bundle replaces the distro manifests dir and the
  # HelmChartConfig machinery (D40): bundle at the clan-owned etc path,
  # SSA oneshot on the clusterInit node, no distro manifests wiring.
  test_bootstrapBundleWiring = {
    expr = {
      bundleEtc = alphaTransport.environment.etc ? "clan-bootstrap/rke2/bundle.yaml";
      applyUnit = alphaTransport.systemd.services ? rke2-rke2-bootstrap-apply;
      oneshotRetries =
        let
          u = alphaTransport.systemd.services.rke2-rke2-bootstrap-apply;
        in
        u.serviceConfig.Type == "oneshot"
        && u.serviceConfig.Restart == "on-failure"
        && u.unitConfig.StartLimitIntervalSec == 0
        && u.after == [ "rke2-server.service" ];
      noManifests = alphaTransport.services.rke2.manifests == { };
      agentNoBundle = !(gammaTransport.environment.etc ? "clan-bootstrap/rke2/bundle.yaml");
      agentNoUnit = !(gammaTransport.systemd.services ? rke2-rke2-bootstrap-apply);
      nonInitServerNoUnit = !(betaTransport.systemd.services ? rke2-rke2-bootstrap-apply);
    };
    expected = {
      bundleEtc = true;
      applyUnit = true;
      oneshotRetries = true;
      noManifests = true;
      agentNoBundle = true;
      agentNoUnit = true;
      nonInitServerNoUnit = true;
    };
  };

  # The digest-alias oneshot (D26/D40 airgap): the bundle references images
  # digest-pinned; preloaded tarballs only register repo:tag, so every node
  # tags each pinned image under its name@digest alias for offline CRI
  # resolution. Server nodes order after rke2-server, agents after
  # rke2-agent.
  test_imageDigestAliasWiring = {
    expr =
      let
        unit = alphaTransport.systemd.services.kube-cluster-rke2-image-digest-aliases or null;
        agentUnit = gammaTransport.systemd.services.kube-cluster-rke2-image-digest-aliases or null;
        aliases =
          if unit == null then [ { alias = ""; } ] else unit.serviceConfig.ExecStart.passthru.aliases;
      in
      {
        serverHasUnit = unit != null;
        agentHasUnit = agentUnit != null;
        # 4 Cilium images + 1 clan CoreDNS, every alias in name@digest form
        aliasesPinnedDigests =
          builtins.length aliases == 5 && lib.all (a: lib.hasInfix "@sha256:" a.alias) aliases;
        serverAfterRuntime = unit == null || unit.after == [ "rke2-server.service" ];
        agentAfterRuntime = agentUnit == null || agentUnit.after == [ "rke2-agent.service" ];
      };
    expected = {
      serverHasUnit = true;
      agentHasUnit = true;
      aliasesPinnedDigests = true;
      serverAfterRuntime = true;
      agentAfterRuntime = true;
    };
  };

  # Minimal base disables the helm-controller and BYO-CNI is selected
  # (cni: none — canonical Cilium comes from the bundle, §6.4); the
  # bundled rke2-cilium chart is disabled in BOTH modes.
  test_helmControllerModes = {
    expr = {
      minimalDisabled = alphaRenderedConfig.disable-helm-controller or false;
      minimalCni = alphaRenderedConfig.cni;
      minimalAddons = alphaRenderedConfig.disable;
      stockKeeps = !(alphaStockRenderedConfig ? disable-helm-controller);
      stockAddons = alphaStockRenderedConfig.disable;
    };
    expected = {
      minimalDisabled = true;
      minimalCni = "none";
      minimalAddons = [
        "rke2-cilium"
        "rke2-coredns"
        "rke2-ingress-nginx"
        "rke2-metrics-server"
        "rke2-snapshot-controller"
        "rke2-snapshot-validation-webhook"
      ];
      stockKeeps = true;
      stockAddons = [
        "rke2-cilium"
        "rke2-coredns"
      ];
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
    expr = alphaStock.services.rke2.enable;
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
    # cilium.id = 1 -> kubeapi LB 7443, supervisor LB 8443, stats 8404.
    expr = {
      kubeapi = lib.hasInfix "bind 10.42.0.1:7443" alphaHaproxyConfig;
      kubeapi6 = lib.hasInfix "bind [fd10:42::1]:7443" alphaHaproxyConfig;
      supervisor = lib.hasInfix "bind 10.42.0.1:8443" alphaHaproxyConfig;
      stats = lib.hasInfix "bind 10.42.0.1:8404" alphaHaproxyConfig;
    };
    expected = {
      kubeapi = true;
      kubeapi6 = true;
      supervisor = true;
      stats = true;
    };
  };

  test_haproxyBackendsAllServers = {
    # alpha (server) lists itself plain and beta as backup, both families,
    # targeting the real apiserver port 6443 and supervisor port 9345.
    expr = {
      selfPlain = lib.hasInfix "server alpha-4 10.42.0.1:6443\n" alphaHaproxyConfig;
      peerBackup = lib.hasInfix "server beta-4 10.42.0.2:6443 backup" alphaHaproxyConfig;
      peerBackup6 = lib.hasInfix "server beta-6 [fd10:42::2]:9345 backup" alphaHaproxyConfig;
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
      alpha = lib.hasInfix "10.42.0.1 kubeapi-rke2.clan" alphaTransport.networking.extraHosts;
      gamma = lib.hasInfix "10.42.0.3 kubeapi-rke2.clan" gammaTransport.networking.extraHosts;
    };
    expected = {
      alpha = true;
      gamma = true;
    };
  };

  test_pkiSyncServerOnly = {
    expr = {
      serverHas = alphaTransport.systemd.services ? rke2-rke2-pki-sync-tls;
      agentHas = gammaTransport.systemd.services ? rke2-rke2-pki-sync-tls;
      serverPath = alphaTransport.systemd.paths ? rke2-rke2-pki-sync-tls;
    };
    expected = {
      serverHas = true;
      agentHas = false;
      serverPath = true;
    };
  };

  test_haproxyHealthcheckTls = {
    expr = {
      checkSsl = lib.hasInfix "default-server check check-ssl verify required" alphaHaproxyConfig;
      supervisorRealApiPort = lib.hasInfix "default-server check check-ssl port 6443" alphaHaproxyConfig;
      sni = lib.hasInfix "sni str(kubeapi-rke2.clan)" alphaHaproxyConfig;
      readyz = lib.hasInfix "option httpchk GET /readyz" alphaHaproxyConfig;
    };
    expected = {
      checkSsl = true;
      supervisorRealApiPort = true;
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
          instances.rke2 = {
            module.name = "rke2";
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
      alphaPool = kubeClusterExport.pools.alpha;
    };
    expected = {
      schemaVersion = 2;
      name = "rke2";
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
          region = "rke2";
          zone = "rke2";
        };
      };
      betaTopology = {
        region = "rke2";
        zone = "dc2";
      };
      poolNames = [
        "alpha"
        "beta"
        "gamma"
        "rke2-fabric"
      ];
      alphaPool = {
        blocks = [
          "10.42.0.1/32"
          "fd10:42::1/128"
        ];
        serviceSelector."clan.lol/pool" = "alpha";
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
    expr = alphaTransport.services.rke2.nodeLabel;
    expected = [
      "cluster=rke2"
      "role=server"
      "machine=alpha"
      "topology.kubernetes.io/region=rke2"
      "topology.kubernetes.io/zone=rke2"
    ];
  };

  test_topologyLabelsPerMachineOverride = {
    expr = builtins.filter (lib.hasPrefix "topology.kubernetes.io/") betaTransport.services.rke2.nodeLabel;
    expected = [
      "topology.kubernetes.io/region=rke2"
      "topology.kubernetes.io/zone=dc2"
    ];
  };

  test_topologyLabelsAgent = {
    expr = builtins.filter (lib.hasPrefix "topology.kubernetes.io/") gammaTransport.services.rke2.nodeLabel;
    expected = [
      "topology.kubernetes.io/region=rke2"
      "topology.kubernetes.io/zone=rke2"
    ];
  };

  # --- all-or-none transport posture (§6.3) ---------------------------------

  test_postureMissingMemberRejected = {
    expr = failedAssertion postureEvaled.config.nixosConfigurations.alpha.config "no export from the configured node_transport source";
    expected = true;
  };

  # --- D16: one cluster per node, across distro services ---------------------

  test_nodeInTwoClustersCrossServiceThrows = {
    expr = !(builtins.tryEval (builtins.deepSeq dualClaimEvaled.config true)).success;
    expected = true;
  };

  # --- phase 5: BGP / fabric / BIRD (D9/D10/D19/D22) ---------------------------

  # The default fabric renders the BGP v2 resource set into the bundle.
  test_bgpResourcesInBundle = {
    expr =
      let
        ccAlpha = findObj "CiliumBGPClusterConfig" "rke2-alpha";
        ccBeta = findObj "CiliumBGPClusterConfig" "rke2-beta";
        ccGamma = findObj "CiliumBGPClusterConfig" "rke2-gamma";
        pc = findObj "CiliumBGPPeerConfig" "rke2-bird";
        adv = findObj "CiliumBGPAdvertisement" "rke2-service-vips";
        instance = builtins.head ccAlpha.spec.bgpInstances;
        fabricPool = findObj "CiliumLoadBalancerIPPool" "rke2-fabric";
      in
      {
        perNode = ccAlpha != null && ccBeta != null && ccGamma != null;
        selector = ccAlpha.spec.nodeSelector.matchLabels."kubernetes.io/hostname";
        asns = {
          local = instance.localASN;
          peer = (builtins.head instance.peers).peerASN;
        };
        dialOut = (builtins.head instance.peers).peerAddress;
        noListener = !(instance ? localPort);
        timers = pc.spec.timers;
        fabricBlocks = fabricPool.spec.blocks;
        advPools = (builtins.head adv.spec.advertisements).selector.matchExpressions;
        noPodAdvert = findObj "CiliumBGPAdvertisement" "rke2-pod-cidrs" == null;
        noClusterIpAdvert = findObj "CiliumBGPAdvertisement" "rke2-cluster-ips" == null;
      };
    expected = {
      perNode = true;
      selector = "alpha";
      asns = {
        local = 4200812391;
        peer = 4226982861;
      };
      dialOut = "169.254.179.1";
      noListener = true;
      timers = {
        holdTimeSeconds = 9;
        keepAliveTimeSeconds = 3;
        connectRetryTimeSeconds = 5;
      };
      fabricBlocks = [
        { cidr = "172.16.1.0/24"; }
        { cidr = "fd11:1::/64"; }
      ];
      advPools = [
        {
          key = "clan.lol/pool";
          operator = "In";
          values = [ "rke2-fabric" ];
        }
      ];
      noPodAdvert = true;
      noClusterIpAdvert = true;
    };
  };

  # The private CoreDNS (D22 substrate) on its fabric VIP — rendered in the
  # minimal base AND under distroDefaults (D46).
  test_privateCoreDNSInBundle = {
    expr =
      let
        svc = findObj "Service" "coredns-private";
        cm = findObj "ConfigMap" "coredns-private";
      in
      {
        inherit (svc.spec) externalTrafficPolicy loadBalancerClass;
        ips = svc.metadata.annotations."lbipam.cilium.io/ips";
        poolLabel = svc.metadata.labels."clan.lol/pool";
        zone = lib.hasInfix "rke2.clan:53 {" cm.data.Corefile;
        noClusterLocal = !(lib.hasInfix "cluster.local:53" cm.data.Corefile);
      };
    expected = {
      externalTrafficPolicy = "Local";
      loadBalancerClass = "io.cilium/bgp-control-plane";
      ips = "172.16.1.53,fd11:1:0:0:0:0:0:53";
      poolLabel = "rke2-fabric";
      zone = true;
      noClusterLocal = true;
    };
  };

  # The per-node BIRD (D19): fragment contributed under the namespaced key,
  # routerId = the node's mesh IPv4, one bird service, loopback link unit.
  test_birdWiring = {
    expr = {
      birdEnabled = alphaTransport.services.bird.enable;
      bird2Package = lib.hasInfix "bird-2." (toString alphaTransport.services.bird.package);
      routerId = alphaTransport.clan.bird.routerId;
      fragmentKey = alphaTransport.clan.bird.fragments ? kube-cluster-rke2;
      fragmentHasCilium = lib.hasInfix "protocol bgp rke2_cilium" alphaTransport.clan.bird.fragments.kube-cluster-rke2.config;
      fragmentStrictBind = lib.hasInfix "strict bind on;" alphaTransport.clan.bird.fragments.kube-cluster-rke2.config;
      linkUnit = alphaTransport.systemd.services ? kube-cluster-rke2-bgp-link;
      birdOrderedAfter = lib.elem "kube-cluster-rke2-bgp-link.service" alphaTransport.systemd.services.bird.after;
      firewallDrop4179 = lib.hasInfix "tcp dport 4179 drop" alphaTransport.networking.firewall.extraInputRules;
      checkConfig = alphaTransport.services.bird.checkConfig;
      agentBird = gammaTransport.services.bird.enable;
      agentRouterId = gammaTransport.clan.bird.routerId;
    };
    expected = {
      birdEnabled = true;
      bird2Package = true;
      routerId = "10.42.0.1";
      fragmentKey = true;
      fragmentHasCilium = true;
      fragmentStrictBind = true;
      linkUnit = true;
      birdOrderedAfter = true;
      firewallDrop4179 = true;
      checkConfig = true;
      agentBird = true;
      agentRouterId = "10.42.0.3";
    };
  };

  # §6.12: disabling the fabric while leaving bgp.enable on is an eval error.
  test_bgpCouplingServiceAssertion = {
    expr =
      let
        bad = mkEvaled (
          lib.recursiveUpdate transportInventory {
            instances.rke2.roles.server.settings.fabric.enable = false;
          }
        );
      in
      failedAssertion bad.config.nixosConfigurations.alpha.config "BGP only for shared-bgp pools";
    expected = true;
  };

  # D19: a second, conflicting routerId on the same host is an eval error.
  test_routerIdConflictThrows = {
    expr =
      let
        conflicted = clanLib.clan {
          self = { };
          directory = ./fixtures;
          inherit exportInterfaces;
          imports = [ kube.fleetChecksModule ];
          modules = {
            wireguard-mesh = wgModule;
            rke2 = rke2Module;
          };
          machines = machineConfigs // {
            alpha = {
              nixpkgs.hostPlatform = "x86_64-linux";
              clan.bird.routerId = "192.0.2.99";
            };
          };
          inventory = transportInventory;
        };
      in
      !(builtins.tryEval (builtins.deepSeq conflicted.config true)).success;
    expected = true;
  };

  # The export's phase-5 facts (schema v2).
  test_kubeClusterExportBgpFabric = {
    expr = {
      inherit (kubeClusterExport.bgp)
        enabled
        ciliumAsn
        birdAsn
        upstreamPeers
        ;
      inherit (kubeClusterExport) fabric;
      fabricPoolDelivery = kubeClusterExport.pools.rke2-fabric.delivery;
    };
    expected = {
      enabled = true;
      ciliumAsn = 4200812391;
      birdAsn = 4226982861;
      upstreamPeers = [ ];
      fabric = {
        enabled = true;
        pool = "rke2-fabric";
        ipv4Block = "172.16.1.0/24";
        ipv6Block = "fd11:1::/64";
        coreDNS = {
          ipv4 = "172.16.1.53";
          ipv6 = "fd11:1:0:0:0:0:0:53";
          svcZone = "";
          podZone = "";
          zone = "rke2.clan";
        };
      };
      fabricPoolDelivery = "shared-bgp";
    };
  };
}
