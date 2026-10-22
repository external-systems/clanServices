# Networking

One Cilium base, one LoadBalancer arbitration rule, one BGP fabric — on
every cluster.

## Transport

Host WireGuard full mesh is the only tested node transport (SPEC.md §6.3):
every machine gets a mesh IPv4 and IPv6 address, deterministic from cluster
id + machine name, on a host WireGuard interface. Per-machine overrides
cover addresses, port, endpoint, interface, MTU, routes, and pool blocks.

Dual-stack inside the cluster is mandatory. Mesh groups (cross-cluster
transport peering) are rendered from exports: remote prefixes only in
`AllowedIPs`, and every remote node InternalIP must be reachable before
ClusterMesh is considered ready. The tunnel MTU budget is transport MTU
minus 50. The posture is all-or-none per mesh trust domain: a cluster mesh
shares one transport.

`transport.mode = cilium-wireguard | unencrypted` survive only as untested
Cilium helm-values overrides — no contract, no VM coverage.

## The Cilium base

One canonical upstream Cilium 1.20+ profile on both distros (the RKE2-bundled
Cilium is disabled). Always on: kube-proxy replacement, VXLAN tunnel,
multi-pool pod IPAM with derived non-clashing dual-stack CIDRs, BPF
masquerade with tproxy, Maglev, PMTU discovery, and **Node IPAM for
classless LoadBalancer Services** (D41). Cilium is networking-only (D1) —
its Gateway and Ingress controllers are permanently off, and that is now the
only in-cluster Cilium surface. `ipam.mode: kubernetes` is an allowed
explicit override for pod IPAM.

An admin helm-values override hatch exists with post-merge validation: it
rejects values that violate routing, tunnel, IPAM, dual-stack, CNI-chaining,
artifact, or ETP invariants. The base never blocks you from using Cilium in
any way you see fit; the contract only guarantees the un-overridden profile.

## LoadBalancer arbitration: Node IPAM vs pools (D41/D8)

One rule decides who serves a `type: LoadBalancer` Service:

- **Classless Services → Node IPAM.** The canonical profile sets
  `nodeIPAM.enabled=true` and `defaultLBServiceIPAM=nodeipam`. A Service
  with no `loadBalancerClass` receives node IPs (ExternalIP preferred, else
  InternalIP) — the k3s-ServiceLB experience on every distro, including
  stock Traefik under `distroDefaults`. With `externalTrafficPolicy: Local`
  the advertised node set follows real EndpointSlices (pod placement). The
  documented Cilium dummy-Endpoints limitation affects only Cilium's own
  Gateway/Ingress implementations, which stay disabled (D1) — third-party
  proxies with real backends (a day-2 Envoy Gateway) are unaffected.
- **`loadBalancerClass: io.cilium/lb-ipam` → pools.** Every clan-rendered
  VIP consumer (ClusterMesh apiserver, private CoreDNS, mirror Services)
  pins this class automatically and draws from LB-IPAM pools. Pools are the
  only VIP mechanism.

servicelb/klipper stays disabled in every mode (D42): two controllers racing
on `status.loadBalancer.ingress` is a contract violation.

## The LB pool model: 2 scopes × 4 delivery modes (D8)

A pool is an address inventory plus a `serviceSelector` — nothing else.

**Scope** (who contributes the addresses):

- **Per-machine** — node-named pools built from the machine's join address
  (/32 + /128) plus declared extra blocks. Always node-fate-bound.
- **Cluster-global** — generic-named pools (`helsinki-ipv4-1`,
  `fsn-ipv6`). Never node-fate-bound.

**Delivery mode** (how traffic reaches the address, and its failure
semantics):

- `node-fate-bound` — provider/static routing to one machine; no failover,
  no BGP.
- `floating` — a runtime controller moves the IP to one machine at a time;
  failover timing is the controller's contract (a blackhole window exists);
  requires full local proxy coverage on the candidate set.
- `shared-bgp` — all healthy machines advertise /32 + /128; the upstream
  router ECMPs; an unhealthy machine withdraws via ETP Local.
- `external-class` — a cloud CCM handles it.

Labels like `public=true`, `private=true` are selector labels on pools of
any scope and mode — not a category. A dynamic tenant draw gets one IP per
family; an explicit `lbipam.cilium.io/ips` annotation is a deliberate
projection. Eval asserts: blocks non-overlapping, scope⇒mode validity, BGP
only for `shared-bgp`, floating candidate coverage, and `shared-bgp` blocks
inside router-role prefixes when the router is in the same inventory.

Zero-config example: a single-machine cluster whose join addresses are
10.0.0.1/32 + fd0::1/128 gets pool `node-1` with exactly those blocks,
served under `loadBalancerClass: io.cilium/lb-ipam`.

## BGP and the BIRD fabric (D9/D19)

Cilium agents (GoBGP) originate VIP routes and dial **out** over loopback to
a per-machine BIRD daemon — nothing listens on :179. BIRD imports only
approved exact VIPs and exports only those upstream; it never installs mesh,
primary, or transit routes into cluster-machine kernels. The upstream router
(a NixOS BIRD machine, a MikroTik, a switch) hears the same route from every
healthy machine and ECMPs across them. Cilium agents never peer with each
other.

Each cluster gets two deterministic private 32-bit ASNs (BIRD-side and
Cilium-side) plus a per-machine router id; uniform ASNs mean no multipath
relax. Timers: hold 9, keepalive 3, connect-retry 5 (no BFD in Cilium 1.20).
A published foreign-router contract covers ASNs, timers, max-prefix and
prefix filters (accept only pool blocks as /32 + /128), ECMP path counts,
and proxy-NDP on-LAN.

BIRD config is rendered through a vendored named-fragment pattern (D19):
multiple clanServices contribute named, instance-prefixed blocks to one BIRD
per machine, with nixpkgs' `bird -p` pre-start check as the validator.

## The private fleet fabric (D10)

On by default per cluster: one private `shared-bgp` pool (ULA + RFC1918
carved from the cluster's derived CIDR space), per-machine BIRD and BGP v2
resources, and core VIPs on it — private CoreDNS, the ClusterMesh apiserver,
and the mirror Services. This is what lets clan machines route into every
cluster.

Public `shared-bgp` is opt-in and has hard preconditions: upstream-routed
address space (DHCPv6-PD carve-out, static assignment, or PI space) and a
router you control. Explicit non-goals: BGP over a single dynamic
residential IPv4, and heterogeneous multi-WAN inbound failover (use DNS
failover instead — the Hetzner public edge pattern is node-bound + floating
pools with health-checked DNS failover).

One VIP per cluster: never advertise the same VIP from two clusters.
Cross-cluster traffic goes through ClusterMesh global Services or DNS.

## Firewall posture (SPEC.md §6.12)

The firewall contract: the API listens on the transport only; public ports
open only where a Service exposes them; mesh and BGP traffic is restricted
to expected peers; mirror Services are reachable only from GitOps
namespaces (D30). VM tests assert positive connectivity *and* negative
exposure.
