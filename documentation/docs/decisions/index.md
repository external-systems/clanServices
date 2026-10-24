# Decision record (D1–D50)

Every normative choice in the project. SPEC.md §4 is authoritative; this is
the human rendering. Revoked entries remain for history.

**Round 14 (2026-10-24) — FRR + per-pair WireGuard + native Cilium.**
Revised D8, D9, D11, D13, D19, D33, D41, D44; added D47–D50. The BIRD/VXLAN
checkpoint at `2995ac3` is legacy, with 5 green / 7 red suites, and is not
round-14 acceptance evidence.

**Round 13 (2026-10-22) — Bootstrap + Data-plane scope.** Added D39–D45;
revoked D2, D4–D7, D15, D17, D18, D20, D28, D29, D31, D32; revised D1, D3,
D8, D22, D26, D27, D35; D36/D37 superseded by D43.

| ID | Status | Decision |
| --- | --- | --- |
| D1 | revised | Cilium is networking-only; Gateway and Ingress permanently off |
| D2 | REVOKED | Envoy Gateway is a day-2 GitOps recipe |
| D3 | revised | Traefik only as stock distro output under `distroDefaults` |
| D4 | REVOKED | Ingress API posture is moot |
| D5 | REVOKED | HAProxy edge proxy; per-node kubeapi HAProxy remains |
| D6 | REVOKED | Gateway ownership/zero-churn layers |
| D7 | REVOKED | Default Gateway pair/listeners |
| D8 | revised (r14) | 2 pool scopes × 5 delivery modes: node-fate-bound, node-bgp, floating, shared-bgp, external-class |
| D9 | revised (r14) | Per-node FRR eBGP full mesh + local Cilium peering; strict filters, BFD, Zebra, ECMP |
| D10 | active | Private shared-bgp fabric default-on; public BGP needs routed space and controlled router |
| D11 | revised (r14) | `fleet-routing` owns the entire flat-L3 fabric; legacy wireguard-mesh retires |
| D12 | active | ClusterMesh apiserver exposure stays node-bound with DNS fan-in |
| D13 | revised (r14) | Native pod routes automatic for Kubernetes; non-Kubernetes pod/ClusterIP access admin-only |
| D14 | active | Raw L4 uses plain LoadBalancer Services |
| D15 | REVOKED | Gateway TLS rule set |
| D16 | active | One cluster per machine |
| D17 | REVOKED | Gateway class/instance structure |
| D18 | REVOKED | Fleet CA/browser trust |
| D19 | revised (r14) | One atomically rendered integrated FRR config per host; no BIRD fragments |
| D20 | REVOKED | Fleet east-west mTLS path |
| D21 | active | `cluster.local` pinned and never served to clients |
| D22 | revised | Private CoreDNS zones; wildcard target is day-2 proxy |
| D23 | active | Upstream kubeadm distro Reserved |
| D24 | active | CNCF in-cluster posture; host FRR/WireGuard/HAProxy exempt |
| D25 | active | RKE2 CIS hardening default |
| D26 | revised | Kubenix two-layer rendering, zero IFD |
| D27 | revised | Rancher helm-controller off except distro defaults |
| D28 | REVOKED | No clan-installed Flux |
| D29 | REVOKED | Replaced by generic bootstrap/GitOps handoff |
| D30 | active | Hub reaches spoke APIs through ClusterMesh mirror Services |
| D31 | REVOKED | external-dns is day-2 |
| D32 | REVOKED | OLM rejection is moot |
| D33 | revised (r14) | Fleet roles member/client/admin/router; dual-role legal; one fleet membership per host |
| D34 | active | Last 3 Kubernetes minors, latest patch |
| D35 | revised | Clan vars own bootstrap plane only |
| D36 | superseded | Carried into D43 |
| D37 | superseded | Carried into D43 |
| D38 | active | Read-only credential never reads Secrets or writes |
| D39 | active (r13) | Exactly two contracts: Bootstrap and Data plane |
| D40 | active (r13) | One SSA bootstrap bundle, then GitOps adoption |
| D41 | revised (r14) | Node IPAM default; BGP class applies to node-bgp and shared-bgp |
| D42 | active | `distroDefaults`; servicelb permanently off |
| D43 | active | GitOps-neutral standalone/hub/spoke control domains |
| D44 | revised (r14) | VM surface covers native/FRR behavior and the two contracts only |
| D45 | active | Shared lib is `lib/kube-cluster/` |
| D46 | active | Uniform clan-rendered CoreDNS |
| D47 | active (r14) | One one-peer WireGuard interface per node pair; AllowedIPs derive from route policy |
| D48 | active (r14) | FRR + Zebra owns routing and kernel FIB |
| D49 | active (r14) | Native-routed multi-pool Cilium mandatory |
| D50 | active (r14) | Inventory owns core host networking through `netif` |

## Round 14 decisions in detail

### D47 — Per-pair routed WireGuard

Every machine has stable dual-stack loopback addresses and exactly one
point-to-point WireGuard interface per remote machine. Each interface has
one peer and deterministic transfer prefixes. Shared prefixes across
interfaces can form kernel ECMP; overlapping peers on one interface cannot.

One UDP session per pair removes the old shared-identity roaming collision.
AllowedIPs and FRR filters derive from one policy. NAT members dial
reachable members with keepalive; a pair with no reachable endpoint fails
evaluation. Full mesh is the supported small/medium-fleet topology.

### D48 — FRR and Zebra

Each node runs one integrated FRR configuration, unique private ASN,
eBGP per address family per link, BFD, strict policy, and multipath-relax.
Cilium peers only with local FRR over `::1`; FRR rewrites the loopback next
hop. Zebra installs remote routes. Rejected: BIRD, direct Cilium fabric
peering, and treating BGP advertisement as a substitute for kernel
forwarding.

### D49 — Native-routed multi-pool Cilium

`routing-mode: native`, no VXLAN/Geneve, and
`auto-direct-node-routes=false`. FRR distributes remote pod-pool routes.
Native-routing CIDRs cover all pods in the ClusterMesh trust domain;
Cilium devices cover all per-pair links. Multi-pool remains the default.
ClusterMesh requires native mode, non-overlap, and working pod routes in
every cluster.

### D50 — Inventory-owned host networking

`netif` declares links, addresses, gateways, routes, policy routing, MTU,
DNS, firewall trust, and deploy-target exports in `inventory.nix`.
`fleet-routing` consumes its peer facts. Supporting modules may handle
Wi-Fi association or platform quirks but cannot own static core routes.
Home's `hostSpec.networking`/`machines.json` static-IP path is removed
during migration; borg supplies behavior and runbooks, not service code.

## Round 13 decisions retained

- **D39/D40:** exactly two contracts; one kubenix bundle applied once with
  SSA, then adopted by the operator's GitOps tool without a first-reconcile
  diff.
- **D41/D42:** Node IPAM serves classless Services; servicelb never runs.
  Minimal distro base by default, stock components only by explicit
  `distroDefaults`.
- **D43:** control domains provide mirror Services, RBAC, and kubeconfigs
  for any GitOps tool; clan installs no GitOps controller.
- **D44/D45/D46:** narrowed test surface, shared `lib/kube-cluster/`, and
  uniform clan-rendered CoreDNS.
