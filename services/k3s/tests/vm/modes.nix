# k3s-modes (specs/netif.md N4, use case U2): one machine with a
# NetworkManager `default` mode and an IfState `kubernetes` mode. The
# single-node cluster and its WireGuard transport exist in the
# `kubernetes` mode only. The machine is booted default → kubernetes →
# default → kubernetes: the default mode has nothing of the cluster, and
# the cluster comes back with its state after a round trip.
{
  lib,
  inputs,
  ...
}: let
  kubeconfig = "/etc/rancher/k3s/k3s.yaml";
in {
  name = "k3s-modes";

  clan = {
    directory = ./.;
    test.useContainers = false;
    modules.wireguard-mesh = lib.modules.importApply ../../../wireguard-mesh/default.nix {
      ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
    };
    exportInterfaces.node_transport = ../../../../lib/node-transport-interface.nix;

    inventory = {
      meta.domain = "test.clan";

      machines.alpha = {};

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
          roles.default.machines.alpha.settings.host = "192.168.1.1";
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
              modes = ["kubernetes"];
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

  nodes.alpha = {
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

  testScript = {nodes, ...}: let
    kubernetes = "${nodes.alpha.system.build.toplevel}/specialisation/kubernetes";
  in ''
    import os

    ${import ../../../../tests/ifstate-noop.nix}

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
        for unit in ["k3s", "haproxy", "ifstate", "k3s-k3s-bootstrap-apply", "k3s-k3s-pki-seed"]:
            alpha.fail(f"systemctl cat {unit}.service")
        links = alpha.succeed("ip -o link show").strip()
        for name in ["wg-mesh", "cilium_host", "cilium_net", "lxc"]:
            assert name not in links, f"{name} exists in the default mode:\n{links}"
        alpha.fail("test -e /etc/rancher/k3s/config.yaml")
        alpha.fail("mountpoint -q /sys/fs/bpf && grep -q cilium /proc/mounts")
        alpha.fail("nft list ruleset | grep -F 'cilium' >/dev/null")
        assert alpha.succeed("sysctl -n net.ipv4.ip_forward").strip() == "0"

    def kubernetes_mode():
        assert alpha.succeed("cat /etc/netif-mode").strip() == "kubernetes"
        alpha.fail("systemctl cat NetworkManager.service")
        alpha.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
        alpha.succeed("ip -br addr show wg-mesh | grep '192.168.77.1/32' >/dev/null")
        alpha.wait_for_unit("haproxy.service", timeout=240)
        alpha.wait_for_unit("k3s.service", timeout=600)
        alpha.wait_until_succeeds(
            "systemctl show -p Result --value k3s-k3s-bootstrap-apply | grep '^success$' >/dev/null",
            timeout=900,
        )
        alpha.wait_until_succeeds("kubectl wait --for=condition=Ready node/alpha --timeout=120s", timeout=300)
        alpha.wait_until_succeeds("KUBECONFIG=${kubeconfig} cilium status --wait --wait-duration 10s", timeout=300)

    try:
        alpha.start()
        alpha.wait_for_unit("multi-user.target", timeout=300)

        with subtest("the default mode has nothing of the cluster (N4)"):
            default_mode()
            print("K3S_MODES_DEFAULT_OK")

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
            print("K3S_MODES_CLUSTER_OK")

        with subtest("back in the default mode: the cluster is gone from the system, its state stays on disk"):
            boot(None)
            default_mode()
            alpha.succeed("test -d /var/lib/rancher/k3s/server/db")
            print("K3S_MODES_BACK_OK")

        with subtest("the kubernetes mode again: the same cluster, with its objects"):
            boot("${kubernetes}/init")
            kubernetes_mode()
            assert alpha.succeed("kubectl get node alpha -o jsonpath='{.metadata.uid}'").strip() == uid
            assert alpha.succeed("kubectl get configmap -n modes survives -o jsonpath='{.data.boot}'").strip() == "first"
            alpha.wait_until_succeeds("kubectl wait -n modes --for=condition=Ready pod/probe --timeout=120s", timeout=300)
            alpha.wait_until_succeeds("kubectl exec -n modes probe -- nc -z -w 3 10.2.0.1 443", timeout=120)
            print("K3S_MODES_RETURN_OK")

        print("K3S_MODES_OK")
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
        raise
  '';
}
