# Probe PR1 (specs/gateway.md §6; G5): pod IPv4 egress from a node that
# has no IPv4 on its NIC, through a CLAT on the node and NAT64 on a
# gateway.
#
#   alpha (k3s, Cilium; NIC IPv6 only) ── vlan 1 ── gw (Jool NAT64 in a
#   namespace) ── vlan 2 ── server4 (IPv4 only)
#
# The node is the k3s-single suite's node with an IPv6-only NIC and the
# CLAT of specs/gateway.md G23. Questions:
#   - Does a pod's IPv4 packet to the internet reach the CLAT at all, and
#     with which source address (Cilium masquerades in eBPF)?
#   - If it arrives with the pod's address: does a stateless mapping of
#     the node's pod CIDR carry it?
#   - Does bulk traffic work in both directions (MTU)?
#
# Lines that start with FINDING are the result.
{
  lib,
  inputs,
  ...
}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  base = import ../../../ifstate.nix {inherit ifstateOverlay;};
  echo = import ./echo.nix;
  body = import ../../../kube-cluster/tests/vm/single.nix {
    inherit lib inputs;
    distro = "k3s";
  };
  kubeconfig = "/etc/rancher/k3s/k3s.yaml";
  pool = "2001:db8:64:0:64::/96";
  clatAddr = "2001:db8:1::c1a7";
  # a /120 for the node's pod /24, should a stateless mapping be needed
  podMap = "2001:db8:1::a:0/120";

  phys = addresses: {
    inherit addresses;
    link = {
      kind = "physical";
      state = "up";
    };
  };
in
  lib.recursiveUpdate body {
    name = "probe-k3s-clat";

    clan.inventory = {
      machines = {
        gw = {};
        server4 = {};
      };
      instances.underlay.roles.default.machines.alpha.settings.host = "2001:db8:1::1";
    };

    nodes = {
      alpha = {
        pkgs,
        config,
        ...
      }: {
        imports = [body.nodes.alpha];
        virtualisation.vlans = [1];
        boot = {
          extraModulePackages = [config.boot.kernelPackages.jool];
          kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
        };
        environment.systemPackages = [
          pkgs.jool-cli
          pkgs.curl
          pkgs.tcpdump
          pkgs.jq
        ];
        networking.ifstate.settings = {
          interfaces = {
            eth1.addresses = lib.mkForce ["2001:db8:1::1/64"];
            clat0 = {
              addresses = [
                "192.0.0.1/29"
                "fd00:c1a7::1/64"
              ];
              link = {
                kind = "veth";
                state = "up";
                peer = "clat1";
                peer_netns = "clat";
              };
            };
          };
          namespaces.clat = {
            interfaces.clat1 = {
              addresses = [
                "192.0.0.2/29"
                "fd00:c1a7::2/64"
              ];
              link = {
                kind = "veth";
                state = "up";
                peer = "clat0";
                peer_netns = null;
              };
            };
            routing.routes = [
              {
                to = "::/0";
                via = "fd00:c1a7::1";
              }
              {
                to = "0.0.0.0/0";
                via = "192.0.0.1";
              }
            ];
          };
          routing.routes = [
            {
              to = "0.0.0.0/0";
              via = "192.0.0.2";
            }
            {
              to = "2001:db8:64::/64";
              via = "2001:db8:1::64";
            }
            {
              to = "${clatAddr}/128";
              via = "fd00:c1a7::2";
            }
            {
              to = podMap;
              via = "fd00:c1a7::2";
            }
          ];
        };
        systemd.services.clat = {
          wantedBy = ["multi-user.target"];
          after = ["ifstate.service"];
          requires = ["ifstate.service"];
          path = [
            pkgs.iproute2
            pkgs.kmod
            pkgs.jool-cli
            pkgs.procps
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            modprobe jool_siit
            ip netns exec clat sysctl -w net.ipv4.conf.all.forwarding=1 net.ipv6.conf.all.forwarding=1
            ip netns exec clat jool_siit instance display | grep clat >/dev/null \
              || ip netns exec clat jool_siit instance add clat --netfilter --pool6 ${pool}
            ip netns exec clat jool_siit -i clat eamt add ${clatAddr} 192.0.0.1 || true
            ip route replace default via 192.0.0.2 dev clat0 mtu 1480
          '';
        };
      };

      gw = import ./nat64-gateway.nix {
        inherit base pool;
        allow = "2001:db8:1::/64";
        inside = ["2001:db8:1::64/64"];
        outside = ["198.51.100.1/24"];
        routes = [
          {
            to = "${clatAddr}/128";
            via = "2001:db8:1::1";
          }
          {
            to = podMap;
            via = "2001:db8:1::1";
          }
        ];
      };

      server4 = {pkgs, ...}: {
        imports = [base];
        virtualisation = {
          cores = 1;
          memorySize = 1024;
          vlans = [2];
        };
        networking = {
          firewall.enable = false;
          ifstate.settings.interfaces.eth1 = phys ["198.51.100.80/24"];
        };
        systemd.services.echo = {
          wantedBy = ["multi-user.target"];
          serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [80]}";
        };
      };
    };

    testScript = ''
      import ipaddress
      import json

      K = "KUBECONFIG=${kubeconfig}"
      counter = [0]

      def observe(label, machine, cmd):
          status, out = machine.execute(cmd + " 2>&1")
          print(f"FINDING {label}: rc={status}\n{out.rstrip()}")
          return status, out.strip()

      def pod(label, command, timeout=40):
          counter[0] += 1
          name = f"probe{counter[0]}"
          return observe(
              label,
              alpha,
              f"{K} timeout {timeout} kubectl run {name} --rm --attach --restart=Never --image=busybox:1.36.1 --image-pull-policy=Never -- {command}",
          )

      def cilium(label, command):
          return observe(label, alpha, f"{K} kubectl -n kube-system exec ds/cilium -c cilium-agent -- {command}")

      start_all()
      for machine in [gw, server4]:
          machine.wait_for_unit("multi-user.target", timeout=300)
      gw.wait_for_unit("jool-netns.service", timeout=60)
      server4.wait_until_succeeds("ss -tln | grep ':80 ' >/dev/null", timeout=60)
      alpha.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
      alpha.wait_for_unit("clat.service", timeout=120)

      with subtest("the node itself reaches IPv4 through its CLAT"):
          out = alpha.wait_until_succeeds("curl -s --max-time 5 http://198.51.100.80/", timeout=120).strip()
          assert out.endswith("198.51.100.1"), out
          observe("node addresses and IPv4 routes", alpha, "ip -br addr; ip -4 route")
          print("PROBE_K3S_CLAT_HOST_OK")

      with subtest("the cluster comes up on the IPv6-only node"):
          alpha.wait_for_unit("k3s.service", timeout=600)
          alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready node/alpha --timeout=120s", timeout=600)
          alpha.wait_until_succeeds(f"{K} cilium status", timeout=300)
          alpha.wait_until_succeeds(f"{K} kubectl get serviceaccount default", timeout=120)
          observe("the node still reaches IPv4 with Cilium up", alpha, "curl -s --max-time 5 http://198.51.100.80/")
          cilium("Cilium status", "cilium-dbg status --verbose | grep -i -A4 'masquerading\\|host routing\\|kubeproxyreplacement\\|^Routing'")
          observe("Cilium devices and native routing", alpha, f"{K} kubectl -n kube-system get configmap cilium-config -o json | jq -r '.data | to_entries[] | select(.key | test(\"device|native-routing|masq|routing-mode|host-legacy\")) | \"\\(.key)=\\(.value)\"'")
          observe("node routes after Cilium", alpha, "ip -4 route; ip -br link | cut -c1-60")
          observe("netfilter rules Cilium added", alpha, "iptables-save 2>/dev/null | grep -c CILIUM; nft list ruleset | grep -c -i cilium")

      with subtest("a pod reaches an IPv4 address"):
          alpha.execute("tcpdump -i clat0 -n -c 8 'tcp port 80 or icmp' > /tmp/clat0.txt 2>&1 &")
          status, out = pod("pod to an IPv4 literal", "wget -T 10 -qO- http://198.51.100.80/")
          observe("what the CLAT link carried", alpha, "sleep 1; pkill tcpdump; sleep 1; cat /tmp/clat0.txt")
          observe("CLAT statistics", alpha, "ip netns exec clat jool_siit -i clat stats display")
          works = status == 0 and "198.51.100.1" in out
          print(f"FINDING pod IPv4 egress through the node CLAT with Cilium's own masquerade: {'works' if works else 'FAILS'}")
          if not works:
              cilium("Cilium drops", "timeout 3 cilium-dbg monitor --type drop")
              pods = json.loads(alpha.succeed(f"{K} kubectl get ciliumnode alpha -o json"))["spec"]["ipam"]["podCIDRs"]
              v4 = [c for c in pods if ":" not in c][0]
              print(f"FINDING the node's pod CIDRs are {pods}")
              net = ipaddress.ip_network(v4)
              if net.prefixlen == 24:
                  alpha.succeed(f"ip netns exec clat jool_siit -i clat eamt add ${podMap} {v4}")
                  status, out = pod("pod to an IPv4 literal, with the pod CIDR mapped statelessly", "wget -T 10 -qO- http://198.51.100.80/")
                  observe("CLAT statistics after the mapping", alpha, "ip netns exec clat jool_siit -i clat stats display")
                  works = status == 0 and "198.51.100.1" in out
                  print(f"FINDING pod IPv4 egress with a stateless pod CIDR mapping: {'works' if works else 'FAILS'}")
          pod("pod: 2 MB down", "sh -c 'wget -T 20 -qO- http://198.51.100.80/big | wc -c'")
          pod("pod: 2 MB up", "sh -c 'dd if=/dev/zero bs=1024 count=2000 2>/dev/null > /tmp/up; wget -T 20 -qO- --post-file=/tmp/up http://198.51.100.80/'")
          pod("pod: ping", "ping -c2 -W2 198.51.100.80")
          pod("pod: cluster DNS still answers", "nslookup kubernetes.default.svc.cluster.local")
          observe("gateway conntrack", gw, "conntrack -L 2>/dev/null | grep 198.51.100.80 | head -5")

      print("PROBE_K3S_CLAT_OK")
    '';
  }
