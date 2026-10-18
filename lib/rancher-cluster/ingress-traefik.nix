{ lib }:
let
  # Resolve an entrypoint's ports from its protocol.
  resolveEntrypoint = epName: ep: {
    inherit epName;
    inherit (ep)
      protocol
      http3
      tls
      allowedRoutes
      expose
      ;
    containerPort =
      if ep.containerPort != null then
        ep.containerPort
      else if ep.protocol == "HTTP" then
        8000
      else
        8443;
    servicePort =
      if ep.servicePort != null then
        ep.servicePort
      else if ep.protocol == "HTTP" then
        80
      else
        443;
  };

  # Resolve a raw Traefik instance into a shape the renderers consume.
  resolveInstance =
    {
      name,
      inst,
      members,
      certManagerEnabled,
      getChartSource,
    }:
    let
      nodes = if inst.nodes == null then members else inst.nodes;
      entrypoints = lib.mapAttrsToList resolveEntrypoint inst.entryPoints;
      exposedEps = lib.filter (ep: ep.expose) entrypoints;
      hasTerminateListener = lib.any (
        ep:
        ep.tls.mode == "Terminate"
        && (
          ep.protocol == "HTTPS"
          || (ep.protocol == "TCP" && (ep.tls.options != null || ep.tls.certSecretNames != [ ]))
        )
      ) entrypoints;
      defaultCertRendered = inst.gatewayAPI.enabled && hasTerminateListener && certManagerEnabled;
      defaultCertName = "${name}-gateway-tls";
      listenerCerts =
        ep:
        if ep.tls.certSecretNames != [ ] then
          ep.tls.certSecretNames
        else
          lib.optional defaultCertRendered defaultCertName;
      chartSource = getChartSource name;
    in
    {
      inherit
        name
        nodes
        members
        entrypoints
        exposedEps
        hasTerminateListener
        defaultCertRendered
        defaultCertName
        listenerCerts
        chartSource
        ;
      inherit (inst)
        namespace
        workloadKind
        ingressController
        gatewayAPI
        service
        certificate
        replicas
        autoscaling
        helmValues
        ;
    };

  # Helm values for one resolved instance.
  mkInstanceValues =
    i:
    lib.recursiveUpdate (lib.recursiveUpdate
      (
        {
          fullnameOverride = i.name;
          deployment.kind = if i.workloadKind == "daemonset" then "DaemonSet" else "Deployment";
          ports =
            lib.genAttrs (lib.subtractLists (map (ep: ep.epName) i.entrypoints) [
              "web"
              "websecure"
            ]) (_: null)
            // builtins.listToAttrs (
              map (
                ep:
                lib.nameValuePair ep.epName (
                  {
                    port = ep.containerPort;
                    hostPort = null;
                    expose.default = ep.expose;
                    exposedPort = ep.servicePort;
                    protocol = if ep.protocol == "UDP" then "UDP" else "TCP";
                  }
                  // lib.optionalAttrs (ep.protocol == "HTTPS" && ep.http3) {
                    http3.enabled = true;
                  }
                  // lib.optionalAttrs (ep.tls.options != null) {
                    http.tls = {
                      enabled = true;
                      inherit (ep.tls) options;
                    };
                  }
                )
              ) i.entrypoints
            );
          service = {
            enabled = true;
            single = true;
            inherit (i.service) labels annotations;
            spec = {
              inherit (i.service) type ipFamilies;
              ipFamilyPolicy =
                if builtins.length i.service.ipFamilies == 2 then "PreferDualStack" else "SingleStack";
            }
            // lib.optionalAttrs (i.service.loadBalancerClass != null) {
              inherit (i.service) loadBalancerClass;
            };
          };
          ingressClass = {
            inherit (i.ingressController) enabled;
            name = i.ingressController.ingressClass;
          };
          providers = {
            kubernetesCRD = {
              inherit (i.ingressController) enabled;
              allowCrossNamespace = true;
              inherit (i.ingressController) ingressClass;
            };
            kubernetesIngress = {
              enabled = true;
              inherit (i.ingressController) ingressClass;
            };
            kubernetesGateway = {
              inherit (i.gatewayAPI) enabled experimentalChannel;
            };
          };
          gateway.enabled = false;
          gatewayClass.enabled = i.gatewayAPI.enabled;
          log.level = "INFO";
        }
        // lib.optionalAttrs (i.nodes != i.members) {
          affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = [
            {
              matchExpressions = [
                {
                  key = "machine";
                  operator = "In";
                  values = i.nodes;
                }
              ];
            }
          ];
        }
        // lib.optionalAttrs (i.workloadKind == "deployment") {
          deployment.replicas = if i.replicas != null then i.replicas else builtins.length i.nodes;
        }
      )
      (
        lib.optionalAttrs (i.autoscaling != { }) {
          inherit (i) autoscaling;
        }
      )
    ) i.helmValues;
in
{
  mkTraefikInstances =
    {
      settings,
      members,
      certManagerEnabled ? settings.certManager.enabled,
      getChartSource ? (
        _: {
          kind = "helmChart";
          chartName = "traefik";
        }
      ),
    }:
    lib.mapAttrsToList (
      name: inst:
      resolveInstance {
        inherit
          name
          inst
          members
          certManagerEnabled
          getChartSource
          ;
      }
    ) settings.traefik.instances;

  mkTraefikValues =
    {
      instance,
    }:
    mkInstanceValues instance;

  mkTraefikManifests =
    {
      instances,
      domain,
      manifestLabels,
    }:
    let
      gatewayInstances = lib.filter (i: i.gatewayAPI.enabled) instances;
      certConsumedBy = lib.unique (
        lib.concatMap (
          i:
          lib.concatMap (
            ep:
            if (ep.protocol == "HTTPS" || ep.protocol == "TCP") && ep.tls.mode == "Terminate" then
              i.listenerCerts ep
            else
              [ ]
          ) i.entrypoints
        ) gatewayInstances
      );
    in
    {
      gateways = builtins.listToAttrs (
        map (
          i:
          lib.nameValuePair "${i.name}-gateway" {
            enable = i.gatewayAPI.renderResources;
            content = {
              apiVersion = "gateway.networking.k8s.io/v1";
              kind = "Gateway";
              metadata = {
                name = "${i.name}-gateway";
                inherit (i) namespace;
                inherit manifestLabels;
              };
              spec = {
                gatewayClassName = "traefik";
                listeners = lib.concatMap (
                  ep:
                  if ep.protocol == "HTTP" then
                    [
                      {
                        name = ep.epName;
                        port = ep.containerPort;
                        protocol = "HTTP";
                        allowedRoutes.namespaces.from = ep.allowedRoutes.namespaces.from;
                      }
                    ]
                  else if ep.protocol == "HTTPS" then
                    [
                      (
                        {
                          name = ep.epName;
                          port = ep.containerPort;
                          allowedRoutes.namespaces.from = ep.allowedRoutes.namespaces.from;
                        }
                        // (
                          if ep.tls.mode == "Passthrough" then
                            {
                              protocol = "TLS";
                              tls.mode = "Passthrough";
                            }
                          else
                            {
                              protocol = "HTTPS";
                            }
                            // lib.optionalAttrs (i.listenerCerts ep != [ ]) {
                              tls = {
                                mode = "Terminate";
                                certificateRefs = map (n: {
                                  group = "";
                                  kind = "Secret";
                                  name = n;
                                }) (i.listenerCerts ep);
                              };
                            }
                        )
                      )
                    ]
                  else if ep.protocol == "TCP" then
                    [
                      (
                        if ep.tls.mode == "Passthrough" then
                          {
                            name = ep.epName;
                            port = ep.containerPort;
                            protocol = "TLS";
                            tls.mode = "Passthrough";
                            allowedRoutes.namespaces.from = ep.allowedRoutes.namespaces.from;
                          }
                        else if ep.tls.options != null || ep.tls.certSecretNames != [ ] then
                          {
                            name = ep.epName;
                            port = ep.containerPort;
                            protocol = "TLS";
                            allowedRoutes.namespaces.from = ep.allowedRoutes.namespaces.from;
                          }
                          // lib.optionalAttrs (i.listenerCerts ep != [ ]) {
                            tls = {
                              mode = "Terminate";
                              certificateRefs = map (n: {
                                group = "";
                                kind = "Secret";
                                name = n;
                              }) (i.listenerCerts ep);
                            };
                          }
                        else
                          {
                            name = ep.epName;
                            port = ep.containerPort;
                            protocol = "TCP";
                            allowedRoutes.namespaces.from = ep.allowedRoutes.namespaces.from;
                          }
                      )
                    ]
                  else
                    [ ]
                ) i.exposedEps;
              };
            };
          }
        ) gatewayInstances
      );

      certificates = builtins.listToAttrs (
        map (
          i:
          lib.nameValuePair "${i.name}-gateway-tls" {
            enable = i.defaultCertRendered;
            content = {
              apiVersion = "cert-manager.io/v1";
              kind = "Certificate";
              metadata = {
                name = i.defaultCertName;
                inherit (i) namespace;
                inherit manifestLabels;
              };
              spec = {
                secretName = i.defaultCertName;
                dnsNames =
                  if i.certificate.dnsNames != null then
                    i.certificate.dnsNames
                  else
                    [
                      domain
                      "*.${domain}"
                    ];
                issuerRef = {
                  name = "rancher-ca";
                  kind = "ClusterIssuer";
                  group = "cert-manager.io";
                };
              };
            };
          }
        ) gatewayInstances
      );

      networkPolicies = builtins.listToAttrs (
        map (
          i:
          lib.nameValuePair "${i.name}-listeners" {
            enable = true;
            content = {
              apiVersion = "networking.k8s.io/v1";
              kind = "NetworkPolicy";
              metadata = {
                name = "${i.name}-listeners";
                inherit (i) namespace;
                inherit manifestLabels;
              };
              spec = {
                podSelector.matchLabels = {
                  "app.kubernetes.io/name" = "traefik";
                  "app.kubernetes.io/instance" = "${i.name}-${i.namespace}";
                };
                policyTypes = [ "Ingress" ];
                ingress = [
                  {
                    ports =
                      map (ep: {
                        protocol = "TCP";
                        port = ep.containerPort;
                      }) i.entrypoints
                      ++ map (ep: {
                        protocol = "UDP";
                        port = ep.containerPort;
                      }) (lib.filter (ep: ep.protocol == "UDP" || (ep.protocol == "HTTPS" && ep.http3)) i.entrypoints);
                  }
                ];
              };
            };
          }
        ) instances
      );

      inherit certConsumedBy;
    };
}
