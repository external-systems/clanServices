The edge of a LAN with one WAN (`specs/gateway.md` G8, G11, G12, G14,
G15, G20, G22).

- **Zones** are netif zone labels. Default deny between zones; a zone
  reaches the WAN when `internet` is on and the zones in `allowTo`.
  Nothing enters from the WAN unless `servicePrefix.expose` names it.
- **IPv4:** NAT44 to the WAN; kea serves DHCPv4 in each zone (the upper
  half of the zone's subnet).
- **IPv6:** corerad advertises each zone's /64 of the delegated prefix
  and its ULA /64, with RDNSS and DNSSL. A prefix hook follows a change
  of the delegation: it retires the old prefix at once, rejects stale
  sources at the LAN edge, and keeps the service prefix rewrite current.
- **DNS:** CoreDNS answers on each zone's own address, in that zone only,
  with an optional blocklist and static records, forwarding over TLS.

## A router that is also something else (G25)

The router's table judges a packet only when it enters or leaves
through a **router link**: the WAN link or a zone's link. Every other
link of the machine is **unzoned** (a fabric's WireGuard links, Cilium's
links, a VPN): the NixOS firewall judges it, as on any machine. So a
router can be a Kubernetes node. The NixOS firewall must stay on; on a
router link a packet passes both.

What may cross between the two sides is named, default deny:

- The cluster always reaches the WAN.
- `unzoned.zones = ["home"]`: zone `home` and the cluster's pods and
  services may reach each other, in both directions. The router cannot
  tell who opened a flow there: Cilium sends a pod's packets straight
  out of the zone's link, past the router's table. A flow from the
  zone is masqueraded: pods see the router's address as the source,
  because the fabric carries cluster addresses only. On a node the source is the node's fabric
  address, read from the fabric (`unzoned.source.ipv4` and `.ipv6`
  override it): a plain masquerade picks an address the fabric's peers
  refuse. Narrow it with a
  Cilium network policy. For a zone that is not named, the router drops
  what the zone sends towards the cluster, so no connection forms.
- `zones.<zone>.hostPorts = true`: the zone may reach the ports the
  machine opens to everyone, such as the fabric's WireGuard ports. Set
  it on the zone that holds the other nodes.
- `wanPorts.tcp`, `wanPorts.udp`: ports of the router itself that the
  WAN may reach. Empty by default: nothing enters. **Name 22 here
  before the first deploy if you deploy over the WAN.**

On a cluster member the WAN link joins Cilium's `devices` (SPEC.md
D71), so the node's pods leave with the WAN address. A zone link is
never a Cilium device: the device list is one list of names for the
whole cluster, so the build refuses a zone link that has the same name
as another node's uplink. Give one of them another name.

A zone is one link (put several ports in a bridge), its link must set
`ra = false`, and the router's own IPv4 address must be in the lower
half of the zone's subnet: the upper half is the DHCPv4 pool.

netif owns every link, address and the delegation. The router reads
them: the zone's links, the first IPv4 and IPv6 address of the zone's
first link (the router's address there), and the subnet id netif's
`prefixDelegation.assign` gives that link.

```nix
inventory.instances.edge = {
  module.name = "router";
  module.input = "clanServices";
  roles.router.machines.router.settings = {
    zones = {
      home.allowTo = ["iot"];
      iot = {};
      servers = {};
      mgmt.internet = false;
    };
    domain = "home.arpa";
  };
};
```

Not built yet (frozen, `specs/gateway.md` §14.1 point 2): IPv6-mostly,
a second WAN, several routers. Also open: the HaGeZi blocklist package,
port forwards (G12 class 3), the mDNS reflector, metrics on the fabric
address (G18), the hairpin source rewrite of G20 (§14.3).
