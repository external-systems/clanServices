# rke2-clustermesh: the D60 ClusterMesh contract over the NATIVE transport
# (routed-fabric leaf/spine, D59) with internal-load-balancer exposure:
#   - two rke2 clusters (rke2-a: alpha+beta, rke2-b: gamma+delta) share one
#     routed-fabric instance → ONE mesh group (D54), full peering default,
#   - auto exposure resolves to internal-load-balancer (the native transport
#     exposes the capability): the pinned offset-79 IPv4 VIPs
#     (172.16.1.79 / 172.16.2.79) draw from each cluster's
#     <instance>-fabric pool by explicit lbipam.cilium.io/ips projection,
#     class io.cilium/bgp-control-plane, ETP Local (D60). Cilium 1.20.3's
#     apiserver control-plane listener is IPv4-only; the data plane is dual-stack,
#   - the apiserver Deployment: replicas = min(3, eligible voters) = 2,
#     REQUIRED hostname anti-affinity + nodeSelector, rolling update
#     maxSurge=0 / maxUnavailable=1,
#   - the clustermesh-apiserver TLS secrets come from the clan vars mesh
#     material (shared group CA + per-cluster leaf set) via the
#     clusterInit nodes' clustermesh-secrets oneshots,
#   - peers dial the published VIPs directly (no DNS, D60);
#     cilium clustermesh status shows both clusters connected on BOTH
#     sides, and a pod on k3s-a pings a pod on k3s-b over native
#     routed pod paths (D49).
#
# Fabric topology: alpha and gamma are spines (the spine↔spine adjacency
# derives automatically); beta and delta are leaves attaching every spine.
{ lib, inputs, ... }:
{
  name = "rke2-clustermesh";

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules.routed-fabric = lib.modules.importApply ../../../routed-fabric/default.nix {
      ifstateOverlay = inputs.pkgs.overlays.ifstate;
    };
    exportInterfaces = {
      node_transport = ../../../../lib/node-transport-interface.nix;
      routed_fabric = ../../../routed-fabric/routed-fabric-interface.nix;
    };

    inventory = {
      meta.domain = "test.clan";

      machines = {
        alpha = { };
        beta = { };
        gamma = { };
        delta = { };
      };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = {
            alpha.settings.host = "192.168.1.1";
            beta.settings.host = "192.168.1.2";
            gamma.settings.host = "192.168.1.3";
            delta.settings.host = "192.168.1.4";
          };
        };

        mesh = {
          module.name = "routed-fabric";
          module.input = "self";
          roles = {
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
              };
              gamma.settings = {
                ipv4 = "192.168.77.3";
                ipv6 = "fd77::3";
                endpoint = "192.168.1.3";
                endpointSources = [
                  {
                    service = "clan-core/internet";
                    instance = "underlay";
                  }
                ];
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
              };
              delta.settings = {
                ipv4 = "192.168.77.4";
                ipv6 = "fd77::4";
                endpoint = "192.168.1.4";
                endpointSources = [
                  {
                    service = "clan-core/internet";
                    instance = "underlay";
                  }
                ];
              };
            };
          };
        };

        rke2-a = {
          module.name = "rke2";
          module.input = "self";
          roles.server = {
            settings = {
              network.fabric = {
                service = "routed-fabric";
                instance = "mesh";
              };
              cilium.id = 1;
            };
            machines = {
              alpha.settings.clusterInit = true;
              beta.settings.clusterInit = false;
            };
          };
        };

        rke2-b = {
          module.name = "rke2";
          module.input = "self";
          roles.server = {
            settings = {
              network.fabric = {
                service = "routed-fabric";
                instance = "mesh";
              };
              cilium.id = 2;
            };
            machines = {
              gamma.settings.clusterInit = true;
              delta.settings.clusterInit = false;
            };
          };
        };
      };
    };
  };

  nodes =
    let
      busyboxImage =
        pkgs:
        pkgs.dockerTools.pullImage {
          imageName = "busybox";
          imageDigest = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662";
          hash = "sha256-OasmfjRQsuVWudSc4qWuMKK5nNz4hdIS8Si4B0okXEw=";
          finalImageTag = "1.36.1";
        };
      commonNode = name: { pkgs, ... }: {
        imports = [
          (import ../../../../tests/ifstate-vm.nix {
            ifstateOverlay = inputs.pkgs.overlays.ifstate;
            addresses = [
              "192.168.1.${
                toString
                  {
                    alpha = 1;
                    beta = 2;
                    gamma = 3;
                    delta = 4;
                  }
                  .${name}
              }/24"
            ];
          })
        ];
        virtualisation = {
          cores = 2;
          memorySize = 3584;
          diskSize = 8192;
        };
        environment.sessionVariables.KUBECONFIG = "/etc/rancher/rke2/rke2.yaml";
        environment.systemPackages = [
          pkgs.kubectl
          pkgs.cilium-cli
          pkgs.socat
        ];
        services.rke2.images = [ (busyboxImage pkgs) ];
      };
    in
    {
      alpha = commonNode "alpha";
      beta = commonNode "beta";
      gamma = commonNode "gamma";
      delta = commonNode "delta";
    };

  testScript = ''
    def fail_dump(m):
        for cmd in [
            "ip -br addr >&2",
            "ip route >&2; ip -6 route >&2",
            "journalctl -u rke2-server --no-pager -l | tail -n 60 >&2 || true",
            "journalctl -u rke2-rke2-a-bootstrap-apply --no-pager -l | tail -n 40 >&2 || true",
            "journalctl -u rke2-rke2-a-clustermesh-secrets --no-pager -l | tail -n 40 >&2 || true",
            "kubectl get nodes,pods -A -o wide >&2 || true",
            "kubectl get service -n kube-system clustermesh-apiserver -o yaml >&2 || true",
            "kubectl describe pod -n kube-system -l k8s-app=clustermesh-apiserver --request-timeout=10s >&2 || true",
            "timeout 20 cilium status >&2 || true",
            "timeout 20 cilium clustermesh status >&2 || true",
            "kubectl logs -n kube-system -l k8s-app=cilium --all-containers=true --tail=80 >&2 || true",
            "kubectl logs -n kube-system -l k8s-app=clustermesh-apiserver --all-containers=true --tail=80 >&2 || true",
        ]:
            m.execute(cmd)

    try:
        start_all()

        for m in [alpha, beta, gamma, delta]:
            m.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep -q '^success$'", timeout=120)
            m.wait_for_unit("haproxy.service", timeout=240)
            m.wait_for_unit("rke2-server.service", timeout=600)

        # Both bootstrap bundles applied (each cluster's clusterInit node).
        alpha.wait_until_succeeds(
            "systemctl show -p Result --value rke2-rke2-a-bootstrap-apply | grep -q '^success$'",
            timeout=900,
        )
        gamma.wait_until_succeeds(
            "systemctl show -p Result --value rke2-rke2-b-bootstrap-apply | grep -q '^success$'",
            timeout=900,
        )

        # The mesh CA/cert vars material landed via the secrets oneshots.
        alpha.wait_until_succeeds(
            "systemctl show -p Result --value rke2-rke2-a-clustermesh-secrets | grep -q '^success$'",
            timeout=300,
        )
        gamma.wait_until_succeeds(
            "systemctl show -p Result --value rke2-rke2-b-clustermesh-secrets | grep -q '^success$'",
            timeout=300,
        )

        # Nodes up on both clusters.
        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s",
            timeout=300,
        )
        gamma.wait_until_succeeds(
            "kubectl wait --for=condition=Ready node/gamma node/delta --timeout=120s",
            timeout=300,
        )

        # Cilium healthy on both clusters, with every node's local-router
        # configuration and pod/VIP advertisements present.
        alpha.wait_until_succeeds("cilium status", timeout=180)
        gamma.wait_until_succeeds("cilium status", timeout=180)
        for m in [alpha, gamma]:
            m.wait_until_succeeds("test $(kubectl get ciliumbgpclusterconfig --no-headers | wc -l) -eq 2", timeout=180)
            m.wait_until_succeeds("test $(kubectl get ciliumbgppeerconfig --no-headers | wc -l) -eq 2", timeout=180)
            m.wait_until_succeeds("test $(kubectl get ciliumbgpadvertisement --no-headers | wc -l) -eq 4", timeout=180)
        for m in [alpha, beta, gamma, delta]:
            m.wait_until_succeeds("test $(cilium bgp peers | grep -c established) -eq 2", timeout=180)

        # --- apiserver placement (D60) ------------------------------------
        for m in [alpha, gamma]:
            m.wait_until_succeeds(
                "kubectl wait --for=condition=Ready pod -n kube-system -l k8s-app=clustermesh-apiserver --timeout=180s",
                timeout=300,
            )
        replicas_a = alpha.succeed(
            "kubectl get deployment -n kube-system clustermesh-apiserver -o jsonpath='{.spec.replicas}'"
        ).strip()
        assert replicas_a == "2", f"rke2-a apiserver replicas: {replicas_a!r}"
        # One pod per voter node (required anti-affinity + nodeSelector).
        alpha.succeed(
            "kubectl get pod -n kube-system -l k8s-app=clustermesh-apiserver -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\\n' | sort | uniq -c | grep -q '^ *1 alpha$'"
        )
        alpha.succeed(
            "kubectl get pod -n kube-system -l k8s-app=clustermesh-apiserver -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\\n' | grep -q '^beta$'"
        )

        # --- internal-load-balancer exposure (D60) -------------------------
        alpha.wait_until_succeeds(
            "kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.status.loadBalancer.ingress[*].ip}' | grep -q '^172.16.1.79$'",
            timeout=240,
        )
        alpha.succeed(
            "kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.spec.ipFamilies[0]}' | grep -qx 'IPv4'"
        )
        gamma.wait_until_succeeds(
            "kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.status.loadBalancer.ingress[*].ip}' | grep -q '^172.16.2.79$'",
            timeout=240,
        )
        for m in [alpha, gamma]:
            m.succeed(
                "kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.spec.externalTrafficPolicy}' | grep -q '^Local$'"
            )

        # The VIPs are reachable across the fabric from every node (peers
        # dial them directly — no DNS, D60). Etcd health requires mTLS.
        for m in [alpha, beta, gamma, delta]:
            m.succeed("kubectl -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.ca\\.crt}' | base64 -d > /tmp/clustermesh-ca.crt")
            m.succeed("kubectl -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.tls\\.crt}' | base64 -d > /tmp/clustermesh-client.crt")
            m.succeed("kubectl -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.tls\\.key}' | base64 -d > /tmp/clustermesh-client.key")
            m.wait_until_succeeds("curl -s --cacert /tmp/clustermesh-ca.crt --cert /tmp/clustermesh-client.crt --key /tmp/clustermesh-client.key --max-time 5 https://172.16.1.79:2379/health -o /dev/null -w '%{http_code}' | grep -qx 200", timeout=240)

        # --- peering established on BOTH sides -----------------------------
        alpha.wait_until_succeeds("cilium clustermesh status | grep -q 'rke2-b'", timeout=300)
        gamma.wait_until_succeeds("cilium clustermesh status | grep -q 'rke2-a'", timeout=300)

        # --- cross-cluster pod connectivity (native routed pod paths) ------
        alpha.succeed("kubectl run pinger-a --image=busybox:1.36.1 --restart=Never --command -- sleep 3600")
        gamma.succeed("kubectl run pinger-b --image=busybox:1.36.1 --restart=Never --command -- sleep 3600")
        alpha.wait_until_succeeds("kubectl get pod pinger-a -o jsonpath='{.status.phase}' | grep -q Running", timeout=120)
        gamma.wait_until_succeeds("kubectl get pod pinger-b -o jsonpath='{.status.phase}' | grep -q Running", timeout=120)
        pod_b_ip = gamma.succeed("kubectl get pod pinger-b -o jsonpath='{.status.podIP}'").strip()
        pod_a_ip = alpha.succeed("kubectl get pod pinger-a -o jsonpath='{.status.podIP}'").strip()
        alpha.wait_until_succeeds(f"kubectl exec pinger-a -- ping -c2 -W3 {pod_b_ip}", timeout=180)
        gamma.wait_until_succeeds(f"kubectl exec pinger-b -- ping -c2 -W3 {pod_a_ip}", timeout=180)
        # A global Service merges backends from both clusters.
        for m, cluster in [(alpha, "CLUSTER_A"), (gamma, "CLUSTER_B")]:
            m.succeed(f"kubectl create deployment global-web --image=busybox:1.36.1 -- /bin/sh -c 'echo {cluster} > /tmp/index.html; httpd -f -p 80 -h /tmp'")
            m.succeed("kubectl expose deployment global-web --port=80")
            m.succeed("kubectl annotate service global-web service.cilium.io/global=true")
            m.wait_until_succeeds("kubectl rollout status deployment/global-web --timeout=180s", timeout=240)
        seen = set()
        for _ in range(60):
            seen.add(alpha.succeed("kubectl exec pinger-a -- wget -qO- --timeout=5 http://global-web.default.svc.cluster.local").strip())
            if seen == {"CLUSTER_A", "CLUSTER_B"}:
                break
            alpha.execute("sleep 1")
        assert seen == {"CLUSTER_A", "CLUSTER_B"}, f"global Service backends: {seen!r}"

        # ETP Local withdraws the internal VIP when a node loses its last
        # apiserver backend, and restores ECMP when both backends return.
        gamma.wait_until_succeeds("ip -j route show 172.16.1.79 | jq -e '.[0].nexthops | length == 2'", timeout=240)
        alpha.succeed("kubectl scale deployment/clustermesh-apiserver -n kube-system --replicas=1")
        gamma.wait_until_succeeds(
            "ip -j route show 172.16.1.79 | jq -e '(.[0].nexthops // [{gateway: .[0].gateway}]) | length == 1'",
            timeout=300,
        )
        alpha.wait_until_succeeds("curl -s --cacert /tmp/clustermesh-ca.crt --cert /tmp/clustermesh-client.crt --key /tmp/clustermesh-client.key --max-time 5 https://172.16.2.79:2379/health -o /dev/null -w '%{http_code}' | grep -qx 200", timeout=120)
        alpha.succeed("kubectl scale deployment/clustermesh-apiserver -n kube-system --replicas=2")
        gamma.wait_until_succeeds("ip -j route show 172.16.1.79 | jq -e '.[0].nexthops | length == 2'", timeout=300)
        print("RKE2_CLUSTERMESH_NATIVE_OK")
    except Exception:
        for m in [alpha, beta, gamma, delta]:
            try:
                fail_dump(m)
            except Exception:
                pass
        raise
  '';
}
