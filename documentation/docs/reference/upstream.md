# Upstream references

The upstream facts behind the spec. Re-check these when versions move.

- **Cilium 1.20:** [native routing](https://docs.cilium.io/en/v1.20/network/concepts/routing/)
  delegates non-local pod traffic to the kernel; off-L2 nodes need a
  routing daemon. Multi-pool uses `CiliumPodIPPool` advertisements. BGP v2
  advertises pod pools and Service VIPs but is not the packet datapath.
- **Cilium ClusterMesh:** the
  [setup guide](https://docs.cilium.io/en/v1.20/network/clustermesh/setup/)
  is the primary source: clusters peer pairwise and symmetrically through
  per-remote clustermesh-apiserver connections, so selective peering and
  leaf isolation (unpeered clusters share no state and no pod routes) are
  upstream-supported behavior, not a custom deviation. Requirements stay:
  same datapath, non-overlapping pod CIDRs, node connectivity, and
  native-routing CIDRs covering all meshed pods.
- **Cilium LB features:** LB IPAM allocates; Node IPAM, provider routing,
  floating controllers, or BGP delivers. BGP announces only unset or
  `io.cilium/bgp-control-plane` classes. Node IPAM's ETP-Local dummy-
  Endpoints caveat affects only Cilium Gateway/Ingress, which are disabled.
  Fabric-wide reachability of Node-IPAM Service addresses (via node-local
  FRR) and `defaultLBServiceIPAM=nodeipam` are **project decisions**
  (D41), not upstream defaults — upstream Node IPAM only fills a Service's
  ingress status; delivery is a separate step.
- **Cilium lifecycle:** the chart ships no `crds/` directory; the operator
  manages CRDs. Helm is the canonical install path. The `cilium` CLI's
  environment auto-detection is not the bootstrap mechanism.
- **FRR 10.7:** integrated `/etc/frr/frr.conf`, eBGP, explicit AF
  activation, prefix-lists/route-maps, maximum-prefix, `maximum-paths`,
  multipath-relax, BFD, and Zebra RIB-to-kernel installation. See the
  [FRR 10.7 documentation](https://docs.frrouting.org/en/frr-10.7/).
- **FRR topology facts:** route reflection is an iBGP mechanism only
  (RFC 4456; FRR's `route-reflector` config); eBGP has no route
  reflectors, so a routed hub is plain eBGP transit with `next-hop-self`
  toward spokes — which is why the round-15 fabric forbids iBGP/RR
  outright and makes spokes non-transit by policy, not by omission.
- **FRR with Cilium:** `allow-reserved-ranges` and martian-next-hop
  handling are needed for loopback peering; rewrite Cilium's `::1` next hop
  to the stable node address. Cilium has no BFD, so local sessions use
  short timers while FRR-FRR paths use BFD.
- **NixOS FRR module:** one `services.frr.config`; no automatic firewall
  openings. FRR 10.7.1 reload starts newly enabled daemons while preserving
  bgpd (probe-verified). Preview with `frr-reload.py --test`; inspect its
  add/delete delta because a non-empty delta still exits zero.
- **WireGuard:** `AllowedIPs` is cryptokey routing, not a substitute for IP
  routing — and it is simultaneously an **inbound source ACL**: after a
  handshake, a peer may only send packets whose source IP lies in that
  peer's AllowedIPs (`wg(8)`, wireguard.com whitepaper). One peer per
  interface; ECMP works across interfaces, not across overlapping peers
  on one interface. This dual role is what makes the AllowedIPs =
  transit/source ACL contract enforceable at the crypto layer. The kernel
  module installs no routes at all (route installation is a userspace
  choice — wg-quick adds them, the clan renderer does not), which is why
  an external-transit 0.0.0.0/0 + ::/0 may sit in the crypto ACL while the
  RIB/FIB carries no default route.
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
