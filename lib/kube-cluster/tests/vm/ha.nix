# <distro>-ha: three servers (managers) on the routed fabric
# (routed-fabric, FRR, per-pair WireGuard, Cilium native routing).
# Proves the HA shape: every manager joins through its OWN haproxy
# (kubeapi FQDN -> own node address; k3s: LB kubeapi port 7443 -> manager
# kube-apiserver backends, rke2: LB supervisor port 8443 -> manager
# supervisor backends, over the fabric), etcd quorum with 3 members, Cilium
# healthy everywhere — then an unclean loss of one manager (shutdown):
# the survivors keep serving through their own haproxy (healthchecks mark
# the dead manager DOWN), fresh etcd writes succeed with 2/3 quorum, and
# new pods still schedule.
#
# alpha and beta are spines, gamma is a leaf attached to both. The
# manager that dies (beta) is a spine, so the survivors also prove that
# the fabric routes around a dead spine.
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
  # Splice a multi-line distro branch into testScript: every line after the
  # first gets `n` spaces of indentation (blank lines stay empty).
  indent = n: s: let
    lines = lib.splitString "\n" (lib.removeSuffix "\n" s);
  in
    lib.concatStringsSep "\n" (
      [(lib.head lines)]
      ++ map (l: lib.optionalString (l != "") (lib.concatStrings (lib.replicate n " ") + l)) (lib.tail lines)
    );
  # The fabric loopback that holds the node addresses.
  loopback = "rflo${builtins.substring 0 10 (builtins.hashString "sha256" "mesh")}";
  member = n: {
    settings = {
      ipv4 = "192.168.77.${toString n}";
      ipv6 = "fd00:77::${toString n}";
      endpointSources = [
        {
          service = "clan-core/internet";
          instance = "underlay";
        }
      ];
    };
  };
in {
  name = "${distro}-ha";

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules.routed-fabric = lib.modules.importApply ../../../../services/routed-fabric/default.nix {
      ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
    };
    exportInterfaces = {
      routed_fabric = ../../../../services/routed-fabric/routed-fabric-interface.nix;
      node_transport = ../../../node-transport-interface.nix;
    };

    inventory = {
      meta.domain = "test.clan";

      machines = {
        alpha = {};
        beta = {};
        gamma = {};
      };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = {
            # IP literals: a hostname endpoint is an eval error
            # (routed-fabric R4)
            alpha.settings.host = "192.168.1.1";
            beta.settings.host = "192.168.1.2";
            gamma.settings.host = "192.168.1.3";
          };
        };

        mesh = {
          module.name = "routed-fabric";
          module.input = "self";
          roles = {
            # one LAN: the fast timers (the default between sites is `wan`)
            spine.settings.site = "lab";
            leaf.settings.site = "lab";
            spine.machines = {
              alpha = member 1;
              beta = member 2;
            };
            leaf.machines.gamma = member 3;
          };
        };

        ${distro} = {
          module.name = distro;
          module.input = "self";

          roles.server = {
            settings = {
              network.fabric = {
                service = "routed-fabric";
                instance = "mesh";
              };
              # Pinned id (§6.2): keeps CIDRs/clusterDNS/HAProxy ports stable.
              cilium.id = 1;
            };
            machines = {
              alpha.settings.clusterInit = true;
              beta.settings.clusterInit = false;
              gamma.settings.clusterInit = false;
            };
          };
        };
      };
    };
  };

  nodes = let
    commonNode = name: {pkgs, ...}: let
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
          addresses = [
            "192.168.1.${
              toString
              {
                alpha = 1;
                beta = 2;
                gamma = 3;
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

      # k3s counts embedded-etcd members with etcdctl; rke2 counts its
      # etcd static pods.
      environment.systemPackages =
        [
          pkgs.kubectl
          pkgs.cilium-cli
        ]
        ++ lib.optional k3s pkgs.etcd
        ++ [pkgs.socat];
      environment.sessionVariables.KUBECONFIG = "/etc/rancher/${distro}/${distro}.yaml";

      services.${distro}.images = [busyboxImage];
      # RKE2: a top-level symlink plus the service's .cache.json marker makes
      # the airgap importer see the busybox image.
      systemd.tmpfiles.rules = lib.mkIf (!k3s) [
        "L+ /var/lib/rancher/rke2/agent/images/${builtins.unsafeDiscardStringContext (baseNameOf busyboxImage)} - - - - ${busyboxImage}"
      ];
    };
  in {
    alpha = commonNode "alpha";
    beta = commonNode "beta";
    gamma = commonNode "gamma";
  };

  testScript = ''
    machines = [alpha, beta, gamma]
    mesh_ips = {
        "alpha": "192.168.77.1",
        "beta": "192.168.77.2",
        "gamma": "192.168.77.3",
    }
    mesh_ips6 = {
        "alpha": "fd00:77::1",
        "beta": "fd00:77::2",
        "gamma": "fd00:77::3",
    }

    def fail_dump(m):
        for cmd in [
            "journalctl -u ${serverUnit} --no-pager -l | tail -n 80 >&2",
            "journalctl -u haproxy --no-pager -l | tail -n 40 >&2",
            "kubectl get nodes,pods -A -o wide >&2 || true",
            "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock >&2 || true",
            "cilium status >&2 || true",
        ]:
            m.execute(cmd)

    try:
        start_all()

        with subtest("ifstate, haproxy and the runtime up on every manager"):
            for m in machines:
                m.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
                m.wait_for_unit("haproxy.service", timeout=240)
                m.wait_for_unit("${serverUnit}.service", timeout=600)

        # --- Transport (§6.3): the routed fabric, dual-stack -------------
        # Every node holds both families on its fabric loopback; remote node InternalIPs are
        ${indent 4 (
      if k3s
      then ''
        # reachable over the fabric in both families (alpha↔beta, alpha↔gamma).''
      else ''
        # reachable over the fabric in both families (alpha→beta/gamma and
        # gamma→alpha/beta).''
    )}
        with subtest("dual-stack node addresses over the routed fabric"):
            for m in machines:
                m.succeed(f"ip -br addr show ${loopback} | grep '{mesh_ips[m.name]}/32' >/dev/null")
                m.succeed(f"ip -br addr show ${loopback} | grep '{mesh_ips6[m.name]}/128' >/dev/null")
            for target in ["beta", "gamma"]:
                alpha.wait_until_succeeds(f"ping -c2 -W2 {mesh_ips[target]}", timeout=120)
                alpha.wait_until_succeeds(f"ping -6 -c2 -W2 {mesh_ips6[target]}", timeout=120)
                gamma.wait_until_succeeds(f"ping -c2 -W2 {mesh_ips[target]}", timeout=120)
                gamma.wait_until_succeeds(f"ping -6 -c2 -W2 {mesh_ips6[target]}", timeout=120)

        # --- Non-init managers joined through THEIR OWN haproxy ----------
        # kubeapi FQDN -> own node address (/etc/hosts), join URL on the LB
        ${
      if k3s
      then "# kubeapi port 7443."
      else "# supervisor port 8443."
    } The clusterInit manager has NO server URL.
        with subtest("non-init managers joined through their own haproxy"):
            for name, m in [("alpha", alpha), ("beta", beta), ("gamma", gamma)]:
                m.succeed(f"grep -q '^{mesh_ips[name]} kubeapi-${distro}.test.clan$' /etc/hosts")
                for port in [${
      if k3s
      then ''"6443", "7443", "8404"''
      else ''"7443", "8443", "8404"''
    }]:
                    m.succeed(f"ss -tln | grep ':{port}' >/dev/null")
            for m in [beta, gamma]:
                m.succeed(
                    "grep -q '\"server\":\"https://kubeapi-${distro}.test.clan:${
      if k3s
      then "7443"
      else "8443"
    }\"' /etc/rancher/${distro}/config.yaml"
                )
            alpha.succeed("! grep -q '\"server\"' /etc/rancher/${distro}/config.yaml")

        with subtest("every manager Ready with mesh InternalIPs and topology labels"):
            for name in ["alpha", "beta", "gamma"]:
                alpha.wait_until_succeeds(
                    f"kubectl wait --for=condition=Ready node/{name} --timeout=120s", timeout=180
                )

            # Every node registered with its fabric address as the node IP (both
            # families), and topology labels default to the instance name
            # (invariant 7).
            for name in mesh_ips:
                out = alpha.succeed(
                    f"kubectl get node {name} -o jsonpath='{{.status.addresses[?(@.type==\"InternalIP\")].address}}'"
                )
                assert mesh_ips[name] in out and mesh_ips6[name] in out, (
                    f"{name} InternalIPs {out.strip()!r} missing node addresses"
                )
                alpha.succeed(
                    f"kubectl get node {name} --show-labels | grep 'topology.kubernetes.io/region=${distro}' >/dev/null"
                )

        ${indent 4 (
      if k3s
      then ''
        # --- All API backends UP on every node -----------------------------
        # The TLS /readyz healthchecks over the fabric converge after the
        # nodes report Ready (a joining peer is L4-up before it can serve)
        # — poll until every API server line reports UP.
        with subtest("all haproxy backends UP on every node"):
            for m in machines:
                m.wait_until_succeeds(
                    "for b in $(echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep '^k3s_api,' | grep -v ',BACKEND,' | cut -d, -f18); do [ \"$b\" = UP ] || exit 1; done",
                    timeout=300,
                )

        # --- 3 embedded-etcd members -----------------------------------------
        with subtest("3 etcd members"):
            alpha.wait_until_succeeds(
                "test \"$(ETCDCTL_API=3 etcdctl --endpoints=https://192.168.77.1:2379,https://192.168.77.2:2379,https://192.168.77.3:2379 --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt --key=/var/lib/rancher/k3s/server/tls/etcd/client.key member list | wc -l)\" -eq 3",
                timeout=240,
            )''
      else ''
        # --- All backends UP on every node --------------------------------
        # The TLS /readyz healthchecks over the fabric converge after the
        # nodes report Ready (a joining peer is L4-up before it can serve)
        # — poll until every server line of both backends reports UP.
        with subtest("all haproxy backends UP on every node"):
            for m in machines:
                for backend in ["rke2_api", "rke2_supervisor_lb"]:
                    m.wait_until_succeeds(
                        "for b in $(echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep '^%s,' | grep -v ',BACKEND,' | cut -d, -f18); do [ \"$b\" = UP ] || exit 1; done" % backend,
                        timeout=300,
                    )

        # --- 3 etcd members ------------------------------------------------
        with subtest("3 etcd members"):
            alpha.wait_until_succeeds(
                "test \"$(kubectl get pods -n kube-system -o name | grep -c '^pod/etcd-')\" -eq 3",
                timeout=240,
            )''
    )}

        # --- Cilium healthy on every node ----------------------------------
        with subtest("Cilium healthy on every node"):
            for m in machines:
                m.wait_until_succeeds("cilium status", timeout=180)

        # --- etcd smoke -----------------------------------------------------
        with subtest("etcd smoke write"):
            alpha.succeed("kubectl create configmap ${distro}-ha-smoke --from-literal=probe=ok")
            out = alpha.succeed("kubectl get configmap ${distro}-ha-smoke -o jsonpath={.data.probe}")
            assert out.strip() == "ok", f"etcd smoke read back {out!r}"

        # --- HA: unclean loss of beta ---------------------------------------
        # The survivors keep serving through their OWN haproxy + apiservers,
        # the fabric routes around the dead node, and etcd holds 2/3 quorum.
        with subtest("unclean loss of beta: survivors mark it DOWN and keep serving"):
            # crash(), not shutdown(): no unit on beta gets to say goodbye.
            beta.crash()

            # The survivors' haproxy healthchecks mark beta's backends DOWN.
            for m in [alpha, gamma]:
                m.wait_until_succeeds(
                    "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep '^${distro}_api,beta-4,' | grep ',DOWN,' >/dev/null",
                    timeout=300,
                )

            # The API keeps answering — through the local haproxy (the admin
            # kubeconfig's server URL is the kubeapi FQDN on the LB port).
            for m in [alpha, gamma]:
                m.wait_until_succeeds(
                    "kubectl --kubeconfig /etc/rancher/${distro}/admin-kubeconfig get --raw /readyz | grep ok >/dev/null",
                    timeout=300,
                )

            # Node list from the survivor: beta falls NotReady, 2/3 stay Ready.
            alpha.wait_until_succeeds(
                "test \"$(kubectl get node beta -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" != 'True'",
                timeout=300,
            )
            for name in ["alpha", "gamma"]:
                out = alpha.succeed(
                    f"kubectl get node {name} -o jsonpath='{{.status.conditions[?(@.type==\"Ready\")].status}}'"
                )
                assert out.strip() == "True", f"{name} not Ready after beta loss: {out!r}"

        with subtest("2/3 quorum takes writes and pods still schedule"):
            # A fresh etcd write through the 2/3 quorum.
            alpha.succeed("kubectl create configmap ${distro}-ha-post-crash --from-literal=probe=survived")
            out = alpha.succeed("kubectl get configmap ${distro}-ha-post-crash -o jsonpath={.data.probe}")
            assert out.strip() == "survived", f"post-crash etcd read back {out!r}"

            # Pods still schedule on the survivors: the scheduler picks
            # the node, nothing names one.
            alpha.succeed(
                "kubectl run ha-post-crash --image=busybox:1.36.1 --restart=Never -- sleep infinity"
            )
            alpha.wait_until_succeeds(
                "kubectl wait --for=condition=Ready pod/ha-post-crash --timeout=120s", timeout=180
            )
            placed = alpha.succeed("kubectl get pod ha-post-crash -o jsonpath='{.spec.nodeName}'").strip()
            assert placed in ("alpha", "gamma"), f"the pod was scheduled on {placed!r}"

        with subtest("cluster DNS survives the loss (D70: the replicas never share a node)"):
            print(alpha.succeed("kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide"))
            alpha.wait_until_succeeds(
                "kubectl exec ha-post-crash -- nslookup kubernetes.default.svc.cluster.local | grep 'Address' >/dev/null",
                timeout=180,
            )

        with subtest("beta returns: three Ready nodes, the API on beta, both DNS replicas"):
            beta.start()
            alpha.wait_until_succeeds(
                "test \"$(kubectl get nodes --no-headers | grep -c ' Ready ')\" -eq 3",
                timeout=900,
            )
            beta.wait_until_succeeds(
                "kubectl --kubeconfig /etc/rancher/${distro}/admin-kubeconfig get --raw /readyz | grep ok >/dev/null",
                timeout=600,
            )
            for m in [alpha, gamma]:
                m.wait_until_succeeds(
                    "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep '^${distro}_api,beta-4,' | grep ',UP,' >/dev/null",
                    timeout=600,
                )
            # a write after the return, read back on the node that was dead
            alpha.succeed("kubectl create configmap ${distro}-ha-rejoined --from-literal=probe=back")
            beta.wait_until_succeeds(
                "kubectl get configmap ${distro}-ha-rejoined -o jsonpath={.data.probe} | grep -x back >/dev/null",
                timeout=300,
            )
            alpha.wait_until_succeeds(
                "kubectl -n kube-system get deployment coredns -o jsonpath='{.status.readyReplicas}' | grep -x 2 >/dev/null",
                timeout=600,
            )
            for m in machines:
                m.wait_until_succeeds("cilium status", timeout=300)
        print("${lib.toUpper distro}_HA_OK")
    except Exception:
        for m in machines:
            try:
                fail_dump(m)
            except Exception:
                pass
        raise
  '';
}
