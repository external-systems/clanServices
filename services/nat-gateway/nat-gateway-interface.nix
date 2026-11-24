# Export interface `nat_gateway`: what a `nat-gateway` client tells
# other services (specs/gateway.md G5, SPEC.md D71). The kube services
# read it to put the CLAT link into Cilium's `devices`. Every leaf has a
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
      description = "The netif zone of the client's uplink, whose links carry no IPv4.";
    };
  };
}
