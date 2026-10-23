_: {
  name = "rke2-single";

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

        rke2 = {
          module.name = "rke2";
          module.input = "self";

          roles.server = {
            settings = {
              network.transport = {
                service = "wireguard-mesh";
                instance = "mesh";
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
        pkgs.socat
      ];
      environment.sessionVariables.KUBECONFIG = "/etc/rancher/rke2/rke2.yaml";

      # Pre-load busybox for workload pods. Top-level symlink plus the service's
      # .cache.json marker makes the airgap importer see it.
      services.rke2.images = [ busyboxImage ];
      systemd.tmpfiles.rules = [
        "L+ /var/lib/rancher/rke2/agent/images/${builtins.unsafeDiscardStringContext (builtins.baseNameOf busyboxImage)} - - - - ${busyboxImage}"
      ];
    };

  testScript = ''
    def fail_dump(m):
        for cmd in [
            "journalctl -u rke2-server --no-pager -l | tail -n 80",
            "journalctl -u haproxy --no-pager -l | tail -n 40 >&2",
            "kubectl get nodes,pods -A -o wide >&2 || true",
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
            "kubectl get configmap -n kube-system rke2-coredns-rke2-coredns -o yaml >&2 || true",
            "kubectl get configmap -n kube-system coredns-custom -o yaml >&2 || true",
            "kubectl logs -n kube-system -l app.kubernetes.io/name=rke2-coredns --tail=200 >&2 || true",
            "for ip in $(kubectl get pod -n kube-system -l app.kubernetes.io/name=rke2-coredns -o jsonpath='{.items[*].status.podIP}'); do echo === coredns $ip === >&2; kubectl exec -n rke2-probe api-probe -- nslookup kubernetes.default.svc.cluster.local \"$ip\" >&2; done || true",
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
        alpha.wait_for_unit("rke2-server.service", timeout=600)

        # The pre-generated PKI was synced in before rke2-server started,
        # and the per-node haproxy LB is bound on the mesh address.
        # (pki-sync is a oneshot — prove the RESULT, not the unit state.)
        alpha.succeed("test -f /var/lib/rancher/rke2/server/tls/server-ca.crt")
        alpha.succeed("test -f /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt")
        alpha.succeed("test -f /var/lib/rancher/rke2/server/tls/service.key")
        for port in ["7443", "8443", "8404"]:
            alpha.succeed(f"ss -tln | grep -q ':{port}'")
        alpha.wait_until_succeeds(
            "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep '^rke2_api,alpha-4,' | grep -q ',UP,'",
            timeout=300,
        )

        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Ready node/alpha --timeout=120s", timeout=180
        )

        # The admin kubeconfig (vars PKI client cert) works through the
        # local haproxy LB (server URL = kubeapi FQDN on the LB port).
        alpha.succeed(
            "kubectl --kubeconfig /etc/rancher/rke2/admin-kubeconfig get --raw /readyz | grep -q ok"
        )

        # Pod API clients need both the real apiserver endpoint and Cilium's
        # ClusterIP translation.
        alpha.succeed("kubectl create namespace rke2-probe")
        alpha.succeed(
            "kubectl run -n rke2-probe api-probe --image=busybox:1.36.1 --restart=Never -- sleep infinity"
        )
        alpha.wait_until_succeeds(
            "kubectl wait -n rke2-probe --for=condition=Ready pod/api-probe --timeout=120s",
            timeout=180,
        )
        for host, port in [("192.168.77.1", 6443), ("10.2.0.1", 443)]:
            alpha.wait_until_succeeds(
                f"kubectl exec -n rke2-probe api-probe -- nc -z -w 3 {host} {port}",
                timeout=60,
            )

        # Cilium health (kube-proxy replacement is enabled).
        alpha.wait_until_succeeds(
            "KUBECONFIG=/etc/rancher/rke2/rke2.yaml cilium status", timeout=180
        )

        # ClusterIP service round-trip proves kube-proxy replacement works.
        alpha.succeed("kubectl create namespace rke2-test")
        alpha.succeed("""
            kubectl run -n rke2-test server --image=busybox:1.36.1 --restart=Never -- sleep infinity
        """)
        alpha.wait_until_succeeds(
            "kubectl wait -n rke2-test --for=condition=Ready pod/server --timeout=120s", timeout=180
        )
        alpha.succeed("""
            kubectl exec -n rke2-test server -- sh -c 'echo OK > /tmp/index.html && httpd -f -p 8080 -h /tmp >/tmp/httpd.log 2>&1 </dev/null &'
        """)
        alpha.succeed("kubectl expose pod -n rke2-test server --port=80 --target-port=8080")
        alpha.wait_until_succeeds(
            "kubectl get endpoints -n rke2-test server -o jsonpath='{.subsets[0].addresses[0].ip}'",
            timeout=60,
        )
        out = alpha.succeed("""
            kubectl run -n rke2-test --rm --attach --restart=Never --image=busybox:1.36.1 client \
                -- wget -qO- http://server.rke2-test.svc.cluster.local/
        """)
        assert "OK" in out, f"ClusterIP round-trip returned {out!r}"

        # CoreDNS default lookup from a pod.
        out = alpha.succeed("""
            kubectl run -n rke2-test --rm --attach --restart=Never --image=busybox:1.36.1 coredns-default \
                -- nslookup kubernetes.default.svc.cluster.local
        """)
        assert "10.2.0.1" in out, f"kubernetes.default lookup failed: {out!r}"

        # CoreDNS rewrite from a pod.
        out = alpha.succeed("""
            kubectl run -n rke2-test --rm --attach --restart=Never --image=busybox:1.36.1 coredns-rewrite \
                -- nslookup foo.test.clan
        """)
        assert "10.2.0.1" in out, f"foo.test.clan rewrite failed: {out!r}"

        # etcd smoke check
        alpha.succeed("kubectl create configmap rke2-smoke --from-literal=probe=ok")
        out = alpha.succeed("kubectl get configmap rke2-smoke -o jsonpath={.data.probe}")
        assert out.strip() == "ok", f"etcd smoke read back {out!r}"
    except Exception:
        fail_dump(alpha)
        raise
  '';
}
