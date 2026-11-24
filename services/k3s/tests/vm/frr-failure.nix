# k3s-frr-failure (SPEC.md D72): FRR is on every node, and there is no
# second data plane to fall back on. This suite is the answer D72 gives
# for that cost: the k3s-join cluster (alpha a spine and the server, beta
# a leaf and the agent; Cilium native routing over routed-fabric) runs
# its join script unchanged, then two failures on the spine:
#
#   - bgpd crashes (SIGKILL). watchfrr starts it again; every BGP
#     session, the leaf's routes to the spine's pods and the pod network
#     in both families come back without anyone acting.
#   - a deploy carries a broken FRR config (a specialisation whose
#     frr.conf has a line FRR rejects). The reload refuses it; FRR keeps
#     the running config, bgpd and every session; pods still reach each
#     other. Switching back reloads cleanly. The switch itself exits 0:
#     the refusal shows only in the journal (an upstream fact, D72).
{
  lib,
  inputs,
  ...
}: let
  body = import ../../../../lib/kube-cluster/tests/vm/join.nix {
    inherit lib inputs;
    distro = "k3s";
  };
  kubeconfig = "/etc/rancher/k3s/k3s.yaml";
  busyboxImage = pkgs:
    pkgs.dockerTools.pullImage {
      imageName = "busybox";
      imageDigest = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662";
      hash = "sha256-OasmfjRQsuVWudSc4qWuMKK5nNz4hdIS8Si4B0okXEw=";
      finalImageTag = "1.36.1";
    };
  # Not an FRR command: `vtysh -C` and frr-reload refuse the file.
  badLine = "this-is-not-an-frr-command";
  marker = ''print("K3S_JOIN_OK")'';
  phases = ''
    KUBECTL = "KUBECONFIG=${kubeconfig} kubectl"
    nodes = [alpha, beta]
    # every BGP session of the node, with Cilium's to the local FRR
    PEERS = "vtysh -c 'show bgp summary json' | jq -c '[.[] | (.peers // {}) | to_entries[] | [.key, .value.state]] | sort'"
    BGPD_PID = "pgrep -x bgpd"

    def peers(node):
        return json.loads(node.succeed(PEERS))

    def all_established(node, expected):
        """Every session of `expected` (peer names) is Established again."""
        node.wait_until_succeeds(
            PEERS + " | jq -e --argjson want '" + json.dumps(sorted(expected)) + "' '[.[] | select(.[1] == \"Established\") | .[0]] | sort == $want' >/dev/null",
            timeout=300,
        )

    def pod_ips(name):
        ips = alpha.succeed(f"{KUBECTL} get pod probe-{name} -o jsonpath='{{.status.podIPs[*].ip}}'").split()
        v4 = [ip for ip in ips if ":" not in ip]
        v6 = [ip for ip in ips if ":" in ip]
        assert len(v4) == 1 and len(v6) == 1, f"probe-{name} is not dual-stack: {ips}"
        return v4[0], v6[0]

    def pods_reach_each_other(timeout):
        for source, target in [("alpha", "beta"), ("beta", "alpha")]:
            ipv4, ipv6 = pod_ips(target)
            alpha.wait_until_succeeds(f"{KUBECTL} exec probe-{source} -- ping -c 2 -W 2 {ipv4}", timeout=timeout)
            alpha.wait_until_succeeds(f"{KUBECTL} exec probe-{source} -- ping -6 -c 2 -W 2 {ipv6}", timeout=timeout)

    def leaf_has_spine_pod_routes(timeout):
        """beta's kernel has a BGP route to alpha's pod block (Cilium
        advertises a /24 and a /64 per node), both families."""
        ipv4, ipv6 = pod_ips("alpha")
        net4 = ipaddress.ip_network(f"{ipv4}/24", strict=False)
        net6 = ipaddress.ip_network(f"{ipv6}/64", strict=False)
        beta.wait_until_succeeds(f"ip -4 route show proto bgp {net4} | grep . >/dev/null", timeout=timeout)
        beta.wait_until_succeeds(f"ip -6 route show proto bgp {net6} | grep . >/dev/null", timeout=timeout)

    with state_dump_on_failure(nodes, extra=["vtysh -c 'show bgp summary'", "ip route show proto bgp", "ip -6 route show proto bgp", "journalctl -u frr --no-pager -l | tail -n 60"]):
        with subtest("versions"):
            for node in nodes:
                print_versions(node, ["kernel", "frr", "k3s"])

        with subtest("probe pods on both nodes reach each other over the fabric"):
            for node in nodes:
                alpha.succeed(
                    f"{KUBECTL} run probe-{node.name} --image=busybox:1.36.1 --restart=Always "
                    f"--overrides='{{\"spec\":{{\"nodeName\":\"{node.name}\"}}}}' -- sleep infinity"
                )
            alpha.wait_until_succeeds(f"{KUBECTL} wait --for=condition=Ready pod/probe-alpha pod/probe-beta --timeout=120s", timeout=300)
            pods_reach_each_other(120)
            leaf_has_spine_pod_routes(120)
            sessions = {node.name: [peer for peer, _ in peers(node)] for node in nodes}
            for node in nodes:
                assert len(sessions[node.name]) >= 2, f"{node.name}: fewer BGP sessions than the fabric and Cilium: {sessions[node.name]}"
                all_established(node, sessions[node.name])
            print(f"FINDING BGP sessions: {sessions}")

        with subtest("bgpd crashes on the spine: watchfrr restarts it, sessions, routes and pods come back"):
            old_pid = alpha.succeed(BGPD_PID).strip()
            alpha.succeed("pkill -KILL -x bgpd")
            alpha.wait_until_succeeds(f"test -n \"$({BGPD_PID})\" && test \"$({BGPD_PID})\" != {old_pid}", timeout=120)
            alpha.succeed("systemctl is-active frr.service")
            for node in nodes:
                all_established(node, sessions[node.name])
            leaf_has_spine_pod_routes(300)
            pods_reach_each_other(300)
            observe("alpha: frr after the crash", alpha, "journalctl -u frr --no-pager -l | grep -i -E 'bgpd|restart' | tail -n 20")
            print("FRR_BGPD_CRASH_OK")

        with subtest("a broken FRR config is refused at reload (the switch still exits 0); the running FRR, its sessions and the pods stay"):
            pid = alpha.succeed(BGPD_PID).strip()
            running = alpha.succeed("vtysh -c 'show running-config'")
            assert "${badLine}" not in running
            bad = "/run/current-system/specialisation/bad-frr"
            alpha.succeed(f"grep -F '${badLine}' {bad}/etc/frr/frr.conf >/dev/null")
            since = alpha.succeed("date +%s").strip()
            # Upstream fact: frrinit.sh reload exits 0 when vtysh refuses
            # the file, so systemd logs "Reloaded" and the switch succeeds.
            # The refusal shows only in the journal. If the switch starts
            # failing, upstream changed: update SPEC.md D72 and this phase.
            code, out = alpha.execute(f"{bad}/bin/switch-to-configuration test 2>&1")
            print(f"FINDING switch to the broken FRR config: rc={code}\n{out}")
            assert code == 0, f"the switch to a broken FRR config failed (rc={code}): upstream changed"
            alpha.succeed(
                f"journalctl -u frr --no-pager --since @{since} | grep -F 'vtysh failed to process new configuration' >/dev/null"
            )
            alpha.succeed(f"journalctl -u frr --no-pager --since @{since} | grep -F '${badLine}' >/dev/null")
            alpha.succeed("grep -F '${badLine}' /etc/frr/frr.conf >/dev/null")
            alpha.succeed("systemctl is-active frr.service")
            assert alpha.succeed(BGPD_PID).strip() == pid, "bgpd restarted on a refused reload"
            assert "${badLine}" not in alpha.succeed("vtysh -c 'show running-config'"), "the broken line reached the running config"
            for node in nodes:
                all_established(node, sessions[node.name])
            pods_reach_each_other(60)

            # back to the booted config: the reload has nothing to change
            alpha.succeed("/run/booted-system/bin/switch-to-configuration test")
            alpha.fail("grep -F '${badLine}' /etc/frr/frr.conf")
            diff = alpha.succeed("/etc/frr-reload.py --bindir /run/current-system/sw/bin --test /etc/frr/frr.conf 2>&1")
            assert "Lines To Delete" not in diff and "Lines To Add" not in diff, diff
            assert alpha.succeed(BGPD_PID).strip() == pid, "bgpd restarted on the switch back"
            for node in nodes:
                all_established(node, sessions[node.name])
            pods_reach_each_other(60)
            print("FRR_BAD_RELOAD_OK")
  '';
in
  lib.recursiveUpdate body {
    name = "k3s-frr-failure";

    nodes = {
      alpha = {pkgs, ...}: {
        imports = [body.nodes.alpha];
        environment = {
          systemPackages = [pkgs.jq];
          etc."frr-reload.py".source = "${pkgs.frr}/libexec/frr/frr-reload.py";
        };
        services.k3s.images = [(busyboxImage pkgs)];
        specialisation.bad-frr.configuration.services.frr.config = lib.mkAfter ''
          ${badLine}
        '';
      };
      beta = {pkgs, ...}: {
        imports = [body.nodes.beta];
        environment.systemPackages = [pkgs.jq];
        services.k3s.images = [(busyboxImage pkgs)];
      };
    };

    # The phases run where the join suite prints its marker; the marker
    # moves after them. Fail the evaluation when the marker is gone: a
    # miss would drop the phases and leave the suite green.
    testScript = assert lib.hasInfix marker body.testScript;
      "import ipaddress\nimport json\n\n"
      + import ../../../../tests/suite-lib.nix
      + "\n"
      + builtins.replaceStrings [marker] [
        (lib.concatStringsSep "\n    " (lib.splitString "\n" phases) + ''print("K3S_FRR_FAILURE_OK")'')
      ]
      body.testScript;
  }
