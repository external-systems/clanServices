# Fleet-wide (inventory-wide) assertions (SPEC §6.2, D16/D33), computed
# from the kube_cluster exports — the one place cross-service checks can
# live, since a service's perInstance/perMachine only sees its own
# instances. mkFleetChecks maps the exports tree to a clan.checks-style
# attrset; fleetChecksModule wires it into a clan evaluation as a
# clan-class module (`clan.imports = [ kube.fleetChecksModule ]` — or
# `imports = [ ... ]` in a clanLib.clan call). Scope keys are only ever
# read through clanLib.parseScope, never hand-parsed.
#
# Every check names the offending instances/machines in its message.
{lib}: let
  cidr = import ./cidr.nix {inherit lib;};

  # Unique cluster entries keyed "service:instance", from the exports
  # tree. Every member machine of a cluster publishes the same
  # kube_cluster facts (per-member scopes), so the first scope's value
  # carries the cluster-level fields.
  clustersOf = clanLib: exports: let
    scoped = lib.filterAttrs (_: v: v.kube_cluster or null != null) exports;
    parsed =
      lib.mapAttrsToList (
        scope: value: let
          s = clanLib.parseScope scope;
        in {
          inherit (s) serviceName instanceName machineName;
          key = "${s.serviceName}:${s.instanceName}";
          cluster = value.kube_cluster;
        }
      )
      scoped;
  in
    lib.foldl' (
      acc: entry:
        if acc ? ${entry.key}
        then
          acc
          // {
            ${entry.key} =
              acc.${entry.key}
              // {
                machines = acc.${entry.key}.machines ++ [entry.machineName];
              };
          }
        else
          acc
          // {
            ${entry.key} = {
              inherit (entry) serviceName instanceName;
              machines = [entry.machineName];
              inherit (entry) cluster;
            };
          }
    ) {}
    parsed;

  # Pairwise combinations of a list.
  pairs = xs:
    if builtins.length xs < 2
    then []
    else
      lib.concatMap (
        i:
          map (j: {
            fst = builtins.elemAt xs i;
            snd = builtins.elemAt xs j;
          }) (lib.range (i + 1) (builtins.length xs - 1))
      ) (lib.range 0 (builtins.length xs - 2));
in rec {
  inherit clustersOf;

  # Mesh-group helpers shared with the distro services (peer resolution).
  # cluster values are the kube_cluster export attrsets; the defensive
  # `or` fallbacks keep hand-built export trees (tests) evaluable.
  meshGroupsOf = clusters: lib.groupBy (c: c.cluster.meshGroup or "") clusters;

  # The peering edge view used by the symmetry + bounds checks: an explicit
  # peer list names edges; null = full peering with every same-group peer.
  peerEdge = a: b:
    if (a.cluster.mesh.peers or null) == null
    then true
    else lib.elem b.cluster.name (a.cluster.mesh.peers or []);

  mkFleetChecks = clanLib: exports: let
    clusters = lib.attrValues (clustersOf clanLib exports);

    # 1. Duplicate cluster names across instances/services (the cluster
    # name = instance name must be fleet-unique, §6.2).
    byName = lib.groupBy (c: c.cluster.name) clusters;
    duplicateNames = lib.filterAttrs (_: cs: builtins.length cs > 1) byName;

    # 2. Resolved cilium id collisions (hashed defaults make these
    # possible; the escape is an explicit cilium.id pin).
    byId = lib.groupBy (c: toString c.cluster.ciliumId) clusters;
    duplicateIds = lib.filterAttrs (_: cs: builtins.length cs > 1) byId;

    # 3. Same mesh group ⇒ pairwise non-overlapping pod AND service
    # CIDRs (D33: meshed clusters share a routed trust domain).
    byGroup = lib.groupBy (c: c.cluster.meshGroup) clusters;
    cidrOverlaps = lib.concatMap (
      groupClusters:
        lib.filter (
          p: let
            a = p.fst.cluster.network;
            b = p.snd.cluster.network;
            overlapPair = x: y: x != null && y != null && cidr.overlap x y;
          in
            overlapPair a.podCIDRv4 b.podCIDRv4
            || overlapPair a.podCIDRv6 b.podCIDRv6
            || overlapPair a.serviceCIDRv4 b.serviceCIDRv4
            || overlapPair a.serviceCIDRv6 b.serviceCIDRv6
        ) (pairs groupClusters)
    ) (lib.attrValues byGroup);

    # 4. Node-in-two-clusters (D16), INCLUDING across distro services:
    # a machine exporting kube_cluster under two cluster keys.
    machineClusters =
      lib.foldl' (
        acc: c:
          lib.foldl' (
            acc2: m:
              acc2
              // {
                ${m} = (acc2.${m} or []) ++ ["${c.serviceName}/${c.instanceName}"];
              }
          )
          acc
          c.machines
      ) {}
      clusters;
    doubleClaimed = lib.filterAttrs (_: ks: builtins.length (lib.unique ks) > 1) machineClusters;

    # 5. Mesh-group fabric consistency (§6.3/D54): same-group clusters
    # must consume the same fabric instance — one mesh group = one
    # routed-fabric instance. Posture mixes (fabric vs manual) inside a
    # group are likewise rejected.
    fabricInconsistent = lib.concatMap (
      groupClusters:
        lib.filter (
          p:
            (p.fst.cluster.network.fabric.service or null)
            != (p.snd.cluster.network.fabric.service or null)
            || (p.fst.cluster.network.fabric.instance or null) != (p.snd.cluster.network.fabric.instance or null)
        ) (pairs groupClusters)
    ) (lib.attrValues byGroup);

    # 6. BGP ASN collisions (D9): the hashed per-cluster Cilium-side and
    # host-side ASNs must be unique fleet-wide (the escape hatch is the
    # bgp.ciliumASN/bgp.hostASN pin). Defensive `or null` keeps
    # hand-built export trees (tests, older publishers) evaluable.
    asnClaims =
      lib.concatMap (
        c:
          lib.optionals (c.cluster.bgp.enabled or false) [
            {
              asn = c.cluster.bgp.ciliumAsn or null;
              who = "${c.serviceName}/${c.instanceName} (cilium)";
            }
            {
              asn = c.cluster.bgp.hostAsn or null;
              who = "${c.serviceName}/${c.instanceName} (host)";
            }
          ]
      )
      clusters;
    byAsn = lib.groupBy (x: toString x.asn) (builtins.filter (x: x.asn != null) asnClaims);
    duplicateAsns = lib.filterAttrs (_: xs: builtins.length (lib.unique (map (x: x.who) xs)) > 1) byAsn;

    # 7. shared-bgp ⊆ border-owned prefixes (D8 round 16): fires once any
    # routed-fabric border export exists in the same inventory (the
    # in-progress routed-fabric service publishes `borderOwnedPrefixes`
    # on its routed_fabric export); vacuous until then. Consumed through
    # parseScope only.
    borderOwnedPrefixes = lib.concatMap (
      scope: let
        v = exports.${scope};
      in
        v.routed_fabric.border.ownedPrefixes or []
    ) (builtins.attrNames exports);
    sharedBgpOutside =
      lib.concatMap (
        c: let
          sharedPools = lib.filterAttrs (_: p: p.delivery or null == "shared-bgp") (c.cluster.pools or {});
          blocks = lib.concatMap (p: p.blocks or []) (builtins.attrValues sharedPools);
          uncovered = builtins.filter (b: !lib.any (r: cidr.contains r b) borderOwnedPrefixes) blocks;
        in
          map (b: {
            cluster = "${c.serviceName}/${c.instanceName}";
            block = b;
          })
          uncovered
      )
      clusters;

    # 8. ClusterMesh group uniformity (D60): identical datapath mode,
    # tunnel protocol and maxConnectedClusters across every member.
    groupUniformity = lib.concatMap (
      groupClusters:
        lib.filter (
          p: let
            a = p.fst.cluster;
            b = p.snd.cluster;
          in
            (a.datapath.mode or null)
            != (b.datapath.mode or null)
            || (a.datapath.tunnelProtocol or null) != (b.datapath.tunnelProtocol or null)
            || (a.mesh.maxConnectedClusters or 255) != (b.mesh.maxConnectedClusters or 255)
        ) (pairs groupClusters)
    ) (lib.attrValues (meshGroupsOf clusters));

    # 9. Selective ClusterMesh peers (D54/D60): explicit peers must
    # resolve to same-group clusters and be symmetric (A↔B). Full peering
    # (null) covers every same-group peer, so an explicit edge toward a
    # full-peering cluster is consistent iff the reverse holds.
    peerProblems =
      lib.concatMap (
        c: let
          explicit = c.cluster.mesh.peers or null;
          peers' =
            if explicit == null
            then []
            else explicit;
          group = c.cluster.meshGroup or "";
          groupClusters =
            lib.filter (
              o: o.cluster.name != c.cluster.name && (o.cluster.meshGroup or "") == group
            )
            clusters;
          knownNames = map (o: o.cluster.name) clusters;
          unknown = lib.filter (n: !(lib.elem n knownNames)) peers';
          wrongGroup =
            lib.filter (
              n: !(lib.elem n (map (o: o.cluster.name) groupClusters)) && lib.elem n knownNames
            )
            peers';
          asymmetric = lib.filter (o: !(peerEdge o {cluster.name = c.cluster.name;})) groupClusters;
        in
          lib.optionals (explicit != null) (
            map (n: {
              cluster = "${c.serviceName}/${c.instanceName}";
              problem = "unknown peer '${n}' (no kube_cluster export with that name)";
            })
            unknown
            ++ map (n: {
              cluster = "${c.serviceName}/${c.instanceName}";
              problem = "peer '${n}' is not in mesh group '${group}' (selective peers are same-trust-domain only, D54)";
            })
            wrongGroup
            ++ map (o: {
              cluster = "${c.serviceName}/${c.instanceName}";
              problem = "selective peer '${o.cluster.name}' does not peer back (symmetric selective peers, D54/D60)";
            })
            asymmetric
          )
      )
      clusters;

    # 10. Duplicate mesh NodePorts per machine (D60): two clusters
    # exposing the apiserver NodePort on the SAME machine must not share
    # the port. (One cluster per node is D16, but the check guards the
    # port set anyway — it is the fleet-visible half of the per-machine
    # collision rule; the port-range half is type-level.)
    nodePortClaims =
      lib.concatMap (
        c: let
          np = c.cluster.mesh.exposure.nodePort or null;
        in
          lib.optionals (np != null) (
            map (m: {
              machine = m;
              port = np;
              cluster = "${c.serviceName}/${c.instanceName}";
            })
            c.machines
          )
      )
      clusters;
    byMachinePort = lib.groupBy (x: "${x.machine}:${toString x.port}") nodePortClaims;
    nodePortCollisions = lib.filterAttrs (_: xs: builtins.length xs > 1) byMachinePort;

    # 11. Pinned internal ClusterMesh IPv4 VIP collisions (D60): every
    # cluster's offset-79 VIP must be fleet-unique (explicit fabric block
    # overrides can collide across clusters).
    vipClaims =
      lib.concatMap (
        c: let
          e = c.cluster.mesh.exposure or {};
        in
          lib.optionals (e.vip4 or null != null) [
            {
              vip = e.vip4;
              cluster = "${c.serviceName}/${c.instanceName}";
            }
          ]
      )
      clusters;
    byVip = lib.groupBy (x: x.vip) vipClaims;
    vipCollisions =
      lib.filterAttrs (
        _: xs: builtins.length (lib.unique (map (x: x.cluster) xs)) > 1
      )
      byVip;
  in {
    kube-cluster-unique-names = {
      assertion = duplicateNames == {};
      message = "kube-cluster fleet check: duplicate cluster names (cluster name = instance name must be fleet-unique): ${
        lib.concatStringsSep "; " (
          lib.mapAttrsToList (
            name: cs: "'${name}' claimed by ${lib.concatMapStringsSep ", " (c: "${c.serviceName}/${c.instanceName}") cs}"
          )
          duplicateNames
        )
      }";
    };

    kube-cluster-unique-cilium-ids = {
      assertion = duplicateIds == {};
      message = "kube-cluster fleet check: resolved cilium.id collision (pin cilium.id explicitly on all but one claimant): ${
        lib.concatStringsSep "; " (
          lib.mapAttrsToList (
            id: cs: "id ${id} claimed by ${lib.concatMapStringsSep ", " (c: "${c.serviceName}/${c.instanceName}") cs}"
          )
          duplicateIds
        )
      }";
    };

    kube-cluster-meshed-cidr-overlap = {
      assertion = cidrOverlaps == [];
      message = "kube-cluster fleet check: overlapping pod/service CIDRs between clusters sharing a mesh group (D33): ${
        lib.concatMapStringsSep "; " (
          p: "${p.fst.serviceName}/${p.fst.instanceName} ~ ${p.snd.serviceName}/${p.snd.instanceName}"
        )
        cidrOverlaps
      }";
    };

    kube-cluster-node-in-two-clusters = {
      assertion = doubleClaimed == {};
      message = "kube-cluster fleet check: one cluster per node (D16) — machines claimed by multiple clusters: ${
        lib.concatStringsSep "; " (
          lib.mapAttrsToList (
            machine: ks: "${machine} ← ${lib.concatStringsSep ", " (lib.unique ks)}"
          )
          doubleClaimed
        )
      }";
    };

    kube-cluster-mesh-group-fabric = {
      assertion = fabricInconsistent == [];
      message = "kube-cluster fleet check: clusters in one mesh group must consume the same fabric instance (one group = one routed-fabric instance, D54): ${
        lib.concatMapStringsSep "; " (
          p: "${p.fst.serviceName}/${p.fst.instanceName} (${builtins.toJSON p.fst.cluster.network.fabric}) vs ${p.snd.serviceName}/${p.snd.instanceName} (${builtins.toJSON p.snd.cluster.network.fabric})"
        )
        fabricInconsistent
      }";
    };

    kube-cluster-unique-bgp-asns = {
      assertion = duplicateAsns == {};
      message = "kube-cluster fleet check: BGP ASN collision (D9 — pin bgp.ciliumASN on all but one cluster claimant): ${
        lib.concatStringsSep "; " (
          lib.mapAttrsToList (
            asn: xs: "ASN ${asn} claimed by ${lib.concatStringsSep ", " (lib.unique (map (x: x.who) xs))}"
          )
          duplicateAsns
        )
      }";
    };

    kube-cluster-shared-bgp-border-prefixes = {
      assertion = borderOwnedPrefixes == [] || sharedBgpOutside == [];
      message = "kube-cluster fleet check: shared-bgp pool blocks outside all routed-fabric border-owned prefixes (D8): ${
        lib.concatMapStringsSep "; " (x: "${x.block} (${x.cluster})") sharedBgpOutside
      }";
    };

    kube-cluster-mesh-group-uniformity = {
      assertion = groupUniformity == [];
      message = "kube-cluster fleet check: ClusterMesh group members must share datapath mode, tunnel protocol and maxConnectedClusters (D60): ${
        lib.concatMapStringsSep "; " (
          p: "${p.fst.serviceName}/${p.fst.instanceName} ~ ${p.snd.serviceName}/${p.snd.instanceName} (${
            builtins.toJSON {
              fst = {
                mode = p.fst.cluster.datapath.mode or null;
                proto = p.fst.cluster.datapath.tunnelProtocol or null;
                mcc = p.fst.cluster.mesh.maxConnectedClusters or 255;
              };
              snd = {
                mode = p.snd.cluster.datapath.mode or null;
                proto = p.snd.cluster.datapath.tunnelProtocol or null;
                mcc = p.snd.cluster.mesh.maxConnectedClusters or 255;
              };
            }
          })"
        )
        groupUniformity
      }";
    };

    kube-cluster-mesh-peers = {
      assertion = peerProblems == [];
      message = "kube-cluster fleet check: ClusterMesh peer problems (D54/D60): ${
        lib.concatMapStringsSep "; " (p: "${p.cluster}: ${p.problem}") peerProblems
      }";
    };

    kube-cluster-mesh-nodeport-collisions = {
      assertion = nodePortCollisions == {};
      message = "kube-cluster fleet check: duplicate ClusterMesh NodePort on one machine (D60): ${
        lib.concatStringsSep "; " (
          lib.mapAttrsToList (
            k: xs: "${k} claimed by ${lib.concatMapStringsSep ", " (x: x.cluster) xs}"
          )
          nodePortCollisions
        )
      }";
    };

    kube-cluster-mesh-vip-collisions = {
      assertion = vipCollisions == {};
      message = "kube-cluster fleet check: pinned internal ClusterMesh VIP collision (offset 79, D60): ${
        lib.concatStringsSep "; " (
          lib.mapAttrsToList (
            k: xs: "${k} claimed by ${lib.concatMapStringsSep ", " (x: x.cluster) xs}"
          )
          vipCollisions
        )
      }";
    };
  };

  fleetChecksModule = {
    config,
    clanLib,
    ...
  }: {
    checks = mkFleetChecks clanLib config.exports;
  };
}
