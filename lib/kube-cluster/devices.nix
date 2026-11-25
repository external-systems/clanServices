# SPEC.md D71 (specs/gateway.md §14.2): the Cilium `devices` beyond the
# transport's links, rendered from facts, never hand-set.
#
# Per member machine:
#   - the link that owns the machine's default route (netif N21,
#     `gatewayInMain`): pod traffic to the outside leaves there, and
#     Cilium masquerades only on a `devices` link. Without it a pod's
#     packets leave with the pod's address, and the answers come back
#     another way or not at all (specs/gateway.md §16.4, `router-kube`).
#     Never a VPN zone's link;
#   - the CLAT link, when the machine is a `nat-gateway` client (G5);
#   - the underlay links of that client's uplink zone that carry no
#     IPv4 (no static IPv4 address, no DHCPv4): pod IPv6 leaves only
#     through a `devices` link (§13.2 point 10);
#   - every link of a `nat-gateway` gateway's uplink zone: its public
#     IPv4 is there, and pod IPv4 is masqueraded only on a `devices`
#     link (specs/gateway.md §14.5 point 5);
#   - the WAN link of a `router`: the same reason, for a router that is
#     a node (specs/gateway.md G25).
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
    natGateway = exportsOf clanLib exports "nat-gateway" machineName;
    clients = builtins.filter (value: (value.nat_gateway.clat.interface or null) != null) natGateway;
    gateways = builtins.filter (value: value.nat_gateway.gateway or false) natGateway;
    routers = builtins.filter (value: (value.router.wanZone or null) != null) (exportsOf clanLib exports "router" machineName);
    netifLinks = lib.concatMap (value: builtins.attrValues (value.netif.links or {})) (
      exportsOf clanLib exports "netif" machineName
    );
    defaults = map (link: link.interface) (
      builtins.filter (link: (link.gatewayInMain or false) && (link.interface or null) != null && !(lib.elem (link.zone or null) vpnZones)) netifLinks
    );
  in
    defaults
    ++ lib.concatMap (
      client: let
        zone = client.nat_gateway.uplinkZone or null;
        underlay = builtins.filter (link: zone != null && (link.zone or null) == zone && !(hasIpv4 link) && (link.interface or null) != null) netifLinks;
      in
        [client.nat_gateway.clat.interface] ++ map (link: link.interface) underlay
    )
    clients
    ++ lib.concatMap (
      gateway: let
        zone = gateway.nat_gateway.uplinkZone or null;
      in
        map (link: link.interface) (builtins.filter (link: zone != null && (link.zone or null) == zone && (link.interface or null) != null) netifLinks)
    )
    gateways
    ++ lib.concatMap (
      router:
        map (link: link.interface) (builtins.filter (link: (link.zone or null) == router.router.wanZone && (link.interface or null) != null) netifLinks)
    )
    routers;

  vpnNames = clanLib: exports: machineName:
    map (link: link.interface) (
      builtins.filter (link: lib.elem (link.zone or null) vpnZones && (link.interface or null) != null) (
        lib.concatMap (value: builtins.attrValues (value.netif.links or {})) (exportsOf clanLib exports "netif" machineName)
      )
    );
  # The zone links of a member that is a `router` (specs/gateway.md
  # G25): the router's firewall judges them, never Cilium.
  zoneLinks = clanLib: exports: machineName: let
    zones = lib.concatMap (value: value.router.zones or []) (exportsOf clanLib exports "router" machineName);
  in
    map (link: link.interface) (
      builtins.filter (link: lib.elem (link.zone or null) zones && (link.interface or null) != null) (
        lib.concatMap (value: builtins.attrValues (value.netif.links or {})) (exportsOf clanLib exports "netif" machineName)
      )
    );
in {
  inherit vpnPrefixes vpnZones;

  # Names in `devices` that are a zone link of a member that is a
  # router: a list of messages. `devices` is one list of names for the
  # whole cluster, so another member's uplink of the same name would
  # attach Cilium to the router's zone link, and Cilium would pass that
  # zone's traffic by the router's firewall.
  routerViolations = {
    clanLib,
    exports,
    members,
    devices,
  }:
    lib.concatMap (
      member:
        map (name: "'${name}' is a zone link of the router '${member}' and also a Cilium device (another member's uplink has that name): Cilium would pass the zone's traffic by the router's firewall. Give one of the two links another name (specs/gateway.md G25)") (
          builtins.filter (name: lib.elem name devices) (zoneLinks clanLib exports member)
        )
    )
    members;

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
