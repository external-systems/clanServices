# <distro>-data-plane: the Data-plane contract (§3.2, D41/D8/D9/D10, D44) over the
# phase-3 bootstrap bundle (D40):
#   - cluster comes up via the bundle path (bootstrap-apply oneshot),
#   - pool allocation: a Service with the explicit LB-IPAM class + the
#     pool's selector draws from the declared CiliumLoadBalancerIPPool,
#   - classless Service (no class) gets node IPs via Node IPAM,
#   - ETP-Local candidate restriction: with the backend pinned to one node,
#     only that node's IPs are advertised,
#   - shared-bgp ECMP and node-bgp owner-only delivery through the local
#     Cilium/FRR sessions and a foreign FRR router,
#   - ETP-Local withdrawal: when beta dies, shared VIPs stay reachable via
#     alpha and beta's node-owned VIPs withdraw,
#   - floating-pool documented blackhole window (D8): no controller in the
#     VM, so the floating VIP dies with its holding node,
#   - firewall positive (LB port and expected upstream BGP reachable) AND
#     negative (unexposed ports and the LB port on the untrusted underlay),
#   - hermetic: all images preloaded (distro airgap + artifact-flake Cilium
#     airgap set via the service defaults + go-httpbin fixture here).
#
# Underlay addressing is the test driver's deterministic assignment
# (alphabetical node order): alpha=192.168.1.1/2001:db8:1::1,
# beta=192.168.1.2/2001:db8:1::2, router=192.168.1.3/2001:db8:1::3.
#
# Shared by k3s and RKE2: services/{k3s,rke2}/tests/vm/data-plane.nix are thin
# wrappers that pass `distro`. Every distro difference is a `k3s` branch.
{
  inputs,
  distro,
  # "fixture": the bare IfState node fixture. "netif": the nodes'
  # underlay is declared through the netif service (specs/netif.md N14:
  # netif proven under Cilium Kubernetes and FRR); the wrapper adds the
  # netif instance.
  underlay ? "fixture",
}: {
  lib,
  nodes,
  ...
}: let
  k3s = distro == "k3s";
  netifUnderlay = underlay == "netif";
  suiteName = "${distro}-data-plane" + lib.optionalString netifUnderlay "-netif";
  fixture = addresses:
    lib.optional (!netifUnderlay) (
      import ../../../../tests/ifstate-vm.nix {
        ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
        inherit addresses;
      }
    );
  # Python for the netif variant only. Both are empty for the fixture
  # variant, whose test script must stay exactly as it was.
  indent = prefix: text: lib.concatMapStringsSep "\n" (line: lib.optionalString (line != "") (prefix + line)) (lib.splitString "\n" text);
  netifHelpers = lib.optionalString netifUnderlay (import ../../../../tests/ifstate-noop.nix);
  # one more phase inside the script's `try:` block
  netifPhase = lib.optionalString netifUnderlay (
    indent "    " ''
      with subtest("netif under a live cluster: status, drift watch, a reapply that changes nothing (N14)"):
          for node in [alpha, beta]:
              status = json.loads(node.succeed("netif-status --json"))
              uplink = [l for l in status["links"] if l["interface"] == "eth1"]
              assert len(uplink) == 1 and uplink[0]["state"] == "UP" and not uplink[0]["trusted"], status
              node.succeed("systemctl is-active netif-guard.service")
              # Cilium, FRR and the fabric own their links, routes and rules:
              # IfState proposes no change, and a real reapply changes nothing
              status, preview = node.execute("netif-preview")
              print(preview)
              if status != 0:
                  print(node.succeed("ifstatecli --config /etc/ifstate/ifstate.yaml check 2>&1; ip -6 -d addr show | grep -B3 -A3 '/127' || true"))
              assert status == 0, f"{node.name}: IfState would change a live cluster node:\n{preview}"
              node.succeed("systemctl start netif-drift.service")
              assert_ifstate_noop(node)
          # the cluster and the fabric did not notice
          alpha.wait_until_succeeds("kubectl get nodes --no-headers | grep -c ' Ready ' | grep -x 2 >/dev/null", timeout=120)
          alpha.succeed("vtysh -c 'show bgp summary json' | jq -e '[.. | objects | select(has(\"state\")) | .state] | length > 0 and all(. == \"Established\")' >/dev/null")
          router.wait_until_succeeds("curl -sf --max-time 5 http://172.16.1.80/get | grep '\"url\"' >/dev/null", timeout=120)
          print("NETIF_UNDER_KUBERNETES_OK")
    ''
  );
  # RKE2 runs distinct server and agent units; k3s runs one unit on both.
  serverUnit =
    if k3s
    then "k3s"
    else "rke2-server";
  agentUnit =
    if k3s
    then "k3s"
    else "rke2-agent";
  bootstrapUnit = "${distro}-${distro}-bootstrap-apply";
  kube = import ../../../../lib/kube-cluster {inherit lib;};
  fabric = import ../../../../lib/kube-cluster/fabric.nix {inherit lib;};
  fabricLink = fabric.adjacencyName (fabric.adjacencyKey "mesh" "alpha" "beta");
  fabricLoopback = "rflo${builtins.substring 0 10 (builtins.hashString "sha256" "mesh")}";
  nodeAsns = lib.genAttrs ["alpha" "beta"] (name: nodes.${name}.clan.networkFacts.fabric.mesh.asn);
  betaTransfer = nodes.beta.clan.networkFacts.fabric.mesh.adjacencies.alpha.ipv4;
  fabricPort = nodes.alpha.clan.networkFacts.fabric.mesh.adjacencies.beta.port;
  # the LB port of the kube API (7442 + cilium.id; the id is pinned to 1)
  apiLbPort = "7443";

  # The workload and pools that do not depend on BGP.
  fixtures = import ./data-plane-fixtures.nix {inherit lib inputs distro;};
  inherit
    (fixtures)
    httpbinImage
    manifestLabels
    poolService
    floatService
    httpbinPinned
    classlessService
    ;
  rke2ImageLinks = lib.optionals (!k3s) [(fixtures.rke2ImageLink httpbinImage)];
  # the shell image of the client pods (preloaded: the suite is offline)
  busyboxImage = pkgs:
    pkgs.dockerTools.pullImage {
      imageName = "busybox";
      imageDigest = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662";
      hash = "sha256-OasmfjRQsuVWudSc4qWuMKK5nNz4hdIS8Si4B0okXEw=";
      finalImageTag = "1.36.1";
    };
  dualStack = {
    ipFamilies = [
      "IPv4"
      "IPv6"
    ];
    ipFamilyPolicy = "RequireDualStack";
  };

  # /hostname answers with the pod name, so a caller sees which backend
  # (which node) served it.
  httpbinDaemonSet = lib.recursiveUpdate fixtures.httpbinDaemonSet {
    spec.template.spec.containers =
      map (
        container:
          container
          // {
            env = [
              {
                name = "USE_REAL_HOSTNAME";
                value = "true";
              }
            ];
          }
      )
      fixtures.httpbinDaemonSet.spec.template.spec.containers;
  };

  # A pod with a shell on every node: the source of pod traffic
  # (ported from the tunnel suite, D72).
  clientDaemonSet = {
    apiVersion = "apps/v1";
    kind = "DaemonSet";
    metadata.name = "client";
    spec = {
      selector.matchLabels.app = "client";
      template = {
        metadata.labels.app = "client";
        spec = {
          terminationGracePeriodSeconds = 1;
          containers = [
            {
              name = "client";
              image = "busybox:1.36.1";
              command = [
                "sleep"
                "86400"
              ];
            }
          ];
        };
      };
    };
  };

  clusterIPService = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "httpbin-cluster";
      labels = manifestLabels;
    };
    spec =
      {
        type = "ClusterIP";
        selector.app = "httpbin";
        ports = [
          {
            port = 80;
            targetPort = 8080;
          }
        ];
      }
      // dualStack;
  };

  # Classless with a backend on every node: Node IPAM publishes every
  # node, and withdraws the one that dies.
  classlessAllService = lib.recursiveUpdate classlessService {
    metadata.name = "httpbin-nodeipam-all";
    spec = {
      selector.app = "httpbin";
      ports = [
        {
          port = 83;
          targetPort = 8080;
        }
      ];
    };
  };

  routerNeighbor = {
    address,
    node,
    family,
  }: ''
    router bgp 65001
     neighbor ${address} remote-as ${toString nodeAsns.${node}}
     neighbor ${address} description ${node}-ipv${toString family}
     neighbor ${address} bfd
     neighbor ${address} timers 3 9
     neighbor ${address} timers connect 5
     address-family ipv${toString family} unicast
      neighbor ${address} activate
      neighbor ${address} route-map cluster_in${toString family} in
      neighbor ${address} route-map cluster_out${toString family} out
      neighbor ${address} maximum-prefix 100
      maximum-paths 8
     exit-address-family
  '';

  routerFrrConf = ''
    frr defaults datacenter
    ip prefix-list cluster_vips4 seq 5 permit 172.16.1.0/24 ge 32 le 32
    ip prefix-list cluster_vips4 seq 10 permit 192.0.2.128/28 ge 32 le 32
    ip prefix-list cluster_none4 seq 5 deny any
    ipv6 prefix-list cluster_vips6 seq 5 permit fd11:1::/64 ge 128 le 128
    ipv6 prefix-list cluster_vips6 seq 10 permit fd20:db8:2::/112 ge 128 le 128
    ipv6 prefix-list cluster_none6 seq 5 deny any
    route-map cluster_in4 permit 10
     match ip address prefix-list cluster_vips4
    exit
    route-map cluster_out4 permit 10
     match ip address prefix-list cluster_none4
    exit
    route-map cluster_in6 permit 10
     match ipv6 address prefix-list cluster_vips6
    exit
    route-map cluster_out6 permit 10
     match ipv6 address prefix-list cluster_none6
    exit
    router bgp 65001
     bgp router-id 192.168.1.3
     no bgp default ipv4-unicast
     bgp ebgp-requires-policy
     bgp bestpath as-path multipath-relax
    ${lib.concatMapStringsSep "\n" routerNeighbor [
      {
        address = "192.168.1.1";
        node = "alpha";
        family = 4;
      }
      {
        address = "192.168.1.2";
        node = "beta";
        family = 4;
      }
      {
        address = "2001:db8:1::1";
        node = "alpha";
        family = 6;
      }
      {
        address = "2001:db8:1::2";
        node = "beta";
        family = 6;
      }
    ]}
  '';

  # The shared-bgp probe (D9/D10): draws from the DEFAULT fabric pool with
  # the BGP-advertised class and a pinned VIP; with a DaemonSet backend and
  # ETP Local, EVERY healthy node advertises it (router ECMPs).
  fabricService = kube.render.mkLBService {
    name = "httpbin-fabric";
    inherit manifestLabels;
    labels."clan.lol/pool" = "${distro}-fabric";
    annotations."lbipam.cilium.io/ips" = "172.16.1.80,fd11:1:0:0:0:0:0:80";
    loadBalancerClass = "io.cilium/bgp-control-plane";
    ports = [
      {
        port = 80;
        targetPort = 8080;
      }
    ];
    selector.app = "httpbin";
    extraSpec = {
      ipFamilies = [
        "IPv4"
        "IPv6"
      ];
      ipFamilyPolicy = "RequireDualStack";
    };
  };

  nodeService = kube.render.mkLBService {
    name = "httpbin-node";
    inherit manifestLabels;
    labels."clan.lol/pool" = "nodepool";
    annotations."lbipam.cilium.io/ips" = "192.0.2.130,fd20:db8:2::130";
    loadBalancerClass = "io.cilium/bgp-control-plane";
    ports = [
      {
        port = 80;
        targetPort = 8080;
      }
    ];
    selector.app = "httpbin";
    extraSpec = {
      ipFamilies = [
        "IPv4"
        "IPv6"
      ];
      ipFamilyPolicy = "RequireDualStack";
    };
  };

  # Cluster-level settings, identical on every role (cross-role parity is
  # eval-asserted).
  clusterSettings = {
    network.fabric = {
      service = "routed-fabric";
      instance = "mesh";
    };
    # Pinned id (§6.2): keeps CIDRs/clusterDNS/HAProxy ports and the fabric
    # pool blocks (172.16.1.0/24 + fd11:1::/64) stable.
    cilium.id = 1;
    # The upstream-facing underlay joins the complete fabric device set for
    # VIP ingress from the foreign router.
    cilium.helmValues.devices = "${fabricLoopback} ${fabricLink} eth1";
    pools = {
      inherit (fixtures.pools) dataplane floaty;
      nodepool = {
        blocks = [
          "192.0.2.128/28"
          "fd20:db8:2::/112"
        ];
        serviceSelector."clan.lol/pool" = "nodepool";
        delivery = "node-bgp";
        owner = "beta";
      };
    };
  };

  probesJson = builtins.toJSON {
    apiVersion = "v1";
    kind = "List";
    items = [
      httpbinDaemonSet
      poolService
      fabricService
      nodeService
      floatService
      httpbinPinned
      classlessService
      clientDaemonSet
      clusterIPService
      classlessAllService
    ];
  };
in {
  name = suiteName;

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules.routed-fabric = lib.modules.importApply ../../../../services/routed-fabric/default.nix {
      ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
    };
    exportInterfaces = {
      routed_fabric = ../../../../services/routed-fabric/routed-fabric-interface.nix;
      node_transport = ../../../../lib/node-transport-interface.nix;
    };

    inventory = {
      meta.domain = "test.clan";

      machines = {
        alpha = {};
        beta = {};
        # The foreign router joins NO service instance; inventory
        # membership only gives the test node the clan machine base.
        router = {};
      };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = {
            alpha.settings.host = "alpha";
            beta.settings.host = "beta";
          };
        };

        mesh = {
          module.name = "routed-fabric";
          module.input = "self";
          # Default Round-17 shape: one spine and one Kubernetes leaf;
          # border configuration remains orthogonal on both nodes (D59).
          roles = {
            # one LAN: the fast timers (the default between sites is `wan`)
            spine.settings.site = "lab";
            leaf.settings.site = "lab";
            spine.machines = {
              alpha.settings = {
                ipv4 = "192.168.77.1";
                ipv6 = "fd77::1";
                endpoint = "192.168.1.1";
                endpointSources = [
                  {
                    service = "clan-core/internet";
                    instance = "underlay";
                  }
                ];
                border = {
                  ownedPrefixes = [
                    "172.16.0.0/12"
                    "fd11::/16"
                    "192.0.2.128/28"
                    "fd20:db8:2::/112"
                  ];
                  upstreamPeers = [
                    {
                      address = "192.168.1.3";
                      asn = 65001;
                    }
                    {
                      address = "2001:db8:1::3";
                      asn = 65001;
                    }
                  ];
                };
              };
            };
            leaf.machines = {
              beta.settings = {
                ipv4 = "192.168.77.2";
                ipv6 = "fd77::2";
                endpoint = "192.168.1.2";
                endpointSources = [
                  {
                    service = "clan-core/internet";
                    instance = "underlay";
                  }
                ];
                border = {
                  ownedPrefixes = [
                    "172.16.0.0/12"
                    "fd11::/16"
                    "192.0.2.128/28"
                    "fd20:db8:2::/112"
                  ];
                  upstreamPeers = [
                    {
                      address = "192.168.1.3";
                      asn = 65001;
                    }
                    {
                      address = "2001:db8:1::3";
                      asn = 65001;
                    }
                  ];
                };
              };
            };
          };
        };

        ${distro} = {
          module.name = distro;
          module.input = "self";

          # Cluster-level settings are role-uniform (eval-asserted): one
          # shared attrset for server and agent.
          roles.server = {
            settings = clusterSettings;
            machines.alpha.settings.clusterInit = true;
          };

          roles.agent = {
            settings = clusterSettings;
            machines.beta = {};
          };
        };
      };
    };
  };

  nodes = let
    commonNode = {pkgs, ...}: {
      virtualisation = {
        cores = 2;
        memorySize =
          if k3s
          then 3584
          else 4096;
        diskSize = 8192;
      };

      environment.systemPackages = [
        pkgs.kubectl
        pkgs.cilium-cli
        pkgs.cri-tools
        pkgs.iptables
        pkgs.socat
        pkgs.tcpdump
        pkgs.curl
        pkgs.jq
      ];
      services.${distro}.images = [(busyboxImage pkgs)];
      systemd.tmpfiles.rules = lib.optionals (!k3s) [(fixtures.rke2ImageLink (busyboxImage pkgs))];
    };
  in {
    alpha = {...}: {
      imports =
        [commonNode]
        ++ fixture [
          "192.168.1.1/24"
          "2001:db8:1::1/64"
        ];
      environment.sessionVariables.KUBECONFIG = "/etc/rancher/${distro}/${distro}.yaml";
      environment.etc."data-plane/probes.json".text = probesJson;
      # Airgap: the workload fixture image (distro + Cilium airgap
      # images come from the service's defaults).
      services.${distro}.images = [httpbinImage];
      systemd.tmpfiles.rules = rke2ImageLinks;
    };
    beta = {...}: {
      imports =
        [commonNode]
        ++ fixture [
          "192.168.1.2/24"
          "2001:db8:1::2/64"
        ];
      # The httpbin DaemonSet schedules on every node — preload the
      # fixture image here too (hermetic).
      services.${distro}.images = [httpbinImage];
      systemd.tmpfiles.rules = rke2ImageLinks;
    };

    # The foreign router (D9 contract fixture): FRR with strict exact-VIP
    # import policy, not part of the fabric or cluster inventory.
    router = {pkgs, ...}: {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
          addresses = [
            "192.168.1.3/24"
            "2001:db8:1::3/64"
          ];
          withBase = true;
        })
      ];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
      };
      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
        pkgs.dnsutils
      ];
      services.frr = {
        bgpd.enable = true;
        bfdd.enable = true;
        config = routerFrrConf;
      };
      # The router is a host here (it curls the VIPs itself); forwarding
      # is not part of the fixture.
      networking.firewall.enable = false;
    };
  };

  testScript = ''
    import json
    import time

    ${netifHelpers}FABRIC = {"alpha": ("192.168.77.1", "fd77::1"), "beta": ("192.168.77.2", "fd77::2")}
    UNDERLAY = {"alpha": ("192.168.1.1", "2001:db8:1::1"), "beta": ("192.168.1.2", "2001:db8:1::2")}
    HOST_HTTP = "curl -sf --max-time 5 -o /dev/null "


    def url(ip, port=80, path="/get"):
        host = f"[{ip}]" if ":" in ip else ip
        return f"http://{host}:{port}{path}"


    def pod_on(node, app, namespace="default"):
        return alpha.succeed(
            f"kubectl -n {namespace} get pod -l {app} --field-selector spec.nodeName={node},status.phase=Running"
            " -o jsonpath='{.items[0].metadata.name}'"
        ).strip()


    def pod_ips(pod):
        ips = alpha.succeed("kubectl get pod " + pod + " -o jsonpath='{.status.podIPs[*].ip}'").split()
        return next(ip for ip in ips if ":" not in ip), next(ip for ip in ips if ":" in ip)


    def from_pod(pod, target):
        """A shell command: fetch `target` from inside `pod`."""
        return f"kubectl exec {pod} -- wget -q -T 5 -O - '{target}'"


    def backends(pod, target, wanted, tries=80):
        """The httpbin pods that answer `target`, asked from `pod`."""
        seen = set()
        for _ in range(tries):
            seen.add(json.loads(alpha.succeed(from_pod(pod, target)))["hostname"])
            if seen == wanted:
                break
        return seen


    def seconds_until(cmd, limit=120):
        """Seconds until `cmd` succeeds on alpha, or None."""
        started = time.time()
        while time.time() - started < limit:
            if alpha.execute(cmd + " 2>/dev/null")[0] == 0:
                return round(time.time() - started, 1)
            time.sleep(0.5)
        return None


    def seconds_until_only(pod, target, wanted, limit=180, streak=20):
        """Seconds until `target`, asked from `pod`, is answered `streak`
        times in a row and only by the httpbin pod `wanted`; or None."""
        started = time.time()
        run = 0
        while time.time() - started < limit:
            status, out = alpha.execute(from_pod(pod, target))
            run = run + 1 if status == 0 and json.loads(out)["hostname"] == wanted else 0
            if run == streak:
                return round(time.time() - started, 1)
        return None


    def lb_ingress(service):
        return sorted(
            alpha.succeed(
                "kubectl get service " + service + " -o jsonpath='{.status.loadBalancer.ingress[*].ip}'"
            ).split()
        )


    def fail_dump(m):
        for cmd in [
            "journalctl -u ${serverUnit} --no-pager -l | tail -n 80",
            "journalctl -u ${bootstrapUnit} --no-pager -l | tail -n 60 >&2 || true",
            "journalctl -u frr --no-pager -l | tail -n 100 >&2 || true",
            "vtysh -c 'show bgp summary' >&2 || true",
            "vtysh -c 'show ip route' >&2 || true; vtysh -c 'show ipv6 route' >&2 || true",
            "journalctl -u haproxy --no-pager -l | tail -n 40 >&2",
            "kubectl get nodes,pods -A -o wide >&2 || true",
            "kubectl describe pods -n kube-system -l k8s-app=cilium >&2 || true",
            "kubectl logs -n kube-system -l k8s-app=cilium -c cilium-agent --previous --tail=300 >&2 || true",
            "crictl images >&2 || true",
            "kubectl get service,endpoints,endpointslices -A -o wide >&2 || true",
            "kubectl get ciliumloadbalancerippools,ciliumbgpclusterconfigs,ciliumbgppeerconfigs,ciliumbgpadvertisements -A >&2 || true",
            "kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.enable-node-ipam}{\"\\n\"}{.data.default-lb-service-ipam}' >&2 || true",
            "kubectl -n kube-system exec ds/cilium -- cilium-dbg shell -- bgp/peers >&2 || true",
            "kubectl -n kube-system exec ds/cilium -- cilium-dbg service list >&2 || true",
            "nft list chain inet nixos-fw input >&2 || true",
            "wg show >&2 || true",
            "pkill -INT tcpdump >&2 || true; sleep 1; tcpdump -nn -r /tmp/fabric.pcap >&2 || true; cat /tmp/tcpdump.log >&2 || true",
            "ip route get ${betaTransfer} >&2; ping -c2 -W2 ${betaTransfer} >&2 || true",
            "ip -br addr >&2; ip rule >&2; ss -ulnp >&2",
            "iptables-save >&2 || true; ip6tables-save >&2 || true",
            "ip route >&2; ip -6 route >&2",
            "kubectl logs -n kube-system -l k8s-app=cilium --tail=200 >&2 || true",
            "kubectl logs -n kube-system -l k8s-app=cilium-operator --tail=200 >&2 || true",
            "kubectl get events -A --sort-by=.lastTimestamp | tail -n 120 >&2 || true",
            "cilium status >&2 || true",
        ]:
            m.execute(cmd)

    def safe_dump(m):
        try:
            fail_dump(m)
        except Exception:
            pass

    try:
        start_all()

        with subtest("underlay, FRR and WireGuard come up"):
            for m in [alpha, beta]:
                m.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
                m.wait_for_unit("haproxy.service", timeout=240)
                m.wait_for_unit("frr.service", timeout=240)
                m.wait_until_succeeds("wg show interfaces | grep '^rf' >/dev/null", timeout=120)
                m.wait_until_succeeds(
                    "wg show all latest-handshakes | awk '$3 > 0 { ok = 1 } END { exit !ok }'",
                    timeout=120,
                )
                m.fail("journalctl -u frr --no-pager | grep -E 'Unknown command|processing failure'")

            router.wait_for_unit("frr.service", timeout=240)

        with subtest("dual-stack addresses and fabric transport"):
            # Stable dual-stack node addresses and point-to-point transport.
            for m, ipv4, ipv6 in [(alpha, "192.168.77.1", "fd77::1"), (beta, "192.168.77.2", "fd77::2")]:
                m.succeed(f"ip -br addr | grep '{ipv4}/32' >/dev/null")
                m.succeed(f"ip -br addr | grep '{ipv6}/128' >/dev/null")
            for m in [alpha, beta]:
                m.succeed("command -v tcpdump")
                m.execute("rm -f /tmp/fabric.pcap; tcpdump -i any -nn -c 40 -w /tmp/fabric.pcap 'icmp or tcp port 179 or udp port ${toString fabricPort}' >/tmp/tcpdump.log 2>&1 &")
            alpha.succeed("ip route get ${betaTransfer} | grep 'dev rf' >/dev/null")
            alpha.wait_until_succeeds("ping -c2 -W2 ${betaTransfer}", timeout=120)
            alpha.wait_until_succeeds("ping -c2 -W2 192.168.77.2", timeout=120)
            alpha.wait_until_succeeds("ping -6 -c2 -W2 fd77::2", timeout=120)
            beta.wait_until_succeeds("ping -c2 -W2 192.168.77.1", timeout=120)
            beta.wait_until_succeeds("ping -6 -c2 -W2 fd77::1", timeout=120)

        with subtest("cluster starts and the bootstrap bundle applies"):
            alpha.wait_for_unit("${serverUnit}.service", timeout=600)
            beta.wait_for_unit("${agentUnit}.service", timeout=600)

            # --- Bootstrap contract: the bundle was applied by the oneshot ---
            alpha.wait_until_succeeds(
                "systemctl show -p Result --value ${bootstrapUnit} | grep '^success$' >/dev/null",
                timeout=900,
            )
            alpha.succeed("test -f /etc/clan-bootstrap/${distro}/bundle.yaml")
            alpha.wait_until_succeeds("kubectl get ciliumloadbalancerippools | grep dataplane >/dev/null", timeout=300)
            alpha.wait_until_succeeds("kubectl get ciliumloadbalancerippools | grep '^alpha' >/dev/null", timeout=300)
            alpha.wait_until_succeeds("kubectl get ciliumloadbalancerippools | grep '^beta' >/dev/null", timeout=300)
            alpha.wait_until_succeeds("kubectl get ciliumloadbalancerippools | grep ${distro}-fabric >/dev/null", timeout=300)
            alpha.wait_until_succeeds("kubectl get ciliumbgpclusterconfigs | grep ${distro}-alpha >/dev/null", timeout=300)
            alpha.wait_until_succeeds("kubectl get ciliumbgppeerconfigs | grep ${distro}-alpha-frr >/dev/null", timeout=300)
            alpha.wait_until_succeeds("kubectl get ciliumbgpadvertisements | grep ${distro}-alpha-service-vips >/dev/null", timeout=300)
            alpha.wait_until_succeeds("kubectl get ciliumbgpadvertisements | grep ${distro}-beta-node-vips >/dev/null", timeout=300)
            alpha.fail("kubectl get ciliumbgpadvertisements | grep ${distro}-alpha-node-vips >/dev/null")

        with subtest("nodes Ready, native-routed Cilium and BGP sessions up"):
            # --- Both nodes Ready, Cilium healthy --------------------------
            alpha.wait_until_succeeds(
                "kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s",
                timeout=300,
            )
            alpha.wait_until_succeeds("cilium status", timeout=180)
            alpha.wait_until_succeeds(
                "kubectl -n kube-system rollout status daemonset/cilium --timeout=120s",
                timeout=180,
            )
            alpha.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.routing-mode}' | grep '^native$' >/dev/null")
            alpha.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.auto-direct-node-routes}' | grep '^false$' >/dev/null")
            alpha.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.direct-routing-device}' | grep '^${fabricLoopback}$' >/dev/null")
            alpha.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.install-iptables-rules}' | grep '^true$' >/dev/null")

            for m in [alpha, beta]:
                m.wait_until_succeeds("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^5$' >/dev/null", timeout=300)
                m.wait_until_succeeds("vtysh -c 'show bfd peers brief' | grep -c ' up ' | grep '^4$' >/dev/null", timeout=300)
                m.fail("ip link show cilium_vxlan")
                m.succeed("command -v iptables && command -v crictl")
                m.succeed("iptables --version | grep 'nf_tables' >/dev/null")
                m.succeed("iptables-save | grep 'CILIUM' >/dev/null")
                m.fail("iptables-save | grep -E 'KUBE-(SERVICES|PROXY|NODEPORTS|FORWARD|MARK-MASQ)'")
            router.wait_until_succeeds("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^4$' >/dev/null", timeout=300)

        with subtest("probe workload and pod routes over the fabric"):
            # --- Probe workload --------------------------------------------
            alpha.succeed("kubectl apply -f /etc/data-plane/probes.json")
            alpha.wait_until_succeeds(
                "kubectl wait --for=condition=Ready pod -l app=httpbin --timeout=180s",
                timeout=240,
            )
            alpha.wait_until_succeeds(
                "kubectl wait --for=condition=Ready pod -l app=httpbin-pinned --timeout=180s",
                timeout=240,
            )
            pinned_node = alpha.succeed(
                "kubectl get pod -l app=httpbin-pinned -o jsonpath='{.items[0].spec.nodeName}'"
            ).strip()
            assert pinned_node == "beta", f"pinned pod landed on {pinned_node!r}"

            for m in [alpha, beta]:
                m.wait_until_succeeds("ip route | grep -E '10[.]1[.][0-9]+[.]0/24.*dev rf'", timeout=180)
                m.wait_until_succeeds("ip -6 route | grep -E 'fd10:1:.*dev rf'", timeout=180)
                m.wait_until_succeeds("vtysh -c 'show ip route' | grep -E 'B>.*10[.]1[.][0-9]+[.]0/24'", timeout=180)
                m.wait_until_succeeds("vtysh -c 'show ipv6 route' | grep -E 'B>.*fd10:1:'", timeout=180)

            pinned_ips = alpha.succeed(
                "kubectl get pod -l app=httpbin-pinned -o jsonpath='{.items[0].status.podIPs[*].ip}'"
            ).strip().split()
            pinned4 = next(ip for ip in pinned_ips if ":" not in ip)
            pinned6 = next(ip for ip in pinned_ips if ":" in ip)
            alpha.wait_until_succeeds(f"curl -sf --max-time 5 http://{pinned4}:8080/get | grep '\"url\"' >/dev/null", timeout=120)
            alpha.wait_until_succeeds(f"curl -sf --max-time 5 http://[{pinned6}]:8080/get | grep '\"url\"' >/dev/null", timeout=120)

        with subtest("pod to pod across nodes: pod pools, pod MTU, a 200 KB body in both families"):
            # Ported from the tunnel suite (D72). The body is larger than
            # one packet: a pod MTU above the fabric path drops it.
            for ds in ["httpbin", "client"]:
                alpha.wait_until_succeeds(f"kubectl rollout status daemonset/{ds} --timeout=180s", timeout=240)
            # multi-pool IPAM: a slice of the pod pool for every node
            for name in ["alpha", "beta"]:
                alpha.succeed(
                    "kubectl get ciliumnode " + name + " -o json | jq -e '[.spec.ipam.pools.allocated[].cidrs[]]"
                    " | (any(test(\"^10[.]1[.]\")) and any(test(\"^fd10:1:\")))' >/dev/null"
                )
            web = {name: pod_on(name, "app=httpbin") for name in ["alpha", "beta"]}
            shell = {name: pod_on(name, "app=client") for name in ["alpha", "beta"]}
            ips = {name: pod_ips(web[name]) for name in ["alpha", "beta"]}
            for name, (ipv4, ipv6) in ips.items():
                assert ipv4.startswith("10.1."), f"{name} pod IPv4 {ipv4} is not from the pod pool"
                assert ipv6.startswith("fd10:1:"), f"{name} pod IPv6 {ipv6} is not from the pod pool"
            assert ips["alpha"][0].rsplit(".", 1)[0] != ips["beta"][0].rsplit(".", 1)[0], f"both nodes share one IPv4 slice: {ips!r}"
            # the pod MTU is Cilium's (the minimum transport MTU, D58) and
            # fits the fabric link
            mtu = alpha.succeed("kubectl -n kube-system get configmap cilium-config -o jsonpath='{.data.mtu}'").strip()
            assert mtu.isdigit(), f"cilium-config has no mtu: {mtu!r}"
            for node in [alpha, beta]:
                link_mtu = int(node.succeed("ip -j link show ${fabricLink} | jq '.[0].mtu'").strip())
                assert int(mtu) <= link_mtu, f"{node.name}: Cilium MTU {mtu} exceeds the fabric link MTU {link_mtu}"
            for name in ["alpha", "beta"]:
                pod_mtu = alpha.succeed(f"kubectl exec {shell[name]} -- cat /sys/class/net/eth0/mtu").strip()
                assert pod_mtu == mtu, f"pod MTU on {name} is {pod_mtu}, Cilium's is {mtu}"
            print(f"FINDING pod MTU {mtu}")
            for source, target in [("alpha", "beta"), ("beta", "alpha")]:
                for ip in ips[target]:
                    alpha.wait_until_succeeds(from_pod(shell[source], url(ip, 8080)) + " | grep '\"url\"' >/dev/null", timeout=120)
                    alpha.succeed(from_pod(shell[source], url(ip, 8080, "/bytes/200000")) + " | wc -c | grep -x 200000 >/dev/null")

        with subtest("ClusterIP Service from pods: both families, backends on both nodes, DNS"):
            cluster_ips = alpha.succeed("kubectl get service httpbin-cluster -o jsonpath='{.spec.clusterIPs[*]}'").split()
            assert len(cluster_ips) == 2 and ":" not in cluster_ips[0] and ":" in cluster_ips[1], f"ClusterIPs: {cluster_ips!r}"
            everyone = set(web.values())
            for name in ["alpha", "beta"]:
                for ip in cluster_ips:
                    alpha.wait_until_succeeds(from_pod(shell[name], url(ip)) + " >/dev/null", timeout=120)
                    seen = backends(shell[name], url(ip, 80, "/hostname"), everyone)
                    assert seen == everyone, f"{ip} from the pod on {name} reached {seen!r}, wanted {everyone!r}"
                alpha.wait_until_succeeds(
                    from_pod(shell[name], "http://httpbin-cluster.default.svc.cluster.local/get") + " | grep '\"url\"' >/dev/null",
                    timeout=120,
                )

        with subtest("LB-IPAM pool allocation"):
            # --- Pool allocation (io.cilium/bgp-control-plane + selector) -------------
            alpha.wait_until_succeeds(
                "kubectl get service httpbin-pool -o jsonpath='{.status.loadBalancer.ingress}' | grep 192.0.2.24 >/dev/null",
                timeout=240,
            )
            ingress = alpha.succeed(
                "kubectl get service httpbin-pool -o jsonpath='{.status.loadBalancer.ingress[*].ip}'"
            ).strip().split()
            vip4 = next((i for i in ingress if ":" not in i), None)
            vip6 = next((i for i in ingress if ":" in i), None)
            assert vip4 and (vip4.startswith("192.0.2.24") or vip4.startswith("192.0.2.25")), \
                f"pool service v4 ingress not from dataplane pool: {ingress!r}"
            assert vip6 and vip6.startswith("fd20:db8::"), \
                f"pool service v6 ingress not from dataplane pool: {ingress!r}"
            # Reachable from both nodes (ETP Local + a pod on every node).
            for m in [alpha, beta]:
                m.wait_until_succeeds(
                    f"curl -sf --max-time 5 http://{vip4}/get | grep '\"url\"' >/dev/null",
                    timeout=120,
                )
            alpha.succeed(f"curl -sf --max-time 5 http://[{vip6}]/get | grep '\"url\"' >/dev/null")

        with subtest("classless Service gets Node IPAM node IPs"):
            # --- Classless Service -> Node IPAM node IPs --------------------
            alpha.wait_until_succeeds(
                "kubectl get service httpbin-nodeipam -o jsonpath='{.status.loadBalancer.ingress}' | grep 192.168.77.2 >/dev/null",
                timeout=240,
            )
            ingress = alpha.succeed(
                "kubectl get service httpbin-nodeipam -o jsonpath='{.status.loadBalancer.ingress[*].ip}'"
            ).strip().split()
            # ETP-Local candidate restriction: the backend is pinned to beta,
            # so ONLY beta's mesh addresses may be advertised.
            assert "192.168.77.2" in ingress, f"beta v4 missing from nodeipam ingress: {ingress!r}"
            assert "fd77::2" in ingress, f"beta v6 missing from nodeipam ingress: {ingress!r}"
            assert "192.168.77.1" not in ingress, f"alpha v4 must NOT be advertised (no local endpoint): {ingress!r}"
            assert "fd77::1" not in ingress, f"alpha v6 must NOT be advertised: {ingress!r}"

            # Positive: the classless Service answers on beta's advertised IP.
            alpha.wait_until_succeeds(
                "curl -sf --max-time 5 http://192.168.77.2:81/get | grep '\"url\"' >/dev/null",
                timeout=120,
            )
            # ETP-Local negative: alpha is not a candidate — nothing answers on
            # alpha's mesh address for this Service.
            alpha.fail("curl -sf --max-time 5 http://192.168.77.1:81/get")
            # A backend on every node: every node's fabric addresses.
            alpha.wait_until_succeeds(
                "kubectl get service httpbin-nodeipam-all -o jsonpath='{.status.loadBalancer.ingress[*].ip}' | wc -w | grep -x 4 >/dev/null",
                timeout=240,
            )
            all_ingress = lb_ingress("httpbin-nodeipam-all")
            assert all_ingress == sorted(FABRIC["alpha"] + FABRIC["beta"]), f"httpbin-nodeipam-all ingress: {all_ingress!r}"
            for ip in FABRIC["alpha"]:
                beta.wait_until_succeeds(HOST_HTTP + url(ip, 83), timeout=120)
            for ip in FABRIC["beta"]:
                alpha.wait_until_succeeds(HOST_HTTP + url(ip, 83), timeout=120)
                alpha.wait_until_succeeds(from_pod(shell["alpha"], url(ip, 81)) + " >/dev/null", timeout=120)

        with subtest("shared-bgp ECMP to the foreign router"):
            # --- shared-bgp ECMP (D9/D10) -----------------------------------
            # The fabric probe drew its pinned VIP from the fabric pool.
            alpha.wait_until_succeeds(
                "kubectl get service httpbin-fabric -o jsonpath='{.status.loadBalancer.ingress}' | grep 172.16.1.80 >/dev/null",
                timeout=240,
            )
            # Every healthy node advertises the VIP (DaemonSet backend + ETP
            # Local); the router ECMPs across BOTH nodes (v4 and v6).
            router.wait_until_succeeds(
                "ip -j route show 172.16.1.80 | jq -e '.[0].nexthops | length == 2' >/dev/null",
                timeout=300,
            )
            router.wait_until_succeeds(
                "ip -j -6 route show fd11:1::80 | jq -e '.[0].nexthops | length == 2' >/dev/null",
                timeout=300,
            )
            # The internal ClusterMesh apiserver VIP (D60: offset 79 of the
            # fabric pool, internal-load-balancer exposure — auto on this
            # native transport) is advertised only by the voter running its
            # sole replica. Beta is an agent, not a second voter.
            alpha.wait_until_succeeds(
                "kubectl wait --for=condition=Ready pod -n kube-system -l k8s-app=clustermesh-apiserver --timeout=180s",
                timeout=300,
            )
            alpha.succeed(
                "kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.spec.externalTrafficPolicy}' | grep '^Local$' >/dev/null"
            )
            alpha.succeed(
                "kubectl -n kube-system get deployment clustermesh-apiserver -o jsonpath='{.spec.replicas}' | grep '^1$' >/dev/null"
            )
            alpha.succeed(
                "kubectl -n kube-system get pod -l k8s-app=clustermesh-apiserver -o jsonpath='{.items[0].spec.nodeName}' | grep '^alpha$' >/dev/null"
            )
            router.wait_until_succeeds(
                "ip -j route show 172.16.1.79 | jq -e '.[0].gateway == \"192.168.1.1\"' >/dev/null",
                timeout=300,
            )
            alpha.succeed(
                "kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.spec.ipFamilies[0]}' | grep '^IPv4$' >/dev/null"
            )
            # Round-trip from the router through the fabric.
            router.wait_until_succeeds(
                "curl -sf --max-time 5 http://172.16.1.80/get | grep '\"url\"' >/dev/null",
                timeout=120,
            )
            router.wait_until_succeeds(
                "curl -sf --max-time 5 http://[fd11:1::80]/get | grep '\"url\"' >/dev/null",
                timeout=120,
            )
            # The router imports ONLY pool VIPs: no pod CIDRs leak upstream.
            # ip route show exits zero with empty output, so assert on output.
            router.fail("ip route show 10.1.0.0/16 | grep . >/dev/null")
            router.fail("ip route show 10.2.0.0/16 | grep . >/dev/null")

        with subtest("node-bgp owner-only delivery"):
            # node-bgp: exactly beta advertises the owner-pinned VIPs.
            alpha.wait_until_succeeds(
                "kubectl get service httpbin-node -o jsonpath='{.status.loadBalancer.ingress}' | grep 192.0.2.130 >/dev/null",
                timeout=240,
            )
            router.wait_until_succeeds(
                "ip -j route show 192.0.2.130 | jq -e '.[0].gateway == \"192.168.1.2\"' >/dev/null",
                timeout=300,
            )
            router.wait_until_succeeds(
                "ip -j -6 route show fd20:db8:2::130 | jq -e '.[0].gateway == \"fe80::5054:ff:fe12:102\"' >/dev/null",
                timeout=300,
            )
            router.wait_until_succeeds(
                "curl -sf --max-time 5 http://192.0.2.130/get | grep '\"url\"' >/dev/null",
                timeout=120,
            )

        with subtest("floating-pool placement"):
            # --- Floating pool: documented blackhole window (D8) ------------
            # Allocation happened (LB IPAM) but no controller exists in the VM;
            # simulate the controller's placement on beta + upstream routing.
            alpha.wait_until_succeeds(
                "kubectl get service httpbin-float -o jsonpath='{.status.loadBalancer.ingress}' | grep 192.0.2.100 >/dev/null",
                timeout=240,
            )
            beta.succeed("ip addr add 192.0.2.100/32 dev lo")
            router.succeed("ip route add 192.0.2.100/32 via 192.168.1.2")
            router.wait_until_succeeds(
                "curl -sf --max-time 5 http://192.0.2.100:82/get | grep '\"url\"' >/dev/null",
                timeout=120,
            )

        with subtest("node firewall: the underlay is refused, the fabric opens the cluster's ports only"):
            # --- Firewall: positive + negative ------------------------------
            # Ported from the tunnel suite (D72): eth1 is a Cilium device
            # here too, so the same refusals must hold on the underlay.
            def nc(address, port):
                return f"nc -z -w3 {address} {port}"
            # A listener on a port nobody opens: the probe of a refusal is
            # only meaningful when something answers on the trusted path.
            beta.succeed("systemd-run --unit=probe-listener $(command -v socat) TCP6-LISTEN:9999,fork,reuseaddr EXEC:true")
            beta.wait_until_succeeds("ss -tln | grep ':9999 ' >/dev/null", timeout=30)
            for address in FABRIC["beta"]:
                # over the fabric: the kubelet, and no port the cluster
                # does not open (routed-fabric R5: the fabric links are
                # no trusted interfaces)
                alpha.succeed(nc(address, "10250"))
                alpha.fail(nc(address, "9999"))
            beta.succeed(nc("::1", "9999"))
            for address in UNDERLAY["beta"]:
                # on the underlay: nothing, from the other node or from outside
                for port in ["10250", "9999", "${apiLbPort}", "81", "83", "80"]:
                    alpha.fail(nc(address, port))
                    router.fail(nc(address, port))
            for address in UNDERLAY["alpha"]:
                for port in ["6443", "${apiLbPort}", "10250", "2379", "2380", "83"]:
                    beta.fail(nc(address, port))
                    router.fail(nc(address, port))
            # the same control-plane ports answer over the fabric
            for address in FABRIC["alpha"]:
                for port in ["6443", "${apiLbPort}", "10250"]:
                    beta.succeed(nc(address, port))
            beta.succeed("systemctl stop probe-listener")
            # D69: a NodePort answers on the node addresses (the fabric)
            # and on no other address. eth1 is a Cilium device, and Cilium
            # serves a NodePort in BPF before the NixOS firewall sees the
            # packet: `nodeport-addresses` keeps it off the underlay.
            node_port = alpha.succeed("kubectl get service httpbin-pool -o jsonpath='{.spec.ports[0].nodePort}'").strip()
            assert node_port.isdigit(), f"httpbin-pool has no NodePort: {node_port!r}"
            def http(address, port):
                host = f"[{address}]" if ":" in address else address
                return f"curl -sf --max-time 5 -o /dev/null http://{host}:{port}/get"
            for name in ["alpha", "beta"]:
                for address in FABRIC[name]:
                    alpha.wait_until_succeeds(http(address, node_port), timeout=60)
                    beta.wait_until_succeeds(http(address, node_port), timeout=60)
                for address in UNDERLAY[name]:
                    router.fail(http(address, node_port))
            for address in UNDERLAY["beta"]:
                alpha.fail(http(address, node_port))
            # The classless Service does not expose its LB port on the
            # untrusted underlay address; its Node-IPAM candidates are
            # fabric addresses.
            alpha.fail(http(UNDERLAY["beta"][0], 81))
            for m in [alpha, beta]:
                m.succeed("ss -tln | grep ':179 ' >/dev/null")
            # The expected upstream BGP listen is reachable; no legacy BIRD
            # listener or unrelated exposed port exists.
            router.wait_until_succeeds("nc -z -w3 192.168.1.1 179", timeout=60)
            router.fail("nc -z -w3 192.168.1.1 4179")

    ${netifPhase}    with subtest("beta dies: ETP-Local withdrawal and floating blackhole"):
            # --- ETP-Local withdrawal + floating blackhole (beta dies) ------
            beta.shutdown()
            # beta's BGP session drops; the router withdraws its nexthop and
            # converges to alpha only — the VIP stays reachable (round-trip +
            # failure behavior, §7).
            router.wait_until_succeeds(
                "ip -j route show 172.16.1.80 | jq -e '.[0].gateway == \"192.168.1.1\"' >/dev/null",
                timeout=300,
            )
            router.wait_until_succeeds(
                "curl -sf --max-time 5 http://172.16.1.80/get | grep '\"url\"' >/dev/null",
                timeout=180,
            )
            router.wait_until_succeeds(
                "ip -j -6 route show fd11:1::80 | jq -e '.[0].gateway == \"fe80::5054:ff:fe12:101\"' >/dev/null",
                timeout=300,
            )
            # The owner-only VIP withdraws rather than re-homing to alpha.
            router.wait_until_fails("ip route show 192.0.2.130 | grep . >/dev/null", timeout=300)
            router.wait_until_fails("ip -6 route show fd20:db8:2::130 | grep . >/dev/null", timeout=300)
            router.fail("curl -sf --max-time 5 http://192.0.2.130/get")
            # The floating VIP blackholes: no controller re-homes it. This
            # assertion DOCUMENTS the window (D8) — it must keep failing.
            router.fail("curl -sf --max-time 5 http://192.0.2.100:82/get")

        with subtest("beta is gone: the cluster notices, ClusterIP and Node IPAM drop it, alpha keeps working"):
            # Ported from the tunnel suite (D72).
            for ip in ips["alpha"]:
                alpha.succeed(from_pod(shell["alpha"], url(ip, 8080)) + " >/dev/null")
            noticed = seconds_until(
                "kubectl get node beta -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -x -E 'Unknown|False'",
                limit=180,
            )
            print(f"FINDING node beta NotReady after {noticed} s")
            assert noticed is not None, "the cluster did not notice the dead node"
            withdrawn = seconds_until(
                "kubectl get endpointslices -l kubernetes.io/service-name=httpbin-cluster -o json"
                " | jq -e '[.items[].endpoints[] | select(.conditions.ready) | .nodeName] | unique == [\"alpha\"]'",
                limit=300,
            )
            print(f"FINDING httpbin-cluster endpoints on beta not ready {withdrawn} s after NotReady")
            assert withdrawn is not None, "the dead node's endpoints stayed ready"
            # ClusterIP from a pod and from the node: only alpha's backend
            # answers now, 20 times in a row
            for target in cluster_ips:
                clean = seconds_until_only(shell["alpha"], url(target, 80, "/hostname"), web["alpha"])
                print(f"FINDING {target} served only by alpha's backend {clean} s after the endpoints")
                assert clean is not None, f"{target} still reaches the dead node's backend"
                alpha.succeed(HOST_HTTP + url(target))
            dns = seconds_until(from_pod(shell["alpha"], "http://httpbin-cluster.default.svc.cluster.local/get"), limit=120)
            print(f"FINDING cluster DNS and the Service by name answer {dns} s later")
            assert dns is not None, "no cluster DNS after the death"
            # Node IPAM withdraws the dead node
            shrunk = seconds_until(
                "kubectl get service httpbin-nodeipam-all -o jsonpath='{.status.loadBalancer.ingress[*].ip}' | wc -w | grep -x 2",
                limit=300,
            )
            print(f"FINDING Node IPAM withdrew beta {shrunk} s after the endpoints")
            assert shrunk is not None, "Node IPAM kept the dead node"
            assert lb_ingress("httpbin-nodeipam-all") == sorted(FABRIC["alpha"]), lb_ingress("httpbin-nodeipam-all")
            # the Service whose only backend was on beta has no address left
            assert lb_ingress("httpbin-nodeipam") == [], lb_ingress("httpbin-nodeipam")
            for ip in FABRIC["alpha"]:
                alpha.succeed(HOST_HTTP + url(ip, 83))
            # a new pod starts on alpha and uses the Service
            alpha.succeed("kubectl run after --image=busybox:1.36.1 --restart=Never --command -- sleep 3600")
            alpha.wait_until_succeeds("kubectl wait --for=condition=Ready pod/after --timeout=120s", timeout=180)
            alpha.succeed("kubectl get pod after -o jsonpath='{.spec.nodeName}' | grep -x alpha >/dev/null")
            for ip in cluster_ips:
                alpha.succeed(from_pod("after", url(ip)) + " >/dev/null")
        for machine in [alpha, beta]:
            print(f"FINDING guard drops on {machine.name} at the end of the suite: " + " | ".join(l.strip() for l in machine.succeed("nft list ruleset | awk '/^table inet (routed-fabric|kube)-/,/^}/' | grep 'counter packets [1-9]' || true").splitlines()))
        print("${lib.toUpper (lib.replaceStrings ["-"] ["_"] suiteName)}_OK")
    except Exception:
        safe_dump(alpha)
        safe_dump(beta)
        safe_dump(router)
        raise
  '';
}
