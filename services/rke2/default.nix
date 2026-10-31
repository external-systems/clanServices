{
  self,
  inputs,
}: {
  clanLib,
  lib,
  ...
}: let
  kube = import ../../lib/kube-cluster {inherit lib;};

  # Resolve the per-machine node_transport export from the configured
  # transport instance (D58: the ONLY transport view rke2 consumes —
  # generic schemaVersion 2, never provider service names). Returns the
  # whole export scope value, or null.
  transportExportFor = {
    exports,
    transport,
    machineName,
  }: let
    matches = lib.attrValues (
      clanLib.selectExports (
        scope:
          scope.serviceName
          == transport.service
          && scope.instanceName == transport.instance
          && scope.machineName == machineName
      )
      exports
    );
  in
    if matches == []
    then null
    else builtins.head matches;

  # Reduce a machine's node_transport export to the validated generic
  # profile. No provider-specific export is consulted (D58).
  memberTransport = {
    instanceName,
    machineName,
    exportValue,
  }:
    if exportValue == null
    then null
    else
      kube.transport.resolve {
        inherit instanceName machineName;
        transport = exportValue.node_transport or null;
      };

  # Artifact-flake Cilium facts (chart version -> committed manifest path;
  # image set -> airgap tarball packages). Pure: committed source files.
  ciliumVersions = import (inputs.pkgs + "/pkgs/cilium/versions.nix");
  ciliumManifest = inputs.pkgs.lib.cilium.manifest;

  # Artifact-flake CoreDNS pin (D46): the uniform clan-rendered
  # cluster.local DNS image. Pure: committed source file.
  corednsVersions = import (inputs.pkgs + "/pkgs/coredns/versions.nix");
  coreDNSImageRef = inputs.pkgs.lib.coredns.imageRef;

  # Shared role interface: both server and agent consume the same cluster/node
  # options plus the distro-specific rke2 escape hatches.
  roleInterface = {lib, ...}: {
    imports = [
      kube.interfaces.cluster
      kube.interfaces.node
    ];

    options = {
      profile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "cis";
        description = ''
          RKE2 profile passed to the runtime (e.g. `"cis"`).
          The value `"cis"` is mapped to the nixpkgs
          `services.rke2.cisHardening` option; any other non-null
          value is written to `config.yaml` as the `profile` key.
        '';
      };

      configOverrides = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = ''
          Extra top-level keys merged last into
          `/etc/rancher/rke2/config.yaml`. Use sparingly — most
          customization should go through the typed options above.
        '';
      };
    };
  };

  perInstanceFn = {
    instanceName,
    settings,
    machine,
    roles,
    exports,
    mkExports,
    meta,
    ...
  }: let
    allMembers = (roles.server.machines or {}) // (roles.agent.machines or {});

    roleMembers =
      (lib.mapAttrsToList (name: m: {
        machineName = name;
        role = "server";
        inherit (m) settings;
      }) (roles.server.machines or {}))
      ++ (lib.mapAttrsToList (name: m: {
        machineName = name;
        role = "agent";
        inherit (m) settings;
      }) (roles.agent.machines or {}));

    members = map (m: m.machineName) roleMembers;
    serverMembers = lib.filter (m: m.role == "server") roleMembers;

    fabricEnabled = settings.network.fabric != null;
    allTransportExports = lib.genAttrs members (
      name:
        if fabricEnabled
        then
          transportExportFor {
            inherit exports;
            transport = settings.network.fabric;
            machineName = name;
          }
        else null
    );

    # Per-machine resolved transport facts (null = manual-address member).
    allTransportFacts =
      lib.mapAttrs (
        name: exportValue:
          memberTransport {
            inherit instanceName;
            machineName = name;
            inherit exportValue;
          }
      )
      allTransportExports;

    # A member's node addresses: the node_transport export when
    # configured, else the explicit per-machine network.ipv4/ipv6
    # settings.
    memberAddr = name:
      if allTransportFacts.${name} != null
      then {
        inherit (allTransportFacts.${name}) ipv4 ipv6;
      }
      else {
        inherit (allMembers.${name}.settings.network) ipv4 ipv6;
      };

    initMember = lib.findFirst (m: m.settings.clusterInit) null serverMembers;

    # Members with known addresses — pool rendering skips null-addressed
    # members (the address assertions in mkClusterAssertions cover them).
    poolMembers = lib.filter (m: m.ipv4 != null && m.ipv6 != null) (
      map (m: {
        inherit (m) machineName;
        inherit (memberAddr m.machineName) ipv4 ipv6;
        inherit (m.settings) poolBlocks;
      })
      roleMembers
    );

    # --- Resolved identity (§6.2): hashed-default cilium id, resolved
    # dual-stack CIDRs, mesh group. Single source for distro config,
    # Cilium profile, HAProxy ports, and the kube_cluster export.
    resolvedCiliumId = kube.resolveCiliumId {inherit instanceName settings;};
    resolvedCidrs = kube.render.resolveCidrs {
      inherit settings;
      ciliumId = resolvedCiliumId;
    };

    domain =
      if settings.domain != null
      then settings.domain
      else meta.domain;
    # D54: the mesh group defaults from the fabric instance; explicit
    # meshGroup wins; manual clusters fall back to the domain.
    meshGroup =
      if settings.meshGroup != null
      then settings.meshGroup
      else if fabricEnabled
      then settings.network.fabric.instance
      else domain;

    # --- Data plane (D9/D10/D19/D49/D55): the Cilium-side BGP v2
    # resources and the fabric pool — one resolution seam shared by the
    # bundle, assertions, and the export. The host FRR is owned by
    # routed-fabric (D19); the distro service renders NO routing stack.
    hostAsns = lib.filterAttrs (_: asn: asn != null) (
      lib.mapAttrs (
        name: facts:
          if facts == null || facts.routeExchange != "local-router"
          then null
          else if allMembers.${name}.settings.bgp.hostASN != null
          then allMembers.${name}.settings.bgp.hostASN
          else facts.asn
      )
      allTransportFacts
    );

    nativeRouting = transportProfile == null || transportProfile.nativeRouting;
    localRouter =
      transportProfile != null && nativeRouting && transportProfile.routeExchange == "local-router";
    effectiveSettings =
      settings
      // {
        fabric =
          settings.fabric
          // {
            enable =
              if settings.fabric.enable != null
              then settings.fabric.enable
              else localRouter;
          };
        bgp =
          settings.bgp
          // {
            enable = settings.bgp.enable && localRouter;
          };
      };

    dp = kube.resolveDataPlane {
      inherit instanceName hostAsns;
      settings = effectiveSettings;
      ciliumId = resolvedCiliumId;
      members = poolMembers;
    };

    resolvedPools = kube.render.resolvePools {
      settings = effectiveSettings;
      members = poolMembers;
      extraPools = lib.optionalAttrs (dp.fabricPool != null) {${dp.fabricPool.name} = dp.fabricPool;};
    };

    # Effective per-member topology labels (invariant 7: default =
    # instance name, per-machine override wins; empty = eval-asserted).
    topologyOf = m: {
      region =
        if m.settings.topology.region != null
        then m.settings.topology.region
        else instanceName;
      zone =
        if m.settings.topology.zone != null
        then m.settings.topology.zone
        else instanceName;
    };

    # The cluster's uniform transport view (D58): mode/protocol/
    # capabilities from the members (uniformity is asserted in
    # mkClusterAssertions); the cluster MTU is the minimum of the
    # members' derived MTUs (one cilium-config serves all nodes).
    transportProfile = let
      profiles = lib.filter (p: p != null) (lib.attrValues allTransportFacts);
    in
      if profiles == []
      then null
      else
        (builtins.head profiles)
        // {
          mtu = lib.foldl' lib.min 65535 (map (p: p.mtu) profiles);
        };

    # The mesh peers: same-group clusters (self excluded), keyed by
    # cluster name. The bundle renders their published endpoints into
    # the cilium-clustermesh secrets; fleet-checks asserts symmetry,
    # same-group membership and group uniformity (D54/D60).
    peerClusters = let
      all = kube.clustersOf clanLib exports;
      sameGroup = lib.filter (c: c.cluster.meshGroup == meshGroup && c.cluster.name != instanceName) (
        builtins.attrValues all
      );
    in
      lib.listToAttrs (
        map (c: {
          name = c.cluster.name;
          value = c.cluster;
        })
        sameGroup
      );

    # --- ClusterMesh resolution (D60): placement, exposure, replicas,
    # VIPs, published endpoints, peer configs, cert SANs.
    meshResolved = kube.mesh.resolve {
      inherit instanceName domain;
      settings = effectiveSettings;
      ciliumId = resolvedCiliumId;
      transport =
        if transportProfile == null
        then
          # Manual-address clusters: no internal LB capability (no
          # transport-provided VIP pool); node-port is the universal
          # fallback (operator-managed node connectivity).
          {
            internalLoadBalancer = false;
            nodePort = true;
          }
        else transportProfile;
      members =
        map (m: {
          inherit (m) machineName role settings;
          inherit (memberAddr m.machineName) ipv4 ipv6;
        })
        roleMembers;
      peers = peerClusters;
      fabricBlocks =
        if dp.fabricPool != null
        then {
          v4 = builtins.elemAt dp.fabricPool.blocks 0;
          v6 = builtins.elemAt dp.fabricPool.blocks 1;
        }
        else null;
    };

    # The cert SANs (D60) — every exported member address, the published
    # endpoint set, the fan-in name and the external dnsName.
    meshSans = {
      dns = meshResolved.sanDns;
      ip = meshResolved.sanIps;
    };

    # kube_cluster export content (§6.2, schemaVersion 4): identity +
    # datapath facts (D58) + mesh facts (D60) + pool handoff. No secrets;
    # every interface option has a default.
    memberExportFacts = lib.listToAttrs (
      map (
        m: let
          addr = memberAddr m.machineName;
          facts = allTransportFacts.${m.machineName};
        in {
          name = m.machineName;
          value =
            {
              inherit (m) role;
              inherit (addr) ipv4 ipv6;
              topology = topologyOf m;
            }
            // lib.optionalAttrs (facts != null) {
              inherit
                (facts)
                interfaces
                mtu
                endpoint
                port
                ;
            };
        }
      )
      roleMembers
    );

    poolExportFacts =
      lib.mapAttrs (
        name: p:
          {
            inherit (p) blocks serviceSelector;
            owner = p.owner or null;
          }
          // (
            if dp.effectivePools ? ${name}
            then {
              scope = "cluster-global";
              inherit (dp.effectivePools.${name}) delivery;
            }
            else {
              scope = "per-machine";
              delivery = "node-fate-bound";
            }
          )
      )
      resolvedPools;
  in {
    exports = mkExports {
      kube_cluster = {
        schemaVersion = 4;
        name = instanceName;
        ciliumId = resolvedCiliumId;
        network = {
          inherit
            (resolvedCidrs)
            podCIDRv4
            podCIDRv6
            serviceCIDRv4
            serviceCIDRv6
            clusterDNS
            ;
          fabric =
            if fabricEnabled
            then {
              inherit (settings.network.fabric) service instance;
            }
            else {
              service = null;
              instance = null;
            };
        };
        # D58: the transport-derived datapath facts (group uniformity
        # inputs for the fleet checks).
        datapath =
          if transportProfile == null
          then {
            mode = "native";
            tunnelProtocol = null;
            routeExchange = null;
            devices = [];
            directRoutingDevice = null;
            mtu = null;
            internalLoadBalancer = false;
            nodePort = false;
          }
          else {
            inherit
              (transportProfile)
              mode
              tunnelProtocol
              routeExchange
              mtu
              internalLoadBalancer
              nodePort
              ;
            devices = transportProfile.interfaces;
            inherit (transportProfile) directRoutingDevice;
          };
        inherit meshGroup;
        # D54: null = full peering within the mesh group; an explicit
        # list names selective peers (symmetric, non-transitive).
        mesh = {
          inherit
            (settings.mesh)
            peers
            placement
            maxConnectedClusters
            ;
          # D60: the resolved exposure facts (peers dial `published`).
          exposure = kube.mesh.exportFacts {mesh = meshResolved;};
        };
        # D43 placeholder: the real controlDomain option lands in
        # phase 6; the export field is structured now.
        controlDomain.role = "standalone";
        members = memberExportFacts;
        pools = poolExportFacts;
        bgp =
          dp.exportFacts.bgp
          // {
            hostAsn = hostAsns.${machine.name} or dp.exportFacts.bgp.hostAsn;
          };
        inherit (dp.exportFacts) fabric;
      };
    };

    nixosModule = {
      config,
      pkgs,
      ...
    }: let
      role =
        if (roles.server.machines or {}) ? ${machine.name}
        then "server"
        else "agent";
      isServer = role == "server";
      machineSettings = allMembers.${machine.name}.settings;

      # --- Per-node kube-apiserver / supervisor load balancer -------
      # EVERY node runs a local haproxy bound to its own transport
      # addresses. The kubeapi FQDN resolves to the node's OWN address
      # via /etc/hosts, so the kubelet bootstrap, Cilium's API
      # endpoint (k8sServiceHost) and every joining server/agent all
      # go through the local LB, which balances across the servers'
      # transport addresses with TLS /readyz healthchecks. The
      # apiserver owns :6443 and the supervisor :9345 on every
      # address, so the LB listens on the derived ports (7442 +
      # resolved cilium.id, +1000 — unique per cluster sharing a
      # transport).
      kubeapiAddr = "kubeapi-${instanceName}.${domain}";
      haproxyKubeapiPort = 7442 + resolvedCiliumId;
      haproxySupervisorPort = haproxyKubeapiPort + 1000;

      ownAddr = memberAddr machine.name;
      nodeIPv4 = ownAddr.ipv4;
      nodeIPv6 = ownAddr.ipv6;

      ownTransport = allTransportFacts.${machine.name};
      # Every datapath interface of this machine (D58: the transport's
      # exported interfaces — one per fabric adjacency on native
      # fabrics) and its derived MTU; manual clusters fall back to the
      # single underlay guess eth0/1500 (the old behavior).
      transportInterfaces =
        if ownTransport != null
        then ownTransport.interfaces
        else [];

      # haproxy backend list: one entry per server-role member, both
      # families. Servers list THEMSELVES normally and the remote
      # servers as backups (local-first; option allbackups keeps the
      # cluster reachable through the backups when the local apiserver
      # is down); agents list every server plain.
      haproxyBackends =
        map (
          m: let
            addr = memberAddr m.machineName;
          in {
            name = m.machineName;
            inherit (addr) ipv4 ipv6;
            backup = isServer && m.machineName != machine.name;
          }
        )
        serverMembers;

      isInit = initMember != null && machine.name == initMember.machineName;
      joinUrl = "https://${kubeapiAddr}:${toString haproxySupervisorPort}";

      # Invariant 7: topology labels, defaulting to the instance name
      # (empty overrides are eval-asserted in mkClusterAssertions).
      topologyLabels = topologyOf {
        settings = machineSettings;
      };

      computedNodeLabels =
        [
          "cluster=${instanceName}"
          "role=${role}"
          "machine=${machine.name}"
          "topology.kubernetes.io/region=${topologyLabels.region}"
          "topology.kubernetes.io/zone=${topologyLabels.zone}"
        ]
        ++ lib.mapAttrsToList (k: v: "${k}=${v}") machineSettings.nodeLabels;

      # The canonical Cilium profile (§6.4) with the admin's
      # cilium.helmValues folded in — translated into bundle patches by
      # profilePatches (never re-run through helm, D26). The datapath
      # mode/protocol/MTU/devices derive from the node_transport
      # export (D58) — admin overrides cannot contradict them
      # (post-merge validated in mkCiliumValues).
      ciliumProfile = kube.render.mkCiliumValues {
        inherit settings instanceName;
        transportFacts = {
          # Devices cover EVERY cluster member's datapath interfaces
          # (one cilium-config serves all nodes, §6.4/D51); the MTU is
          # the cluster-wide minimum (transportProfile). Both fall back
          # to the manual-cluster guess.
          interfaces =
            if transportProfile != null
            then
              lib.unique (
                lib.concatMap (p: p.interfaces) (lib.filter (p: p != null) (lib.attrValues allTransportFacts))
              )
            else ["eth0"];
          directRoutingDevice =
            if ownTransport != null
            then ownTransport.directRoutingDevice
            else "eth0";
          mtu =
            if transportProfile != null
            then transportProfile.mtu
            else 1500;
          mode =
            if ownTransport != null
            then ownTransport.mode
            else "native";
          tunnelProtocol =
            if ownTransport != null
            then ownTransport.tunnelProtocol
            else null;
        };
        k8sServiceHost = kubeapiAddr;
        k8sServicePort = haproxyKubeapiPort;
      };

      manifestLabels = kube.render.mkManifestLabels {inherit instanceName;};

      # The kubenix bootstrap bundle (D26 layer 2, D40). Evaluated only
      # for the clusterInit node when bootstrap.apply is on.
      bundle = kube.render.mkBundle {
        inherit
          pkgs
          instanceName
          manifestLabels
          ;
        settings = effectiveSettings;
        kubenixSrc = inputs.kubenix;
        baseManifest = ciliumManifest;
        profile = ciliumProfile;
        pools = resolvedPools;
        podIPCidr = resolvedCidrs.clusterCidr;
        inherit (resolvedCidrs) clusterDNS;
        coreDNSImage = coreDNSImageRef;
        k8sServiceHost = kubeapiAddr;
        k8sServicePort = haproxyKubeapiPort;
        bgp = dp.bgpBundle;
        mesh = meshResolved;
      };

      effectiveRke2Package =
        if settings.packages.rke2 != null
        then settings.packages.rke2
        else pkgs.rke2;

      artifactPackages = inputs.pkgs.packages.${pkgs.stdenv.hostPlatform.system};

      imageArchSuffix =
        if pkgs.stdenv.hostPlatform.isx86_64
        then "amd64"
        else if pkgs.stdenv.hostPlatform.isAarch64
        then "arm64"
        else throw "rke2/${instanceName}: unsupported platform ${pkgs.stdenv.hostPlatform.system}";

      # The artifact flake publishes the digest-pinned Cilium tarballs
      # matching the bundle's manifest for each supported system.
      ciliumImages = map (name: artifactPackages.${name}) inputs.pkgs.lib.cilium.imagePackageNames;

      coreDNSImages = [artifactPackages.image-coredns];

      defaultImages =
        [
          effectiveRke2Package."images-core-linux-${imageArchSuffix}-tar-zst"
        ]
        ++ ciliumImages
        ++ coreDNSImages;

      # The pinned repo/tag/digest triples behind the preloaded
      # tarballs — the bundle references images digest-pinned
      # (repo:tag@digest), which containerd only resolves via a
      # name@digest alias (mkImageDigestAliases).
      pinnedImageTriples =
        map (img: {inherit (img) repo tag digest;}) ciliumVersions.images
        ++ [
          {inherit (corednsVersions) repo tag digest;}
        ];

      effectiveImages =
        if settings.packages.images != []
        then settings.packages.images
        else defaultImages;

      serverTokenPath =
        config.clan.core.vars.generators."rancher-server-token-${instanceName}".files.server-token.path;
      agentTokenPath =
        config.clan.core.vars.generators."rancher-agent-token-${instanceName}".files.agent-token.path;

      # --- HAProxy healthcheck + stats material (vars) -------------
      # The rancher-haproxy-<instance> shared generator renders the
      # kube-apiserver healthcheck client cert (signed by the PKI's
      # client CA) and the stats-page password hash (eval-consumed via
      # getPublicValue).
      haproxyHealthcheckFiles = config.clan.core.vars.generators."rancher-haproxy-${instanceName}".files;
      haproxyStatsPasswordHash = lib.trim (
        clanLib.getPublicValue {
          generator = "rancher-haproxy-${instanceName}";
          file = "password-hash-haproxy";
          flake = config.clan.core.settings.directory;
          default = throw "rke2/${instanceName}: no haproxy stats password hash; run 'clan vars generate' (generator rancher-haproxy-${instanceName})";
        }
      );

      haproxyConfig = kube.render.mkHaproxyConfig {
        inherit
          instanceName
          nodeIPv4
          nodeIPv6
          ;
        lbKubeapiPort = haproxyKubeapiPort;
        lbSupervisorPort = haproxySupervisorPort;
        backends = haproxyBackends;
        caCrtPath = haproxyHealthcheckFiles."kubeapi-ca.crt".path;
        clientPemPath = haproxyHealthcheckFiles."kubeapi-client.pem".path;
        statsPasswordHash = haproxyStatsPasswordHash;
        healthCheckSni = kubeapiAddr;
      };

      # distroDefaults (D42): in the minimal base (the default) the
      # distro's packaged add-ons AND the embedded helm-controller are
      # disabled — the kubenix bootstrap bundle (D40) replaced
      # helm-controller delivery in phase 3. The bundled rke2-cilium
      # and rke2-coredns charts are disabled in BOTH modes: canonical
      # Cilium comes from the bundle (§6.4) and cluster.local DNS comes
      # from the uniform clan-rendered CoreDNS in the bundle (D46;          # distroDefaults=true restores the distro's stock CoreDNS and the
      # bundle skips its own — mode-exclusive). RKE2 ships no
      # servicelb/klipper.
      disabledAddons =
        [
          "rke2-cilium"
          "rke2-coredns"
        ]
        ++ lib.optionals (!settings.distroDefaults.enable) [
          "rke2-ingress-nginx"
          "rke2-metrics-server"
          "rke2-snapshot-controller"
          "rke2-snapshot-validation-webhook"
        ];

      baseServerConfig =
        {
          token-file = serverTokenPath;
          agent-token-file = agentTokenPath;
          tls-san =
            [
              kubeapiAddr
            ]
            ++ lib.unique (
              lib.concatMap (
                m: let
                  addr = memberAddr m.machineName;
                in [
                  addr.ipv4
                  addr.ipv6
                ]
              )
              roleMembers
            );
          cluster-cidr = resolvedCidrs.clusterCidr;
          service-cidr = resolvedCidrs.serviceCidr;
          cluster-dns = resolvedCidrs.clusterDNS;
          disable-kube-proxy = true;
          # BYO CNI: canonical Cilium comes from the bootstrap bundle,
          # not the bundled rke2-cilium chart (§6.4).
          cni = "none";
          node-label = computedNodeLabels;
        }
        // lib.optionalAttrs (!settings.distroDefaults.enable) {
          ingress-controller = "none";
          disable-helm-controller = true;
        }
        // lib.optionalAttrs isInit {
          cluster-init = true;
        }
        // lib.optionalAttrs (!isInit) {
          server = joinUrl;
        }
        // lib.optionalAttrs (settings.profile != null && settings.profile != "cis") {
          inherit (settings) profile;
        }
        // settings.configOverrides
        // lib.optionalAttrs (disabledAddons != [] || settings.configOverrides ? disable) {
          disable = (settings.configOverrides.disable or []) ++ disabledAddons;
        };

      baseAgentConfig =
        {
          server = joinUrl;
          token-file = agentTokenPath;
          node-label = computedNodeLabels;
        }
        // lib.optionalAttrs (settings.profile != null && settings.profile != "cis") {
          inherit (settings) profile;
        }
        // settings.configOverrides;

      cleanConfig = lib.filterAttrs (_: v: v != null) (
        {
          resolv-conf =
            if config.services.resolved.enable
            then "/run/systemd/resolve/resolv.conf"
            else "/etc/resolv.conf";
        }
        // (
          if isServer
          then baseServerConfig
          else baseAgentConfig
        )
      );
      configPath = pkgs.writeText "rke2-config.yaml" (builtins.toJSON cleanConfig);
    in {
      imports = [../../lib/kube-cluster/network-facts.nix];

      # D19: the ONE host routing stack (FRR) is owned by
      # routed-fabric — the distro service renders no BIRD and no
      # second FRR stack; it publishes the kube_cluster facts
      # routed-fabric consumes.

      # Internal eval seam for tests (rendered distro config.yaml and
      # the bundle's object JSON; bundleJson only on the clusterInit
      # node with bootstrap.apply on).
      options.clan.kubeClusters = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              renderedDistroConfig = lib.mkOption {
                type = lib.types.attrs;
                internal = true;
              };
              bundleJson = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                internal = true;
                default = null;
              };
            };
          }
        );
        internal = true;
        default = {};
      };

      config = lib.mkMerge [
        {
          nixpkgs.overlays = lib.mkAfter [inputs.pkgs.overlays.kubernetes];

          clan = {
            _networkFacts.forwarding = true;
            kubeClusters.${instanceName} = {
              renderedDistroConfig = cleanConfig;
              bundleJson = lib.mkIf (isInit && settings.bootstrap.apply) bundle.json;
            };
          };

          assertions =
            (kube.assertions.mkClusterAssertions {
              inherit
                instanceName
                roleMembers
                settings
                ;
              transportFacts =
                if fabricEnabled
                then allTransportFacts
                else null;
              inherit nativeRouting;
              # Cross-role parity (the export is per-member; fleet
              # consumers read one scope — all roles must agree on the
              # cluster-level knobs). Sourced from MACHINE-level
              # settings (roles.<r>.settings is deprecated read-side in
              # clan-core) — per-machine overrides are covered too.
              roleSettings = lib.flatten (
                lib.mapAttrsToList (
                  roleName: r:
                    lib.mapAttrsToList (machineName: m: {
                      name = "${roleName}/${machineName}";
                      inherit (m) settings;
                    }) (r.machines or {})
                )
                roles
              );
            })
            ++ (kube.assertions.mkPoolAssertions {
              inherit instanceName;
              settings = effectiveSettings;
              members = poolMembers;
              ciliumId = resolvedCiliumId;
              reservedCidrs = [
                resolvedCidrs.podCIDRv4
                resolvedCidrs.podCIDRv6
                resolvedCidrs.serviceCIDRv4
                resolvedCidrs.serviceCIDRv6
              ];
            })
            # D9: a fabric-allocated node ASN equal to the cluster's Cilium
            # ASN makes the Cilium→FRR `::1` session accidental iBGP.
            ++ (kube.assertions.mkBgpAsnAssertions {
              inherit instanceName hostAsns;
              inherit (dp) bgpActive;
              ciliumAsn = dp.asns.cilium;
            })
            ++ [
              {
                assertion = settings.coredns.helmValues == {};
                message = "rke2/${instanceName}: coredns.helmValues is not supported; the HelmChartConfig machinery was removed in phase 3 — the distro's CoreDNS is configured by the operator (distroDefaults) or day-2";
              }
            ];

          clan.core.vars.generators = lib.mkMerge (
            [
              (kube.vars.mkTokenGenerators {inherit pkgs instanceName;})
              (kube.vars.mkHaproxyGenerator {inherit pkgs instanceName;})
              # D60: the mesh group CA (shared across the group) and the
              # per-cluster apiserver leaf set (SANs = the published
              # endpoints). Defined on every member; share = true keeps
              # one generation per group/instance.
              (kube.vars.mkMeshCaGenerator {
                inherit pkgs;
                group = meshGroup;
              })
              (kube.vars.mkMeshCertGenerator {
                inherit pkgs instanceName;
                group = meshGroup;
                sans = meshSans;
              })
            ]
            ++ lib.optionals isServer [
              (kube.vars.mkPkiGenerator {inherit pkgs instanceName;})
              (kube.vars.mkAdminKubeconfigGenerator {
                inherit pkgs instanceName;
                server = "https://${kubeapiAddr}:${toString haproxyKubeapiPort}";
              })
            ]
          );

          services.rke2 = {
            enable = true;
            inherit role;
            serverAddr =
              if isInit
              then ""
              else joinUrl;
            tokenFile =
              if isServer
              then serverTokenPath
              else agentTokenPath;
            agentTokenFile = lib.mkIf isServer agentTokenPath;
            nodeIP = "${nodeIPv4},${nodeIPv6}";
            nodeLabel = computedNodeLabels;
            images = effectiveImages;
            cisHardening = settings.profile == "cis";
            # NO services.rke2.manifests: clan manifests are delivered
            # by the bootstrap bundle only (D40; §6.12 eval-rejects the
            # distro manifests dir for clan manifests — structurally
            # enforced by never writing there).
          };

          # Keep /etc/rancher/rke2 under NixOS's etc machinery so the
          # directory exists and is writable; rke2 writes its Pod
          # Security Admission config (rke2-pss.yaml) there at runtime.
          # rke2 reads /etc/rancher/rke2/config.yaml by default (the
          # nixpkgs module adds --config only when its configPath is
          # set), so the etc entry IS the config.
          environment.etc."rancher/rke2/config.yaml".source = configPath;

          # RKE2's runtime-image loader scans /var/lib/rancher/rke2/agent/images
          # for tarballs at the top level. The nixpkgs rke2 module links images
          # into a `nixos/` subdirectory, so we add top-level symlinks plus the
          # `.cache.json` marker that airgap imports expect.
          systemd.tmpfiles.rules =
            [
              "f /var/lib/rancher/rke2/agent/images/.cache.json 0600 root root -"
            ]
            # Admin kubeconfig (clan var) at the documented path.
            ++ lib.optionals isServer [
              "L+ /etc/rancher/rke2/admin-kubeconfig - - - - ${
                config.clan.core.vars.generators."rancher-admin-kubeconfig-${instanceName}".files."kubeconfig.yaml".path
              }"
            ]
            ++ map (
              img: "L+ /var/lib/rancher/rke2/agent/images/${builtins.unsafeDiscardStringContext (baseNameOf img)} - - - - ${toString img}"
            )
            effectiveImages;

          boot = {
            kernelModules = [
              "br_netfilter"
              "overlay"
            ];
            kernel.sysctl = {
              "net.ipv4.conf.all.rp_filter" = lib.mkForce 2;
              "net.ipv4.ip_forward" = lib.mkForce true;
              "net.ipv6.conf.all.forwarding" = lib.mkForce true;
            };
          };

          fileSystems."/sys/fs/bpf" = {
            device = "bpffs";
            fsType = "bpf";
            options = [
              "rw"
              "nosuid"
              "nodev"
              "noexec"
              "relatime"
              "mode=700"
            ];
          };

          networking = {
            nftables.enable = true;
            firewall = {
              checkReversePath = "loose";
              extraReversePathFilterRules = lib.concatStringsSep "\n" (
                map (iface: ''iifname "${iface}" accept'') transportInterfaces
                ++ ["meta mark and 0x0f00 == 0x0200 accept"]
              );
              trustedInterfaces =
                [
                  "cilium_host"
                  "cilium_net"
                ]
                ++ transportInterfaces;
              extraInputRules = let
                interfaceGuard =
                  if transportInterfaces != []
                  then "iifname { ${lib.concatStringsSep ", " (map (i: ''"${i}"'') transportInterfaces)} } "
                  else "";
              in ''
                # Pod traffic: pod->apiserver flows (ClusterIP DNAT'd to
                # the node endpoint on 6443) re-enter the input hook on a
                # cilium_*/lxc* veth — without this accept every in-cluster
                # API client crash-loops.
                iifname { "cilium*", "lxc*" } accept
                ${interfaceGuard}tcp dport { 6443, 9345, ${toString haproxyKubeapiPort}, ${toString haproxySupervisorPort}, 10250, 2379, 2380, 2381 } accept
              '';
              extraForwardRules = ''
                iifname { "cilium*", "lxc*" } accept
                oifname { "cilium*", "lxc*" } accept
              '';
            };
            # kubeapi FQDN -> the node's OWN transport address: every
            # node talks to its LOCAL haproxy (the per-node
            # kube-apiserver load balancer), which balances across the
            # servers' transport addresses with TLS /readyz
            # healthchecks.
            extraHosts = ''
              ${nodeIPv4} ${kubeapiAddr}
              ${nodeIPv6} ${kubeapiAddr}
            '';
          };

          # --- haproxy: per-node kube-apiserver load balancer --------
          # Servers run kube-apiserver/supervisor, but every node needs
          # the LB path: an agent's join and its API traffic ride ITS
          # OWN haproxy.
          services.haproxy = {
            enable = true;
            config = haproxyConfig;
          };

          # haproxy binds transport addresses created by IfState;
          # Restart=always rides out any remaining bind race.
          systemd.services.haproxy = {
            after = ["ifstate.service"];
            unitConfig.StartLimitIntervalSec = 0;
          };
        }

        # --- PKI sync (servers only): the pre-generated rancher-pki
        # CA tree lands in rke2's tls dir BEFORE rke2-server starts, so
        # rke2 adopts the custom CAs instead of generating its own.
        (lib.mkIf isServer (
          kube.nixos.mkPkiSync {
            inherit pkgs;
            pkiGenerator = config.clan.core.vars.generators."rancher-pki-${instanceName}";
            tlsDir = "/var/lib/rancher/rke2/server/tls";
            beforeUnit = "rke2-server.service";
            namePrefix = "rke2-${instanceName}";
          }
        ))

        # The bootstrap bundle + apply oneshot on the clusterInit node
        # only (D40). bootstrap.apply = false is the day-2 off-ramp.
        (lib.mkIf (isInit && settings.bootstrap.apply) (
          kube.mkBootstrapApply {
            inherit pkgs instanceName;
            namePrefix = "rke2";
            serverUnit = "rke2-server.service";
            kubeconfigPath = "/etc/rancher/rke2/rke2.yaml";
            bundle = bundle.path;
          }
        ))

        # The ClusterMesh apiserver TLS secrets from clan vars (D60) on
        # the clusterInit node — after the bundle created the apiserver
        # objects. Key material never enters the bundle/Nix store.
        (lib.mkIf isInit (
          kube.mkClustermeshSecretsApply {
            inherit pkgs instanceName;
            namePrefix = "rke2";
            serverUnit = "rke2-server.service";
            bootstrapUnit = "rke2-${instanceName}-bootstrap-apply.service";
            kubeconfigPath = "/etc/rancher/rke2/rke2.yaml";
            files = config.clan.core.vars.generators."rancher-clustermesh-${instanceName}".files;
          }
        ))

        # Offline resolution of the bundle's digest-pinned image
        # references (D26/D40 airgap): tag each preloaded image with
        # its name@digest alias on every node. Only when the default
        # preload set is in effect (x86_64; an admin packages.images
        # override owns its own digest resolution).
        (lib.mkIf (pkgs.stdenv.hostPlatform.isx86_64 && settings.packages.images == []) (
          kube.mkImageDigestAliases {
            inherit pkgs instanceName;
            runtimeUnit =
              if isServer
              then "rke2-server.service"
              else "rke2-agent.service";
            images = pinnedImageTriples;
          }
        ))
      ];
    };
  };
in {
  _class = "clan.service";
  manifest = {
    name = "rke2";
    description = "Thin RKE2 Kubernetes cluster on lib/kube-cluster";
    categories = ["System"];
    readme = builtins.readFile ./README.md;
    exports = {
      # D58: the transport is consumed through the GENERIC node_transport
      # schemaVersion 2 export only — never provider-specific exports.
      inputs = ["node_transport"];
      out = ["kube_cluster"];
    };
  };

  roles.server = {
    description = "RKE2 server (runs the control plane and, by default, workloads).";
    interface = roleInterface;
    perInstance = perInstanceFn;
  };

  roles.agent = {
    description = "RKE2 agent (worker node).";
    interface = roleInterface;
    perInstance = perInstanceFn;
  };
}
