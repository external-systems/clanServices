# <distro>-data-plane-tunnel: the Data-plane contract (§3.2, D8, D41, D42,
# D58) on the tunnel transport: wireguard-mesh, Cilium VXLAN, no BGP and
# no FRR. The same workload and pools as <distro>-data-plane
# (data-plane-fixtures.nix), without the parts that need BGP delivery.
#
#   alpha (server) ── wg-mesh ── beta (agent)      client (no cluster,
#        └──────────── underlay vlan 1 ───────────────┘  no mesh)
#
# Phase by phase, against data-plane.nix (native routing):
#
#   native phase                         here
#   underlay, FRR and WireGuard          neutral: underlay and one wg-mesh
#                                        link; native-only: FRR, per-pair links
#   dual-stack addresses, transport      neutral: node addresses on wg-mesh
#   cluster starts, bundle applies       neutral; tunnel: NO fabric pool and
#                                        NO CiliumBGP* object is rendered
#   nodes Ready, Cilium profile          neutral; tunnel: routing-mode tunnel,
#                                        vxlan, MTU 1370, cilium_vxlan exists
#   probe workload, pod routes           neutral: pod pools, pod to pod;
#                                        native-only: FRR pod routes on rf*
#   (not in native)                      tunnel: pod to pod and ClusterIP from
#                                        pods, both families, both nodes
#   LB-IPAM pool allocation              neutral (D8 external-class)
#   classless Service, Node IPAM         neutral (D41)
#   shared-bgp ECMP                      native-only: needs BGP (D8, D9)
#   node-bgp owner-only                  native-only: needs BGP (D8)
#   floating-pool placement              neutral (D8 floating)
#   firewall positive and negative       neutral; tunnel: no BGP listener
#   netif under a live cluster           not here (data-plane-netif)
#   beta dies: ETP-Local withdrawal      BGP withdrawal is native-only; here
#                                        the Node NotReady, the EndpointSlice
#                                        and Node IPAM withdraw beta
#   beta dies: floating blackhole        neutral (D8)
#
# Shared by k3s and RKE2: services/{k3s,rke2}/tests/vm/data-plane-tunnel.nix
# are thin wrappers that pass `distro`. Every distro difference is a `k3s`
# branch.
{
  inputs,
  distro,
}: {lib, ...}: let
  k3s = distro == "k3s";
  suiteName = "${distro}-data-plane-tunnel";
  serverUnit =
    if k3s
    then "k3s"
    else "rke2-server";
  agentUnit =
    if k3s
    then "k3s"
    else "rke2-agent";
  bootstrapUnit = "${distro}-${distro}-bootstrap-apply";
  # the LB port of the kube API (7442 + cilium.id)
  apiLbPort = "7443";

  fixtures = import ./data-plane-fixtures.nix {inherit lib inputs distro;};
  inherit (fixtures) httpbinImage manifestLabels;
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

  # A pod with a shell on every node: the source of pod traffic.
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
  classlessAllService = lib.recursiveUpdate fixtures.classlessService {
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

  clusterSettings = {
    network.fabric = {
      service = "wireguard-mesh";
      instance = "mesh";
    };
    # Pinned id (§6.2): keeps CIDRs, clusterDNS and HAProxy ports stable.
    cilium.id = 1;
    # The underlay joins the device set, as in data-plane.nix: a floating
    # address arrives on the underlay, not through the mesh.
    cilium.helmValues.devices = "wg-mesh eth1";
    # No node-bgp and no shared-bgp pool: a tunnel transport has no BGP
    # delivery (D8), and the service refuses them at evaluation.
    inherit (fixtures) pools;
  };

  probesJson = builtins.toJSON {
    apiVersion = "v1";
    kind = "List";
    items = [
      httpbinDaemonSet
      clientDaemonSet
      clusterIPService
      fixtures.poolService
      fixtures.floatService
      fixtures.httpbinPinned
      fixtures.classlessService
      classlessAllService
    ];
  };

  members = {
    alpha = 1;
    beta = 2;
  };
in {
  name = suiteName;

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules.wireguard-mesh = lib.modules.importApply ../../../../services/wireguard-mesh/default.nix {
      ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
    };
    exportInterfaces.node_transport = ../../../node-transport-interface.nix;

    inventory = {
      meta.domain = "test.clan";

      machines = {
        alpha = {};
        beta = {};
        # Outside the mesh and the cluster; inventory membership only
        # gives the test node the clan machine base.
        client = {};
      };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = lib.mapAttrs (_: n: {settings.host = "192.168.1.${toString n}";}) members;
        };

        mesh = {
          module.name = "wireguard-mesh";
          module.input = "self";
          roles.peer = {
            settings.endpointSources = [
              {
                service = "clan-core/internet";
                instance = "underlay";
              }
            ];
            machines =
              lib.mapAttrs (_: n: {
                settings = {
                  ipv4 = "192.168.77.${toString n}";
                  ipv6 = "fd00:77::${toString n}";
                };
              })
              members;
          };
        };

        ${distro} = {
          module.name = distro;
          module.input = "self";
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
    clusterNode = name: {pkgs, ...}: let
      busyboxImage = pkgs.dockerTools.pullImage {
        imageName = "busybox";
        imageDigest = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662";
        hash = "sha256-OasmfjRQsuVWudSc4qWuMKK5nNz4hdIS8Si4B0okXEw=";
        finalImageTag = "1.36.1";
      };
      n = toString members.${name};
    in {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
          addresses = [
            "192.168.1.${n}/24"
            "2001:db8:1::${n}/64"
          ];
        })
      ];
      virtualisation = {
        cores = 2;
        memorySize =
          if k3s
          then 3584
          else 4096;
        diskSize = 8192;
      };
      environment = {
        sessionVariables.KUBECONFIG = "/etc/rancher/${distro}/${distro}.yaml";
        etc."data-plane/probes.json".text = probesJson;
        systemPackages = [
          pkgs.kubectl
          pkgs.cilium-cli
          pkgs.cri-tools
          pkgs.iptables
          pkgs.socat
          pkgs.tcpdump
          pkgs.curl
          pkgs.jq
        ];
      };
      # Airgap: the workload images (distro and Cilium airgap images come
      # from the service's defaults).
      services.${distro}.images = [
        httpbinImage
        busyboxImage
      ];
      systemd.tmpfiles.rules = lib.optionals (!k3s) (map fixtures.rke2ImageLink [httpbinImage busyboxImage]);
    };
  in {
    alpha = clusterNode "alpha";
    beta = clusterNode "beta";

    client = {pkgs, ...}: {
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
        pkgs.curl
        pkgs.jq
        pkgs.socat
      ];
      networking.firewall.enable = false;
    };
  };

  testScript = ''
    import json
    import time

    ${import ../../../../tests/suite-lib.nix}
    ${import ../../../../tests/ifstate-noop.nix}

    MESH = {"alpha": ("192.168.77.1", "fd00:77::1"), "beta": ("192.168.77.2", "fd00:77::2")}
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


    def ingress(service):
        return sorted(
            alpha.succeed(
                "kubectl get service " + service + " -o jsonpath='{.status.loadBalancer.ingress[*].ip}'"
            ).split()
        )


    cluster_dump = [
        "journalctl -u ${serverUnit} -u ${agentUnit} --no-pager -l | tail -n 80",
        "journalctl -u ${bootstrapUnit} --no-pager -l | tail -n 60",
        "journalctl -u haproxy --no-pager -l | tail -n 40",
        "wg show",
        "kubectl get nodes,pods -A -o wide",
        "kubectl get service,endpointslices -A -o wide",
        "kubectl get ciliumloadbalancerippools,ciliumpodippools,ciliumnodes -o wide",
        "kubectl get events -A --sort-by=.lastTimestamp | tail -n 80",
        "kubectl logs -n kube-system -l k8s-app=cilium --tail=120",
        "kubectl logs -n kube-system -l io.cilium/app=operator --tail=120",
        "timeout 20 cilium status",
        "crictl images",
    ]

    with state_dump_on_failure([alpha, beta, client], extra=cluster_dump):
        start_all()

        with subtest("versions"):
            print_versions(alpha, ["kernel", "ifstate", "wireguard", "nftables", "${distro}"])

        with subtest("underlay and the WireGuard mesh come up, no routing daemon"):
            for m in [alpha, beta]:
                m.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
                m.wait_for_unit("haproxy.service", timeout=240)
                m.wait_until_succeeds(
                    "wg show wg-mesh latest-handshakes | awk '$2 > 0 { ok = 1 } END { exit !ok }'",
                    timeout=120,
                )
                # one link for every peer, and no per-pair fabric link
                m.succeed("test \"$(wg show interfaces)\" = wg-mesh")
                # native-only: FRR. A tunnel transport runs no routing daemon.
                m.fail("systemctl cat frr.service")
                m.fail("command -v vtysh")
            client.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)

        with subtest("dual-stack node addresses over wg-mesh"):
            for m in [alpha, beta]:
                ipv4, ipv6 = MESH[m.name]
                m.succeed(f"ip -br addr show wg-mesh | grep '{ipv4}/32' >/dev/null")
                m.succeed(f"ip -br addr show wg-mesh | grep '{ipv6}/128' >/dev/null")
            for source, target in [(alpha, "beta"), (beta, "alpha")]:
                ipv4, ipv6 = MESH[target]
                source.succeed(f"ip route get {ipv4} | grep 'dev wg-mesh' >/dev/null")
                source.succeed(f"ip -6 route get {ipv6} | grep 'dev wg-mesh' >/dev/null")
                source.wait_until_succeeds(f"ping -c2 -W2 {ipv4}", timeout=120)
                source.wait_until_succeeds(f"ping -6 -c2 -W2 {ipv6}", timeout=120)
            # the client is outside the mesh
            client.fail("ping -c1 -W2 192.168.77.1")

        with subtest("cluster starts and the bootstrap bundle applies: pools, no BGP object"):
            alpha.wait_for_unit("${serverUnit}.service", timeout=600)
            beta.wait_for_unit("${agentUnit}.service", timeout=600)
            alpha.wait_until_succeeds(
                "systemctl show -p Result --value ${bootstrapUnit} | grep '^success$' >/dev/null",
                timeout=900,
            )
            alpha.succeed("test -f /etc/clan-bootstrap/${distro}/bundle.yaml")
            # the declared pools and one pool per node
            for pool in ["dataplane", "floaty", "alpha", "beta"]:
                alpha.wait_until_succeeds(f"kubectl get ciliumloadbalancerippools -o name | grep -x 'ciliumloadbalancerippool.cilium.io/{pool}' >/dev/null", timeout=300)
            # tunnel: the private fabric pool (D10) and the BGP resources
            # (D9) are not rendered, in the bundle or in the cluster
            alpha.succeed("kubectl get ciliumloadbalancerippools -o name | wc -l | grep -x 4 >/dev/null")
            alpha.fail("grep -E 'kind: CiliumBGP|${distro}-fabric' /etc/clan-bootstrap/${distro}/bundle.yaml")
            for kind in ["ciliumbgpclusterconfigs", "ciliumbgppeerconfigs", "ciliumbgpadvertisements"]:
                alpha.wait_until_succeeds(f"kubectl get crd {kind}.cilium.io", timeout=300)
                alpha.succeed(f"kubectl get {kind} -o name | wc -l | grep -x 0 >/dev/null")

        with subtest("nodes Ready, Cilium in VXLAN tunnel mode with Node IPAM and LB IPAM"):
            alpha.wait_until_succeeds(
                "kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s",
                timeout=300,
            )
            alpha.wait_until_succeeds("cilium status", timeout=180)
            alpha.wait_until_succeeds(
                "kubectl -n kube-system rollout status daemonset/cilium --timeout=120s",
                timeout=180,
            )
            # suite-lib's `cilium` entry asks the CLI; the agent knows its own version
            print("VERSION alpha cilium-agent: " + alpha.succeed("kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg version").strip())
            for key, value in [
                ("routing-mode", "tunnel"),
                ("tunnel-protocol", "vxlan"),
                ("mtu", "1370"),
                ("devices", "wg-mesh eth1"),
                ("direct-routing-device", "wg-mesh"),
                ("auto-direct-node-routes", "false"),
                ("install-iptables-rules", "true"),
                ("ipam", "multi-pool"),
                ("enable-node-ipam", "true"),
                ("default-lb-service-ipam", "nodeipam"),
                # registers the LB-IPAM class of explicit pools (D41), with
                # no BGP resource behind it
                ("enable-bgp-control-plane", "true"),
            ]:
                found = alpha.succeed(
                    "kubectl get configmap -n kube-system cilium-config -o json | jq -r --arg key " + key + " '.data[$key]'"
                ).strip()
                assert found == value, f"cilium-config {key}: {found!r}, wanted {value!r}"
            for name in ["alpha", "beta"]:
                addresses = alpha.succeed(
                    "kubectl get node " + name + " -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'"
                ).split()
                assert sorted(addresses) == sorted(MESH[name]), f"{name} InternalIP: {addresses!r}"
            for m in [alpha, beta]:
                m.succeed("ip link show cilium_vxlan")
                m.succeed("iptables --version | grep 'nf_tables' >/dev/null")
                m.succeed("iptables-save | grep 'CILIUM' >/dev/null")
                m.fail("iptables-save | grep -E 'KUBE-(SERVICES|PROXY|NODEPORTS|FORWARD|MARK-MASQ)'")
            # D42: no servicelb
            alpha.succeed("kubectl get pods -A -o name >/tmp/pods && test -s /tmp/pods && ! grep svclb /tmp/pods")

        with subtest("probe workload: pod pools, pod to pod across nodes in both families"):
            alpha.succeed("kubectl apply -f /etc/data-plane/probes.json")
            for app in ["httpbin", "client", "httpbin-pinned"]:
                alpha.wait_until_succeeds(
                    f"kubectl rollout status {'deployment' if app == 'httpbin-pinned' else 'daemonset'}/{app} --timeout=180s",
                    timeout=240,
                )
            pinned = pod_on("beta", "app=httpbin-pinned")
            # multi-pool IPAM: one pool, a slice of it for every node
            alpha.succeed(
                "kubectl get ciliumpodippools -o json | jq -e '[.items[].spec.ipv4.cidrs[]] == [\"10.1.0.0/16\"]' >/dev/null"
            )
            observe("pod pools", alpha, "kubectl get ciliumpodippools -o yaml | grep -A12 '^  spec:'")
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
            # the pod MTU is the tunnel MTU (wg-mesh 1420 - 50)
            for name in ["alpha", "beta"]:
                alpha.succeed(f"kubectl exec {shell[name]} -- cat /sys/class/net/eth0/mtu | grep -x 1370 >/dev/null")
            # pod to pod, across the nodes, both directions, both families,
            # and a body larger than one packet
            for source, target in [("alpha", "beta"), ("beta", "alpha")]:
                for ip in ips[target]:
                    alpha.wait_until_succeeds(from_pod(shell[source], url(ip, 8080)) + " | grep '\"url\"' >/dev/null", timeout=120)
                    alpha.succeed(from_pod(shell[source], url(ip, 8080, "/bytes/200000")) + " | wc -c | grep -x 200000 >/dev/null")
            # node to pod on the other node (the native suite's check)
            for ip in pod_ips(pinned):
                alpha.wait_until_succeeds(HOST_HTTP + url(ip, 8080), timeout=120)
            # the traffic between the nodes is VXLAN inside WireGuard: no
            # pod route points at the mesh link or the underlay
            for m in [alpha, beta]:
                m.fail("ip route show | grep -E '^10[.]1[.].* dev (wg-mesh|eth1)'")
                m.fail("ip -6 route show | grep -E '^fd10:1:.* dev (wg-mesh|eth1)'")
                m.succeed("ip -j -s link show cilium_vxlan | jq -e '.[0].stats64.rx.packets > 0 and .[0].stats64.tx.packets > 0' >/dev/null")
            observe("pod routes", alpha, "ip route show | grep -E '^10[.]1[.]'; ip -6 route show | grep -E '^fd10:1:'")

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
            # FINDING: CoreDNS's two replicas start before the second node is
            # Ready, so the soft anti-affinity (lib/kube-cluster/bundle.nix)
            # puts both on one node and nothing moves them later: if that
            # node dies, the cluster has no DNS. (A rollout restart moves
            # both to the other node, not one.) The suite deletes one, and
            # its replacement goes to the other node; the death phase
            # relies on that.
            observe("CoreDNS placement after bootstrap", alpha, "kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide")
            dns_nodes = alpha.succeed("kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].spec.nodeName}'").split()
            print(f"FINDING CoreDNS replicas after bootstrap are on {sorted(dns_nodes)}")
            assert len(dns_nodes) == 2, dns_nodes
            if len(set(dns_nodes)) == 1:
                alpha.succeed("kubectl -n kube-system delete --wait=true $(kubectl -n kube-system get pods -l k8s-app=kube-dns -o name | head -n1)")
                alpha.wait_until_succeeds("kubectl -n kube-system rollout status deployment/coredns --timeout=120s", timeout=180)
            alpha.wait_until_succeeds(
                "kubectl -n kube-system get pods -l k8s-app=kube-dns -o json"
                " | jq -e '[.items[] | select(.metadata.deletionTimestamp == null) | .spec.nodeName] | sort == [\"alpha\", \"beta\"]' >/dev/null",
                timeout=120,
            )
            for name in ["alpha", "beta"]:
                alpha.wait_until_succeeds(
                    from_pod(shell[name], "http://httpbin-cluster.default.svc.cluster.local/get") + " | grep '\"url\"' >/dev/null",
                    timeout=120,
                )

        with subtest("LB-IPAM pool allocation: an address from the pool, served inside the cluster"):
            alpha.wait_until_succeeds(
                "kubectl get service httpbin-pool -o jsonpath='{.status.loadBalancer.ingress}' | grep 192.0.2.24 >/dev/null",
                timeout=240,
            )
            pool = ingress("httpbin-pool")
            vip4 = next((i for i in pool if ":" not in i), None)
            vip6 = next((i for i in pool if ":" in i), None)
            assert vip4 and (vip4.startswith("192.0.2.24") or vip4.startswith("192.0.2.25")), \
                f"pool service v4 ingress not from dataplane pool: {pool!r}"
            assert vip6 and vip6.startswith("fd20:db8::"), \
                f"pool service v6 ingress not from dataplane pool: {pool!r}"
            # from both nodes and from pods on both nodes, both families
            for m in [alpha, beta]:
                for vip in [vip4, vip6]:
                    m.wait_until_succeeds(HOST_HTTP + url(vip), timeout=120)
                    alpha.wait_until_succeeds(from_pod(shell[m.name], url(vip)) + " >/dev/null", timeout=120)
            # external-class: allocation only. No node holds the address and
            # nothing announces it; delivery is the provider's work (D8).
            for m in [alpha, beta]:
                m.fail(f"ip -br addr | grep -F '{vip4}/'")
            client.fail(f"ip route get {vip4}")

        with subtest("classless Service gets Node IPAM node addresses"):
            alpha.wait_until_succeeds(
                "kubectl get service httpbin-nodeipam -o jsonpath='{.status.loadBalancer.ingress}' | grep 192.168.77.2 >/dev/null",
                timeout=240,
            )
            # ETP-Local candidate restriction: the backend is pinned to beta,
            # so only beta's node addresses are published
            pinned_ingress = ingress("httpbin-nodeipam")
            assert pinned_ingress == sorted(MESH["beta"]), f"httpbin-nodeipam ingress: {pinned_ingress!r}"
            # a backend on every node: every node's addresses
            alpha.wait_until_succeeds(
                "kubectl get service httpbin-nodeipam-all -o jsonpath='{.status.loadBalancer.ingress[*].ip}' | wc -w | grep -x 4 >/dev/null",
                timeout=240,
            )
            all_ingress = ingress("httpbin-nodeipam-all")
            assert all_ingress == sorted(MESH["alpha"] + MESH["beta"]), f"httpbin-nodeipam-all ingress: {all_ingress!r}"
            # the published addresses answer, over the mesh and from a pod
            for ip in MESH["beta"]:
                alpha.wait_until_succeeds(HOST_HTTP + url(ip, 81), timeout=120)
                alpha.wait_until_succeeds(from_pod(shell["alpha"], url(ip, 81)) + " >/dev/null", timeout=120)
            for ip in MESH["alpha"]:
                beta.wait_until_succeeds(HOST_HTTP + url(ip, 83), timeout=120)
            # alpha is no candidate of the pinned Service
            for ip in MESH["alpha"]:
                alpha.fail(HOST_HTTP + url(ip, 81))
                beta.fail(HOST_HTTP + url(ip, 81))

        with subtest("floating pool: allocation, an address placed by hand is served on the underlay"):
            alpha.wait_until_succeeds(
                "kubectl get service httpbin-float -o jsonpath='{.status.loadBalancer.ingress}' | grep 192.0.2.100 >/dev/null",
                timeout=240,
            )
            assert ingress("httpbin-float") == ["192.0.2.100", "fd20:db8:1::100"], ingress("httpbin-float")
            # no controller in the VM: place the address on beta as it
            # would, and route to it as the provider would
            client.fail(HOST_HTTP + url("192.0.2.100", 82))
            beta.succeed("ip addr add 192.0.2.100/32 dev lo; ip -6 addr add fd20:db8:1::100/128 dev lo")
            client.succeed("ip route add 192.0.2.100/32 via 192.168.1.2; ip -6 route add fd20:db8:1::100/128 via 2001:db8:1::2")
            for address in ["192.0.2.100", "fd20:db8:1::100"]:
                client.wait_until_succeeds(HOST_HTTP + url(address, 82), timeout=120)

        with subtest("node firewall: the underlay is refused, the mesh is trusted"):
            beta.succeed("systemd-run --unit=probe-listener $(command -v socat) TCP6-LISTEN:9999,fork,reuseaddr EXEC:true")
            beta.wait_until_succeeds("ss -tln | grep ':9999 ' >/dev/null", timeout=30)
            for ipv4, ipv6 in [MESH["beta"]]:
                # over the mesh: the kubelet and any other port (the mesh
                # link is a trusted interface)
                for port in ["10250", "9999"]:
                    alpha.succeed(f"nc -z -w3 {ipv4} {port}")
                    alpha.succeed(f"nc -z -w3 {ipv6} {port}")
            for address in UNDERLAY["beta"]:
                # on the underlay: nothing, from the other node or from outside
                for port in ["10250", "9999", "${apiLbPort}", "81", "83", "80"]:
                    alpha.fail(f"nc -z -w3 {address} {port}")
                    client.fail(f"nc -z -w3 {address} {port}")
            for address in UNDERLAY["alpha"]:
                for port in ["6443", "${apiLbPort}", "10250", "2379", "2380", "83"]:
                    beta.fail(f"nc -z -w3 {address} {port}")
                    client.fail(f"nc -z -w3 {address} {port}")
            # the same control-plane ports answer over the mesh
            for address in MESH["alpha"]:
                for port in ["6443", "${apiLbPort}", "10250"]:
                    beta.succeed(f"nc -z -w3 {address} {port}")
            # native-only: BGP. No listener here.
            for m in [alpha, beta]:
                m.fail("ss -tln | grep ':179 '")
            # the WireGuard port is the only UDP port the service opens
            observe("input rules", beta, "nft list chain inet nixos-fw input-allow")
            observe("udp listeners", beta, "ss -uln")
            # FINDING: a NodePort answers on the underlay address, from
            # outside the cluster. eth1 is a Cilium device here (as in
            # data-plane.nix), so Cilium serves the port in BPF before the
            # NixOS firewall sees the packet: the firewall does not guard
            # NodePorts on a link that is in `cilium.helmValues.devices`.
            node_port = alpha.succeed("kubectl get service httpbin-pool -o jsonpath='{.spec.ports[0].nodePort}'").strip()
            for address in [*UNDERLAY["beta"], *MESH["beta"]]:
                alpha.succeed(HOST_HTTP + url(address, node_port))
            for address in UNDERLAY["beta"]:
                client.succeed(HOST_HTTP + url(address, node_port))

        with subtest("an IfState reapply changes nothing on a live tunnel node"):
            for m in [alpha, beta]:
                assert_ifstate_noop(m)
            alpha.succeed("kubectl get nodes --no-headers | grep -c ' Ready ' | grep -x 2 >/dev/null")
            client.wait_until_succeeds(HOST_HTTP + url("192.0.2.100", 82), timeout=120)

        with subtest("beta dies: the cluster notices, alpha's pods keep working, the floating address blackholes"):
            agent = pod_on("alpha", "k8s-app=cilium", "kube-system")
            observe("cilium datapath", alpha, f"kubectl -n kube-system exec {agent} -c cilium-agent -- cilium-dbg status | grep -E 'KubeProxyReplacement|Host firewall|Routing|Masquerading'")
            # Cilium's own probes reach both nodes and their health endpoints
            alpha.wait_until_succeeds(
                f"kubectl -n kube-system exec {agent} -c cilium-agent -- cilium-health status --probe | grep 'Cluster health: *2/2 reachable' >/dev/null",
                timeout=120,
            )
            beta.crash()
            # pods on alpha reach each other at once
            for ip in ips["alpha"]:
                alpha.succeed(from_pod(shell["alpha"], url(ip, 8080)) + " >/dev/null")
            noticed = seconds_until(
                alpha,
                "kubectl get node beta -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -x Unknown",
                limit=150,
            )
            print(f"FINDING node beta NotReady after {noticed} s")
            assert noticed is not None, "the cluster did not notice the dead node"
            withdrawn = seconds_until(
                alpha,
                "kubectl get endpointslices -l kubernetes.io/service-name=httpbin-cluster -o json"
                " | jq -e '[.items[].endpoints[] | select(.conditions.ready) | .nodeName] | unique == [\"alpha\"]'",
                limit=300,
            )
            print(f"FINDING httpbin-cluster endpoints on beta not ready {withdrawn} s after NotReady")
            assert withdrawn is not None, "the dead node's endpoints stayed ready"
            # ClusterIP and the pool address, from a pod and from the node:
            # only alpha's backend answers now, 20 times in a row
            for target in [*cluster_ips, vip4, vip6]:
                clean = seconds_until_only(shell["alpha"], url(target, 80, "/hostname"), web["alpha"])
                print(f"FINDING {target} served only by alpha's backend {clean} s after the endpoints")
                assert clean is not None, f"{target} still reaches the dead node's backend"
                alpha.succeed(HOST_HTTP + url(target))
            observe("Cilium service table after the death", alpha, f"kubectl -n kube-system exec {agent} -c cilium-agent -- cilium-dbg service list")
            # cluster DNS: the replica on alpha answers
            dns = seconds_until(alpha, from_pod(shell["alpha"], "http://httpbin-cluster.default.svc.cluster.local/get"), limit=120, wanted='"url"')
            print(f"FINDING cluster DNS and the Service by name answer {dns} s later")
            assert dns is not None, "no cluster DNS after the death"
            # Node IPAM withdraws the dead node
            shrunk = seconds_until(
                alpha,
                "kubectl get service httpbin-nodeipam-all -o jsonpath='{.status.loadBalancer.ingress[*].ip}' | wc -w | grep -x 2",
                limit=300,
            )
            print(f"FINDING Node IPAM withdrew beta {shrunk} s after the endpoints")
            observe("Node IPAM after the death", alpha, "kubectl get service -o wide")
            assert shrunk is not None, "Node IPAM kept the dead node"
            assert ingress("httpbin-nodeipam-all") == sorted(MESH["alpha"]), ingress("httpbin-nodeipam-all")
            # the Service whose only backend was on beta has no address left
            assert ingress("httpbin-nodeipam") == [], ingress("httpbin-nodeipam")
            for ip in MESH["alpha"]:
                alpha.succeed(HOST_HTTP + url(ip, 83))
            # a new pod starts on alpha and uses the Service
            alpha.succeed("kubectl run after --image=busybox:1.36.1 --restart=Never --command -- sleep 3600")
            alpha.wait_until_succeeds("kubectl wait --for=condition=Ready pod/after --timeout=120s", timeout=180)
            alpha.succeed("kubectl get pod after -o jsonpath='{.spec.nodeName}' | grep -x alpha >/dev/null")
            for ip in cluster_ips:
                alpha.succeed(from_pod("after", url(ip)) + " >/dev/null")
            # The floating address blackholes: no controller re-homes it.
            # This assertion documents the window (D8): it must keep failing.
            for address in ["192.0.2.100", "fd20:db8:1::100"]:
                client.fail(HOST_HTTP + url(address, 82))
    print("${lib.toUpper (lib.replaceStrings ["-"] ["_"] suiteName)}_OK")
  '';
}
