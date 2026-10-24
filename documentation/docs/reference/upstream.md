# Upstream references

The upstream facts behind the spec. Re-check these when versions move.

- **Cilium 1.20:** [native routing](https://docs.cilium.io/en/v1.20/network/concepts/routing/)
  delegates non-local pod traffic to the kernel; off-L2 nodes need a
  routing daemon. Multi-pool uses `CiliumPodIPPool` advertisements. BGP v2
  advertises pod pools and Service VIPs but is not the packet datapath.
  ClusterMesh requires the same datapath, non-overlapping pod CIDRs, node
  connectivity, and native-routing CIDRs covering all meshed pods.
- **Cilium LB features:** LB IPAM allocates; Node IPAM, provider routing,
  floating controllers, or BGP delivers. BGP announces only unset or
  `io.cilium/bgp-control-plane` classes. Node IPAM's ETP-Local dummy-
  Endpoints caveat affects only Cilium Gateway/Ingress, which are disabled.
- **Cilium lifecycle:** the chart ships no `crds/` directory; the operator
  manages CRDs. Helm is the canonical install path. The `cilium` CLI's
  environment auto-detection is not the bootstrap mechanism.
- **FRR 10.7:** integrated `/etc/frr/frr.conf`, eBGP, explicit AF
  activation, prefix-lists/route-maps, maximum-prefix, `maximum-paths`,
  multipath-relax, BFD, and Zebra RIB-to-kernel installation. See the
  [FRR 10.7 documentation](https://docs.frrouting.org/en/frr-10.7/).
- **FRR with Cilium:** `allow-reserved-ranges` and martian-next-hop
  handling are needed for loopback peering; rewrite Cilium's `::1` next hop
  to the stable node address. Cilium has no BFD, so local sessions use
  short timers while FRR-FRR paths use BFD.
- **NixOS FRR module:** one `services.frr.config`; no automatic firewall
  openings; config-only reloads preserve sessions, but enabling a daemon
  requires a restart. Preview with `frr-reload.py --test`.
- **WireGuard:** `AllowedIPs` is cryptokey routing, not a substitute for IP
  routing. One peer per interface; ECMP works across interfaces, not across
  overlapping peers on one interface.
- **GitOps handoff:** Flux prune touches only its own inventory; SSA
  bootstrap avoids client-side/server-side ownership friction. Argo uses
  resource tracking. HelmRelease adoption without Helm release storage is
  impossible.
- **Kubenix:** chart inflation at update time; typed-tree patching in
  clanServices without IFD.
- **Kubernetes:** aggregated `view` excludes Secrets; external CCM uses the
  uninitialized-taint flow; kubelet may lag apiserver by three minors.
- **RKE2:** `profile: cis`, PSA restricted, and host prerequisites.
- **hcloud-ip-floater:** reference for floating-IP movers; upstream is
  effectively unmaintained, so fork rather than depend.
- **go-httpbin:** the standard airgapped HTTP VM workload.
