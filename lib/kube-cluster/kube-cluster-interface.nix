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
      default = 2;
      description = "kube_cluster export schema version (2 = phase 5: bgp/fabric facts).";
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
        setting, else the cluster's domain (meta.domain by default).
        Same-group clusters form one ClusterMesh/control-domain trust
        domain and must share one node_transport source.
      '';
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

    # All-or-none transport posture fact (§6.3): the node_transport
    # source this cluster consumes, or nulls for a manual-address cluster.
    transport = {
      service = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "Service name of the consumed node_transport exporter (e.g. wireguard-mesh); null = manual addresses.";
      };
      instance = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "Instance name of the consumed node_transport exporter; null = manual addresses.";
      };
    };

    # Per-member mesh endpoints: the member's node addresses plus its
    # transport facts (when transport-provided) and effective topology
    # labels.
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
            interface = lib.mkOption {
              type = t.nullOr t.str;
              default = null;
              description = "The member's transport interface name (null for manual-address clusters).";
            };
            mtu = lib.mkOption {
              type = t.nullOr t.ints.positive;
              default = null;
              description = "The member's transport MTU (null for manual-address clusters).";
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
                "floating"
                "shared-bgp"
                "external-class"
              ];
              default = "node-fate-bound";
              description = "Delivery mode: how traffic reaches pool addresses + failure semantics (D8).";
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

    # BGP plane facts (D9, phase 5): consumed by fleet-routing (its router
    # role peers with the cluster BIRD ASNs; its client/admin roles learn
    # where VIP routes come from) and by the fleet checks (ASN collision).
    bgp = {
      enabled = lib.mkOption {
        type = t.bool;
        default = false;
        description = "Whether the cluster renders the BGP v2 plane (locked to shared-bgp pool presence, §6.12).";
      };
      ciliumAsn = lib.mkOption {
        type = t.nullOr t.ints.positive;
        default = null;
        description = "The Cilium-side ASN (deterministic private 32-bit per cluster, or pinned).";
      };
      birdAsn = lib.mkOption {
        type = t.nullOr t.ints.positive;
        default = null;
        description = "The BIRD-side ASN — the cluster's ASN as its upstream/fleet peers see it.";
      };
      upstreamPeers = lib.mkOption {
        type = t.listOf (
          t.submodule {
            options = {
              address = lib.mkOption {
                type = t.str;
                default = "";
                description = "Upstream peer address.";
              };
              asn = lib.mkOption {
                type = t.nullOr t.ints.positive;
                default = null;
                description = "Upstream peer ASN.";
              };
              receivePodCIDRs = lib.mkOption {
                type = t.bool;
                default = false;
                description = "Peer receives pod CIDR routes (D13; requires the cluster's advertisePodCIDRs opt-in).";
              };
              receiveClusterIPs = lib.mkOption {
                type = t.bool;
                default = false;
                description = "Peer receives ClusterIP routes (D13; requires the cluster's advertiseClusterIPs opt-in).";
              };
            };
          }
        );
        default = [ ];
        description = "Configured upstream BGP peers (D9).";
      };
      advertisePodCIDRs = lib.mkOption {
        type = t.bool;
        default = false;
        description = "D13 opt-in fact: pod CIDRs are advertised.";
      };
      advertiseClusterIPs = lib.mkOption {
        type = t.bool;
        default = false;
        description = "D13 opt-in fact: ClusterIPs are advertised.";
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
