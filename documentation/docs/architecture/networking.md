# Networking

The data plane is inventory-owned host networking, encrypted per-pair
WireGuard, FRR/Zebra routing, and native-routed Cilium. BIRD and VXLAN are
legacy, not the round-14 target.

## Host links: `netif`

`netif` declares the core host network in `inventory.nix`: physical or
logical interfaces, static or DHCP/RA addressing, prefixes, gateways,
static and policy routes, MTU, DNS, firewall trust, and an optional clan
deploy-target export. Supporting NixOS modules may handle Wi-Fi
association or platform tuning, but they do not own static addresses or
routes.

`fleet-routing` consumes `peer` exports from `netif` or another underlay
service. Home's older `hostSpec.networking` and `machines.json` static-IP
path leaves during migration. Borg's `lan` service is the behavioral
reference, not preserved implementation code.

## Flat L3 transport: one WireGuard interface per pair

Every fabric member has stable dual-stack `/32` and `/128` addresses on a
fabric loopback/dummy interface. These are the node InternalIPs, FRR
router ID, and API/HAProxy transport addresses.

For every remote member, `fleet-routing` renders exactly one
point-to-point WireGuard interface. It has one peer, deterministic
transfer prefixes, and a deterministic instance/peer-derived name of at
most 15 characters. There is no multi-peer `wg-mesh` and no second set of
auxiliary routed interfaces.

This shape is required by WireGuard's cryptokey routing: the destination
selects a peer inside one interface, so duplicate `AllowedIPs` across two
peers on that interface cannot provide ECMP. The same prefixes on
*different* one-peer interfaces are valid; Linux ECMP selects an interface
per flow, then WireGuard finds the one peer.

`AllowedIPs` and FRR route filters come from one resolved policy. Shared
VIPs are allowed on each advertiser interface, node-owned BGP VIPs only on
the owner interface, pod routes on Kubernetes/admin interfaces, and
ClusterIPs only on admin interfaces. No default route or unapproved LAN
prefix leaks into the fabric.

NAT or outbound-only members omit an endpoint and use a 25-second
keepalive. Every pair must have at least one reachable endpoint. Native
Cilium uses the WireGuard MTU directly; there is no VXLAN 50-byte budget.

## FRR and Zebra

Every member runs one integrated `services.frr` configuration with
`bgpd`, `bfdd`, and Zebra. `fleet-routing` renders it atomically from
inventory and exports. Distro services publish cluster facts and render
Cilium resources; they do not contribute a second routing stack.

Fabric FRR instances use unique private 32-bit node ASNs and eBGP, one
session per address family over each per-pair link. Policy is mandatory:
`bgp ebgp-requires-policy`, explicit address-family activation,
prefix-lists/route-maps, and maximum-prefix limits. `maximum-paths` and
`bgp bestpath as-path multipath-relax` preserve shared-VIP ECMP. BFD
monitors every FRR-FRR path.

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
`frr-reload.py`, while enabling a new daemon requires a one-time
`systemctl restart frr`. Preview with
`frr-reload.py --test --confdir /etc/frr /etc/frr/frr.conf`. The NixOS
module does not open BGP or BFD firewall ports automatically.

## Native-routed Cilium

The canonical Cilium 1.20+ profile uses kube-proxy replacement,
`routing-mode: native`, multi-pool pod IPAM, dual-stack, BPF
masquerade+tproxy, Maglev, PMTU, and Node IPAM. VXLAN/Geneve and Cilium
L7/Gateway/Ingress features are off. Multi-pool remains mandatory unless
the operator explicitly selects `ipam.mode: kubernetes`.

`auto-direct-node-routes` is false because the per-pair WireGuard fabric
is routed L3, not shared L2. Cilium advertises local `CiliumPodIPPool`
allocations to local FRR; FRR distributes them and Zebra installs remote
routes. Native Cilium delegates non-local pod traffic to that FIB.

Dual-stack native-routing CIDRs cover every pod CIDR in the ClusterMesh
trust domain. Cilium device configuration covers all per-pair interfaces.
ClusterMesh requires native mode everywhere, non-overlapping pod CIDRs,
reachable node InternalIPs, and working cross-cluster pod routes before
readiness.

## LoadBalancer arbitration

- **Classless Services → Node IPAM.** `nodeIPAM.enabled=true` and
  `defaultLBServiceIPAM=nodeipam` provide the ServiceLB-style default.
- **Non-BGP pools → `io.cilium/lb-ipam`.**
- **`node-bgp` and `shared-bgp` pools →
  `io.cilium/bgp-control-plane`.** Cilium 1.20 announces that class (or an
  unset class) through BGP.

servicelb/klipper stays disabled. Cilium LB IPAM allocates addresses;
Node IPAM, provider routing, a floating controller, or BGP delivers them.

## Pool scopes and five delivery modes

| Delivery | Scope | Delivery behavior |
| --- | --- | --- |
| `node-fate-bound` | per-machine | Provider/static routing to the owner; no BGP |
| `node-bgp` | per-machine | Only the owner advertises exact VIPs; no cross-node ECMP |
| `shared-bgp` | cluster-global | Every healthy eligible node advertises; routers ECMP |
| `floating` | cluster-global | A runtime controller moves the address; blackhole window without it |
| `external-class` | cluster-global | A cloud CCM handles delivery |

Use `node-bgp` for node-owned public IPv4 extras and carve-outs of the
node's routed IPv6 subnet. Per-node advertisements select only that
owner's pool. ETP Local withdraws the VIP when no eligible local backend
exists, so consumers must keep eligible backends on the owner.

Use `shared-bgp` for private fabric VIPs and upstream-router pools. Every
healthy eligible node advertises the same `/32` or `/128`; FRR and the
upstream router retain all equal paths. One VIP is never advertised from
two clusters.

The default private `<instance>-fabric` pool is shared-bgp and carries
CoreDNS, ClusterMesh, and mirror-Service VIPs. Public BGP pools require
upstream-routed address space and a controlled router. Dynamic residential
IPv4 BGP and heterogeneous multi-WAN inbound failover are not goals; use
DNS failover for the latter.

## Route consumption and DNS

`member` provides flat-L3 transport and automatic native pod routes on
Kubernetes nodes. `client` adds VIP routes and the instance-zone DNS stub.
`admin` adds explicit pod/ClusterIP consumption and svc/pod zones.
`router` adds upstream peers, owned-prefix policy, forwarding, and optional
proxy-NDP.

Ordinary clients do not receive pod or ClusterIP routes. `cluster.local`
is never served to them. Route-only DNS uses global systemd-resolved
settings so packets follow the kernel's ECMP routes.

## Firewall posture

The API listens on transport only. Public ports open only where a Service
exposes them. WireGuard is restricted to configured underlays; BGP/BFD is
restricted to loopback and expected fabric/upstream peers. VM tests assert
positive connectivity and negative exposure.
