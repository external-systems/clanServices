# The kube_cluster custom export interface (SPEC §6.2, renamed from
# rancher_cluster — D45). Published per cluster member machine by both
# distro services (rke2/k3s); consumed by the fleet checks (§6.2
# inventory-wide assertions) and, from phase 5, the fleet-routing
# service (pool handoff facts) and ClusterMesh peers (mesh endpoints).
#
# Every option carries a default (the clan CLI deep-evaluates the exports
# tree during `clan machines install/update` — an undefined leaf explodes
# mid-deploy). No secrets: only facts derivable from the inventory and
# the consumed node_transport exports.
{ lib, ... }:
let
  t = lib.types;
in
{
  options = {
    schemaVersion = lib.mkOption {
      type = t.ints.positive;
      default = 3;
      description = "kube_cluster export schema version (3 = native Cilium/FRR data plane: fabric reference, mesh peers, pool owners).";
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
          description = "Service name of the consumed routed-fabric source (routed_fabric export); null = manual addresses.";
        };
        instance = lib.mkOption {
          type = t.nullOr t.str;
          default = null;
          description = "Instance name of the consumed routed-fabric source; null = manual addresses.";
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
        setting, else the fabric instance name (D54). Same-group clusters
        form one ClusterMesh/control-domain trust domain, must consume the
        same fabric instance, and must have non-overlapping pod/service
        CIDRs (fleet-asserted).
      '';
    };

    # D54: null = full peering within the fabric instance; an explicit
    # list names selective (symmetric, non-transitive) peers.
    mesh = {
      peers = lib.mkOption {
        type = t.nullOr (t.listOf t.str);
        default = null;
        description = ''
          Explicit ClusterMesh peers (cluster instance names). null = full
          peering among the fabric instance's clusters. Peering bounds the
          automatic cross-cluster pod/Service route policy.
        '';
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
              default = [ ];
              description = "The member's fabric adjacency interface names (one per declared adjacency, D51); empty for manual-address clusters.";
            };
            interface = lib.mkOption {
              type = t.nullOr t.str;
              default = null;
              description = "COMPATIBILITY VIEW: the member's first fabric adjacency interface (node_transport shape); null for manual-address clusters.";
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
      default = { };
      description = "Mesh endpoints + effective topology per cluster member machine.";
    };

    # Pool handoff facts (D8): consumed by the phase-5 fleet-routing
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
              default = [ ];
              description = "Address inventory: CIDR blocks served by this pool.";
            };
            serviceSelector = lib.mkOption {
              type = t.attrsOf t.str;
              default = { };
              description = "matchLabels of the pool's serviceSelector.";
            };
          };
        }
      );
      default = { };
      description = "Resolved LB-IPAM pool handoff facts (phase-3 pools resolution) for fleet-routing.";
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
        description = "The host-side ASN Cilium dials at `::1` — the fabric node ASN from routed_fabric when the fabric reference resolves, else the hashed/pinned fallback.";
      };
      advertiseClusterIPs = lib.mkOption {
        type = t.bool;
        default = false;
        description = "D13 opt-in fact: ClusterIPs are advertised (pod-pool advertisements are always on — native routing, D49).";
      };
    };

    # Private fleet fabric facts (D10/D22, phase 5): the fabric pool and
    # the private CoreDNS VIP/zone — consumed by fleet-routing's router
    # role (pool facts) and client/admin roles (DNS stub target).
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
        description = "The fabric pool's IPv4 block.";
      };
      ipv6Block = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "The fabric pool's IPv6 block.";
      };
      coreDNS = {
        ipv4 = lib.mkOption {
          type = t.nullOr t.str;
          default = null;
          description = "The private CoreDNS VIP (v4) — the DNS stub target for <instance>.<domain> (D22).";
        };
        ipv6 = lib.mkOption {
          type = t.nullOr t.str;
          default = null;
          description = "The private CoreDNS VIP (v6).";
        };
        zone = lib.mkOption {
          type = t.str;
          default = "";
          description = "The private DNS zone served on the VIP (<instance>.<domain>); empty when the private CoreDNS is off.";
        };
        svcZone = lib.mkOption {
          type = t.str;
          default = "";
          description = "The D22(a) service zone (<instance>.svc.<domain>) when the cluster opted in; empty otherwise.";
        };
        podZone = lib.mkOption {
          type = t.str;
          default = "";
          description = "The D22(b) pod zone (<instance>.pods.<domain>) when the cluster opted in; empty otherwise.";
        };
      };
    };
  };
}
