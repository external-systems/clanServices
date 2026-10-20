# Networking

One Cilium base, one LB-IPAM model, one BGP fabric — on every cluster.

## Transport modes

Every cluster integrates exactly one node transport (SPEC.md §5.3):

| Mode | What it does |
| --- | --- |
| `host-wireguard` (default) | Every node gets a mesh IPv4 and IPv6 address (deterministic from cluster id + machine name) on a host WireGuard interface. Per-machine overrides for addresses, port, endpoint, interface, MTU, routes. |
| `cilium-wireguard` | No host WireGuard resources; Cilium's transparent encryption carries node traffic. You must supply explicit dual-stack node facts. |
| `unencrypted` | No confidentiality claim; explicit facts required. A missing address family is an eval error. |

Dual-stack inside the cluster is mandatory in every mode. Mesh groups
(cross-cluster transport peering) are rendered from exports: remote prefixes
only in `AllowedIPs`, and every remote node InternalIP must be reachable
before ClusterMesh is considered ready. The tunnel MTU budget is transport
MTU minus 50.

## The Cilium base

One canonical upstream Cilium 1.20+ profile on both distros (the RKE2-bundled
Cilium is disabled). Always on: kube-proxy replacement, VXLAN tunnel,
multi-pool pod IPAM, BPF masquerade with tproxy, Maglev, PMTU discovery, and
a default dual-stack pod pool. Cilium is networking-only (D1) — its Gateway
and Ingress controllers are permanently off. Post-merge validation rejects
any `helmValues` that violate routing, tunnel, IPAM, dual-stack, CNI-chaining,
artifact, or ETP invariants.

## The LB pool model: 2 scopes × 4 delivery modes (D8)

A pool is an address inventory plus a `serviceSelector` — nothing else.

**Scope** (who contributes the addresses):

- **Per-machine** — node-named pools built from the node's join address
  (/32 + /128) plus declared extra blocks. Always node-fate-bound.
- **Cluster-global** — generic-named pools (`helsinki-ipv4-1`,
  `fsn-ipv6`). Never node-fate-bound.

**Delivery mode** (how traffic reaches the address, and its failure
semantics):

- `node-fate-bound` — provider/static routing to one node; no failover, no
  BGP.
- `floating` — a runtime controller moves the IP to one node at a time;
  failover timing is the controller's contract (a blackhole window exists);
  requires full local proxy coverage on the candidate set.
- `shared-bgp` — all healthy nodes advertise /32 + /128; the upstream
  router ECMPs; an unhealthy node withdraws via ETP Local.
- `external-class` — a cloud CCM handles it.

Labels like `public=true`, `private=true`, `games=true` are selector labels
on pools of any scope and mode — not a category. A dynamic tenant draw gets
one IP per family; an explicit `lbipam.cilium.io/ips` annotation is a
deliberate projection. Eval asserts: blocks non-overlapping, scope⇒mode
validity, BGP only for `shared-bgp`, floating candidate coverage, and
`shared-bgp` blocks inside router-role prefixes when the router is in the
same inventory.

## BGP and the BIRD fabric (D9)

Cilium agents (GoBGP) originate VIP routes and dial **out** over loopback to
a per-node BIRD daemon — nothing listens on :179. BIRD imports only approved
exact VIPs and exports only those upstream; it never installs mesh, primary,
or transit routes into cluster-node kernels. The upstream router (a NixOS
BIRD host, a MikroTik, a switch) hears the same route from every healthy
node and ECMPs across them. Cilium agents never peer with each other.

Each cluster gets two deterministic private 32-bit ASNs (BIRD-side and
Cilium-side) plus a per-node router id; uniform ASNs mean no multipath
relax. Timers: hold 9, keepalive 3, connect-retry 5 (no BFD in Cilium
1.20). A published foreign-router contract covers ASNs, timers, max-prefix
and prefix filters (accept only pool blocks as /32 + /128), ECMP path
counts, and proxy-NDP on-LAN.

BIRD config is rendered through a vendored named-fragment pattern (D19):
multiple clanServices contribute named, instance-prefixed blocks
(`bgp.<instance>_cilium`, `bgp.<instance>_upstream`) to one BIRD per host,
with nixpkgs' `bird -p` pre-start check as the validator.

## The private fleet fabric (D10)

On by default per cluster: one private `shared-bgp` pool (ULA + RFC1918
carved from the cluster's derived CIDR space), per-node BIRD and BGP v2
resources, and core VIPs on it — the private Gateway and CoreDNS. This is
what lets clan hosts route into every cluster.

Public `shared-bgp` is opt-in and has hard preconditions: upstream-routed
address space (DHCPv6-PD carve-out, static assignment, or PI space) and a
router you control. Explicit non-goals: BGP over a single dynamic
residential IPv4, and heterogeneous multi-WAN inbound failover (use DNS
failover instead — the Hetzner public edge pattern is node-bound + floating
pools with Cloudflare-healthcheck DNS failover).

One VIP per cluster: never advertise the same VIP from two clusters.
Cross-cluster traffic goes through ClusterMesh global Services or DNS.
