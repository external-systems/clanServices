# The fleet_routing custom export interface (SPEC §6.13, D11/D33).
# Published per fleet-routing machine by all roles; consumed by the
# kube-cluster fleet check `kube-cluster-shared-bgp-router-prefixes`
# (routerPrefixes, D8) and by operators wiring a cluster's
# bgp.upstreamPeers (asn).
#
# Every option carries a default (the clan CLI deep-evaluates the exports
# tree). No secrets.
{ lib, ... }:
let
  t = lib.types;
in
{
  options = {
    schemaVersion = lib.mkOption {
      type = t.ints.positive;
      default = 1;
      description = "fleet_routing export schema version.";
    };

    asn = lib.mkOption {
      type = t.nullOr t.ints.positive;
      default = null;
      description = ''
        The fleet-routing instance's BIRD ASN (deterministic private 32-bit
        hash of the instance name). Clusters peer with fleet machines by
        listing their mesh addresses in bgp.upstreamPeers with this ASN.
      '';
    };

    routerPrefixes = lib.mkOption {
      type = t.listOf t.str;
      default = [ ];
      description = ''
        Router role only: the prefixes this router owns (D33). The
        kube-cluster fleet check rejects cluster shared-bgp pool blocks
        outside the union of all routerPrefixes in the inventory (D8).
      '';
    };
  };
}
