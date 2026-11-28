# nat-gateway-kube (specs/gateway.md §14.5 point 5): a `nat-gateway`
# gateway that is also a Kubernetes node, and a node behind it.
#
#   alpha (k3s server; gateway: Jool NAT64 in a namespace, public IPv4 on
#          eth2) ── vlan 2 ── server4 (IPv4 only)
#     │ vlan 1, IPv6 only
#   beta  (k3s agent; client: CLAT, IPv6-only NIC)
#   router (the fabric's upstream FRR, on vlan 1): a machine that is no
#          client
#
# The <distro>-data-plane topology on netif: routed-fabric, FRR,
# per-pair WireGuard, Cilium native routing (SPEC.md D72). Every link,
# the gateway, the CLAT and Cilium's `devices` come from the services.
#
# What the suite pins:
#   - D71 on a gateway member: its uplink (eth2) is a Cilium device, so
#     pods on the gateway leave with its public IPv4 through Cilium's
#     eBPF masquerade, without a CLAT; the gateway runs no CLAT;
#   - beta, its host and its pods, reach IPv4 through its CLAT and the
#     gateway on alpha;
#   - two masquerades share one public IPv4 on one link: Cilium's eBPF
#     one (alpha's pods) and the gateway's nftables one (NAT64). Many
#     long flows from both at once, and from alpha's host, all complete,
#     twice;
#   - the gateway's allowlist holds on a Cilium node: an undeclared
#     source does not reach the translator, and every packet is counted;
#   - a NodePort does not answer on the public IPv4 (D69);
#   - a restart of nftables or of the gateway's Jool on the node leaves
#     the cluster's egress working.
{inputs}: {
  lib,
  nodes,
  ...
}: let
  distro = "k3s";
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  base = import ../../../ifstate.nix {inherit ifstateOverlay;};
  echo = import ./echo.nix;
  plain = import ../../../kube-cluster/tests/vm/data-plane.nix {
    inherit inputs distro;
    underlay = "netif";
  } {inherit lib nodes;};
  # D71: nothing is hand-set; the data-plane topology's own `devices` goes
  dropDevices = settings:
    settings
    // {
      cilium =
        settings.cilium
        // {
          helmValues = removeAttrs settings.cilium.helmValues ["devices"];
        };
    };
  roleSettings = lib.genAttrs ["server" "agent"] (role: {
    settings = dropDevices plain.clan.inventory.instances.${distro}.roles.${role}.settings;
  });
  body =
    lib.recursiveUpdateUntil (
      path: _: _:
        lib.elem path (map (role: ["clan" "inventory" "instances" distro "roles" role "settings"]) ["server" "agent"])
    )
    plain {
      clan.inventory.instances.${distro}.roles = roleSettings;
    };
  kubeconfig = "/etc/rancher/${distro}/${distro}.yaml";

  members = {
    alpha = 1;
    beta = 2;
  };
  underlay = n: "2001:db8:1::${toString n}";
  # alpha's /96; the /64 around it is routed to alpha, as a provider
  # routes one
  pool = "2001:db8:64:0:64::/96";
  betaClat = "2001:db8:1::c1a2";
  public4 = "198.51.100.1";
  targets = ["198.51.100.90" "198.51.100.91" "198.51.100.92"];

  phys = addresses: {
    inherit addresses;
    link = {
      kind = "physical";
      state = "up";
    };
  };

  # A TCP server: each connection sends one line, the server holds it
  # for `hold` s, sends the line back and closes. Many such flows are
  # open at once.
  holdServer = pkgs:
    pkgs.writeText "hold-server.py" ''
      import socket
      import threading
      import time


      def serve(conn):
          with conn:
              line = conn.makefile().readline()
              time.sleep(8)
              conn.sendall(line.encode())


      sock = socket.socket()
      sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
      sock.bind(("0.0.0.0", 9002))
      sock.listen(4096)
      while True:
          conn, _ = sock.accept()
          threading.Thread(target=serve, args=(conn,), daemon=True).start()
    '';
  # The client side for a host: `count` flows at once, prints how many
  # got their own line back.
  holdClient = ''
    import socket
    import sys
    import threading

    host, count = sys.argv[1], int(sys.argv[2])
    good = []


    def flow(i):
        try:
            with socket.create_connection((host, 9002), timeout=30) as sock:
                sock.sendall(f"hi{i}\n".encode())
                if sock.makefile().readline().strip() == f"hi{i}":
                    good.append(i)
        except OSError:
            pass


    threads = [threading.Thread(target=flow, args=(i,)) for i in range(count)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    print(len(good))
  '';

  node = name: {pkgs, ...}: {
    imports = [body.nodes.${name}];
    environment = {
      systemPackages = [
        pkgs.curl
        pkgs.tcpdump
        pkgs.jq
        pkgs.python3
        pkgs.conntrack-tools
      ];
      etc."suite/hold.py".text = holdClient;
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
    name = "nat-gateway-kube";

    clan.inventory = {
      machines.server4 = {};
      instances = {
        links = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines = {
            alpha.settings.links = {
              inside = {
                interface = "eth1";
                zone = "inside";
                static.ipv6 = ["${underlay 1}/64"];
                ra = false;
              };
              # the public IPv4 and its default route
              wan = {
                interface = "eth2";
                zone = "wan";
                static.ipv4 = ["${public4}/24"];
                gateway.ipv4 = "198.51.100.80";
                ra = false;
              };
            };
            beta.settings.links.uplink = {
              interface = "eth1";
              zone = "wan";
              static.ipv6 = ["${underlay 2}/64"];
              routes = [
                {
                  destination = "2001:db8:64::/64";
                  gateway = underlay 1;
                }
              ];
              ra = false;
            };
          };
        };
        nat64 = {
          module.name = "nat-gateway";
          module.input = "self";
          roles = {
            gateway.machines.alpha.settings = {
              pool6 = pool;
              address = underlay 1;
              health.targets = targets;
            };
            client.machines.beta.settings.clat.address = betaClat;
          };
        };
        underlay.roles.default.machines = lib.mapAttrs (_: n: {settings.host = underlay n;}) members;
        mesh.roles = {
          spine.machines.alpha = lib.recursiveUpdate v6Endpoints.alpha v6Upstream;
          leaf.machines.beta = lib.recursiveUpdate v6Endpoints.beta v6Upstream;
        };
      };
    };

    nodes = {
      alpha = {
        imports = [(node "alpha")];
        virtualisation.vlans = [
          1
          2
        ];
      };
      beta = node "beta";
      server4 = {pkgs, ...}: {
        imports = [base];
        virtualisation = {
          cores = 1;
          memorySize = 1024;
          vlans = [2];
        };
        networking = {
          firewall.enable = false;
          # the health targets are /32s of their own
          ifstate.settings.interfaces.eth1 = phys (["198.51.100.80/24"] ++ map (address: "${address}/32") targets);
        };
        systemd.services = {
          echo = {
            wantedBy = ["multi-user.target"];
            serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [80]}";
          };
          hold = {
            wantedBy = ["multi-user.target"];
            serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${holdServer pkgs}";
          };
        };
      };
    };

    testScript = ''
      import ipaddress
      import json
      import re

      ${import ../../../../tests/suite-lib.nix}
      ${import ../../../../tests/ifstate-noop.nix}

      K = "KUBECONFIG=${kubeconfig}"
      NODES = {"alpha": alpha, "beta": beta}
      SERVER4 = "198.51.100.80"
      PUBLIC4 = "${public4}"
      POOL = ipaddress.IPv6Network("${pool}")
      BETA_CLAT = "${betaClat}"
      UP = 120
      FLOWS = 150
      BGP_ALL_UP = "vtysh -c 'show bgp summary json' | jq -e '[.[] | (.peers // {}) | to_entries[] | .value.state] | length >= 3 and all(. == \"Established\")' >/dev/null"
      ips: dict[str, list[str]] = {}


      def address(text):
          parsed = ipaddress.ip_address(text.strip().strip("[]").split("%")[0])
          return getattr(parsed, "ipv4_mapped", None) or parsed


      def kubectl(args, timeout=60):
          return alpha.succeed(f"{K} timeout {timeout} kubectl {args}")


      def pod_exec(node, command, timeout=40):
          status, out = alpha.execute(f"{K} timeout {timeout} kubectl exec anchor-{node} -- {command} 2>&1")
          return status, out.strip()


      def pod_succeed(node, command, timeout=40):
          status, out = pod_exec(node, command, timeout)
          assert status == 0, f"pod on {node}: {command}: rc={status}\n{out}"
          return out


      def anchor(node):
          """A pod pinned to `node`; records its addresses."""
          overrides = json.dumps({"spec": {"nodeSelector": {"kubernetes.io/hostname": node}}})
          kubectl(f"run anchor-{node} --restart=Never --image=busybox:1.36.1 --image-pull-policy=Never --overrides='{overrides}' -- sleep 3600")
          alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready pod/anchor-{node} --timeout=60s", timeout=300)
          pod = json.loads(kubectl(f"get pod anchor-{node} -o json"))
          assert pod["spec"]["nodeName"] == node, pod["spec"]["nodeName"]
          ips[node] = [ip["ip"] for ip in pod["status"]["podIPs"]]


      def agent(node, command):
          pod = kubectl(f"-n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName={node} -o name").strip()
          return kubectl(f"-n kube-system exec {pod} -c cilium-agent -- {command}")


      def masquerade_devices(node):
          lines = [line.strip() for line in agent(node, "cilium-dbg status --verbose").splitlines() if line.strip().startswith("Masquerading:")]
          assert len(lines) == 1 and "BPF" in lines[0], lines
          print(f"FINDING {node}: {lines[0]}")
          match = re.search(r"\[([^\]]*)\]", lines[0])
          assert match is not None, lines[0]
          return sorted(device.strip() for device in match.group(1).split(","))


      def counted(chain, comment):
          rule = alpha.succeed(f"nft list chain inet nat64 {chain} | grep '{comment}'")
          match = re.search(r"counter packets (\d+)", rule)
          assert match is not None, rule
          return int(match.group(1))


      def pod_page(node):
          """The pod's IPv4 page: the source the IPv4 server saw."""
          return address(pod_succeed(node, f"wget -T 8 -qO- http://{SERVER4}/").splitlines()[-1])


      def start_flows(attempt):
          """FLOWS long flows at once from each pod and each host, all
          together; each source writes how many came back to a file."""
          for node in NODES:
              script = f"for i in $(seq {FLOWS}); do (echo hi$i | nc -w 25 {SERVER4} 9002 | grep -x hi$i >/dev/null && echo ok) & done; wait"
              alpha.succeed(
                  f"rm -f /tmp/pod-{node}.out; cat > /tmp/pod-{node}.sh <<'EOF'\n"
                  "export PATH=/run/current-system/sw/bin:$PATH\n"
                  f"{K} timeout 120 kubectl exec anchor-{node} -- sh -c '{script}' | grep -c ok > /tmp/pod-{node}.out\n"
                  "EOF"
              )
          for node in NODES:
              alpha.succeed(f"systemd-run --unit=pod-flows-{node}-{attempt} sh /tmp/pod-{node}.sh")
          for machine in NODES.values():
              machine.succeed(f"rm -f /tmp/hold.out; systemd-run --unit=hold-{attempt} -p StandardOutput=file:/tmp/hold.out python3 /etc/suite/hold.py {SERVER4} {FLOWS}")


      def flows_back(attempt):
          got = {}
          for node in NODES:
              alpha.wait_until_succeeds(f"test -s /tmp/pod-{node}.out", timeout=180)
              got[f"{node} pod"] = int(alpha.succeed(f"cat /tmp/pod-{node}.out").strip())
          for name, machine in NODES.items():
              machine.wait_until_succeeds("test -s /tmp/hold.out", timeout=180)
              got[f"{name} host"] = int(machine.succeed("cat /tmp/hold.out").strip())
          return got


      def egress_all(when):
          """alpha's pod leaves with the public IPv4 (eBPF masquerade, no
          NAT64); beta's host and pod through beta's CLAT and alpha's NAT64."""
          before = int(alpha.succeed("ip netns exec nat64 jool session display --tcp --numeric --csv --no-headers 2>/dev/null | wc -l"))
          seen = pod_page("alpha")
          assert seen == address(PUBLIC4), f"{when}: alpha's pod: the IPv4 server saw {seen}"
          seen = address(beta.succeed(f"curl -s --max-time 10 http://{SERVER4}/"))
          assert seen == address(PUBLIC4), f"{when}: beta's host: the IPv4 server saw {seen}"
          seen = pod_page("beta")
          assert seen == address(PUBLIC4), f"{when}: beta's pod: the IPv4 server saw {seen}"
          sessions = alpha.succeed("ip netns exec nat64 jool session display --tcp --numeric --csv --no-headers 2>/dev/null")
          print(f"FINDING {when}: NAT64 TCP sessions on alpha ({before} before):\n{sessions.rstrip()}")
          assert BETA_CLAT in sessions, f"{when}: beta's flows did not pass alpha's translator:\n{sessions}"


      with state_dump_on_failure(
          [alpha, beta, server4],
          extra=[
              f"{K} kubectl get nodes,pods -A -o wide",
              "nft list table inet nat64",
              "ip netns exec nat64 jool session display --tcp --numeric | tail -n 20",
              "journalctl -b --no-pager -u nat64-health -u clat-follow | tail -n 30",
          ],
      ):
          start_all()

          with subtest("versions; the gateway on alpha, the CLAT on beta"):
              server4.wait_until_succeeds("ss -tln | grep ':9002 ' >/dev/null", timeout=120)
              for machine in NODES.values():
                  machine.wait_for_unit("multi-user.target", timeout=300)
                  print_versions(machine, ["kernel", "ifstate", "jool", "${distro}", "frr"])
              for unit in ["nat64-jool.service", "nat64-health.service"]:
                  alpha.wait_for_unit(unit, timeout=120)
              for unit in ["clat.service", "clat-follow.service"]:
                  beta.wait_for_unit(unit, timeout=120)
              # a gateway is never a client (§14.5 point 5)
              alpha.fail("systemctl cat clat.service")
              alpha.fail("ip link show clat0")
              alpha.wait_until_succeeds("systemctl is-active nat64-beacon.service >/dev/null", timeout=UP + 180)
              beta.wait_until_succeeds(f"dig +short AAAA ipv4only.arpa @${underlay 1} | grep -F '{POOL[0xc00000aa]}' >/dev/null", timeout=60)

          with subtest("the cluster comes up; alpha's uplink and beta's CLAT and NIC are Cilium devices (D71)"):
              alpha.wait_for_unit("k3s.service", timeout=600)
              beta.wait_for_unit("k3s.service", timeout=600)
              alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s", timeout=900)
              alpha.wait_until_succeeds(f"{K} kubectl wait -n kube-system --for=condition=Ready pod -l k8s-app=cilium --timeout=120s", timeout=300)
              alpha.wait_until_succeeds(f"{K} kubectl get serviceaccount default", timeout=120)
              for machine in NODES.values():
                  machine.wait_until_succeeds(BGP_ALL_UP, timeout=300)
              config = json.loads(kubectl("-n kube-system get configmap cilium-config -o json"))["data"]
              devices = config["devices"].split()
              print(f"FINDING Cilium devices: {devices}")
              for name in ["eth2", "clat0", "eth1"]:
                  assert name in devices, devices
              assert config["enable-bpf-masquerade"] == "true", config
              assert "eth2" in masquerade_devices("alpha")
              print("NAT_GATEWAY_KUBE_DEVICES_OK")

          with subtest("IPv4 egress: alpha's pod by eBPF masquerade, beta's host and pod through the CLAT and alpha's NAT64"):
              for name in NODES:
                  anchor(name)
              print(f"FINDING pod addresses: {ips}")
              egress_all("first")
              print("NAT_GATEWAY_KUBE_EGRESS_OK")

          with subtest("two masquerades on one public IPv4: long flows from alpha's pod, alpha's host, beta's pod and beta's host at once all complete, twice"):
              before = alpha.succeed("conntrack -S")
              for attempt in [1, 2]:
                  start_flows(attempt)
                  # while the flows are held open: both NATs hold entries
                  alpha.wait_until_succeeds("ip netns exec nat64 jool session display --tcp --numeric --csv --no-headers | grep -c . | awk '$1 >= 100 { ok = 1 } END { exit !ok }'", timeout=60)
                  nat = agent("alpha", "cilium-dbg bpf nat list").count("\n")
                  got = flows_back(attempt)
                  print(f"FINDING round {attempt}: flows back of {FLOWS} each: {got}; Cilium NAT entries on alpha while open: {nat}")
                  assert all(count == FLOWS for count in got.values()), f"round {attempt}: {got}"
              print(f"FINDING alpha conntrack statistics before:\n{before}after:\n{alpha.succeed('conntrack -S')}")
              print("NAT_GATEWAY_KUBE_SHARED_IPV4_OK")

          with subtest("the allowlist holds on a Cilium node: a machine that is no client does not reach the translator"):
              router.succeed("ip -6 route replace 2001:db8:64::/64 via ${underlay 1}")
              target = str(POOL[int(ipaddress.IPv4Address(SERVER4))])
              before = counted("forward", "nat64-undeclared")
              router.fail(f"ping -c2 -W2 {target}")
              router.fail(f"curl -sg --max-time 4 http://[{target}]/")
              dropped = counted("forward", "nat64-undeclared") - before
              print(f"FINDING alpha dropped {dropped} packets from the router towards the translator")
              assert dropped >= 3, dropped
              before = counted("input", "beacon-undeclared")
              router.fail("dig +short +time=2 +tries=1 AAAA ipv4only.arpa @${underlay 1}")
              assert counted("input", "beacon-undeclared") == before + 1

          with subtest("a NodePort does not answer on the gateway's public IPv4 (D69)"):
              overrides = json.dumps({"spec": {"nodeSelector": {"kubernetes.io/hostname": "alpha"}}})
              kubectl(f"run web --restart=Never --image=busybox:1.36.1 --image-pull-policy=Never --overrides='{overrides}' -- httpd -f -p 8080")
              alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready pod/web --timeout=60s", timeout=300)
              kubectl("expose pod web --port=8080 --type=NodePort --name=np")
              kubectl("patch service np --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":30080}]'")
              config = json.loads(kubectl("-n kube-system get configmap cilium-config -o json"))["data"]
              print(f"FINDING Cilium nodeport-addresses: {config.get('nodeport-addresses')!r}")
              assert PUBLIC4 not in config.get("nodeport-addresses", ""), config.get("nodeport-addresses")
              code = "curl -s --max-time 4 -o /dev/null -w '%{http_code}' "
              # positive control: alpha's IPv4 node address answers from
              # beta (`expose` makes an IPv4-only Service)
              internal = [ip for ip in kubectl("get node alpha -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'").split() if ":" not in ip]
              assert internal, "alpha has no IPv4 node address"
              for ip in internal:
                  answer = beta.wait_until_succeeds(f"{code}http://{ip}:30080/ | grep -v '^000$'", timeout=60).strip()
                  print(f"FINDING the NodePort on {ip} answered beta with HTTP {answer}")
              status, answer = server4.execute(f"{code}http://{PUBLIC4}:30080/")
              print(f"FINDING the NodePort on the public IPv4 from the IPv4 internet: rc={status} code={answer!r}")
              assert answer.strip() == "000", answer
              kubectl("delete service np")
              kubectl("delete pod web --wait=false")

          with subtest("a restart of nftables, then of the gateway's Jool, on the node: the cluster's egress still works"):
              alpha.succeed("systemctl restart nftables.service")
              alpha.wait_until_succeeds(f"{K} kubectl exec anchor-beta -- wget -T 5 -qO- http://{SERVER4}/", timeout=60)
              egress_all("after an nftables restart")
              alpha.succeed("systemctl restart nat64-jool.service")
              alpha.wait_until_succeeds(f"{K} kubectl exec anchor-beta -- wget -T 5 -qO- http://{SERVER4}/", timeout=60)
              egress_all("after a Jool restart")
              assert_ifstate_noop(alpha)
              egress_all("after an IfState apply")
              alpha.succeed("systemctl is-active nat64-beacon.service")

      for machine in [alpha, beta]:
          print(f"FINDING guard drops on {machine.name} at the end of the suite: " + " | ".join(l.strip() for l in machine.succeed("nft list ruleset | awk '/^table inet (routed-fabric|kube)-/,/^}/' | grep 'counter packets [1-9]' || true").splitlines()))
      print("NAT_GATEWAY_KUBE_OK")
    '';
  }
