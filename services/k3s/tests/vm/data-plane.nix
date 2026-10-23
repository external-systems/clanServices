# k3s-data-plane: the Data-plane contract (§3.2, D41/D8, D44) over the
# phase-3 bootstrap bundle (D40):
#   - cluster comes up via the bundle path (bootstrap-apply oneshot),
#   - pool allocation: a Service with loadBalancerClass io.cilium/lb-ipam
#     + the pool's selector draws from the declared CiliumLoadBalancerIPPool,
#   - classless Service (no class) gets node IPs via Node IPAM,
#   - ETP-Local candidate restriction: with the backend pinned to one node,
#     only that node's IPs are advertised,
#   - firewall positive (LB port reachable where exposed) AND negative
#     (a nowhere-exposed port on the mesh address; the LB port on the
#     untrusted underlay interface),
#   - hermetic: all images preloaded (distro airgap + artifact-flake Cilium
#     airgap set via the service defaults + go-httpbin fixture here).
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

  # go-httpbin everywhere (DaemonSet) for the pool service.
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
              # Pinned id (§6.2): keeps CIDRs/clusterDNS/HAProxy ports stable.
              cilium.id = 1;
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
    };

  testScript = ''
    def fail_dump(m):
        for cmd in [
            "journalctl -u k3s --no-pager -l | tail -n 80",
            "journalctl -u k3s-k3s-bootstrap-apply --no-pager -l | tail -n 60 >&2 || true",
            "journalctl -u haproxy --no-pager -l | tail -n 40 >&2",
            "kubectl get nodes,pods -A -o wide >&2 || true",
            "kubectl get service,endpoints,endpointslices -A -o wide >&2 || true",
            "kubectl get ciliumloadbalancerippools -A >&2 || true",
            "kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.enable-node-ipam}{\"\\n\"}{.data.default-lb-service-ipam}' >&2 || true",
            "kubectl -n kube-system exec ds/cilium -- cilium-dbg service list >&2 || true",
            "nft list chain inet nixos-fw input >&2 || true",
            "ip route >&2; ip -6 route >&2",
            "kubectl logs -n kube-system -l k8s-app=cilium --tail=200 >&2 || true",
            "kubectl logs -n kube-system -l k8s-app=cilium-operator --tail=200 >&2 || true",
            "kubectl get events -A --sort-by=.lastTimestamp | tail -n 120 >&2 || true",
            "cilium status >&2 || true",
        ]:
            m.execute(cmd)

    try:
        start_all()

        for m in [alpha, beta]:
            m.wait_for_unit("systemd-networkd.service", timeout=120)
            m.wait_for_unit("haproxy.service", timeout=240)

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

        # --- Firewall: positive + negative ------------------------------
        # Negative 1: a port nowhere exposed, on the mesh address.
        alpha.fail("nc -z -w3 192.168.77.2 9999")
        # Negative 2: the LB port on the untrusted underlay interface —
        # Cilium's devices pinning (wg-mesh only) means the underlay hits
        # the host firewall, which drops it.
        beta_underlay = beta.succeed(
            "ip -4 -o addr show scope global | grep -v wg-mesh | awk '{print $4}' | cut -d/ -f1 | head -n1"
        ).strip()
        alpha.fail(f"curl -sf --max-time 5 http://{beta_underlay}:81/get")
    except Exception:
        fail_dump(alpha)
        fail_dump(beta)
        raise
  '';
}
