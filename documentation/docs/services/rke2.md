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
  not import `coredns-custom`, so the day-2 private-zone rewrites (D22
  amended) on rke2 want the minimal base (or day-2 chart config).
- **PKI sync is non-destructive** (SPEC.md §6.10).

## What is shared

Transport, the native-routed Cilium base with Node IPAM, pools/BGP/FRR,
ClusterMesh, the bootstrap bundle and its GitOps handoff, the
control-domain substrate, secrets planes, assertions — all from the shared
library. See
[Architecture](../architecture/overview.md).

The entire day-1 in-cluster surface is delivered as one kubenix-rendered
bootstrap bundle, applied once via server-side apply on the `clusterInit`
machine (D40) — nothing is written to RKE2's watched manifests dir.

## Status

Bootstrap phases 1–4 are implemented. The imported baseline recorded green
single/join/HA suites; the later legacy BIRD checkpoint retained green
rke2 join/HA but red rke2 single/data-plane suites, so it is not a green
current-tree claim. Phase 5's BIRD/VXLAN implementation at `2995ac3` is
legacy and superseded.

Round 15/16 phases 5R1–5R4 deliver, as one complete overhaul session, the
netif underlay and routed-fabric data plane (per-adjacency WireGuard,
FRR/BFD/Zebra, routed-hub MVP), native-routed multi-pool Cilium,
node-bgp/shared-bgp pools, full-by-default ClusterMesh with selective
peers, read-only `clan.networkFacts` for consumer-owned diagrams, and the
`external-systems/pkgs` native Cilium base re-inflation with the
clanServices pin update — all planned, with no implementation or VM
evidence yet. CIS hardening, the bootstrap
bundle, and distro-specific bootstrap behavior remain unchanged.

