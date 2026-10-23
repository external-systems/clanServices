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

## Migrating to hashed cluster ids (phase 4, SPEC.md §6.2)

`cilium.id` is now nullable and defaults to a stable hash of the instance
name mapped into 1–127. **Before upgrading a deployment that predates the
hashed default**, pin the id (and CIDRs) the cluster actually runs:

```nix
roles.server.settings.cilium.id = 1; # the id this cluster booted with
```

The resolved id drives the pod/service CIDRs, clusterDNS, and the HAProxy
kubeapi/supervisor ports (`7442 + id`, `+1000`), so an unpinned upgrade
re-derives all of them — a disruptive change for a running cluster. An
explicit id above 127 additionally requires explicit
`network.podCIDRv4` + `network.serviceCIDRv4` (the derived
`10.<2id-1>`/`10.<2id>` space overflows the /8). A resolved-id collision
between two cluster instances is an eval error naming both claimants; pin
one of them explicitly.
