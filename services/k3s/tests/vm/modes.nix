# k3s-modes (specs/netif.md N4, use case U2): one machine with a
# NetworkManager `default` mode and an IfState `kubernetes` mode. The
# single-node cluster and its routed-fabric transport exist in the
# `kubernetes` mode only. The machine is booted default → kubernetes →
# default → kubernetes: the default mode has nothing of the cluster, and
# the cluster comes back with its state after a round trip.
#
# Cilium runs in native routing. alpha is a fabric leaf in its
# `kubernetes` mode only; its spine is `gw`, a second machine that is
# always on (a spine may not be limited to a mode). The spine must learn
# the leaf's pod routes over BGP and reach a pod in both families while
# the mode is booted, and lose the session and the routes when alpha
# boots its default mode.
{
  lib,
  inputs,
  ...
}: let
  marker = "K3S_MODES";
  kubeconfig = "/etc/rancher/k3s/k3s.yaml";
  endpointSources = [
    {
      service = "clan-core/internet";
      instance = "underlay";
    }
  ];
  # Python spliced into the test script, `prefix` before every line.
  indent = prefix: text: lib.concatMapStringsSep "\n" (line: lib.optionalString (line != "") (prefix + line)) (lib.splitString "\n" text);
in {
  name = "k3s-modes";

  clan = {
    directory = ./.;
    test.useContainers = false;
    modules.routed-fabric = lib.modules.importApply ../../../routed-fabric/default.nix {
      ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
    };
    exportInterfaces = {
      node_transport = ../../../../lib/node-transport-interface.nix;
      routed_fabric = ../../../routed-fabric/routed-fabric-interface.nix;
    };

    inventory = {
      meta.domain = "test.clan";

      machines = {
        alpha = {};
        gw = {};
      };

      instances = {
        modes = {
          module.name = "modes";
          module.input = "self";
          roles.default.machines.alpha.settings.modes = {
            default.manager = "networkmanager";
            kubernetes.manager = "ifstate";
          };
        };

        # the wired link is the machine's in every mode
        home = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.alpha.settings.links.lan = {
            interface = "eth1";
            static.ipv4 = ["192.168.1.1/24"];
            ra = false;
          };
        };

        underlay = {
          module.name = "internet";
          roles.default.machines = {
            alpha.settings.host = "192.168.1.1";
            gw.settings.host = "192.168.1.2";
          };
        };

        mesh = {
          module.name = "routed-fabric";
          module.input = "self";
          roles = {
            # one LAN: the fast timers (the default between sites is `wan`)
            spine.settings.site = "lab";
            # D75 (A5): the pinned loopbacks lie in their pools
            spine.settings.loopback4Pool = "192.168.77.0/24";
            spine.settings.loopback6Pool = "fd00:77::/64";
            leaf.settings.loopback4Pool = "192.168.77.0/24";
            leaf.settings.loopback6Pool = "fd00:77::/64";
            leaf.settings.site = "lab";
            # a spine is in every mode of its machine (N4)
            spine.machines.gw.settings = {
              ipv4 = "192.168.77.2";
              ipv6 = "fd00:77::2";
              inherit endpointSources;
            };
            leaf.machines.alpha.settings = {
              modes = ["kubernetes"];
              ipv4 = "192.168.77.1";
              ipv6 = "fd00:77::1";
              inherit endpointSources;
            };
          };
        };

        k3s = {
          module.name = "k3s";
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
            machines.alpha.settings = {
              clusterInit = true;
              modes = ["kubernetes"];
            };
          };
        };
      };
    };
  };

  nodes = {
    alpha = {
      config,
      pkgs,
      ...
    }: let
      busyboxImage = pkgs.dockerTools.pullImage {
        imageName = "busybox";
        imageDigest = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662";
        hash = "sha256-OasmfjRQsuVWudSc4qWuMKK5nNz4hdIS8Si4B0okXEw=";
        finalImageTag = "1.36.1";
      };
    in {
      virtualisation = {
        cores = 2;
        memorySize = 4096;
        diskSize = 8192;
      };
      environment = {
        systemPackages = [
          pkgs.kubectl
          pkgs.cilium-cli
          pkgs.jq
        ];
        sessionVariables.KUBECONFIG = kubeconfig;
        etc."netif-mode".text = config.clanServices.networking.mode.name;
      };
      # the test's own management NIC is nobody's link
      networking.networkmanager.unmanaged = ["interface-name:eth0"];
      services.k3s.images = [busyboxImage];
    };

    # the spine: always on, never in a mode
    gw = {pkgs, ...}: {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
          addresses = ["192.168.1.2/24"];
        })
      ];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
      };
      environment.systemPackages = [pkgs.jq];
    };
  };

  testScript = {nodes, ...}: let
    kubernetes = "${nodes.alpha.system.build.toplevel}/specialisation/kubernetes";
    leaf = nodes.alpha.clan.networkFacts.fabric.mesh;
    spine = nodes.gw.clan.networkFacts.fabric.mesh;
    # the link that holds the node address
    nodeLink = leaf.loopback;
    established = "vtysh -c 'show bgp neighbors' | grep 'BGP state = Established' >/dev/null";
  in ''
    import os

    ${import ../../../../tests/ifstate-noop.nix}${indent "" ''
      import json
      import time

      ${import ../../../../tests/suite-lib.nix}

      def spine_pod_routes():
          """The BGP routes in the spine's kernel table that lie inside the
          cluster's pod CIDRs (cilium.id 1: 10.1.0.0/16, fd10:1::/56):
          (IPv4 routes, IPv6 routes)."""
          found = []
          for family, prefix in [("-4", "10.1."), ("-6", "fd10:1:")]:
              routes = json.loads(gw.succeed(f"ip -j {family} route show proto bgp"))
              found.append([route["dst"] for route in routes if route["dst"].startswith(prefix)])
          return found

      def spine_has_pod_routes(limit=240):
          started = time.time()
          while True:
              ipv4, ipv6 = spine_pod_routes()
              if ipv4 and ipv6:
                  return ipv4, ipv6
              assert time.time() - started < limit, f"the spine has no pod route in both families after {limit}s: {ipv4} {ipv6}"
              time.sleep(2)

      def spine_reaches_probe():
          """Native routing: the spine reaches a pod on the leaf, no tunnel, no NAT."""
          ips = alpha.succeed("kubectl get pod -n modes probe -o jsonpath='{.status.podIPs[*].ip}'").split()
          assert len(ips) == 2, f"the probe pod is not dual-stack: {ips}"
          for ip in ips:
              gw.wait_until_succeeds(f"ping -c 2 -W 2 {ip}", timeout=120)
    ''}

    def boot(mode_init):
        """Boot the machine into one mode, as the boot menu does."""
        alpha.shutdown()
        if mode_init:
            os.environ["QEMU_KERNEL_PARAMS"] = f"init={mode_init}"
        else:
            os.environ.pop("QEMU_KERNEL_PARAMS", None)
        alpha.start()
        alpha.wait_for_unit("multi-user.target", timeout=300)

    def default_mode():
        assert alpha.succeed("cat /etc/netif-mode").strip() == "default"
        alpha.succeed("systemctl is-active NetworkManager.service")
        alpha.wait_until_succeeds("ip -4 -o addr show dev eth1 | grep -F '192.168.1.1/24' >/dev/null", timeout=120)
        # nothing of the cluster or its transport: no unit, no link, no forwarding, no firewall rule
        for unit in ["k3s", "haproxy", "ifstate", "k3s-k3s-bootstrap-apply", "k3s-k3s-pki-seed", "frr"]:
            alpha.fail(f"systemctl cat {unit}.service")
        links = alpha.succeed("ip -o link show").strip()
        for name in ["${nodeLink}", "cilium_host", "cilium_net", "lxc"]:
            assert name not in links, f"{name} exists in the default mode:\n{links}"
        alpha.fail("test -e /etc/rancher/k3s/config.yaml")
        alpha.fail("mountpoint -q /sys/fs/bpf && grep -q cilium /proc/mounts")
        alpha.fail("nft list ruleset | grep -F 'cilium' >/dev/null")
        assert alpha.succeed("sysctl -n net.ipv4.ip_forward").strip() == "0"
    ${indent "    " ''
      # no fabric tunnel and no fabric address on the leaf (N4)
      assert alpha.succeed("ip -o link show type wireguard").strip() == "", "a fabric tunnel in the default mode"
      alpha.fail("ip -o addr | grep -F '${leaf.ipv4}' >/dev/null")
      # the spine keeps its side; the leaf and its pods are simply away
      gw.wait_until_fails("${established}", timeout=120)
      gw.fail("ping -c 1 -W 2 ${leaf.ipv4}")
      started = time.time()
      while spine_pod_routes() != [[], []]:
          assert time.time() - started < 120, f"the spine keeps pod routes of a leaf that is away: {spine_pod_routes()}"
          time.sleep(2)
    ''}
    def kubernetes_mode():
        assert alpha.succeed("cat /etc/netif-mode").strip() == "kubernetes"
        alpha.fail("systemctl cat NetworkManager.service")
        alpha.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
        alpha.succeed("ip -br addr show ${nodeLink} | grep '192.168.77.1/32' >/dev/null")
        alpha.wait_for_unit("haproxy.service", timeout=240)
        alpha.wait_for_unit("k3s.service", timeout=600)
        alpha.wait_until_succeeds(
            "systemctl show -p Result --value k3s-k3s-bootstrap-apply | grep '^success$' >/dev/null",
            timeout=900,
        )
        alpha.wait_until_succeeds("kubectl wait --for=condition=Ready node/alpha --timeout=120s", timeout=300)
        alpha.wait_until_succeeds("KUBECONFIG=${kubeconfig} cilium status --wait --wait-duration 10s", timeout=300)
    ${indent "    " ''
      # the leaf is on the fabric: FRR, both sessions to the spine, node addresses both ways
      mode = alpha.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.routing-mode}'").strip()
      assert mode == "native", f"Cilium routing-mode is {mode!r}"
      alpha.wait_for_unit("frr.service", timeout=180)
      gw.wait_until_succeeds(
          "vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^2$' >/dev/null",
          timeout=240,
      )
      # every session of the leaf: the spine's two and Cilium's
      alpha.wait_until_succeeds(
          "vtysh -c 'show bgp summary json' | jq -e '[.. | objects | select(has(\"state\")) | .state] | length > 2 and all(. == \"Established\")' >/dev/null",
          timeout=240,
      )
      alpha.wait_until_succeeds("ping -c 2 -W 2 ${spine.ipv4}", timeout=120)
      alpha.wait_until_succeeds("ping -6 -c 2 -W 2 ${spine.ipv6}", timeout=120)
      gw.wait_until_succeeds("ping -c 2 -W 2 ${leaf.ipv4}", timeout=120)
      gw.wait_until_succeeds("ping -6 -c 2 -W 2 ${leaf.ipv6}", timeout=120)
      # native routing: the spine learns where the leaf's pods are
      print("FINDING the spine's pod routes:", spine_has_pod_routes())
    ''}
    try:
    ${indent "    " ''
      gw.start()
      gw.wait_for_unit("frr.service", timeout=180)
    ''}    alpha.start()
        alpha.wait_for_unit("multi-user.target", timeout=300)

        with subtest("the default mode has nothing of the cluster (N4)"):
            default_mode()
            print("${marker}_DEFAULT_OK")

        with subtest("rebooted into the kubernetes mode: the cluster bootstraps"):
            boot("${kubernetes}/init")
            kubernetes_mode()
            alpha.succeed("kubectl create namespace modes")
            alpha.succeed("kubectl create configmap -n modes survives --from-literal=boot=first")
            alpha.succeed("kubectl run -n modes probe --image=busybox:1.36.1 --restart=Always -- sleep infinity")
            alpha.wait_until_succeeds("kubectl wait -n modes --for=condition=Ready pod/probe --timeout=120s", timeout=240)
            uid = alpha.succeed("kubectl get node alpha -o jsonpath='{.metadata.uid}'").strip()
            # a network reapply under the running node changes nothing
            alpha.succeed("netif-preview | grep 'would change nothing' >/dev/null")
            assert_ifstate_noop(alpha)
            alpha.succeed("kubectl exec -n modes probe -- nc -z -w 3 10.2.0.1 443")
    ${indent "        " ''
      spine_reaches_probe()
      # the reapply restarted no session of the spine
      gw.succeed("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^2$' >/dev/null")
    ''}        print("${marker}_CLUSTER_OK")

        with subtest("back in the default mode: the cluster is gone from the system, its state stays on disk"):
            boot(None)
            default_mode()
            alpha.succeed("test -d /var/lib/rancher/k3s/server/db")
            print("${marker}_BACK_OK")

        with subtest("the kubernetes mode again: the same cluster, with its objects"):
            boot("${kubernetes}/init")
            kubernetes_mode()
            assert alpha.succeed("kubectl get node alpha -o jsonpath='{.metadata.uid}'").strip() == uid
            assert alpha.succeed("kubectl get configmap -n modes survives -o jsonpath='{.data.boot}'").strip() == "first"
            alpha.wait_until_succeeds("kubectl wait -n modes --for=condition=Ready pod/probe --timeout=120s", timeout=300)
            alpha.wait_until_succeeds("kubectl exec -n modes probe -- nc -z -w 3 10.2.0.1 443", timeout=120)
    ${indent "        " ''
      spine_reaches_probe()
    ''}        print("${marker}_RETURN_OK")

        print("${marker}_OK")
    except Exception:
        for command in [
            "cat /etc/netif-mode >&2; ip -br link >&2; ip -br addr >&2; ip route >&2",
            "systemctl --failed --no-pager >&2",
            "journalctl -u k3s --no-pager -l | tail -n 80 >&2",
            "journalctl -u k3s-k3s-bootstrap-apply --no-pager -l | tail -n 60 >&2 || true",
            "journalctl -u haproxy --no-pager -l | tail -n 40 >&2",
            "kubectl get nodes,pods -A -o wide >&2 || true",
            "kubectl get events -A --sort-by=.lastTimestamp | tail -n 80 >&2 || true",
            "cilium status >&2 || true",
            "ifstatecli --config /etc/ifstate/ifstate.yaml check >&2 || true",
        ]:
            alpha.execute(command)
    ${indent "    " ''
      for command in [
          "ip -br addr >&2; ip route >&2; ip -6 route >&2; wg show >&2",
          "vtysh -c 'show bgp summary' >&2; vtysh -c 'show bfd peers brief' >&2",
          "journalctl -u frr --no-pager -l | tail -n 60 >&2",
      ]:
          gw.execute(command)
      alpha.execute("wg show >&2; vtysh -c 'show bgp summary' >&2 || true")
    ''}    raise
  '';
}
