# BGP v2 resource rendering (D9 revised round 14/15) and the private fleet
# fabric (D10).
#
# Topology (D9/D48/D55): Cilium's BGP control plane originates pod-pool and
# authorized Service routes and dials OUT to the node's ONE host FRR over a
# single node-local `::1` session carrying BOTH address families (no
# localPort — Cilium listens on no :179; hold 9 / keepalive 3 / connect
# retry 5 because Cilium has no BFD). FRR — rendered and owned exclusively
# by routed-fabric (D19) — accepts the session with `neighbor ::1 capability
# extended-nexthop`, rewrites the loopback next hop to the node's stable
# fabric address, and exchanges filtered routes across the fabric. The
# distro services NEVER render a routing stack; they publish the facts
# routed-fabric consumes (kube_cluster export) and these Cilium-side CRs.
# Cilium agents never peer with each other; cluster-side bgp.upstreamPeers
# is gone (border owns upstream transit, D56).
#
# Determinism (D9): two deterministic private 32-bit ASNs per cluster
# (RFC 6996 range 4200000000–4294967294) hashed from the instance name: the
# Cilium-side ASN and the host-side ASN (used until the fabric's real node
# ASN arrives from routed_fabric's export, which wins). Router ids: Cilium's
# default allocation (the node's IPv4 address).
{ lib }:
let
  cidrLib = import ./cidr.nix { inherit lib; };

  # First 8 hex chars of sha256(s) as a 32-bit int (same scheme as the
  # cilium id hash in default.nix; pure Nix, no IFD).
  hash32 =
    s:
    let
      hexVal =
        c:
        let
          digits = lib.stringToCharacters "0123456789abcdef";
          idx = lib.findFirst (i: builtins.elemAt digits i == c) (-1) (lib.genList (x: x) 16);
        in
        if idx == -1 then throw "kube-cluster/bgp: bad hex digit '${c}' in hash" else idx;
    in
    lib.foldl' (acc: c: acc * 16 + hexVal c) 0 (
      lib.stringToCharacters (lib.substring 0 8 (builtins.hashString "sha256" s))
    );

  asnBase = 4200000000;
  asnSpan = 4294967294 - asnBase; # 94967294 values

  # BIRD-safe symbol form of a name (no '-' or '.'). LEGACY — consumed by
  # the legacy fleet-routing service until its deletion (5R3).
  birdSym = s: lib.replaceStrings [ "-" "." ] [ "_" "_" ] s;

  mergeAttrs = items: lib.foldl' (acc: item: acc // item) { } items;
in
rec {
  # D9: two deterministic private 32-bit ASNs per cluster. Derivation:
  # sha256("kube-cluster-bgp-cilium:<instance>") / ("...-host:<instance>"),
  # first 8 hex chars as u32, mapped into 4200000000..4294967293 by modulo
  # (the top of the RFC 6996 range is excluded so the collision fallback
  # +1 stays in range).
  hashBgpAsns =
    instanceName:
    let
      cilium = asnBase + lib.mod (hash32 "kube-cluster-bgp-cilium:${instanceName}") asnSpan;
      host0 = asnBase + lib.mod (hash32 "kube-cluster-bgp-host:${instanceName}") asnSpan;
      host = if host0 == cilium then host0 + 1 else host0;
    in
    {
      inherit cilium host;

      # LEGACY alias (pre-round-14 salt) — consumed by the legacy
      # fleet-routing service until its outright deletion (5R3); new code
      # must use `host`.
      bird = asnBase + lib.mod (hash32 "kube-cluster-bgp-bird:${instanceName}") asnSpan;
    };

  # LEGACY helpers consumed by the legacy fleet-routing service until its
  # deletion (5R3). New code must not use these.
  inherit birdSym;

  hashAsn = salt: name: asnBase + lib.mod (hash32 "${salt}:${name}") asnSpan;

  # Resolved ASNs: explicit pins win over the hashed defaults — the escape
  # hatch for a fleet-wide ASN collision (fleet-asserted), parallel to the
  # cilium.id pin (§6.2). `host` is the fallback host-side ASN; the fabric
  # node ASN from routed_fabric's export supersedes it wherever the fabric
  # reference resolves (D9 revised).
  resolveBgpAsns =
    { instanceName, settings }:
    let
      hashed = hashBgpAsns instanceName;
    in
    {
      cilium = if settings.bgp.ciliumASN != null then settings.bgp.ciliumASN else hashed.cilium;
      host = if settings.bgp.hostASN != null then settings.bgp.hostASN else hashed.host;
    };

  # Fabric pool blocks (D10): RFC1918 + ULA derived from the resolved
  # cilium id (overridable). 172.16.<id>.0/24 sits inside 172.16.0.0/12 for
  # every legal id (1–255) and is disjoint from the id-derived pod/service
  # space (10/8 + fd10::/16) and the mesh hash space (192.168/16 +
  # fd77::/16); non-overlap with explicit pod/service CIDR overrides is
  # eval-asserted (assertions.nix reservedCidrs).
  fabricBlocks =
    { ciliumId, settings }:
    {
      v4 =
        if settings.fabric.ipv4Block != null then
          settings.fabric.ipv4Block
        else
          "172.16.${toString ciliumId}.0/24";
      v6 =
        if settings.fabric.ipv6Block != null then
          settings.fabric.ipv6Block
        else
          "fd11:${toString ciliumId}::/64";
    };

  # Well-known core VIPs inside the fabric blocks: offset 53 (the DNS
  # port) is the private CoreDNS VIP (D22 substrate).
  fabricCoreDNSVips =
    { ciliumId, settings }:
    let
      blocks = fabricBlocks { inherit ciliumId settings; };
    in
    {
      ipv4 = cidrLib.addressAt blocks.v4 53;
      ipv6 = cidrLib.addressAtV6 blocks.v6 83; # 0x53
    };

  # The default private fabric pool (D10): one cluster-global shared-bgp
  # pool per cluster, on by default. Returns null when fabric.enable=false.
  mkFabricPool =
    {
      instanceName,
      ciliumId,
      settings,
    }:
    if !settings.fabric.enable then
      null
    else
      let
        blocks = fabricBlocks { inherit ciliumId settings; };
      in
      {
        name = "${instanceName}-fabric";
        blocks = [
          blocks.v4
          blocks.v6
        ];
        serviceSelector."clan.lol/pool" = "${instanceName}-fabric";
        delivery = "shared-bgp";
        owner = null;
        candidates = [ ];
      };

  # The BGP v2 resource set (D9 revised), rendered iff node-bgp or
  # shared-bgp pools exist (§6.12). Returns kubenix typed-tree fragments
  # (custom types registered in bundle.nix).
  #
  # ONE node-local `::1` session per node (no localPort, both AFs, D55);
  # advertisements: the local CiliumPodIPPool allocations (REQUIRED for
  # native routing — FRR distributes remote pod-pool routes, D49/D13) plus
  # the pool VIPs of the BGP-delivered pools (shared-bgp: every healthy
  # eligible node; node-bgp: owner-only by pool serviceSelector + ETP
  # Local). ClusterIP stays an explicit opt-in (D13).
  mkBgpResources =
    {
      instanceName,
      asns,
      hostAsns ? { },
      # [ machineName ] — one CiliumBGPClusterConfig per node (overlapping
      # node selectors are rejected by Cilium, so we never share one).
      members,
      # names of the cluster's shared-bgp pools (advertised VIP sources)
      sharedBgpPoolNames,
      # owners of the cluster's node-bgp pools (D8)
      nodeBgpPoolOwners ? { },
      advertiseClusterIPs ? false,
      manifestLabels,
    }:
    let
      nodeAdvertLabel = m: { "clan.lol/bgp-advertisement-node" = m; };
      commonAdvertisements = mergeAttrs (
        map (
          m:
          let
            labels = manifestLabels // nodeAdvertLabel m;
          in
          {
            # Native routing requires every node's local pool allocations.
            "${instanceName}-${m}-pod-pools" = {
              metadata.labels = labels;
              spec.advertisements = [
                {
                  advertisementType = "CiliumPodIPPool";
                  selector.matchLabels."clan.lol/cluster" = instanceName;
                }
              ];
            };
          }
          // lib.optionalAttrs (sharedBgpPoolNames != [ ]) {
            "${instanceName}-${m}-service-vips" = {
              metadata.labels = labels;
              spec.advertisements = [
                {
                  advertisementType = "Service";
                  service.addresses = [ "LoadBalancerIP" ];
                  selector.matchExpressions = [
                    {
                      key = "clan.lol/pool";
                      operator = "In";
                      values = sharedBgpPoolNames;
                    }
                  ];
                }
              ];
            };
          }
          // lib.optionalAttrs advertiseClusterIPs {
            "${instanceName}-${m}-cluster-ips" = {
              metadata.labels = labels;
              spec.advertisements = [
                {
                  advertisementType = "Service";
                  service.addresses = [ "ClusterIP" ];
                  selector.matchExpressions = [
                    {
                      key = "clan.lol/cluster";
                      operator = "NotIn";
                      values = [ "never" ];
                    }
                  ];
                }
              ];
            };
          }
        ) members
      );
      ownerAdvertisements = mergeAttrs (
        map (
          m:
          let
            ownerPools = lib.filterAttrs (_: owner: owner == m) nodeBgpPoolOwners;
          in
          lib.optionalAttrs (ownerPools != { }) {
            "${instanceName}-${m}-node-vips" = {
              metadata.labels = manifestLabels // nodeAdvertLabel m;
              spec.advertisements = [
                {
                  advertisementType = "Service";
                  service.addresses = [ "LoadBalancerIP" ];
                  selector.matchExpressions = [
                    {
                      key = "clan.lol/pool";
                      operator = "In";
                      values = builtins.attrNames ownerPools;
                    }
                  ];
                }
              ];
            };
          }
        ) members
      );
    in
    {
      ciliumBGPPeerConfigs = lib.listToAttrs (
        map (m: {
          name = "${instanceName}-${m}-frr";
          value = {
            metadata.labels = manifestLabels;
            spec = {
              timers = {
                holdTimeSeconds = 9;
                keepAliveTimeSeconds = 3;
                connectRetryTimeSeconds = 5;
              };
              families = [
                {
                  afi = "ipv4";
                  safi = "unicast";
                  advertisements.matchLabels = nodeAdvertLabel m;
                }
                {
                  afi = "ipv6";
                  safi = "unicast";
                  advertisements.matchLabels = nodeAdvertLabel m;
                }
              ];
            };
          };
        }) members
      );

      ciliumBGPClusterConfigs = lib.listToAttrs (
        map (m: {
          name = "${instanceName}-${m}";
          value = {
            metadata.labels = manifestLabels;
            spec = {
              nodeSelector.matchLabels."kubernetes.io/hostname" = m;
              bgpInstances = [
                {
                  name = "${instanceName}-frr";
                  localASN = asns.cilium;
                  peers = [
                    {
                      name = "frr";
                      peerASN = hostAsns.${m} or asns.host;
                      peerAddress = "::1";
                      peerConfigRef.name = "${instanceName}-${m}-frr";
                    }
                  ];
                }
              ];
            };
          };
        }) members
      );

      ciliumBGPAdvertisements = commonAdvertisements // ownerAdvertisements;
    };
}
