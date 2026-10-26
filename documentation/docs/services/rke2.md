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
library. **Round-17 target (5R5):** transport facts arrive **only** through
the generic
`node_transport` export (schemaVersion 2); the service never branches on
fabric service names (D58). Today's code still consumes the
provider-specific `routed_fabric` export. See
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

The 5R overhaul landed in stages: **5R1 and 5R2(1)–(3) are implemented
(2026-10-25)** — the netif underlay and the routed-fabric data plane
(per-adjacency WireGuard, FRR/BFD/Zebra), multi-pool Cilium and pools,
and the `external-systems/pkgs` native Cilium base re-inflation with the
clanServices pin update — in the round-16 shape (`member`/`hub` topology,
service-specific transport facts), with suites registered but not
green-claimed. **Still planned (round 17, docs-locked):** the generic
`node_transport` transport + capability profiles (native routed-fabric /
tunnel wireguard-mesh) consumed without service-name branching, the
`leaf`/`spine` rename, full-by-default ClusterMesh with selective peers
and the placement/exposure contract (D60), and read-only
`clan.networkFacts` (schemaVersion 2) for consumer-owned diagrams — no
implementation or VM evidence yet. CIS hardening, the bootstrap
bundle, and distro-specific bootstrap behavior remain unchanged.

