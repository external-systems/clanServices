# Probe (2026-11-16, proof session): N22 with the `containers`
# preset's ignores (IfState built-ins + ^podman), nftables firewall on,
# published ports reached from another machine.
{
  pkgs,
  lib,
  ...
}: let
  image = pkgs.dockerTools.buildImage {
    name = "probe";
    tag = "latest";
    copyToRoot = [pkgs.busybox];
    config.Cmd = ["/bin/sleep" "100000"];
  };
  owned = ["^docker" "^br-" "^podman" "^veth"];
in {
  name = "netif-containers2-probe";
  nodes = {
    host = {
      virtualisation = {
        vlans = [1];
        memorySize = 3072;
        diskSize = 4096;
        docker.enable = true;
        podman.enable = true;
      };
      networking = {
        interfaces = lib.mkForce {};
        useDHCP = false;
        nftables.enable = true;
        firewall = {
          enable = true;
          allowedTCPPorts = [8080 8081];
        };
        ifstate = {
          enable = true;
          settings = {
            parameters.ignore = {
              ifname = owned;
              netns = ["^netns-"];
              routes = map (dev: {inherit dev;}) owned;
            };
            interfaces.eth1 = {
              addresses = ["192.168.1.1/24"];
              link = {
                kind = "physical";
                state = "up";
              };
            };
            routing.routes = [
              {
                to = "198.51.100.0/24";
                via = "192.168.1.254";
                dev = "eth1";
              }
            ];
            routing.rules = [
              {
                from = "192.168.1.0/24";
                table = 300;
                priority = 1000;
              }
            ];
          };
        };
      };
      environment.systemPackages = [pkgs.jq];
    };
    peer = {
      virtualisation.vlans = [1];
      networking.firewall.enable = false;
      networking.interfaces.eth1 = lib.mkForce {
        ipv4.addresses = [
          {
            address = "192.168.1.2";
            prefixLength = 24;
          }
        ];
      };
    };
  };

  testScript = ''
    def show(cmd):
        rc, out = host.execute(cmd + " 2>&1")
        print(f"=== {cmd}\n{out}")
        return out
    def fact(name, value):
        print(f"FACT {name}: {value}")
    def ok(m, cmd):
        return m.execute(cmd)[0] == 0
    SNAP = "ip -br link | awk '{print $1, $2, $3}' | sort; ip -br addr | sort; ip -4 route show table all | grep -v -E '^(local|broadcast)' | sort; ip rule; ip netns list | sort"
    SERVE = "/bin/sh -c 'while true; do echo ok | nc -l -p 8080; done'"

    start_all()
    host.wait_for_unit("multi-user.target")
    host.wait_for_unit("docker.service")
    peer.wait_for_unit("multi-user.target")

    with subtest("docker"):
        host.succeed("docker load -i ${image}")
        host.succeed(f"docker run -d --name c1 -p 8080:8080 probe:latest {SERVE}")
        host.succeed("docker network create probenet && docker run -d --name c2 --network probenet probe:latest")
        host.wait_until_succeeds("docker exec c1 ping -c1 -W2 192.168.1.2", timeout=30)
        fact("docker_port_from_peer_before", ok(peer, "echo | nc -w2 192.168.1.1 8080 | grep ok"))
    with subtest("podman rootful"):
        host.succeed("podman load -i ${image}")
        host.succeed(f"podman run -d --cap-add NET_RAW --name p1 -p 8081:8080 localhost/probe:latest {SERVE}")
        host.succeed("podman network create pnet && podman run -d --cap-add NET_RAW --name p2 --network pnet localhost/probe:latest")
        host.wait_until_succeeds("podman exec p1 ping -c1 -W2 192.168.1.2", timeout=30)
        host.wait_until_succeeds("podman exec p2 ping -c1 -W2 192.168.1.2", timeout=30)
        fact("podman_port_from_peer_before", ok(peer, "echo | nc -w2 192.168.1.1 8081 | grep ok"))

    with subtest("two applies"):
        before = show(SNAP)
        show("ifstatecli --config /etc/ifstate/ifstate.yaml check | tail -30")
        host.succeed("systemctl restart ifstate.service"); host.succeed("systemctl restart ifstate.service")
        after = show(SNAP)
        fact("snapshot_identical_after_two_applies", before == after)
        fact("docker_default_bridge_connectivity", ok(host, "docker exec c1 ping -c1 -W2 192.168.1.2"))
        fact("docker_user_network_connectivity", ok(host, "docker exec c2 ping -c1 -W2 192.168.1.2"))
        fact("docker_port_from_peer_after", ok(peer, "echo | nc -w2 192.168.1.1 8080 | grep ok"))
        fact("podman_default_bridge_connectivity", ok(host, "podman exec p1 ping -c1 -W2 192.168.1.2"))
        fact("podman_user_network_connectivity", ok(host, "podman exec p2 ping -c1 -W2 192.168.1.2"))
        fact("podman_port_from_peer_after", ok(peer, "echo | nc -w2 192.168.1.1 8081 | grep ok"))
        show("ip -br link; nft list tables; sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding; podman network ls; podman info | grep -i -E 'networkBackend|firewall' ")
        # a container started after the applies still works
        host.succeed("podman run -d --cap-add NET_RAW --name p3 localhost/probe:latest")
        fact("podman_new_container_after_applies", ok(host, "sleep 2; podman exec p3 ping -c1 -W2 192.168.1.2"))
    print("NETIF_CONTAINERS2_PROBE_DONE")
  '';
}
