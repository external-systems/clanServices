{ lib, ... }:
{
  options = {
    clusterInit = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bootstrap the cluster. Exactly one server-role member per
        cluster must set this.
      '';
    };

    nodeLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Extra Kubernetes node labels for this machine, rendered as
        key=value strings.
      '';
    };

    # Topology labels (invariant 7): rendered as
    # topology.kubernetes.io/region|zone node labels. null (default) =
    # the cluster's instance name; a per-machine string overrides; the
    # empty string is an eval error.
    topology = {
      region = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "hel1";
        description = ''
          This machine's topology.kubernetes.io/region label. null
          defaults to the cluster's instance name; empty string is
          rejected at eval.
        '';
      };
      zone = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "hel1-dc2";
        description = ''
          This machine's topology.kubernetes.io/zone label. null defaults
          to the cluster's instance name; empty string is rejected at
          eval.
        '';
      };
    };

    network = {
      ipv4 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          The node's IPv4 address. Required when network.transport is
          null (no transport service provides one).
        '';
      };
      ipv6 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          The node's IPv6 address. Required when network.transport is
          null.
        '';
      };
    };

    kubelet = {
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Extra kubelet command-line flags for this machine.
        '';
      };
    };

    # Extra blocks for this machine's auto-rendered node-named
    # CiliumLoadBalancerIPPool (D8 per-machine scope: the join-address
    # /32+/128 pair is always included; these are the declared
    # primary/extra blocks). Always node-fate-bound.
    poolBlocks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Additional CIDR blocks for the node-named LB pool of this machine
        (pool name = machine name, serviceSelector label
        clan.lol/pool=<machine>).
      '';
    };
  };
}
