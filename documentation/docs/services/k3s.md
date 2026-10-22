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
  helm-controller, no Traefik, no servicelb. Set `distroDefaults.enable =
  true` to let k3s deploy its stock components through its own
  helm-controller and HelmChartConfig surface — your day-2 concern.
  servicelb/klipper stays off in both modes: Node IPAM (D41) gives every
  classless LoadBalancer Service node IPs — the ServiceLB experience without
  the second controller.

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
imported baseline `896acdf` in the source fork). The canonical fleet-routing
test shape — kamrui-h1 — is a single-node k3s cluster holding the admin
role (D33).
