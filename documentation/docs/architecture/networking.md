# Networking

The data plane is inventory-owned host networking (`netif`), an encrypted
routed fabric (`routed-fabric`: per-adjacency WireGuard, FRR/Zebra routing,
routed-hub MVP topology), and native-routed Cilium. BIRD and VXLAN are
legacy, not the target. The round-14 full-mesh target is superseded by
round 15's routed-hub design (D51–D55); round 16 replaces the four-role
model with two topology roles plus orthogonal `access`/`border` switches
(D56) and adds the `clan.networkFacts` seam (D57).

## Host links: `netif`

`netif` declares the core host network in `inventory.nix`, multi-instance
and multi-link (D53): one instance per segment — a site LAN, a public
uplink, an SFP+ group — with segment defaults and per-machine/per-link
overrides. Links may be physical, VLAN, bond, or bridge, with DHCP/RA or
static addressing, prefixes, gateways (on-link and default), static and
policy routes, MTU, DNS, and firewall trust. A host may join several
instances (public + private NICs, multi-NIC routers); cross-instance checks
enforce unique link ownership, a single host default route, and
non-conflicting DNS. See [netif](../services/netif.md) for the contract and
inventory example.

`routed-fabric` consumes `peer` endpoint exports from `netif` or another
underlay service and owns all fabric policy routing. `netif` links never
become a shared-L2 Kubernetes datapath. Home's older
`hostSpec.networking` and `machines.json` static-IP path leaves during
migration. Borg's `lan` service is the behavioral reference, not preserved
implementation code.

## Flat L3 transport: one WireGuard interface per declared adjacency

Every fabric member has stable dual-stack `/32` and `/128` addresses on a
fabric loopback/dummy interface. These are the node InternalIPs, FRR
router ID, and API/HAProxy transport addresses.

The MVP topology is **routed-hub** (D51/D56): members declare adjacency
to hub-role machines (one minimum, two for HA, no arbitrary maximum),
hubs forward and readvertise between members, and members never provide
spoke transit. Full mesh is deferred. For every declared adjacency —
member↔hub, hub↔hub, border↔upstream — `routed-fabric`
renders exactly one point-to-point WireGuard interface with one peer,
deterministic transfer prefixes, and a deterministic instance/peer-derived
name of at most 15 characters. There is no multi-peer interface and no
second set of auxiliary routed interfaces.

This shape is required by WireGuard's cryptokey routing: `AllowedIPs`
selects the peer inside one interface, so duplicate entries across two
peers on that interface cannot provide ECMP. The same prefixes on
*different* one-peer interfaces are valid; Linux ECMP selects an interface
per flow, then WireGuard finds the one peer.

`AllowedIPs` is both **outbound selection and the inbound source ACL**
(D51), and it must include the transit prefixes a peer is authorized to
carry through this machine — a hub's spoke-facing interfaces carry the
other spokes' prefixes, or readvertised traffic dies in cryptokey routing
even with BGP accepted. AllowedIPs and FRR route filters come from one
resolved policy. Shared VIPs are allowed on each advertiser interface,
node-owned BGP VIPs only on the owner interface, pod routes on
Kubernetes/admin interfaces, and ClusterIPs only on admin interfaces. A
default route never enters the fabric as an installed route; an
external-transit link may list default entries purely as a crypto ACL, and
Internet ingress requires source-policy return routing via the correct
fabric egress.

NAT or outbound-only spokes omit an endpoint and use a 25-second keepalive,
dialing reachable hubs; two NAT sites both work through the hubs. Private
endpoints are acceptable when actually reachable — every adjacency needs at
least one reachable side, checked before peering is advertised. MTU derives
from the underlay link export; native Cilium uses the WireGuard MTU
directly; there is no VXLAN 50-byte budget.

## FRR and Zebra

Every member runs one integrated `services.frr` configuration with
`bgpd`, `bfdd`, and Zebra. `routed-fabric` renders it atomically from
inventory and exports. Distro services publish cluster facts and render
Cilium resources; they do not contribute a second routing stack.

Fabric FRR instances use unique private 32-bit node ASNs and eBGP, one
session per address family over each adjacency, with `next-hop-self` on hub
readvertisement. There is **no iBGP and no route reflector** (D51) — the
hub topology replaces them. Policy is mandatory: `bgp ebgp-requires-policy`,
explicit address-family activation, prefix-lists/route-maps, and
maximum-prefix limits. `maximum-paths` and
`bgp bestpath as-path multipath-relax` preserve shared-VIP and dual-hub
ECMP. BFD monitors every FRR-FRR path.

Cilium has no BFD in 1.20, so its local session uses 3-second keepalive,
9-second hold, and 5-second connect retry. Cilium dials only local FRR at
`::1`, without `localPort`. FRR enables reserved-range and martian-next-hop
handling and rewrites the loopback next hop to the node's stable transport
address before redistribution.

Zebra installs accepted remote routes into the kernel. Normal eBGP
next-hop rewriting makes each path resolve through its corresponding
WireGuard interface. BGP distributes reachability; the kernel and Cilium
forward the packets.

NixOS reload behavior matters: configuration-only changes reload through
`frr-reload.py`. On FRR 10.7.1, reload also starts newly enabled daemons
without restarting bgpd (probe-verified); a full `systemctl restart frr` is
not required for daemon-set changes. Preview with
`frr-reload.py --test --confdir /etc/frr /etc/frr/frr.conf`; a non-empty
add/delete delta still exits zero, so convergence checks inspect the output.
The NixOS module does not open BGP or BFD firewall ports automatically.

## Native-routed Cilium

The canonical Cilium 1.20+ profile uses kube-proxy replacement,
`routing-mode: native`, multi-pool pod IPAM, dual-stack, BPF
masquerade+tproxy, Maglev, PMTU, and Node IPAM. VXLAN/Geneve and Cilium
L7/Gateway/Ingress features are off. Multi-pool remains mandatory unless
the operator explicitly selects `ipam.mode: kubernetes`.

`auto-direct-node-routes` is false because the per-adjacency WireGuard
fabric is routed L3, not shared L2. Cilium advertises local
`CiliumPodIPPool` allocations to local FRR; FRR distributes them and Zebra
installs remote routes. Native Cilium delegates non-local pod traffic to
that FIB.

Dual-stack native-routing CIDRs cover every pod CIDR in the ClusterMesh
trust domain. Cilium device configuration covers all fabric interfaces.
ClusterMesh requires native mode everywhere, non-overlapping pod CIDRs,
node connectivity, and working cross-cluster pod routes before readiness.

## LoadBalancer arbitration

- **Classless Services → Node IPAM.** `nodeIPAM.enabled=true` and
  `defaultLBServiceIPAM=nodeipam` provide the ServiceLB-style default.
  Node IPAM's node-IP answers are **fabric-scoped**; they are how classless
  Services reach fleet participants.
- **Explicit pools → `io.cilium/bgp-control-plane`.** Node IPAM owns every
  unset-class Service, so pool draws need a recognized LB-IPAM class. This
  class requests allocation, not automatic advertisement; BGP selectors
  announce only `node-bgp` and `shared-bgp` pools. `io.cilium/lb-ipam` is
  not a Cilium-handled class.
- **`node-bgp` and `shared-bgp` pools →
  `io.cilium/bgp-control-plane`.** Cilium 1.20 announces that class (or an
  unset class) through BGP.

Public exposure uses **explicit pools** — there is no implicit Internet
publication of fabric VIPs. `node-bgp` is selected only where BGP delivery
actually exists (an owner node plus router advertisement); otherwise it is
not an option. servicelb/klipper stays disabled. Cilium LB IPAM allocates
addresses; Node IPAM, provider routing, a floating controller, or BGP
delivers them.

## Pool scopes and five delivery modes

| Delivery | Scope | Delivery behavior |
| --- | --- | --- |
| `node-fate-bound` | per-machine | Provider/static routing to the owner; no BGP |
| `node-bgp` | per-machine | Only the owner advertises exact VIPs; no cross-node ECMP |
| `shared-bgp` | cluster-global | Every healthy eligible node advertises; routers ECMP |
| `floating` | cluster-global | A runtime controller moves the address; blackhole window without it |
| `external-class` | cluster-global | A cloud CCM handles delivery |

Use `node-bgp` for node-owned public IPv4 extras and carve-outs of the
node's routed IPv6 subnet, where BGP delivery exists. Per-node
advertisements select only that owner's pool. ETP Local withdraws the VIP
when no eligible local backend exists, so consumers must keep eligible
backends on the owner.

Use `shared-bgp` for private fabric VIPs and upstream-router pools. Every
healthy eligible node advertises the same `/32` or `/128`; FRR and the
upstream router retain all equal paths. One VIP is never advertised from
two clusters.

The default private `<instance>-fabric` pool is shared-bgp and carries
CoreDNS, ClusterMesh, and mirror-Service VIPs. Public BGP pools
require upstream-routed address space and a controlled router. Dynamic
residential IPv4 BGP and heterogeneous multi-WAN inbound failover are not
goals; use DNS failover for the latter.

## Route consumption (member DNS is day-2)

Route consumption is the per-machine `access` switch, orthogonal to
topology (D56) — `access = member` (the default) provides fabric transport
and automatic native pod routes on Kubernetes nodes. `access = client` adds
fabric-pool LoadBalancer-VIP routes only. `access = admin` adds explicit
pod/ClusterIP route consumption. The optional per-machine `border` switch owns upstream
transit — upstream peers, owned-prefix policy, forwarding, and optional
NDP — and implies neither hub membership nor admin DNS; a hub need not be
a border and vice versa.

Ordinary clients do not receive pod or ClusterIP routes, and
`cluster.local` is never served to them. No cluster DNS is served to
fabric members in the MVP (D22 amended 2026-10-25): members get routes
only and resolve cluster names day-2 via Kubernetes-side automation such
as external-dns.

## Firewall posture

The host firewall is **nftables** (D55): kube-proxy is replaced by Cilium
(kube-proxy off). Cilium 1.20.3 requires `install-iptables-rules=true` for
KPR/BPF masquerade; its required datapath rules use the `iptables-nft`
backend. Legacy iptables and kube-proxy rules remain forbidden. The API
listens on transport only. Public ports open only where a Service exposes
them. WireGuard is restricted to configured underlays; BGP/BFD is
restricted to loopback and expected fabric/upstream peers. VM tests assert
positive connectivity and negative exposure.

The official `mycelium`, `yggdrasil`, and `wireguard` meshes are
alternative **overlays**, not underlays (D55) — none can replace the
routed, filtered, ACL'd fabric datapath. The useful seam for any
alternative transport is the standard `peer` export set that `netif`
already publishes.
