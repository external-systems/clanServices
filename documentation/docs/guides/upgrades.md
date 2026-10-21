# Upgrades

## Version policy: last three minors (D34)

The artifact flake packages the **last three Kubernetes minors per distro**,
latest patch each — today 1.35.x, 1.36.x, 1.37.x. Pins are release tags
only; there are no locked-HEAD constructors. Kubernetes minor parity across
distros is enforced per minor by the `k8s-version-parity` check.

## Upgrade cadence

Follow the upstream version-skew policy: upgrade servers/managers first,
then agents/workers. Kubelets may lag the apiserver by up to three minors —
that asymmetry is exactly why three minors are carried. Because three minors
are always available pinned, you can step a fleet through a skewed upgrade
without waiting on packaging.

## Support-window warning

Evaluation emits a **warning** (not a failure) when a pinned Kubernetes
minor is ahead of the support matrices of the pinned Cilium or Envoy
Gateway. Today 1.37.1 is ahead of Envoy Gateway 1.9's 1.33–1.36 matrix —
an accepted, recorded bleeding-edge risk. Treat the warning as a prompt to
verify your component versions line up before upgrading the fleet.

## What upgrades are safe

- **Component upgrades via Flux.** After the bootstrap apply, a Flux
  Kustomization owns Cilium (D29): upgrades flow pkgs bump → rebuild →
  republish → Flux applies. The first reconcile after handoff is a no-op by
  construction, and a publish-freshness CI gate keeps the published
  manifests equal to a fresh render.
- **Tenant changes.** Routes, tenant Gateways, certificates — GitOps, no
  NixOS rebuild (D6).
- **Base upgrades preserve tenant CRDs** (SPEC.md §5.11).

Disruptive changes — pools, CIDRs, cluster ids, CA roots, mesh membership —
are reviewed operational changes with runbooks, not incidental edits
(SPEC.md §5.10).
