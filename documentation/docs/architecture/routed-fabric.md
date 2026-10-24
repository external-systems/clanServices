# Routed fabric

`routed-fabric` is the flat-L3 trust-domain clanService for Kubernetes and
ordinary NixOS machines (round 15, D51; the round-14 `fleet-routing` name and
full-mesh topology are superseded; round 16, D56, replaces the four-role
model). It owns per-adjacency WireGuard,
FRR/BFD/Zebra routing, access/border route policy, and fleet DNS consumption.
The BIRD/VXLAN design and the legacy `wireguard-mesh` are superseded; the
existing `services/fleet-routing/` code is legacy and is not the
round-15/16 implementation.

## Two topology roles, orthogonal access and border

The service has **two topology roles**; every machine joins exactly one
(D56):

- **`member`** — the fabric participant: encrypted dual-stack fabric
  transport, FRR/BFD/Zebra, and (on Kubernetes nodes) automatic native pod
  routes.
- **`hub`** — a member that also forwards and readvertises between spokes;
  hub↔hub links are explicit. Spokes never transit.

What a machine may **consume** is a separate, orthogonal per-machine
switch, `access` (D56; default `member`):

- **`access = member`** (default) — fabric membership plus automatic
  native pod routes on Kubernetes nodes.
- **`access = client`** — member plus cluster VIP routes and the
  `<instance>.<meta.domain>` DNS stub. No pod or ClusterIP routes.
- **`access = admin`** — client plus explicit pod/ClusterIP route
  consumption and the svc/pod DNS zones. The developer/admin profile.

Whether a machine speaks to the **outside** is a second orthogonal,
optional per-machine switch, `border` (D56): upstream BGP peers,
owned-prefix filtering, forwarding, optional NDP (proxy-NDP), and
authorized external/fabric transit. A border gets **no automatic admin
DNS** — access still governs consumption.

Topology, access, and border are fully orthogonal and composable: **a
border need not be a hub, and a hub need not be a border**. Public
endpoints do not imply either hub or border. The round-15 `router` role is
retired — upstream transit is the `border` switch, hub placement is the
`hub` role, and neither implies the other. Edge proxies on a border remain
separate operator NixOS modules, never part of routed-fabric.

Keep the terms apart: a **fabric hub** forwards/readvertises fabric
traffic; a **border** owns upstream/external transit; a **default gateway**
is ordinary host routing (DHCP/RA addressing is a separate concern, owned
by `netif`); **Kubernetes Gateway API** is a day-2 in-cluster ingress
concern that clan never renders (D1/D2).

A host joins **at most one** routed-fabric instance (D53). Multiple
routed-fabric instances are how a fleet segments trust domains — one
membership per host, and cross-cluster reachability never spans fabrics.
The fabric a cluster joins supplies its mesh group (D54); see
[Multi-cluster](multi-cluster.md).

## Routed-hub topology: the MVP

The supported topology is **routed-hub**: every member declares adjacency
to hub-role machines; full mesh is deferred (D51). One hub is the minimum,
**two hubs are the HA default**, and there is **no arbitrary maximum of
two** — more than two hubs is a legal, explicit operator tradeoff, not a
violation. Kubernetes managers are not default hubs; only the `hub` role
fills a hub slot. Two NAT sites both work through the hubs; hubs forward
and readvertise between members, **members never provide spoke transit**.
An all-hub all-to-all fabric is still the deferred full mesh, not a
supported topology (D56).

Each fabric member has stable dual-stack `/32` and `/128` addresses on a
fabric loopback/dummy interface — the node InternalIPs, FRR router ID, and
API/HAProxy transport addresses. For **every declared adjacency**
(member↔hub, hub↔hub, border↔upstream) routed-fabric renders exactly one
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
external peers belong in the machine's optional `border` attrset; fabric
and cluster exports provide the facts to render both sides without
duplicating addresses.

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
  follow the correct adjacency instead of the host default route. **NAT
  borders have no automatic conntrack sharing**: existing-flow failover
  requires a separate state mechanism; new flows take whichever border
  policy selects (D56).

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

The per-machine `access` switch governs consumption (D56): `member`
(default) provides fabric transport and automatic native pod routes on
Kubernetes nodes. `client` adds VIP routes and the instance-zone DNS stub.
`admin` adds explicit pod/ClusterIP consumption and the svc/pod zones.
Ordinary clients never receive pod or ClusterIP routes, and `cluster.local`
is never served to them. Route-only DNS uses global systemd-resolved
settings so queries follow the kernel's ECMP routes. `border` changes what
a machine may originate and transit — never what it automatically gets to
consume or resolve.

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
  # no instance-level settings: topology lives on the member machines
  roles = {
    # hub slot + upstream transit: hub role + border (neither implies the other)
    hub.machines.hel-hub-1.settings = {
      border.ownedPrefixes = [ "203.0.113.0/24" "2001:db8:100::/48" ];
      endpointSources = [
        { service = "netif"; instance = "uplink-a"; }
      ];
    };
    # hub slot without upstream transit: hub is topology, not transit
    hub.machines.hel-hub-2.settings.endpointSources = [
      { service = "netif"; instance = "uplink-b"; }
    ];
    # NAT site 1, admin access: no reachable public endpoint; dials its hubs
    member.machines.kamrui-h1.settings = {
      access = "admin";
      hubs = [ "hel-hub-1" "hel-hub-2" ];
    };
    # NAT site 2, client access: works through the same hubs
    member.machines.site-b-client.settings = {
      access = "client";
      hubs = [ "hel-hub-1" "hel-hub-2" ];
    };
    # upstream-only border: transit to the ISP, not a hub, no special access
    member.machines.edge-2.settings = {
      hubs = [ "hel-hub-1" "hel-hub-2" ];
      border.ownedPrefixes = [ "203.0.113.0/24" "2001:db8:100::/48" ];
    };
  };
};
```

Each spoke explicitly names its hub list (`settings.hubs` on the machine),
and every member needs at least one reachable hub in its list — two for
HA, more an explicit tradeoff. Hub membership is **directly declared** by
the `hub` role; the spoke lists select adjacency, they do not elect hubs by
union (D56). The switches compose orthogonally: `hel-hub-2` is a hub
without being a border, `edge-2` is a border without being a hub or gaining
admin DNS, and `kamrui-h1` is an ordinary member with admin access that
happens to be behind NAT.

Clusters reference the fabric through `network.fabric`; see
[Multi-cluster](multi-cluster.md) for the `mesh.peers` selective-peering
shape and the three-graph model.

## Acceptance

Evaluation must prove deterministic names and transfer prefixes, one peer
per interface, AllowedIP/filter equivalence including transit prefixes,
access/border policy, self-exclusion, hub reachability (≥1 reachable hub),
NAT viability through hubs, spoke-non-transit filtering, and collision
detection.

Hermetic VMs must prove real handshakes, FRR sessions and BFD on both
sides, RIB-to-FIB installation, hub readvertisement, native pod round
trips, shared-VIP dual-stack ECMP and withdrawal across two hubs, node-bgp
owner-only advertisement, client VIP-only isolation, admin
pod/Service/DNS access, border upstream filtering, hub/border/access
orthogonality (a border that is not a hub, a hub that is not a border), and
the kamrui-h1
dual-shape. All of this is **planned for phases 5R1–5R3** — there is
no implementation or VM evidence for the round-15/16 shape yet.
