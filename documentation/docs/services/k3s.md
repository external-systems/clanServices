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
  `/etc/coredns/custom/*.override`). The clan CoreDNS carries the same
  `coredns-custom` import convention (D46 amended): day-2 custom config
  drops in via a GitOps-managed `coredns-custom` ConfigMap. No private
  member-facing CoreDNS is rendered in either mode — member DNS is day-2
  (D22 amended).

## What is shared

Transport, the Cilium base with Node IPAM, pools/BGP/FRR,
ClusterMesh, the bootstrap bundle and its GitOps handoff, the
control-domain substrate, secrets planes, assertions — all from the shared
library. Transport facts arrive **only** through the generic
`node_transport` export (schemaVersion 2); the service never branches on
fabric service names (D58). See [Architecture](../architecture/overview.md).

The entire day-1 in-cluster surface is delivered as one kubenix-rendered
bootstrap bundle, applied once via server-side apply on the `clusterInit`
machine (D40) — nothing is written to the k3s manifests dir.

## Status

Bootstrap, `leaf`/`spine` transport, generic `node_transport` profiles,
full/selective ClusterMesh, placement/exposure, and read-only
`clan.networkFacts` schemaVersion 2 are implemented. IfState supplies the
live static host network. Current hermetic suites pass single/join/HA,
native data-plane, and every native/tunnel/selective/external ClusterMesh
profile. The canonical dual-shape remains kamrui-h1: a single-node k3s
cluster holding the routed-fabric `spine` topology role with
`access = "admin"` (D33, revised by D52, D56, and renamed D59).
