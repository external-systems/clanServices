# The kube_cluster custom export interface (SPEC §6.2, renamed from
# rancher_cluster — D45; schemaVersion 4 per D58/D60). Published per
# cluster member machine by both distro services (rke2/k3s); consumed by
# the fleet checks (§6.2 inventory-wide assertions), ClusterMesh peers
# (mesh.exposure.published endpoints), and routed-fabric (route-policy
# bounds).
#
# Every option carries a default (the clan CLI deep-evaluates the exports
# tree during `clan machines install/update` — an undefined leaf explodes
# mid-deploy). No secrets: only facts derivable from the inventory and
# the consumed node_transport exports.
{lib, ...}: let
  t = lib.types;
in {
  options = {
    schemaVersion = lib.mkOption {
      type = t.ints.positive;
      default = 4;
      description = "kube_cluster export schema version (4 = generic node_transport datapath facts + ClusterMesh placement/exposure facts, D58/D60).";
    };

    name = lib.mkOption {
      type = t.str;
      default = "";
      description = "Cluster name (= the clan instance name).";
    };

    ciliumId = lib.mkOption {
      type = t.nullOr (t.ints.between 1 255);
      default = null;
      description = "The resolved Cilium cluster id (explicit pin or hashed default).";
    };

    network = {
      fabric = {
        service = lib.mkOption {
          type = t.nullOr t.str;
          default = null;
          description = "Service name of the consumed node_transport source; null = manual addresses.";
        };
        instance = lib.mkOption {
          type = t.nullOr t.str;
          default = null;
          description = "Instance name of the consumed node_transport source; null = manual addresses.";
        };
      };
      podCIDRv4 = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "Resolved IPv4 pod CIDR.";
      };
      podCIDRv6 = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "Resolved IPv6 pod CIDR.";
      };
      serviceCIDRv4 = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "Resolved IPv4 service CIDR.";
      };
      serviceCIDRv6 = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "Resolved IPv6 service CIDR.";
      };
      clusterDNS = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "Resolved clusterDNS address (10th address of the service v4 CIDR).";
      };
    };

    meshGroup = lib.mkOption {
      type = t.str;
      default = "";
      description = ''
        The mesh (trust-domain) group string: the explicit meshGroup
        setting, else the transport instance name (D54). Same-group
        clusters form one ClusterMesh/control-domain trust domain, must
        consume the same fabric instance, and must have non-overlapping
        pod/service CIDRs (fleet-asserted).
      '';
    };

    # D54: null = full peering within the mesh group; an explicit list
    # names selective (symmetric, non-transitive) peers. D60: the resolved
    # exposure facts (how peers reach this cluster's apiserver) ride the
    # mesh subtree, and the datapath facts (D58) feed group uniformity.
    mesh = {
      peers = lib.mkOption {
        type = t.nullOr (t.listOf t.str);
        default = null;
        description = ''
          Explicit ClusterMesh peers (cluster instance names). null = full
          peering among the mesh group's clusters. Peering bounds the
          automatic cross-cluster pod/Service route policy; explicit peers
          must be symmetric and same-group (fleet-asserted).
        '';
      };
      placement = lib.mkOption {
        type = t.enum [
          "voters"
          "workers"
          "all"
          "labels"
        ];
        default = "voters";
        description = "The resolved clustermesh-apiserver placement (D60).";
      };
      maxConnectedClusters = lib.mkOption {
        type = t.enum [
          255
          511
        ];
        default = 255;
        description = ''
          Cilium maxConnectedClusters. MUST be identical across every
          cluster of the mesh group (fleet-asserted, D60).
        '';
      };
      exposure = {
        method = lib.mkOption {
          type = t.enum [
            "internal-load-balancer"
            "node-port"
            "external-load-balancer"
          ];
          default = "internal-load-balancer";
          description = ''
            The resolved exposure method (D60): auto never reaches the
            export — it resolves to internal-load-balancer when the
            transport exposes that capability, else node-port.
          '';
        };
        nodePort = lib.mkOption {
          type = t.nullOr (t.ints.between 30000 32767);
          default = null;
          description = "The apiserver Service NodePort (node-port exposure only; default 32379).";
        };
        replicas = lib.mkOption {
          type = t.ints.positive;
          default = 1;
          description = ''
            The apiserver Deployment replica count: node-port exposure
            pins it to the selected node count; LoadBalancer methods use
            min(3, eligible) unless the user pinned a positive count no
            larger than the eligible set (D60).
          '';
        };
        vip4 = lib.mkOption {
          type = t.nullOr t.str;
          default = null;
          description = ''
            The pinned internal IPv4 VIP (host offset 79 of the
            <instance>-fabric pool, class io.cilium/bgp-control-plane,
            explicit lbipam.cilium.io/ips projection); null on other
            methods (D60).
          '';
        };
        dnsName = lib.mkOption {
          type = t.nullOr t.str;
          default = null;
          description = "The external DNS name (external-load-balancer only, D60); null otherwise.";
        };
        loadBalancerClass = lib.mkOption {
          type = t.nullOr t.str;
          default = null;
          description = ''
            The Service loadBalancerClass: io.cilium/bgp-control-plane on
            internal exposure, the explicit non-clan class on external
            exposure, null on node-port (D60).
          '';
        };
        published = lib.mkOption {
          type = t.listOf t.str;
          default = [];
          description = ''
            This cluster's published clustermesh endpoints (what peers
            dial): the internal IPv4 VIP, every selected node's stable IPv4
            address on the mesh NodePort, or the external dnsName (D60).
            Peers render these into their cilium-clustermesh /
            cilium-kvstoremesh secrets; no DNS is needed internally.
          '';
        };
      };
    };

    # D58: the transport-derived datapath facts (from the generic
    # node_transport export) — consumed by the fleet checks (group
    # uniformity) and by fabric peers (route-policy bounds).
    datapath = {
      mode = lib.mkOption {
        type = t.enum [
          "native"
          "tunnel"
        ];
        default = "native";
        description = "The transport-derived Cilium datapath mode (routing-mode).";
      };
      tunnelProtocol = lib.mkOption {
        type = t.nullOr (t.enum ["vxlan"]);
        default = null;
        description = "The tunnel protocol (tunnel mode only; vxlan is the only supported profile).";
      };
      routeExchange = lib.mkOption {
        type = t.nullOr (t.enum ["local-router"]);
        default = null;
        description = "The daemon-neutral route-exchange profile (native only: local-router; null on tunnels).";
      };
      devices = lib.mkOption {
        type = t.listOf t.str;
        default = [];
        description = "The union of the cluster's datapath interface names (Cilium devices).";
      };
      directRoutingDevice = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "The transport's directRoutingDevice (null for manual-address clusters).";
      };
      mtu = lib.mkOption {
        type = t.nullOr t.ints.positive;
        default = null;
        description = "The cluster's derived Cilium MTU (native: min interface MTU; VXLAN: min minus 50; null for manual-address clusters).";
      };
      internalLoadBalancer = lib.mkOption {
        type = t.bool;
        default = false;
        description = "Whether the transport exposes the internal LoadBalancer capability (D58).";
      };
      nodePort = lib.mkOption {
        type = t.bool;
        default = false;
        description = "Whether the transport exposes the NodePort capability (D58).";
      };
    };

    controlDomain = {
      role = lib.mkOption {
        type = t.enum [
          "standalone"
          "hub"
          "spoke"
        ];
        default = "standalone";
        description = ''
          Control-domain role (D43). Phase 4 publishes the structural
          default "standalone"; the real controlDomain option lands in
          phase 6.
        '';
      };
    };

    # Per-member mesh endpoints: the member's node addresses plus its
    # fabric facts (when fabric-provided) and effective topology
    # labels. The fabric source itself is published under network.fabric.
    members = lib.mkOption {
      type = t.attrsOf (
        t.submodule {
          options = {
            role = lib.mkOption {
              type = t.enum [
                "server"
                "agent"
              ];
              default = "server";
              description = "The member's cluster role.";
            };
            ipv4 = lib.mkOption {
              type = t.nullOr t.str;
              default = null;
              description = "The member's node IPv4 (mesh or manual).";
            };
            ipv6 = lib.mkOption {
              type = t.nullOr t.str;
              default = null;
              description = "The member's node IPv6 (mesh or manual).";
            };
            endpoint = lib.mkOption {
              type = t.nullOr t.str;
              default = null;
              description = "The member's externally reachable transport endpoint (host:port), when known.";
            };
            interfaces = lib.mkOption {
              type = t.listOf t.str;
              default = [];
              description = "The member's fabric adjacency interface names (one per declared adjacency, D51); empty for manual-address clusters.";
            };
            mtu = lib.mkOption {
              type = t.nullOr t.ints.positive;
              default = null;
              description = "The member's smallest fabric adjacency MTU (native Cilium uses it directly, D51); null for manual-address clusters.";
            };
            port = lib.mkOption {
              type = t.nullOr t.port;
              default = null;
              description = "The member's transport listen port (null for manual-address clusters).";
            };
            topology = {
              region = lib.mkOption {
                type = t.nullOr t.str;
                default = null;
                description = "Effective topology.kubernetes.io/region label (override or instance name).";
              };
              zone = lib.mkOption {
                type = t.nullOr t.str;
                default = null;
                description = "Effective topology.kubernetes.io/zone label (override or instance name).";
              };
            };
          };
        }
      );
      default = {};
      description = "Mesh endpoints + effective topology per cluster member machine.";
    };

    # Pool handoff facts (D8): consumed by routed-fabric
    # service. Per-machine pools are node-fate-bound by construction;
    # cluster-global pools carry their declared delivery mode.
    pools = lib.mkOption {
      type = t.attrsOf (
        t.submodule {
          options = {
            scope = lib.mkOption {
              type = t.enum [
                "per-machine"
                "cluster-global"
              ];
              default = "cluster-global";
              description = "Pool scope: per-machine (node-named) or cluster-global (generic-named).";
            };
            delivery = lib.mkOption {
              type = t.enum [
                "node-fate-bound"
                "node-bgp"
                "floating"
                "shared-bgp"
                "external-class"
              ];
              default = "node-fate-bound";
              description = "Delivery mode: how traffic reaches pool addresses + failure semantics (D8).";
            };
            owner = lib.mkOption {
              type = t.nullOr t.str;
              default = null;
              description = "The machine that owns a node-bgp pool (D8 owner-only delivery); null for non-node-bgp pools.";
            };
            blocks = lib.mkOption {
              type = t.listOf t.str;
              default = [];
              description = "Address inventory: CIDR blocks served by this pool.";
            };
            serviceSelector = lib.mkOption {
              type = t.attrsOf t.str;
              default = {};
              description = "matchLabels of the pool's serviceSelector.";
            };
          };
        }
      );
      default = {};
      description = "Resolved LB-IPAM pool handoff facts (phase-3 pools resolution) for routed-fabric.";
    };

    # BGP plane facts (D9 revised): consumed by routed-fabric (the host FRR
    # terminates the Cilium `::1` sessions and exchanges filtered routes
    # across the fabric) and by the fleet checks (ASN collision).
    bgp = {
      enabled = lib.mkOption {
        type = t.bool;
        default = false;
        description = "Whether the cluster renders the BGP v2 plane (locked to node-bgp/shared-bgp pool presence, §6.12).";
      };
      ciliumAsn = lib.mkOption {
        type = t.nullOr t.ints.positive;
        default = null;
        description = "The Cilium-side ASN (deterministic private 32-bit per cluster, or pinned).";
      };
      hostAsn = lib.mkOption {
        type = t.nullOr t.ints.positive;
        default = null;
        description = "The host-side ASN Cilium dials at `::1`, derived from the native local-router profile or an explicit bgp.hostASN pin.";
      };
      advertiseClusterIPs = lib.mkOption {
        type = t.bool;
        default = false;
        description = "D13 opt-in fact: ClusterIPs are advertised (pod-pool advertisements are always on — native routing, D49).";
      };
    };

    # Private fleet fabric facts (D10 round 17): the fabric pool carrying
    # the internal ClusterMesh IPv4 VIP. Member-facing DNS is day-2 (D22).
    fabric = {
      enabled = lib.mkOption {
        type = t.bool;
        default = false;
        description = "Whether the private fleet fabric pool is rendered (D10).";
      };
      pool = lib.mkOption {
        type = t.str;
        default = "";
        description = "The fabric pool's name (= its clan.lol/pool selector value).";
      };
      ipv4Block = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "The fabric pool's IPv4 block (must hold host offset 79 — at least 128 addresses).";
      };
      ipv6Block = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "The fabric pool's IPv6 block.";
      };
    };
  };
}
