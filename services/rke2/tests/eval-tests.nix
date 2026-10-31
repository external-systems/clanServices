{
  lib,
  module,
  clanLib,
  exportInterfaces,
  self,
  inputs,
  ...
}: let
  rke2Module = module;
  k3sModule = lib.modules.importApply ../../k3s/default.nix {inherit self inputs;};
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
      rke2 = {
        module.name = "rke2";
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
  # packaged components (D42).
  stockInventory = lib.recursiveUpdate explicitInventory {
    instances.rke2.roles.server.settings.distroDefaults.enable = true;
  };
  stockEvaled = mkEvaled stockInventory;
  alphaStock = stockEvaled.config.nixosConfigurations.alpha.config;

  failedAssertion = machineConfig: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) machineConfig.assertions;

  # The rendered bootstrap bundle on the clusterInit node (D40).
  bundleObjs = builtins.fromJSON alphaTransport.clan.kubeClusters.rke2.bundleJson;
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
  # schemaVersion 2 seam — rke2 must consume it with NO provider branching.
  # Native profile (local-router exchange, both exposure capabilities) with
  # per-link MTUs to exercise the minimum-MTU derivation.
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
      rke2-a = {
        module.name = "rke2";
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
      rke2-b = {
        module.name = "rke2";
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

  fakeBundleObjs = builtins.fromJSON alphaFake.clan.kubeClusters.rke2-a.bundleJson;
  fakeFindObj = kind: name: lib.findFirst (o: o.kind == kind && o.metadata.name == name) null fakeBundleObjs;
  fakeCiliumConfigData = (fakeFindObj "ConfigMap" "cilium-config").data;
  fakeUsers = (fakeFindObj "ConfigMap" "clustermesh-remote-users").data."users.yaml";
  fakeApiserverDeploy = fakeFindObj "Deployment" "clustermesh-apiserver";
  fakeApiserverSvc = fakeFindObj "Service" "clustermesh-apiserver";
  fakeClustermeshSecret = fakeFindObj "Secret" "cilium-clustermesh";

  fakeExportOf = instanceName:
    (clanLib.getExport {
        serviceName = "rke2";
        inherit instanceName;
        roleName = "server";
        machineName =
          if instanceName == "rke2-a"
          then "alpha"
          else "gamma";
      }
      fakeEvaled.config.exports).kube_cluster;

  # One-directional selective peers: the symmetry fleet check throws at
  # clan eval.
  fakeAsymmetricEvaled = mkEvaled {
    instances = {
      fabric = fakeInventory.instances.fabric;
      rke2-a = {
        module.name = "rke2";
        module.input = "self";
        roles.server = {
          settings = {
            network.fabric = {
              service = "fake-transport";
              instance = "fabric";
            };
            cilium.id = 1;
            mesh.peers = ["rke2-b"];
          };
          machines = {
            alpha.settings.clusterInit = true;
            beta.settings.clusterInit = false;
          };
        };
      };
      rke2-b = {
        module.name = "rke2";
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

  # Contradicting admin overrides on the fake transport must eval-fail.
  fakeContradictionEvaled = mkEvaled {
    instances = {
      fabric = fakeInventory.instances.fabric;
      rke2-a = {
        module.name = "rke2";
        module.input = "self";
        roles.server = {
          settings = {
            network.fabric = {
              service = "fake-transport";
              instance = "fabric";
            };
            cilium.id = 1;
            cilium.helmValues.MTU = 9000;
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
      "rancher-clustermesh-ca-clan"
      "rancher-clustermesh-rke2"
      "rancher-haproxy-rke2"
      "rancher-pki-rke2"
      "rancher-server-token-rke2"
      "state-version"
    ];
  };

  test_generatorNamesAgentNoPki = {
    # Agents get the join tokens, the haproxy healthcheck material, and
    # the mesh material (CA + apiserver leaf set — SANs are eval-computed),
    # but NEVER the PKI / admin kubeconfig generators.
    expr = builtins.attrNames gammaTransport.clan.core.vars.generators;
    expected = [
      "rancher-agent-token-rke2"
      "rancher-clustermesh-ca-mesh"
      "rancher-clustermesh-rke2"
      "rancher-haproxy-rke2"
      "rancher-server-token-rke2"
      "state-version"
      "wireguard-mesh-mesh"
      "wireguard-mesh-mesh-node"
      "wireguard-mesh-mesh-prefixes"
      "wireguard-mesh-mesh-ula"
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
      oneshotRetries = let
        u = alphaTransport.systemd.services.rke2-rke2-bootstrap-apply;
      in
        u.serviceConfig.Type
        == "oneshot"
        && u.serviceConfig.Restart == "on-failure"
        && u.unitConfig.StartLimitIntervalSec == 0
        && u.after == ["rke2-server.service"];
      noManifests = alphaTransport.services.rke2.manifests == {};
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
    expr = let
      unit = alphaTransport.systemd.services.kube-cluster-rke2-image-digest-aliases or null;
      agentUnit = gammaTransport.systemd.services.kube-cluster-rke2-image-digest-aliases or null;
      aliases =
        if unit == null
        then [{alias = "";}]
        else unit.serviceConfig.ExecStart.passthru.aliases;
    in {
      serverHasUnit = unit != null;
      agentHasUnit = agentUnit != null;
      # 4 Cilium images + 1 clan CoreDNS, every alias in name@digest form
      aliasesPinnedDigests =
        builtins.length aliases == 5 && lib.all (a: lib.hasInfix "@sha256:" a.alias) aliases;
      serverAfterRuntime = unit == null || unit.after == ["rke2-server.service"];
      agentAfterRuntime = agentUnit == null || agentUnit.after == ["rke2-agent.service"];
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
    expr = let
      bad = mkEvaled {
        instances.rke2 = {
          module.name = "rke2";
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
      alphaPool = kubeClusterExport.pools.alpha;
    };
    expected = {
      schemaVersion = 4;
      name = "rke2";
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
      ];
      alphaPool = {
        blocks = [
          "10.42.0.1/32"
          "fd10:42::1/128"
        ];
        serviceSelector."clan.lol/pool" = "alpha";
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
    expr = failedAssertion postureEvaled.config.nixosConfigurations.alpha.config "no export from the configured fabric source";
    expected = true;
  };

  # --- D16: one cluster per node, across distro services ---------------------

  test_nodeInTwoClustersCrossServiceThrows = {
    expr = !(builtins.tryEval (builtins.deepSeq dualClaimEvaled.config true)).success;
    expected = true;
  };

  # --- phase 5: BGP / fabric / BIRD (D9/D10/D19/D22) ---------------------------

  # The native third-party transport renders the BGP v2 resource set.
  test_bgpResourcesInBundle = {
    expr = let
      ccAlpha = fakeFindObj "CiliumBGPClusterConfig" "rke2-a-alpha";
      ccBeta = fakeFindObj "CiliumBGPClusterConfig" "rke2-a-beta";
      ccGamma = fakeFindObj "CiliumBGPClusterConfig" "rke2-a-gamma";
      pc = fakeFindObj "CiliumBGPPeerConfig" "rke2-a-alpha-frr";
      adv = fakeFindObj "CiliumBGPAdvertisement" "rke2-a-alpha-service-vips";
      podAdv = fakeFindObj "CiliumBGPAdvertisement" "rke2-a-alpha-pod-pools";
      instance = builtins.head ccAlpha.spec.bgpInstances;
      fabricPool = fakeFindObj "CiliumLoadBalancerIPPool" "rke2-a-fabric";
    in {
      perNode = ccAlpha != null && ccBeta != null && ccGamma == null;
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
      podAdvType = (builtins.head podAdv.spec.advertisements).advertisementType;
      podAdvSelector = (builtins.head podAdv.spec.advertisements).selector.matchLabels;
      noClusterIpAdvert = fakeFindObj "CiliumBGPAdvertisement" "rke2-a-alpha-cluster-ips" == null;
    };
    expected = {
      perNode = true;
      selector = "alpha";
      asns = {
        local = 4268898264;
        peer = 4258224172;
      };
      dialOut = "::1";
      noListener = true;
      podAdvType = "CiliumPodIPPool";
      podAdvSelector."clan.lol/cluster" = "rke2-a";
      timers = {
        holdTimeSeconds = 9;
        keepAliveTimeSeconds = 3;
        connectRetryTimeSeconds = 5;
      };
      fabricBlocks = [
        {cidr = "172.16.1.0/24";}
        {cidr = "fd11:1::/64";}
      ];
      advPools = [
        {
          key = "clan.lol/pool";
          operator = "In";
          values = ["rke2-a-fabric"];
        }
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
    expr = !(alphaTransport.systemd.services ? kube-cluster-rke2-bgp-link);
    expected = true;
  };

  # §6.12: disabling the fabric while leaving bgp.enable on is an eval error.
  test_bgpCouplingServiceAssertion = {
    expr = let
      bad = mkEvaled (
        lib.recursiveUpdate fakeInventory {
          instances.rke2-a.roles.server.settings.fabric.enable = false;
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
          instances.rke2-a.roles.server.settings.bgp.ciliumASN = 4258224173;
        }
      );
      badAlpha = bad.config.nixosConfigurations.alpha.config;
    in {
      fired = failedAssertion badAlpha "accidental iBGP";
      namesCluster = failedAssertion badAlpha "kube-cluster/rke2-a";
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
          instances.rke2-a.roles.server.machines = {
            alpha.settings.bgp.hostASN = 4258224172;
            beta.settings.bgp.hostASN = 4268898264;
          };
        }
      );
      badAlpha = bad.config.nixosConfigurations.alpha.config;
    in {
      fired = failedAssertion badAlpha "bgp.hostASN must match the local-router transport ASN";
      namesMachine = failedAssertion badAlpha "machine beta";
      namesPin = failedAssertion badAlpha "pins 4268898264";
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
          instances.rke2-a.roles.server.machines = {
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

  # D19 revised: ONE dual-AF `::1` session to the node-local FRR, no
  # localPort (timers pinned per D9/D55).
  test_localFrrSessionShape = {
    expr = let
      find = kind: name: lib.findFirst (o: o.kind == kind && o.metadata.name == name) null fakeBundleObjs;
      instance = builtins.head (find "CiliumBGPClusterConfig" "rke2-a-alpha").spec.bgpInstances;
      peer = builtins.head instance.peers;
      pc = find "CiliumBGPPeerConfig" "rke2-a-alpha-frr";
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
      peerRef = "rke2-a-alpha-frr";
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
      fabricPoolAbsent = !(kubeClusterExport.pools ? rke2-fabric);
    };
    expected = {
      enabled = false;
      ciliumAsn = 4200812391;
      hostAsn = 4253360446;
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
    expr = alphaFake.services.rke2.nodeIP;
    expected = "192.168.77.1,fd77::1";
  };

  test_fakeTransportDerivedProfile = {
    expr = {
      routing = fakeCiliumConfigData."routing-mode";
      autoDirect = fakeCiliumConfigData."auto-direct-node-routes";
      directDevice = fakeCiliumConfigData."direct-routing-device";
      # Devices cover EVERY member's datapath interfaces; the MTU is the
      # cluster-wide minimum (beta's 1400-underlay link derives 1300).
      devices = fakeCiliumConfigData."devices";
      mtu = fakeCiliumConfigData."mtu";
    };
    expected = {
      routing = "native";
      autoDirect = "false";
      directDevice = "fk-alpha-1";
      devices = "fk-alpha-1 fk-alpha-2 fk-beta-1 fk-beta-2";
      mtu = "1300";
    };
  };

  test_fakeTransportExportFacts = {
    expr = {
      a = {
        inherit (fakeExportOf "rke2-a") meshGroup datapath;
        exposure = (fakeExportOf "rke2-a").mesh.exposure;
      };
      bExposure = (fakeExportOf "rke2-b").mesh.exposure;
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
      peersEndpoints = fakeClustermeshSecret.stringData."rke2-b" or null;
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
      users = "users:\n- name: remote-rke2-b\n  role: remote\n";
      peersKeyPresent = true;
      peersEndpoints = "endpoints:\n- https://172.16.2.79:2379\ntrusted-ca-file: /var/lib/cilium/clustermesh/common-etcd-client-ca.crt\nkey-file: /var/lib/cilium/clustermesh/common-etcd-client.key\ncert-file: /var/lib/cilium/clustermesh/common-etcd-client.crt";
      clustermeshEnable = "true";
    };
  };

  test_clustermeshReverseBundleRendering = {
    expr = let
      objs = builtins.fromJSON gammaFake.clan.kubeClusters.rke2-b.bundleJson;
      secret = lib.findFirst (o: o.kind == "Secret" && o.metadata.name == "cilium-clustermesh") null objs;
      users =
        (lib.findFirst (
            o: o.kind == "ConfigMap" && o.metadata.name == "clustermesh-remote-users"
          )
          null
          objs).data."users.yaml";
    in {
      endpoints = secret.stringData."rke2-a" or null;
      inherit users;
    };
    expected = {
      endpoints = "endpoints:\n- https://172.16.1.79:2379\ntrusted-ca-file: /var/lib/cilium/clustermesh/common-etcd-client-ca.crt\nkey-file: /var/lib/cilium/clustermesh/common-etcd-client.key\ncert-file: /var/lib/cilium/clustermesh/common-etcd-client.crt";
      users = "users:\n- name: remote-rke2-a\n  role: remote\n";
    };
  };

  test_clustermeshSecretsUnit = {
    expr = {
      initHasUnit = alphaFake.systemd.services ? rke2-rke2-a-clustermesh-secrets;
      afterBootstrap =
        alphaFake.systemd.services.rke2-rke2-a-clustermesh-secrets.after
        == [
          "rke2-server.service"
          "rke2-rke2-a-bootstrap-apply.service"
        ];
      nonInitNoUnit = !(gammaFake.systemd.services ? rke2-rke2-a-clustermesh-secrets);
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

  test_clustermeshAsymmetricPeersRejected = {
    expr = !(builtins.tryEval (builtins.deepSeq fakeAsymmetricEvaled.config true)).success;
    expected = true;
  };

  test_forwardingFact = {
    expr = alphaExplicit.clan.networkFacts.forwarding;
    expected = true;
  };

  test_fakeTransportContradictingOverridesRejected = {
    expr = !(builtins.tryEval (builtins.deepSeq fakeContradictionEvaled.config true)).success;
    expected = true;
  };
}
