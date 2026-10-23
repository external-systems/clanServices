# Kubernetes cluster clanServices — Full Specification (agent edition)

Single dense contract for agents; `documentation/` (MkDocs) is the human
record. **Same spec, two renderings — edit both together.** This file is
both the *target contract* and the *status authority*. Baseline: canonical
import (`896acdf` in this repo); recorded green: wireguard-mesh + rke2/k3s
single/join/HA VM suites in the source fork.

Revised 2026-10-22: **round 13 — data-plane-only scope reduction.** The
contract narrows to two verifiable promises — the Bootstrap contract and
the Data-plane contract (D39). Everything else that was spec'd as
clan-rendered in-cluster software is revoked and becomes documented day-2
GitOps patterns. New decisions D39–D45; revoked: D2, D4, D5, D6, D7, D15,
D17, D18, D20, D28, D29, D31, D32; revised: D1, D3, D8, D26, D27, D35,
D36, D37. Round history is retained in §4 with per-decision status.

Round-8 amendments (2026-10-20, retained): **A1** artifact flake packages
the last 3 k8s minors per distro (→ D34). **A2/A3** application-plane
credentials are never clan vars (→ D35, narrowed further in round 13).
**A4** spec locks land without code changes in the same commit — round 13
also lands docs-only; code changes are scheduled in §8.

## 1. Problem (condensed)

Declare machines + cluster instances in `inventory.nix`, receive working,
secure, interconnected Kubernetes clusters (rke2, k3s, upstream kubeadm —
D23 Reserved) whose **bootstrap and data plane are a verifiable contract**.
Hard interacting requirements: multi-cluster identity/CIDR coherence;
mandatory dual-stack regardless of underlay; bare-metal LoadBalancing =
allocation + delivery + datapath (three different things); address
families asymmetric in the real world; artifacts and services have
different release cycles; misconfiguration must fail at eval where
possible, VM-proven where not. **Explicitly not the problem**: which
ingress/Gateway/proxy, certificate, storage, virtualization, or GitOps
software runs in the cluster — that is day-2, owned by GitOps
repositories, never by NixOS host configuration. Applying manifests via
`clan machines update` (host churn for in-cluster state) is the anti-goal
this revision removes.

## 2. Architecture in one paragraph

Thin public `rke2` + `k3s` clanServices (upstream `kubernetes`/kubeadm
spec'd, Reserved) over a private shared library (`lib/kube-cluster/` —
renamed from `lib/rancher-cluster/` in delivery phase 1, D45):
shared interfaces, kubenix renderers, vars generators, assertions. Host
WireGuard full mesh is the only tested node transport (dual-stack,
all-or-none per mesh trust domain). Cilium = CNI + KPR + VXLAN tunnel +
multi-pool pod IPAM + Node IPAM for classless LoadBalancer Services + LB
IPAM pools + BGP v2 + ClusterMesh — networking only (D1). Per-node BIRD +
default private BGP fleet fabric; the fleet-routing clanService extends
VIP/pod/Service reachability to non-Kubernetes NixOS hosts. HAProxy on
every node gives HA kubeapi access and the join URL. The entire day-1
in-cluster surface is ONE kubenix-rendered bootstrap bundle, applied once
via server-side apply on the `clusterInit` node (D40) — no Rancher
helm-controller, no host-resident manifest dirs. Clusters run standalone,
or as hub/spoke control domains (D43): clan mints the kubeconfigs, RBAC,
and API mirror Services that let any GitOps tool (Flux, Argo) manage
spokes from a hub, but installs no GitOps controller itself. Day 2 =
GitOps takes over: Cilium ownership transfers by adopting the identical
published manifest set (first reconcile is a no-op by construction), and
all other cluster software (Envoy Gateway, cert-manager, external-dns,
Sealed Secrets, OpenEBS, KubeVirt, CCMs) is installed and owned by GitOps
repos. Artifact flake (`external-systems/pkgs`) pins the distro runtimes
(last 3 minors each), the Cilium chart with its committed inflated base
manifest, and test fixtures; airgap-ready is the tested default.

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
  (Cilium, pools, ClusterMesh config, CoreDNS zones, mirror Services,
  RBAC), applied once by a oneshot on the `clusterInit` node via
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

- Cilium only: one canonical upstream 1.20+ profile — KPR, VXLAN,
  multi-pool pod IPAM with derived non-clashing dual-stack CIDRs, BPF
  masquerade+tproxy, Maglev, pmtu. `ipam.mode: kubernetes` allowed as an
  explicit override. Admin helm-values override hatch with post-merge
  invariant validation (§6.4).
- **Node IPAM on by default** (`nodeIPAM.enabled=true`,
  `defaultLBServiceIPAM=nodeipam`, D41): classless `type: LoadBalancer`
  Services get node IPs, ServiceLB-style; ETP-Local-aware candidate
  selection. Pool/BGP VIP draws use explicit
  `loadBalancerClass: io.cilium/lb-ipam`, set automatically by every
  clan-rendered VIP consumer.
- LB-IPAM pool model (D8 revised), BGP v2 + per-node BIRD (D9/D19),
  default private fleet fabric (D10), floating pools via runtime
  controllers (e.g. hcloud-ip-floater pattern).
- ClusterMesh automatic per mesh group, mixed-distro (§6.5).
- Host WireGuard full mesh (§6.3) — the only tested transport;
  cilium-wireguard/unencrypted survive only as untested helm-values
  overrides.
- CoreDNS private zones (D21/D22) + pod/Service advertisement opt-ins
  (D13): DNS into every cluster for clan hosts.
- **fleet-routing** clanService (client/admin/router, D33) from day one.
- No Gateway, no Ingress, no proxy implementation in the contract. The
  data-plane proof uses plain `type: LoadBalancer` Services + firewall
  positive/negative assertions (§7).

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

## 4. Decision record (D1–D45)

Statuses: **active** | **REVISED** (round noted) | **REVOKED** (round 13
unless noted) — revoked entries keep one-line reasons for history.

### Active decisions (rounds 1–12, text unchanged in substance)

- **D1 Cilium is networking-only.** (REVISED round 13: reaffirmed, and now
  the ONLY in-cluster Cilium surface.) `gatewayAPI.enabled=false`,
  `ingressController.enabled=false` permanently. Reasons: no Gateway
  HTTP/3 (cilium#28497), no Gateway mTLS (GEP-91), no DaemonSet mode, no
  multi-Gateway IP sharing (cilium#25567). Round-13 consequence: the
  Cilium dummy-Endpoints Node-IPAM limitation never applies here (D41).
- **D8 Pool model: 2 scopes × 4 delivery modes.** (REVISED round 13:
  pools serve only Services with `loadBalancerClass: io.cilium/lb-ipam`;
  classless Services go to Node IPAM, D41.) Pool = address inventory +
  `serviceSelector` only. Scope: *per-machine* → node-named pools (auto
  join-address /32+/128 + declared primary/extra blocks; always
  node-fate-bound); *cluster-global* → generic-named pools. Delivery:
  `node-fate-bound` | `floating` (runtime controller moves IP, one node
  at a time; blackhole window; requires full local proxy coverage on
  candidate set) | `shared-bgp` (all healthy nodes advertise /32+/128;
  router ECMPs; ETP-Local withdrawal) | `external-class` (cloud CCM).
  Assertions: blocks non-overlapping; scope⇒mode validity; BGP only for
  `shared-bgp`; floating ⇒ candidate-set coverage; `shared-bgp` blocks ⊆
  router-role prefixes when router in same inventory.
- **D9 BGP topology + foreign-router contract.** Cilium GoBGP originates
  VIP routes, dials OUT over loopback to per-node BIRD (no :179
  listener); BIRD imports only approved exact VIPs, exports only those
  upstream, no broad kernel install on cluster nodes; upstream router
  hears the same route from every healthy node → ECMP. Cilium agents
  never peer with each other. Deterministic 2 private 32-bit ASNs per
  cluster + per-node router id. Timers: hold 9 / keepalive 3 /
  connect-retry 5. Foreign-router contract (published): ASNs, timers,
  accept only pool blocks as /32+/128 with max-prefix + prefix filters,
  ECMP path count ≥ node count, proxy-NDP if on-LAN. BIRD rendered via
  the vendored named-fragment pattern (D19).
- **D10 Private fleet routing fabric DEFAULT ON.** Per cluster by
  default: per-node BIRD + BGP v2 resources, one private `shared-bgp`
  pool (ULA + RFC1918 from derived cluster CIDR space), core VIPs on it
  (private CoreDNS, ClusterMesh apiserver, mirror Services). Public
  `shared-bgp` opt-in; preconditions: upstream-routed space + controlled
  router. Non-goals: single dynamic residential IPv4 public BGP;
  heterogeneous multi-WAN inbound failover (DNS failover instead).
  Hetzner public edge = node-bound + floating + DNS failover. One VIP per
  cluster — never advertise the same VIP from two clusters.
- **D11 Fleet-routing clanService (working name `cluster-client`).**
  Non-Kubernetes clan hosts → cluster VIPs. Roles per D33.
- **D12 ClusterMesh apiserver exposure stays node-bound** mesh addresses
  + selectorless-Service DNS fan-in. Generalized for the kube-apiserver
  mirror Services (D30).
- **D13 Pod/ClusterIP advertisement to hosts: opt-in, default off.**
  Hosts reach Services via VIPs, never pods or ClusterIPs directly —
  except via the fleet-routing `admin` role (D33).
- **D14 Raw L4 (games).** Plain `type: LoadBalancer` Services, never
  Gateways. Round-13 note: these are tenant/day-2 objects; the contract
  only guarantees the LB data plane they rely on (D41/D8).
- **D16 One cluster per node.** Inventory-wide eval assertion.
  Fleet-routing roles may coexist with cluster membership (D33).
- **D19 BIRD rendering: vendored named-fragment pattern.** Multiple
  clanServices contribute named blocks to ONE bird daemon; vendored into
  the shared lib with `filters`/`functions` maps; keys namespace-prefixed
  per instance; same-key = text concat (avoid); `routerId` set exactly
  once; `bird -p` pre-start check remains the validator. One BIRD per
  host; fleet-routing roles on a cluster member merge into its existing
  BIRD; eval asserts no second BGP stack / ASN conflict.
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
  (BIRD, WireGuard, HAProxy) exempt. rke2 = documented distro-layer
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
- **D33 Fleet-routing roles: `client`, `admin`, `router`.** `client` =
  mesh join, BIRD peering, VIP routes, gateway-zone DNS stub. `admin` =
  client + D13 consumption + D22 svc/pod zones default-on (e.g.
  kamrui-h1). `router` = upstream prefix ownership, filtered VIP
  acceptance, NDP. **Node duality is legal** (D16 coexistence; BIRD
  fragments merge per D19). Canonical test shape: kamrui-h1 =
  single-node k3s + admin role.
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
  always pin `loadBalancerClass: io.cilium/lb-ipam` and draw from pools
  (D8/D9/D10 unchanged). Multi-pool remains the default pod IPAM with
  derived non-clashing CIDRs; `ipam.mode: kubernetes` is an allowed
  explicit override (the old Node-IPAM ban referred to pod IPAM; both
  readings are now permitted/overridden explicitly).
- **D42 `distroDefaults` knob; servicelb permanently off.** Default
  `distroDefaults.enable = false` gives a uniform minimal base across
  rke2/k3s/kubernetes: no helm-controller, no Traefik, no servicelb, no
  distro add-ons. `true` (rke2/k3s only): the service refrains from
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
- **D44 Test-surface reduction.** VM suites kept: single/join/HA per
  distro; transport (host-wireguard only); ClusterMesh + mirror-Service
  reachability; **data-plane suite** (pool allocation + nodeipam
  classless Service + ETP-Local candidate restriction + shared-bgp ECMP
  + withdrawal + firewall positive/negative); fleet-routing
  (client/admin/router incl. dual-role); PKI rotation; **GitOps-handoff
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

## 5. Invariants (target; eval-asserted or VM-proven)

1. One declarative fleet: instance declaration ⇒ stable identity,
   non-overlapping defaults, integrated transport, automatic ClusterMesh
   when the mesh group has peers.
2. Dual-stack inside, always (nodes/pods/Services); public exposure
   varies per node/Service (v4-only, v6-only, both, neither).
3. Cilium is the only CNI base: one upstream 1.20+ profile, KPR, VXLAN,
   multi-pool; networking-only (D1).
4. L3 only: no VLAN/L2-announce/VRRP/shared-L2. Tested transport =
   host-wireguard; every cluster dual-stack.
5. ETP Local on every clan-rendered external-facing Service (mirror
   Services, ClusterMesh apiserver, private CoreDNS VIP); no silent
   Cluster fallback.
6. LB IPAM ownership unambiguous: classless Services → Node IPAM (D41);
   `loadBalancerClass: io.cilium/lb-ipam` → pools (D8); BGP only for
   `shared-bgp` pools; private fabric default, public opt-in (D9/D10).
7. Topology always labeled: region/zone default to instance name,
   per-machine overrides, non-empty.
8. Hermetic proof: pinned artifacts, eval rejection of invalid
   inventories, hermetic VM suites.
9. One cluster per node (D16); fleet-routing roles may coexist (D33);
   one BIRD per host (D19); exactly one classless-LB implementation per
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

## 6. Subsystem contracts (condensed)

### 6.1 Ownership boundaries
Canonical repo = external-systems/clanServices; thin distro services own
bootstrap/TLS-dir/join semantics; shared lib (`lib/kube-cluster/`) owns
parity; artifact flake = only packaging input (distro runtimes at release
tags, last 3 minors — D34; Cilium chart + committed inflated base
manifest — D26; test fixtures); consumers pin immutable revisions;
fleet-routing and tenant resources are consumers, never hidden
dependencies. Day-2 software is pinned by operator GitOps repos, never
here (D39).

### 6.2 Identity, CIDRs, topology, exports
Cluster name = instance name (≤32 chars, DNS-style). `cilium.id`
nullable; default = stable hash of instance name → 1–127; collision =
eval error; explicit 1–255 override requires explicit v4 CIDRs above 127.
Migration: pin existing ids/CIDRs before hashed defaults land. One
resolved dual-stack CIDR structure feeds distro, Cilium, DNS, pools,
assertions, exports. region/zone labels default to instance name,
per-machine overrides. `rancher_cluster` instance export: identity, mesh
group, control-domain role (D43), CIDRs, mesh endpoints, pool handoff,
API mirror facts (D30), schema version. `node_transport` per-node
export: mesh/underlay addresses, interface, MTU, primary/external facts,
delivery modes, topology. No secrets in exports. Inventory-wide
assertions: duplicate names/ids/CIDRs, overlapping CIDRs (incl.
fleet-wide PodCIDR non-overlap for meshed clusters, D33), duplicate
NodePorts, missing peers, missing labels, node-in-two-clusters (D16),
control-domain⇔mesh-group consistency (D43).

### 6.3 Transport
Host WireGuard full mesh is the only tested transport: every node gets
mesh v4+v6 (deterministic from id + machine name); per-machine overrides
(addresses, port, endpoint, interface, MTU, routes, pool blocks).
All-or-none per mesh trust domain: a cluster mesh shares one transport
posture. Mesh groups: cross-cluster peering from exports + public vars
keys, remote prefixes only in AllowedIPs; every remote node InternalIP
reachable before ClusterMesh ready. MTU: transport MTU −50 = tunnel
budget. `transport.mode = cilium-wireguard | unencrypted` survive only
as untested Cilium helm-values overrides — no contract, no VM coverage.
Distro HTTP-proxy setting = documented escape only.

### 6.4 Cilium base
Same canonical upstream Cilium 1.20+ chart/images both distros; RKE2
bundled Cilium disabled. Always: KPR, VXLAN, multi-pool pod IPAM
(default; derived non-clashing dual-stack CIDRs), BPF masquerade+tproxy,
Maglev, pmtu, Node IPAM for classless LB Services (D41). Per-cluster
variation lands in the `cilium-config` ConfigMap and CRs via kubenix
module merging over the committed base manifest (D26). Admin escape
hatch: arbitrary helm-values overrides, post-merge validated against
routing/tunnel/IPAM/dual-stack/CNI-chaining/artifact/ETP invariants —
the base must never block an operator from using Cilium in any way they
see fit; the contract only guarantees the un-overridden profile.
Multus optional: chaining switch is explicit + atomic (and under
`distroDefaults` the distro's own Multus is stock, D42). Lifecycle:
bootstrap bundle apply → GitOps adoption (D40); publish-freshness gated
in CI.

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

### 6.7 Pools, LB, BGP, BIRD
Per D8/D9/D10/D19/D41. Node IPAM serves classless Services with node
IPs (no pools, no BGP — delivery is the node's own address). Zero-config
single-node example: node-1 with join addresses 10.0.0.1/32 + fd0::1/128
⇒ pool `node-1` with exactly those blocks, `loadBalancerClass`
`io.cilium/lb-ipam`. Generic tenant draw = one IP per family from
labeled pools. Pool updates may reassign IPs (Cilium-side) ⇒ reviewed
network changes. Floating pools: runtime controllers (e.g.
hcloud-ip-floater — unmaintained upstream; fork-don't-depend) move
addresses; clan asserts shape + coverage only. Node-bound BGP pools can
hand addresses to non-cluster consumers (e.g. KubeVirt VMs with
provider-assigned MACs on Hetzner bare metal) — the pool/BGP contract
is day-1; the consumers are day-2. BIRD-on-hosts (client/admin/router)
installs routes into the kernel; cluster nodes do not broadly install —
except `admin` role consumption of D13 advertisements (D33).

### 6.8 Day-2 proxy layer (out of contract)
No Gateway API, Ingress, or proxy implementation is clan-rendered
(revoked D2/D6/D7/D15/D17). The day-2 guide carries the Envoy Gateway
recipe: DaemonSet-mode EnvoyProxy on labeled workers, ETP Local (safe
with Node IPAM — real EndpointSlices, D41), `loadBalancerClass:
io.cilium/lb-ipam` + pool-label selectors or explicit
`lbipam.cilium.io/ips` projections for VIP draws, one proxy
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
Eval rejects: multiple bootstraps, duplicate ids/CIDRs/ports, missing
dual-stack facts, missing topology labels, pool overlap, scope⇒mode
violations, floating without candidate coverage, `shared-bgp` ⊄ router
prefixes, node-in-two-clusters, second BGP stack per host, ETP Cluster
on clan-rendered external Services, published base manifest drift from
the renderer (CI gate), IFD-smuggling manifest paths (D26), unsupported
k8s minor without acknowledgment (D34 warning), clan vars generators
declared for application-plane secrets (D35 lint), control-domain⇔mesh
violations (D43), spoke without mirror Service / mirror SAN missing from
API cert (D30/D43), servicelb enabled anywhere (D42), distro manifests
dir used for clan manifests (D40). The read-only ClusterRole never
containing `secrets` or write verbs is renderer-fixed and VM-proven
(D38). Firewall: API on transport only; public ports only where a
Service exposes them; mesh/BGP restricted to expected peers; mirror
Services reachable only from GitOps namespaces (D30). VM tests assert
positive connectivity AND negative exposure.

### 6.13 Fleet-routing service
Per D11/D13/D19/D22/D33. `client`: mesh join, BIRD peering, route
install, DNS stub = `<instance>.<domain>` zone only. `admin`: client +
D13/D22 svc/pod zones + pod/service route consumption. `router`:
upstream prefix ownership, filtered VIP acceptance, NDP — the router
role can define pools for its downstream cluster(s) and advertise
service VIPs + pod IPs upstream; edge proxies on a router machine (e.g.
Traefik with the Kubernetes provider) are the operator's nixosModules,
NOT fleet-routing's concern. Node duality legal (D33). Acceptance:
client reaches cluster VIPs (routes + DNS stub) on a non-cluster host;
admin resolves svc/pod zones and routes OTHER clusters' CIDRs; router
accepts only owned prefixes; cross-inventory prefix assertions;
MikroTik-style foreign-router runbook; dual-role cluster-member suite
(kamrui-h1 shape).

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
- existing single/join/HA per distro (keep);
- transport (host-wireguard full mesh, incl. all-or-none trust-domain
  posture);
- artifact matrix (3-minor version pins eval, D34);
- **data-plane suite**: pool allocation via `io.cilium/lb-ipam`,
  classless Service → Node IPAM node IPs (ServiceLB parity), ETP-Local
  candidate restriction under nodeipam, `shared-bgp` ECMP + withdrawal,
  floating-pool documented blackhole window, firewall positive AND
  negative exposure;
- bgp-ecmp suite (+ private fabric, MikroTik-style foreign-router
  fixture);
- ClusterMesh matrix (+ kube-api mirror Service reachability, D30);
- PKI rotation (+ cert bootstrap runbook execution);
- CCM knob suite (hermetic fake-CCM);
- **GitOps-handoff suite** (D40/D44): bootstrap bundle applied by
  `clan-bootstrap`, then re-applied server-side under a second field
  manager — strict no-op (no object drift, dataplane green before and
  after); no Flux in VMs;
- `distroDefaults` suite (D42): stock rke2/k3s deploy Traefik via their
  own helm-controller; classless Traefik Service gets node IPs from
  Node IPAM; servicelb stays off;
- rke2 CIS profile suite (D25);
- fleet-routing suite (client/admin split, dual-role cluster member,
  opt-in svc/pod rewrite zones, D13/D22/D33);
- control-domain suite (D43/D30/D38): hub + two spokes + one standalone
  in a mesh — hub-held kubeconfigs resolve through the mesh; spokes run
  no GitOps controller; mirror-SAN assertion; read-only credential
  positive (list pods/nodes) + negative (secrets forbidden);
  cert rotation re-issue keeps access green; standalone unaffected but
  mesh-reachable.

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
- **2 NEXT — ACTIVE** — artifact flake narrowing (external-systems/pkgs): drop
  envoy-gateway/cert-manager/flux/external-dns/multus/sealed-secrets
  components + freshness checks; keep distro runtimes (3 minors), Cilium
  chart + committed inflated manifest, go-httpbin; add Cilium image
  airgap set; clean-public-fetch proof.
- **3** — kubenix bootstrap bundle + bootstrap-apply oneshot
  (`clusterInit` node, SSA, `bootstrap.apply` off-ramp, D40); canonical
  Cilium profile with Node IPAM (D41); pools (D8); ETP-Local rendering;
  override validation.
- **4** — host-wireguard transport, hashed ids, topology, dual-stack
  exports; one-cluster-per-node assertion.
- **5** — BGP v2 + BIRD + private fleet fabric (vendored BIRD fragment
  renderer) + fleet-routing service (client/admin/router; dual-role
  suite).
- **6** — automatic ClusterMesh (apiserver node-bound + fan-in) +
  control domain: mirror Services (D30), `gitops-hub` identities +
  secret-sync + read-only credential (D43/D38).
- **7** — PKI ops + rotation runbooks/scripts, RKE2 CIS suite (D25),
  CCM knob + fake-CCM test, GitOps-handoff proof suite (D44),
  `distroDefaults` suite.
- **8** — borg migration + upstream review.
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
reference only). Also: alternative CNIs / native-routing base / L2
announcements / VRRP / Keepalived; single-stack internals; Rancher
Manager; cross-inventory automatic mesh; implicit global Services;
early/default-on MCS-API; bundled provider CCMs; replicated storage;
Windows guests; direct-to-pod routing from edges; NAT64/app egress
remediation; same VIP advertised from two clusters; pod-CIDR
advertisement to hosts by default (admin role excepted, D33); public
shared-BGP without upstream-routed space; heterogeneous multi-WAN
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
  correctly: Cilium CNI, Node IPAM + pools, BGP/BIRD, ClusterMesh, host
  WireGuard, CoreDNS zones, fleet-routing (§3.2).
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
  projects; host-level (BIRD, WireGuard, HAProxy) exempt; rke2 is the
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
- **Integrated node transport** — per-cluster routed L3 host WireGuard
  full mesh carrying dual-stack node InternalIPs, API, VXLAN.
- **Mesh group** — mutually trusted cluster instances forming one
  ClusterMesh; the trust domain string.
- **Pool scope** — per-machine (node-named) vs cluster-global
  (generic-named); who contributes a pool's addresses.
- **Delivery mode** — node-fate-bound | floating | shared-bgp |
  external-class; how traffic reaches pool addresses + failure semantics.
- **Node IPAM** — Cilium's LoadBalancer feature (helm `nodeIPAM.enabled`)
  that advertises node IPs (ExternalIP, else InternalIP) as a Service's
  LB ingress; the classless-Service default (D41). Distinct from
  `ipam.mode: kubernetes` (pod IPAM), which is an allowed override.
- **LB IPAM pool** — CiliumLoadBalancerIPPool; serves only Services with
  `loadBalancerClass: io.cilium/lb-ipam` (D41); the only VIP mechanism.
- **Node-fate-bound delivery** — provider/static routing to one node; no
  failover, no BGP.
- **Floating delivery** — runtime controller moves the address to one
  node at a time; failover is the controller's contract.
- **Shared BGP VIP** — address advertised from all healthy nodes
  (ETP-Local withdrawal); the `shared-bgp` mode of a cluster-global pool.
- **Private fleet fabric** — default per-cluster private shared-bgp pool
  + BIRD/BGP base + CoreDNS/mesh VIPs; lets clan hosts route into every
  cluster.
- **Fleet-routing service** — clanService (client/admin/router roles)
  giving non-Kubernetes hosts routed access to cluster VIPs (client),
  pod/Service CIDRs (admin), or upstream prefix ownership (router).
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

- Cilium 1.20: LB IPAM, Node IPAM (docs.cilium.io/en/latest/network/
  node-ipam/ — ETP-Local EndpointSlice caveat affects only Cilium's own
  Gateway/Ingress, D41), BGP v2, ClusterMesh (global Services +
  `service.cilium.io/global|shared|affinity`, EndpointSlice sync),
  Gateway gaps (cilium#28497, cilium#25567, GEP-91 — why Cilium stays
  networking-only, D1); configuration via the rendered `cilium-config`
  ConfigMap (D26 layer-2 seam); official install = Helm, cosign-signed
  digest-pinnable OCI charts; the chart ships no `crds/` dir — the
  operator manages CRDs at runtime (why manifest rendering loses
  nothing, D40).
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
- BIRD 2 + vendored fragment pattern (D19).
- hcloud-ip-floater (costela): floating-IP mover reference; upstream
  effectively unmaintained (last non-dependabot commit 2023) —
  fork-don't-depend.
- go-httpbin (mccutchen): standard airgapped HTTP VM-test workload.
