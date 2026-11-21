# Probe PR10 (specs/gateway.md §6; G5, G23, SPEC.md D67): pod IPv4 egress
# from a two-node cluster whose NICs carry only IPv6, on both transports.
#
#   alpha, beta (Cilium; NIC IPv6 only; a CLAT each) ── vlan 1 ── gw (Jool
#   NAT64 in a namespace) ── vlan 2 ── server4 (IPv4 only)
#
# `transport = "fabric"`: the <distro>-data-plane topology (routed-fabric,
# FRR, per-pair WireGuard, Cilium native routing). `transport = "mesh"`:
# the <distro>-join topology (wireguard-mesh, Cilium VXLAN tunnel). The
# test script is the same for both, so a difference between the modes
# shows as a different FINDING.
#
# Each node maps the whole cluster IPv4 pod pool into a /112 of a prefix
# routed to that node (specs/gateway.md G5): only its own pods leave
# through its CLAT, so the mapping needs no state and no per-node pod
# range.
#
# Questions:
#   - Does the fabric come up with IPv6 WireGuard endpoints only?
#   - With which source address does a pod's IPv4 packet reach the CLAT
#     in each mode?
#   - Does the pool mapping carry pods of both nodes, in both modes?
#   - Does the pod network between the nodes still work, both families?
#
# Lines that start with FINDING are the result.
{
  inputs,
  distro,
  transport,
  # true: the CLAT link joins Cilium's devices, so Cilium's own
  # masquerade should cover it and no pod pool mapping is needed
  device ? false,
}: {
  lib,
  nodes,
  ...
}: let
  k3s = distro == "k3s";
  fabric = transport == "fabric";
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  base = import ../../../ifstate.nix {inherit ifstateOverlay;};
  echo = import ./echo.nix;
  plain =
    if fabric
    then import ../../../kube-cluster/tests/vm/data-plane.nix {inherit inputs distro;} {inherit lib nodes;}
    else import ../../../kube-cluster/tests/vm/join.nix {inherit lib inputs distro;};
  # the devices the transport gives Cilium, plus the CLAT link
  withClat = settings: {
    cilium.helmValues.devices = "${settings.cilium.helmValues.devices or "wg-mesh"} clat0";
  };
  body =
    if device
    then
      lib.recursiveUpdate plain {
        clan.inventory.instances.${distro}.roles = lib.genAttrs ["server" "agent"] (role: {
          settings = withClat plain.clan.inventory.instances.${distro}.roles.${role}.settings;
        });
      }
    else plain;
  suffix = lib.optionalString device "-device";
  kubeconfig = "/etc/rancher/${distro}/${distro}.yaml";
  serverUnit =
    if k3s
    then "k3s"
    else "rke2-server";
  agentUnit =
    if k3s
    then "k3s"
    else "rke2-agent";
  pool = "2001:db8:64:0:64::/96";
  members = {
    alpha = 1;
    beta = 2;
  };
  underlay = n: "2001:db8:1::${toString n}";
  # the prefix routed to node n, as a cloud routes a /64 to a server
  routed = n: "2001:db8:a${toString n}";
  clatAddr = n: "${routed n}::c1a7";
  podMap = n: "${routed n}::a:0:0/112";

  phys = addresses: {
    inherit addresses;
    link = {
      kind = "physical";
      state = "up";
    };
  };

  clatNode = name: n: {
    pkgs,
    config,
    ...
  }: let
    busyboxImage = pkgs.dockerTools.pullImage {
      imageName = "busybox";
      imageDigest = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662";
      hash = "sha256-OasmfjRQsuVWudSc4qWuMKK5nNz4hdIS8Si4B0okXEw=";
      finalImageTag = "1.36.1";
    };
  in {
    imports = [body.nodes.${name}];
    boot = {
      extraModulePackages = [config.boot.kernelPackages.jool];
      kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
    };
    environment.systemPackages = [
      pkgs.jool-cli
      pkgs.curl
      pkgs.tcpdump
      pkgs.jq
      pkgs.kubectl
      pkgs.cilium-cli
    ];
    services.${distro}.images = [busyboxImage];
    systemd.tmpfiles.rules = lib.optionals (!k3s) [
      "L+ /var/lib/rancher/rke2/agent/images/${builtins.unsafeDiscardStringContext (baseNameOf busyboxImage)} - - - - ${busyboxImage}"
    ];
    networking.ifstate.settings = {
      interfaces = {
        eth1.addresses = lib.mkForce ["${underlay n}/64"];
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
          to = "${routed n}::/64";
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
        pkgs.gnugrep
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
        ip netns exec clat jool_siit -i clat eamt add ${clatAddr n} 192.0.0.1 || true
        ip route replace default via 192.0.0.2 dev clat0 mtu 1480
      '';
    };
  };

  v6Endpoints = lib.mapAttrs (_: n: {settings.endpoint = underlay n;}) members;
  v6Upstream = {
    settings.border.upstreamPeers = [
      {
        address = "2001:db8:1::3";
        asn = 65001;
      }
    ];
  };
in
  lib.recursiveUpdate body {
    name = "probe-${distro}-clat-${transport}${suffix}";

    clan.inventory = {
      machines = {
        gw = {};
        server4 = {};
      };
      instances =
        {
          underlay.roles.default.machines = lib.mapAttrs (_: n: {settings.host = underlay n;}) members;
        }
        // lib.optionalAttrs fabric {
          mesh.roles = {
            spine.machines.alpha = lib.recursiveUpdate v6Endpoints.alpha v6Upstream;
            leaf.machines.beta = lib.recursiveUpdate v6Endpoints.beta v6Upstream;
          };
        };
    };

    nodes =
      lib.mapAttrs clatNode members
      // {
        gw = import ./nat64-gateway.nix {
          inherit base pool;
          allow = "{ 2001:db8:1::/64, 2001:db8:a0::/44 }";
          inside = ["2001:db8:1::64/64"];
          outside = ["198.51.100.1/24"];
          routes =
            lib.mapAttrsToList (_: n: {
              to = "${routed n}::/64";
              via = underlay n;
            })
            members;
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
      import json

      K = "KUBECONFIG=${kubeconfig}"
      NODES = {"alpha": alpha, "beta": beta}
      MAPS = {"alpha": "${podMap 1}", "beta": "${podMap 2}"}

      def observe(label, machine, cmd):
          status, out = machine.execute(cmd + " 2>&1")
          print(f"FINDING {label}: rc={status}\n{out.rstrip()}")
          return status, out.strip()

      def in_pod(label, node, command, timeout=40):
          return observe(label, alpha, f"{K} timeout {timeout} kubectl exec anchor-{node} -- {command}")

      def attempt(node, label):
          machine = NODES[node]
          machine.execute("timeout 20 tcpdump -i clat0 -n -l -c 6 'tcp port 80 or icmp' > /tmp/clat0.txt 2>&1 &")
          machine.execute("sleep 1")
          status, out = in_pod(f"{node}: pod to an IPv4 literal, {label}", node, "wget -T 8 -qO- http://198.51.100.80/")
          observe(f"{node}: {label}: what the CLAT link carried", machine, "sleep 2; grep -v '^tcpdump\\|^listening' /tmp/clat0.txt")
          works = status == 0 and "198.51.100.1" in out
          print(f"FINDING {node}: pod IPv4 egress, {label}: {'works' if works else 'FAILS'}")
          return works

      start_all()
      for machine in [gw, server4]:
          machine.wait_for_unit("multi-user.target", timeout=300)
      gw.wait_for_unit("jool-netns.service", timeout=60)
      server4.wait_until_succeeds("ss -tln | grep ':80 ' >/dev/null", timeout=60)

      with subtest("each node reaches IPv4 through its own CLAT"):
          for name, machine in NODES.items():
              machine.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null", timeout=120)
              machine.wait_for_unit("clat.service", timeout=120)
              out = machine.wait_until_succeeds("curl -s --max-time 5 http://198.51.100.80/", timeout=120).strip()
              assert out.endswith("198.51.100.1"), out
              assert "inet " not in machine.succeed("ip -4 -br addr show dev eth1"), "the NIC has an IPv4 address"
          print("PROBE_CLAT_HOST_OK")

      with subtest("the transport comes up over IPv6 endpoints"):
          for name, machine in NODES.items():
              machine.wait_until_succeeds("wg show all latest-handshakes | awk '$3 > 0 { ok = 1 } END { exit !ok }'", timeout=180)
              observe(f"{name}: WireGuard endpoints", machine, "wg show all endpoints")
          ${lib.optionalString fabric ''
        for name, machine in NODES.items():
                  machine.wait_for_unit("frr.service", timeout=240)
                  observe(f"{name}: BGP sessions", machine, "sleep 20; vtysh -c 'show bgp summary' | tail -n 14")
      ''}
      with subtest("the cluster comes up on IPv6-only NICs"):
          alpha.wait_for_unit("${serverUnit}.service", timeout=600)
          beta.wait_for_unit("${agentUnit}.service", timeout=600)
          alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s", timeout=900)
          alpha.wait_until_succeeds(f"{K} cilium status", timeout=300)
          alpha.wait_until_succeeds(f"{K} kubectl get serviceaccount default", timeout=120)
          observe("Cilium datapath settings", alpha, f"{K} kubectl -n kube-system get configmap cilium-config -o json | jq -r '.data | to_entries[] | select(.key | test(\"device|native-routing|masq|routing-mode|tunnel-protocol|host-legacy\")) | \"\\(.key)=\\(.value)\"'")
          observe("Cilium status", alpha, f"{K} kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep -i -A3 'masquerading\\|host routing\\|^Routing'")
          for name, machine in NODES.items():
              observe(f"{name}: the node still reaches IPv4 with Cilium up", machine, "curl -s --max-time 5 http://198.51.100.80/")
              observe(f"{name}: IPv4 routes", machine, "ip -4 route")

      with subtest("a pod on each node; the pod network between the nodes"):
          ips = {}
          for name in NODES:
              overrides = json.dumps({"spec": {"nodeSelector": {"kubernetes.io/hostname": name}}})
              alpha.succeed(f"{K} kubectl run anchor-{name} --restart=Never --image=busybox:1.36.1 --image-pull-policy=Never --overrides='{overrides}' -- sleep 3600")
          for name in NODES:
              alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready pod/anchor-{name} --timeout=60s", timeout=300)
              pod = json.loads(alpha.succeed(f"{K} kubectl get pod anchor-{name} -o json"))
              assert pod["spec"]["nodeName"] == name, pod["spec"]["nodeName"]
              ips[name] = [ip["ip"] for ip in pod["status"]["podIPs"]]
          print(f"FINDING pod addresses: {ips}")
          for address in ips["beta"]:
              status, _ = in_pod(f"pod on alpha pings the pod on beta at {address}", "alpha", f"ping -c2 -W3 {address}")
              assert status == 0, f"pod network between the nodes is broken for {address}"
          print("PROBE_CLAT_POD_NETWORK_OK")

      with subtest("pods reach an IPv4 address"):
          v4 = next(ip for ip in ips["alpha"] if ":" not in ip)
          pod_pool = ".".join(v4.split(".")[:2]) + ".0.0/16"
          print(f"FINDING the cluster IPv4 pod pool is taken to be {pod_pool}")
          shipped = {name: attempt(name, "as shipped") for name in NODES}
          print(f"FINDING as shipped (${transport}${suffix}): {shipped}")
          mapped = shipped
          if not all(shipped.values()):
              for name, machine in NODES.items():
                  machine.succeed(f"ip netns exec clat jool_siit -i clat eamt add {MAPS[name]} {pod_pool}")
              mapped = {name: attempt(name, "with the pod pool mapped statelessly") for name in NODES}
              print(f"FINDING pool mapping (${transport}${suffix}): {mapped}")
          for name, machine in NODES.items():
              in_pod(f"{name}: pod, 2 MB down", name, "sh -c 'wget -T 20 -qO- http://198.51.100.80/big | wc -c'")
              in_pod(f"{name}: pod, 2 MB up", name, "sh -c 'yes | head -c 2000000 > /tmp/up; wget -T 20 -qO- --post-file=/tmp/up http://198.51.100.80/'")
              in_pod(f"{name}: pod, ping", name, "ping -c2 -W2 198.51.100.80")
              in_pod(f"{name}: pod, cluster DNS", name, "nslookup kubernetes.default.svc.cluster.local")
              observe(f"{name}: CLAT statistics", machine, "ip netns exec clat jool_siit -i clat stats display | head -n 12")
          # pods still talk to each other after the mapping
          for address in ips["beta"]:
              status, _ = in_pod(f"after the mapping: pod on alpha pings the pod on beta at {address}", "alpha", f"ping -c2 -W3 {address}")
              assert status == 0, address
          # the cluster's CoreDNS forwards to the fixture's IPv4 nameserver
          in_pod("pod to a private IPv4 address beyond the cluster", "alpha", "wget -T 4 -qO- http://192.168.1.254/", timeout=10)
          observe("gateway: private IPv4 destinations refused", gw, "nft list ruleset | grep nat64-private")
          assert "packets 0 " not in gw.succeed("nft list ruleset | grep nat64-private"), "the gateway refused nothing"
          observe("gateway conntrack", gw, "conntrack -L 2>/dev/null | grep 198.51.100.80 | head -6")
          assert all(mapped.values()), f"pod IPv4 egress with the pool mapping: {mapped}"

      with subtest("an IfState apply leaves pod IPv4 egress intact"):
          after = {}
          for name, machine in NODES.items():
              machine.succeed("systemctl restart ifstate.service")
              machine.wait_for_unit("clat.service", timeout=60)
              observe(f"{name}: what IfState would still change", machine, "ifstatecli --config /etc/ifstate/ifstate.yaml check | grep -v ' ok$\\| = \\|orphan' | head -n 20")
              status, out = in_pod(f"{name}: pod to an IPv4 literal after an IfState apply", name, "wget -T 8 -qO- http://198.51.100.80/")
              after[name] = status == 0 and "198.51.100.1" in out
          print(f"FINDING after an IfState apply (${transport}${suffix}): {after}")
          for address in ips["beta"]:
              status, _ = in_pod(f"after an IfState apply: pod on alpha pings the pod on beta at {address}", "alpha", f"ping -c2 -W3 {address}")
              assert status == 0, address
          assert all(after.values()), after

      print("PROBE_${lib.toUpper distro}_CLAT_${lib.toUpper transport}${lib.toUpper (lib.replaceStrings ["-"] ["_"] suffix)}_OK")
    '';
  }
