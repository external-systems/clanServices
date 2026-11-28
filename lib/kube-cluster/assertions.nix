# Eval assertions (§6.12). mkClusterAssertions covers cluster shape;
# mkPoolAssertions covers the D8 pool model plus the D9/D10 BGP/fabric
# coupling; mkBgpAsnAssertions covers the D9 node-ASN/Cilium-ASN eBGP
# invariant.
{
  lib,
  hashCiliumId,
}: let
  cidr = import ./cidr.nix {inherit lib;};
  bgpLib = import ./bgp.nix {inherit lib;};
  transport = import ./transport.nix {inherit lib;};

  prefixLen = block: builtins.fromJSON (builtins.elemAt (lib.splitString "/" block) 1);
in {
  mkClusterAssertions = {
    instanceName,
    roleMembers,
    settings,
    # machine name -> the member's resolved node_transport facts (null:
    # the member has no export from network.fabric)
    transportFacts,
    # [ { name, settings } ] — the fully merged per-machine settings of
    # every cluster member, name = "<role>/<machine>" (for the parity
    # check across all machines of all roles).
    roleSettings ? [],
    # K-A8: the distro's own cluster-level options (rke2: `profile`),
    # checked for parity beside the shared ones
    extraClusterLevel ? [],
    # the resolved pod/service CIDRs (cilium.nix resolveCidrs), for the
    # overlap and prefix-length checks; null skips them
    resolvedCidrs ? null,
  }: let
    serverMembers = lib.filter (m: m.role == "server") roleMembers;
    serverCount = builtins.length serverMembers;

    # K6: a CIDR family pair is explicit as a whole or derived as a whole
    # (one explicit family would leave the other null).
    halfPair = a: b: (a == null) != (b == null);
    resolvedList = lib.optionals (resolvedCidrs != null) (
      lib.filter (c: c.cidr != null) [
        {
          name = "pod IPv4";
          cidr = resolvedCidrs.podCIDRv4;
        }
        {
          name = "pod IPv6";
          cidr = resolvedCidrs.podCIDRv6;
        }
        {
          name = "service IPv4";
          cidr = resolvedCidrs.serviceCIDRv4;
        }
        {
          name = "service IPv6";
          cidr = resolvedCidrs.serviceCIDRv6;
        }
      ]
    );
    cidrOverlaps =
      lib.concatMap (
        a:
          map (b: "${a.name} ${a.cidr} overlaps ${b.name} ${b.cidr}") (
            lib.filter (b: a.name < b.name && cidr.overlap a.cidr b.cidr) resolvedList
          )
      )
      resolvedList;
    # Cilium's pod pool hands every node a /24 (IPv4) and a /64 (IPv6)
    # (bundle.nix mkPodIPPoolResource maskSize), so the pod CIDRs must be
    # at least that large.
    podMaskViolations = lib.optionals (resolvedCidrs != null) (
      lib.optional (
        resolvedCidrs.podCIDRv4 != null && prefixLen resolvedCidrs.podCIDRv4 > 24
      ) "pod IPv4 ${resolvedCidrs.podCIDRv4} is smaller than the per-node /24"
      ++ lib.optional (
        resolvedCidrs.podCIDRv6 != null && prefixLen resolvedCidrs.podCIDRv6 > 64
      ) "pod IPv6 ${resolvedCidrs.podCIDRv6} is smaller than the per-node /64"
    );
    clusterInitMembers = lib.filter (m: m.settings.clusterInit) serverMembers;

    # The members' node addresses come from the fabric's node_transport
    # export (D72: the fabric is the only transport; manual addresses
    # were removed in round 67, D76). A member without an export has
    # none; the assertion below names it.
    memberAddrs =
      map (
        m: let
          facts = transportFacts.${m.machineName} or null;
        in
          if facts == null
          then {}
          else facts
      )
      roleMembers;
    memberIpv4s = map (a: a.ipv4 or null) memberAddrs;
    memberIpv6s = map (a: a.ipv6 or null) memberAddrs;

    # Resolved id per member (explicit pin or the hashed default); the
    # whole cluster must resolve to ONE id — a per-member pin drift
    # would split CIDRs/DNS/HAProxy ports across the fleet.
    resolvedId =
      if settings.cilium.id != null
      then settings.cilium.id
      else hashCiliumId instanceName;
    memberId = m: let
      explicit = m.settings.cilium.id or null;
    in
      if explicit != null
      then explicit
      else hashCiliumId instanceName;

    membersMissingFacts =
      lib.filter (
        m: (transportFacts.${m.machineName} or null) == null
      )
      roleMembers;

    # Invariant 7: topology overrides must be non-empty (null = the
    # instance-name default, applied at render).
    memberTopology = m: m.settings.topology or {};
    emptyTopology =
      lib.filter (
        m: (memberTopology m).region or null == "" || (memberTopology m).zone or null == ""
      )
      roleMembers;

    # Cross-role parity: the cluster-level option groups must be
    # identical on every machine of every role, otherwise the bundle,
    # the per-member exports, and the assertions disagree silently.
    clusterLevelOf = rs:
      lib.getAttrs [
        "cilium"
        "pools"
        "bgp"
        "fabric"
        "mesh"
        "meshGroup"
        "domain"
        "distroDefaults"
        "coredns"
        "bootstrap"
        "firewall"
      ]
      rs
      // lib.getAttrs (lib.filter (n: rs ? ${n}) extraClusterLevel) rs
      // {
        networkFabric = rs.network.fabric or null;
      };
    roleDrift =
      if builtins.length roleSettings < 2
      then []
      else let
        first = clusterLevelOf (builtins.head roleSettings).settings;
      in
        lib.filter (r: clusterLevelOf r.settings != first) (lib.drop 1 roleSettings);
  in [
    {
      assertion = builtins.length clusterInitMembers == 1;
      message = "kube-cluster/${instanceName}: exactly one server must set clusterInit = true (found ${toString (builtins.length clusterInitMembers)})";
    }
    {
      # K11: the instance name is Cilium's cluster-name
      assertion = builtins.match "[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?" instanceName != null;
      message = "kube-cluster/${instanceName}: the instance name is the Cilium cluster name: at most 32 characters, lower-case letters, digits and '-', starting and ending with a letter or digit";
    }
    {
      # K7: two etcd voters need both for quorum, so losing either stops
      # the cluster: worse than one
      assertion = serverCount != 2;
      message = "kube-cluster/${instanceName}: two servers is refused: etcd needs both for quorum, so the loss of either stops the cluster. Use one server or three (make the second machine an agent)";
    }
    {
      assertion = !(halfPair settings.network.podCIDRv4 settings.network.podCIDRv6);
      message = "kube-cluster/${instanceName}: set network.podCIDRv4 and network.podCIDRv6 together, or neither (both are derived from cilium.id)";
    }
    {
      assertion = !(halfPair settings.network.serviceCIDRv4 settings.network.serviceCIDRv6);
      message = "kube-cluster/${instanceName}: set network.serviceCIDRv4 and network.serviceCIDRv6 together, or neither (both are derived from cilium.id)";
    }
    {
      assertion = cidrOverlaps == [];
      message = "kube-cluster/${instanceName}: the pod and service CIDRs must not overlap: ${lib.concatStringsSep "; " cidrOverlaps}";
    }
    {
      assertion = podMaskViolations == [];
      message = "kube-cluster/${instanceName}: ${lib.concatStringsSep "; " podMaskViolations}";
    }
    {
      assertion =
        builtins.length (lib.unique (lib.filter (x: x != null) memberIpv4s))
        == builtins.length (lib.filter (x: x != null) memberIpv4s);
      message = "kube-cluster/${instanceName}: every cluster member needs a unique IPv4 address";
    }
    {
      assertion =
        builtins.length (lib.unique (lib.filter (x: x != null) memberIpv6s))
        == builtins.length (lib.filter (x: x != null) memberIpv6s);
      message = "kube-cluster/${instanceName}: every cluster member needs a unique IPv6 address";
    }
    {
      assertion = lib.all (r: r != "" && !lib.hasInfix "\n" r) settings.coredns.rewrites;
      message = "kube-cluster/${instanceName}: every coredns.rewrites entry must be a single non-empty line";
    }
    {
      # §6.2: explicit ids above 127 cannot derive v4 CIDRs (the /8
      # overflows), so both v4 CIDRs must be pinned explicitly.
      assertion =
        settings.cilium.id
        == null
        || settings.cilium.id <= 127
        || (settings.network.podCIDRv4 != null && settings.network.serviceCIDRv4 != null);
      message = "kube-cluster/${instanceName}: cilium.id ${
        toString (settings.cilium.id or 0)
      } is above 127 — set network.podCIDRv4 and network.serviceCIDRv4 explicitly (the derived 10.<2id-1>/10.<2id> space overflows the /8)";
    }
    {
      assertion = lib.all (m: memberId m == resolvedId) roleMembers;
      message = "kube-cluster/${instanceName}: all members must resolve the same cilium.id (resolved here: ${toString resolvedId}); check for per-member cilium.id drift";
    }
    {
      assertion = membersMissingFacts == [];
      message = "kube-cluster/${instanceName}: these members have no node_transport export from network.fabric (add them to that routed-fabric instance): ${
        lib.concatMapStringsSep ", " (m: m.machineName) membersMissingFacts
      }";
    }
    {
      assertion = emptyTopology == [];
      message = "kube-cluster/${instanceName}: topology.region/zone must be non-empty when set (null defaults to the instance name, invariant 7): ${
        lib.concatMapStringsSep ", " (m: m.machineName) emptyTopology
      }";
    }
    {
      assertion =
        settings.network.podCIDRv4
        == null
        || cidr.contains "10.0.0.0/8" settings.network.podCIDRv4;
      message = "kube-cluster/${instanceName}: network.podCIDRv4 must be contained in ipv4NativeRoutingCIDR 10.0.0.0/8 (D49)";
    }
    {
      assertion =
        settings.network.podCIDRv6
        == null
        || cidr.contains "fd10::/16" settings.network.podCIDRv6;
      message = "kube-cluster/${instanceName}: network.podCIDRv6 must be contained in ipv6NativeRoutingCIDR fd10::/16 (D49)";
    }
    {
      # Cluster-level settings are one logical cluster configuration:
      # they must be identical on every machine of every role
      # (server/agent), otherwise the bundle, the per-member exports,
      # and the assertions disagree silently.
      assertion = roleDrift == [];
      message = "kube-cluster/${instanceName}: cluster-level settings must be identical across all machines — drifted member(s): ${
        lib.concatStringsSep ", " (map (r: r.name) roleDrift)
      } (set cilium/pools/bgp/fabric/mesh/meshGroup/domain/distroDefaults/coredns/bootstrap/firewall/network.fabric${lib.concatMapStrings (n: "/${n}") extraClusterLevel} uniformly on every machine of every role)";
    }
    {
      # D58: the transport route exchange and capabilities are uniform
      # across the cluster's members (one transport instance = one trust domain).
      assertion = lib.all (
        n:
          transport.uniformityKey transportFacts.${n}
          == transport.uniformityKey transportFacts.${builtins.head (builtins.attrNames transportFacts)}
      ) (lib.drop 1 (builtins.attrNames transportFacts));
      message = "kube-cluster/${instanceName}: node_transport profiles differ across members — one transport instance must present ONE uniform route-exchange/capability profile (D58)";
    }
  ];

  # K7: an even number of etcd voters above two tolerates no more
  # failures than one voter less. A list of warning strings.
  mkClusterWarnings = {
    instanceName,
    roleMembers,
  }: let
    serverCount = builtins.length (lib.filter (m: m.role == "server") roleMembers);
  in
    lib.optional (serverCount > 2 && lib.mod serverCount 2 == 0)
    "kube-cluster/${instanceName}: ${toString serverCount} servers tolerate the loss of no more servers than ${toString (serverCount - 1)} would; an odd number of servers is the etcd norm";

  # K14: configOverrides merge last into the distro's config.yaml, so a
  # key the service renders would be replaced silently, and a token would
  # land in the Nix store. ownedKeys: the keys this service renders for
  # the machine's role (`disable` is merged, not replaced).
  mkConfigOverrideAssertions = {
    instanceName,
    distro,
    overrides,
    ownedKeys,
  }: let
    denied = lib.unique (
      lib.filter (k: k != "disable") ownedKeys
      ++ [
        "token"
        "token-file"
        "agent-token"
        "agent-token-file"
        "server"
        "cluster-init"
        "cluster-cidr"
        "service-cidr"
        "cluster-dns"
        "node-ip"
      ]
    );
    hits = lib.filter (k: lib.elem k denied) (builtins.attrNames overrides);
  in [
    {
      assertion = hits == [];
      message = "${distro}/${instanceName}: configOverrides may not set ${lib.concatStringsSep ", " hits}: the service renders these keys (an override would replace them silently, and a token would land in the Nix store)";
    }
  ];

  # D8 pool assertions, including the fabric pool (D10) and the BGP
  # coupling (§6.12: BGP only for node-bgp/shared-bgp pools, and those pools
  # require BGP). members: [ { machineName, ipv4, ipv6, poolBlocks } ].
  # ciliumId: the RESOLVED id (fabric blocks derive from it).
  # reservedCidrs: pod/service CIDRs — no pool block may overlap them.
  # The shared-bgp ⊆ border-owned-prefixes assertion is fleet-wide (it
  # needs the fabric's border exports) and lives in fleet-checks.nix.
  mkPoolAssertions = {
    instanceName,
    settings,
    members,
    ciliumId,
    reservedCidrs ? [],
  }: let
    memberNames = map (m: m.machineName) members;

    autoPools =
      map (m: {
        name = m.machineName;
        blocks =
          [
            "${m.ipv4}/32"
            "${m.ipv6}/128"
          ]
          ++ m.poolBlocks;
      })
      members;

    fabricPool = bgpLib.mkFabricPool {inherit instanceName ciliumId settings;};
    effectivePools =
      settings.pools // lib.optionalAttrs (fabricPool != null) {${fabricPool.name} = fabricPool;};

    declaredPools =
      lib.mapAttrsToList (name: p: {
        inherit name;
        inherit (p) blocks delivery candidates;
        owner = p.owner or null;
      })
      effectivePools;

    allBlocks = lib.concatMap (p: p.blocks) (
      autoPools ++ map (p: {inherit (p) blocks;}) declaredPools
    );
    overlapping = cidr.anyOverlap allBlocks;

    # No pool block (auto, declared, or fabric) may overlap the cluster's
    # pod/service CIDRs.
    reservedOverlap =
      lib.concatMap (
        b:
          map (r: {
            block = b;
            reserved = r;
          }) (builtins.filter (r: cidr.overlap b r) reservedCidrs)
      )
      allBlocks;

    nodeFateBoundDeclared = lib.filter (p: p.delivery == "node-fate-bound") declaredPools;
    floatingWithoutCoverage =
      lib.filter (
        p:
          p.delivery
          == "floating"
          && (p.candidates == [] || !lib.all (c: lib.elem c memberNames) p.candidates)
      )
      declaredPools;
    nameCollisions = lib.filter (p: lib.elem p.name memberNames) declaredPools;

    bgpPoolNames = builtins.attrNames (
      lib.filterAttrs (_: p: p.delivery == "shared-bgp" || p.delivery == "node-bgp") effectivePools
    );

    # D8: node-bgp pools are owner-only — the owner must be declared and
    # must be a cluster member.
    nodeBgpPools = lib.filter (p: p.delivery == "node-bgp") declaredPools;
    nodeBgpBadOwner =
      lib.filter (
        p: (p.owner or null) == null || !(lib.elem p.owner memberNames)
      )
      nodeBgpPools;

    # The fabric blocks must hold the well-known internal VIPs: the
    # clustermesh-apiserver pair at host offset 79 (D60) — at least 128
    # addresses per v4 block (prefix /25 or shorter) and 256 per v6 block
    # (prefix /120 or shorter). The old offset-53 / 64-address rule is
    # retired (D10 round 17).
    fabricV4Ok = fabricPool == null || prefixLen (builtins.elemAt fabricPool.blocks 0) <= 25;
    fabricV6Ok = fabricPool == null || prefixLen (builtins.elemAt fabricPool.blocks 1) <= 120;
  in [
    {
      assertion = overlapping == [];
      message = "kube-cluster/${instanceName}: overlapping pool blocks: ${
        lib.concatMapStringsSep ", " (p: "${p.a} ~ ${p.b}") overlapping
      }";
    }
    {
      assertion = reservedOverlap == [];
      message = "kube-cluster/${instanceName}: pool blocks overlap the cluster's pod/service CIDRs: ${
        lib.concatMapStringsSep ", " (x: "${x.block} ~ ${x.reserved}") reservedOverlap
      }";
    }
    {
      assertion = nodeFateBoundDeclared == [];
      message = "kube-cluster/${instanceName}: node-fate-bound delivery is per-machine scope (auto-rendered node pools); invalid on cluster-global pools: ${
        lib.concatMapStringsSep ", " (p: p.name) nodeFateBoundDeclared
      }";
    }
    {
      assertion = floatingWithoutCoverage == [];
      message = "kube-cluster/${instanceName}: floating pools need a non-empty candidate set drawn from cluster members: ${
        lib.concatMapStringsSep ", " (p: p.name) floatingWithoutCoverage
      }";
    }
    {
      assertion = nameCollisions == [];
      message = "kube-cluster/${instanceName}: cluster-global pool names collide with auto per-machine node pools: ${
        lib.concatMapStringsSep ", " (p: p.name) nameCollisions
      }";
    }
    {
      # §6.12: BGP only for node-bgp/shared-bgp pools; those pools only
      # with BGP. The two knobs are locked together.
      assertion = settings.bgp.enable == (bgpPoolNames != []);
      message = "kube-cluster/${instanceName}: bgp.enable = ${builtins.toJSON settings.bgp.enable} but node-bgp/shared-bgp pools = [${lib.concatStringsSep ", " bgpPoolNames}] (§6.12: BGP only for node-bgp/shared-bgp pools, and such pools require BGP — with the default fabric a shared-bgp pool always exists, so disabling fabric requires bgp.enable = false.)";
    }
    {
      # D8: node-bgp pools need exactly one owner and it must be a member.
      assertion = nodeBgpBadOwner == [];
      message = "kube-cluster/${instanceName}: node-bgp pools need an owner that is a cluster member (D8 owner-only delivery): ${
        lib.concatMapStringsSep ", " (
          p: "${p.name} (owner: ${
            if (p.owner or null) == null
            then "null"
            else p.owner
          })"
        )
        nodeBgpBadOwner
      }";
    }
    {
      assertion = fabricV4Ok && fabricV6Ok;
      message = "kube-cluster/${instanceName}: fabric pool blocks must have at least 128 addresses (v4 /25 or shorter) and 256 (v6 /120 or shorter) — the internal ClusterMesh apiserver VIPs live at host offset 79 (D10 round 17/D60)";
    }
  ];

  # D9 (round 22 PR review): the fabric-allocated node ASNs (the
  # node_transport export's `asn`, RFC 6996 private range) and the cluster's
  # Cilium ASN (the same private space — the §6.2 hash or a bgp.ciliumASN
  # pin) must differ on every local-router member. An equality makes the
  # Cilium→FRR `::1` session accidental iBGP instead of eBGP (D9). Only
  # enforced while BGP is active: with no node-bgp/shared-bgp pool no
  # CiliumBGPClusterConfig is rendered and no session exists. A member
  # without a local-router profile is filtered out of hostAsns upstream.
  mkBgpAsnAssertions = {
    instanceName,
    ciliumAsn,
    hostAsns,
    bgpActive,
    transportFacts,
  }: let
    colliding = lib.filterAttrs (_: asn: asn == ciliumAsn) hostAsns;
    collidingMachines = builtins.attrNames colliding;
  in [
    {
      assertion = !bgpActive || colliding == {};
      message = "kube-cluster/${instanceName}: local-router transport node ASN ${toString ciliumAsn} allocated to machine(s) ${
        lib.concatStringsSep ", " collidingMachines
      } equals the cluster's Cilium BGP ASN — the Cilium→FRR session would be accidental iBGP, not eBGP (both sides draw from the RFC 6996 private range). Fix: pin bgp.ciliumASN to a different ASN, or run: ${
        lib.concatMapStringsSep ", " (
          m: let
            facts = transportFacts.${m};
          in "clan vars generate ${m} --generator ${facts.service}-${facts.instance}-asn --regenerate"
        )
        collidingMachines
      }";
    }
  ];

  # FRR always uses the transport allocation. A hostASN pin therefore only
  # checks consistency; it must never make Cilium dial a different peer ASN.
  mkHostAsnAssertions = {
    instanceName,
    roleMembers,
    transportFacts,
  }: let
    drifted =
      lib.filter (
        m: let
          facts = transportFacts.${m.machineName} or null;
          pin = m.settings.bgp.hostASN;
        in
          facts != null && facts.routeExchange == "local-router" && pin != null && pin != facts.asn
      )
      roleMembers;
  in [
    {
      assertion = drifted == [];
      message = "kube-cluster/${instanceName}: bgp.hostASN must match the local-router transport ASN; ${
        lib.concatMapStringsSep "; " (
          m: let
            facts = transportFacts.${m.machineName};
            pin = m.settings.bgp.hostASN;
          in "machine ${m.machineName} pins ${toString pin} but transport allocates ${toString facts.asn}; remove the bgp.hostASN pin, or run: clan vars generate ${m.machineName} --generator ${facts.service}-${facts.instance}-asn --regenerate"
        )
        drifted
      }";
    }
  ];
}
