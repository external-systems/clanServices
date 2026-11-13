# Testing

Misconfiguration fails at evaluation where possible and is VM-proven where
it cannot be. Tests cover the Bootstrap and Data-plane contracts only.

## Seams and rules

- Pure renderer nix-unit tests, including kubenix determinism.
- Throwaway clans through `clanLib.clan` for the inventory boundary.
- Hermetic clan VM suites, declared per service in `clanTests.<suite>` and
  exposed as `legacyPackages.<system>.vmTests` by the org runner (org-pkgs
  `flakeModules.vmTests`). VM suites never enter `checks` or CI; `checks`
  stays a lightweight static gate.
- **Where suites live.** Each service registers its suites in its
  `flake-module.nix` (24 in all); `flake-parts/clan-tests.nix` wraps each in
  clan-core's `clanTest` and hands it to `vmTests.tests`. k3s and RKE2
  suites that test one contract share a body in
  `lib/kube-cluster/tests/vm/<suite>.nix` (`single`, `join`, `ha`,
  `data-plane`, `clustermesh`, `clustermesh-tunnel`, `external`,
  `selective`); the files under `services/{k3s,rke2}/tests/vm/` are thin
  wrappers that pass `distro`, and every distro difference is an explicit
  branch in the shared body.
- **Running suites,** on the remote builder (euc-hel-0):
  - `vm-test --list` lists the suites.
  - `vm-test --check <suite>` checks that a suite evaluates and fits the
    resource limits without booting it; `vm-test --check` checks every
    suite, one Nix process per suite (about 3 GB each).
  - `vm-test <suite> --remote --quiet` runs one suite, keeps the full log
    in `build.log` and prints only the run summary;
    `vm-test --summary <suite>` prints the last summary again without
    building.
  - `vm-test --all --remote --rebuild --quiet` runs every suite. Suites
    run side by side, largest first, as long as their VMs fit the
    `vmTests.parallel` budget (the vCPUs and memory of all running VMs);
    a suite larger than the budget runs alone. A suite that failed while
    others ran beside it is rerun alone: passing then is `PASS(!)`, a pass
    with a warning that the suite is timing-sensitive under load (its first
    log is `build-under-load.log`). The run ends with one line per suite
    (`PASS`, `PASS(!)`, `CACHED` or `FAIL`) and exits non-zero on any
    `FAIL`.
  - `--serial` (with `--all`) runs one suite at a time.
  - `--rebuild` boots a suite whose result is already in the store. It
    builds a fresh copy of the test, so it works with `--remote` and
    `--all`. Without it, such a suite reports `CACHED`: nothing booted, so
    it is not a pass of this run.
- **Results and logs.** Sandboxed runs are authoritative: a suite passes
  when its build exits 0. Driver and interactive modes (`--driver`,
  `--interactive`) are for debugging only, and every fix found that way is
  re-proven with a sandboxed run. Every run ends with a summary (the
  subtests started, `!!!` failures, first build errors such as the
  test-script linter). Each suite writes `.vm-tests/<suite>/build.log`,
  `summary.txt` and `result.txt` (gitignored); read the summary before the
  full log.
- **Subtests and markers.** Test scripts group their steps in
  `with subtest("...")` phases, so the summary names the phase that failed.
  Every suite still prints one final `<SUITE>_OK` (suite name upper-cased,
  `-` → `_`) as the last statement of its `testScript`, after every
  assertion, and intermediate markers remain. They are for readers; the
  runner does not check them.
- **Pipes.** Test scripts read whole streams: `cmd | grep PAT >/dev/null`,
  never `grep -q`, whose early exit kills the writer with SIGPIPE under the
  driver's `pipefail`.
- **Resource limits,** owner-approved for euc-hel-0 because RKE2 nodes need
  at least 4 GiB and 2 vCPUs and planned topologies are larger:

  | Limit | Value |
  |---|---|
  | Per suite | 96 GiB and 36 vCPUs |
  | Per VM | 16 GiB and 8 vCPUs |
  | Default timeout | 2 hours |
  | `--all` budget (`vmTests.parallel`) | 24 vCPUs and 96 GiB |

- Artifact source/hash/render and publish-freshness gates.
- Offline execution, dual-stack in every boot test, round trips and failure
  behavior, negative assertions, operational postconditions, and fail-fast
  diagnostics. Eval fixtures are deterministic; VM allocations are generated
  fresh and printed at suite startup for diagnosis.

go-httpbin is the standard airgapped HTTP workload. Minimal local
artifacts are mandatory.

## Vars fixtures and VM generation

Eval tests use readable public values committed as plain `value` files under
`services/<svc>/tests/fixtures/vars/per-machine/<machine>/<generator>/<file>/`
and `services/<svc>/tests/fixtures/vars/shared/<generator>/<file>/`. Expected
addresses, ASNs, ports, transfer prefixes, and reserved-port strings come from
those fixtures, never from recomputed name hashes. D64 allocation tests cover
missing node and adjacency vars, duplicate loopbacks and ASNs, same-host
port/transfer collisions, unequal or overlapping pools, explicit overrides,
and the accepted case of equal transfers on unrelated hosts.

The locked clan-core `clanTest` module uses its Nix vars executor for VM
suites. It runs shared generators first and per-machine generators afterward,
encrypts test secrets with the harness's fixed test recipient, and merges the
result into a temporary directory. `clan.varsDirectory` and each node's
`clan.core.settings.directory` point at that merged directory, so
`getPublicValue` reads the newly generated values. The merge removes the
source suite's `vars/` tree and replaces it with generated vars. Test vars
are therefore generated during evaluation, and `vm-test <suite>` is all a
suite needs: there is no `update-vars` step. Do not run one and do not commit VM
allocation files or obsolete public-key fixtures. Each run draws fresh values;
routed-fabric and wireguard-mesh print their allocated addresses at startup
and assert those exact values with `ROUTED_FABRIC_ALLOCATED_OK` and
`WIREGUARD_MESH_ALLOCATED_OK` markers. Other suites retain explicit address
pins where they exercise override behavior.

## Current suites

- Existing single/join/HA per distro run on **wireguard-mesh** and assert
  the transport-derived tunnel/VXLAN profile, while the native data-plane
  suites on routed-fabric remain native. Not every suite is native.
- **IfState (D61):** live static reconfiguration with apply/check/restore,
  real DHCPv4 and SLAAC/default-route convergence, one persistent DHCP
  client across reapply, and clean `ifstatecli check` output.
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
  datapath mode, tunnel protocol, or maxConnectedClusters). VM proof covers
  k3s/RKE2 on native and tunnel profiles: selected edges' authenticated
  health and global-Service backends, A/B/C backend sets, and native
  dual-stack route isolation on non-transit leaves. A dedicated spine carries
  the union leaves consume; that is the eval-visible routed-only exception.
  Full-peering native/tunnel defaults and all four external suites also pass
  on the selective-aware resolver. Final logs are linked from SPEC.md §7.
- **ClusterMesh exposure and placement (D60):** native internal
  ClusterMesh (ONE pinned IPv4 VIP locked at host offset `0x79` in the
  `<instance>-fabric` private pool's IPv4 `/24`, explicit
  `lbipam.cilium.io/ips` projection, collision-checked against other pinned
  clan VIPs and pool-contained; NO ClusterMesh IPv6 VIP and NO
  `RequireDualStack` advertisement — the pinned Cilium 1.20.3
  clustermesh-apiserver etcd listens on an IPv4 wildcard with no
  dual-stack listener knob; cert SANs carry published IPv4/DNS endpoints
  only); tunnel NodePort
  ClusterMesh (exactly one apiserver per selected node — Deployment
  replicas = selected count, required hostname anti-affinity +
  nodeSelector — with stable selected node IPv4 addresses + default
  NodePort `32379`, optional explicit override, collision-checked per
  machine,
  maxSurge=0/maxUnavailable=1);
  external class + DNS name on BOTH profiles (explicit non-clan
  loadBalancerClass, DNS-only name, external DNS name in peers and cert
  SANs, runtime A record); placement selectors (voters/workers/all/labels)
  with clan-declared/generated labels only and zero-match eval negatives;
  LB replica rules (default min(3, eligible), positive ≤ eligible,
  required anti-affinity); auto choosing internal when capable else
  nodePort; unsupported/no-method eval negatives; ETP Local on every
  method. Current VM proof covers k3s and RKE2 external class+DNS exposure
  on both native and tunnel profiles; final logs are linked from SPEC.md §7.
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

**VM-proven on the final IfState tree:** netif live apply/check/restore;
DHCPv4/default-route and IPv6 SLAAC with one persistent client across live
reapply; WireGuard handshakes; routed-fabric transport and spine HA on a
flat underlay (NAT sites, external transit, Internet source/return and
route-filter negatives are planned, see
[Data-plane hardening](../plans/data-plane-hardening.md));
k3s/RKE2 single/join/HA and native data planes; and all twelve
native/tunnel/selective/external ClusterMesh variants. The selective proofs
include symmetric A↔B and B↔C edges, non-transitive A/C global-Service
isolation, and dual-stack route isolation on non-transit leaves. SPEC.md §7
records the final runs and remains the status authority. A VM-proven status
names its test file and a unique `*_OK` marker that the test prints.
Run logs land in `.vm-tests/<suite>/` and are never committed.

The imported baseline and BIRD checkpoint `2995ac3` (5 green / 7 red) are
legacy evidence only. No full-mesh fabric suite exists or is required.
