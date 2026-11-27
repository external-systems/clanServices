# The ONE implementation of the k3s and rke2 clan services (hard rule 4,
# K13). `services/k3s` and `services/rke2` call this with a distro
# record that holds only what differs between the two distros:
#
#   name            "k3s" | "rke2": unit, path, var and message prefix
#   displayName     "k3s" | "RKE2": manifest and role descriptions
#   readme          the service's README.md
#   supervisor      true: the distro has a separate supervisor port
#                   (9345) behind its own HAProxy front; joins use it
#   serverUnit      the systemd unit of a server
#   agentUnit       the systemd unit of an agent
#   extraOptions    lib -> options of the role interface beside
#                   configOverrides (rke2: `profile`)
#   extraOwnedKeys  configOverrides keys owned by a typed option
#   corednsHelmValuesMessage
#                   why `coredns.helmValues` is refused
#   imagesPackage   {package, arch} -> the distro's airgap image tarball
#   disabledAddons  settings -> the distro add-ons to disable
#   serverConfig    {settings, resolvedCidrs} -> the distro's own keys
#                   of a server's config.yaml
#   agentConfig     {settings} -> the distro's own keys of an agent's
#   pkiGeneratorOn  "server" | "init": the machines with the PKI var
#   nixos           ctx -> the distro's runtime config (services.<name>,
#                   the config.yaml in /etc, tmpfiles)
#   pki             ctx -> how the custom CA tree reaches the distro
{
  inputs,
  distro,
}: {
  clanLib,
  lib,
  ...
}: let
  kube = import ./. {inherit lib;};
  modeScope = import ../mode-scope.nix {inherit lib;};
  inherit (distro) name;
  dataDir = "/var/lib/rancher/${name}";
  kubeconfigPath = "/etc/rancher/${name}/${name}.yaml";
  # The apiserver's own port; the LB fronts it on haproxyKubeapiPort.
  kubeapiPort = 6443;
  # The rke2 supervisor's own port (joins), when the distro has one.
  supervisorPort = 9345;

  # Resolve the per-machine node_transport export from the configured
  # transport instance (D58: the ONLY transport view the distro consumes
  # — generic schemaVersion 2, never provider service names). Returns
  # the whole export scope value, or null.
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
  ciliumVersions = import (inputs.org-pkgs + "/pkgs/cilium/versions.nix");
  ciliumManifest = inputs.org-pkgs.lib.cilium.manifest;

  # Artifact-flake CoreDNS pin (D46): the uniform clan-rendered
  # cluster.local DNS image. Pure: committed source file.
  corednsVersions = import (inputs.org-pkgs + "/pkgs/coredns/versions.nix");
  coreDNSImageRef = inputs.org-pkgs.lib.coredns.imageRef;

  # Shared role interface: both server and agent consume the same cluster/node
  # options plus the distro's escape hatches.
  roleInterface = {lib, ...}: {
    imports = [
      kube.interfaces.cluster
      kube.interfaces.node
    ];

    options =
      distro.extraOptions lib
      // {
        configOverrides = lib.mkOption {
          type = lib.types.attrs;
          default = {};
          description = ''
            Extra top-level keys merged last into
            `/etc/rancher/${name}/config.yaml`. Use sparingly — most
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
    # SPEC.md D71: the CLAT link and the IPv6-only underlay links of every
    # member, from the netif and nat_gateway exports (lib/kube-cluster/devices.nix).
    extraDevices = kube.devices.extra {
      inherit clanLib exports members;
    };

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

    localRouter =
      transportProfile != null && transportProfile.routeExchange == "local-router";
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
        # D58: the transport-derived datapath facts (routing is always
        # native, D72).
        datapath =
          if transportProfile == null
          then {
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
      # Mode scoping (N4): rendered only in the instance's modes.
      modeActive = modeScope.active config machineSettings.modes;

      # --- Per-node kube-apiserver / supervisor load balancer -------
      # EVERY node runs a local haproxy bound to its own transport
      # addresses. The kubeapi FQDN resolves to the node's OWN address
      # via /etc/hosts, so the kubelet bootstrap, Cilium's API
      # endpoint (k8sServiceHost) and every joining server/agent all
      # go through the local LB, which balances across the servers'
      # transport addresses with TLS /readyz healthchecks. The
      # apiserver owns :6443 (and an rke2 supervisor :9345) on every
      # address, so the LB listens on the derived ports (7442 +
      # resolved cilium.id, +1000 — unique per cluster sharing a
      # transport). k3s serves joins on the API port: one front.
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
      joinUrl = "https://${kubeapiAddr}:${toString (
        if distro.supervisor
        then haproxySupervisorPort
        else haproxyKubeapiPort
      )}";

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
        memberCount = builtins.length members;
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
                ++ extraDevices
              )
            else ["eth0"] ++ extraDevices;
          directRoutingDevice =
            if ownTransport != null
            then ownTransport.directRoutingDevice
            else "eth0";
          mtu =
            if transportProfile != null
            then transportProfile.mtu
            else 1500;
        };
        k8sServiceHost = kubeapiAddr;
        k8sServicePort = haproxyKubeapiPort;
        # D69: NodePorts answer on the members' node addresses only.
        nodeAddresses = lib.concatMap (
          name: let
            addr = memberAddr name;
          in
            lib.filter (a: a != null) [
              addr.ipv4
              addr.ipv6
            ]
        ) (lib.attrNames allMembers);
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
        memberCount = builtins.length (lib.attrNames allMembers);
        k8sServiceHost = kubeapiAddr;
        k8sServicePort = haproxyKubeapiPort;
        bgp = dp.bgpBundle;
        mesh = meshResolved;
      };

      effectivePackage =
        if settings.packages.${name} != null
        then settings.packages.${name}
        else pkgs.${name};

      artifactPackages = inputs.org-pkgs.packages.${pkgs.stdenv.hostPlatform.system};

      imageArchSuffix =
        if pkgs.stdenv.hostPlatform.isx86_64
        then "amd64"
        else if pkgs.stdenv.hostPlatform.isAarch64
        then "arm64"
        else throw "${name}/${instanceName}: unsupported platform ${pkgs.stdenv.hostPlatform.system}";

      # The artifact flake publishes the digest-pinned Cilium tarballs
      # matching the bundle's manifest for each supported system.
      ciliumImages = map (name: artifactPackages.${name}) inputs.org-pkgs.lib.cilium.imagePackageNames;

      coreDNSImages = [artifactPackages.image-coredns];

      defaultImages =
        [
          (distro.imagesPackage {
            package = effectivePackage;
            arch = imageArchSuffix;
          })
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

      # --- HAProxy healthcheck material (vars) ---------------------
      # The rancher-haproxy-<instance> shared generator renders the
      # kube-apiserver healthcheck client cert (signed by the PKI's
      # client CA). The stats page is read-only on loopback (K15).
      haproxyHealthcheckFiles = config.clan.core.vars.generators."rancher-haproxy-${instanceName}".files;

      haproxyConfig = kube.render.mkHaproxyConfig {
        inherit
          instanceName
          nodeIPv4
          nodeIPv6
          ;
        inherit kubeapiPort;
        lbKubeapiPort = haproxyKubeapiPort;
        lbSupervisorPort = haproxySupervisorPort;
        enableSupervisor = distro.supervisor;
        backends = haproxyBackends;
        caCrtPath = haproxyHealthcheckFiles."kubeapi-ca.crt".path;
        clientPemPath = haproxyHealthcheckFiles."kubeapi-client.pem".path;
        healthCheckSni = kubeapiAddr;
      };

      # distroDefaults (D42): the distro's own list (services/<distro>).
      disabledAddons = distro.disabledAddons settings;

      # The keys the service renders; configOverrides may not set them
      # (K14, kube.assertions.mkConfigOverrideAssertions). The distro
      # adds its own keys (CNI off, kube-proxy and the bundled charts).
      ownedServerConfig =
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
          disable-kube-proxy = true;
          node-label = computedNodeLabels;
        }
        // lib.optionalAttrs (!settings.distroDefaults.enable) {
          disable-helm-controller = true;
        }
        // lib.optionalAttrs isInit {
          cluster-init = true;
        }
        // lib.optionalAttrs (!isInit) {
          server = joinUrl;
        }
        // distro.serverConfig {inherit settings resolvedCidrs kubeapiPort;};

      ownedAgentConfig =
        {
          server = joinUrl;
          token-file = agentTokenPath;
          node-label = computedNodeLabels;
        }
        // distro.agentConfig {inherit settings;};

      baseServerConfig =
        ownedServerConfig
        // settings.configOverrides
        // lib.optionalAttrs (disabledAddons != [] || settings.configOverrides ? disable) {
          disable = (settings.configOverrides.disable or []) ++ disabledAddons;
        };

      baseAgentConfig = ownedAgentConfig // settings.configOverrides;

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
      configPath = pkgs.writeText "${name}-config.yaml" (builtins.toJSON cleanConfig);

      # What the distro's own pieces (distro.nixos, distro.pki) read.
      ctx = {
        inherit
          lib
          kube
          config
          pkgs
          instanceName
          settings
          role
          isServer
          isInit
          joinUrl
          serverTokenPath
          agentTokenPath
          nodeIPv4
          nodeIPv6
          computedNodeLabels
          effectivePackage
          effectiveImages
          configPath
          dataDir
          ;
        adminKubeconfigPath =
          config.clan.core.vars.generators."rancher-admin-kubeconfig-${instanceName}".files."kubeconfig.yaml".path;
        pkiGenerator = config.clan.core.vars.generators."rancher-pki-${instanceName}";
      };
    in {
      imports = [
        ../../lib/kube-cluster/network-facts.nix
        # the ownership registry: this service declares what it owns
        ../../lib/ownership.nix
        ../../lib/modes.nix
      ];

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
        (modeScope.scope modeActive {
          nixpkgs.overlays = lib.mkAfter [inputs.org-pkgs.overlays.kubernetes];

          clan = {
            _networkFacts = {
              forwarding = true;
              # The cluster's ranges, for the overlap checks of
              # lib/ownership.nix (containers, the tailnet).
              clusters.${instanceName} = {
                distro = name;
                ciliumId = resolvedCiliumId;
                inherit
                  (resolvedCidrs)
                  podCIDRv4
                  podCIDRv6
                  serviceCIDRv4
                  serviceCIDRv6
                  clusterDNS
                  ;
                fabric = {
                  inherit (settings.network.fabric) service instance;
                };
              };
            };
            kubeClusters.${instanceName} = {
              renderedDistroConfig = cleanConfig;
              bundleJson = lib.mkIf (isInit && settings.bootstrap.apply) bundle.json;
            };
          };

          assertions =
            modeScope.assertions {
              service = name;
              inherit instanceName config;
              machineName = machine.name;
              inherit (machineSettings) modes;
              everyMode =
                if isServer && builtins.length (builtins.attrNames allMembers) > 1
                then "an etcd voter of a cluster with other machines"
                else null;
            }
            ++ map (message: {
              assertion = false;
              message = "${name}/${instanceName}: Cilium devices: ${message}";
            }) (
              kube.devices.vpnViolations {
                inherit clanLib exports members;
                devices = lib.splitString " " (ciliumProfile.devices or "");
              }
              ++ kube.devices.routerViolations {
                inherit clanLib exports members;
                devices = lib.splitString " " (ciliumProfile.devices or "");
              }
              ++ kube.devices.underlayViolations {
                inherit clanLib exports members;
                nativeRoutingCidr = "10.0.0.0/8";
              }
            )
            ++ (kube.assertions.mkClusterAssertions {
              inherit
                instanceName
                roleMembers
                settings
                resolvedCidrs
                ;
              transportFacts =
                if fabricEnabled
                then allTransportFacts
                else null;
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
              transportFacts = allTransportFacts;
            })
            ++ (kube.assertions.mkHostAsnAssertions {
              inherit instanceName roleMembers;
              transportFacts = allTransportFacts;
            })
            ++ kube.assertions.mkConfigOverrideAssertions {
              inherit instanceName;
              distro = name;
              overrides = settings.configOverrides;
              # distro.extraOwnedKeys have their typed options
              ownedKeys =
                distro.extraOwnedKeys
                ++ builtins.attrNames (
                  if isServer
                  then ownedServerConfig
                  else ownedAgentConfig
                );
            }
            ++ [
              {
                assertion = settings.coredns.helmValues == {};
                message = "${name}/${instanceName}: coredns.helmValues is not supported; ${distro.corednsHelmValuesMessage}";
              }
            ];

          warnings = kube.assertions.mkClusterWarnings {inherit instanceName roleMembers;};

          # K1: a machine gets only the secrets its role reads. An agent
          # joins with the agent token; the server token is a server's.
          clan.core.vars.generators = lib.mkMerge (
            [
              (kube.vars.mkAgentTokenGenerator {inherit pkgs instanceName;})
              (kube.vars.mkHaproxyGenerator {inherit pkgs instanceName;})
            ]
            # D60: the mesh group CA (shared across the group) and the
            # per-cluster apiserver leaf set (SANs = the published
            # endpoints), on the clusterInit server only: its secrets
            # oneshot is the one reader. share = true keeps one
            # generation per group/instance.
            ++ lib.optionals isInit [
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
              (kube.vars.mkServerTokenGenerator {inherit pkgs instanceName;})
              (kube.vars.mkAdminKubeconfigGenerator {
                inherit pkgs instanceName;
                server = "https://${kubeapiAddr}:${toString haproxyKubeapiPort}";
              })
            ]
            # the custom CA tree: on every server (rke2) or the init
            # server only (k3s), whichever machines distro.pki reads it on
            ++ lib.optional (
              if distro.pkiGeneratorOn == "server"
              then isServer
              else isInit
            ) (kube.vars.mkPkiGenerator {inherit pkgs instanceName;})
          );

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

          # Floating pools (D8): a runtime controller puts these addresses
          # on a candidate machine. They are that controller's, so a network
          # reapply must not remove them (specs/netif.md N6).
          clanServices.networking.owners."${instanceName}-floating".addresses = lib.concatMap (pool: pool.blocks) (
            lib.filter (pool: pool.delivery == "floating" && lib.elem machine.name pool.candidates) (
              builtins.attrValues dp.effectivePools
            )
          );

          networking = {
            nftables.enable = true;
            firewall = {
              checkReversePath = "loose";
              extraReversePathFilterRules = lib.concatStringsSep "\n" (
                map (iface: ''iifname "${iface}" accept'') transportInterfaces
                ++ ["meta mark and 0x0f00 == 0x0200 accept"]
              );
              # The fabric links are not trusted here: routed-fabric owns
              # their trust (firewall.trust), and the cluster opens only
              # its own ports, by source (K2, lib/kube-cluster/firewall.nix).
              # A pod's API traffic (ClusterIP translated to a server's
              # 6443) arrives with its pod source.
              trustedInterfaces = [
                "cilium_host"
                "cilium_net"
              ];
              extraInputRules = kube.render.mkInputRules {
                inherit transportInterfaces isServer;
                inherit (resolvedCidrs) podCIDRv4 podCIDRv6;
                members = map (m: {inherit (m) role;} // memberAddr m.machineName) roleMembers;
                # the API, the LBs, the kubelet, Cilium's health port
                clusterPorts =
                  lib.optional isServer kubeapiPort
                  ++ [haproxyKubeapiPort]
                  ++ lib.optional distro.supervisor haproxySupervisorPort
                  ++ [
                    10250
                    4240
                  ];
                # the supervisor: joins through the members' HAProxy
                memberOnlyPorts = lib.optional (isServer && distro.supervisor) supervisorPort;
              };
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
        })

        # The distro's runtime: services.<distro>, its config.yaml in
        # /etc and its tmpfiles (services/<distro>).
        (modeScope.scope modeActive (distro.nixos ctx))

        # The custom CA tree reaches the distro before its server
        # starts, so it adopts the clan CAs (distro.pki).
        (lib.mkIf modeActive (distro.pki ctx))

        # The bootstrap bundle + apply oneshot on the clusterInit node
        # only (D40). bootstrap.apply = false is the day-2 off-ramp.
        # specs/gateway.md §16.3: a first server without data never
        # starts beside a cluster that is alive
        (lib.mkIf (modeActive && isInit) (
          kube.nixos.mkInitGuard {
            inherit pkgs;
            namePrefix = "${name}-${instanceName}";
            beforeUnit = distro.serverUnit;
            etcdDir = "${dataDir}/server/db/etcd";
            overrideFile = "${dataDir}/server/allow-new-cluster-${instanceName}";
            port = kubeapiPort;
            peers = map (
              m: let
                addr = memberAddr m.machineName;
              in
                if addr.ipv4 != null
                then addr.ipv4
                else addr.ipv6
            ) (builtins.filter (m: m.machineName != machine.name) serverMembers);
          }
        ))

        (lib.mkIf (modeActive && isInit && settings.bootstrap.apply) (
          kube.mkBootstrapApply {
            inherit config pkgs instanceName kubeconfigPath;
            namePrefix = name;
            inherit (distro) serverUnit;
            bundle = bundle.path;
          }
        ))

        # The ClusterMesh apiserver TLS secrets from clan vars (D60) on
        # the clusterInit node — after the bundle created the apiserver
        # objects. Key material never enters the bundle/Nix store.
        (lib.mkIf (modeActive && isInit) (
          kube.mkClustermeshSecretsApply {
            inherit pkgs instanceName kubeconfigPath;
            namePrefix = name;
            inherit (distro) serverUnit;
            bootstrapUnit = "${name}-${instanceName}-bootstrap-apply.service";
            files = config.clan.core.vars.generators."rancher-clustermesh-${instanceName}".files;
          }
        ))

        # Offline resolution of the bundle's digest-pinned image
        # references (D26/D40 airgap): tag each preloaded image with
        # its name@digest alias on every node. Only when the default
        # preload set is in effect (x86_64; an admin packages.images
        # override owns its own digest resolution).
        (lib.mkIf (modeActive && pkgs.stdenv.hostPlatform.isx86_64 && settings.packages.images == []) (
          kube.mkImageDigestAliases {
            inherit pkgs instanceName;
            runtimeUnit =
              if isServer
              then distro.serverUnit
              else distro.agentUnit;
            images = pinnedImageTriples;
          }
        ))
      ];
    };
  };
in {
  _class = "clan.service";
  manifest = {
    inherit name;
    description = "Thin ${distro.displayName} Kubernetes cluster on lib/kube-cluster";
    categories = ["System"];
    readme = builtins.readFile distro.readme;
    exports = {
      # D58: the transport is consumed through the GENERIC node_transport
      # schemaVersion 2 export only — never provider-specific exports.
      inputs = [
        "node_transport"
        # D71: the CLAT link and the IPv6-only underlay of each member
        "netif"
        "nat_gateway"
        # D71: the WAN of a member that is a router
        "router"
      ];
      out = ["kube_cluster"];
    };
  };

  roles.server = {
    description = "${distro.displayName} server (runs the control plane and, by default, workloads).";
    interface = roleInterface;
    perInstance = perInstanceFn;
  };

  roles.agent = {
    description = "${distro.displayName} agent (worker node).";
    interface = roleInterface;
    perInstance = perInstanceFn;
  };
}
