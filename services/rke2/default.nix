{ self, inputs }:
{
  clanLib,
  lib,
  ...
}:
let
  rancher = import ../../lib/rancher-cluster { inherit lib; };
  certManagerImages = import ../../lib/rancher-cluster/cert-manager-images.nix;
  sealedSecretsImages = import ../../lib/rancher-cluster/sealed-secrets-images.nix;

  defaultInstanceName = "rke2-traefik";

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

  # Shared role interface: both server and agent consume the same cluster/node
  # options plus the distro-specific rke2 escape hatches.
  roleInterface =
    { lib, ... }:
    {
      imports = [
        rancher.interfaces.cluster
        rancher.interfaces.node
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

      config.traefik.instances.${defaultInstanceName}.namespace = lib.mkDefault "kube-system";
    };

  perInstanceFn =
    {
      instanceName,
      settings,
      machine,
      roles,
      exports,
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
    in
    {
      nixosModule =
        { config, pkgs, ... }:
        let
          role = if (roles.server.machines or { }) ? ${machine.name} then "server" else "agent";
          isServer = role == "server";
          machineSettings = allMembers.${machine.name}.settings;

          domain = if settings.domain != null then settings.domain else config.clan.core.settings.domain;

          # --- Per-node kube-apiserver / supervisor load balancer -------
          # EVERY node runs a local haproxy bound to its own transport
          # addresses. The kubeapi FQDN resolves to the node's OWN address
          # via /etc/hosts, so the kubelet bootstrap, Cilium's API
          # endpoint (k8sServiceHost) and every joining server/agent all
          # go through the local LB, which balances across the servers'
          # transport addresses with TLS /readyz healthchecks. The
          # apiserver owns :6443 and the supervisor :9345 on every
          # address, so the LB listens on the derived ports (7442 +
          # cilium.id, +1000 — unique per cluster sharing a transport).
          kubeapiAddr = "kubeapi-${instanceName}.${domain}";
          haproxyKubeapiPort = 7442 + settings.cilium.id;
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

          manifestLabels = rancher.render.mkManifestLabels { inherit instanceName; };

          computedNodeLabels = [
            "cluster=${instanceName}"
            "role=${role}"
            "machine=${machine.name}"
          ]
          ++ lib.mapAttrsToList (k: v: "${k}=${v}") machineSettings.nodeLabels;

          resolvedCidrs = rancher.cidrs settings.cilium.id;

          ciliumValues = rancher.render.mkCiliumValues {
            inherit settings instanceName;
            transportFacts = {
              interface = if transportInterface != null then transportInterface else "eth0";
              mtu = if transportMtu != null then transportMtu else 1500;
            };
            k8sServiceHost = kubeapiAddr;
            k8sServicePort = haproxyKubeapiPort;
          };

          traefikInstances = rancher.render.mkTraefikInstances {
            inherit settings members;
            certManagerEnabled = settings.certManager.enabled;
            getChartSource =
              name:
              if name == defaultInstanceName then
                {
                  kind = "helmChartConfig";
                  chartName = "rke2-traefik";
                }
              else
                {
                  kind = "helmChart";
                  chartName = "traefik-${name}";
                };
          };

          defaultTraefikInstance = lib.findFirst (i: i.name == defaultInstanceName) null traefikInstances;
          extraTraefikInstances = lib.filter (i: i.name != defaultInstanceName) traefikInstances;
          gatewayApiCrdEnabled = lib.any (i: i.gatewayAPI.enabled) traefikInstances;

          corednsValues = rancher.render.mkCoreDNSValues {
            inherit settings;
          };

          corednsManifests = rancher.render.mkCoreDNSManifests {
            inherit settings instanceName manifestLabels;
          };

          certManagerManifests = rancher.render.mkCertManagerManifests {
            inherit settings domain manifestLabels;
          };

          traefikManifests = rancher.render.mkTraefikManifests {
            instances = traefikInstances;
            inherit domain manifestLabels;
          };

          effectiveRke2Package =
            if settings.packages.rke2 != null then
              settings.packages.rke2
            else
              self.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.rke2;

          # The chart flake inputs are unpacked source trees (flake type
          # "tarball"); the rke2 helm-controller fetches <name>.tgz from
          # the supervisor's static content dir, so repack into a real
          # archive. A user-supplied packages.*Chart that already is a
          # file passes through untouched.
          packChart =
            name: src:
            pkgs.runCommand "${name}.tgz" { } ''
              if [ -d ${src} ]; then
                tar czf $out -C ${src} .
              else
                cp ${src} $out
              fi
            '';
          effectiveCertManagerChart = packChart "cert-manager" (
            if settings.packages.certManagerChart != null then
              settings.packages.certManagerChart
            else
              inputs.cert-manager-chart
          );
          effectiveSealedSecretsChart = packChart "sealed-secrets" (
            if settings.packages.sealedSecretsChart != null then
              settings.packages.sealedSecretsChart
            else
              inputs.sealed-secrets-chart
          );
          effectiveTraefikChart = settings.packages.traefikChart;
          rke2CoreImages = effectiveRke2Package."images-core-linux-${imageArchSuffix}-tar-zst";
          traefikCrdChartSource =
            pkgs.runCommand "rke2-traefik-crd-without-gateway-api"
              {
                nativeBuildInputs = [
                  pkgs.gnutar
                  pkgs.zstd
                  pkgs.gzip
                  pkgs.jq
                  pkgs.python3
                ];
              }
              ''
                layer=$(tar --zstd -xOf ${rke2CoreImages} manifest.json | jq -r '.[] | select(.RepoTags[0] | test("rancher/rke2-runtime")) | .Layers[0]')
                tar --zstd -xOf ${rke2CoreImages} "$layer" > runtime.tar.gz
                gzip -dc runtime.tar.gz | tar -xOf - charts/rke2-traefik-crd.yaml > chart.yaml
                python3 - <<'PYEOF'
                import base64
                from pathlib import Path
                payload = next(
                    line.strip().split(" ", 1)[1]
                    for line in Path("chart.yaml").read_text().splitlines()
                    if line.strip().startswith("chartContent:")
                )
                Path("chart.tgz").write_bytes(base64.b64decode(payload))
                PYEOF
                mkdir -p $out
                tar -xzf chart.tgz -C $out
                rm -f $out/rke2-traefik-crd/templates/gateway-standard-install.yaml
              '';
          effectiveTraefikCrdChart = pkgs.runCommand "traefik-crd.tgz" { } ''
            tar czf $out -C ${traefikCrdChartSource} rke2-traefik-crd
          '';
          effectiveGatewayApiCrds =
            if settings.packages.gatewayApiCrds != null then
              settings.packages.gatewayApiCrds
            else
              pkgs.runCommand "gateway-api-crds-v1.6.1.yaml"
                {
                  nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];
                }
                ''
                  python3 - ${inputs.gateway-api-crds}/config/crd/experimental $out <<'PYEOF'
                  import glob
                  import os
                  import sys
                  import yaml

                  src, out = sys.argv[1], sys.argv[2]
                  docs = []
                  for f in sorted(glob.glob(os.path.join(src, "*.yaml"))):
                      for d in yaml.safe_load_all(open(f)):
                          # The upstream experimental dir carries one stray
                          # kustomize `resources:` doc (inside xmeshes.yaml)
                          # with no kind — the rke2 deploy agent would retry
                          # it forever. Only real API objects pass.
                          if d and d.get("kind"):
                              docs.append(d)
                  with open(out, "w") as fh:
                      yaml.safe_dump_all(docs, fh, explicit_start=True, sort_keys=False)
                  PYEOF
                  chmod +w $out
                '';
          effectiveGatewayApiCrdsSource = "${effectiveGatewayApiCrds}";

          imageArchSuffix =
            if pkgs.stdenv.hostPlatform.isx86_64 then
              "amd64"
            else if pkgs.stdenv.hostPlatform.isAarch64 then
              "arm64"
            else
              throw "rke2/${instanceName}: unsupported platform ${pkgs.stdenv.hostPlatform.system}";

          defaultImages = [
            effectiveRke2Package."images-core-linux-${imageArchSuffix}-tar-zst"
            effectiveRke2Package."images-cilium-linux-${imageArchSuffix}-tar-zst"
            effectiveRke2Package."images-traefik-linux-${imageArchSuffix}-tar-zst"
          ]
          ++ lib.optionals settings.certManager.enabled (certManagerImages.mkImages { inherit pkgs; })
          ++ lib.optionals settings.sealedSecrets.enabled (sealedSecretsImages.mkImages { inherit pkgs; });

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

          haproxyConfig = rancher.render.mkHaproxyConfig {
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
            ingress-controller =
              if settings.traefik.enabled && settings.traefik.instances != { } then "traefik" else "none";
            disable-kube-proxy = true;
            node-label = computedNodeLabels;
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
          //
            lib.optionalAttrs
              (
                gatewayApiCrdEnabled
                || (
                  settings.traefik.enabled
                  && settings.traefik.instances != { }
                  && !(settings.traefik.instances ? ${defaultInstanceName})
                )
              )
              {
                disable =
                  (settings.configOverrides.disable or [ ])
                  ++ lib.optional gatewayApiCrdEnabled "rke2-gateway-api-crd"
                  ++ lib.optional gatewayApiCrdEnabled "rke2-traefik-crd"
                  ++ lib.optional (
                    settings.traefik.enabled
                    && settings.traefik.instances != { }
                    && !(settings.traefik.instances ? ${defaultInstanceName})
                  ) "rke2-traefik";
              }
          // settings.configOverrides;

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

          renderedManifests = lib.mkMerge [
            (
              {
                rke2-cilium-config = {
                  enable = isServer;
                  content = {
                    apiVersion = "helm.cattle.io/v1";
                    kind = "HelmChartConfig";
                    metadata = {
                      name = "rke2-cilium";
                      namespace = "kube-system";
                      inherit manifestLabels;
                    };
                    spec.valuesContent = builtins.toJSON (lib.filterAttrsRecursive (_: v: v != null) ciliumValues);
                  };
                };

                cilium-pod-ip-pool = {
                  enable = isServer;
                  content = builtins.head (
                    rancher.render.mkCiliumManifests {
                      inherit settings;
                    }
                  );
                };

                rke2-traefik-config = {
                  enable = isServer && defaultTraefikInstance != null;
                  content =
                    if defaultTraefikInstance != null then
                      {
                        apiVersion = "helm.cattle.io/v1";
                        kind = "HelmChartConfig";
                        metadata = {
                          name = "rke2-traefik";
                          namespace = "kube-system";
                          inherit manifestLabels;
                        };
                        spec.valuesContent = builtins.toJSON (
                          rancher.render.mkTraefikValues { instance = defaultTraefikInstance; }
                        );
                      }
                    else
                      null;
                };

                gateway-api-crds = {
                  enable = isServer && gatewayApiCrdEnabled;
                  source = effectiveGatewayApiCrdsSource;
                };

                rke2-coredns-config = {
                  enable = isServer && (settings.coredns.rewrites != [ ] || settings.coredns.helmValues != { });
                  content = {
                    apiVersion = "helm.cattle.io/v1";
                    kind = "HelmChartConfig";
                    metadata = {
                      name = "rke2-coredns";
                      namespace = "kube-system";
                      inherit manifestLabels;
                    };
                    spec.valuesContent = builtins.toJSON (
                      lib.recursiveUpdate (lib.optionalAttrs (
                        settings.coredns.rewrites != [ ]
                      ) corednsValues) settings.coredns.helmValues
                    );
                  };
                };

                coredns-custom = {
                  enable = isServer && corednsManifests ? coredns-custom;
                  content =
                    if corednsManifests ? coredns-custom then corednsManifests.coredns-custom.content else null;
                };

                cert-manager-bootstrap = {
                  enable = isServer && settings.certManager.enabled;
                  content = certManagerManifests;
                };

                cert-manager-certificates = {
                  enable = isServer && settings.certManager.enabled && settings.certManager.certificates != [ ];
                  content = map (c: {
                    apiVersion = "cert-manager.io/v1";
                    kind = "Certificate";
                    metadata = {
                      name = c.secretName;
                      namespace = "kube-system";
                      inherit manifestLabels;
                    };
                    spec = {
                      inherit (c) secretName dnsNames;
                      issuerRef = {
                        inherit (c.issuer) name;
                        kind = if c.issuer.kind == "cluster-issuer" then "ClusterIssuer" else "Issuer";
                        group = "cert-manager.io";
                      };
                    }
                    // lib.optionalAttrs (c.renewBefore != null) {
                      inherit (c) renewBefore;
                    };
                  }) settings.certManager.certificates;
                };
              }
              // lib.mapAttrs' (
                name: cert:
                lib.nameValuePair "traefik-cert-${name}" {
                  enable = isServer && cert.enable;
                  inherit (cert) content;
                }
              ) traefikManifests.certificates
              // lib.mapAttrs' (
                name: gw:
                lib.nameValuePair "traefik-gateway-${name}" {
                  enable = isServer && gw.enable;
                  inherit (gw) content;
                }
              ) traefikManifests.gateways
              // lib.mapAttrs' (
                name: np:
                lib.nameValuePair "traefik-netpol-${name}" {
                  enable = isServer && np.enable;
                  inherit (np) content;
                }
              ) traefikManifests.networkPolicies
            )
          ];

          renderedAutoDeployCharts = lib.mkIf isServer (
            lib.optionalAttrs settings.certManager.enabled {
              cert-manager = {
                package = effectiveCertManagerChart;
                targetNamespace = "kube-system";
                values = lib.recursiveUpdate {
                  crds.enabled = true;
                  startupapicheck.enabled = false;
                  config = {
                    enableGatewayAPI = true;
                    enableCertificateOwnerRef = true;
                  };
                  global.leaderElection.namespace = "kube-system";
                } settings.certManager.helmValues;
              };
            }
            // lib.optionalAttrs gatewayApiCrdEnabled {
              traefik-crd = {
                package = effectiveTraefikCrdChart;
                targetNamespace = "kube-system";
                values = { };
              };
            }
            // lib.optionalAttrs settings.sealedSecrets.enabled {
              # The pre-generated keypair arrives as the sealed-secrets-key
              # Secret via the manifest sync below — the chart just runs the
              # controller (keyrenewperiod 0: never rotate the vars-owned key).
              sealed-secrets = {
                package = effectiveSealedSecretsChart;
                targetNamespace = "kube-system";
                values = lib.recursiveUpdate {
                  keyrenewperiod = "0";
                  fullnameOverride = "sealed-secrets-controller";
                  networkPolicy.enabled = true;
                  resources = {
                    requests = {
                      cpu = "1m";
                      memory = "2Mi";
                    };
                    limits = {
                      cpu = "500m";
                      memory = "256Mi";
                    };
                  };
                } settings.sealedSecrets.helmValues;
              };
            }
            // lib.listToAttrs (
              map (
                i:
                lib.nameValuePair "traefik-${i.name}" {
                  package =
                    if effectiveTraefikChart != null then
                      effectiveTraefikChart
                    else
                      throw "rke2/${instanceName}: traefik.instances.${i.name} requires packages.traefikChart to be set";
                  targetNamespace = i.namespace;
                  createNamespace = true;
                  values = rancher.render.mkTraefikValues { instance = i; };
                }
              ) extraTraefikInstances
            )
          );
        in
        lib.mkMerge [
          {
            assertions = rancher.assertions.mkClusterAssertions {
              inherit
                instanceName
                roleMembers
                members
                domain
                settings
                ;
              transportFacts = if transportEnabled then allTransportFacts else null;
            };

            clan.core.vars.generators = lib.mkMerge (
              [
                (rancher.vars.mkTokenGenerators { inherit pkgs instanceName; })
                (rancher.vars.mkHaproxyGenerator { inherit pkgs instanceName; })
              ]
              ++ lib.optionals isServer (
                [
                  (rancher.vars.mkPkiGenerator { inherit pkgs instanceName; })
                  (rancher.vars.mkAdminKubeconfigGenerator {
                    inherit pkgs instanceName;
                    server = "https://${kubeapiAddr}:${toString haproxyKubeapiPort}";
                  })
                ]
                ++ lib.optional settings.sealedSecrets.enabled (
                  rancher.vars.mkSealedSecretsGenerator {
                    inherit pkgs instanceName;
                    labels = manifestLabels;
                  }
                )
              )
            );

            services.rke2 = {
              enable = true;
              inherit role;
              serverAddr = if isInit then "" else joinUrl;
              tokenFile = if isServer then serverTokenPath else agentTokenPath;
              agentTokenFile = lib.mkIf isServer agentTokenPath;
              extraFlags = lib.optionals isServer [ "--cni=cilium" ];
              nodeIP = "${nodeIPv4},${nodeIPv6}";
              nodeLabel = computedNodeLabels;
              images = effectiveImages;
              manifests = lib.mkIf isServer renderedManifests;
              autoDeployCharts = renderedAutoDeployCharts;
              cisHardening = settings.profile == "cis";
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
            rancher.nixos.mkPkiSync {
              inherit pkgs;
              pkiGenerator = config.clan.core.vars.generators."rancher-pki-${instanceName}";
              tlsDir = "/var/lib/rancher/rke2/server/tls";
              beforeUnit = "rke2-server.service";
              namePrefix = "rke2-${instanceName}";
            }
          ))

          # --- Sealed Secrets key manifest sync (servers only): the
          # pre-generated signing keypair drops into the auto-deploy
          # manifests dir as a SECRET (never through the Nix store).
          (lib.mkIf (isServer && settings.sealedSecrets.enabled) (
            rancher.nixos.mkSecretManifestSync {
              inherit pkgs;
              namePrefix = "rke2-${instanceName}-sealed-secrets";
              sourcePath =
                config.clan.core.vars.generators."rancher-sealed-secrets-${instanceName}".files."sealed-secrets-key.yaml".path;
              targetPath = "/var/lib/rancher/rke2/server/manifests/sealed-secrets-key.yaml";
              beforeUnit = "rke2-server.service";
            }
          ))
        ];
    };
in
{
  _class = "clan.service";
  manifest = {
    name = "rke2";
    description = "Thin RKE2 Kubernetes cluster on lib/rancher-cluster";
    categories = [ "System" ];
    readme = builtins.readFile ./README.md;
    exports.out = [ ];
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
