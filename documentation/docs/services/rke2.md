# rke2

The `rke2` clanService deploys RKE2 clusters. It is a thin distro layer:
bootstrap, TLS directory, and join semantics live here; everything shared
comes from the private library.

## What is rke2-specific

- **CIS hardening by default (D25).** `profile: cis` (v1.29+) — PSA
  `restricted` cluster-wide except `kube-system`, protect-kernel-defaults,
  etcd user/group, CIS sysctls, with host prerequisites rendered by the
  NixOS module. Opt out explicitly with `security.cis = false`. Tenants get
  a namespace-exemption runbook.
- **Distro-layer exception to the CNCF posture (D24).** rke2 is
  SUSE/Rancher-owned; k3s and the upstream `kubernetes` distro are the
  fully-CNCF paths.
- **Bundled components off.** The RKE2-bundled Cilium is disabled in favor
  of the canonical upstream profile; the Rancher helm-controller is
  disabled by default (D27); bundled Traefik is always off (D3).
- **PKI sync is non-destructive** (SPEC.md §5.10).

## What is shared

Transport, Cilium base, pools/BGP/BIRD, Envoy Gateway, cert-manager,
ClusterMesh, Flux day two, secrets planes, assertions — all from the shared
library. See [Architecture](../architecture/overview.md).

## Status

Implemented. Single-node, join, and HA VM suites are green (recorded at the
imported baseline `692807c` in the source fork).
