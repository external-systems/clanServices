# Decision record (D1–D38)

Every normative choice in the project, locked 2026-10-20 after design
rounds 1–8 and 10–12. Round-8 amendments: A1 (artifact flake carries last 3
k8s minors → D34), A2 (external-dns credentials are not clan-vars-owned →
D31), A3 (clan vars avoid owning in-cluster secrets → D35, exception
carved out in round 10 → D37), A4 (round 8 locked the spec; no code
changes in the same commit). Round 10 locked the Flux control domain:
D36/D37 are new, and D28/D29/D30/D35 are revised (marked below). Round 11
added the read-only cluster credential (D38). Round 12 corrected the
rendering pipeline: D26 and D29 are revised again (two-layer rendering;
Flux Kustomization handoff replaces HelmRelease adoption). Repo history's
"round 9" was the QUIC/two-fixture rule, already in D15 and the testing
contract.

| ID | Decision | Rationale |
| --- | --- | --- |
| D1 | Cilium is networking-only; its Gateway/Ingress controllers stay off | No Gateway HTTP/3, no mTLS, no DaemonSet mode, no multi-Gateway IP sharing upstream |
| D2 | Envoy Gateway is the default and only ingress/Gateway | Only implementation that satisfies the full TLS-mode set (D15); one upstream profile both distros, airgap-locked |
| D3 | Traefik is removed entirely | Distro-bundled charts always disabled; multi-instance stories move to EG Gateways (D17) |
| D4 | Ingress API deprecated entirely | Gateway API core lacks mTLS/HTTP3; EG policy CRDs are the sanctioned extension until GEP-91 lands |
| D5 | HAProxy edge-proxy scrapped | Edge = EG DaemonSet on labeled workers; HTTP response caching dropped with it |
| D6 | Three-layer Gateway ownership (zero-churn contract) | L1 clan always / L2 clan 0–N / L3 GitOps always — tenants never need a NixOS rebuild |
| D7 | Default Gateway pair: public (NS) + private (EW), identical `web` profile | One cert SAN list, HTTP/3 + terminate + hostname-mandatory passthrough on both |
| D8 | LB pool model: 2 scopes × 4 delivery modes | Pool = inventory + selector; scope (per-machine/cluster-global) and delivery (node-fate-bound/floating/shared-bgp/external-class) are orthogonal |
| D9 | BGP topology + foreign-router contract | Cilium dials out to per-node BIRD; BIRD exports only approved VIPs; upstream ECMPs across healthy nodes |
| D10 | Private fleet routing fabric default-on | One private shared-bgp pool + BIRD per cluster; public BGP is opt-in with hard preconditions |
| D11 | Fleet-routing clanService for non-Kubernetes hosts | Clan hosts reach cluster VIPs; `/etc/hosts` is the zero-BGP fallback (roles revised in D33) |
| D12 | ClusterMesh apiserver exposure stays node-bound | Consumers are mesh members with direct routes; control plane takes fewest dependencies |
| D13 | Pod/ClusterIP advertisement to hosts: opt-in, default off | Ephemeral IPs and trust extension are real costs; the `admin` role (D33) is the exception |
| D14 | Raw L4 (games) = plain LoadBalancer Services, never Gateways | No SNI in Minecraft ⇒ one IP:25565 = one backend or one proxy; ETP Local preserves player IPs |
| D15 | One IP:443 serves all TLS modes; QUIC terminate and passthrough never share an address | Raw UDP has no demux key; QUIC-passthrough Gateways get their own VIP; eval-asserted |
| D16 | One cluster per node | A machine belongs to at most one cluster instance — inventory-wide eval assertion |
| D17 | Gateway classes vs instances are 0–N | Class = isolation domain; instance = one rendered Gateway with address projection and listener profile |
| D18 | Dedicated fleet CA + browser trust | Private Gateway certs from cert-manager; client/admin roles install trust (Firefox via enterprise policy) |
| D19 | BIRD rendered via vendored named-fragment pattern | bird.nix reviewed, not adopted; one BIRD per host, instance-prefixed blocks, `bird -p` validates |
| D20 | Fleet-wide east-west mTLS is preferred, gated on VM proof | Accept/reject must be proven before default-on; browser client-cert UX stays terminate-only |
| D21 | Internal cluster domain pinned to `cluster.local` | The ecosystem hardcodes it; high blast radius, zero benefit; aliasing via CoreDNS rewrites (D22) |
| D22 | Private-domain routing contract | Clients resolve only `<instance>.<domain>` (wildcard → private Gateway); svc/pod zones are opt-in |
| D23 | Upstream `kubernetes` (kubeadm) distro = first-class target, Reserved | Third public clanService; same interfaces and pipeline; implementation waits for rke2/k3s to stabilize |
| D24 | CNCF in-cluster posture | Every in-cluster component is a CNCF project; rke2 is the documented distro exception |
| D25 | RKE2 hardened by default (`profile: cis`) | PSA restricted cluster-wide with rendered host prerequisites; explicit opt-out |
| D26 | Kubenix is the manifest renderer; two layers, zero IFD (revised round 12) | Charts are helm-inflated at update time and committed as source in pkgs; per-cluster variation lands by kubenix module merging, never re-run helm values |
| D27 | Rancher helm-controller disabled by default | Manifests flow kubenix → manifests dir → Flux Kustomization handoff |
| D28 | Flux runs per control domain; never installed remotely (revised round 10) | flux-operator + FluxInstance on standalone and hub clusters only; spokes run no Flux — the hub reconciles into them via `kubeConfig.secretRef` |
| D29 | Cilium lifecycle: bootstrap apply → Flux Kustomization handoff (revised round 12) | Identical rendered set from one kubenix eval ⇒ no-op first reconcile by construction; HelmRelease adoption rejected (no release storage); parity is a publish-freshness CI gate |
| D30 | Hub → spoke API via ClusterMesh mirror Services (revised round 10) | Selectorless global Service + EndpointSlice + CoreDNS rewrite; mandatory for spokes; kubeconfigs use the mirror DNS name (SAN-asserted) |
| D31 | external-dns = optional Flux component, creds via Sealed Secrets | Authoritative providers only; never for inter-cluster DNS; annotation knobs on clan objects |
| D32 | OLM v1 rejected | Catalog coverage gaps, OpenShift-only airgap docs, cert-manager collision risk; duplicates Flux+kubenix |
| D33 | Fleet-routing roles: client / admin / router; node duality legal | admin = client + pod/Service zones and routes; kamrui-h1 (single-node k3s + admin) is the canonical shape |
| D34 | Version policy: last 3 minors, latest patch, support-window gate | kubelets may lag the apiserver 3 minors; eval warns when the pinned k8s minor is ahead of support matrices |
| D35 | Secrets planes: clan vars = bootstrap plane only (revised round 10) | If k8s/Flux can rotate or serve it, clan vars does not store it — unless clan is the issuer (D37 hub credentials are the exception) |
| D36 | Flux control domain: three modes, linked to the mesh trust domain | standalone (default) / hub / spoke; hub+spokes share one mesh group, ≤1 hub per group, spoke requires a hub — eval-asserted |
| D37 | Hub credential plane: clan-minted client-cert identities | Per-spoke cert signed by the spoke's cluster CA (CN=`flux-hub-<spoke>`, O=`flux-hub`); SA-token extraction is emergency-runbook-only; offline JWTs and bearer-token refresh CronJobs rejected |
| D38 | Read-only cluster credential for AI-agent access | Every cluster mints a no-secrets read-only identity (aggregated `view` + cluster-scoped reads; never `secrets`, never write verbs); the hub holds each spoke's read-only kubeconfig beside the admin one |

## Decisions in detail (rounds 8, 10, 11, and 12)

### D23 — Upstream `kubernetes` distro

The third public clanService uses kubeadm — the CNCF-sponsored bootstrapper,
wrapped declaratively by the NixOS module. It shares the library interfaces,
invariants, and rendering/GitOps pipeline with rke2 and k3s. It is fully
spec'd but implementation is Reserved until the rke2/k3s core stabilizes.
This is a hard requirement for the project, not optional scope.

### D24 — CNCF in-cluster posture

Every in-cluster component is a CNCF project: Cilium, Envoy Gateway,
cert-manager, Flux, CoreDNS, external-dns, Kubernetes/k3s. Host-level
components (BIRD, WireGuard) are exempt. rke2 is a documented distro-layer
exception (SUSE/Rancher-owned), so a fully-CNCF cluster is expressible as
`kubernetes` or `k3s` plus all defaults.

### D25 — RKE2 CIS defaults

`profile: cis` (v1.29+) is the default: PSA `restricted` cluster-wide
(except `kube-system`), protect-kernel-defaults, etcd user/group, and CIS
sysctls, with host prerequisites rendered by the NixOS module.
`security.cis = false` opts out explicitly. Curated exemptions for system
components come with the upstream profile; tenants get a namespace-exemption
runbook. k3s/kubernetes get equivalent PSA defaults where supported.

### D26 — Kubenix rendering, two layers (revised round 12)

All clan-rendered manifests are kubenix typed resources, produced in two
layers. Layer 1: the artifact flake's atomic updater renders each pinned
chart with the canonical fleet-uniform profile via `helm template` at
**update time** and commits the rendered manifest into the pkgs repo next
to the version pins — consumers read committed source files, so evaluation
has zero import-from-derivation (reading a package output at eval would
itself be IFD). Layer 2: clanServices imports the base manifest and applies
per-cluster variation by Nix module merging over the typed resource tree
(the `cilium-config` ConfigMap and sibling CRs), never by re-running helm
with per-cluster values. Fleet-uniform knobs stay frozen in layer 1;
IFD-smuggling manifest paths are eval-rejected, keeping cold-store
`nix flake check --no-build` green.

### D27 — Rancher helm-controller off

`disable-helm-controller` is the default on both distros; explicit opt-in
re-enables it. The distro bundled charts (Traefik, servicelb, and friends)
remain disabled per D3. Manifests flow kubenix → distro manifests dir →
Flux Kustomization handoff (D29).

### D28 — Flux runs per control domain (revised round 10)

flux-operator and a FluxInstance are clan-rendered from pinned artifacts on
**standalone and hub clusters only**; spokes run no Flux control plane —
the hub's controllers reconcile into them via core-Flux
`kubeConfig.secretRef` (D36/D37). Remote installation was declined upstream
(flux-operator#624): hub→spoke delivery is a Flux feature, not an operator
feature. `flux.enable = false` renders no Flux at all — the clan applies
manifests directly and Cilium stays clan-owned — and combining it with mode
`hub` or `spoke` is an eval error.

### D29 — Cilium bootstrap apply → Flux Kustomization handoff (revised round 12)

Bootstrap and Flux apply the same rendered manifest set from one kubenix
evaluation: bootstrap applies it via the distro manifests dir at first boot
(the CNI must exist before Flux pods run), then a Flux Kustomization
(prune on, drift correction) takes over the identical set published to the
GitOps repo/OCI artifact — locally on standalone/hub, hub-remote on spokes.
The first reconcile is a no-op by construction; thereafter Flux owns
upgrades (pkgs bump → rebuild → republish → Flux applies). HelmRelease
adoption was rejected: with the helm-controller off there is no helm
release storage to adopt, and a HelmRelease install over helm-unowned
resources fails on ownership metadata. "Parity" is now a publish-freshness
CI gate (published manifest ≡ fresh render), not an eval assertion. With
`flux.enable = false` the bootstrap apply is permanent.

### D30 — Mirror Services for API reachability (revised round 10)

A clan-rendered selectorless Service `kube-api-<cluster>` plus an
EndpointSlice of the cluster's API endpoints is annotated ClusterMesh-global;
consumers render the same-named Service with no local backends and
ClusterMesh merges the remote endpoints. Exporting the API is **mandatory
for spokes** and optional otherwise. Consumer CoreDNS rewrites
`kubernetes.<cluster>.<meta.domain>` to the mirror Service (the tooling
path); kubeconfigs use the mirror DNS name directly as `server`, and the
API certificate SANs must include it — eval-asserted. Mesh connectivity is
symmetric: spokes reach the hub, and standalone mesh members reach both,
through the same mechanism.

### D31 — external-dns as an optional Flux component

external-dns is not clan base; it deploys per cluster through GitOps.
Provider credentials are Sealed-Secrets-owned, never clan vars. Clan
objects get annotation knobs (`dns.hostnames` emits the hostname
annotation, overridable per object). Scope is authoritative providers only
— inter-cluster DNS is covered by ClusterMesh and the D22 zones.

### D32 — OLM v1 rejected

OLM v1 is neither base nor an optional install method. Evidence
(2026-10): the community catalog lacks current Cilium, Envoy Gateway, and
external-dns; cert-manager and OpenEBS entries are stale; airgap workflows
are documented only for OpenShift/OKD; and upstream install depends on
cert-manager, colliding with the base install. Revisit criteria are
recorded: catalog currency, non-OpenShift airgap docs, or a needed operator
that is catalog-only.

### D33 — Fleet-routing roles and node duality

`client` is the D11 behavior (mesh join, BIRD peering, VIP routes,
gateway-zone DNS stub, fleet CA trust). `admin` adds pod/Service
advertisement consumption and svc/pod DNS zones default-on — the developer
profile. `router` owns upstream prefixes with filtered VIP acceptance and
NDP. A machine may be a cluster node and hold fleet-routing roles
simultaneously; on a cluster member the BIRD fragments merge into the
existing host BIRD. The canonical test shape is kamrui-h1: single-node k3s
plus the admin role.

### D34 — Version policy

The artifact flake packages the last three Kubernetes minors per distro at
their latest patch each (today: 1.35.x, 1.36.x, 1.37.x). Servers/managers
upgrade first; agents/workers lag per the upstream version-skew policy
(kubelets may trail the apiserver by up to three minors). Pins are release
tags only — no locked-HEAD constructors. Evaluation emits a warning (not a
failure) when a pinned k8s minor is ahead of the Cilium/Envoy Gateway
support matrices — today 1.37.1 is ahead of EG 1.9's 1.33–1.36 matrix, an
accepted bleeding-edge risk.

### D35 — Secrets planes (revised round 10)

Clan vars own the bootstrap plane only: cluster CAs, join tokens, admin
kubeconfigs, fleet CA, ClusterMesh CA/certs, Sealed-Secrets sealing keys
(including keypair history custody) — and, the round-10 exception, the
hub↔spoke Flux control-plane credentials (D37). All in-cluster application
credentials — external-dns provider keys, tenant secrets — are GitOps-owned
via Sealed Secrets. Rule of thumb: if Kubernetes or Flux can rotate or
serve it, clan vars does not store it — unless clan is the issuer, in which
case vars is the only declarative source. A lint rejects clan vars
generators declared for application-plane secrets.

### D36 — Flux control domain: three modes

`flux.mode = standalone | hub | spoke` (default `standalone`) per cluster
instance. Standalone runs its own Flux and shares nothing; a hub runs Flux
plus the control-domain plane for its group's spokes; a spoke runs no Flux
and accepts reconciliation from its group's hub. The trust domain is the
ClusterMesh mesh group string (default `meta.domain`): hub and spokes must
share one group, at most one hub per group, and a spoke requires exactly
one hub — all eval-asserted. Mesh and flux are linked but distinct:
standalone clusters may be full mesh members, and multiple mesh groups are
multiple independent trust domains, each optionally with its own hub.

### D37 — Hub credential plane: client-cert identities

Per spoke, a shared vars generator dependent on the spoke's cluster CA
signs a client certificate (CN=`flux-hub-<spoke>`, O=`flux-hub`, 365-day).
The spoke renders a ClusterRoleBinding `flux-hub` → `cluster-admin`
(default; configurable) plus optional per-tenant impersonation
ServiceAccounts — the flux2-hub-spoke-example pattern, with its
tenants → infra-controllers → infra-configs → apps `dependsOn` ordering as
the documented hub tree shape. The hub holds a per-spoke namespace
`flux-spoke-<spoke>` with a `kubeconfig` Secret delivered via secret-sync;
spoke machines never receive the client key. Rotation is a vars regenerate
plus secret-sync re-apply with spokes unaffected. Manual SA-token
extraction is the documented emergency runbook only; offline-minted SA JWTs
and expiring bearer-token kubeconfigs with refresh CronJobs are rejected.

### D38 — Read-only cluster credential (AI-agent access)

Every cluster auto-renders a read-only, no-secrets identity alongside the
admin kubeconfig: ClusterRole `cluster-readonly` = the built-in aggregated
`view` role plus explicit cluster-scoped reads (nodes, namespaces, PVs,
storage/ingress/gateway classes, CRDs, clusterroles/-bindings,
priorityclasses) — never `secrets` in any apiGroup, never a write verb —
bound to group `cluster-readers`; a vars generator signs a client cert with
the cluster CA (CN=`readonly-<instance>`, O=`cluster-readers`). The
read-only kubeconfig deploys alongside the admin one on server machines;
the primary consumer is AI agents outside the cluster, handed the
kubeconfig via `clan vars get`. The hub receives each spoke's read-only
kubeconfig as Secret `kubeconfig-readonly` in `flux-spoke-<spoke>` beside
the D37 admin `kubeconfig`, so hub-resident tooling gets fleet-wide read
access without admin keys. Caveat recorded: read-only ≠ harmless —
ConfigMaps, pod specs/env, and logs stay visible; the `secrets` exclusion
is the hard line, VM-proven positive and negative.
