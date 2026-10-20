# k3s

The `k3s` clanService deploys k3s clusters. Like `rke2`, it is a thin distro
layer over the shared library; only bootstrap, TLS directory, and join
semantics are distro-specific here.

## What is k3s-specific

- **CNCF distro path (D24).** k3s is a CNCF project, so a k3s cluster with
  all defaults is a fully-CNCF cluster.
- **PSA defaults where supported (D25).** k3s gets equivalent Pod Security
  Admission defaults; there is no CIS profile off RKE2.
- **Init-only PKI seeding** plus native replication (SPEC.md §5.10).
- **Bundled components off.** The Rancher helm-controller is disabled by
  default (D27); bundled Traefik and servicelb are always off (D3).

## What is shared

Transport, Cilium base, pools/BGP/BIRD, Envoy Gateway, cert-manager,
ClusterMesh, Flux day two, secrets planes, assertions — all from the shared
library. See [Architecture](../architecture/overview.md).

## Status

Implemented. Single-node, join, and HA VM suites are green (recorded at the
imported baseline `692807c` in the source fork). The canonical fleet-routing
test shape — kamrui-h1 — is a single-node k3s cluster holding the admin
role (D33).
