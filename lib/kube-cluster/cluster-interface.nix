{lib, ...}: {
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
      fabric = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              service = lib.mkOption {
                type = lib.types.str;
                description = ''
                  Name of the clanService that exports the generic
                  node_transport interface (the transport source — e.g.
                  routed-fabric or wireguard-mesh, or any third-party
                  overlay implementing the neutral schemaVersion 2 seam,
                  D58). The cluster consumes that instance's node_transport
                  export ONLY; it never branches on provider service names.
                '';
              };
              instance = lib.mkOption {
                type = lib.types.str;
                description = "Name of the transport instance to consume.";
              };
            };
          }
        );
        default = null;
        description = ''
          Selects the transport source consumed through the generic
          node_transport schemaVersion 2 export (D58). null requires
          explicit per-node network.ipv4/ipv6 addresses. The mesh group
          defaults to the transport instance name (D54).
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
        default = {};
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
                matchLabels of the pool's serviceSelector. Every explicit
                pool draw pins io.cilium/bgp-control-plane; only BGP pools
                are selected for advertisement.
              '';
            };
            delivery = lib.mkOption {
              type = lib.types.enum [
                "node-fate-bound"
                "node-bgp"
                "floating"
                "shared-bgp"
                "external-class"
              ];
              description = ''
                How traffic reaches pool addresses + failure semantics
                (D8). node-fate-bound is per-machine scope and is rejected
                for declared (cluster-global) pools. node-bgp is the
                owner-only BGP delivery: exactly one `owner` machine
                advertises the pool's exact /32+/128 VIPs (no cross-node
                ECMP), requiring the BGP plane (bgp.enable — locked
                together, eval-asserted) and
                loadBalancerClass: io.cilium/bgp-control-plane on drawing
                Services (Cilium announces only that class or unset).
                shared-bgp likewise requires the BGP plane and the
                bgp-control-plane class; every healthy eligible node
                advertises (FRR/upstream ECMP, ETP-Local withdrawal).
                shared-bgp blocks must stay inside border-owned prefixes
                when a border is declared (fleet-wide check, D8 round 16).
              '';
            };
            owner = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                The machine that owns a node-bgp pool: only that node's
                Cilium advertises the pool's VIPs (D8 owner-only delivery).
                Required for node-bgp pools; null otherwise.
              '';
            };
            candidates = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = ''
                Machine names a floating pool's runtime controller may move
                addresses to. floating ⇒ must cover the full candidate set
                (eval-asserted non-empty and subset of cluster members).
              '';
            };
          };
        }
      );
      default = {};
      description = ''
        Cluster-global CiliumLoadBalancerIPPool definitions (D8). Explicit
        pool draws pin io.cilium/bgp-control-plane; classless Services go
        to Node IPAM (D41).
      '';
    };

    # BGP v2 control plane (D9 revised). `enable` is locked to the presence
    # of node-bgp/shared-bgp pools (invariant 6, eval-asserted): BGP exists
    # only to deliver BGP pool VIPs (plus the always-on pod-pool
    # advertisements native routing requires, D49), and those pools cannot
    # work without it. With the default fabric (D10, fabric.enable = true)
    # a shared-bgp pool always exists, so the default here is consistent.
    bgp = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Render the BGP v2 resources (CiliumBGPClusterConfig per node,
          CiliumBGPPeerConfig, CiliumBGPAdvertisement). Must equal "any
          node-bgp or shared-bgp pool exists" — both directions are
          eval-asserted (§6.12).
        '';
      };
      advertiseClusterIPs = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          D13 opt-in: advertise Service ClusterIPs to BGP peers. Default
          off. Pod-pool advertisements are NOT optional: native routing
          requires FRR-distributed remote pod routes (D49), so the
          CiliumPodIPPool advertisement is always rendered.
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
      hostASN = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 1 4294967295);
        default = null;
        description = ''
          The host-side BGP ASN Cilium peers with at `::1`. null derives
          the same deterministic node ASN as the native local-router
          producer. Set this explicitly when a third-party local-router
          implementation uses a different ASN.
        '';
      };
    };

    # The private fleet fabric (D10, round 17): one private shared-bgp
    # pool derived from the cluster's CIDR space, carrying the pinned
    # internal ClusterMesh apiserver IPv4 VIP at host offset 79 (D60).
    # Member-facing private DNS is wholly day-2 (D22 amended).
    fabric = {
      enable = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Render the private fleet fabric (D10): a cluster-global
          shared-bgp pool "<instance>-fabric" carrying the internal
          ClusterMesh apiserver IPv4 VIP (offset 79, D60). null defaults on
          for native local-router transports and off for tunnel/manual
          transports. Explicitly enabling it requires local-router BGP.
        '';
      };
      ipv4Block = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Fabric pool IPv4 block. null derives 172.16.<ciliumId>.0/24.
          The prefix must be /25 or shorter (at least 128 addresses: the
          ClusterMesh apiserver VIP lives at offset 79, D10 round 17).
        '';
      };
      ipv6Block = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Fabric pool IPv6 block. null derives fd11:<ciliumId>::/64.
          Prefix must be /120 or shorter (the ClusterMesh apiserver VIP
          lives at offset 0x79).
        '';
      };
    };

    meshGroup = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The mesh (trust-domain) group this cluster belongs to. null =
        the default group: the fabric instance name when network.fabric is
        set, else the clan's meta.domain (or the instance's domain
        override). An explicit string names a group; clusters sharing a
        group form one trust domain (ClusterMesh, control domains — D43/
        D54). Same-group clusters must consume the same fabric instance
        (fleet-asserted). Recorded in the kube_cluster export.
      '';
    };

    # D60 normalized ClusterMesh settings (replaces the old flat meshPeers
    # knob — breaking, no migration shims).
    mesh = {
      # D54: full peering within one fabric instance is the default (null);
      # an explicit list names selective peers (symmetric, non-transitive;
      # fleet-asserted).
      peers = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Explicit ClusterMesh peers (cluster instance names) for selective
          peering (D54). null (default) = full peering among the clusters
          of the mesh group. Peering bounds the automatic cross-cluster
          pod/Service route policy rendered into fabric filters; selective
          peers must be symmetric and same-group (fleet-asserted).
        '';
      };

      placement = lib.mkOption {
        type = lib.types.enum [
          "voters"
          "workers"
          "all"
          "labels"
        ];
        default = "voters";
        description = ''
          clustermesh-apiserver placement (D60): voters (default — server
          nodes), workers (agent nodes), all, or labels (clan-declared/
          generated node labels only — a selector matching zero nodes is
          an eval error).
        '';
      };

      placementLabels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = ''
          Label selector for placement = labels. Only clan-declared
          (nodeLabels) or generated (role/machine/cluster/topology) labels
          are selectable; a selector matching zero cluster nodes is an
          eval error (D60).
        '';
      };

      exposure = lib.mkOption {
        type = lib.types.enum [
          "auto"
          "internal-load-balancer"
          "node-port"
          "external-load-balancer"
        ];
        default = "auto";
        description = ''
          clustermesh-apiserver exposure (D60): auto (default) picks
          internal-load-balancer when the transport exposes that
          capability, else node-port; unsupported or no-method selections
          are eval errors. external-load-balancer always wins on every
          overlay: it needs no internal capability, but requires an
          explicit non-clan loadBalancerClass and a dnsName (mesh.external).
          ETP Local on every method.
        '';
      };

      replicas = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 1 500);
        default = null;
        description = ''
          Independent clustermesh-apiserver replica count — internal and
          external LoadBalancer exposure ONLY. null (default) =
          min(3, eligible nodes); a user value must be positive and no
          larger than the eligible node count. FORBIDDEN on node-port
          exposure (replicas there equal the selected node count, D60).
        '';
      };

      nodePort = lib.mkOption {
        type = lib.types.ints.between 30000 32767;
        default = 32379;
        description = ''
          Node-port exposure port (Kubernetes NodePort range 30000–32767).
          Collision-checked per machine against every other mesh NodePort
          (D60).
        '';
      };

      maxConnectedClusters = lib.mkOption {
        type = lib.types.enum [
          255
          511
        ];
        default = 255;
        description = ''
          Cilium maxConnectedClusters (Cilium 1.20: 255 or 511). Set at
          install time; MUST be identical across every cluster of the mesh
          group (fleet-asserted, D60) — changing it live disrupts
          connectivity and policy enforcement.
        '';
      };

      external = {
        loadBalancerClass = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            External exposure ONLY: an explicit non-clan LoadBalancerClass
            (io.cilium/* classes are clan-internal and rejected). The
            class needs no internal transport capability — external
            exposure wins on every overlay (D60).
          '';
        };
        dnsName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            External exposure ONLY: the DNS name peers dial and the
            certificate carries (DNS ONLY — a literal IP is rejected).
            DNS resolution is a runtime prerequisite (D60).
          '';
        };
        annotations = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = ''
            External exposure ONLY: provider Service annotations
            (external-dns is day-2 and never clan-rendered).
          '';
        };
      };
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
        default = [];
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
        default = {};
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
        default = [];
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
