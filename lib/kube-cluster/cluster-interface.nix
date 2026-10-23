{ lib, ... }:
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
        description = ''
          Admin override hatch for the canonical Cilium profile (§6.4).
          Merged post-profile and translated into bundle patches
          (cilium-config ConfigMap data / KPR env); keys without a layer-2
          translation throw at eval. Post-merge invariants are validated
          and violations are eval errors.
        '';
      };
    };

    # LB-IPAM pools (D8): cluster-global, generic-named pools rendered into
    # the bootstrap bundle as CiliumLoadBalancerIPPool CRs. Per-machine
    # node-named pools (node-fate-bound) are auto-rendered for every member
    # from its join addresses + poolBlocks — they are NOT declared here.
    pools = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            blocks = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Address inventory: CIDR blocks served by this pool.";
            };
            serviceSelector = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              description = ''
                matchLabels of the pool's serviceSelector — only Services
                carrying these labels (and loadBalancerClass
                io.cilium/lb-ipam) draw from this pool.
              '';
            };
            delivery = lib.mkOption {
              type = lib.types.enum [
                "node-fate-bound"
                "floating"
                "shared-bgp"
                "external-class"
              ];
              description = ''
                How traffic reaches pool addresses + failure semantics
                (D8). node-fate-bound is per-machine scope and is rejected
                for declared (cluster-global) pools. shared-bgp assertions
                against router-role prefixes land with the router role in
                phase 5 — currently shape-only.
              '';
            };
            candidates = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Machine names a floating pool's runtime controller may move
                addresses to. floating ⇒ must cover the full candidate set
                (eval-asserted non-empty and subset of cluster members).
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        Cluster-global CiliumLoadBalancerIPPool definitions (D8). Pools
        serve only Services with loadBalancerClass: io.cilium/lb-ipam;
        classless Services go to Node IPAM (D41).
      '';
    };

    bootstrap = {
      apply = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Apply the kubenix bootstrap bundle on the clusterInit node via a
          systemd oneshot (kubectl apply --server-side
          --field-manager=clan-bootstrap, D40). false removes the unit —
          the day-2 off-ramp once GitOps has adopted the bundle.
        '';
      };
    };

    distroDefaults = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Restore the distro's stock packaged components (D42). false
          (default) = uniform minimal base: the distro service passes the
          flags that disable the packaged Traefik/ingress, metrics-server,
          local-storage, snapshot controller, the helm-controller, and
          other distro add-ons. true (rke2/k3s only) = the service refrains
          from disabling them, so stock components deploy and are
          configured through the distro's own HelmChartConfig surface
          (day-2, never clan-rendered). servicelb/klipper stays disabled in
          BOTH modes — Cilium Node IPAM (D41) replaces it. The bundled
          rke2-cilium chart is ALWAYS disabled — canonical Cilium comes
          from the bootstrap bundle (§6.4).
        '';
      };
    };

    coredns = {
      rewrites = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          CoreDNS rewrite directives — the argument part of a CoreDNS
          rewrite directive, one entry per line. Rendered into the bundle
          as the coredns-custom ConfigMap (kube-system), consumed by the
          distro CoreDNS where it imports /etc/coredns/custom/*.override
          (k3s does; rke2 in the minimal base runs no distro CoreDNS).
        '';
      };
      helmValues = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = ''
          Unsupported: clan never renders chart values for the distro's
          CoreDNS (the HelmChartConfig machinery was removed in phase 3).
          Must stay empty; eval-asserted.
        '';
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
      images = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [ ];
        description = ''
          Airgap image tarballs / packages. Empty = the service default:
          the distro runtime airgap images plus the artifact flake's
          digest-pinned Cilium image tarballs (matching the bundle's
          manifest exactly).
        '';
      };
    };
  };
}
