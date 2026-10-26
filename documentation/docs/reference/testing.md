# Testing

Misconfiguration fails at evaluation where possible and is VM-proven where
it cannot be. Tests cover the Bootstrap and Data-plane contracts only.

## Seams and rules

- Pure renderer nix-unit tests, including kubenix determinism.
- Throwaway clans through `clanLib.clan` for the inventory boundary.
- Hermetic `clan.nixosTests`, one at a time; sandboxed runs are
  authoritative (interactive/driver mode is debug-only, and every
  driver-mode fix is re-proven with a sandboxed rerun). VM logs live
  under `.baton-pass/vm-logs/`, one per suite.
- Artifact source/hash/render and publish-freshness gates.
- Offline execution, deterministic addresses, dual-stack in every boot
  test, round trips and failure behavior, negative assertions,
  operational postconditions, and fail-fast diagnostics.

go-httpbin is the standard airgapped HTTP workload. Minimal local
artifacts are mandatory.

## Round-17 suites

- Existing single/join/HA per distro — these suites currently run on
  **wireguard-mesh** transport; the Round 17 target asserts the
  transport-derived tunnel/VXLAN profile there, while the native
  data-plane suites on the routed-fabric profile remain native. Not every
  existing suite is native.
- **Generic transport (D58):** a third-party eval overlay proves k3s/rke2
  consume only the generic `node_transport` export and never branch on
  service names; profile validation accepts the two validated profiles
  (routed-fabric → native + local-router + internalLoadBalancer/nodePort;
  wireguard-mesh → tunnel/VXLAN + nodePort) and rejects every other
  route-exchange/tunnel combination; `cilium.helmValues` contradiction of
  the derived mode/protocol/devices/directRoutingDevice/MTU/exposure is an
  eval negative; MTU floor checks (native minimum, VXLAN minimum − 50).
- **netif:** multi-instance and multi-link inventories, static and
  DHCP/RA addressing, on-link and policy routes, conflicting-ownership
  and duplicate-default-route eval negatives, MTU derivation, exports,
  and deploy-target behavior.
- **Routed-fabric transport/FRR:** the derived spine/leaf graph — every
  spine pair automatically adjacent, leaves defaulting to all spines,
  explicit per-leaf spine subsets, no mutual lists (no iBGP, no route
  reflectors, no leaf↔leaf peering); eBGP sessions and BFD on both
  sides; RIB versus kernel FIB with no reject routes and no installed IP
  default route unless an explicit policy table requires it;
  **spine/leaf HA = 2 active-active multi-flow ECMP, single-spine
  withdrawal, and failure/restore convergence**; **FRR reload/restart
  with a stable RIB/FIB**; two NAT
  sites with no direct link via reachable spines; next-hop-self from
  spines; leaf non-transit negatives; NAT/outbound-only members; the
  external-transit 0.0.0.0/0 and ::/0 present ONLY in the WireGuard
  crypto ACL, with Internet-SOURCED inbound traffic via spine/border to a
  VIP and its source-policy return path (any installed/accepted default
  route is a negative; NAT borders have no automatic conntrack sharing,
  so existing-flow failover needs a separate state mechanism);
  route-filter negatives; MTU/PMTU.
- **Data plane per distro:** native pod-to-pod without any tunnel or
  overlay on the routed-fabric profile, multi-pool remote routes, Node
  IPAM classless Services at
  fabric scope, ETP-Local candidates, node-bgp owner-only advertisement
  and withdrawal, shared-bgp dual-stack ECMP and single-path
  withdrawal, floating-pool blackhole window, Cilium
  `install-iptables-rules=true` through `iptables-nft`, no legacy
  iptables or kube-proxy rules, and firewall positive/negative exposure.
  Single-path checks handle Linux `ip -j`
  output instead of assuming a `nexthops` array.
- **BGP/foreign router:** private fabric, MikroTik-style FRR fixture,
  upstream-router pools, and node-owned IPv6 pools.
- **ClusterMesh (D60):** full peering remains the DEFAULT within one
  fabric; explicit symmetric selective peers override it within that
  fabric — in the canonical A-B-C shape, B peers with A and C while
  A and C share no state and install no pod routes for each other
  (leaf isolation); cross-cluster pod routes and mirror-Service
  reachability for peering pairs; separate routed-fabric trust domains
  stay isolated (negative); mesh-group uniformity negatives (mixed
  datapath mode, tunnel protocol, or maxConnectedClusters).
- **ClusterMesh exposure and placement (D60):** native internal
  ClusterMesh (pinned dual-stack VIPs locked at host offset `0x79` in the
  `<instance>-fabric` private pool's IPv4 `/24` + IPv6 `/64`, explicit
  `lbipam.cilium.io/ips` projection, collision-checked against other pinned
  clan VIPs and pool-contained); tunnel NodePort
  ClusterMesh (exactly one apiserver per selected node — Deployment
  replicas = selected count, required hostname anti-affinity +
  nodeSelector — with stable selected node addresses + default NodePort
  `32379`, optional explicit override, collision-checked per machine,
  maxSurge=0/maxUnavailable=1);
  external class + DNS name on BOTH profiles (explicit non-clan
  loadBalancerClass, DNS-only name, external DNS name in peers and cert
  SANs); placement selectors (voters/workers/all/labels) with
  clan-declared/generated labels only and zero-match eval negatives;
  LB replica rules (default min(3, eligible), positive ≤ eligible,
  required anti-affinity); auto choosing internal when capable else
  nodePort; unsupported/no-method eval negatives; ETP Local on every
  method.
- **Roles and switches:** exactly two topology roles — `leaf` and
  `spine` (D59, renamed from round 16's member/hub); plus the orthogonal
  per-machine `access` switch (`member` default,
  `client`, `admin`) — no `router` role,
  no default-role model. Isolation per access level (client pod-route
  isolation, admin svc/pod/ClusterIP route access, border upstream
  filtering with no automatic admin DNS), spine/border/access
  orthogonality (a border that is not a spine, a spine that is not a
  border), the
  kamrui-h1 single-node k3s + spine topology + access=admin dual-shape,
  and NO member-facing DNS assertions — member DNS is day-2 (D22 amended
  2026-10-25).
- **Network facts and diagrams (D57):** deep evaluation, JSON
  serializability, versioned/secret-free/read-only schema (version 2 per
  D59), parity with
  exports and functional renders, dynamic-state labeling, and one
  consumer-owned nix-topology wrapper build producing SVGs without a
  nix-topology dependency in clanServices.
- PKI rotation, fake CCM, GitOps SSA no-op handoff, distroDefaults, RKE2
  CIS, and control-domain/read-only credential behavior.

Retired: Gateway/QUIC/Flux-controller/external-dns/OpenEBS/KubeVirt/Multus/
Sealed-Secrets suites. Reserved: MCS-API and upstream-kubernetes suites.

## Status evidence

**Implemented (suites registered, not green-claimed):** netif and the
round-16 `member`/`hub` routed-fabric data plane (5R1, 2026-10-25), plus
the native Cilium/pools stages 5R2(1)–(3). **Planned (round 17, 5R5,
docs-locked, no implementation or VM evidence):** the `leaf`/`spine`
rename, the generic `node_transport` schema, and the D60 ClusterMesh
placement/exposure suites above — the existing SPEC acceptance baseline is
the only standing evidence for those.
The imported baseline recorded
green wireguard-mesh and distro single/join/HA suites in the source
fork; the later BIRD checkpoint `2995ac3` retained 5 green and 7 red
suites. Both are legacy evidence only — they say nothing about
round-17 spine/leaf routed fabrics, generic `node_transport` profiles,
ClusterMesh exposure profiles, or native multi-pool
routing. No full-mesh suite exists or is required.
