{ lib, ... }:
{
  options = {
    ipv4 = lib.mkOption {
      type = lib.types.str;
      description = "The member's WireGuard mesh IPv4 host address.";
    };
    ipv6 = lib.mkOption {
      type = lib.types.str;
      description = "The member's WireGuard mesh IPv6 host address.";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      description = "The WireGuard interface name.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      description = "The WireGuard UDP listen port.";
    };
    mtu = lib.mkOption {
      type = lib.types.ints.positive;
      description = "The WireGuard interface MTU.";
    };
    endpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The externally reachable host and UDP port peers dial, when known.";
    };
    instance = lib.mkOption {
      type = lib.types.str;
      description = "The WireGuard mesh instance name.";
    };
    # §6.2 audit: topology rides the kube_cluster export (cluster-node
    # concept, effective labels); the node_transport interface carries
    # optional pass-through fields for transport services that know them.
    # wireguard-mesh leaves them null.
    topology = {
      region = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The member's topology region, when the transport service knows it.";
      };
      zone = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The member's topology zone, when the transport service knows it.";
      };
    };
  };
}
