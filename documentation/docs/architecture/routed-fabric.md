# Routed fabric

`routed-fabric` is the flat-L3 trust-domain clanService for Kubernetes and
ordinary NixOS machines (round 15, D51; the round-14 `fleet-routing` name and
full-mesh topology are superseded). It owns per-adjacency WireGuard,
FRR/BFD/Zebra routing, role-based route policy, and fleet DNS consumption.
The BIRD/VXLAN design and the legacy `wireguard-mesh` are superseded; the
existing `services/fleet-routing/` code is legacy and is not the
round-15 implementation.

## Four canonical roles

The service has four roles; every member machine joins exactly one. There
is no default role and no per-machine access switch — the role is the
membership:

- **`member`** — the base role: fabric transport plus automatic native
  Kubernetes pod routes on cluster nodes. The ordinary participant
  profile.
- **`client`** — member plus cluster VIP routes and the
  `<instance>.<meta.domain>` DNS stub. No pod or ClusterIP routes.
- **`admin`** — client plus explicit pod/ClusterIP route consumption and
  the svc/pod DNS zones. The developer/admin profile.
- **`router`** — member plus authorized external/upstream transit:
  upstream BGP peers, owned-prefix filtering, forwarding, and optional
  proxy-NDP. A router is **not necessarily a hub**.

**Hub is topology, not role.** Each spoke declares its hub list on the
machine: `roles.<role>.machines.<name>.settings.hubs = [ ... ]`. A machine
is a hub when it appears in the **union** of all spokes' lists. Hub
placement is orthogonal to the four roles (D52): any role can fill a hub
slot, and the `router` role does not imply hub membership.
Edge proxies on a router remain separate operator NixOS modules, never part
of routed-fabric.

A host joins **at most one** routed-fabric instance (D53). Multiple
routed-fabric instances are how a fleet segments trust domains — one
membership per host, and cross-cluster reachability never spans fabrics.
The fabric a cluster joins supplies its mesh group (D54); see
[Multi-cluster](multi-cluster.md).

## Routed-hub topology: the MVP

Round 15's supported topology is **routed-hub**: every spoke declares
adjacency to the fabric's hubs; full mesh is deferred (D51). One hub is the
minimum, **two hubs are the HA default**, and Kubernetes managers are not
default hubs — hubs are (usually dedicated) routers, and a machine of any
role can fill a hub slot. Two NAT sites both work through the
hubs; hubs forward and readvertise between spokes, **spokes never
transit**.

Each fabric member has stable dual-stack `/32` and `/128` addresses on a
fabric loopback/dummy interface — the node InternalIPs, FRR router ID, and
API/HAProxy transport addresses. For **every declared adjacency**
(hub↔spoke, hub↔hub, router↔upstream) routed-fabric renders exactly one
point-to-point WireGuard interface with one peer and a
deterministic instance/peer-derived name of at most 15 characters. There is
no multi-peer interface and no second set of auxiliary routed interfaces.

This shape is required by WireGuard's cryptokey routing (D51): `AllowedIPs`
selects the peer inside one interface, so overlapping entries across two
peers on that interface cannot provide ECMP. The same prefixes on
*different* one-peer interfaces are valid; Linux ECMP then selects an
interface per flow.

## eBGP + BFD + Zebra, no iBGP

Every member runs one integrated `services.frr` configuration rendered
atomically from inventory. Adjacencies use eBGP with BFD, one session per
address family, `next-hop-self` on hub readvertisement, and **no iBGP and
no route reflectors** (D51) — the hub topology plus eBGP replaces them.
Policy is mandatory: `bgp ebgp-requires-policy`, explicit address-family
activation, prefix-lists/route-maps, and maximum-prefix limits.
`maximum-paths` and `bgp bestpath as-path multipath-relax` preserve
shared-VIP and dual-hub ECMP. Zebra installs accepted routes into the
kernel FIB.

Cilium has no BFD in 1.20, so its local session uses 3-second keepalive,
9-second hold, 5-second connect retry, dialing only local FRR at `::1`
without `localPort`. FRR enables reserved-range and martian-next-hop
handling and rewrites the loopback next hop to the node's stable transport
address before redistribution. Cluster-side `bgp.upstreamPeers` is gone:
external peers belong to machines in the `router` role; fabric and
cluster exports provide the facts to render both sides without duplicating
addresses.

## AllowedIPs: crypto ACL and route policy together

`AllowedIPs` is simultaneously **outbound peer selection and an inbound
source ACL** (D51). Every interface admits exactly what policy authorizes —
remote stable host addresses, shared VIPs, owner-only node VIPs,
role-appropriate pod/Service prefixes — **plus the transit prefixes the
peer is allowed to carry through this machine**. A hub's spoke-facing
interfaces must include the other spokes' prefixes, or readvertised traffic
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
  follow the correct adjacency instead of the host default route.

Transport correctness is per adjacency (D51): every pair of endpoints must
have at least one actually reachable side — private endpoints are fine when
they are reachable. NAT/outbound-only spokes omit an endpoint and dial
reachable hubs with a 25-second keepalive. MTU derives from the underlay
link export; native Cilium uses the WireGuard MTU directly (no VXLAN
50-byte budget). Per-adjacency reachability is evaluated before peering is
advertised.

## Active-active hubs

Two hubs give fabric participants active-active forwarding via BFD/ECMP:
both hubs advertise the same prefixes, spokes install both paths, and BFD
withdraws a failed hub's paths. **Upstream** active-active additionally
requires the upstream side to ECMP (two BGP sessions, one per hub) — the
fabric cannot unilaterally make a single upstream path active-active.
Transparent active-active default gateway for ordinary non-fabric LAN
clients is **out of MVP**: it requires either client-side routing or an
L2/VRRP-like mechanism, and neither is rendered by routed-fabric (D51).

## Route consumption and DNS

`member` provides fabric transport and automatic native pod routes on
Kubernetes nodes. `client` adds VIP routes and the instance-zone DNS stub.
`admin` adds explicit pod/ClusterIP consumption and the svc/pod zones.
Ordinary clients never receive pod or ClusterIP routes, and `cluster.local`
is never served to them. Route-only DNS uses global systemd-resolved
settings so queries follow the kernel's ECMP routes.

The private-domain zones are unchanged from round 14: the instance zone
`<instance>.<meta.domain>` (wildcard target is the operator's day-2 proxy),
the service zone `<instance>.svc.<meta.domain>` with answer-name reversal,
and the pod zone (`pods insecure`, dash-form rewrites, admin default-on).

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
  # no instance-level settings: topology lives on the spoke machines
  roles = {
    # hub slot + upstream transit: the router role (not *because* it is a hub)
    router.machines.hel-hub-1.settings.endpointSources = [
      { service = "netif"; instance = "uplink-a"; }
    ];
    # hub slot without upstream transit: hub is topology, not role
    member.machines.hel-hub-2.settings.endpointSources = [
      { service = "netif"; instance = "uplink-b"; }
    ];
    # NAT site 1: no reachable public endpoint; dials its hubs with keepalive
    admin.machines.kamrui-h1.settings.hubs = [ "hel-hub-1" "hel-hub-2" ];
    # NAT site 2: works through the same hubs
    client.machines.site-b-client.settings.hubs = [ "hel-hub-1" "hel-hub-2" ];
  };
};
```

Each spoke declares its own hub list (`settings.hubs` on the machine);
hub machines are the **union** of the spokes' lists, and every instance
needs at least one reachable hub in that union — two for HA. The roles
declare what each machine may reach, orthogonally: `hel-hub-2` is a hub
without being a router, and a `router`-role machine that appears in no
spoke's list is purely an upstream gateway, not transit between spokes.

Clusters reference the fabric through `network.fabric`; see
[Multi-cluster](multi-cluster.md) for the `mesh.peers` selective-peering
shape and the three-graph model.

## Acceptance

Evaluation must prove deterministic names and transfer prefixes, one peer
per interface, AllowedIP/filter equivalence including transit prefixes,
role policy, self-exclusion, hub reachability (≥1 reachable hub), NAT
viability through hubs, spoke-non-transit filtering, and collision
detection.

Hermetic VMs must prove real handshakes, FRR sessions and BFD on both
sides, RIB-to-FIB installation, hub readvertisement, native pod round
trips, shared-VIP dual-stack ECMP and withdrawal across two hubs, node-bgp
owner-only advertisement, client VIP-only isolation, admin
pod/Service/DNS access, router upstream filtering, and the kamrui-h1
dual-shape. All of this is **planned for phases 5R1–5R3** — there is
no implementation or VM evidence for the round-15 shape yet.
