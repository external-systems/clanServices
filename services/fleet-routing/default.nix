# fleet-routing (SPEC §6.13, D11/D13/D19/D22/D33): routed access to
# cluster VIPs for non-Kubernetes clan hosts, over the same BIRD/BGP
# fabric the clusters run (D9).
#
# Session topology (campaign-A contract): cluster nodes dial OUT to
# fleet-routing machines — the operator lists each fleet machine's mesh
# addresses in the cluster's `bgp.upstreamPeers` with this instance's ASN
# (exported as fleet_routing.asn; deterministic hash of the instance
# name). Cluster nodes listen only on their loopback BGP link
# (169.254.179.1, D9) — fleet machines CANNOT dial in. Fleet-routing
# BIRDs are passive, listen on their own mesh addresses only (strict
# bind), and accept only:
#   - the consumed clusters' shared-bgp pool VIPs as exact /32+/128
#     (pool handoff facts from the kube_cluster exports),
#   - (admin role) pod CIDRs / ClusterIPs from clusters that opted in
#     (D13 export facts bgp.advertisePodCIDRs/advertiseClusterIPs) —
#     and only when the operator flagged the peer
#     bgp.upstreamPeers[].receivePodCIDRs/receiveClusterIPs on the
#     cluster side.
# Routes install into the kernel (merge paths = ECMP across the
# advertising nodes) — unlike cluster nodes, fleet hosts DO install.
#
# Node duality (D33/D16): a cluster member may also hold fleet-routing
# roles; fragments merge into the host's ONE bird daemon via clan.bird
# (the lib's bird-module is path-imported for dedup, like the distro
# services) and the router id is the same mesh IPv4 everywhere (setting
# it twice with the same value merges; a conflict is an eval error).
{
  clanLib,
  lib,
  ...
}:
let
  kube = import ../../lib/kube-cluster { inherit lib; };
  cidr = import ../../lib/kube-cluster/cidr.nix { inherit lib; };

  birdSym = kube.bgp.birdSym;

  routedInterfaceName =
    instanceName: service: clusterInstance: memberName:
    let
      key = "${instanceName}:${service}:${clusterInstance}:${memberName}";
    in
    "fr${builtins.substring 0 4 (birdSym instanceName)}-${
      builtins.substring 0 8 (builtins.hashString "sha256" key)
    }";

  routedNetdevName = instanceName: name: "40-fleet-routing-${instanceName}-${name}";

  # The machine's own node_transport facts from the consumed mesh
  # instance (null when the machine is not a mesh member) — same
  # consumption pattern as the distro services.
  ownTransportFor =
    {
      exports,
      mesh,
      machineName,
    }:
    let
      matches = lib.attrValues (
        clanLib.selectExports (
          scope:
          scope.serviceName == mesh.service
          && scope.instanceName == mesh.instance
          && scope.machineName == machineName
        ) exports
      );
    in
    if matches == [ ] then null else (builtins.head matches).node_transport;

  # The kube_cluster facts of a consumed cluster (identical content on
  # every member scope; null when the cluster is not in the inventory).
  clusterFactsFor =
    {
      exports,
      service,
      instance,
    }:
    let
      matches = lib.attrValues (
        clanLib.selectExports (
          scope: scope.serviceName == service && scope.instanceName == instance
        ) exports
      );
    in
    if matches == [ ] then null else (builtins.head matches).kube_cluster;

  byFamily = blocks: {
    v4 = builtins.filter (b: !(lib.hasInfix ":" b)) blocks;
    v6 = builtins.filter (lib.hasInfix ":") blocks;
  };

  cap4 =
    block:
    let
      prefix = builtins.fromJSON (builtins.elemAt (lib.splitString "/" block) 1);
    in
    if prefix >= 16 then lib.foldl' (acc: _: acc * 2) 1 (lib.genList (x: x) (32 - prefix)) else 4096;
  cap6 =
    block:
    let
      prefix = builtins.fromJSON (builtins.elemAt (lib.splitString "/" block) 1);
    in
    if prefix >= 120 then lib.foldl' (acc: _: acc * 2) 1 (lib.genList (x: x) (128 - prefix)) else 4096;

  # BIRD prefix-set pattern: exact /32 (v4) / /128 (v6) within blocks.
  exactSet =
    blocks: len:
    "[ ${lib.concatMapStringsSep ", " (b: "${b}{${toString len},${toString len}}") blocks} ]";

  # Superset match (router upstream re-advertisement of owned prefixes).
  coverSet = prefixes: "[ ${lib.concatStringsSep ", " prefixes} ]";

  # Per-cluster acceptance filter body (one branch per accepted category).
  inFilterBody =
    {
      vipBlocks,
      podCidr,
      svcCidr,
      len,
    }:
    let
      vipLine = if vipBlocks == [ ] then null else "  if net ~ ${exactSet vipBlocks len} then accept;";
      podLine =
        if podCidr == null then
          null
        else
          # Pod CIDRs arrive as the nodes' allocated CIDRs (the bundle's
          # CiliumPodIPPool pins maskSize 24 v4 / 64 v6).
          "  if net ~ [ ${podCidr}{${if len == 32 then "24,24" else "64,64"}} ] then accept;";
      svcLine = if svcCidr == null then null else "  if net ~ ${exactSet [ svcCidr ] len} then accept;";
      lines = lib.filter (l: l != null) [
        vipLine
        podLine
        svcLine
      ];
    in
    if lines == [ ] then "  reject;" else lib.concatStringsSep "\n" (lines ++ [ "  else reject;" ]);

  # The BIRD fragment for one fleet-routing instance on one host.
  mkFragment =
    {
      instanceName,
      asn,
      ownMesh, # { interface, ipv4, ipv6 }
      clusters, # resolved: [ { ns, birdAsn, members = [{name,ipv4,ipv6}], vip = {v4,v6}, pod = {v4,v6} or null-ish, svc = ... } ]
      roleKind, # "client" | "admin" | "router"
      routerPrefixes ? [ ],
      upstreamPeers ? [ ],
    }:
    let
      ns = birdSym instanceName;

      mkClusterFilters = c: ''
        filter fr_${ns}_${c.ns}_in4 {
        ${inFilterBody {
          vipBlocks = c.vip.v4;
          podCidr = c.pod.v4;
          svcCidr = c.svc.v4;
          len = 32;
        }}
        }
        filter fr_${ns}_${c.ns}_in6 {
        ${inFilterBody {
          vipBlocks = c.vip.v6;
          podCidr = c.pod.v6;
          svcCidr = c.svc.v6;
          len = 128;
        }}
        }
      '';

      lim4 =
        c:
        lib.max 1 (
          lib.min 4096 (
            lib.foldl' (acc: b: acc + cap4 b) 0 c.vip.v4
            + (if c.pod.v4 != null then 1024 else 0)
            + (if c.svc.v4 != null then 4096 else 0)
          )
        );
      lim6 =
        c:
        lib.max 1 (
          lib.min 4096 (
            lib.foldl' (acc: b: acc + cap6 b) 0 c.vip.v6
            + (if c.pod.v6 != null then 1024 else 0)
            + (if c.svc.v6 != null then 4096 else 0)
          )
        );

      mkMemberProto =
        c: m: family:
        let
          is4 = family == 4;
          localAddr = if is4 then ownMesh.ipv4 else ownMesh.ipv6;
          peerAddr = if is4 then m.ipv4 else m.ipv6;
          channel = if is4 then "ipv4" else "ipv6";
          filterName = "fr_${ns}_${c.ns}_in${toString family}";
          igpTable = "fr_${ns}_mesh_igp_table${toString family}";
          lim = if is4 then lim4 c else lim6 c;
        in
        ''
          protocol bgp fr_${ns}_${c.ns}_${birdSym m.name}${toString family} {
            local ${localAddr} port 179 as ${toString asn};
            neighbor ${peerAddr} as ${toString c.birdAsn};
            passive on;
            strict bind on;
            free bind on;
            # /32 mesh hosts are reachable through routes, not interface subnets.
            multihop 1;
            hold time 9;
            keepalive time 3;
            connect retry time 5;
            ${channel} {
              igp table ${igpTable};
              import filter ${filterName};
              import limit ${toString lim} action block;
              export none;
            };
          }
        '';

      upstreams4 = builtins.filter (p: !(lib.hasInfix ":" p.address)) upstreamPeers;
      upstreams6 = builtins.filter (p: lib.hasInfix ":" p.address) upstreamPeers;

      outFilters =
        let
          fam = byFamily routerPrefixes;
        in
        lib.optionalString (routerPrefixes != [ ]) ''
          filter fr_${ns}_out4 {
            if net ~ ${coverSet fam.v4} then accept;
            else reject;
          }
          filter fr_${ns}_out6 {
            if net ~ ${coverSet fam.v6} then accept;
            else reject;
          }
        '';

      kernelExportBody =
        family:
        let
          lines = lib.concatMap (
            c:
            map (
              m:
              if family == 6 then
                # BIRD needs onlink for private-IGP recursion; the kernel
                # instead validates this gateway through the per-peer /128.
                "  if proto = \"fr_${ns}_${c.ns}_${birdSym m.name}${toString family}\" then { onlink = false; accept; }"
              else
                "  if proto = \"fr_${ns}_${c.ns}_${birdSym m.name}${toString family}\" then accept;"
            ) c.members
          ) clusters;
        in
        if lines == [ ] then "  reject;" else lib.concatStringsSep "\n" (lines ++ [ "  else reject;" ]);

      mkUpstream = i: peer: channel: ''
        protocol bgp fr_${ns}_upstream_${toString i} {
          local port 4179 as ${toString asn};
          neighbor ${peer.address} as ${toString peer.asn};
          hold time 9;
          keepalive time 3;
          connect retry time 5;
          ${channel} {
            import none;
            export filter fr_${ns}_out${if channel == "ipv4" then "4" else "6"};
            next hop self;
          };
        }
      '';
    in
    ''
      # fleet-routing/${instanceName} (D33, role ${roleKind}): passive
      # acceptance of the cluster nodes' dial-out (they listen only on
      # their loopback link, D9), filtered to pool VIPs (+ D13 opt-ins on
      # admin); routes install into the kernel with ECMP merge.
      # BIRD-only IGP tables preserve per-node gateways for recursive BGP
      # next hops and ECMP through the per-member routed interfaces; they
      # never leak into the kernel. A dual-role host keeps self on its mesh.
      ipv4 table fr_${ns}_mesh_igp_table4;
      ipv6 table fr_${ns}_mesh_igp_table6;
      protocol static fr_${ns}_mesh_igp4 {
        ipv4 { table fr_${ns}_mesh_igp_table4; };
        ${lib.concatMapStringsSep "\n" (
          c:
          lib.concatMapStringsSep "\n" (
            m:
            "route ${m.ipv4}/32 via ${m.ipv4} dev \"${
              if (m.routedInterface or null) == null then ownMesh.interface else m.routedInterface
            }\" onlink;"
          ) c.members
        ) clusters}
      }
      # Onlink is required for BIRD's private-IGP recursion and stripped at
      # kernel export. The networkd host routes then validate each gateway;
      # their higher metric keeps BGP on the main mesh.
      protocol static fr_${ns}_mesh_igp6 {
        ipv6 { table fr_${ns}_mesh_igp_table6; };
        ${lib.concatMapStringsSep "\n" (
          c:
          lib.concatMapStringsSep "\n" (
            m:
            "route ${m.ipv6}/128 via ${m.ipv6} dev \"${
              if (m.routedInterface or null) == null then ownMesh.interface else m.routedInterface
            }\" onlink;"
          ) c.members
        ) clusters}
      }
      filter fr_${ns}_kernel_out4 {
      ${kernelExportBody 4}
      }
      filter fr_${ns}_kernel_out6 {
      ${kernelExportBody 6}
      }
      protocol kernel fr_${ns}_k4 {
        ipv4 {
          # Export-only: on a dual-role node, learning Cilium's local routes
          # contaminates the fleet table and logs their loopback next hops.
          import none;
          export filter fr_${ns}_kernel_out4;
        };
        merge paths on;
      }
      protocol kernel fr_${ns}_k6 {
        ipv6 {
          import none;
          export filter fr_${ns}_kernel_out6;
        };
        merge paths on;
      }
      ${lib.concatMapStringsSep "\n" (
        c:
        mkClusterFilters c
        + lib.concatMapStringsSep "\n" (m: mkMemberProto c m 4 + mkMemberProto c m 6) c.members
      ) clusters}
      ${lib.optionalString (roleKind == "router") outFilters}
      ${lib.concatStringsSep "\n" (lib.imap1 (i: p: mkUpstream i p "ipv4") upstreams4)}
      ${lib.concatStringsSep "\n" (
        lib.imap1 (i: p: mkUpstream (i + builtins.length upstreams4) p "ipv6") upstreams6
      )}
    '';

  # Resolve a role's per-machine view: own mesh facts + the consumed
  # clusters' kube_cluster facts (nulls where missing — the role's
  # assertions turn that into a hard error).
  resolveRole =
    {
      instanceName,
      settings,
      machine,
      exports,
      roleKind,
    }:
    let
      ownTransport =
        if settings.mesh.service != null then
          ownTransportFor {
            inherit exports machineName;
            inherit (settings) mesh;
          }
        else
          null;
      machineName = machine.name;

      fleetAsn = kube.bgp.hashAsn "fleet-routing-bird" instanceName;

      clusters = map (
        c:
        let
          facts = clusterFactsFor {
            inherit exports;
            inherit (c) service instance;
          };
          sharedPools = lib.filterAttrs (_: p: p.delivery == "shared-bgp") (
            if facts != null then facts.pools else { }
          );
          vipBlocks = lib.concatMap (p: p.blocks) (builtins.attrValues sharedPools);
          admin = roleKind == "admin";
          # kube_cluster schema v3: pod-pool advertisements are unconditional
          # (D49) — the legacy opt-in leaf is gone, so default to true.
          wantPods = admin && facts != null && (facts.bgp.advertisePodCIDRs or true);
          wantSvc = admin && facts != null && facts.bgp.advertiseClusterIPs;
        in
        {
          inherit (c) service instance;
          inherit facts;
          ns = birdSym "${c.service}-${c.instance}";
          # kube_cluster schema v3 renamed the host-side leaf birdAsn → hostAsn.
          birdAsn = if facts != null then (facts.bgp.birdAsn or facts.bgp.hostAsn or null) else null;
          members = lib.filter (m: m.ipv4 != null && m.ipv6 != null) (
            lib.mapAttrsToList (name: m: {
              inherit name;
              inherit (m)
                ipv4
                ipv6
                endpoint
                mtu
                port
                ;
              routedInterface =
                if name == machineName then null else routedInterfaceName instanceName c.service c.instance name;
            }) (if facts != null then facts.members else { })
          );
          vip = byFamily vipBlocks;
          pod = {
            v4 = if wantPods then facts.network.podCIDRv4 else null;
            v6 = if wantPods then facts.network.podCIDRv6 else null;
          };
          svc = {
            v4 = if wantSvc then facts.network.serviceCIDRv4 else null;
            v6 = if wantSvc then facts.network.serviceCIDRv6 else null;
          };
          dns = if facts != null then facts.fabric.coreDNS else null;
          inherit vipBlocks;
        }
      ) settings.clusters;

      # DNS stub zones/servers per role (D22): client gets the instance
      # zone only; admin adds the svc/pod zones when the cluster renders
      # them (and the role knobs stay on).
      dnsClusters = builtins.filter (c: c.dns != null && c.dns.ipv4 != null) clusters;
      baseZones = map (c: c.dns.zone) dnsClusters;
      svcZones = lib.optionals (roleKind == "admin" && settings.dns.svcZones) (
        builtins.filter (z: z != "") (map (c: c.dns.svcZone) dnsClusters)
      );
      podZones = lib.optionals (roleKind == "admin" && settings.dns.podZones) (
        builtins.filter (z: z != "") (map (c: c.dns.podZone) dnsClusters)
      );
      zones = lib.unique (baseZones ++ svcZones ++ podZones);
      dnsServers = lib.unique (
        lib.concatMap (c: [
          c.dns.ipv4
          c.dns.ipv6
        ]) dnsClusters
      );

      active =
        ownTransport != null
        && clusters != [ ]
        && lib.all (c: c.facts != null && c.birdAsn != null) clusters;

      routedPeers = lib.concatMap (
        c:
        map (
          m:
          let
            interface = m.routedInterface;
          in
          {
            inherit interface;
            inherit (m) endpoint ipv4 ipv6;
            memberName = m.name;
            clusterService = c.service;
            clusterInstance = c.instance;
            netdevName = routedNetdevName instanceName interface;
            allowedIPs = [
              "${m.ipv4}/32"
              "${m.ipv6}/128"
            ]
            ++ c.vipBlocks
            ++ lib.optionals (c.pod.v4 != null) [
              c.pod.v4
              c.pod.v6
            ]
            ++ lib.optionals (c.svc.v4 != null) [
              c.svc.v4
              c.svc.v6
            ];
          }
        ) (builtins.filter (m: m.routedInterface != null) c.members)
      ) clusters;

      missingRoutedEndpoints = map (p: "${p.clusterService}/${p.clusterInstance}:${p.memberName}") (
        builtins.filter (p: p.endpoint == null) routedPeers
      );

      fragment =
        if active then
          mkFragment {
            inherit
              instanceName
              clusters
              roleKind
              ;
            asn = fleetAsn;
            ownMesh = {
              inherit (ownTransport) ipv4 ipv6 interface;
            };
            routerPrefixes = settings.prefixes or [ ];
            upstreamPeers = settings.upstreamPeers or [ ];
          }
        else
          null;

      # Router role (D8/§6.12): every consumed cluster's shared-bgp pool
      # blocks must be covered by the owned prefixes.
      uncoveredPoolBlocks = lib.concatMap (
        c: builtins.filter (b: !lib.any (p: cidr.contains p b) (settings.prefixes or [ ])) c.vipBlocks
      ) clusters;
    in
    {
      inherit
        ownTransport
        clusters
        fleetAsn
        zones
        dnsServers
        active
        fragment
        routedPeers
        missingRoutedEndpoints
        uncoveredPoolBlocks
        ;
    };

  # Shared role options (all three roles). Called fresh per role so the
  # module values never collide.
  commonRoleOptions =
    { lib, ... }:
    {
      options = {
        mesh = {
          service = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Name of the clanService exporting node_transport (e.g.
              "wireguard-mesh") — the mesh instance this machine joined.
            '';
          };
          instance = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "The mesh instance name this machine joined.";
          };
        };

        clusters = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                service = lib.mkOption {
                  type = lib.types.str;
                  description = "The cluster's clanService name (e.g. k3s, rke2).";
                };
                instance = lib.mkOption {
                  type = lib.types.str;
                  description = "The cluster's instance name.";
                };
              };
            }
          );
          default = [ ];
          description = ''
            Clusters to consume (their kube_cluster exports provide member
            mesh endpoints, pool handoff facts, BGP/fabric facts). The
            cluster side must list this machine's mesh addresses in its
            bgp.upstreamPeers with this fleet-routing instance's ASN
            (exported as fleet_routing.asn).
          '';
        };

        dns.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Install the systemd-resolved route-only DNS stub(s) for the
            consumed clusters' private zones onto the mesh link. Off = BGP
            routes only.
          '';
        };
      };
    };

  adminRoleOptions =
    { lib, ... }:
    {
      imports = [ commonRoleOptions ];
      options.dns = {
        svcZones = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "D22(a): also stub <instance>.svc.<domain> when the cluster renders it (default-on for admin, D33).";
        };
        podZones = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "D22(b): also stub the pod zone when the cluster renders it (default-on for admin, D33).";
        };
      };
    };

  routerRoleOptions =
    { lib, ... }:
    {
      imports = [ commonRoleOptions ];
      options = {
        prefixes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            The prefixes this router owns (D33): exported as
            fleet_routing.routerPrefixes (the fleet-wide check rejects any
            cluster shared-bgp pool outside them) and used as the upstream
            re-advertisement filter. Eval-asserted to cover every consumed
            cluster's shared-bgp pool blocks.
          '';
        };
        upstreamPeers = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                address = lib.mkOption {
                  type = lib.types.str;
                  description = "Further-upstream BGP peer address (v4 or v6).";
                };
                asn = lib.mkOption {
                  type = lib.types.ints.between 1 4294967295;
                  description = "Peer ASN.";
                };
              };
            }
          );
          default = [ ];
          description = ''
            Optional further-upstream peers the router re-advertises the
            owned prefixes' routes to (family-split dial-out, next hop
            self).
          '';
        };
        ndpInterfaces = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            LAN interfaces on which to answer NDP for the owned IPv6
            prefixes (proxy-NDP via ndppd, method static — D9's
            "proxy-NDP if on-LAN").
          '';
        };
      };
    };

  mkRole = roleKind: interfaceModule: {
    description =
      {
        client = "Reach cluster VIPs + the <instance>.<domain> DNS stub (D33).";
        admin = "client + D13 route consumption + D22 svc/pod zones (D33).";
        router = "Upstream prefix ownership, filtered VIP acceptance, proxy-NDP (D33).";
      }
      .${roleKind};
    interface = interfaceModule;
    perInstance =
      {
        instanceName,
        settings,
        machine,
        exports,
        mkExports,
        ...
      }:
      let
        r = resolveRole {
          inherit
            instanceName
            settings
            machine
            exports
            roleKind
            ;
        };
        isRouter = roleKind == "router";
        dnsActive = !isRouter && settings.dns.enable && r.zones != [ ];
      in
      {
        exports = mkExports {
          fleet_routing = {
            schemaVersion = 1;
            asn = r.fleetAsn;
            routerPrefixes = if isRouter then settings.prefixes else [ ];
          };
        };

        nixosModule =
          { config, ... }:
          let
            generatorName = "wireguard-mesh-${settings.mesh.instance}";
            privateKeyFile = config.clan.core.vars.generators.${generatorName}.files.privatekey.path;

            publicKeyOf =
              name:
              lib.trim (
                clanLib.getPublicValue {
                  generator = generatorName;
                  machine = name;
                  file = "publickey";
                  flake = config.clan.core.settings.directory;
                  default = throw "fleet-routing/${instanceName}: no WireGuard public key for cluster member '${name}'";
                }
              );

            routedNetdevs = lib.listToAttrs (
              map (p: {
                name = p.netdevName;
                value = {
                  netdevConfig = {
                    Kind = "wireguard";
                    Name = p.interface;
                    MTUBytes = r.ownTransport.mtu;
                  };
                  wireguardConfig = {
                    PrivateKeyFile = privateKeyFile;
                  };
                  wireguardPeers = [
                    (
                      {
                        PublicKey = publicKeyOf p.memberName;
                        AllowedIPs = p.allowedIPs;
                      }
                      // lib.optionalAttrs (p.endpoint != null) { Endpoint = p.endpoint; }
                    )
                  ];
                };
              }) r.routedPeers
            );

            routedNetworks = lib.listToAttrs (
              map (p: {
                name = p.netdevName;
                value = {
                  matchConfig.Name = p.interface;
                  address = [
                    "${r.ownTransport.ipv4}/32"
                    "${r.ownTransport.ipv6}/128"
                  ];
                  routes = [
                    {
                      Destination = "${p.ipv4}/32";
                      Metric = 2048;
                    }
                    {
                      Destination = "${p.ipv6}/128";
                      Metric = 2048;
                    }
                  ];
                };
              }) r.routedPeers
            );
          in
          {
            # One BIRD per host (D19): path import dedups with the
            # distro services' import.
            imports = [ kube.birdModule ];

            config = lib.mkMerge [
              {
                assertions = [
                  {
                    assertion = settings.mesh.service != null && settings.mesh.instance != null;
                    message = "fleet-routing/${instanceName}: mesh.service + mesh.instance are required (the machine must join a node_transport-exporting mesh)";
                  }
                  {
                    assertion = r.ownTransport != null;
                    message = "fleet-routing/${instanceName}: machine '${machine.name}' has no node_transport export from ${settings.mesh.service}/${settings.mesh.instance} — add it to that mesh instance";
                  }
                  {
                    assertion = settings.clusters != [ ];
                    message = "fleet-routing/${instanceName}: role ${roleKind} on '${machine.name}' consumes no clusters";
                  }
                  {
                    assertion = lib.all (c: c.facts != null) r.clusters;
                    message = "fleet-routing/${instanceName}: no kube_cluster export for: ${
                      lib.concatStringsSep ", " (
                        map (c: "${c.service}/${c.instance}") (builtins.filter (c: c.facts == null) r.clusters)
                      )
                    }";
                  }
                  {
                    assertion = lib.all (c: c.facts == null || c.facts.bgp.enabled) r.clusters;
                    message = "fleet-routing/${instanceName}: these clusters have bgp.enable = false (no BGP plane to consume): ${
                      lib.concatStringsSep ", " (
                        map (c: "${c.service}/${c.instance}") (
                          builtins.filter (c: c.facts != null && !c.facts.bgp.enabled) r.clusters
                        )
                      )
                    }";
                  }
                  {
                    assertion = !isRouter || settings.prefixes != [ ];
                    message = "fleet-routing/${instanceName}: the router role needs a non-empty prefixes list (the prefixes it owns, D33)";
                  }
                  {
                    assertion = !isRouter || r.uncoveredPoolBlocks == [ ];
                    message = "fleet-routing/${instanceName}: consumed clusters' shared-bgp pool blocks escape this router's prefixes (D8): ${lib.concatStringsSep ", " r.uncoveredPoolBlocks}";
                  }
                  {
                    assertion = r.missingRoutedEndpoints == [ ];
                    message = "fleet-routing/${instanceName}: every remote cluster member needs a reachable node_transport endpoint for its routed interface; missing: ${lib.concatStringsSep ", " r.missingRoutedEndpoints}";
                  }
                  {
                    assertion = lib.all (p: builtins.stringLength p.interface <= 15) r.routedPeers;
                    message = "fleet-routing/${instanceName}: a routed WireGuard interface exceeds the 15-character kernel limit";
                  }
                  {
                    assertion =
                      lib.length (lib.unique (map (p: p.interface) r.routedPeers)) == lib.length r.routedPeers;
                    message = "fleet-routing/${instanceName}: routed WireGuard interface names collide; check duplicate cluster/member references";
                  }
                ];
              }

              (lib.mkIf r.active {
                clan.bird = {
                  # Same value the cluster service would set on a
                  # dual-role host (the mesh IPv4) — equal definitions
                  # merge, a conflict is an eval error (D19).
                  routerId = r.ownTransport.ipv4;
                  fragments."fleet-routing-${instanceName}".config = r.fragment;
                };
                # Mesh addresses land via networkd moments after boot.
                systemd.services.bird.after = [ "systemd-networkd.service" ];
                systemd.network = {
                  netdevs = routedNetdevs;
                  networks = routedNetworks;
                };
                networking.networkmanager.unmanaged = map (p: p.interface) r.routedPeers;
              })

              (lib.mkIf (r.active && dnsActive) {
                services.resolved = {
                  enable = true;
                  # Global route-only zones follow the kernel's ECMP route;
                  # per-link DNS bypasses that route or binds to wg-mesh,
                  # whose AllowedIPs exclude the private CoreDNS VIP.
                  settings.Resolve = {
                    DNS = r.dnsServers;
                    Domains = map (z: "~${z}") r.zones;
                  };
                };
              })

              (lib.mkIf (r.active && isRouter) {
                # A router forwards VIP traffic to the cluster nodes.
                boot.kernel.sysctl = {
                  "net.ipv4.ip_forward" = lib.mkDefault true;
                  "net.ipv6.conf.all.forwarding" = lib.mkDefault true;
                };
                # BIRD's wildcard :4179 listen artifact (D9 note) accepts
                # nothing; drop it inbound like on cluster nodes.
                networking.firewall.extraInputRules = ''
                  tcp dport 4179 drop
                '';
                services.ndppd = lib.mkIf (settings.ndpInterfaces != [ ]) {
                  enable = true;
                  proxies = lib.listToAttrs (
                    map (iface: {
                      name = iface;
                      value.rules = lib.listToAttrs (
                        map (p: {
                          name = p;
                          value.method = "static";
                        }) (builtins.filter (lib.hasInfix ":") settings.prefixes)
                      );
                    }) settings.ndpInterfaces
                  );
                };
              })
            ];
          };
      };
  };
in
{
  _class = "clan.service";
  manifest = {
    name = "fleet-routing";
    description = "Routed access to cluster VIPs (+ private DNS zones) for non-Kubernetes clan hosts";
    categories = [ "Network" ];
    readme = builtins.readFile ./README.md;
    exports = {
      inputs = [
        "node_transport"
        "kube_cluster"
      ];
      out = [ "fleet_routing" ];
    };
  };

  # One machine holds at most one role per instance (D33 duality is about
  # combining fleet-routing with CLUSTER membership, not stacking roles).
  perMachine =
    { instances, machine, ... }:
    {
      nixosModule =
        { lib, ... }:
        let
          roleMemberships = lib.concatMap (
            instanceName:
            let
              inst = instances.${instanceName};
            in
            lib.filter (r: r != null) (
              map (
                roleName:
                if inst.roles ? ${roleName} && inst.roles.${roleName}.machines ? ${machine.name} then
                  "${instanceName}/${roleName}"
                else
                  null
              ) (builtins.attrNames inst.roles)
            )
          ) (builtins.attrNames instances);
          perInstance = lib.groupBy (r: builtins.head (lib.splitString "/" r)) roleMemberships;
          doubled = lib.filterAttrs (_: rs: builtins.length rs > 1) perInstance;
        in
        {
          assertions = [
            {
              assertion = doubled == { };
              message = "fleet-routing: machine '${machine.name}' holds multiple roles in one instance: ${
                lib.concatStringsSep "; " (
                  lib.mapAttrsToList (i: rs: "${i}: ${lib.concatStringsSep ", " rs}") doubled
                )
              }";
            }
          ];
        };
    };

  roles = {
    client = mkRole "client" commonRoleOptions;
    admin = mkRole "admin" adminRoleOptions;
    router = mkRole "router" routerRoleOptions;
  };
}
