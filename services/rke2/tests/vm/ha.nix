# rke2-ha: three RKE2 servers (managers) over the wireguard-mesh transport.
# Proves the HA shape: every manager joins through its OWN haproxy
# (kubeapi FQDN -> own mesh address, LB supervisor port 8443 -> manager
# supervisor backends over the mesh), etcd quorum with 3 members, Cilium
# healthy everywhere — then an unclean loss of one manager (shutdown):
# the survivors keep serving through their own haproxy (healthchecks mark
# the dead manager DOWN), fresh etcd writes succeed with 2/3 quorum, and
# new pods still schedule.
{
  name = "rke2-ha";

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
        gamma = { };
      };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = {
            alpha.settings.host = "alpha";
            beta.settings.host = "beta";
            gamma.settings.host = "gamma";
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

  nodes =
    let
      commonNode =
        { pkgs, ... }:
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
            memorySize = 3584;
            diskSize = 8192;
          };

          environment.systemPackages = [
            pkgs.kubectl
            pkgs.cilium-cli
            pkgs.socat
          ];
          environment.sessionVariables.KUBECONFIG = "/etc/rancher/rke2/rke2.yaml";

          services.rke2.images = [ busyboxImage ];
          systemd.tmpfiles.rules = [
            "L+ /var/lib/rancher/rke2/agent/images/${builtins.unsafeDiscardStringContext (builtins.baseNameOf busyboxImage)} - - - - ${busyboxImage}"
          ];
        };
    in
    {
      alpha = commonNode;
      beta = commonNode;
      gamma = commonNode;
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
            "journalctl -u rke2-server --no-pager -l | tail -n 80 >&2",
            "journalctl -u haproxy --no-pager -l | tail -n 40 >&2",
            "kubectl get nodes,pods -A -o wide >&2 || true",
            "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock >&2 || true",
            "cilium status >&2 || true",
        ]:
            m.execute(cmd)

    try:
        start_all()

        for m in machines:
            m.wait_for_unit("systemd-networkd.service", timeout=120)
            m.wait_for_unit("haproxy.service", timeout=240)
            m.wait_for_unit("rke2-server.service", timeout=600)

        # --- Transport (§6.3): full mesh, dual-stack ----------------------
        # Every node holds both mesh families; remote node InternalIPs are
        # reachable over the mesh in both families (alpha→beta/gamma and
        # gamma→alpha/beta).
        for m in machines:
            m.succeed(f"ip -br addr show wg-mesh | grep -q '{mesh_ips[m.name]}/32'")
            m.succeed(f"ip -br addr show wg-mesh | grep -q '{mesh_ips6[m.name]}/128'")
        for target in ["beta", "gamma"]:
            alpha.wait_until_succeeds(f"ping -c2 -W2 {mesh_ips[target]}", timeout=120)
            alpha.wait_until_succeeds(f"ping -6 -c2 -W2 {mesh_ips6[target]}", timeout=120)
            gamma.wait_until_succeeds(f"ping -c2 -W2 {mesh_ips[target]}", timeout=120)
            gamma.wait_until_succeeds(f"ping -6 -c2 -W2 {mesh_ips6[target]}", timeout=120)

        # --- Non-init managers joined through THEIR OWN haproxy ----------
        # kubeapi FQDN -> own mesh address (/etc/hosts), join URL on the LB
        # supervisor port 8443. The clusterInit manager has NO server URL.
        for name, m in [("alpha", alpha), ("beta", beta), ("gamma", gamma)]:
            m.succeed(f"grep -q '^{mesh_ips[name]} kubeapi-rke2.test.clan$' /etc/hosts")
            for port in ["7443", "8443", "8404"]:
                m.succeed(f"ss -tln | grep -q ':{port}'")
        for m in [beta, gamma]:
            m.succeed(
                "grep -q '\"server\":\"https://kubeapi-rke2.test.clan:8443\"' /etc/rancher/rke2/config.yaml"
            )
        alpha.succeed("! grep -q '\"server\"' /etc/rancher/rke2/config.yaml")

        for name in ["alpha", "beta", "gamma"]:
            alpha.wait_until_succeeds(
                f"kubectl wait --for=condition=Ready node/{name} --timeout=120s", timeout=180
            )

        # Every node registered with its mesh address as the node IP (both
        # families), and topology labels default to the instance name
        # (invariant 7).
        for name in mesh_ips:
            out = alpha.succeed(
                f"kubectl get node {name} -o jsonpath='{{.status.addresses[?(@.type==\"InternalIP\")].address}}'"
            )
            assert mesh_ips[name] in out and mesh_ips6[name] in out, (
                f"{name} InternalIPs {out.strip()!r} missing mesh addresses"
            )
            alpha.succeed(
                f"kubectl get node {name} --show-labels | grep -q 'topology.kubernetes.io/region=rke2'"
            )

        # --- All backends UP on every node --------------------------------
        # The TLS /readyz healthchecks over the mesh converge after the
        # nodes report Ready (a joining peer is L4-up before it can serve)
        # — poll until every server line of both backends reports UP.
        for m in machines:
            for backend in ["rke2_api", "rke2_supervisor_lb"]:
                m.wait_until_succeeds(
                    "for b in $(echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep '^%s,' | grep -v ',BACKEND,' | cut -d, -f18); do [ \"$b\" = UP ] || exit 1; done" % backend,
                    timeout=300,
                )

        # --- 3 etcd members ------------------------------------------------
        alpha.wait_until_succeeds(
            "test \"$(kubectl get pods -n kube-system -o name | grep -c '^pod/etcd-')\" -eq 3",
            timeout=240,
        )

        # --- Cilium healthy on every node ----------------------------------
        for m in machines:
            m.wait_until_succeeds("cilium status", timeout=180)

        # --- etcd smoke -----------------------------------------------------
        alpha.succeed("kubectl create configmap rke2-ha-smoke --from-literal=probe=ok")
        out = alpha.succeed("kubectl get configmap rke2-ha-smoke -o jsonpath={.data.probe}")
        assert out.strip() == "ok", f"etcd smoke read back {out!r}"

        # --- HA: unclean loss of beta ---------------------------------------
        # The survivors keep serving through their OWN haproxy + apiservers,
        # the mesh routes around the dead node, and etcd holds 2/3 quorum.
        beta.shutdown()

        # The survivors' haproxy healthchecks mark beta's backends DOWN.
        for m in [alpha, gamma]:
            m.wait_until_succeeds(
                "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep '^rke2_api,beta-4,' | grep -q ',DOWN,'",
                timeout=300,
            )

        # The API keeps answering — through the local haproxy (the admin
        # kubeconfig's server URL is the kubeapi FQDN on the LB port).
        alpha.wait_until_succeeds(
            "kubectl --kubeconfig /etc/rancher/rke2/admin-kubeconfig get --raw /readyz | grep -q ok",
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

        # A fresh etcd write through the 2/3 quorum.
        alpha.succeed("kubectl create configmap rke2-ha-post-crash --from-literal=probe=survived")
        out = alpha.succeed("kubectl get configmap rke2-ha-post-crash -o jsonpath={.data.probe}")
        assert out.strip() == "survived", f"post-crash etcd read back {out!r}"

        # Pods still schedule on the survivors.
        alpha.succeed(
            "kubectl run ha-post-crash --image=busybox:1.36.1 --restart=Never --overrides='{\"spec\":{\"nodeName\":\"gamma\"}}' -- sleep infinity"
        )
        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Ready pod/ha-post-crash --timeout=120s", timeout=180
        )
    except Exception:
        for m in machines:
            try:
                fail_dump(m)
            except Exception:
                pass
        raise
  '';
}
