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
{ lib }:
let
  yaml = import ./yaml.nix { inherit lib; };
  bgpLib = import ./bgp.nix { inherit lib; };

  boolStr = b: if b then "true" else "false";

  # Deep-remove nulls (helm emits e.g. `annotations:` explicitly; kubenix
  # strips nulls at render anyway, and null attrs conflict with kubenix's
  # api.defaults merging).
  stripNulls =
    v:
    if builtins.isAttrs v then
      lib.mapAttrs (_: stripNulls) (lib.filterAttrs (_: x: x != null) v)
    else if builtins.isList v then
      map stripNulls v
    else
      v;

  # k8s Quantities (resources limits/requests) must be strings in the
  # typed tree; the k8s API accepts both. Stringify numeric leaves there.
  stringifyQuantities =
    v:
    if builtins.isAttrs v then
      lib.mapAttrs (
        k: val:
        if (k == "limits" || k == "requests") && builtins.isAttrs val then
          lib.mapAttrs (_: q: if builtins.isInt q || builtins.isFloat q then toString q else q) val
        else
          stringifyQuantities val
      ) v
    else if builtins.isList v then
      map stringifyQuantities v
    else
      v;

  # Normalize a parsed document for the typed tree: kubenix's generated
  # list-with-merge-key coercion requires Service ports to carry a
  # protocol; the k8s API defaults it to TCP, so filling it is a no-op
  # against the apiserver.
  normalizeDoc =
    obj:
    let
      stripped = stringifyQuantities (stripNulls obj);
    in
    if stripped.kind or null == "Service" && stripped.spec ? ports then
      lib.recursiveUpdate stripped {
        spec.ports = map (p: { protocol = "TCP"; } // p) stripped.spec.ports;
      }
    else
      stripped;

  # Route one parsed document to its typed-tree address.
  docResource =
    obj:
    let
      gv = lib.splitString "/" obj.apiVersion;
      version = lib.last gv;
      group = if builtins.length gv == 1 then "core" else builtins.head gv;
    in
    {
      inherit group version;
      inherit (obj) kind;
      inherit (obj.metadata) name;
      inherit obj;
    };

  # Every image reference ("repo:tag@digest") in an object tree.
  imagesOf =
    v:
    lib.unique (
      if builtins.isAttrs v then
        lib.concatMap (
          kv:
          let
            val = kv.value;
          in
          if kv.name == "image" && builtins.isString val then [ val ] else imagesOf val
        ) (lib.attrsToList v)
      else if builtins.isList v then
        lib.concatMap imagesOf v
      else
        [ ]
    );
in
rec {
  # Translate the merged Cilium profile (mkCiliumValues output, with the
  # admin's cilium.helmValues already folded in) into typed-tree patches.
  # Every value is mkForce'd so it wins over the imported base document.
  profilePatches =
    {
      profile,
      k8sServiceHost,
      k8sServicePort,
    }:
    let
      cmData = lib.mapAttrs (_: lib.mkForce) {
        "cluster-name" = profile.cluster.name;
        "cluster-id" = toString profile.cluster.id;
        "kube-proxy-replacement" = boolStr profile.kubeProxyReplacement;
        "routing-mode" = profile.routingMode;
        "tunnel-protocol" = profile.tunnelProtocol;
        "ipv4-native-routing-cidr" = profile.ipv4NativeRoutingCIDR;
        "ipv6-native-routing-cidr" = profile.ipv6NativeRoutingCIDR;
        "devices" = profile.devices;
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
      };
      # KPR's API endpoint is passed to the agent and operator as env, not
      # via the ConfigMap (cilium chart: k8sServiceHost/k8sServicePort →
      # KUBERNETES_SERVICE_HOST/PORT).
      kprEnv = {
        KUBERNETES_SERVICE_HOST.value = k8sServiceHost;
        KUBERNETES_SERVICE_PORT.value = toString k8sServicePort;
      };
    in
    {
      "core"."v1".ConfigMap."cilium-config".data = cmData;
      "apps"."v1".DaemonSet."cilium".spec.template.spec.containers.cilium.env = kprEnv;
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
    [ "kubeProxyReplacement" ]
    [ "k8sServiceHost" ]
    [ "k8sServicePort" ]
    [ "routingMode" ]
    [ "tunnelProtocol" ]
    [ "ipv4NativeRoutingCIDR" ]
    [ "ipv6NativeRoutingCIDR" ]
    [ "devices" ]
    [
      "nodePort"
      "directRoutingDevice"
    ]
    [ "MTU" ]
    [
      "ipam"
      "mode"
    ]
    [ "defaultLBServiceIPAM" ]
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
    [ "enableIPv4Masquerade" ]
    [ "enableIPv6Masquerade" ]
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
  ];

  # Attr paths (dotted) present in an attrset tree.
  leafPaths =
    prefix: v:
    if builtins.isAttrs v then
      lib.concatMap (kv: leafPaths (prefix ++ [ kv.name ]) kv.value) (lib.attrsToList v)
    else
      [ prefix ];

  unsupportedHelmValues =
    helmValues: lib.filter (p: !(lib.elem p knownProfilePaths)) (leafPaths [ ] helmValues);

  # §6.4 post-merge invariant validation. Runs over the FINAL rendered
  # objects (so it sees the merged result, not the intent) plus the merged
  # profile (for the assert-only invariants that have no ConfigMap key).
  # Throws at eval on violation.
  validateBundle =
    {
      instanceName,
      profile,
      objects,
      baseObjects,
    }:
    let
      cm = lib.findFirst (o: o.kind == "ConfigMap" && o.metadata.name == "cilium-config") null objects;
      cmData =
        if cm == null then
          throw "kube-cluster/${instanceName}: bundle lost the cilium-config ConfigMap"
        else
          cm.data;

      operator = lib.findFirst (
        o: o.kind == "Deployment" && o.metadata.name == "cilium-operator"
      ) null objects;
      operatorEnv =
        if operator == null then
          throw "kube-cluster/${instanceName}: bundle lost the cilium-operator Deployment"
        else
          (lib.findFirst (c: c.name == "cilium-operator") null operator.spec.template.spec.containers).env;

      # Images in the rendered bundle must be exactly the committed base
      # manifest's digest-pinned set (artifact invariant — overrides must
      # never retag/repoint images).
      renderedImages = lib.sort builtins.lessThan (imagesOf objects);
      baseImages = lib.sort builtins.lessThan (imagesOf baseObjects);

      checks = [
        {
          ok = cmData."kube-proxy-replacement" == "true" && profile.kubeProxyReplacement == true;
          msg = "kube-proxy-replacement must stay enabled (KPR)";
        }
        {
          ok = cmData."routing-mode" == "tunnel" && cmData."tunnel-protocol" == "vxlan";
          msg = "routingMode=tunnel + tunnelProtocol=vxlan are invariant (§5.4)";
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
          # D9/§6.12: the control-plane flag tracks the presence of BGP
          # resources exactly (BGP only for shared-bgp pools).
          ok =
            (lib.any (o: o.kind == "CiliumBGPClusterConfig") objects)
            == (cmData."enable-bgp-control-plane" == "true");
          msg = "enable-bgp-control-plane must match the presence of BGP resources (BGP only for shared-bgp pools, §6.12)";
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
      ];
      bad = lib.filter (c: !c.ok) checks;
    in
    if bad != [ ] then
      throw "kube-cluster/${instanceName}: bootstrap bundle invariant violation(s): ${
        lib.concatMapStringsSep "; " (c: c.msg) bad
      }"
    else
      true;

  # Render one CiliumLoadBalancerIPPool (D8: pool = address inventory +
  # serviceSelector only). The metadata.name defaults from the resource's
  # attribute key in the kubenix tree.
  mkPoolResource =
    {
      blocks,
      serviceSelector,
      manifestLabels,
    }:
    {
      spec = {
        blocks = map (cidr: { inherit cidr; }) blocks;
        serviceSelector.matchLabels = serviceSelector;
      };
      metadata.labels = manifestLabels;
    };

  # The default CiliumPodIPPool carrying the cluster's dual-stack pod CIDRs.
  mkPodIPPoolResource =
    {
      clusterCidr,
      manifestLabels,
    }:
    let
      cidrs = lib.splitString "," clusterCidr;
    in
    {
      spec = {
        ipv4 = {
          cidrs = [ (builtins.elemAt cidrs 0) ];
          maskSize = 24;
        };
        ipv6 = {
          cidrs = [ (builtins.elemAt cidrs 1) ];
          maskSize = 64;
        };
      };
      metadata.labels = manifestLabels;
    };

  # Helper for every clan-rendered external-facing Service (invariants
  # 5/6): ETP Local + a Cilium-handled LB class pinned. The class defaults
  # to io.cilium/lb-ipam (pool draw only); Services whose VIPs are
  # BGP-advertised (shared-bgp delivery) MUST pass loadBalancerClass =
  # "io.cilium/bgp-control-plane" — Cilium 1.20 announces ingress IPs only
  # for that class or unset, while LB-IPAM allocation works for both
  # (verified against the v1.20 BGP/LB-IPAM docs).
  mkLBService =
    {
      name,
      namespace ? "default",
      manifestLabels,
      labels ? { },
      annotations ? { },
      loadBalancerClass ? "io.cilium/lb-ipam",
      ports,
      selector ? null,
      extraSpec ? { },
    }:
    {
      metadata = {
        inherit name namespace;
        labels = manifestLabels // labels;
      }
      // lib.optionalAttrs (annotations != { }) { inherit annotations; };
      spec = {
        type = "LoadBalancer";
        externalTrafficPolicy = "Local";
        inherit loadBalancerClass;
        inherit ports;
      }
      // lib.optionalAttrs (selector != null) { inherit selector; }
      // extraSpec;
    };

  # The uniform clan-rendered CoreDNS for cluster.local (D46) — typed
  # resources, no chart. Rendered by mkBundle only when
  # distroDefaults.enable = false (mode-exclusive with the distro's stock
  # CoreDNS: never two claimants of the clusterDNS Service IP). The
  # coredns.rewrites (D21/D22 aliasing) fold into the Corefile, so k3s and
  # rke2 behave identically.
  mkCoreDNSResources =
    {
      clusterDNS,
      image,
      rewrites,
      manifestLabels,
    }:
    {
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
            apiGroups = [ "" ];
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
            apiGroups = [ "discovery.k8s.io" ];
            resources = [ "endpointslices" ];
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
          labels = manifestLabels // {
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
            metadata.labels = manifestLabels // {
              "k8s-app" = "kube-dns";
            };
            spec = {
              priorityClassName = "system-cluster-critical";
              serviceAccountName = "coredns";
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
                    add = [ "NET_BIND_SERVICE" ];
                    drop = [ "all" ];
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
          labels = manifestLabels // {
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

  # The private-zone CoreDNS (D22 substrate, phase 5): a second CoreDNS
  # instance serving <instance>.<domain> (+ opt-in svc/pod zones) on a
  # fabric-pool VIP. Distinct from the D46 cluster.local CoreDNS — this one
  # NEVER serves cluster.local (D21): the svc/pod zones suffix-rewrite and
  # forward to the cluster CoreDNS instead, so no kubernetes plugin and no
  # RBAC are needed here. The instance zone's wildcard target is the day-2
  # proxy (D22 round-13): null wildcardAddress = the zone serves NXDOMAIN
  # until day-2 sets a target. Rendered in BOTH distroDefaults modes.
  mkPrivateCoreDNSResources =
    {
      instanceName,
      domain,
      image,
      manifestLabels,
      # deterministic fabric VIPs (fabric blocks + offset 53)
      vip4,
      vip6,
      # the fabric pool's serviceSelector value (clan.lol/pool label)
      fabricPoolName,
      wildcardAddress, # nullOr str
      svcZone, # bool — D22(a)
      podZone, # bool — D22(b)
      clusterDNS, # forward target for the svc/pod zones
    }:
    let
      zone = "${instanceName}.${domain}";
      svcZoneName = "${instanceName}.svc.${domain}";
      podZoneName = "${instanceName}.pods.${domain}";

      wildcardIsV6 = wildcardAddress != null && lib.hasInfix ":" wildcardAddress;

      baseZone = [
        "${zone}:53 {"
        "    errors"
        "    ready"
        "    health {"
        "        lameduck 5s"
        "    }"
      ]
      ++ (
        if wildcardAddress != null then
          [
            "    template IN ${if wildcardIsV6 then "AAAA" else "A"} ${zone} {"
            "        answer \"{{ .Name }} 60 IN ${if wildcardIsV6 then "AAAA" else "A"} ${wildcardAddress}\""
            "        fallthrough"
            "    }"
          ]
        else
          [ ]
      )
      ++ [
        "    template IN ANY ${zone} {"
        "        rcode NXDOMAIN"
        "    }"
        "    cache 30"
        "    loadbalance"
        "}"
      ];

      rewriteZone = name: target: [
        "${name}:53 {"
        "    errors"
        "    ready"
        "    rewrite name suffix .${name}. .${target}. answer auto"
        "    forward . ${clusterDNS}"
        "    cache 30"
        "}"
      ];

      corefile = lib.concatStringsSep "\n" (
        baseZone
        ++ lib.optionals svcZone (rewriteZone svcZoneName "svc.cluster.local")
        ++ lib.optionals podZone (rewriteZone podZoneName "pod.cluster.local")
        ++ [ "" ]
      );
    in
    {
      "core"."v1".ConfigMap."coredns-private" = {
        metadata = {
          namespace = "kube-system";
          labels = manifestLabels;
        };
        data.Corefile = corefile;
      };

      "apps"."v1".Deployment."coredns-private" = {
        metadata = {
          namespace = "kube-system";
          labels = manifestLabels // {
            "k8s-app" = "coredns-private";
          };
        };
        spec = {
          replicas = 2;
          strategy = {
            type = "RollingUpdate";
            rollingUpdate.maxUnavailable = 1;
          };
          selector.matchLabels."k8s-app" = "coredns-private";
          template = {
            metadata.labels = manifestLabels // {
              "k8s-app" = "coredns-private";
            };
            spec = {
              tolerations = [
                {
                  key = "node-role.kubernetes.io/control-plane";
                  operator = "Exists";
                  effect = "NoSchedule";
                }
              ];
              nodeSelector."kubernetes.io/os" = "linux";
              # Spread across nodes: with ETP Local, the VIP is advertised
              # exactly by the nodes hosting a replica (D9 withdrawal).
              affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
                {
                  weight = 100;
                  podAffinityTerm = {
                    labelSelector.matchLabels."k8s-app" = "coredns-private";
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
                    add = [ "NET_BIND_SERVICE" ];
                    drop = [ "all" ];
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
                  name = "coredns-private";
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

      # The VIP Service (invariants 5/6): ETP Local, BGP-advertised class
      # (shared-bgp delivery — Cilium announces only io.cilium/bgp-control-plane
      # or unset), pinned to the deterministic fabric VIPs.
      "core"."v1".Service."coredns-private" = mkLBService {
        name = "coredns-private";
        namespace = "kube-system";
        inherit manifestLabels;
        labels."clan.lol/pool" = fabricPoolName;
        annotations."lbipam.cilium.io/ips" = "${vip4},${vip6}";
        loadBalancerClass = "io.cilium/bgp-control-plane";
        selector."k8s-app" = "coredns-private";
        ports = [
          {
            name = "dns";
            port = 53;
            targetPort = 53;
            protocol = "UDP";
          }
          {
            name = "dns-tcp";
            port = 53;
            targetPort = 53;
            protocol = "TCP";
          }
        ];
        extraSpec = {
          ipFamilies = [
            "IPv4"
            "IPv6"
          ];
          ipFamilyPolicy = "RequireDualStack";
        };
      };
    };

  # The bundle itself. Returns:
  #   objects    — final object list (labels + config-hash applied)
  #   json       — builtins.toJSON objects (pure; for determinism tests)
  #   configHash — sha256 over json
  #   path       — derivation with the multi-doc YAML (for environment.etc)
  mkBundle =
    {
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
      # null or { asns, members, sharedBgpPoolNames, advertisePodCIDRs,
      # advertiseClusterIPs } — the D9 BGP v2 resource set. Rendered iff
      # shared-bgp pools exist (§6.12).
      bgp ? null,
      # null or { domain, vip4, vip6, fabricPoolName, wildcardAddress,
      # svcZone, podZone, clusterDNS } — the D22 private-zone CoreDNS.
      privateCoreDNS ? null,
    }:
    let
      unsupported = unsupportedHelmValues settings.cilium.helmValues;

      baseDocs = map (d: d // { obj = normalizeDoc d.obj; }) (
        map docResource (yaml.fromYAMLMulti (builtins.readFile baseManifest))
      );

      baseResources = lib.foldl' (
        acc: r: lib.recursiveUpdate acc { ${r.group}.${r.version}.${r.kind}.${r.name} = r.obj; }
      ) { } baseDocs;

      kubenixModule =
        { kubenix, lib, ... }:
        {
          imports = [ kubenix.modules.k8s ];
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
              [ baseResources ]
              ++ [
                (profilePatches { inherit profile k8sServiceHost k8sServicePort; })
                {
                  ciliumPodIPPools.default = mkPodIPPoolResource {
                    clusterCidr = podIPCidr;
                    inherit manifestLabels;
                  };
                  ciliumLoadBalancerIPPools = lib.mapAttrs (
                    _name: pool:
                    mkPoolResource {
                      inherit manifestLabels;
                      inherit (pool) blocks serviceSelector;
                    }
                  ) pools;
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
              ++ lib.optional (settings.distroDefaults.enable && settings.coredns.rewrites != [ ]) {
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
                bgpLib.mkBgpResources ({ inherit instanceName manifestLabels; } // bgp)
              )
              # D22 substrate: the private-zone CoreDNS on its fabric VIP
              # (rendered in both distroDefaults modes — D46).
              ++ lib.optional (privateCoreDNS != null) (
                mkPrivateCoreDNSResources (
                  {
                    inherit instanceName manifestLabels;
                    image = coreDNSImage;
                  }
                  // privateCoreDNS
                )
              )
            );
          };
        };

      evalK8s = import "${kubenixSrc}/lib/eval-modules.nix" { inherit pkgs; };
      evaled = evalK8s { module = kubenixModule; };
      objects = evaled.config.kubernetes.objects;

      baseObjects = map (d: d.obj) baseDocs;

      _validated = validateBundle {
        inherit
          instanceName
          profile
          objects
          baseObjects
          ;
      };

      withHash =
        let
          json = builtins.toJSON objects;
          configHash = builtins.hashString "sha256" json;
        in
        {
          inherit json configHash;
          objects = map (
            o:
            o
            // {
              metadata = o.metadata // {
                labels = (o.metadata.labels or { }) // {
                  "clan.lol/config-hash" = configHash;
                };
              };
            }
          ) objects;
        };

      upstreamables = import "${kubenixSrc}/lib/upstreamables.nix" { inherit lib pkgs; };
    in
    assert
      unsupported == [ ]
      || throw "kube-cluster/${instanceName}: cilium.helmValues keys have no layer-2 (ConfigMap/env) translation and would be silently dropped: ${
        lib.concatMapStringsSep ", " (lib.concatStringsSep ".") unsupported
      }";
    assert builtins.deepSeq _validated _validated;
    {
      inherit (withHash) objects configHash;
      json = builtins.toJSON withHash.objects;
      path = upstreamables.toMultiDocumentYaml "clan-bootstrap-${instanceName}.yaml" withHash.objects;
    };
}
