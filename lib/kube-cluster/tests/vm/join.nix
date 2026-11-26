# <distro>-join: one server + one agent on the routed fabric (routed-fabric,
# FRR, per-pair WireGuard, Cilium native routing): the server is a spine,
# the agent a leaf.
# The agent joins through its LOCAL haproxy: the kubeapi FQDN resolves to
# the agent's own node address (/etc/hosts), where its haproxy frontend
# balances to the server:
# - k3s: kubeapi frontend (7443 = 7442 + cilium.id 1) to the server's
#   kube-apiserver (6443) with TLS /readyz healthchecks;
# - rke2: supervisor frontend (8443 = 7442 + cilium.id 1 + 1000) to the
#   server's real supervisor (9345) with TLS /readyz healthchecks.
# Shared by the k3s and rke2 suites; every distro difference is a `k3s`
# branch below.
#
# <distro>-join-netif (`underlay = "netif"`): the same cluster with the
# nodes' underlay declared through the netif service instead of the bare
# IfState fixture (specs/netif.md N14: netif proven under Cilium
# Kubernetes, here with native routing over the routed fabric).
# Everything the join suite asserts must hold unchanged, on links netif
# does not firewall-trust. Its extra phases pin: the fabric derives its
# adjacency MTU from the netif link (N17); pods reach each other across
# nodes in both families over the adjacency; `ifstatecli check` proposes
# nothing and a reapply changes nothing; the ownership registry keeps
# Cilium's links and the CNI's namespaces, and IfState keeps the fabric
# links, through an apply (N6); the agent comes back after a reboot.
{
  lib,
  inputs,
  distro,
  # "fixture": tests/ifstate-vm.nix. "netif": the netif service.
  underlay ? "fixture",
}: let
  k3s = distro == "k3s";
  netifUnderlay = underlay == "netif";
  suiteName = "${distro}-join" + lib.optionalString netifUnderlay "-netif";
  nodeAddress = {
    alpha = "192.168.1.1/24";
    beta = "192.168.1.2/24";
  };
  # The netif link's declared path MTU, and what the fabric derives from
  # it (routed-fabric adjacency MTU: path MTU minus 96; 1420 without netif).
  pathMtu = 1500;
  adjacencyMtu = pathMtu - 96;
  # The fabric loopback that holds the node addresses.
  loopback = "rflo${builtins.substring 0 10 (builtins.hashString "sha256" "mesh")}";
  endpointSources = [
    {
      service = "clan-core/internet";
      instance = "underlay";
    }
  ];
  # Python for the netif variant only. Both are empty for the fixture
  # variant, whose test script must stay exactly as it was.
  indent = prefix: text: lib.concatMapStringsSep "\n" (line: lib.optionalString (line != "") (prefix + line)) (lib.splitString "\n" text);
  netifHelpers = lib.optionalString netifUnderlay (
    "import json\n\n" + import ../../../../tests/suite-lib.nix + "\n" + import ../../../../tests/ifstate-noop.nix + "\n"
  );
  # more phases inside the script's `try:` block
  netifPhase = lib.optionalString netifUnderlay (
    indent "    " ''
      KUBECTL = "KUBECONFIG=${kubeconfig} kubectl"
      nodes = [alpha, beta]
      mesh4 = {"alpha": "192.168.77.1", "beta": "192.168.77.2"}
      mesh6 = {"alpha": "fd00:77::1", "beta": "fd00:77::2"}
      # each node's one fabric adjacency (alpha is the spine, beta the leaf)
      adjacency = {node.name: node.succeed("wg show interfaces").strip() for node in nodes}
      for name, link in adjacency.items():
          assert link and " " not in link, f"{name}: expected one fabric adjacency, got {link!r}"

      def pod_ips(node_name):
          """The probe pod's addresses on one node: (IPv4, IPv6)."""
          ips = alpha.succeed(
              f"{KUBECTL} get pod netif-{node_name} -o jsonpath='{{.status.podIPs[*].ip}}'"
          ).split()
          v4 = [ip for ip in ips if ":" not in ip]
          v6 = [ip for ip in ips if ":" in ip]
          assert len(v4) == 1 and len(v6) == 1, f"netif-{node_name} is not dual-stack: {ips}"
          return v4[0], v6[0]

      def pods_reach_each_other(timeout):
          """Each probe pod pings the one on the other node, both families."""
          for source, target in [("alpha", "beta"), ("beta", "alpha")]:
              ipv4, ipv6 = pod_ips(target)
              alpha.wait_until_succeeds(f"{KUBECTL} exec netif-{source} -- ping -c 2 -W 2 {ipv4}", timeout=timeout)
              alpha.wait_until_succeeds(f"{KUBECTL} exec netif-{source} -- ping -6 -c 2 -W 2 {ipv6}", timeout=timeout)

      def foreign_objects(node):
          """What IfState must leave alone: the fabric links it declares, and
          Cilium's links and the CNI's namespaces, which the registry owns."""
          links = {
              link["ifname"]: link["ifindex"]
              for link in json.loads(node.succeed("ip -j link show"))
              if link["ifname"] in (adjacency[node.name], "${loopback}") or link["ifname"].startswith(("cilium_", "lxc"))
          }
          netns = sorted(
              line.split()[0] for line in node.succeed("ip netns list").splitlines() if line.startswith("cni-")
          )
          return links, netns

      def netif_changes_nothing(node):
          code, preview = node.execute("netif-preview")
          print(preview)
          if code != 0:
              print(node.succeed("ifstatecli --config /etc/ifstate/ifstate.yaml check 2>&1"))
          assert code == 0, f"{node.name}: IfState would change a live cluster node:\n{preview}"
          node.succeed("systemctl start netif-drift.service")
          assert_ifstate_noop(node)

      with state_dump_on_failure(nodes, extra=["wg show all", "vtysh -c 'show bgp summary'", "ifstatecli --config /etc/ifstate/ifstate.yaml check"]):
          with subtest("versions"):
              for node in nodes:
                  print_versions(node, ["kernel", "ifstate", "wireguard", "frr", "nftables", "${distro}"])
              observe("cilium version", alpha, "KUBECONFIG=${kubeconfig} cilium version")

          with subtest("netif renders the underlay; the fabric derives its adjacency MTU from the netif link (N14, N17)"):
              for node in nodes:
                  status = json.loads(node.succeed("netif-status --json"))
                  uplink = [l for l in status["links"] if l["interface"] == "eth1"]
                  assert len(uplink) == 1 and uplink[0]["state"] == "UP" and not uplink[0]["trusted"], status
                  address = ${builtins.toJSON nodeAddress}[node.name]
                  node.succeed(f"ip -4 -o addr show dev eth1 | grep -F '{address}' >/dev/null")
                  node.succeed("systemctl is-active netif-guard.service")
                  mtu = int(node.succeed(f"cat /sys/class/net/{adjacency[node.name]}/mtu"))
                  assert mtu == ${toString adjacencyMtu}, f"{node.name}: {adjacency[node.name]} MTU {mtu}, expected ${toString pathMtu} - 96"
              print("NETIF_UNDERLAY_OK")

          with subtest("pods reach each other across nodes in both families, natively routed over the fabric adjacency"):
              mode = alpha.succeed(f"{KUBECTL} get configmap -n kube-system cilium-config -o jsonpath='{{.data.routing-mode}}'").strip()
              assert mode == "native", f"Cilium routing-mode is {mode!r}"
              for node in nodes:
                  node.fail("ip link show cilium_vxlan")
                  alpha.succeed(
                      f"{KUBECTL} run netif-{node.name} --image=busybox:1.36.1 --restart=Always "
                      f"--overrides='{{\"spec\":{{\"nodeName\":\"{node.name}\"}}}}' -- sleep infinity"
                  )
              alpha.wait_until_succeeds(
                  f"{KUBECTL} wait --for=condition=Ready pod/netif-alpha pod/netif-beta --timeout=120s", timeout=300
              )
              # pod packets leave on the fabric adjacency, not on the underlay
              tx = "cat /sys/class/net/{}/statistics/tx_packets"
              before = {node.name: int(node.succeed(tx.format(adjacency[node.name]))) for node in nodes}
              pods_reach_each_other(120)
              for node in nodes:
                  sent = int(node.succeed(tx.format(adjacency[node.name]))) - before[node.name]
                  assert sent >= 4, f"{node.name}: only {sent} packets left on {adjacency[node.name]} during the pod pings"
              print("NETIF_POD_NETWORK_OK")

          with subtest("under a live cluster a reapply changes nothing and keeps Cilium's and the fabric's objects (N6, N14)"):
              # The cluster must be done starting first: the ClusterMesh
              # apiserver's VIP is announced when its rollout ends, at the
              # end of alpha's boot, and a route that arrives during the
              # comparison is not the apply's doing.
              for node in nodes:
                  node.wait_for_unit("multi-user.target")
              for node in nodes:
                  node.wait_until_succeeds(
                      "a=$(ip -4 route show table all; ip -6 route show table all | grep -v ' expires '); sleep 5; "
                      "b=$(ip -4 route show table all; ip -6 route show table all | grep -v ' expires '); "
                      'test "$a" = "$b"',
                      timeout=120,
                  )
              for node in nodes:
                  links, netns = foreign_objects(node)
                  for name in [adjacency[node.name], "${loopback}", "cilium_host", "cilium_net", "lxc_health"]:
                      assert name in links, f"{node.name}: no {name} before the apply: {links}"
                  assert [name for name in links if name.startswith("lxc") and name != "lxc_health"], f"{node.name}: no pod link: {links}"
                  assert netns, f"{node.name}: no cni- namespace before the apply"
                  handshakes = node.succeed(f"wg show {adjacency[node.name]} latest-handshakes").split()
                  netif_changes_nothing(node)
                  after_links, after_netns = foreign_objects(node)
                  # the same ifindex: no link was deleted and created again
                  assert after_links == links, f"{node.name}: the apply changed links: {links} -> {after_links}"
                  assert after_netns == netns, f"{node.name}: the apply changed namespaces: {netns} -> {after_netns}"
                  # the WireGuard session was not reset
                  after_handshakes = node.succeed(f"wg show {adjacency[node.name]} latest-handshakes").split()
                  assert int(after_handshakes[1]) >= int(handshakes[1]) > 0, (node.name, handshakes, after_handshakes)
              # the cluster did not notice
              alpha.succeed(f"{KUBECTL} get nodes --no-headers | grep -c ' Ready ' | grep -x 2 >/dev/null")
              alpha.succeed(f"{KUBECTL} wait -n kube-system --for=condition=Ready pod -l k8s-app=cilium --timeout=60s")
              pods_reach_each_other(60)
              print("NETIF_UNDER_KUBERNETES_OK")

          with subtest("the agent reboots: netif, the fabric and the pod network come back"):
              boot_id = alpha.succeed(f"{KUBECTL} get node beta -o jsonpath='{{.status.nodeInfo.bootID}}'").strip()
              beta.shutdown()
              beta.start()
              # `Result` reads "success" before the unit ran: wait for what it renders
              beta.wait_until_succeeds("ip -4 -o addr show dev eth1 | grep -F '192.168.1.2/24' >/dev/null", timeout=300)
              beta.wait_until_succeeds(f"ip link show {adjacency['beta']} >/dev/null && test \"$(systemctl show -p ActiveState --value ifstate.service)\" != activating", timeout=120)
              beta.succeed("test $(systemctl show -p Result --value ifstate.service) = success")
              beta.succeed("ip -br addr show ${loopback} | grep '192.168.77.2/32' >/dev/null")
              beta.succeed("ip -br addr show ${loopback} | grep 'fd00:77::2/128' >/dev/null")
              alpha.wait_until_succeeds("ping -c 2 -W 2 192.168.77.2", timeout=120)
              alpha.wait_until_succeeds("ping -6 -c 2 -W 2 fd00:77::2", timeout=120)
              beta.wait_for_unit("${agentUnit}.service", timeout=600)
              # the node object is the new boot's, and Ready
              alpha.wait_until_succeeds(
                  f"test \"$({KUBECTL} get node beta -o jsonpath='{{.status.nodeInfo.bootID}}')\" != '{boot_id}' && "
                  f"{KUBECTL} wait --for=condition=Ready node/beta --timeout=10s",
                  timeout=600,
              )
              alpha.wait_until_succeeds(
                  f"{KUBECTL} get pod netif-beta -o jsonpath='{{.status.containerStatuses[0].restartCount}} {{.status.containerStatuses[0].ready}}'"
                  " | grep -E '^[1-9][0-9]* true$' >/dev/null",
                  timeout=600,
              )
              alpha.wait_until_succeeds(
                  f"{KUBECTL} wait -n kube-system --for=condition=Ready pod -l k8s-app=cilium --timeout=60s", timeout=300
              )
              pods_reach_each_other(300)
              netif_changes_nothing(beta)
              pods_reach_each_other(60)
              print("NETIF_REBOOT_OK")
    ''
  );
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
  name = suiteName;

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
      };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = {
            # IP literals: a hostname endpoint is an eval error
            # (routed-fabric R4)
            alpha.settings.host = "192.168.1.1";
            beta.settings.host = "192.168.1.2";
          };
        };

        mesh = {
          module.name = "routed-fabric";
          module.input = "self";
          roles = {
            # one LAN: the fast timers (the default between sites is `wan`)
            spine.settings.site = "lab";
            leaf.settings.site = "lab";
            spine.machines.alpha.settings = {
              ipv4 = "192.168.77.1";
              ipv6 = "fd00:77::1";
              inherit endpointSources;
            };
            leaf.machines.beta.settings = {
              ipv4 = "192.168.77.2";
              ipv6 = "fd00:77::2";
              inherit endpointSources;
            };
          };
        };

        # the netif variant: the link the fixture declares otherwise
        ${
          if netifUnderlay
          then "lan"
          else null
        } = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines =
            lib.mapAttrs (_: address: {
              settings.links.uplink = {
                interface = "eth1";
                static.ipv4 = [address];
                ra = false;
                inherit pathMtu;
              };
            })
            nodeAddress;
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
            machines.alpha.settings.clusterInit = true;
          };

          roles.agent = {
            settings = {
              network.fabric = {
                service = "routed-fabric";
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
    commonNode = name: {pkgs, ...}: let
      busyboxImage = pkgs.dockerTools.pullImage {
        imageName = "busybox";
        imageDigest = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662";
        hash = "sha256-OasmfjRQsuVWudSc4qWuMKK5nNz4hdIS8Si4B0okXEw=";
        finalImageTag = "1.36.1";
      };
    in {
      imports = lib.optional (!netifUnderlay) (
        import ../../../../tests/ifstate-vm.nix {
          ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
          addresses = [nodeAddress.${name}];
        }
      );

      # The netif variant runs probe pods (airgap: preload their image).
      # RKE2: a top-level symlink plus the service's .cache.json marker
      # makes the airgap importer see the image.
      services.${distro}.images = lib.mkIf netifUnderlay [busyboxImage];
      systemd.tmpfiles.rules = lib.mkIf (netifUnderlay && !k3s) [
        "L+ /var/lib/rancher/rke2/agent/images/${builtins.unsafeDiscardStringContext (baseNameOf busyboxImage)} - - - - ${busyboxImage}"
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
    ${netifHelpers}def fail_dump(m):
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

        # --- Transport (§6.3): the routed fabric, dual-stack -------------
        # Every node holds both families on its fabric loopback, and every
        # remote node InternalIP is reachable over the fabric in both families.
        with subtest("dual-stack node addresses over the routed fabric"):
            mesh_addrs = {
                "alpha": ("192.168.77.1", "fd00:77::1"),
                "beta": ("192.168.77.2", "fd00:77::2"),
            }
            for m in [alpha, beta]:
                ipv4, ipv6 = mesh_addrs[m.name]
                m.succeed(f"ip -br addr show ${loopback} | grep '{ipv4}/32' >/dev/null")
                m.succeed(f"ip -br addr show ${loopback} | grep '{ipv6}/128' >/dev/null")
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
        # kubeapi FQDN -> own node address (/etc/hosts), join URL on the
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

        # --- K1: the agent holds the agent token only -------------------
        # The server token joins the control plane; it and the ClusterMesh
        # keys stay off the agent (SPEC.md §6.9).
        with subtest("the agent holds no server token and no mesh keys"):
            alpha.succeed("find /run/secrets* -path '*rancher-server-token-${distro}*' -name server-token | grep . >/dev/null")
            beta.succeed("find /run/secrets* -path '*rancher-agent-token-${distro}*' -name agent-token | grep . >/dev/null")
            beta.fail("find /run/secrets* -path '*rancher-server-token*' | grep . >/dev/null")
            beta.fail("find /run/secrets* -path '*rancher-clustermesh*' | grep . >/dev/null")

        # --- Both nodes Ready with fabric InternalIPs (dual-stack) -------
        with subtest("both nodes Ready with dual-stack fabric InternalIPs"):
            alpha.wait_until_succeeds(
                "KUBECONFIG=${kubeconfig} kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s",
                timeout=240,
            )
            for name, ips in [("alpha", ("192.168.77.1", "fd00:77::1")), ("beta", ("192.168.77.2", "fd00:77::2"))]:
                out = alpha.succeed(
                    f"KUBECONFIG=${kubeconfig} kubectl get node {name} -o jsonpath='{{.status.addresses[?(@.type==\"InternalIP\")].address}}'"
                )
                for ip in ips:
                    assert ip in out, f"{name} InternalIP {out.strip()!r} is missing the node address {ip}"
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
    ${netifPhase}    print("${lib.toUpper distro}_JOIN${lib.optionalString netifUnderlay "_NETIF"}_OK")
    except Exception:
        fail_dump(alpha)
        fail_dump(beta)
        raise
  '';
}
