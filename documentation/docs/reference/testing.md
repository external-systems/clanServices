# Testing

The testing contract (SPEC.md §7, D44): misconfiguration fails at evaluation
where possible, and is VM-proven where it cannot be. The test surface covers
the two contracts — nothing else is VM-tested.

## Seams

- **Pure renderer nix-unit tests** — including kubenix render determinism.
- **Throwaway clans** via `clanLib.clan` — the inventory boundary.
- **`clan.nixosTests` hermetic VM suites** — one at a time, sandboxed and
  authoritative.
- **Artifact gates** — source/hash/render checks in the artifact flake,
  including committed-manifest inflation proofs and publish-freshness checks
  (D26/D40).

## Test fixtures

The standard internal HTTP workload is **go-httpbin** (a zero-dependency Go
stdlib httpbin port), pinned and airgap-carried as a test-fixture artifact.
It is the one workload fixture. Minimal airgapped artifacts for hermetic VM
tests are a hard requirement.

## Rules

Hermetic/offline; eval-deterministic addresses; dual-stack asserted in every
boot test; round-trips plus failure behavior (BGP withdrawal keeps the VIP
via healthy nodes); negative assertions; operational postconditions; fail
fast.

## Suites

- Existing single/join/HA suites per distro (keep).
- Transport — host-wireguard full mesh, including the all-or-none
  trust-domain posture.
- Artifact matrix — 3-minor version pins eval (D34).
- **Data-plane suite** — pool allocation via `io.cilium/lb-ipam`, classless
  Service → Node IPAM node IPs (ServiceLB parity), ETP-Local candidate
  restriction under nodeipam, firewall positive AND negative exposure;
  go-httpbin workload fixture, hermetic (artifact-flake Cilium airgap
  images preloaded). Registered as `k3s-data-plane` and `rke2-data-plane`
  since phase 3. The `shared-bgp` ECMP + withdrawal and floating-pool
  blackhole-window assertions land with the BGP/BIRD phases (§8 phase 5).
- bgp-ecmp suite — private fabric, MikroTik-style foreign-router fixture.
- ClusterMesh matrix — including kube-api mirror Service reachability (D30).
- PKI rotation — including cert bootstrap runbook execution.
- CCM knob suite — hermetic fake-CCM.
- **GitOps-handoff suite** (D40/D44) — the bootstrap bundle applied by
  `clan-bootstrap`, then re-applied server-side under a second field
  manager: strict no-op, no object drift, dataplane green before and after.
  No Flux in VMs; Flux artifacts were cut from pkgs.
- `distroDefaults` suite (D42) — stock rke2/k3s deploy Traefik via their own
  helm-controller; the classless Traefik Service gets node IPs from Node
  IPAM; servicelb stays off.
- rke2 CIS profile suite (D25).
- Fleet-routing suite — client/admin split, dual-role cluster member, opt-in
  svc/pod rewrite zones (D13/D22/D33).
- Control-domain suite (D43/D30/D38) — hub + two spokes + one standalone in
  a mesh: hub-held kubeconfigs resolve through the mesh; spokes run no
  GitOps controller; mirror-SAN assertion; read-only credential positive
  (list pods/nodes) + negative (secrets forbidden); cert rotation re-issue
  keeps access green; standalone unaffected but mesh-reachable.

Retired suites (round 13): EG gateway matrix, QUIC/Caddy fixtures, flux
control-domain suite, external-dns, OpenEBS, KubeVirt, Multus,
sealed-secrets.

Reserved: MCS-API suites and upstream-`kubernetes` distro suites (D23).

## Recorded green

Baseline `896acdf` (imported): wireguard-mesh plus rke2/k3s single/join/HA
VM suites, in the source fork.
