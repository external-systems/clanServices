# routed-fabric

`routed-fabric` is the flat-L3 clanService for Kubernetes and ordinary
NixOS machines: per-adjacency WireGuard, one FRR routing stack per host,
access/border-based route policy, and fleet route consumption (member DNS
is day-2, D22 amended). Round 17 (D58–D60) makes it the **native Cilium
profile** and renames its topology roles **`leaf`/`spine`**.

## Roles and switches

**Two topology roles** (D56, renamed D59); each machine joins exactly one:

- **`leaf`** — the fabric participant: encrypted dual-stack fabric
  transport, FRR/BFD/Zebra, and automatic native pod routes on Kubernetes
  nodes.
- **`spine`** — a leaf that also forwards and readvertises between leaves;
  every spine pair is automatically adjacent; leaves never transit.

Two **orthogonal, composable per-machine switches** layer on top:

- **`access = member | client | admin`** (default `member`) — controls
  route consumption; the enum is unchanged by the role rename — it is
  baseline membership, not topology. `client` adds fabric-pool
  LoadBalancer-VIP routes only (explicit private pools; never pods or
  ClusterIPs); `admin` adds pod/ClusterIP routes; Kubernetes nodes install
  pod/VIP routes regardless of access (D49). kamrui-h1 remains the
  canonical dual-shape: single-node k3s + `spine` + `access = "admin"`.
  Member-facing DNS is day-2 (external-dns),
  not an MVP render.
- **`border`** (optional) — the machine owns upstream transit: upstream
  peers, owned-prefix filtering, forwarding, optional NDP. A border is
  **not automatically a spine**, gets **no automatic admin DNS**, and a
  spine is **not automatically a border**; public endpoints imply neither.
  Border is an external route-exchange policy, not automatically a public
  WAN role: it supplies no public addresses, NAT, default route, or general
  fabric transit. A border leaf stays non-transit for ordinary fabric
  routes. Kubernetes leaves can originate private pod/VIP pools without a
  border; use border only when selected prefixes must cross the fabric
  boundary through an upstream router, with real upstream routing and
  source-return policy. Automatic adjacency is instance-scoped: spines in
  different routed-fabric instances never auto-peer. Separate instances
  are hard trust-domain boundaries and need deliberate external routing.

## Topology: the automatic graph (D59)

The adjacency graph is **derived, not mutually listed**: every unordered
spine pair is automatically adjacent; every leaf attaches to **every spine
by default**, and a leaf may declare an explicit spine subset
(`settings.spines` on the machine). **Full spine peering is not full
fabric mesh** — leaves never peer with leaves. Two spines are the HA
default with no arbitrary maximum; there is no iBGP and no route
reflectors — eBGP with `next-hop-self` over each derived adjacency
replaces them.

## Data plane

Every machine has stable loopback `/32` and `/128` addresses. Every
adjacency in the derived graph — leaf↔spine, spine↔spine, border↔upstream
— gets exactly one point-to-point WireGuard interface with one peer. This
preserves cryptokey correctness and kernel ECMP across interfaces.
`AllowedIPs` is both outbound peer selection and the inbound source ACL,
and includes the transit prefixes a spine readvertises; FRR filters derive
from the same route policy. External-transit links may list default entries
as a crypto ACL without installing a default route, and Internet-sourced
ingress requires source-policy return. Multiple NAT borders do not share
conntrack state by default, so existing-flow failover requires a separate
state mechanism (D56).

As the native profile (D58), routed-fabric publishes the generic
`node_transport` export (schemaVersion 2) with `datapath.mode = native`,
`native.routeExchange = local-router`, the allocated host ASN, and the
`internalLoadBalancer` + `nodePort` exposure capabilities; the
provider-specific `routed_fabric` export carries ASN, topology, adjacencies,
ACL, `access`, and `border`.
FRR exchanges eBGP routes per address family, uses BFD on every fabric
path, and installs accepted routes through Zebra. Cilium peers only with
local FRR over `::1`; FRR rewrites its next hop before redistribution, and
native routing forwards remote pod traffic through the kernel FIB.

## Allocation (D64)

Run `clan vars generate <machine>` after adding a machine or adjacency and
before evaluation or deployment. Public, non-deployed vars allocate each
machine's loopback IPv4/IPv6 and ASN, and each adjacency's port and transfer
prefixes. The shared ULA generator creates an RFC 4193 ULA /48 and has no
settings validation, so an IPv4 pool edit cannot re-roll it. A separate
prefix generator records the member-uniform `loopback4Pool` (default
`198.18.0.0/17`) and `transfer4Pool` (default `198.19.0.0/16`). Evaluation
asserts that those records still equal the settings and that every allocated
address or transfer lies inside its pool or ULA `/64`. Loopback IPv6 uses the
ULA's `:0::/64`; transfer IPv6 uses `:1::/64`. The ASN has its own generator,
so repairing an address collision does not reset BGP sessions.

`portRange` defaults to 10000–29999 and must be equal on every member. Custom
ranges must avoid `clanServices.networking.reservedPorts` and, on Kubernetes
members, NodePorts 30000–32767. Explicit `ipv4`, `ipv6`, and
`adjacencies.<remote>.port` settings override allocated values. Evaluation
rejects missing values, fleet-wide duplicate loopbacks/ASNs, same-host
port/transfer collisions, unequal pools, and overlap with member netif
underlay, kube-cluster CIDRs, or another instance/service pool on the host.
A duplicate message names both owners and directs regeneration at the newer
machine:

```console
clan vars generate <newer-machine> --generator <generator> --regenerate
```

For a shared adjacency generator, either endpoint can run that command.
Collisions are possible at initial random allocation; regeneration fixes them
once and the committed values then stay stable. Regenerating the ULA is an
instance-wide IPv6 loopback and transfer renumber, not an IPv4 pool remedy.
Renaming a machine creates a new clan identity with new allocations; no
migration shim preserves the old identity.

Remove orphaned shared adjacency vars after confirming that their adjacency
is no longer present in the inventory. Each network-facts adjacency exports
its `generator`; collect those names from every fabric member into
`expected-adjacencies`, one per line, then review this command's output before
deleting anything:

```console
comm -23 \
  <(find vars/shared -mindepth 1 -maxdepth 1 -type d \
      -name 'routed-fabric-*-adj-*' -printf '%f\n' | sort) \
  <(sort expected-adjacencies)
```

Interface names, FRR symbols, and per-adjacency link-local addresses remain
hash-derived by design; they are names, not clan-vars allocations.

D63 makes convergence deliberately stable. Equal `settings.site` values use
the `site` profile (BFD 300 ms x3); different sites use `wan` (BFD 1000 ms
x5 plus BGP keepalive/hold 10/30 seconds). Set
`adjacencies.<remote>.timerProfile = "site" | "wan"` to override the
default; conflicting two-sided overrides fail eval. Border upstreams always
use `wan`. Both ends and upstreams use a five-second FRR DelayOpen fixed
hold-down before a recovered session establishes; this is not exponential
flap damping. Every maximum-prefix limit restarts the session after ten
minutes. Plain `bfd` accompanies each profile, site defaults stay implicit,
and `use-underlays-nexthop-weight` is explicit, so an unchanged reload has
an empty dry-run diff and preserves peer uptimes and the immediate RIB.
TCP 179 and UDP 3784/4784 are opened only on fabric WireGuard interfaces and
from declared literal upstream peer addresses, never globally. Every
WireGuard listen port is unique and reserved in
`net.ipv4.ip_local_reserved_ports`; additional ports or ranges can be added
through `clanServices.networking.reservedPorts`. The shared IfState module
has a stable key, so importing it through several networking services is safe.

Declared literal endpoints on an adjacency must share an address family;
hostname endpoints produce an eval warning because evaluation does not
resolve DNS. Full per-host underlay-family reachability is phase-5 work.
Source-return tables never use `{0,200,201,253,254,255,2004,2005}` or
collide with same-host netif/source-return tables. Their independent rule
priorities stay below 32766 and unique across fabric and netif rules.
`adjacencies.<remote>.sourceReturnTable` and `sourceReturnPriority` pin
explicit non-conflicting values when derived values are unsuitable.

Node-owned `node-bgp` pools advertise only from their owner (and only when
BGP delivery actually exists). `shared-bgp` pools advertise from every
healthy eligible node and use ECMP. Ordinary clients receive
fabric-pool LoadBalancer VIPs only; admin access explicitly receives pod
and ClusterIP routes. External BGP
peers and owned prefixes are declared in a machine's optional `border`
attrset, not duplicated in cluster settings.

A host belongs to at most one routed-fabric instance; multiple instances
segment trust domains. The cluster-side reference is
`settings.network.fabric`; selective ClusterMesh peering through
`mesh.peers` and the round-17 exposure profiles are described in
[Multi-cluster](../architecture/multi-cluster.md).

See [Routed fabric architecture](../architecture/routed-fabric.md) and
[Networking](../architecture/networking.md) for the full contract, and
[netif](netif.md) for the underlay links whose `peer` exports provide
endpoints.

## Status

The `leaf`/`spine` topology (D59), generic `node_transport` schemaVersion 2
(D58), and D60 ClusterMesh contract are implemented and VM-proven. IfState
owns the loopback, per-adjacency WireGuard links, static routes/rules, and
forwarding sysctls; FRR/Zebra owns dynamic routes. The hermetic
two-spine/three-leaf suite passes handshakes, RIB/FIB, MTU, and HA
failure/restore. The native data-plane and ClusterMesh matrices pass for
both distros. The earlier implementation was delivered from
[the implementation prompt](../guides/routed-fabric-mvp-prompt.md)
(historical: written for the round-16 `member`/`hub` role names, renamed
`leaf`/`spine` by D59).

The legacy `services/fleet-routing/` tree and its BIRD/VXLAN checkpoint at
`2995ac3` (5 green / 7 red suites) were never accepted as this service's
implementation. The obsolete tree, BIRD helpers, and BIRD-specific fixtures
were deleted in the round-17 cleanup — no archiving or commented-out
remnants; the historical docs record them.
