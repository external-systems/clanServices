# k3s-data-plane: the Data-plane contract (§3.2, D41/D8/D9/D10, D44) over the
# phase-3 bootstrap bundle (D40):
#   - cluster comes up via the bundle path (bootstrap-apply oneshot),
#   - pool allocation: a Service with loadBalancerClass io.cilium/lb-ipam
#     + the pool's selector draws from the declared CiliumLoadBalancerIPPool,
#   - classless Service (no class) gets node IPs via Node IPAM,
#   - ETP-Local candidate restriction: with the backend pinned to one node,
#     only that node's IPs are advertised,
#   - shared-bgp ECMP (D9/D10): the default fabric pool's VIPs are
#     advertised by ALL healthy nodes to a foreign-router fixture (BIRD);
#     the router ECMPs across both nodes,
#   - ETP-Local withdrawal: when beta dies, its advertisements withdraw and
#     the VIP stays reachable via alpha,
#   - floating-pool documented blackhole window (D8): no controller in the
#     VM, so the floating VIP dies with its holding node,
#   - firewall positive (LB port reachable where exposed) AND negative
#     (a nowhere-exposed port on the mesh address; the LB port on the
#     untrusted underlay interface; BGP :179 bound to the loopback link
#     alias only, never the underlay),
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

  httpbinVersions = import (inputs.pkgs + "/pkgs/go-httpbin/versions.nix");
  httpbinImageRef = "go-httpbin:v${httpbinVersions.version}";
  httpbinImage = inputs.pkgs.packages.x86_64-linux.image-go-httpbin;

  instanceName = "k3s";
  manifestLabels = kube.render.mkManifestLabels {
    inherit instanceName;
    component = "data-plane-test";
  };

  # The cluster's BIRD-side ASN (D9 derivation — pinned by
  # test_hashBgpAsnsPinnedValues).
  clusterBgpAsn = (kube.bgp.hashBgpAsns instanceName).bird;

  # Foreign-router fixture (D9 contract): plain BIRD accepting ONLY the
  # cluster's shared-bgp pool blocks as exact /32+/128, with max-prefix
  # limits and per-node passive neighbors; kernel export merges the
  # per-node paths into ECMP routes (merge paths — the BIRD equivalent of
  # the contract's "ECMP path count ≥ node count").
  routerBirdConf = ''
    router id 192.168.1.3;
    protocol device {
      scan time 10;
    }
    protocol kernel kernel4 {
      ipv4 { export all; };
      merge paths on;
    }
    protocol kernel kernel6 {
      ipv6 { export all; };
      merge paths on;
    }
    filter accept_cluster4 {
      if net ~ [ 172.16.1.0/24{32,32} ] then accept;
      else reject;
    }
    filter accept_cluster6 {
      if net ~ [ fd11:1::/64{128,128} ] then accept;
      else reject;
    }
    protocol bgp node_alpha {
      local as 65001;
      neighbor 192.168.1.1 as ${toString clusterBgpAsn};
      passive on;
      hold time 9;
      keepalive time 3;
      connect retry time 5;
      ipv4 {
        import filter accept_cluster4;
        import limit 100 action block;
        export none;
      };
    }
    protocol bgp node_beta {
      local as 65001;
      neighbor 192.168.1.2 as ${toString clusterBgpAsn};
      passive on;
      hold time 9;
      keepalive time 3;
      connect retry time 5;
      ipv4 {
        import filter accept_cluster4;
        import limit 100 action block;
        export none;
      };
    }
    protocol bgp node_alpha6 {
      local as 65001;
      neighbor 2001:db8:1::1 as ${toString clusterBgpAsn};
      passive on;
      hold time 9;
      keepalive time 3;
      connect retry time 5;
      ipv6 {
        import filter accept_cluster6;
        import limit 100 action block;
        export none;
      };
    }
    protocol bgp node_beta6 {
      local as 65001;
      neighbor 2001:db8:1::2 as ${toString clusterBgpAsn};
      passive on;
      hold time 9;
      keepalive time 3;
      connect retry time 5;
      ipv6 {
        import filter accept_cluster6;
        import limit 100 action block;
        export none;
      };
    }
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
        spec.containers.httpbin = {
          image = httpbinImageRef;
          ports.http.containerPort = 8080;
        };
      };
    };
  };

  # Pool-allocation probe via the lib's LB Service helper (invariants 5/6:
  # ETP Local + io.cilium/lb-ipam pinned automatically).
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
    labels."clan.lol/pool" = "k3s-fabric";
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

  # The floating-pool probe (D8): allocated from the floating pool (class
  # io.cilium/lb-ipam — never BGP-advertised). With no runtime controller
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
          containers.httpbin = {
            image = httpbinImageRef;
            ports.http.containerPort = 8080;
          };
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

  probesJson = builtins.toJSON [
    httpbinDaemonSet
    poolService
    fabricService
    floatService
    httpbinPinned
    classlessService
  ];
in
{
  name = "k3s-data-plane";

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules.wireguard-mesh = ../../../wireguard-mesh/default.nix;
    exportInterfaces.node_transport = ../../../wireguard-mesh/node-transport-interface.nix;

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
          module.name = "wireguard-mesh";
          module.input = "self";
          roles.peer = {
            settings.endpointSources = [
              {
                service = "clan-core/internet";
                instance = "underlay";
              }
            ];
            machines = {
              alpha.settings = {
                ipv4 = "192.168.77.1";
                ipv6 = "fd00:77::1";
              };
              beta.settings = {
                ipv4 = "192.168.77.2";
                ipv6 = "fd00:77::2";
              };
            };
          };
        };

        k3s = {
          module.name = "k3s";
          module.input = "self";

          roles.server = {
            settings = {
              network.transport = {
                service = "wireguard-mesh";
                instance = "mesh";
              };
              # Pinned id (§6.2): keeps CIDRs/clusterDNS/HAProxy ports and
              # the fabric pool blocks (172.16.1.0/24 + fd11:1::/64) stable.
              cilium.id = 1;
              # Test-only (documented): the upstream-facing interface must
              # be a Cilium device for VIP ingress from the router VM.
              cilium.helmValues.devices = "wg-mesh eth1";
              # D9: the node BIRD dials the foreign router (both families).
              bgp.upstreamPeers = [
                {
                  address = "192.168.1.3";
                  asn = 65001;
                }
                {
                  address = "2001:db8:1::3";
                  asn = 65001;
                }
              ];
              # Declared cluster-global pool (D8). external-class: no
              # delivery machinery needed for an allocation proof.
              pools.dataplane = {
                blocks = [
                  "192.0.2.240/28"
                  "fd20:db8::/120"
                ];
                serviceSelector."clan.lol/pool" = "dataplane";
                delivery = "external-class";
              };
              # Floating pool (D8): runtime-controller delivery; the VM
              # documents the no-controller blackhole window.
              pools.floaty = {
                blocks = [
                  "192.0.2.96/28"
                  "fd20:db8:1::/120"
                ];
                serviceSelector."clan.lol/pool" = "floaty";
                delivery = "floating";
                candidates = [
                  "alpha"
                  "beta"
                ];
              };
            };
            machines.alpha.settings.clusterInit = true;
          };

          roles.agent = {
            settings = {
              network.transport = {
                service = "wireguard-mesh";
                instance = "mesh";
              };
              cilium.id = 1;
              bgp.upstreamPeers = [
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
            memorySize = 3584;
            diskSize = 8192;
          };

          environment.systemPackages = [
            pkgs.kubectl
            pkgs.cilium-cli
            pkgs.socat
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
          environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
          environment.etc."data-plane/probes.json".text = probesJson;
          # Airgap: the workload fixture image (distro + Cilium airgap
          # images come from the service's defaults).
          services.k3s.images = [ httpbinImage ];
        };
      beta =
        { ... }:
        {
          imports = [ commonNode ];
          # The httpbin DaemonSet schedules on every node — preload the
          # fixture image here too (hermetic).
          services.k3s.images = [ httpbinImage ];
        };

      # The foreign router (D9 contract fixture): a plain BIRD, NOT part of
      # the clan inventory.
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
          services.bird = {
            enable = true;
            package = pkgs.bird2;
            # bird -p at build time — the fixture config is validated too.
            checkConfig = true;
            config = routerBirdConf;
          };
          # The router is a host here (it curls the VIPs itself); forwarding
          # is not part of the fixture.
          networking.firewall.enable = false;
        };
    };

  testScript = ''
    def fail_dump(m):
        for cmd in [
            "journalctl -u k3s --no-pager -l | tail -n 80",
            "journalctl -u k3s-k3s-bootstrap-apply --no-pager -l | tail -n 60 >&2 || true",
            "journalctl -u bird --no-pager -l | tail -n 60 >&2 || true",
            "journalctl -u haproxy --no-pager -l | tail -n 40 >&2",
            "kubectl get nodes,pods -A -o wide >&2 || true",
            "kubectl get service,endpoints,endpointslices -A -o wide >&2 || true",
            "kubectl get ciliumloadbalancerippools,ciliumbgpclusterconfigs,ciliumbgppeerconfigs,ciliumbgpadvertisements -A >&2 || true",
            "kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.enable-node-ipam}{\"\\n\"}{.data.default-lb-service-ipam}' >&2 || true",
            "kubectl -n kube-system exec ds/cilium -- cilium-dbg shell -- bgp/peers >&2 || true",
            "kubectl -n kube-system exec ds/cilium -- cilium-dbg service list >&2 || true",
            "nft list chain inet nixos-fw input >&2 || true",
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
            m.wait_for_unit("bird.service", timeout=240)

        router.wait_for_unit("bird.service", timeout=240)

        # --- Transport (§6.3): mesh v4+v6 on both nodes; remote node
        # InternalIPs reachable over the mesh in both families.
        for m, ipv4, ipv6 in [(alpha, "192.168.77.1", "fd00:77::1"), (beta, "192.168.77.2", "fd00:77::2")]:
            m.succeed(f"ip -br addr show wg-mesh | grep -q '{ipv4}/32'")
            m.succeed(f"ip -br addr show wg-mesh | grep -q '{ipv6}/128'")
        alpha.wait_until_succeeds("ping -c2 -W2 192.168.77.2", timeout=120)
        alpha.wait_until_succeeds("ping -6 -c2 -W2 fd00:77::2", timeout=120)
        beta.wait_until_succeeds("ping -c2 -W2 192.168.77.1", timeout=120)
        beta.wait_until_succeeds("ping -6 -c2 -W2 fd00:77::1", timeout=120)

        alpha.wait_for_unit("k3s.service", timeout=600)
        beta.wait_for_unit("k3s.service", timeout=600)

        # --- Bootstrap contract: the bundle was applied by the oneshot ---
        alpha.wait_until_succeeds(
            "systemctl show -p Result --value k3s-k3s-bootstrap-apply | grep -q '^success$'",
            timeout=900,
        )
        alpha.succeed("test -f /etc/clan-bootstrap/k3s/bundle.yaml")
        alpha.succeed("kubectl get ciliumloadbalancerippools | grep -q dataplane")
        # The auto per-machine node pools (D8) render for both members.
        alpha.succeed("kubectl get ciliumloadbalancerippools | grep -q '^alpha'")
        alpha.succeed("kubectl get ciliumloadbalancerippools | grep -q '^beta'")
        # D10: the default fabric pool + the D9 BGP v2 resources render.
        alpha.succeed("kubectl get ciliumloadbalancerippools | grep -q k3s-fabric")
        alpha.succeed("kubectl get ciliumbgpclusterconfigs | grep -q k3s-alpha")
        alpha.succeed("kubectl get ciliumbgppeerconfigs | grep -q k3s-bird")
        alpha.succeed("kubectl get ciliumbgpadvertisements | grep -q k3s-service-vips")

        # --- Both nodes Ready, Cilium healthy --------------------------
        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s",
            timeout=300,
        )
        alpha.wait_until_succeeds("cilium status", timeout=180)

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

        # --- Pool allocation (io.cilium/lb-ipam + selector) -------------
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
        assert "fd00:77::2" in ingress, f"beta v6 missing from nodeipam ingress: {ingress!r}"
        assert "192.168.77.1" not in ingress, f"alpha v4 must NOT be advertised (no local endpoint): {ingress!r}"
        assert "fd00:77::1" not in ingress, f"alpha v6 must NOT be advertised: {ingress!r}"

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
        # The router imports ONLY pool VIPs: no pod CIDRs leak (D13
        # default off).
        router.fail("ip route show 10.1.0.0/16")
        router.fail("ip route show 10.2.0.0/16")

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
        # Negative 1: a port nowhere exposed, on the mesh address.
        alpha.fail("nc -z -w3 192.168.77.2 9999")
        # Negative 2: the LB port on the untrusted underlay interface —
        # the classless Service advertises mesh IPs only.
        beta_underlay = beta.succeed(
            "ip -4 -o addr show scope global | grep -v wg-mesh | awk '{print $4}' | cut -d/ -f1 | head -n1"
        ).strip()
        alpha.fail(f"curl -sf --max-time 5 http://{beta_underlay}:81/get")
        # D9: BGP :179 listens ONLY on the loopback link alias — never on
        # the mesh or underlay addresses.
        for m in [alpha, beta]:
            m.succeed("ss -tln | grep -q '169.254.179.1:179 '")
            m.fail("ss -tln | grep ':179 ' | grep -v '169.254.179.1'")
        # BIRD's upstream-session listen artifact (wildcard :4179) is
        # firewall-dropped on the untrusted underlay.
        router.fail("nc -z -w3 192.168.1.1 4179")
        router.fail("nc -z -w3 192.168.1.1 179")

        # --- ETP-Local withdrawal + floating blackhole (beta dies) ------
        beta.shutdown()
        # beta's BGP session drops; the router withdraws its nexthop and
        # converges to alpha only — the VIP stays reachable (round-trip +
        # failure behavior, §7).
        router.wait_until_succeeds(
            "ip -j route show 172.16.1.80 | jq -e '.[0].nexthops | length == 1 and .[0].nexthops[0].via == \"192.168.1.1\"' >/dev/null",
            timeout=300,
        )
        router.wait_until_succeeds(
            "curl -sf --max-time 5 http://172.16.1.80/get | grep -q '\"url\"'",
            timeout=180,
        )
        # The floating VIP blackholes: no controller re-homes it. This
        # assertion DOCUMENTS the window (D8) — it must keep failing.
        alpha.fail("curl -sf --max-time 5 http://192.0.2.100:82/get")
    except Exception:
        safe_dump(alpha)
        safe_dump(beta)
        safe_dump(router)
        raise
  '';
}
