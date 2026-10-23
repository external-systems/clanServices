# Eval assertions (§6.12). mkClusterAssertions covers cluster shape;
# mkPoolAssertions covers the D8 pool model.
{ lib, hashCiliumId }:
let
  cidr = import ./cidr.nix { inherit lib; };
in
{
  mkClusterAssertions =
    {
      instanceName,
      roleMembers,
      settings,
      transportFacts ? null,
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
    ];

  # D8 pool assertions. members: [ { machineName, ipv4, ipv6, poolBlocks } ].
  # The shared-bgp ⊆ router-prefixes assertion is deferred to phase 5 (the
  # router role does not exist yet) — only shape is checked here.
  mkPoolAssertions =
    {
      instanceName,
      settings,
      members,
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

      declaredPools = lib.mapAttrsToList (name: p: {
        inherit name;
        inherit (p) blocks delivery candidates;
      }) settings.pools;

      allBlocks = lib.concatMap (p: p.blocks) (
        autoPools ++ map (p: { inherit (p) blocks; }) declaredPools
      );
      overlapping = cidr.anyOverlap allBlocks;

      nodeFateBoundDeclared = lib.filter (p: p.delivery == "node-fate-bound") declaredPools;
      floatingWithoutCoverage = lib.filter (
        p:
        p.delivery == "floating"
        && (p.candidates == [ ] || !lib.all (c: lib.elem c memberNames) p.candidates)
      ) declaredPools;
      nameCollisions = lib.filter (p: lib.elem p.name memberNames) declaredPools;
    in
    [
      {
        assertion = overlapping == [ ];
        message = "kube-cluster/${instanceName}: overlapping pool blocks: ${
          lib.concatMapStringsSep ", " (p: "${p.a} ~ ${p.b}") overlapping
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
    ];
}
