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

  defaultInstanceName = "k3s-traefik";

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

  roleInterface =
    { lib, ... }:
    {
      imports = [
        rancher.interfaces.cluster
        rancher.interfaces.node
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

          kubeapiAddr = "kubeapi-${instanceName}.${domain}";
          kubeapiPort = 6443;
          haproxyKubeapiPort = 7442 + settings.cilium.id;

          ownAddr = memberAddr machine.name;
          nodeIPv4 = ownAddr.ipv4;
          nodeIPv6 = ownAddr.ipv6;

          ownTransport = allTransportFacts.${machine.name};
          transportInterface = if ownTransport != null then ownTransport.interface else null;
          transportMtu = if ownTransport != null then ownTransport.mtu else null;

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

          mkBootstrapHelmChartSpec = name: {
            chart = "https://127.0.0.1:${toString kubeapiPort}/static/charts/${name}.tgz";
            bootstrap = true;
          };

          manifestLabels = rancher.render.mkManifestLabels { inherit instanceName; };

          computedNodeLabels = [
            "cluster=${instanceName}"
            "role=${role}"
            "machine=${machine.name}"
          ]
          ++ lib.mapAttrsToList (k: v: "${k}=${v}") machineSettings.nodeLabels;

          resolvedCidrs = rancher.cidrs settings.cilium.id;
          podCidrs = lib.splitString "," resolvedCidrs.clusterCidr;

          ciliumValues =
            lib.recursiveUpdate
              {
                global = {
                  clusterCIDRv4 = builtins.elemAt podCidrs 0;
                  clusterCIDRv6 = builtins.elemAt podCidrs 1;
                };
              }
              (
                rancher.render.mkCiliumValues {
                  inherit settings instanceName;
                  transportFacts = {
                    interface = if transportInterface != null then transportInterface else "eth0";
                    mtu = if transportMtu != null then transportMtu else 1500;
                  };
                  k8sServiceHost = kubeapiAddr;
                  k8sServicePort = haproxyKubeapiPort;
                }
              );

          traefikInstances = lib.optionals settings.traefik.enabled (
            rancher.render.mkTraefikInstances {
              inherit settings members;
              certManagerEnabled = settings.certManager.enabled;
              getChartSource = name: {
                kind = "helmChart";
                chartName = if name == defaultInstanceName then name else "traefik-${name}";
              };
            }
          );

          gatewayApiCrdEnabled = lib.any (i: i.gatewayAPI.enabled) traefikInstances;

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

          effectiveK3sPackage =
            if settings.packages.k3s != null then
              settings.packages.k3s
            else
              self.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.k3s;

          ciliumImagePackage = self.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.rke2;

          packChart =
            name: src:
            pkgs.runCommand "${name}.tgz" { } ''
              if [ -d ${src} ]; then
                tar czf $out -C ${src} .
              else
                cp ${src} $out
              fi
            '';

          effectiveCiliumChart = packChart "rke2-cilium" (
            if settings.packages.ciliumChart != null then settings.packages.ciliumChart else inputs.cilium-chart
          );
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
          effectiveTraefikChart = packChart "traefik" (
            if settings.packages.traefikChart != null then
              settings.packages.traefikChart
            else
              inputs.traefik-chart
          );

          traefikCrdChartSource = pkgs.runCommand "traefik-crd-without-gateway-api" { } ''
            mkdir -p $out/traefik-crd
            if [ -d ${inputs.traefik-crd-chart} ]; then
              cp -r ${inputs.traefik-crd-chart}/. $out/traefik-crd/
            else
              tar -xzf ${inputs.traefik-crd-chart} -C $out
            fi
            chmod -R u+w $out
            rm -f $out/traefik-crd/templates/gateway-standard-install.yaml
          '';
          effectiveTraefikCrdChart = pkgs.runCommand "traefik-crd.tgz" { } ''
            tar czf $out -C ${traefikCrdChartSource} traefik-crd
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
              throw "k3s/${instanceName}: unsupported platform ${pkgs.stdenv.hostPlatform.system}";

          defaultImages = [
            effectiveK3sPackage."airgap-images-${imageArchSuffix}-tar-zst"
            ciliumImagePackage."images-cilium-linux-${imageArchSuffix}-tar-zst"
          ]
          ++ lib.optionals settings.certManager.enabled (certManagerImages.mkImages { inherit pkgs; })
          ++ lib.optionals settings.sealedSecrets.enabled (sealedSecretsImages.mkImages { inherit pkgs; });

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

          haproxyConfig = rancher.render.mkHaproxyConfig {
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
          // lib.optionalAttrs isInit {
            cluster-init = true;
          }
          // lib.optionalAttrs (!isInit) {
            server = joinUrl;
          }
          // settings.configOverrides
          // {
            disable = (settings.configOverrides.disable or [ ]) ++ [
              "servicelb"
              "traefik"
            ];
          };

          baseAgentConfig = {
            server = joinUrl;
            token-file = agentTokenPath;
            disable-apiserver-lb = true;
            node-label = computedNodeLabels;
          }
          // settings.configOverrides;

          cleanConfig = lib.filterAttrs (_: v: v != null) (
            if isServer then baseServerConfig else baseAgentConfig
          );
          configPath = pkgs.writeText "k3s-config.yaml" (builtins.toJSON cleanConfig);

          renderedManifests = lib.mkMerge [
            (
              {
                cilium = {
                  enable = isServer;
                  content = {
                    apiVersion = "helm.cattle.io/v1";
                    kind = "HelmChart";
                    metadata = {
                      name = "cilium";
                      namespace = "kube-system";
                      inherit manifestLabels;
                    };
                    spec = (mkBootstrapHelmChartSpec "cilium") // {
                      targetNamespace = "kube-system";
                      valuesContent = builtins.toJSON (lib.filterAttrsRecursive (_: v: v != null) ciliumValues);
                    };
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

                gateway-api-crds = {
                  enable = isServer && gatewayApiCrdEnabled;
                  source = effectiveGatewayApiCrdsSource;
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
            lib.mapAttrs (name: chart: chart // { extraFieldDefinitions.spec = mkBootstrapHelmChartSpec name; })
              (
                lib.optionalAttrs (traefikInstances != [ ]) {
                  traefik-crd = {
                    package = effectiveTraefikCrdChart;
                    targetNamespace = "kube-system";
                    values = { };
                  };
                }
                // lib.optionalAttrs settings.certManager.enabled {
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
                // lib.optionalAttrs settings.sealedSecrets.enabled {
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
                    lib.nameValuePair i.chartSource.chartName {
                      package = effectiveTraefikChart;
                      targetNamespace = i.namespace;
                      createNamespace = true;
                      values = lib.recursiveUpdate {
                        image = {
                          repository = "rancher/mirrored-library-traefik";
                          tag = "3.7.13";
                        };
                        global.checkNewVersion = false;
                      } (rancher.render.mkTraefikValues { instance = i; });
                    }
                  ) traefikInstances
                )
              )
          );
        in
        lib.mkMerge [
          {
            assertions =
              (rancher.assertions.mkClusterAssertions {
                inherit
                  instanceName
                  roleMembers
                  members
                  domain
                  settings
                  ;
                transportFacts = if transportEnabled then allTransportFacts else null;
              })
              ++ [
                {
                  assertion = settings.coredns.helmValues == { };
                  message = "k3s/${instanceName}: coredns.helmValues is not supported; k3s uses its bundled CoreDNS with coredns.rewrites";
                }
              ];

            clan.core.vars.generators = lib.mkMerge (
              [
                (rancher.vars.mkTokenGenerators { inherit pkgs instanceName; })
                (rancher.vars.mkHaproxyGenerator { inherit pkgs instanceName; })
              ]
              ++ lib.optionals isServer (
                [
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
              ++ lib.optional isInit (rancher.vars.mkPkiGenerator { inherit pkgs instanceName; })
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
              manifests = lib.mkIf isServer renderedManifests;
              charts.cilium = lib.mkIf isServer effectiveCiliumChart;
              autoDeployCharts = renderedAutoDeployCharts;
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

          (lib.mkIf (isServer && settings.sealedSecrets.enabled) (
            rancher.nixos.mkSecretManifestSync {
              inherit pkgs;
              namePrefix = "k3s-${instanceName}-sealed-secrets";
              sourcePath =
                config.clan.core.vars.generators."rancher-sealed-secrets-${instanceName}".files."sealed-secrets-key.yaml".path;
              targetPath = "/var/lib/rancher/k3s/server/manifests/sealed-secrets-key.yaml";
              beforeUnit = "k3s.service";
            }
          ))
        ];
    };
in
{
  _class = "clan.service";
  manifest = {
    name = "k3s";
    description = "Thin k3s Kubernetes cluster on lib/rancher-cluster";
    categories = [ "System" ];
    readme = builtins.readFile ./README.md;
    exports.out = [ ];
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
