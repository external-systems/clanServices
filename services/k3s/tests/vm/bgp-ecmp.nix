# k3s-bgp-ecmp: the private fleet fabric by DEFAULT (D10) + the D9
# foreign-router contract, on a 3-node cluster with a plain-BIRD router
# fixture (MikroTik-style):
#   - no declared pools at all — the fabric pool, the BGP v2 resources, the
#     per-node BIRD, and the private CoreDNS all render by default,
#   - the private CoreDNS VIP (172.16.1.53 + fd11:1::53) is advertised by
#     the nodes hosting its replicas (ETP Local) and ECMP'd by the router,
#   - DNS: the <instance>.<domain> zone resolves via the VIP (wildcard
#     answer = the day-2 proxy stand-in); the opt-in svc zone rewrites to
#     svc.cluster.local through the cluster CoreDNS,
#   - ETP-Local withdrawal: scaling coredns-private to 1 replica withdraws
#     the removed node's advertisement; the VIP keeps resolving,
#   - firewall: BGP :179 listens only on the loopback link alias
#     (169.254.179.1), never on mesh/underlay; the :4179 upstream-session
#     listen artifact is dropped inbound.
#
# Underlay addressing is the test driver's deterministic assignment
# (alphabetical node order): alpha=192.168.1.1/2001:db8:1::1,
# beta=192.168.1.2/2001:db8:1::2, gamma=192.168.1.3/2001:db8:1::3,
# router=192.168.1.4/2001:db8:1::4.
{ lib, ... }:
let
  kube = import ../../../../lib/kube-cluster { inherit lib; };

  instanceName = "k3s";

  # The cluster's BIRD-side ASN (D9 derivation — pinned by
  # test_hashBgpAsnsPinnedValues).
  clusterBgpAsn = (kube.bgp.hashBgpAsns instanceName).bird;

  # Cluster-level settings, identical on every role (cross-role parity is
  # eval-asserted).
  clusterSettings = {
    network.transport = {
      service = "wireguard-mesh";
      instance = "mesh";
    };
    # Pinned id (§6.2): keeps CIDRs and the fabric pool blocks
    # (172.16.1.0/24 + fd11:1::/64) stable.
    cilium.id = 1;
    # Test-only (documented): the upstream-facing interface must be a
    # Cilium device for VIP ingress from the router VM.
    cilium.helmValues.devices = "wg-mesh eth1";
    bgp.upstreamPeers = [
      {
        address = "192.168.1.4";
        asn = 65001;
      }
      {
        address = "2001:db8:1::4";
        asn = 65001;
      }
    ];
    # D22: the wildcard target stand-in (a day-2 proxy would own this
    # address); svc zone opt-in proven live.
    fabric.coredns.wildcardAddress = "172.16.1.200";
    fabric.coredns.svcZone = true;
  };

  # Foreign-router fixture (D9 contract): accept ONLY the cluster's
  # shared-bgp pool blocks (the fabric pool here) as exact /32+/128, with
  # max-prefix limits; kernel export merges per-node paths into ECMP
  # routes (ECMP path count ≥ node count).
  routerBirdConf =
    let
      mkNeighbor = name: addr: channel: filter: ''
        protocol bgp node_${name} {
          local as 65001;
          neighbor ${addr} as ${toString clusterBgpAsn};
          passive on;
          hold time 9;
          keepalive time 3;
          connect retry time 5;
          ${channel} {
            import filter ${filter};
            import limit 100 action block;
            export none;
          };
        }
      '';
    in
    ''
      router id 192.168.1.4;
      protocol device {
        scan time 10;
      }
      protocol kernel kernel4 {
        ipv4 { export all; };
        merge paths on;
      }
      protocol kernel kernel6 {
        ipv6 { export all; };
        merge paths on;
      }
      filter accept_cluster4 {
        if net ~ [ 172.16.1.0/24{32,32} ] then accept;
        else reject;
      }
      filter accept_cluster6 {
        if net ~ [ fd11:1::/64{128,128} ] then accept;
        else reject;
      }
      ${mkNeighbor "alpha" "192.168.1.1" "ipv4" "accept_cluster4"}
      ${mkNeighbor "beta" "192.168.1.2" "ipv4" "accept_cluster4"}
      ${mkNeighbor "gamma" "192.168.1.3" "ipv4" "accept_cluster4"}
      ${mkNeighbor "alpha6" "2001:db8:1::1" "ipv6" "accept_cluster6"}
      ${mkNeighbor "beta6" "2001:db8:1::2" "ipv6" "accept_cluster6"}
      ${mkNeighbor "gamma6" "2001:db8:1::3" "ipv6" "accept_cluster6"}
    '';
in
{
  name = "k3s-bgp-ecmp";

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules.wireguard-mesh = ../../../wireguard-mesh/default.nix;
    exportInterfaces.node_transport = ../../../wireguard-mesh/node-transport-interface.nix;

    inventory = {
      meta.domain = "test.clan";

      machines = {
        alpha = { };
        beta = { };
        gamma = { };
        # The foreign router joins NO service instance; inventory
        # membership only gives the test node the clan machine base.
        router = { };
      };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = {
            alpha.settings.host = "alpha";
            beta.settings.host = "beta";
            gamma.settings.host = "gamma";
          };
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
            machines = {
              alpha.settings = {
                ipv4 = "192.168.77.1";
                ipv6 = "fd00:77::1";
              };
              beta.settings = {
                ipv4 = "192.168.77.2";
                ipv6 = "fd00:77::2";
              };
              gamma.settings = {
                ipv4 = "192.168.77.3";
                ipv6 = "fd00:77::3";
              };
            };
          };
        };

        k3s = {
          module.name = "k3s";
          module.input = "self";

          # NO declared pools: the private fabric (D10) is the default.
          # Cluster-level settings are role-uniform (eval-asserted).
          roles.server = {
            settings = clusterSettings;
            machines = {
              alpha.settings.clusterInit = true;
              beta = { };
            };
          };

          roles.agent = {
            settings = clusterSettings;
            machines.gamma = { };
          };
        };
      };
    };
  };

  nodes =
    let
      commonNode =
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
            pkgs.curl
            pkgs.jq
            pkgs.dnsutils
          ];
        };
    in
    {
      alpha =
        { ... }:
        {
          imports = [ commonNode ];
          environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
        };
      beta = { ... }: { imports = [ commonNode ]; };
      gamma = { ... }: { imports = [ commonNode ]; };

      # The foreign router (D9 contract fixture): a plain BIRD, NOT part of
      # the clan inventory.
      router =
        { pkgs, ... }:
        {
          virtualisation = {
            cores = 1;
            memorySize = 1024;
          };
          environment.systemPackages = [
            pkgs.jq
            pkgs.curl
            pkgs.dnsutils
          ];
          services.bird = {
            enable = true;
            package = pkgs.bird2;
            checkConfig = true;
            config = routerBirdConf;
          };
          networking.firewall.enable = false;
        };
    };

  testScript = ''
    def fail_dump(m):
        for cmd in [
            "journalctl -u k3s --no-pager -l | tail -n 80 >&2 || true",
            "journalctl -u k3s-k3s-bootstrap-apply --no-pager -l | tail -n 60 >&2 || true",
            "journalctl -u bird --no-pager -l | tail -n 60 >&2 || true",
            "kubectl get nodes,pods -A -o wide >&2 || true",
            "kubectl get service -A -o wide >&2 || true",
            "kubectl -n kube-system exec ds/cilium -- cilium-dbg shell -- bgp/peers >&2 || true",
            "ip route >&2; ip -6 route >&2",
            "kubectl get events -A --sort-by=.lastTimestamp | tail -n 80 >&2 || true",
        ]:
            m.execute(cmd)

    def router_dump():
        router.execute("journalctl -u bird --no-pager -l | tail -n 80 >&2 || true")
        router.execute("birdc show protocols >&2 || true")
        router.execute("birdc show route >&2 || true")
        router.execute("ip route >&2; ip -6 route >&2")

    try:
        start_all()

        for m in [alpha, beta, gamma]:
            m.wait_for_unit("systemd-networkd.service", timeout=120)
            m.wait_for_unit("haproxy.service", timeout=240)
            m.wait_for_unit("bird.service", timeout=240)
        router.wait_for_unit("bird.service", timeout=240)

        alpha.wait_for_unit("k3s.service", timeout=600)
        beta.wait_for_unit("k3s.service", timeout=600)
        gamma.wait_for_unit("k3s.service", timeout=600)

        alpha.wait_until_succeeds(
            "systemctl show -p Result --value k3s-k3s-bootstrap-apply | grep -q '^success$'",
            timeout=900,
        )
        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Ready node/alpha node/beta node/gamma --timeout=120s",
            timeout=300,
        )
        alpha.wait_until_succeeds("cilium status", timeout=180)

        # --- The private fabric renders by default (D10) ----------------
        alpha.succeed("kubectl get ciliumloadbalancerippools | grep -q k3s-fabric")
        alpha.wait_until_succeeds(
            "kubectl wait --for=condition=Ready pod -n kube-system -l k8s-app=coredns-private --timeout=180s",
            timeout=300,
        )
        # The private CoreDNS VIPs are the deterministic fabric addresses.
        alpha.wait_until_succeeds(
            "kubectl -n kube-system get service coredns-private -o jsonpath='{.status.loadBalancer.ingress}' | grep -q 172.16.1.53",
            timeout=240,
        )
        ingress = alpha.succeed(
            "kubectl -n kube-system get service coredns-private -o jsonpath='{.status.loadBalancer.ingress[*].ip}'"
        ).strip()
        assert "fd11:1::53" in ingress, f"v6 VIP missing: {ingress!r}"

        # --- BGP: every replica-hosting node advertises the VIP ---------
        # 2 replicas with soft anti-affinity on 3 nodes ⇒ exactly 2
        # advertisers (ETP Local) ⇒ 2 ECMP nexthops on the router.
        router.wait_until_succeeds(
            "birdc show protocols | grep -c 'BGP.*Established' | grep -q '^6$'",
            timeout=300,
        )
        router.wait_until_succeeds(
            "ip -j route show 172.16.1.53 | jq -e '.[0].nexthops | length == 2' >/dev/null",
            timeout=300,
        )
        router.wait_until_succeeds(
            "ip -j -6 route show fd11:1::53 | jq -e '.[0].nexthops | length == 2' >/dev/null",
            timeout=300,
        )

        # --- DNS over the fabric VIP (D22) -------------------------------
        # The instance zone wildcard answers with the day-2 proxy stand-in.
        router.wait_until_succeeds(
            "dig +short @172.16.1.53 www.k3s.test.clan A | grep -q '^172.16.1.200$'",
            timeout=180,
        )
        # Same over the v6 VIP.
        router.wait_until_succeeds(
            "dig +short @fd11:1::53 api.k3s.test.clan A | grep -q '^172.16.1.200$'",
            timeout=180,
        )
        # No v6 wildcard configured: AAAA answers NXDOMAIN (the zone exists
        # and serves negatives by default).
        out = router.succeed("dig @172.16.1.53 www.k3s.test.clan AAAA +noall +comments | grep -o 'status: [A-Z]*'")
        assert "NXDOMAIN" in out, f"expected NXDOMAIN for AAAA, got: {out!r}"
        # The svc zone (D22a opt-in) rewrites into svc.cluster.local and
        # resolves through the cluster CoreDNS.
        router.wait_until_succeeds(
            "dig +short @172.16.1.53 kubernetes.default.k3s.svc.test.clan A | grep -q '^10.2.0.1$'",
            timeout=180,
        )
        # cluster.local itself is NEVER served to clients (D21).
        out = router.succeed("dig @172.16.1.53 kubernetes.default.svc.cluster.local A +noall +comments | grep -o 'status: [A-Z]*' || true")
        assert "NOERROR" not in out or "ANSWER: 0" in router.succeed("dig @172.16.1.53 kubernetes.default.svc.cluster.local A +noall +comments | grep -o 'ANSWER: [0-9]*'"), \
            f"cluster.local must not be served: {out!r}"

        # --- Firewall: BGP exposure (§6.12, D9) ---------------------------
        for m in [alpha, beta, gamma]:
            m.succeed("ss -tln | grep -q '169.254.179.1:179 '")
            m.fail("ss -tln | grep ':179 ' | grep -v '169.254.179.1'")
        router.fail("nc -z -w3 192.168.1.1 179")
        router.fail("nc -z -w3 192.168.1.1 4179")

        # --- ETP-Local withdrawal (scale-down form) -----------------------
        # Removing one replica withdraws exactly its node's advertisement;
        # the VIP keeps resolving through the surviving advertiser.
        alpha.succeed("kubectl -n kube-system scale deployment/coredns-private --replicas=1")
        router.wait_until_succeeds(
            "ip -j route show 172.16.1.53 | jq -e '.[0].nexthops | length == 1' >/dev/null",
            timeout=300,
        )
        router.wait_until_succeeds(
            "dig +short @172.16.1.53 www.k3s.test.clan A | grep -q '^172.16.1.200$'",
            timeout=180,
        )
    except Exception:
        for m in [alpha, beta, gamma]:
            try:
                fail_dump(m)
            except Exception:
                pass
        router_dump()
        raise
  '';
}
