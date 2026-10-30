# Decision record (D1–D63)

Every normative choice in the project. SPEC.md §4 is authoritative; this is
the human rendering. Revoked entries remain for history.

**Round 21 (2026-10-29) — correctness and stable convergence.** D63 limits
BGP/BFD exposure to fabric interfaces and declared literal upstream sources,
reserves unique WireGuard listen ports through the composable
`clanServices.networking.reservedPorts` list; the shared IfState module's
stable key deduplicates repeated service imports. D63 also eval-enforces
policy, declared-endpoint, mesh, and final-value underlay deploy-target
coherence. Netif and source-return tables share the same kernel/Cilium
reserved set; source-return tables and independent rule priorities have
explicit pins, priorities stay before `main`, and neither tables nor
priorities can collide with netif. IPv6 deploy targets are normalized before
comparison. Explicit
forwarding facts drive `accept_ra = 2`. Fabric adjacencies use symmetric
site/WAN profiles: 300 ms x3 BFD on site, 1000 ms x5 BFD plus BGP 10/30
seconds on WAN. Upstreams always use WAN stability settings. A bilateral
five-second DelayOpen provides a fixed recovery hold-down, not exponential
flap damping; FRR 10.7.1 `bgp_bfd.c` confirms BFD strict hold-time requires
a zero effective BGP hold timer, while FRR route dampening is discouraged
and not dual-stack complete. Hostname families warn instead of triggering
DNS resolution; complete underlay reachability remains phase-5 work. Plain
`bfd` accompanies every profile, site defaults stay implicit, and
`use-underlays-nexthop-weight` is explicit so FRR running config round-trips.
A no-op reload must have an empty dry-run diff, preserve peer uptimes, and
leave the RIB immediately identical rather than waiting for recovery.

**Round 19 (2026-10-28) — artifact authority and static-only checks.** Added
D62: `pkgs` owns shared inputs, overlays, packages, and airgap artifacts; VM
suites moved to `legacyPackages.<system>.vmTests`.

**Round 18 (2026-10-27) — IfState-only static networking.** Added D61;
revised D44 and D50. IfState 2.5.1 exclusively renders physical and virtual
links, addresses, WireGuard peers, static/policy routes, rules, and sysctls
for `netif`, `routed-fabric`, and `wireguard-mesh`. systemd-networkd,
netdevs, scripted network units, NetworkManager, and parallel
`networking.interfaces` ownership are removed without shims. NixOS
activation reconciles changes live without reboot. Per-link hooks own
DHCP clients; kernel RA owns SLAAC; private keys remain runtime includes
from clan vars. FRR/Zebra owns dynamic routes and Cilium owns its datapath.
The full netif, fabric, and k3s/RKE2 native/tunnel/selective/external VM
matrix is green.

**Round 17 (2026-10-25) — generic transport profiles, spine/leaf fabric,
ClusterMesh placement/exposure.** Revised D9, D11, D12, D33, D44, D47,
D49, D51, D52, D54, D56, D57; added D58–D60. The fabric topology roles are renamed
**`leaf`/`spine`** (was `member`/`hub`, D59): every unordered spine pair is
automatically adjacent, every leaf attaches to every spine by default (a
leaf may declare an explicit spine subset), the graph is derived
symmetrically with **no mutual lists**, and full spine peering is **not**
full fabric mesh — leaves never peer with leaves. On top of that, a generic,
neutral **`node_transport` export (schemaVersion 2)** — stable dual-stack
node addresses/instance/endpoint, datapath interfaces keyed by Linux name
with MTU, one `directRoutingDevice`, `datapath.mode native|tunnel` plus
tunnel protocol, `native.routeExchange = local-router` (daemon-neutral, not
`local-frr`/`local-bgp`), and independent `internalLoadBalancer`/`nodePort`
exposure capabilities — replaces service-specific transport facts:
`routed-fabric` is the native + local-router + internalLoadBalancer/nodePort
profile, `wireguard-mesh` is the supported tunnel/VXLAN + nodePort profile,
and k3s/rke2 consume **only** `node_transport`, never branching on service
names. ClusterMesh gains **placement selectors** (voters/workers/all/labels)
and a four-value exposure enum (`auto`, `internal-load-balancer`,
`node-port`, `external-load-balancer`) with a pinned internal IPv4 VIP
from the
existing `<instance>-fabric` private pool, or an explicit external class +
DNS name (D60). The round-17 contract is implemented and VM-proven; it was
originally locked as a docs-only target before its 5R5 implementation.

**Amended 2026-10-26 — ClusterMesh control plane is IPv4-only.** The
pinned Cilium v1.20.3 chart's
[clustermesh-apiserver Deployment](https://github.com/cilium/cilium/blob/v1.20.3/install/kubernetes/cilium/templates/clustermesh-apiserver/deployment.yaml)
embeds etcd with `--listen-client-urls=https://0.0.0.0:2379` and the
template has no dual-stack listener knob, so the round-17 dual-stack
control-plane VIP assumption is false. D60/D10 internal exposure pins ONE
IPv4 VIP at host offset `0x79` (`172.16.<id>.79`); there is no
ClusterMesh IPv6 VIP and no `RequireDualStack` advertisement; NodePort
publishes selected nodes' stable IPv4 addresses; external exposure uses
DNS (runtime A record); cert SANs carry published IPv4/DNS endpoints
only. The ClusterMesh data plane remains dual-stack. D10, D30, D44, D60
wording revised; SPEC.md and this site updated in the same pass.

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
planned. (Round 17, D59, renames the two topology roles `member`/`hub` →
`leaf`/`spine` and derives the adjacency graph automatically; the
`access`/`border` switches stand.)

**Amended 2026-10-25 — member DNS deferred to day-2.** `access` governs
routes only (`client`: VIP routes; `admin`: + pod/ClusterIP routes); the
MVP renders no CoreDNS zones for fabric members — admin machines reach pod
and Service IPs by address and resolve their names day-2 via
Kubernetes-side automation such as external-dns. In-cluster
`cluster.local` DNS (D46) is unchanged. D13/D22/D33 wording revised;
SPEC.md §3.1–§3.3, §5, §6.8, §6.13, §7, §9, §10 updated in the same
change.

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
| D9 | revised (r15, r17) | Per-node FRR eBGP over the derived leaf/spine adjacencies (D59) + local Cilium peering through the daemon-neutral `local-router` exchange (D58); next-hop-self, no iBGP/RR, BFD, Zebra, ECMP |
| D10 | active | Private shared-bgp fabric default-on; public BGP needs routed space and controlled router |
| D11 | revised (r15, r17) | `routed-fabric` (renamed from `fleet-routing`) owns the flat-L3 fabric; `wireguard-mesh` is now a supported tunnel/VXLAN profile (D58) |
| D12 | revised (r17) | ClusterMesh apiserver exposure is profiled (D60): ETP Local for every method, placement selectors, exposure enum `auto`/`internal-load-balancer`/`node-port`/`external-load-balancer` |
| D13 | revised (r14, r15) | Native pod routes automatic for Kubernetes; non-Kubernetes pod/ClusterIP access admin-only |
| D14 | active | Raw L4 uses plain LoadBalancer Services |
| D15 | REVOKED | Gateway TLS rule set |
| D16 | active | One cluster per machine |
| D17 | REVOKED | Gateway class/instance structure |
| D18 | REVOKED | Fleet CA/browser trust |
| D19 | revised (r14) | One atomically rendered integrated FRR config per host; no BIRD fragments |
| D20 | REVOKED | Fleet east-west mTLS path |
| D21 | active | `cluster.local` pinned and never served to clients |
| D22 | revised (r16, 2026-10-25) | Private member DNS zones deferred to day-2 (external-dns); MVP serves routes only |
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
| D33 | revised (r16, r17) | Two topology roles leaf/spine (renamed from member/hub, D59); per-machine access member/client/admin (default member) is baseline membership, not topology; optional border; dual-shape legal; one fabric membership per host |
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
| D44 | revised (r14, r15, r17, r18) | VM surface covers the two contracts plus transport/ClusterMesh and IfState live/DHCP convergence |
| D45 | active | Shared lib is `lib/kube-cluster/` |
| D46 | revised (2026-10-25) | Uniform clan-rendered CoreDNS with the k3s `coredns-custom` import seam (custom ConfigMap is GitOps day-2) |
| D47 | revised (r15, r17) | One one-peer WireGuard interface per derived adjacency (spine/leaf fabric, D59); AllowedIPs derive from route policy |
| D48 | active (r14) | FRR + Zebra owns routing and kernel FIB |
| D49 | revised (r14, r17) | Native-routed multi-pool Cilium is the routed-fabric profile default (D58); the wireguard-mesh tunnel/VXLAN profile is equally supported — native is not mandatory for every overlay |
| D50 | revised (r15, r18) | Inventory owns core host networking through multi-instance multi-link `netif`, rendered exclusively by IfState |
| D51 | revised (r17) | Routed spine/leaf MVP: automatic spine↔spine peering, leaves default to all spines with an explicit subset allowed, eBGP/next-hop-self, two-spine active-active HA with no arbitrary maximum, transit and return-path correctness |
| D52 | revised (r16, r17) | `routed-fabric` service: leaf/spine topology roles (renamed from member/hub); graph derived symmetrically, no mutual lists; access and border orthogonal; fabric-scoped Node IPAM; `routed_fabric` export schemaVersion 2 |
| D53 | active (r15) | Multi-instance multi-link `netif`; multiple fabrics segment trust; one fabric membership per host |
| D54 | revised (r15, r17) | ClusterMesh full by default in one fabric; explicit symmetric selective peers; mesh group derived from fabric; mesh members share datapath mode, tunnel protocol, and maxConnectedClusters |
| D55 | revised (2026-10-25) | nftables host with Cilium KPR rules via iptables-nft; no legacy iptables or kube-proxy rules; dual-AF local Cilium↔FRR session |
| D56 | revised (r16, r17) | Topology roles leaf/spine (renamed from member/hub, D59); orthogonal per-machine access (member default) and optional border; automatic spine graph; two-spine HA, no arbitrary max; no router role |
| D57 | revised (r16, r17) | Versioned non-secret producer-owned `clan.networkFacts` NixOS interface (schemaVersion 2, D59); nix-topology stays consumer-owned; no clanServices dependency on it |
| D58 | active (r17) | Generic neutral `node_transport` export (schemaVersion 2): Linux-name-keyed datapath interfaces + MTU, one directRoutingDevice, datapath.mode native\|tunnel + protocol, native.routeExchange = local-router, internalLoadBalancer/nodePort capabilities; k3s/rke2 consume only node_transport, never branch on service names |
| D59 | active (r17) | Fabric topology roles renamed leaf/spine; automatic symmetric adjacency graph (every spine pair adjacent, leaves default to all spines, explicit leaf subset allowed, no mutual lists); routed_fabric and networkFacts schemas bump to 2 |
| D60 | active (r17, amended 2026-10-26) | ClusterMesh placement selectors (voters/workers/all/labels) and exposure enum auto\|internal-load-balancer\|node-port\|external-load-balancer; NodePort pins exactly one apiserver per selected node; internal exposure is ONE pinned IPv4 VIP (host offset `0x79`) from the existing `<instance>-fabric` pool — control plane IPv4-only on Cilium 1.20.3, data plane stays dual-stack; external always wins with explicit non-clan class + DNS name |
| D61 | active (r18) | IfState 2.5.1 is the exclusive static network renderer; live reconciliation, no networkd/netdev/scripted networking, per-link DHCP hooks, runtime-secret includes, FRR/Cilium ownership boundaries |
| D62 | active (r19) | `pkgs` owns nixpkgs/flake-parts, overlays, runtime packages, and per-system airgap artifacts; clanServices follows and re-exports them; VM suites live under `legacyPackages.<system>.vmTests`, never `checks` |

## Round 19 decisions in detail

### D62 — Artifact authority and static-only checks

`external-systems/pkgs` pins nixpkgs and flake-parts and owns the IfState and
Kubernetes overlays, distro packages, committed manifests, and per-system
airgap outputs. clanServices follows those shared inputs, re-exports the
overlays, and consumes published artifacts instead of rebuilding them. The
`pkgs` input remains replaceable by downstream users, but consumers do not
need to declare it directly.

`clan.nixosTests` is still the declaration interface. The local output adapter
places every suite under `legacyPackages.<system>.vmTests`; `checks` contains
only lightweight static checks. VM derivations must never return to `checks`.

## Round 18 decisions in detail

### D61 — IfState-only static networking

`netif`, `routed-fabric`, and `wireguard-mesh` render one composed
`networking.ifstate.settings` tree. `inputs.pkgs.overlays.ifstate` supplies
IfState 2.5.1; `lib/ifstate.nix` supplies the per-machine base, package
overlay, version assertion, competing-manager assertions, and
Cilium/table-200 ignores. The service
renderers own only their declared objects: netif links/routes and DHCP
hooks, fabric loopback/WireGuard/policy/sysctls, or the mesh's one shared
WireGuard interface. FRR/Zebra and Cilium retain dynamic ownership.

Stage-2 NixOS activation applies settings live through `ifstate.service`;
routers and Kubernetes nodes do not reboot for network changes. Full
reconcile means undeclared objects are cleaned up, so ownership boundaries
and `ifstatecli check` are mandatory. `KillMode=process` preserves hook
daemons after the oneshot. WireGuard keys use runtime `!include` paths from
root-owned clan-vars files, never Nix-store text.

Acceptance covers static live apply/check/restore, DHCPv4/default-route and
SLAAC convergence with one persistent client, real WireGuard handshakes,
fabric HA, both native data planes, and every dependent ClusterMesh
profile. No migration renderer or compatibility shim remains.

## Round 17 decisions in detail

### D58 — Generic `node_transport` transport and capability profiles

Round 17 replaces service-specific transport facts with ONE generic shared
neutral export — **`node_transport`, schemaVersion 2** — consumed by both
distro services:

- stable dual-stack node addresses, instance, and endpoint;
- every datapath interface **keyed by its Linux interface name**, with MTU;
- exactly one **`directRoutingDevice`** naming an exported interface;
- **`datapath.mode`** (`native`|`tunnel`) with sibling
  **`datapath.tunnelProtocol`**; for native mode **`native.routeExchange =
  local-router`** — daemon-neutral (explicitly
  NOT `local-frr`/`local-bgp`);
- independent exposure capabilities **`internalLoadBalancer`** and
  **`nodePort`**; and a **`port`** plus nullable endpoint.

The provider-specific **`routed_fabric`** export remains for ASN, topology,
adjacencies, ACL, `access`, and `border`. **k3s/rke2 consume only
`node_transport`** and never branch on service names — a third-party eval
overlay proves it. The schema is open, with strict validated profiles
initially: `routed-fabric` ⇒ Cilium **native** + `local-router` +
`internalLoadBalancer` + `nodePort`, exporting one interface per derived
adjacency; `wireguard-mesh` ⇒ Cilium
**tunnel/VXLAN** + `nodePort`, exporting its existing ONE full-mesh
multi-peer interface (one peer per remote, stable `/32`+`/128` per
member). Native mode takes the minimum interface MTU;
VXLAN takes the minimum minus 50. Other route-exchange or tunnel modes are
representable in the schema but **rejected until implemented and tested**.
`cilium.helmValues` may not contradict the derived mode, protocol, devices,
`directRoutingDevice`, MTU, or exposure. The cluster-side fabric reference
stays `network.fabric` — D58 changes exports, not that setting.

### D59 — Spine/leaf topology, automatic adjacency graph

The round-16 topology roles **`member`/`hub` are renamed `leaf`/`spine`**.
The `access` enum (`member`/`client`/`admin`, default `member`) is unchanged
— it expresses baseline membership, not topology. The graph is **derived,
not mutually listed**: every unordered spine pair is automatically adjacent;
every leaf attaches to **every spine by default**, and a leaf may declare an
explicit spine subset. **Full spine peering is not full fabric mesh** —
leaves never peer with leaves. One WireGuard interface per adjacency (D47
stands); spines forward/readvertise with `next-hop-self`; leaves never
transit. Two spines are the HA default, with no arbitrary maximum. The
`routed_fabric` export and the `clan.networkFacts` schema bump to
**schemaVersion 2**.

### D60 — ClusterMesh placement and exposure

ClusterMesh apiserver exposure becomes an explicit, eval-validated contract:

- **ETP Local for every exposure method.** ClientIP session affinity is
  useful, but **mTLS is identity** — source preservation is not required
  for identity.
- **Placement selectors:** `voters` (default — server-role nodes),
  `workers` (agents), `all`, or `labels`. Labels may be only
  clan-declared/generated; a selector matching zero nodes is an eval error.
- **NodePort has no replica option**: exactly one apiserver per selected
  node — Deployment `replicas` = the selected-node count, required hostname
  anti-affinity + nodeSelector; all selected nodes' stable IPv4 addresses
  plus a collision-checked NodePort are published — **default `32379`** (the
  upstream default), optional explicit per-machine-collision-checked
  override; rolling update
  `maxSurge=0`, `maxUnavailable=1`.
- **Internal/external LoadBalancer**: replica count is independent —
  default `min(3, eligible)`, user-configurable positive ≤ eligible — with
  required anti-affinity; a stable VIP/DNS means no per-node endpoint
  publication; the same rolling update.
- **Exposure enum** (default `auto`) `auto | internal-load-balancer |
  node-port |
  external-load-balancer`, with the inventory surface normalized as
  `mesh.peers`, `mesh.placement` (default `voters`), `mesh.placementLabels`,
  `mesh.exposure`,
  `mesh.replicas` (LB only; null default; forbidden for node-port),
  `mesh.nodePort` (default `32379`), and
  `mesh.external.{loadBalancerClass,dnsName,annotations}` (external only).
  The revised datapath/exposure facts use `kube_cluster` **schemaVersion
  4** — no compatibility shims:
  - explicit **external** always wins on every overlay, regardless of
    capabilities. It requires an
    explicit non-clan `mesh.external.loadBalancerClass` and a
    `mesh.external.dnsName` (DNS name only,
    never a literal IP), allows provider annotations (external-dns stays
    day-2), and needs no overlay internal capability. The external DNS name
    goes into peers and certificate SANs; dynamic, eval-unknown DNS
    resolution is a runtime prerequisite;
  - **internal-load-balancer** pins ONE IPv4 literal VIP locked at
    **host offset 79 decimal / `0x79`** — `172.16.<id>.79` — in the
    existing D10 `<instance>-fabric` private pool's IPv4 `/24` block
    (analogous to the prior offset-`0x53` convention), with
    `loadBalancerClass: io.cilium/bgp-control-plane` and an explicit
    `lbipam.cilium.io/ips` projection; remote clusters use
    the pinned VIP; no DNS is required; existing private-pool names are
    unchanged. Control-plane exposure is **IPv4-only** on the pinned
    Cilium 1.20.3 profile (the chart's clustermesh-apiserver Deployment
    embeds etcd with `--listen-client-urls=https://0.0.0.0:2379` and no
    dual-stack listener exists), so there is no ClusterMesh IPv6 VIP and
    no `RequireDualStack` advertisement while the data plane stays
    dual-stack. Explicit internal requires the capability. **auto**
    chooses
    internal when capable, else nodePort; unsupported or no method is an
    eval error. The internal VIP is pool-contained and collision-checked
    against every other pinned clan VIP;
  - **node-port** publishes the stable selected node IPv4 addresses;
  - DNS is supported by Cilium for LoadBalancer Services; external-dns
    remains day-2 only.

Mesh groups additionally require the **same datapath mode, tunnel protocol,
and `maxConnectedClusters`** across members (the full-peering default and
symmetric selective peers stand, D54): native members need cross-cluster pod
routes and native-routing CIDRs; tunnel members need node connectivity.

## Round 16 decisions in detail

### D56 — Two topology roles, orthogonal access and border

> **Superseded in part (round 17, D59).** The topology roles are renamed
> `leaf`/`spine`, the adjacency graph is derived automatically (every spine
> pair adjacent; leaves default to all spines with an optional explicit
> subset; no mutual lists), and `routed_fabric`/`networkFacts` schemas bump
> to version 2. The `access`/`border` switches and the orthogonality rules
> below stand unchanged.

Round 15's four exclusive roles (`member` base with `client`/`admin`/
`router` specializations) are replaced by **two topology roles** — `member`
and `hub` — plus two orthogonal, composable per-machine switches:

- **`access = member | client | admin`** (default `member`) controls what a
  machine may consume. `member` is fabric membership plus automatic native
  pod routes on Kubernetes nodes; `client` adds fabric-pool
  LoadBalancer-VIP routes only (never pods or ClusterIPs); `admin` adds
  pod/ClusterIP routes; Kubernetes nodes install pod/VIP routes
  regardless of access (D49). Member DNS is day-2 (D22 amended
  2026-10-25), not an MVP render.
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

> **Amended (round 17, D59).** The network-facts schema bumps to
> **schemaVersion 2** alongside the `routed_fabric` export, and fabric
> topology facts use the `leaf`/`spine` role names.

ClanServices exposes a **dependency-free, versioned, JSON-serializable,
non-secret, per-node network-facts NixOS interface** at
`clan.networkFacts`; option leaves carry defaults so deep evaluation never
breaks. It is **producer-owned and actually read-only**: leaves use NixOS
`readOnly = true`; the service owning each fact populates it from the same
resolved configuration used for functional networking and exports;
wrappers/consumers only read and never define or override values. This
complements the exports system — there is no second source of truth.

Coverage is the complete build-time-declared topology and policy: node
identity; `netif` links/interfaces/networks/addresses/gateways/routes/
policy routes/MTU/DNS/firewall trust; fabric leaf/spine/access/border,
stable loopbacks, per-adjacency WireGuard links, transfer prefixes, MTU,
public endpoints, AllowedIPs, ASNs, upstreams, FRR prefix policy, and
NAT/source-return intent; and k8s cluster identity, node membership,
distros, CIDRs, pools, Node-IPAM facts, and API/mirror
endpoints — as independent underlay/fabric/ClusterMesh/control-domain
graph facts. Member-facing private DNS is never rendered (day-2), so no
private DNS facts exist. No
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
routes), `client` (+ VIP routes and instance-zone DNS, day-2 per the
2026-10-25 amendment), `admin` (+
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
pod/Service route policy the fabric renders. Spine transit is the
eval-visible routed-only exception: a spine carries the union its attached
leaves consume, even when a cluster on that spine does not peer with the
route's origin. One kernel FIB cannot both withhold that route locally and
forward it, so route-isolation proofs use non-transit leaves;
ClusterMesh/global-Service isolation applies everywhere. Separate
routed-fabric instances are the hard trust-isolation boundary. The underlay,
fabric, and ClusterMesh graphs are distinct.

### D55 — Datapath hygiene and local Cilium peering

Hosts run an nftables firewall with kube-proxy off. Cilium 1.20.3 requires
`install-iptables-rules=true` for KPR/BPF masquerade; its required rules use
the `iptables-nft` backend, with no legacy iptables or kube-proxy rules.
The official `mycelium`/`yggdrasil`/`wireguard` meshes are alternative
overlays, not underlays; standard `peer` exports are the integration seam.

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
Round 17 (D59) revises it again: adjacencies are **derived** from the
automatic spine/leaf graph, not declared per pair.

### D48 — FRR and Zebra

Each node runs one integrated FRR configuration, unique private ASN,
eBGP per address family per link, BFD, strict policy, and multipath-relax.
Cilium peers only with local FRR over `::1`; FRR rewrites the loopback
next hop. Zebra installs remote routes. Rejected: BIRD, direct Cilium fabric
peering, and treating BGP advertisement as a substitute for kernel
forwarding.

### D49 — Native-routed multi-pool Cilium

> **Amended (round 17, D58).** Native routing is the **routed-fabric
> profile default**, not a mandate for every overlay: the
> `wireguard-mesh` tunnel/VXLAN profile is equally supported, and a
> ClusterMesh group needs one shared datapath mode + tunnel protocol, not
> native everywhere. The native-profile mechanics below stand.

`routing-mode: native`, no VXLAN/Geneve, and
`auto-direct-node-routes=false`. FRR distributes remote pod-pool routes.
Native-routing CIDRs cover all pods in the ClusterMesh trust domain;
Cilium devices cover all fabric links. Multi-pool remains the default.
Native ClusterMesh members need non-overlap and working pod routes in
every cluster; tunnel members need node connectivity instead.

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
