# Upgrades

## Version policy: last three minors (D34)

The artifact flake packages the **last three Kubernetes minors per distro**,
latest patch each. Pins are release tags only; there are no locked-HEAD
constructors. Kubernetes minor parity across distros is enforced per minor.

## Upgrade cadence

Follow the upstream version-skew policy: upgrade servers first, then agents.
Kubelets may lag the apiserver by up to three minors — that asymmetry is
exactly why three minors are carried. Because three minors are always
available pinned, you can step a fleet through a skewed upgrade without
waiting on packaging.

## Support-window warning

Evaluation emits a **warning** (not a failure) when a pinned Kubernetes
minor is ahead of the support matrix of the pinned Cilium. Treat the warning
as a prompt to verify your component versions line up before upgrading the
fleet. Day-2 components (Envoy Gateway and friends) carry their own
matrices in your GitOps repos.

## What upgrades are safe

- **Distro runtime upgrades.** Bump the pin in the artifact flake, rebuild,
  and roll the fleet servers-first per the skew policy.
- **Cilium upgrades after handoff.** pkgs bump → rebuild → republish →
  GitOps applies (D40). The bootstrap apply itself is a one-time event; post
  adoption your GitOps owns the bundle's lifecycle, and a publish-freshness
  CI gate keeps the published manifests equal to a fresh render.
- **Day-2 component upgrades.** Entirely your GitOps repos' concern — pin,
  review, roll out.
- **Stock distro components under `distroDefaults`.** Upgrade through the
  distro's own machinery (D42).
- **Base upgrades preserve operator CRDs** (SPEC.md §6.11).

Disruptive changes — pools, CIDRs, cluster ids, CA roots, mesh membership —
are reviewed operational changes with runbooks, not incidental edits
(SPEC.md §6.10).
