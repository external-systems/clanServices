# rke2-join: one server + one agent over the wireguard-mesh transport.
# The agent joins through its LOCAL haproxy: the kubeapi FQDN resolves to
# the agent's own mesh address (/etc/hosts), where its haproxy supervisor
# frontend (8443 = 7442 + cilium.id 1 + 1000) balances to the server's
# real supervisor (9345) with TLS /readyz healthchecks.
{
  name = "rke2-join";

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

        rke2 = {
          module.name = "rke2";
          module.input = "self";

          roles.server = {
            settings = {
              network.transport = {
                service = "wireguard-mesh";
                instance = "mesh";
              };

              # Focus on the join path; skip the optional stacks.
              traefik.enabled = false;
              certManager.enabled = false;
            };
            machines.alpha.settings.clusterInit = true;
          };

          roles.agent = {
            settings.network.transport = {
              service = "wireguard-mesh";
              instance = "mesh";
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
          ];
        };
    in
    {
      alpha = commonNode;
      beta = commonNode;
    };

  testScript = ''
    def fail_dump(m):
        for cmd in [
            "ip -br addr >&2",
            "journalctl -u rke2-server --no-pager -l | tail -n 80 >&2",
            "journalctl -u rke2-agent --no-pager -l | tail -n 80 >&2",
            "journalctl -u haproxy --no-pager -l | tail -n 40 >&2",
            "ss -tlnp | grep -E '7443|8443|8404|6443|9345' >&2 || true",
            "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock >&2 || true",
        ]:
            m.execute(cmd)

    try:
        start_all()

        for m in [alpha, beta]:
            m.wait_for_unit("systemd-networkd.service", timeout=120)
            m.wait_for_unit("haproxy.service", timeout=240)

        alpha.wait_for_unit("rke2-server.service", timeout=600)
        beta.wait_for_unit("rke2-agent.service", timeout=600)

        # --- The agent joined through its OWN haproxy --------------------
        # kubeapi FQDN -> own mesh address (/etc/hosts), join URL on the
        # LB supervisor port 8443 (the supervisor owns 9345 itself).
        for m, ip in [(alpha, "192.168.77.1"), (beta, "192.168.77.2")]:
            m.succeed(f"grep -q '^{ip} kubeapi-rke2.test.clan$' /etc/hosts")
            m.succeed("systemctl is-active haproxy")
            for port in ["7443", "8443", "8404"]:
                m.succeed(f"ss -tln | grep -q ':{port}'")
        beta.succeed(
            "grep -q '\"server\":\"https://kubeapi-rke2.test.clan:8443\"' /etc/rancher/rke2/config.yaml"
        )
        alpha.succeed("! grep -q '\"server\"' /etc/rancher/rke2/config.yaml")

        # The agent's haproxy kubeapi backend (alpha) is UP — the join and
        # the agent's Cilium API traffic ride the local LB.
        beta.wait_until_succeeds(
            "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep '^rke2_api,alpha-4,' | grep -q ',UP,'",
            timeout=300,
        )

        # --- Both nodes Ready with mesh InternalIPs -----------------------
        alpha.wait_until_succeeds(
            "KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s",
            timeout=240,
        )
        for name, ip in [("alpha", "192.168.77.1"), ("beta", "192.168.77.2")]:
            out = alpha.succeed(
                f"KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl get node {name} -o jsonpath='{{.status.addresses[?(@.type==\"InternalIP\")].address}}'"
            )
            assert ip in out, f"{name} InternalIP {out.strip()!r} is not the mesh address {ip}"

        # --- Cilium healthy (cluster-wide check covers the agent) --------
        alpha.wait_until_succeeds(
            "KUBECONFIG=/etc/rancher/rke2/rke2.yaml cilium status", timeout=180
        )
        alpha.wait_until_succeeds(
            "KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl wait -n kube-system --for=condition=Ready pod -l k8s-app=cilium --timeout=120s",
            timeout=180,
        )
    except Exception:
        fail_dump(alpha)
        fail_dump(beta)
        raise
  '';
}
