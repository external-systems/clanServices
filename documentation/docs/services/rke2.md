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
- **Minimal base by default (D42).** The RKE2-bundled Cilium is disabled in
  favor of the canonical upstream profile, and with
  `distroDefaults.enable = false` (the default) the service passes the
  distro's disable flags: no helm-controller, no Traefik, no servicelb, no
  distro add-ons — the same minimal base as k3s and kubernetes. Set
  `distroDefaults.enable = true` to let RKE2's own machinery deploy its
  stock components and configure them through HelmChartConfig — your day-2
  concern. servicelb stays off in both modes; Node IPAM (D41) replaces it.
  Cluster DNS (D46): RKE2's bundled `rke2-coredns` is a HelmChart and is
  disabled in BOTH modes in favor of the uniform clan-rendered CoreDNS from
  the bootstrap bundle — Service pinned to the derived clusterDNS IP,
  `coredns.rewrites` folded into its Corefile. Under
  `distroDefaults.enable = true` the stock `rke2-coredns` deploys and the
  bundle skips its own CoreDNS (mode-exclusive); note the stock chart does
  not import `coredns-custom`, so private-zone rewrites on rke2 want the
  minimal base (or day-2 chart config).
- **PKI sync is non-destructive** (SPEC.md §6.10).

## What is shared

Transport, the Cilium base with Node IPAM, pools/BGP/BIRD, ClusterMesh, the
bootstrap bundle and its GitOps handoff, the control-domain substrate,
secrets planes, assertions — all from the shared library. See
[Architecture](../architecture/overview.md).

The entire day-1 in-cluster surface is delivered as one kubenix-rendered
bootstrap bundle, applied once via server-side apply on the `clusterInit`
machine (D40) — nothing is written to RKE2's watched manifests dir.

## Status

Implemented. Single-node, join, and HA VM suites are green (recorded at the
imported baseline `896acdf` in the source fork). Phase 3 (SPEC.md §8)
replaced all helm-controller/manifests-dir delivery with the kubenix
bootstrap bundle + SSA oneshot (D40) and added the hermetic
`rke2-data-plane` VM suite (pool allocation, Node IPAM classless Service,
ETP-Local candidate restriction, firewall positive/negative). Cluster DNS
is the uniform clan-rendered CoreDNS (D46) in both distros' minimal base.
Phase 4 added hashed-default `cilium.id` resolution (pin your id before
upgrading — see [Upgrades](../guides/upgrades.md)), topology labels
(invariant 7), the `kube_cluster` dual-stack export, and the fleet-wide
`clan.checks` (one cluster per node across rke2+k3s, id collisions,
meshed-CIDR overlap).
