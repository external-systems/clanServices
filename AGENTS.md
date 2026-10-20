# AGENTS.md

Canonical standalone flake for External Systems' clan services. Consumers
must NOT need `clan-community`. Upstream (`git.clan.lol/clan/clan-community`)
is a review destination, not a dependency.

## Layout

- `services/<name>/` — public clanServices (`rke2`, `k3s`, `wireguard-mesh`).
  Auto-discovered via `flake-module.nix`; no central registration list.
- `lib/rancher-cluster/` — PRIVATE shared implementation for rke2+k3s
  (interfaces, renderers, vars, assertions). Not a clan service.
- `lib/import-flake/` — legacy flake-input adapter (optional).
- `tests/` — eval-test wiring; every `clan.modules` entry must have a
  nix-unit test (enforced by `checks.coverage`).
- `SPEC.md` (repo root) — the normative decision contract AND the status
  authority (implemented vs planned), optimized for agents.
- `documentation/` — MkDocs site + reveal.js slides (human record, built
  via the `external-systems/presenting` flake). **Edit SPEC.md and
  `documentation/` together.** The old `services/rancher-cluster-spec.*`
  pair is retired.
- Planned rename (not yet applied to code): `lib/rancher-cluster/` →
  `lib/kube-cluster/` once the upstream `kubernetes` distro lands (D23).

## Hard rules

1. `git add` new files BEFORE any nix eval — Nix reads the git tree.
2. Static gates before commit: `nix fmt .` then `nix flake check
   --show-trace`; keep statix/deadnix clean. Fix all eval warnings.
3. No spec-implementation drift: amend the spec BEFORE implementing when a
   test disproves an assumption; never weaken a test to fit code.
4. Distro-specific config lives in the thin `rke2`/`k3s` services; shared
   behavior goes in `lib/rancher-cluster/` — fix once, not twice.
5. Multi-instance safe: namespace every global (systemd units, generators,
   interfaces) by `instanceName`.
6. Secrets: clan vars own the bootstrap plane only (CAs, tokens,
   kubeconfigs, sealing keys) — never in the Nix store. In-cluster
   application credentials (provider keys, hub↔spoke kubeconfigs) are
   GitOps-owned via Sealed Secrets (SPEC.md D35).
7. Do not implement Planned/Reserved spec rows without reading SPEC.md's
   decision record (D1–D35) first — several invariants changed
   (Cilium is networking-only; Envoy Gateway is the default ingress/Gateway;
   Ingress API deprecated; HAProxy edge-proxy scrapped; Flux is default-on
   day two; OLM rejected).
9. DO NOT RUN `nix flake check`, it boots VM tests and will OOM kill the machine!!! Run with `--no-build`.

## Verified upstream facts the spec depends on

- Cilium 1.20: no Gateway HTTP/3, no Gateway mTLS, no multi-Gateway IP
  sharing, no BFD. LB IPAM allocates; delivery is separate (BGP v2 /
  floating / provider).
- Envoy Gateway: DaemonSet mode + ETP Local default + per-listener mTLS +
  HTTP/3 via ClientTrafficPolicy; managed Service is customized via
  EnvoyProxy `envoyService` (labels/annotations), never directly.
- `nix fmt` uses the repo `formatter.nix`.
