# GitOps

Clan renders the day-1 in-cluster surface exactly once and then stops.
**Clan never installs a GitOps controller** — which tool you run (Flux,
Argo CD, anything else) and how it is installed is your repo's decision.
This page covers the delivery mechanism and the handoff; the recipes are in
the [Day-2 GitOps guide](../guides/day-2-gitops.md).

## The bootstrap bundle (D40)

The whole day-1 in-cluster surface is ONE kubenix-rendered manifest set per
cluster — Cilium, pools, ClusterMesh config, CoreDNS zones, mirror Services,
RBAC. A systemd oneshot on the `clusterInit` machine applies it once at
first boot: wait for apiserver health, then
`kubectl apply --server-side --field-manager=clan-bootstrap`.

Properties of the mechanism:

- **Never the distro manifests dir.** Nothing host-resident tracks or
  redeploys in-cluster state; `clan machines update` never churns the
  cluster.
- **Idempotent.** Server-side apply is a no-op when cluster state matches
  the bundle.
- **Off-ramp.** `bootstrap.apply = false` removes the unit once your GitOps
  owns the set.

## Day-2 adoption: the handoff

The identical rendered set is published to your GitOps repo. Your GitOps
adopts it — Flux as a Kustomization with prune on, Argo CD via resource
tracking — and the **first reconcile is a no-op by construction**: identical
bytes, one Nix source, so there is no dataplane flap and no values-parity
problem. Thereafter your GitOps owns upgrades: pkgs bump → rebuild →
republish → GitOps applies — and prunes.

Adoption is safe by upstream design: Flux prune garbage-collects only the
Kustomization's own `.status.inventory`, so pre-applied objects are adopted,
not deleted; SSA bootstrap (`--server-side`) avoids client-side-apply
field-ownership friction; and the Cilium chart ships no `crds/` directory —
the operator manages CRDs at runtime — so manifest rendering loses nothing
and no Helm hooks are needed.

Rejected alternatives (D40):

- `cilium install` CLI — hidden environment-autodetected values make
  HelmRelease parity fragile, with documented crash-loop migrations and
  cert-generation mode skew.
- Rancher helm-controller — off per D42.
- HelmRelease adoption of the bundle — impossible without helm release
  storage. If you want HelmRelease ownership, bootstrap Cilium yourself with
  plain `helm install` from the pinned chart (the Flux-maintainer-recommended
  pattern); that variant is documented in the day-2 guide.

## Publish freshness

What used to be a values-parity eval assertion is now a **publish-freshness
gate** — the published manifest set must equal a fresh render — enforced as
an artifact/CI check, not at eval.

## The control domain substrate (D43)

For hub/spoke fleets, clan renders the tool-agnostic substrate any GitOps
tool consumes: mirror Services (D30), `gitops-hub` client-cert identities
and in-spoke RBAC, and hub-side `gitops-spoke-<spoke>` namespaces holding
`kubeconfig` + `kubeconfig-readonly` Secrets. Wiring a specific tool to that
substrate is day-2. See [Multi-cluster](multi-cluster.md).

## Rendering pipeline (D26)

Rendering is two layers. **Layer 1 — base inflation (artifact flake, update
time):** the atomic updater renders the pinned Cilium chart with the
canonical fleet-uniform profile via `helm template` semantics and **commits**
the rendered manifest into the pkgs repo next to the version pins,
regenerated and reviewed like `versions.nix`. Consumers read committed
source files — zero import-from-derivation (IFD) anywhere in clanServices
evaluation. **Layer 2 — per-cluster composition (clanServices, pure eval):**
kubenix imports the base manifest and applies cluster variation by Nix
module merging over the typed resource tree — cluster name/id, pod CIDRs,
nodeipam, mesh peers land in the `cilium-config` ConfigMap and sibling CRs,
never in re-run helm values. Fleet-uniform knobs stay frozen in layer 1 by
design; post-merge validation rejects overrides that violate invariants.

This keeps cold-store `nix flake check --no-build` green and makes inflation
diffs ordinary reviewable git diffs.

Every clan-rendered manifest carries labels (managed-by, instance,
component, config-hash — never in selectors), so you can always tell what
clan owns from what GitOps owns.
