# Networking

One Cilium base, one LoadBalancer arbitration rule, one BGP fabric — on
every cluster.

## Transport

Host WireGuard full mesh is the only tested node transport (SPEC.md §6.3):
every machine gets a mesh IPv4 and IPv6 address — deterministic from the
mesh instance + machine name (a stable hash into 192.168.0.0/16 +
fd77::/16), with per-machine overrides for addresses, port, endpoint,
interface, MTU, routes, and pool blocks — on a host WireGuard interface.

Dual-stack inside the cluster is mandatory. The posture is all-or-none per
mesh trust domain: a cluster whose members mix transport-provided and
manual addresses is an eval error. **One mesh group = one
`wireguard-mesh` instance** (phase-4 mapping): a cluster joins a group by
consuming that instance's `node_transport` exports, so cross-cluster
peering between group members happens inside the shared mesh; same-group
clusters consuming different transport instances fail evaluation. Remote
prefixes only in `AllowedIPs`, and every remote node InternalIP must be
reachable before ClusterMesh is considered ready. The tunnel MTU budget is
transport MTU minus 50.

Every node carries topology labels (invariant 7):
`topology.kubernetes.io/region` and `topology.kubernetes.io/zone` default
to the cluster's instance name, overridable per machine
(`topology.region`/`topology.zone`); an empty override is an eval error.

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
- **Cilium-handled `loadBalancerClass` → pools.** Every clan-rendered
  VIP consumer (ClusterMesh apiserver, private CoreDNS, mirror Services)
  pins a pool class automatically and draws from LB-IPAM pools. Pools are
  the only VIP mechanism. Two classes serve pools:
  `io.cilium/lb-ipam` for node-fate-bound and floating draws, and
  `io.cilium/bgp-control-plane` for `shared-bgp` draws — Cilium 1.20's
  BGP control plane announces ingress IPs only for the latter (or unset
  classless Services, which Node IPAM owns), while LB-IPAM allocation
  serves both. Pinning `io.cilium/lb-ipam` on a shared-bgp Service
  allocates but never announces — the renderer pins the right class for
  its own consumers; day-2 Services must pick by delivery mode.

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

Cilium agents (GoBGP) originate VIP routes and dial **out** to a
per-machine BIRD daemon over a node-local loopback link: the address
`169.254.179.1/32` is assigned to `lo` (a systemd oneshot per cluster
node), BIRD binds its *only* `:179` listener to it (`passive on; strict
bind on; free bind on`), and Cilium's `CiliumBGPClusterConfig` (one per
node, selected by `kubernetes.io/hostname`) peers with it — no
`localPort`, so the Cilium side listens on nothing. BIRD refuses 127/8
neighbor addresses, hence the link-local alias instead of 127.0.0.1.

BIRD imports only approved exact VIPs — `/32` and `/128` prefixes inside
the cluster's `shared-bgp` pool blocks, enforced by per-family prefix
filters *and* an `import limit` (block capacity, capped at 4096) — and
re-exports exactly those to the cluster's configured
`bgp.upstreamPeers`. Upstream sessions are dialed out by the node and
split per address family (a v4 session carries the ipv4 channel, a v6
session the ipv6 channel), with `next hop self` so the router sees each
node's own address as the VIP next hop. BIRD installs nothing into the
cluster node's kernel (no kernel protocol in the fragment). One BIRD
quirk to know: BIRD 2 opens a wildcard listen socket per BGP protocol
with no way to disable it, so the upstream-session protocols live on
`local port 4179` — `:179` stays loopback-only, and inbound `:4179` is
firewall-dropped (it accepts nothing anyway: only configured neighbor
addresses match).

The upstream router (a NixOS BIRD machine, a MikroTik, a switch) hears
the same route from every healthy machine and ECMPs across them. Cilium
agents never peer with each other.

Each cluster gets two deterministic private 32-bit ASNs (Cilium-side and
BIRD-side), derived from the instance name: the first 8 hex chars of
`sha256("kube-cluster-bgp-cilium:<instance>")` resp.
`sha256("kube-cluster-bgp-bird:<instance>")` as a u32, mapped modulo into
the RFC 6996 range 4200000000–4294967293 (a deterministic +1 covers the
salt-collision case). Explicit `bgp.ciliumASN` / `bgp.birdASN` pins are
the escape hatch; ASN collisions are a fleet-wide eval error. Uniform
ASNs mean no multipath relax on the router. The router id is the node's
IPv4 (mesh/transport) address on both sides. Timers: hold 9, keepalive 3,
connect-retry 5 (no BFD in Cilium 1.20).

**Foreign-router contract (published):** peer with each cluster node's
BIRD (ASN = the cluster's BIRD-side ASN, exported as
`kube_cluster.bgp.birdAsn`) over any routed path to the node; timers hold
9 / keepalive 3 / connect-retry 5; accept **only** the cluster's
shared-bgp pool blocks (exported as `kube_cluster.pools`) and only as
exact /32 + /128 (prefix filters + a max-prefix limit); set your ECMP
path count ≥ the node count; proxy-NDP if the VIPs are on-LAN. The VM
suites ship a complete reference implementation: the `router` fixture in
`services/{k3s,rke2}/tests/vm/bgp-ecmp.nix` is a plain BIRD daemon
realizing exactly this contract.

BIRD config is rendered through a vendored named-fragment pattern (D19):
multiple clanServices contribute named, instance-prefixed blocks
(`clan.bird.fragments."kube-cluster-<instance>"`, later
`fleet-routing-<instance>`) into one BIRD per machine; the router id is
set exactly once (a conflicting second definition fails evaluation), and
the assembled config is validated by `bird -p` at **build** time (the
nixpkgs `services.bird` checkConfig hook — stronger than a pre-start
check). A second BGP stack on the host (e.g. FRR bgpd) is an eval error
(invariant 9).

## The private fleet fabric (D10)

On by default per cluster (`fabric.enable = true`): one private
`shared-bgp` pool `<instance>-fabric` with blocks
`172.16.<ciliumId>.0/24` + `fd11:<ciliumId>::/64` — derived from the
resolved cluster id, disjoint from the id-derived pod/service space
(`10/8` + `fd10::/16`) and the mesh hash space (`192.168/16` +
`fd77::/16`) by construction, and eval-asserted non-overlapping with any
explicit CIDR overrides (override the blocks via `fabric.ipv4Block` /
`fabric.ipv6Block` when your RFC1918 plan needs it) — plus per-machine
BIRD and the BGP v2 resources, and the private CoreDNS on the fabric VIP
(offset 53/0x53 in the fabric blocks, pinned via `lbipam.cilium.io/ips`,
advertised with ETP Local withdrawal). This is what lets clan machines
route into every cluster. `bgp.enable` is locked to "any shared-bgp pool
exists" — disabling the fabric without declaring another shared-bgp pool
requires `bgp.enable = false` (both directions are eval errors, §6.12).

Pod/ClusterIP advertisement to hosts stays opt-in and default-off (D13):
`bgp.advertisePodCIDRs` / `bgp.advertiseClusterIPs`.

Floating pools (D8) have a documented failure mode: with no runtime
controller, the VIP is node-fate-bound in practice — when the holding
node dies, the address blackholes until the controller re-homes it. The
VM suites assert exactly that window (the controller itself, e.g. an
hcloud-ip-floater fork, is day-2).

Public `shared-bgp` is opt-in and has hard preconditions: upstream-routed
address space (DHCPv6-PD carve-out, static assignment, or PI space) and a
router you control. Explicit non-goals: BGP over a single dynamic
residential IPv4, and heterogeneous multi-WAN inbound failover (use DNS
failover instead — the Hetzner public edge pattern is node-bound +
floating pools with health-checked DNS failover).

One VIP per cluster: never advertise the same VIP from two clusters.
Cross-cluster traffic goes through ClusterMesh global Services or DNS.

## Firewall posture (SPEC.md §6.12)

The firewall contract: the API listens on the transport only; public ports
open only where a Service exposes them; mesh and BGP traffic is restricted
to expected peers; mirror Services are reachable only from GitOps
namespaces (D30). VM tests assert positive connectivity *and* negative
exposure.
