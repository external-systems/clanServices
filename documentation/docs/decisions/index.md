# Decision record (D1–D45)

Every normative choice in the project. SPEC.md §4 is the normative record;
this page is the human rendering. Statuses: **active** | **REVISED** (round
noted) | **REVOKED** (round 13 unless noted) — revoked entries keep one-line
reasons for history.

**Round 13 (2026-10-22) — data-plane-only scope reduction.** The contract
narrowed to two verifiable promises: the Bootstrap contract (§3.1) and the
Data-plane contract (§3.2). Everything else that was spec'd as clan-rendered
in-cluster software is revoked and became documented day-2 GitOps patterns.
New: D39–D45. Revoked: D2, D4, D5, D6, D7, D15, D17, D18, D20, D28, D29,
D31, D32. Revised: D1, D3, D8, D22, D26, D27, D35; D36/D37 superseded by
D43.

| ID | Status | Decision |
| --- | --- | --- |
| D1 | REVISED (r13) | Cilium is networking-only — `gatewayAPI.enabled=false`, `ingressController.enabled=false` permanently; now the ONLY in-cluster Cilium surface, so the dummy-Endpoints Node-IPAM caveat never applies (D41) |
| D2 | REVOKED | Envoy Gateway as clan-rendered base ingress/Gateway — day-2 GitOps recipe now |
| D3 | REVISED (r13) | Traefik is never clan-rendered; it exists only as stock distro output under `distroDefaults` (D42) |
| D4 | REVOKED | Ingress API deprecation posture — moot, no ingress/Gateway surface remains in the contract |
| D5 | REVOKED (r5–7) | HAProxy edge-proxy scrapped; unrelated to the retained per-node kubeapi HAProxy (§6.6) |
| D6 | REVOKED | Three-layer Gateway ownership / zero-churn contract |
| D7 | REVOKED | Default NS+EW Gateway pair and `web` listener profile |
| D8 | REVISED (r13) | Pool model: 2 scopes × 4 delivery modes — pools serve Cilium-handled classes only (`io.cilium/lb-ipam` non-BGP, `io.cilium/bgp-control-plane` for shared-bgp, phase 5); classless Services go to Node IPAM (D41) |
| D9 | active | BGP topology + foreign-router contract: Cilium dials out to per-node BIRD over a loopback alias (169.254.179.1, phase 5); BIRD exports only approved VIPs; upstream ECMPs across healthy nodes; hashed private ASNs + hold 9/keepalive 3/retry 5 |
| D10 | active | Private fleet routing fabric default-on; public `shared-bgp` opt-in with hard preconditions; one VIP per cluster |
| D11 | active | Fleet-routing clanService for non-Kubernetes machines (roles per D33) |
| D12 | active | ClusterMesh apiserver exposure stays node-bound; pattern generalized for the D30 mirror Services |
| D13 | active | Pod/ClusterIP advertisement to machines: opt-in, default off; `admin` role excepted |
| D14 | active | Raw L4 (games) = plain LoadBalancer Services, never Gateways — tenant/day-2 objects over the guaranteed LB data plane |
| D15 | REVOKED | One IP:443 all-TLS-modes rule set; the one-proxy-per-IP:port principle survives as the day-2 recipe constraint |
| D16 | active | One cluster per machine — inventory-wide eval assertion |
| D17 | REVOKED | `gateway.classes`/`gateway.instances` 0–N structure |
| D18 | REVOKED | Fleet CA + browser trust — no clan-issued in-cluster TLS remains; ClusterMesh CA (bootstrap plane) unaffected |
| D19 | active | BIRD rendered via vendored named-fragment pattern; one BIRD per machine; `bird -p` validates |
| D20 | REVOKED | Fleet-wide east-west mTLS path — gated, never proven; its fleet-CA prerequisite is revoked |
| D21 | active | Internal cluster domain pinned to `cluster.local`; never served to clients |
| D22 | REVISED (r13) | Private-domain routing contract — the zone wildcard target is now whatever day-2 proxy you install; zone and VIP exist regardless |
| D23 | active | Upstream `kubernetes` (kubeadm) distro = first-class target, Reserved; hard requirement, not optional scope |
| D24 | active | CNCF in-cluster posture — clan-rendered in-cluster components are CNCF projects (Cilium, CoreDNS); host-level exempt; rke2 is the documented distro exception |
| D25 | active | RKE2 hardened by default (`profile: cis`); explicit `security.cis = false` opt-out |
| D26 | REVISED (r13) | Kubenix is the manifest renderer, two layers, zero IFD — scope shrunk to the bootstrap bundle; inflation stays an update-time act in the artifact flake |
| D27 | REVISED (r13) | Rancher helm-controller off by default — folded into `distroDefaults` (D42); returns only when you opt into stock distro behavior |
| D28 | REVOKED | Clan-rendered flux-operator + FluxInstance — clan never installs a GitOps controller (D43) |
| D29 | REVOKED | Replaced by D40: same handoff idea, generalized to any GitOps tool and pinned to the bootstrap-bundle mechanism |
| D30 | active | Hub → spoke API via ClusterMesh mirror Services; mandatory for spokes; mirror DNS name is the kubeconfig `server` (SAN-asserted) |
| D31 | REVOKED | external-dns as optional Flux component — wholly day-2; no clan-rendered objects remain to annotate |
| D32 | REVOKED | OLM rejection record — moot under day-2 scope; the reasoning stands if ever re-proposed |
| D33 | active | Fleet-routing roles: client / admin / router; node duality legal; kamrui-h1 (single-node k3s + admin) is the canonical shape |
| D34 | active | Version policy: last 3 minors per distro, latest patch, support-window eval warning |
| D35 | REVISED (r13) | Secrets planes: clan vars = bootstrap plane only — Sealed-Secrets sealing keys LEAVE the vars plane; Sealed Secrets is wholly day-2, keys included |
| D36 | superseded by D43 | Flux control-domain modes — renamed and de-Fluxed in round 13 |
| D37 | superseded by D43 | Hub credential plane — semantics carried into the GitOps-neutral control domain |
| D38 | active | Read-only cluster credential (AI-agent access): aggregated `view` + cluster-scoped reads, never `secrets`, never write verbs; hub holds each spoke's read-only kubeconfig |
| D39 | active (r13) | Two-contract scope: Bootstrap contract + Data-plane contract; everything else in-cluster is a documented day-2 GitOps pattern |
| D40 | active (r13) | Cilium lifecycle: rendered bootstrap bundle, SSA once on `clusterInit`, then GitOps adoption — first reconcile no-op by construction |
| D41 | active (r13) | Node IPAM default (`nodeIPAM.enabled=true`, `defaultLBServiceIPAM=nodeipam`); pools keep the VIP plane |
| D42 | active (r13) | `distroDefaults` knob; servicelb permanently off in both modes |
| D43 | active (r13) | GitOps-neutral control domain: `controlDomain.role = standalone \| hub \| spoke`; supersedes D36/D37 naming and D28's controller install |
| D44 | active (r13) | Test-surface reduction to the two contracts |
| D45 | active (r13) | Shared lib renamed `lib/kube-cluster/` (spec level; code rename lands with phase 1) |

## Round 13 decisions in detail

### D39 — Two-contract scope

The clanServices promise exactly two verifiable contracts: the Bootstrap
contract (the cluster exists and is reachable) and the Data-plane contract
(packets flow correctly). Everything else in-cluster is a documented day-2
GitOps pattern, never clan-rendered, never host-churned. Rationale: keeping
uniform state through host-resident YAML manifests on multiple manager
machines is bad practice — untracked, unsynchronized, and redundant once a
GitOps repo exists.

### D40 — Cilium lifecycle: bootstrap bundle → GitOps adoption

ONE kubenix-rendered bundle per cluster, applied ONCE at first boot by a
systemd oneshot on the `clusterInit` machine:
`kubectl apply --server-side --field-manager=clan-bootstrap`. Never the
distro manifests dir; idempotent; `bootstrap.apply = false` is the day-2
off-ramp. Handoff: the identical set is published to the GitOps repo; Flux
Kustomization (prune on) or Argo CD adopts it, and the first reconcile is a
no-op by construction. Flux prune touches only its own `.status.inventory`;
the Cilium chart ships no `crds/` dir, so manifest rendering loses nothing.
Rejected: `cilium install` CLI, Rancher helm-controller, HelmRelease
adoption without helm release storage (operators who want HelmRelease
ownership bootstrap with plain `helm install` themselves). Upgrades
post-handoff: pkgs bump → rebuild → republish → GitOps applies. The
publish-freshness gate lives in artifact/CI checks, not eval.

### D41 — Node IPAM default; pools keep the VIP plane

`nodeIPAM.enabled=true` + `defaultLBServiceIPAM=nodeipam`: classless
`type: LoadBalancer` Services receive node IPs — the k3s-ServiceLB
experience on every distro. With `externalTrafficPolicy: Local` the
advertised node set follows real EndpointSlices; the documented
dummy-Endpoints limitation affects only Cilium's own Gateway/Ingress, which
are permanently disabled (D1). Clan-rendered VIP consumers always pin
`loadBalancerClass: io.cilium/lb-ipam` and draw from pools. Multi-pool
remains the default pod IPAM; `ipam.mode: kubernetes` is an allowed explicit
override.

### D42 — `distroDefaults` knob; servicelb permanently off

`distroDefaults.enable = false` (default) gives a uniform minimal base
across rke2/k3s/kubernetes: no helm-controller, no Traefik, no servicelb, no
distro add-ons. `true` (rke2/k3s only) refrains from passing the distro
`--disable` flags, so packaged components deploy stock and are configured
through the distro's own HelmChartConfig surface — your day-2 concern.
servicelb/klipper stays disabled in BOTH modes: Node IPAM (D41) is its
replacement, and two controllers racing on `status.loadBalancer.ingress` is
a contract violation. The `kubernetes` distro has no such knob — which keeps
the minimal base honest.

### D43 — GitOps-neutral control domain

`controlDomain.role = standalone | hub | spoke` per cluster instance
(default `standalone`), bounded by the mesh trust domain (hub+spokes same
mesh group; ≤1 hub per group; spoke ⇒ hub exists; eval-asserted). Clan
renders ONLY the tool-agnostic substrate: mirror Services (D30), in-spoke
ClusterRoleBinding `gitops-hub` → `cluster-admin` (configurable) plus
optional per-tenant impersonation SAs, the per-spoke shared dependent vars
generator `gitops-hub-client-<spoke>` (CN=`gitops-hub-<spoke>`,
O=`gitops-hub`, signed by the SPOKE's cluster CA), and the hub-side
namespace `gitops-spoke-<spoke>` holding Secrets `kubeconfig` +
`kubeconfig-readonly`. Any GitOps tool consumes this: Flux via
`kubeConfig.secretRef`, Argo via cluster secrets — wired by you, documented
in the [Day-2 GitOps guide](../guides/day-2-gitops.md). Rotation = vars
regenerate + secret-sync re-apply; spokes unaffected (same CA). **Clan never
installs a GitOps controller.**

### D44 — Test-surface reduction

VM suites kept: single/join/HA per distro; transport (host-wireguard only);
ClusterMesh + mirror-Service reachability; the data-plane suite (pool
allocation + nodeipam classless Service + ETP-Local candidate restriction +
shared-bgp ECMP + withdrawal + firewall positive/negative); fleet-routing;
PKI rotation; CCM fake suite; the GitOps-handoff proof (second-field-manager
SSA no-op; no Flux in VMs); `distroDefaults` suite; rke2 CIS suite;
control-domain suite. Retired: EG gateway matrix, QUIC/Caddy fixtures, flux
control-domain suite, external-dns, OpenEBS, KubeVirt, Multus,
sealed-secrets suites. go-httpbin remains the one workload fixture.

### D45 — Shared lib renamed `lib/kube-cluster/`

Supersedes the D23 rename gate (was: on kubernetes-distro landing). The lib
serves all three distros' bootstrap+data-plane; "rancher" is the misleading
name. Spec-level now; the code rename lands with phase 1 (SPEC.md §8).
