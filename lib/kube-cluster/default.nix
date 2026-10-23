{ lib }:
let
  # Stable cluster-id derivation (§6.2): sha256(instanceName), first 8 hex
  # chars as a 32-bit int, mod 127, +1 → 1–127. Pure Nix, no IFD.
  # Collisions between two instances' resolved ids are an eval error
  # (fleet-wide check, fleet-checks.nix); explicit cilium.id pins escape it.
  hashCiliumId =
    instanceName:
    let
      hexVal =
        c:
        let
          digits = lib.stringToCharacters "0123456789abcdef";
          idx = lib.findFirst (i: builtins.elemAt digits i == c) (-1) (lib.genList (x: x) 16);
        in
        if idx == -1 then throw "kube-cluster: bad hex digit '${c}' in instance-name hash" else idx;
      n = lib.foldl' (acc: c: acc * 16 + hexVal c) 0 (
        lib.stringToCharacters (lib.substring 0 8 (builtins.hashString "sha256" instanceName))
      );
    in
    1 + lib.mod n 127;

  # The resolved cilium id: explicit cilium.id wins; null → hashed default.
  resolveCiliumId =
    { instanceName, settings }:
    if settings.cilium.id != null then settings.cilium.id else hashCiliumId instanceName;

  # Pod/service CIDR derivation from the (resolved) Cilium cluster id.
  # Multiple clusters can share one transport when their ids differ.
  cidrs = id: {
    clusterCidr = "10.${toString (id * 2 - 1)}.0.0/16,fd10:${toString (id * 2 - 1)}::/56";
    serviceCidr = "10.${toString (id * 2)}.0.0/16,fd10:${toString (id * 2)}::/112";
    clusterDNS = "10.${toString (id * 2)}.0.10";
  };

  clusterInterface = import ./cluster-interface.nix;
  nodeInterface = import ./node-interface.nix;

  cidrLib = import ./cidr.nix { inherit lib; };
  bgp = import ./bgp.nix { inherit lib; };
  bird = import ./bird.nix { inherit lib; };
  cilium = import ./cilium.nix {
    inherit
      lib
      cidrs
      hashCiliumId
      cidrLib
      ;
  };
  assertFns = import ./assertions.nix { inherit lib hashCiliumId; };
  bundle = import ./bundle.nix { inherit lib; };
  bootstrap = import ./bootstrap.nix { };
  haproxy = import ./haproxy.nix { inherit lib; };
  nixos = import ./nixos.nix { inherit lib; };
  vars = import ./vars.nix { inherit lib; };
  fleetChecks = import ./fleet-checks.nix { inherit lib; };

  # §6.11 manifest labels: on every clan-rendered object, never in
  # selectors. bundle.nix adds clan.lol/config-hash per object at the end
  # of the render.
  mkManifestLabels =
    {
      instanceName,
      component ? "bootstrap",
    }:
    {
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
  resolvePools =
    {
      settings,
      members,
      extraPools ? { },
    }:
    lib.listToAttrs (
      map (m: {
        name = m.machineName;
        value = {
          blocks = [
            "${m.ipv4}/32"
            "${m.ipv6}/128"
          ]
          ++ m.poolBlocks;
          serviceSelector."clan.lol/pool" = m.machineName;
        };
      }) members
    )
    // lib.mapAttrs (_: p: { inherit (p) blocks serviceSelector; }) (settings.pools // extraPools);

  # The phase-5 data plane in one resolution seam (D9/D10/D19/D22):
  # shared by both distro services and the eval tests so the bundle, the
  # BIRD fragment, the assertions, and the export all see the same facts.
  #
  # members: [ { machineName, ... } ] (the cluster's member machines with
  # known addresses). Returns:
  #   asns              — { cilium, bird } (deterministic private 32-bit)
  #   fabricPool        — null or the fabric pool attrset (D10)
  #   effectivePools    — settings.pools + the fabric pool
  #   sharedBgpPoolNames / sharedBgpBlocks / bgpActive
  #   bgpBundle         — mkBundle's bgp param (null when bgp inactive)
  #   birdFragment      — the cluster's BIRD fragment text (null likewise)
  #   privateCoreDNS    — mkBundle's privateCoreDNS param (null when off)
  #   exportFacts       — the kube_cluster export's bgp/fabric subtrees
  resolveDataPlane =
    {
      instanceName,
      settings,
      ciliumId,
      domain,
      clusterDNS,
      members,
    }:
    let
      asns = bgp.resolveBgpAsns { inherit instanceName settings; };
      fabricPool = bgp.mkFabricPool { inherit instanceName ciliumId settings; };
      effectivePools =
        settings.pools // lib.optionalAttrs (fabricPool != null) { ${fabricPool.name} = fabricPool; };
      sharedBgpPools = lib.filterAttrs (_: p: p.delivery == "shared-bgp") effectivePools;
      sharedBgpPoolNames = builtins.attrNames sharedBgpPools;
      bgpActive = sharedBgpPoolNames != [ ];
      sharedBgpBlocks = lib.concatMap (p: p.blocks) (builtins.attrValues sharedBgpPools);
      fabricBlocks' = bgp.fabricBlocks { inherit ciliumId settings; };
      vips = bgp.fabricCoreDNSVips { inherit ciliumId settings; };
      privateDnsOn = settings.fabric.enable && settings.fabric.coredns.enable;
    in
    {
      inherit
        asns
        fabricPool
        effectivePools
        sharedBgpPoolNames
        bgpActive
        sharedBgpBlocks
        ;

      bgpBundle =
        if bgpActive then
          {
            inherit asns sharedBgpPoolNames;
            members = map (m: m.machineName) members;
            inherit (settings.bgp) advertisePodCIDRs advertiseClusterIPs;
          }
        else
          null;

      birdFragment =
        if bgpActive then
          bgp.mkBirdFragment {
            inherit instanceName asns;
            blocks = sharedBgpBlocks;
            inherit (settings.bgp) upstreamPeers;
          }
        else
          null;

      privateCoreDNS =
        if privateDnsOn then
          {
            inherit domain clusterDNS;
            vip4 = vips.ipv4;
            vip6 = vips.ipv6;
            fabricPoolName = fabricPool.name;
            inherit (settings.fabric.coredns) wildcardAddress svcZone podZone;
          }
        else
          null;

      exportFacts = {
        bgp = {
          enabled = bgpActive;
          ciliumAsn = asns.cilium;
          birdAsn = asns.bird;
          inherit (settings.bgp) upstreamPeers advertisePodCIDRs advertiseClusterIPs;
        };
        fabric = {
          enabled = settings.fabric.enable;
          pool = if fabricPool != null then fabricPool.name else "";
          ipv4Block = if settings.fabric.enable then fabricBlocks'.v4 else null;
          ipv6Block = if settings.fabric.enable then fabricBlocks'.v6 else null;
          coreDNS = {
            ipv4 = if privateDnsOn then vips.ipv4 else null;
            ipv6 = if privateDnsOn then vips.ipv6 else null;
            zone = if privateDnsOn then "${instanceName}.${domain}" else "";
          };
        };
      };
    };
in
rec {
  inherit
    cidrs
    hashCiliumId
    resolveCiliumId
    resolveDataPlane
    ;

  # BGP v2 / fabric derivation helpers (D9/D10) and the vendored BIRD
  # fragment machinery (D19).
  inherit bgp bird;

  # The vendored BIRD NixOS module (path — NixOS dedups path imports, so
  # every contributing clanService lands in ONE bird daemon per host).
  birdModule = ./bird-module.nix;

  interfaces = {
    cluster = clusterInterface;
    node = nodeInterface;
    # The custom export interface (§6.2, D45): published by both distro
    # services, consumed by fleet checks and (phase 5+) fleet-routing.
    kube_cluster = ./kube-cluster-interface.nix;
  };

  render = {
    inherit (cilium) mkCiliumValues resolveCidrs;
    inherit (bundle)
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

  # Bootstrap-apply oneshot fragment (D40).
  inherit (bootstrap) mkBootstrapApply;

  # Vars generators (bare generator attrsets — the distro service merges
  # them into clan.core.vars.generators, gated by role as documented in
  # vars.nix).
  inherit vars;

  # NixOS fragment builders (PKI sync).
  inherit nixos;

  # Fleet-wide assertions (§6.2): mkFleetChecks computes the clan.checks
  # attrset from the kube_cluster exports; fleetChecksModule is a
  # clan-class module wiring them into a clan evaluation
  # (`clan.imports = [ kube.fleetChecksModule ]`).
  inherit (fleetChecks) mkFleetChecks fleetChecksModule;
}
