# k3s

The `k3s` clanService deploys k3s clusters. Like `rke2`, it is a thin distro
layer over the shared library; only bootstrap, TLS directory, and join
semantics are distro-specific here.

## What is k3s-specific

- **CNCF distro path (D24).** k3s is a CNCF project, so a k3s cluster with
  all defaults is a fully-CNCF cluster.
- **PSA defaults where supported (D25).** k3s gets equivalent Pod Security
  Admission defaults; there is no CIS profile off RKE2.
- **Init-only PKI seeding** plus native replication (SPEC.md §6.10).
- **Minimal base by default (D42).** With `distroDefaults.enable = false`
  (the default) the service disables the distro's packaged components: no
  helm-controller, no Traefik, no servicelb, no distro CoreDNS. Set
  `distroDefaults.enable = true` to let k3s deploy its stock components
  through its own helm-controller and HelmChartConfig surface — your day-2
  concern. servicelb/klipper stays off in both modes: Node IPAM (D41) gives
  every classless LoadBalancer Service node IPs — the ServiceLB experience
  without the second controller. Cluster DNS in the minimal base is the
  uniform clan-rendered CoreDNS from the bootstrap bundle (D46): same
  Corefile, same image, same behavior on every distro, with
  `coredns.rewrites` folded in; under `distroDefaults` the stock distro
  CoreDNS serves cluster.local instead (mode-exclusive) and rewrites keep
  the distro's `coredns-custom` import path (k3s's stock Corefile imports
  `/etc/coredns/custom/*.override`).

## What is shared

Transport, the native-routed Cilium base with Node IPAM, pools/BGP/FRR,
ClusterMesh, the bootstrap bundle and its GitOps handoff, the
control-domain substrate, secrets planes, assertions — all from the shared
library. See
[Architecture](../architecture/overview.md).

The entire day-1 in-cluster surface is delivered as one kubenix-rendered
bootstrap bundle, applied once via server-side apply on the `clusterInit`
machine (D40) — nothing is written to the k3s manifests dir.

## Status

Bootstrap phases 1–4 are implemented. The imported baseline recorded green
single/join/HA suites; the later legacy BIRD checkpoint retained green
k3s join/HA but red k3s single/data-plane suites, so it is not a green
current-tree claim. Phase 5's BIRD/VXLAN implementation at `2995ac3` is
legacy and superseded.

Round 15 phases 5R1–5R3 deliver, as one complete overhaul session, the
netif underlay and the routed-fabric data plane (per-adjacency WireGuard,
FRR/BFD/Zebra, routed-hub MVP), native-routed multi-pool Cilium,
node-bgp/shared-bgp pools, full-by-default ClusterMesh with selective
peers, and the `external-systems/pkgs` native Cilium base re-inflation
with the clanServices pin update — all planned, with no implementation or
VM evidence yet. The canonical dual-shape remains kamrui-h1: a
single-node k3s cluster holding the routed-fabric `admin` role (D33,
revised by D52).
