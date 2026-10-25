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
              network.fabric = {
                service = "wireguard-mesh";
                instance = "mesh";
              };

              # Pinned id (§6.2): keeps CIDRs/clusterDNS/HAProxy ports stable.
              cilium.id = 1;

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
      environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

      services.k3s.images = [ busyboxImage ];
    };

  testScript = ''
    def fail_dump(m):
        for cmd in [
            "journalctl -u k3s --no-pager -l | tail -n 80",
            "journalctl -u k3s-k3s-bootstrap-apply --no-pager -l | tail -n 60 >&2 || true",
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
            "kubectl get configmap -n kube-system coredns -o yaml >&2 || true",
            "kubectl logs -n kube-system -l k8s-app=kube-dns --tail=200 >&2 || true",
            "for ip in $(kubectl get pod -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}'); do echo === coredns $ip === >&2; kubectl exec -n k3s-probe api-probe -- nslookup kubernetes.default.svc.cluster.local \"$ip\" >&2; done || true",
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

        # Transport (§6.3, dual-stack asserted in every boot test): the
        # node holds both mesh families on the WireGuard interface.
        alpha.succeed("ip -br addr show wg-mesh | grep -q '192.168.77.1/32'")
        alpha.succeed("ip -br addr show wg-mesh | grep -q 'fd00:77::1/128'")

        # The bootstrap bundle was applied by the oneshot (D40): unit
        # succeeded, bundle at the clan-owned path, nothing clan-owned in
        # the distro's watched manifests dir.
        alpha.wait_until_succeeds(
            "systemctl show -p Result --value k3s-k3s-bootstrap-apply | grep -q '^success$'",
            timeout=900,
        )
        alpha.succeed("test -f /etc/clan-bootstrap/k3s/bundle.yaml")
        alpha.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.metadata.labels.clan\.lol/cluster}' | grep -q '^k3s$'")

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

        # The node registers BOTH mesh families as InternalIPs, and the
        # topology labels default to the instance name (invariant 7).
        out = alpha.succeed(
            "kubectl get node alpha -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'"
        )
        assert "192.168.77.1" in out and "fd00:77::1" in out, f"dual-stack InternalIPs: {out!r}"
        alpha.succeed("kubectl get node alpha --show-labels | grep -q 'topology.kubernetes.io/region=k3s'")
        alpha.succeed("kubectl get node alpha --show-labels | grep -q 'topology.kubernetes.io/zone=k3s'")

        # The admin kubeconfig (vars PKI client cert) works through the
        # local haproxy LB (server URL = kubeapi FQDN on the LB port).
        alpha.succeed(
            "kubectl --kubeconfig /etc/rancher/k3s/admin-kubeconfig get --raw /readyz | grep -q ok"
        )

        # Pod API clients need both the real apiserver endpoint and Cilium's
        # ClusterIP translation.
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

        # The clan CoreDNS (D46): Service pinned to the derived clusterDNS
        # IP; direct pod-IP queries prove cluster.local + rewrites; a name
        # outside the served zones does not resolve (negative).
        alpha.wait_until_succeeds(
            "kubectl wait -n kube-system --for=condition=Available deployment/coredns --timeout=180s",
            timeout=240,
        )
        dns_ip = alpha.succeed(
            "kubectl get service -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}'"
        ).strip()
        assert dns_ip == "10.2.0.10", f"kube-dns clusterIP is {dns_ip!r}, expected 10.2.0.10"
        pod_ip = alpha.succeed(
            "kubectl get pod -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}'"
        ).strip()
        out = alpha.succeed(f"""
            kubectl exec -n k3s-probe api-probe -- nslookup kubernetes.default.svc.cluster.local {pod_ip}
        """)
        assert "10.2.0.1" in out, f"pod-IP direct lookup failed: {out!r}"
        out = alpha.succeed(f"""
            kubectl exec -n k3s-probe api-probe -- nslookup foo.test.clan {pod_ip}
        """)
        assert "10.2.0.1" in out, f"foo.test.clan rewrite via pod IP failed: {out!r}"
        alpha.fail(f"""
            kubectl exec -n k3s-probe api-probe -- nslookup nowhere.test.clan {pod_ip}
        """)

        # etcd smoke check
        alpha.succeed("kubectl create configmap k3s-smoke --from-literal=probe=ok")
        out = alpha.succeed("kubectl get configmap k3s-smoke -o jsonpath={.data.probe}")
        assert out.strip() == "ok", f"etcd smoke read back {out!r}"
    except Exception:
        fail_dump(alpha)
        raise
  '';
}
