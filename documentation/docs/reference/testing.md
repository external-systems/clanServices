# Testing

The testing contract (SPEC.md §6): misconfiguration fails at evaluation
where possible, and is VM-proven where it cannot be.

## Seams

- **Pure renderer nix-unit tests** — including kubenix render determinism.
- **Throwaway clans** via `clanLib.clan` — the inventory boundary.
- **`clan.nixosTests` hermetic VM suites** — one at a time, sandboxed and
  authoritative.
- **Artifact gates** — source/hash/render checks in the artifact flake,
  including the inflation and publish-freshness gates (D26/D29).

## Test fixtures

The standard internal HTTP/HTTPS workload is **go-httpbin** (a
zero-dependency Go stdlib httpbin port), pinned and airgap-carried. It
speaks HTTP/1.1 and HTTP/2 only, so HTTP/3 termination suites point an
HTTP/3-capable client at the Gateway with go-httpbin as the plain backend —
QUIC terminates at Envoy Gateway, which is the architecture under test. The
HTTP/3 client is nixpkgs `curlHTTP3`, run by the VM test driver directly on
the node; if an in-cluster client is needed, the artifact flake builds its
own image from `pkgs.curlHTTP3` via `dockerTools` — never third-party
images.

A required **QUIC passthrough suite** uses a UDPRoute (raw L4 UDP — QUIC
cannot be SNI-routed at L7) through an EG UDP listener on its own VIP (D15)
to a pinned **Caddy** fixture serving HTTP/3 end-to-end. Two fixtures, no
replacement: Caddy serves QUIC only; go-httpbin remains the L7 oracle.
HTTP/3 advertisement comes from the `Alt-Svc` response header (core
`ResponseHeaderModifier` HTTPRoute filter) or DNS `HTTPS`/SVCB records with
`alpn="h3"` in the private-domain zones (D22).

## Rules

Hermetic/offline; eval-deterministic addresses; dual-stack asserted in
every boot test; round-trips plus failure behavior (HTTPS validates the CA,
UDP echo, HTTP/3 uses QUIC, BGP withdrawal keeps the VIP via healthy
nodes); negative assertions; operational postconditions; fail fast.

## Suites

Existing single/join/HA suites stay. On top of them: transport matrix;
artifact matrix (3-minor version pins, D34); the EG gateway matrix
(replacing the old Cilium-gateway and Traefik-multi suites) — DaemonSet
placement, ETP Local, projections, L4+L7 on one Gateway, HTTP/3 QUIC, mTLS
accept/reject, cert-manager Gateway integration, source preservation, 0–N
multi-Gateway isolation, zero-clan-Gateway tenant round-trip; lb-pool
suite; bgp-ecmp suite (private fabric, MikroTik-style foreign-router
fixture); ClusterMesh matrix including kube-api mirror Service reachability
(D30); PKI rotation; CCM/GitOps handoff (Flux Kustomization no-op
first-reconcile proof, D29);
the `flux.enable=false` direct-apply suite (D28); the flux control-domain
suite (D36/D37: one hub + two spokes + one standalone in a mesh — the hub
applies to spokes via kubeconfig Secrets, spokes run no Flux deployments,
mirror-SAN assertion, an impersonation negative test, cert rotation keeps
reconciliation green, and the standalone cluster is unaffected but
mesh-reachable); rke2 CIS profile suite
(D25); external-dns annotation rendering (D31); sealed-secrets plane
separation (D35); multus; openEBS; kubevirt; and the fleet-routing suite
(client/admin split, dual-role cluster member, opt-in svc/pod zones,
east-west mTLS accept/reject — D20/D22/D33).

Reserved: MCS-API suites and upstream-`kubernetes` distro suites (D23).

## Recorded green

Baseline `692807c` (imported): wireguard-mesh plus rke2/k3s single/join/HA
VM suites, in the source fork.
