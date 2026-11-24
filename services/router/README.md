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
