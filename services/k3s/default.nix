{ self, inputs }:
{
  clanLib,
  lib,
  ...
}:
let
  kube = import ../../lib/kube-cluster { inherit lib; };

  # Resolve the per-machine export from the configured fabric instance.
  # routed_fabric is the authoritative view (stable host addresses +
  # per-adjacency interfaces/MTU); node_transport of the same instance is
  # a compatibility view. Returns the whole export scope value, or null.
  fabricExportFor =
    {
      exports,
      fabric,
      machineName,
    }:
    let
      matches = lib.attrValues (
        clanLib.selectExports (
          scope:
          scope.serviceName == fabric.service
          && scope.instanceName == fabric.instance
          && scope.machineName == machineName
        ) exports
      );
    in
    if matches == [ ] then null else builtins.head matches;

  # Reduce a machine's fabric export to the kube-cluster consumption shape:
  # addresses + endpoint/port + EVERY adjacency interface + the smallest
  # adjacency MTU (D49/D51). Manual-address clusters return null.
  memberFabric =
    exportValue:
    if exportValue == null then
      null
    else
      let
        rf = exportValue.routed_fabric or null;
        nt = exportValue.node_transport or null;
        view = if rf != null then rf else nt;
        adjacencies = if rf != null then lib.attrValues (rf.adjacencies or { }) else [ ];
        adjacencyIfaces = lib.filter (x: x != "") (map (a: a.interface or a.name or "") adjacencies);
        adjacencyMtus = lib.filter (x: x > 0) (map (a: a.mtu or 0) adjacencies);
        compatIface = view.interface or null;
        interfaces =
          if adjacencyIfaces != [ ] then
            adjacencyIfaces
          else
            lib.optionals (compatIface != null) [ compatIface ];
        mtu = if adjacencyMtus != [ ] then lib.foldl' lib.min 65535 adjacencyMtus else view.mtu or null;
      in
      {
        inherit interfaces mtu;
        ipv4 = view.ipv4 or null;
        ipv6 = view.ipv6 or null;
        endpoint = view.endpoint or null;
        port = view.port or null;
        asn = view.asn or null;
      };

  # Artifact-flake Cilium facts (chart version -> committed manifest path;
  # image set -> airgap tarball packages). Pure: committed source files.
  ciliumVersions = import (inputs.pkgs + "/pkgs/cilium/versions.nix");
  ciliumManifest = inputs.pkgs + "/manifests/cilium/${ciliumVersions.chartVersion}.yaml";

  # Artifact-flake CoreDNS pin (D46): the uniform clan-rendered
  # cluster.local DNS image. Pure: committed source file.
  corednsVersions = import (inputs.pkgs + "/pkgs/coredns/versions.nix");
  coreDNSImageRef = "${corednsVersions.repo}:${corednsVersions.tag}@${corednsVersions.digest}";

  roleInterface =
    { lib, ... }:
    {
      imports = [
        kube.interfaces.cluster
        kube.interfaces.node
      ];

      options.configOverrides = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = ''
          Extra top-level keys merged last into
          `/etc/rancher/k3s/config.yaml`. Use sparingly — most
          customization should go through the typed options above.
        '';
      };
    };

  perInstanceFn =
    {
      instanceName,
      settings,
      machine,
      roles,
      exports,
      mkExports,
      meta,
      ...
    }:
    let
      allMembers = (roles.server.machines or { }) // (roles.agent.machines or { });

      roleMembers =
        (lib.mapAttrsToList (name: m: {
          machineName = name;
          role = "server";
          inherit (m) settings;
        }) (roles.server.machines or { }))
        ++ (lib.mapAttrsToList (name: m: {
          machineName = name;
          role = "agent";
          inherit (m) settings;
        }) (roles.agent.machines or { }));

      members = map (m: m.machineName) roleMembers;
      serverMembers = lib.filter (m: m.role == "server") roleMembers;

      fabricEnabled = settings.network.fabric != null;
      allFabricExports = lib.genAttrs members (
        name:
        if fabricEnabled then
          fabricExportFor {
            inherit exports;
            fabric = settings.network.fabric;
            machineName = name;
          }
        else
          null
      );

      # Per-machine resolved fabric facts (null = manual-address member).
      allFabricFacts = lib.mapAttrs (_: memberFabric) allFabricExports;

      memberAddr =
        name:
        if allFabricFacts.${name} != null then
          {
            inherit (allFabricFacts.${name}) ipv4 ipv6;
          }
        else
          {
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
        }) roleMembers
      );

      # --- Resolved identity (§6.2): hashed-default cilium id, resolved
      # dual-stack CIDRs, mesh group. Single source for distro config,
      # Cilium profile, HAProxy ports, and the kube_cluster export.
      resolvedCiliumId = kube.resolveCiliumId { inherit instanceName settings; };
      resolvedCidrs = kube.render.resolveCidrs {
        inherit settings;
        ciliumId = resolvedCiliumId;
      };

      domain = if settings.domain != null then settings.domain else meta.domain;
      # D54: the mesh group defaults from the fabric instance; explicit
      # meshGroup wins; manual clusters fall back to the domain.
      meshGroup =
        if settings.meshGroup != null then
          settings.meshGroup
        else if fabricEnabled then
          settings.network.fabric.instance
        else
          domain;

      # --- Data plane (D9/D10/D19/D49/D55): the Cilium-side BGP v2
      # resources, the fabric pool, and the private CoreDNS — one
      # resolution seam shared by the bundle, assertions, and the export.
      # The host FRR is owned by routed-fabric (D19); the distro service
      # renders NO routing stack.
      dp = kube.resolveDataPlane {
        inherit
          instanceName
          settings
          domain
          ;
        ciliumId = resolvedCiliumId;
        inherit (resolvedCidrs) clusterDNS;
        members = poolMembers;
        hostAsns = lib.filterAttrs (_: asn: asn != null) (
          lib.mapAttrs (_: facts: if facts == null then null else facts.asn) allFabricFacts
        );
      };

      resolvedPools = kube.render.resolvePools {
        inherit settings;
        members = poolMembers;
        extraPools = lib.optionalAttrs (dp.fabricPool != null) { ${dp.fabricPool.name} = dp.fabricPool; };
      };

      # Effective per-member topology labels (invariant 7: default =
      # instance name, per-machine override wins; empty = eval-asserted).
      topologyOf = m: {
        region = if m.settings.topology.region != null then m.settings.topology.region else instanceName;
        zone = if m.settings.topology.zone != null then m.settings.topology.zone else instanceName;
      };

      # kube_cluster export content (§6.2): identity + mesh endpoints +
      # pool handoff. No secrets; every interface option has a default.
      memberExportFacts = lib.listToAttrs (
        map (
          m:
          let
            addr = memberAddr m.machineName;
            facts = allFabricFacts.${m.machineName};
          in
          {
            name = m.machineName;
            value = {
              inherit (m) role;
              inherit (addr) ipv4 ipv6;
              topology = topologyOf m;
            }
            // lib.optionalAttrs (facts != null) {
              interface = if facts.interfaces != [ ] then builtins.head facts.interfaces else null;
              inherit (facts)
                interfaces
                mtu
                endpoint
                port
                ;
            };
          }
        ) roleMembers
      );

      poolExportFacts = lib.mapAttrs (
        name: p:
        {
          inherit (p) blocks serviceSelector;
          owner = p.owner or null;
        }
        // (
          if dp.effectivePools ? ${name} then
            {
              scope = "cluster-global";
              inherit (dp.effectivePools.${name}) delivery;
            }
          else
            {
              scope = "per-machine";
              delivery = "node-fate-bound";
            }
        )
      ) resolvedPools;
    in
    {
      exports = mkExports {
        kube_cluster = {
          schemaVersion = 3;
          name = instanceName;
          ciliumId = resolvedCiliumId;
          network = {
            inherit (resolvedCidrs)
              podCIDRv4
              podCIDRv6
              serviceCIDRv4
              serviceCIDRv6
              clusterDNS
              ;
            fabric =
              if fabricEnabled then
                {
                  inherit (settings.network.fabric) service instance;
                }
              else
                {
                  service = null;
                  instance = null;
                };
          };
          inherit meshGroup;
          # D54: null = full peering within the fabric instance.
          mesh.peers = settings.meshPeers;
          # D43 placeholder: the real controlDomain option lands in
          # phase 6; the export field is structured now.
          controlDomain.role = "standalone";
          members = memberExportFacts;
          pools = poolExportFacts;
          bgp = dp.exportFacts.bgp // {
            hostAsn =
              if allFabricFacts.${machine.name} != null && allFabricFacts.${machine.name}.asn != null then
                allFabricFacts.${machine.name}.asn
              else
                dp.exportFacts.bgp.hostAsn;
          };
          inherit (dp.exportFacts) fabric;
        };
      };

      nixosModule =
        { config, pkgs, ... }:
        let
          role = if (roles.server.machines or { }) ? ${machine.name} then "server" else "agent";
          isServer = role == "server";
          machineSettings = allMembers.${machine.name}.settings;

          kubeapiAddr = "kubeapi-${instanceName}.${domain}";
          kubeapiPort = 6443;
          haproxyKubeapiPort = 7442 + resolvedCiliumId;

          ownAddr = memberAddr machine.name;
          nodeIPv4 = ownAddr.ipv4;
          nodeIPv6 = ownAddr.ipv6;

          ownFabric = allFabricFacts.${machine.name};
          # Every fabric adjacency interface of this machine (D49/D51) and
          # the smallest adjacency MTU; manual clusters fall back to the
          # single underlay guess eth0/1500 (the old behavior).
          fabricInterfaces = if ownFabric != null then ownFabric.interfaces else [ ];
          fabricMtu = if ownFabric != null then ownFabric.mtu else null;

          haproxyBackends = map (
            m:
            let
              addr = memberAddr m.machineName;
            in
            {
              name = m.machineName;
              inherit (addr) ipv4 ipv6;
              backup = isServer && m.machineName != machine.name;
            }
          ) serverMembers;

          isInit = initMember != null && machine.name == initMember.machineName;
          joinUrl = "https://${kubeapiAddr}:${toString haproxyKubeapiPort}";

          # Invariant 7: topology labels, defaulting to the instance name
          # (empty overrides are eval-asserted in mkClusterAssertions).
          topologyLabels = topologyOf {
            settings = machineSettings;
          };

          computedNodeLabels = [
            "cluster=${instanceName}"
            "role=${role}"
            "machine=${machine.name}"
            "topology.kubernetes.io/region=${topologyLabels.region}"
            "topology.kubernetes.io/zone=${topologyLabels.zone}"
          ]
          ++ lib.mapAttrsToList (k: v: "${k}=${v}") machineSettings.nodeLabels;

          # The canonical Cilium profile (§6.4) with the admin's
          # cilium.helmValues folded in — translated into bundle patches by
          # profilePatches (never re-run through helm, D26).
          ciliumProfile = kube.render.mkCiliumValues {
            inherit settings instanceName;
            transportFacts = {
              interfaces = if fabricInterfaces != [ ] then fabricInterfaces else [ "eth0" ];
              mtu = if fabricMtu != null then fabricMtu else 1500;
            };
            k8sServiceHost = kubeapiAddr;
            k8sServicePort = haproxyKubeapiPort;
          };

          manifestLabels = kube.render.mkManifestLabels { inherit instanceName; };

          # The kubenix bootstrap bundle (D26 layer 2, D40). Evaluated only
          # for the clusterInit node when bootstrap.apply is on.
          bundle = kube.render.mkBundle {
            inherit
              pkgs
              settings
              instanceName
              manifestLabels
              ;
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
            inherit (dp) privateCoreDNS;
          };

          effectiveK3sPackage =
            if settings.packages.k3s != null then
              settings.packages.k3s
            else
              self.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.k3s;

          imageArchSuffix =
            if pkgs.stdenv.hostPlatform.isx86_64 then
              "amd64"
            else if pkgs.stdenv.hostPlatform.isAarch64 then
              "arm64"
            else
              throw "k3s/${instanceName}: unsupported platform ${pkgs.stdenv.hostPlatform.system}";

          # The artifact flake's digest-pinned Cilium image tarballs match
          # the bundle's manifest exactly (D26/D40 airgap). The pins come
          # from the pkgs flake's committed versions.nix; the pullImage
          # FODs are content-addressed by the same hashes, so they are
          # byte-identical to pkgs' image-cilium-* / cilium-airgap-images
          # tarballs. amd64 only (the pkgs airgap set is x86_64-linux);
          # other systems fall back to registry pulls.
          ciliumImages = lib.optionals pkgs.stdenv.hostPlatform.isx86_64 (
            map (
              img:
              pkgs.dockerTools.pullImage {
                inherit (img) sha256;
                imageName = img.repo;
                imageDigest = img.digest;
                finalImageName = img.repo;
                finalImageTag = img.tag;
                os = "linux";
                arch = "amd64";
              }
            ) ciliumVersions.images
          );

          # The clan CoreDNS image (D46), digest-pinned like the Cilium set
          # (same content-addressed FOD as the pkgs flake's image-coredns).
          coreDNSImages = lib.optional pkgs.stdenv.hostPlatform.isx86_64 (
            pkgs.dockerTools.pullImage {
              inherit (corednsVersions) sha256;
              imageName = corednsVersions.repo;
              imageDigest = corednsVersions.digest;
              finalImageName = corednsVersions.repo;
              finalImageTag = corednsVersions.tag;
              os = "linux";
              arch = "amd64";
            }
          );

          defaultImages = [
            effectiveK3sPackage."airgap-images-${imageArchSuffix}-tar-zst"
          ]
          ++ ciliumImages
          ++ coreDNSImages;

          # The pinned repo/tag/digest triples behind the preloaded
          # tarballs — the bundle references images digest-pinned
          # (repo:tag@digest), which containerd only resolves via a
          # name@digest alias (mkImageDigestAliases).
          pinnedImageTriples = map (img: { inherit (img) repo tag digest; }) ciliumVersions.images ++ [
            { inherit (corednsVersions) repo tag digest; }
          ];

          effectiveImages =
            if settings.packages.images != [ ] then settings.packages.images else defaultImages;

          serverTokenPath =
            config.clan.core.vars.generators."rancher-server-token-${instanceName}".files.server-token.path;
          agentTokenPath =
            config.clan.core.vars.generators."rancher-agent-token-${instanceName}".files.agent-token.path;

          haproxyHealthcheckFiles = config.clan.core.vars.generators."rancher-haproxy-${instanceName}".files;
          haproxyStatsPasswordHash = lib.trim (
            clanLib.getPublicValue {
              generator = "rancher-haproxy-${instanceName}";
              file = "password-hash-haproxy";
              flake = config.clan.core.settings.directory;
              default = throw "k3s/${instanceName}: no haproxy stats password hash; run 'clan vars generate' (generator rancher-haproxy-${instanceName})";
            }
          );

          haproxyConfig = kube.render.mkHaproxyConfig {
            inherit
              instanceName
              kubeapiPort
              nodeIPv4
              nodeIPv6
              ;
            lbKubeapiPort = haproxyKubeapiPort;
            enableSupervisor = false;
            backends = haproxyBackends;
            caCrtPath = haproxyHealthcheckFiles."kubeapi-ca.crt".path;
            clientPemPath = haproxyHealthcheckFiles."kubeapi-client.pem".path;
            statsPasswordHash = haproxyStatsPasswordHash;
            healthCheckSni = kubeapiAddr;
          };

          # distroDefaults (D42): servicelb/klipper is disabled in BOTH
          # modes — Cilium Node IPAM (D41) replaces it. In the minimal base
          # (the default) the distro's packaged add-ons AND the embedded
          # helm-controller are disabled: the kubenix bootstrap bundle
          # (D40) replaced helm-controller delivery in phase 3. The distro
          # CoreDNS is disabled too (D46): the bundle renders the uniform
          # clan CoreDNS for cluster.local instead.
          # distroDefaults.enable = true refrains so stock components
          # (including the distro CoreDNS) deploy via the distro's own
          # helm-controller (day-2 concern) — and the bundle skips its
          # cluster.local CoreDNS (mode-exclusive).
          disabledAddons = [
            "servicelb"
          ]
          ++ lib.optionals (!settings.distroDefaults.enable) [
            "coredns"
            "traefik"
            "local-storage"
            "metrics-server"
          ];

          baseServerConfig = {
            token-file = serverTokenPath;
            agent-token-file = agentTokenPath;
            tls-san = [
              kubeapiAddr
            ]
            ++ lib.unique (
              lib.concatMap (
                m:
                let
                  addr = memberAddr m.machineName;
                in
                [
                  addr.ipv4
                  addr.ipv6
                ]
              ) roleMembers
            );
            cluster-cidr = resolvedCidrs.clusterCidr;
            service-cidr = resolvedCidrs.serviceCidr;
            https-listen-port = kubeapiPort;
            disable-apiserver-lb = true;
            flannel-backend = "none";
            disable-kube-proxy = true;
            disable-network-policy = true;
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
          // settings.configOverrides
          // {
            disable = (settings.configOverrides.disable or [ ]) ++ disabledAddons;
          };

          baseAgentConfig = {
            server = joinUrl;
            token-file = agentTokenPath;
            disable-apiserver-lb = true;
            node-label = computedNodeLabels;
          }
          // settings.configOverrides;

          cleanConfig = lib.filterAttrs (_: v: v != null) (
            {
              resolv-conf =
                if config.services.resolved.enable then "/run/systemd/resolve/resolv.conf" else "/etc/resolv.conf";
            }
            // (if isServer then baseServerConfig else baseAgentConfig)
          );
          configPath = pkgs.writeText "k3s-config.yaml" (builtins.toJSON cleanConfig);
        in
        {
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
            default = { };
          };

          config = lib.mkMerge [
            {
              clan.kubeClusters.${instanceName} = {
                renderedDistroConfig = cleanConfig;
                bundleJson = lib.mkIf (isInit && settings.bootstrap.apply) bundle.json;
              };

              assertions =
                (kube.assertions.mkClusterAssertions {
                  inherit
                    instanceName
                    roleMembers
                    settings
                    ;
                  transportFacts = if fabricEnabled then allFabricFacts else null;
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
                      }) (r.machines or { })
                    ) roles
                  );
                })
                ++ (kube.assertions.mkPoolAssertions {
                  inherit instanceName settings;
                  members = poolMembers;
                  ciliumId = resolvedCiliumId;
                  reservedCidrs = [
                    resolvedCidrs.podCIDRv4
                    resolvedCidrs.podCIDRv6
                    resolvedCidrs.serviceCIDRv4
                    resolvedCidrs.serviceCIDRv6
                  ];
                })
                ++ [
                  {
                    assertion = settings.coredns.helmValues == { };
                    message = "k3s/${instanceName}: coredns.helmValues is not supported; k3s uses its bundled CoreDNS with coredns.rewrites";
                  }
                ];

              clan.core.vars.generators = lib.mkMerge (
                [
                  (kube.vars.mkTokenGenerators { inherit pkgs instanceName; })
                  (kube.vars.mkHaproxyGenerator { inherit pkgs instanceName; })
                ]
                ++ lib.optionals isServer [
                  (kube.vars.mkAdminKubeconfigGenerator {
                    inherit pkgs instanceName;
                    server = "https://${kubeapiAddr}:${toString haproxyKubeapiPort}";
                  })
                ]
                ++ lib.optional isInit (kube.vars.mkPkiGenerator { inherit pkgs instanceName; })
              );

              services.k3s = {
                enable = true;
                package = effectiveK3sPackage;
                inherit role;
                clusterInit = isInit;
                serverAddr = if isInit then "" else joinUrl;
                tokenFile = if isServer then serverTokenPath else agentTokenPath;
                agentTokenFile = lib.mkIf isServer agentTokenPath;
                nodeIP = "${nodeIPv4},${nodeIPv6}";
                nodeLabel = computedNodeLabels;
                images = effectiveImages;
                # NO services.k3s.manifests / services.k3s.charts: clan
                # manifests are delivered by the bootstrap bundle only (D40;
                # §6.12 eval-rejects the distro manifests dir for clan
                # manifests — structurally enforced by never writing there).
              };

              environment.etc."rancher/k3s/config.yaml".source = configPath;

              systemd.tmpfiles.rules = lib.optionals isServer [
                "L+ /etc/rancher/k3s/admin-kubeconfig - - - - ${
                  config.clan.core.vars.generators."rancher-admin-kubeconfig-${instanceName}".files."kubeconfig.yaml".path
                }"
              ];

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
                    map (iface: ''iifname "${iface}" accept'') fabricInterfaces
                    ++ [ "meta mark and 0x0f00 == 0x0200 accept" ]
                  );
                  trustedInterfaces = [
                    "cilium_host"
                    "cilium_net"
                  ]
                  ++ fabricInterfaces;
                  extraInputRules =
                    let
                      interfaceGuard =
                        if fabricInterfaces != [ ] then
                          "iifname { ${lib.concatStringsSep ", " (map (i: ''"${i}"'') fabricInterfaces)} } "
                        else
                          "";
                    in
                    ''
                      iifname { "cilium*", "lxc*" } accept
                      ${interfaceGuard}tcp dport { ${toString kubeapiPort}, ${toString haproxyKubeapiPort}, 10250, 2379, 2380, 2381 } accept
                    '';
                  extraForwardRules = ''
                    iifname { "cilium*", "lxc*" } accept
                    oifname { "cilium*", "lxc*" } accept
                  '';
                };
                extraHosts = ''
                  ${nodeIPv4} ${kubeapiAddr}
                  ${nodeIPv6} ${kubeapiAddr}
                '';
              };

              services.haproxy = {
                enable = true;
                config = haproxyConfig;
              };

              systemd.services.haproxy = {
                after = [ "systemd-networkd.service" ];
                unitConfig.StartLimitIntervalSec = 0;
              };
            }

            (lib.mkIf isInit {
              systemd.services."k3s-${instanceName}-pki-seed" = {
                description = "Seed the initial k3s custom CA certificates";
                wantedBy = [ "multi-user.target" ];
                before = [ "k3s.service" ];
                requiredBy = [ "k3s.service" ];
                unitConfig.ConditionPathExists =
                  config.clan.core.vars.generators."rancher-pki-${instanceName}".files."server-ca.key".path;
                serviceConfig = {
                  Type = "oneshot";
                  User = "root";
                  ExecStart = pkgs.writeShellScript "k3s-${instanceName}-pki-seed" ''
                    set -euo pipefail
                    TLS_DIR=/var/lib/rancher/k3s/server/tls
                    if [ -e "$TLS_DIR/service.current.key" ] || [ -e "$TLS_DIR/server-ca.nochain.crt" ]; then
                      exit 0
                    fi
                    mkdir -p "$TLS_DIR/etcd"
                    chmod 700 "$TLS_DIR" "$TLS_DIR/etcd"
                    ${pkgs.coreutils}/bin/install -Dm644 ${
                      config.clan.core.vars.generators."rancher-pki-${instanceName}".files."server-ca.crt".path
                    } "$TLS_DIR/server-ca.crt"
                    ${pkgs.coreutils}/bin/install -Dm600 ${
                      config.clan.core.vars.generators."rancher-pki-${instanceName}".files."server-ca.key".path
                    } "$TLS_DIR/server-ca.key"
                    ${pkgs.coreutils}/bin/install -Dm644 ${
                      config.clan.core.vars.generators."rancher-pki-${instanceName}".files."client-ca.crt".path
                    } "$TLS_DIR/client-ca.crt"
                    ${pkgs.coreutils}/bin/install -Dm600 ${
                      config.clan.core.vars.generators."rancher-pki-${instanceName}".files."client-ca.key".path
                    } "$TLS_DIR/client-ca.key"
                    ${pkgs.coreutils}/bin/install -Dm644 ${
                      config.clan.core.vars.generators."rancher-pki-${instanceName}".files."request-header-ca.crt".path
                    } "$TLS_DIR/request-header-ca.crt"
                    ${pkgs.coreutils}/bin/install -Dm600 ${
                      config.clan.core.vars.generators."rancher-pki-${instanceName}".files."request-header-ca.key".path
                    } "$TLS_DIR/request-header-ca.key"
                    ${pkgs.coreutils}/bin/install -Dm644 ${
                      config.clan.core.vars.generators."rancher-pki-${instanceName}".files."etcd-peer-ca.crt".path
                    } "$TLS_DIR/etcd/peer-ca.crt"
                    ${pkgs.coreutils}/bin/install -Dm600 ${
                      config.clan.core.vars.generators."rancher-pki-${instanceName}".files."etcd-peer-ca.key".path
                    } "$TLS_DIR/etcd/peer-ca.key"
                    ${pkgs.coreutils}/bin/install -Dm644 ${
                      config.clan.core.vars.generators."rancher-pki-${instanceName}".files."etcd-server-ca.crt".path
                    } "$TLS_DIR/etcd/server-ca.crt"
                    ${pkgs.coreutils}/bin/install -Dm600 ${
                      config.clan.core.vars.generators."rancher-pki-${instanceName}".files."etcd-server-ca.key".path
                    } "$TLS_DIR/etcd/server-ca.key"
                    ${pkgs.coreutils}/bin/install -Dm600 ${
                      config.clan.core.vars.generators."rancher-pki-${instanceName}".files."service.key".path
                    } "$TLS_DIR/service.key"
                  '';
                };
              };
            })

            # The bootstrap bundle + apply oneshot on the clusterInit node
            # only (D40). bootstrap.apply = false is the day-2 off-ramp.
            (lib.mkIf (isInit && settings.bootstrap.apply) (
              kube.mkBootstrapApply {
                inherit pkgs instanceName;
                namePrefix = "k3s";
                serverUnit = "k3s.service";
                kubeconfigPath = "/etc/rancher/k3s/k3s.yaml";
                bundle = bundle.path;
              }
            ))

            # Offline resolution of the bundle's digest-pinned image
            # references (D26/D40 airgap): tag each preloaded image with
            # its name@digest alias on every node. Only when the default
            # preload set is in effect (x86_64; an admin packages.images
            # override owns its own digest resolution).
            (lib.mkIf (pkgs.stdenv.hostPlatform.isx86_64 && settings.packages.images == [ ]) (
              kube.mkImageDigestAliases {
                inherit pkgs instanceName;
                runtimeUnit = "k3s.service";
                images = pinnedImageTriples;
              }
            ))
          ];
        };
    };
in
{
  _class = "clan.service";
  manifest = {
    name = "k3s";
    description = "Thin k3s Kubernetes cluster on lib/kube-cluster";
    categories = [ "System" ];
    readme = builtins.readFile ./README.md;
    exports = {
      # The fabric reference resolves the routed_fabric export
      # (authoritative) with node_transport as the compatibility view.
      inputs = [
        "routed_fabric"
        "node_transport"
      ];
      out = [ "kube_cluster" ];
    };
  };

  roles.server = {
    description = "k3s server (runs the control plane and, by default, workloads).";
    interface = roleInterface;
    perInstance = perInstanceFn;
  };

  roles.agent = {
    description = "k3s agent (worker node).";
    interface = roleInterface;
    perInstance = perInstanceFn;
  };
}
