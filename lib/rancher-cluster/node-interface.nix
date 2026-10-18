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
  };
}
