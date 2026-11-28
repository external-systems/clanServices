# rke2

The `rke2` clanService deploys RKE2 clusters. It is a thin distro layer:
bootstrap, TLS directory, and join semantics live here; everything shared
comes from the private library.

## What is rke2-specific

- **CIS hardening (D25, planned as the default).** Today `profile = "cis"`
  is opt-in (the default is `null`); it maps to the nixpkgs `cisHardening`
  (v1.29+): PSA `restricted` cluster-wide except `kube-system`,
  protect-kernel-defaults, etcd user/group, CIS sysctls. No suite runs it
  yet.
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
bootstrap bundle, applied at boot and on each deploy that changes it via server-side apply on the `clusterInit`
machine (D40) — nothing is written to RKE2's watched manifests dir.

## Status

Bootstrap, `leaf`/`spine` transport, generic `node_transport` profiles,
full/selective ClusterMesh, placement/exposure, and read-only
`clan.networkFacts` schemaVersion 2 are implemented. IfState supplies the
live static host network. Current hermetic suites pass single/join/HA,
native data-plane, and the native, selective and external ClusterMesh
suites. Every suite runs on `routed-fabric`: Cilium tunnel mode and
`wireguard-mesh` were removed (D72, round 53). CIS hardening, the bootstrap bundle, and distro-specific bootstrap
behavior remain unchanged.

## Hardening (round G11)

- **A machine holds only what its role reads.** An agent gets the agent
  token, never the server token (which joins the control plane); the
  ClusterMesh CA and keys stay on the `clusterInit` server.
- **The cluster ports by source, from one matrix (D76).** The API
  answers the members and the cluster's pods; the supervisor and Cilium's health port answer the members; the kubelet answers the
  servers (pods only with `firewall.kubeletFromPods`); etcd answers the
  servers. A pod reaches the API on a server and nothing else of a node.
  No link is trusted: not a fabric link, not Cilium's host links.
- **HAProxy on loopback (D76).** The fronts listen on `127.0.0.1` and
  `::1`; the kubeapi name resolves there. No other host and no pod
  reaches them. Every backend connection leaves from the node's fabric
  address.
  An agent's supervisor front has port 9345, the supervisor's own:
  the agent's tunnel (`kubectl logs`, `exec`) dials the servers on the
  port of its join URL.
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
- **Hostile suite.** `rke2-hostile` attacks the cluster as an outsider
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
