{ self, inputs }:
{
  clanLib,
  lib,
  ...
}:
let
  kube = import ../../lib/kube-cluster { inherit lib; };

  # Resolve the transport facts for a single member from the configured
  # node_transport source. Returns null when the source has no export for
  # the machine (the assertions below turn that into a hard failure).
  transportFactsFor =
    {
      exports,
      transport,
      machineName,
    }:
    let
      matches = lib.attrValues (
        clanLib.selectExports (
          scope:
          scope.serviceName == transport.service
          && scope.instanceName == transport.instance
          && scope.machineName == machineName
        ) exports
      );
    in
    if matches == [ ] then null else (builtins.head matches).node_transport;

  # Artifact-flake Cilium facts (chart version -> committed manifest path;
  # image set -> airgap tarball packages). Pure: committed source files.
  ciliumVersions = import (inputs.pkgs + "/pkgs/cilium/versions.nix");
  ciliumManifest = inputs.pkgs + "/manifests/cilium/${ciliumVersions.chartVersion}.yaml";

  # Artifact-flake CoreDNS pin (D46): the uniform clan-rendered
  # cluster.local DNS image. Pure: committed source file.
  corednsVersions = import (inputs.pkgs + "/pkgs/coredns/versions.nix");
  coreDNSImageRef = "${corednsVersions.repo}:${corednsVersions.tag}@${corednsVersions.digest}";

  # Shared role interface: both server and agent consume the same cluster/node
  # options plus the distro-specific rke2 escape hatches.
  roleInterface =
    { lib, ... }:
    {
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
          default = { };
          description = ''
            Extra top-level keys merged last into
            `/etc/rancher/rke2/config.yaml`. Use sparingly — most
            customization should go through the typed options above.
          '';
        };
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

      transportEnabled = settings.network.transport != null;
      allTransportFacts = lib.genAttrs members (
        name:
        if transportEnabled then
          transportFactsFor {
            inherit exports;
            transport = settings.network.transport;
            machineName = name;
          }
        else
          null
      );

      # A member's node addresses: the transport export when configured,
      # else the explicit per-machine network.ipv4/ipv6 settings.
      memberAddr =
        name:
        if allTransportFacts.${name} != null then
          {
            inherit (allTransportFacts.${name}) ipv4 ipv6;
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
      meshGroup = if settings.meshGroup != null then settings.meshGroup else domain;

      # --- Phase-5 data plane (D9/D10/D19/D22): BGP v2 resources, the
      # fabric pool, the BIRD fragment, and the private CoreDNS — one
      # resolution seam shared by the bundle, assertions, and the export.
      dp = kube.resolveDataPlane {
        inherit
          instanceName
          settings
          domain
          ;
        ciliumId = resolvedCiliumId;
        inherit (resolvedCidrs) clusterDNS;
        members = poolMembers;
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
            facts = allTransportFacts.${m.machineName};
          in
          {
            name = m.machineName;
            value = {
              inherit (m) role;
              inherit (addr) ipv4 ipv6;
              topology = topologyOf m;
            }
            // lib.optionalAttrs (facts != null) {
              inherit (facts)
                endpoint
                interface
                mtu
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
          schemaVersion = 2;
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
          };
          inherit meshGroup;
          # D43 placeholder: the real controlDomain option lands in
          # phase 6; the export field is structured now.
          controlDomain.role = "standalone";
          transport =
            if transportEnabled then
              {
                inherit (settings.network.transport) service instance;
              }
            else
              {
                service = null;
                instance = null;
              };
          members = memberExportFacts;
          pools = poolExportFacts;
          inherit (dp.exportFacts) bgp fabric;
        };
      };

      nixosModule =
        { config, pkgs, ... }:
        let
          role = if (roles.server.machines or { }) ? ${machine.name} then "server" else "agent";
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
          transportInterface = if ownTransport != null then ownTransport.interface else null;
          transportMtu = if ownTransport != null then ownTransport.mtu else null;

          # haproxy backend list: one entry per server-role member, both
          # families. Servers list THEMSELVES normally and the remote
          # servers as backups (local-first; option allbackups keeps the
          # cluster reachable through the backups when the local apiserver
          # is down); agents list every server plain.
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
          joinUrl = "https://${kubeapiAddr}:${toString haproxySupervisorPort}";

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
              interface = if transportInterface != null then transportInterface else "eth0";
              mtu = if transportMtu != null then transportMtu else 1500;
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

          effectiveRke2Package =
            if settings.packages.rke2 != null then
              settings.packages.rke2
            else
              self.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.rke2;

          imageArchSuffix =
            if pkgs.stdenv.hostPlatform.isx86_64 then
              "amd64"
            else if pkgs.stdenv.hostPlatform.isAarch64 then
              "arm64"
            else
              throw "rke2/${instanceName}: unsupported platform ${pkgs.stdenv.hostPlatform.system}";

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
            effectiveRke2Package."images-core-linux-${imageArchSuffix}-tar-zst"
          ]
          ++ ciliumImages
          ++ coreDNSImages;

          effectiveImages =
            if settings.packages.images != [ ] then settings.packages.images else defaultImages;

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
          disabledAddons = [
            "rke2-cilium"
            "rke2-coredns"
          ]
          ++ lib.optionals (!settings.distroDefaults.enable) [
            "rke2-ingress-nginx"
            "rke2-metrics-server"
            "rke2-snapshot-controller"
            "rke2-snapshot-validation-webhook"
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
          // lib.optionalAttrs (disabledAddons != [ ] || settings.configOverrides ? disable) {
            disable = (settings.configOverrides.disable or [ ]) ++ disabledAddons;
          };

          baseAgentConfig = {
            server = joinUrl;
            token-file = agentTokenPath;
            node-label = computedNodeLabels;
          }
          // lib.optionalAttrs (settings.profile != null && settings.profile != "cis") {
            inherit (settings) profile;
          }
          // settings.configOverrides;

          cleanConfig = lib.filterAttrs (_: v: v != null) (
            if isServer then baseServerConfig else baseAgentConfig
          );
          configPath = pkgs.writeText "rke2-config.yaml" (builtins.toJSON cleanConfig);
        in
        {
          # The vendored BIRD fragment module (D19): path-imported (NixOS
          # dedups), merges with other contributors into ONE bird daemon.
          imports = [ kube.birdModule ];

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
                  transportFacts = if transportEnabled then allTransportFacts else null;
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
                    message = "rke2/${instanceName}: coredns.helmValues is not supported; the HelmChartConfig machinery was removed in phase 3 — the distro's CoreDNS is configured by the operator (distroDefaults) or day-2";
                  }
                ];

              clan.core.vars.generators = lib.mkMerge (
                [
                  (kube.vars.mkTokenGenerators { inherit pkgs instanceName; })
                  (kube.vars.mkHaproxyGenerator { inherit pkgs instanceName; })
                ]
                ++ lib.optionals isServer [
                  (kube.vars.mkPkiGenerator { inherit pkgs instanceName; })
                  (kube.vars.mkAdminKubeconfigGenerator {
                    inherit pkgs instanceName;
                    server = "https://${kubeapiAddr}:${toString haproxyKubeapiPort}";
                  })
                ]
              );

              services.rke2 = {
                enable = true;
                inherit role;
                serverAddr = if isInit then "" else joinUrl;
                tokenFile = if isServer then serverTokenPath else agentTokenPath;
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
              systemd.tmpfiles.rules = [
                "f /var/lib/rancher/rke2/agent/images/.cache.json 0600 root root -"
              ]
              # Admin kubeconfig (clan var) at the documented path.
              ++ lib.optionals isServer [
                "L+ /etc/rancher/rke2/admin-kubeconfig - - - - ${
                  config.clan.core.vars.generators."rancher-admin-kubeconfig-${instanceName}".files."kubeconfig.yaml".path
                }"
              ]
              ++ map (
                img:
                "L+ /var/lib/rancher/rke2/agent/images/${builtins.unsafeDiscardStringContext (builtins.baseNameOf img)} - - - - ${toString img}"
              ) effectiveImages;

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
                    lib.optional (transportInterface != null) ''iifname "${transportInterface}" accept''
                    ++ [ "meta mark and 0x0f00 == 0x0200 accept" ]
                  );
                  trustedInterfaces = [
                    "cilium_host"
                    "cilium_net"
                  ]
                  ++ lib.optional (transportInterface != null) transportInterface;
                  extraInputRules =
                    let
                      interfaceGuard = if transportInterface != null then ''iifname "${transportInterface}" '' else "";
                    in
                    ''
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

              # haproxy binds the transport addresses: with a networkd
              # transport the interface is created and the addresses
              # assigned moments after boot — order the LB after networkd
              # and let Restart=always ride out any bind race (no
              # burst-limit kill).
              systemd.services.haproxy = {
                after = [ "systemd-networkd.service" ];
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

            # The per-node BIRD (D9/D19): loopback BGP link alias, the
            # cluster's fragment in the host's single bird daemon, and the
            # firewall drop for BIRD's unavoidable wildcard listen socket
            # on the upstream-session port (4179 — :179 itself stays bound
            # to the loopback alias only).
            (lib.mkIf dp.bgpActive {
              systemd.services."kube-cluster-${instanceName}-bgp-link" = {
                description = "Assign the node-local loopback BGP link address (D9)";
                wantedBy = [ "multi-user.target" ];
                before = [ "bird.service" ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  ${pkgs.iproute2}/bin/ip addr replace ${kube.bgp.bgpLinkV4}/32 dev lo
                '';
              };
              systemd.services.bird.after = [ "kube-cluster-${instanceName}-bgp-link.service" ];

              clan.bird = {
                routerId = nodeIPv4;
                fragments."kube-cluster-${instanceName}".config = dp.birdFragment;
              };

              networking.firewall.extraInputRules = ''
                tcp dport 4179 drop
              '';
            })
          ];
        };
    };
in
{
  _class = "clan.service";
  manifest = {
    name = "rke2";
    description = "Thin RKE2 Kubernetes cluster on lib/kube-cluster";
    categories = [ "System" ];
    readme = builtins.readFile ./README.md;
    exports = {
      inputs = [ "node_transport" ];
      out = [ "kube_cluster" ];
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
