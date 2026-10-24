# routed-fabric

`routed-fabric` is the flat-L3 clanService for Kubernetes and ordinary
NixOS machines: per-adjacency WireGuard, one FRR routing stack per host,
role-based route policy, and fleet DNS consumption. It replaces the legacy
`wireguard-mesh` transport and the BIRD-based phase-5 design (round 15,
D51–D55).

## Roles

Four canonical roles; each machine joins exactly one. There is no default
role and no per-machine access setting:

- **`member`** — the base role: encrypted dual-stack fabric transport,
  FRR/BFD/Zebra, and automatic native pod routes on Kubernetes nodes.
- **`client`** — member plus cluster VIP routes and the instance-zone DNS
  stub.
- **`admin`** — client plus explicit pod/ClusterIP routes and svc/pod DNS
  zones; kamrui-h1 remains the canonical dual-shape example.
- **`router`** — member plus authorized external/upstream transit (upstream
  peers, owned-prefix filtering, forwarding, optional proxy-NDP). A router
  is not automatically a hub: each spoke declares its hubs per machine
  (`settings.hubs`), and hub membership — the union of the spokes' lists —
  is orthogonal to the roles.

## Data plane

Every machine has stable loopback `/32` and `/128` addresses. Every
**declared adjacency** — hub↔spoke, hub↔hub, router↔upstream — gets
exactly one point-to-point WireGuard interface with one peer. This
preserves cryptokey correctness and kernel ECMP across interfaces.
`AllowedIPs` is both outbound peer selection and the inbound source ACL,
and includes the transit prefixes a hub readvertises; FRR filters derive
from the same route policy. External-transit links may list default entries
as a crypto ACL without installing a default route.

The MVP topology is routed-hub: hubs forward/readvertise, spokes never
transit, one hub minimum and two for HA, Kubernetes managers not default
hubs, and NAT spokes work through the hubs. Full mesh is deferred; there is
no iBGP and no route reflectors — eBGP with `next-hop-self` over each
adjacency replaces them.

FRR exchanges eBGP routes per address family, uses BFD on every fabric
path, and installs accepted routes through Zebra. Cilium peers only with
local FRR over `::1`; FRR rewrites its next hop before redistribution, and
native routing forwards remote pod traffic through the kernel FIB.

Node-owned `node-bgp` pools advertise only from their owner (and only when
BGP delivery actually exists). `shared-bgp` pools advertise from every
healthy eligible node and use ECMP. Ordinary clients receive VIPs only;
admin explicitly receives pod and ClusterIP routes. External BGP peers are
declared by machines in the `router` role, not duplicated in cluster
settings.

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

Round-15 target, **planned for phases 5R1–5R3** — no implementation or VM
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
