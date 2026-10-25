{ lib, ... }:
let
  t = lib.types;
in
{
  options = {
    schemaVersion = lib.mkOption {
      type = t.ints.positive;
      default = 2;
      description = "Node transport schema version; version 2 represents routed adjacency transport.";
    };
    ipv4 = lib.mkOption {
      type = t.nullOr t.str;
      default = null;
      description = "Stable dual-stack fabric IPv4 host address.";
    };
    ipv6 = lib.mkOption {
      type = t.nullOr t.str;
      default = null;
      description = "Stable dual-stack fabric IPv6 host address.";
    };
    interface = lib.mkOption {
      type = t.nullOr t.str;
      default = null;
      description = "Primary datapath interface; routed-fabric consumers use routed_fabric.adjacencies for every link.";
    };
    port = lib.mkOption {
      type = t.nullOr t.port;
      default = null;
      description = "Base transport UDP port.";
    };
    mtu = lib.mkOption {
      type = t.nullOr t.ints.positive;
      default = null;
      description = "Smallest datapath MTU.";
    };
    endpoint = lib.mkOption {
      type = t.nullOr t.str;
      default = null;
      description = "Reachable transport endpoint when one exists.";
    };
    instance = lib.mkOption {
      type = t.nullOr t.str;
      default = null;
      description = "Transport instance name.";
    };
    topology = {
      region = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "Optional topology region supplied by a transport.";
      };
      zone = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "Optional topology zone supplied by a transport.";
      };
    };
  };
}
