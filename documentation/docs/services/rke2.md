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
  Cluster DNS (D46): on the minimal base (`distroDefaults.enable =
  false`, the default) the uniform clan-rendered CoreDNS from the
  bootstrap bundle serves `cluster.local` — Service pinned to the derived
  clusterDNS IP, `coredns.rewrites` folded into its Corefile, with the
  built-in `coredns-custom` import seam for day-2 custom config (D46
  amended). Under `distroDefaults.enable = true` the stock
  `rke2-coredns` HelmChart deploys and the bundle skips its own CoreDNS
  (mode-exclusive; day-2 custom config then wants chart config). No
  private member-facing CoreDNS is rendered in either mode — member DNS
  is day-2 (D22 amended).
- **PKI sync is non-destructive** (SPEC.md §6.10).

## What is shared

Transport, the Cilium base with Node IPAM, pools/BGP/FRR,
ClusterMesh, the bootstrap bundle and its GitOps handoff, the
control-domain substrate, secrets planes, assertions — all from the shared
library. Transport facts arrive **only** through the generic
`node_transport` export (schemaVersion 2); the service never branches on
fabric service names (D58). See [Architecture](../architecture/overview.md).

The entire day-1 in-cluster surface is delivered as one kubenix-rendered
bootstrap bundle, applied once via server-side apply on the `clusterInit`
machine (D40) — nothing is written to RKE2's watched manifests dir.

## Status

Bootstrap, `leaf`/`spine` transport, generic `node_transport` profiles,
full/selective ClusterMesh, placement/exposure, and read-only
`clan.networkFacts` schemaVersion 2 are implemented. IfState supplies the
live static host network. Current hermetic suites pass single/join/HA,
native data-plane, and every native/tunnel/selective/external ClusterMesh
profile. CIS hardening, the bootstrap bundle, and distro-specific bootstrap
behavior remain unchanged.

