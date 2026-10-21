# GitOps

Day two is Flux, on by default — but not on every cluster. Flux runs per
**control domain** (D36): standalone clusters run their own Flux, a hub
cluster runs the only Flux control plane for its domain and pushes to its
spokes, and spokes run no Flux at all. Flux is never installed remotely
(upstream declined it — flux-operator#624); hub→spoke delivery is a core
Flux feature, not an operator feature.

## The three flux modes (D36)

`flux.mode` is set per cluster instance:

- **`standalone`** (default) — runs its own flux-operator and FluxInstance,
  shares no kubeconfig with any cluster. A singleton standalone cluster is
  the simplest shape: Flux manages only itself.
- **`hub`** — runs Flux like standalone, plus the control-domain plane
  (D37): per-spoke kubeconfig Secrets and the Kustomizations/HelmReleases
  that reconcile into spokes.
- **`spoke`** — runs **no Flux control plane**. The hub's controllers
  reconcile into it via `Kustomization/HelmRelease.spec.kubeConfig.secretRef`.
  A spoke still runs all non-Flux base — including the sealed-secrets
  controller, whose SealedSecrets the hub applies remotely.

`flux.enable` defaults to `true`. `false` renders no Flux anywhere: the
clan applies all manifests directly through the distro manifests dir and
Cilium stays clan-owned. Declaring mode `hub` or `spoke` with
`flux.enable = false` is an eval error.

## Trust domains: mesh ≠ flux

The trust domain is the ClusterMesh mesh group string (default
`meta.domain`). A hub and all its spokes must share one mesh group; at most
one hub per group; a spoke requires exactly one hub in its group — all
eval-asserted. Multiple mesh groups are multiple independent trust domains,
each optionally with its own hub.

Mesh membership and flux control are linked but **distinct**: standalone
clusters may be full mesh members, and mesh members may consume each
other's mirror Services without any flux relationship.

## Mirror Services are mandatory for spokes

A spoke exports its API through a ClusterMesh-global mirror Service (D30),
and the hub's kubeconfig points at the mirror DNS name directly — the
spoke's API certificate SANs must include it (eval-asserted). Details in
[Multi-cluster](multi-cluster.md).

## The hub credential plane (D37/D38)

The hub's spoke access is fully declarative — zero manual steps:

1. A shared vars generator `flux-hub-client-<spoke>` (dependent on the
   spoke's cluster CA generator) signs a client certificate with the
   **spoke's cluster CA**: CN=`flux-hub-<spoke>`, O=`flux-hub`, 365-day
   validity.
2. The spoke renders RBAC: a ClusterRoleBinding `flux-hub` binding group
   `flux-hub` to `cluster-admin` (default posture; configurable
   ClusterRole), plus optional per-tenant impersonation ServiceAccounts
   with namespace-scoped RoleBindings — the flux2-hub-spoke-example
   multi-tenant pattern. Hub tenants apply with
   `.spec.serviceAccountName`.
3. The hub renders a per-spoke namespace `flux-spoke-<spoke>` holding a
   `kubeconfig` Secret (mirror DNS server + spoke CA public value + client
   cert/key), delivered via secret-sync from vars. Spoke machines never
   receive the client key.
4. Beside it, the hub holds each spoke's **read-only** kubeconfig as
   Secret `kubeconfig-readonly` in the same namespace (D38): every cluster
   mints a no-secrets read-only identity (CN=`readonly-<instance>`,
   O=`cluster-readers`) alongside its admin kubeconfig, and the hub copy —
   server = mirror DNS name — gives hub-resident tooling and AI agents
   fleet-wide read access without admin keys.

Rotation is `clan vars generate --regenerate` plus a secret-sync re-apply;
spokes are unaffected (same CA). Manual SA-token extraction survives only
as the documented emergency runbook. Offline-minted SA JWTs and
expiring bearer-token kubeconfigs with refresh CronJobs are rejected —
machinery for a problem client certs do not have (D37).

These control-plane credentials are the documented exception to the
secrets-planes rule: clan vars owns them because clan is the issuer
(D35/D37/D38). See [Secrets](../guides/secrets.md).

## The hub tree convention

The documented hub repository shape follows flux2-hub-spoke-example's
`dependsOn` ordering: **tenants → infra-controllers → infra-configs →
apps**, with per-spoke overlays under `clusters/<spoke>/`. Every
spoke-bound object carries `kubeConfig.secretRef`.

## Cilium handoff: bootstrap apply → Flux Kustomization (D29)

Bootstrap and Flux apply **the same rendered manifest set from one kubenix
evaluation**. Bootstrap applies it via the distro manifests dir at first
boot — the CNI must exist before Flux pods can run. The handoff is a Flux
**Kustomization** (prune on, drift correction) over that identical set,
published to the GitOps repo / OCI artifact by the cluster's publish step —
locally for standalone and hub clusters, hub-remote via
`kubeConfig.secretRef` for spokes. The first reconcile is a no-op **by
construction**: identical bytes, one Nix source, so there is no dataplane
flap and no values-parity problem at all. Thereafter Flux owns upgrades —
pkgs bump → rebuild → republish → Flux applies — and prunes.

HelmRelease adoption was rejected: with the helm-controller off (D27) there
is no helm release storage to adopt, and a HelmRelease install over
helm-unowned resources fails on ownership metadata. What used to be a
values-parity eval assertion is now a **publish-freshness gate** — the
published manifest must equal a fresh render — enforced as an artifact/CI
check. Helm chart upgrade hooks are replaced by explicit rendered ordering
(CRDs-first artifacts, includeCRDs discipline). With `flux.enable = false`
the bootstrap apply is permanent.

The handoff set (Flux-owned post-bootstrap, locally or hub-remote, as
Kustomizations over the rendered sets): Cilium, external-dns, and the
optional add-ons. Never Flux-owned: the Envoy Gateway controller (D6), the
distro runtime, and cluster PKI.

## external-dns (D31)

external-dns is an optional Flux component, deployed per cluster through the
GitOps layer — it is not part of the clan base. Its provider credentials
(GoDaddy, Cloudflare, RFC2136 keys) are **never** clan vars generators; they
live as Sealed Secrets in the GitOps repo. Clan provides annotation knobs:
`dns.hostnames` on `gateway.instances` and LB Service renderings emits
`external-dns.alpha.kubernetes.io/hostname`, overridable per object.

Scope is authoritative DNS providers only. external-dns is not used for
inter-cluster DNS (its CoreDNS provider needs an etcd backend the clusters
do not run); ClusterMesh plus the private-domain zones (D22) cover private
naming. The multi-cluster value is the same public hostname with
per-cluster targets.

## Sealed Secrets

Off by default, but **required** before any GitOps-owned secret exists
(D35) — on spokes too, where the hub applies SealedSecrets remotely. Key
management is either `clan-vars` (default when enabled: a persistent
keypair with the public cert available offline, native renewal disabled,
old keys retained) or `controller` (native Sealed Secrets lifecycle plus a
backup runbook). Sealing keys are never a plain cert-manager Certificate.
See [Secrets](../guides/secrets.md).

## Rendering pipeline (D26)

Rendering is two layers. **Layer 1 — base inflation (artifact flake, update
time):** the atomic updater renders each pinned chart with the canonical
fleet-uniform profile via `helm template` and **commits** the rendered
manifest into the pkgs repo next to the version pins, regenerated and
reviewed like `versions.nix`. Consumers read committed source files — zero
import-from-derivation (IFD) anywhere in clanServices evaluation.
**Layer 2 — per-cluster composition (clanServices, pure eval):** kubenix
imports the base manifest and applies cluster variation by Nix module
merging over the typed resource tree — cluster name/id, pod CIDRs, mesh
peers land in the `cilium-config` ConfigMap and sibling CRs, never in
re-run helm values. Fleet-uniform knobs stay frozen in layer 1 by design;
post-merge validation rejects overrides that violate invariants.

This keeps cold-store `nix flake check --no-build` green and makes
inflation diffs ordinary reviewable git diffs. The Rancher helm-controller
is disabled by default on both distros (D27); manifests flow kubenix →
distro manifests dir → Flux Kustomization handoff (D29).

Every clan-rendered manifest carries labels (managed-by, instance,
component, config-hash — never in selectors), so you can always tell what
the clan owns from what GitOps owns.
