# <distro>-clustermesh-tunnel: the D60 ClusterMesh contract over the TUNNEL
# transport (wireguard-mesh, D58) with node-port exposure:
#   - two clusters (<distro>-a: alpha+beta, <distro>-b: gamma+delta) share one
#     transport instance → ONE mesh group (D54), full peering default,
#   - auto exposure resolves to node-port (the tunnel transport exposes no
#     internalLoadBalancer capability): the Service is type NodePort on the
#     default 32379 with ETP Local, replicas = the selected voter count (one
#     pod per node), every selected node's stable address published (D60),
#   - the apiserver Deployment: replicas = min(3, eligible voters) = 2,
#     REQUIRED hostname anti-affinity + nodeSelector, rolling update
#     maxSurge=0 / maxUnavailable=1,
#   - the clustermesh-apiserver TLS secrets come from the clan vars mesh
#     material (shared group CA + per-cluster leaf set) via the
#     clusterInit nodes' clustermesh-secrets oneshots,
#   - peers dial every selected node's stable address on the NodePort (no
#     DNS, D60); cilium clustermesh status shows both clusters connected on
#     BOTH sides, and a pod on <distro>-a pings a pod on <distro>-b through the VXLAN
#     tunnel (D58).
#
# Transport: one wireguard-mesh instance, four peers.
#
# Shared by the thin services/{k3s,rke2}/tests/vm/clustermesh-tunnel.nix
# wrappers; every distro difference is a `k3s` branch.
{
  lib,
  inputs,
  distro,
}: let
  k3s = distro == "k3s";
  clusterA = "${distro}-a";
  clusterB = "${distro}-b";
  runtimeUnit =
    if k3s
    then "k3s"
    else "rke2-server";
  marker = lib.toUpper distro;
in {
  name = "${distro}-clustermesh-tunnel";

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules.wireguard-mesh = lib.modules.importApply ../../../../services/wireguard-mesh/default.nix {
      ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
    };
    exportInterfaces = {
      node_transport = ../../../../lib/node-transport-interface.nix;
    };

    inventory = {
      meta.domain = "test.clan";

      machines = {
        alpha = {};
        beta = {};
        gamma = {};
        delta = {};
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
              gamma.settings = {
                ipv4 = "192.168.77.3";
                ipv6 = "fd00:77::3";
              };
              delta.settings = {
                ipv4 = "192.168.77.4";
                ipv6 = "fd00:77::4";
              };
            };
          };
        };

        ${clusterA} = {
          module.name = distro;
          module.input = "self";
          roles.server = {
            settings = {
              network.fabric = {
                service = "wireguard-mesh";
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

        ${clusterB} = {
          module.name = distro;
          module.input = "self";
          roles.server = {
            settings = {
              network.fabric = {
                service = "wireguard-mesh";
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

  nodes = let
    busyboxImage = pkgs:
      pkgs.dockerTools.pullImage {
        imageName = "busybox";
        imageDigest = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662";
        hash = "sha256-OasmfjRQsuVWudSc4qWuMKK5nNz4hdIS8Si4B0okXEw=";
        finalImageTag = "1.36.1";
      };
    commonNode = name: {pkgs, ...}: {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
          addresses = [
            "192.168.1.${
              toString
              {
                alpha = 1;
                beta = 2;
                gamma = 3;
                delta = 4;
              }
                  .${
                name
              }
            }/24"
          ];
        })
      ];
      virtualisation = {
        cores = 2;
        memorySize = 3584;
        diskSize = 8192;
      };
      environment.sessionVariables.KUBECONFIG = "/etc/rancher/${distro}/${distro}.yaml";
      environment.systemPackages = [
        pkgs.kubectl
        pkgs.cilium-cli
        pkgs.socat
      ];
      services.${distro}.images = [(busyboxImage pkgs)];
    };
  in {
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
            "journalctl -u ${runtimeUnit} --no-pager -l | tail -n 60 >&2 || true",
            "journalctl -u ${distro}-${clusterA}-bootstrap-apply --no-pager -l | tail -n 40 >&2 || true",
            "journalctl -u ${distro}-${clusterA}-clustermesh-secrets --no-pager -l | tail -n 40 >&2 || true",
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

        with subtest("nodes boot: ifstate, haproxy and ${runtimeUnit} up"):
            for m in [alpha, beta, gamma, delta]:
                m.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
                m.wait_for_unit("haproxy.service", timeout=240)
                m.wait_for_unit("${runtimeUnit}.service", timeout=600)

        with subtest("bootstrap bundles and mesh secrets applied"):
            # Both bootstrap bundles applied (each cluster's clusterInit node).
            alpha.wait_until_succeeds(
                "systemctl show -p Result --value ${distro}-${clusterA}-bootstrap-apply | grep '^success$' >/dev/null",
                timeout=900,
            )
            gamma.wait_until_succeeds(
                "systemctl show -p Result --value ${distro}-${clusterB}-bootstrap-apply | grep '^success$' >/dev/null",
                timeout=900,
            )

            # The mesh CA/cert vars material landed via the secrets oneshots.
            alpha.wait_until_succeeds(
                "systemctl show -p Result --value ${distro}-${clusterA}-clustermesh-secrets | grep '^success$' >/dev/null",
                timeout=300,
            )
            gamma.wait_until_succeeds(
                "systemctl show -p Result --value ${distro}-${clusterB}-clustermesh-secrets | grep '^success$' >/dev/null",
                timeout=300,
            )

        with subtest("nodes Ready on both clusters"):
            # Nodes up on both clusters.
            alpha.wait_until_succeeds(
                "kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s",
                timeout=300,
            )
            gamma.wait_until_succeeds(
                "kubectl wait --for=condition=Ready node/gamma node/delta --timeout=120s",
                timeout=300,
            )

        with subtest("Cilium healthy in VXLAN tunnel mode, MTU 1370"):
            # Cilium healthy on both clusters.
            alpha.wait_until_succeeds("cilium status", timeout=180)
            gamma.wait_until_succeeds("cilium status", timeout=180)
            for m in [alpha, gamma]:
                m.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.routing-mode}' | grep -x tunnel >/dev/null")
                m.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.tunnel-protocol}' | grep -x vxlan >/dev/null")
                m.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.mtu}' | grep -x 1370 >/dev/null")

        with subtest("apiserver placement: 2 replicas, one per voter"):
            # --- apiserver placement (D60) ------------------------------------
            for m in [alpha, gamma]:
                m.wait_until_succeeds(
                    "kubectl wait --for=condition=Ready pod -n kube-system -l k8s-app=clustermesh-apiserver --timeout=180s",
                    timeout=300,
                )
            replicas_a = alpha.succeed(
                "kubectl get deployment -n kube-system clustermesh-apiserver -o jsonpath='{.spec.replicas}'"
            ).strip()
            assert replicas_a == "2", f"${clusterA} apiserver replicas: {replicas_a!r}"
            # One pod per voter node (required anti-affinity + nodeSelector).
            alpha.succeed(
                "kubectl get pod -n kube-system -l k8s-app=clustermesh-apiserver -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\\n' | sort | uniq -c | grep '^ *1 alpha$' >/dev/null"
            )
            alpha.succeed(
                "kubectl get pod -n kube-system -l k8s-app=clustermesh-apiserver -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\\n' | grep '^beta$' >/dev/null"
            )

        with subtest("node-port exposure on 32379, ETP Local"):
            # --- node-port exposure (D60) --------------------------------------
            alpha.succeed(
                "kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.spec.type}' | grep '^NodePort$' >/dev/null"
            )
            alpha.succeed(
                "kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.spec.ports[0].nodePort}' | grep '^32379$' >/dev/null"
            )
            for m in [alpha, gamma]:
                m.succeed(
                    "kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.spec.externalTrafficPolicy}' | grep '^Local$' >/dev/null"
                )

        with subtest("every node's NodePort reachable over mTLS"):
            # Every selected node's stable address is published (D60): the
            # apiserver is reachable on the NodePort from every peer node.
            for m in [alpha, gamma]:
                m.succeed("kubectl -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.ca\\.crt}' | base64 -d > /tmp/clustermesh-ca.crt")
                m.succeed("kubectl -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.tls\\.crt}' | base64 -d > /tmp/clustermesh-client.crt")
                m.succeed("kubectl -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.tls\\.key}' | base64 -d > /tmp/clustermesh-client.key")
            for target in ["192.168.77.1", "192.168.77.2"]:
                gamma.wait_until_succeeds(f"curl -s --cacert /tmp/clustermesh-ca.crt --cert /tmp/clustermesh-client.crt --key /tmp/clustermesh-client.key --max-time 5 https://{target}:32379/health -o /dev/null -w '%{{http_code}}' | grep -x 200 >/dev/null", timeout=240)
            for target in ["192.168.77.3", "192.168.77.4"]:
                alpha.wait_until_succeeds(f"curl -s --cacert /tmp/clustermesh-ca.crt --cert /tmp/clustermesh-client.crt --key /tmp/clustermesh-client.key --max-time 5 https://{target}:32379/health -o /dev/null -w '%{{http_code}}' | grep -x 200 >/dev/null", timeout=240)

        with subtest("peering established on both sides"):
            # --- peering established on BOTH sides -----------------------------
            alpha.wait_until_succeeds("cilium clustermesh status | grep '${clusterB}' >/dev/null", timeout=300)
            gamma.wait_until_succeeds("cilium clustermesh status | grep '${clusterA}' >/dev/null", timeout=300)

        with subtest("cross-cluster pod ping through the VXLAN tunnel"):
            # --- cross-cluster pod connectivity (native routed pod paths) ------
            alpha.succeed("kubectl run pinger-a --image=busybox:1.36.1 --restart=Never --command -- sleep 3600")
            gamma.succeed("kubectl run pinger-b --image=busybox:1.36.1 --restart=Never --command -- sleep 3600")
            alpha.wait_until_succeeds("kubectl get pod pinger-a -o jsonpath='{.status.phase}' | grep Running >/dev/null", timeout=120)
            gamma.wait_until_succeeds("kubectl get pod pinger-b -o jsonpath='{.status.phase}' | grep Running >/dev/null", timeout=120)
            pod_b_ip = gamma.succeed("kubectl get pod pinger-b -o jsonpath='{.status.podIP}'").strip()
            pod_a_ip = alpha.succeed("kubectl get pod pinger-a -o jsonpath='{.status.podIP}'").strip()
            alpha.wait_until_succeeds(f"kubectl exec pinger-a -- ping -c2 -W3 {pod_b_ip}", timeout=180)
            gamma.wait_until_succeeds(f"kubectl exec pinger-b -- ping -c2 -W3 {pod_a_ip}", timeout=180)

        with subtest("global Service merges backends from both clusters"):
            # Global Service traffic uses the same VXLAN datapath as pod pings.
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
        print("${marker}_CLUSTERMESH_TUNNEL_OK")
    except Exception:
        for m in [alpha, beta, gamma, delta]:
            try:
                fail_dump(m)
            except Exception:
                pass
        raise
  '';
}
