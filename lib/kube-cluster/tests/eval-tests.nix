{
  lib,
  inputs,
  pkgs,
}:
let
  kube = import ../default.nix { inherit lib; };
  clanLib = inputs.clan-core.lib;

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
          config = lib.recursiveUpdate baseConfig extraConfig;
        })
      ];
    }).config;

  baseSettings = evalSettings { };

  transportFacts = {
    interface = "wg-mesh";
    mtu = 1420;
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

  manifestLabels = kube.render.mkManifestLabels { inherit instanceName; };

  mkTestBundle =
    settings:
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
      pools = kube.render.resolvePools { inherit settings members; };
      podIPCidr = "10.1.0.0/16,fd10:1::/56";
      clusterDNS = "10.2.0.10";
      coreDNSImage = "${corednsVersions.repo}:${corednsVersions.tag}@${corednsVersions.digest}";
      k8sServiceHost = "kubeapi-test.example.org";
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

  # Hand-built kube_cluster exports for the fleet checks (the applied
  # exports tree shape: scope string -> { kube_cluster = { ... }; }).
  mkKubeExport =
    {
      name,
      ciliumId,
      meshGroup ? "clan",
      transportService ? "wireguard-mesh",
      transportInstance ? "mesh",
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
      };
      controlDomain.role = "standalone";
      transport = {
        service = transportService;
        instance = transportInstance;
      };
      members = { };
      pools = { };
      schemaVersion = 1;
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
      transportInstance = "mesh-b";
      podCIDRv4 = "10.3.0.0/16";
      podCIDRv6 = "fd10:3::/56";
      serviceCIDRv4 = "10.4.0.0/16";
      serviceCIDRv6 = "fd10:4::/112";
    };
  };

  fleetChecksPass = kube.mkFleetChecks clanLib fleetExportsSeparateGroupsPass;
  fleetExportsSeparateGroupsPass = fleetExportsCidrSeparateGroups;
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

  # Per-cluster identity + KPR endpoint land in the bundle.
  test_bundleClusterIdentityAndKpr = {
    expr =
      let
        ds = findObj "DaemonSet" "cilium";
        agentContainer = lib.findFirst (c: c.name == "cilium") null ds.spec.template.spec.containers;
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
          tunnel-protocol
          ;
        inherit envHost envPort;
      };
    expected = {
      cluster-name = "test";
      cluster-id = "1";
      routing-mode = "tunnel";
      tunnel-protocol = "vxlan";
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
      metadata = {
        name = "probe";
        namespace = "kube-system";
        labels = manifestLabels;
      };
      spec = {
        type = "LoadBalancer";
        externalTrafficPolicy = "Local";
        loadBalancerClass = "io.cilium/lb-ipam";
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
      failedAssertion assertions "network.transport is null";
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
        network.podCIDRv4 = "172.16.0.0/16";
        network.serviceCIDRv4 = "172.17.0.0/16";
      };
      roleMembers = oneServer;
    }) "above 127";
    expected = false;
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

  # --- all-or-none transport posture (§6.3) -------------------------------

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
              transport = {
                service = "wireguard-mesh";
                instance = "mesh";
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
              transport = null;
              ipv4 = "10.0.0.2";
              ipv6 = "fd00::2";
            };
          };
        }
      ];
    }) "all-or-none transport posture";
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
            network.transport = {
              service = "wireguard-mesh";
              instance = "mesh";
            };
          };
        }
        {
          machineName = "beta";
          role = "agent";
          settings = {
            clusterInit = false;
            network.transport = {
              service = "wireguard-mesh";
              instance = "mesh";
            };
          };
        }
      ];
    }) "no export from the configured node_transport source";
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
            network.transport = {
              service = "wireguard-mesh";
              instance = "mesh";
            };
          };
        }
        {
          machineName = "beta";
          role = "agent";
          settings = {
            clusterInit = false;
            network.transport = {
              service = "wireguard-mesh";
              instance = "mesh";
            };
          };
        }
      ];
    }) "transport posture";
    expected = false;
  };

  # --- fleet checks (§6.2, D16/D33) ----------------------------------------

  test_fleetChecksCleanTreePasses = {
    expr = lib.mapAttrs (_: c: c.assertion) fleetChecksPass;
    expected = {
      kube-cluster-meshed-cidr-overlap = true;
      kube-cluster-mesh-group-transport = true;
      kube-cluster-node-in-two-clusters = true;
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

  test_fleetCheckMeshGroupTransportConsistency = {
    expr =
      let
        check = (kube.mkFleetChecks clanLib fleetExportsTransportMixed).kube-cluster-mesh-group-transport;
      in
      {
        inherit (check) assertion;
        namesInstances = lib.hasInfix "mesh-b" check.message;
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
}
