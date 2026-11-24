IPv4 reach for clan machines that have no IPv4 on their network cards
(`specs/gateway.md` G1–G6, G23, G24).

## Roles

- **gateway**: a machine with a public IPv4. Jool NAT64 in a network
  namespace of its own, a source allowlist built from the clients, a
  rate limit per source in two tiers, a health check through the
  translator, and a health beacon that answers `ipv4only.arpa` and
  nothing else.
- **client**: an IPv6-only machine. A CLAT (Jool SIIT) turns its IPv4
  into IPv6 towards one gateway; a follower moves it to a live gateway
  when the current one withdraws its beacon.

There is no DNS64: every client runs a CLAT and uses plain IPv6
resolvers, which netif sets.

## Requirements

- netif on every machine. The gateway's public IPv4 link is in the zone
  `uplinkZone` (default `wan`); so is the client's uplink.
- Each gateway's `pool6` (a /96) is routed to it, and each client's
  CLAT address is routed to the client or answered for by proxy NDP
  (`proxyNdp`, on by default).
- One gateway and one CLAT per machine; a machine is not both.

## Example

```nix
inventory.instances.nat64 = {
  module.name = "nat-gateway";
  module.input = "clanServices";
  roles.gateway.machines = {
    gw1.settings = {
      pool6 = "2001:db8:a1:0:64::/96";
      address = "2001:db8:a1::1";
      health.targets = ["1.1.1.1" "8.8.8.8" "9.9.9.9"];
    };
    gw2.settings = {
      pool6 = "2001:db8:a2:0:64::/96";
      address = "2001:db8:a2::1";
      health.targets = ["1.0.0.1" "8.8.4.4" "149.112.112.112"];
    };
  };
  roles.client.machines.node1.settings.clat.address = "2001:db8:c::c1a7";
};
```

A member of a kube cluster is `trusted` by default; set `tier` to
change it.
