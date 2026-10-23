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
        description = "Extra Helm values for the Cilium chart.";
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
          local-storage, snapshot controller, and other distro add-ons.
          true (rke2/k3s only) = the service refrains from disabling them,
          so stock components deploy and are configured through the
          distro's own HelmChartConfig surface (day-2, never
          clan-rendered). servicelb/klipper stays disabled in BOTH modes —
          Cilium Node IPAM (D41) replaces it.
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
      images = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [ ];
        description = "Airgap image tarballs / packages.";
      };
    };
  };
}
