{lib}: let
  # Stable cluster-id derivation (§6.2): sha256(instanceName), first 8 hex
  # chars as a 32-bit int, mod 127, +1 → 1–127. Pure Nix, no IFD.
  # Collisions between two instances' resolved ids are an eval error
  # (fleet-wide check, fleet-checks.nix); explicit cilium.id pins escape it.
  hashCiliumId = instanceName: let
    hexVal = c: let
      digits = lib.stringToCharacters "0123456789abcdef";
      idx = lib.findFirst (i: builtins.elemAt digits i == c) (-1) (lib.genList (x: x) 16);
    in
      if idx == -1
      then throw "kube-cluster: bad hex digit '${c}' in instance-name hash"
      else idx;
    n = lib.foldl' (acc: c: acc * 16 + hexVal c) 0 (
      lib.stringToCharacters (lib.substring 0 8 (builtins.hashString "sha256" instanceName))
    );
  in
    1 + lib.mod n 127;

  # The resolved cilium id: explicit cilium.id wins; null → hashed default.
  resolveCiliumId = {
    instanceName,
    settings,
  }:
    if settings.cilium.id != null
    then settings.cilium.id
    else hashCiliumId instanceName;

  # Pod/service CIDR derivation from the (resolved) Cilium cluster id.
  # Multiple clusters can share one transport when their ids differ.
  cidrs = id: {
    clusterCidr = "10.${toString (id * 2 - 1)}.0.0/16,fd10:${toString (id * 2 - 1)}::/56";
    serviceCidr = "10.${toString (id * 2)}.0.0/16,fd10:${toString (id * 2)}::/112";
    clusterDNS = "10.${toString (id * 2)}.0.10";
  };

  clusterInterface = import ./cluster-interface.nix;
  nodeInterface = import ./node-interface.nix;

  cidrLib = import ./cidr.nix {inherit lib;};
  bgp = import ./bgp.nix {inherit lib;};
  transport = import ./transport.nix {inherit lib;};
  mesh = import ./mesh.nix {inherit lib;};
  cilium = import ./cilium.nix {
    inherit
      lib
      cidrs
      hashCiliumId
      cidrLib
      ;
  };
  assertFns = import ./assertions.nix {inherit lib hashCiliumId;};
  bundle = import ./bundle.nix {inherit lib;};
  bootstrap = import ./bootstrap.nix {inherit lib;};
  haproxy = import ./haproxy.nix {inherit lib;};
  nixos = import ./nixos.nix {inherit lib;};
  vars = import ./vars.nix {inherit lib;};
  fleetChecks = import ./fleet-checks.nix {inherit lib;};

  # §6.11 manifest labels: on every clan-rendered object, never in
  # selectors. bundle.nix adds clan.lol/config-hash per object at the end
  # of the render.
  mkManifestLabels = {
    instanceName,
    component ? "bootstrap",
  }: {
    "app.kubernetes.io/managed-by" = "clan";
    "clan.lol/kube-cluster" = "core-component";
    "clan.lol/cluster" = instanceName;
    "clan.lol/component" = component;
  };

  # Resolve the full pool set for a cluster (D8): the auto per-machine
  # node-named pools (join-address /32+/128 + declared poolBlocks, always
  # node-fate-bound) plus the declared cluster-global pools.
  # members: [ { machineName, ipv4, ipv6, poolBlocks } ].
  # extraPools: pre-resolved additions (the fabric pool, D10 — see
  # resolveDataPlane). Returns an attrset: pool name -> { blocks,
  # serviceSelector }.
  resolvePools = {
    settings,
    members,
    extraPools ? {},
  }:
    lib.listToAttrs (
      map (m: {
        name = m.machineName;
        value = {
          blocks =
            [
              "${m.ipv4}/32"
              "${m.ipv6}/128"
            ]
            ++ m.poolBlocks;
          serviceSelector."clan.lol/pool" = m.machineName;
        };
      })
      members
    )
    // lib.mapAttrs (_: p: {inherit (p) blocks serviceSelector;}) (settings.pools // extraPools);

  # The data plane in one resolution seam (D9/D10/D19/D49/D55): shared by
  # both distro services and the eval tests so the bundle, the assertions,
  # and the export all see the same facts. The host routing stack is owned
  # by routed-fabric (D19) — this seam renders ONLY the Cilium-side BGP v2
  # resources and publishes the facts routed-fabric consumes.
  #
  # members: [ { machineName, ... } ] (the cluster's member machines with
  # known addresses). Returns:
  #   asns              — { cilium, host } (deterministic private 32-bit;
  #                       the fabric's real node ASN supersedes host at the
  #                       consumer, D9 revised)
  #   fabricPool        — null or the fabric pool attrset (D10)
  #   effectivePools    — settings.pools + the fabric pool
  #   sharedBgpPoolNames / nodeBgpPoolNames / bgpActive / bgpPoolBlocks
  #   bgpBundle         — mkBundle's bgp param (null when bgp inactive)
  #   exportFacts       — the kube_cluster export's bgp/fabric subtrees
  resolveDataPlane = {
    instanceName,
    settings,
    ciliumId,
    members,
    hostAsns ? {},
  }: let
    asns = bgp.resolveBgpAsns {inherit instanceName settings;};
    fabricPool = bgp.mkFabricPool {inherit instanceName ciliumId settings;};
    effectivePools =
      settings.pools // lib.optionalAttrs (fabricPool != null) {${fabricPool.name} = fabricPool;};
    sharedBgpPools = lib.filterAttrs (_: p: p.delivery == "shared-bgp") effectivePools;
    nodeBgpPools = lib.filterAttrs (_: p: p.delivery == "node-bgp") effectivePools;
    sharedBgpPoolNames = builtins.attrNames sharedBgpPools;
    nodeBgpPoolNames = builtins.attrNames nodeBgpPools;
    nodeBgpPoolOwners = lib.mapAttrs (_: pool: pool.owner) nodeBgpPools;
    bgpActive = sharedBgpPoolNames != [] || nodeBgpPoolNames != [];
    bgpPoolBlocks = lib.concatMap (p: p.blocks) (builtins.attrValues (sharedBgpPools // nodeBgpPools));
    fabricBlocks' = bgp.fabricBlocks {inherit ciliumId settings;};
  in {
    inherit
      asns
      fabricPool
      effectivePools
      sharedBgpPoolNames
      nodeBgpPoolNames
      bgpActive
      bgpPoolBlocks
      ;

    bgpBundle =
      if bgpActive
      then {
        inherit
          asns
          hostAsns
          sharedBgpPoolNames
          nodeBgpPoolOwners
          ;
        members = map (m: m.machineName) members;
        inherit (settings.bgp) advertiseClusterIPs;
      }
      else null;

    exportFacts = {
      bgp = {
        enabled = bgpActive;
        ciliumAsn = asns.cilium;
        hostAsn = asns.host;
        inherit (settings.bgp) advertiseClusterIPs;
      };
      fabric = {
        enabled = settings.fabric.enable;
        pool =
          if fabricPool != null
          then fabricPool.name
          else "";
        ipv4Block =
          if settings.fabric.enable
          then fabricBlocks'.v4
          else null;
        ipv6Block =
          if settings.fabric.enable
          then fabricBlocks'.v6
          else null;
      };
    };
  };
in rec {
  inherit
    cidrs
    hashCiliumId
    resolveCiliumId
    resolveDataPlane
    ;

  # BGP v2 / local-router derivation helpers (D9/D10).
  inherit bgp;

  # The generic node_transport consumer (D58) and the ClusterMesh
  # placement/exposure resolution (D60).
  inherit transport mesh;

  interfaces = {
    cluster = clusterInterface;
    node = nodeInterface;
    # The custom export interface (§6.2, D45): published by both distro
    # services, consumed by fleet checks and routed-fabric.
    kube_cluster = ./kube-cluster-interface.nix;
  };

  render = {
    inherit (cilium) mkCiliumValues resolveCidrs;
    inherit
      (bundle)
      mkBundle
      mkLBService
      mkCoreDNSResources
      validateBundle
      unsupportedHelmValues
      ;
    inherit (haproxy) mkHaproxyConfig;
    inherit mkManifestLabels resolvePools;
  };

  assertions = {
    inherit (assertFns) mkClusterAssertions mkPoolAssertions;
  };

  # Bootstrap-apply oneshot fragment (D40) + the ClusterMesh secrets-apply
  # oneshot (D60) + the image digest-alias oneshot (offline digest-pinned
  # references, D26/D40 airgap).
  inherit (bootstrap) mkBootstrapApply mkClustermeshSecretsApply mkImageDigestAliases;

  # Vars generators (bare generator attrsets — the distro service merges
  # them into clan.core.vars.generators, gated by role as documented in
  # vars.nix).
  inherit vars;

  # NixOS fragment builders (PKI sync).
  inherit nixos;

  # Fleet-wide assertions (§6.2): mkFleetChecks computes the clan.checks
  # attrset from the kube_cluster exports; fleetChecksModule is a
  # clan-class module wiring them into a clan evaluation
  # (`clan.imports = [ kube.fleetChecksModule ]`). clustersOf is the shared
  # export-tree helper (also used by the distro services for ClusterMesh
  # peer resolution, D60).
  inherit (fleetChecks) mkFleetChecks fleetChecksModule clustersOf;
}
