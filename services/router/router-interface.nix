# Export interface `router`: what a `router` machine tells other
# services (specs/gateway.md G25, SPEC.md D71). The kube services read
# it: the WAN link of a router that is a cluster node goes into Cilium's
# `devices`. Every leaf has a default: the clan CLI deep-evaluates
# exports.
{lib, ...}: let
  inherit (lib) mkOption types;
in {
  options = {
    schemaVersion = mkOption {
      type = types.int;
      default = 1;
      description = "Schema version of this export.";
    };
    wanZone = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The netif zone of the router's WAN link.";
    };
    zones = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "The netif zones the router judges (its LAN zones). Their links are never Cilium devices.";
    };
  };
}
