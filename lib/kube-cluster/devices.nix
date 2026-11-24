# SPEC.md D71 (specs/gateway.md §14.2): the Cilium `devices` beyond the
# transport's links, rendered from facts, never hand-set.
#
# Per member machine:
#   - the CLAT link, when the machine is a `nat-gateway` client (G5);
#   - the underlay links of that client's uplink zone that carry no
#     IPv4 (no static IPv4 address, no DHCPv4): pod IPv6 leaves only
#     through a `devices` link (§13.2 point 10).
# Names come from the machines' netif and nat_gateway exports, whatever
# the kernel calls a link. `devices` is one cluster-wide Helm value: it
# is the union over the members, as the transport's links already are.
# Cilium skips a named link that a node lacks (proven by the transport
# links, which differ per node, and by `<distro>-clat`).
#
# Never a VPN link: a netif link in a zone named in `vpnZones`, or a
# name that starts with a known VPN prefix, is refused (§14.2).
{lib}: let
  vpnPrefixes = ["tailscale" "wt" "nb-" "zt" "tun"];
  vpnZones = ["vpn" "tailnet"];

  exportsOf = clanLib: exports: service: machineName:
    builtins.attrValues (
      clanLib.selectExports (scope: scope.serviceName == service && scope.machineName == machineName) exports
    );

  hasIpv4 = link:
    (link.dhcp4 or false) || lib.any (address: !(lib.hasInfix ":" address)) (link.addresses or []);

  # One member's extra devices, with where each came from.
  memberDevices = clanLib: exports: machineName: let
    clients = builtins.filter (value: (value.nat_gateway.clat.interface or null) != null) (
      map (value: value) (exportsOf clanLib exports "nat-gateway" machineName)
    );
    netifLinks = lib.concatMap (value: builtins.attrValues (value.netif.links or {})) (
      exportsOf clanLib exports "netif" machineName
    );
  in
    lib.concatMap (
      client: let
        zone = client.nat_gateway.uplinkZone or null;
        underlay = builtins.filter (link: zone != null && (link.zone or null) == zone && !(hasIpv4 link) && (link.interface or null) != null) netifLinks;
      in
        [client.nat_gateway.clat.interface] ++ map (link: link.interface) underlay
    )
    clients;

  vpnNames = clanLib: exports: machineName:
    map (link: link.interface) (
      builtins.filter (link: lib.elem (link.zone or null) vpnZones && (link.interface or null) != null) (
        lib.concatMap (value: builtins.attrValues (value.netif.links or {})) (exportsOf clanLib exports "netif" machineName)
      )
    );
in {
  inherit vpnPrefixes vpnZones;

  # The extra devices of the cluster: a sorted, unique list of names.
  extra = {
    clanLib,
    exports,
    members,
  }:
    lib.sort builtins.lessThan (lib.unique (lib.concatMap (memberDevices clanLib exports) members));

  # Names in `devices` that are VPN links: a list of messages.
  vpnViolations = {
    clanLib,
    exports,
    members,
    devices,
  }: let
    vpn = lib.unique (lib.concatMap (vpnNames clanLib exports) members);
  in
    map (name: "'${name}' is a VPN link (D71: never in Cilium devices)") (
      builtins.filter (name: lib.elem name vpn || lib.any (prefix: lib.hasPrefix prefix name) vpnPrefixes) devices
    );
}
