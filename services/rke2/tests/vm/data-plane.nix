# rke2-data-plane: the Data-plane contract (§3.2, D41/D8/D9/D10, D44) over the
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
{ inputs }:
{ lib, ... }:
let
  kube = import ../../../../lib/kube-cluster { inherit lib; };
  fabric = import ../../../../lib/kube-cluster/fabric.nix { inherit lib; };
  fabricLink = fabric.adjacencyName (fabric.adjacencyKey "mesh" "alpha" "beta");
  nodeAsns = lib.genAttrs [ "alpha" "beta" ] (fabric.nodeAsn "mesh");

  httpbinVersions = import (inputs.pkgs + "/pkgs/go-httpbin/versions.nix");
  httpbinImageRef = "go-httpbin:v${httpbinVersions.version}";
  httpbinImage = inputs.pkgs.packages.x86_64-linux.image-go-httpbin;

  instanceName = "rke2";
  manifestLabels = kube.render.mkManifestLabels {
    inherit instanceName;
    component = "data-plane-test";
  };

  routerNeighbor =
    {
      address,
      node,
      family,
    }:
    ''
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

  # go-httpbin everywhere (DaemonSet) for the pool services.
  httpbinDaemonSet = {
    apiVersion = "apps/v1";
    kind = "DaemonSet";
    metadata.name = "httpbin";
    spec = {
      selector.matchLabels.app = "httpbin";
      template = {
        metadata.labels.app = "httpbin";
        spec.containers = [
          {
            name = "httpbin";
            image = httpbinImageRef;
            ports = [
              {
                name = "http";
                containerPort = 8080;
              }
            ];
          }
        ];
      };
    };
  };

  # Pool-allocation probe via the lib's LB Service helper (invariants 5/6:
  # ETP Local + io.cilium/bgp-control-plane pinned automatically).
  poolService = kube.render.mkLBService {
    name = "httpbin-pool";
    inherit manifestLabels;
    labels."clan.lol/pool" = "dataplane";
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

  # The shared-bgp probe (D9/D10): draws from the DEFAULT fabric pool with
  # the BGP-advertised class and a pinned VIP; with a DaemonSet backend and
  # ETP Local, EVERY healthy node advertises it (router ECMPs).
  fabricService = kube.render.mkLBService {
    name = "httpbin-fabric";
    inherit manifestLabels;
    labels."clan.lol/pool" = "rke2-fabric";
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

  # The floating-pool probe (D8): allocated from the floating pool (class
  # io.cilium/bgp-control-plane — never BGP-advertised). With no runtime controller
  # in the VM, the test places the VIP on beta by hand and documents the
  # blackhole window when beta dies.
  floatService = kube.render.mkLBService {
    name = "httpbin-float";
    inherit manifestLabels;
    labels."clan.lol/pool" = "floaty";
    annotations."lbipam.cilium.io/ips" = "192.0.2.100,fd20:db8:1::100";
    ports = [
      {
        port = 82;
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

  # The classless probe: backend pinned to beta only — Node IPAM must
  # advertise ONLY beta's addresses (ETP-Local candidate restriction).
  httpbinPinned = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata.name = "httpbin-pinned";
    spec = {
      replicas = 1;
      selector.matchLabels.app = "httpbin-pinned";
      template = {
        metadata.labels.app = "httpbin-pinned";
        spec = {
          nodeSelector."kubernetes.io/hostname" = "beta";
          containers = [
            {
              name = "httpbin";
              image = httpbinImageRef;
              ports = [
                {
                  name = "http";
                  containerPort = 8080;
                }
              ];
            }
          ];
        };
      };
    };
  };

  # Classless (no loadBalancerClass) ⇒ Node IPAM (D41). Not via the lib
  # helper — that one pins the pool class by design.
  classlessService = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "httpbin-nodeipam";
      labels = manifestLabels;
    };
    spec = {
      type = "LoadBalancer";
      externalTrafficPolicy = "Local";
      selector.app = "httpbin-pinned";
      ports = [
        {
          port = 81;
          targetPort = 8080;
        }
      ];
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
    cilium.helmValues.devices = "${fabricLink} eth1";
    pools = {
      # external-class needs no delivery machinery for an allocation proof.
      dataplane = {
        blocks = [
          "192.0.2.240/28"
          "fd20:db8::/120"
        ];
        serviceSelector."clan.lol/pool" = "dataplane";
        delivery = "external-class";
      };
      nodepool = {
        blocks = [
          "192.0.2.128/28"
          "fd20:db8:2::/112"
        ];
        serviceSelector."clan.lol/pool" = "nodepool";
        delivery = "node-bgp";
        owner = "beta";
      };
      # No runtime controller: the VM proves the floating blackhole window.
      floaty = {
        blocks = [
          "192.0.2.96/28"
          "fd20:db8:1::/112"
        ];
        serviceSelector."clan.lol/pool" = "floaty";
        delivery = "floating";
        candidates = [
          "alpha"
          "beta"
        ];
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
    ];
  };
in
{
  name = "rke2-data-plane";

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules.routed-fabric = ../../../routed-fabric/default.nix;
    exportInterfaces = {
      routed_fabric = ../../../routed-fabric/routed-fabric-interface.nix;
      node_transport = ../../../routed-fabric/node-transport-interface.nix;
    };

    inventory = {
      meta.domain = "test.clan";

      machines = {
        alpha = { };
        beta = { };
        # The foreign router joins NO service instance; inventory
        # membership only gives the test node the clan machine base.
        router = { };
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
          roles.hub.machines = {
            alpha.settings = {
              ipv4 = "192.168.77.1";
              ipv6 = "fd77::1";
              endpoint = "192.168.1.1";
              hubs = [ "beta" ];
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
            beta.settings = {
              ipv4 = "192.168.77.2";
              ipv6 = "fd77::2";
              endpoint = "192.168.1.2";
              hubs = [ "alpha" ];
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

        rke2 = {
          module.name = "rke2";
          module.input = "self";

          # Cluster-level settings are role-uniform (eval-asserted): one
          # shared attrset for server and agent.
          roles.server = {
            settings = clusterSettings;
            machines.alpha.settings.clusterInit = true;
          };

          roles.agent = {
            settings = clusterSettings;
            machines.beta = { };
          };
        };
      };
    };
  };

  nodes =
    let
      commonNode =
        { pkgs, ... }:
        {
          virtualisation = {
            cores = 2;
            memorySize = 4096;
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
        };
    in
    {
      alpha =
        { ... }:
        {
          imports = [ commonNode ];
          environment.sessionVariables.KUBECONFIG = "/etc/rancher/rke2/rke2.yaml";
          environment.etc."data-plane/probes.json".text = probesJson;
          # Airgap: the workload fixture image (distro + Cilium airgap
          # images come from the service's defaults). RKE2's runtime-image
          # loader scans the top level of the images dir, so add the
          # top-level symlink (same pattern as rke2-single).
          services.rke2.images = [ httpbinImage ];
          systemd.tmpfiles.rules = [
            "L+ /var/lib/rancher/rke2/agent/images/${builtins.unsafeDiscardStringContext (builtins.baseNameOf httpbinImage)} - - - - ${httpbinImage}"
          ];
        };
      beta =
        { ... }:
        {
          imports = [ commonNode ];
          # The httpbin DaemonSet schedules on every node — preload the
          # fixture image here too (hermetic).
          services.rke2.images = [ httpbinImage ];
          systemd.tmpfiles.rules = [
            "L+ /var/lib/rancher/rke2/agent/images/${builtins.unsafeDiscardStringContext (builtins.baseNameOf httpbinImage)} - - - - ${httpbinImage}"
          ];
        };

      # The foreign router (D9 contract fixture): FRR with strict exact-VIP
      # import policy, not part of the fabric or cluster inventory.
      router =
        { pkgs, ... }:
        {
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
    def fail_dump(m):
        for cmd in [
            "journalctl -u rke2-server --no-pager -l | tail -n 80",
            "journalctl -u rke2-rke2-bootstrap-apply --no-pager -l | tail -n 60 >&2 || true",
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
            "ip route get 100.179.155.123 >&2; ping -c2 -W2 100.179.155.123 >&2 || true",
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

        for m in [alpha, beta]:
            m.wait_for_unit("systemd-networkd.service", timeout=120)
            m.wait_for_unit("haproxy.service", timeout=240)
            m.wait_for_unit("frr.service", timeout=240)
            m.wait_until_succeeds("wg show interfaces | grep -q '^rf'", timeout=120)
            m.wait_until_succeeds(
                "wg show all latest-handshakes | awk '$2 > 0 { ok = 1 } END { exit !ok }'",
                timeout=120,
            )
            m.fail("journalctl -u frr --no-pager | grep -E 'Unknown command|processing failure'")

        router.wait_for_unit("frr.service", timeout=240)

        # Stable dual-stack node addresses and point-to-point transport.
        for m, ipv4, ipv6 in [(alpha, "192.168.77.1", "fd77::1"), (beta, "192.168.77.2", "fd77::2")]:
            m.succeed(f"ip -br addr | grep -q '{ipv4}/32'")
            m.succeed(f"ip -br addr | grep -q '{ipv6}/128'")
        for m in [alpha, beta]:
            m.succeed("command -v tcpdump")
            m.execute("rm -f /tmp/fabric.pcap; tcpdump -i any -nn -c 40 -w /tmp/fabric.pcap 'icmp or tcp port 179 or udp port 53344' >/tmp/tcpdump.log 2>&1 &")
        alpha.succeed("ip route get 100.179.155.123 | grep -q 'dev rf'")
        alpha.wait_until_succeeds("ping -c2 -W2 100.179.155.123", timeout=120)
        alpha.wait_until_succeeds("ping -c2 -W2 192.168.77.2", timeout=120)
        alpha.wait_until_succeeds("ping -6 -c2 -W2 fd77::2", timeout=120)
        beta.wait_until_succeeds("ping -c2 -W2 192.168.77.1", timeout=120)
        beta.wait_until_succeeds("ping -6 -c2 -W2 fd77::1", timeout=120)

        alpha.wait_for_unit("rke2-server.service", timeout=600)
        beta.wait_for_unit("rke2-agent.service", timeout=600)

        # --- Bootstrap contract: the bundle was applied by the oneshot ---
        alpha.wait_until_succeeds(
            "systemctl show -p Result --value rke2-rke2-bootstrap-apply | grep -q '^success$'",
            timeout=900,
        )
        alpha.succeed("test -f /etc/clan-bootstrap/rke2/bundle.yaml")
        alpha.wait_until_succeeds("kubectl get ciliumloadbalancerippools | grep -q dataplane", timeout=300)
        alpha.wait_until_succeeds("kubectl get ciliumloadbalancerippools | grep -q '^alpha'", timeout=300)
        alpha.wait_until_succeeds("kubectl get ciliumloadbalancerippools | grep -q '^beta'", timeout=300)
        alpha.wait_until_succeeds("kubectl get ciliumloadbalancerippools | grep -q rke2-fabric", timeout=300)
        alpha.wait_until_succeeds("kubectl get ciliumbgpclusterconfigs | grep -q rke2-alpha", timeout=300)
        alpha.wait_until_succeeds("kubectl get ciliumbgppeerconfigs | grep -q rke2-alpha-frr", timeout=300)
        alpha.wait_until_succeeds("kubectl get ciliumbgpadvertisements | grep -q rke2-alpha-service-vips", timeout=300)
        alpha.wait_until_succeeds("kubectl get ciliumbgpadvertisements | grep -q rke2-beta-node-vips", timeout=300)
        alpha.fail("kubectl get ciliumbgpadvertisements | grep -q rke2-alpha-node-vips")

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
        alpha.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.routing-mode}' | grep -q '^native$'")
        alpha.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.auto-direct-node-routes}' | grep -q '^false$'")
        alpha.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.direct-routing-device}' | grep -q '^${fabricLink}$'")
        alpha.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.install-iptables-rules}' | grep -q '^true$'")

        for m in [alpha, beta]:
            m.wait_until_succeeds("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep -q '^5$'", timeout=300)
            m.wait_until_succeeds("vtysh -c 'show bfd peers brief' | grep -c ' up ' | grep -q '^4$'", timeout=300)
            m.fail("ip link show cilium_vxlan")
            m.succeed("command -v iptables && command -v crictl")
            m.succeed("iptables --version | grep -q 'nf_tables'")
            m.succeed("iptables-save | grep -q 'CILIUM'")
            m.fail("iptables-save | grep -E 'KUBE-(SERVICES|PROXY|NODEPORTS|FORWARD|MARK-MASQ)'")
        router.wait_until_succeeds("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep -q '^4$'", timeout=300)

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
        alpha.wait_until_succeeds(f"curl -sf --max-time 5 http://{pinned4}:8080/get | grep -q '\"url\"'", timeout=120)
        alpha.wait_until_succeeds(f"curl -sf --max-time 5 http://[{pinned6}]:8080/get | grep -q '\"url\"'", timeout=120)

        # --- Pool allocation (io.cilium/bgp-control-plane + selector) -------------
        alpha.wait_until_succeeds(
            "kubectl get service httpbin-pool -o jsonpath='{.status.loadBalancer.ingress}' | grep -q 192.0.2.24",
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
                f"curl -sf --max-time 5 http://{vip4}/get | grep -q '\"url\"'",
                timeout=120,
            )
        alpha.succeed(f"curl -sf --max-time 5 http://[{vip6}]/get | grep -q '\"url\"'")

        # --- Classless Service -> Node IPAM node IPs --------------------
        alpha.wait_until_succeeds(
            "kubectl get service httpbin-nodeipam -o jsonpath='{.status.loadBalancer.ingress}' | grep -q 192.168.77.2",
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
            "curl -sf --max-time 5 http://192.168.77.2:81/get | grep -q '\"url\"'",
            timeout=120,
        )
        # ETP-Local negative: alpha is not a candidate — nothing answers on
        # alpha's mesh address for this Service.
        alpha.fail("curl -sf --max-time 5 http://192.168.77.1:81/get")

        # --- shared-bgp ECMP (D9/D10) -----------------------------------
        # The fabric probe drew its pinned VIP from the fabric pool.
        alpha.wait_until_succeeds(
            "kubectl get service httpbin-fabric -o jsonpath='{.status.loadBalancer.ingress}' | grep -q 172.16.1.80",
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
        # The private CoreDNS VIP (D10/D22 substrate) is advertised too
        # (2 replicas, one per node).
        router.wait_until_succeeds(
            "ip -j route show 172.16.1.53 | jq -e '.[0].nexthops | length == 2' >/dev/null",
            timeout=300,
        )
        # Round-trip from the router through the fabric.
        router.wait_until_succeeds(
            "curl -sf --max-time 5 http://172.16.1.80/get | grep -q '\"url\"'",
            timeout=120,
        )
        router.wait_until_succeeds(
            "curl -sf --max-time 5 http://[fd11:1::80]/get | grep -q '\"url\"'",
            timeout=120,
        )
        # The router imports ONLY pool VIPs: no pod CIDRs leak upstream.
        # ip route show exits zero with empty output, so assert on output.
        router.fail("ip route show 10.1.0.0/16 | grep -q .")
        router.fail("ip route show 10.2.0.0/16 | grep -q .")

        # node-bgp: exactly beta advertises the owner-pinned VIPs.
        alpha.wait_until_succeeds(
            "kubectl get service httpbin-node -o jsonpath='{.status.loadBalancer.ingress}' | grep -q 192.0.2.130",
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
            "curl -sf --max-time 5 http://192.0.2.130/get | grep -q '\"url\"'",
            timeout=120,
        )

        # --- Floating pool: documented blackhole window (D8) ------------
        # Allocation happened (LB IPAM) but no controller exists in the VM;
        # simulate the controller's placement on beta + upstream routing.
        alpha.wait_until_succeeds(
            "kubectl get service httpbin-float -o jsonpath='{.status.loadBalancer.ingress}' | grep -q 192.0.2.100",
            timeout=240,
        )
        beta.succeed("ip addr add 192.0.2.100/32 dev lo")
        alpha.succeed("ip route add 192.0.2.100/32 via 192.168.1.2")
        alpha.wait_until_succeeds(
            "curl -sf --max-time 5 http://192.0.2.100:82/get | grep -q '\"url\"'",
            timeout=120,
        )

        # --- Firewall: positive + negative ------------------------------
        alpha.fail("nc -z -w3 192.168.77.2 9999")
        # The classless Service does not expose its LB port on the untrusted
        # underlay address; its Node-IPAM candidates are fabric addresses.
        beta_underlay = beta.succeed(
            "ip -4 -o addr show dev eth1 | awk '{print $4}' | cut -d/ -f1 | head -n1"
        ).strip()
        alpha.fail(f"curl -sf --max-time 5 http://{beta_underlay}:81/get")
        for m in [alpha, beta]:
            m.succeed("ss -tln | grep -q ':179 '")
        # The expected upstream BGP listen is reachable; no legacy BIRD
        # listener or unrelated exposed port exists.
        router.wait_until_succeeds("nc -z -w3 192.168.1.1 179", timeout=60)
        router.fail("nc -z -w3 192.168.1.1 4179")

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
            "curl -sf --max-time 5 http://172.16.1.80/get | grep -q '\"url\"'",
            timeout=180,
        )
        router.wait_until_succeeds(
            "ip -j -6 route show fd11:1::80 | jq -e '.[0].gateway == \"fe80::5054:ff:fe12:101\"' >/dev/null",
            timeout=300,
        )
        # The owner-only VIP withdraws rather than re-homing to alpha.
        router.wait_until_fails("ip route show 192.0.2.130 | grep -q .", timeout=300)
        router.wait_until_fails("ip -6 route show fd20:db8:2::130 | grep -q .", timeout=300)
        router.fail("curl -sf --max-time 5 http://192.0.2.130/get")
        # The floating VIP blackholes: no controller re-homes it. This
        # assertion DOCUMENTS the window (D8) — it must keep failing.
        alpha.fail("curl -sf --max-time 5 http://192.0.2.100:82/get")
        print("RKE2_DATA_PLANE_OK")
    except Exception:
        safe_dump(alpha)
        safe_dump(beta)
        safe_dump(router)
        raise
  '';
}
