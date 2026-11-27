# Target design for networking and Kubernetes

Decided by the owner on 2026-11-27 as the direction. **Not implemented
yet.** The agent contract is `specs/target-design.md` and the four
`specs/design-*.md` files.

## Why

A review put an attacker VM beside each service. It found gaps:

- A spine forwarded traffic from the underlay into the fabric.
- A host on the node LAN could reach a pod.
- A pod could reach BGP on other nodes.
- One packet could loop 32 times through a NAT64 gateway or a CLAT.
- Hosts accepted ICMP redirects.

The router service had no gap.

The cause was the same each time. The stack named what is bad and
trusted the underlay for the rest. The target design names what is
allowed.

## The design in four lines

| Area | Rule |
|---|---|
| routed-fabric | A link carries a packet only if BGP may carry its route. One contract per link feeds FRR, WireGuard and the firewall |
| k3s and rke2 | The node says what may come in. Pods refuse the outside unless they are labelled. NodePorts answer by source |
| gateways | Policy is checked before translation. Inside the translator, anything that was not translated is dropped |
| netif | One program applies, checks and rolls back. DHCP and router advertisements are untrusted input |

## What changes for a user

- Router advertisements are off unless a link says `ra = true`.
- DHCP classless routes are ignored unless a link opts in.
- A router zone reaches the fabric only with `fabric = true`.
- NodePorts answer cluster members only, unless other sources are listed.
- Manual-address clusters go away. A cluster needs a fabric.
- A deploy whose new network does not work stays on the last good one.

## What is still open

The owner decides eight points. They are listed in
`specs/target-design.md` §4. The largest:

- transit tunnels as their own link type;
- how NodePorts are guarded (custom eBPF or an admission policy);
- the remote-builder redesign, which needs a change in the `home` repo.

## How it gets built

In waves, one PR per step:

1. The hostile suites, with the small fixes that make them pass.
2. Probes for the behaviour the designs assume.
3. The structural steps of each area.
4. The large steps (the netif transaction, cluster founding, transit).
5. Optional and owner-gated steps.

Until the design is frozen, tests prove behaviour and may be rewritten
(see [Testing](../reference/testing.md)).
