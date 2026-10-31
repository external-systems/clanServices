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
    transportFacts ? null,
    # Whether the cluster's transport profile is native routing (D58) —
    # only then must the pod CIDRs stay inside the native-routing CIDRs
    # (D49); tunnel transports encapsulate and never consult them.
    nativeRouting ? true,
    # [ { name, settings } ] — the fully merged per-machine settings of
    # every cluster member, name = "<role>/<machine>" (for the parity
    # check across all machines of all roles).
    roleSettings ? [],
  }: let
    serverMembers = lib.filter (m: m.role == "server") roleMembers;
    clusterInitMembers = lib.filter (m: m.settings.clusterInit) serverMembers;

    memberAddrs =
      map (
        m:
          if transportFacts != null && transportFacts ? ${m.machineName}
          then transportFacts.${m.machineName}
          else {
            ipv4 = m.settings.network.ipv4 or null;
            ipv6 = m.settings.network.ipv6 or null;
          }
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

    # §6.3 all-or-none fabric posture: members either all ride the fabric
    # or all carry manual addresses; mixing breaks the mesh trust domain.
    memberUsesFabric = m: (m.settings.network.fabric or null) != null;
    fabricMembers = lib.filter memberUsesFabric roleMembers;
    manualMembers = lib.filter (m: !memberUsesFabric m) roleMembers;
    membersMissingFacts =
      lib.filter (
        m: !(transportFacts ? ${m.machineName}) || transportFacts.${m.machineName} == null
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
      ]
      rs
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
      assertion =
        transportFacts
        != null
        || lib.all (m: m.settings.network.ipv4 != null && m.settings.network.ipv6 != null) roleMembers;
      message = "kube-cluster/${instanceName}: network.fabric is null, so every member must set network.ipv4 and network.ipv6";
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
      assertion = fabricMembers == [] || manualMembers == [];
      message = "kube-cluster/${instanceName}: all-or-none fabric posture (§6.3) — members mix fabric-provided and manual addresses: fabric: ${
        lib.concatMapStringsSep ", " (m: m.machineName) fabricMembers
      }; manual: ${lib.concatMapStringsSep ", " (m: m.machineName) manualMembers}";
    }
    {
      assertion = transportFacts == null || membersMissingFacts == [];
      message = "kube-cluster/${instanceName}: these members have no export from the configured fabric source (add them to the routed-fabric instance or switch to manual addresses): ${
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
        !nativeRouting
        || settings.network.podCIDRv4 == null
        || cidr.contains "10.0.0.0/8" settings.network.podCIDRv4;
      message = "kube-cluster/${instanceName}: network.podCIDRv4 must be contained in ipv4NativeRoutingCIDR 10.0.0.0/8 (native transport, D49)";
    }
    {
      assertion =
        !nativeRouting
        || settings.network.podCIDRv6 == null
        || cidr.contains "fd10::/16" settings.network.podCIDRv6;
      message = "kube-cluster/${instanceName}: network.podCIDRv6 must be contained in ipv6NativeRoutingCIDR fd10::/16 (native transport, D49)";
    }
    {
      assertion = !settings.bgp.enable || settings.network.fabric != null;
      message = "kube-cluster/${instanceName}: bgp.enable requires network.fabric so routed-fabric owns the node-local FRR peer; manual-address clusters must disable BGP and the default fabric pool";
    }
    {
      # Cluster-level settings are one logical cluster configuration:
      # they must be identical on every machine of every role
      # (server/agent), otherwise the bundle, the per-member exports,
      # and the assertions disagree silently.
      assertion = roleDrift == [];
      message = "kube-cluster/${instanceName}: cluster-level settings must be identical across all machines — drifted member(s): ${
        lib.concatStringsSep ", " (map (r: r.name) roleDrift)
      } (set cilium/pools/bgp/fabric/mesh/meshGroup/domain/distroDefaults/coredns/bootstrap/network.fabric uniformly on every machine of every role)";
    }
    {
      # D58: the transport mode/protocol/capabilities are uniform across
      # the cluster's members (one transport instance = one trust domain).
      assertion =
        transportFacts
        == null
        || lib.all (
          n:
            transport.uniformityKey transportFacts.${n}
            == transport.uniformityKey transportFacts.${builtins.head (builtins.attrNames transportFacts)}
        ) (lib.tail (builtins.attrNames transportFacts));
      message = "kube-cluster/${instanceName}: node_transport profiles differ across members — one transport instance must present ONE uniform datapath mode/protocol/capability profile (D58)";
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
      message = "kube-cluster/${instanceName}: bgp.enable = ${builtins.toJSON settings.bgp.enable} but node-bgp/shared-bgp pools = [${lib.concatStringsSep ", " bgpPoolNames}] (§6.12: BGP only for node-bgp/shared-bgp pools, and such pools require BGP — with the default fabric a shared-bgp pool always exists, so disabling fabric requires bgp.enable = false)";
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
  # CiliumBGPClusterConfig is rendered and no session exists. Vacuous for
  # tunnel/manual transports: their members have no routeExchange and are
  # filtered out of hostAsns upstream.
  mkBgpAsnAssertions = {
    instanceName,
    ciliumAsn,
    hostAsns,
    bgpActive,
  }: let
    colliding = lib.filterAttrs (_: asn: asn == ciliumAsn) hostAsns;
    collidingMachines = builtins.attrNames colliding;
  in [
    {
      assertion = !bgpActive || colliding == {};
      message = "kube-cluster/${instanceName}: routed-fabric node ASN ${toString ciliumAsn} allocated to machine(s) ${
        lib.concatStringsSep ", " collidingMachines
      } equals the cluster's Cilium BGP ASN — the Cilium→FRR session would be accidental iBGP, not eBGP (both sides draw from the RFC 6996 private range). Fix: pin bgp.ciliumASN to a different ASN, or pin ${
        lib.concatMapStringsSep ", " (m: "${m}'s bgp.hostASN") collidingMachines
      } to a different value";
    }
  ];
}
