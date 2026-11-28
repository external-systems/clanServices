# <distro>-hostile: hostile actors against a cluster on the routed
# fabric. Hermetic: one test VLAN, no real network, images preloaded.
#
#   outsider  192.168.1.66, on the nodes' underlay LAN; no key, no token
#   mallory   a fabric leaf with `access = "client"` that is NOT a
#             cluster member (valid fabric keys and BGP session, hostile
#             root)
#   alpha     server, spine            beta   agent, leaf
#   pods      `hostile` on beta and `hostile-alpha` on alpha (busybox,
#             default service account); `web` on beta is a target
#
# Every attack ends in one `verdict(id, safe, detail)`. The suite runs
# all of them, prints a `HOSTILE SAFE|GAP <id>` line each, and fails at
# the end when any is a gap. A new attack is a new verdict; never
# delete one to make the suite pass.
#
# Every group of verdicts has a positive control: `control(id, worked,
# detail)` shows that the attack is real (it works without the guard),
# that its packets arrive, or that the same probe finds what it looks
# for on a legal target. A SAFE without a working control proves
# nothing, so a control that did not work fails the suite as a gap does
# (SPEC.md H19).
#
# `info(...)` lines report behaviour that a later step of the target
# design closes (specs/design-kube.md §8). Each names its step. That
# step turns the line into a verdict with a control; until then it
# never fails the suite.
#
# A pod's attacks run on its node inside the pod's network namespace
# (`ip netns exec`), so they have the pod's network identity and the
# node's tools (nmap, curl).
#
# The design and the invariants: specs/design-kube.md §2 and §6.
{
  lib,
  inputs,
  nodes,
  distro,
}: let
  k3s = distro == "k3s";
  nodeAddress = {
    alpha = "192.168.1.1";
    beta = "192.168.1.2";
    mallory = "192.168.1.3";
  };
  fabricAddress = {
    alpha = {
      ipv4 = "192.168.77.1";
      ipv6 = "fd00:77::1";
    };
    beta = {
      ipv4 = "192.168.77.2";
      ipv6 = "fd00:77::2";
    };
    mallory = {
      ipv4 = "192.168.77.3";
      ipv6 = "fd00:77::3";
    };
  };
  outsider = "192.168.1.66";
  # D75 (K43): a node-bgp pool owned by alpha; beta must not originate it
  pools.owned = {
    blocks = [
      "192.0.2.144/28"
      "fd20:db8:3::/112"
    ];
    serviceSelector."clan.lol/pool" = "owned";
    delivery = "node-bgp";
    owner = "alpha";
  };
  adj = name: remote: nodes.${name}.clan.networkFacts.fabric.mesh.adjacencies.${remote};
  endpointSources = [
    {
      service = "clan-core/internet";
      instance = "underlay";
    }
  ];
  serverUnit =
    if k3s
    then "k3s"
    else "rke2-server";
  agentUnit =
    if k3s
    then "k3s"
    else "rke2-agent";
  kubeconfig = "/etc/rancher/${distro}/${distro}.yaml";
  # what a pod may reach on a node (lib/kube-cluster/firewall.nix, D76,
  # specs/design-kube.md §3.2): the API on a server, nothing on an agent.
  # The kubelet answers the servers, Cilium's health port and the rke2
  # supervisor the members; the HAProxy fronts bind loopback.
  clusterPorts = {
    alpha = [6443];
    beta = [];
  };
  # the HAProxy fronts per node: the API front, and the rke2 supervisor
  # front. An rke2 agent's supervisor front has the supervisor's own port
  # (its tunnel dials the servers on the port of its join URL, §3.6).
  frontPorts =
    if k3s
    then {
      alpha = [7443];
      beta = [7443];
    }
    else {
      alpha = [7443 8443];
      beta = [7443 9345];
    };
  # every port a hostile actor would try first
  interesting = "22,179,2379-2381,4240,4244,4245,6443,7443,8404,8443,9345,9963,10248-10259";
in {
  name = "${distro}-hostile";

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
        mallory = {};
        outsider = {};
      };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = lib.mapAttrs (_: host: {settings = {inherit host;};}) nodeAddress;
        };

        mesh = {
          module.name = "routed-fabric";
          module.input = "self";
          roles = {
            spine.settings.site = "lab";
            # D75 (A5): the pinned loopbacks lie in their pools
            spine.settings.loopback4Pool = "192.168.77.0/24";
            spine.settings.loopback6Pool = "fd00:77::/64";
            leaf.settings.loopback4Pool = "192.168.77.0/24";
            leaf.settings.loopback6Pool = "fd00:77::/64";
            leaf.settings.site = "lab";
            spine.machines.alpha.settings = fabricAddress.alpha // {inherit endpointSources;};
            leaf.machines = {
              beta.settings = fabricAddress.beta // {inherit endpointSources;};
              mallory.settings =
                fabricAddress.mallory
                // {
                  inherit endpointSources;
                  access = "client";
                };
            };
          };
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
              cilium.id = 1;
              inherit pools;
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
              inherit pools;
            };
            machines.beta = {};
          };
        };
      };
    };
  };

  nodes = let
    fixture = address: extra:
      import ../../../../tests/ifstate-vm.nix ({
          ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
          addresses = ["${address}/24"];
        }
        // extra);
    clusterNode = name: {pkgs, ...}: let
      busyboxImage = pkgs.dockerTools.pullImage {
        imageName = "busybox";
        imageDigest = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662";
        hash = "sha256-OasmfjRQsuVWudSc4qWuMKK5nNz4hdIS8Si4B0okXEw=";
        finalImageTag = "1.36.1";
      };
    in {
      imports = [(fixture nodeAddress.${name} {})];
      services.${distro}.images = [busyboxImage];
      systemd.tmpfiles.rules = lib.mkIf (!k3s) [
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
        pkgs.nmap
        pkgs.curl
        pkgs.tcpdump
        pkgs.netcat-openbsd
        pkgs.conntrack-tools
      ];
    };
    tools = pkgs: [
      pkgs.nmap
      pkgs.netcat-openbsd
      pkgs.curl
      pkgs.tcpdump
    ];
  in {
    alpha = clusterNode "alpha";
    beta = clusterNode "beta";
    mallory = {pkgs, ...}: {
      imports = [(fixture nodeAddress.mallory {})];
      environment.systemPackages = tools pkgs;
      virtualisation = {
        cores = 1;
        memorySize = 1536;
      };
    };
    outsider = {pkgs, ...}: {
      imports = [(fixture outsider {withBase = true;})];
      networking.firewall.enable = false;
      environment.systemPackages = tools pkgs;
      virtualisation = {
        cores = 2;
        memorySize = 1024;
      };
    };
  };

  testScript = ''
    import json
    import re

    ${import ../../../../tests/suite-lib.nix}

    KUBECTL = "KUBECONFIG=${kubeconfig} kubectl"
    KUBE_TABLE = "inet kube-${distro}"
    FABRIC_TABLE = "inet routed-fabric-mesh"
    OUTSIDE_TO_CLUSTER = "outside to the cluster's pods and Services"
    cluster = [alpha, beta]
    underlay = ${builtins.toJSON nodeAddress}
    fabric = ${builtins.toJSON fabricAddress}
    cluster_ports = ${builtins.toJSON clusterPorts}
    front_ports = ${builtins.toJSON frontPorts}
    interesting = "${interesting}"
    rke2 = ${
      if k3s
      then "False"
      else "True"
    }
    alpha_mallory = "${(adj "alpha" "mallory").interface}"
    mallory_alpha = "${(adj "mallory" "alpha").interface}"
    alpha_beta = "${(adj "alpha" "beta").interface}"
    alpha_on_beta_link4 = "${(adj "alpha" "beta").ipv4}"
    alpha_on_beta_link6 = "${(adj "alpha" "beta").ipv6}"
    beta_on_alpha_link4 = "${(adj "beta" "alpha").ipv4}"
    beta_on_alpha_link6 = "${(adj "beta" "alpha").ipv6}"
    alpha_on_mallory_link4 = "${(adj "alpha" "mallory").ipv4}"
    alpha_on_mallory_link6 = "${(adj "alpha" "mallory").ipv6}"
    mallory_on_alpha_link4 = "${(adj "mallory" "alpha").ipv4}"
    mallory_on_alpha_link6 = "${(adj "mallory" "alpha").ipv6}"
    outsider_ip = "${outsider}"

    RESULTS = []
    CONTROLS = []


    def verdict(key, safe, detail=""):
        RESULTS.append((key, bool(safe), detail))
        print(f"HOSTILE {'SAFE' if safe else 'GAP '} {key}: {detail}")


    def control(key, worked, detail=""):
        """A positive control: the attack of a verdict group is real."""
        CONTROLS.append((key, bool(worked), detail))
        print(f"HOSTILE CONTROL {'OK  ' if worked else 'FAIL'} {key}: {detail}")


    def info(key, detail):
        print(f"HOSTILE INFO {key}: {detail}")


    def scan(machine, target, ports="-", family="", prefix=""):
        """Open TCP ports of one address, as `machine` (or a pod) sees them."""
        out = machine.succeed(f"{prefix} nmap {family} -n -Pn -sS -p{ports} --min-rate 3000 --max-retries 1 -oG - {target} 2>&1")
        found = []
        for line in out.splitlines():
            if "Ports:" in line:
                found += [int(p.split("/")[0].strip()) for p in line.split("Ports:")[1].split(",") if "/open/" in p]
        return sorted(found)


    def node_port_range(port):
        """A NodePort: Cilium serves it ahead of the node firewall, to
        whoever reaches a Cilium device, until kube step 8 gives every
        front source ranges (K10n, K13)."""
        return 30000 <= port <= 32767


    def pod_ips(pod):
        ips = alpha.succeed(f"{KUBECTL} get pod {pod} -o jsonpath='{{.status.podIPs[*].ip}}'").split()
        return [ip for ip in ips if ":" not in ip][0], [ip for ip in ips if ":" in ip][0]


    def pod_netns(node, pod):
        """`ip netns exec <the pod's namespace>` on the pod's node."""
        ipv4, _ = pod_ips(pod)
        name = node.succeed(
            f"for ns in $(ip netns list | awk '{{print $1}}'); do ip -n $ns -4 -o addr 2>/dev/null | grep -F ' {ipv4}/' >/dev/null && echo $ns; done; true"
        ).strip()
        assert name and "\n" not in name, f"no namespace for pod {pod} ({ipv4}) on {node.name}: {name!r}"
        return f"ip netns exec {name}"


    def http_code(machine, url, prefix="", header=""):
        return machine.succeed(f"{prefix} curl -sk -m 5 -o /dev/null -w '%{{http_code}}' {header} {url} || true").strip()[-3:]


    def bgp_routes(machine, family, neighbor):
        out = machine.succeed(f"vtysh -c 'show bgp {family} unicast neighbors {neighbor} routes json'")
        return sorted(json.loads(out).get("routes", {}).keys())


    def capture(machine, unit, iface, direction, expr):
        machine.execute(f"systemctl stop {unit} 2>/dev/null; systemctl reset-failed {unit} 2>/dev/null; rm -f /tmp/{unit}")
        machine.succeed(f"systemd-run --unit={unit} $(command -v tcpdump) -pUni {iface} -Q {direction} -w /tmp/{unit} '{expr}'")
        machine.wait_until_succeeds(f"test -s /tmp/{unit}", timeout=20)


    def captured(machine, unit):
        """The packets a capture saw, one text line each."""
        machine.execute("sleep 1")
        machine.execute(f"systemctl stop {unit}")
        out = machine.succeed(f"tcpdump -nr /tmp/{unit} 2>/dev/null || true")
        return [line for line in out.splitlines() if line.strip()]


    def table_off(machine, table):
        """For a positive control: the same attack without a guard table."""
        machine.succeed(f"nft delete table {table}")


    def tables_on(machine):
        # nftables.service reloads only its own tables (no flushRuleset):
        # Cilium's rules stay
        machine.succeed("systemctl reload nftables")
        machine.succeed(f"nft list table {KUBE_TABLE} >/dev/null && nft list table {FABRIC_TABLE} >/dev/null")


    try:
        start_all()

        with subtest("the cluster is up before any attack"):
            alpha.wait_for_unit("${serverUnit}.service", timeout=600)
            beta.wait_for_unit("${agentUnit}.service", timeout=600)
            alpha.wait_until_succeeds(f"{KUBECTL} wait --for=condition=Ready node/alpha node/beta --timeout=120s", timeout=600)
            alpha.wait_until_succeeds(f"{KUBECTL} wait -n kube-system --for=condition=Ready pod -l k8s-app=cilium --timeout=120s", timeout=600)
            mallory.wait_for_unit("frr.service", timeout=180)
            mallory.wait_until_succeeds(f"ping -c 2 -W 2 {fabric['beta']['ipv4']}", timeout=240)
            for pod, node, command in [
                ("hostile", "beta", "sleep infinity"),
                ("web", "beta", "httpd -f -p 8080 -h /tmp"),
                ("hostile-alpha", "alpha", "httpd -f -p 8080 -h /tmp"),
            ]:
                alpha.succeed(
                    f"{KUBECTL} run {pod} --image=busybox:1.36.1 --restart=Always --labels=app={pod} "
                    f"--overrides='{{\"spec\":{{\"nodeName\":\"{node}\",\"tolerations\":[{{\"operator\":\"Exists\"}}]}}}}' -- {command}"
                )
            alpha.wait_until_succeeds(f"{KUBECTL} wait --for=condition=Ready pod/hostile pod/web pod/hostile-alpha --timeout=120s", timeout=600)
            # type NodePort until kube step 8 (Service fronts by source)
            alpha.succeed(f"{KUBECTL} expose pod web --type=NodePort --port=8080 --name=web")
            node_port = alpha.succeed(f"{KUBECTL} get svc web -o jsonpath='{{.spec.ports[0].nodePort}}'").strip()
            api_vip = alpha.succeed(f"{KUBECTL} get svc kubernetes -o jsonpath='{{.spec.clusterIP}}'").strip()
            web4, web6 = pod_ips("web")
            alpha_pod4, alpha_pod6 = pod_ips("hostile-alpha")
            in_pod = pod_netns(beta, "hostile")
            in_pod_alpha = pod_netns(alpha, "hostile-alpha")
            # the pod network works: the attacks below fail for a reason
            beta.wait_until_succeeds(f"{in_pod} curl -s -m 5 -o /dev/null http://{web4}:8080/", timeout=120)
            alpha.wait_until_succeeds(f"nc -z -w 3 {fabric['beta']['ipv4']} {node_port}", timeout=120)
            link_local = {
                node.name: node.succeed("ip -6 -o addr show dev eth1 scope link | awk '{print $4}' | cut -d/ -f1").strip()
                for node in cluster
            }
            asn = mallory.succeed("vtysh -c 'show running-config' | awk '/^router bgp/ {print $3; exit}'").strip()
            print(f"web pod {web4} {web6}; NodePort {node_port}; API ClusterIP {api_vip}")
            print_versions(alpha, ["kernel", "${distro}", "cilium", "frr", "nftables"])

        # ------------------------------------------------------------------
        # The outsider: on the nodes' underlay LAN, no key, no token
        # ------------------------------------------------------------------
        with subtest("outsider: a full TCP scan of every node's underlay address, both families"):
            # control: the same scan finds a port alpha opens on purpose
            alpha.succeed("nft insert rule inet nixos-fw input-allow iifname eth1 tcp dport { 4444, 4445 } accept")
            alpha.succeed("systemd-run --unit=listen-4444 $(command -v nc) -4 -lk 4444")
            alpha.succeed("systemd-run --unit=listen-4445 $(command -v nc) -6 -lk 4445")
            alpha.wait_until_succeeds("ss -tln | grep ':4444 ' >/dev/null && ss -tln | grep ':4445 ' >/dev/null", timeout=20)
            seen4 = scan(outsider, underlay["alpha"])
            seen6 = scan(outsider, f"{link_local['alpha']}%eth1", family="-6")
            control("K01/K02 the scan finds the ports alpha opened on its underlay", 4444 in seen4 and 4445 in seen6, f"IPv4 {seen4}, IPv6 {seen6}")
            alpha.succeed("systemctl stop listen-4444 listen-4445")
            alpha.succeed("nft delete rule inet nixos-fw input-allow handle $(nft -a list chain inet nixos-fw input-allow | awk '/4445/ {print $NF}')")
            for name in ["alpha", "beta"]:
                found = scan(outsider, underlay[name])
                verdict(f"K01 no TCP port open on the underlay ({name}, IPv4)", not found, f"open: {found}")
                found = scan(outsider, f"{link_local[name]}%eth1", family="-6")
                verdict(f"K02 no TCP port open on the underlay ({name}, IPv6 link-local)", not found, f"open: {found}")

        with subtest("outsider: the nodes' fabric addresses through a node's underlay address"):
            outsider.succeed("ip route add 192.168.77.0/24 via 192.168.1.1")
            outsider.succeed(f"ip -6 route add fd00:77::/64 via {link_local['alpha']} dev eth1")
            capture(alpha, "cap-k03", "eth1", "in", "tcp and (dst net 192.168.77.0/24 or dst net fd00:77::/64)")
            for name in ["alpha", "beta"]:
                found = scan(outsider, fabric[name]["ipv4"], ports=interesting)
                verdict(f"K03 no cluster port of {name}'s node address answers the outsider (IPv4)", not found, f"open: {found}")
                found = scan(outsider, fabric[name]["ipv6"], ports=interesting, family="-6")
                verdict(f"K04 no cluster port of {name}'s node address answers the outsider (IPv6)", not found, f"open: {found}")
            syns = captured(alpha, "cap-k03")
            control("K03/K04 the outsider's probes of the node addresses arrive on alpha's underlay", len(syns) >= 40, f"{len(syns)} packets")

        with subtest("outsider: pods and services through a node's underlay address"):
            outsider.succeed(f"ip route add {web4}/32 via {underlay['beta']}")
            outsider.succeed(f"ip route add {api_vip}/32 via {underlay['alpha']}")
            before = {node.name: drops(node, KUBE_TABLE, OUTSIDE_TO_CLUSTER) for node in cluster}
            code, _ = outsider.execute(f"nc -z -w 3 {web4} 8080")
            verdict("K05 a pod does not answer the outsider through its node's underlay address", code != 0, f"TCP {web4}:8080 connected" if code == 0 else "")
            code, _ = outsider.execute(f"ping -c 2 -W 1 {web4}")
            verdict("K06 a pod does not answer the outsider's ping", code != 0)
            code, _ = outsider.execute(f"nc -z -w 3 {api_vip} 443")
            verdict("K07 the API's ClusterIP does not answer the outsider", code != 0)
            dropped = {node.name: drops(node, KUBE_TABLE, OUTSIDE_TO_CLUSTER) - before[node.name] for node in cluster}
            control("K05/K06 the outsider's packets for the pod reach beta and its kube table drops them", dropped["beta"] >= 3, f"beta dropped +{dropped['beta']}")
            control("K07 the outsider's packets for the ClusterIP reach alpha and its kube table drops them", dropped["alpha"] >= 1, f"alpha dropped +{dropped['alpha']}")
            table_off(beta, KUBE_TABLE)
            code, _ = outsider.execute(f"nc -z -w 3 {web4} 8080")
            tables_on(beta)
            control("K05 without beta's kube table the outsider connects to the pod", code == 0, f"rc={code}")
            for name in ["alpha", "beta"]:
                code, _ = outsider.execute(f"nc -z -w 3 {underlay[name]} {node_port}")
                verdict(f"K08 NodePort {node_port} on {name}'s underlay address does not answer the outsider", code != 0)
            # control: the NodePort answers on a node address (D69: node
            # addresses only), for the members and the pods
            code, _ = alpha.execute(f"nc -z -w 3 {fabric['beta']['ipv4']} {node_port}")
            control("K08/K13m a member reaches the NodePort on another member's node address", code == 0)
            code, _ = beta.execute(f"{in_pod} nc -z -w 3 {fabric['alpha']['ipv4']} {node_port}")
            control("K08/K13p a pod reaches the NodePort on a member's node address", code == 0)
            for name in ["alpha", "beta"]:
                for port, path in [(6443, "/api/v1/namespaces/kube-system/secrets"), (10250, "/pods")]:
                    code = http_code(outsider, f"https://{underlay[name]}:{port}{path}")
                    verdict(f"K09 {name}:{port} gives the outsider no data", code in ("000", "401", "403"), f"HTTP {code}")
            # control: the same request from a member reaches the service
            # on its node address and gets an answer
            code = http_code(beta, f"https://{fabric['alpha']['ipv4']}:6443/api/v1/namespaces/kube-system/secrets")
            control("K09 the API answers the same request from a member", code in ("401", "403"), f"HTTP {code}")
            code = http_code(alpha, f"https://{fabric['beta']['ipv4']}:10250/pods")
            control("K09/K22 the kubelet answers the same request from a server", code in ("401", "403"), f"HTTP {code}")

        # ------------------------------------------------------------------
        # mallory: a fabric member outside the cluster
        # ------------------------------------------------------------------
        with subtest("mallory: the nodes' ports over the fabric"):
            # control: the same scan finds BGP on alpha's end of mallory's link
            seen4 = scan(mallory, alpha_on_mallory_link4, ports="179")
            seen6 = scan(mallory, alpha_on_mallory_link6, ports="179", family="-6")
            control("K10 the scan finds BGP on alpha's address on mallory's link", seen4 == [179] and seen6 == [179], f"IPv4 {seen4}, IPv6 {seen6}")
            for name in ["alpha", "beta"]:
                for key, family in [("ipv4", ""), ("ipv6", "-6")]:
                    found = scan(mallory, fabric[name][key], family=family)
                    extra = [p for p in found if p != 179 and not node_port_range(p)]
                    verdict(f"K10 a fabric member outside the cluster reaches no port of {name} but BGP ({key})", not extra, f"open: {found}")
                    ports = [p for p in found if node_port_range(p)]
                    if ports:
                        info(f"K10n NodePorts of {name} answer a fabric member outside the cluster ({key}); kube step 8 closes it", f"{ports}")

        with subtest("mallory: pods and services over the fabric"):
            route = mallory.succeed(f"ip route get {web4} 2>&1 || true").strip()
            code, _ = mallory.execute(f"nc -z -w 3 {web4} 8080")
            verdict("K11 a fabric member outside the cluster does not reach a pod", code != 0, f"TCP {web4}:8080 connected; route: {route}" if code == 0 else "")
            code, _ = mallory.execute(f"nc -z -w 3 {api_vip} 443")
            verdict("K12 a fabric member outside the cluster does not reach the API's ClusterIP", code != 0)
            # control: the same connects from a member host succeed
            code_pod, _ = alpha.execute(f"nc -z -w 3 {web4} 8080")
            code_vip, _ = alpha.execute(f"nc -z -w 3 {api_vip} 443")
            control("K11/K12 a member reaches the pod and the API's ClusterIP", code_pod == 0 and code_vip == 0, f"pod rc={code_pod}, ClusterIP rc={code_vip}")
            for name in ["alpha", "beta"]:
                for key in ["ipv4", "ipv6"]:
                    code, _ = mallory.execute(f"nc -z -w 3 {fabric[name][key]} {node_port}")
                    info(f"K13 NodePort {node_port} on {name}'s node address from a fabric member outside the cluster ({key}); kube step 8 closes it", "reachable" if code == 0 else "not reachable")

        with subtest("mallory: BGP hijacks of the cluster's prefixes are not accepted"):
            own4, own6 = fabric["mallory"]["ipv4"] + "/32", fabric["mallory"]["ipv6"] + "/128"
            pod_net4 = ".".join(web4.split(".")[:3]) + ".0/24"
            hijack4 = [web4 + "/32", pod_net4, api_vip + "/32", fabric["beta"]["ipv4"] + "/32", "0.0.0.0/0"]
            hijack6 = [web6 + "/128", fabric["beta"]["ipv6"] + "/128", "::/0"]
            before = alpha.succeed(f"ip route get {web4}").strip()
            commands = ["conf t", "route-map EVIL permit 10", "exit", f"router bgp {asn}", "no bgp network import-check"]
            commands += ["address-family ipv4 unicast", f"neighbor {alpha_on_mallory_link4} route-map EVIL out"]
            commands += [f"network {prefix}" for prefix in hijack4] + ["exit-address-family"]
            commands += ["address-family ipv6 unicast", f"neighbor {alpha_on_mallory_link6} route-map EVIL out"]
            commands += [f"network {prefix}" for prefix in hijack6] + ["exit-address-family"]
            mallory.succeed("vtysh " + " ".join(f"-c '{c}'" for c in commands))
            mallory.succeed("vtysh -c 'clear bgp * soft out'")
            for family, neighbor, hijacks in [("ipv4", alpha_on_mallory_link4, hijack4), ("ipv6", alpha_on_mallory_link6, hijack6)]:
                mallory.wait_until_succeeds(
                    f"vtysh -c 'show bgp {family} unicast neighbors {neighbor} advertised-routes json' | grep -F '\"{hijacks[0]}\"' >/dev/null",
                    timeout=60,
                )
                sent = json.loads(mallory.succeed(f"vtysh -c 'show bgp {family} unicast neighbors {neighbor} advertised-routes json'"))
                missing = [p for p in hijacks if p not in sent.get("advertisedRoutes", {})]
                control(f"K14..K16 mallory advertises every hijack to the spine ({family})", not missing, f"not advertised: {missing}")
            alpha.succeed("sleep 15")
            got4 = bgp_routes(alpha, "ipv4", mallory_on_alpha_link4)
            got6 = bgp_routes(alpha, "ipv6", mallory_on_alpha_link6)
            verdict("K14 the spine accepts only mallory's own /32 from it", got4 == [own4], f"accepted: {got4}")
            verdict("K15 the spine accepts only mallory's own /128 from it", got6 == [own6], f"accepted: {got6}")
            after = alpha.succeed(f"ip route get {web4}").strip()
            verdict("K16 the route to the pod did not move", before == after, f"{before} -> {after}")
            beta.succeed(f"{in_pod} curl -s -m 5 -o /dev/null http://{web4}:8080/")
            # mallory takes its hijacks back: a locally originated /32 of
            # another member replaced its own learned route to that member
            undo = ["conf t", f"router bgp {asn}", "address-family ipv4 unicast"]
            undo += [f"no network {prefix}" for prefix in hijack4] + ["exit-address-family", "address-family ipv6 unicast"]
            undo += [f"no network {prefix}" for prefix in hijack6] + ["exit-address-family"]
            mallory.succeed("vtysh " + " ".join(f"-c '{c}'" for c in undo))
            mallory.wait_until_succeeds(f"ping -c 2 -W 2 {fabric['beta']['ipv4']}", timeout=60)

        with subtest("beta: a node-bgp VIP of another owner is not accepted from a cluster member"):
            # alpha owns the pool `owned`; beta is a member, not its owner
            vip4, vip6 = "192.0.2.145/32", "fd20:db8:3::1/128"
            beta_asn = beta.succeed("vtysh -c 'show running-config' | awk '/^router bgp/ {print $3; exit}'").strip()
            running = beta.succeed("vtysh -c 'show running-config'")
            out4 = re.findall(rf"neighbor {re.escape(alpha_on_beta_link4)} route-map (\S+) out", running)
            out6 = re.findall(rf"neighbor {re.escape(alpha_on_beta_link6)} route-map (\S+) out", running)
            assert out4 and out6, f"beta's export route-maps toward alpha not found: {out4} {out6}"
            # a hostile root on beta: export everything, and the VIP
            commands = ["conf t", "route-map EVIL permit 10", "exit", f"router bgp {beta_asn}", "no bgp network import-check"]
            commands += ["address-family ipv4 unicast", f"neighbor {alpha_on_beta_link4} route-map EVIL out", f"network {vip4}", "exit-address-family"]
            commands += ["address-family ipv6 unicast", f"neighbor {alpha_on_beta_link6} route-map EVIL out", f"network {vip6}", "exit-address-family"]
            beta.succeed("vtysh " + " ".join(f"-c '{c}'" for c in commands))
            beta.succeed("vtysh -c 'clear bgp * soft out'")
            for family, neighbor, vip in [("ipv4", alpha_on_beta_link4, vip4), ("ipv6", alpha_on_beta_link6, vip6)]:
                beta.wait_until_succeeds(
                    f"vtysh -c 'show bgp {family} unicast neighbors {neighbor} advertised-routes json' | grep -F '\"{vip}\"' >/dev/null",
                    timeout=60,
                )
            alpha.succeed("sleep 15")
            got4 = bgp_routes(alpha, "ipv4", beta_on_alpha_link4)
            got6 = bgp_routes(alpha, "ipv6", beta_on_alpha_link6)
            control("K43 beta advertises the VIP to the spine, and the spine takes beta's own routes", fabric["beta"]["ipv4"] + "/32" in got4 and fabric["beta"]["ipv6"] + "/128" in got6, f"accepted from beta: {got4} {got6}")
            kernel = alpha.succeed(f"ip route show {vip4}; ip -6 route show {vip6}").strip()
            verdict("K43 the spine does not accept a node-bgp VIP from a member that does not own it", vip4 not in got4 and vip6 not in got6 and beta_on_alpha_link4 not in kernel, f"accepted from beta: {got4} {got6}; kernel: {kernel!r}")
            undo = ["conf t", f"router bgp {beta_asn}"]
            undo += ["address-family ipv4 unicast", f"no network {vip4}", f"neighbor {alpha_on_beta_link4} route-map {out4[0]} out", "exit-address-family"]
            undo += ["address-family ipv6 unicast", f"no network {vip6}", f"neighbor {alpha_on_beta_link6} route-map {out6[0]} out", "exit-address-family"]
            undo += ["bgp network import-check", "exit", "no route-map EVIL permit 10"]
            beta.succeed("vtysh " + " ".join(f"-c '{c}'" for c in undo))
            beta.succeed("vtysh -c 'clear bgp * soft out'")
            beta.wait_until_succeeds(f"{in_pod} curl -s -m 5 -o /dev/null http://{alpha_pod4}:8080/", timeout=60)

        with subtest("mallory: a forced route to the pods through the spine"):
            def probe_counters():
                # what nft sees of mallory's packets on the kube spine
                alpha.succeed(f"nft insert rule {FABRIC_TABLE} ingress iifname {alpha_mallory} counter comment \\\"probe: seen at prerouting\\\"")
                alpha.succeed(f"nft insert rule {FABRIC_TABLE} forward iifname {alpha_mallory} counter comment \\\"probe: seen at forward\\\"")

            probe_counters()
            # a hostile root widens its own ACL and routes the pods to the spine
            peer, allowed = mallory.succeed(f"wg show {mallory_alpha} allowed-ips").strip().split("\t")
            mallory.succeed(f"wg set {mallory_alpha} peer {peer} allowed-ips {allowed.replace(' ', ',')},{web4}/32,{web6}/128,{alpha_pod4}/32,{alpha_pod6}/128")
            for target, via, flag in [(web4, alpha_on_mallory_link4, ""), (alpha_pod4, alpha_on_mallory_link4, ""), (web6, alpha_on_mallory_link6, "-6"), (alpha_pod6, alpha_on_mallory_link6, "-6")]:
                mallory.succeed(f"ip {flag} route add {target} via {via} dev {mallory_alpha}")
            # a hostile root also removes its own guard: it would drop the
            # replies (a pod address is no source its contract knows), and a
            # SAFE would then prove nothing
            mallory.succeed(f"nft delete table {FABRIC_TABLE}")
            source = {"": fabric["mallory"]["ipv4"], "-6": fabric["mallory"]["ipv6"]}

            # legal traffic first: relayed fabric -> fabric through the kube spine
            pre, fwd = drops(alpha, FABRIC_TABLE, "probe: seen at prerouting"), drops(alpha, FABRIC_TABLE, "probe: seen at forward")
            mallory.succeed(f"ping -c 3 -W 2 {fabric['beta']['ipv4']}")
            pre_seen = drops(alpha, FABRIC_TABLE, "probe: seen at prerouting") - pre
            fwd_seen = drops(alpha, FABRIC_TABLE, "probe: seen at forward") - fwd
            verdict("K40a nft on a kube spine sees relayed fabric traffic (prerouting and forward)", pre_seen >= 3 and fwd_seen >= 3, f"prerouting +{pre_seen}, forward +{fwd_seen}")

            contract = "mallory: destination outside its contract"
            for label, target, flag in [("IPv4", web4, ""), ("IPv6", web6, "-6")]:
                dropped = drops(alpha, FABRIC_TABLE, contract)
                url = f"http://{target}:8080/" if not flag else f"http://[{target}]:8080/"
                code = http_code(mallory, url, header=f"--interface {source[flag]}")
                nc_code, _ = mallory.execute(f"nc -z -w 3 -s {source[flag]} {target} 8080")
                ping_code, _ = mallory.execute(f"ping {flag} -c 3 -W 1 -I {source[flag]} {target}")
                dropped = drops(alpha, FABRIC_TABLE, contract) - dropped
                verdict(f"K40 a client leaf does not reach a pod on another node through the kube spine ({label})", code == "000" and ping_code != 0, f"http {code}, ping rc={ping_code}")
                verdict(f"K11f a fabric member outside the cluster with a forced route does not reach a pod on beta through the spine ({label})", nc_code != 0)
                # control: the packets reached the spine's guard and that rule dropped them
                control(f"K40/K11f the spine's link contract dropped mallory's packets for the pod ({label})", dropped >= 3, f"contract drops +{dropped}")
            # control: without the spine's guard table the same request is served
            table_off(alpha, FABRIC_TABLE)
            served = http_code(mallory, f"http://{web4}:8080/", header=f"--interface {fabric['mallory']['ipv4']}")
            tables_on(alpha)
            probe_counters()
            control("K40/K11f without the spine's guard table the client leaf gets an answer from the pod on beta", served != "000", f"HTTP {served}")

            # a pod on the spine itself: Cilium delivers it before netfilter
            for label, target, flag in [("IPv4", alpha_pod4, ""), ("IPv6", alpha_pod6, "-6")]:
                capture_unit = "cap-k41"
                alpha.execute(f"systemctl stop {capture_unit} 2>/dev/null; systemctl reset-failed {capture_unit} 2>/dev/null; rm -f /tmp/{capture_unit}")
                alpha.succeed(f"systemd-run --unit={capture_unit} {in_pod_alpha} $(command -v tcpdump) -pUni eth0 -Q in -w /tmp/{capture_unit} 'icmp or icmp6'")
                alpha.succeed("sleep 2")
                ping_code, _ = mallory.execute(f"ping {flag} -c 3 -W 1 -I {source[flag]} {target}")
                nc_code, _ = mallory.execute(f"nc -z -w 3 -s {source[flag]} {target} 8080")
                alpha.execute(f"sleep 1; systemctl stop {capture_unit}")
                arrived = alpha.succeed(f"tcpdump -nr /tmp/{capture_unit} 2>/dev/null | grep -c 'echo request' || true").strip()
                info(
                    f"K41/K11f a client leaf and a pod on the kube spine itself ({label}); kube step 7 (the clusterwide policy) closes it",
                    f"ping {'answered' if ping_code == 0 else 'not answered'}, TCP {'connects' if nc_code == 0 else 'refused'}; {arrived} echo requests reached the pod",
                )

        with subtest("probe P5: conntrack and relayed fabric traffic on the kube spine"):
            def tracked(first, last):
                """Conntrack entries of the flood: UDP to beta's node address, one port range."""
                out = alpha.succeed(f"conntrack -L -p udp -d {fabric['beta']['ipv4']} 2>/dev/null || true")
                ports = [int(part.split("=")[1]) for line in out.splitlines() for part in line.split() if part.startswith("dport=")]
                return len({port for port in ports if first <= port <= last})

            def relay_flood(first, last):
                # 2000 one-way UDP flows from mallory to beta's node address, relayed by alpha
                mallory.execute(f"nmap -n -Pn -sU --min-rate 2000 --max-retries 0 -S {fabric['mallory']['ipv4']} -e {mallory_alpha} -p {first}-{last} {fabric['beta']['ipv4']} >/dev/null 2>&1")

            total = alpha.succeed("cat /proc/sys/net/netfilter/nf_conntrack_count").strip()
            relay_flood(20000, 21999)
            grown = tracked(20000, 21999)
            print(f"FINDING P5 conntrack entries on the kube spine for 2000 relayed one-way UDP flows: {grown} (table size before: {total})")
            alpha.succeed("nft add table inet probe-notrack")
            alpha.succeed("nft add chain inet probe-notrack pre '{ type filter hook prerouting priority raw + 1; }'")
            alpha.succeed(f"nft add rule inet probe-notrack pre iifname {{ {alpha_mallory}, {alpha_beta} }} fib daddr type != local counter notrack")
            alpha.succeed("sleep 2")
            relay_flood(22000, 23999)
            flat = tracked(22000, 23999)
            relayed_ok = mallory.execute(f"ping -c 3 -W 2 -I {fabric['mallory']['ipv4']} {fabric['beta']['ipv4']}")[0] == 0
            pod_path_ok = beta.execute(f"{in_pod} curl -s -m 5 -o /dev/null http://{web4}:8080/")[0] == 0
            api_ok = beta.execute(f"{in_pod} curl -sk -m 5 -o /dev/null https://{api_vip}:443/version")[0] == 0
            alpha_pod_ok = alpha.execute(f"{in_pod_alpha} curl -s -m 5 -o /dev/null http://{web4}:8080/")[0] == 0
            hits = alpha.succeed("nft list table inet probe-notrack | grep -o 'counter packets [0-9]*' || true").strip()
            print(f"FINDING P5 with notrack for fabric-link packets that are not local: conntrack entries for 2000 more flows: {flat}; relayed ping ok={relayed_ok}; pod->pod on beta ok={pod_path_ok}; pod on beta->API ClusterIP (on alpha) ok={api_ok}; pod on alpha->pod on beta ok={alpha_pod_ok}; rule {hits}")
            alpha.succeed("nft delete table inet probe-notrack")

        with subtest("local user: BGP on the node's loopback is for root"):
            owner = alpha.succeed("ss -Htnp 'dport = :179 or sport = :179' | grep -F '[::1]' || true").strip()
            print(f"FINDING P6 the Cilium session to ::1:179 on alpha: {' '.join(owner.split())[:400]}")
            connect = "bash -c 'exec 3<>/dev/tcp/::1/179' 2>/dev/null"
            # control: FRR listens there, and without the guard table an
            # unprivileged user gets in
            root_ok = alpha.execute(connect)[0] == 0
            table_off(alpha, FABRIC_TABLE)
            open_without = alpha.execute(f"runuser -u nobody -- {connect}")[0] == 0
            tables_on(alpha)
            control("K44 root connects to ::1:179, and so does an unprivileged user without the fabric's guard table", root_ok and open_without, f"root {root_ok}, nobody without the table {open_without}")
            before = drops(alpha, FABRIC_TABLE, "BGP on the loopback is for root")
            open_with = alpha.execute(f"runuser -u nobody -- {connect}")[0] == 0
            after = drops(alpha, FABRIC_TABLE, "BGP on the loopback is for root")
            verdict("K44 an unprivileged local user cannot open BGP on the loopback", not open_with and after > before, f"connected {open_with}; rule counted {after - before}")
            alpha.succeed("vtysh -c 'clear bgp ::1'")
            back = seconds_until(alpha, "vtysh -c 'show bgp neighbors ::1 json' | grep -F '\"bgpState\":\"Established\"'", limit=60, interval=1)
            verdict("K44 Cilium's session on the loopback comes back within 30 s with the rule in place", back is not None and back <= 30, f"re-established after {back} s")

        # ------------------------------------------------------------------
        # A hostile pod: unprivileged, default service account
        # ------------------------------------------------------------------
        with subtest("pod: what a pod reaches on the nodes"):
            for label, prefix, node in [("pod on beta", in_pod, beta), ("pod on alpha", in_pod_alpha, alpha)]:
                # control: the same scan finds the API on alpha's node address
                seen4 = scan(node, fabric["alpha"]["ipv4"], ports="6443", prefix=prefix)
                seen6 = scan(node, fabric["alpha"]["ipv6"], ports="6443", prefix=prefix, family="-6")
                control(f"K20/K21 the scan of a {label} finds the API on alpha's node address", seen4 == [6443] and seen6 == [6443], f"IPv4 {seen4}, IPv6 {seen6}")
                for name in ["alpha", "beta"]:
                    for where, target in [("node address", fabric[name]["ipv4"]), ("underlay address", underlay[name])]:
                        found = scan(node, target, prefix=prefix)
                        extra = [p for p in found if p not in cluster_ports[name] and not node_port_range(p)]
                        verdict(f"K20 a {label} reaches only the cluster ports of {name}'s {where}", not extra, f"unexpected: {extra}; all open: {found}")
                found = scan(node, fabric["alpha"]["ipv6"], prefix=prefix, family="-6")
                extra = [p for p in found if p not in cluster_ports["alpha"] and not node_port_range(p)]
                verdict(f"K21 a {label} reaches only the cluster ports of alpha's node address (IPv6)", not extra, f"unexpected: {extra}; all open: {found}")

        with subtest("pod: the kubelet, etcd, the supervisor and the API give an anonymous pod no data"):
            for name in ["alpha", "beta"]:
                code = http_code(beta, f"https://{fabric[name]['ipv4']}:10250/pods", prefix=in_pod)
                verdict(f"K22 the kubelet of {name} refuses an anonymous pod", code in ("000", "401", "403"), f"HTTP {code}")
                code = http_code(beta, f"http://{fabric[name]['ipv4']}:10255/pods", prefix=in_pod)
                verdict(f"K23 the kubelet read-only port of {name} is closed", code == "000", f"HTTP {code}")
            # control: the same plain-HTTP request from the pod gets an answer from a listener
            code = http_code(beta, f"http://{alpha_pod4}:8080/", prefix=in_pod)
            control("K23 the same request from the pod gets an HTTP answer from a pod's listener", code != "000", f"HTTP {code}")
            # 8443: the rke2 supervisor's HAProxy front (K-A2)
            ports = [2379, 2380, 2381, 9345, 8404] + ([8443] if rke2 else [])
            for port in ports:
                for label, prefix, node in [("pod on beta", in_pod, beta), ("pod on alpha", in_pod_alpha, alpha)]:
                    code, _ = node.execute(f"{prefix} socat -T 3 /dev/null TCP:{fabric['alpha']['ipv4']}:{port},connect-timeout=3")
                    verdict(f"K24 a {label} cannot connect to alpha:{port}", code != 0)
            # control: the same connect reaches the API from the pods
            for label, prefix, node in [("pod on beta", in_pod, beta), ("pod on alpha", in_pod_alpha, alpha)]:
                code, _ = node.execute(f"{prefix} socat -T 3 /dev/null TCP:{fabric['alpha']['ipv4']}:6443,connect-timeout=3")
                control(f"K24 the same connect from a {label} reaches alpha:6443", code == 0, f"rc={code}")
            if rke2:
                # control: the supervisor answers a member (its front 8443
                # binds loopback: K27)
                code, _ = beta.execute(f"socat -T 3 /dev/null TCP:{fabric['alpha']['ipv4']}:9345,connect-timeout=3")
                control("K24 a member connects to alpha:9345", code == 0, f"rc={code}")
            code = http_code(beta, f"https://{api_vip}:443/api/v1/namespaces/kube-system/secrets", prefix=in_pod)
            verdict("K25 the API refuses an anonymous request for secrets", code in ("401", "403"), f"HTTP {code}")
            token = alpha.succeed(f"{KUBECTL} exec hostile -- cat /var/run/secrets/kubernetes.io/serviceaccount/token").strip()
            beta.succeed(f"umask 077; printf 'Authorization: Bearer %s' '{token}' > /tmp/hostile-header")
            for path in ["/api/v1/namespaces/kube-system/secrets", "/api/v1/secrets", "/api/v1/nodes", "/api/v1/namespaces/default/pods"]:
                code = http_code(beta, f"https://{api_vip}:443{path}", prefix=in_pod, header="-H @/tmp/hostile-header")
                verdict(f"K26 the default service account may not read {path}", code == "403", f"HTTP {code}")
            # control: the token is valid and the API answers the pod
            code = http_code(beta, f"https://{api_vip}:443/version", prefix=in_pod, header="-H @/tmp/hostile-header")
            control("K25/K26 the pod's token is valid: the API serves it /version", code == "200", f"HTTP {code}")

        with subtest("the load-balancer fronts listen on loopback only"):
            # D76 (specs/design-kube.md §3.6): only the node itself dials
            # its fronts. Control: the node connects to each front on
            # loopback, so the listener is there and the probe works.
            for node in cluster:
                listeners = node.succeed("ss -Hltn | awk '{print $4}'").split()
                for port in front_ports[node.name]:
                    binds = sorted(l.rsplit(":", 1)[0] for l in listeners if l.endswith(f":{port}"))
                    verdict(f"K27 the front {port} of {node.name} listens on loopback only", binds == ["127.0.0.1", "[::1]"], f"binds: {binds}")
                    code4, _ = node.execute(f"nc -z -w 3 127.0.0.1 {port}")
                    code6, _ = node.execute(f"nc -z -w 3 ::1 {port}")
                    control(f"K27 {node.name} reaches its own front {port} on loopback", code4 == 0 and code6 == 0, f"rc IPv4 {code4}, IPv6 {code6}")
            for src, dst in [(beta, "alpha"), (alpha, "beta")]:
                # control: the same member reaches the other member's node
                # address on a port that is open to it
                open_port = 6443 if dst == "alpha" else 4240
                for key in ["ipv4", "ipv6"]:
                    code, _ = src.execute(f"nc -z -w 3 {fabric[dst][key]} {open_port}")
                    control(f"K27 {src.name} reaches {dst}:{open_port} ({key})", code == 0, f"rc={code}")
                    for port in front_ports[dst]:
                        code, _ = src.execute(f"nc -z -w 3 {fabric[dst][key]} {port}")
                        verdict(f"K27 a member ({src.name}) does not reach the front {port} of another member ({dst}, {key})", code != 0, f"rc={code}")
            for dst, node in [("alpha", alpha), ("beta", beta)]:
                # control: a port that the firewall opens for the test
                # answers mallory on the same node address, so the path
                # to the fronts is real
                node.succeed("systemd-run --unit k27-listener socat TCP6-LISTEN:9998,fork,reuseaddr EXEC:true")
                node.wait_until_succeeds("ss -tln | grep ':9998 ' >/dev/null", timeout=30)
                node.succeed("nft insert rule inet nixos-fw input tcp dport 9998 accept comment k27-control")
                for key in ["ipv4", "ipv6"]:
                    code, _ = mallory.execute(f"nc -z -w 3 -s {fabric['mallory'][key]} {fabric[dst][key]} 9998")
                    control(f"K27 mallory reaches an opened port on {dst}'s node address ({key})", code == 0, f"rc={code}")
                    for port in front_ports[dst]:
                        code, _ = mallory.execute(f"nc -z -w 3 -s {fabric['mallory'][key]} {fabric[dst][key]} {port}")
                        verdict(f"K27 a fabric member outside the cluster does not reach the front {port} of {dst} ({key})", code != 0, f"rc={code}")
                handle = node.succeed("nft -a list chain inet nixos-fw input | grep k27-control | awk '{print $NF}'").strip()
                node.succeed(f"nft delete rule inet nixos-fw input handle {handle}")
                node.succeed("systemctl stop k27-listener")

        with subtest("the cluster still works: logs and exec on the agent, node health"):
            # P6: the API server reaches the agent's kubelet; node-to-node health
            code, _ = alpha.execute(f"{KUBECTL} exec web -- hostname | grep -x web >/dev/null")
            verdict("K42 kubectl exec reaches a pod on the agent", code == 0)
            code, _ = alpha.execute(f"{KUBECTL} logs web --tail=1 && {KUBECTL} logs hostile-alpha --tail=1")
            verdict("K42 kubectl logs reaches the kubelets of both nodes", code == 0)
            # Cilium's node health probe dials 4240 on the node address
            for node, peer in [(alpha, "beta"), (beta, "alpha")]:
                for key in ["ipv4", "ipv6"]:
                    code, _ = node.execute(f"nc -z -w 3 {fabric[peer][key]} 4240")
                    verdict(f"K41 {node.name} reaches Cilium's health port on {peer} ({key})", code == 0)
            code, health = alpha.execute(
                f"timeout 300 sh -c 'until {KUBECTL} -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep \"Cluster health\" | grep \"2/2 reachable\"; do sleep 10; done' 2>&1"
            )
            verdict("K41 Cilium reports every node reachable", code == 0, health.strip()[-200:])
            for node in cluster:
                found = node.succeed("find /run/secrets* -path '*rancher-*-token-${distro}*' -name '*-token' -exec cut -c1-3 {} + | sort -u").split()
                info(f"K34 the join token prefixes of {node.name}; kube step 6 adds the CA pin (K10)", f"{found}")

        with subtest("Pod Security today; kube step 9 enforces baseline"):
            alpha.succeed(f"{KUBECTL} create namespace fresh")
            container = {"name": "main", "image": "busybox:1.36.1", "command": ["sleep", "infinity"], "securityContext": {"privileged": True}}
            overrides = "--overrides=\'" + json.dumps({"spec": {"containers": [container]}}) + "\'"
            code, out = alpha.execute(f"{KUBECTL} -n fresh run privileged --image=busybox:1.36.1 {overrides} 2>&1")
            info("K50 a privileged pod in a fresh namespace; kube step 9 refuses it", "admitted" if code == 0 else f"refused: {out.strip()[:200]}")

        # ------------------------------------------------------------------
        # A local account without root on a node
        # ------------------------------------------------------------------
        with subtest("local user: no secret of the cluster is readable without root"):
            for node in cluster:
                candidates = node.succeed(
                    "(find /etc/rancher /var/lib/rancher /run/secrets /run/secrets.d /run/haproxy -xdev "
                    "\\( -name '*.key' -o -name '*token*' -o -name '*.kubeconfig' -o -name '${distro}.yaml' "
                    "-o -name '*.sock' -o -name 'passwd' \\) \\( -type f -o -type s \\) ! -path '*/bin/*' ! -path '/etc/rancher/*/config.yaml' 2>/dev/null || true)"
                ).split()
                control(f"K30 the search finds the keys, tokens and sockets of {node.name}", len(candidates) >= 3, f"{len(candidates)} files: {candidates[:6]}")
                readable = node.succeed(
                    "(find /etc/rancher /var/lib/rancher /run/secrets /run/secrets.d /run/haproxy -xdev "
                    "\\( -name '*.key' -o -name '*token*' -o -name '*.kubeconfig' -o -name '${distro}.yaml' "
                    "-o -name '*.sock' -o -name 'passwd' \\) \\( -type f -o -type s \\) ! -path '*/bin/*' ! -path '/etc/rancher/*/config.yaml' 2>/dev/null || true) "
                    "| while read -r f; do if runuser -u nobody -- test -r \"$f\" 2>/dev/null; then echo \"$f\"; fi; done"
                ).split()
                verdict(f"K30 no key, token, kubeconfig or socket of {node.name} is readable by an unprivileged user", not readable, f"readable: {readable[:12]}")
                code, _ = node.execute("runuser -u nobody -- sh -c 'echo show info | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock' | grep -i pid >/dev/null")
                verdict(f"K31 the HAProxy admin socket of {node.name} refuses an unprivileged user", code != 0)
                code, _ = node.execute("echo show info | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep -i pid >/dev/null")
                control(f"K31 the HAProxy admin socket of {node.name} answers root", code == 0, f"rc={code}")
                # the join tokens themselves: search for their literal values
                token_files = node.succeed("find /run/secrets* -path '*rancher-*-token-${distro}*' -type f -name '*-token'").split()
                tokens = [node.succeed(f"cat '{f}'").strip() for f in token_files]
                control(f"K32/K33 {node.name} holds its join tokens", tokens and all(len(t) >= 16 for t in tokens), f"{len(tokens)} token(s) in {token_files}")
                args = node.succeed("ps -eo args")
                leaked = [f"{t[:4]}..." for t in tokens if t in args]
                verdict(f"K32 no join token shows in a process argument on {node.name}", not leaked, f"{leaked}")
                found = []
                for f in token_files:
                    # the value without its newline, as a fixed-string pattern
                    # file: never on a command line
                    node.succeed(f"umask 077; tr -d '\\n' < '{f}' > /root/k33-pattern")
                    found += node.succeed(
                        "grep -rIlF --exclude-dir=containerd --exclude-dir=db -f /root/k33-pattern "
                        "/etc/rancher /etc/systemd/system /var/lib/rancher/${distro} /run/secrets /run/secrets.d 2>/dev/null || true"
                    ).split()
                    node.succeed("rm -f /root/k33-pattern")
                found = sorted(set(found))
                control(f"K33 the search for the token values finds their own files on {node.name}", all(f in found for f in token_files), f"{found}")
                world = [f for f in found if node.execute(f"runuser -u nobody -- test -r '{f}'")[0] == 0]
                verdict(f"K33 no file with a join token is world-readable on {node.name}", not world, f"{world}")

        with subtest("outsider: the node LAN link as a Cilium device (D71 on a real node)"):
            # netfilter does not see a packet that eBPF hands to a local pod
            # on a Cilium device: only the clusterwide policy (kube step 7)
            # stands there. Last phase: it restarts Cilium.
            devices = alpha.succeed(f"{KUBECTL} -n kube-system get configmap cilium-config -o jsonpath='{{.data.devices}}'").strip()
            alpha.succeed(f"{KUBECTL} -n kube-system patch configmap cilium-config --type merge -p '{{\"data\":{{\"devices\":\"{devices} eth1\"}}}}'")
            alpha.succeed(f"{KUBECTL} -n kube-system rollout restart daemonset/cilium")
            alpha.wait_until_succeeds(f"{KUBECTL} -n kube-system rollout status daemonset/cilium --timeout=60s", timeout=600)
            beta.wait_until_succeeds(f"{in_pod} curl -s -m 5 -o /dev/null http://{web4}:8080/", timeout=300)
            alpha.wait_until_succeeds(f"{KUBECTL} -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep 'Devices:' | grep eth1 >/dev/null", timeout=300)
            alpha.succeed("sleep 45")
            outsider.succeed(f"ip route replace {alpha_pod4}/32 via {underlay['alpha']}")
            for address, target in [(web4, "beta"), (alpha_pod4, "alpha")]:
                code, _ = outsider.execute(f"nc -z -w 3 {address} 8080")
                info(f"K05d a pod on {target} and the outsider through a LAN link that is a Cilium device; kube step 7 closes it", "connects" if code == 0 else "refused")
            for node in cluster:
                info(f"K05d what the kube table of {node.name} dropped", f"{drops(node, KUBE_TABLE, OUTSIDE_TO_CLUSTER)} packets")

        print("HOSTILE SUMMARY")
        for key, safe, detail in RESULTS:
            print(f"  {'SAFE' if safe else 'GAP '} {key}" + (f" [{detail}]" if not safe else ""))
        for key, worked, detail in CONTROLS:
            print(f"  {'CONTROL OK  ' if worked else 'CONTROL FAIL'} {key}" + (f" [{detail}]" if not worked else ""))
        gaps = [key for key, safe, _ in RESULTS if not safe]
        failed = [key for key, worked, _ in CONTROLS if not worked]
        assert not gaps, f"{len(gaps)} gap(s): {gaps}"
        assert not failed, f"{len(failed)} positive control(s) did not work, so their verdicts prove nothing: {failed}"
        print("${lib.toUpper distro}_HOSTILE_OK")
    except Exception:
        for node in cluster:
            node.execute("nft list ruleset >&2; ip route >&2; ss -tlnp >&2")
        raise
  '';
}
