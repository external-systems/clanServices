# Export interface `nat_gateway`: what a `nat-gateway` machine tells
# other services (specs/gateway.md G5, §14.5 point 5, SPEC.md D71). The
# kube services read it: a client's CLAT link and IPv6-only uplink, and a
# gateway's uplink (its pods' IPv4 leaves there), go into Cilium's
# `devices`. Every leaf has a
# default: the clan CLI deep-evaluates exports.
{lib, ...}: let
  inherit (lib) mkOption types;
in {
  options = {
    schemaVersion = mkOption {
      type = types.int;
      default = 1;
      description = "Schema version of this export.";
    };
    clat = {
      interface = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The host side of the machine's CLAT link; null without a CLAT.";
      };
      address = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The CLAT's own IPv6 address.";
      };
    };
    uplinkZone = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The netif zone of the machine's uplink: a client's carries no IPv4, a gateway's carries its public IPv4.";
    };
    gateway = mkOption {
      type = types.bool;
      default = false;
      description = "The machine is a gateway (it has its own IPv4 and runs no CLAT).";
    };
  };
}
