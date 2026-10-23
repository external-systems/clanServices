# AGENTS.md

Canonical standalone flake for External Systems' clan services. Consumers
must NOT need `clan-community`. Upstream (`git.clan.lol/clan/clan-community`)
is a review destination, not a dependency.

## Layout

- `services/<name>/` — public clanServices (`rke2`, `k3s`, `wireguard-mesh`).
  Auto-discovered via `flake-module.nix`; no central registration list.
- `lib/kube-cluster/` — PRIVATE shared implementation for rke2+k3s
  (interfaces, renderers, vars, assertions). Not a clan service. Renamed
  from `lib/rancher-cluster/` in delivery phase 1 (SPEC.md D45).
- `lib/import-flake/` — legacy flake-input adapter (optional).
- `tests/` — eval-test wiring; every `clan.modules` entry must have a
  nix-unit test (enforced by `checks.coverage`).
- `SPEC.md` (repo root) — the normative decision contract AND the status
  authority (implemented vs planned), optimized for agents. Round 13
  (2026-10-22) narrowed the contract to the Bootstrap + Data-plane
  contracts; Envoy Gateway, cert-manager, Flux install, external-dns,
  Sealed Secrets, OpenEBS, KubeVirt, Multus are REVOKED day-2 GitOps
  patterns, never clan-rendered (SPEC.md §3.3, D39–D45).
- `documentation/` — MkDocs site + reveal.js slides (human record, built
  via the `external-systems/presenting` flake). **Edit SPEC.md and
  `documentation/` together.** The old `services/rancher-cluster-spec.*`
  pair is retired.

## Hard rules

1. `git add` new files BEFORE any nix eval — Nix reads the git tree.
2. Static gates before commit: `nix fmt .` then `nix flake check
   --no-build --show-trace` (rule 9: never without `--no-build`); keep
   statix/deadnix clean. Fix all eval warnings.
3. No spec-implementation drift: amend the spec BEFORE implementing when a
   test disproves an assumption; never weaken a test to fit code.
4. Distro-specific config lives in the thin `rke2`/`k3s` services; shared
   behavior goes in the shared lib (`lib/kube-cluster/`) — fix once, not
   twice.
5. Multi-instance safe: namespace every global (systemd units, generators,
   interfaces) by `instanceName`.
6. Secrets: clan vars own the bootstrap plane only (CAs, tokens,
   kubeconfigs, ClusterMesh material, gitops-hub identities) — never in
   the Nix store. Sealing keys and all in-cluster application credentials
   are day-2 GitOps-owned (SPEC.md D35 revised, round 13).
7. Do not implement Planned/Reserved spec rows without reading SPEC.md's
   decision record (D1–D45) first — round 13 revoked the Gateway/Envoy
   layer, cert-manager base, clan-installed Flux, external-dns, Sealed
   Secrets, OpenEBS, KubeVirt, and Multus suites (day-2 GitOps patterns
   now); Cilium stays networking-only (D1); Node IPAM is the default
   classless-LB mechanism (D41); servicelb is permanently disabled (D42);
   the control domain is GitOps-neutral (`controlDomain.role`, D43).
9. DO NOT RUN `nix flake check`, it boots VM tests and will OOM kill the machine!!! Run with `--no-build`.

## Verified upstream facts the spec depends on

- Cilium 1.20: no Gateway HTTP/3, no Gateway mTLS, no multi-Gateway IP
  sharing, no BFD. LB IPAM allocates; delivery is separate (BGP v2 /
  floating / provider). Node IPAM (`nodeIPAM.enabled`) advertises node IPs
  for classless LoadBalancer Services; its ETP-Local EndpointSlice caveat
  affects only Cilium's own Gateway/Ingress (dummy Endpoints), which stay
  disabled (D1/D41). The Cilium chart ships no `crds/` dir — the operator
  manages CRDs at runtime.
- GitOps handoff (D40): Flux prune garbage-collects only the
  Kustomization's own `.status.inventory`; bootstrap with
  `kubectl apply --server-side` avoids CSA→SSA field-ownership friction;
  `cilium install` (CLI) auto-detects hidden values and skews cert
  generation — rejected as the bootstrap mechanism.
- `nix fmt` uses the repo `formatter.nix`.
