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
        type = lib.types.nullOr (lib.types.ints.between 1 255);
        default = null;
        description = ''
          Cilium cluster id (1-255, unique per cluster, eval-asserted).
          null (default) resolves to a stable hash of the instance name
          mapped into 1-127. An explicit id above 127 requires explicit
          network.podCIDRv4 + network.serviceCIDRv4 (the derived
          10.<2id-1>/10.<2id> space overflows the /8 past 127).
          Drives the pod/service CIDR derivation, clusterDNS, and the
          HAProxy ports (7442+id, +1000).

          Migration: deployments predating the hashed default must pin
          their current id (and v4 CIDRs when > 127) before upgrading.
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
                carrying these labels (and a Cilium-handled
                loadBalancerClass: io.cilium/lb-ipam for non-BGP draws,
                io.cilium/bgp-control-plane for shared-bgp draws) draw
                from this pool.
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
                for declared (cluster-global) pools. shared-bgp requires the
                BGP plane (bgp.enable — locked together, eval-asserted) and
                Services drawing from it must pin
                loadBalancerClass: io.cilium/bgp-control-plane (Cilium
                announces only that class or unset). shared-bgp blocks must
                stay inside router-role prefixes when a fleet-routing router
                exists in the same inventory (fleet-wide check, phase 5+).
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

    # BGP v2 control plane (D9). `enable` is locked to the presence of
    # shared-bgp pools (invariant 6, eval-asserted): BGP exists only to
    # deliver shared-bgp VIPs, and shared-bgp pools cannot work without it.
    # With the default fabric (D10, fabric.enable = true) a shared-bgp pool
    # always exists, so the default here is consistent.
    bgp = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Render the BGP v2 resources (CiliumBGPClusterConfig per node,
          CiliumBGPPeerConfig, CiliumBGPAdvertisement) and the per-node
          BIRD fragment. Must equal "any shared-bgp pool exists" (including
          the default fabric pool) — both directions are eval-asserted
          (§6.12).
        '';
      };
      advertisePodCIDRs = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          D13 opt-in: advertise the cluster's pod CIDRs (CiliumPodIPPool
          advertisement) to BGP peers. Default off — hosts reach Services
          via VIPs, never pods directly.
        '';
      };
      advertiseClusterIPs = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          D13 opt-in: advertise Service ClusterIPs to BGP peers. Default
          off.
        '';
      };
      upstreamPeers = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              address = lib.mkOption {
                type = lib.types.str;
                description = "Upstream BGP peer address (v4 or v6).";
              };
              asn = lib.mkOption {
                type = lib.types.ints.between 1 4294967295;
                description = "Upstream peer ASN.";
              };
            };
          }
        );
        default = [ ];
        description = ''
          Upstream BGP peers the per-node BIRD dials out to (active,
          family-split sessions; D9). With none configured, BIRD still runs
          locally, terminating the Cilium sessions (the private fabric
          works within the mesh; upstream reachability simply has no
          carrier yet — D10).
        '';
      };
      ciliumASN = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 1 4294967295);
        default = null;
        description = ''
          The Cilium-side BGP ASN. null derives a deterministic private
          32-bit ASN from the instance name (D9). Pin only to escape a
          fleet-wide ASN collision (fleet-asserted).
        '';
      };
      birdASN = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 1 4294967295);
        default = null;
        description = ''
          The BIRD-side BGP ASN (the cluster's ASN as its upstream peers
          see it). null derives like ciliumASN.
        '';
      };
    };

    # The private fleet fabric (D10), on by default: one private shared-bgp
    # pool derived from the cluster's CIDR space + core VIPs on it.
    fabric = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Render the private fleet fabric (D10): a cluster-global
          shared-bgp pool "<instance>-fabric" (RFC1918 + ULA blocks derived
          from the resolved cilium id, non-overlap with pod/service CIDRs
          eval-asserted) plus the private CoreDNS VIP.
        '';
      };
      ipv4Block = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Fabric pool IPv4 block. null derives 172.16.<ciliumId>.0/24.
          The prefix must be /26 or shorter (at least 64 addresses: the
          private CoreDNS VIP lives at offset 53).
        '';
      };
      ipv6Block = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Fabric pool IPv6 block. null derives fd11:<ciliumId>::/64.
          Prefix must be /120 or shorter (the private CoreDNS VIP lives at
          offset 0x53).
        '';
      };
      coredns = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Render the private-zone CoreDNS (D22 substrate): a second
            CoreDNS Deployment + a type:LoadBalancer Service pinned to the
            fabric VIP (offset 53 in the fabric blocks), serving the zone
            <instance>.<domain>. cluster.local is NEVER served here (D21).
          '';
        };
        wildcardAddress = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            The day-2 proxy address the <instance>.<domain> wildcard A/AAAA
            answer points at (D22: the zone's wildcard target is whatever
            proxy the operator installs). null = the zone serves NXDOMAIN —
            it exists and resolves negatively until day-2 sets a target.
          '';
        };
        svcZone = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            D22(a) opt-in: serve <instance>.svc.<domain> — suffix-rewritten
            to svc.cluster.local with answer-name reversal, forwarded to the
            cluster CoreDNS. Consumed by the fleet-routing admin role.
          '';
        };
        podZone = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            D22(b) opt-in: serve <instance>.pods.<domain> — suffix-rewritten
            to pod.cluster.local (dash-form), forwarded to the cluster
            CoreDNS (which has `pods insecure`). Meaningful only with
            bgp.advertisePodCIDRs (D13). Consumed by the fleet-routing
            admin role.
          '';
        };
      };
    };

    meshGroup = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The mesh (trust-domain) group this cluster belongs to. null =
        the default group: all cluster instances under the clan's
        meta.domain (or the instance's own domain override). An explicit
        string names a group; clusters sharing a group form one trust
        domain (ClusterMesh, control domains — D43). Phase-4 mapping: one
        mesh group = one wireguard-mesh instance — same-group clusters
        must consume the same node_transport source (fleet-asserted).
        Recorded in the kube_cluster export.
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
