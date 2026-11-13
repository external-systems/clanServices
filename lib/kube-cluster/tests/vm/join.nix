# <distro>-join: one server + one agent over the wireguard-mesh transport.
# The agent joins through its LOCAL haproxy: the kubeapi FQDN resolves to
# the agent's own mesh address (/etc/hosts), where its haproxy frontend
# balances to the server:
# - k3s: kubeapi frontend (7443 = 7442 + cilium.id 1) to the server's
#   kube-apiserver (6443) with TLS /readyz healthchecks;
# - rke2: supervisor frontend (8443 = 7442 + cilium.id 1 + 1000) to the
#   server's real supervisor (9345) with TLS /readyz healthchecks.
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
  agentUnit =
    if k3s
    then "k3s"
    else "rke2-agent";
  # The LB port the agent joins on: k3s joins on the kubeapi frontend,
  # rke2 on the supervisor frontend.
  joinPort =
    if k3s
    then "7443"
    else "8443";
  kubeconfig = "/etc/rancher/${distro}/${distro}.yaml";
in {
  name = "${distro}-join";

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules.wireguard-mesh = lib.modules.importApply ../../../../services/wireguard-mesh/default.nix {
      ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
    };
    exportInterfaces.node_transport = ../../../node-transport-interface.nix;

    inventory = {
      meta.domain = "test.clan";

      machines = {
        alpha = {};
        beta = {};
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
            };
            machines.alpha.settings.clusterInit = true;
          };

          roles.agent = {
            settings = {
              network.fabric = {
                service = "wireguard-mesh";
                instance = "mesh";
              };
              cilium.id = 1;
            };
            machines.beta = {};
          };
        };
      };
    };
  };

  nodes = let
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

      environment.systemPackages = [
        pkgs.kubectl
        pkgs.cilium-cli
        pkgs.socat
      ];
    };
  in {
    alpha = commonNode "alpha";
    beta = commonNode "beta";
  };

  testScript = ''
    def fail_dump(m):
        for cmd in [
            "ip -br addr >&2",
            "journalctl -u ${serverUnit} --no-pager -l | tail -n 80 >&2",
            "journalctl -u ${agentUnit} --no-pager -l | tail -n 80 >&2",
            "journalctl -u haproxy --no-pager -l | tail -n 40 >&2",
            "ss -tlnp | grep -E '${
      if k3s
      then "6443|7443|8404"
      else "7443|8443|8404|6443|9345"
    }' >&2 || true",
            "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock >&2 || true",
        ]:
            m.execute(cmd)

    try:
        start_all()

        with subtest("ifstate and haproxy up on both nodes"):
            for m in [alpha, beta]:
                m.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
                m.wait_for_unit("haproxy.service", timeout=240)

        # --- Transport (§6.3): full mesh, dual-stack ----------------------
        # Every node holds both mesh families on wg-mesh, and every remote
        # node InternalIP is reachable over the mesh in both families.
        with subtest("dual-stack full mesh over wg-mesh"):
            mesh_addrs = {
                "alpha": ("192.168.77.1", "fd00:77::1"),
                "beta": ("192.168.77.2", "fd00:77::2"),
            }
            for m in [alpha, beta]:
                ipv4, ipv6 = mesh_addrs[m.name]
                m.succeed(f"ip -br addr show wg-mesh | grep '{ipv4}/32' >/dev/null")
                m.succeed(f"ip -br addr show wg-mesh | grep '{ipv6}/128' >/dev/null")
            for source in [alpha, beta]:
                for target in [alpha, beta]:
                    if source.name == target.name:
                        continue
                    ipv4, ipv6 = mesh_addrs[target.name]
                    source.wait_until_succeeds(f"ping -c2 -W2 {ipv4}", timeout=120)
                    source.wait_until_succeeds(f"ping -6 -c2 -W2 {ipv6}", timeout=120)

        with subtest("server and agent runtimes up"):
            alpha.wait_for_unit("${serverUnit}.service", timeout=600)
            beta.wait_for_unit("${agentUnit}.service", timeout=600)

        # --- The agent joined through its OWN haproxy --------------------
        # kubeapi FQDN -> own mesh address (/etc/hosts), join URL on the
        ${
      if k3s
      then "# LB kubeapi port 7443 (the kube-apiserver owns 6443 itself)."
      else "# LB supervisor port 8443 (the supervisor owns 9345 itself)."
    }
        with subtest("agent joined through its own haproxy"):
            for m, ip in [(alpha, "192.168.77.1"), (beta, "192.168.77.2")]:
                m.succeed(f"grep -q '^{ip} kubeapi-${distro}.test.clan$' /etc/hosts")
                m.succeed("systemctl is-active haproxy")
                for port in [${
      if k3s
      then ''"7443", "8404"''
      else ''"7443", "8443", "8404"''
    }]:
                    m.succeed(f"ss -tln | grep ':{port}' >/dev/null")${lib.optionalString k3s "\n        alpha.succeed(\"ss -tln | grep ':6443' >/dev/null\")"}
            beta.succeed(
                "grep -q '\"server\":\"https://kubeapi-${distro}.test.clan:${joinPort}\"' /etc/rancher/${distro}/config.yaml"
            )
            alpha.succeed("! grep -q '\"server\"' /etc/rancher/${distro}/config.yaml")

            # The agent's haproxy kubeapi backend (alpha) is UP — the join and
            # the agent's Cilium API traffic ride the local LB.
            beta.wait_until_succeeds(
                "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep '^${distro}_api,alpha-4,' | grep ',UP,' >/dev/null",
                timeout=300,
            )

        # --- Both nodes Ready with mesh InternalIPs (dual-stack) ---------
        with subtest("both nodes Ready with dual-stack mesh InternalIPs"):
            alpha.wait_until_succeeds(
                "KUBECONFIG=${kubeconfig} kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s",
                timeout=240,
            )
            for name, ips in [("alpha", ("192.168.77.1", "fd00:77::1")), ("beta", ("192.168.77.2", "fd00:77::2"))]:
                out = alpha.succeed(
                    f"KUBECONFIG=${kubeconfig} kubectl get node {name} -o jsonpath='{{.status.addresses[?(@.type==\"InternalIP\")].address}}'"
                )
                for ip in ips:
                    assert ip in out, f"{name} InternalIP {out.strip()!r} is missing the mesh address {ip}"
                # Topology labels default to the instance name (invariant 7).
                alpha.succeed(
                    f"KUBECONFIG=${kubeconfig} kubectl get node {name} --show-labels | grep 'topology.kubernetes.io/region=${distro}' >/dev/null"
                )
                alpha.succeed(
                    f"KUBECONFIG=${kubeconfig} kubectl get node {name} --show-labels | grep 'topology.kubernetes.io/zone=${distro}' >/dev/null"
                )

        # --- Cilium healthy (cluster-wide check covers the agent) --------
        with subtest("Cilium healthy cluster-wide"):
            alpha.wait_until_succeeds(
                "KUBECONFIG=${kubeconfig} cilium status", timeout=180
            )
            alpha.wait_until_succeeds(
                "KUBECONFIG=${kubeconfig} kubectl wait -n kube-system --for=condition=Ready pod -l k8s-app=cilium --timeout=120s",
                timeout=180,
            )
        print("${lib.toUpper distro}_JOIN_OK")
    except Exception:
        fail_dump(alpha)
        fail_dump(beta)
        raise
  '';
}
