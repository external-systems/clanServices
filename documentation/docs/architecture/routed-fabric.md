# Routed fabric

`routed-fabric` is the flat-L3 trust-domain clanService for Kubernetes and
ordinary NixOS machines. It owns per-adjacency WireGuard,
FRR/BFD/Zebra routing, access/border route policy, and fleet route
consumption (member-facing DNS is day-2, D22 amended 2026-10-25). Round 17
(D58–D60) makes it the **native Cilium profile**: it publishes the generic
`node_transport` export (schemaVersion 2) with `datapath.mode = native`,
`native.routeExchange = local-router`, and the `internalLoadBalancer` and
`nodePort` exposure capabilities, and its topology roles are **`leaf`/`spine`**
(renamed from round 16's `member`/`hub`, D59). The BIRD/VXLAN design and the
round-14 full-mesh target are superseded; the legacy
`services/fleet-routing/` tree was deleted in the round-17 cleanup.

> **Status.** The `leaf`/`spine` graph, generic `node_transport` schema,
> and D60 ClusterMesh contract are implemented and VM-proven. IfState
> exclusively renders the static host configuration and applies changes
> live; FRR/Zebra retains dynamic route ownership (D61).

## Two topology roles, orthogonal access and border

The service has **two topology roles**; every machine joins exactly one
(D56, renamed D59):

- **`leaf`** — the fabric participant: encrypted dual-stack fabric
  transport, FRR/BFD/Zebra, and (on Kubernetes nodes) automatic native pod
  routes.
- **`spine`** — a leaf that also forwards and readvertises between leaves;
  every spine pair is automatically adjacent (see below). Leaves never
  transit.

What a machine may **consume** is a separate, orthogonal per-machine
switch, `access` (D56; default `member`) — the enum values are unchanged by
the round-17 role rename; `access` expresses baseline membership, not
topology:

- **`access = member`** (default) — fabric membership plus automatic
  native pod routes on Kubernetes nodes.
- **`access = client`** — member plus routes to fabric-pool
  LoadBalancer VIPs only: exact /32+/128 advertisements for Services of
  type LoadBalancer that drew from an explicit private BGP pool. No pod
  or ClusterIP routes, ever.
- **`access = admin`** — client plus explicit pod/ClusterIP route
  consumption: every advertised pod-pool allocation block and authorized
  ClusterIP CIDR. The developer/admin profile; DNS for those IPs is
  day-2 (external-dns), not a fabric render.

Whether a machine speaks to the **outside** is a second orthogonal,
optional per-machine switch, `border` (D56): upstream BGP peers,
owned-prefix filtering, forwarding, optional NDP (proxy-NDP), and
authorized external/fabric transit. A border gets **no automatic admin
DNS** — access still governs consumption.

Topology, access, and border are fully orthogonal and composable: **a
border need not be a spine, and a spine need not be a border**. Public
endpoints do not imply either. The round-15 `router` role is
retired — upstream transit is the `border` switch, spine placement is the
`spine` role, and neither implies the other. Edge proxies on a border remain
separate operator NixOS modules, never part of routed-fabric.

A border is an **external route-exchange policy**, not automatically a
public-WAN designation. It does not supply public addresses, NAT, a default
route, member DNS, or general fabric transit. A border leaf still never
readvertises ordinary fabric routes; only its explicitly authorized
upstream policy is added. A Kubernetes leaf can originate private pod
pools and Service VIPs without any border. Add border configuration only
when selected prefixes must cross the fabric boundary through an upstream
router. Public reachability additionally requires real upstream routing and
correct source-return policy; `border` alone cannot make private addresses
publicly reachable.

Automatic adjacency is **instance-scoped**. Spines in different
routed-fabric instances never auto-peer, even when an operator informally
calls them one domain. Separate instances are hard trust-domain boundaries;
connecting them requires deliberate external routing through border and
upstream policy, not another automatic fabric graph.

Keep the terms apart: a **fabric spine** forwards/readvertises fabric
traffic; a **border** owns upstream/external transit; a **default gateway**
is ordinary host routing (DHCP/RA addressing is a separate concern, owned
by `netif`); **Kubernetes Gateway API** is a day-2 in-cluster ingress
concern that clan never renders (D1/D2).

A host joins **at most one** routed-fabric instance (D53). Multiple
routed-fabric instances are how a fleet segments trust domains — one
membership per host, and cross-cluster reachability never spans fabrics.
The fabric a cluster joins supplies its mesh group (D54); see
[Multi-cluster](multi-cluster.md).

## Spine/leaf topology: the automatic graph

The supported topology is **spine/leaf** (D59, superseding the routed-hub
MVP): the adjacency graph is **derived, not mutually listed**.

- Every **unordered spine pair** is automatically adjacent — spine peering
  needs no declaration at all.
- Every **leaf attaches to every spine by default**; a leaf may instead
  declare an explicit spine subset (`settings.spines` on the machine).
- The graph is derived **symmetrically**: a leaf's spine subset selects its
  adjacencies; there are **no mutual lists** anywhere (the round-16
  hub-mutual-listing shape is gone).
- **Full spine peering is not full fabric mesh** — leaves never peer with
  leaves, so even with every spine pair adjacent the fabric stays a
  two-level graph.

Two spines are the HA default, and there is **no arbitrary maximum of
two** — more than two spines is a legal, explicit operator tradeoff, not a
violation. Kubernetes managers are not default spines; only the `spine`
role fills a spine slot. Two NAT sites both work through the spines; spines
forward and readvertise between leaves, **leaves never provide transit**.
An all-spine fabric is still not a leaf-meshing topology; leaves never peer.

Each fabric machine has stable dual-stack `/32` and `/128` addresses on a
fabric loopback/dummy interface — the node InternalIPs, FRR router ID, and
API/HAProxy transport addresses. For **every adjacency in the derived
graph** (leaf↔spine, spine↔spine, border↔upstream) routed-fabric renders
exactly one point-to-point WireGuard interface with one peer and a
deterministic instance/peer-derived name of at most 15 characters. There is
no multi-peer interface and no second set of auxiliary routed interfaces.

This shape is required by WireGuard's cryptokey routing (D51): `AllowedIPs`
selects the peer inside one interface, so overlapping entries across two
peers on that interface cannot provide ECMP. The same prefixes on
*different* one-peer interfaces are valid; Linux ECMP then selects an
interface per flow.

## eBGP + BFD + Zebra, no iBGP

Every fabric machine runs one integrated `services.frr` configuration
rendered atomically from inventory. Adjacencies use eBGP with BFD, one
session per address family, `next-hop-self` on spine readvertisement, and
**no iBGP and no route reflectors** (D51) — the spine topology plus eBGP
replaces them. Policy is mandatory: `bgp ebgp-requires-policy`, explicit
address-family activation, prefix-lists/route-maps, and maximum-prefix
limits. `maximum-paths` and `bgp bestpath as-path multipath-relax` preserve
shared-VIP and dual-spine ECMP. Zebra installs accepted routes into the
kernel FIB.

Cilium has no BFD in 1.20, so its local session uses 3-second keepalive,
9-second hold, 5-second connect retry, dialing only local FRR at `::1`
without `localPort`. FRR enables reserved-range and martian-next-hop
handling and rewrites the loopback next hop to the node's stable transport
address before redistribution. Cluster-side `bgp.upstreamPeers` is gone:
external peers belong in the machine's optional `border` attrset; fabric
and cluster exports provide the facts to render both sides without
duplicating addresses.

## AllowedIPs: crypto ACL and route policy together

`AllowedIPs` is simultaneously **outbound peer selection and an inbound
source ACL** (D51). Every interface admits exactly what policy authorizes —
remote stable host addresses, shared VIPs, owner-only node VIPs,
role-appropriate pod/Service prefixes — **plus the transit prefixes the
peer is allowed to carry through this machine**. A spine's leaf-facing
interfaces must include the other leaves' prefixes, or readvertised traffic
is dropped by cryptokey routing even though BGP accepted it. FRR filters
render from the same resolved policy, so cryptokey and routing state cannot
drift.

Two consequences:

- **External-transit links may carry default entries as a crypto ACL**
  without installing a default route. The `0.0.0.0/0` / `::/0` entries
  authorize inbound transit traffic; whether the kernel default-routes
  through the fabric is a separate, explicit decision.
- **Internet ingress needs source-policy return.** A machine reached from
  the Internet via the fabric must answer out the same fabric egress;
  routed-fabric renders the policy-routing rules that make return traffic
  follow the correct adjacency instead of the host default route. **NAT
  borders have no automatic conntrack sharing**: existing-flow failover
  requires a separate state mechanism; new flows take whichever border
  policy selects (D56).

Transport correctness is per adjacency (D51): every pair of endpoints must
have at least one actually reachable side — private endpoints are fine when
they are reachable. NAT/outbound-only leaves omit an endpoint and dial
reachable spines with a 25-second keepalive. MTU derives from the underlay
link export; native Cilium uses the WireGuard MTU directly (no VXLAN
50-byte budget — that belongs to the wireguard-mesh tunnel profile, D58).
Per-adjacency reachability is evaluated before peering is advertised.

## Active-active spines

Two spines give fabric participants active-active forwarding via BFD/ECMP:
both spines advertise the same prefixes, leaves install both paths, and BFD
withdraws a failed spine's paths. **Upstream** active-active additionally
requires the upstream side to ECMP (two BGP sessions, one per spine) — the
fabric cannot unilaterally make a single upstream path active-active.
Transparent active-active default gateway for ordinary non-fabric LAN
clients is **out of MVP**: it requires either client-side routing or an
L2/VRRP-like mechanism, and neither is rendered by routed-fabric (D51).

## Route consumption (member DNS is day-2)

The per-machine `access` switch governs consumption (D56): `member`
(default) provides fabric transport and automatic native pod routes on
Kubernetes nodes. `client` adds fabric-pool LoadBalancer-VIP routes only —
exact /32+/128 advertisements for Services that drew from an explicit
private pool; never pod blocks, never ClusterIP CIDRs. `admin` adds
explicit pod/ClusterIP route consumption: every advertised pod-pool
allocation block plus authorized ClusterIP CIDRs. Kubernetes nodes always
install remote pod-pool blocks and advertised VIPs regardless of `access`
— Cilium native routing delegates non-local pod traffic to the kernel FIB
(D49); ClusterIPs stay eBPF-local to each node and are never routed there.
Ordinary clients never receive pod or ClusterIP routes, and `cluster.local`
is never served to them. `border` changes what a machine may originate
and transit — never what it automatically gets to consume.

Member-facing DNS is NOT part of the MVP (D22 amended 2026-10-25): the
fabric and the bootstrap bundle render no cluster DNS zones for members,
no private DNS service, and no private/member-facing CoreDNS VIP — the
`<instance>-fabric` pool carries the pinned ClusterMesh apiserver VIP.
Mirror-Service VIPs are allocated separately and cannot share it.
Admin machines reach pod and Service IPs over their routes and resolve
cluster names day-2 through Kubernetes-side automation such as
external-dns. In-cluster DNS is unchanged — the clan CoreDNS serves
`cluster.local` inside every cluster (D46).

The private-domain zones remain the day-2 target contract only: the
instance zone `<instance>.<meta.domain>` (wildcard target is the
operator's day-2 proxy), the service zone
`<instance>.svc.<meta.domain>` with answer-name
reversal, and the pod zone (`pods insecure`, dash-form rewrites, admin
default-on). None of them is clan-rendered in the MVP.

## The native Cilium profile (D58)

As the native profile provider, routed-fabric publishes the generic
`node_transport` export (schemaVersion 2) for both distro services:
stable dual-stack node addresses/instance/endpoint, datapath interfaces
keyed by Linux name with MTU, one `directRoutingDevice`,
`datapath.mode = native` with sibling `datapath.tunnelProtocol`,
`native.routeExchange = local-router`
(daemon-neutral), and the `internalLoadBalancer` + `nodePort` exposure
capabilities. Its provider-specific `routed_fabric` export carries the
ASN, topology, adjacencies, ACL, `access`, and `border` facts. Distro
services never branch on service names — they see only `node_transport`.
`cilium.helmValues` cannot contradict the derived mode, protocol, devices,
`directRoutingDevice`, MTU, or exposure. See
[Networking](networking.md) for the tunnel/VXLAN wireguard-mesh profile
and [Multi-cluster](multi-cluster.md) for what the mesh requires of each
profile.

## Relationship to netif and alternatives

`routed-fabric` consumes `peer` endpoint exports from `netif` (or another
underlay service) and owns **fabric policy routing** — never netif.
The official `mycelium`, `yggdrasil`, and `wireguard` meshes are
**alternative overlays, not underlays**: they cannot provide the routed,
filtered, ACL'd transit the fabric needs. The useful seam for any transport
is the standard `peer` export set; that is what alternative overlays would
have to speak.

## Inventory example

```nix
inventory.instances.fabric = {
  module.input = "clanServices";
  module.name = "routed-fabric";
  # no instance-level topology settings: the graph is derived from the
  # spine role plus each leaf's optional explicit spine subset
  roles = {
    # spine slot + upstream transit: spine role + border (neither implies
    # the other); every spine pair is automatically adjacent
    spine.machines.hel-spine-1.settings = {
      border.ownedPrefixes = [ "203.0.113.0/24" "2001:db8:100::/48" ];
      endpointSources = [
        { service = "netif"; instance = "uplink-a"; }
      ];
    };
    # the canonical kamrui-h1 dual-shape: a single-node k3s cluster holding
    # the SPINE topology role with access = "admin"
    spine.machines.kamrui-h1.settings = {
      access = "admin";
      endpointSources = [
        { service = "netif"; instance = "home-net"; }
      ];
    };
    # NAT site, client access: no reachable public endpoint; dials the
    # spines (default: all spines — no explicit subset needed)
    leaf.machines.site-b-client.settings.access = "client";
    # upstream-only border: transit to the ISP, not a spine, no special
    # access; explicit spine subset is allowed but defaults to all spines
    leaf.machines.edge-2.settings = {
      border.ownedPrefixes = [ "203.0.113.0/24" "2001:db8:100::/48" ];
    };
  };
};
```

The graph derives symmetrically: the two spines (`hel-spine-1` and
`kamrui-h1`) are automatically adjacent, and every leaf attaches to both
spines by default. A leaf with an explicit
`settings.spines = [ "hel-spine-1" ];` narrows its adjacency to that
subset. There are no mutual lists — a spine never lists the other spines,
and leaves do not make spines reachable by naming them in two places. Every
leaf needs at least one reachable spine; two spines are the HA default,
more an explicit tradeoff. The switches compose orthogonally:
`kamrui-h1` is the canonical dual-shape — a single-node k3s cluster that
holds the `spine` topology role with `access = "admin"` — while `edge-2`
is a border without being a spine or gaining admin DNS.

Clusters reference the fabric through `network.fabric`; see
[Multi-cluster](multi-cluster.md) for the `mesh.peers` selective-peering
shape and the three-graph model.

## Acceptance

Evaluation must prove deterministic names and transfer prefixes, one peer
per interface, AllowedIP/filter equivalence including transit prefixes,
access/border policy, self-exclusion, spine reachability (≥1 reachable
spine per leaf), NAT viability through spines, leaf-non-transit filtering,
and collision detection.

Hermetic VMs prove real handshakes, FRR sessions and BFD on both sides,
RIB-to-FIB installation, spine readvertisement, native pod round trips,
shared-VIP dual-stack ECMP and withdrawal across two spines,
**spine/leaf HA ECMP failure and restore**, **FRR reload/restart with a
stable RIB/FIB**, node-bgp owner-only advertisement, client VIP-only
isolation, admin pod/Service route access, no member-facing cluster DNS in
the MVP, border upstream filtering, and spine/border/access orthogonality.
The IfState base also proves live convergence without reboot (D61).
