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

## Round-15 suites

- Existing single/join/HA per distro, with native datapath assertions.
- **netif:** multi-instance and multi-link inventories, static and
  DHCP/RA addressing, on-link and policy routes, conflicting-ownership
  and duplicate-default-route eval negatives, MTU derivation, exports,
  and deploy-target behavior.
- **Routed-fabric transport/FRR:** explicit routed hubs only (no iBGP,
  no route reflectors, no full mesh); eBGP sessions and BFD on both
  sides; RIB versus kernel FIB with no reject routes and no installed IP
  default route unless an explicit policy table requires it; hub HA = 2
  active-active multi-flow ECMP and single-hub withdrawal; two NAT
  sites with no direct link via reachable hubs; next-hop-self from
  hubs; spoke non-transit negatives; NAT/outbound-only members; the
  external-transit 0.0.0.0/0 and ::/0 present ONLY in the WireGuard
  crypto ACL, with Internet-SOURCED inbound traffic via router/hub to a
  VIP and its source-policy return path (any installed/accepted default
  route is a negative); route-filter negatives; reload/restart behavior;
  MTU/PMTU.
- **Data plane per distro:** native pod-to-pod without any tunnel or
  overlay, multi-pool remote routes, Node IPAM classless Services at
  fabric scope, ETP-Local candidates, node-bgp owner-only advertisement
  and withdrawal, shared-bgp dual-stack ECMP and single-path
  withdrawal, floating-pool blackhole window, Cilium
  `installIptablesRules=false` with nftables, and firewall
  positive/negative exposure. Single-path checks handle Linux `ip -j`
  output instead of assuming a `nexthops` array.
- **BGP/foreign router:** private fabric, MikroTik-style FRR fixture,
  upstream-router pools, and node-owned IPv6 pools.
- **Selective ClusterMesh:** full peering is the DEFAULT within one
  fabric; explicit symmetric selective peers override it within that
  fabric — in the canonical A-B-C shape, B peers with A and C while
  A and C share no state and install no pod routes for each other
  (leaf isolation); cross-cluster pod routes and mirror-Service
  reachability for peering pairs; separate routed-fabric trust domains
  stay isolated (negative).
- **Roles:** exactly four canonical roles — `member` (base),
  `client`, `admin`, `router` (specializations); no default role, no
  access setting. Isolation per role (client pod-route isolation, admin
  svc/pod/ClusterIP + DNS access, router filtering), hub versus router
  orthogonality, and the kamrui-h1 single-node k3s + admin dual-role
  shape.
- PKI rotation, fake CCM, GitOps SSA no-op handoff, distroDefaults, RKE2
  CIS, and control-domain/read-only credential behavior.

Retired: Gateway/QUIC/Flux-controller/external-dns/OpenEBS/KubeVirt/Multus/
Sealed-Secrets suites. Reserved: MCS-API and upstream-kubernetes suites.

## Status evidence

Round 15 is the normative target; the routed-fabric MVP described above
is not yet implemented or VM-proven. The imported baseline recorded
green wireguard-mesh and distro single/join/HA suites in the source
fork; the later BIRD checkpoint `2995ac3` retained 5 green and 7 red
suites. Both are legacy evidence only — they say nothing about
round-15 routed hubs, selective ClusterMesh, or native multi-pool
routing. No full-mesh suite exists or is required under round 15.
