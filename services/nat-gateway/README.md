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
  when the current one's beacon has been gone for 60 s.

A machine with its own IPv4 needs no role. A gateway may be a
Kubernetes node; it is never a client (`specs/gateway.md` §14.5).

There is no DNS64: every client runs a CLAT and uses plain IPv6
resolvers, which netif sets.

## Stability over speed

- A gateway withdraws its beacon when half of the last 60 s were bad
  (fewer than two targets answered), and brings it back only after 120
  clean seconds.
- A client moves after 60 s without its gateway's beacon, only to a
  beacon that answered 5 of the last 10 rounds, and never moves back on
  its own. A round in which no beacon answers does not restart the
  60 s.
- A beacon is believed only when it names its own gateway's `pool6`.
  Any other answer counts as silence.

## What the gateway refuses

- A source that is no client: every protocol, and the beacon.
- A destination that embeds a private IPv4 address.
- A destination that embeds one of the gateway's own IPv4 addresses:
  the translator is no way into the gateway itself.

## Changing `pool6` or a CLAT address

The next start of the unit applies it. On a gateway the translator is
made again, which ends the flows through it; clients follow after 60 s.

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

## Rate limits

Defaults per source /64: `default` 50 new flows/s (burst 200) and
20 000 packets/s (burst 40 000); `trusted` 200 (4 000) and 200 000
(400 000). The `trusted` new-flow rate keeps one source from filling
the gateway's one `pool4` address within Jool's 5 minute UDP timeout. Override them for the whole instance
(`roles.gateway.settings.limits`), for one gateway (its machine
settings), or for one client (`roles.client.machines.<m>.settings.limits`,
any of `newFlows`, `newFlowsBurst`, `packets`, `packetsBurst`).
