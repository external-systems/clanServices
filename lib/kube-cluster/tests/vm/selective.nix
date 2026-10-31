{
  lib,
  inputs,
  distro,
  profile ? "native",
}: let
  clusterA = "${distro}-a";
  clusterB = "${distro}-b";
  clusterC = "${distro}-c";
  k3s = distro == "k3s";
  native = profile == "native";
  transportModule =
    if native
    then "routed-fabric"
    else "wireguard-mesh";
  runtimeUnit =
    if k3s
    then "k3s.service"
    else "rke2-server.service";
  marker = "${lib.toUpper distro}_CLUSTERMESH_SELECTIVE${lib.optionalString (!native) "_TUNNEL"}_OK";
  underlayIp = name: "192.168.1.${
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
  }";
  stableIp = name: "192.168.77.${
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
  }";
  stableIp6 = name: "fd77::${
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
  }";
  clusterSettings = id: peers: {
    network.fabric = {
      service = transportModule;
      instance = "mesh";
    };
    cilium.id = id;
    mesh.peers = peers;
  };
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
        ifstateOverlay = inputs.pkgs.overlays.ifstate;
        addresses = ["${underlayIp name}/24"];
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
      pkgs.jq
      pkgs.socat
    ];
    services.${distro}.images = [(busyboxImage pkgs)];
  };
in {
  name = "${distro}-clustermesh-selective${lib.optionalString (!native) "-${profile}"}";

  clan = {
    directory = ./.;
    test.useContainers = false;
    modules =
      lib.optionalAttrs native {
        routed-fabric = lib.modules.importApply ../../../../services/routed-fabric/default.nix {
          ifstateOverlay = inputs.pkgs.overlays.ifstate;
        };
      }
      // lib.optionalAttrs (!native) {
        wireguard-mesh = lib.modules.importApply ../../../../services/wireguard-mesh/default.nix {
          ifstateOverlay = inputs.pkgs.overlays.ifstate;
        };
      };
    exportInterfaces =
      {
        node_transport = ../../../../lib/node-transport-interface.nix;
      }
      // lib.optionalAttrs native {
        routed_fabric = ../../../../services/routed-fabric/routed-fabric-interface.nix;
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
        mesh = {
          module.name = transportModule;
          module.input = "self";
          roles =
            if native
            then {
              spine.machines.delta.settings = {
                ipv4 = stableIp "delta";
                ipv6 = stableIp6 "delta";
                endpoint = underlayIp "delta";
              };
              leaf.machines = lib.genAttrs ["alpha" "beta" "gamma"] (name: {
                settings = {
                  ipv4 = stableIp name;
                  ipv6 = stableIp6 name;
                  endpoint = underlayIp name;
                };
              });
            }
            else {
              peer.machines = lib.genAttrs ["alpha" "beta" "gamma"] (name: {
                settings = {
                  ipv4 = stableIp name;
                  ipv6 = stableIp6 name;
                  endpoint = underlayIp name;
                };
              });
            };
        };
        ${clusterA} = {
          module.name = distro;
          module.input = "self";
          roles.server = {
            settings = clusterSettings 1 [clusterB];
            machines.alpha.settings.clusterInit = true;
          };
        };
        ${clusterB} = {
          module.name = distro;
          module.input = "self";
          roles.server = {
            settings = clusterSettings 2 [
              clusterA
              clusterC
            ];
            machines.beta.settings.clusterInit = true;
          };
        };
        ${clusterC} = {
          module.name = distro;
          module.input = "self";
          roles.server = {
            settings = clusterSettings 3 [clusterB];
            machines.gamma.settings.clusterInit = true;
          };
        };
      };
    };
  };

  nodes =
    {
      alpha = commonNode "alpha";
      beta = commonNode "beta";
      gamma = commonNode "gamma";
    }
    // lib.optionalAttrs native {
      delta = commonNode "delta";
    };

  testScript = ''
    def fail_dump(m):
        for cmd in [
            "ip -br addr >&2",
            "ip route >&2; ip -6 route >&2",
            "journalctl -u ${runtimeUnit} --no-pager -l | tail -n 60 >&2 || true",
            "kubectl get nodes,pods -A -o wide >&2 || true",
            "kubectl describe pod -n kube-system -l k8s-app=clustermesh-apiserver --request-timeout=10s >&2 || true",
            "timeout 20 cilium status >&2 || true",
            "timeout 20 cilium clustermesh status >&2 || true",
            "kubectl -n kube-system exec ds/cilium -- cilium-dbg service list >&2 || true",
            "kubectl get endpointslice -A -o wide >&2 || true",
            "kubectl -n kube-system exec ds/cilium -- cilium-dbg troubleshoot clustermesh >&2 || true",
            "kubectl -n kube-system exec deploy/clustermesh-apiserver -c kvstoremesh -- clustermesh-apiserver kvstoremesh-dbg troubleshoot ${clusterB} >&2 || true",
            "timeout 20 cilium bgp peers >&2 || true",
            "kubectl get ciliumbgpclusterconfig,ciliumbgppeerconfig,ciliumbgpadvertisement -o yaml >&2 || true",
            "kubectl logs -n kube-system -l k8s-app=cilium --all-containers=true --tail=80 >&2 || true",
            "kubectl logs -n kube-system -l k8s-app=clustermesh-apiserver --all-containers=true --tail=80 >&2 || true",
            "vtysh -c 'show ip route' >&2 || true",
            "vtysh -c 'show bgp ipv4 unicast' >&2 || true",
        ]:
            m.execute(cmd)

    try:
        start_all()
        machines = [alpha, beta, gamma]
        for m in machines${lib.optionalString native " + [delta]"}:
            m.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep -q '^success$'", timeout=120)
        for m in machines:
            m.wait_for_unit("haproxy.service", timeout=240)
            m.wait_for_unit("${runtimeUnit}", timeout=600)

        for m, cluster in [(alpha, "${clusterA}"), (beta, "${clusterB}"), (gamma, "${clusterC}")]:
            m.wait_until_succeeds(
                f"systemctl show -p Result --value ${distro}-{cluster}-bootstrap-apply | grep -q '^success$'",
                timeout=900,
            )
            m.wait_until_succeeds(
                f"systemctl show -p Result --value ${distro}-{cluster}-clustermesh-secrets | grep -q '^success$'",
                timeout=300,
            )
            m.wait_until_succeeds("cilium status", timeout=240)
            m.wait_until_succeeds(
                "kubectl wait --for=condition=Ready pod -n kube-system -l k8s-app=clustermesh-apiserver --timeout=180s",
                timeout=300,
            )
            if ${
      if native
      then "True"
      else "False"
    }:
                m.wait_until_succeeds("test $(kubectl get ciliumbgpclusterconfig --no-headers | wc -l) -eq 1", timeout=180)
                m.wait_until_succeeds("test $(kubectl get ciliumbgppeerconfig --no-headers | wc -l) -eq 1", timeout=180)
                m.wait_until_succeeds("test $(kubectl get ciliumbgpadvertisement --no-headers | wc -l) -eq 2", timeout=180)
                m.wait_until_succeeds("test $(cilium bgp peers | grep -c established) -eq 1", timeout=240)

        if ${
      if native
      then "True"
      else "False"
    }:
            # Prove the exposed apiserver path independently of peering state.
            for m in machines:
                m.succeed("kubectl -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.ca\\.crt}' | base64 -d > /tmp/clustermesh-ca.crt")
                m.succeed("kubectl -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.tls\\.crt}' | base64 -d > /tmp/clustermesh-client.crt")
                m.succeed("kubectl -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.tls\\.key}' | base64 -d > /tmp/clustermesh-client.key")
            alpha.wait_until_succeeds("curl -s --cacert /tmp/clustermesh-ca.crt --cert /tmp/clustermesh-client.crt --key /tmp/clustermesh-client.key --max-time 5 https://172.16.2.79:2379/health -o /dev/null -w '%{http_code}' | grep -qx 200", timeout=240)
            beta.wait_until_succeeds("curl -s --cacert /tmp/clustermesh-ca.crt --cert /tmp/clustermesh-client.crt --key /tmp/clustermesh-client.key --max-time 5 https://172.16.1.79:2379/health -o /dev/null -w '%{http_code}' | grep -qx 200", timeout=240)
            beta.wait_until_succeeds("curl -s --cacert /tmp/clustermesh-ca.crt --cert /tmp/clustermesh-client.crt --key /tmp/clustermesh-client.key --max-time 5 https://172.16.3.79:2379/health -o /dev/null -w '%{http_code}' | grep -qx 200", timeout=240)
            gamma.wait_until_succeeds("curl -s --cacert /tmp/clustermesh-ca.crt --cert /tmp/clustermesh-client.crt --key /tmp/clustermesh-client.key --max-time 5 https://172.16.2.79:2379/health -o /dev/null -w '%{http_code}' | grep -qx 200", timeout=240)

        # Symmetric selective edges A<->B and B<->C only; peering is not transitive.
        alpha.wait_until_succeeds("cilium clustermesh status | grep -q '${clusterB}'", timeout=300)
        alpha.fail("cilium clustermesh status | grep -q '${clusterC}'")
        beta.wait_until_succeeds("cilium clustermesh status | grep -q '${clusterA}'", timeout=300)
        beta.wait_until_succeeds("cilium clustermesh status | grep -q '${clusterC}'", timeout=300)
        gamma.wait_until_succeeds("cilium clustermesh status | grep -q '${clusterB}'", timeout=300)
        gamma.fail("cilium clustermesh status | grep -q '${clusterA}'")

        if ${
      if native
      then "True"
      else "False"
    }:
            # Native peering also bounds remote pod-route policy. Cilium
            # advertises per-node /24 + /64 allocations, not the whole pool.
            for m in machines:
                m.wait_until_succeeds("ip route show 10.3.0.0/24 | grep -q .", timeout=240)
                m.wait_until_succeeds("ip -6 route show fd10:3::/64 | grep -q .", timeout=240)
            alpha.fail("ip route show 10.5.0.0/24 | grep -q .")
            alpha.fail("ip -6 route show fd10:5::/64 | grep -q .")
            gamma.fail("ip route show 10.1.0.0/24 | grep -q .")
            gamma.fail("ip -6 route show fd10:1::/64 | grep -q .")
            beta.wait_until_succeeds("ip route show 10.1.0.0/24 | grep -q .", timeout=240)
            beta.wait_until_succeeds("ip route show 10.5.0.0/24 | grep -q .", timeout=240)
            beta.wait_until_succeeds("ip -6 route show fd10:1::/64 | grep -q .", timeout=240)
            beta.wait_until_succeeds("ip -6 route show fd10:5::/64 | grep -q .", timeout=240)
        else:
            # Tunnel mode has no remote pod-route policy; selective isolation is
            # proved by ClusterMesh membership and global-Service backends below.
            for m in machines:
                m.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.routing-mode}' | grep -qx tunnel")
                m.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.tunnel-protocol}' | grep -qx vxlan")

        # Global Services synchronize only across the selected edges.
        for m, cluster in [(alpha, "CLUSTER_A"), (beta, "CLUSTER_B"), (gamma, "CLUSTER_C")]:
            m.succeed(f"kubectl create deployment global-web --image=busybox:1.36.1 -- /bin/sh -c 'echo {cluster} > /tmp/index.html; httpd -f -p 80 -h /tmp'")
            m.succeed("kubectl expose deployment global-web --port=80")
            m.succeed("kubectl annotate service global-web service.cilium.io/global=true")
            m.wait_until_succeeds("kubectl rollout status deployment/global-web --timeout=180s", timeout=240)
            m.succeed("kubectl run probe --image=busybox:1.36.1 --restart=Never --command -- sleep 3600")
            m.wait_until_succeeds("kubectl get pod probe -o jsonpath='{.status.phase}' | grep -q Running", timeout=120)

        alpha.wait_until_succeeds("curl -sf --unix-socket /var/run/cilium/cilium.sock http://localhost/v1/service | jq -e --arg ip \"$(kubectl get service global-web -o jsonpath='{.spec.clusterIP}')\" '[.[] | select(.spec[\"frontend-address\"].ip == $ip) | .spec[\"backend-addresses\"] | length] == [2]' >/dev/null", timeout=600)
        seen_a = set()
        for _ in range(20):
            seen_a.add(alpha.succeed("kubectl exec probe -- wget -qO- --timeout=5 http://global-web.default.svc.cluster.local").strip())
            if seen_a == {"CLUSTER_A", "CLUSTER_B"}:
                break
        assert seen_a == {"CLUSTER_A", "CLUSTER_B"}, f"A selective peers: {seen_a!r}"

        beta.wait_until_succeeds("curl -sf --unix-socket /var/run/cilium/cilium.sock http://localhost/v1/service | jq -e --arg ip \"$(kubectl get service global-web -o jsonpath='{.spec.clusterIP}')\" '[.[] | select(.spec[\"frontend-address\"].ip == $ip) | .spec[\"backend-addresses\"] | length] == [3]' >/dev/null", timeout=600)
        seen_b = set()
        for _ in range(30):
            seen_b.add(beta.succeed("kubectl exec probe -- wget -qO- --timeout=5 http://global-web.default.svc.cluster.local").strip())
            if seen_b == {"CLUSTER_A", "CLUSTER_B", "CLUSTER_C"}:
                break
        assert seen_b == {"CLUSTER_A", "CLUSTER_B", "CLUSTER_C"}, f"B selective peers: {seen_b!r}"

        gamma.wait_until_succeeds("curl -sf --unix-socket /var/run/cilium/cilium.sock http://localhost/v1/service | jq -e --arg ip \"$(kubectl get service global-web -o jsonpath='{.spec.clusterIP}')\" '[.[] | select(.spec[\"frontend-address\"].ip == $ip) | .spec[\"backend-addresses\"] | length] == [2]' >/dev/null", timeout=600)
        seen_c = set()
        for _ in range(20):
            seen_c.add(gamma.succeed("kubectl exec probe -- wget -qO- --timeout=5 http://global-web.default.svc.cluster.local").strip())
            if seen_c == {"CLUSTER_B", "CLUSTER_C"}:
                break
        assert seen_c == {"CLUSTER_B", "CLUSTER_C"}, f"C selective peers: {seen_c!r}"
        print("${marker}")
    except Exception:
        for m in [alpha, beta, gamma]${lib.optionalString native " + [delta]"}:
            try:
                fail_dump(m)
            except Exception:
                pass
        raise
  '';
}
