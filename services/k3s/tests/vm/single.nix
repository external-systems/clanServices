_: {
  name = "k3s-single";

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules.wireguard-mesh = ../../../wireguard-mesh/default.nix;
    exportInterfaces.node_transport = ../../../wireguard-mesh/node-transport-interface.nix;

    inventory = {
      meta.domain = "test.clan";

      machines.alpha = { };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines.alpha.settings.host = "alpha";
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
            machines.alpha.settings = {
              ipv4 = "192.168.77.1";
              ipv6 = "fd00:77::1";
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

              # Prove the default stack: Traefik + Gateway API + cert-manager.
              traefik.instances.k3s-traefik = {
                gatewayAPI.enabled = true;
                # The test has no cloud provider; use ClusterIP and exercise
                # the Gateway via kubectl port-forward.
                service.type = "ClusterIP";
              };

              coredns.rewrites = [
                "name foo.test.clan kubernetes.default.svc.cluster.local"
              ];

            };
            machines.alpha.settings = {
              clusterInit = true;
            };
          };
        };
      };
    };
  };

  nodes.alpha =
    {
      pkgs,
      ...
    }:
    let
      busyboxImage = pkgs.dockerTools.pullImage {
        imageName = "busybox";
        imageDigest = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662";
        hash = "sha256-OasmfjRQsuVWudSc4qWuMKK5nNz4hdIS8Si4B0okXEw=";
        finalImageTag = "1.36.1";
      };
    in
    {
      virtualisation = {
        cores = 2;
        memorySize = 4096;
        diskSize = 8192;
      };

      environment.systemPackages = [
        pkgs.kubectl
        pkgs.cilium-cli
        pkgs.curl
        pkgs.socat
      ];
      environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

      services.k3s.images = [ busyboxImage ];
    };

  testScript = ''
    def fail_dump(m):
        for cmd in [
            "journalctl -u k3s --no-pager -l | tail -n 80",
            "journalctl -u haproxy --no-pager -l | tail -n 40 >&2",
            "kubectl get nodes,pods,certificates,gateways -A -o wide >&2 || true",
            "kubectl get service,endpoints,endpointslices -A -o wide >&2 || true",
            "kubectl get endpoints kubernetes -o yaml >&2 || true",
            "kubectl get configmap -n kube-system cilium-config -o yaml >&2 || true",
            "kubectl -n kube-system exec ds/cilium -- cilium-dbg service list >&2 || true",
            "kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list >&2 || true",
            "nft list chain inet nixos-fw input >&2 || true",
            "nft list chain inet nixos-fw forward >&2 || true",
            "ip route >&2; ip -6 route >&2",
            "kubectl describe pod -n kube-system -l k8s-app=cilium >&2 || true",
            "kubectl logs -n kube-system -l k8s-app=cilium --tail=200 >&2 || true",
            "kubectl get configmap -n kube-system coredns -o yaml >&2 || true",
            "kubectl get configmap -n kube-system coredns-custom -o yaml >&2 || true",
            "kubectl logs -n kube-system -l k8s-app=kube-dns --tail=200 >&2 || true",
            "for ip in $(kubectl get pod -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}'); do echo === coredns $ip === >&2; kubectl exec -n k3s-probe api-probe -- nslookup kubernetes.default.svc.cluster.local \"$ip\" >&2; done || true",
            "kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=200 >&2 || true",
            "kubectl describe pod -n kube-system -l app.kubernetes.io/instance=cert-manager >&2 || true",
            "kubectl logs -n kube-system -l app.kubernetes.io/instance=cert-manager --all-containers=true --prefix=true --tail=120 >&2 || true",
            "kubectl logs -n kube-system -l app.kubernetes.io/instance=cert-manager --all-containers=true --prefix=true --previous --tail=120 >&2 || true",
            "kubectl get endpoints -n kube-system cert-manager-webhook -o yaml >&2 || true",
            "kubectl get secret -n kube-system cert-manager-webhook-ca -o yaml >&2 || true",
            "for j in $(kubectl get jobs -n kube-system -o name); do echo === $j === >&2; kubectl logs -n kube-system $j --all-containers=true --tail=40 >&2; done",
            "kubectl get events -A --sort-by=.lastTimestamp | tail -n 120 >&2 || true",
            "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock >&2 || true",
            "cilium status >&2 || true",
        ]:
            m.execute(cmd)

    try:
        start_all()

        alpha.wait_for_unit("systemd-networkd.service", timeout=120)
        alpha.wait_for_unit("haproxy.service", timeout=240)
        alpha.wait_for_unit("k3s.service", timeout=600)

        # The initial server seeded the pre-generated PKI before k3s started,
        # and the per-node haproxy LB is bound on the mesh address.
        alpha.succeed("systemctl show -p Result --value k3s-k3s-pki-seed | grep -q '^success$'")
        alpha.succeed("test -f /var/lib/rancher/k3s/server/tls/server-ca.crt")
        alpha.succeed("test -f /var/lib/rancher/k3s/server/tls/etcd/server-ca.crt")
        alpha.succeed("test -f /var/lib/rancher/k3s/server/tls/service.key")
        for port in ["6443", "7443", "8404"]:
            alpha.succeed(f"ss -tln | grep -q ':{port}'")
        alpha.wait_until_succeeds(
            "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep '^k3s_api,alpha-4,' | grep -q ',UP,'",
            timeout=300,
        )

        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Ready node/alpha --timeout=120s", timeout=180
        )

        # The admin kubeconfig (vars PKI client cert) works through the
        # local haproxy LB (server URL = kubeapi FQDN on the LB port).
        alpha.succeed(
            "kubectl --kubeconfig /etc/rancher/k3s/admin-kubeconfig get --raw /readyz | grep -q ok"
        )

        # Pod API clients need both the real apiserver endpoint and Cilium's
        # ClusterIP translation before any cert-manager component can converge.
        alpha.succeed("kubectl create namespace k3s-probe")
        alpha.succeed(
            "kubectl run -n k3s-probe api-probe --image=busybox:1.36.1 --restart=Never -- sleep infinity"
        )
        alpha.wait_until_succeeds(
            "kubectl wait -n k3s-probe --for=condition=Ready pod/api-probe --timeout=120s",
            timeout=180,
        )
        for host, port in [("192.168.77.1", 6443), ("10.2.0.1", 443)]:
            alpha.wait_until_succeeds(
                f"kubectl exec -n k3s-probe api-probe -- nc -z -w 3 {host} {port}",
                timeout=60,
            )

        # cert-manager must be ready before the Gateway certificate can be issued.
        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Ready -n kube-system -l app.kubernetes.io/instance=cert-manager pod --timeout=120s",
            timeout=180,
        )

        # Default Traefik instance and its Gateway must converge.
        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Ready -n kube-system -l app.kubernetes.io/name=traefik pod --timeout=120s",
            timeout=180,
        )
        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Ready -n kube-system certificate/k3s-traefik-gateway-tls --timeout=120s",
            timeout=180,
        )
        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Programmed gateway/k3s-traefik-gateway -n kube-system --timeout=120s",
            timeout=180,
        )

        # Cilium health (kube-proxy replacement is enabled).
        alpha.wait_until_succeeds(
            "KUBECONFIG=/etc/rancher/k3s/k3s.yaml cilium status", timeout=180
        )

        # ClusterIP service round-trip proves kube-proxy replacement works.
        alpha.succeed("kubectl create namespace k3s-test")
        alpha.succeed("""
            kubectl run -n k3s-test server --image=busybox:1.36.1 --restart=Never -- sleep infinity
        """)
        alpha.wait_until_succeeds(
            "kubectl wait -n k3s-test --for=condition=Ready pod/server --timeout=120s", timeout=180
        )
        alpha.succeed("""
            kubectl exec -n k3s-test server -- sh -c 'echo OK > /tmp/index.html && httpd -f -p 8080 -h /tmp >/tmp/httpd.log 2>&1 </dev/null &'
        """)
        alpha.succeed("kubectl expose pod -n k3s-test server --port=80 --target-port=8080")
        alpha.wait_until_succeeds(
            "kubectl get endpoints -n k3s-test server -o jsonpath='{.subsets[0].addresses[0].ip}'",
            timeout=60,
        )
        out = alpha.succeed("""
            kubectl run -n k3s-test --rm --attach --restart=Never --image=busybox:1.36.1 client \
                -- wget -qO- http://server.k3s-test.svc.cluster.local/
        """)
        assert "OK" in out, f"ClusterIP round-trip returned {out!r}"

        # CoreDNS default lookup from a pod.
        out = alpha.succeed("""
            kubectl run -n k3s-test --rm --attach --restart=Never --image=busybox:1.36.1 coredns-default \
                -- nslookup kubernetes.default.svc.cluster.local
        """)
        assert "10.2.0.1" in out, f"kubernetes.default lookup failed: {out!r}"

        # CoreDNS rewrite from a pod.
        out = alpha.succeed("""
            kubectl run -n k3s-test --rm --attach --restart=Never --image=busybox:1.36.1 coredns-rewrite \
                -- nslookup foo.test.clan
        """)
        assert "10.2.0.1" in out, f"foo.test.clan rewrite failed: {out!r}"

        # cert-manager-backed Gateway HTTPS: extract the CA and port-forward to Traefik.
        alpha.succeed("""
            kubectl get secret rancher-ca -n kube-system -o jsonpath='{.data.tls\\.crt}' \
                | base64 -d > /tmp/rancher-ca.crt
        """)
        alpha.succeed("""
            nohup kubectl port-forward -n kube-system service/k3s-traefik 8443:443 8080:80 \
                >/tmp/pf.log 2>&1 </dev/null &
        """)
        alpha.wait_for_open_port(8443)
        alpha.wait_for_open_port(8080)

        # Valid CA: TLS succeeds. No matching route means 404.
        out = alpha.succeed("""
            curl --cacert /tmp/rancher-ca.crt -s -o /dev/null -w '%{http_code}' \
                -H 'Host: test.clan' --resolve test.clan:8443:127.0.0.1 \
                https://test.clan:8443/
        """)
        assert out.strip() == "404", f"expected 404 from HTTPS Gateway, got {out!r}"

        # Plain certless request fails TLS verification as designed.
        alpha.fail("""
            curl -s -o /dev/null -w '%{http_code}' \
                -H 'Host: test.clan' --resolve test.clan:8443:127.0.0.1 \
                https://test.clan:8443/
        """)

        # HTTP listener is also reachable (no routes, so 404).
        out = alpha.succeed("""
            curl -s -o /dev/null -w '%{http_code}' \
                -H 'Host: test.clan' --resolve test.clan:8080:127.0.0.1 \
                http://test.clan:8080/
        """)
        assert out.strip() == "404", f"expected 404 from HTTP Gateway, got {out!r}"

        # etcd smoke check
        alpha.succeed("kubectl create configmap k3s-smoke --from-literal=probe=ok")
        out = alpha.succeed("kubectl get configmap k3s-smoke -o jsonpath={.data.probe}")
        assert out.strip() == "ok", f"etcd smoke read back {out!r}"
    except Exception:
        fail_dump(alpha)
        raise
  '';
}
