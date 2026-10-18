{ lib, ... }:
let
  traefikEntrypointInterface = { lib, ... }: {
    options = {
      protocol = lib.mkOption {
        type = lib.types.enum [
          "HTTP"
          "HTTPS"
          "TCP"
          "UDP"
        ];
        default = "HTTP";
        description = ''
          Entrypoint protocol. HTTP/HTTPS render HTTP(S) routers; TCP
          serves IngressRouteTCP and Gateway TCP/TLS listeners; UDP
          serves IngressRouteUDP.
        '';
      };
      containerPort = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = ''
          The pod-side port Traefik binds. null = 8000 for HTTP, 8443
          otherwise. Must be unique per instance.
        '';
      };
      servicePort = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = ''
          The exposed Service port. null = 80 for HTTP, 443 otherwise.
          Must be unique per instance.
        '';
      };
      http3 = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          HTTP/3 (QUIC) on this entrypoint — HTTPS only.
        '';
      };
      tls = {
        mode = lib.mkOption {
          type = lib.types.enum [
            "Terminate"
            "Passthrough"
          ];
          default = "Terminate";
          description = ''
            TLS mode for TLS-capable entrypoints (HTTPS/TCP).
          '';
        };
        options = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            A TLSOption reference BY NAME in the cross-provider form
            ("<namespace>-<name>@kubernetescrd").
          '';
        };
        certSecretNames = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            The TLS Secrets backing this entrypoint's Gateway listener
            (certificateRefs). Empty = the instance's cert-manager
            DEFAULT certificate when rendered.
          '';
        };
      };
      allowedRoutes.namespaces.from = lib.mkOption {
        type = lib.types.enum [
          "All"
          "Same"
        ];
        default = "All";
        description = "Gateway listener route scoping.";
      };
      expose = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          false = container-only port (metrics, dashboard): rendered
          into the pod but NOT into the Service.
        '';
      };
    };
  };

  traefikInstanceInterface = { name, lib, ... }: {
    options = {
      namespace = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "The instance's namespace (created by the HelmChart).";
      };
      workloadKind = lib.mkOption {
        type = lib.types.enum [
          "daemonset"
          "deployment"
        ];
        default = "daemonset";
        description = ''
          daemonset: one pod per covered node with externalTrafficPolicy = Local.
          deployment: replicas + pod anti-affinity with ETP Cluster.
        '';
      };
      nodes = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          The cluster members this instance covers. null = every cluster member.
        '';
      };
      ingressController = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            The Traefik CRD provider + Kubernetes Ingress provider,
            scoped to the instance's ingressClass.
          '';
        };
        ingressClass = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = ''
            The instance's IngressClass name — the per-instance route
            isolation mechanism.
          '';
        };
      };
      gatewayAPI = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Traefik's kubernetesGateway provider + the service-rendered
            Gateway. AT MOST ONE instance per cluster may enable it.
          '';
        };
        renderResources = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Render the service-managed Gateway as a manifest.
          '';
        };
        experimentalChannel = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            providers.kubernetesGateway.experimentalChannel — TCPRoute
            + TLSRoute support.
          '';
        };
      };
      service = {
        type = lib.mkOption {
          type = lib.types.enum [
            "LoadBalancer"
            "ClusterIP"
          ];
          default = "LoadBalancer";
          description = "The Service type (ClusterIP = internal-only instance).";
        };
        loadBalancerClass = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            The Service's loadBalancerClass. null lets the distro or an
            external LB service wire the Service.
          '';
        };
        ipFamilies = lib.mkOption {
          type = lib.types.listOf (
            lib.types.enum [
              "IPv4"
              "IPv6"
            ]
          );
          default = [
            "IPv4"
            "IPv6"
          ];
          description = "The Service's ipFamilies.";
        };
        annotations = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "Extra Service annotations.";
        };
        labels = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "Extra Service labels.";
        };
      };
      entryPoints = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule traefikEntrypointInterface);
        default = {
          web = { };
          websecure = {
            protocol = "HTTPS";
          };
        };
        description = ''
          The instance's entrypoints (default: web 80/8000 HTTP +
          websecure 443/8443 HTTPS).
        '';
      };
      certificate = {
        dnsNames = lib.mkOption {
          type = lib.types.nullOr (lib.types.listOf lib.types.str);
          default = null;
          description = ''
            The instance's cert-manager DEFAULT certificate's dnsNames
            (null = the cluster domain + its wildcard).
          '';
        };
      };
      replicas = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = ''
          Deployment replica count (workloadKind = deployment only).
        '';
      };
      autoscaling = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = ''
          Chart autoscaling values (HPA), workloadKind = deployment only.
        '';
      };
      helmValues = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra Helm values for this instance's chart.";
      };
    };
  };

  certManagerCertificateInterface = { lib, ... }: {
    options = {
      secretName = lib.mkOption {
        type = lib.types.str;
        description = "The kubernetes.io/tls Secret the Certificate writes.";
      };
      dnsNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "The Certificate's dnsNames.";
      };
      renewBefore = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional renewBefore (e.g. \"720h\").";
      };
      issuer = {
        kind = lib.mkOption {
          type = lib.types.enum [
            "cluster-issuer"
            "issuer"
          ];
          description = ''
            The backer: ANY cert-manager issuer named issuer.name
            ("cluster-issuer" = ClusterIssuer, "issuer" = namespaced Issuer).
          '';
        };
        name = lib.mkOption {
          type = lib.types.str;
          description = "The issuer resource name.";
        };
      };
    };
  };
in
{
  options = {
    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Domain name for the cluster. null lets the distro service fall
        back to clan meta.domain.
      '';
    };

    network = {
      transport = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              service = lib.mkOption {
                type = lib.types.str;
                description = ''
                  Name of the clanService that exports the node_transport
                  interface (e.g. "wireguard-mesh").
                '';
              };
              instance = lib.mkOption {
                type = lib.types.str;
                description = "Name of the service instance to consume.";
              };
            };
          }
        );
        default = null;
        description = ''
          Selects the node_transport export source. null requires explicit
          per-node network.ipv4/ipv6 addresses.
        '';
      };
      podCIDRv4 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          IPv4 pod CIDR. null derives from cilium.id:
          10.<2id-1>.0.0/16.
        '';
      };
      podCIDRv6 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          IPv6 pod CIDR. null derives from cilium.id:
          fd10:<2id-1>::/56.
        '';
      };
      serviceCIDRv4 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          IPv4 service CIDR. null derives from cilium.id:
          10.<2id>.0.0/16.
        '';
      };
      serviceCIDRv6 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          IPv6 service CIDR. null derives from cilium.id:
          fd10:<2id>::/112.
        '';
      };
    };

    cilium = {
      id = lib.mkOption {
        type = lib.types.ints.between 1 255;
        default = 1;
        description = ''
          Cilium cluster id (1-255, unique per cluster). Drives the
          pod/service CIDR derivation.
        '';
      };
      helmValues = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra Helm values for the Cilium chart.";
      };
    };

    traefik = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Deploy Traefik ingress controllers. instances = {} means zero
          Traefik.
        '';
      };
      instances = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule traefikInstanceInterface);
        default = { };
        description = ''
          The Traefik instances. The distro service supplies the default
          instance key and addressing defaults.
        '';
      };
    };

    certManager = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Deploy cert-manager and render the self-signed CA bootstrap.
        '';
      };
      helmValues = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra Helm values for the cert-manager chart.";
      };
      certificates = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule certManagerCertificateInterface);
        default = [ ];
        description = ''
          Backer-agnostic certificate layer. Every entry renders one
          Certificate CR. Providing entries switches OFF the per-instance
          default certificates.
        '';
      };
    };

    coredns = {
      rewrites = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          CoreDNS rewrite directives — the argument part of a CoreDNS
          rewrite directive, one entry per line.
        '';
      };
      helmValues = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra Helm values for the coredns chart.";
      };
    };

    sealedSecrets = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Deploy the Sealed Secrets controller with a pre-generated
          signing keypair from clan vars (rancher-sealed-secrets-<instance>
          — the public tls.crt is the offline sealing key, the private key
          syncs into the cluster as the sealed-secrets-key Secret).
        '';
      };
      helmValues = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra Helm values for the sealed-secrets chart.";
      };
    };

    packages = {
      rke2 = lib.mkOption {
        type = lib.types.nullOr lib.types.anything;
        default = null;
        description = "The RKE2 distribution package. null lets the rke2 service pick nixpkgs.rke2.";
      };
      k3s = lib.mkOption {
        type = lib.types.nullOr lib.types.anything;
        default = null;
        description = "The k3s distribution package. null lets the k3s service pick nixpkgs.k3s.";
      };
      ciliumChart = lib.mkOption {
        type = lib.types.nullOr lib.types.anything;
        default = null;
        description = "The Cilium chart package (distro-specific name).";
      };
      traefikChart = lib.mkOption {
        type = lib.types.nullOr lib.types.anything;
        default = null;
        description = "The Traefik chart package.";
      };
      certManagerChart = lib.mkOption {
        type = lib.types.nullOr lib.types.anything;
        default = null;
        description = "The cert-manager chart package.";
      };
      sealedSecretsChart = lib.mkOption {
        type = lib.types.nullOr lib.types.anything;
        default = null;
        description = "The sealed-secrets chart package.";
      };
      gatewayApiCrds = lib.mkOption {
        type = lib.types.nullOr lib.types.anything;
        default = null;
        description = "The Gateway API CRDs manifest package.";
      };
      images = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [ ];
        description = "Airgap image tarballs / packages.";
      };
    };
  };
}
