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
{ lib }:
let
  cidr = import ./cidr.nix { inherit lib; };

  # Unique cluster entries keyed "service:instance", from the exports
  # tree. Every member machine of a cluster publishes the same
  # kube_cluster facts (per-member scopes), so the first scope's value
  # carries the cluster-level fields.
  clustersOf =
    clanLib: exports:
    let
      scoped = lib.filterAttrs (_: v: v.kube_cluster or null != null) exports;
      parsed = lib.mapAttrsToList (
        scope: value:
        let
          s = clanLib.parseScope scope;
        in
        {
          inherit (s) serviceName instanceName machineName;
          key = "${s.serviceName}:${s.instanceName}";
          cluster = value.kube_cluster;
        }
      ) scoped;
    in
    lib.foldl' (
      acc: entry:
      if acc ? ${entry.key} then
        acc
        // {
          ${entry.key} = acc.${entry.key} // {
            machines = acc.${entry.key}.machines ++ [ entry.machineName ];
          };
        }
      else
        acc
        // {
          ${entry.key} = {
            inherit (entry) serviceName instanceName;
            machines = [ entry.machineName ];
            inherit (entry) cluster;
          };
        }
    ) { } parsed;

  # Pairwise combinations of a list.
  pairs =
    xs:
    if builtins.length xs < 2 then
      [ ]
    else
      lib.concatMap (
        i:
        map (j: {
          fst = builtins.elemAt xs i;
          snd = builtins.elemAt xs j;
        }) (lib.range (i + 1) (builtins.length xs - 1))
      ) (lib.range 0 (builtins.length xs - 2));
in
rec {
  mkFleetChecks =
    clanLib: exports:
    let
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
          p:
          let
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
      machineClusters = lib.foldl' (
        acc: c:
        lib.foldl' (
          acc2: m:
          acc2
          // {
            ${m} = (acc2.${m} or [ ]) ++ [ "${c.serviceName}/${c.instanceName}" ];
          }
        ) acc c.machines
      ) { } clusters;
      doubleClaimed = lib.filterAttrs (_: ks: builtins.length (lib.unique ks) > 1) machineClusters;

      # 5. Mesh-group transport consistency (§6.3 mapping): same-group
      # clusters must consume the same node_transport source — one mesh
      # group = one transport instance. Posture mixes (transport vs
      # manual) inside a group are likewise rejected.
      transportInconsistent = lib.concatMap (
        groupClusters:
        lib.filter (
          p:
          (p.fst.cluster.transport.service or null) != (p.snd.cluster.transport.service or null)
          || (p.fst.cluster.transport.instance or null) != (p.snd.cluster.transport.instance or null)
        ) (pairs groupClusters)
      ) (lib.attrValues byGroup);
    in
    {
      kube-cluster-unique-names = {
        assertion = duplicateNames == { };
        message = "kube-cluster fleet check: duplicate cluster names (cluster name = instance name must be fleet-unique): ${
          lib.concatStringsSep "; " (
            lib.mapAttrsToList (
              name: cs:
              "'${name}' claimed by ${lib.concatMapStringsSep ", " (c: "${c.serviceName}/${c.instanceName}") cs}"
            ) duplicateNames
          )
        }";
      };

      kube-cluster-unique-cilium-ids = {
        assertion = duplicateIds == { };
        message = "kube-cluster fleet check: resolved cilium.id collision (pin cilium.id explicitly on all but one claimant): ${
          lib.concatStringsSep "; " (
            lib.mapAttrsToList (
              id: cs:
              "id ${id} claimed by ${lib.concatMapStringsSep ", " (c: "${c.serviceName}/${c.instanceName}") cs}"
            ) duplicateIds
          )
        }";
      };

      kube-cluster-meshed-cidr-overlap = {
        assertion = cidrOverlaps == [ ];
        message = "kube-cluster fleet check: overlapping pod/service CIDRs between clusters sharing a mesh group (D33): ${
          lib.concatMapStringsSep "; " (
            p: "${p.fst.serviceName}/${p.fst.instanceName} ~ ${p.snd.serviceName}/${p.snd.instanceName}"
          ) cidrOverlaps
        }";
      };

      kube-cluster-node-in-two-clusters = {
        assertion = doubleClaimed == { };
        message = "kube-cluster fleet check: one cluster per node (D16) — machines claimed by multiple clusters: ${
          lib.concatStringsSep "; " (
            lib.mapAttrsToList (
              machine: ks: "${machine} ← ${lib.concatStringsSep ", " (lib.unique ks)}"
            ) doubleClaimed
          )
        }";
      };

      kube-cluster-mesh-group-transport = {
        assertion = transportInconsistent == [ ];
        message = "kube-cluster fleet check: clusters in one mesh group must consume the same node_transport source (one group = one transport instance, §6.3): ${
          lib.concatMapStringsSep "; " (
            p:
            "${p.fst.serviceName}/${p.fst.instanceName} (${builtins.toJSON p.fst.cluster.transport}) vs ${p.snd.serviceName}/${p.snd.instanceName} (${builtins.toJSON p.snd.cluster.transport})"
          ) transportInconsistent
        }";
      };
    };

  fleetChecksModule =
    { config, clanLib, ... }:
    {
      checks = mkFleetChecks clanLib config.exports;
    };
}
