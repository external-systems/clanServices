# netif-containers (specs/netif.md N22; phase P7). Docker and rootful
# Podman run beside netif on one machine. The `containers` preset of the
# ownership registry switches on by itself; IfState reapplies must leave
# every container link, network namespace and published port alone.
#
#   host (netif: eth1 static, untrusted) ── vlan 1 ── peer
{inputs, ...}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  noopHelper = import ../../../../tests/ifstate-noop.nix;
in {
  name = "netif-containers";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        host = {};
        peer = {};
      };
      instances.lan = {
        module.name = "netif";
        module.input = "self";
        # Node order (host, peer) gives host 192.168.1.1.
        roles.default.machines.host.settings.links.uplink = {
          interface = "eth1";
          static.ipv4 = ["192.168.1.1/24"];
        };
      };
    };
  };

  nodes = {
    host = {pkgs, ...}: {
      virtualisation = {
        cores = 2;
        memorySize = 3072;
        diskSize = 4096;
        docker.enable = true;
        podman.enable = true;
      };
      environment.systemPackages = [pkgs.jq];
      # The image is in the store: the test has no network.
      environment.etc."netif-test/image".source = pkgs.dockerTools.buildImage {
        name = "probe";
        tag = "latest";
        copyToRoot = [pkgs.busybox];
        config.Cmd = [
          "/bin/sleep"
          "100000"
        ];
      };
    };
    peer = {pkgs, ...}: {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          inherit ifstateOverlay;
          addresses = ["192.168.1.2/24"];
          withBase = true;
        })
      ];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
      };
      networking.firewall.enable = false;
      environment.systemPackages = [pkgs.netcat];
    };
  };

  testScript = ''
    import json

    ${noopHelper}

    SERVE = "/bin/sh -c 'while true; do echo ok | nc -l -p 8080; done'"
    IMAGE = "/etc/netif-test/image"

    def reaches_peer(runtime, name):
        host.wait_until_succeeds(f"{runtime} exec {name} ping -c1 -W2 192.168.1.2", timeout=30)

    def port_answers(port):
        peer.wait_until_succeeds(f"echo | nc -w2 192.168.1.1 {port} | grep ok >/dev/null", timeout=30)

    def container_links():
        links = json.loads(host.succeed("ip -j link show"))
        return sorted(l["ifname"] for l in links if l["ifname"].startswith(("docker", "br-", "podman", "veth")))

    try:
        start_all()
        host.wait_for_unit("multi-user.target", timeout=180)
        host.wait_for_unit("docker.service", timeout=180)
        peer.wait_for_unit("multi-user.target", timeout=180)
        host.wait_until_succeeds("ping -c1 -W2 192.168.1.2", timeout=60)

        with subtest("the containers preset is on and names every object (N22)"):
            ignore = host.succeed("sed -n '/^parameters:/,$p' /etc/ifstate/ifstate.yaml")
            for regex in ["^docker", "^br-", "^podman", "^veth", "^netns-"]:
                assert regex in ignore, f"{regex} missing from parameters.ignore:\n{ignore}"
            print("NETIF_CONTAINERS_PRESET_OK")

        with subtest("Docker: default bridge, a user network, a published port"):
            host.succeed(f"docker load -i {IMAGE}")
            host.succeed(f"docker run -d --name c1 -p 8080:8080 probe:latest {SERVE}")
            host.succeed("docker network create probenet && docker run -d --name c2 --network probenet probe:latest")
            reaches_peer("docker", "c1")
            reaches_peer("docker", "c2")
            port_answers(8080)

        with subtest("rootful Podman: default bridge, a user network, a published port"):
            host.succeed(f"podman load -i {IMAGE}")
            host.succeed(f"podman run -d --cap-add NET_RAW --name p1 -p 8081:8080 localhost/probe:latest {SERVE}")
            host.succeed("podman network create pnet && podman run -d --cap-add NET_RAW --name p2 --network pnet localhost/probe:latest")
            reaches_peer("podman", "p1")
            reaches_peer("podman", "p2")
            port_answers(8081)
            # Podman's named namespaces are the reason the preset owns ^netns-
            host.succeed("ip netns list | grep '^netns-' >/dev/null")

        with subtest("two reapplies change nothing and break nothing (invariant 5)"):
            links = container_links()
            namespaces = host.succeed("ip netns list | sort")
            assert any(l.startswith("podman") for l in links) and any(l.startswith("docker") for l in links), links
            assert_ifstate_noop(host)
            assert_ifstate_noop(host)
            assert container_links() == links, (links, container_links())
            assert host.succeed("ip netns list | sort") == namespaces
            for runtime, name in [("docker", "c1"), ("docker", "c2"), ("podman", "p1"), ("podman", "p2")]:
                reaches_peer(runtime, name)
            port_answers(8080)
            port_answers(8081)
            print("NETIF_CONTAINERS_NOOP_OK")

        with subtest("containers started and removed after the reapplies"):
            host.succeed("podman run -d --cap-add NET_RAW --name p3 localhost/probe:latest")
            host.succeed("docker run -d --name c3 probe:latest")
            reaches_peer("podman", "p3")
            reaches_peer("docker", "c3")
            host.succeed("docker rm -f c2 && podman rm -f p2")
            assert_ifstate_noop(host)
            reaches_peer("docker", "c1")
            reaches_peer("podman", "p1")
            print("NETIF_CONTAINERS_CHURN_OK")

        with subtest("the uplink stays untrusted; the tools see only netif's link (N19, N41)"):
            trusted = host.succeed("nft list ruleset | grep 'trusted interfaces' || true")
            assert "eth1" not in trusted and "docker" not in trusted and "podman" not in trusted, trusted
            status = json.loads(host.succeed("netif-status --json"))
            assert [l["interface"] for l in status["links"]] == ["eth1"], status
            host.succeed("netif-preview | grep 'would change nothing' >/dev/null")
            host.succeed("systemctl start netif-drift.service")
            print("NETIF_CONTAINERS_TOOLS_OK")

        print("NETIF_CONTAINERS_OK")
    except Exception:
        for command in [
            "ip -br link >&2; ip -br addr >&2; ip netns list >&2",
            "ip route show table all | grep -v -E '^(local|broadcast)' >&2",
            "nft list ruleset >&2",
            "docker ps -a >&2; podman ps -a >&2",
            "journalctl -b -u ifstate.service -u docker.service --no-pager | tail -n 150 >&2",
        ]:
            host.execute(command)
        raise
  '';
}
