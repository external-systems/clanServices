# fleet-routing VM suite (SPEC §7, §6.13; D11/D13/D22/D33): a k3s cluster
# (alpha server+init, beta agent) plus three fleet hosts — client
# (client role), admin (admin role), router (router role) — and beta as
# the dual-role shape (cluster member AND admin, the kamrui-h1 shape).
#
#   - client: VIP routes installed (ECMP across both nodes), DNS stub
#     resolves ONLY <instance>.<domain> via the private CoreDNS VIP
#     (negative: svc/pod zones and cluster.local are NOT stubbed),
#   - admin: + svc/pod zone stubs and D13 pod-CIDR routes (the cluster
#     opted in; the peer entries flagged receivePodCIDRs),
#   - router: prefix ownership — filtered acceptance (VIPs only, pods
#     rejected), kernel forwarding on,
#   - beta (dual-role): ONE bird daemon, both fragments merged, one
#     router id.
#
# Session topology: cluster nodes dial OUT to the fleet hosts (upstream
# peers over the mesh); fleet BIRDs listen on their mesh addresses only.
#
# Underlay addressing is the test driver's deterministic assignment
# (alphabetical node order): admin=192.168.1.1, alpha=192.168.1.2,
# beta=192.168.1.3, client=192.168.1.4, router=192.168.1.5.
{ self, inputs }:
{ lib, ... }:
let
  # Cluster-level settings, identical on every machine (cross-role parity
  # is eval-asserted per machine).
  clusterSettings = {
    # The legacy fleet-routing VM inventory exercises the node_transport
    # compatibility view of the fabric reference (routed-fabric itself
    # lands on its own branch).
    network.fabric = {
      service = "wireguard-mesh";
      instance = "mesh";
    };
    # Pinned id (§6.2): keeps CIDRs and the fabric pool blocks
    # (172.16.1.0/24 + fd11:1::/64) stable.
    cilium.id = 1;
    fabric.coredns = {
      # D22: the wildcard target stand-in (a day-2 proxy would own this
      # address); svc+pod zone opt-ins proven live on the admin host.
      wildcardAddress = "172.16.1.200";
      svcZone = true;
      podZone = true;
    };
    bgp = {
      # Pod-pool advertisements are unconditional in the new contract
      # (D49 native routing); ClusterIPs stay opted in here so the admin
      # role's svc consumption remains VM-proven.
      advertiseClusterIPs = true;
    };
  };

  fleetRoleSettings = {
    mesh = {
      service = "wireguard-mesh";
      instance = "mesh";
    };
    clusters = [
      {
        service = "k3s";
        instance = "k3s";
      }
    ];
  };

  # Mesh peer endpoints come from the underlay (written per-machine —
  # role-level settings reads are deprecated in clan-core).
  endpointSources = [
    {
      service = "clan-core/internet";
      instance = "underlay";
    }
  ];
in
{
  name = "fleet-routing";

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules.wireguard-mesh = ../../../wireguard-mesh/default.nix;
    modules.k3s = lib.modules.importApply ../../../k3s/default.nix { inherit self inputs; };
    exportInterfaces.node_transport = ../../../wireguard-mesh/node-transport-interface.nix;

    inventory = {
      meta.domain = "test.clan";

      machines = {
        alpha = { };
        beta = { };
        client = { };
        admin = { };
        router = { };
      };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = {
            alpha.settings.host = "alpha";
            beta.settings.host = "beta";
            client.settings.host = "client";
            admin.settings.host = "admin";
            router.settings.host = "router";
          };
        };

        mesh = {
          module.name = "wireguard-mesh";
          module.input = "self";
          roles.peer.machines = {
            alpha.settings = {
              inherit endpointSources;
              ipv4 = "192.168.77.1";
              ipv6 = "fd00:77::1";
            };
            beta.settings = {
              inherit endpointSources;
              ipv4 = "192.168.77.2";
              ipv6 = "fd00:77::2";
            };
            client.settings = {
              inherit endpointSources;
              ipv4 = "192.168.77.10";
              ipv6 = "fd00:77::10";
            };
            admin.settings = {
              inherit endpointSources;
              ipv4 = "192.168.77.11";
              ipv6 = "fd00:77::11";
            };
            router.settings = {
              inherit endpointSources;
              ipv4 = "192.168.77.12";
              ipv6 = "fd00:77::12";
            };
          };
        };

        k3s = {
          module.name = "k3s";
          module.input = "self";
          roles.server.machines.alpha.settings = clusterSettings // {
            clusterInit = true;
          };
          roles.agent.machines.beta.settings = clusterSettings;
        };

        fleet = {
          module.name = "fleet-routing";
          module.input = "self";
          roles = {
            client.machines.client.settings = fleetRoleSettings;
            # admin VM plus the dual-role cluster member (D33).
            admin.machines = {
              admin.settings = fleetRoleSettings;
              beta.settings = fleetRoleSettings;
            };
            router.machines.router.settings = fleetRoleSettings // {
              prefixes = [
                "172.16.0.0/12"
                "fd11::/16"
              ];
            };
          };
        };
      };
    };
  };

  nodes =
    let
      clusterNode =
        { pkgs, ... }:
        {
          virtualisation = {
            cores = 2;
            memorySize = 3584;
            diskSize = 8192;
          };
          environment.systemPackages = [
            pkgs.kubectl
            pkgs.cilium-cli
            pkgs.jq
            pkgs.dnsutils
            pkgs.tcpdump
          ];
        };
      fleetNode =
        { pkgs, ... }:
        {
          virtualisation = {
            cores = 1;
            memorySize = 1024;
          };
          environment.systemPackages = [
            pkgs.jq
            pkgs.dnsutils
            pkgs.tcpdump
            pkgs.curl
          ];
        };
    in
    {
      alpha =
        { ... }:
        {
          imports = [ clusterNode ];
          environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
        };
      beta = { ... }: { imports = [ clusterNode ]; };
      client = { ... }: { imports = [ fleetNode ]; };
      admin = { ... }: { imports = [ fleetNode ]; };
      router = { ... }: { imports = [ fleetNode ]; };
    };

  testScript = ''
    def packet_dump(m):
        print("fleet-routing packet diagnostics")
        for cmd in [
            "tcpdump -nn -r /tmp/wg.pcap 'icmp or tcp port 179' 2>/dev/null | tail -n 120 >&2",
            "tcpdump -nn -r /tmp/underlay.pcap 'icmp or udp port 51820' 2>/dev/null | tail -n 120 >&2",
        ]:
            m.execute(cmd)

    def dump(m):
        print("fleet-routing host failure diagnostics")
        for cmd in [
            "journalctl -u bird --no-pager -l | tail -n 80 >&2 || true",
            "journalctl -u systemd-networkd --no-pager -l | tail -n 60 >&2 || true",
            "journalctl -u systemd-resolved --no-pager -l | tail -n 100 >&2 || true",
            "dig +time=2 +tries=1 +noall +comments +answer @172.16.1.53 www.k3s.test.clan A >&2 || true",
            "dig +time=2 +tries=1 +noall +comments +answer @fd11:1::53 www.k3s.test.clan A >&2 || true",
            "ip -4 addr show >&2; ip -6 addr show >&2",
            "ip route >&2; ip -6 route >&2",
            "ip route get 172.16.1.53 >&2; ip -6 route get fd11:1::53 >&2",
            "ip route get 192.168.77.1 >&2; ip -6 route get fd00:77::1 >&2",
            "ping -c 2 -W 2 192.168.77.1 >&2 || true; ping -c 2 -W 2 fd00:77::1 >&2 || true",
            "nc -z -w 3 192.168.77.1 179 >&2 || true; nc -z -w 3 fd00:77::1 179 >&2 || true",
            "wg show >&2 || true",
            "resolvectl status >&2 || true",
            "ss -tlnp >&2 || true",
            "birdc show protocols all >&2 || true",
            "birdc show route >&2 || true",
            "birdc show route table fr_fleet_mesh_igp_table4 >&2 || true",
            "birdc show route table fr_fleet_mesh_igp_table6 >&2 || true",
        ]:
            m.execute(cmd)

    def cluster_dump(m):
        print("fleet-routing cluster failure diagnostics")
        for cmd in [
            "journalctl -u k3s --no-pager -l | tail -n 100 >&2 || true",
            "journalctl -u k3s-k3s-bootstrap-apply --no-pager -l | tail -n 80 >&2 || true",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl get nodes,pods -A -o wide >&2 || true",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n kube-system get service/coredns-private -o yaml >&2 || true; kubectl -n kube-system get configmap/coredns-private -o yaml >&2 || true",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=coredns-private -o yaml >&2 || true",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n kube-system logs deployment/coredns-private --all-containers --prefix --tail=100 >&2 || true",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n kube-system logs deployment/coredns --all-containers --prefix --previous --tail=80 >&2 || true; kubectl -n kube-system logs deployment/coredns --all-containers --prefix --tail=80 >&2 || true",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; for ip in $(kubectl -n kube-system get pods -l k8s-app=coredns-private -o jsonpath='{.items[*].status.podIP}'); do echo pod-dns-$ip >&2; dig +time=1 +tries=1 +noall +comments +answer @$ip www.k3s.test.clan A >&2 || true; done",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; ip=$(kubectl -n kube-system get service/coredns-private -o jsonpath='{.spec.clusterIP}'); dig +time=1 +tries=1 +noall +comments +answer @$ip www.k3s.test.clan A >&2 || true; dig +time=1 +tries=1 +noall +comments +answer @172.16.1.53 www.k3s.test.clan A >&2 || true",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl get ciliumbgpclusterconfigs.cilium.io,ciliumbgppeerconfigs.cilium.io,ciliumbgpadvertisements.cilium.io,ciliumbgpnodeconfigs.cilium.io >&2 || true",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n kube-system get configmap/cilium-config -o yaml >&2 || true",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n kube-system logs deployment/clustermesh-apiserver --all-containers --prefix --previous --tail=100 >&2 || true; kubectl -n kube-system logs deployment/clustermesh-apiserver --all-containers --prefix --tail=100 >&2 || true",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl logs -n kube-system -l k8s-app=cilium --all-containers --tail=150 >&2 || true",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; for p in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do echo $p >&2; kubectl -n kube-system exec $p -c cilium-agent -- cilium-dbg service list >&2 || true; kubectl -n kube-system exec $p -c cilium-agent -- cilium-dbg shell -- bgp/peers -f detailed >&2 || true; done",
            "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl get events -A --sort-by=.lastTimestamp | tail -n 60 >&2 || true",
        ]:
            m.execute(cmd)

    try:
        start_all()

        for m in [alpha, beta, client, admin, router]:
            m.wait_for_unit("systemd-networkd.service", timeout=120)
            m.wait_for_unit("bird.service", timeout=240)

        for m in [alpha, admin]:
            m.succeed("tcpdump -U -ni wg-mesh -w /tmp/wg.pcap &")
            m.succeed("tcpdump -U -ni eth1 -w /tmp/underlay.pcap &")

        alpha.wait_for_unit("k3s.service", timeout=600)
        alpha.execute("sleep 60")
        cluster_dump(alpha)
        beta.wait_for_unit("k3s.service", timeout=600)

        # is-active latches only after a SUCCESSFUL oneshot exit
        # (RemainAfterExit); `systemctl show -p Result` reads "success"
        # even before the unit's first run, which would pass vacuously.
        alpha.wait_until_succeeds(
            "systemctl is-active --quiet k3s-k3s-bootstrap-apply",
            timeout=900,
        )
        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s",
            timeout=300,
        )
        alpha.wait_until_succeeds("cilium status", timeout=180)
        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Ready pod -n kube-system -l k8s-app=coredns-private --timeout=180s",
            timeout=300,
        )
        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Available deployment/coredns -n kube-system --timeout=180s",
            timeout=300,
        )

        # --- Sessions: both cluster nodes dial all three fleet hosts ----
        for m in [client, admin, router]:
            m.wait_until_succeeds(
                "birdc show protocols | grep -c 'BGP.*Established' | grep -q '^4$'",
                timeout=600,
            )
            m.wait_until_succeeds(
                "wg show interfaces | tr ' ' '\n' | grep -c '^fr' | grep -q '^2$'",
                timeout=120,
            )
        beta.wait_until_succeeds(
            "wg show interfaces | tr ' ' '\n' | grep -c '^fr' | grep -q '^1$'",
            timeout=120,
        )

        # --- client: VIP routes + base-zone DNS stub ONLY ---------------
        client.wait_until_succeeds(
            "ip -j route show 172.16.1.53 | jq -e '.[0].nexthops | (length == 2) and (map(.dev) | unique | length == 2)' >/dev/null",
            timeout=300,
        )
        client.wait_until_succeeds(
            "ip -j -6 route show fd11:1::53 | jq -e '.[0].nexthops | (length == 2) and (map(.dev) | unique | length == 2)' >/dev/null",
            timeout=300,
        )
        # Direct dual-stack round trips over the VIPs (bypass the stub).
        client.wait_until_succeeds(
            "dig +short @172.16.1.53 www.k3s.test.clan A | grep -q '^172.16.1.200$'",
            timeout=180,
        )
        client.wait_until_succeeds(
            "dig +short @fd11:1::53 www.k3s.test.clan A | grep -q '^172.16.1.200$'",
            timeout=180,
        )
        packet_dump(alpha)
        packet_dump(admin)
        # The stub: system resolution of the instance zone works...
        client.wait_until_succeeds(
            "resolvectl query www.k3s.test.clan | grep -q '^172.16.1.200'",
            timeout=180,
        )
        # ...and NOTHING else: no svc zone (client role), never
        # cluster.local (D21).
        client.fail("resolvectl query kubernetes.default.k3s.svc.test.clan")
        client.fail("resolvectl query kubernetes.default.svc.cluster.local")
        # D13 default: no pod CIDR routes on the client.
        client.fail("ip route show | grep -q '^10\\.1\\.'")
        client.fail("ip -6 route show | grep -q '^fd10:1:'")

        # --- admin: svc/pod zones + D13 pod routes ----------------------
        admin.wait_until_succeeds(
            "resolvectl query kubernetes.default.k3s.svc.test.clan | grep -q '^10.2.0.1'",
            timeout=300,
        )
        # Pod zone (dash-form rewrite -> cluster CoreDNS `pods insecure`).
        podip = alpha.succeed(
            "kubectl get pod -n kube-system -l k8s-app=coredns-private -o jsonpath='{.items[0].status.podIP}'"
        ).strip()
        dashed = podip.replace(".", "-")
        admin.wait_until_succeeds(
            f"resolvectl query {dashed}.kube-system.k3s.pods.test.clan | grep -q '^{podip}$'",
            timeout=300,
        )
        # D13: pod CIDR routes installed (via the mesh, ECMP where both
        # nodes advertise their own /24).
        admin.wait_until_succeeds(
            "ip route show | grep -qE '^10\\.1\\.[0-9]+\\.0/24'",
            timeout=300,
        )
        admin.wait_until_succeeds(
            "ip -6 route show | grep -qE '^fd10:1:[0-9a-f:]+/64'",
            timeout=300,
        )
        # ...but the router does NOT get pod routes (D13 is admin-only;
        # its prefixes don't own 10/8 either).
        router.fail("birdc show route | grep -q '10\\.1\\.'")

        # --- router role: filtered acceptance + forwarding --------------
        router.wait_until_succeeds(
            "ip -j route show 172.16.1.53 | jq -e '.[0].nexthops | (length == 2) and (map(.dev) | unique | length == 2)' >/dev/null",
            timeout=300,
        )
        router.succeed("sysctl -n net.ipv4.ip_forward | grep -q '^1$'")
        router.succeed("sysctl -n net.ipv6.conf.all.forwarding | grep -q '^1$'")
        # The router's acceptance filter takes only pool VIPs as /32+/128
        router.succeed("birdc show route | grep -q '172.16.1.53/32'")

        # --- dual role (beta: cluster member + admin, kamrui-h1 shape) --
        beta.succeed("grep -c 'protocol device' /etc/bird/bird.conf | grep -q '^1$'")
        beta.succeed("grep -q 'fragment kube-cluster-k3s' /etc/bird/bird.conf")
        beta.succeed("grep -q 'fragment fleet-routing-fleet' /etc/bird/bird.conf")
        # its own Cilium<->BIRD loopback session is up AND the fleet
        # admin stubs resolve
        beta.wait_until_succeeds(
            "birdc show protocols k3s_cilium | grep -q 'Established'",
            timeout=300,
        )
        beta.wait_until_succeeds(
            "resolvectl query kubernetes.default.k3s.svc.test.clan | grep -q '^10.2.0.1'",
            timeout=300,
        )

        # --- firewall: fleet hosts listen only on their mesh addresses --
        client.succeed("ss -tln | grep -q '192.168.77.10:179 '")
        client.succeed("ss -tln | grep -F '[fd00:77::10]:179 '")
        client.fail("ss -tln | grep ':179 ' | grep -v -F -e '192.168.77.10:179' -e '[fd00:77::10]:179'")
        # nothing BGP on the underlay (positive-negative, §6.12)
        alpha.fail("nc -z -w3 192.168.1.4 179")
    except Exception:
        for m in [client, admin, router, alpha, beta]:
            try:
                dump(m)
            except Exception:
                pass
        try:
            cluster_dump(alpha)
        except Exception:
            pass
        raise
  '';
}
