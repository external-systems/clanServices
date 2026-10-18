{
  lib,
  module,
  clanLib,
  exportInterfaces,
  ...
}:
let
  rke2Module = module;
  wgModule = ../../wireguard-mesh/default.nix;

  machineConfigs = lib.genAttrs [ "alpha" "beta" "gamma" ] (_: {
    nixpkgs.hostPlatform = "x86_64-linux";
  });

  mkEvaled =
    inventory:
    clanLib.clan {
      self = { };
      directory = ./fixtures;
      inherit exportInterfaces;
      modules = {
        wireguard-mesh = wgModule;
        rke2 = rke2Module;
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
        settings.network.transport = null;
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
          settings.network.transport = {
            service = "wireguard-mesh";
            instance = "mesh";
          };
          machines = {
            alpha.settings.clusterInit = true;
            beta.settings.clusterInit = false;
          };
        };
        roles.agent = {
          settings.network.transport = {
            service = "wireguard-mesh";
            instance = "mesh";
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

  # Sealed Secrets enabled (single server, explicit addresses).
  sealedInventory = {
    instances.rke2 = {
      module.name = "rke2";
      module.input = "self";
      roles.server = {
        settings = {
          network.transport = null;
          sealedSecrets.enabled = true;
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
  sealedEvaled = mkEvaled sealedInventory;
  alphaSealed = sealedEvaled.config.nixosConfigurations.alpha.config;

  gatewayInventory = lib.recursiveUpdate explicitInventory {
    instances.rke2.roles.server.settings.traefik.instances.rke2-traefik.gatewayAPI.enabled = true;
  };
  gatewayEvaled = mkEvaled gatewayInventory;
  alphaGateway = gatewayEvaled.config.nixosConfigurations.alpha.config;

  failedAssertion =
    machineConfig: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) machineConfig.assertions;

  # Extract the rke2-cilium HelmChartConfig valuesContent for inspection.
  alphaManifests = alphaTransport.services.rke2.manifests;
  ciliumConfigContent = builtins.fromJSON alphaManifests.rke2-cilium-config.content.spec.valuesContent;

  # The rendered config.yaml (via the environment.etc source derivation is
  # not directly inspectable; the nixpkgs module mirrors the join URL into
  # serverAddr and the token files into tokenFile).
  alphaHaproxyConfig = alphaTransport.services.haproxy.config;
  gammaHaproxyConfig = gammaTransport.services.haproxy.config;

  # A cluster with two clusterInit servers should fail.
  dualInitInventory = lib.recursiveUpdate explicitInventory {
    instances.rke2.roles.server.machines.beta.settings.clusterInit = true;
  };
  dualInitEvaled = mkEvaled dualInitInventory;
  alphaDualInit = dualInitEvaled.config.nixosConfigurations.alpha.config;

  # A cluster with two gatewayAPI-enabled Traefik instances should fail.
  dualGatewayInventory = lib.recursiveUpdate explicitInventory {
    instances.rke2.roles.server.settings.traefik.instances = {
      rke2-traefik = {
        gatewayAPI.enabled = true;
      };
      extra = {
        gatewayAPI.enabled = true;
      };
    };
  };

  dualGatewayEvaled = mkEvaled dualGatewayInventory;
  alphaDualGateway = dualGatewayEvaled.config.nixosConfigurations.alpha.config;
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
    # NEVER the PKI / admin kubeconfig / sealed-secrets generators.
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
    expr = ciliumConfigContent.routingMode;
    expected = "tunnel";
  };

  test_ciliumValuesKubeProxyReplacement = {
    expr = ciliumConfigContent.kubeProxyReplacement;
    expected = true;
  };

  test_ciliumValuesMtu = {
    expr = ciliumConfigContent.MTU;
    expected = 1370;
  };

  test_ciliumValuesApiViaLocalHaproxy = {
    expr = {
      inherit (ciliumConfigContent) k8sServiceHost k8sServicePort;
    };
    expected = {
      k8sServiceHost = "kubeapi-rke2.clan";
      k8sServicePort = 7443;
    };
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

  test_sealedSecretsWiring = {
    # Note: autoDeployCharts has an apply that maps each chart to its
    # rendered HelmChart manifest attrs (target/enable/package/source).
    expr = {
      generator = alphaSealed.clan.core.vars.generators ? rancher-sealed-secrets-rke2;
      syncUnit = alphaSealed.systemd.services ? rke2-rke2-sealed-secrets-sync;
      chart = alphaSealed.services.rke2.autoDeployCharts ? sealed-secrets;
      chartEnabled = alphaSealed.services.rke2.autoDeployCharts.sealed-secrets.enable;
    };
    expected = {
      generator = true;
      syncUnit = true;
      chart = true;
      chartEnabled = true;
    };
  };

  test_sealedSecretsOffByDefault = {
    expr = {
      generator = alphaTransport.clan.core.vars.generators ? rancher-sealed-secrets-rke2;
      syncUnit = alphaTransport.systemd.services ? rke2-rke2-sealed-secrets-sync;
      chart = alphaTransport.services.rke2.autoDeployCharts ? sealed-secrets;
    };
    expected = {
      generator = false;
      syncUnit = false;
      chart = false;
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

  test_gatewayApiCrdSources = {
    expr = {
      replacementChart = alphaGateway.services.rke2.autoDeployCharts ? traefik-crd;
      pinnedManifest = alphaGateway.services.rke2.manifests ? gateway-api-crds;
    };
    expected = {
      replacementChart = true;
      pinnedManifest = true;
    };
  };

  test_certManagerBootstrapManifest = {
    expr = map (m: m.kind) alphaManifests.cert-manager-bootstrap.content;
    expected = [
      "ClusterIssuer"
      "Certificate"
      "ClusterIssuer"
    ];
  };

  test_defaultGatewayCertificateAbsentWithoutGatewayApi = {
    expr = alphaManifests ? "traefik-cert-rke2-traefik-gateway-tls";
    expected = false;
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
              settings.network.transport = null;
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

  test_dualGatewayAssertion = {
    expr = failedAssertion alphaDualGateway "at most one traefik.instances entry";
    expected = true;
  };
}
