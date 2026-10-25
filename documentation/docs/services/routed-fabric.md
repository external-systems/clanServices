# routed-fabric

`routed-fabric` is the flat-L3 clanService for Kubernetes and ordinary
NixOS machines: per-adjacency WireGuard, one FRR routing stack per host,
access/border-based route policy, and fleet route consumption (member DNS
is day-2, D22 amended). It replaces the legacy
`wireguard-mesh` transport and the BIRD-based phase-5 design (round 15,
D51–D55; role model revised round 16, D56).

## Roles and switches

**Two topology roles** (D56); each machine joins exactly one:

- **`member`** — the fabric participant: encrypted dual-stack fabric
  transport, FRR/BFD/Zebra, and automatic native pod routes on Kubernetes
  nodes.
- **`hub`** — a member that also forwards and readvertises between spokes,
  with explicit hub↔hub links; spokes never transit.

Two **orthogonal, composable per-machine switches** layer on top:

- **`access = member | client | admin`** (default `member`) — controls
  route consumption. `client` adds cluster VIP routes; `admin` adds
  pod/ClusterIP routes; kamrui-h1 remains the canonical dual-shape
  example. Member-facing DNS is day-2 (external-dns), not an MVP render.
- **`border`** (optional) — the machine owns upstream transit: upstream
  peers, owned-prefix filtering, forwarding, optional NDP. A border is
  **not automatically a hub**, gets **no automatic admin DNS**, and a hub
  is **not automatically a border**; public endpoints imply neither.
  Each spoke names its hubs per machine (`settings.hubs`); hub membership
  is declared by the `hub` role, not inferred from the union of spoke
  lists.

## Data plane

Every machine has stable loopback `/32` and `/128` addresses. Every
**declared adjacency** — member↔hub, hub↔hub, border↔upstream — gets
exactly one point-to-point WireGuard interface with one peer. This
preserves cryptokey correctness and kernel ECMP across interfaces.
`AllowedIPs` is both outbound peer selection and the inbound source ACL,
and includes the transit prefixes a hub readvertises; FRR filters derive
from the same route policy. External-transit links may list default entries
as a crypto ACL without installing a default route, and Internet-sourced
ingress requires source-policy return. Multiple NAT borders do not share
conntrack state by default, so existing-flow failover requires a separate
state mechanism (D56).

The MVP topology is routed-hub: hubs forward/readvertise, members never
provide spoke transit, one hub minimum and two for HA with no arbitrary
maximum, Kubernetes managers not default hubs, and NAT members work
through the hubs. Full mesh is deferred; there is no iBGP and no route
reflectors — eBGP with `next-hop-self` over each adjacency replaces them.

FRR exchanges eBGP routes per address family, uses BFD on every fabric
path, and installs accepted routes through Zebra. Cilium peers only with
local FRR over `::1`; FRR rewrites its next hop before redistribution, and
native routing forwards remote pod traffic through the kernel FIB.

Node-owned `node-bgp` pools advertise only from their owner (and only when
BGP delivery actually exists). `shared-bgp` pools advertise from every
healthy eligible node and use ECMP. Ordinary clients receive VIPs only;
admin access explicitly receives pod and ClusterIP routes. External BGP
peers and owned prefixes are declared in a machine's optional `border`
attrset, not duplicated in cluster settings.

A host belongs to at most one routed-fabric instance; multiple instances
segment trust domains. The cluster-side reference is
`settings.network.fabric`; selective ClusterMesh peering through
`mesh.peers` is described in
[Multi-cluster](../architecture/multi-cluster.md).

See [Routed fabric architecture](../architecture/routed-fabric.md) and
[Networking](../architecture/networking.md) for the full contract, and
[netif](netif.md) for the underlay links whose `peer` exports provide
endpoints.

## Status

Round-15/16 target, **planned for phases 5R1–5R3** — no implementation or VM
evidence exists for the routed-hub shape yet. The round-15 implementation
is a one-session complete overhaul delivered from
[the implementation prompt](../guides/routed-fabric-mvp-prompt.md):
multi-instance `netif`, `routed-fabric` (routed-hub MVP), native Cilium
and pools on both distros, full and selective ClusterMesh, the
`external-systems/pkgs` native Cilium base re-inflation, and the
clanServices pin update.

The code still in the tree at `services/fleet-routing/` is legacy: the
BIRD/VXLAN checkpoint at `2995ac3` (5 green / 7 red suites) and the
round-14 full-mesh target it follows are both superseded, and it is not
accepted as this service's implementation. It is **deleted outright** once
the `services/routed-fabric/` replacement suites are green — no archiving,
no commented-out remnants; the historical docs record it.
