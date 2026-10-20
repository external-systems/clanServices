# GitOps

Day two is Flux, on by default everywhere. The fleet model is per-cluster
autopilot: there is no remote Flux installation (upstream declined it —
flux-operator#624), so every cluster bootstraps itself, and a hub cluster
only *delivers* workloads to spokes.

## Per-cluster bootstrap (D28)

Every cluster renders flux-operator and a FluxInstance from pinned artifacts
at first boot. After that, Flux manages itself. `flux.enable` defaults to
`true`.

Set `flux.enable = false` and no Flux is rendered anywhere: the clan applies
all manifests directly through the distro manifests dir, and Cilium stays
clan-owned permanently. This path has its own VM suite — it is a supported
shape, not an afterthought.

## Hub delivers, never installs

The hub cluster is distinguished only by holding spoke kubeconfigs and
targeting spokes with `Kustomization`/`HelmRelease`
`spec.kubeConfig.secretRef` (ResourceSet matrix templating is optional).
Spoke API reachability comes from ClusterMesh mirror Services and CoreDNS
rewrites — see [Multi-cluster](multi-cluster.md). A singleton cluster has
no hub config; its Flux manages only itself.

Spoke kubeconfigs are Sealed Secrets in the Flux namespace (D35) — clan
vars never stores them.

## Cilium adoption with values parity (D29)

Bootstrap installs Cilium from the pinned chart and values — just enough
for Flux pods to run. A Flux HelmRelease then adopts the release (matching
releaseName and namespace, no `createNamespace`) and owns upgrades from
then on. An eval-time assertion guarantees bootstrap-rendered values are
identical to the HelmRelease values, so adoption is a no-op upgrade — never
a dataplane flap.

The adoption set (Flux-owned post-bootstrap): Cilium, external-dns, and the
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
(D35). Key management is either `clan-vars` (default when enabled: a
persistent keypair with the public cert available offline, native renewal
disabled, old keys retained) or `controller` (native Sealed Secrets
lifecycle plus a backup runbook). Sealing keys are never a plain
cert-manager Certificate. See [Secrets](../guides/secrets.md).

## Rendering pipeline

All clan-rendered manifests are kubenix typed resources (D26). There is no
import-from-derivation during clanServices evaluation — Helm chart inflation
happens at build time inside the artifact flake, and clanServices composes
typed resources plus imports pre-rendered YAML. This preserves fast
`nix flake check --no-build` evaluation and airgap operation. The Rancher
helm-controller is disabled by default on both distros (D27); manifests flow
kubenix → distro manifests dir → optional Flux adoption.

Every clan-rendered manifest carries labels (managed-by, instance,
component, config-hash — never in selectors), so you can always tell what
the clan owns from what GitOps owns.
