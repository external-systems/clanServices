# <distro>-clat-<transport>[-mapped] (specs/gateway.md G5, G23; SPEC.md
# D67): pod IPv4 egress from a two-node cluster whose NICs carry only
# IPv6, on both transports.
#
#   alpha, beta (Cilium; NIC IPv6 only; a CLAT each) ── vlan 1 ── gw (Jool
#   NAT64 in a namespace, DNS64) ── vlan 2 ── server4 (IPv4 only)
#   server6 (IPv6 only, on vlan 1): the IPv6 internet, and the machine
#   outside the cluster
#
# `transport = "fabric"`: the <distro>-data-plane topology (routed-fabric,
# FRR, per-pair WireGuard, Cilium native routing). `transport = "mesh"`:
# the <distro>-join topology (wireguard-mesh, Cilium VXLAN tunnel). One
# test script runs on both; a step that only one transport has branches
# on `FABRIC`.
#
# What the suite pins:
#   - the transport and the cluster come up on IPv6-only NICs (D67);
#   - the decided design (G5): the CLAT link `clat0` is one of Cilium's
#     `devices`, Cilium's eBPF masquerade hides pods behind 192.0.0.1,
#     and the CLAT needs only its one host mapping (G23);
#   - `mapped = true`, the documented alternative: `clat0` is not a
#     Cilium device. As shipped, pod IPv4 egress fails, because the
#     pod's own address reaches the CLAT link: this is why the design is
#     needed, and a Cilium bump that changes it must show here. Mapping
#     the cluster IPv4 pod pool into a /112 routed to the node then
#     works without state on the node;
#   - the underlay NIC is one of Cilium's `devices` too: a pod's IPv6
#     leaves with the node's NIC address. Without it (the `-mapped`
#     suites: the transport's own devices) pod IPv6 egress fails, the
#     pod's own address reaches the wire, and cluster DNS cannot reach
#     the node's resolver;
#   - the nodes have one nameserver, the gateway's DNS64, over IPv6 (G5).
#     A node fetches an IPv4-only name through DNS64 and NAT64, 2 MB: the
#     path of an image pull. A pod resolves that name through cluster
#     DNS and fetches it by name, by the synthesized address and by the
#     IPv4 literal;
#   - a NodePort answers on the node addresses, never on the NIC address;
#   - a pod on each node: a page, 2 MB down and up, ping, cluster DNS;
#     the pod network between the nodes in both families; a ClusterIP
#     Service in both families; pod to node without the CLAT masquerade;
#   - the gateway refuses a /96 destination that embeds a private IPv4
#     address (G5);
#   - one pod request to a private IPv4 address moves the gateway's
#     counter by exactly one, and nothing else ever moved it;
#   - an IfState apply leaves all of it intact; the CLAT link made again
#     under pod load on each node (how long pod egress is down, and what
#     leaves before Cilium attaches); a reboot of each node, the server
#     too.
{
  inputs,
  distro,
  transport,
  # false: the decided design, the CLAT link joins Cilium's devices and
  # Cilium's own masquerade covers it. true: the CLAT link stays out of
  # Cilium's devices and the test maps the pod pool statelessly.
  mapped ? false,
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
  nic = "eth1";
  # The underlay NIC is a Cilium device in the decided design. The
  # `-mapped` suites run on the transport's own devices, without it.
  nicDevice = !mapped;
  # The devices the transport gives Cilium (the fabric topology adds the
  # NIC itself), with or without the NIC, plus the CLAT link.
  withDevices = settings: {
    cilium.helmValues.devices = lib.concatStringsSep " " (
      lib.remove nic (lib.splitString " " (settings.cilium.helmValues.devices or "wg-mesh"))
      ++ lib.optional nicDevice nic
      ++ lib.optional (!mapped) "clat0"
    );
  };
  body =
    # the mesh topology as shipped: nothing to change
    if mapped && !fabric
    then plain
    else
      lib.recursiveUpdate plain {
        clan.inventory.instances.${distro}.roles = lib.genAttrs ["server" "agent"] (role: {
          settings = withDevices plain.clan.inventory.instances.${distro}.roles.${role}.settings;
        });
      };
  suiteName = "${distro}-clat-${transport}" + lib.optionalString mapped "-mapped";
  python = value:
    if value
    then "True"
    else "False";
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
  # the gateway's inside address: the NAT64 next hop and the DNS64
  dns64 = "2001:db8:1::64";
  server6Addr = "2001:db8:1::66";
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
      pkgs.bpftools
    ];
    # G5: an IPv6-only machine has IPv6 nameservers only. The fixture's
    # IPv4 nameserver goes; the gateway's DNS64 is the only one.
    networking.nameservers = lib.mkForce [dns64];
    services.${distro}.images = [busyboxImage];
    # a listener on the node itself: it answers with the source address
    # it saw, so the test can tell whether pod to node was masqueraded
    networking.firewall.allowedTCPPorts = [8099];
    systemd.services.echo = {
      wantedBy = ["multi-user.target"];
      serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [8099]}";
    };
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
    name = suiteName;

    clan.inventory = {
      machines = {
        gw = {};
        server4 = {};
        server6 = {};
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
          inside = ["${dns64}/64"];
          # web.test has an A record only, six.test an AAAA record only
          corefile = ''
            . {
              bind ${dns64}
              hosts {
                198.51.100.80 web.test
                ${server6Addr} six.test
              }
              dns64 {
                prefix ${pool}
              }
              errors
            }
          '';
          outside = ["198.51.100.1/24"];
          # an IPv4 default route, as a real gateway has: without one the
          # kernel drops a private destination before the firewall sees it
          routes =
            [
              {
                to = "0.0.0.0/0";
                via = "198.51.100.80";
              }
            ]
            ++ lib.mapAttrsToList (_: n: {
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

        # An IPv6-only server on the nodes' underlay: what a pod's IPv6
        # reaches without the gateway. Also the machine outside the
        # cluster that tries the NodePort.
        server6 = {pkgs, ...}: {
          imports = [base];
          virtualisation = {
            cores = 1;
            memorySize = 1024;
            vlans = [1];
          };
          environment.systemPackages = [
            pkgs.curl
            pkgs.tcpdump
          ];
          networking = {
            firewall.enable = false;
            ifstate.settings.interfaces.eth1 = phys ["${server6Addr}/64"];
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
      import re

      ${import ../../../../tests/suite-lib.nix}
      ${import ../../../../tests/ifstate-noop.nix}

      K = "KUBECONFIG=${kubeconfig}"
      FABRIC = ${python fabric}
      MAPPED = ${python mapped}
      # the underlay NIC is one of Cilium's devices
      NIC_DEVICE = ${python nicDevice}
      NODES = {"alpha": alpha, "beta": beta}
      UNITS = {"alpha": "${serverUnit}", "beta": "${agentUnit}"}
      NIC6 = {"alpha": "${underlay 1}", "beta": "${underlay 2}"}
      DNS64 = "${dns64}"
      SERVER6 = "${server6Addr}"
      # an A record only, an AAAA record only (the gateway's DNS64)
      NAME4 = "web.test"
      NAME6 = "six.test"
      NODEPORT = 30080
      # Seconds, about three times the largest sample of 2026-11-22 (the
      # FINDING lines print each run's): Cilium attached to a new clat0
      # after at most 16.4 s; pod IPv4 egress was down for at most 18.2 s
      # when the link was made again; with Cilium attached, the first pod
      # page took at most 1.0 s.
      ATTACH_LIMIT = 50
      SETTLE_LIMIT = 20
      DOWN_LIMIT = 60
      CLAT6 = {"alpha": "${clatAddr 1}", "beta": "${clatAddr 2}"}
      MAPS = {"alpha": "${podMap 1}", "beta": "${podMap 2}"}
      SERVER4 = "198.51.100.80"
      # the IPv4 server as the DNS64 synthesizes it
      SYNTH = ipaddress.ip_network("${pool}")[int(ipaddress.ip_address(SERVER4))]
      PUBLIC4 = "198.51.100.1"
      CLAT4 = "192.0.0.1"
      IFSTATE_OK = "systemctl show -p Result --value ifstate.service | grep '^success$' >/dev/null"
      # every fabric and upstream session; Cilium's own session to the local
      # FRR (::1) only exists once the cluster runs
      BGP_FABRIC_UP = "vtysh -c 'show bgp summary json' | jq -e '[.[] | (.peers // {}) | to_entries[] | select(.key | test(\"^(::1|127[.]0[.]0[.]1)$\") | not) | .value.state] | length >= 2 and all(. == \"Established\")' >/dev/null"
      BGP_ALL_UP = "vtysh -c 'show bgp summary json' | jq -e '[.[] | (.peers // {}) | to_entries[] | .value.state] | length >= 3 and all(. == \"Established\")' >/dev/null"
      ips: dict[str, list[str]] = {}


      def address(text):
          """An address as the peer printed it: no brackets, no IPv4-mapped form."""
          parsed = ipaddress.ip_address(str(text).strip().strip("[]"))
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


      def pod_wait(node, command, timeout=120):
          return alpha.wait_until_succeeds(f"{K} timeout 20 kubectl exec anchor-{node} -- {command}", timeout=timeout).strip()


      def anchor(node):
          """A pod pinned to `node`; records its addresses."""
          overrides = json.dumps({"spec": {"nodeSelector": {"kubernetes.io/hostname": node}}})
          kubectl(f"run anchor-{node} --restart=Never --image=busybox:1.36.1 --image-pull-policy=Never --overrides='{overrides}' -- sleep 3600")
          alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready pod/anchor-{node} --timeout=60s", timeout=300)
          pod = json.loads(kubectl(f"get pod anchor-{node} -o json"))
          assert pod["spec"]["nodeName"] == node, pod["spec"]["nodeName"]
          ips[node] = [ip["ip"] for ip in pod["status"]["podIPs"]]
          families = sorted(address(ip).version for ip in ips[node])
          assert families == [4, 6], f"the pod on {node} is not dual-stack: {ips[node]}"


      def pod_v4(node):
          return next(ip for ip in ips[node] if ":" not in ip)


      def pod_v6(node):
          return next(ip for ip in ips[node] if ":" in ip)


      def addresses_in(text):
          """Every word of `text` that is an IP address."""
          found = set()
          for token in text.split():
              try:
                  found.add(address(token))
              except ValueError:
                  pass
          return found


      def uptime(machine):
          return float(machine.succeed("cut -d' ' -f1 /proc/uptime"))


      def pod_network(when):
          for source, target in [("alpha", "beta"), ("beta", "alpha")]:
              for target_address in ips[target]:
                  status, out = pod_exec(source, f"ping -c2 -W3 {target_address}")
                  assert status == 0, f"{when}: the pod on {source} does not reach the pod on {target} at {target_address}:\n{out}"


      def agent_pod(node):
          return kubectl(f"-n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName={node} -o name").strip()


      def agent(node, command):
          return kubectl(f"-n kube-system exec {agent_pod(node)} -c cilium-agent -- {command}")


      def masquerade_devices(node):
          """The devices of the "Masquerading: BPF [a, b]" line of the node's agent."""
          lines = [line.strip() for line in agent(node, "cilium-dbg status --verbose").splitlines() if line.strip().startswith("Masquerading:")]
          assert len(lines) == 1 and "BPF" in lines[0], lines
          match = re.search(r"\[([^\]]*)\]", lines[0])
          assert match is not None, lines[0]
          print(f"FINDING {node}: {lines[0]}")
          return sorted(device.strip() for device in match.group(1).split(","))


      def assert_cilium_on_clat(node, when):
          """`clat0` is a Cilium device exactly in the decided design."""
          devices = masquerade_devices(node)
          show = f"{K} timeout 20 kubectl -n kube-system exec {agent_pod(node)} -c cilium-agent -- bpftool net show dev clat0"
          if not MAPPED:
              # the agent lists a device before its loader has attached the
              # programs (seen 2026-11-21: Ready agent, empty `tc:` section)
              waited = seconds_until(alpha, f"{show} | grep cil_to_netdev", limit=ATTACH_LIMIT)
              print(f"FINDING {node}: {when}: Cilium attached to clat0 after {waited} s")
              assert waited is not None, f"{node}: {when}: Cilium did not attach to clat0 in {ATTACH_LIMIT} s"
          programs = alpha.succeed(show)
          print(f"FINDING {node}: {when}: BPF programs on clat0:\n{programs.rstrip()}")
          if MAPPED:
              assert "clat0" not in devices, f"{node}: {when}: clat0 is a masquerade device: {devices}"
              assert "cil_" not in programs, f"{node}: {when}: Cilium is attached to clat0:\n{programs}"
          else:
              assert "clat0" in devices, f"{node}: {when}: clat0 is not a masquerade device: {devices}"
              assert "cil_to_netdev" in programs, f"{node}: {when}: Cilium is not attached to clat0:\n{programs}"


      def host_v4(machine, when):
          """The node's own IPv4 traffic leaves through its CLAT."""
          out = machine.wait_until_succeeds(f"curl -s --max-time 5 http://{SERVER4}/", timeout=120)
          assert address(out) == address(PUBLIC4), f"{machine.name}: {when}: the IPv4 server saw {out!r}"
          assert "inet " not in machine.succeed("ip -4 -br addr show dev eth1"), f"{machine.name}: {when}: the NIC has an IPv4 address"
          # the CLAT unit's route, with the MTU the translation needs
          routes = machine.succeed("ip -4 route show default").strip().splitlines()
          assert len(routes) == 1 and routes[0].startswith("default via 192.0.0.2 dev clat0 ") and routes[0].rstrip().endswith(" mtu 1480"), f"{machine.name}: {when}: IPv4 default route: {routes}"


      def assert_nameservers(node, when):
          """G5: the node's only nameserver is the gateway's DNS64, over IPv6."""
          machine = NODES[node]
          upstream = [line.split()[1] for line in machine.succeed("cat /run/systemd/resolve/resolv.conf").splitlines() if line.startswith("nameserver")]
          assert upstream == [DNS64], f"{node}: {when}: the resolver's upstream nameservers: {upstream}"
          # what a program on the node reads: the local stub of systemd-resolved
          stub = [line.split()[1] for line in machine.succeed("cat /etc/resolv.conf").splitlines() if line.startswith("nameserver")]
          assert all(address(entry).is_loopback for entry in stub), f"{node}: {when}: /etc/resolv.conf: {stub}"
          listed = []
          for line in machine.succeed("resolvectl dns").splitlines():
              listed += [found for token in line.partition(":")[2].split() for found in addresses_in(token.split("%")[0].split("#")[0])]
          print(f"FINDING {node}: {when}: nameservers: upstream {upstream}, /etc/resolv.conf {stub}, resolvectl {[str(entry) for entry in listed]}")
          assert listed and set(listed) == {address(DNS64)}, f"{node}: {when}: resolvectl lists {listed}"


      def host_names(node, when):
          """The node resolves an IPv4-only name at the DNS64 and fetches it
          over IPv6 through the NAT64, 2 MB: the path an image pull takes."""
          machine = NODES[node]
          capture_start(gw, "eth1", "inside")
          seen = machine.wait_until_succeeds(f"curl -6 -s --max-time 10 http://{NAME4}/", timeout=60)
          assert address(seen) == address(PUBLIC4), f"{node}: {when}: the IPv4 server saw {seen!r}"
          at_gateway = capture_stop(gw, "inside", NIC6[node])
          assert at_gateway["IP6"] == {address(NIC6[node])}, f"{node}: {when}: sources at the gateway: {at_gateway['IP6']}, expected {NIC6[node]}"
          remote, size = machine.succeed(f"curl -6 -s --max-time 30 -o /dev/null -w '%{{remote_ip}} %{{size_download}}' http://{NAME4}/big").split()
          assert address(remote) == SYNTH and size == "2000000", f"{node}: {when}: 2 MB by name: {size} bytes from {remote}"
          default = machine.succeed(f"curl -s --max-time 10 -o /dev/null -w '%{{remote_ip}}' http://{NAME4}/").strip()
          print(f"FINDING {node}: {when}: with no family forced, the node fetched {NAME4} from {default}")


      def capture_start(machine, link, tag, expression="tcp dst port 80", options=""):
          machine.succeed(
              f"systemctl stop capture-{tag}.service 2>/dev/null || true; rm -f /tmp/{tag}.txt /tmp/{tag}.err; "
              f"systemd-run --quiet --collect --unit=capture-{tag} -p StandardOutput=file:/tmp/{tag}.txt -p StandardError=file:/tmp/{tag}.err "
              f"tcpdump -i {link} -n -l {options} {expression}"
          )
          machine.wait_until_succeeds(f"grep listening /tmp/{tag}.err >/dev/null", timeout=30)


      def capture_stop(machine, tag, wanted):
          """Wait until the capture has a SYN (from `wanted`, if given); return the SYN sources per family."""
          pattern = f"IP6? {re.escape(wanted)}[.][0-9]+ > .*Flags \\[S\\]" if wanted else "Flags \\[S\\]"
          machine.wait_until_succeeds(f"grep -E '{pattern}' /tmp/{tag}.txt >/dev/null", timeout=30)
          machine.succeed(f"systemctl stop capture-{tag}.service")
          text = machine.succeed(f"cat /tmp/{tag}.txt")
          sources = {"IP": set(), "IP6": set()}
          for line in text.splitlines():
              match = re.search(r" (IP6?) (\S+)\.\d+ > \S+\.80: Flags \[S\]", line)
              if match is not None:
                  sources[match.group(1)].add(address(match.group(2)))
          print(f"FINDING {machine.name}: SYN sources on the capture {tag}: {sources}\n{text.rstrip()}")
          return sources


      def page(node):
          status, out = pod_exec(node, f"wget -T 8 -qO- http://{SERVER4}/")
          works = status == 0 and out != "" and address(out.splitlines()[-1]) == address(PUBLIC4)
          return works, out


      def egress(node, works, v4, v6, when):
          """One page from the pod on `node`, and the sources it had on the
          CLAT link (IPv4 before, IPv6 after the translation) and at the gateway."""
          machine = NODES[node]
          capture_start(machine, "clat0", "clat")
          capture_start(gw, "eth1", "inside")
          worked, out = page(node)
          print(f"FINDING {node}: pod IPv4 egress, {when}: {'works' if worked else 'FAILS'}: {out}")
          on_link = capture_stop(machine, "clat", str(v6))
          assert worked == works, f"{node}: {when}: pod IPv4 egress {'works' if worked else 'fails'}: {out}"
          assert on_link["IP"] == {address(v4)}, f"{node}: {when}: IPv4 sources on the CLAT link: {on_link['IP']}, expected {v4}"
          assert on_link["IP6"] == {address(v6)}, f"{node}: {when}: IPv6 sources on the CLAT link: {on_link['IP6']}, expected {v6}"
          if works:
              at_gateway = capture_stop(gw, "inside", str(v6))
              assert at_gateway["IP6"] == {address(v6)}, f"{node}: {when}: sources at the gateway: {at_gateway['IP6']}, expected {v6}"
          else:
              gw.succeed("systemctl stop capture-inside.service")


      def egress_settles(node, when):
          """Bounded: the seconds until the first page from the pod on `node`."""
          waited = seconds_until(alpha, f"{K} timeout 10 kubectl exec anchor-{node} -- wget -T 3 -qO- http://{SERVER4}/", limit=SETTLE_LIMIT)
          print(f"FINDING {node}: {when}: first pod IPv4 page after {waited} s")
          assert waited is not None, f"{node}: {when}: no pod IPv4 page in {SETTLE_LIMIT} s"


      def v6_egress(node, when):
          """One page from the pod on `node` at the IPv6 server, by address."""
          capture_start(server6, "eth1", "six")
          status, out = pod_exec(node, f"wget -T 5 -qO- http://[{SERVER6}]/", timeout=20)
          worked = status == 0 and out != ""
          print(f"FINDING {node}: pod IPv6 egress, {when}: {'works' if worked else 'FAILS'}: {out}")
          if NIC_DEVICE:
              assert worked, f"{node}: {when}: pod IPv6 egress fails: {out}"
              assert address(out.splitlines()[-1]) == address(NIC6[node]), f"{node}: {when}: the IPv6 server saw {out!r}, expected {NIC6[node]}"
              on_wire = capture_stop(server6, "six", NIC6[node])
              assert on_wire["IP6"] == {address(NIC6[node])}, f"{node}: {when}: sources at the IPv6 server: {on_wire['IP6']}"
          else:
              # FINDING: eBPF masquerade covers only Cilium's devices. The
              # NIC is not one, so the pod's own address is on the wire and
              # no reply can return.
              assert not worked, f"{node}: {when}: pod IPv6 egress works without the NIC in Cilium's devices: {out}"
              on_wire = capture_stop(server6, "six", pod_v6(node))
              assert on_wire["IP6"] == {address(pod_v6(node))}, f"{node}: {when}: sources at the IPv6 server: {on_wire['IP6']}"


      def pod_names(node, when):
          """External names from the pod on `node`: cluster DNS forwards to
          the node's resolver, the gateway's DNS64."""
          status, answer = pod_exec(node, f"nslookup -type=aaaa {NAME4}", timeout=60)
          found = addresses_in(answer)
          print(f"FINDING {node}: {when}: the pod asked cluster DNS for the AAAA of {NAME4}: rc={status}\n{answer}")
          if not NIC_DEVICE:
              # FINDING: cluster DNS is a pod. Its queries to the node's
              # IPv6 nameserver leave with a pod address and get no answer.
              assert SYNTH not in found, f"{node}: {when}: cluster DNS reached the DNS64 without the NIC in Cilium's devices:\n{answer}"
              status, out = pod_exec(node, f"wget -T 5 -qO- http://{NAME4}/", timeout=60)
              assert status != 0, f"{node}: {when}: the pod fetched {NAME4} without the NIC in Cilium's devices: {out}"
              return
          assert status == 0 and SYNTH in found, f"{node}: {when}: no synthesized AAAA for {NAME4}:\n{answer}"
          # by the synthesized address: pod IPv6, masqueraded to the NIC
          # address, straight to the NAT64 (no CLAT)
          capture_start(gw, "eth1", "inside")
          out = pod_succeed(node, f"wget -T 8 -qO- http://[{SYNTH}]/")
          assert address(out.splitlines()[-1]) == address(PUBLIC4), f"{node}: {when}: the IPv4 server saw {out!r}"
          at_gateway = capture_stop(gw, "inside", NIC6[node])
          assert at_gateway["IP6"] == {address(NIC6[node])}, f"{node}: {when}: sources at the gateway: {at_gateway['IP6']}, expected {NIC6[node]}"
          # by name: the pod's resolver picks the family
          capture_start(gw, "eth1", "inside")
          out = pod_succeed(node, f"wget -T 8 -qO- http://{NAME4}/")
          assert address(out.splitlines()[-1]) == address(PUBLIC4), f"{node}: {when}: the IPv4 server saw {out!r}"
          at_gateway = capture_stop(gw, "inside", "")
          paths = {str(address(NIC6[node])): "IPv6 and the DNS64 address", str(address(expected_sources(node)[1])): "IPv4 and the CLAT"}
          taken = sorted(paths.get(str(source), f"unexpected source {source}") for source in at_gateway["IP6"])
          print(f"FINDING {node}: {when}: the pod fetched {NAME4} by name over: {taken}")
          assert taken and all(not path.startswith("unexpected") for path in taken), f"{node}: {when}: {taken}"
          out = pod_succeed(node, f"wget -T 8 -qO- http://{NAME6}/")
          assert address(out.splitlines()[-1]) == address(NIC6[node]), f"{node}: {when}: the IPv6 server saw {out!r} for {NAME6}"


      def expected_sources(node):
          """The sources a working pod request has, per variant."""
          if MAPPED:
              low = int(address(pod_v4(node))) & 0xFFFF
              return pod_v4(node), ipaddress.ip_network(MAPS[node])[low]
          return CLAT4, CLAT6[node]


      def traffic(node):
          down = pod_succeed(node, f"sh -c 'wget -T 20 -qO- http://{SERVER4}/big | wc -c'", 60)
          assert down == "2000000", f"{node}: 2 MB down delivered {down} bytes"
          up = pod_succeed(node, f"sh -c 'yes | head -c 2000000 > /tmp/up; wget -T 20 -qO- --post-file=/tmp/up http://{SERVER4}/'", 60)
          assert up == "2000000", f"{node}: 2 MB up delivered {up} bytes"
          pod_succeed(node, f"ping -c2 -W2 {SERVER4}")
          answer = pod_succeed(node, "nslookup kubernetes.default.svc.cluster.local")
          assert "Name:" in answer and "kubernetes.default.svc.cluster.local" in answer, answer


      def jool_stats(machine, command):
          lines = machine.succeed(f"{command} stats display").splitlines()
          pairs = (line.rpartition(":") for line in lines if ":" in line)
          return {key.strip(): int(value) for key, _, value in pairs if value.strip().isdigit()}


      def moved(before, after):
          return {key: value - before.get(key, 0) for key, value in after.items() if value != before.get(key, 0)}


      def private_refused():
          """Packets the gateway's firewall refused: a private IPv4 destination."""
          rule = gw.succeed("nft list ruleset | grep nat64-private")
          match = re.search(r"counter packets (\d+)", rule)
          assert match is not None, rule
          return int(match.group(1))


      def agent_runs(node):
          """A shell test: the Cilium agent on `node` answers. It looks the
          pod up itself, so it can wait for an API server that is down."""
          find = f"{K} kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName={node} -o name"
          return f"{K} timeout 30 kubectl -n kube-system exec $({find}) -c cilium-agent -- cilium-dbg status --brief"


      def remake(node):
          """Delete the CLAT link of `node` and let IfState make it again,
          while the pod on `node` requests an IPv4 page five times a second."""
          machine = NODES[node]
          pod4 = address(pod_v4(node))
          pod_exec(node, "rm -f /tmp/stop")
          loop = (
              f"while [ ! -e /tmp/stop ]; do read t rest < /proc/uptime; "
              f"if wget -T 1 -qO- http://{SERVER4}/ >/dev/null 2>&1; then echo \"$t ok\"; else echo \"$t fail\"; fi; usleep 200000; done"
          )
          recovered = "tail -n 3 /tmp/loop.txt | grep -c ' ok$' | grep -x 3 >/dev/null"
          capture_start(machine, "any", "remake", expression=f"tcp dst port 80 and dst host {SERVER4}", options="-tt")
          capture_start(gw, "eth1", "remake-gw")
          alpha.succeed(
              "systemctl stop pod-loop.service 2>/dev/null || true; rm -f /tmp/loop.txt; "
              f"systemd-run --quiet --collect --unit=pod-loop -E {K} -p StandardOutput=file:/tmp/loop.txt kubectl exec anchor-{node} -- sh -c '{loop}'"
          )
          alpha.wait_until_succeeds(recovered, timeout=30)
          epoch, up = machine.succeed("echo $(date +%s.%N) $(cut -d' ' -f1 /proc/uptime)").split()
          offset = float(epoch) - float(up)
          index = machine.succeed("cat /sys/class/net/clat0/ifindex").strip()

          deleted = uptime(machine)
          machine.succeed("ip link delete clat0; systemctl reset-failed ifstate.service; systemctl restart ifstate.service")
          made = uptime(machine)
          assert machine.succeed("cat /sys/class/net/clat0/ifindex").strip() != index, f"{node}: clat0 is the old link"
          waited = seconds_until(machine, "bpftool net show dev clat0 | grep cil_to_netdev", limit=ATTACH_LIMIT, interval=0.2)
          attached = uptime(machine)
          assert waited is not None, f"{node}: Cilium did not attach to the new clat0 in {ATTACH_LIMIT} s"
          alpha.wait_until_succeeds(recovered, timeout=DOWN_LIMIT)
          pod_exec(node, "touch /tmp/stop")
          alpha.succeed("systemctl stop pod-loop.service 2>/dev/null || true")
          machine.succeed("systemctl stop capture-remake.service")
          at_gateway = capture_stop(gw, "remake-gw", CLAT6[node])["IP6"]

          requests = [(float(line.split()[0]), line.split()[1]) for line in alpha.succeed("cat /tmp/loop.txt").splitlines() if len(line.split()) == 2]
          fails = [at for at, state in requests if state == "fail"]
          assert not [at for at in fails if at < deleted - 2], f"{node}: pod requests failed before the link was deleted: {requests}"
          assert fails, f"{node}: no pod request failed while the CLAT link was gone"
          back = min(at for at, state in requests if state == "ok" and at > max(fails))
          early = [at for at, state in requests if state == "ok" and made < at < attached - 1]
          print(
              f"FINDING {node}: CLAT link made again under pod load: the link was away for {made - deleted:.1f} s; "
              f"Cilium attached {attached - made:.1f} s after the link was back; "
              f"pod IPv4 egress was down for {back - deleted:.1f} s ({len(fails)} failed requests), "
              f"and worked {back - attached:.1f} s after Cilium attached; "
              f"{len(early)} requests succeeded on the new link before Cilium attached"
          )
          assert back - deleted <= DOWN_LIMIT, f"{node}: pod IPv4 egress was down for {back - deleted:.1f} s"

          # what left on the CLAT link, by source
          sent: dict[str, list[float]] = {}
          capture = machine.succeed("cat /tmp/remake.txt")
          for line in capture.splitlines():
              match = re.search(r"^(\d+\.\d+) clat0\s+Out\s+IP (\S+)\.\d+ > \S+\.80: Flags \[S\]", line)
              if match is not None:
                  sent.setdefault(match.group(2), []).append(float(match.group(1)) - offset)
          for source, times in sent.items():
              after_link = [at - made for at in times if at >= made]
              print(
                  f"FINDING {node}: SYNs on clat0 from {source}: {len(times)}, {len(after_link)} of them on the new link"
                  + (f", {after_link[0]:.1f} s to {after_link[-1]:.1f} s after it was back (Cilium attached at {attached - made:.1f} s)" if after_link else "")
              )
          leaked = sent.get(str(pod4), [])
          print(f"FINDING {node}: pre-attach window: {len(leaked)} SYNs left on clat0 with the pod's own address {pod4}; sources at the gateway: {sorted(str(source) for source in at_gateway)}")
          assert CLAT4 in sent and set(sent) <= {CLAT4, str(pod4)}, f"{node}: sources on clat0: {sorted(sent)}\n{capture}"
          # FINDING (G5 "Cilium attaches late"): until Cilium attaches to the
          # new link, pod packets leave on it with the pod's own address.
          # The CLAT embeds that address in the NAT64 prefix, which is not
          # a source the gateway forwards. A Cilium that closes the window
          # must show here.
          assert leaked, f"{node}: no SYN left clat0 with the pod's address before Cilium attached:\n{capture}"
          assert not early, f"{node}: pod requests succeeded before Cilium attached: {early}"
          assert all(at < attached + 1 for at in leaked), f"{node}: a SYN left with the pod's address after Cilium attached: {[at - made for at in leaked]}, attached at {attached - made:.1f}"
          # the translated pod address is not a source the gateway forwards
          embedded = ipaddress.ip_network("${pool}")[int(pod4)]
          assert at_gateway <= {address(CLAT6[node]), embedded}, f"{node}: sources at the gateway: {at_gateway}"

          machine.wait_for_unit("clat.service", timeout=60)
          host_v4(machine, "after the CLAT link was made again")
          assert_cilium_on_clat(node, "after the CLAT link was made again")
          egress(node, True, CLAT4, CLAT6[node], "after the CLAT link was made again")
          v6_egress(node, "after the CLAT link was made again")
          pod_network("after the CLAT link was made again")


      def reboot(node):
          machine = NODES[node]
          unit = UNITS[node]
          kubectl(f"delete pod anchor-{node} --force --grace-period=0")
          machine.shutdown()
          machine.start()
          machine.wait_for_unit("multi-user.target", timeout=900)
          machine.wait_until_succeeds(IFSTATE_OK, timeout=120)
          machine.wait_for_unit("clat.service", timeout=120)
          host_v4(machine, "after the reboot")
          assert_nameservers(node, "after the reboot")
          host_names(node, "after the reboot")
          machine.wait_for_unit(f"{unit}.service", timeout=600)
          # an exec only works once the rebooted kubelet runs the agent again
          alpha.wait_until_succeeds(agent_runs(node), timeout=600)
          alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready node/alpha node/beta --timeout=60s", timeout=300)
          alpha.wait_until_succeeds(f"{K} kubectl get serviceaccount default", timeout=120)
          observe(
              f"{node}: unit order after the reboot (monotonic microseconds)",
              machine,
              f"for unit in ifstate clat {unit}; do echo $unit $(systemctl show -p ActiveEnterTimestampMonotonic --value $unit.service); done; "
              f"journalctl -b --no-pager -u {unit}.service | grep -m1 -i 'cilium\\|Running kubelet' || true",
          )
          observe(f"{node}: the agent's own words about its devices", alpha, f"{K} kubectl -n kube-system logs {agent_pod(node)} -c cilium-agent | grep -i 'clat0' | head -n 8")
          if FABRIC:
              for peer in NODES.values():
                  peer.wait_until_succeeds(BGP_ALL_UP, timeout=300)
          assert_cilium_on_clat(node, "after the reboot")
          anchor(node)
          egress_settles(node, "after the reboot")
          egress(node, True, CLAT4, CLAT6[node], "after the reboot")
          traffic(node)
          v6_egress(node, "after the reboot")
          pod_names(node, "after the reboot")
          host_v4(machine, "after the reboot, with Cilium up")
          pod_network("after the reboot")


      with state_dump_on_failure(
          list(machines),
          extra=[
              f"{K} kubectl get nodes,pods,services -A -o wide",
              "wg show all endpoints",
              "vtysh -c 'show bgp summary'",
              "ip netns exec clat jool_siit -i clat eamt display",
              "journalctl -b --no-pager -u clat.service | tail -n 20",
          ],
      ):
          start_all()

          # every translated packet to a private IPv4 destination, from the
          # first one on: who sent what the gateway refuses
          gw.wait_for_unit("jool-netns.service", timeout=300)
          capture_start(gw, "j0", "private", expression="ip and not dst host 10.64.0.2 and '(dst net 10.0.0.0/8 or dst net 100.64.0.0/10 or dst net 169.254.0.0/16 or dst net 172.16.0.0/12 or dst net 192.168.0.0/16)'", options="-Q in")

          with subtest("versions"):
              for machine in [gw, server4]:
                  machine.wait_for_unit("multi-user.target", timeout=300)
              for machine in NODES.values():
                  machine.wait_until_succeeds(IFSTATE_OK, timeout=300)
                  if FABRIC:
                      machine.wait_for_unit("frr.service", timeout=240)
                  print_versions(machine, ["kernel", "ifstate", "jool", "wireguard", "${distro}"] + (["frr"] if FABRIC else []))
              print_versions(gw, ["kernel", "ifstate", "jool", "nftables"])

          with subtest("the gateway and the IPv4 server are up"):
              gw.wait_for_unit("jool-netns.service", timeout=60)
              gw.wait_for_unit("coredns.service", timeout=60)
              print_versions(gw, ["coredns"])
              for server in [server4, server6]:
                  server.wait_until_succeeds("ss -tln | grep ':80 ' >/dev/null", timeout=60)

          with subtest("each node has no IPv4 on its NIC and reaches IPv4 through its own CLAT (G23)"):
              for name, machine in NODES.items():
                  machine.wait_until_succeeds(IFSTATE_OK, timeout=120)
                  machine.wait_for_unit("clat.service", timeout=120)
                  host_v4(machine, "before the cluster")
                  mappings = machine.succeed("ip netns exec clat jool_siit -i clat eamt display --csv --no-headers").strip().splitlines()
                  assert len(mappings) == 1 and CLAT4 in mappings[0], f"{name}: the CLAT has more than its host mapping: {mappings}"
              print("CLAT_HOST_OK")

          with subtest("each node has one nameserver, the gateway's DNS64 over IPv6, and fetches an IPv4-only name through NAT64, 2 MB (G5; the path of an image pull)"):
              for name in NODES:
                  assert_nameservers(name, "before the cluster")
                  observe(f"{name}: resolvectl status", NODES[name], "resolvectl status | head -n 12")
                  host_names(name, "before the cluster")
              print("CLAT_HOST_NAMES_OK")

          with subtest("the transport comes up over IPv6 endpoints (D67)"):
              for name, machine in NODES.items():
                  machine.wait_until_succeeds("wg show all latest-handshakes | awk '$3 > 0 { ok = 1 } END { exit !ok }'", timeout=180)
                  endpoints = [line.split()[-1] for line in machine.succeed("wg show all endpoints").strip().splitlines()]
                  print(f"FINDING {name}: WireGuard endpoints: {endpoints}")
                  assert endpoints and all(endpoint.startswith("[2001:db8:1::") for endpoint in endpoints), f"{name}: a WireGuard endpoint is not an IPv6 underlay address: {endpoints}"
                  if FABRIC:
                      machine.wait_for_unit("frr.service", timeout=240)
                      machine.wait_until_succeeds(BGP_FABRIC_UP, timeout=180)
                      observe(f"{name}: BGP sessions", machine, "vtysh -c 'show bgp summary' | tail -n 14")
              print("CLAT_TRANSPORT_V6_OK")

          with subtest("the cluster comes up on IPv6-only NICs (D67)"):
              alpha.wait_for_unit("${serverUnit}.service", timeout=600)
              beta.wait_for_unit("${agentUnit}.service", timeout=600)
              alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s", timeout=900)
              alpha.wait_until_succeeds(f"{K} cilium status", timeout=300)
              alpha.wait_until_succeeds(f"{K} kubectl wait -n kube-system --for=condition=Ready pod -l k8s-app=cilium --timeout=120s", timeout=300)
              alpha.wait_until_succeeds(f"{K} kubectl get serviceaccount default", timeout=120)
              if FABRIC:
                  for machine in NODES.values():
                      machine.wait_until_succeeds(BGP_ALL_UP, timeout=300)

          with subtest("Cilium: the routing mode of the transport; clat0 is a masquerade device only in the decided design (G5)"):
              config = json.loads(kubectl("-n kube-system get configmap cilium-config -o json"))["data"]
              print("FINDING Cilium datapath settings: " + str({key: value for key, value in config.items() if re.search("device|native-routing|masq|routing-mode|tunnel-protocol", key)}))
              print("VERSION alpha cilium: " + agent("alpha", "cilium-dbg version").strip().replace("\n", " "))
              assert config["routing-mode"] == ("native" if FABRIC else "tunnel"), config["routing-mode"]
              assert config["enable-bpf-masquerade"] == "true" and config["enable-ipv4-masquerade"] == "true", config
              assert ("clat0" in config["devices"].split()) != MAPPED, config["devices"]
              assert ("${nic}" in config["devices"].split()) == NIC_DEVICE, config["devices"]
              for name in NODES:
                  routing = [line.strip() for line in agent(name, "cilium-dbg status --verbose").splitlines() if line.strip().startswith("Routing:")]
                  print(f"FINDING {name}: {routing}")
                  assert len(routing) == 1 and ("Native" if FABRIC else "Tunnel [vxlan]") in routing[0], routing
                  assert_cilium_on_clat(name, "after the cluster came up")

          with subtest("the node's own IPv4 traffic still works with Cilium up"):
              for machine in NODES.values():
                  host_v4(machine, "with Cilium up")
                  observe(f"{machine.name}: IPv4 routes", machine, "ip -4 route")
              for name in NODES:
                  host_names(name, "with Cilium up")
              print("CLAT_HOST_WITH_CILIUM_OK")

          with subtest("a pod on each node; the pod network between the nodes, both families"):
              for name in NODES:
                  anchor(name)
              print(f"FINDING pod addresses: {ips}")
              pod_network("before any pod IPv4 egress")
              print("CLAT_POD_NETWORK_OK")

          if MAPPED:
              with subtest("as shipped, pod IPv4 egress fails: the pod's own address reaches the CLAT link (why G5 is needed)"):
                  for name in NODES:
                      # the CLAT has no mapping for the pod, so Jool embeds the
                      # pod's address in the NAT64 prefix: no reply can return
                      embedded = ipaddress.ip_network("${pool}")[int(address(pod_v4(name)))]
                      egress(name, False, pod_v4(name), embedded, "as shipped")
                  print("CLAT_UNMAPPED_FAILS_OK")

              with subtest("the stateless pod pool mapping (G5, the documented alternative)"):
                  pod_pool = ".".join(pod_v4("alpha").split(".")[:2]) + ".0.0/16"
                  for name, machine in NODES.items():
                      assert address(pod_v4(name)) in ipaddress.ip_network(pod_pool), f"{pod_v4(name)} is outside {pod_pool}"
                      machine.succeed(f"ip netns exec clat jool_siit -i clat eamt add {MAPS[name]} {pod_pool}")

          with subtest("pods reach an IPv4 address: a page with its source, 2 MB down and up, ping, cluster DNS (G5)"):
              for name in NODES:
                  v4, v6 = expected_sources(name)
                  egress_settles(name, "first request")
                  egress(name, True, v4, v6, "first request")
                  traffic(name)
                  observe(f"{name}: CLAT statistics", NODES[name], "ip netns exec clat jool_siit -i clat stats display | head -n 12")
              pod_network("after pod IPv4 egress")
              observe("gateway conntrack", gw, f"conntrack -L 2>/dev/null | grep {SERVER4} | head -6")
              print("CLAT_POD_EGRESS_OK")

          with subtest(
              "pod IPv6 egress: the IPv6 server sees the node's NIC address"
              if NIC_DEVICE
              else "without the NIC in Cilium's devices, pod IPv6 egress fails: the pod's own address is on the wire"
          ):
              for name in NODES:
                  v6_egress(name, "first request")
              print("CLAT_POD_V6_EGRESS_OK")

          with subtest(
              "pods resolve external names through cluster DNS and the DNS64, and fetch an IPv4-only name by name and by its synthesized address"
              if NIC_DEVICE
              else "without the NIC in Cilium's devices, cluster DNS cannot reach the node's IPv6 nameserver"
          ):
              for name in NODES:
                  pod_names(name, "first request")
              print("CLAT_POD_NAMES_OK")

          with subtest("a ClusterIP Service works from pods in both families, with the pod's own source"):
              who = "mkdir -p /www/cgi-bin; echo '#!/bin/sh' > /www/cgi-bin/who; echo 'echo; echo $REMOTE_ADDR' >> /www/cgi-bin/who; chmod +x /www/cgi-bin/who; exec httpd -f -p 8080 -h /www"
              manifest = {
                  "apiVersion": "v1",
                  "kind": "List",
                  "items": [
                      {
                          "apiVersion": "v1",
                          "kind": "Pod",
                          "metadata": {"name": "web", "labels": {"app": "web"}},
                          "spec": {
                              "nodeSelector": {"kubernetes.io/hostname": "beta"},
                              "restartPolicy": "Never",
                              "containers": [{"name": "web", "image": "busybox:1.36.1", "imagePullPolicy": "Never", "command": ["sh", "-c", who]}],
                          },
                      },
                      {
                          "apiVersion": "v1",
                          "kind": "Service",
                          "metadata": {"name": "web"},
                          "spec": {"ipFamilyPolicy": "RequireDualStack", "selector": {"app": "web"}, "ports": [{"port": 8080}]},
                      },
                  ],
              }
              alpha.succeed(f"{K} kubectl apply -f - <<'EOF'\n{json.dumps(manifest)}\nEOF")
              alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready pod/web --timeout=60s", timeout=300)
              cluster_ips = json.loads(kubectl("get service web -o json"))["spec"]["clusterIPs"]
              assert sorted(address(ip).version for ip in cluster_ips) == [4, 6], cluster_ips
              for name in NODES:
                  for cluster_ip in cluster_ips:
                      family = address(cluster_ip).version
                      host = f"[{cluster_ip}]" if family == 6 else cluster_ip
                      seen = pod_wait(name, f"wget -T 5 -qO- http://{host}:8080/cgi-bin/who")
                      own = next(ip for ip in ips[name] if address(ip).version == family)
                      print(f"FINDING the Service at {cluster_ip} saw the pod on {name} ({own}) as {seen}")
                      assert address(seen) == address(own), f"the Service at {cluster_ip} saw the pod on {name} ({own}) as {seen}"
              print("CLAT_CLUSTERIP_OK")

          node_ips: dict[str, list[str]] = {}
          for name in NODES:
              node_ips[name] = kubectl(f"get node {name} -o jsonpath='{{.status.addresses[?(@.type==\"InternalIP\")].address}}'").split()
          print(f"FINDING node addresses: {node_ips}")

          with subtest("a NodePort answers on the node addresses from the other node, and not on a NIC address from outside the cluster (D69)"):
              limited = config.get("nodeport-addresses", "")
              print(f"FINDING Cilium nodeport-addresses: {limited!r}")
              listed = {ipaddress.ip_network(entry).network_address for entry in limited.split(",") if entry}
              assert listed == {address(ip) for found in node_ips.values() for ip in found}, f"nodeport-addresses {limited!r} are not the node addresses {node_ips}"
              service = {
                  "apiVersion": "v1",
                  "kind": "Service",
                  "metadata": {"name": "web-nodeport"},
                  "spec": {"type": "NodePort", "ipFamilyPolicy": "RequireDualStack", "selector": {"app": "web"}, "ports": [{"port": 8080, "nodePort": NODEPORT}]},
              }
              alpha.succeed(f"{K} kubectl apply -f - <<'EOF'\n{json.dumps(service)}\nEOF")
              for source, target in [("alpha", "beta"), ("beta", "alpha")]:
                  assert sorted(address(ip).version for ip in node_ips[target]) == [4, 6], node_ips
                  for ip in node_ips[target]:
                      host = f"[{ip}]" if ":" in ip else ip
                      seen = NODES[source].wait_until_succeeds(f"curl -s --max-time 5 http://{host}:{NODEPORT}/cgi-bin/who", timeout=60).strip()
                      print(f"FINDING the NodePort on {target} at {ip}, asked from {source}: the pod saw {seen}")
                      assert addresses_in(seen), f"the NodePort on {target} at {ip} answered {seen!r}"
              for name, machine in NODES.items():
                  # the outside machine does reach the node on its NIC address
                  machine.wait_until_succeeds("ss -tln | grep ':8099 ' >/dev/null", timeout=60)
                  seen = server6.succeed(f"curl -s --max-time 5 http://[{NIC6[name]}]:8099/")
                  assert address(seen) == address(SERVER6), f"{name}: the node's own listener saw the outside machine as {seen!r}"
                  status, out = server6.execute(f"curl -sS --max-time 4 http://[{NIC6[name]}]:{NODEPORT}/cgi-bin/who 2>&1")
                  print(f"FINDING the NodePort on {name} at its NIC address {NIC6[name]}, asked from outside: rc={status} {out.strip()}")
                  assert status != 0, f"{name}: the NodePort answers on the NIC address {NIC6[name]} from outside the cluster: {out}"
              print("CLAT_NODEPORT_OK")

          with subtest("pod to node on the node's IPv4 address is not masqueraded to the CLAT address"):
              node_v4: dict[str, str] = {}
              for name in NODES:
                  found = node_ips[name]
                  node_v4[name] = next(ip for ip in found if ":" not in ip)
                  NODES[name].wait_until_succeeds("ss -tln | grep ':8099 ' >/dev/null", timeout=60)
              for source in NODES:
                  for target in NODES:
                      seen = pod_wait(source, f"wget -T 5 -qO- http://{node_v4[target]}:8099/")
                      print(f"FINDING node {target} at {node_v4[target]} saw the pod on {source} ({pod_v4(source)}) as {seen}")
                      assert address(seen) != address(CLAT4), f"pod on {source} to node {target} was masqueraded to the CLAT address"
              print("CLAT_POD_TO_NODE_OK")

          with subtest("the gateway refuses a destination that embeds a private IPv4 address: one pod request, one refused packet; nothing else ever was refused (G5)"):
              clat_stats = "ip netns exec clat jool_siit -i clat"
              gw_stats = "ip netns exec nat64 jool -i default"
              observe("gateway: its IPv4 addresses", gw, "ip -4 -br addr; ip netns exec nat64 ip -4 route")
              # the nodes have no IPv4 nameserver now: no stray packet to a
              # private address reached the gateway since it booted
              refused = private_refused()
              strays = gw.succeed("cat /tmp/private.txt").strip().splitlines()
              print(f"FINDING the gateway refused {refused} packets to private IPv4 addresses before any test request:\n" + "\n".join(strays))
              assert len(strays) == refused, f"the capture has {len(strays)} packets, the counter {refused}"
              # FINDING (2026-11-22): on the routed fabric a node address is
              # a BGP route. Until the fabric has converged, a node's packet
              # to another node's IPv4 address (the agent's to the API server
              # at 192.168.77.1:6443) takes the IPv4 default route into the
              # CLAT and reaches the gateway, which refuses it. Seen: 1 and 2
              # packets. The mesh has a static route per peer: none.
              targets = {match.group(1) for line in strays if (match := re.search(r" > (\S+)\.\d+: ", line)) is not None}
              node_v4s = {ip for found in node_ips.values() for ip in found if ":" not in ip}
              if FABRIC:
                  assert targets <= node_v4s and refused <= 10, f"stray packets to private IPv4 addresses that are not node addresses, or too many: {strays}"
              else:
                  assert refused == 0, f"the gateway refused {refused} packets to private IPv4 addresses before any test request"
              for name, machine in NODES.items():
                  for private in ["172.20.0.1", "192.168.1.254"]:
                      observe(f"{name}: route to {private}", machine, f"ip route get {private}")
                      observe(f"gateway NAT64 namespace: route to {private}", gw, f"ip netns exec nat64 ip route get {private}")
                      before = (jool_stats(machine, clat_stats), jool_stats(gw, gw_stats))
                      status, out = pod_exec(name, f"wget -T 4 -qO- http://{private}/", timeout=10)
                      print(f"FINDING pod on {name} to the private IPv4 address {private}: rc={status} {out}")
                      assert status != 0, f"{private} was reachable through the NAT64 prefix"
                      crossed = moved(before[1], jool_stats(gw, gw_stats))
                      print(f"FINDING {name}: {private}: CLAT counters that moved: {moved(before[0], jool_stats(machine, clat_stats))}")
                      print(f"FINDING {name}: {private}: gateway NAT64 counters that moved: {crossed}")
                      # Jool itself translates the packet; the firewall behind it refuses
                      assert crossed.get("JSTAT_SUCCESS", 0) > 0, f"the translator did not translate the packet to {private}: {crossed}"
                      now = private_refused()
                      assert now - refused == 1, f"{name}: one pod request to {private} moved the gateway's counter by {now - refused}"
                      refused = now
              print("CLAT_PRIVATE_REFUSED_OK")

          with subtest("an IfState apply on each node changes nothing and leaves pod IPv4 egress and the pod network intact"):
              for name, machine in NODES.items():
                  assert_ifstate_noop(machine)
                  machine.wait_for_unit("clat.service", timeout=60)
                  host_v4(machine, "after an IfState apply")
                  v4, v6 = expected_sources(name)
                  egress(name, True, v4, v6, "after an IfState apply")
                  assert_cilium_on_clat(name, "after an IfState apply")
                  assert_nameservers(name, "after an IfState apply")
                  host_names(name, "after an IfState apply")
                  v6_egress(name, "after an IfState apply")
                  pod_names(name, "after an IfState apply")
              pod_network("after an IfState apply")
              print("CLAT_IFSTATE_APPLY_OK")

          if not MAPPED:
              # nothing orders the cluster unit after the CLAT, so Cilium
              # must take a `clat0` that appears after it started
              for name in NODES:
                  with subtest(f"the CLAT link of {name} is made again under a running Cilium and pod load: Cilium attaches to the new link, pod IPv4 egress returns"):
                      remake(name)
              print("CLAT_LINK_REMADE_OK")

              kubectl("delete pod web --force --grace-period=0")
              # beta is the agent, alpha the cluster's only server
              for name in ["beta", "alpha"]:
                  with subtest(f"{name} reboots: its CLAT, its nameserver, the node, Cilium on clat0 and pod egress in both families come back"):
                      reboot(name)
              print("CLAT_REBOOT_OK")

      print("${lib.toUpper (lib.replaceStrings ["-"] ["_"] suiteName)}_OK")
    '';
  }
