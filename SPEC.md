# Kubernetes cluster clanServices — Full Specification (agent edition)

Single dense contract for agents; `documentation/` (MkDocs) is the human
record. **Same spec, two renderings — edit both together.** This file is
both the *target contract* and the *status authority*. Baseline: canonical
import (`896acdf` in this repo); recorded green: wireguard-mesh + rke2/k3s
single/join/HA VM suites in the source fork.

Revised 2026-10-24: **round 14 — FRR, routed WireGuard, and native
Cilium.** The data plane now uses one point-to-point host WireGuard
interface per node pair, one FRR routing stack per host with Zebra-owned
kernel routes, and Cilium native routing with multi-pool IPAM. BIRD,
VXLAN, and the ordinary-mesh-plus-auxiliary-routed-interface model are
superseded. New decisions D47–D50; revised: D8, D9, D11, D13, D19, D33,
D41, D44. This round lands docs-only under A4; the BIRD implementation at
checkpoint `2995ac3` is legacy and is not round-14 acceptance evidence.
Its retained baseline is 5 green / 7 red VM suites.

Round 13 (2026-10-22, retained): **data-plane-only scope reduction.** The
contract has exactly two verifiable promises — the Bootstrap contract and
the Data-plane contract (D39). Everything else that was spec'd as
clan-rendered in-cluster software is revoked and becomes documented day-2
GitOps patterns. Round history is retained in §4 with per-decision status.

Round-8 amendments (2026-10-20, retained): **A1** artifact flake packages
the last 3 k8s minors per distro (→ D34). **A2/A3** application-plane
credentials are never clan vars (→ D35, narrowed further in round 13).
**A4** spec locks land without code changes in the same commit — rounds 13
and 14 land docs-only; code changes are scheduled in §8.

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
D45). `netif` owns inventory-declared physical/logical links and static
routes; `fleet-routing` owns the flat-L3 fabric: one WireGuard interface
per node pair, per-node FRR/bfdd, and Zebra-installed routes. Cilium = CNI
+ KPR + **native routing** + multi-pool pod IPAM + Node IPAM for classless
LoadBalancer Services + LB-IPAM pools + BGP v2 + ClusterMesh — networking
only (D1). Local Cilium agents advertise pod pools and Service VIPs only
to their node-local FRR; FRR exchanges filtered routes over the encrypted
full mesh and programs the kernel. `fleet-routing` roles provide transport
only (`member`), VIP access (`client`), pod/Service access (`admin`), and
upstream routing (`router`). HAProxy on every node gives HA kubeapi access
and the join URL. The entire day-1 in-cluster surface is ONE
kubenix-rendered bootstrap bundle, applied once via server-side apply on
the `clusterInit` node (D40) — no Rancher helm-controller, no host-resident
manifest dirs. Clusters run standalone, or as hub/spoke control domains
(D43): clan mints the kubeconfigs, RBAC, and API mirror Services that let
any GitOps tool manage spokes from a hub, but installs no GitOps controller
itself. Day 2 = GitOps takes over: Cilium ownership transfers by adopting
the identical published manifest set, and all other cluster software is
installed and owned by GitOps repos. Artifact flake
(`external-systems/pkgs`) pins distro runtimes, the Cilium chart with its
committed inflated base manifest, and test fixtures; airgap-ready is the
tested default.

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
  (Cilium, clan CoreDNS (D46), pools, ClusterMesh config, CoreDNS private
  zones, mirror Services, RBAC), applied once by a oneshot on the
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

- Cilium only: one canonical upstream 1.20+ profile — KPR, **native
  routing**, multi-pool pod IPAM with derived non-clashing dual-stack
  CIDRs, BPF masquerade+tproxy, Maglev, pmtu. `auto-direct-node-routes`
  is false: FRR/Zebra owns remote pod-pool routes. `ipam.mode: kubernetes`
  remains an explicit override. Admin helm-values overrides pass
  post-merge invariant validation (§6.4).
- **Node IPAM on by default** (`nodeIPAM.enabled=true`,
  `defaultLBServiceIPAM=nodeipam`, D41): classless `type: LoadBalancer`
  Services get node IPs, ServiceLB-style; ETP-Local-aware candidate
  selection. Pool VIP draws use explicit Cilium-handled
  `loadBalancerClass`es: `io.cilium/lb-ipam` for non-BGP deliveries and
  `io.cilium/bgp-control-plane` for `node-bgp` and `shared-bgp`.
- LB-IPAM pool model with five delivery modes (D8 revised), BGP v2 +
  per-node FRR/Zebra (D9/D19/D48), default private fleet fabric (D10),
  node-owned BGP pools and shared ECMP pools, plus floating pools via
  runtime controllers.
- ClusterMesh automatic per mesh group, mixed-distro, native-routed in
  every member (§6.5). Mesh-wide native-routing CIDRs cover every pod
  CIDR; cross-cluster pod routes must exist before readiness.
- Host WireGuard full mesh with exactly one point-to-point interface per
  node pair (§6.3, D47). FRR-BFD monitors every fabric path. WireGuard
  `AllowedIPs` and BGP filters derive from the same route policy.
- CoreDNS private zones (D21/D22) + role-scoped pod/Service route
  consumption (D13): DNS into every cluster for authorized clan hosts.
- **netif** for inventory-owned links/static routes (D50) and
  **fleet-routing** (`member`/`client`/`admin`/`router`, D33) for the flat
  L3 fabric. The legacy standalone `wireguard-mesh` service is retired
  after migration.
- No Gateway, no Ingress, no proxy implementation in the contract. The
  data-plane proof uses native pod round trips, plain `type: LoadBalancer`
  Services, and firewall positive/negative assertions (§7).

### 3.3 Day-2 GitOps — documented patterns, never clan-rendered

GitOps-controller install (Flux or Argo) and takeover of the Cilium
bundle (adopt the identical published set; Kustomization+prune or Argo
tracking — first reconcile is a no-op by construction, D40), Envoy
Gateway (incl. the Node IPAM + ETP Local + `loadBalancerClass` recipe),
cert-manager, external-dns, Sealed Secrets (incl. sealing-key custody),
OpenEBS, KubeVirt, Multus, provider CCMs, hcloud-ip-floater-style
floating-IP movers. These live in `documentation/` as recipes and are
pinned/consumed by the operator's GitOps repos — not by this repo, not by
the artifact flake (D44/pkgs narrowing).

## 4. Decision record (D1–D50)

Statuses: **active** | **REVISED** (round noted) | **REVOKED** (round 13
unless noted) — revoked entries keep one-line reasons for history.

### Active decisions (rounds 1–12, with round-14 revisions)

- **D1 Cilium is networking-only.** (REVISED round 13: reaffirmed, and now
  the ONLY in-cluster Cilium surface.) `gatewayAPI.enabled=false`,
  `ingressController.enabled=false` permanently. Reasons: no Gateway
  HTTP/3 (cilium#28497), no Gateway mTLS (GEP-91), no DaemonSet mode, no
  multi-Gateway IP sharing (cilium#25567). Round-13 consequence: the
  Cilium dummy-Endpoints Node-IPAM limitation never applies here (D41).
- **D8 Pool model: 2 scopes × 5 delivery modes.** (REVISED round 14.)
  Pool = address inventory + `serviceSelector`. Scope: *per-machine* →
  node-named pools with exactly one owner; *cluster-global* → generic
  pools. Delivery: `node-fate-bound` (provider/static route, no BGP) |
  `node-bgp` (only the owner advertises exact /32+/128 VIPs; for
  node-owned IPv4 extras and routed IPv6-subnet carve-outs) | `floating`
  (runtime controller moves one address; blackhole window) | `shared-bgp`
  (every healthy eligible node advertises; upstream ECMP; ETP-Local
  withdrawal) | `external-class` (cloud CCM). Non-BGP draws use
  `io.cilium/lb-ipam`; both BGP modes use
  `io.cilium/bgp-control-plane`. Assertions: non-overlap; scope⇒mode
  validity; `node-bgp` exactly one owner and never shared; `shared-bgp`
  only cluster-global; floating candidate coverage; BGP pool blocks ⊆
  router-role prefixes when a router is declared. One VIP is never
  advertised by two clusters.
- **D9 BGP topology + foreign-router contract.** (REVISED round 14.)
  Every fabric node runs FRR/bgpd+bfdd+Zebra with a deterministic unique
  private 32-bit node ASN and stable mesh IPv4 router ID. Node FRRs form
  an eBGP full mesh, one session per address family over each per-pair
  WireGuard interface (D47). `bgp ebgp-requires-policy`, explicit AF
  activation, prefix-lists/route-maps, maximum-prefix, `maximum-paths`,
  `bgp bestpath as-path multipath-relax`, and fast convergence are
  mandatory. BFD monitors every FRR-FRR path; Cilium uses hold 9 /
  keepalive 3 / connect-retry 5 because Cilium 1.20 has no BFD.
  Each cluster has a separate deterministic Cilium-side ASN. Cilium dials
  only its node-local FRR at `::1` (no `localPort`); FRR is not passive,
  sets `allow-reserved-ranges` and `bgp allow-martian-nexthop`, and
  rewrites the loopback next hop to the node's stable transport address.
  Zebra installs accepted remote routes. Cilium agents never peer with
  each other. Foreign routers consume the published ASN/CIDR/pool facts,
  accept only approved exact VIPs and opted-in prefixes, and peer through
  the `router` role; cluster-side `bgp.upstreamPeers` duplication is
  removed. Shared VIPs ECMP across advertisers; `node-bgp` VIPs have one
  advertiser.
- **D10 Private fleet routing fabric DEFAULT ON.** Per cluster by
  default: local Cilium↔FRR + BGP v2 resources and one private
  `shared-bgp` pool (ULA + RFC1918 from derived cluster CIDR space), with
  core VIPs (private CoreDNS, ClusterMesh apiserver, mirror Services).
  Public `shared-bgp` and `node-bgp` are opt-in; preconditions are
  upstream-routed space plus a controlled router. Non-goals: single
  dynamic residential IPv4 public BGP; heterogeneous multi-WAN inbound
  failover (DNS failover instead). Hetzner public edge = node-bound,
  node-bgp, floating + DNS failover. The fabric pool remains
  `<instance>-fabric` with blocks `172.16.<ciliumId>.0/24` +
  `fd11:<ciliumId>::/64` (overridable; non-overlap and capacity asserted);
  private CoreDNS is offset 53/0x53, pinned and ETP Local. `bgp.enable` ⇔
  "any node-bgp or shared-bgp pool exists" is eval-locked (§6.12).
- **D11 Fleet-routing is the flat-L3 fabric.** (REVISED round 14.) One
  instance is one trust domain; it owns per-pair WireGuard, FRR, BFD,
  Zebra route installation, role policy, and fleet DNS consumption for
  Kubernetes and non-Kubernetes machines. The legacy `wireguard-mesh`
  service and its ordinary-mesh-plus-auxiliary-routed-interface extension
  are retired after migration. Roles per D33.
- **D12 ClusterMesh apiserver exposure stays node-bound** mesh addresses
  + selectorless-Service DNS fan-in. Generalized for the kube-apiserver
  mirror Services (D30).
- **D13 Pod/ClusterIP consumption is role-scoped.** (REVISED round 14.)
  Cilium always advertises local multi-pool allocations to node-local FRR
  because native routing requires them. FRR distributes pod routes to all
  Kubernetes members in the trust domain. Non-Kubernetes `client` hosts
  receive VIPs only; `admin` explicitly consumes pod and ClusterIP routes
  and their DNS zones. There is no default direct pod/ClusterIP access for
  ordinary hosts.
- **D14 Raw L4 (games).** Plain `type: LoadBalancer` Services, never
  Gateways. Round-13 note: these are tenant/day-2 objects; the contract
  only guarantees the LB data plane they rely on (D41/D8).
- **D16 One cluster per node.** Inventory-wide eval assertion.
  Fleet-routing roles may coexist with cluster membership (D33).
- **D19 One integrated FRR configuration per host.** (REVISED round 14.)
  `fleet-routing` atomically renders `services.frr.config` from inventory
  and exports; distro services publish facts and render Cilium resources,
  never a second routing stack or independent FRR text fragments. Zebra
  owns kernel installation. `bgpd` and `bfdd` are enabled from the first
  implementation so daemon-set changes are not hidden by NixOS reload
  semantics. Configuration previews use `frr-reload.py --test`; config-only
  changes reload, while daemon-set changes require a documented `frr`
  restart. The legacy `clan.bird.fragments` renderer is removed after
  migration.
- **D21 The internal cluster domain is pinned to `cluster.local`.**
  Never changed, eval-asserted. Aliasing via CoreDNS rewrites (D22).
- **D22 Private-domain routing contract.** Default: client machines
  resolve ONLY the zone `<instance>.<meta.domain>` — a clan-rendered
  CoreDNS zone on the cluster's private CoreDNS VIP. Round-13 revision:
  the zone's wildcard target is whatever day-2 proxy the operator
  installs (previously the private Gateway VIP); the zone and VIP exist
  regardless. Per-client opt-ins (default-on for `admin`, D33):
  (a) service zone `<instance>.svc.<meta.domain>` → rewrites to
  `<name>.<ns>.svc.cluster.local` with answer-name reversal;
  (b) pod zone (`pods insecure` + dash-form rewrites + D13 pod
  advertisement). `cluster.local` is NEVER served to clients.
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
  `service.cilium.io/global: "true"`, `loadBalancerClass` pinned per D41.
  Consumers render the same-name Service; ClusterMesh merges endpoints.
  Consumer CoreDNS rewrite (rendered from exports):
  `kubernetes.<cluster>.<meta.domain>` → `kube-api-<cluster>.<ns>.
  svc.cluster.local`. Kubeconfigs (D37/D38) use the mirror DNS name
  directly as `server`; the cluster's API certificate SANs MUST include
  it (eval-asserted). NetworkPolicy restricts mirror-Service access to
  GitOps namespaces. Mesh connectivity is symmetric.
- **D33 Fleet-routing roles: `member`, `client`, `admin`, `router`.**
  (REVISED round 14.) `member` = per-pair mesh + FRR/BFD/Zebra and, on a
  Kubernetes machine, automatic native pod-route exchange. `client` =
  member + VIP routes + instance-zone DNS. `admin` = client + D13
  pod/ClusterIP consumption + D22 svc/pod zones default-on (kamrui-h1).
  `router` = member + upstream prefix ownership, filtered route exchange,
  forwarding, and optional NDP. Every interface has one peer and a
  deterministic instance/peer-derived collision-checked name ≤15
  characters. One machine joins at most one fleet-routing instance and
  holds one role there. **Node duality is legal** (D16): the same FRR
  handles local Cilium and fabric peers; no self-interface or second BGP
  stack. Canonical test shape: kamrui-h1 = single-node k3s + admin role.
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
- **D41 Node IPAM default; pools keep the VIP plane.** Canonical profile
  sets `nodeIPAM.enabled=true` + `defaultLBServiceIPAM=nodeipam`:
  classless `type: LoadBalancer` Services receive node IPs (ExternalIP
  preferred, else InternalIP), the k3s-ServiceLB experience on every
  distro — including stock Traefik under `distroDefaults`. With
  `externalTrafficPolicy: Local` the advertised node set follows real
  EndpointSlices (pod placement); the documented Cilium dummy-Endpoints
  limitation affects only Cilium's own Gateway/Ingress implementations,
  which are permanently disabled (D1) — third-party proxies with real
  backends (Envoy Gateway day-2) are unaffected. Clan-rendered VIP
  consumers (ClusterMesh apiserver, private CoreDNS, mirror Services)
  always pin a Cilium-handled `loadBalancerClass` and draw from pools
  (D8/D9/D10): `io.cilium/lb-ipam` for node-fate-bound/floating draws,
  `io.cilium/bgp-control-plane` for `node-bgp` and `shared-bgp` draws
  (the only class Cilium 1.20's BGP control plane announces, besides
  unset). Multi-pool remains the
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
  D28's controller install.) `controlDomain.role = standalone | hub |
  spoke` per cluster instance (default `standalone`), bounded by the mesh
  trust domain exactly as before (hub+spokes same mesh group; ≤1 hub per
  group; spoke ⇒ hub exists; eval-asserted). Clan renders ONLY the
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
- **D44 Test-surface reduction.** (REVISED round 14.) VM suites kept:
  single/join/HA per distro; netif + per-pair transport/FRR/BFD;
  native-routed ClusterMesh + mirror-Service reachability; **data-plane
  suite** (pool allocation + nodeipam + ETP-Local + native pod routes +
  node-bgp ownership + shared-bgp ECMP/withdrawal + firewall
  positive/negative); fleet-routing (member/client/admin/router incl.
  dual-role); PKI rotation; **GitOps-handoff
  proof** (bootstrap bundle applied, then re-applied SSA under a second
  field manager — strict no-op, dataplane green before/after; no Flux in
  VMs, Flux artifacts were cut from pkgs); rke2 CIS profile. Retired:
  EG gateway matrix, QUIC/Caddy fixtures, flux control-domain suite,
  external-dns, OpenEBS, KubeVirt, Multus, sealed-secrets suites.
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
  `cluster.local` and skips the clan one (the private-zone CoreDNS, D22,
  stays clan-rendered in both modes — own VIP, no conflict). Rationale:
  rke2's bundled CoreDNS cannot carry the rewrite/private-zone import
  uniformly; one DNS implementation makes the base identical across
  distros and anticipates D23. NOT bundled, ever: etcd (the distro's
  datastore, not an addon), metrics-server (kubectl top/HPA only,
  non-CNCF, day-2), local-storage/snapshot controllers (day-2). The
  uniform minimal base = distro runtime + Cilium + clan CoreDNS.

### Round 14 decisions (2026-10-24) — active

- **D47 Per-pair routed WireGuard is the only fabric datapath.** Every
  machine has a stable dual-stack `/32` + `/128` on a fabric
  loopback/dummy interface and exactly one point-to-point WireGuard
  interface per remote machine. Each interface has one peer and
  deterministic transfer prefixes; identical prefixes across interfaces
  are valid ECMP, while overlapping peers on one interface are forbidden.
  One UDP session per pair removes the legacy shared-identity roaming
  collision. AllowedIPs derive from the same policy as BGP filters. NAT
  members dial reachable members with keepalive 25; a pair with no
  reachable endpoint on either side is an eval error. Full mesh is the
  supported small/medium-fleet topology; hidden hub-and-spoke/route
  reflector variants are not part of the contract.
- **D48 FRR + Zebra owns the routing control plane and kernel FIB.** FRR
  10.7+ uses one integrated config, eBGP per AF per WG link, BFD on every
  FRR path, strict bidirectional policy, and ECMP across interfaces.
  Cilium only advertises to local FRR. Rejected: BIRD (superseded),
  Cilium agents peering directly across the fleet (couples manifests to
  transport and lacks BFD), and treating BGP itself as the datapath
  (Zebra/kernel forwarding is the datapath).
- **D49 Native-routed multi-pool Cilium is mandatory.** `routing-mode:
  native`, no VXLAN/Geneve, `auto-direct-node-routes=false`, dual-stack
  mesh-wide native-routing CIDRs, and Cilium devices covering every
  per-pair WG interface. FRR distributes remote `CiliumPodIPPool` routes;
  ClusterMesh requires native mode, non-overlap, and working pod routes in
  every member. Multi-pool remains the default; `ipam.mode: kubernetes`
  remains an explicit override. Cilium stays networking-only and no L7
  feature is enabled.
- **D50 Inventory owns the core host data plane.** `netif` declares
  links, static/DHCP/RA addressing, gateways, routes, policy routing,
  MTU, DNS, firewall trust, and deploy-target exports in `inventory.nix`.
  `fleet-routing` consumes its peer facts. Supporting NixOS modules may
  handle Wi-Fi association or platform quirks, but cannot own static core
  addresses/routes. Home's `hostSpec.networking`/`machines.json` static-IP
  ownership is removed during migration; borg's `lan` is a behavioral
  reference, not code to preserve.

## 5. Invariants (target; eval-asserted or VM-proven)

1. One declarative fleet: instance declaration ⇒ stable identity,
   non-overlapping defaults, integrated transport, automatic ClusterMesh
   when the mesh group has peers.
2. Dual-stack inside, always (nodes/pods/Services); public exposure
   varies per node/Service (v4-only, v6-only, both, neither).
3. Cilium is the only CNI base: one upstream 1.20+ profile, KPR, native
   routing, multi-pool; networking-only (D1/D49).
4. L3 only: no L2-announce/VRRP/shared-L2. Tested transport = one host
   WireGuard interface per node pair; every cluster dual-stack. `netif`
   may configure VLAN parents/children as underlay links, never as a
   shared cluster datapath.
5. ETP Local on every clan-rendered external-facing Service (mirror
   Services, ClusterMesh apiserver, private CoreDNS VIP); no silent
   Cluster fallback.
6. LB IPAM ownership unambiguous: classless Services → Node IPAM (D41);
   `io.cilium/lb-ipam` → non-BGP pools; `io.cilium/bgp-control-plane` →
   `node-bgp` or `shared-bgp` only, with owner/advertiser coherence (D8).
7. Topology always labeled: region/zone default to instance name,
   per-machine overrides, non-empty.
8. Hermetic proof: pinned artifacts, eval rejection of invalid
   inventories, hermetic VM suites.
9. One cluster per node (D16); one fleet-routing membership and one FRR
   per host (D19/D33); exactly one classless-LB implementation per
   cluster (Node IPAM; servicelb never — D42).
10. `cluster.local` is pinned and never served to clients (D21); private
    domains resolve through clan-rendered CoreDNS zones (D22).
11. Kubenix renders every clan manifest; two-layer pipeline, zero IFD in
    clanServices eval (D26); delivery = one bootstrap bundle, SSA, once
    (D40); Rancher helm-controller off by default (D42).
12. Control domain without clan-installed GitOps: standalone/hub/spoke
    (D43); mirror Service + mirror SAN mandatory for spokes (D30);
    hub+spokes share one mesh group; ≤1 hub per group; spoke ⇒ hub
    exists (eval-asserted).
13. Clan vars = bootstrap plane only (D35 revised); no clan vars
    generators for application-plane secrets (lint).
14. Artifact flake carries the last 3 k8s minors per distro (D34);
    airgap-ready is the tested default.
15. Every cluster mints admin + read-only (no-secrets) kubeconfigs
    (D38); the hub holds both for every spoke.
16. CNCF in-cluster posture for clan-rendered components (D24); rke2
    CIS-hardened by default (D25).
17. Every static core link/address/route is inventory-owned through
    `netif`; every fabric AllowedIP and BGP filter derives from one route
    policy; no default route or unapproved prefix leaks (D47/D50).

## 6. Subsystem contracts (condensed)

### 6.1 Ownership boundaries
Canonical repo = external-systems/clanServices. `netif` owns links and
static host routes; `fleet-routing` owns the encrypted fabric and one
integrated FRR configuration; thin distro services own
bootstrap/TLS-dir/join semantics and Cilium resources; shared lib
(`lib/kube-cluster/`) owns parity. Artifact flake = only packaging input
(distro runtimes, Cilium chart + committed inflated base manifest, test
fixtures); consumers pin immutable revisions. Supporting NixOS modules
may implement platform-specific association/tuning, never a parallel
static data plane. Day-2 software is pinned by operator GitOps repos,
never here (D39).

### 6.2 Identity, CIDRs, topology, exports
Cluster name = instance name (≤32 chars, DNS-style). `cilium.id`
nullable; default = stable hash of instance name → 1–127 (pure Nix, no
IFD); collisions are eval errors. Explicit 1–255 override requires
explicit v4 CIDRs above 127. Deployments predating hashed defaults must
pin current ids/CIDRs before upgrading. One resolved dual-stack CIDR
structure feeds distro, Cilium, DNS, pools, assertions, and exports.
region/zone labels default to instance name and must be non-empty.
`kube_cluster` publishes schema version, identity, pod/service CIDRs,
clusterDNS, mesh group, control-domain role, transport source, per-member
stable mesh endpoints/topology, pool handoff (scope, delivery, blocks,
selectors, owner), Cilium-side ASN, advertisement facts, fabric CoreDNS,
and API mirror facts. `fleet_routing` publishes per-node ASN,
loopback/per-pair interface facts, and router-owned prefixes.
`node_transport` publishes a versioned dual-stack transport view: stable
addresses, loopback and per-pair datapath interfaces, MTU, port,
nullable endpoint, native-routing posture, primary/external facts,
delivery modes, and topology. No secrets in exports; every leaf has a
default (clan CLI deep-eval).
Inventory-wide assertions cover duplicate names/ids/CIDRs/ASNs/pair
names/transfer prefixes, overlapping CIDRs, duplicate NodePorts, missing
peers/labels/endpoints, impossible NAT pairs, multiple fabric memberships
per machine, node-in-two-clusters, second routing stacks, native-routing
CIDR containment, and control-domain⇔mesh-group consistency. Fleet checks
read exports; per-instance/per-machine checks stay in the services.

### 6.3 Host networking and routed WireGuard transport
`netif` is the inventory-facing link service: static or DHCP/RA
addressing, prefixes, default/static routes, on-link gateways, policy
routing, MTU, DNS, firewall trust, and optional deploy-target export. Its
`peer`/`netif` exports feed endpoint selection. Static values may be
interpolated from the consumer's `secrets`/`not-secret` input; exports
still contain no private keys.

`fleet-routing` is the only tested overlay transport. Every member gets
stable dual-stack host addresses (existing hash defaults into
192.168.0.0/16 + fd77::/16, explicit pins allowed) on a fabric
loopback/dummy interface. For each remote member it renders exactly one
point-to-point WG interface with deterministic ≤15-character name,
instance/peer-derived transfer prefixes, one peer, and one UDP session.
The canonical pair key is `<instance>:<sorted-machine-a>:<sorted-machine-b>`;
its sha256 derives a /31 from 100.64.0.0/10 and a /127 from fd76::/16,
with the sorted endpoints assigned in the same order. Explicit per-pair
pins are the migration/collision escape. Pair/name/address collisions are
eval errors. The node keypair is
instance-scoped clan vars; public keys are public vars, private keys only
deploy to their owner.

AllowedIPs include the remote stable host addresses plus exactly the
prefixes that peer is authorized to receive: shared VIPs on every
advertiser interface, node-bgp VIPs only on the owner interface, pod
routes to Kubernetes members and `admin`, ClusterIPs only to `admin`,
and router-approved upstream prefixes. No default routes. The same
resolved policy renders FRR filters, preventing cryptokey/routing drift.
A pair needs at least one reachable endpoint; NAT/outbound-only members
omit endpoints and keepalive every 25 seconds. One mesh group = one
`fleet-routing` instance; one machine has at most one membership/role.

```nix
inventory.instances = {
  home-net = {
    module.input = "clanServices";
    module.name = "netif";
    roles.default.machines.kamrui-h1.settings = {
      interface = "wlp2s0";
      dhcp.ipv4 = true;
      mtu = 1500;
      targetHost = true;
    };
  };
  fleet = {
    module.input = "clanServices";
    module.name = "fleet-routing";
    roles = {
      member.machines.helsinki-manager-1 = { };
      admin.machines.kamrui-h1.settings.endpointSources = [
        { service = "netif"; instance = "home-net"; }
      ];
    };
  };
  spoke = {
    module.input = "clanServices";
    module.name = "k3s";
    roles.server.machines.kamrui-h1.settings.network.transport = {
      service = "fleet-routing";
      instance = "fleet";
    };
  };
};
```

All actual static addresses/routes live in inventory settings, not
supporting NixOS modules. Native Cilium uses the WG MTU directly; no
VXLAN `-50`.

### 6.4 Cilium base
Same canonical upstream Cilium 1.20+ chart/images both distros; RKE2
bundled Cilium disabled. Always: KPR, `routing-mode: native`, no
VXLAN/Geneve, multi-pool pod IPAM (default; derived non-clashing
dual-stack CIDRs), `auto-direct-node-routes: false`, BPF
masquerade+tproxy, Maglev, pmtu, Node IPAM (D41). Dual-stack
native-routing CIDRs cover all pod CIDRs in the mesh trust domain
(default `10.0.0.0/8` + `fd10::/16` for derived space; explicit overrides
must contain every explicit pod CIDR). Cilium device configuration covers
every per-pair WG interface. Cilium advertises local `CiliumPodIPPool`
allocations and authorized Service routes to local FRR; FRR/Zebra owns
remote routes. Native ClusterMesh requires the same mode everywhere,
non-overlap, node InternalIP connectivity, and working cross-cluster pod
routes.
Per-cluster variation lands in `cilium-config` and CRs through kubenix
merging over the committed base manifest (D26). Admin helm-values
overrides remain limited to layer-2-expressible keys and are post-merge
validated against native-routing/no-tunnel/IPAM/dual-stack/device/CNI/
artifact/ETP invariants. Multus follows D42. Lifecycle: bootstrap bundle
apply → GitOps adoption (D40); publish-freshness gated in CI.

### 6.5 ClusterMesh (automatic, mixed-distro)
Mesh groups (default = all cluster instances under `meta.domain`;
opt-out separates trust — and bounds control domains, D43). Every
eligible cluster runs clustermesh-apiserver + mesh certs from first
boot; singleton peer list empty. Peering rendered from exports into
`clustermesh.config.clusters` — no CLI. Exposure: LoadBalancer (default,
node-bound mesh addresses + ETP Local + ClientIP affinity, all servers
as endpoints, anti-affinity) with collision-checked NodePort escape.
DNS fan-in: selectorless local ClusterIP Service + eval-rendered
EndpointSlice per remote cluster — the same pattern, generalized,
carries the kube-apiserver mirror Services (D30; mandatory for spokes).
Shared `rancher-clustermesh-ca-<group>` vars generator (share=true);
per-cluster dependent cert generators; SANs include every exported
address + fan-in name; endpoint set is a public validation input
(membership change ⇒ reissue before advertise). CA/cert material never
in exports/helm/store. Same datapath, same Cilium profile,
maxConnectedClusters uniform. Global Services opt-in per Service (mirror
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
(no pools/BGP). Non-BGP pools use `io.cilium/lb-ipam`; `node-bgp` and
`shared-bgp` use `io.cilium/bgp-control-plane` or Cilium allocates without
announcing. Pool updates may reassign IPs and are reviewed changes.

| Delivery | Scope | Advertiser / failure semantics |
| --- | --- | --- |
| `node-fate-bound` | per-machine | Provider/static delivery; no BGP; follows owner |
| `node-bgp` | per-machine | Only owner advertises exact VIPs; no cross-node ECMP |
| `shared-bgp` | cluster-global | Every healthy eligible node advertises; FRR/upstream ECMP |
| `floating` | cluster-global | Runtime controller moves one address; blackhole window without it |
| `external-class` | cluster-global | Cloud CCM owns delivery |

`node-bgp` is the contract for node-owned public IPv4 extras and
carve-outs of a node's routed IPv6 subnet. Per-node BGP resources select
only that owner's pool. ETP Local withdraws when no eligible local
backend exists; consumers that require the address must keep eligible
backends on the owner. Other nodes must not re-advertise the route as if
shared. `shared-bgp` is the contract for private fabric VIPs and
upstream-router pools; all healthy eligible nodes originate the same
/32+/128 and FRR uses `maximum-paths` plus multipath-relax to retain
interfaces as ECMP members.

Local Cilium advertisements terminate on node-local FRR. FRR accepts only
owned node-bgp/shared-bgp VIPs, local multi-pool allocations, and
authorized ClusterIPs, then exports according to the receiving member's
role. Zebra installs remote routes on Kubernetes and fleet hosts alike;
Cilium's local endpoint routes remain more specific. FRR next-hop
rewriting resolves each path through its per-pair interface. Foreign
upstreams are configured only in `router` roles, with strict prefix and
maximum-prefix policy and optional proxy-NDP for on-LAN prefixes.

### 6.8 Day-2 proxy layer (out of contract)
No Gateway API, Ingress, or proxy implementation is clan-rendered
(revoked D2/D6/D7/D15/D17). The day-2 guide carries the Envoy Gateway
recipe: DaemonSet-mode EnvoyProxy on labeled workers, ETP Local (safe
with Node IPAM — real EndpointSlices, D41), `loadBalancerClass:
io.cilium/lb-ipam` + pool-label selectors or explicit
`lbipam.cilium.io/ips` projections for VIP draws from
node-fate-bound/floating pools — and `io.cilium/bgp-control-plane` when
the pool is `node-bgp` or `shared-bgp` (Cilium 1.20 only announces that class) — one
proxy
implementation per IP:port, QUIC-passthrough on its own VIP. The
contract guarantees the substrate (pools, BGP, firewall, DNS zones);
the proxy is GitOps-owned.

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
Eval rejects: multiple bootstraps; duplicate ids/CIDRs/ports/ASNs/pair
names/transfer prefixes; missing dual-stack or topology facts; pool
overlap; scope⇒mode violations; floating without candidates; `node-bgp`
without exactly one owner or with non-local advertisers; BGP pools
without `bgp.enable` or BGP without any `node-bgp`/`shared-bgp` pool;
fabric blocks too small; BGP pools outside router-owned prefixes;
node-in-two-clusters; multiple fleet memberships or routing stacks per
host; impossible NAT pairs; default-route/AllowedIP leaks; missing native
CIDR containment; VXLAN/Geneve or `auto-direct-node-routes` in the
canonical profile; Cilium devices missing WG links; ETP Cluster on
clan-rendered external Services; base-manifest drift; IFD smuggling;
unsupported k8s minor without acknowledgment; application-secret vars;
control-domain violations; spoke without mirror/SAN; servicelb; and
distro-manifests-dir delivery. The read-only ClusterRole never contains
`secrets` or write verbs (D38). Firewall: API on transport only; public
ports only where exposed; WireGuard only on configured underlays;
BGP/BFD only on loopback and expected WG/upstream peers; mirror Services
restricted to GitOps namespaces. VMs assert positive AND negative exposure.

### 6.13 Fleet-routing service
Per D11/D13/D19/D22/D33/D47/D48. `member`: stable loopback addressing,
one WG interface per remote member, FRR/BFD/Zebra, and automatic pod
routes when also a Kubernetes node. `client`: member + VIP routes +
instance-zone DNS. `admin`: client + D13/D22 svc/pod zones + pod/Service
route consumption. `router`: member + upstream peers, owned-prefix
filtering, forwarding, and optional NDP; proxies on a router are separate
operator modules. Node duality uses the same FRR, never a second stack.
Route-only DNS stubs use global systemd-resolved settings and the
kernel's per-member ECMP routes.

Acceptance: eval proves deterministic names/transfer prefixes,
peer/AllowedIP/filter equivalence, self-exclusion, role and collision
checks, and export defaults. Hermetic VMs prove real WG handshakes, FRR
sessions and BFD on both sides, RIB-to-FIB installation, native pod
round trips, client VIP ECMP/DNS, admin svc/pod/ClusterIP access to local
and foreign clusters, client pod-route isolation, node-bgp owner-only and
shared-bgp ECMP withdrawal, router filtering, NAT membership, and the
kamrui-h1 dual-role shape with local Cilium behavior intact.

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
domain. Singleton standalone = no hub config.

## 7. Testing contract (D44)

Seams: pure renderer nix-unit tests (kubenix render determinism
included); throwaway clans via `clanLib.clan` (inventory boundary);
`clan.nixosTests` hermetic VM suites (one at a time, sandboxed
authoritative); artifact source/hash/render gates (incl.
committed-manifest inflation proofs and publish-freshness checks,
D26/D40). Standard internal HTTP test workload: **go-httpbin** (pinned,
airgap-carried as a test-fixture artifact). Rules: hermetic/offline;
eval-deterministic addresses; dual-stack asserted in every boot test;
round-trips + failure behavior (BGP withdrawal keeps VIP via healthy
nodes); negative assertions; operational postconditions; fail fast.
Minimal airgapped artifacts for hermetic VM tests is a hard requirement.

Suites (the whole contract surface — nothing else is VM-tested):
- existing single/join/HA per distro (keep; native datapath asserted);
- **netif**: static/DHCP/RA, on-link and policy routes, exports;
- **fleet transport/FRR**: 3+ node dual-stack per-pair WG full mesh, real
  handshakes, NAT/outbound-only member, no `(none)` AllowedIPs; FRR
  sessions and BFD on both sides; RIB-vs-kernel FIB; per-pair next hops;
  route-filter and default-route negatives; reload/restart behavior;
- artifact matrix (3-minor version pins eval, D34);
- **data-plane suite per distro**: native pod-to-pod without VXLAN,
  multi-pool remote routes, pool allocation, classless Node IPAM,
  ETP-Local candidate restriction, node-bgp owner-only advertisement and
  withdrawal, shared-bgp dual-stack ECMP and single-path withdrawal
  (including Linux `ip -j` single-path shape), floating-pool blackhole
  window, firewall positive/negative exposure;
- **bgp-ecmp suite**: private fabric, MikroTik-style FRR foreign-router
  fixture, upstream router pools and node-owned IPv6 pools;
- native ClusterMesh matrix (cross-cluster pod routes + kube-api mirror
  Service reachability, D30);
- PKI rotation (+ cert bootstrap runbook execution);
- CCM knob suite (hermetic fake-CCM);
- **GitOps-handoff suite** (D40/D44): strict no-op under a second SSA
  field manager, dataplane green before/after; no Flux in VMs;
- `distroDefaults` suite (D42) and rke2 CIS profile suite (D25);
- fleet-routing suite (member/client/admin/router, client pod isolation,
  admin svc/pod/ClusterIP access and DNS, router filtering, kamrui-h1
  dual-role);
- control-domain suite (D43/D30/D38): hub + two spokes + standalone,
  mirror-SAN and read-only positive/negative, rotation, offline spoke.

Retired suites (round 13): EG gateway matrix, QUIC/Caddy fixtures, flux
control-domain suite, external-dns, OpenEBS, KubeVirt, Multus,
sealed-secrets. Reserved: MCS-API, upstream-kubernetes distro suites
(D23).

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
  schemaVersion/identity/CIDRs/meshGroup/transport source/member mesh
  endpoints incl. effective topology/pool handoff facts from both distro
  services; `node_transport` gained topology fields. Fleet-wide
  assertions (id collisions, duplicate names, same-group pod/service CIDR
  overlap, node-in-two-clusters across rke2+k3s (D16), mesh-group
  transport consistency) are `clan.checks` computed from the
  `kube_cluster` exports by the shared lib's fleet-checks module
  (wired into this flake's own clan and into the eval-test throwaway
  clans; consumers wire `clan.imports = [ fleetChecksModule ]`).
  All-or-none transport posture (§6.3) is a per-instance assertion.
  Legacy wireguard-mesh addresses are derived by default (stable hash of
  mesh instance + machine name → 192.168.0.0/16 + fd77::/16); round 14
  preserves those stable addresses while replacing the interface model.
- **5R0 done (docs only)** — round-14 FRR/per-pair-WG/native-Cilium
  contract, inventory-owned netif family, node-bgp delivery, and delivery
  re-plan. No implementation or VM claim.
- **5 legacy checkpoint, not accepted** — `2995ac3` contains BIRD/VXLAN
  Phase 5 work; retained baseline 5 green / 7 red. It is superseded by
  round 14 and is not a base for further BIRD debugging.
- **5R1 planned** — implement `netif` and per-pair `fleet-routing` with
  FRR/BFD/Zebra, versioned exports, eval tests, and hermetic transport/
  FRR suites. Migrate consumers; retire `wireguard-mesh` after parity.
- **5R2 planned** — re-inflate the pinned Cilium base in pkgs with the
  native profile; implement local Cilium↔FRR pairing, multi-pool route
  exchange, native CIDR/device/MTU invariants, and node-bgp/shared-bgp
  delivery in shared lib + both distros; update the artifact pin.
- **5R3 planned** — native ClusterMesh/multi-cluster, fleet roles/DNS/
  router/dual-role, failure/withdrawal/firewall suites. Remove legacy
  BIRD modules/options/tests only after replacement coverage is green.
- **6** — automatic ClusterMesh (apiserver node-bound + fan-in) +
  control domain: mirror Services (D30), `gitops-hub` identities +
  secret-sync + read-only credential (D43/D38).
- **7** — PKI ops + rotation runbooks/scripts, RKE2 CIS suite (D25),
  CCM knob + fake-CCM test, GitOps-handoff proof suite (D44),
  `distroDefaults` suite.
- **8** — borg migration + upstream review: home consumes `netif` and
  `fleet-routing`, removes `hostSpec.networking`/`machines.json` static-IP
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
reference only). Also: alternative CNIs / VXLAN/Geneve or other tunnel
bases / BIRD / L2 announcements / VRRP / Keepalived; single-stack internals; Rancher
Manager; cross-inventory automatic mesh; implicit global Services;
early/default-on MCS-API; bundled provider CCMs; replicated storage;
Windows guests; direct-to-pod routing from edges; NAT64/app egress
remediation; same VIP advertised from two clusters; pod/ClusterIP routes
to non-Kubernetes hosts by default (admin role excepted, D33); public
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
(D35); external-dns for inter-cluster DNS (D22 covers private naming).

## 10. Glossary

- **Bootstrap contract** — the day-1 promise that a declared cluster
  exists and is reachable: distro install/join, PKI, HAProxy kubeapi HA,
  bootstrap bundle, control-domain substrate (§3.1).
- **Data-plane contract** — the day-1 promise that packets flow
  correctly: native Cilium CNI, Node IPAM + pools, FRR/BGP/Zebra,
  ClusterMesh, per-pair host WireGuard, CoreDNS zones, fleet-routing (§3.2).
- **Day-2 GitOps** — everything in-cluster that is not the two
  contracts; installed and owned by operator GitOps repos, documented
  here as recipes only (§3.3).
- **Bootstrap bundle** — the single kubenix-rendered manifest set per
  cluster, applied once via SSA on the `clusterInit` node (D40).
- **Cluster services** — public rke2/k3s/kubernetes clanServices +
  private shared library; not Rancher Manager.
- **Shared lib** — `lib/kube-cluster/` (renamed from
  `lib/rancher-cluster/`, D45): interfaces, renderers, vars, assertions.
- **Artifact flake** — external-systems/pkgs; distro runtimes (last 3
  minors, D34), Cilium chart + committed base manifest, test fixtures.
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
- **Trust domain** — the ClusterMesh mesh group string (default
  `meta.domain`); bounds ClusterMesh peering AND control domains (D43).
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
- **Integrated node transport** — per-pair routed L3 host WireGuard full
  mesh carrying dual-stack node InternalIPs, API, native pod traffic,
  FRR/BGP, and BFD.
- **Mesh group** — mutually trusted cluster instances forming one
  ClusterMesh; the trust domain string.
- **Pool scope** — per-machine (node-named, one owner) vs cluster-global
  (generic-named); who contributes a pool's addresses.
- **Delivery mode** — node-fate-bound | node-bgp | floating | shared-bgp |
  external-class; how traffic reaches pool addresses + failure semantics.
- **Node IPAM** — Cilium's LoadBalancer feature (helm `nodeIPAM.enabled`)
  that advertises node IPs (ExternalIP, else InternalIP) as a Service's
  LB ingress; the classless-Service default (D41). Distinct from
  `ipam.mode: kubernetes` (pod IPAM), which is an allowed override.
- **LB IPAM pool** — CiliumLoadBalancerIPPool; serves Cilium-handled
  classes (`io.cilium/lb-ipam`, `io.cilium/bgp-control-plane`).
- **Node-fate-bound delivery** — provider/static routing to one node; no
  failover, no BGP.
- **Node BGP delivery** — only the owner node advertises exact VIPs from
  its per-machine pool; no cross-node ECMP.
- **Floating delivery** — runtime controller moves the address to one
  node at a time; failover is the controller's contract.
- **Shared BGP VIP** — address advertised from all healthy nodes
  (ETP-Local withdrawal); the `shared-bgp` mode of a cluster-global pool.
- **Private fleet fabric** — default per-cluster private shared-bgp pool
  + FRR/BGP/Zebra + CoreDNS/mesh VIPs; lets clan hosts route into every
  cluster.
- **Fleet-routing service** — clanService (member/client/admin/router)
  providing flat-L3 transport, VIP access, admin pod/Service routes, and
  upstream routing.
- **Private-domain zones** — per-cluster DNS zones served by cluster
  CoreDNS on the private VIP: `<instance>.<domain>` (default) and opt-in
  `<instance>.svc.<domain>` and pod zone. `cluster.local` never appears
  on clients.
- **Managed base** — labeled clan-rendered APIs/resources installed once
  via the bootstrap bundle; tenant resources GitOps-owned.
- **Airgap-ready** — all artifacts pinned and local at boot.
- **VM-proven** — behavior passed fresh, sandboxed, hermetic on final
  tree.

## 11. Key upstream references

- Cilium 1.20: native routing (`routing-mode: native`; remote pod routes
  require a system routing daemon when nodes are not on one L2),
  multi-pool `CiliumPodIPPool` advertisements, LB IPAM, Node IPAM (the
  ETP-Local EndpointSlice caveat affects only Cilium's own
  Gateway/Ingress, D41), BGP v2, ClusterMesh (same datapath, non-overlap,
  node connectivity, mesh-wide native-routing CIDR), and the Gateway gaps
  behind D1. Configuration uses the rendered `cilium-config` ConfigMap
  (D26 layer-2 seam); official install = Helm, cosign-signed
  digest-pinnable OCI charts; the chart ships no `crds/` dir — the
  operator manages CRDs at runtime (D40).
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
  interfaces, never overlapping AllowedIPs across peers on one interface
  (D47).
- hcloud-ip-floater (costela): floating-IP mover reference; upstream
  effectively unmaintained (last non-dependabot commit 2023) —
  fork-don't-depend.
- go-httpbin (mccutchen): standard airgapped HTTP VM-test workload.
