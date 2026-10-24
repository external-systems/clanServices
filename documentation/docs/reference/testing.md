# Testing

Misconfiguration fails at evaluation where possible and is VM-proven where
it cannot be. Tests cover the Bootstrap and Data-plane contracts only.

## Seams and rules

- Pure renderer nix-unit tests, including kubenix determinism.
- Throwaway clans through `clanLib.clan` for the inventory boundary.
- Hermetic `clan.nixosTests`, one at a time; sandboxed runs are authoritative.
- Artifact source/hash/render and publish-freshness gates.
- Offline execution, deterministic addresses, dual-stack in every boot
  test, round trips and failure behavior, negative assertions, operational
  postconditions, and fail-fast diagnostics.

go-httpbin is the standard airgapped HTTP workload. Minimal local artifacts
are mandatory.

## Round-14 suites

- Existing single/join/HA per distro, with native datapath assertions.
- **netif:** static and DHCP/RA addressing, on-link and policy routes,
  exports, and deploy-target behavior.
- **Fleet transport/FRR:** 3+ node per-pair WireGuard full mesh, real
  handshakes, NAT/outbound-only member, no `(none)` peer shadowing; FRR
  sessions and BFD on both sides; RIB versus kernel FIB; per-pair next
  hops; route-filter/default-route negatives; reload/restart behavior.
- **Data plane per distro:** native pod-to-pod without VXLAN, multi-pool
  remote routes, Node IPAM classless Services, ETP-Local candidates,
  node-bgp owner-only advertisement and withdrawal, shared-bgp dual-stack
  ECMP and single-path withdrawal, floating-pool blackhole window, and
  firewall positive/negative exposure. Single-path checks handle Linux
  `ip -j` output instead of assuming a `nexthops` array.
- **BGP ECMP/foreign router:** private fabric, MikroTik-style FRR fixture,
  upstream-router pools, and node-owned IPv6 pools.
- **Native ClusterMesh:** cross-cluster pod routes and mirror-Service
  reachability.
- **Fleet routing:** member/client/admin/router, client pod isolation,
  admin pod/ClusterIP/DNS access, router filtering, and kamrui-h1 dual-role.
- PKI rotation, fake CCM, GitOps SSA no-op handoff, distroDefaults, RKE2
  CIS, and control-domain/read-only credential behavior.

Retired: Gateway/QUIC/Flux-controller/external-dns/OpenEBS/KubeVirt/Multus/
Sealed-Secrets suites. Reserved: MCS-API and upstream-kubernetes suites.

## Status evidence

The imported baseline recorded green wireguard-mesh and distro single/join/
HA suites in the source fork. The later BIRD checkpoint `2995ac3` retained
5 green and 7 red suites. Those results are legacy evidence only: round-14
FRR, per-pair WireGuard, and native routing are not implemented or VM-proven
by this documentation-only change.
