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

Transport, the Cilium base with Node IPAM, pools/BGP/BIRD, ClusterMesh, the
bootstrap bundle and its GitOps handoff, the control-domain substrate,
secrets planes, assertions — all from the shared library. See
[Architecture](../architecture/overview.md).

The entire day-1 in-cluster surface is delivered as one kubenix-rendered
bootstrap bundle, applied once via server-side apply on the `clusterInit`
machine (D40) — nothing is written to the k3s manifests dir.

## Status

Implemented. Single-node, join, and HA VM suites are green (recorded at the
imported baseline `896acdf` in the source fork). Phase 3 (SPEC.md §8)
replaced all helm-controller/manifests-dir delivery with the kubenix
bootstrap bundle + SSA oneshot (D40) and added the hermetic
`k3s-data-plane` VM suite (pool allocation, Node IPAM classless Service,
ETP-Local candidate restriction, firewall positive/negative). The canonical
fleet-routing test shape — kamrui-h1 — is a single-node k3s cluster holding
the admin role (D33). Phase 4 added hashed-default `cilium.id` resolution
(pin your id before upgrading — see [Upgrades](../guides/upgrades.md)),
topology labels (invariant 7), the `kube_cluster` dual-stack export, and
the fleet-wide `clan.checks` (one cluster per node across rke2+k3s, id
collisions, meshed-CIDR overlap).
