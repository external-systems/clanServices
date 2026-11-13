# <distro>-single: one clusterInit server over the wireguard-mesh transport.
# Shared by the k3s and rke2 suites; every distro difference is a `k3s`
# branch below.
{
  lib,
  inputs,
  distro,
}: let
  k3s = distro == "k3s";
  serverUnit =
    if k3s
    then "k3s"
    else "rke2-server";
  kubeconfig = "/etc/rancher/${distro}/${distro}.yaml";
  lbPorts =
    if k3s
    then ''"6443", "7443", "8404"''
    else ''"7443", "8443", "8404"'';
  # Splice a multi-line distro branch into testScript: every line after the
  # first gets `n` spaces of indentation (blank lines stay empty).
  indent = n: s: let
    lines = lib.splitString "\n" (lib.removeSuffix "\n" s);
  in
    lib.concatStringsSep "\n" (
      [(lib.head lines)]
      ++ map (l: lib.optionalString (l != "") (lib.concatStrings (lib.replicate n " ") + l)) (lib.tail lines)
    );
  # Lines only one distro has, appended after the preceding line.
  extra = n: cond: s: lib.optionalString cond (indent n ("\n" + s));
  # The pod-side cluster.local lookup both distros run (at different points).
  corednsDefaultLookup = ''
    out = alpha.succeed("""
        kubectl run -n ${distro}-test --rm --attach --restart=Never --image=busybox:1.36.1 coredns-default \
            -- nslookup kubernetes.default.svc.cluster.local
    """)
    assert "10.2.0.1" in out, f"kubernetes.default lookup failed: {out!r}"'';
in {
  name = "${distro}-single";

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules.wireguard-mesh = lib.modules.importApply ../../../../services/wireguard-mesh/default.nix {
      ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
    };
    exportInterfaces.node_transport = ../../../node-transport-interface.nix;

    inventory = {
      meta.domain = "test.clan";

      machines.alpha = {};

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

        ${distro} = {
          module.name = distro;
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

  nodes.alpha = {pkgs, ...}: let
    busyboxImage = pkgs.dockerTools.pullImage {
      imageName = "busybox";
      imageDigest = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662";
      hash = "sha256-OasmfjRQsuVWudSc4qWuMKK5nNz4hdIS8Si4B0okXEw=";
      finalImageTag = "1.36.1";
    };
  in {
    imports = [
      (import ../../../../tests/ifstate-vm.nix {
        ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
        addresses = ["192.168.1.1/24"];
      })
    ];
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
    environment.sessionVariables.KUBECONFIG = kubeconfig;

    services.${distro}.images = [busyboxImage];
    # RKE2: a top-level symlink plus the service's .cache.json marker makes
    # the airgap importer see the busybox image.
    systemd.tmpfiles.rules = lib.mkIf (!k3s) [
      "L+ /var/lib/rancher/rke2/agent/images/${builtins.unsafeDiscardStringContext (baseNameOf busyboxImage)} - - - - ${busyboxImage}"
    ];
  };

  testScript = ''
    def fail_dump(m):
        for cmd in [
            "journalctl -u ${serverUnit} --no-pager -l | tail -n 80",${extra 8 k3s ''
        "journalctl -u k3s-k3s-bootstrap-apply --no-pager -l | tail -n 60 >&2 || true",''}
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
            ${indent 8 (
      if k3s
      then ''
        "kubectl get configmap -n kube-system coredns -o yaml >&2 || true",
        "kubectl logs -n kube-system -l k8s-app=kube-dns --tail=200 >&2 || true",
        "for ip in $(kubectl get pod -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}'); do echo === coredns $ip === >&2; kubectl exec -n k3s-probe api-probe -- nslookup kubernetes.default.svc.cluster.local \"$ip\" >&2; done || true",
        "for j in $(kubectl get jobs -n kube-system -o name); do echo === $j === >&2; kubectl logs -n kube-system $j --all-containers=true --tail=40 >&2; done",''
      else ''
        # The clan CoreDNS (D46): configmap + pod logs.
        "kubectl get configmap -n kube-system coredns -o yaml >&2 || true",
        "kubectl logs -n kube-system -l k8s-app=kube-dns --tail=100 >&2 || true",''
    )}
            "kubectl get events -A --sort-by=.lastTimestamp | tail -n 120 >&2 || true",
            "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock >&2 || true",${extra 8 (!k3s) ''
        "journalctl -u rke2-rke2-bootstrap-apply --no-pager -l | tail -n 60 >&2 || true",''}
            "cilium status >&2 || true",
        ]:
            m.execute(cmd)

    try:
        start_all()

        with subtest("ifstate, haproxy and the runtime come up"):
            alpha.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
            alpha.wait_for_unit("haproxy.service", timeout=240)
            alpha.wait_for_unit("${serverUnit}.service", timeout=600)

        # Transport (§6.3, dual-stack asserted in every boot test): the
        # node holds both mesh families on the WireGuard interface.
        with subtest("dual-stack mesh addresses on wg-mesh"):
            alpha.succeed("ip -br addr show wg-mesh | grep '192.168.77.1/32' >/dev/null")
            alpha.succeed("ip -br addr show wg-mesh | grep 'fd00:77::1/128' >/dev/null")

        # The bootstrap bundle was applied by the oneshot (D40): unit
        ${indent 4 (
      if k3s
      then ''
        # succeeded, bundle at the clan-owned path, nothing clan-owned in
        # the distro's watched manifests dir.''
      else ''
        # succeeded, bundle at the clan-owned path, nothing in the distro's
        # watched manifests dir.''
    )}
        with subtest("bootstrap bundle applied by the oneshot"):
            alpha.wait_until_succeeds(
                "systemctl show -p Result --value ${distro}-${distro}-bootstrap-apply | grep '^success$' >/dev/null",
                timeout=900,
            )
            alpha.succeed("test -f /etc/clan-bootstrap/${distro}/bundle.yaml")
            ${indent 8 (
      if k3s
      then ''
        alpha.wait_until_succeeds(
            "kubectl get configmap -n kube-system cilium-config -o jsonpath='{.metadata.labels.clan\.lol/cluster}' | grep '^k3s$' >/dev/null",
            timeout=300,
        )''
      else ''
        # Nothing clan-owned in the distro's watched manifests dir (D40):
        # no rke2-cilium chart manifest, no clan manifests.
        alpha.wait_until_succeeds(
            "! ls /var/lib/rancher/rke2/server/manifests/ 2>/dev/null | grep -i cilium >/dev/null",
            timeout=300,
        )''
    )}

        ${indent 4 (
      if k3s
      then ''
        # The initial server seeded the pre-generated PKI before k3s started,
        # and the per-node haproxy LB is bound on the mesh address.''
      else ''
        # The pre-generated PKI was synced in before rke2-server started,
        # and the per-node haproxy LB is bound on the mesh address.
        # (pki-sync is a oneshot — prove the RESULT, not the unit state.)''
    )}
        with subtest("PKI in place and the haproxy LB serving"):${extra 8 k3s ''
        alpha.succeed("systemctl show -p Result --value k3s-k3s-pki-seed | grep '^success$' >/dev/null")''}
            alpha.succeed("test -f /var/lib/rancher/${distro}/server/tls/server-ca.crt")
            alpha.succeed("test -f /var/lib/rancher/${distro}/server/tls/etcd/server-ca.crt")
            alpha.succeed("test -f /var/lib/rancher/${distro}/server/tls/service.key")
            for port in [${lbPorts}]:
                alpha.succeed(f"ss -tln | grep ':{port}' >/dev/null")
            alpha.wait_until_succeeds(
                "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep '^${distro}_api,alpha-4,' | grep ',UP,' >/dev/null",
                timeout=300,
            )

        with subtest("node Ready with dual-stack InternalIPs and topology labels"):
            alpha.wait_until_succeeds(
                "kubectl wait --for=condition=Ready node/alpha --timeout=120s", timeout=180
            )

            # The node registers BOTH mesh families as InternalIPs, and the
            # topology labels default to the instance name (invariant 7).
            out = alpha.succeed(
                "kubectl get node alpha -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'"
            )
            assert "192.168.77.1" in out and "fd00:77::1" in out, f"dual-stack InternalIPs: {out!r}"
            alpha.succeed("kubectl get node alpha --show-labels | grep 'topology.kubernetes.io/region=${distro}' >/dev/null")
            alpha.succeed("kubectl get node alpha --show-labels | grep 'topology.kubernetes.io/zone=${distro}' >/dev/null")

        # The admin kubeconfig (vars PKI client cert) works through the
        # local haproxy LB (server URL = kubeapi FQDN on the LB port).
        with subtest("admin kubeconfig works through the local LB"):
            alpha.succeed(
                "kubectl --kubeconfig /etc/rancher/${distro}/admin-kubeconfig get --raw /readyz | grep ok >/dev/null"
            )

        # Pod API clients need both the real apiserver endpoint and Cilium's
        # ClusterIP translation.
        with subtest("pods reach the apiserver directly and via ClusterIP"):
            alpha.succeed("kubectl create namespace ${distro}-probe")
            alpha.succeed(
                "kubectl run -n ${distro}-probe api-probe --image=busybox:1.36.1 --restart=Never -- sleep infinity"
            )
            alpha.wait_until_succeeds(
                "kubectl wait -n ${distro}-probe --for=condition=Ready pod/api-probe --timeout=120s",
                timeout=180,
            )
            for host, port in [("192.168.77.1", 6443), ("10.2.0.1", 443)]:
                alpha.wait_until_succeeds(
                    f"kubectl exec -n ${distro}-probe api-probe -- nc -z -w 3 {host} {port}",
                    timeout=60,
                )

        # Cilium health (kube-proxy replacement is enabled).
        with subtest("Cilium healthy"):
            alpha.wait_until_succeeds(
                "KUBECONFIG=${kubeconfig} cilium status", timeout=180
            )

        # ClusterIP service round-trip proves kube-proxy replacement works.
        with subtest("ClusterIP round-trip"):
            alpha.succeed("kubectl create namespace ${distro}-test")
            alpha.succeed("""
                kubectl run -n ${distro}-test server --image=busybox:1.36.1 --restart=Never -- sleep infinity
            """)
            alpha.wait_until_succeeds(
                "kubectl wait -n ${distro}-test --for=condition=Ready pod/server --timeout=120s", timeout=180
            )
            alpha.succeed("""
                kubectl exec -n ${distro}-test server -- sh -c 'echo OK > /tmp/index.html && httpd -f -p 8080 -h /tmp >/tmp/httpd.log 2>&1 </dev/null &'
            """)
            alpha.succeed("kubectl expose pod -n ${distro}-test server --port=80 --target-port=8080")
            alpha.wait_until_succeeds(
                "kubectl get endpoints -n ${distro}-test server -o jsonpath='{.subsets[0].addresses[0].ip}'",
                timeout=60,
            )
            ${indent 8 (
      if k3s
      then ''
        out = alpha.succeed("""
            kubectl run -n k3s-test --rm --attach --restart=Never --image=busybox:1.36.1 client \
                -- wget -qO- http://server.k3s-test.svc.cluster.local/
        """)''
      else ''
        cluster_ip = alpha.succeed(
            "kubectl get service -n rke2-test server -o jsonpath='{.spec.clusterIP}'"
        ).strip()
        out = alpha.succeed(f"""
            kubectl run -n rke2-test --rm --attach --restart=Never --image=busybox:1.36.1 client \
                -- wget -qO- http://{cluster_ip}/
        """)''
    )}
            assert "OK" in out, f"ClusterIP round-trip returned {out!r}"

        with subtest("clan CoreDNS: cluster.local, rewrites and a negative lookup"):
            ${indent 8 (
      if k3s
      then ''
        # CoreDNS default lookup from a pod.
        ${corednsDefaultLookup}

        # CoreDNS rewrite from a pod.
        out = alpha.succeed("""
            kubectl run -n k3s-test --rm --attach --restart=Never --image=busybox:1.36.1 coredns-rewrite \
                -- nslookup foo.test.clan
        """)
        assert "10.2.0.1" in out, f"foo.test.clan rewrite failed: {out!r}"

        # The clan CoreDNS (D46): Service pinned to the derived clusterDNS
        # IP; direct pod-IP queries prove cluster.local + rewrites; a name
        # outside the served zones does not resolve (negative).''
      else ''
        # --- The clan CoreDNS (D46): uniform cluster.local DNS ----------''
    )}
            alpha.wait_until_succeeds(
                "kubectl wait -n kube-system --for=condition=Available deployment/coredns --timeout=180s",
                timeout=240,
            )${extra 8 (!k3s) ''
        # The Service is pinned to the derived clusterDNS IP.''}
            dns_ip = alpha.succeed(
                "kubectl get service -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}'"
            ).strip()
            assert dns_ip == "10.2.0.10", f"kube-dns clusterIP is {dns_ip!r}, expected 10.2.0.10"${extra 8 (!k3s) ''

      # cluster.local resolution from a pod (through the pod's
      # resolv.conf -> the pinned clusterDNS Service IP).
      ${corednsDefaultLookup}

      # Direct query against the CoreDNS POD IP: cluster.local and the
      # coredns.rewrites aliasing (D21/D22).''}
            pod_ip = alpha.succeed(
                "kubectl get pod -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}'"
            ).strip()
            out = alpha.succeed(f"""
                kubectl exec -n ${distro}-probe api-probe -- nslookup kubernetes.default.svc.cluster.local {pod_ip}
            """)
            assert "10.2.0.1" in out, f"pod-IP direct lookup failed: {out!r}"
            out = alpha.succeed(f"""
                kubectl exec -n ${distro}-probe api-probe -- nslookup foo.test.clan {pod_ip}
            """)
            assert "10.2.0.1" in out, f"foo.test.clan rewrite${lib.optionalString k3s " via pod IP"} failed: {out!r}"${extra 8 (!k3s) ''

      # Negative: a name outside the served zones does not resolve.''}
            alpha.fail(f"""
                kubectl exec -n ${distro}-probe api-probe -- nslookup nowhere.test.clan {pod_ip}
            """)

        # etcd smoke check
        with subtest("etcd smoke write"):
            alpha.succeed("kubectl create configmap ${distro}-smoke --from-literal=probe=ok")
            out = alpha.succeed("kubectl get configmap ${distro}-smoke -o jsonpath={.data.probe}")
            assert out.strip() == "ok", f"etcd smoke read back {out!r}"
        print("${lib.toUpper distro}_SINGLE_OK")
    except Exception:
        fail_dump(alpha)
        raise
  '';
}
