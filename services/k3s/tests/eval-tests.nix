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
      k3s = {
        module.name = "k3s";
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

  # Extract the Cilium HelmChart valuesContent for inspection.
  alphaManifests = alphaTransport.services.k3s.manifests;
  ciliumConfigContent = builtins.fromJSON alphaManifests.cilium.content.spec.valuesContent;

  # The rendered config.yaml (via the environment.etc source derivation is
  # not directly inspectable; the nixpkgs module mirrors the join URL into
  # serverAddr and the token files into tokenFile).
  alphaHaproxyConfig = alphaTransport.services.haproxy.config;
  gammaHaproxyConfig = gammaTransport.services.haproxy.config;

  # A cluster with two clusterInit servers should fail.
  dualInitInventory = lib.recursiveUpdate explicitInventory {
    instances.k3s.roles.server.machines.beta.settings.clusterInit = true;
  };
  dualInitEvaled = mkEvaled dualInitInventory;
  alphaDualInit = dualInitEvaled.config.nixosConfigurations.alpha.config;
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
      k8sServiceHost = "kubeapi-k3s.clan";
      k8sServicePort = 7443;
    };
  };

  test_ciliumValuesClusterCidrs = {
    expr = ciliumConfigContent.global;
    expected = {
      clusterCIDRv4 = "10.1.0.0/16";
      clusterCIDRv6 = "fd10:1::/56";
    };
  };

  test_ciliumBootstrapAndStaticChart = {
    expr = {
      inherit (alphaManifests.cilium.content.spec) bootstrap chart;
      staticChart = alphaTransport.services.k3s.charts ? cilium;
    };
    expected = {
      bootstrap = true;
      chart = "https://127.0.0.1:6443/static/charts/cilium.tgz";
      staticChart = true;
    };
  };

  test_ciliumNodeIpamDefault = {
    expr = {
      inherit (ciliumConfigContent) defaultLBServiceIPAM;
      inherit (ciliumConfigContent.nodeIPAM) enabled;
    };
    expected = {
      defaultLBServiceIPAM = "nodeipam";
      enabled = true;
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
}
