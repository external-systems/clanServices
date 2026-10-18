{ lib }:
let
  rancher = import ../default.nix { inherit lib; };

  # Minimal valid cluster settings for rendering tests.
  domain = "example.org";
  baseConfig = {
    inherit domain;
    network = {
      transport = null;
      podCIDRv4 = null;
      podCIDRv6 = null;
      serviceCIDRv4 = null;
      serviceCIDRv6 = null;
    };
    cilium = {
      id = 1;
      helmValues = { };
    };
    traefik = {
      enabled = true;
      instances = {
        traefik = { };
      };
    };
    certManager = {
      enabled = true;
      helmValues = { };
      certificates = [ ];
    };
    coredns = {
      rewrites = [ ];
      helmValues = { };
    };
    packages = {
      ciliumChart = null;
      traefikChart = null;
      certManagerChart = null;
      gatewayApiCrds = null;
      images = [ ];
    };
  };

  # Evaluate the cluster interface so option defaults are applied.
  evalSettings =
    extraConfig:
    (lib.evalModules {
      modules = [
        rancher.interfaces.cluster
        (_: {
          config = lib.recursiveUpdate baseConfig extraConfig;
        })
      ];
    }).config;

  baseSettings = evalSettings { };

  transportFacts = {
    interface = "wg-mesh";
    mtu = 1420;
  };

  members = [
    "alpha"
    "beta"
  ];

  instanceName = "test";

  ciliumValues = rancher.render.mkCiliumValues {
    settings = baseSettings;
    inherit transportFacts instanceName;
    k8sServiceHost = "kubeapi-test.example.org";
    k8sServicePort = 6443;
  };

  ciliumManifests = rancher.render.mkCiliumManifests {
    settings = baseSettings;
  };

  traefikInstances = rancher.render.mkTraefikInstances {
    settings = baseSettings;
    inherit members;
  };

  traefikValues = rancher.render.mkTraefikValues {
    instance = builtins.head traefikInstances;
  };

  gatewayTraefikInstances = rancher.render.mkTraefikInstances {
    settings = evalSettings {
      traefik.instances.ingress = {
        gatewayAPI.enabled = true;
      };
    };
    inherit members;
  };

  gatewayTraefikManifests = rancher.render.mkTraefikManifests {
    instances = gatewayTraefikInstances;
    inherit domain;
    manifestLabels = rancher.render.mkManifestLabels { inherit instanceName; };
  };

  certManagerManifests = rancher.render.mkCertManagerManifests {
    settings = baseSettings;
    inherit domain;
    manifestLabels = rancher.render.mkManifestLabels { inherit instanceName; };
  };

  corednsValues = rancher.render.mkCoreDNSValues {
    settings = evalSettings {
      coredns.rewrites = [ "name suffix svc.test.cluster svc.cluster.local answer auto" ];
    };
  };

  # Assertion helpers.
  failedAssertion =
    assertions: needle: lib.any (item: !item.assertion && lib.hasInfix needle item.message) assertions;

  dualGatewaySettings = evalSettings {
    traefik.instances = {
      a = {
        gatewayAPI.enabled = true;
      };
      b = {
        gatewayAPI.enabled = true;
      };
    };
  };

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
          ipv4 = "10.0.0.2";
          ipv6 = "fd00::2";
        };
      };
    }
  ];

  dualGatewayAssertions = rancher.assertions.mkClusterAssertions {
    inherit
      instanceName
      roleMembers
      members
      domain
      transportFacts
      ;
    settings = dualGatewaySettings;
  };

  # A fake package for the missing-package assertion test.
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
in
{
  test_ciliumValues_tunnelAndMtu = {
    expr = {
      inherit (ciliumValues)
        routingMode
        tunnelProtocol
        kubeProxyReplacement
        MTU
        ;
      inherit (ciliumValues.cluster) name id;
    };
    expected = {
      routingMode = "tunnel";
      tunnelProtocol = "vxlan";
      kubeProxyReplacement = true;
      MTU = 1370;
      name = "test";
      id = 1;
    };
  };

  test_ciliumValues_nodeIpamOffByDefault = {
    expr = ciliumValues.nodeIPAM.enabled;
    expected = false;
  };

  test_ciliumValues_nodeIpamOnWhenLoadBalancerClassSet = {
    expr =
      (rancher.render.mkCiliumValues {
        settings = evalSettings {
          traefik.instances.traefik.service.loadBalancerClass = "io.cilium/node";
        };
        inherit transportFacts instanceName;
        k8sServiceHost = "kubeapi-test.example.org";
        k8sServicePort = 6443;
      }).nodeIPAM.enabled;
    expected = true;
  };

  test_ciliumManifestsCidrDerivation = {
    expr = {
      ipv4 = (builtins.head ciliumManifests).spec.ipv4.cidrs;
      ipv6 = (builtins.head ciliumManifests).spec.ipv6.cidrs;
    };
    expected = {
      ipv4 = [ "10.1.0.0/16" ];
      ipv6 = [ "fd10:1::/56" ];
    };
  };

  test_ciliumManifestsCidrDerivationId2 = {
    expr =
      let
        manifests = rancher.render.mkCiliumManifests {
          settings = baseSettings // {
            cilium.id = 2;
          };
        };
      in
      {
        ipv4 = (builtins.head manifests).spec.ipv4.cidrs;
        ipv6 = (builtins.head manifests).spec.ipv6.cidrs;
      };
    expected = {
      ipv4 = [ "10.3.0.0/16" ];
      ipv6 = [ "fd10:3::/56" ];
    };
  };

  test_traefikInstanceDefaults = {
    expr =
      let
        i = builtins.head traefikInstances;
      in
      {
        inherit (i) namespace workloadKind defaultCertRendered;
        inherit (lib.findFirst (ep: ep.epName == "web") null i.entrypoints) containerPort;
        inherit (lib.findFirst (ep: ep.epName == "websecure") null i.entrypoints) servicePort;
      };
    expected = {
      namespace = "traefik";
      workloadKind = "daemonset";
      defaultCertRendered = false;
      containerPort = 8000;
      servicePort = 443;
    };
  };

  test_traefikValuesHasFullnameOverride = {
    expr = traefikValues.fullnameOverride;
    expected = "traefik";
  };

  test_traefikValuesWebDefaults = {
    expr = traefikValues.ports.web;
    expected = {
      port = 8000;
      hostPort = null;
      expose.default = true;
      exposedPort = 80;
      protocol = "TCP";
    };
  };

  test_traefikManifestsDefaultCertificate = {
    expr =
      let
        cert = gatewayTraefikManifests.certificates."ingress-gateway-tls".content;
      in
      {
        inherit (cert.spec) secretName dnsNames;
        issuerName = cert.spec.issuerRef.name;
      };
    expected = {
      secretName = "ingress-gateway-tls";
      dnsNames = [
        "example.org"
        "*.example.org"
      ];
      issuerName = "rancher-ca";
    };
  };

  test_certManagerBootstrap = {
    expr = map (m: m.kind) certManagerManifests;
    expected = [
      "ClusterIssuer"
      "Certificate"
      "ClusterIssuer"
    ];
  };

  test_corednsValuesHasRewriteImport = {
    expr = corednsValues.servers != null;
    expected = true;
  };

  test_gatewayApiSingletonAssertion = {
    expr = failedAssertion dualGatewayAssertions "at most one traefik.instances entry";
    expected = true;
  };

  test_missingClusterInitAssertion = {
    expr =
      let
        assertions = rancher.assertions.mkClusterAssertions {
          inherit
            instanceName
            members
            domain
            transportFacts
            ;
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
        assertions = rancher.assertions.mkClusterAssertions {
          inherit instanceName members domain;
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
      failedAssertion assertions "network.transport is null";
    expected = true;
  };

  test_tokenGeneratorNames = {
    expr =
      let
        tokens = rancher.vars.mkTokenGenerators {
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
        pki = rancher.vars.mkPkiGenerator {
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
          (rancher.vars.mkHaproxyGenerator {
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
          (rancher.vars.mkAdminKubeconfigGenerator {
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

  test_sealedSecretsGenerator = {
    expr =
      let
        gen =
          (rancher.vars.mkSealedSecretsGenerator {
            pkgs = {
              openssl = fakePackage;
            };
            inherit instanceName;
            labels = {
              "app.kubernetes.io/managed-by" = "clan";
            };
          })."rancher-sealed-secrets-${instanceName}";
      in
      {
        inherit (gen) share;
        crtPublic = !(gen.files."tls.crt".secret or true);
        keySecret = gen.files."tls.key".secret or true;
        manifestHasLabel = lib.hasInfix "sealedsecrets.bitnami.com/sealed-secrets-key: active" gen.script;
      };
    expected = {
      share = true;
      crtPublic = true;
      keySecret = true;
      manifestHasLabel = true;
    };
  };

  test_haproxyConfigRender = {
    expr =
      let
        cfg = rancher.render.mkHaproxyConfig {
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
        frag = rancher.nixos.mkPkiSync {
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
    expr = rancher.render.mkManifestLabels { inherit instanceName; };
    expected = {
      "app.kubernetes.io/managed-by" = "clan";
      "clan.lol/rancher-cluster" = "core-component";
      "clan.lol/cluster" = "test";
    };
  };
}
