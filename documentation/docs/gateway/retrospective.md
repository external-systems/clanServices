# Retrospective: what is proven, and what is not

First written on 2026-11-21 after the probe rounds, and updated the
same day after the probes became real suites. The contract is
`specs/gateway.md` §12. This page is the short version.

!!! note "Reviewed on 2026-11-21"
    A hostile review followed this page. It closed points 3, 7 and 8
    of "Still open" below and found more. Read
    [the review](review.md) for the current state.

## What changed since the first version

- **Every probe is now a suite that checks its result.** A change that
  breaks a proven mechanism now fails a test.
- **The suites corrected the design** in five places (below).
- **Both Cilium modes have the same suites** where the mode allows it.
- Fixed waits in `netif-dhcp` and `netif-guard` were replaced by waits
  for the real condition. Both passed three times in a row.

## Where the suites corrected the design

| Topic | What the design said | What the suite showed |
|---|---|---|
| Two WANs | the primary's default route stays in the main table | with DHCP it disappears when the lease ends, and IPv4 is dead. Every WAN needs a default route there |
| Two WANs | nothing about traffic between the two ISPs | without a firewall rule the router forwards from one ISP to the other |
| Two WANs | netif's guard stays green with a WAN down | only while the dead ISP's box still answers. A deploy during an outage would be rolled back |
| Prefix change | the old prefix is retired also across a reboot | only while the router's small state file exists. Without it, devices keep a dead prefix for up to 45 minutes |
| Gateway health | a gateway that loses its IPv4 upstream withdraws one DNS name, and clients move | the CLAT moves. Name lookups stay on the sick gateway |
| VLAN 0 | without the VLAN link the kernel ignores the ISP's tagged frames | it accepts and answers them, but untagged, so the ISP drops the answers |

## Still open

1. **GitHub has no IPv6.** An IPv6-only machine cannot fetch a flake
   input or a `ghcr.io` image without a NAT gateway. The gateways are a
   dependency of every deploy. Never update both at once. A suite now
   fetches by an IPv4-only name with one gateway down.
2. **Jool is a kernel module outside the kernel tree.** `check` now
   fails if the package set marks it broken.
3. A sick gateway keeps answering DNS. **Closed:** it stops its DNS.
4. **A prefix change with lost state** (above). Now it fails fast:
   a device gets an error at once and uses its next address.
5. **netif's guard and a dead WAN** (above).
6. **Large pings through a CLAT get no answer** (over 1232 bytes). TCP
   and UDP are fine.
7. Cluster DNS can sit on one node. **Closed:** one copy per node
   (D70).
8. NodePorts skip the node's firewall. **Closed:** they answer only on
   node addresses (D69).
9. **One public IPv4 address carries about 64,000 connections** per
   protocol. Not measured yet.
10. **Phones, Windows and consoles** are untested. NetworkManager is
    tested and behaves like the kernel.
11. Four claims still come from memory: Windows and DHCP option 108,
    the Nintendo Switch and IPv6, Headscale behind Cloudflare, the X710
    and SFP+ modules.

## Closed

- The CLAT's health check no longer flaps: no move at 30 % packet loss,
  one move after a crash.
- A WAN failover keeps connections that never used the dead WAN.
- Firewall tables: one table per owner. A restart of one owner leaves
  the others unchanged (router and gateway).
- Path MTU discovery works through both translators.
- A prefix of size /56, /60 and /64; two changes in a row.
- Inbound traffic on the backup WAN is refused.

## The two Cilium modes

| What is tested | Routed fabric, native routing | WireGuard mesh, tunnel |
|---|---|---|
| One server, a second node | yes | yes |
| Three servers, one dies | yes | yes |
| LoadBalancer pools, Node IPAM, firewall, a node dies | yes | yes (no BGP delivery: the mode has none) |
| netif renders the underlay | yes | yes |
| ClusterMesh, all three kinds | yes | yes |
| A cluster inside a network mode | yes (k3s) | yes (k3s) |
| IPv6-only network cards | yes | yes |
| Pod IPv4 through a CLAT | yes | yes |

No difference in behaviour was found between the modes in service code.

## Suite hygiene

- New suites use the shared helpers in `tests/suite-lib.nix`: print
  versions first, wait for conditions, dump state on failure.
- A timing is checked against a bound of about three times the
  measured value.
- Run every suite before a merge that touches netif or the shared base.
- Not done yet: a record of which suites needed a second run under
  load, and lifting `FINDING` lines into the run summary (a change in
  the org's test runner).
