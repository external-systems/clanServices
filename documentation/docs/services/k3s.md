# k3s

The `k3s` clanService deploys k3s clusters. Like `rke2`, it is a thin distro
layer over the shared library; only bootstrap, TLS directory, and join
semantics are distro-specific here.

## What is k3s-specific

- **CNCF distro path (D24).** k3s is a CNCF project, so a k3s cluster with
  all defaults is a fully-CNCF cluster.
- **PSA defaults where supported (D25, planned).** k3s is to get equivalent
  Pod Security Admission defaults; there is no CIS profile off RKE2.
- **Secrets encrypted at rest** (`secrets-encryption: true` on every
  server), as rke2 does by default.
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
bootstrap bundle, applied at boot and on each deploy that changes it via server-side apply on the `clusterInit`
machine (D40) — nothing is written to the k3s manifests dir.

## Status

Bootstrap, `leaf`/`spine` transport, generic `node_transport` profiles,
full/selective ClusterMesh, placement/exposure, and read-only
`clan.networkFacts` schemaVersion 2 are implemented. IfState supplies the
live static host network. Current hermetic suites pass single/join/HA,
native data-plane, and the native, selective and external ClusterMesh
suites. Every suite runs on `routed-fabric`: Cilium tunnel mode and
`wireguard-mesh` were removed (D72, round 53). The canonical dual-shape remains kamrui-h1: a single-node k3s
cluster holding the routed-fabric `spine` topology role with
`access = "admin"` (D33, revised by D52, D56, and renamed D59).

## Hardening (round G11)

- **A machine holds only what its role reads.** An agent gets the agent
  token, never the server token (which joins the control plane); the
  ClusterMesh CA and keys stay on the `clusterInit` server.
- **The cluster ports by source, from one matrix (D76).** The API
  answers the members and the cluster's pods; Cilium's health port answer the members; the kubelet answers the
  servers (pods only with `firewall.kubeletFromPods`); etcd answers the
  servers. A pod reaches the API on a server and nothing else of a node.
  No link is trusted: not a fabric link, not Cilium's host links.
- **HAProxy on loopback (D76).** The fronts listen on `127.0.0.1` and
  `::1`; the kubeapi name resolves there. No other host and no pod
  reaches them. Every backend connection leaves from the node's fabric
  address.
- **A fabric always (D76).** `network.fabric` is required; there are no
  manual addresses. The README quick start is a one-machine fabric, and
  a test evaluates it.
- **Pods and Services only over the fabric (D74).** The table
  `inet kube-<instance>` drops and counts a packet for the cluster's
  pod or Service CIDRs that arrives on any link but a fabric link, a
  pod link, loopback or a link its owner declared inside. A host on the
  node LAN that routes a pod address to a node gets nothing. Cilium
  hands a packet for a local pod past netfilter on its own devices;
  the clusterwide policy of a later step guards that path.
- **Hostile suite.** `k3s-hostile` attacks the cluster as an outsider
  on the node LAN, as a fabric leaf outside the cluster, as a pod and
  as a local user. Every verdict has a positive control.
- **The first-server guard fails closed.** A `clusterInit` server with no
  etcd data waits for IfState and FRR, starts only when every other server
  refuses the connection, and refuses when one answers or stays silent
  for 300 s. `/var/lib/rancher/<distro>/server/allow-new-cluster-<instance>`
  allows one start.
- **Two servers are refused** (etcd needs both: worse than one); an even
  count above two warns. To replace a dead server of three, add the new
  one and remove the old in one commit. Half-explicit CIDR pairs, overlapping pod and
  service CIDRs, and an instance name that is no Cilium cluster name
  (32 characters at most) are eval errors. `configOverrides` cannot replace
  a key the service renders or carry a token.
- **HAProxy**: the stats page is read-only on loopback; the health check
  verifies the kubeapi FQDN.

## Two safety rules (2026-11-21)

- **NodePorts answer only on node addresses** (D69). Cilium serves a
  NodePort before the node's firewall. Without this rule every
  `LoadBalancer` Service opened a port on any outside-facing link
  Cilium is attached to.
- **CoreDNS copies never share a node** (D70) in a cluster of two or
  more machines. One dead node no longer takes cluster DNS with it.
