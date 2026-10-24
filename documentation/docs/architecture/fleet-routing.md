# Fleet routing

`fleet-routing` is the flat-L3 trust-domain clanService for Kubernetes and
ordinary NixOS machines. It owns per-pair WireGuard, FRR/BFD, Zebra route
installation, role-based route policy, and fleet DNS consumption. BIRD and
the old ordinary-mesh-plus-auxiliary-interface design are superseded.

## Roles

- **`member`** — stable dual-stack loopback addresses, one WireGuard
  interface per remote member, FRR/BFD/Zebra. A Kubernetes member also
  exchanges the pod routes required by native routing.
- **`client`** — member plus cluster VIP routes and the
  `<instance>.<meta.domain>` DNS stub. This is the ordinary service-access
  profile; it receives no pod or ClusterIP routes.
- **`admin`** — client plus explicit pod/ClusterIP route consumption and
  the svc/pod DNS zones. This is the developer/admin profile.
- **`router`** — member plus upstream BGP peers, owned-prefix filtering,
  forwarding, and optional proxy-NDP. Edge proxies on a router are separate
  operator NixOS modules, not part of fleet-routing.

A machine joins at most one fleet-routing instance and holds one role in
it. One mesh group maps to one instance. A machine may simultaneously be a
Kubernetes node and hold a fleet role; local Cilium and the fabric share
the same FRR instance.

## Per-pair routed WireGuard

Every machine has stable `/32` and `/128` transport addresses on a fabric
loopback/dummy interface. Every remote machine gets exactly one
point-to-point WireGuard interface with one peer and deterministic
transfer addresses. Names are unique, instance/peer-derived, and at most
15 characters.

One session per pair avoids the legacy endpoint-roaming problem caused by
running an ordinary mesh and extra routed sockets with the same identity.
It also gives each ECMP member a separate cryptokey table. Shared VIPs can
therefore resolve through several interfaces, while node-bgp VIPs resolve
only through their owner.

`AllowedIPs` are derived from the same policy as FRR prefix filters:
remote stable host addresses, shared VIPs, owner-only node VIPs, and
role-appropriate pod/Service prefixes. No default route is permitted.
Missing reachable endpoints on both sides of a pair fail evaluation.
NAT/outbound-only members dial reachable members with persistent
keepalive.

## FRR and route ownership

Each node has a deterministic unique private ASN and runs eBGP to every
other node, separately for IPv4 and IPv6. BFD monitors each path. Strict
inbound/outbound filters and maximum-prefix limits are mandatory.
`maximum-paths` and multipath-relax retain shared-VIP ECMP.

A cluster's Cilium agents peer only with local FRR over `::1`. FRR
rewrites the loopback next hop to the node's stable transport address and
redistributes only approved routes. Zebra installs remote pod and Service
routes into the kernel. Cilium agents never peer with one another.

Cluster-side `bgp.upstreamPeers` is gone. External peers belong to the
`router` role in inventory; cluster and fabric exports provide the facts
needed to render both sides without duplicating addresses.

## Native Kubernetes and node duality

Cilium uses native routing and multi-pool IPAM. It always advertises local
pod-pool allocations to local FRR. Kubernetes members automatically consume
remote pod routes; this is not the non-Kubernetes admin opt-in.

The canonical dual-role shape is **kamrui-h1**: a single-node k3s spoke and
an admin-role fleet member. Its local pods remain local Cilium endpoints;
routes to foreign clusters and authorized Service addresses come from FRR.
ClusterMesh additionally requires native routing in every cluster,
non-overlapping pod CIDRs, and mesh-wide native-routing CIDRs.

## Private-domain zones

`cluster.local` is pinned and never served to fleet clients.

- The instance zone `<instance>.<meta.domain>` is the client default. Its
  wildcard target is the operator's day-2 proxy.
- The service zone `<instance>.svc.<meta.domain>` rewrites to
  `<name>.<ns>.svc.cluster.local` with answer-name reversal. ClusterIPs
  require admin route consumption; private-pool LB VIPs already have
  routes.
- The pod zone uses CoreDNS `pods insecure` and dash-form rewrites, and is
  default-on for admin.

Route-only DNS stubs use global systemd-resolved settings so queries
follow the kernel's per-member ECMP routes.

## Acceptance

Evaluation proves deterministic names and transfer prefixes, one peer per
interface, AllowedIP/filter equivalence, role policy, self-exclusion, NAT
viability, and collision detection.

Hermetic VMs prove real handshakes, FRR sessions and BFD on both sides,
RIB-to-FIB installation, native pod round trips, shared-VIP dual-stack
ECMP and withdrawal, node-bgp owner-only advertisement, client VIP-only
isolation, admin pod/Service/DNS access, router filtering, and the
kamrui-h1 dual-role shape.
