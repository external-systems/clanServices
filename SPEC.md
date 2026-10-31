# Kubernetes cluster clanServices — Full Specification (agent edition)

Single dense contract for agents; `documentation/` (MkDocs) is the human
record. **Same spec, two renderings — edit both together.** This file is
both the *target contract* and the *status authority*.

Round 22 (2026-10-30): **allocate fabric and mesh values once with clan vars
(D64).** Public, non-deployed generators allocate routed-fabric loopbacks,
node ASNs, adjacency ports and transfer prefixes, and wireguard-mesh node
addresses. Evaluation reads the committed values instead of recomputing them
from machine or instance names. Explicit per-machine and per-adjacency pins
remain collision escapes. Fleet/host collision and pool-disjointness checks
name the targeted regeneration or settings fix; interface names, FRR symbols,
link-local addresses, and cluster-level derived identities remain hash-derived
by design.

Round 21 (2026-10-29): **data-plane correctness and stable convergence
(D63).** BGP/BFD exposure is limited to fabric WireGuard interfaces and
source-restricted declared upstream peers; every IfState WireGuard listen
port is reserved against ephemeral-port reuse. Eval rejects source-return
and netif policy collisions, incompatible literal endpoint families,
unreachable mesh pairs, overlapping mesh AllowedIPs, cross-transport listen
ports, and overlay deploy targets. Forwarding nodes accept RAs with
`accept_ra = 2`. Fabric adjacencies use symmetric `site`/`wan` timer
profiles, a bilateral five-second FRR DelayOpen hold-down, and automatic
maximum-prefix restart. Hostname address families remain a warning because
hermetic eval never performs DNS resolution. Positive and negative nix-unit
coverage and the full static `nix flake check --show-trace` pass. Fresh VM
runs pass `netif` (`NETIF_IFSTATE_LIVE_OK`), `netif-dhcp`
(`NETIF_DHCP_RA_IFSTATE_OK`), `routed-fabric`
(`ROUTED_FABRIC_TRANSPORT_OK`, `ROUTED_FABRIC_SPINE_HA_OK`), and
`k3s-data-plane` (`K3S_DATA_PLANE_OK`). The routed-fabric suite also proves
source-return selection before `main`, negative underlay exposure, an empty
reload diff, preserved peer uptimes, and an immediately identical RIB.

Round 20 (2026-10-29): **status corrections and tooling-only phase 1; no
service behavior change.** A review found routed-fabric and netif claims that
the code or VM suites do not yet meet. Those claims stay in the target
contract and are now marked *(planned)* where they appear; the work to close
them is phased in `documentation/docs/plans/data-plane-hardening.md`, with
one hand-off prompt per phase under `documentation/docs/plans/phase-*/`. From
this round, a *VM-proven* status names its test file and a unique `*_OK`
marker the test prints; VM logs live in
`.baton-pass/vm-logs/<suite>/logs-<n>` (never committed). Verification is a
full `nix flake check` (`checks` is static-only), formatting is alejandra,
breaking changes need no shims, and `targetHost` stays on the underlay
(AGENTS.md rules 2 and 10–12).

Phase 1 is implemented on PR #2 (pending merge). It uses alejandra, statix,
deadnix, and nixf-diagnose through treefmt-nix. The nixf-diagnose gate is
limited to `sema-primop-removed-prefix`, rejecting redundant `builtins.`
prefixes when the prelude builtin is unshadowed. Development inputs and the
checks, formatter,
documentation, slides, and development shell outputs live in a flake-parts
`dev` partition so consumers do not lock `nix-unit` or `presenting`. The root
flake has no test-only follows or nix-unit wrapper: the check evaluates the
root `tests.systems` output directly with offline input overrides. Direct
evaluation exposed two malformed fleet-check diagnostic renderers; their
message formatting is corrected without changing any assertion, and eval tests
cover both collision messages. `apps.<system>.vm-test` builds one suite from
`legacyPackages.<system>.vmTests`, atomically allocates the next numbered
build log under `.baton-pass/vm-logs/<suite>/`, fails on log-creation errors,
records cached output paths, and uses a plain build for `--rebuild` when no
cached output exists; VM suites remain outside `checks`.

Round 19 (2026-10-28): **the artifact flake is the packaging and shared-input
authority (D62).** `external-systems/pkgs` pins nixpkgs and flake-parts, owns
the IfState/Kubernetes overlays and per-system airgap artifacts, and remains a
replaceable transitive input. `clanServices` follows those shared inputs,
re-exports the overlays, and consumes published manifests and images instead
of rebuilding them. VM suites now live only under
`legacyPackages.<system>.vmTests`; `checks` is static-only.

Round 18 (2026-10-27): **IfState 2.5.1 is the exclusive static networking
renderer (D61).** `netif`, `routed-fabric`, and `wireguard-mesh` render
`networking.ifstate.settings`; systemd-networkd, netdevs, scripted network
units, and `networking.interfaces` ownership are removed without shims.
The shared per-machine base applies `inputs.pkgs.overlays.ifstate`,
disables competing managers, ignores Cilium-owned interfaces/table 200,
and preserves hook daemons with `KillMode=process`. Inventory remains the
source of truth for links, addresses, WireGuard peers, static/policy routes,
rules, and sysctls; `ifstate.service` reconciles changes live without
reboot. DHCPv4/DHCPv6 uses per-link hooks, IPv6 SLAAC uses kernel RA, and
WireGuard private keys remain runtime includes from clan vars. FRR/Zebra
owns dynamic routes; Cilium owns its datapath. The complete netif,
routed-fabric, k3s, and RKE2 native/tunnel/selective/external VM matrix is
green on this tree. Round 17's generic transport, leaf/spine fabric, and
ClusterMesh contracts are implemented; historical target wording below is
updated to that status.

Revised 2026-10-24 (round 16, after `1291c21`): **composable fabric
roles and dependency-free network diagrams.** `routed-fabric` now has two
mutually exclusive topology roles, `member` and `hub`; per-machine
`access = member | client | admin` controls route consumption, and
optional `border` configuration owns external/upstream transit. These
three axes are orthogonal: borders need not be hubs, hubs need not be
borders, and access no longer consumes a topology role (D56). Fabric
hubs, borders, default gateways, DHCP, NAT, and Kubernetes Gateway API
remain distinct concepts. Two hubs are the HA profile, not a maximum;
stateful NAT failover is not implied by routed ECMP. A versioned,
non-secret, read-only (`readOnly = true`) `clan.networkFacts` NixOS interface is
the neutral seam from which a consumer-owned nix-topology wrapper can
render buildable diagrams without adding a nix-topology dependency to
clanServices (D57). The facts cover all build-time-declared networking;
dynamic runtime state is labeled, never invented. New decisions D56–D57;
revised: D8, D9, D11, D13, D33, D44, D51, D52. Docs-only under A4 — no
implementation or VM evidence is claimed; the retained baseline stays
5 green / 7 red VM suites.

Amended 2026-10-25 (round 16, member DNS deferral): **no member-facing
cluster DNS in the MVP.** `access` governs ROUTES only — `client` adds
VIP routes, `admin` adds pod/ClusterIP routes; the fabric and the
bootstrap bundle render NO CoreDNS zones for members (no instance-zone,
svc, or pod zones, to any access level). Admin machines still reach
pod/Service IPs over those routes and resolve their names day-2 through
Kubernetes-side automation such as external-dns. In-cluster DNS is
unchanged: the clan-rendered CoreDNS still serves `cluster.local` inside
every cluster (D46). Revised: D13, D22, D33; §3.1–§3.3, §5 invariant
10, §6.8, §6.13, §7, §8, §9, §10.

Round 17 (2026-10-25, retained): **docs-only contract lock — generic
node transport, spine/leaf fabric, ClusterMesh placement/exposure.**
Under A4 this round lands without code changes; no implementation or
new VM evidence is claimed. **D58** defines a generic, shared, neutral
`node_transport` schemaVersion 2, declared OUTSIDE `lib/kube-cluster`:
stable dual-stack node addresses per instance/endpoint; every datapath
interface keyed by its Linux interface name, each with its MTU; exactly
one `directRoutingDevice` naming one of the exported interfaces;
`datapath.mode = native | tunnel` plus the tunnel protocol; for native
mode `routeExchange = local-router` — daemon-neutral, never
`local-frr`/`local-bgp`; and the independent exposure capabilities
`internalLoadBalancer` and `nodePort`. The schema is open — other
route-exchange or tunnel modes are representable — but strict validated
profiles are the initial surface: unsupported profiles are eval-rejected
until implemented and tested. From 5R5, k3s/rke2 consume ONLY
`node_transport`
and never branch on provider service names. **D59** renames the fabric
topology roles `member`/`hub` → `leaf`/`spine` (`access =
member|client|admin` stays — membership, not topology); the adjacency
graph is derived symmetrically — every unordered spine pair is adjacent
automatically, every leaf attaches every spine by default (an explicit
spine subset is allowed), and mutual hub lists are gone; spine-only full
peering is NOT a full fabric mesh (there are no leaf-leaf edges).
`routed_fabric` and `networkFacts` moved to schemaVersion 2, and
`kube_cluster` moved from schemaVersion 3 to 4 in 5R5 with revised
datapath/exposure facts and no shims.
**D60**
locks ClusterMesh placement and exposure: mesh groups require identical
datapath mode, tunnel protocol, and maxConnectedClusters; apiserver
exposure is `auto | internal-load-balancer | node-port |
external-load-balancer` with pinned-VIP internal for the
clustermesh-apiserver ONLY (host offset 79 / 0x79
in the D10 pool, explicit `lbipam.cilium.io/ips` projection; mirror
Services get a separate, future allocation — no offset-79 sharing),
no-replica NodePort (default 32379, optional explicit override), and
external class+DNS semantics; normalized `mesh.*` settings carry the
contract. Member-facing private DNS is wholly day-2 — the MVP renders no
member zones, no private DNS service, and no private CoreDNS VIP (D22
revised again). `wireguard-mesh` is now a SUPPORTED
tunnel transport (Cilium tunnel/VXLAN + nodePort), not pending
retirement. Native-mode Cilium MTU = the minimum interface MTU; VXLAN =
minimum minus 50. There are no external consumers or deployments of
these schemas, so the breaking renames ship without migration shims. New
decisions D58–D60; revised: D9, D11, D12, D33, D44, D47, D49, D51, D52,
D54, D56, D57.

Amended 2026-10-26 (round 17 correction, retained): **ClusterMesh
control-plane exposure is IPv4-only.** The pinned Cilium v1.20.3 chart
proves the round-17 dual-stack control-plane VIP assumption false: the
clustermesh-apiserver Deployment embeds etcd with
`--listen-client-urls=https://0.0.0.0:2379` (IPv4 wildcard;
`--advertise-client-urls=https://localhost:2379`) and the template has
no dual-stack listener knob, so an IPv6 control-plane VIP would be
undialable. D60/D10 internal exposure therefore pins ONE IPv4 VIP at
host offset 79 / 0x79 — `172.16.<id>.79` — with no ClusterMesh IPv6 VIP
and no `RequireDualStack` advertisement; NodePort publishes every
selected node's stable IPv4 address; external exposure uses DNS (a
runtime A record); certificate SANs carry published IPv4/DNS endpoints
only, never unreachable IPv6. The ClusterMesh DATA plane remains
dual-stack (§3.2, §5 invariant 2); no unrelated dual-stack data-plane
or BGP requirement changes. Revised: D10, D30, D44, D60; §3.2, §6.5,
§7, §10, §11.

Round 15 (2026-10-24, retained): **routed-hub MVP, routed-fabric,
multi-instance netif, selective ClusterMesh, nftables-only.** The
supported fabric topology became routed hub/spoke only: one WireGuard
interface per declared adjacency, full mesh dropped from the supported
and tested surface (D51); `fleet-routing` was renamed `routed-fabric`;
`netif` became multi-link and multi-instance with cross-instance
assertions (D53); ClusterMesh defaulted to full peering within one fabric
with explicit symmetric selective peers (D54); AllowedIPs/MTU/source-return
transport blockers, nftables-only firewall with kube-proxy off and
`install-iptables-rules=true`, fabric-scoped Node IPAM, netif bridge
plumbing for KubeVirt attachment, and the dual-AF local Cilium↔FRR
session were closed contractually (D51/D55). New decisions D51–D55;
revised: D8, D9, D11, D13, D33, D41, D43, D44, D47, D50. Round 16
supersedes its four-role and inferred-hub-membership model.

Round 14 (2026-10-24, retained): **FRR, routed WireGuard, and native
Cilium.** The data plane moved to point-to-point host WireGuard, one FRR
routing stack per host with Zebra-owned kernel routes, and Cilium native
routing with multi-pool IPAM. BIRD, VXLAN, and the
ordinary-mesh-plus-auxiliary-routed-interface model are superseded. New
decisions D47–D50; revised: D8, D9, D11, D13, D19, D33, D41, D44. This
round landed docs-only under A4; the BIRD implementation at checkpoint
`2995ac3` is legacy and is not round-14 acceptance evidence. Its
retained baseline is 5 green / 7 red VM suites. The per-remote-machine
interface model and the `fleet-routing` name were revised again in round
15 (D51/D52).

Round 13 (2026-10-22, retained): **data-plane-only scope reduction.** The
contract has exactly two verifiable promises — the Bootstrap contract and
the Data-plane contract (D39). Everything else that was spec'd as
clan-rendered in-cluster software is revoked and becomes documented day-2
GitOps patterns. Round history is retained in §4 with per-decision status.

Round-8 amendments (2026-10-20, retained): **A1** artifact flake packages
the last 3 k8s minors per distro (→ D34). **A2/A3** application-plane
credentials are never clan vars (→ D35, narrowed further in round 13).
**A4** spec locks land without code changes in the same commit — rounds
13, 14, 15, and 16 land docs-only; code changes are scheduled in §8.

## 1. Problem (condensed)

Declare machines, their core host networking, and cluster instances in
`inventory.nix`; receive working, secure, interconnected Kubernetes
clusters (rke2, k3s, upstream kubeadm — D23 Reserved) whose **bootstrap
and data plane are a verifiable contract**. Hard interacting requirements:
multi-cluster identity/CIDR coherence; mandatory dual-stack regardless of
underlay; encrypted flat-L3 reachability across Internet and NAT
boundaries; bare-metal LoadBalancing = allocation + delivery + datapath
(three different things); address families asymmetric in the real world;
artifacts and services have different release cycles; misconfiguration
must fail at eval where possible, VM-proven where not. **Explicitly not
the problem**: which ingress/Gateway/proxy, certificate, storage,
virtualization, or GitOps software runs in the cluster — that is day-2,
owned by GitOps repositories, never by NixOS host configuration. Applying
manifests via `clan machines update` (host churn for in-cluster state) is
the anti-goal this revision removes.

## 2. Architecture in one paragraph

Thin public `rke2` + `k3s` clanServices (upstream `kubernetes`/kubeadm
spec'd, Reserved) sit over a private shared library (`lib/kube-cluster/`,
D45). `netif` owns inventory-declared links — multi-link, multi-instance:
physical, VLAN, bond, bridge; static/DHCP/RA addressing, gateways, MTU,
DNS, underlay routes and underlay policy routing (D53) — plus
deploy-target exports. All three networking services render their static
configuration exclusively through IfState 2.5.1 (D61), which reconciles
live without reboot; no systemd-networkd, netdev, or scripted network
renderer remains. `routed-fabric` owns the flat-L3 fabric: a derived
symmetric spine/leaf graph with one WireGuard interface per adjacency
(leaf↔spine attachments, automatic spine↔spine pairs), per-node FRR/bfdd,
and Zebra-installed routes (D51/D59). Cilium = CNI
+ KPR + **datapath mode derived from `node_transport`** (native on
routed-fabric, tunnel/VXLAN on wireguard-mesh, D58) + multi-pool pod
IPAM + Node IPAM for classless
LoadBalancer Services + LB-IPAM pools + BGP v2 + ClusterMesh — networking
only (D1); kube-proxy is off and Cilium's required datapath rules use
iptables-nft (D55). Every transport publishes the generic, neutral
`node_transport` schemaVersion 2 (D58) and k3s/rke2 consume only that
schema and never branch on provider service names.
Local Cilium agents advertise pod pools and Service VIPs only to their
node-local FRR over one dual-AF session; FRR exchanges filtered routes
across the encrypted fabric — spines forward and readvertise with
next-hop-self, leaves never provide transit — and programs the kernel.
`routed-fabric` has two topology roles: non-transit `leaf` and
forwarding/readvertising `spine`. Per-machine `access` selects member,
VIP, or admin route consumption (membership, not topology; member DNS
is day-2, D22 amended); optional
`border` configuration selects external/upstream transit. Topology, access,
and border are orthogonal (D56). HAProxy on every node gives HA kubeapi access and the join URL. The entire day-1 in-cluster surface is ONE
kubenix-rendered bootstrap bundle, applied once via server-side apply on
the `clusterInit` node (D40) — no Rancher helm-controller, no host-resident
manifest dirs. Clusters run standalone, or as hub/spoke control domains
(D43): clan mints the kubeconfigs, RBAC, and API mirror Services that let
any GitOps tool manage spokes from a hub, but installs no GitOps controller
itself. Day 2 = GitOps takes over: Cilium ownership transfers by adopting
the identical published manifest set, and all other cluster software is
installed and owned by GitOps repos. Artifact flake
(`external-systems/pkgs`) owns shared inputs, overlays, distro runtimes,
committed manifests, per-system airgap images, and test fixtures (D62);
airgap-ready is the tested default. Every networking service also publishes its resolved
build-time facts through dependency-free `clan.networkFacts` NixOS
options; a consumer-owned nix-topology wrapper translates those facts to
buildable diagrams without becoming a clanServices dependency (D57).

## 3. The two contracts (D39)

### 3.1 Bootstrap contract — "the cluster exists and is reachable"

- Distro install/join for rke2, k3s, and (Reserved) kubeadm `kubernetes`;
  mixed distros in one fleet; one cluster per node (D16); RKE2 CIS-hardened
  by default (D25).
- Cluster PKI: CAs, join tokens, admin kubeconfig, read-only
  (no-secrets) kubeconfig (D38); cert generation at bootstrap plus
  documented rotation runbooks and scripts (§6.9/§6.10).
- HAProxy on every node (post-bootstrap) load-balancing that cluster's API
  endpoints rendered from exports; join URL and agent kubeconfigs point at
  it (§6.6).
- The bootstrap bundle: one kubenix-rendered manifest set per cluster
  (Cilium, clan CoreDNS (D46), pools, ClusterMesh config,
  mirror Services, RBAC), applied once by a oneshot on the
  `clusterInit` node via
  `kubectl apply --server-side --field-manager=clan-bootstrap`; nothing
  written to the distro's watched manifests dir; `bootstrap.apply = false`
  is the day-2 off-ramp (D40).
- Control domain (`controlDomain.role = standalone | hub | spoke`, D43):
  API mirror Services (D30; mandatory for spokes), `gitops-hub`
  client-cert identities + in-spoke RBAC + hub-side `gitops-spoke-<spoke>`
  kubeconfig Secrets (D37 revised), read-only credential (D38). **Clan
  never installs a GitOps controller.**
- External CCM knob (`cloudController = none | rancher | external`,
  §6.11): day-1 boot config (kubelet args, uninitialized-taint flow). The
  CCM itself deploys day-2.
- `distroDefaults.enable` (D42): `false` (default) = uniform minimal base
  across all three distros; `true` on rke2/k3s restores stock distro
  behavior (helm-controller, Traefik, optional Multus) via the distro's
  own machinery. servicelb is permanently disabled (Node IPAM replaces
  it, D41/D42).

### 3.2 Data-plane contract — "packets flow correctly"

- Cilium only: one canonical upstream 1.20+ profile — KPR, **datapath
  mode per `node_transport`** (native on routed-fabric, tunnel/VXLAN on
  wireguard-mesh, D58), multi-pool pod IPAM with derived non-clashing
  dual-stack CIDRs, BPF masquerade+tproxy, Maglev, pmtu, kube-proxy off,
  `install-iptables-rules=true` (nftables-only, D55). Native mode:
  `auto-direct-node-routes` is false and FRR/Zebra owns remote pod-pool
  routes through the daemon-neutral `local-router` exchange (D58);
  tunnel mode needs no route exchange. `ipam.mode: kubernetes` remains
  an explicit override. Admin helm-values overrides pass post-merge
  invariant validation and cannot contradict the transport-derived
  mode, protocol, devices, `directRoutingDevice`, MTU, or exposure
  (§6.4).
- **Node IPAM on by default** (`nodeIPAM.enabled=true`,
  `defaultLBServiceIPAM=nodeipam`, D41): classless `type: LoadBalancer`
  Services get node IPs, ServiceLB-style; ETP-Local-aware candidate
  selection. Every explicit pool VIP draw pins
  `io.cilium/bgp-control-plane` to bypass that default and select LB IPAM;
  the class alone does not advertise. BGP advertisements select only
  `node-bgp` and `shared-bgp` pools. `bgpControlPlane.enabled=true` keeps
  the class registered even when `bgp.enable=false` renders no BGP
  resources.
- LB-IPAM pool model with five delivery modes (D8 revised round 15:
  `node-bgp` only where BGP delivery actually exists), BGP v2 +
  per-node FRR/Zebra (D9/D19/D48), default private fleet fabric (D10),
  node-owned BGP pools and shared ECMP pools, plus floating pools via
  runtime controllers.
- ClusterMesh automatic per mesh group (default = fabric instance,
  D54), mixed-distro, datapath-uniform per group (§6.5, D60). Full
  peering is the default; explicit symmetric selective peers are
  supported and peering bounds automatic cross-cluster route policy.
  Native groups need mesh-wide native-routing CIDRs covering every pod
  CIDR of every peered cluster and cross-cluster pod routes before
  readiness; tunnel groups need node connectivity. The mesh DATA plane
  stays dual-stack; apiserver control-plane exposure is IPv4-only on the
  validated Cilium 1.20.3 profile (D60).
- Routed spine/leaf host WireGuard fabric: exactly one point-to-point
  interface per adjacency — leaf↔spine attachments plus automatic
  spine↔spine pairs — never one per remote machine (§6.3, D51/D59).
  eBGP per adjacency with unique node ASNs;
  FRR-BFD monitors every fabric path; spines readvertise with
  next-hop-self, leaves never provide transit. WireGuard `AllowedIPs` —
  outbound cryptokey selection AND inbound source ACL — and BGP filters
  derive from the same route policy; external-transit adjacencies may
  carry 0.0.0.0/0 + ::/0 crypto ACL without an IP default route. D63 scopes
  BGP/BFD exposure, reserves listen ports, validates endpoint/policy
  coherence, and uses stable `site`/`wan` timers with DelayOpen and
  maximum-prefix restart.
- Access-scoped route consumption (D13): Kubernetes machines always
  install remote pod-pool blocks and advertised-VIP routes (native-
  routing requirement, D49); non-Kubernetes `access = "client"` machines
  receive fabric-pool LoadBalancer-VIP routes only; `access = "admin"`
  machines additionally receive pod-pool and ClusterIP routes.
  Member-facing DNS is NOT part of the MVP
  data plane: no CoreDNS zones are served to fabric members; admin
  machines reach pod/Service IPs by address and resolve cluster names
  day-2 via Kubernetes-side automation such as external-dns (D22 amended
  2026-10-25).
- **netif** (multi-link, multi-instance) for inventory-owned
  links/routes (D50/D53) and **routed-fabric** (`leaf`/`spine` topology
  roles plus orthogonal `access` and `border`, D56/D59) for the flat L3
  fabric. **`wireguard-mesh` is a supported tunnel transport** (Cilium
  tunnel/VXLAN + nodePort capability, D58), not a retirement candidate.
- No Gateway, no Ingress, no proxy implementation in the contract. The
  data-plane proof uses native pod round trips, plain `type: LoadBalancer`
  Services, and firewall positive/negative assertions (§7).

### 3.3 Day-2 GitOps — documented patterns, never clan-rendered

GitOps-controller install (Flux or Argo) and takeover of the Cilium
bundle (adopt the identical published set; Kustomization+prune or Argo
tracking — first reconcile is a no-op by construction, D40), Envoy
Gateway (incl. the Node IPAM + ETP Local + `loadBalancerClass` recipe),
cert-manager, external-dns (member-facing cluster DNS lands here per the
D22 amendment), custom in-cluster DNS via the GitOps-managed
`coredns-custom` ConfigMap (imported by the clan CoreDNS, D46 amended),
Sealed Secrets (incl. sealing-key custody),
OpenEBS, KubeVirt, Multus, provider CCMs, hcloud-ip-floater-style
floating-IP movers. These live in `documentation/` as recipes and are
pinned/consumed by the operator's GitOps repos — not by this repo, not by
the artifact flake (D44/pkgs narrowing).

## 4. Decision record (D1–D64)

Statuses: **active** | **REVISED** (round noted) | **REVOKED** (round 13
unless noted) — revoked entries keep one-line reasons for history.

### Active decisions (rounds 1–12, with round-14/15/16/17 revisions)

- **D1 Cilium is networking-only.** (REVISED round 13: reaffirmed, and now
  the ONLY in-cluster Cilium surface.) `gatewayAPI.enabled=false`,
  `ingressController.enabled=false` permanently. Reasons: no Gateway
  HTTP/3 (cilium#28497), no Gateway mTLS (GEP-91), no DaemonSet mode, no
  multi-Gateway IP sharing (cilium#25567). Round-13 consequence: the
  Cilium dummy-Endpoints Node-IPAM limitation never applies here (D41).
- **D8 Pool model: 2 scopes × 5 delivery modes.** (REVISED round 14;
  narrowed round 15; round 16: border-owned prefixes.) Pool = address inventory + `serviceSelector`.
  Scope: *per-machine* → node-named pools with exactly one owner;
  *cluster-global* → generic pools. Delivery: `node-fate-bound`
  (provider/static route, no BGP) | `node-bgp` (only where BGP delivery
  actually exists; only the owner advertises exact /32+/128 VIPs; for
  node-owned IPv4 extras and routed IPv6-subnet carve-outs;
  provider-static node-bound extras remain node-fate-bound) | `floating`
  (runtime controller moves one address; blackhole window) |
  `shared-bgp` (every healthy eligible node advertises; upstream ECMP;
  ETP-Local withdrawal) | `external-class` (cloud CCM). REVISED
  2026-10-25 after the k3s runtime probe: every explicit pool draw pins
  `io.cilium/bgp-control-plane`; `io.cilium/lb-ipam` is not Cilium-handled.
  With Node IPAM as the unset-class default, an unset class cannot draw
  from a pool. The BGP class requests LB-IPAM allocation; advertisement
  remains selector-driven, so non-BGP pools stay unannounced. Assertions:
  non-overlap; scope⇒mode
  validity; `node-bgp` exactly one owner and never shared; `shared-bgp`
  only cluster-global; floating candidate coverage; BGP pool blocks ⊆
  `border.ownedPrefixes` when a border is declared. Classless Node-IPAM
  Services are fabric-scoped and public exposure uses explicit pools
  (D41/D55). One VIP is never advertised by two clusters.
- **D9 BGP topology + foreign-router contract.** (REVISED round 14;
  round 15; round 16: border configuration replaces the router role;
  round 17: leaf/spine naming + local-router exchange, D58/D59.) Every
  fabric node runs FRR/bgpd+bfdd+Zebra with a
  deterministic unique private 32-bit node ASN and a stable mesh IPv4
  router ID. eBGP runs per declared fabric adjacency (D51/D59) — one
  session per address family over each adjacency's WireGuard interface —
  with unique node ASNs, `next-hop-self` toward leaves, and no iBGP,
  route reflectors, or route servers. `bgp ebgp-requires-policy`,
  explicit AF activation, prefix-lists/route-maps, maximum-prefix,
  `maximum-paths`, `bgp bestpath as-path multipath-relax`, and fast
  convergence are mandatory. BFD monitors every fabric adjacency;
  Cilium uses hold 9 / keepalive 3 / connect-retry 5 because Cilium
  1.20 has no BFD. Each cluster has a separate deterministic
  Cilium-side ASN. Cilium dials only its node-local FRR at `::1` in one
  session carrying both address families (no `localPort`) — the
  daemon-neutral `local-router` route-exchange profile (D58); FRR is not
  passive, sets `allow-reserved-ranges` and `bgp allow-martian-nexthop`,
  and rewrites the loopback next hop to the node's stable transport
  address. Spines forward and readvertise with next-hop-self so every
  readvertised path has a directly resolvable next hop; leaves never
  provide transit. Zebra installs accepted remote routes. Cilium agents never
  peer with each other. Foreign routers consume the published
  ASN/CIDR/pool facts, accept only approved exact VIPs and opted-in
  prefixes, and peer through `border.upstreamPeers` (orthogonal to
  spine/leaf topology, D56/D59); cluster-side `bgp.upstreamPeers`
  duplication is removed. Shared VIPs ECMP across advertisers; `node-bgp` VIPs have one
  advertiser.
- **D10 Private fleet routing fabric DEFAULT ON; internal VIPs pinned at
  offset 79.** (REVISED round 17: no private CoreDNS VIP — member-facing
  DNS is wholly day-2, D22.) Per cluster by
  default: local Cilium↔FRR + BGP v2 resources and one private
  `shared-bgp` pool (ULA + RFC1918 from derived cluster CIDR space), with
  a pinned internal VIP for the clustermesh-apiserver (D60).
  Mirror-Service VIP allocation is SEPARATE and FUTURE — it must NOT
  share offset 79 (D30).
  Public `shared-bgp` and `node-bgp` are opt-in; preconditions are
  upstream-routed space plus a controlled router. Non-goals: single
  dynamic residential IPv4 public BGP; heterogeneous multi-WAN inbound
  failover (DNS failover instead). Hetzner public edge = node-bound,
  node-bgp, floating + DNS failover. The fabric pool remains
  `<instance>-fabric` with blocks `172.16.<ciliumId>.0/24` +
  `fd11:<ciliumId>::/64` (overridable; non-overlap and capacity asserted
  — the IPv4 block MUST contain host offset 79, i.e. hold at least 128
  addresses; the default /24 satisfies this, and the old offset-53/
  64-address rule is retired).
  The clustermesh-apiserver VIP is a pinned literal at host offset 79
  decimal
  / 0x79 — `172.16.<ciliumId>.79`, IPv4 ONLY (the pinned Cilium 1.20.3
  clustermesh-apiserver etcd listens on an IPv4 wildcard with no
  dual-stack listener knob, D60) — drawn by
  explicit `lbipam.cilium.io/ips` projection, asserted pool-contained and
  collision-checked against every other pinned clan VIP (D60). No CoreDNS
  VIP is pinned or rendered, and no ClusterMesh IPv6 VIP /
  `RequireDualStack` advertisement exists. `bgp.enable` ⇔
  "any node-bgp or shared-bgp pool exists" is eval-locked (§6.12).
- **D11 routed-fabric is the flat-L3 fabric.** (REVISED round 14:
  fleet-routing; round 15: renamed + routed-hub; round 16: composable
  roles; round 17: leaf/spine naming, D59.) The service (renamed from
  `fleet-routing`, D52) is one trust
  domain per instance; it owns per-adjacency WireGuard (leaf↔spine
  attachments, automatic spine↔spine pairs), FRR, BFD, Zebra route
  installation, topology/access/
  border policy, and fleet route consumption for Kubernetes and
  non-Kubernetes machines (member DNS is day-2, D22 amended). Derived
  spine/leaf is the only supported MVP
  topology (D51/D59); full mesh is deferred, and spine-only full peering
  is not a full fabric mesh (no leaf-leaf edges, D59). `wireguard-mesh`
  is a supported tunnel transport (D58); only its
  ordinary-mesh-plus-auxiliary-routed-interface extension is retired.
  Roles per D33/D56/D59.
- **D12 ClusterMesh apiserver exposure.** (REVISED round 17: exposure
  methods and placement per D60.) Exposure follows the D60 contract —
  `auto | internal-load-balancer | node-port | external-load-balancer` —
  with ETP Local on every method: mTLS identity does not depend on
  source IP, but Local preserves the source, avoids a second hop,
  supports ClientIP affinity, and enables internal-LB withdrawal. The
  same shape generalizes to the kube-apiserver mirror Services (D30)
  and their selectorless-Service DNS fan-in.
- **D13 Pod/ClusterIP consumption is access-scoped.** (REVISED round 14;
  round 15: roles; round 16: `access` setting; 2026-10-25: client/admin
  semantics sharpened; round 17: pod-route exchange is native-mode-only,
  D58.) On native transports Cilium advertises local multi-pool
  allocations to node-local FRR because native routing requires them;
  on tunnel transports pod traffic is encapsulated and no pod routes are
  exchanged. FRR distributes pod routes to all Kubernetes members in the trust
  domain, and every Kubernetes machine installs remote pod-pool blocks
  and advertised-VIP routes REGARDLESS of `access` — native routing
  delegates non-local pod traffic to the kernel FIB (D49), so this is a
  transport requirement, not a consumption choice; ClusterIP routes are
  never installed on Kubernetes nodes (kube-proxy replacement handles
  ClusterIP in eBPF locally). For non-Kubernetes hosts, `access =
  "client"` receives routes to shared-bgp fabric-pool VIPs only — exact
  /32+/128 advertisements for `type: LoadBalancer` Services that drew
  from an explicit pool (pool `serviceSelector` or explicit address
  projection) — never pod blocks, never ClusterIP CIDRs. `access =
  "admin"` consumes every explicitly advertised prefix: pod-pool
  allocation blocks (per-node allocations of every advertised
  `CiliumPodIPPool`), authorized ClusterIP CIDRs, and the pool VIPs.
  Pod-advertisement granularity is the pool's per-node allocation
  block; per-pod selection is not a Cilium BGP feature — bounding pod
  reachability is done by pool design or a deliberate FRR route-policy
  exception (D54). No access level receives cluster DNS in the MVP —
  member name resolution is day-2, delivered by Kubernetes-side
  automation such as external-dns (D22 amended 2026-10-25). `border`
  carries NO automatic admin DNS or pod/ClusterIP consumption; access
  remains an independent least-privilege choice (D56). There is no
  default direct pod/ClusterIP access for ordinary hosts.
- **D14 Raw L4 (games).** Plain `type: LoadBalancer` Services, never
  Gateways. Round-13 note: these are tenant/day-2 objects; the contract
  only guarantees the LB data plane they rely on (D41/D8).
- **D16 One cluster per node.** Inventory-wide eval assertion.
  routed-fabric membership may coexist with cluster membership (D33).
- **D19 One integrated FRR configuration per host.** (REVISED round 14.)
  `routed-fabric` atomically renders `services.frr.config` from inventory
  and exports; distro services publish facts and render Cilium resources,
  never a second routing stack or independent FRR text fragments. Zebra
  owns kernel installation. `bgpd` and `bfdd` are enabled from the first
  implementation. Configuration previews use `frr-reload.py --test`; a
  non-empty add/delete delta still exits zero, so convergence checks inspect
  the delta rather than only the exit status. The 2026-10-24 FRR 10.7.1
  probe proved that NixOS reload starts newly enabled daemons while bgpd
  keeps its PID; a full `frr` restart is not required for daemon-set changes.
  The legacy `clan.bird.fragments` renderer is removed after migration.
- **D21 The internal cluster domain is pinned to `cluster.local`.**
  Never changed, eval-asserted. Aliasing via CoreDNS rewrites (D22).
- **D22 Private-domain routing contract.** (REVISED 2026-10-25, twice:
  member-facing DNS is wholly day-2 — the MVP renders NO member DNS
  zones, NO private DNS service, and NO private CoreDNS VIP; members
  receive routes only, D13.) The day-2 pattern (operator-owned,
  e.g. external-dns publication): client machines resolve ONLY the zone
  `<instance>.<meta.domain>`; the zone's wildcard target is whatever
  day-2
  proxy the operator installs. Per-client opt-ins (default-on for
  `access = "admin"`,
  D33): (a) service zone `<instance>.svc.<meta.domain>` → rewrites to
  `<name>.<ns>.svc.cluster.local` with answer-name reversal;
  (b) pod zone (`pods insecure` + dash-form rewrites + D13 pod
  advertisement). `cluster.local` is NEVER served to clients. MVP: admin
  machines reach pod/Service IPs via D13 routes and resolve their names
  via day-2 automation (e.g. external-dns); nothing in the fabric or the
  bootstrap bundle renders member DNS zones, a private DNS service, or a
  private CoreDNS VIP.
- **D23 Upstream `kubernetes` distro = first-class target, Reserved.**
  kubeadm-based; same shared-lib interfaces, invariants, and rendering
  pipeline. Spec'd fully; implementation Reserved after rke2/k3s
  stabilize. Hard requirement, not optional scope.
- **D24 CNCF in-cluster posture.** Every clan-rendered in-cluster
  component is a CNCF project (Cilium, CoreDNS). Host-level components
  (FRR, WireGuard, HAProxy) exempt. rke2 = documented distro-layer
  exception; `k3s` and `kubernetes` are the CNCF distro paths.
- **D25 RKE2 hardened by default (CIS).** `profile: cis` (v1.29+): PSA
  `restricted` cluster-wide (except `kube-system`),
  protect-kernel-defaults, etcd user/group, CIS sysctls — host
  prerequisites rendered by the NixOS module. Explicit `security.cis =
  false` opt-out. Tenants get a namespace-exemption runbook. k3s/
  kubernetes get equivalent PSA defaults where the distro supports them.
- **D26 Kubenix is the manifest renderer; inflation is an UPDATE-time
  act in the artifact flake.** (REVISED round 13: scope shrinks to the
  bootstrap bundle — Cilium, pools, ClusterMesh config, CoreDNS, mirror
  Services, RBAC — but both layers and the zero-IFD rule are unchanged.)
  Layer 1: the atomic updater renders each pinned chart with the
  canonical fleet-uniform profile via `helm template` semantics and
  COMMITS the manifest into the pkgs repo (`manifests/cilium/
  <version>.yaml`); consumers read committed source — zero IFD.
  Layer 2: kubenix imports the base manifest and applies cluster
  variation by Nix module merging over the typed resource tree (cluster
  name/id, pod CIDRs, nodeipam, mesh peers land in `cilium-config` and
  sibling CRs, NOT in re-run helm values). Post-merge validation rejects
  invariant violations. **IFD defined**: evaluation reading a
  derivation's output — forbidden in clanServices (breaks `--no-build`
  gates).
- **D27 Rancher helm-controller disabled by default** on both distros.
  (REVISED round 13: folded into `distroDefaults`, D42 — the controller
  returns only when the operator opts into stock distro behavior.)
- **D30 Hub → spoke API reachability via ClusterMesh mirror Services.**
  Never touch the real `kubernetes.default` Service. Per cluster that
  exports its API (mandatory for `controlDomain.role = "spoke"`):
  clan-rendered selectorless mirror Service `kube-api-<cluster>` +
  EndpointSlice of API endpoints (D12 fan-in), annotated
  `service.cilium.io/global: "true"`, with `loadBalancerClass` pinned per
  D41/D8. Mirror-Service allocation is separate from D60 and MUST NOT use
  the clustermesh-apiserver's offset-79 VIP.
  Consumers render the same-name Service; ClusterMesh merges endpoints.
  Consumer CoreDNS rewrite (rendered from exports):
  `kubernetes.<cluster>.<meta.domain>` → `kube-api-<cluster>.<ns>.
  svc.cluster.local`. Kubeconfigs (D37/D38) use the mirror DNS name
  directly as `server`; the cluster's API certificate SANs MUST include
  it (eval-asserted). NetworkPolicy restricts mirror-Service access to
  GitOps namespaces. Mesh connectivity is symmetric.
- **D33 routed-fabric topology, access, and border are composable.**
  (REVISED round 14; round 15; round 16: two roles plus settings, D56;
  round 17: roles renamed leaf/spine + symmetric derivation, D59.)
  Two mutually exclusive topology roles, with no default role: `leaf`
  is the non-transit base = fabric membership (per-adjacency WG,
  FRR/BFD/Zebra) and, on a Kubernetes machine, automatic native
  pod-route exchange on native transports (D58); `spine` adds authorized
  forwarding and readvertisement between adjacencies. Per-machine
  `access = "member" | "client" | "admin"`
  defaults to `member` (membership, not topology): `client` adds
  fabric-pool LoadBalancer-VIP routes
  only (D13: Services that drew from an explicit private pool — never
  pods or ClusterIPs); `admin` adds D13 pod/ClusterIP route consumption
  (kamrui-h1); Kubernetes nodes on native transports install pod/VIP
  routes regardless of
  access (native-routing requirement, D49); the D22 zones are day-2, not
  MVP. Optional `border` adds upstream prefix
  ownership, filtered route exchange, forwarding, optional NDP, and
  authorized external/fabric transit — explicitly NOT automatic admin
  DNS. Topology, access, and border are orthogonal. Leaves attach to
  spines — every leaf attaches every spine by default and may declare an
  explicit spine subset; spines are declared directly by the spine role;
  every unordered spine pair is adjacent automatically (symmetric
  derivation, no mutual lists, D59). Every interface has
  one peer and a deterministic instance/adjacency-derived collision-
  checked name ≤15 characters. One machine joins at most one
  `routed-fabric` instance (one trust domain) and holds one topology role
  there. **Node duality is legal** (D16): the same FRR handles local
  Cilium and fabric peers; no self-interface or second BGP stack.
  Kubernetes managers are not spines by default (D51). Canonical test
  shape: kamrui-h1 = single-node k3s + spine role + admin access.
- **D34 Version policy: last 3 minors, latest + support-window gate.**
  Artifact flake packages the last 3 k8s minors per distro, latest patch
  each; servers upgrade first, agents lag per version-skew policy.
  Release-tag pins ONLY. k8s minor parity across distros enforced per
  minor. Eval WARNING when pinned Cilium support matrices don't list a
  pinned k8s minor.
- **D35 Secrets planes: clan vars = bootstrap plane only.** (REVISED
  round 13: the bootstrap plane shrinks to cluster CAs, join tokens,
  admin + read-only kubeconfigs, ClusterMesh CA/certs, HAProxy
  health-check material, and `gitops-hub` control-plane identities.
  Sealed-Secrets sealing keys LEAVE the vars plane — Sealed Secrets is
  wholly day-2, keys included.) All in-cluster application credentials
  are GitOps-owned (A3). Rule of thumb: if k8s/GitOps can rotate or
  serve it, clan vars does not store it — unless clan is the issuer.
- **D36/D37 → superseded by D43** (kept for history): Flux control
  domain modes and hub credential plane — renamed and de-Fluxed in
  round 13; semantics carried into D43.
- **D38 Read-only cluster credential (AI-agent access).** Every cluster
  auto-renders a read-only, no-secrets identity. ClusterRole
  `cluster-readonly` = aggregated `view` PLUS cluster-scoped reads
  (nodes, namespaces, persistentvolumes, storageclasses, ingressclasses,
  gatewayclasses, CRDs, clusterroles, clusterrolebindings,
  priorityclasses) — NEVER `secrets`, never any write verb;
  ClusterRoleBinding `cluster-readonly` binds group `cluster-readers`.
  Shared dependent vars generator `cluster-readonly-<instance>` signs a
  client cert with the cluster CA (CN=`readonly-<instance>`,
  O=`cluster-readers`, 365-day, `validation` pins instance); kubeconfig
  deploys alongside the admin one on server machines. Primary consumer:
  AI agents (handout via `clan vars get`). Hub extension: each spoke's
  read-only kubeconfig synced as Secret `kubeconfig-readonly` in
  `gitops-spoke-<spoke>` (D43). Caveat documented: read-only ≠ harmless;
  the `secrets` exclusion is the hard line. VM-proven positive + negative.

### Revoked in round 13 (retained for history)

- **D2 REVOKED** — Envoy Gateway as clan-rendered base ingress/Gateway.
  Reason: data-plane-only scope; EG is a day-2 GitOps recipe.
- **D4 REVOKED** — Ingress API deprecation posture. Moot: no
  ingress/Gateway surface remains in the contract to deprecate.
- **D5 REVOKED** (already scrapped round 5–7) — HAProxy edge-proxy.
  Unrelated to the retained per-node kubeapi HAProxy (§6.6).
- **D6 REVOKED** — three-layer Gateway ownership / zero-churn contract.
- **D7 REVOKED** — default NS+EW Gateway pair and `web` listener profile.
- **D15 REVOKED** — one IP:443 all-TLS-modes rule set (belongs to the EG
  layer). The underlying principle (one proxy implementation per IP:port)
  survives as the day-2 recipe's constraint.
- **D17 REVOKED** — `gateway.classes`/`gateway.instances` 0–N structure.
- **D18 REVOKED** — fleet CA + browser trust. No clan-issued in-cluster
  TLS remains; ClusterMesh CA (bootstrap plane) is unaffected.
- **D20 REVOKED** — fleet-wide east-west mTLS path (gated, never proven;
  its fleet CA prerequisite is revoked).
- **D28 REVOKED** — clan-rendered flux-operator + FluxInstance. Clan
  never installs a GitOps controller (D43).
- **D29 REVOKED** — replaced by D40 (same Kustomization-handoff idea,
  generalized to any GitOps tool and pinned to the bootstrap-bundle
  mechanism; HelmRelease adoption remains rejected unless the operator
  bootstraps via plain `helm install` themselves — day-2 choice).
- **D31 REVOKED** — external-dns as optional Flux component with
  clan-provided annotation knobs. Wholly day-2; no clan-rendered objects
  remain to annotate.
- **D32 REVOKED** — OLM rejection record. Moot under day-2 scope (the
  reasoning stands if ever re-proposed).

### Round 13 decisions (2026-10-22) — active

- **D39 Two-contract scope.** The clanServices promise exactly two
  verifiable contracts: the Bootstrap contract (§3.1) and the Data-plane
  contract (§3.2). Everything else in-cluster is a documented day-2
  GitOps pattern (§3.3), never clan-rendered, never host-churned.
  Rationale: keeping uniform state through host-resident YAML manifests
  on multiple manager nodes is bad practice — untracked, unsynchronized,
  and redundant once a GitOps repo exists. Test surface narrows to the
  two contracts (D44).
- **D40 Cilium lifecycle: rendered bootstrap bundle → GitOps adoption.**
  The whole day-1 in-cluster surface is ONE kubenix-rendered bundle per
  cluster (D26 layers), applied ONCE at first boot by a systemd oneshot
  on the `clusterInit` node: wait for apiserver health, then
  `kubectl apply --server-side --field-manager=clan-bootstrap`. Never
  the distro manifests dir (nothing host-resident to track or redeploy);
  idempotent (SSA no-op when state matches); `bootstrap.apply = false`
  removes the unit on day 2. Handoff: the identical set is published to
  the GitOps repo; Flux Kustomization (prune on) or Argo CD adopts it.
  First reconcile is a no-op BY CONSTRUCTION (identical bytes, one Nix
  source). Evidence (2026-10-22 research): Flux prune garbage-collects
  only its own `.status.inventory`, so adopting pre-applied objects is
  safe; the Cilium chart ships no `crds/` dir (the operator manages CRDs
  at runtime), so manifest rendering loses nothing and no helm hooks are
  needed; SSA bootstrap (`--server-side`) avoids CSA→SSA field-ownership
  friction. Alternatives rejected: `cilium install` CLI (hidden
  environment-autodetected values make HelmRelease parity fragile —
  documented crash-loop migrations; cert-generation mode skew
  cilium-cli#300); Rancher helm-controller (off per D42); HelmRelease
  adoption without helm release storage (impossible) — operators who
  want HelmRelease ownership bootstrap with plain `helm install` from
  the pinned chart themselves (Flux-maintainer-recommended pattern), a
  documented day-2 variant. Upgrades post-handoff: pkgs bump → rebuild →
  republish → GitOps applies. Publish-freshness gate (published ≡ fresh
  render) lives in the artifact/CI checks, not eval.
- **D41 Node IPAM default; pools keep the VIP plane.** (REVISED round 15:
  fabric-scoped.) Canonical profile sets `nodeIPAM.enabled=true` +
  `defaultLBServiceIPAM=nodeipam`: classless `type: LoadBalancer` Services
  receive node IPs (ExternalIP preferred, else InternalIP), the
  k3s-ServiceLB experience on every distro — including stock Traefik
  under `distroDefaults` — **fabric-scoped**: classless Services are a
  fabric-internal exposure and never a public-exposure mechanism; public
  exposure uses explicit pools (D8/D52). With
  `externalTrafficPolicy: Local` the advertised node set follows real
  EndpointSlices (pod placement); the documented Cilium dummy-Endpoints
  limitation affects only Cilium's own Gateway/Ingress implementations,
  which are permanently disabled (D1) — third-party proxies with real
  backends (Envoy Gateway day-2) are unaffected. Clan-rendered VIP
  consumers (ClusterMesh apiserver, mirror Services)
  draw from pools (D8/D9/D10): every explicit pool draw pins
  `io.cilium/bgp-control-plane`, because the Node-IPAM default owns every
  unset-class Service. This class selects LB-IPAM allocation, not automatic
  advertisement; only `node-bgp` and `shared-bgp` pools are selected by the
  rendered BGP advertisements. `bgpControlPlane.enabled=true` registers
  the class independently of `bgp.enable`, which controls BGP resources.
  KubeVirt Hetzner/provider-MAC attachment is netif host-bridge
  plumbing, never a Cilium pool/BGP delivery; KubeVirt stays day-2
  (D52). Multi-pool remains the
  default pod IPAM with
  derived non-clashing CIDRs; `ipam.mode: kubernetes` is an allowed
  explicit override (the old Node-IPAM ban referred to pod IPAM; both
  readings are now permitted/overridden explicitly).
- **D42 `distroDefaults` knob; servicelb permanently off.** Default
  `distroDefaults.enable = false` gives a uniform minimal base across
  rke2/k3s/kubernetes: no helm-controller, no Traefik, no servicelb, no
  distro add-ons. (Phase-3 reality note: rke2 deploys every packaged
  component as a HelmChart — including rke2-coredns — so D46's uniform
  clan-rendered CoreDNS is also what gives minimal rke2 cluster DNS at
  all; k3s's CoreDNS is a plain AddOn manifest but is disabled too, for
  uniformity.) `true` (rke2/k3s only): the service refrains from
  passing the distro `--disable`/`disable-helm-controller` flags, so the
  distro's packaged components deploy stock and are configured through
  the distro's own HelmChartConfig surface — the operator's day-2
  concern, not clan's. The `kubernetes` distro has no such knob (no
  distro defaults exist — which keeps the minimal base honest).
  servicelb/klipper stays disabled in BOTH modes: Node IPAM (D41) is its
  replacement and two controllers racing on `status.loadBalancer.ingress`
  is a contract violation. Traefik is no longer "removed" (old D3) — it
  is simply never clan-rendered and only exists when the distro itself
  ships it under `distroDefaults`.
- **D43 GitOps-neutral control domain.** (Supersedes D36/D37 naming and
  D28's controller install; REVISED round 15: meshGroup default.)
  `controlDomain.role = standalone | hub | spoke` per cluster instance
  (default `standalone`), bounded by the mesh trust domain (meshGroup
  defaults from the fabric instance — no repeated value; hub+spokes same
  fabric instance; ≤1 hub per group; spoke ⇒ hub exists; eval-asserted). Clan renders ONLY the
  tool-agnostic substrate: mirror Services (D30), in-spoke
  ClusterRoleBinding `gitops-hub` binding group `gitops-hub` →
  `cluster-admin` (configurable role) plus optional per-tenant
  impersonation SAs; per-spoke shared dependent vars generator
  `gitops-hub-client-<spoke>` (CN=`gitops-hub-<spoke>`, O=`gitops-hub`,
  365-day, signed by the SPOKE's cluster CA, `validation` pins
  spoke+group); hub-side namespace `gitops-spoke-<spoke>` holding Secret
  `kubeconfig` (admin) + `kubeconfig-readonly` (D38), delivered via
  vars→hub-machines→in-cluster secret-sync; kubeconfigs use the mirror
  DNS name as `server`. Any GitOps tool consumes this: Flux via
  `KubeConfig.secretRef`, Argo via cluster secrets — day-2 wiring
  documented, not rendered. Rotation = `clan vars generate --regenerate`
  + secret-sync re-apply; spokes unaffected (same CA). Alternatives
  rejected remain rejected (manual SA-token extraction = emergency
  runbook only; offline-minted SA JWTs; expiring bearer tokens + refresh
  CronJobs). Flux-specific hub tree conventions (tenants →
  infra-controllers → …) move to the day-2 docs as examples.
- **D44 Test-surface reduction.** (REVISED rounds 14–17; suite list
  updated for composable roles, network-facts parity, and the round-17
  transport/ClusterMesh contract. Round 20: the routed-fabric NAT-site,
  source/return and filter-negative items are target scope; §7 holds
  their status.) VM suites kept: single/join/HA per distro; netif
  (multi-NIC, VLAN/bond/bridge, multi-instance on one host,
  static/DHCP/RA, exports, cross-instance conflict negatives);
  routed-fabric transport/FRR (two spines + leaves, one WG interface per
  adjacency incl. automatic spine↔spine pairs, two NAT sites via spines,
  BFD both sides,
  RIB-to-FIB, next-hop-self, spine readvertise/leaf no-transit,
  route-filter and default-route negatives, 0/0 crypto ACL without IP
  default route, Internet source/return path, MTU floor + path-MTU);
  data-plane suite per distro (pool allocation + nodeipam + ETP-Local +
  native pod routes + node-bgp ownership + shared-bgp ECMP/withdrawal +
  firewall positive/negative + iptables-nft assertion + dual-AF local
  Cilium↔FRR session); bgp-ecmp (two spines active-active + single-spine
  failure/restore, upstream ECMP, border-not-spine, MikroTik-style FRR
  foreign-router fixture); selective ClusterMesh (full-peering default +
  explicit selective peers + selective isolation); native
  ClusterMesh + mirror-Service reachability; fabric topology/access/border
  (leaf/spine, border-not-spine, composable admin-border and the cluster-node
  dual-shape, client pod isolation, admin svc/pod/ClusterIP, border
  filtering, border-without-automatic-admin-DNS); network-facts eval
  parity across every networking service and a consumer-wrapper diagram
  render test (D57);
  PKI rotation; **GitOps-handoff
  proof** (bootstrap bundle applied, then re-applied SSA under a second
  field manager — strict no-op, dataplane green before/after; no Flux in
  VMs, Flux artifacts were cut from pkgs); rke2 CIS profile. Round-17
  additions (status by suite; k3s/RKE2 native and tunnel external class+DNS
  are VM-proven):
  eval third-party
  node_transport overlay with NO provider service-name branching;
  native internal-load-balancer ClusterMesh (pinned IPv4 VIP + class +
  SANs);
  tunnel NodePort ClusterMesh (one pod per selected node, deterministic
  collision-checked NodePort); external class+DNS exposure on both
  profiles; ClusterMesh placement (voters/workers/all/labels + zero-match
  negative) and group-uniformity negatives; internal-VIP pool membership/
  collision checks; spine/leaf HA ECMP failure/restore with FRR
  reload/restart keeping RIB/FIB stable. Retired:
  full-mesh transport suite (superseded by derived spine/leaf, D51/D59;
  historical), EG gateway matrix, QUIC/Caddy fixtures, flux
  control-domain suite, external-dns, OpenEBS, KubeVirt, Multus,
  sealed-secrets suites.
  go-httpbin remains the one workload fixture.
- **D45 Shared lib renamed `lib/kube-cluster/`.** Supersedes the D23
  rename gate (was: on kubernetes-distro landing). The lib serves all
  three distros' bootstrap+data-plane; "rancher" is the misleading name.
  Code rename landed in phase 1 (§8).
- **D46 Uniform clan-rendered CoreDNS (2026-10-23).** The minimal base
  ships ONE clan-rendered CoreDNS on every distro — rke2, k3s, and the
  Reserved `kubernetes` (kubeadm addon phase skipped) — rendered into the
  bootstrap bundle via kubenix typed resources (no chart, no IFD):
  Deployment + Service (pinned to the derived clusterDNS IP) + Corefile
  ConfigMap + RBAC, digest-pinned image airgap-carried by the artifact
  flake. The distro's bundled CoreDNS is disabled in minimal mode (k3s
  `--disable=coredns`, rke2 `rke2-coredns` always disabled);
  `distroDefaults.enable = true` restores the distro's stock CoreDNS for
  `cluster.local` and skips the clan one. Either mode renders ONLY the
  in-cluster `cluster.local` CoreDNS; member-facing DNS (D22) is wholly
  day-2 — no private CoreDNS service or VIP is rendered in either mode.
  Rationale:
  rke2's bundled CoreDNS cannot carry the rewrite/custom-import
  uniformly; one DNS implementation makes the base identical across
  distros and anticipates D23. NOT bundled, ever: etcd (the distro's
  datastore, not an addon), metrics-server (kubectl top/HPA only,
  non-CNCF, day-2), local-storage/snapshot controllers (day-2). The
  uniform minimal base = distro runtime + Cilium + clan CoreDNS. The clan
  CoreDNS serves `cluster.local` in-cluster only; member-facing private
  zones (D22) are day-2, never in the bootstrap bundle.
  **Custom-config seam (2026-10-25 amendment, k3s convention):** the
  clan-rendered Corefile MUST support the k3s `coredns-custom` import
  convention so day-2 GitOps can extend DNS without clan: the main
  `:53` server block ends with `import /etc/coredns/custom/*.override`;
  additional server blocks are imported via `import /etc/coredns/custom/
  *.server` at Corefile top level; the Deployment mounts ConfigMap
  `coredns-custom` (`kube-system`) read-only at `/etc/coredns/custom`
  as an OPTIONAL volume — pods must boot cleanly with the ConfigMap
  absent. Clan NEVER renders `coredns-custom` itself; it is a
  GitOps-owned day-2 object, exactly as with k3s. Under
  `distroDefaults`, k3s's stock CoreDNS already follows this
  convention; rke2's stock chart does not import `coredns-custom`,
  which is another reason the minimal base renders the clan CoreDNS.

### Round 14 decisions (2026-10-24) — active

- **D47 Per-adjacency routed WireGuard is the only fabric datapath.**
  (REVISED round 15: per-remote-machine full mesh superseded; round 17:
  leaf/spine naming, D59; round 22: committed vars allocate transfers, D64.)
  Every fabric machine has a stable
  dual-stack `/32` + `/128` on a fabric loopback/dummy interface and
  exactly one point-to-point WireGuard interface per **fabric
  adjacency** (leaf↔spine attachments; every unordered spine pair
  automatically, D59) — never one per remote
  machine. Each interface has one peer and transfer prefixes allocated once
  in shared public vars; duplicate prefixes on one host are rejected, while
  overlapping peers on one interface are forbidden. One UDP session per
  adjacency removes the legacy shared-identity roaming collision.
  AllowedIPs is both outbound cryptokey selection and the inbound source
  ACL: it carries the remote stable host addresses plus every approved
  transit source/destination prefix on that adjacency, and
  external-transit adjacencies may include 0.0.0.0/0 and ::/0 as crypto
  ACL without creating or accepting an IP default route (D51). NAT
  members dial reachable members with keepalive 25; two NAT sites never
  peer directly — they communicate through spines; an adjacency with no
  reachable endpoint on either side is an eval error. Per-link WG MTU
  derives from the underlay MTU minus WireGuard overhead with a safe
  floor, and VMs assert path MTU (D51). Endpoint reachability is per
  declared adjacency; private endpoints are allowed when actually
  reachable; netif peer exports provide automatic endpoint selection
  with explicit overrides. Derived spine/leaf is the supported MVP
  topology (D59); full mesh is deferred. (Round-14 history: one interface per
  remote machine in an encrypted full mesh, identical prefixes as ECMP,
  hidden hub-and-spoke/route-reflector variants excluded.)
- **D48 FRR + Zebra owns the routing control plane and kernel FIB.** FRR
  10.7+ uses one integrated config, eBGP per AF per WG link, BFD on every
  FRR path, strict bidirectional policy, and ECMP across interfaces.
  Cilium only advertises to local FRR. Rejected: BIRD (superseded),
  Cilium agents peering directly across the fleet (couples manifests to
  transport and lacks BFD), and treating BGP itself as the datapath
  (Zebra/kernel forwarding is the datapath).
- **D49 Native-routed multi-pool Cilium is mandatory on native
  transports.** (REVISED round 17: datapath mode is transport-derived,
  D58.) On a native transport (routed-fabric): `routing-mode:
  native`, no tunnel, `auto-direct-node-routes=false`, dual-stack
  mesh-wide native-routing CIDRs, and Cilium devices covering every
  fabric WG interface (one per adjacency, D51/D59). FRR distributes
  remote `CiliumPodIPPool` routes over the `local-router` exchange (D58);
  native ClusterMesh groups need non-overlap and working pod routes in
  every member (D60). On a tunnel transport (wireguard-mesh): Cilium
  tunnel/VXLAN with node connectivity only; no pod routes are exchanged.
  Multi-pool remains the default pod IPAM on both; `ipam.mode: kubernetes`
  remains an explicit override. Cilium stays networking-only and no L7
  feature is enabled.
- **D50 Inventory owns the core host data plane.** (REVISED round 15:
  multi-link, multi-instance; round 18: IfState-only rendering, D61.)
  `netif` declares links, static/DHCP/RA addressing, gateways, routes,
  MTU, DNS, firewall trust, underlay policy routing, and deploy-target
  exports in `inventory.nix` — multi-link and multi-instance, including
  multiple netif instances on one host (D53). An instance is a
  site/segment with shared defaults plus per-machine and per-link
  overrides; links may be physical, VLAN, bond, or bridge. `netif` owns
  underlay policy routing; `routed-fabric` owns fabric-specific policy
  routing (D53). `routed-fabric` consumes its peer facts. Cross-instance
  assertions: unique link ownership (one link, one instance), no
  default-route conflicts, no DNS conflicts, and instance-namespaced
  DHCP hooks (rule 5). Supporting NixOS modules may handle Wi-Fi
  association or platform quirks, but cannot own static core
  addresses/routes or enable a competing network manager. Home's
  `hostSpec.networking`/`machines.json` static-IP ownership is removed;
  borg's `lan` is a behavioral reference, not code to preserve.

### Round 15 decisions (2026-10-24) — active

- **D51 Derived spine/leaf is the only MVP transport topology.** (REVISED
  round 16: direct hub role and member attachment; round 17: renamed
  leaf/spine with a symmetric derived graph, D59; round 22: node ASNs are
  allocated public vars, D64.) Exactly one WireGuard
  interface per fabric adjacency — leaf↔spine attachments plus automatic
  spine↔spine pairs (D59) — never one per remote machine; full mesh
  is deferred beyond MVP and leaves the supported and tested surface
  (round-14 per-pair full-mesh text retained historically in D47). Every
  fabric node keeps its stable dual-stack `/32`+`/128` loopback (D47) and
  runs FRR bgpd+bfdd+Zebra (D48). eBGP per adjacency with committed,
  fleet-unique private 32-bit node ASNs, one session per address family per
  adjacency interface, BFD on every adjacency, and `next-hop-self` on
  spine
  readvertisement so every distributed next hop is directly resolvable.
  Spine-role machines forward and readvertise; leaf-role machines never
  transit except for explicitly authorized border traffic. No iBGP, no
  route reflectors, no route servers. The graph is derived symmetrically:
  every leaf attaches every spine by default (an explicit spine subset is
  allowed) and every unordered spine pair is adjacent automatically — no
  mutual hub lists. One spine is the minimum, two are the HA profile, and
  there is no arbitrary
  maximum: additional spines must be an explicit capacity/failure-domain
  choice. Spine-only full peering is NOT a full fabric mesh: there are no
  leaf-leaf edges. Public endpoints alone do not imply spine or border
  placement.
  Kubernetes managers are not spines by default. Active-active spine HA is
  pure fabric ECMP — every leaf links both spines, eBGP/BFD on both, FRR
  `maximum-paths` + multipath-relax; no shared gateway VIP, no VRRP.
  Upstream active-active requires upstream ECMP. Transparent active-active
  default gateway for ordinary non-fabric LAN clients is OUTSIDE MVP: it
  needs client routing or an L2/VRRP-like mechanism. AllowedIPs is both
  outbound cryptokey selection and the inbound source ACL, so it carries
  every approved transit source/destination prefix on the adjacency;
  external-transit adjacencies may include 0.0.0.0/0 and ::/0 as crypto
  ACL WITHOUT creating or accepting an IP default route. Internet ingress
  through a border requires source-policy return routing through the
  correct fabric egress — no asymmetric local-WAN reply. Pure routed HA
  does not imply stateful NAT failover: multiple NAT borders do not
  preserve conntrack state or guarantee existing-flow continuity without
  a separate state mechanism. Fabric-originated routes are stable
  /32+/128. NAT members keepalive 25; two NAT sites never peer directly —
  they communicate through spines. Per-link WG MTU derives from the underlay
  MTU minus WireGuard overhead (80 bytes v4 / 96 v6) with a 1280 floor,
  and VMs assert path MTU. Endpoint reachability is evaluated per
  adjacency; private endpoints are allowed when actually reachable; netif
  peer exports provide automatic endpoint selection with explicit
  per-adjacency overrides. Making every node a spine and linking every
  pair is full mesh, not a way around the deferred-topology boundary.
- **D52 `routed-fabric` replaces `fleet-routing`.** (REVISED round 16:
  four-role model superseded by D56; round 17: spine/leaf naming, D59.)
  The service name and trust-domain
  boundary remain; topology/access/border semantics are defined by
  D33/D56/D59. Fabric spine/leaf is distinct from control-domain hub/spoke of
  D43 (GitOps control, §6.14 naming note). Pool/exposure scope: Node IPAM
  classless Services are fabric-scoped; public exposure uses explicit
  pools; `node-bgp` exists only where BGP delivery actually exists and
  provider-static node-bound extras remain node-fate-bound;
  Hetzner/provider-MAC KubeVirt attachment is netif host-bridge plumbing,
  never a Cilium pool/BGP delivery — KubeVirt remains day-2
  (D8/D41 revised).
- **D53 netif is multi-link and multi-instance.** An instance = one
  site/segment with shared defaults plus per-machine and per-link
  overrides; multiple netif instances may coexist on one host. Links:
  physical, VLAN, bond, bridge; addressing static/DHCP/RA; gateways,
  MTU, DNS, underlay routes, endpoint exports. Cross-instance
  assertions: unique link ownership (one link, one instance), no
  default-route conflicts, no DNS conflicts, instance-namespaced units
  (rule 5). Ownership split: netif owns underlay policy routing;
  `routed-fabric` owns fabric-specific policy routing. Multiple
  `routed-fabric` instances are separate trust domains, and a machine
  joins at most one (its meshGroup defaults from it, D43/D54).
- **D54 ClusterMesh: full peering by default, selective peers
  supported.** (REVISED round 17: group datapath uniformity, D60.)
  Within one fabric instance the default is full peering
  among its clusters; explicit symmetric selective peers are supported —
  a central cluster may peer A↔B and B↔C while A and C do not peer.
  ClusterMesh groups require identical datapath mode, tunnel protocol,
  and maxConnectedClusters across members: native groups need
  cross-cluster pod routes and mesh-wide native CIDRs (D49); tunnel
  groups need node connectivity.
  Peering state is non-transitive. Peering alone is not isolation:
  selective peers also bound the automatic cross-cluster pod/Service
  route policy rendered into fabric filters; a routed-only exception
  between non-peered clusters must be deliberate and eval-visible. Spine
  transit is that exception: a spine carries the union its attached leaves
  consume, even when a cluster on that spine does not peer with the route's
  origin. A single kernel FIB cannot both withhold such a route locally and
  forward it, so leaf-local route isolation is proven on non-transit leaves;
  ClusterMesh/global-Service isolation still applies on every node.
  Separate `routed-fabric` instances provide HARD trust-domain
  separation (no mesh, no routes, no DNS across instances). Three
  distinct graphs: the **underlay graph** (netif links), the **fabric
  graph** (routed-fabric adjacencies), the **ClusterMesh graph**
  (peering edges) — similar shapes, independent edges. `meshGroup`
  defaults from the fabric instance; no repeated value required.
- **D55 Host datapath hygiene: nftables-only firewall + dual-AF local
  Cilium session.** (REVISED 2026-10-25 from the k3s data-plane VM failure.)
  (i) Host firewall is nftables-only; kube-proxy is off. Cilium 1.20.3
  rejects KPR/BPF masquerade with `install-iptables-rules=false`, so the
  canonical profile sets the supported `extraConfig."install-iptables-rules"
  = true` key and layer 2 preserves it. Cilium's required datapath rules use
  `iptables-nft`; legacy iptables and kube-proxy rules are forbidden.
  Cilium 1.20.3 exposes no `installIptablesRules` Helm value. Official
  mycelium/yggdrasil/wireguard overlays are NOT dependencies or underlays —
  peer exports are the integration seam.
  (ii) The local Cilium↔FRR `::1` session carries BOTH address
  families; advertisement selectors and the `CiliumPodIPPool` type are
  pinned; explicit `extended-nexthop` capability and v4-over-v6 /
  v6-over-v4 next-hop behavior must be PROBED before the renderer locks
  (5R2); the Cilium GR posture (timers, restart behavior, capability
  fallback) is explicit enough for tests.

### Round 16 decisions (2026-10-24) — active

- **D56 Two fabric topology roles plus orthogonal access and border.**
  (REVISED round 17: roles renamed `leaf`/`spine`, D59.)
  `routed-fabric` roles are exactly `leaf` and `spine` (rounds 15–16
  called them `member`/`hub`); no role is
  selected by default. `leaf` is a non-transit participant; `spine`
  forwards and
  readvertises between authorized adjacencies. Spine↔spine adjacencies
  are automatic for every unordered spine pair; every leaf attaches every
  spine by default and may declare an explicit spine subset; the graph is
  derived symmetrically — no mutual lists (D59). Spine-ness is directly
  visible in the spine machine's role, not inferred only from the union
  of leaf settings. Per-machine `access =
  "member" | "client" | "admin"` defaults to `member` — membership, not
  topology — and implements
  D13/D22; it does not alter topology. Optional `border` configuration
  contains upstream peers, `ownedPrefixes`, filtered route exchange,
  forwarding/NDP policy, and authorized external/fabric transit. Border
  is not a role and grants no automatic admin DNS or route consumption.
  Topology, access, and border may be combined on one machine without
  weakening least-privilege defaults. A fabric spine is internal transit; a
  border is external transit; a default gateway is a route next hop; DHCP
  and NAT are separate functions; Kubernetes Gateway API is day-2
  application traffic management. None is a synonym for another. A border
  is not necessarily a spine, is not inherently a public-WAN node, and does
  not automatically supply public addresses, NAT, or a default route. A
  border leaf remains non-transit for ordinary fabric routes; only its
  explicitly authorized upstream policy is added. Kubernetes leaves can
  originate private pod/VIP pools without any border; border configuration
  is needed only when selected prefixes cross the fabric boundary through
  an upstream router, and public reachability requires actual upstream
  routing and return policy. Automatic spine-pair and leaf-spine adjacency
  derivation is instance-scoped: spines in different routed-fabric
  instances never auto-peer, even when an operator describes them as one
  administrative domain. Separate instances remain hard trust-domain
  boundaries; cross-instance connectivity requires deliberate external
  routing through border/upstream policy.
- **D57 Dependency-free network facts; consumer-owned nix-topology.**
  (REVISED round 17: `networkFacts` moves to schemaVersion 2 with
  leaf/spine fabric facts, D59.)
  ClanServices expose a versioned, JSON-serializable, non-secret,
  per-node `clan.networkFacts` NixOS interface. Producers populate only
  facts they own; leaves use `readOnly = true`, have safe defaults for
  deep evaluation, and derive from the SAME resolved configuration that
  renders functional NixOS networking and public exports. Consumers never
  define or override them. The schema is declared without importing
  nix-topology and covers node identity; netif networks/links/interfaces/
  addressing/gateways/routes/policy routes/MTU/DNS/firewall trust; fabric
  topology/access/border, stable addresses, per-adjacency WireGuard
  interfaces/transfer prefixes/public endpoints/MTU/AllowedIPs, ASNs,
  upstreams, FRR prefix policy, NAT/source-return intent; Kubernetes
  distro/cluster membership/CIDRs/pools/Node-IPAM facts and
  API/mirror endpoints; and the independent underlay, fabric, ClusterMesh,
  and control-domain graphs. No private keys, certificates, tokens,
  kubeconfigs, or other secrets enter facts. Facts are complete and
  accurate for build-time-declared configuration, not a claim about
  runtime: DHCP/RA modes, learned routes, handshakes, reachability,
  health, and failover state are represented as declared intent or left
  unknown, never invented. ClanServices never depend on nix-topology,
  set its `topology.*` options, supply icons/renderers, or own diagram
  packages. A consumer-owned wrapper supplies nix-topology and its
  NixOS/flake integration, translates `clan.networkFacts` into
  `topology.*`, and may expose `topology.<system>.config.output` and
  `packages.<diagram>` as buildable SVG artifacts. Automatic NixOS
  extraction may supplement, but never replace or contradict, these
  authoritative facts. Facts/export/render parity is eval-tested; one
  consumer-wrapper build proves the translation seam.

### Round 17 decisions (2026-10-25) — active

- **D58 Generic `node_transport` schemaVersion 2 — the only transport
  seam.** Supersedes the ad-hoc per-service transport exports: k3s/rke2
  consume ONLY `node_transport` and never branch on provider service
  names. The schema is shared, neutral, and declared OUTSIDE
  `lib/kube-cluster` so third-party overlays can implement it. Per
  instance and endpoint it pins: stable dual-stack node addresses; the
  instance identity; every datapath interface keyed by its Linux
  interface name, each with its MTU; exactly one `directRoutingDevice`
  naming one of the exported interfaces; `datapath.mode = native |
  tunnel` with sibling `datapath.tunnelProtocol` (vxlan for the only
  supported tunnel initially) and, for native mode, `native.routeExchange
  = local-router` — daemon-neutral, never `local-frr`/`local-bgp`
  (`native.routeExchange` is null on tunnel transports); and the
  independent
  exposure capabilities `internalLoadBalancer` and `nodePort`; and
  `port`. The
  schema is open — other route-exchange or tunnel modes are
  representable — but strict validated profiles are the initial
  surface: unsupported profiles are eval-rejected until implemented and
  tested. Provider-specific `routed_fabric` remains the source for
  ASN/topology/adjacencies/ACL/access/border. Admin overrides cannot
  contradict the derived mode, protocol, devices, `directRoutingDevice`,
  MTU, or exposure. Supported profiles: `routed-fabric` ⇒ Cilium native
  + `local-router` route exchange + `internalLoadBalancer` AND
  `nodePort` capabilities; `wireguard-mesh` ⇒ Cilium tunnel/VXLAN +
  `nodePort`. Native-mode Cilium MTU = the minimum interface MTU; VXLAN
  = minimum minus 50. Because `cilium-config` is cluster-wide,
  `directRoutingDevice` must be identical and present on every cluster node;
  routed-fabric therefore always exports its stable loopback and uses it as
  the direct device, while the broader `devices` set also retains every
  per-adjacency interface. Machine-local adjacency names must not be copied
  from the cluster-init node into the shared direct-device value.
- **D59 Spine/leaf symmetric fabric graph; schema renames.** Fabric
  topology roles are `leaf` and `spine` (renamed from `member`/`hub` in
  rounds 15–16; the rename is breaking and ships without migration
  shims — no external consumers or deployments exist). Per-machine
  `access = member|client|admin` is unchanged and is membership, not
  topology. The adjacency graph is DERIVED symmetrically: every
  unordered spine pair is adjacent automatically; every leaf attaches
  every spine by default and may declare an explicit spine subset; there
  are no mutual hub lists to drift. One WireGuard interface per
  adjacency (D47). Making every node a spine and linking every pair is
  full mesh, not a way around the topology boundary — spine-only full
  peering is not a full fabric mesh: there are no leaf-leaf edges.
  Spines forward and readvertise with next-hop-self; leaves never
  provide transit; two spines are the HA profile with no arbitrary
  maximum. `routed_fabric` and `networkFacts` move to schemaVersion 2.
- **D60 ClusterMesh placement and exposure.** ClusterMesh groups
  require identical datapath mode, tunnel protocol, and
  maxConnectedClusters across members (D54 uniformity); full peering
  remains the default and explicit selective peers stay symmetric and
  non-transitive. Native groups need cross-cluster pod routes and
  mesh-wide native-routing CIDRs (D49); tunnel groups need node
  connectivity only. The clustermesh-apiserver runs with ETP Local on
  EVERY exposure method: mTLS identity does not depend on source IP, but
  Local preserves the source, avoids a second hop, supports ClientIP
  affinity, and enables internal-LB withdrawal. Placement = `voters`
  (default — server nodes), `workers` (agent nodes), `all`, or `labels`;
  label selection uses only clan-declared/generated labels and a
  selector matching zero nodes is an eval error. Exposure = `auto |
  internal-load-balancer | node-port | external-load-balancer`, default
  `auto`: `auto`
  picks internal-load-balancer when the transport exposes that
  capability, else node-port; unsupported or no-method selections are
  eval errors. Node-port has NO replica knob: the Deployment replicas
  equal the selected node count with required hostname anti-affinity +
  nodeSelector (one pod per selected node), all selected nodes' stable
  IPv4 addresses are advertised; the NodePort defaults to 32379 with an
  optional explicit port override, collision-checked per machine; and
  rolling updates use maxSurge=0 /
  maxUnavailable=1. Internal (and external) LB exposure has an
  independent replica count: default min(3, eligible), user positive ≤
  eligible, required anti-affinity, no per-node remote endpoints, and
  the same rolling update. Explicit external always wins on every
  overlay: it requires an explicit non-clan `loadBalancerClass` and a
  `dnsName` (DNS name ONLY — no literal IP), allows provider annotations
  (external-dns is day-2), needs no internal capability — it works
  regardless of transport capabilities — and puts the
  DNS name in peers and certificate SANs; DNS (A record) resolution is a
  runtime prerequisite. Internal exposure (clustermesh-apiserver ONLY —
  mirror
  Services get a separate, future allocation and must NOT share offset
  79, D30) pins ONE IPv4-only literal VIP at
  the D10-locked host offset 79 / 0x79 — `172.16.<id>.79` — drawn from
  the existing `<instance>-fabric` private pool's IPv4 block by explicit
  `lbipam.cilium.io/ips` projection, class
  `io.cilium/bgp-control-plane`; the VIP is asserted pool-contained and
  collision-checked against every other pinned clan VIP; remote peers
  consume the VIP
  directly (no DNS needed); pool names are unchanged and pool
  membership/collision assertions stay. Control-plane exposure is
  IPv4-only on the validated Cilium 1.20.3 profile (the pinned chart's
  clustermesh-apiserver Deployment embeds etcd with
  `--listen-client-urls=https://0.0.0.0:2379` and no dual-stack
  listener knob): there is NO ClusterMesh IPv6 VIP and NO
  `RequireDualStack` advertisement, while the ClusterMesh data plane
  stays dual-stack; certificate SANs carry published IPv4/DNS endpoints
  only, never unreachable IPv6. Normalized settings: `mesh.peers`
  (explicit symmetric selective peers; default full),
  `mesh.placement = voters | workers | all | labels` (default `voters`),
  `mesh.placementLabels` (clan-declared/generated only),
  `mesh.exposure = auto | internal-load-balancer | node-port |
  external-load-balancer` (default `auto`), `mesh.replicas`
  (internal/external LB only;
  null default = min(3, eligible); FORBIDDEN on node-port),
  `mesh.nodePort` (default 32379, optional explicit override), and
  `mesh.external.{loadBalancerClass, dnsName, annotations}` (external
  only). The `kube_cluster` export uses schemaVersion 4 for the revised
  datapath/exposure facts — no shims.

### Round 18 decisions (2026-10-27) — active

- **D61 IfState is the only static host-network renderer.** IfState 2.5.1
  owns physical/VLAN/bond/bridge/dummy/WireGuard links, static addresses,
  static and policy routes, rules, and network sysctls for every machine
  managed by these clanServices. `netif`, `routed-fabric`, and
  `wireguard-mesh` compose one shared per-machine base through
  `lib/ifstate.nix`; `inputs.pkgs.overlays.ifstate` supplies the pinned
  pure-pyroute2 package and the base asserts IfState >= 2.5. systemd-networkd, netdevs, scripted network units,
  NetworkManager, global `networking.useDHCP`, and parallel
  `networking.interfaces` ownership are forbidden — no compatibility
  renderer or migration shim. Changes apply through `ifstate.service`
  during normal NixOS activation and converge live without reboot; dry-run
  `ifstatecli check` is the convergence assertion. DHCP clients run in
  per-link IfState hooks and persist across the oneshot via
  `KillMode=process`; IPv6 SLAAC uses per-link RA sysctls. WireGuard
  private keys are root-owned `0400` clan-vars files referenced only by
  runtime `!include`, never store text. FRR/Zebra owns dynamic routes;
  IfState's built-in protocol ignores preserve them. Cilium-owned
  interfaces and table 200 are explicitly ignored, while netif's DHCP
  routes and other declared static ownership remain reconciled. Global
  forwarding uses `sysctl_conf`. The hermetic proof covers live static
  reconfiguration, DHCPv4/default-route and SLAAC convergence with one
  persistent client, real WireGuard handshakes, fabric HA, and every
  dependent k3s/RKE2 native/tunnel/selective/external suite.

### Round 19 decisions (2026-10-28) — active

- **D62 `pkgs` owns artifacts and shared inputs; VM tests stay out of
  `checks`.** `external-systems/pkgs` pins nixpkgs and flake-parts;
  clanServices follows `pkgs/nixpkgs` and `pkgs/flake-parts` so artifact and
  nixpkgs updates do not require an independent clanServices update. The
  artifact flake owns the composed/default, Kubernetes, and IfState overlays,
  the committed Cilium manifest, distro runtime packages, and amd64/arm64
  airgap outputs for x86_64-linux and aarch64-linux. clanServices re-exports
  those overlays and consumes the published manifest and per-system image
  outputs; consumers may replace the transitive `pkgs` input but do not need
  to declare it. Distro defaults come from the receiving machine's overlaid
  `pkgs.k3s`/`pkgs.rke2`, with explicit package and image overrides retained.
  `clan.nixosTests` remains the declaration interface, but the local adapter
  emits `legacyPackages.<system>.vmTests`; `checks` contains only lightweight
  static checks. VM derivations must never return to `checks`.

### Round 21 decisions (2026-10-29) — active

- **D63 Correct exposure, collision-free ownership, and stable convergence.**
  TCP 179 and UDP 3784/4784 are never opened globally by routed-fabric:
  they are allowed on fabric WireGuard interfaces and, for external
  sessions, only from declared literal `border.upstreamPeers` addresses.
  Hostnames, zones, and malformed upstream literals are eval errors. The
  shared IfState base has a stable module key so repeated service imports
  deduplicate, requires globally unique rendered WireGuard listen ports, and
  reserves them, together with entries from the composable clanServices-owned
  `clanServices.networking.reservedPorts` list, in
  `net.ipv4.ip_local_reserved_ports`.

  Source-return and netif policy tables never use the shared kernel/Cilium
  reserved set `{0,200,201,253,254,255,2004,2005}`. Source-return tables also
  avoid same-host netif policy tables and other source-return tables. Their
  independent rule priorities occupy a deterministic band below kernel `main`
  (32766) and are unique across all source-return and effective netif rules.
  `sourceReturnTable` and `sourceReturnPriority` pin either derived value.
  Netif policy tables and effective rule priorities are unique across
  instances. Every adjacency with two
  declared literal endpoints must share an address family; a hostname
  produces an eval warning because eval does not resolve DNS. This is a
  declared-endpoint check, not the phase-5 per-host underlay reachability
  matrix. Wireguard-mesh rejects pairs with no endpoint on either side,
  overlapping `extraAllowedIPs`, and same-host routed-fabric listen-port
  clashes. The final literal `clan.core.networking.targetHost`, including an
  explicit override on a machine without netif, never names a fabric
  loopback, transfer, or tunnel address; optional user/brackets/port are
  parsed and IPv6 is normalized before comparison.
  `clan.networkFacts.forwarding` exports actual host forwarding intent from
  spines, borders with `border.forwarding`, and k3s/rke2 nodes without a
  sysctl evaluation cycle; RA-enabled links on forwarding machines use
  `accept_ra = 2`.

  Each fabric adjacency has a symmetric timer profile: `site` = BFD 300 ms
  x3, `wan` = BFD 1000 ms x5 plus BGP keepalive/hold 10/30 seconds. Equal
  `settings.site` values default to `site`; different sites default to
  `wan`; an explicit per-adjacency profile overrides the default and two
  conflicting overrides are eval errors. Border upstream sessions always
  use `wan`. Both fabric ends and upstreams render FRR 10.7
  `neighbor <peer> timers delayopen 5`: DelayOpen applies on each inbound
  and outbound session recovery and delays establishment for up to five
  seconds. FRR 10.7.1 `bgp_bfd.c` starts BFD strict hold-time only when the
  effective BGP hold timer is zero, so strict hold-time is not this recovery
  hold-down. DelayOpen is fixed, not exponential flap damping; FRR route
  dampening is not substituted because upstream discourages it and its
  dual-stack coverage is incomplete. Periodic-flap behavior belongs to the
  phase-6 WAN soak. Every rendered `maximum-prefix 4096` uses `restart 10`.
  Every profiled neighbor also renders plain `bfd`; site profile defaults
  stay implicit and `use-underlays-nexthop-weight` is explicit, matching FRR
  running-config serialization. A no-op FRR reload therefore has an empty
  `frr-reload.py --test` diff, preserves peer uptimes, and leaves the RIB
  immediately identical; DelayOpen must never excuse reload-induced
  recovery. Stability takes precedence over faster reconvergence.

### Round 22 decisions (2026-10-30) — active

- **D64 Fabric and mesh allocations are committed public clan vars.** Every
  routed-fabric loopback IPv4/IPv6 address, node ASN, per-adjacency UDP port
  and transfer prefix, and every wireguard-mesh node IPv4/IPv6 address is
  generated once and read from vars at eval; none is recomputed from a
  machine or instance name. All allocation files set `secret = false` and
  `deploy = false`. Generator scripts use Python `ipaddress` and `secrets`,
  never shell arithmetic. Services receive the module-level `directory`
  argument and read values with `clanLib.getPublicValue` in `perInstance`;
  shared reads pass `machine = null`, selecting
  `vars/shared/<generator>/<file>/value`. Every value is trimmed and every
  missing value throws the exact `clan vars generate <machine> --generator
  <generator>` remedy rather than flowing into an address as null.

  `routed-fabric-<inst>-ula` is shared, has no validation, and is the only
  generator that writes the random RFC 4193 `fdXX:XXXX:XXXX::/48` `ula48`.
  `routed-fabric-<inst>-prefixes` is a separate shared generator writing only
  `loopback4-pool` and `transfer4-pool`; pool defaults are `198.18.0.0/17`
  and `198.19.0.0/16`. Member settings `loopback4Pool` and `transfer4Pool`
  feed that generator through string-only `validation`, must be equal on
  every member, and must equal the recorded pool vars. Changing an IPv4 pool
  therefore cannot re-roll the ULA. `routed-fabric-<inst>-node` is per
  machine, depends on both generators, and writes `ipv4` (a random
  non-network/non-broadcast host in the loopback pool) and `ipv6` (a random
  host in `<ula48>:0::/64`). `routed-fabric-<inst>-asn` is an independent
  per-machine generator writing `asn` randomly in
  4200000000..4294967294, so repairing an address collision cannot reset BGP
  sessions or ASN-derived source-return defaults.

  Each sorted adjacency `<a>`, `<b>` declares a byte-identical shared
  `routed-fabric-<inst>-adj-<hash>` generator on both endpoints, where the
  short hash names the canonical adjacency key and cannot alias hyphenated
  machine-name pairs. It depends on the ULA and pool generators and writes
  `port`, a `/31` `transfer4` from the transfer pool, and a `/127`
  `transfer6` from `<ula48>:1::/64`. The `portRange` setting defaults to
  10000–29999, below both the Kubernetes NodePort range and the kernel
  ephemeral range, and is member-uniform. Custom ranges must be disjoint
  from `clanServices.networking.reservedPorts` and, on Kubernetes members,
  30000–32767. No machine name or machine-local value may differ in a shared
  generator's script, files, dependencies, or validation.

  `wireguard-mesh-<inst>-ula` and `wireguard-mesh-<inst>-prefixes` have the
  same independent lifecycle; the latter writes `ipv4-pool`, defaulting to
  `198.18.128.0/17`, disjoint from the routed-fabric loopback default. The
  per-machine `wireguard-mesh-<inst>-node` depends on both and writes `ipv4`
  and `ipv6`. Explicit `ipv4`, `ipv6`, and `adjacencies.<remote>.port`
  settings override vars and remain the collision escape. Source-return
  table and rule-priority defaults use the allocated remote ASN with their
  existing formulas and retain all D63 collision assertions; their collision
  remedies name the existing per-adjacency pins rather than ASN
  regeneration. The generic `node_transport` export carries that allocated
  host ASN for local-router consumers, so k3s/RKE2 never recompute it. On a
  local-router member, `bgp.hostASN` is only a consistency pin: it must be
  null or exactly equal to the transport's allocated `asn`. It cannot renumber
  FRR, whose `router bgp` always uses the routed-fabric allocation. A differing
  pin is an eval error naming the machine, both ASNs, and the remedies (remove
  the pin or regenerate `routed-fabric-<inst>-asn`). A Cilium/host ASN
  collision remedy offers `bgp.ciliumASN` or that same targeted ASN
  regeneration, never a `bgp.hostASN` pin.

  Eval rejects missing allocations; allocated values outside their recorded
  pool or ULA `/64`; recorded pools that differ from current settings;
  fleet-wide duplicate loopback IPv4, loopback IPv6, and ASNs within an
  instance; per-host adjacency-port collisions with every other rendered
  WireGuard port; per-host duplicate transfer prefixes; unequal member
  pools; and allocation-pool overlap with each other, the ULA-derived `/64`s,
  member netif static underlay prefixes, and member kube-cluster
  pod/service/fabric-pool CIDRs. Network facts publish allocation pools and
  adjacency generator names so same-host checks also reject overlaps across
  instances and services and explicit addresses in foreign pools. Duplicate
  transfer prefixes on unrelated hosts are valid. k3s/RKE2 reject a
  local-router host ASN equal to their Cilium ASN. Duplicate messages name
  both owners and direct regeneration at the newer machine; an adjacency
  command may name either endpoint. Regenerating a ULA is an explicit
  instance-wide IPv6 loopback/transfer renumber, never the remedy for an
  IPv4 pool edit. Orphaned `vars/shared/routed-fabric-*-adj-*` directories
  require an operator cleanup check because eval cannot enumerate the vars
  tree; the exported generator names provide the expected set.

  Random collisions are resolved once at generation time and then remain
  stable. With `k` random picks among `N` slots, the birthday approximation
  is `P(any collision) ≈ 1 − exp(−k(k−1)/2N)`: 102 loopbacks in a `/17` have
  about a 15% collision probability; a spine with 100 adjacencies has about
  22% for ports in 20000 slots and 14% for transfer `/31`s in 32768 slots.
  A generator cannot enforce cross-machine uniqueness because it sees only
  declared dependencies; a single whole-instance allocator is forbidden
  because adding a member would renumber everyone. Renaming a machine creates
  a new clan identity and new vars; no migration or rename shim exists.

  Hash-derived by design, and therefore outside D64: `adjacencyName`,
  `rflo<hash>`, FRR symbol names, per-adjacency IPv6 link-local addresses,
  the kube-cluster Cilium cluster id, Cilium ASNs, fallback local-router host
  ASNs, and pod/service CIDRs. Fabric-member local-router ASNs are allocated
  vars, not hashes. These remaining names and cluster-level values have
  separate pins and fleet checks.

## 5. Invariants (target; eval-asserted or VM-proven)

1. One declarative fleet: instance declaration ⇒ stable identity,
   non-overlapping defaults, integrated transport, automatic ClusterMesh
   when the mesh group has peers (full peering default; selective peers
   explicit and symmetric, D54).
2. Dual-stack inside, always (nodes/pods/Services); public exposure
   varies per node/Service (v4-only, v6-only, both, neither).
3. Cilium is the only CNI base: one upstream 1.20+ profile, KPR,
   datapath mode per `node_transport` (native or tunnel/VXLAN), multi-pool;
   networking-only (D1/D49/D58).
4. L3 only: no L2-announce/VRRP/shared-L2. Tested fabric transport =
   derived spine/leaf with one host WireGuard interface per adjacency
   (D51/D59; full mesh is not the supported MVP topology); every cluster
   dual-stack. `netif` may configure VLAN parents/children, bonds, and
   bridges as underlay links, never as a shared cluster datapath.
5. ETP Local on every clan-rendered external-facing Service (mirror
   Services, ClusterMesh apiserver); no silent
   Cluster fallback.
6. LB IPAM ownership unambiguous: classless Services → Node IPAM (D41);
   every explicit pool draw → `io.cilium/bgp-control-plane`; BGP
   advertisements select `node-bgp` or `shared-bgp` pools only, with
   owner/advertiser coherence (D8).
7. Topology always labeled: region/zone default to instance name,
   per-machine overrides, non-empty.
8. Hermetic proof: pinned artifacts, eval rejection of invalid
   inventories, hermetic VM suites.
9. One cluster per node (D16); one routed-fabric membership (at most one
   instance/trust domain) and one FRR per host (D19/D33/D52); exactly
   one classless-LB implementation per cluster (Node IPAM; servicelb
   never — D42).
10. `cluster.local` is pinned and never served to clients (D21);
    member-facing private DNS is deferred to day-2 — the MVP serves no
    cluster DNS to fabric members (D22 amended 2026-10-25).
11. Kubenix renders every clan manifest; two-layer pipeline, zero IFD in
    clanServices eval (D26); delivery = one bootstrap bundle, SSA, once
    (D40); Rancher helm-controller off by default (D42).
12. Control domain without clan-installed GitOps: standalone/hub/spoke
    (D43); mirror Service + mirror SAN mandatory for spokes (D30);
    hub+spokes share one fabric instance (meshGroup defaults to it);
    ≤1 hub per group; spoke ⇒ hub exists (eval-asserted).
13. Clan vars = bootstrap plane only (D35 revised); no clan vars
    generators for application-plane secrets (lint).
14. Artifact flake carries the last 3 k8s minors per distro (D34);
    airgap-ready is the tested default.
15. Every cluster mints admin + read-only (no-secrets) kubeconfigs
    (D38); the hub holds both for every spoke.
16. CNCF in-cluster posture for clan-rendered components (D24); rke2
    CIS-hardened by default (D25).
17. Every static core link/address/route is inventory-owned through
    `netif` (multi-instance; cross-instance conflicts eval-rejected,
    D50/D53); every fabric AllowedIP and BGP filter derives from one
    route policy; no default route or unapproved prefix leaks, and a 0/0
    crypto ACL never creates or accepts an IP default route (D47/D51).
18. Spine/leaf transit rule: spine-role machines forward and readvertise
    with next-hop-self; leaf-role machines never provide transit;
    every leaf reaches ≥1 spine (every spine by default, explicit subset
    allowed) and every unordered spine pair is adjacent automatically;
    HA profiles use two spines with no arbitrary maximum, eBGP/BFD/ECMP
    and no shared gateway VIP/VRRP (D51/D59). Access and border never
    silently change this topology.
19. ClusterMesh peering is full within one fabric by default; selective
    peers are explicit, symmetric, and non-transitive; group members share
    datapath mode, tunnel protocol, and maxConnectedClusters (native
    groups also need mesh-wide native CIDRs, D49); peering bounds
    automatic cross-cluster pod/Service route policy; separate
    routed-fabric instances are hard trust-domain separation (D54/D60).
20. Host firewall is nftables-only; kube-proxy is off; Cilium
    `install-iptables-rules=true` for KPR/BPF masquerade through
    iptables-nft; VMs assert Cilium datapath rules and no legacy-iptables
    or kube-proxy rules (D55).
21. WireGuard MTU derives per link from the underlay minus WireGuard
    overhead with a 1280 floor; Cilium MTU = the minimum interface MTU in
    native mode and minimum minus 50 under VXLAN; VMs assert path MTU
    (D51/D58). *(Partially implemented: wireguard-mesh uses a fixed 1420
    and routed-fabric assumes a 1500 underlay when netif exports no MTU,
    as on every DHCP link; see the hardening plan, phase 4.)*
22. `clan.networkFacts` is versioned (schemaVersion 2), non-secret,
    deep-evaluable, and
    identical in meaning to the functional configuration and exports;
    clanServices has no nix-topology dependency, and unknown runtime state
    is never rendered as build-time fact (D57/D59).
23. k3s/rke2 consume ONLY the generic `node_transport` schemaVersion 2
    and never branch on provider service names; admin overrides cannot
    contradict the transport-derived datapath mode, protocol, devices,
    `directRoutingDevice`, MTU, or exposure capabilities (D58).
24. Exposure and convergence follow D63: BGP/BFD are interface/source
    scoped, WireGuard ports are reserved, policy/endpoint/AllowedIP/deploy
    collisions fail eval, forwarding-safe RA is used, and symmetric BFD/BGP
    profiles plus DelayOpen and maximum-prefix restart favor stability over
    speed.

## 6. Subsystem contracts (condensed)

### 6.1 Ownership boundaries
Canonical repo = external-systems/clanServices. IfState exclusively owns
the static kernel network configuration rendered by these services (D61);
no second network manager is permitted. `netif` owns inventory-declared
links (multi-link, multi-instance), underlay policy routing, and static
host routes; `routed-fabric` owns the encrypted spine/leaf fabric,
per-adjacency WireGuard, fabric-specific policy routing, and one
integrated FRR configuration; thin distro services own
bootstrap/TLS-dir/join semantics and Cilium resources; shared lib
(`lib/kube-cluster/`) owns parity. FRR/Zebra owns dynamic routes and
Cilium owns its datapath; the IfState ignore rules preserve those
ownership boundaries. The generic `node_transport` schemaVersion 2 is
declared OUTSIDE `lib/kube-cluster` as the neutral transport seam (D58).
Artifact flake = only packaging input and shared nixpkgs/flake-parts
authority (overlays, distro runtimes, committed manifests, per-system airgap
images, test fixtures); consumers lock immutable revisions and may replace
the transitive input. Supporting NixOS modules may implement platform-specific
association/tuning, never a parallel static data plane. Day-2 software is
pinned by operator GitOps repos, never here (D39). The shared neutral
`clan.networkFacts` schema belongs to clanServices; each producer owns its
leaves, while nix-topology, translation modules, icons, renderers, and
diagram packages belong to the consumer wrapper (D57).

### 6.2 Identity, CIDRs, topology, exports
Cluster name = instance name (≤32 chars, DNS-style). `cilium.id`
nullable; default = stable hash of instance name → 1–127 (pure Nix, no
IFD); collisions are eval errors. Explicit 1–255 override requires
explicit v4 CIDRs above 127. Deployments predating hashed defaults must
pin current ids/CIDRs before upgrading. One resolved dual-stack CIDR
structure feeds distro, Cilium, DNS, pools, assertions, exports, and
`clan.networkFacts` (D57).
region/zone labels default to instance name and must be non-empty.
`kube_cluster` publishes schemaVersion 4 (revised datapath/exposure
facts per D58/D60 — no shims). It carries identity,
pod/service CIDRs,
clusterDNS, mesh group (default = fabric instance), control-domain role,
fabric source, per-member stable fabric endpoints/topology, pool
handoff (scope, delivery, blocks, selectors, owner), Cilium-side ASN,
advertisement facts, and API mirror facts.
`routed_fabric` (schemaVersion 2) publishes per-node ASN,
loopback/per-adjacency interface facts, leaf/spine topology, access, and
border-owned prefixes.
`node_transport` publishes the generic schemaVersion 2 transport view
(D58): stable dual-stack node addresses,
instance/endpoint identity,
every datapath interface keyed by Linux interface name with its MTU,
exactly one `directRoutingDevice`, `datapath.mode = native | tunnel`
with sibling `datapath.tunnelProtocol` and `native.routeExchange`
(`local-router` on native transports, null on tunnel), the
exposure capabilities `internalLoadBalancer` and `nodePort`, `port`, and
nullable `endpoint`. No secrets in exports; every leaf has a
default (clan CLI deep-eval). `clan.networkFacts` presents the same
resolved facts per node for optional diagram consumers; it is not a
second configuration source (D57).
Inventory-wide assertions cover duplicate names/ids/CIDRs/ASNs/interface
names/transfer prefixes, overlapping CIDRs, duplicate NodePorts, missing
peers/labels/endpoints, adjacencies with no reachable endpoint on either
side, leaves with no reachable spine or invalid spine-role references,
HA profiles without two reachable spines, leaf-transit configurations,
multiple fabric memberships per
machine, node-in-two-clusters, second routing stacks, native-routing
CIDR containment, control-domain⇔fabric-instance consistency, netif
cross-instance conflicts (unique link ownership, default-route, DNS),
non-namespaced netif units, WG MTU below the derived floor, firewall
posture violations, overrides contradicting the transport-derived
mode/protocol/devices/MTU/exposure, ClusterMesh groups with mixed
datapath mode/tunnel protocol/maxConnectedClusters, placement selectors
matching zero nodes, external exposure without a non-clan class+dnsName,
and internal exposure VIPs outside the fabric pool (D51/D53/D55/D58/
D60). Fleet checks read exports;
per-instance/per-machine checks stay in the services.

### 6.3 Host networking and routed WireGuard transport
`netif` is the inventory-facing link service: multi-link and
multi-instance — an instance = one site/segment with shared defaults and
per-machine/per-link overrides, and several netif instances may coexist
on one host (D53). It covers physical links, VLANs, bonds, bridges,
static/DHCP/RA addressing, prefixes, default/static routes, on-link
gateways, MTU, DNS, firewall trust, underlay policy routing, and
optional deploy-target export. Its `peer`/`netif` exports feed adjacency
endpoint selection automatically, with explicit per-adjacency overrides.
Static values may be interpolated from the consumer's `secrets`/
`not-secret` input; exports still contain no private keys.
Cross-instance assertions: a link is owned by exactly one instance;
default-route, DNS, policy-table, and effective rule-priority conflicts
between instances are eval errors; and every DHCP hook is
instance-namespaced (rule 5). All netif settings render through IfState
(D61), which applies address/link/route changes live. RA-enabled links use
`accept_ra = 2` on forwarding machines. A literal deploy target is rejected
when it matches any declared fabric or tunnel address.

`routed-fabric` is the native overlay transport (the supported tunnel
transport is `wireguard-mesh`, D58). Its `leaf`/`spine` symmetric graph is
implemented and VM-proven (D59). Every fabric machine gets stable dual-stack
host addresses on a fabric loopback/dummy interface from its public
`routed-fabric-<inst>-node` vars (default pool `198.18.0.0/17` plus the shared
ULA's `:0::/64`; explicit pins win). Wireguard-mesh likewise reads its node
addresses from public vars (default pool `198.18.128.0/17` plus its own shared
ULA). For each fabric adjacency — every leaf↔spine attachment (every leaf
attaches every spine by default; a leaf may declare an explicit spine subset
via `settings.spines`) plus every unordered spine pair, adjacent automatically
— it renders exactly one point-to-point WG interface with a deterministic
≤15-character name, transfer prefixes and a UDP port read from the sorted
pair's shared public adjacency vars, one peer, and one UDP session; it never
renders one interface per remote machine (D51/D59/D64). Spines are declared
directly with `roles.spine.machines.<name>`; leaves use `roles.leaf`; there is
NO instance-level `settings.spines` and no mutual spine lists — the graph is
derived symmetrically (D59).
The canonical adjacency key remains
`<instance>:<sorted-endpoint-a>:<sorted-endpoint-b>`; the key names the shared
generator and hash-derived interface, while its transfer `/31` and `/127` come
from vars (default `198.19.0.0/16` and the shared ULA's `:1::/64`). Sorted
endpoint order selects the first or second transfer host. Explicit
per-adjacency port pins are the collision escape. Missing allocations,
adjacency/name/address collisions, and pool overlap are eval errors with
targeted remedies. The node keypair is instance-scoped clan vars; public keys
are public vars, private keys only deploy to their owner. Interface names,
FRR symbols, and per-adjacency link-local addresses remain hash-derived by
design (D64).

AllowedIPs carry the remote stable host addresses plus exactly the
prefixes that adjacency is authorized to transit — AllowedIPs is both
outbound cryptokey selection and the inbound source ACL. External-transit
adjacencies (`border`, D56) may include 0.0.0.0/0 and ::/0 as crypto ACL
without creating or accepting an IP default route. The same resolved
policy renders FRR filters, preventing cryptokey/routing drift. Internet
ingress through a border requires source-policy return routing through
the correct fabric egress — no asymmetric local-WAN reply.
Fabric-originated routes are stable /32+/128, and next-hop-self on spine
readvertisement keeps every next hop directly resolvable.
An adjacency needs at least one reachable endpoint; NAT/outbound-only
members omit endpoints and keepalive every 25 seconds; two NAT sites
never peer directly — they communicate through spines. Per-link WG MTU
derives from the underlay MTU minus WireGuard overhead (80 bytes v4 /
96 v6) with a 1280 floor; VMs assert path MTU. Endpoint reachability is
evaluated per adjacency; private endpoints are allowed when
actually reachable. One `routed-fabric` instance = one trust domain; one
machine has at most one membership and one topology role. Declared literal
endpoints on one adjacency must share an address family; hostname endpoints
generate an eval warning instead of impure DNS resolution. Source-return
tables have an explicit per-adjacency pin, avoid all kernel/Cilium owners
and netif/source-return collisions, and use independent unique rule
priorities below 32766. `settings.site` selects the default timer profile:
equal sites use `site` (BFD 300 ms x3), different sites use `wan` (BFD
1000 ms x5 and BGP 10/30 seconds), and
`adjacencies.<remote>.timerProfile` overrides either. Upstreams use `wan`.
Both ends and upstreams use a five-second fixed DelayOpen hold-down; all
maximum-prefix limits restart after ten minutes. No-op reloads preserve
peer uptimes and the immediate RIB (D63).

```nix
inventory.instances = {
  home-net = {  # netif instance: role-wide site defaults + per-machine links
    module.input = "clanServices";
    module.name = "netif";
    roles.default.settings = {  # site-wide defaults (every machine/link)
      mtu = 1500;
    };
    roles.default.machines.kamrui-h1.settings = {
      targetHost = true;
      links.wifi = {
        interface = "wlp2s0";
        dhcp.ipv4 = true;  # inherits the site mtu default
      };
    };
  };
  lab-net = {  # second netif instance on the SAME host: separate site/segment
    module.input = "clanServices";
    module.name = "netif";
    roles.default.settings = {
      mtu = 9000;  # segment-wide default
    };
    roles.default.machines.kamrui-h1.settings.links.lab = {
      interface = "enp3s0";
      static.ipv4 = [ "192.0.2.10/24" ];
      # No default gateway here: home-net's DHCP link owns the host default.
      routes = [ { destination = "192.0.2.0/24"; gateway = "192.0.2.1"; } ];
    };
  };
  fleet = {  # leaf/spine shape (D59)
    module.input = "clanServices";
    module.name = "routed-fabric";  # leaf/spine + access + border
    roles = {
      spine.machines = {
        # Spine topology and external-border policy are independent.
        edge-1.settings.border.ownedPrefixes = [
          "203.0.113.0/24"
          "2001:db8:100::/48"
        ];
        edge-2 = { };  # second spine = the HA profile; no border
        # edge-1↔edge-2 adjacency is automatic (every spine pair is).
      };
      leaf.machines = {
        helsinki-manager-1 = { };  # default: attaches every spine
        kamrui-h1.settings = {
          spines = [ "edge-1" "edge-2" ];  # explicit subset; default = all
          access = "admin";
          endpointSources = [
            { service = "netif"; instance = "home-net"; }
          ];
        };
      };
    };
  };
  spoke = {
    module.input = "clanServices";
    module.name = "k3s";
    roles.server.machines.kamrui-h1.settings.network.fabric = {
      service = "routed-fabric";
      instance = "fleet";
    };
  };
};
```

All actual static addresses/routes live in inventory settings, not
supporting NixOS modules. Native-mode Cilium MTU = the minimum interface
MTU (no VXLAN `-50`); VXLAN tunnel mode subtracts 50 (D58).

### 6.4 Cilium base
Same canonical upstream Cilium 1.20+ chart/images both distros; RKE2
bundled Cilium disabled. Always: KPR, multi-pool pod IPAM (default;
derived non-clashing dual-stack CIDRs), BPF masquerade+tproxy, Maglev,
pmtu, Node IPAM (D41), kube-proxy off, `install-iptables-rules=true`
(D55). The datapath mode, tunnel protocol, devices,
`directRoutingDevice`, and MTU derive from `node_transport` (D58) and
admin overrides cannot contradict them: native mode on routed-fabric,
tunnel/VXLAN on wireguard-mesh. Native mode sets `routing-mode: native`,
no tunnel, `auto-direct-node-routes: false`; dual-stack
native-routing CIDRs cover all pod CIDRs in the mesh trust domain
(default `10.0.0.0/8` + `fd10::/16` for derived space; explicit overrides
must contain every explicit pod CIDR). Cilium device configuration covers
every fabric WG interface (one per adjacency, D51/D59). On native
transports Cilium advertises local `CiliumPodIPPool`
allocations and authorized Service routes to local FRR over the
`local-router` exchange; FRR/Zebra owns remote routes. Native ClusterMesh
requires non-overlap, node InternalIP connectivity, and working
cross-cluster pod routes; tunnel ClusterMesh requires node connectivity
(D60).
Local Cilium↔FRR peering is ONE `::1` session carrying both address
families; advertisement selectors and the `CiliumPodIPPool` type are
pinned; explicit `extended-nexthop` capability and v4-over-v6 /
v6-over-v4 next-hop behavior must be probed before the renderer locks,
and the Cilium GR posture (timers, restart behavior, capability
fallback) is explicit enough for tests (D55). Per-cluster variation lands
in `cilium-config` and CRs through kubenix merging over the committed
base manifest (D26). Admin helm-values
overrides remain limited to layer-2-expressible keys and are post-merge
validated against the transport-derived mode/no-contradiction/IPAM/
dual-stack/device/CNI/artifact/ETP invariants. Multus follows D42.
Lifecycle: bootstrap bundle
apply → GitOps adoption (D40); publish-freshness gated in CI.

### 6.5 ClusterMesh (full peering default, selective peers supported)
Mesh groups default from the fabric instance: the clusters under one
`routed-fabric` instance form one mesh group (no repeated value
required; a different fabric instance — or explicit opt-out — separates
trust and bounds control domains, D43). Separate `routed-fabric`
instances are HARD trust-domain separation: no mesh, no routes, no DNS
across them. Three distinct graphs: the **underlay graph** (netif
links), the **fabric graph** (routed-fabric adjacencies), and the
**ClusterMesh graph** (peering edges) — similar shapes, independent
edges (D54). Every eligible cluster runs clustermesh-apiserver + mesh
certs from first boot; singleton peer list empty. Default peering is
FULL among the fabric instance's clusters; explicit symmetric selective
peers are supported — a central cluster may peer A↔B and B↔C while A
and C do not peer; peering state is non-transitive, and selective peers
also bound the automatic cross-cluster pod/Service route policy rendered
into fabric filters (a routed-only exception between non-peered
clusters must be deliberate and eval-visible). Peering rendered from
exports into `clustermesh.config.clusters` — no CLI. Group uniformity
(D60): identical datapath mode, tunnel protocol, and
maxConnectedClusters in every member. Placement: `voters` (default —
server nodes), `workers` (agent nodes), `all`, or `labels`
(clan-declared/generated labels only; zero matches = eval error).
Exposure (D60): `auto` (default) | internal-load-balancer | node-port |
external-load-balancer`. `auto` = internal-load-balancer when the
transport exposes that capability, else node-port; unsupported or
no-method selections are eval errors. `internal-load-balancer`
(clustermesh-apiserver ONLY — mirror Services get a separate, future
allocation and must NOT share offset 79, D30) pins
ONE IPv4-only literal VIP at the D10-locked host offset 79 / 0x79 —
`172.16.<id>.79` — drawn from the `<instance>-fabric`
private pool's IPv4 block
by explicit `lbipam.cilium.io/ips` projection,
class `io.cilium/bgp-control-plane`; the VIP is asserted pool-contained
and collision-checked against every other pinned clan VIP; remote peers
consume the
VIP (no DNS needed); control-plane exposure is IPv4-only on the
validated Cilium 1.20.3 profile (the pinned chart's
clustermesh-apiserver etcd listens on `https://0.0.0.0:2379` with no
dual-stack listener knob) — NO ClusterMesh IPv6 VIP, NO
`RequireDualStack` advertisement, data plane stays dual-stack;
independent replica count — default
min(3, eligible), user positive ≤ eligible, required anti-affinity, no
per-node remote endpoints, rolling update maxSurge=0 / maxUnavailable=1.
`node-port` has NO replica knob: replicas = selected node count,
required hostname anti-affinity + nodeSelector (one pod per selected
node), all selected nodes' stable IPv4 addresses advertised; the NodePort
defaults to 32379 with an optional explicit port override,
collision-checked per machine. `external-load-balancer` always wins on
every overlay: explicit non-clan `loadBalancerClass` + `dnsName` (DNS
ONLY, no literal IP), provider annotations allowed (external-dns is
day-2), no internal capability needed, DNS name in peers and cert SANs,
resolution (a runtime A record) a prerequisite. ETP Local on every method: mTLS
identity does not depend on source IP, but Local preserves the source,
avoids a second hop, supports ClientIP affinity, and enables
internal-LB withdrawal. DNS fan-in: selectorless local ClusterIP Service
+ eval-rendered EndpointSlice per remote cluster — the same pattern,
generalized, carries the kube-apiserver mirror Services (D30; mandatory
for spokes). Shared `rancher-clustermesh-ca-<group>` vars generator
(share=true); per-cluster dependent cert generators; SANs include every
published IPv4/DNS endpoint + fan-in name + external dnsName — never an
unreachable IPv6 endpoint; endpoint set is a
public validation
input (membership change ⇒ reissue before advertise). CA/cert material
never in exports/helm/store. Global Services opt-in per Service (mirror
Services are clan-rendered globals, D30). MCS-API reserved. Rotation =
separate two-phase CA-bundle design; blind regeneration unsupported.

### 6.6 HAProxy kubeapi HA (bootstrap contract)
Every node except the bootstrap server's first boot runs clan-rendered
HAProxy on loopback, load-balancing that cluster's server API endpoints
(rendered from exports, health-checked via the per-node health-check
client certificate — existing `mkHaproxyGenerator`). Join URL and agent
kubeconfigs point at it: server loss never strands nodes. Ports derive
deterministically from `cilium.id` (existing scheme: 7442+id,
+1000 supervisor). This is control-plane HA — unrelated to the revoked
D5 edge-proxy.

### 6.7 Pools, LB, BGP, FRR
Per D8/D9/D10/D19/D41. Node IPAM serves classless Services with node IPs
(no pools/BGP) — fabric-scoped; public exposure uses explicit pools
(D41/D52). Every explicit pool draw uses
`io.cilium/bgp-control-plane`; Cilium allocates through LB IPAM but only
`node-bgp` and `shared-bgp` pools are selected for announcement. Pool
updates may reassign IPs and are reviewed changes.

| Delivery | Scope | Advertiser / failure semantics |
| --- | --- | --- |
| `node-fate-bound` | per-machine | Provider/static delivery; no BGP; follows owner |
| `node-bgp` | per-machine | Only owner advertises exact VIPs; no cross-node ECMP |
| `shared-bgp` | cluster-global | Every healthy eligible node advertises; FRR/upstream ECMP |
| `floating` | cluster-global | Runtime controller moves one address; blackhole window without it |
| `external-class` | cluster-global | Cloud CCM owns delivery |

`node-bgp` is the contract for node-owned public IPv4 extras and
carve-outs of a node's routed IPv6 subnet — only where BGP delivery
actually exists; provider-static node-bound extras remain
node-fate-bound (D8). Hetzner/provider-MAC KubeVirt attachment is netif
host-bridge plumbing, NOT a Cilium pool or BGP delivery; KubeVirt stays
day-2 (D52/D55). Per-node BGP resources select
only that owner's pool. ETP Local withdraws when no eligible local
backend exists; consumers that require the address must keep eligible
backends on the owner. Other nodes must not re-advertise the route as if
shared. `shared-bgp` is the contract for private fabric VIPs and
upstream-router pools; all healthy eligible nodes originate the same
/32+/128 and FRR uses `maximum-paths` plus multipath-relax to retain
interfaces as ECMP members.

Local Cilium advertisements terminate on node-local FRR. FRR accepts only
owned node-bgp/shared-bgp VIPs, local multi-pool allocations, and
authorized ClusterIPs, then exports according to the receiving machine's
`access` (D33/D56) and the adjacency policy (D51). Zebra installs remote
routes on Kubernetes and fleet hosts alike; Cilium's local endpoint
routes remain more specific. FRR next-hop rewriting resolves each path
through its per-adjacency interface. Foreign upstreams are configured
only under `border`, with strict prefix and maximum-prefix policy and
optional proxy-NDP for on-LAN prefixes.

### 6.8 Day-2 proxy layer (out of contract)
No Gateway API, Ingress, or proxy implementation is clan-rendered
(revoked D2/D6/D7/D15/D17). The day-2 guide carries the Envoy Gateway
recipe: DaemonSet-mode EnvoyProxy on labeled workers, ETP Local (safe
with Node IPAM — real EndpointSlices, D41),
`loadBalancerClass: io.cilium/bgp-control-plane` + pool-label selectors or
explicit `lbipam.cilium.io/ips` projections for every explicit pool draw.
BGP advertisements still select only `node-bgp` and `shared-bgp` pools —
one proxy
implementation per IP:port, QUIC-passthrough on its own VIP. The
contract guarantees the substrate (pools, BGP, firewall); the proxy
is GitOps-owned.

### 6.9 Secrets / PKI / airgap
One plane (D35 revised). Clan vars: cluster CAs, join tokens, admin +
read-only kubeconfigs (D38), ClusterMesh CA/certs, HAProxy health-check
material, `gitops-hub` identities (D43). Everything else — Sealed
Secrets keys included — is day-2 GitOps custody. Public certs readable
as public values; private material referenced by deployed paths only.
RKE2 PKI sync non-destructive; k3s init-only seed + native replication.
Airgap-ready default; one explicit opt-out switch; overrides = complete
replacement sets or additive lists.

### 6.10 Rotation and imperative lifecycle
Leaf certs: upstream 365-day, renew at startup; manual via
`{rke2,k3s} certificate rotate` (kubeadm: `kubeadm certs renew`). CA
rotation: staged dir + `rotate-ca`; same-root can be non-disruptive; new
root disruptive (tokens, kubeconfigs, restarts). Service-account signing
key: append/retain. Client-identity certs (`gitops-hub` D43, read-only
D38): 365-day, regenerate via vars + secret-sync, clusters untouched
(same CA). Cert bootstrap/rotation runbooks + scripts ship in
documentation. No blanket 100-year leaf default. Inventory deletion ≠
cluster GC: cordon/drain, Node deletion, etcd member removal, mesh
cleanup, hub kubeconfig/CRB removal = documented runbooks. Disruptive
changes (pools, CIDRs, ids, CA roots, mesh membership) = reviewed
operational changes.

### 6.11 CCM, managed manifests, GitOps
`cloudController = none | rancher | external`; provider CCMs never
bundled, deployed day-2; hermetic fake-CCM VM test. Every clan-rendered
manifest labeled (managed-by, instance, component, config-hash; never in
selectors). Rendering = kubenix (D26); delivery = bootstrap bundle SSA
once (D40); Rancher helm-controller disabled by default (D42). Day-2
GitOps owns all lifecycle post-bootstrap; base upgrades preserve
operator CRDs.

### 6.12 Assertions and firewall
*Status (round 21): D63 exposure, policy, endpoint, mesh, RA, deploy-target,
and timer invariants are eval-enforced. The leaf-transit, asymmetric
source/return, HA-profile and duplicate-ASN rejections below remain planned;
see the later hardening phases.*

Eval rejects: multiple bootstraps; duplicate ids/CIDRs/ports/ASNs/
interface names/transfer prefixes; missing dual-stack or topology facts;
pool overlap; scope⇒mode violations; floating without candidates;
`node-bgp` without exactly one owner, with non-local advertisers, or
where no BGP delivery exists; BGP pools without `bgp.enable` or BGP
without any `node-bgp`/`shared-bgp` pool; fabric blocks too small — the
fabric IPv4 block MUST contain host offset 79 (at least 128 addresses;
the default /24 satisfies this; the old offset-53 / 64-address rule is
retired); BGP pools outside border-owned prefixes; node-in-two-clusters; multiple
fabric memberships or routing stacks per host; adjacencies with no
reachable endpoint on either side or with mismatched literal address
families; leaves with no reachable spine or spines not declared with the
spine role; HA profiles without two reachable spines;
leaf-transit configurations (a non-border leaf readvertising fabric
routes); default-route/AllowedIP leaks — a
0.0.0.0/0 or ::/0 crypto ACL must not create or accept an IP default
route; asymmetric Internet source/return paths; WG MTU below the derived
floor; source-return kernel/Cilium/netif/source-return table collisions or
rule priorities at/above 32766 and any netif/fabric priority collisions;
netif cross-instance conflicts (link ownership, default-route, DNS, policy
tables, effective rule priorities) and non-namespaced netif units;
wireguard-mesh pairs without an endpoint on either side, overlapping
`extraAllowedIPs`, and any same-host WireGuard listen-port clashes;
non-literal upstream peers; final literal overlay deploy targets;
conflicting adjacency timer overrides;
missing native CIDR containment;
Geneve or non-derived tunnel protocols, or `auto-direct-node-routes` in
the canonical profile;
Cilium devices missing WG links; ETP Cluster on clan-rendered external
Services; base-manifest drift; IFD smuggling; unsupported k8s minor
without acknowledgment; application-secret vars; control-domain
violations; spoke without mirror/SAN; servicelb; distro-manifests-dir
delivery; kube-proxy enabled or `install-iptables-rules=false` in the
canonical profile. The read-only ClusterRole never contains `secrets`
or write verbs (D38). Firewall: nftables-only — Cilium's required
KPR/BPF-masquerade rules use iptables-nft; legacy iptables and
kube-proxy rules are forbidden (D55); API on transport only; public
ports only where exposed; WireGuard only on configured underlays;
BGP/BFD only on fabric WireGuard interfaces and from declared upstream
peers, never globally (D63); mirror Services restricted to GitOps
namespaces. VMs assert positive AND negative exposure, the nft backend,
Cilium datapath rules, and no kube-proxy rules.

### 6.13 routed-fabric service
Per D11/D13/D19/D22/D33/D47/D48/D51/D52/D53/D56/D59. Two topology roles,
no
default role: `leaf` = stable loopback addressing, one WG interface
per spine attachment, FRR/BFD/Zebra, automatic pod routes on native
transports when
also a Kubernetes node (D58), and no transit; `spine` adds forwarding
and
readvertisement. Per-machine `access` defaults to `member` (membership,
not topology); `client`
adds fabric-pool LoadBalancer-VIP routes only (never pods or ClusterIPs);
`admin` adds D13 pod/ClusterIP route consumption; Kubernetes nodes on
native transports
install remote pod-pool blocks and advertised VIPs regardless of
`access` (native-routing requirement, D49). Member-facing DNS zones,
any private DNS service, and any private CoreDNS VIP are NOT rendered
in the MVP (D22 day-2).
Optional `border` adds upstream peers, owned-prefix filtering,
forwarding, optional NDP, and authorized external/fabric transit — NOT
automatic admin DNS. Leaves attach every spine by default and may
declare an explicit spine subset; spine pairs are adjacent
automatically (symmetric derivation, D59); spines are
directly declared and may independently have any access or border
configuration. Kubernetes managers are not spines by default. Active-active
spine HA is fabric ECMP — every leaf links both spines with eBGP/BFD and
FRR `maximum-paths` + multipath-relax; no shared gateway VIP, no VRRP;
two spines are the HA profile with no arbitrary maximum.
Upstream active-active requires upstream ECMP; transparent active-active
default gateway for ordinary non-fabric LAN clients is outside MVP.
Node duality uses the same FRR, never a second stack. Members get
routes only — their name resolution is a day-2 concern (external-dns-
style automation), never a fabric render.

Acceptance (target; round 20 status: the NAT-site, Internet source/return,
border-filter and route-filter-negative items are not yet VM-proven, see
the hardening plan, phase 6): eval proves deterministic names, committed
loopback/ASN/port/transfer allocations, explicit overrides, missing-var and
duplicate/pool negatives (D64), adjacency/AllowedIP/filter equivalence,
self-exclusion, topology/access/
border checks, spine references and reachability (every leaf reaches ≥1
spine; HA = 2, no arbitrary maximum), symmetric graph derivation, and
export/facts defaults. Hermetic VMs prove
real WG handshakes per adjacency, FRR sessions and BFD on both sides,
RIB-to-FIB installation, spine readvertise with next-hop-self and leaf
no-transit, two NAT sites communicating through spines, Internet ingress
source/return path, native pod round trips, client VIP ECMP, admin
svc/pod/ClusterIP route access to local and foreign clusters, no
member-facing cluster DNS in the MVP (day-2 external-dns concern),
client pod-route isolation, selective isolation, node-bgp
owner-only and shared-bgp
ECMP withdrawal, border filtering, border-not-spine without automatic
admin DNS, composable admin-border, spine active-active + single-spine
failure/restore with FRR reload/restart keeping RIB/FIB stable,
NAT membership, MTU floor/path MTU, no legacy-iptables or kube-proxy rules,
and the kamrui-h1 dual-shape with local Cilium behavior intact.

### 6.14 Control domain (D43)
Per-cluster `controlDomain.role`: **standalone** (default) — shares no
kubeconfig with any cluster; **hub** — holds `gitops-spoke-<spoke>`
namespaces with per-spoke `kubeconfig` + `kubeconfig-readonly` Secrets
(secret-sync from vars), NetworkPolicy; **spoke** — exports its API via
a mirror Service (D30), renders CRB `gitops-hub` + optional tenant
impersonation SAs, accepts reconciliation from its group's hub. All
spoke-bound day-2 objects carry the tool's remote-kubeconfig mechanism
(Flux `kubeConfig.secretRef`, Argo cluster secrets) — wired by the
operator, documented in the day-2 guide. Standalone clusters may still
join the mesh and consume/export mirror Services — mesh ≠ control
domain. Singleton standalone = no hub config. **Naming note (rounds
16–17):**
control-domain hub/spoke (this section, D43) is a GitOps-control
concept; fabric spine/leaf (§6.3, D51/D56/D59) is a packet-transit
concept.
A cluster may be either, both, or neither; only `roles.spine` makes a
fabric transit spine.

### 6.15 Network facts and diagrams (D57)
`clan.networkFacts` is a neutral NixOS-option interface, not a
nix-topology interface. Its versioned (schemaVersion 2, D59) schema and
read-only leaf options
are declared by clanServices without any diagram dependency. The service
that owns a fact populates it from the same resolved configuration used
for its functional NixOS settings and exports; consumers only read it.
Every leaf has a safe default for deep evaluation. The facts preserve
separate underlay, fabric, ClusterMesh, and control-domain graphs rather
than flattening them into one misleading edge set.

`netif` publishes declared networks, links, interface kinds, addressing
modes and known addresses, gateways, routes, MTU, and attachments.
`routed-fabric` publishes leaf/spine/access/border, stable loopbacks,
per-adjacency WireGuard interfaces, transfer prefixes, public endpoints,
MTU, ASNs, upstreams, and authorized public prefixes. Distro services
publish cluster identity, distro, node membership, pod/Service CIDRs,
pools, mesh peers, and control-domain relationships. Nothing in the
schema admits secret material.

A consumer-owned nix-topology wrapper imports its own NixOS module and
translates these facts into `topology.networks`, `topology.nodes`,
interface addresses/network assignments/connections, and service details.
It may use nix-topology's automatic extraction as a supplement, but the
clan facts are authoritative for clan-owned configuration. Flake-parts
integration can expose `topology.<system>.config.output`; assigning that
derivation to `packages.<name>` yields an ordinary `nix build
.#<name>` artifact. Multiple clans or synthetic inventories can be
rendered as separate topology evaluations and packages. Diagram builds
do not boot VMs and do not query live machines.

The completeness guarantee is deliberately bounded: every build-time-
declared network fact must be represented faithfully. DHCP/RA addresses
not known until runtime, BGP-learned routes, WireGuard handshakes,
reachability, health, and failover state are not claimed as known.
Rendering must show the declared dynamic mode or unknown state instead
of inventing addresses or runtime edges.

## 7. Testing contract (D44)

Seams: pure renderer nix-unit tests (kubenix render determinism
included); throwaway clans via `clanLib.clan` (inventory boundary);
`clan.nixosTests` hermetic VM suites exposed only through
`legacyPackages.<system>.vmTests` (one at a time, sandboxed authoritative;
never `checks`); artifact source/hash/render gates (incl.
committed-manifest inflation proofs and publish-freshness checks,
D26/D40). Standard internal HTTP test workload: **go-httpbin** (pinned,
airgap-carried as a test-fixture artifact). Rules: hermetic/offline;
committed-var or fixture-pinned eval-deterministic addresses; VM allocations
are freshly generated, printed for diagnosis, and asserted through network
facts in the routed-fabric and wireguard-mesh suites; dual-stack asserted in
every boot test; round-trips + failure behavior (BGP withdrawal keeps VIP via
healthy nodes); negative assertions; operational postconditions; fail fast.
Minimal airgapped artifacts for hermetic VM tests is a hard requirement.

Eval tests commit readable public allocation fixtures under
`services/<svc>/tests/fixtures/vars/{per-machine,shared}` and never recompute
hash-derived expectations. Positive and negative tests cover every D64
collision class and explicit overrides. The locked clan-core `clanTest`
harness executes VM generators through its Nix vars executor, encrypts test
secrets with its fixed test recipient, and merges generated `vars/` and
`secrets/` into a temporary directory used by `getPublicValue`. It replaces
the suite's source `vars/` tree, so these VM suites need no committed
allocation files, legacy public-key fixtures, or separate `update-vars` run.
Routed-fabric and wireguard-mesh print the fresh allocations and prove them
with `ROUTED_FABRIC_ALLOCATED_OK` and `WIREGUARD_MESH_ALLOCATED_OK`.

Current registered VM suites:
- **single/join/HA per distro** on `wireguard-mesh`: bootstrap, local
  HAProxy, node readiness, Cilium health, Service/DNS, etcd quorum and
  failure behavior (D58).
- **netif**: multi-NIC physical/VLAN/bond/bridge links, multi-instance
  ownership, static/DHCP/RA addressing, on-link/policy routes, exports,
  and conflict negatives. Live static reconfiguration is applied, checked,
  and restored without reboot. The DHCP/RA suite proves a real lease,
  default routes, one persistent client across reapply, and clean
  `ifstatecli check` convergence (D61).
- **wireguard-mesh**: real dual-stack handshakes and pairwise connectivity.
- **routed-fabric transport/FRR**: two spines + leaves with derived
  adjacencies (D59), one IfState-owned WG interface per pair, real
  handshakes, no `(none)` AllowedIPs, FRR/BFD, RIB-vs-kernel FIB,
  next-hop-self, spine readvertise/leaf no-transit, MTU, and spine HA
  failure/restore, on one flat underlay where every node has an endpoint.
  *Planned (not yet VM-proven):* NAT/outbound-only keepalive,
  external-transit crypto ACL without an IP default route, Internet
  source/return path, and route-filter/default-route negatives (hardening
  plan, phase 6).
- artifact matrix (3-minor version pins eval, D34);
- **native data-plane suite per distro** on `routed-fabric`: native
  pod-to-pod without VXLAN, multi-pool remote routes, pool allocation,
  classless Node IPAM (fabric-scoped), ETP-Local candidate restriction,
  node-bgp owner-only advertisement and withdrawal, shared-bgp dual-stack
  ECMP and single-path withdrawal (including Linux `ip -j` single-path
  shape), floating-pool blackhole window, firewall positive/negative
  exposure, iptables-nft Cilium rules plus NO legacy-iptables or
  kube-proxy rules, and dual-AF local Cilium↔FRR;
- **fabric/BGP HA**: two spines active-active ECMP + single-spine
  failure/restore with FRR reload/restart keeping RIB/FIB stable (D59),
  private fabric, upstream ECMP, border-not-transit-role, MikroTik-style
  FRR foreign-router fixture, upstream border pools and node-owned IPv6
  pools;
- **selective ClusterMesh suite**: full-peering default, explicit
  selective peers (A↔B, B↔C) with A/C selective isolation on non-transit
  leaves; the dedicated spine's union-of-leaf-consumers carriage is the
  deliberate routed-only exception. k3s and RKE2 are VM-proven on BOTH
  native and tunnel profiles: selective edges synchronize only their
  intended global-Service backends, native A/C leaves install no routes for
  each other (dual-stack /24 + /64 allocation assertions), and the full-peering
  defaults remain green. Final selective evidence:
  `.baton-pass/vm-logs/ifstate-k3s-clustermesh-selective-final.log`,
  `.baton-pass/vm-logs/ifstate-rke2-clustermesh-selective-final.log`,
  `.baton-pass/vm-logs/ifstate-k3s-clustermesh-selective-tunnel-final.log`,
  and
  `.baton-pass/vm-logs/ifstate-rke2-clustermesh-selective-tunnel-final.log`;
  full-default regression evidence:
  `.baton-pass/vm-logs/ifstate-k3s-clustermesh-final.log`,
  `.baton-pass/vm-logs/ifstate-rke2-clustermesh-final.log`,
  `.baton-pass/vm-logs/ifstate-k3s-clustermesh-tunnel-final.log`, and
  `.baton-pass/vm-logs/ifstate-rke2-clustermesh-tunnel-final.log`;
- **ClusterMesh suite per profile**: native
  internal-load-balancer exposure (D10-locked offset-79 IPv4 VIP +
  `lbipam.cilium.io/ips` projection +
  `io.cilium/bgp-control-plane` class + SANs covering published IPv4/DNS
  endpoints only + pool membership/
  collision checks; NO ClusterMesh IPv6 VIP and NO `RequireDualStack`
  advertisement — control-plane exposure is IPv4-only on the pinned
  Cilium 1.20.3 profile) and tunnel NodePort exposure (replicas = selected
  nodes, one pod per selected node, NodePort default 32379 with
  optional explicit override, selected nodes' stable IPv4 addresses
  published); external class+DNS exposure wins on BOTH
  profiles
  (non-clan class + dnsName in peers/SANs, runtime A record); placement
  voters/workers/all/labels with zero-match negatives; group-uniformity
  negatives (mixed datapath mode/tunnel protocol/maxConnectedClusters);
  cross-cluster pod routes + kube-api mirror Service reachability (D30)
  in native groups. The k3s and RKE2 external-native and external-tunnel
  suites are VM-proven with a dedicated transport-attached DNS VM, real
  A-record resolution, authenticated external-LB health checks, and
  bidirectional ClusterMesh status. Tunnel suites additionally assert VXLAN
  and the transport-derived MTU. Final external evidence:
  `.baton-pass/vm-logs/ifstate-k3s-clustermesh-external-native-final.log`,
  `.baton-pass/vm-logs/ifstate-rke2-clustermesh-external-native-final.log`,
  `.baton-pass/vm-logs/ifstate-k3s-clustermesh-external-final.log`, and
  `.baton-pass/vm-logs/ifstate-rke2-clustermesh-external-final.log`;
- eval seam suite: a third-party overlay implementing `node_transport`
  schemaVersion 2 is consumed by k3s/rke2 with NO provider service-name
  branching, and contradicting overrides eval-fail (D58);
- **fabric-topology suite** (D33/D56/D59): member/client/admin
  access independent of topology (route-level only), border filtering,
  border WITHOUT transit role and without automatic admin DNS,
  composable
  admin-border, kamrui-h1 dual-shape; member-facing DNS is not asserted
  (day-2, D22 amended);
- **network-facts suite** (D57): deep eval, JSON serializability,
  secret-free and versioned schema, facts/export/functional-render parity,
  dynamic-state labeling, and one consumer-owned nix-topology wrapper
  build proving SVG output without adding a clanServices dependency;
- PKI rotation (+ cert bootstrap runbook execution);
- CCM knob suite (hermetic fake-CCM);
- **GitOps-handoff suite** (D40/D44): strict no-op under a second SSA
  field manager, dataplane green before/after; no Flux in VMs;
- `distroDefaults` suite (D42) and rke2 CIS profile suite (D25);
- control-domain suite (D43/D30/D38): hub + two spokes + standalone,
  mirror-SAN and read-only positive/negative, rotation, offline spoke.

Round-18 acceptance evidence: 276/276 eval tests pass
(`.baton-pass/vm-logs/ifstate-eval-dhcp-killmode-46.log`); netif live
apply/check/restore passes (`.baton-pass/vm-logs/ifstate-netif-live-17.log`);
DHCP/RA and live reapply pass
(`.baton-pass/vm-logs/ifstate-netif-dhcp-final-48.log`); native data planes
pass (`.baton-pass/vm-logs/ifstate-k3s-data-plane-52.log` and
`.baton-pass/vm-logs/ifstate-rke2-data-plane-51.log`); all join/HA and all
twelve ClusterMesh variants pass on IfState (final logs named
`.baton-pass/vm-logs/ifstate-<suite>-final.log`). PKI rotation, fake CCM,
GitOps SSA no-op handoff, distroDefaults, RKE2 CIS, and control-domain
runtime behavior are not claimed by this acceptance matrix.

Retired suites: full-mesh transport suite (round 15 — superseded by
derived spine/leaf, D51/D59; historical); round-13 retirements: EG
gateway matrix, QUIC/Caddy fixtures, flux control-domain suite,
external-dns, OpenEBS, KubeVirt, Multus, sealed-secrets. Reserved:
MCS-API, upstream-kubernetes distro suites (D23).

## 8. Delivery plan (phases; each lands lib + both distros + docs + pins +
tests together)

- **0 done** — canonical import (`896acdf`).
- **1 done** — scope-reduction execution (docs-only round 13 landed first,
  per A4): out-of-contract code deleted (traefik renderers and inputs,
  cert-manager + sealed-secrets renderers/inputs, gateway-api-crds input);
  `lib/rancher-cluster/` renamed to `lib/kube-cluster/` (D45); interfaces
  pruned to bootstrap + data plane; `distroDefaults` knob (D42); static
  gates green.
- **2 done** — artifact flake narrowing (external-systems/pkgs): drop
  envoy-gateway/cert-manager/flux/external-dns/multus/sealed-secrets
  components + freshness checks; keep distro runtimes (3 minors), Cilium
  chart + committed inflated manifest, go-httpbin; add Cilium image
  airgap set; clean-public-fetch proof; CoreDNS image artifact added for
  D46 (2026-10-23). Consumed at pinned rev
  `feb7946fa83769f839ab5f835d3c84bd93b43fa5`.
- **3 done** — kubenix bootstrap bundle + bootstrap-apply oneshot
  (`clusterInit` node, SSA, `bootstrap.apply` off-ramp, D40); canonical
  Cilium profile with Node IPAM (D41); pools (D8); ETP-Local rendering;
  override validation. Implementation notes: the committed base manifest is
  imported into kubenix's typed tree with a pure-Nix YAML-subset parser
  (kubenix's own importYAML is yq-based IFD — forbidden by D26);
  `cilium.helmValues` overrides are limited to the layer-2-expressible
  profile tree (untranslatable keys throw at eval — §6.4 wording adjusted);
  clan-rendered CoreDNS in the bundle gives every distro the same DNS
  base (D46, added 2026-10-23 — supersedes the interim "minimal rke2 runs
  no distro CoreDNS" state); data-plane VM suite registered per distro
  (`k3s-data-plane`, `rke2-data-plane`).
- **4 done** — host-wireguard transport, hashed ids, topology, dual-stack
  exports; one-cluster-per-node assertion. Implementation notes
  (2026-10-23): `cilium.id` defaults to the sha256-based hash of the
  instance name mapped into 1–127 (pure Nix, no IFD); all id consumers
  (CIDRs, clusterDNS — 10th address of an explicit service v4 CIDR — and
  HAProxy ports) use the resolved id; explicit ids > 127 require explicit
  v4 CIDRs. Topology labels (`topology.kubernetes.io/region|zone`,
  default = instance name, per-machine overrides, empty = eval error,
  invariant 7) render into the distro node labels. The `kube_cluster`
  custom export interface (renamed from `rancher_cluster`, D45) publishes
  schemaVersion/identity/CIDRs/meshGroup/fabric source/member mesh
  endpoints incl. effective topology/pool handoff facts from both distro
  services; `node_transport` gained topology fields. Fleet-wide
  assertions (id collisions, duplicate names, same-group pod/service CIDR
  overlap, node-in-two-clusters across rke2+k3s (D16), mesh-group
  transport consistency) are `clan.checks` computed from the
  `kube_cluster` exports by the shared lib's fleet-checks module
  (wired into this flake's own clan and into the eval-test throwaway
  clans; consumers wire `clan.imports = [ fleetChecksModule ]`).
  All-or-none transport posture (§6.3) is a per-instance assertion.
  Wireguard-mesh addresses were historically hash-derived; D64 replaces
  that derivation with committed public node allocations while preserving
  the one-shared-multi-peer-interface transport model.
- **5R0 done (docs only)** — round-14 FRR/per-pair-WG/native-Cilium
  contract, inventory-owned netif family, node-bgp delivery, and delivery
  re-plan. No implementation or VM claim. Rounds 15–16 supersede its
  per-remote-machine transport and fleet-routing naming (5R1–5R4 below).
- **5 legacy checkpoint, not accepted** — `2995ac3` contains BIRD/VXLAN
  Phase 5 work; retained baseline 5 green / 7 red. It is superseded by
  rounds 14–16 and is not a base for further BIRD debugging.
- **5R1 done (implementation + suites registered 2026-10-25; no new
  green claim)** — `netif` (multi-link, multi-instance,
  cross-instance assertions, endpoint exports) and the ROUND-16
  `routed-fabric` (per-adjacency WireGuard member↔hub + optional
  hub↔hub; eBGP/BFD/
  Zebra with next-hop-self; AllowedIPs dual semantics incl. 0/0 crypto
  ACL; source-policy return routing; underlay-derived MTU) implemented
  with versioned exports/network facts, eval tests, and hermetic
  transport/netif suites registered. The leaf/spine symmetric graph is
  the round-17 TARGET (D59) — implemented in 5R5, not here. Round 17 is
  docs-only, so suite
  green-ness is not re-claimed here; the retained baseline stands.
- **5R2 done — both repos** — the pinned Cilium base manifest was
  re-inflated and committed with native-routing defaults (D26 layer 1);
  the local Cilium↔FRR dual-AF session, multi-pool exchange,
  native CIDR/device/MTU invariants, iptables-nft assertion, and
  node-bgp/shared-bgp delivery landed in the shared lib + both distros.
  The full ClusterMesh phase landed with D60 in 5R5.
- **5R3 done** — selective ClusterMesh policy, topology/access/border
  filtering, and full/external regressions are implemented and VM-proven
  for k3s/RKE2 on native and tunnel profiles. The obsolete
  BIRD/VXLAN/fleet-routing modules, helpers, fixtures,
  `lib/import-flake/`, and `lib/inputs-module.nix` are deleted outright.
  `wireguard-mesh` is the supported tunnel transport (D58).
- **5R4 done** — `clan.networkFacts` schemaVersion 2 parity, deep-eval,
  secret-free/dynamic-state invariants, and the consumer-wrapper diagram
  proof are covered by eval tests (D57/D59); nix-topology remains
  consumer-owned.
- **5R5 done — round-17 contract** — generic `node_transport`
  schemaVersion 2 outside `lib/kube-cluster` with no provider-name
  branching (D58); `leaf`/`spine` with the symmetric derived graph (D59);
  full/selective ClusterMesh placement/exposure (D60); and the supported
  `wireguard-mesh` tunnel/VXLAN profile. The native, tunnel, selective,
  and external eval/VM suites are green. Breaking schema changes shipped
  without migration shims.
- **5R6 done — IfState-only networking (round 18, D61)** — replaced all
  systemd-networkd/netdev and scripted network rendering with IfState
  2.5.1; added the shared overlay/base, runtime-secret includes, DHCP/RA
  hooks, Cilium/FRR ownership ignores, live reconfiguration, and hermetic
  dependent regressions. No machines were deployed and no compatibility
  renderer remains.
- **6** — control domain: mirror Services (D30), `gitops-hub` identities
  + secret-sync + read-only credential (D43/D38). (The ClusterMesh data
  plane itself is 5R2(4) → 5R5, D60.)
- **7** — PKI ops + rotation runbooks/scripts, RKE2 CIS suite (D25),
  CCM knob + fake-CCM test, GitOps-handoff proof suite (D44),
  `distroDefaults` suite.
- **8** — borg migration + upstream review: home consumes `netif` and
  `routed-fabric`, removes `hostSpec.networking`/`machines.json` static-IP
  ownership, and salvages borg facts/runbooks only before archival.
- Reserved: upstream `kubernetes` distro implementation (D23; spec'd,
  hard requirement), MCS-API, clan-operator (per-agent read-only
  identities beyond D38, tenant lifecycle).

## 9. Out of scope

Everything day-2 (§3.3) as clan-rendered surface: Envoy Gateway and all
Gateway API rendering; the Ingress API; cert-manager; Flux/Argo
installation; external-dns; Sealed Secrets (controller AND sealing-key
custody); OpenEBS and any storage provisioner; KubeVirt/CDI (kubelet
CPU-pinning = generic distro config passthrough only); Multus as clan
rendering (distro-stock Multus via `distroDefaults` excepted); provider
CCM deployments (the `cloudController = external` knob is bootstrap
config and stays); hcloud-ip-floater deployment (floating-pool contract
stays; the controller is day-2 and upstream-unmaintained — fork
reference only). Also: alternative CNIs / tunnel protocols other than
the supported vxlan profile / Geneve / BIRD / L2 announcements / VRRP /
Keepalived (spine HA is fabric ECMP, D51/D59); full-mesh fabric topology
and per-remote-machine WireGuard links (deferred beyond MVP, D51/D59 —
spine-only full peering is not a full fabric mesh); iBGP / route
reflectors / route servers (D51); shared gateway VIP / VRRP-style spine
HA and transparent active-active default gateway for ordinary non-fabric
LAN clients
(outside MVP — needs client routing or an L2/VRRP-like mechanism, D51);
other route-exchange or tunnel modes representable in the `node_transport`
schema (rejected until implemented and tested, D58); migration shims or
a compatibility burden for the round-17 schema/role renames (no external
consumers or deployments exist, D58/D59);
official mycelium/yggdrasil/wireguard overlays as dependencies or
underlays (peer exports are the integration seam, D55); mandatory
all-to-all ClusterMesh as the only peering mode (full is the default,
selective peers supported, D54); more than one routed-fabric membership
per machine (D53); legacy-iptables or kube-proxy-owned firewall rules
(D55); single-stack internals; Rancher
Manager; cross-inventory automatic mesh; implicit global Services;
early/default-on MCS-API; bundled provider CCMs; replicated storage;
Windows guests; direct-to-pod routing from edges; NAT64/app egress
remediation; same VIP advertised from two clusters; pod/ClusterIP routes
to non-Kubernetes hosts by default (`access = "admin"` excepted, D33);
clanServices-owned nix-topology dependencies, `topology.*` rendering, or
diagram packages (the neutral facts seam and consumer wrapper are D57);
public
node-bgp/shared-bgp without upstream-routed space; heterogeneous multi-WAN
inbound failover (use DNS failover); cilium CLI installs (D40);
HelmRelease adoption without helm release storage (D40); Rancher
helm-controller in the minimal base (D42); servicelb/klipper in any
mode (D42); clan rendering of Traefik (stock distro Traefik via
`distroDefaults` excepted, D42); delivery of clan manifests via distro
manifests dirs (D40); cilium-wireguard/unencrypted as tested transports
(§6.3); offline-minted SA JWTs and expiring bearer-token kubeconfigs
with refresh CronJobs (D43); secret-reading "read-only" roles (D38's
hard line); per-agent identity minting (clan-operator, Reserved);
blanket 100-year leaves; blind live CA regeneration; fully declarative
node/etcd/cluster deletion; in-place rke2↔k3s↔kubernetes conversion;
locked-HEAD distro constructors (D34); OLM v1 (D32 reasoning retained);
clan vars ownership of application-plane secrets incl. sealing keys
(D35); member-facing cluster DNS as a clan-rendered/fabric service
(D22 deferred — day-2 delivers member DNS via Kubernetes-side automation
such as external-dns).

## 10. Glossary

- **Bootstrap contract** — the day-1 promise that a declared cluster
  exists and is reachable: distro install/join, PKI, HAProxy kubeapi HA,
  bootstrap bundle, control-domain substrate (§3.1).
- **Data-plane contract** — the day-1 promise that packets flow
  correctly: native Cilium CNI, Node IPAM + pools, FRR/BGP/Zebra,
  ClusterMesh, per-adjacency host WireGuard, in-cluster CoreDNS
  (cluster.local), routed-fabric (§3.2).
- **Day-2 GitOps** — everything in-cluster that is not the two
  contracts; installed and owned by operator GitOps repos, documented
  here as recipes only (§3.3).
- **Bootstrap bundle** — the single kubenix-rendered manifest set per
  cluster, applied once via SSA on the `clusterInit` node (D40).
- **Cluster services** — public rke2/k3s/kubernetes clanServices +
  private shared library; not Rancher Manager.
- **Shared lib** — `lib/kube-cluster/` (renamed from
  `lib/rancher-cluster/`, D45): interfaces, renderers, vars, assertions.
- **Artifact flake** — external-systems/pkgs; nixpkgs/flake-parts authority,
  overlays, distro runtimes (last 3 minors, D34), committed manifests,
  per-system airgap images, test fixtures (D62).
- **Distro** — the Kubernetes distribution a cluster instance runs:
  `rke2` | `k3s` | `kubernetes` (upstream, kubeadm-based, D23).
- **distroDefaults** — per-distro-service knob; `true` on rke2/k3s
  restores stock packaged components (helm-controller, Traefik, Multus)
  via the distro's own machinery (D42).
- **CNCF posture** — clan-rendered in-cluster components are CNCF
  projects; host-level (FRR, WireGuard, HAProxy) exempt; rke2 is the
  documented distro exception (D24).
- **Kubenix rendering** — manifests built as typed Nix module resources;
  chart inflation only at artifact-flake update time (D26).
- **IFD (import-from-derivation)** — evaluation reading a derivation's
  output, forcing a build during eval; forbidden in clanServices (D26).
- **Base manifest** — a chart rendered with the canonical fleet-uniform
  profile, committed as source in the artifact flake (D26 layer 1).
- **Control domain** — the set of clusters one GitOps control plane
  manages: a hub plus its spokes (D43). Bounded by a mesh trust domain.
- **Control-domain role** — per-cluster `standalone` (shares nothing) |
  `hub` (holds spoke kubeconfigs) | `spoke` (hub-reconciled) (D43).
- **Trust domain** — the `routed-fabric` instance and its ClusterMesh
  mesh group (meshGroup defaults from the fabric instance); bounds
  fabric membership, ClusterMesh peering + route policy, AND control
  domains (D43/D53/D54).
- **gitops-hub identity** — the per-spoke client certificate (CN
  `gitops-hub-<spoke>`, O `gitops-hub`) signed by the spoke's cluster
  CA, consumed by whatever GitOps tool the hub runs (D43).
- **Read-only credential** — the per-cluster client certificate (CN
  `readonly-<instance>`, O `cluster-readers`) and kubeconfig for
  no-secrets read access, minted for AI agents; synced to the hub for
  spokes (D38).
- **Mirror Service** — clan-rendered selectorless ClusterMesh-global
  Service + EndpointSlice exposing a cluster's kube-apiserver to mesh
  members (D30); mandatory for spokes.
- **Bootstrap plane** — secrets custody: clan vars own bootstrap secrets
  only (CAs, tokens, admin + read-only kubeconfigs, ClusterMesh
  material, HAProxy health-check material, gitops-hub identities); all
  application-plane secrets are GitOps-owned (D35).
- **Integrated node transport** — the generic `node_transport`
  schemaVersion 2 contract (D58) and its two supported profiles:
  routed-fabric (per-adjacency routed L3 host WireGuard — leaf↔spine
  attachments plus automatic spine↔spine pairs, D51/D59 — carrying
  dual-stack node InternalIPs, API, native pod traffic, FRR/BGP, and
  BFD) and wireguard-mesh (Cilium tunnel/VXLAN + nodePort). (Round-14
  "per-pair full mesh" phrasing is historical.)
- **node_transport (schema)** — the shared, neutral, open transport
  export schema declared outside `lib/kube-cluster` (D58): stable
  dual-stack node addresses, instance/endpoint identity, every datapath
  interface keyed by Linux name with its MTU, exactly one
  `directRoutingDevice`, `datapath.mode = native | tunnel` plus tunnel
  protocol, native `routeExchange = local-router` (never `local-frr`/
  `local-bgp`), and the independent exposure capabilities
  `internalLoadBalancer` and `nodePort`. k3s/rke2 consume only this
  schema and never branch on provider service names.
- **Mesh group** — mutually trusted cluster instances forming one
  ClusterMesh; defaults from the fabric instance (no repeated value
  required). (Round-14 default `meta.domain` is historical.) Members
  share datapath mode, tunnel protocol, and maxConnectedClusters (D60).
- **ClusterMesh exposure** — how the clustermesh-apiserver is reached:
  `auto | internal-load-balancer | node-port | external-load-balancer`
  (D60). Internal pins ONE IPv4 literal VIP from the D10
  `<instance>-fabric` pool (class `io.cilium/bgp-control-plane`) —
  control-plane exposure is IPv4-only on the validated Cilium 1.20.3
  profile, while the ClusterMesh data plane stays dual-stack; node-port
  advertises selected nodes' stable IPv4 addresses with replicas = selected
  count and no replica knob; external always wins, requires a non-clan
  `loadBalancerClass` + a DNS-only `dnsName` (runtime A record), and needs
  no internal capability. Certificate SANs carry published IPv4/DNS
  endpoints only. ETP Local on every method. Mirror-Service allocation is
  separate and never uses the clustermesh-apiserver's VIP.
- **ClusterMesh placement** — which nodes run the clustermesh-apiserver:
  `voters` (default — servers), `workers` (agents), `all`, or `labels`
  (clan-declared/generated only; zero matches = eval error) (D60).
- **Pool scope** — per-machine (node-named, one owner) vs cluster-global
  (generic-named); who contributes a pool's addresses.
- **Delivery mode** — node-fate-bound | node-bgp | floating | shared-bgp |
  external-class; how traffic reaches pool addresses + failure semantics.
- **Node IPAM** — Cilium's LoadBalancer feature (helm `nodeIPAM.enabled`)
  that advertises node IPs (ExternalIP, else InternalIP) as a Service's
  LB ingress; the classless-Service default (D41). Distinct from
  `ipam.mode: kubernetes` (pod IPAM), which is an allowed override.
- **LB IPAM pool** — CiliumLoadBalancerIPPool; explicit draws use
  `io.cilium/bgp-control-plane`, while advertisement remains selector-driven.
- **Node-fate-bound delivery** — provider/static routing to one node; no
  failover, no BGP.
- **Node BGP delivery** — only the owner node advertises exact VIPs from
  its per-machine pool; no cross-node ECMP.
- **Floating delivery** — runtime controller moves the address to one
  node at a time; failover is the controller's contract.
- **Shared BGP VIP** — address advertised from all healthy nodes
  (ETP-Local withdrawal); the `shared-bgp` mode of a cluster-global pool.
- **Private fleet fabric** — default per-cluster private shared-bgp pool
  + FRR/BGP/Zebra + the clustermesh-apiserver VIP (pinned at host offset
  79, D10/D60); lets clan
  hosts route into every
  cluster. Mirror-Service VIP allocation is separate/future and must not
  share offset 79 (D30). No CoreDNS VIP — member DNS is wholly day-2
  (D22).
- **routed-fabric service** — clanService providing the flat-L3
  spine/leaf fabric: one WireGuard interface per adjacency (leaf↔spine
  attachments, automatic spine↔spine pairs),
  FRR/BFD/Zebra, orthogonal access and border policy, and the native
  Cilium profile (local-router exchange + internalLoadBalancer/nodePort
  capabilities, D58). Renamed from
  `fleet-routing` in round 15 (D52); roles revised in round 16 (D56) and
  renamed `leaf`/`spine` in round 17 (D59).
- **Fabric adjacency** — a leaf↔spine attachment or an automatic
  spine↔spine pair
  in a routed-fabric instance; owns exactly one WireGuard interface, one
  eBGP session pair (one per AF), and one BFD monitor (D51/D59).
- **Leaf / spine** — mutually exclusive fabric topology roles (renamed
  from member/hub in round 17, D59): spines
  forward and readvertise (next-hop-self); leaves never provide transit
  and reach ≥1 spine — every spine by default, explicit subset allowed;
  HA profiles use two spines with no arbitrary maximum
  (D51/D59). Orthogonal to control-domain hub/spoke (D43), access, and
  border. Spine-only full peering is not a full fabric mesh: there are
  no leaf-leaf edges.
- **Fabric access** — per-machine `member | client | admin` route
  consumption (member DNS is day-2, D22 amended): `client` = fabric-pool
  LoadBalancer-VIP routes only; `admin` = + pod-pool and ClusterIP
  routes; Kubernetes nodes on native transports install pod/VIP routes
  regardless (D49). Membership, not topology — independent of leaf/spine
  roles and border (D56/D59).
- **Border** — optional per-machine external/upstream transit
  configuration, not a topology role, default gateway, NAT device, DHCP
  server, or Kubernetes Gateway API implementation (D56).
- **Underlay / fabric / ClusterMesh graphs** — three distinct graphs:
  netif links; routed-fabric adjacencies; ClusterMesh peering edges.
  Similar shapes, independent edges (D54). Control-domain edges are a
  fourth, also independent graph (D43/D57).
- **Network facts** — versioned (schemaVersion 2), non-secret, read-only
  `clan.networkFacts` NixOS options describing resolved build-time
  networking for optional consumers; runtime-unknown state is explicit
  (D57/D59).
- **nix-topology wrapper** — consumer-owned integration translating
  network facts into buildable diagrams; never a clanServices dependency
  (D57).
- **IfState** — the exclusive static network renderer (D61), pinned to
  2.5.1. It owns links, addresses, WireGuard, static/policy routes, rules,
  and sysctls and reconciles them live without reboot; FRR/Zebra and
  Cilium retain dynamic ownership. No systemd-networkd, netdevs, or
  scripted network units.
- **netif instance** — one site/segment declaration of the netif
  service with shared defaults and per-machine/link overrides; several
  may coexist on one host (D53).
- **Private-domain zones** — day-2 member-facing DNS zones (D22
  amended; NOT served in the MVP): `<instance>.<domain>` (default) and
  opt-in `<instance>.svc.<domain>` and pod zone, published by
  Kubernetes-side automation such as external-dns. `cluster.local` never
  appears on clients.
- **Managed base** — labeled clan-rendered APIs/resources installed once
  via the bootstrap bundle; tenant resources GitOps-owned.
- **Airgap-ready** — all artifacts pinned and local at boot.
- **VM-proven** — behavior passed fresh, sandboxed, hermetic on final
  tree.

## 11. Key upstream references

- IfState 2.5.1 (D61): declarative netlink reconciliation for links,
  addresses, routes/rules, sysctls, and WireGuard; runtime `!include` for
  secrets; interface hooks for DHCP; built-in ignores for dynamic routing
  protocols. Source/tag: <https://codeberg.org/routerkit/ifstate/src/tag/2.5.1>.
- Cilium 1.20: native routing (`routing-mode: native`; remote pod routes
  require a system routing daemon when nodes are not on one L2),
  multi-pool `CiliumPodIPPool` advertisements, LB IPAM, Node IPAM (the
  ETP-Local EndpointSlice caveat affects only Cilium's own
  Gateway/Ingress, D41), BGP v2, ClusterMesh (identical datapath per
  group, non-overlap,
  node connectivity, mesh-wide native-routing CIDR for native groups —
  tunnel groups need node connectivity only, D58/D60), and the Gateway gaps
  behind D1. Configuration uses the rendered `cilium-config` ConfigMap
  (D26 layer-2 seam); official install = Helm, cosign-signed
  digest-pinnable OCI charts; the chart ships no `crds/` dir — the
  operator manages CRDs at runtime (D40).
- Cilium ClusterMesh control plane (D10/D60): the pinned chart's
  v1.20.3 clustermesh-apiserver Deployment embeds etcd with
  `--listen-client-urls=https://0.0.0.0:2379` (IPv4 wildcard;
  `--advertise-client-urls=https://localhost:2379`) and the template has
  no dual-stack listener knob — control-plane exposure is IPv4-only on
  the validated profile: ONE pinned IPv4 VIP internally, selected nodes'
  stable IPv4 addresses on NodePort, DNS (A record) externally, and cert
  SANs covering published IPv4/DNS endpoints only. The ClusterMesh data
  plane stays dual-stack.
- Cilium bootstrap/handoff evidence (D40): Flux prune only touches the
  Kustomization's own `.status.inventory` (fluxcd.io Kustomization
  docs); SSA vs client-side-apply field-manager friction and
  `--server-side` bootstrap avoidance (same docs + Flux FAQ); Argo CD
  adoption via tracking annotation/label (Argo resource-tracking docs);
  Flux maintainer on CNI takeover (fluxcd/flux2#3070); cilium-cli helm
  mode + value auto-detection + cert-mode skew (cilium-cli README,
  cilium-cli#300; Reddit crash-loop migration report).
- Kubenix (hall/kubenix): helm inflation at update time (IFD — why it
  lives in pkgs); patching chart output via typed resource tree
  re-declaration (D26 layer 2); `includeCRDs = false` default (loses
  nothing for Cilium).
- Kubernetes RBAC: built-in aggregated `view` ClusterRole excludes
  Secrets by design (basis of D38).
- Kubernetes CCM: `--cloud-provider=external` uninitialized-taint flow;
  no Cilium-specific caveat (agent tolerates `Exists`) (§6.11).
- RKE2 hardening: `profile: cis` (v1.29+), PSA restricted, host
  sysctl/etcd-user prerequisites (D25).
- Kubernetes version skew: kubelets may lag apiserver up to 3 minors
  (motivates D34).
- FRR 10.7+: integrated NixOS `services.frr` config; BGP eBGP/ECMP,
  prefix-lists/route-maps, martian/loopback next-hop handling, BFD,
  `frr-reload.py --test`, Zebra RIB-to-kernel installation; Cilium local
  `::1` peering and next-hop rewrite (D9/D19/D48).
- WireGuard cryptokey routing: one peer per interface; ECMP across
  interfaces, never overlapping AllowedIPs across peers on one interface;
  AllowedIPs is outbound cryptokey selection AND the inbound source ACL
  — every approved transit prefix must appear, and 0/0 is a crypto ACL,
  not a routing decision (D47/D51).
- hcloud-ip-floater (costela): floating-IP mover reference; upstream
  effectively unmaintained (last non-dependabot commit 2023) —
  fork-don't-depend.
- go-httpbin (mccutchen): standard airgapped HTTP VM-test workload.
- Host firewall: nftables-only; Cilium 1.20.3 KPR/BPF masquerade requires
  `install-iptables-rules=true` through iptables-nft; legacy iptables and
  kube-proxy rules are forbidden (D55).
- Cilium BGP session: one local `::1` session carrying both AFs;
  `extended-nexthop` capability and v4/v6 next-hop interworking are
  probed before renderer lock (D55).
- WireGuard MTU: underlay MTU minus WireGuard overhead (80 bytes v4 /
  96 v6); 1280 floor; path-MTU asserted in VMs (D51). Cilium MTU = the
  minimum interface MTU in native mode, minimum minus 50 under VXLAN
  (D58).
- nix-topology: evaluated `nixosConfigurations` plus explicit networks,
  nodes, interfaces, connections, and service details produce SVGs;
  `topology.<system>.config.output` is a derivation and may be exposed as
  `packages.<diagram>`. Its flake-parts module selects compatible
  `self.nixosConfigurations`; clan's evaluated hosts therefore fit the
  consumer-owned wrapper without making raw inventory a nix-topology
  input (D57).
