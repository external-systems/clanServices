# The kubenix bootstrap bundle renderer (D26 layer 2, D40).
#
# mkBundle produces, per cluster instance, ONE multi-document YAML bundle:
# the artifact flake's committed Cilium base manifest (imported with the
# pure-Nix YAML subset parser — zero IFD, D26) merged with per-cluster
# variation in kubenix's typed resource tree, plus the clan-rendered CRs
# (CiliumPodIPPool, CiliumLoadBalancerIPPool, coredns-custom ConfigMap).
#
# Per-cluster variation lands as module merges over the imported objects:
# the cilium-config ConfigMap data, the agent/operator KUBERNETES_SERVICE_*
# env (KPR endpoint), operator replicas, and the CRs. Helm values are never
# re-run (that would be IFD); `cilium.helmValues` is the admin override
# hatch, merged into the profile tree post-profile and translated to
# ConfigMap/env patches by profilePatches. Helm-value keys with no known
# layer-2 translation throw — re-running the chart for arbitrary values is
# the artifact flake's update-time job (D26 layer 1).
#
# Post-merge invariant validation (§6.4) runs on the FINAL rendered objects
# and throws at eval on violation.
{lib}: let
  yaml = import ./yaml.nix {inherit lib;};
  bgpLib = import ./bgp.nix {inherit lib;};
  meshLib = import ./mesh.nix {inherit lib;};

  boolStr = b:
    if b
    then "true"
    else "false";

  # Deep-remove nulls (helm emits e.g. `annotations:` explicitly; kubenix
  # strips nulls at render anyway, and null attrs conflict with kubenix's
  # api.defaults merging).
  stripNulls = v:
    if builtins.isAttrs v
    then lib.mapAttrs (_: stripNulls) (lib.filterAttrs (_: x: x != null) v)
    else if builtins.isList v
    then map stripNulls v
    else v;

  # k8s Quantities (resources limits/requests) must be strings in the
  # typed tree; the k8s API accepts both. Stringify numeric leaves there.
  stringifyQuantities = v:
    if builtins.isAttrs v
    then
      lib.mapAttrs (
        k: val:
          if (k == "limits" || k == "requests") && builtins.isAttrs val
          then
            lib.mapAttrs (_: q:
              if builtins.isInt q || builtins.isFloat q
              then toString q
              else q)
            val
          else stringifyQuantities val
      )
      v
    else if builtins.isList v
    then map stringifyQuantities v
    else v;

  # Normalize a parsed document for the typed tree: kubenix's generated
  # list-with-merge-key coercion requires Service ports to carry a
  # protocol; the k8s API defaults it to TCP, so filling it is a no-op
  # against the apiserver. ConfigMap data values must be strings — layer 2
  # stringifies boolean and integer values from the base manifest.
  normalizeDoc = obj: let
    stripped = stringifyQuantities (stripNulls obj);
  in
    if stripped.kind or null == "Service" && stripped.spec ? ports
    then
      lib.recursiveUpdate stripped {
        spec.ports = map (p: {protocol = "TCP";} // p) stripped.spec.ports;
      }
    else if stripped.kind or null == "ConfigMap" && stripped.data or null != null
    then
      stripped
      // {
        data =
          lib.mapAttrs (
            _: v:
              if builtins.isBool v || builtins.isInt v
              then toString v
              else v
          )
          stripped.data;
      }
    else stripped;

  # Route one parsed document to its typed-tree address.
  docResource = obj: let
    gv = lib.splitString "/" obj.apiVersion;
    version = lib.last gv;
    group =
      if builtins.length gv == 1
      then "core"
      else builtins.head gv;
  in {
    inherit group version;
    inherit (obj) kind;
    inherit (obj.metadata) name;
    inherit obj;
  };

  # Every image reference ("repo:tag@digest") in an object tree.
  imagesOf = v:
    lib.unique (
      if builtins.isAttrs v
      then
        lib.concatMap (
          kv: let
            val = kv.value;
          in
            if kv.name == "image" && builtins.isString val
            then [val]
            else imagesOf val
        ) (lib.attrsToList v)
      else if builtins.isList v
      then lib.concatMap imagesOf v
      else []
    );
in rec {
  # Translate the merged Cilium profile (mkCiliumValues output, with the
  # admin's cilium.helmValues already folded in) into typed-tree patches.
  # Every value is mkForce'd so it wins over the imported base document.
  profilePatches = {
    profile,
    k8sServiceHost,
    k8sServicePort,
  }: let
    cmData = lib.mapAttrs (_: lib.mkForce) (
      {
        "cluster-name" = profile.cluster.name;
        "cluster-id" = toString profile.cluster.id;
        "kube-proxy-replacement" = boolStr profile.kubeProxyReplacement;
        "routing-mode" = profile.routingMode;
        "auto-direct-node-routes" = boolStr profile.autoDirectNodeRoutes;
        # D55: Cilium's required KPR rules use the host's nft backend.
        "install-iptables-rules" = boolStr profile.extraConfig."install-iptables-rules";
        "devices" = profile.devices;
        "direct-routing-device" = profile.nodePort.directRoutingDevice;
        "mtu" = toString profile.MTU;
        "ipam" = profile.ipam.mode;
        # D41: Node IPAM is the default classless LoadBalancer mechanism.
        "default-lb-service-ipam" = profile.defaultLBServiceIPAM;
        "enable-node-ipam" = boolStr profile.nodeIPAM.enabled;
        # D9: BGP v2 control plane (locked to shared-bgp pool presence).
        "enable-bgp-control-plane" = boolStr profile.bgpControlPlane.enabled;
        "enable-ipv4" = boolStr profile.ipv4.enabled;
        "enable-ipv6" = boolStr profile.ipv6.enabled;
        "enable-ipv4-masquerade" = boolStr profile.enableIPv4Masquerade;
        "enable-ipv6-masquerade" = boolStr profile.enableIPv6Masquerade;
        "enable-bpf-masquerade" = boolStr profile.bpf.masquerade;
        "enable-bpf-tproxy" = boolStr profile.bpf.tproxy;
        "cni-chaining-mode" = profile.cni.chainingMode;
        "cni-exclusive" = boolStr profile.cni.exclusive;
        "bpf-lb-algorithm" = profile.loadBalancer.algorithm;
        "enable-pmtu-discovery" = boolStr profile.pmtuDiscovery.enabled;
        # D60: the ClusterMesh control plane is part of the canonical
        # profile (clustermesh-apiserver + agents, from first boot).
        "clustermesh-enable" = boolStr profile.clusterMesh.enable;
        "max-connected-clusters" = toString profile.clusterMesh.maxConnectedClusters;
      }
      # D49/D58: native-routing CIDRs apply to native routing only; on
      # tunnel transports they render empty (unset), like the chart.
      // lib.optionalAttrs (profile.routingMode == "native") {
        "ipv4-native-routing-cidr" = profile.ipv4NativeRoutingCIDR;
        "ipv6-native-routing-cidr" = profile.ipv6NativeRoutingCIDR;
      }
      // lib.optionalAttrs (profile.routingMode == "tunnel") {
        "ipv4-native-routing-cidr" = "";
        "ipv6-native-routing-cidr" = "";
        "tunnel-protocol" = profile.tunnelProtocol;
      }
    );
    # KPR's API endpoint is passed to the agent and operator as env, not
    # via the ConfigMap (cilium chart: k8sServiceHost/k8sServicePort →
    # KUBERNETES_SERVICE_HOST/PORT).
    kprEnv = {
      KUBERNETES_SERVICE_HOST.value = k8sServiceHost;
      KUBERNETES_SERVICE_PORT.value = toString k8sServicePort;
    };
  in {
    "core"."v1".ConfigMap."cilium-config".data = cmData;
    # The base manifest names the agent container "cilium-agent" — a
    # wrong key here would APPEND an imageless phantom container (the
    # apiserver rejects it: spec.template.spec.containers[0].image is
    # Required). validateBundle checks the merged result.
    "apps"."v1".DaemonSet."cilium".spec.template.spec.containers.cilium-agent.env = kprEnv;
    # The API-talking init containers need the endpoint too (the chart
    # gives it to both when k8sServiceHost is set; the artifact manifest
    # is rendered without it so the per-cluster endpoint lands here):
    # "config" (cilium-dbg build-config resolves the ConfigMap and
    # CiliumNodeConfigs via the API) and "clean-cilium-state" (agent
    # cleanup runs with a k8s client).
    "apps"."v1".DaemonSet."cilium".spec.template.spec.initContainers.config.env = kprEnv;
    "apps"."v1".DaemonSet."cilium".spec.template.spec.initContainers.clean-cilium-state.env = kprEnv;
    "apps"."v1".Deployment."cilium-operator".spec.template.spec.containers.cilium-operator.env = kprEnv;
    "apps"."v1".Deployment."cilium-operator".spec.replicas = lib.mkForce profile.operator.replicas;
  };

  # Helm-values keys the layer-2 translation supports (the full profile
  # tree). Anything else the admin puts in cilium.helmValues cannot be
  # expressed without re-running the chart and throws.
  knownProfilePaths = [
    [
      "cluster"
      "name"
    ]
    [
      "cluster"
      "id"
    ]
    ["kubeProxyReplacement"]
    ["k8sServiceHost"]
    ["k8sServicePort"]
    ["routingMode"]
    ["tunnelProtocol"]
    ["autoDirectNodeRoutes"]
    [
      "extraConfig"
      "install-iptables-rules"
    ]
    ["ipv4NativeRoutingCIDR"]
    ["ipv6NativeRoutingCIDR"]
    ["devices"]
    [
      "nodePort"
      "directRoutingDevice"
    ]
    ["MTU"]
    [
      "ipam"
      "mode"
    ]
    ["defaultLBServiceIPAM"]
    [
      "nodeIPAM"
      "enabled"
    ]
    [
      "bgpControlPlane"
      "enabled"
    ]
    [
      "ipv4"
      "enabled"
    ]
    [
      "ipv6"
      "enabled"
    ]
    ["enableIPv4Masquerade"]
    ["enableIPv6Masquerade"]
    [
      "bpf"
      "masquerade"
    ]
    [
      "bpf"
      "tproxy"
    ]
    [
      "cni"
      "chainingMode"
    ]
    [
      "cni"
      "exclusive"
    ]
    [
      "operator"
      "replicas"
    ]
    [
      "gatewayAPI"
      "enabled"
    ]
    [
      "ingressController"
      "enabled"
    ]
    [
      "loadBalancer"
      "algorithm"
    ]
    [
      "pmtuDiscovery"
      "enabled"
    ]
    [
      "clusterMesh"
      "enable"
    ]
    [
      "clusterMesh"
      "maxConnectedClusters"
    ]
  ];

  # Attr paths (dotted) present in an attrset tree.
  leafPaths = prefix: v:
    if builtins.isAttrs v
    then lib.concatMap (kv: leafPaths (prefix ++ [kv.name]) kv.value) (lib.attrsToList v)
    else [prefix];

  unsupportedHelmValues = helmValues: lib.filter (p: !(lib.elem p knownProfilePaths)) (leafPaths [] helmValues);

  # §6.4/D60 post-merge invariant validation. Runs over the FINAL rendered
  # objects (so it sees the merged result, not the intent) plus the merged
  # profile (for the assert-only invariants that have no ConfigMap key) and
  # the resolved mesh facts (apiserver placement/exposure). Throws at eval
  # on violation.
  validateBundle = {
    instanceName,
    profile,
    mesh,
    objects,
    baseObjects,
  }: let
    cm = lib.findFirst (o: o.kind == "ConfigMap" && o.metadata.name == "cilium-config") null objects;
    cmData =
      if cm == null
      then throw "kube-cluster/${instanceName}: bundle lost the cilium-config ConfigMap"
      else cm.data;

    operator =
      lib.findFirst (
        o: o.kind == "Deployment" && o.metadata.name == "cilium-operator"
      )
      null
      objects;
    operatorEnv =
      if operator == null
      then throw "kube-cluster/${instanceName}: bundle lost the cilium-operator Deployment"
      else (lib.findFirst (c: c.name == "cilium-operator") null operator.spec.template.spec.containers).env;

    agent = lib.findFirst (o: o.kind == "DaemonSet" && o.metadata.name == "cilium") null objects;
    agentContainer =
      if agent == null
      then throw "kube-cluster/${instanceName}: bundle lost the cilium DaemonSet"
      else lib.findFirst (c: c.name == "cilium-agent") null agent.spec.template.spec.containers;
    # The API-talking init containers (build-config resolves the ConfigMap
    # via the API; clean-cilium-state runs the agent's cleanup client).
    agentInitEnvs = map (c: map (e: e.name) c.env) (
      lib.filter (
        c:
          lib.elem c.name [
            "config"
            "clean-cilium-state"
          ]
      ) (agent.spec.template.spec.initContainers or [])
    );

    # The ClusterMesh apiserver (D60): rendered from first boot on every
    # cluster (peers may be empty).
    apiserver =
      lib.findFirst (
        o: o.kind == "Deployment" && o.metadata.name == "clustermesh-apiserver"
      )
      null
      objects;
    apiserverSvc =
      lib.findFirst (
        o: o.kind == "Service" && o.metadata.name == "clustermesh-apiserver"
      )
      null
      objects;
    apiserverContainers =
      if apiserver == null
      then throw "kube-cluster/${instanceName}: bundle lost the clustermesh-apiserver Deployment"
      else apiserver.spec.template.spec.containers;
    apiserverArgsOf = name: map (a: a) ((lib.findFirst (c: c.name == name) null apiserverContainers).args or []);
    maxConnArg = prefix: args: lib.findFirst (a: lib.hasPrefix prefix a) null args;

    # Every container in every pod template must carry a non-empty image.
    # A named-container patch that misses its target key silently APPENDS
    # an imageless phantom container, and the apiserver rejects the whole
    # workload (spec.template.spec.containers[i].image is Required).
    imageless =
      lib.concatMap (
        o: let
          t = o.spec.template.spec or null;
        in
          if t == null
          then []
          else
            map (c: "${o.kind}/${o.metadata.name}:${c.name or "?"}") (
              lib.filter (c: (c.image or "") == "") ((t.containers or []) ++ (t.initContainers or []))
            )
      )
      objects;

    # Images in the rendered bundle must be exactly the committed base
    # manifest's digest-pinned set (artifact invariant — overrides must
    # never retag/repoint images).
    renderedImages = lib.sort builtins.lessThan (imagesOf objects);
    baseImages = lib.sort builtins.lessThan (imagesOf baseObjects);

    native = profile.routingMode == "native";

    svcType = apiserverSvc.spec.type or null;
    expectedType =
      if mesh.method == "node-port"
      then "NodePort"
      else "LoadBalancer";

    checks = [
      {
        ok = cmData."kube-proxy-replacement" == "true" && profile.kubeProxyReplacement == true;
        msg = "kube-proxy-replacement must stay enabled (KPR)";
      }
      {
        ok = cmData."routing-mode" == profile.routingMode;
        msg = "routing-mode must equal the transport-derived mode '${profile.routingMode}' (D58)";
      }
      {
        ok = !native -> (cmData."tunnel-protocol" or null) == (profile.tunnelProtocol or null);
        msg = "tunnel-protocol must equal the transport-derived protocol '${
          profile.tunnelProtocol or "null"
        }' (D58)";
      }
      {
        ok = native -> (cmData ? "ipv4-native-routing-cidr" && cmData ? "ipv6-native-routing-cidr");
        msg = "native-routing CIDRs must render on the native profile (D49)";
      }
      {
        ok = cmData."auto-direct-node-routes" == "false" && profile.autoDirectNodeRoutes == false;
        msg = "auto-direct-node-routes=false is invariant (remote pod routes ride the transport, §6.4/D58)";
      }
      {
        ok = cmData."install-iptables-rules" == "true";
        msg = "install-iptables-rules=true is required by Cilium KPR/BPF masquerade (iptables-nft host, D55)";
      }
      {
        ok = cmData."enable-ipv4" == "true" && cmData."enable-ipv6" == "true";
        msg = "dual-stack stays on (invariant 2)";
      }
      {
        ok = cmData."cni-chaining-mode" == "none" && cmData."cni-exclusive" == "true";
        msg = "cni.chainingMode=none + exclusive (Multus flip is a separate explicit switch)";
      }
      {
        ok = lib.elem cmData."ipam" [
          "multi-pool"
          "kubernetes"
        ];
        msg = "ipam.mode must be multi-pool or kubernetes (kubernetes = allowed explicit override, D41)";
      }
      {
        ok = profile.gatewayAPI.enabled == false && profile.ingressController.enabled == false;
        msg = "gatewayAPI/ingressController stay disabled (D1)";
      }
      {
        ok = cmData."enable-node-ipam" == "true" && cmData."default-lb-service-ipam" == "nodeipam";
        msg = "Node IPAM stays enabled and the default classless LB IPAM (D41)";
      }
      {
        # D41: the BGP class is the explicit-pool LB-IPAM class even when
        # D9 renders no BGP resources.
        ok = cmData."enable-bgp-control-plane" == "true";
        msg = "enable-bgp-control-plane=true is required to register the explicit-pool LB-IPAM class (D41)";
      }
      {
        # D60: the ClusterMesh subsystem is part of the canonical profile.
        ok = cmData."clustermesh-enable" == "true";
        msg = "clustermesh-enable=true is required (ClusterMesh from first boot, D60)";
      }
      {
        ok = cmData."max-connected-clusters" == toString profile.clusterMesh.maxConnectedClusters;
        msg = "max-connected-clusters must match the mesh setting (group uniformity, D60)";
      }
      {
        # Every base-manifest image reference must survive unchanged
        # (overrides may never retag/repoint them); clan-added resources
        # (e.g. the D46 CoreDNS) may add their own pinned images.
        ok = lib.all (img: lib.elem img renderedImages) baseImages;
        msg = "base manifest image references must survive byte-identical (artifact invariant; rendered: ${builtins.toJSON renderedImages})";
      }
      {
        ok = (lib.findFirst (e: e.name == "KUBERNETES_SERVICE_HOST") null operatorEnv) != null;
        msg = "cilium-operator lost its KPR endpoint env (KUBERNETES_SERVICE_HOST)";
      }
      {
        ok =
          agentContainer
          != null
          && (lib.findFirst (e: e.name == "KUBERNETES_SERVICE_HOST") null agentContainer.env) != null;
        msg = "cilium DaemonSet lost its cilium-agent container or its KPR endpoint env (KUBERNETES_SERVICE_HOST)";
      }
      {
        ok =
          builtins.length agentInitEnvs == 2 && lib.all (lib.elem "KUBERNETES_SERVICE_HOST") agentInitEnvs;
        msg = "cilium DaemonSet API-talking init containers (config, clean-cilium-state) lost their KPR endpoint env (KUBERNETES_SERVICE_HOST)";
      }
      {
        ok = imageless == [];
        msg = "every pod-template container must carry a non-empty image (imageless: ${lib.concatStringsSep ", " imageless})";
      }
      {
        # D60 placement/exposure on the upstream apiserver objects.
        ok = apiserver != null && apiserver.spec.replicas == mesh.replicas;
        msg = "clustermesh-apiserver replicas must equal the resolved placement count (${toString mesh.replicas})";
      }
      {
        ok =
          apiserver.spec.strategy.type
          == "RollingUpdate"
          && apiserver.spec.strategy.rollingUpdate.maxSurge == 0
          && apiserver.spec.strategy.rollingUpdate.maxUnavailable == 1;
        msg = "clustermesh-apiserver rolling update must be maxSurge=0 / maxUnavailable=1 (D60)";
      }
      {
        ok =
          (
            apiserver.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution
              or []
          )
          != [];
        msg = "clustermesh-apiserver needs REQUIRED hostname anti-affinity (D60)";
      }
      {
        ok = apiserverSvc != null && svcType == expectedType;
        msg = "clustermesh-apiserver Service type must be ${expectedType} (mesh method ${mesh.method})";
      }
      {
        ok = apiserverSvc != null && apiserverSvc.spec.externalTrafficPolicy == "Local";
        msg = "clustermesh-apiserver Service must keep ETP Local on every exposure method (D60/invariant 5)";
      }
      {
        ok =
          maxConnArg "--max-connected-clusters=" (apiserverArgsOf "apiserver")
          == "--max-connected-clusters=${toString profile.clusterMesh.maxConnectedClusters}";
        msg = "apiserver container --max-connected-clusters must match the mesh setting (D60)";
      }
      {
        ok =
          maxConnArg "--max-connected-clusters=" (apiserverArgsOf "kvstoremesh")
          == "--max-connected-clusters=${toString profile.clusterMesh.maxConnectedClusters}";
        msg = "kvstoremesh container --max-connected-clusters must match the mesh setting (D60)";
      }
    ];
    bad = lib.filter (c: !c.ok) checks;
  in
    if bad != []
    then
      throw "kube-cluster/${instanceName}: bootstrap bundle invariant violation(s): ${
        lib.concatMapStringsSep "; " (c: c.msg) bad
      }"
    else true;

  # Render one CiliumLoadBalancerIPPool (D8: pool = address inventory +
  # serviceSelector only). The metadata.name defaults from the resource's
  # attribute key in the kubenix tree.
  mkPoolResource = {
    blocks,
    serviceSelector,
    manifestLabels,
  }: {
    spec = {
      blocks = map (cidr: {inherit cidr;}) blocks;
      serviceSelector.matchLabels = serviceSelector;
    };
    metadata.labels = manifestLabels;
  };

  # The default CiliumPodIPPool carrying the cluster's dual-stack pod CIDRs.
  mkPodIPPoolResource = {
    clusterCidr,
    manifestLabels,
  }: let
    cidrs = lib.splitString "," clusterCidr;
  in {
    spec = {
      ipv4 = {
        cidrs = [(builtins.elemAt cidrs 0)];
        maskSize = 24;
      };
      ipv6 = {
        cidrs = [(builtins.elemAt cidrs 1)];
        maskSize = 64;
      };
    };
    metadata.labels = manifestLabels;
  };

  # Helper for every clan-rendered external-facing Service (invariants
  # 5/6): ETP Local. Explicit pools use the BGP class for LB-IPAM
  # allocation; advertisement remains selector-driven.
  mkLBService = {
    name,
    namespace ? "default",
    manifestLabels,
    labels ? {},
    annotations ? {},
    loadBalancerClass ? "io.cilium/bgp-control-plane",
    ports,
    selector ? null,
    extraSpec ? {},
  }: {
    apiVersion = "v1";
    kind = "Service";
    metadata =
      {
        inherit name namespace;
        labels = manifestLabels // labels;
      }
      // lib.optionalAttrs (annotations != {}) {inherit annotations;};
    spec =
      {
        type = "LoadBalancer";
        externalTrafficPolicy = "Local";
        inherit ports;
      }
      // lib.optionalAttrs (loadBalancerClass != null) {inherit loadBalancerClass;}
      // lib.optionalAttrs (selector != null) {inherit selector;}
      // extraSpec;
  };

  # The uniform clan-rendered CoreDNS for cluster.local (D46) — typed
  # resources, no chart. Rendered by mkBundle only when
  # distroDefaults.enable = false (mode-exclusive with the distro's stock
  # CoreDNS: never two claimants of the clusterDNS Service IP). The
  # coredns.rewrites (D21/D22 aliasing) fold into the Corefile, so k3s and
  # rke2 behave identically.
  mkCoreDNSResources = {
    clusterDNS,
    image,
    rewrites,
    manifestLabels,
  }: {
    "core"."v1".ServiceAccount."coredns" = {
      metadata = {
        namespace = "kube-system";
        labels = manifestLabels;
      };
    };

    "rbac.authorization.k8s.io"."v1".ClusterRole."coredns" = {
      metadata.labels = manifestLabels;
      rules = [
        {
          apiGroups = [""];
          resources = [
            "endpoints"
            "services"
            "pods"
            "namespaces"
          ];
          verbs = [
            "list"
            "watch"
          ];
        }
        {
          apiGroups = ["discovery.k8s.io"];
          resources = ["endpointslices"];
          verbs = [
            "list"
            "watch"
          ];
        }
      ];
    };

    "rbac.authorization.k8s.io"."v1".ClusterRoleBinding."coredns" = {
      metadata.labels = manifestLabels;
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "coredns";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "coredns";
          namespace = "kube-system";
        }
      ];
    };

    "core"."v1".ConfigMap."coredns" = {
      metadata = {
        namespace = "kube-system";
        labels = manifestLabels;
      };
      data.Corefile = lib.concatStringsSep "\n" (
        [
          ".:53 {"
          "    errors"
          "    health {"
          "        lameduck 10s"
          "    }"
          "    ready"
        ]
        ++ map (r: "    rewrite ${r}") rewrites
        ++ [
          "    kubernetes cluster.local in-addr.arpa ip6.arpa {"
          "        pods insecure"
          "        fallthrough in-addr.arpa ip6.arpa"
          "        ttl 30"
          "    }"
          "    forward . /etc/resolv.conf"
          "    cache 30"
          "    loop"
          "    reload"
          "    loadbalance"
          "}"
          ""
        ]
      );
    };

    "apps"."v1".Deployment."coredns" = {
      metadata = {
        namespace = "kube-system";
        labels =
          manifestLabels
          // {
            "k8s-app" = "kube-dns";
          };
      };
      spec = {
        replicas = 2;
        strategy = {
          type = "RollingUpdate";
          rollingUpdate.maxUnavailable = 1;
        };
        selector.matchLabels."k8s-app" = "kube-dns";
        template = {
          metadata.labels =
            manifestLabels
            // {
              "k8s-app" = "kube-dns";
            };
          spec = {
            priorityClassName = "system-cluster-critical";
            serviceAccountName = "coredns";
            dnsPolicy = "Default";
            tolerations = [
              {
                key = "CriticalAddonsOnly";
                operator = "Exists";
              }
              {
                key = "node-role.kubernetes.io/control-plane";
                operator = "Exists";
                effect = "NoSchedule";
              }
            ];
            nodeSelector."kubernetes.io/os" = "linux";
            # Two replicas, spread across nodes when possible (soft: a
            # single-node cluster still schedules both).
            affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
              {
                weight = 100;
                podAffinityTerm = {
                  labelSelector.matchLabels."k8s-app" = "kube-dns";
                  topologyKey = "kubernetes.io/hostname";
                };
              }
            ];
            containers.coredns = {
              inherit image;
              imagePullPolicy = "IfNotPresent";
              args = [
                "-conf"
                "/etc/coredns/Corefile"
              ];
              volumeMounts."config-volume" = {
                name = "config-volume";
                mountPath = "/etc/coredns";
                readOnly = true;
              };
              ports = {
                dns = {
                  name = "dns";
                  containerPort = 53;
                  protocol = "UDP";
                };
                dns-tcp = {
                  name = "dns-tcp";
                  containerPort = 53;
                  protocol = "TCP";
                };
              };
              resources = {
                limits.memory = "170Mi";
                requests = {
                  cpu = "100m";
                  memory = "70Mi";
                };
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities = {
                  add = ["NET_BIND_SERVICE"];
                  drop = ["all"];
                };
                readOnlyRootFilesystem = true;
              };
              livenessProbe.httpGet = {
                path = "/health";
                port = 8080;
                scheme = "HTTP";
              };
              readinessProbe.httpGet = {
                path = "/ready";
                port = 8181;
                scheme = "HTTP";
              };
            };
            volumes."config-volume" = {
              name = "config-volume";
              configMap = {
                name = "coredns";
                items = [
                  {
                    key = "Corefile";
                    path = "Corefile";
                  }
                ];
              };
            };
          };
        };
      };
    };

    # The ClusterIP is pinned to the derived clusterDNS address, so the
    # distro's kubelet cluster-dns setting stays unchanged.
    "core"."v1".Service."kube-dns" = {
      metadata = {
        namespace = "kube-system";
        labels =
          manifestLabels
          // {
            "k8s-app" = "kube-dns";
          };
      };
      spec = {
        clusterIP = clusterDNS;
        selector."k8s-app" = "kube-dns";
        ports = {
          dns = {
            name = "dns";
            port = 53;
            protocol = "UDP";
          };
          dns-tcp = {
            name = "dns-tcp";
            port = 53;
            protocol = "TCP";
          };
        };
      };
    };
  };

  # The bundle itself. Returns:
  #   objects    — final object list (labels + config-hash applied; the
  #                clan.lol/config-hash LABEL carries only the first 32 hex
  #                chars — Kubernetes label values cap at 63 bytes)
  #   json       — builtins.toJSON objects (pure; for determinism tests)
  #   configHash — full sha256 over json
  #   path       — derivation with the multi-doc YAML (for environment.etc)
  mkBundle = {
    pkgs,
    # the kubenix flake input as a PATH (never touch .overlays/outputs —
    # evaluating the kubenix flake would drag its transitive inputs into
    # sandboxed test evals; lib/eval-modules.nix is the pure entry point)
    kubenixSrc,
    baseManifest,
    settings,
    instanceName,
    k8sServiceHost,
    k8sServicePort ? 6443,
    profile,
    pools,
    podIPCidr,
    clusterDNS,
    # digest-pinned CoreDNS image reference (repo:tag@digest) from the
    # artifact flake's pkgs/coredns/versions.nix
    coreDNSImage,
    manifestLabels,
    # null or { asns, members, sharedBgpPoolNames, nodeBgpPoolNames,
    # advertiseClusterIPs } — the D9 revised BGP v2 resource set.
    # Rendered iff node-bgp/shared-bgp pools exist (§6.12).
    bgp ? null,
    # The resolved ClusterMesh facts (mesh.nix resolve, D60): placement,
    # exposure, replicas, VIPs, published endpoints, and peer configs.
    # Always non-null — every cluster runs the apiserver from first boot.
    mesh,
  }: let
    unsupported = unsupportedHelmValues settings.cilium.helmValues;

    # Helm-inflated TLS Secrets contain generated private keys. They are
    # never clan inputs: ClusterMesh material arrives at runtime through
    # clan vars, and endpoint-only peer Secrets are rendered separately.
    baseDocs = map (d: d // {obj = normalizeDoc d.obj;}) (
      builtins.filter (d: d.kind != "Secret") (
        map docResource (yaml.fromYAMLMulti (builtins.readFile baseManifest))
      )
    );

    baseResources =
      lib.foldl' (
        acc: r: lib.recursiveUpdate acc {${r.group}.${r.version}.${r.kind}.${r.name} = r.obj;}
      ) {}
      baseDocs;

    kubenixModule = {
      kubenix,
      lib,
      ...
    }: {
      imports = [kubenix.modules.k8s];
      kubernetes = {
        version = "1.36";
        # Our own labels are the contract (§6.11); the kubenix/hash
        # label is replaced by clan.lol/config-hash below.
        addHashLabel = false;

        # Replace kubenix's default annotations (project-name/k8s-version)
        # with the clan manifest labels on every object.
        api.defaults = lib.mkForce [
          {
            default = {
              metadata.labels = manifestLabels;
            };
          }
        ];

        customTypes = [
          {
            group = "cilium.io";
            version = "v2alpha1";
            kind = "CiliumPodIPPool";
            attrName = "ciliumPodIPPools";
          }
          {
            group = "cilium.io";
            version = "v2alpha1";
            kind = "CiliumLoadBalancerIPPool";
            attrName = "ciliumLoadBalancerIPPools";
          }
          {
            group = "cilium.io";
            version = "v2alpha1";
            kind = "CiliumBGPClusterConfig";
            attrName = "ciliumBGPClusterConfigs";
          }
          {
            group = "cilium.io";
            version = "v2alpha1";
            kind = "CiliumBGPPeerConfig";
            attrName = "ciliumBGPPeerConfigs";
          }
          {
            group = "cilium.io";
            version = "v2alpha1";
            kind = "CiliumBGPAdvertisement";
            attrName = "ciliumBGPAdvertisements";
          }
        ];

        # The Cilium CRDs are created by the cilium operator at runtime
        # (the chart ships no crds/ dir), so the CRs must apply AFTER the
        # base objects; the bootstrap-apply oneshot retries until they
        # stick. kubenix orders CRDs/Namespaces first and everything else
        # in definition order otherwise — custom kinds land last via the
        # resourceOrder default fallback.
        resources = lib.mkMerge (
          [baseResources]
          ++ [
            (profilePatches {inherit profile k8sServiceHost k8sServicePort;})
            (meshLib.apiserverDeploymentPatch {inherit mesh;})
            (meshLib.apiserverServicePatch {inherit mesh;})
            (meshLib.peerSecrets {
              inherit manifestLabels;
              inherit (mesh) peerConfigs;
            })
            {
              # The chart omits this object when clustermesh.config is
              # disabled; the base manifest's apiserver mounts it. The
              # resolved peers each get an etcd user bound to the shared
              # read-only `remote` role (D60 route/identity bounds).
              "core"."v1".ConfigMap."clustermesh-remote-users" = {
                metadata = {
                  namespace = "kube-system";
                  labels = manifestLabels;
                };
                data."users.yaml" = meshLib.remoteUsersYaml mesh.peerConfigs;
              };
              ciliumPodIPPools.default = mkPodIPPoolResource {
                clusterCidr = podIPCidr;
                inherit manifestLabels;
              };
              ciliumLoadBalancerIPPools =
                lib.mapAttrs (
                  _name: pool:
                    mkPoolResource {
                      inherit manifestLabels;
                      inherit (pool) blocks serviceSelector;
                    }
                )
                pools;
            }
          ]
          # D46: the uniform clan-rendered CoreDNS owns cluster.local in
          # the minimal base; distroDefaults.enable = true keeps the
          # distro's stock CoreDNS instead (mode-exclusive — never two
          # claimants of the clusterDNS IP).
          ++ lib.optional (!settings.distroDefaults.enable) (mkCoreDNSResources {
            inherit clusterDNS manifestLabels;
            image = coreDNSImage;
            inherit (settings.coredns) rewrites;
          })
          # Under distroDefaults the distro's stock CoreDNS serves
          # cluster.local; private-zone rewrites keep the legacy
          # coredns-custom ConfigMap path (k3s's stock Corefile imports
          # /etc/coredns/custom/*.override; inert on rke2). In the
          # minimal base the rewrites are folded into the clan Corefile
          # above and the ConfigMap is not rendered.
          ++ lib.optional (settings.distroDefaults.enable && settings.coredns.rewrites != []) {
            "core"."v1".ConfigMap."coredns-custom" = {
              metadata = {
                namespace = "kube-system";
                labels = manifestLabels;
              };
              data."${instanceName}.override" = lib.concatStringsSep "\n" (
                map (r: "rewrite ${r}") settings.coredns.rewrites
              );
            };
          }
          # D9: the BGP v2 resource set — iff shared-bgp pools exist
          # (the enable-bgp-control-plane flag consistency is validated
          # post-merge in validateBundle).
          ++ lib.optional (bgp != null) (
            bgpLib.mkBgpResources ({inherit instanceName manifestLabels;} // bgp)
          )
        );
      };
    };

    evalK8s = import "${kubenixSrc}/lib/eval-modules.nix" {inherit pkgs;};
    evaled = evalK8s {module = kubenixModule;};

    # Post-render object patching: list-valued leaves the kubenix typed
    # tree can only replace wholesale, which would go stale on chart
    # bumps. The --max-connected-clusters args of the apiserver and
    # kvstoremesh containers are patched list-surgically instead (D60
    # group uniformity), before validation and hashing.
    replaceArg = prefix: value: args:
      map (a:
        if lib.hasPrefix prefix a
        then "${prefix}${toString value}"
        else a)
      args;
    patchObject = o:
      if o.kind == "Deployment" && o.metadata.name == "clustermesh-apiserver"
      then
        o
        // {
          spec =
            o.spec
            // {
              template =
                o.spec.template
                // {
                  spec =
                    o.spec.template.spec
                    // {
                      containers =
                        map (
                          c:
                            if
                              lib.elem c.name [
                                "apiserver"
                                "kvstoremesh"
                              ]
                            then c // {args = replaceArg "--max-connected-clusters=" settings.mesh.maxConnectedClusters c.args;}
                            else c
                        )
                        o.spec.template.spec.containers;
                    };
                };
            };
        }
      else o;

    objects = map patchObject evaled.config.kubernetes.objects;

    baseObjects = map (d: d.obj) baseDocs;

    _validated = validateBundle {
      inherit
        instanceName
        profile
        mesh
        objects
        baseObjects
        ;
    };

    withHash = let
      json = builtins.toJSON objects;
      configHash = builtins.hashString "sha256" json;
      # Kubernetes label values cap at 63 bytes — a full sha256 hex (64
      # chars) is rejected by the apiserver. A 128-bit prefix is plenty
      # for drift detection; the bundle's `configHash` output stays
      # full-length.
      configHashLabel = builtins.substring 0 32 configHash;
    in {
      inherit json configHash;
      objects =
        map (
          o:
            o
            // {
              metadata =
                o.metadata
                // {
                  labels =
                    (o.metadata.labels or {})
                    // {
                      "clan.lol/config-hash" = configHashLabel;
                    };
                };
            }
        )
        objects;
    };

    upstreamables = import "${kubenixSrc}/lib/upstreamables.nix" {inherit lib pkgs;};
  in
    assert unsupported
    == []
    || throw "kube-cluster/${instanceName}: cilium.helmValues keys have no layer-2 (ConfigMap/env) translation and would be silently dropped: ${
      lib.concatMapStringsSep ", " (lib.concatStringsSep ".") unsupported
    }";
    assert builtins.deepSeq _validated _validated; {
      inherit (withHash) objects configHash;
      json = builtins.toJSON withHash.objects;
      path = upstreamables.toMultiDocumentYaml "clan-bootstrap-${instanceName}.yaml" withHash.objects;
    };
}
