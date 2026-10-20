# Rancher clanServices — Normative Decisions (agent edition)

Machine-readable companion to `rancher-cluster-spec.html` (the full human
record with figures and evidence). **Keep both in sync.** This file is the
normative decision summary; the HTML carries rationale, status evidence, and
figures. §1 of the HTML is always the current-status authority — decisions
below are the *target* contract, mostly unimplemented at baseline `692807c`.

## Decision record (locked 2026-10-19, design review rounds 1–6)

### D1. Cilium is networking base only

Cilium = CNI, kube-proxy replacement, LB IPAM, BGP v2, ClusterMesh.
`gatewayAPI.enabled = false` and `ingressController.enabled = false`
permanently. The old "Cilium default ingress + Gateway" plan and the
`cilium-l4`/`cilium-l7` split are deleted. Reasons: Cilium Gateway has no
HTTP/3 (cilium#28497), no mTLS client validation (GEP-91), no DaemonSet mode,
no multi-Gateway IP sharing (cilium#25567).

### D2. Envoy Gateway is THE default Gateway API / ingress implementation

- EG controller + CRDs + Gateway API CRDs (standard + experimental) are
  always clan-rendered base, like cert-manager. Artifact flake gains one
  atomic `gateway-envoy` component (EG chart + envoy image + CRDs), shared
  upstream profile for both distros, airgap-locked.
- Data plane shape via `EnvoyProxy`: **DaemonSet** on labeled worker nodes,
  `envoyService.externalTrafficPolicy: Local` (EG's default), pool-selector
  labels + `lbipam.cilium.io/ips` projection via
  `envoyService.labels`/`envoyService.annotations`. Never annotate the
  managed Service directly — the controller owns it.
- `mergeGateways` is NOT used on the default class (one bad tenant listener
  would NACK the shared IPv4:443 fleet). Opt-in separate class only.
- mTLS = `ClientTrafficPolicy.spec.tls.clientValidation` (per Gateway or per
  listener via `sectionName`). HTTP/3 = `ClientTrafficPolicy` http3 + UDP
  Service port + firewall UDP. Known upstream bug: http3 + proxyProtocol on
  one ClientTrafficPolicy generates invalid QUIC listeners
  (envoyproxy/gateway#9798).

### D3. Traefik stays first-class 0–N

`ingressGateway.controller = "envoy-gateway" | "traefik"` (default
`envoy-gateway`); selecting Traefik makes it the only ingress/Gateway
implementation. Extra instances default to per-node IPv6 projections.
Traefik mTLS/UDP need its CRDs — acceptable only under D4's policy-CRD rule.

### D4. Ingress API is deprecated entirely

No `networking.k8s.io/v1 Ingress`, no Cilium Ingress, no Traefik
IngressRoute in the rendered base or the recommended tenant path. Gateway
API core lacks mTLS/HTTP3 (GEP-91 experimental, no HTTP3 GEP), so
controller **policy** CRDs (ClientTrafficPolicy, BackendTrafficPolicy,
TLSOption where Traefik is selected) are the sanctioned extension point.
Route CRDs (IngressRoute) are not.

### D5. HAProxy edge-proxy is scrapped

Former §5.13 / Phase 11 deleted. Edge = EG DaemonSet on labeled worker
nodes; every node is Kubernetes-managed. Dropped requirement, recorded:
HTTP response caching (EG exposes no cache API). Cloudflare mTLS =
ClientTrafficPolicy clientValidation with the Cloudflare client CA.
Cloudflare Origin CA issuer is Flux/Sealed-Secrets-owned, never clan vars.

### D6. Three-layer Gateway ownership (zero-churn contract)

| Layer | Owner | Contents |
|---|---|---|
| L1 | clan, always | EG controller, CRDs, LB pools — the platform API |
| L2 | clan, 0–N | `gateway.instances`: GatewayClass + EnvoyProxy + Gateway + projection. **Empty map = fully GitOps-owned Gateway layer, zero NixOS churn — first-class shape, not degenerate** |
| L3 | GitOps, always | Routes, certs, tenant Gateways, raw L4 Services |

Tenants can run a complete Gateway stack against clan pools with no NixOS
rebuild: dynamic labeled pool draw (one IP per family) or explicit
`lbipam.cilium.io/ips` annotation (deliberate, documented). The EG
*controller* is never Flux-managed (artifact pinning is the point); Gateway
*configuration* may be.

### D7. Default Gateway (0–1) — the :443 maximizer

Platform-owned shared Gateway, on by default when L2 is non-empty:

- Listeners: `:80` HTTP (redirect); catch-all `HTTPS:443` terminate with
  the cert-manager default cert; `TLS:443` passthrough (hostname
  MANDATORY — passthrough is unroutable without SNI); HTTP/3 on UDP/443.
- `domains = [ ... ]` → ONE cert-manager Certificate with the SAN list.
  cert-manager Gateway annotation (`cert-manager.io/issuer`) provisions
  listener certs automatically. No ListenerSets (experimental).
- Optional named extra listeners (e.g. `cloudflare`: own hostname, own
  cert, optional ClientTrafficPolicy profile such as Cloudflare mTLS).
- Tenants own Routes (`allowedRoutes` open); platform owns listeners.
  Fluid domains/listeners → Flux-owned Gateway with its own address.
- Exactly one proxy implementation may own a given IP:port. The default
  Gateway claims the node's primary public IPv4 on 80/443; additional
  proxies default to IPv6 carve-outs.

### D8. Pool model: 2 scopes × 4 delivery modes

A `CiliumLoadBalancerIPPool` is address inventory + `serviceSelector`.
Meaning attaches via two axes:

- **Scope** (who contributes addresses):
  - *per-machine* → node-named pools. Auto join-address /32 + /128 blocks +
    declared primary/extra IPs/subnets (Hetzner fixed extra IP/subnet).
    Always node-fate-bound.
  - *cluster-global* → generic-named pools (`helsinki-ipv4-1`, `fsn-ipv6`,
    `bare-metal-helsinki-ipv4-2`). Never node-fate-bound (that's a modeling
    error → move the block to the machine's settings).
- **Delivery mode** (how traffic arrives; failure semantics):

| Mode | Scope | Mechanism | Failure |
|---|---|---|---|
| `node-fate-bound` | per-machine | provider/static routing to one node | none, ever; no BGP |
| `floating` | cluster-global | runtime controller (hcloud-ip-floater style) moves IP, one node at a time | controller's contract, not eval-visible; no route withdrawal; blackhole window → full local proxy coverage on candidate set |
| `shared-bgp` | cluster-global | all healthy nodes advertise /32+/128, router ECMPs | ETP-Local next-hop withdrawal |
| `external-class` | cluster-global | cloud/external controller owns Service class | controller-defined |

- `public=true` / `private=true` / `games=true` are selector LABELS on
  pools of any scope/mode, not a category. Dynamic draw = one IP per
  family; multi-IP explicit annotation = deliberate projection.
- Assertions: blocks non-overlapping; scope⇒mode validity; BGP resources
  only for `shared-bgp`; floating ⇒ declared candidate-node set with full
  local coverage; `shared-bgp` blocks ⊆ router-role-owned prefixes when the
  router is in the same inventory.

### D9. BGP topology and the foreign-router contract

```
upstream router (NixOS BIRD host | MikroTik | switch)
   ▲ eBGP: VIP /32+/128 via node mesh addr — same route from EVERY healthy node
BIRD (per node): import filter = approved VIPs from localhost only;
   export = approved VIPs only (never default/mesh/primary/transit);
   no broad kernel-route install on cluster nodes
   ▲ eBGP over loopback (Cilium dials OUT; no :179 listener)
Cilium GoBGP (per node): ORIGINATES VIP routes; ETP-Local-aware withdraw.
   Agents NEVER peer with each other (no intra-cluster BGP mesh).
```

- ECMP exists only at the upstream router; verify its path limit.
- Deterministic ASNs: 2 private 32-bit ASNs per cluster (BIRD-side,
  Cilium-side) + unique router id per node; uniform per cluster ⇒ no
  multipath-relax needed.
- Timers, not BFD (none in 1.20): hold 9 / keepalive 3 / connect-retry 5.
- Foreign-router contract (published for MikroTik etc.): these ASNs,
  these timers, accept only pool blocks as /32+/128 host routes with
  max-prefix + prefix filters, ECMP path count ≥ node count, proxy-NDP if
  the block is on-LAN rather than routed.

### D10. Private fleet routing fabric is DEFAULT ON

Every cluster renders by default: per-node BIRD + BGP v2 resources, one
private `shared-bgp` pool (ULA + RFC1918 from the derived cluster CIDR
space), and core VIPs on it (private Gateway, CoreDNS). BGP/BIRD therefore
moves EARLIER in the delivery plan (before ClusterMesh and the
fleet-routing service) — it is base, not an add-on phase.

Public `shared-bgp` stays opt-in with stated preconditions: upstream-routed
address space (DHCPv6-PD carve-out, static block, or PI) + a router the
clan controls or contracts with. Non-goals (Out of Scope): single dynamic
residential IPv4 public BGP; heterogeneous multi-WAN inbound failover
(DNS failover is the answer); Hetzner public edge stays node-bound +
floating + Cloudflare-healthcheck DNS failover.

### D11. Fleet-routing clanService (new; working name `cluster-client`)

Gives non-Kubernetes clan NixOS hosts access to cluster VIPs. Two roles:

- `client`: join wireguard-mesh; BIRD peer with cluster nodes; install
  learned routes into the kernel; DNS stub (systemd-resolved/unbound) for
  each cluster's domain → that cluster's CoreDNS VIP. /etc/hosts entries
  remain the zero-BGP fallback.
- `router`: owns declared prefixes (PD carve-outs, static blocks); accepts
  prefix-filtered VIP advertisements from cluster nodes; NDP handling;
  optional default origination. A host may hold both roles — a "client"
  and an "upstream router" are the same BIRD with different peer roles.

Cross-cluster VIP rule: one VIP per cluster; never advertise the same VIP
from two clusters (no coherent fate). Cross-cluster backends = ClusterMesh
global services or DNS across both VIPs.

### D12. ClusterMesh apiserver exposure stays node-bound

Mesh addresses + selectorless-Service DNS fan-in, as already specified.
NOT moved to a shared-BGP VIP: consumers are all mesh members with direct
mesh routes; the mesh control plane takes the fewest dependencies.

### D13. Pod CIDR advertisement to hosts: opt-in, default off

Hosts reach Services via VIPs, never pods directly. Per-cluster option may
advertise `CiliumPodIPPool` prefixes to the host routing domain for
deliberate admin use. Caveats: ephemeral IPs, `world` policy identity,
trust extension, no readiness/load-balancing.

### D14. Raw L4 (Minecraft / Simple Voice Chat / game servers)

Plain `type: LoadBalancer` Services — NEVER Gateways (no L7 value, extra
hop, bad UDP session semantics; Minecraft has no SNI ⇒ one IP:25565 = one
backend or one Velocity proxy). One Service with mixed protocols
(`25565/TCP` + `24454/UDP`) shares one IP. ETP Local preserves player
source IPs. Address: labeled pool draw (e.g. `games=true`), floating pool,
or explicit projection. Velocity/BungeeCord PROXY protocol is a Velocity
config concern, not cluster config.

### D15. One :443, all TLS modes — feasibility contract

One IP:443 can simultaneously: terminate TLS (SNI multi-cert HTTPS
listener), pass through TLS (hostname-filtered TLS listener), validate
client certs (per-listener ClientTrafficPolicy), and serve HTTP/3 (UDP/443
beside TCP/443). Firewall opens TCP+UDP together. This full set is only
satisfiable by EG (see D1), which is why it owns the default web path.

## Delivery-plan deltas (vs HTML §7)

- BGP/BIRD phase moves BEFORE ClusterMesh (D10: private fabric is base).
- Cilium ingress/Gateway phases/suites replaced by EG equivalents
  (`rke2-gateway-envoy` / `k3s-gateway-envoy`): DaemonSet placement, ETP
  Local, projections, L4+L7 on one Gateway, HTTP/3 QUIC proof, mTLS
  accept/reject, cert-manager Gateway integration, source preservation.
- New phase: fleet-routing service (client + router roles, CoreDNS VIP
  DNS stub, route installation, cross-inventory prefix assertions).
- Edge-proxy phase/suite deleted (D5); caching recorded as dropped.
- New suite cases: floating-pool failover semantics (documented
  blackhole window, no route-withdrawal claim), foreign-router peering
  contract (MikroTik-style fixture), zero-clan-Gateway tenant round-trip
  (`gateway.instances = {}`, Flux-created Gateway draws from labeled
  pool), raw-L4 mixed-protocol game Service.

## Glossary deltas (HTML §9.4 additions)

- **Pool scope** — per-machine (node-named) vs cluster-global
  (generic-named); who contributes a pool's addresses.
- **Delivery mode** — node-fate-bound | floating | shared-bgp |
  external-class; how traffic reaches a pool's addresses and what failure
  means.
- **Floating delivery** — a runtime controller moves the address to one
  node at a time; failover is the controller's contract, not eval-visible.
- **Private fleet fabric** — the default per-cluster private shared-bgp
  pool + BIRD/BGP base + CoreDNS/private-Gateway VIPs that lets clan
  NixOS hosts route into every cluster.
- **Shared-gateway model** — platform owns the Gateway + listeners,
  tenants own Routes; cert-manager Gateway integration provisions certs.
- **Zero-churn contract** — `gateway.instances = {}` plus clan pools lets
  tenants run the full Gateway stack via GitOps with no NixOS rebuild.
- **Fleet-routing service** — the clanService (client/router roles)
  giving non-Kubernetes hosts routed access to cluster VIPs.

## Standing rules (unchanged, restated for agents)

- ETP Local on every clan-rendered external proxy Service; no silent
  Cluster fallback.
- Dual-stack internally, always; public families vary per node/Service.
- No Node IPAM for clan-managed proxies; ordinary LB IPAM + explicit
  projection.
- L3 only: no L2 announcements, VRRP, Keepalived, host-network Gateway.
- Everything global is namespaced by `instanceName`.
- `git add` before eval — Nix reads the git tree.
- Amend the spec BEFORE implementing when a test disproves an assumption;
  never edit a test to match a weaker design.
