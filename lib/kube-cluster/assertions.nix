# Eval assertions (§6.12). mkClusterAssertions covers cluster shape;
# mkPoolAssertions covers the D8 pool model plus the D9/D10 BGP/fabric
# coupling.
{ lib, hashCiliumId }:
let
  cidr = import ./cidr.nix { inherit lib; };
  bgpLib = import ./bgp.nix { inherit lib; };

  prefixLen = block: builtins.fromJSON (builtins.elemAt (lib.splitString "/" block) 1);
in
{
  mkClusterAssertions =
    {
      instanceName,
      roleMembers,
      settings,
      transportFacts ? null,
      # [ { name, settings } ] — the fully merged per-machine settings of
      # every cluster member, name = "<role>/<machine>" (for the parity
      # check across all machines of all roles).
      roleSettings ? [ ],
    }:
    let
      serverMembers = lib.filter (m: m.role == "server") roleMembers;
      clusterInitMembers = lib.filter (m: m.settings.clusterInit) serverMembers;

      memberAddrs = map (
        m:
        if transportFacts != null && transportFacts ? ${m.machineName} then
          transportFacts.${m.machineName}
        else
          {
            ipv4 = m.settings.network.ipv4 or null;
            ipv6 = m.settings.network.ipv6 or null;
          }
      ) roleMembers;
      memberIpv4s = map (a: a.ipv4 or null) memberAddrs;
      memberIpv6s = map (a: a.ipv6 or null) memberAddrs;

      # Resolved id per member (explicit pin or the hashed default); the
      # whole cluster must resolve to ONE id — a per-member pin drift
      # would split CIDRs/DNS/HAProxy ports across the fleet.
      resolvedId = if settings.cilium.id != null then settings.cilium.id else hashCiliumId instanceName;
      memberId =
        m:
        let
          explicit = m.settings.cilium.id or null;
        in
        if explicit != null then explicit else hashCiliumId instanceName;

      # §6.3 all-or-none transport posture: members either all ride the
      # transport or all carry manual addresses; mixing breaks the mesh
      # trust domain.
      memberUsesTransport = m: (m.settings.network.transport or null) != null;
      transportMembers = lib.filter memberUsesTransport roleMembers;
      manualMembers = lib.filter (m: !memberUsesTransport m) roleMembers;
      membersMissingFacts = lib.filter (
        m: !(transportFacts ? ${m.machineName}) || transportFacts.${m.machineName} == null
      ) roleMembers;

      # Invariant 7: topology overrides must be non-empty (null = the
      # instance-name default, applied at render).
      memberTopology = m: m.settings.topology or { };
      emptyTopology = lib.filter (
        m: (memberTopology m).region or null == "" || (memberTopology m).zone or null == ""
      ) roleMembers;

      # Cross-role parity: the cluster-level option groups must be
      # identical on every machine of every role, otherwise the bundle,
      # the per-member exports, and the assertions disagree silently.
      clusterLevelOf =
        rs:
        lib.getAttrs [
          "cilium"
          "pools"
          "bgp"
          "fabric"
          "meshGroup"
          "domain"
          "distroDefaults"
          "coredns"
          "bootstrap"
        ] rs
        // {
          transport = rs.network.transport or null;
        };
      roleDrift =
        if builtins.length roleSettings < 2 then
          [ ]
        else
          let
            first = clusterLevelOf (builtins.head roleSettings).settings;
          in
          lib.filter (r: clusterLevelOf r.settings != first) (lib.drop 1 roleSettings);
    in
    [
      {
        assertion = builtins.length clusterInitMembers == 1;
        message = "kube-cluster/${instanceName}: exactly one server must set clusterInit = true (found ${toString (builtins.length clusterInitMembers)})";
      }
      {
        assertion =
          transportFacts != null
          || lib.all (m: m.settings.network.ipv4 != null && m.settings.network.ipv6 != null) roleMembers;
        message = "kube-cluster/${instanceName}: network.transport is null, so every member must set network.ipv4 and network.ipv6";
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
          settings.cilium.id == null
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
        assertion = transportMembers == [ ] || manualMembers == [ ];
        message = "kube-cluster/${instanceName}: all-or-none transport posture (§6.3) — members mix transport-provided and manual addresses: transport: ${
          lib.concatMapStringsSep ", " (m: m.machineName) transportMembers
        }; manual: ${lib.concatMapStringsSep ", " (m: m.machineName) manualMembers}";
      }
      {
        assertion = transportFacts == null || membersMissingFacts == [ ];
        message = "kube-cluster/${instanceName}: these members have no export from the configured node_transport source (add them to the transport instance or switch to manual addresses): ${
          lib.concatMapStringsSep ", " (m: m.machineName) membersMissingFacts
        }";
      }
      {
        assertion = emptyTopology == [ ];
        message = "kube-cluster/${instanceName}: topology.region/zone must be non-empty when set (null defaults to the instance name, invariant 7): ${
          lib.concatMapStringsSep ", " (m: m.machineName) emptyTopology
        }";
      }
      {
        # Cluster-level settings are one logical cluster configuration:
        # they must be identical on every machine of every role
        # (server/agent), otherwise the bundle, the per-member exports,
        # and the assertions disagree silently.
        assertion = roleDrift == [ ];
        message = "kube-cluster/${instanceName}: cluster-level settings must be identical across all machines — drifted member(s): ${
          lib.concatStringsSep ", " (map (r: r.name) roleDrift)
        } (set cilium/pools/bgp/fabric/meshGroup/domain/distroDefaults/coredns/bootstrap/network.transport uniformly on every machine of every role)";
      }
    ];

  # D8 pool assertions, including the phase-5 fabric pool (D10) and the
  # BGP coupling (§6.12: BGP only for shared-bgp pools, and shared-bgp
  # pools require BGP). members: [ { machineName, ipv4, ipv6, poolBlocks } ].
  # ciliumId: the RESOLVED id (fabric blocks derive from it).
  # reservedCidrs: pod/service CIDRs — no pool block may overlap them.
  # The shared-bgp ⊆ router-prefixes assertion is fleet-wide (it needs the
  # router role's exports) and lives in fleet-checks.nix.
  mkPoolAssertions =
    {
      instanceName,
      settings,
      members,
      ciliumId,
      reservedCidrs ? [ ],
    }:
    let
      memberNames = map (m: m.machineName) members;

      autoPools = map (m: {
        name = m.machineName;
        blocks = [
          "${m.ipv4}/32"
          "${m.ipv6}/128"
        ]
        ++ m.poolBlocks;
      }) members;

      fabricPool = bgpLib.mkFabricPool { inherit instanceName ciliumId settings; };
      effectivePools =
        settings.pools // lib.optionalAttrs (fabricPool != null) { ${fabricPool.name} = fabricPool; };

      declaredPools = lib.mapAttrsToList (name: p: {
        inherit name;
        inherit (p) blocks delivery candidates;
      }) effectivePools;

      allBlocks = lib.concatMap (p: p.blocks) (
        autoPools ++ map (p: { inherit (p) blocks; }) declaredPools
      );
      overlapping = cidr.anyOverlap allBlocks;

      # No pool block (auto, declared, or fabric) may overlap the cluster's
      # pod/service CIDRs.
      reservedOverlap = lib.concatMap (
        b:
        map (r: {
          block = b;
          reserved = r;
        }) (builtins.filter (r: cidr.overlap b r) reservedCidrs)
      ) allBlocks;

      nodeFateBoundDeclared = lib.filter (p: p.delivery == "node-fate-bound") declaredPools;
      floatingWithoutCoverage = lib.filter (
        p:
        p.delivery == "floating"
        && (p.candidates == [ ] || !lib.all (c: lib.elem c memberNames) p.candidates)
      ) declaredPools;
      nameCollisions = lib.filter (p: lib.elem p.name memberNames) declaredPools;

      sharedBgpPoolNames = builtins.attrNames (
        lib.filterAttrs (_: p: p.delivery == "shared-bgp") effectivePools
      );

      # The fabric blocks must hold the well-known core VIPs (private
      # CoreDNS at offset 53): at least 64 addresses per family.
      fabricV4Ok = fabricPool == null || prefixLen (builtins.elemAt fabricPool.blocks 0) <= 26;
      fabricV6Ok = fabricPool == null || prefixLen (builtins.elemAt fabricPool.blocks 1) <= 120;
    in
    [
      {
        assertion = overlapping == [ ];
        message = "kube-cluster/${instanceName}: overlapping pool blocks: ${
          lib.concatMapStringsSep ", " (p: "${p.a} ~ ${p.b}") overlapping
        }";
      }
      {
        assertion = reservedOverlap == [ ];
        message = "kube-cluster/${instanceName}: pool blocks overlap the cluster's pod/service CIDRs: ${
          lib.concatMapStringsSep ", " (x: "${x.block} ~ ${x.reserved}") reservedOverlap
        }";
      }
      {
        assertion = nodeFateBoundDeclared == [ ];
        message = "kube-cluster/${instanceName}: node-fate-bound delivery is per-machine scope (auto-rendered node pools); invalid on cluster-global pools: ${
          lib.concatMapStringsSep ", " (p: p.name) nodeFateBoundDeclared
        }";
      }
      {
        assertion = floatingWithoutCoverage == [ ];
        message = "kube-cluster/${instanceName}: floating pools need a non-empty candidate set drawn from cluster members: ${
          lib.concatMapStringsSep ", " (p: p.name) floatingWithoutCoverage
        }";
      }
      {
        assertion = nameCollisions == [ ];
        message = "kube-cluster/${instanceName}: cluster-global pool names collide with auto per-machine node pools: ${
          lib.concatMapStringsSep ", " (p: p.name) nameCollisions
        }";
      }
      {
        # §6.12: BGP only for shared-bgp pools; shared-bgp pools only with
        # BGP. The two knobs are locked together.
        assertion = settings.bgp.enable == (sharedBgpPoolNames != [ ]);
        message = "kube-cluster/${instanceName}: bgp.enable = ${builtins.toJSON settings.bgp.enable} but shared-bgp pools = [${lib.concatStringsSep ", " sharedBgpPoolNames}] (§6.12: BGP only for shared-bgp pools; shared-bgp pools require BGP — with the default fabric a shared-bgp pool always exists, so disabling fabric requires bgp.enable = false)";
      }
      {
        # D13: a peer flagged receivePodCIDRs/receiveClusterIPs while the
        # cluster doesn't advertise them is a no-op lie — reject at eval.
        assertion =
          lib.all (
            p: !(p.receivePodCIDRs or false) || settings.bgp.advertisePodCIDRs
          ) settings.bgp.upstreamPeers
          && lib.all (
            p: !(p.receiveClusterIPs or false) || settings.bgp.advertiseClusterIPs
          ) settings.bgp.upstreamPeers;
        message = "kube-cluster/${instanceName}: bgp.upstreamPeers entries with receivePodCIDRs/receiveClusterIPs require the matching cluster opt-in (bgp.advertisePodCIDRs/advertiseClusterIPs, D13)";
      }
      {
        assertion = fabricV4Ok && fabricV6Ok;
        message = "kube-cluster/${instanceName}: fabric pool blocks must have at least 64 addresses (v4 /26 or shorter, v6 /120 or shorter) — the private CoreDNS VIP lives at offset 53";
      }
    ];
}
