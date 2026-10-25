# Decision record (D1–D57)

Every normative choice in the project. SPEC.md §4 is authoritative; this is
the human rendering. Revoked entries remain for history.

**Round 16 (2026-10-24) — two topology roles + network facts.** Revised
D33, D52; added D56, D57. Routed-fabric's four exclusive roles
(`member`/`client`/`admin`/`router`) are replaced by **two topology roles**
— `member` and `hub` — with a per-machine orthogonal `access` switch
(`member` default, `client`, `admin`) and an optional orthogonal `border`
capability for upstream transit; hub membership is directly declared by the
`hub` role, not inferred from the union of spoke lists; every member needs
≥1 reachable hub with HA = 2 and no arbitrary maximum. Separately, the
flake will expose a dependency-free, versioned, JSON-serializable,
non-secret, producer-owned **network-facts NixOS interface** at
`clan.networkFacts` (exact schema planned, not implemented) as the neutral
seam for consumer-owned nix-topology diagram wrappers. There is no
implementation or VM evidence for either change yet; phases 5R1–5R4 remain
planned.

**Round 15 (2026-10-24) — routed-fabric, routed-hub MVP, selective
ClusterMesh.** Revised D8, D9, D11, D13, D33, D41, D43, D44, D47, D50;
added D51–D55. The fabric
service is renamed `routed-fabric`: four canonical roles (`member` base,
`client`/`admin`/`router` specialized, no default role), routed-hub
topology as the MVP with full mesh deferred and explicit hub membership
orthogonal to the `router` role, multi-instance multi-link `netif`,
fabric-derived mesh groups with explicit symmetric selective peers, and
transport/egress correctness rules.
Round 14's FRR + WireGuard + native-Cilium data plane stands; the change is
the topology, shape, and strictness of that plane. There is no
implementation or VM evidence for the round-15 shape; phases 5R1–5R3 remain
planned. The four-exclusive-role model of this round is superseded by D56
(round 16), which keeps the same routed-hub data plane.

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
| D8 | revised (r14, r15) | 2 pool scopes × 5 delivery modes: node-fate-bound, node-bgp, floating, shared-bgp, external-class |
| D9 | revised (r15) | Per-node FRR eBGP over declared adjacencies + local Cilium peering; next-hop-self, no iBGP/RR, BFD, Zebra, ECMP |
| D10 | active | Private shared-bgp fabric default-on; public BGP needs routed space and controlled router |
| D11 | revised (r15) | `routed-fabric` (renamed from `fleet-routing`) owns the flat-L3 fabric; legacy wireguard-mesh retires |
| D12 | active | ClusterMesh apiserver exposure stays node-bound with DNS fan-in |
| D13 | revised (r14, r15) | Native pod routes automatic for Kubernetes; non-Kubernetes pod/ClusterIP access admin-only |
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
| D33 | revised (r16) | Two topology roles member/hub; per-machine access member/client/admin (default member); optional border; dual-shape legal; one fabric membership per host |
| D34 | active | Last 3 Kubernetes minors, latest patch |
| D35 | revised | Clan vars own bootstrap plane only |
| D36 | superseded | Carried into D43 |
| D37 | superseded | Carried into D43 |
| D38 | active | Read-only credential never reads Secrets or writes |
| D39 | active (r13) | Exactly two contracts: Bootstrap and Data plane |
| D40 | active (r13) | One SSA bootstrap bundle, then GitOps adoption |
| D41 | revised (r14, r15) | Node IPAM default; BGP class applies to node-bgp and shared-bgp |
| D42 | active | `distroDefaults`; servicelb permanently off |
| D43 | revised (r15) | GitOps-neutral standalone/hub/spoke control domains |
| D44 | revised (r14, r15) | VM surface covers native/FRR behavior and the two contracts only |
| D45 | active | Shared lib is `lib/kube-cluster/` |
| D46 | active | Uniform clan-rendered CoreDNS |
| D47 | revised (r15) | One one-peer WireGuard interface per declared adjacency (routed-hub MVP); AllowedIPs derive from route policy |
| D48 | active (r14) | FRR + Zebra owns routing and kernel FIB |
| D49 | active (r14) | Native-routed multi-pool Cilium mandatory |
| D50 | revised (r15) | Inventory owns core host networking through multi-instance multi-link `netif` |
| D51 | active (r15) | Routed-hub-only MVP; declared adjacencies, eBGP/next-hop-self, two-hub active-active HA, transit and return-path correctness |
| D52 | revised (r16) | `routed-fabric` service: two topology roles (member, hub); hub declared by role, not inferred; access and border orthogonal; fabric-scoped Node IPAM |
| D53 | active (r15) | Multi-instance multi-link `netif`; multiple fabrics segment trust; one fabric membership per host |
| D54 | active (r15) | ClusterMesh full by default in one fabric; explicit symmetric selective peers; mesh group derived from fabric |
| D55 | active (r15) | nftables/no-iptables datapath hygiene; dual-AF local Cilium↔FRR session; official overlays are not underlays |
| D56 | active (r16) | Two topology roles member/hub; orthogonal per-machine access (member default) and optional border; ≥1 reachable hub, HA = 2, no arbitrary max; no router role |
| D57 | active (r16) | Versioned non-secret producer-owned `clan.networkFacts` NixOS interface; nix-topology stays consumer-owned; no clanServices dependency on it |

## Round 16 decisions in detail

### D56 — Two topology roles, orthogonal access and border

Round 15's four exclusive roles (`member` base with `client`/`admin`/
`router` specializations) are replaced by **two topology roles** — `member`
and `hub` — plus two orthogonal, composable per-machine switches:

- **`access = member | client | admin`** (default `member`) controls what a
  machine may consume. `member` is fabric membership plus automatic native
  pod routes on Kubernetes nodes; `client` adds cluster VIP routes and the
  instance-zone DNS stub; `admin` adds pod/ClusterIP routes and the
  svc/pod DNS zones.
- **`border`** (optional) declares that the machine owns upstream transit:
  upstream BGP peers, owned-prefix filtering, forwarding, optional NDP
  (proxy-NDP), and authorized external/fabric transit. A border gets **no
  automatic admin DNS**.

Topology (`member`/`hub`), access (`member`/`client`/`admin`), and `border`
are fully orthogonal: a border need not be a hub, and a hub need not be a
border. Public endpoints do not imply either.

Hubs are the `hub` role: each member names its hubs with
`settings.hubs`, hub-hub links remain explicit, and hub membership is
**directly declared by role** — not inferred solely from the union of spoke
lists. Every member has at least one reachable hub; **HA = 2**; there is
**no arbitrary maximum of two** — more than two hubs is a legal, explicit
operator tradeoff. An all-hub all-to-all fabric is still the deferred full
mesh, not a supported topology.

Terms are kept distinct: a **fabric hub** forwards/readvertises fabric
traffic; a **border** speaks to upstream/external networks; a **default
gateway** is ordinary host routing (DHCP/RA is a separate concern, owned by
`netif`); **Kubernetes Gateway API** is a day-2 in-cluster ingress concern
that clan never renders (D1/D2). Routed ingress requires **source-policy
return**; NAT borders have no automatic conntrack sharing, so
existing-flow failover requires a separate state mechanism.

### D57 — Producer-owned network facts (`clan.networkFacts`)

ClanServices will expose a **dependency-free, versioned, JSON-serializable,
non-secret, per-node network-facts NixOS interface** at
`clan.networkFacts` — the exact option schema is **planned, not
implemented**; option leaves carry defaults so deep evaluation never
breaks. It is **producer-owned and actually read-only**: leaves use NixOS
`readOnly = true`; the service owning each fact populates it from the same
resolved configuration used for functional networking and exports;
wrappers/consumers only read and never define or override values. This
complements the exports system — there is no second source of truth.

Coverage is the complete build-time-declared topology and policy: node
identity; `netif` links/interfaces/networks/addresses/gateways/routes/
policy routes/MTU/DNS/firewall trust; fabric member/hub/access/border,
stable loopbacks, per-adjacency WireGuard links, transfer prefixes, MTU,
public endpoints, AllowedIPs, ASNs, upstreams, FRR prefix policy, and
NAT/source-return intent; and k8s cluster identity, node membership,
distros, CIDRs, pools, Node-IPAM facts, private DNS, and API/mirror
endpoints — as independent underlay/fabric/ClusterMesh/control-domain
graph facts. No
private keys, certificates, tokens, kubeconfigs, or other secrets ever
appear. Dynamic DHCP/RA addresses, BGP-learned routes, live handshakes,
reachability, and failures are **not build-time certainties**: the
interface represents declared mode/intent and never invents values. The
contract is 100% accurate for declared build-time configuration, not
runtime state.

ClanServices must **not** depend on `nix-topology`, import its modules, set
its `topology.*` options, render icons/SVGs, or own diagram packages. A
**consumer-owned wrapper** supplies the nix-topology input/overlay/flake
module/NixOS module, translates `clan.networkFacts` to `topology.*`, and
may expose `packages.<diagram>` or `topology.<system>.config.output`. See
[Network diagrams](../architecture/network-diagrams.md). There is no
implementation or VM evidence for D57 yet.

## Round 15 decisions in detail

### D51 — Routed-hub-only MVP

The MVP topology is **routed-hub**: one WireGuard interface per declared
hub↔spoke or optional hub↔hub adjacency. Hubs forward and readvertise;
spokes never transit. eBGP + BFD + Zebra uses `next-hop-self`; there is no
iBGP, route reflector, route server, or supported full-mesh profile. One
reachable hub is the minimum, two hubs provide active-active HA through
BFD/ECMP, and Kubernetes managers are not hubs by default. Two NAT sites
communicate through hubs; private endpoints are valid when reachable.

`AllowedIPs` is both outbound peer selection and the **inbound source ACL**,
so it includes every authorized transit prefix. External-transit links may
list default entries as a crypto ACL without installing a default route.
Internet ingress requires source-policy return routing through the correct
fabric egress. Stable host routes, per-link MTU derivation, and explicit
per-adjacency endpoint selection are mandatory.

Transparent active-active default gateways for ordinary non-fabric LAN
clients are out of MVP: that requires client routing or an L2/VRRP-like
mechanism. Upstream active-active requires upstream ECMP.

### D52 — routed-fabric and four canonical roles

> **Superseded (round 16, D56).** The role model below — four exclusive
> roles with `router` as the upstream-transit specialization — is replaced
> by two topology roles (`member`, `hub`) plus orthogonal per-machine
> `access` and optional `border`. The fabric-scoped Node IPAM and
> provider-MAC/netif points stand.

The flat-L3 service is renamed `routed-fabric` (the round-14
`fleet-routing` code is legacy). It has **four canonical roles** and no
default role: `member` (fabric transport + automatic Kubernetes pod
routes), `client` (+ VIP routes and instance-zone DNS), `admin` (+
pod/ClusterIP routes and svc/pod DNS), `router` (+ authorized
external/upstream transit). `member` is the base; the others are
specialized. Each spoke declares its hub list on the machine
(`roles.<role>.machines.<name>.settings.hubs`); hub machines are the union
of the spokes' lists, orthogonal to the `router` role.

Node IPAM classless Services are fabric-scoped; public exposure uses
explicit pools. `node-bgp` exists only where BGP delivery exists.
Provider-MAC KubeVirt attachment is netif host-bridge plumbing, not a
Cilium pool or BGP delivery; KubeVirt remains day-2.

### D53 — Multi-instance netif and trust segmentation

`netif` is multi-instance and multi-link: one instance per segment with
site/segment defaults and machine/link overrides (physical/VLAN/bond/bridge,
DHCP/RA/static, gateway/MTU/DNS/routes/endpoint exports). A host joins
multiple instances (public/private NICs, SFP+ groups); cross-instance
checks enforce unique link ownership, no default-route conflicts, and
non-conflicting DNS. `netif` owns underlay policy routing;
`routed-fabric` owns fabric policy routing.

Multiple routed-fabric instances segment trust domains, with one fabric
membership per host. Each supplies the cluster's default mesh-group name.

### D54 — Selective ClusterMesh

ClusterMesh is **full by default within one fabric**. Explicit selective
peers via `mesh.peers` are supported within that fabric: symmetric
(A lists B iff B lists A, eval-asserted) and **non-transitive** — A↔B plus
B↔C gives no A↔C state. Peering bounds the automatic cross-cluster
pod/Service route policy the fabric renders; routed-only exceptions must
be explicit. Separate routed-fabric instances are the hard trust-isolation
boundary. The underlay, fabric, and ClusterMesh graphs are distinct.

### D55 — Datapath hygiene and local Cilium peering

Hosts run an nftables firewall with kube-proxy off and Cilium
`install-iptables-rules=false`, verified by a preliminary probe and VM
assertions. The official `mycelium`/`yggdrasil`/`wireguard` meshes are
alternative overlays, not underlays; standard `peer` exports are the
integration seam.

One local Cilium↔FRR `::1` session carries both address families.
Advertisement selectors and `CiliumPodIPPool` are pinned; extended-next-hop
and dual-family next-hop behavior are probed before the renderer locks.

## Round 14 decisions in detail

### D47 — Per-pair routed WireGuard (revised round 15)

Every machine has stable dual-stack loopback addresses and exactly one
point-to-point WireGuard interface per remote machine. Each interface has
one peer and deterministic transfer prefixes. Shared prefixes across
interfaces can form kernel ECMP; overlapping peers on one interface cannot.

One UDP session per pair removes the old shared-identity roaming collision.
AllowedIPs and FRR filters derive from one policy. NAT members dial
reachable members with keepalive; a pair with no reachable endpoint fails
evaluation. Full mesh is the supported small/medium-fleet topology.

Round 15 (D51) revises this: interfaces are rendered per **declared
adjacency** in a routed-hub MVP (full mesh deferred), and `AllowedIPs`
additionally acts as the inbound source ACL including transit prefixes.

### D48 — FRR and Zebra

Each node runs one integrated FRR configuration, unique private ASN,
eBGP per address family per link, BFD, strict policy, and multipath-relax.
Cilium peers only with local FRR over `::1`; FRR rewrites the loopback
next hop. Zebra installs remote routes. Rejected: BIRD, direct Cilium fabric
peering, and treating BGP advertisement as a substitute for kernel
forwarding.

### D49 — Native-routed multi-pool Cilium

`routing-mode: native`, no VXLAN/Geneve, and
`auto-direct-node-routes=false`. FRR distributes remote pod-pool routes.
Native-routing CIDRs cover all pods in the ClusterMesh trust domain;
Cilium devices cover all fabric links. Multi-pool remains the default.
ClusterMesh requires native mode, non-overlap, and working pod routes in
every cluster.

### D50 — Inventory-owned host networking (revised round 15)

`netif` declares links, addresses, gateways, routes, policy routing, MTU,
DNS, firewall trust, and deploy-target exports in `inventory.nix`.
`fleet-routing` consumes its peer facts. Supporting modules may handle
Wi-Fi association or platform quirks but cannot own static core routes.
Home's `hostSpec.networking`/`machines.json` static-IP path is removed
during migration; borg supplies behavior and runbooks, not service code.

Round 15 (D53) revises this: `netif` is multi-instance and multi-link, and
`routed-fabric` consumes its peer facts.

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
