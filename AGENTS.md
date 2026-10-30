# AGENTS.md

Canonical standalone flake for External Systems' clan services. Consumers
must NOT need `clan-community`. Upstream (`git.clan.lol/clan/clan-community`)
is a review destination, not a dependency.

## Layout

- `services/<name>/` — public clanServices (`rke2`, `k3s`, `netif`,
  `routed-fabric`; `wireguard-mesh` is a supported tunnel transport,
  D58 — not pending retirement). The obsolete `fleet-routing`,
  `lib/import-flake/`, `lib/inputs-module.nix`, BIRD helpers, and
  BIRD-specific VM fixtures were deleted in the round-17 cleanup;
  their former ghost failures no longer block eval gates. No archives.
  Auto-discovered via `flake-module.nix`; no central registration list.
- `lib/kube-cluster/` — PRIVATE shared implementation for rke2+k3s
  (interfaces, renderers, vars, assertions). Not a clan service. Renamed
  from `lib/rancher-cluster/` in delivery phase 1 (SPEC.md D45).
- `tests/` — eval-test wiring and the VM output adapter; every
  `clan.modules` entry must have a nix-unit test (enforced by
  `checks.coverage`). `clan.nixosTests` definitions are emitted under
  `legacyPackages.<system>.vmTests`, never `checks`. Run one with
  `nix run .#vm-test -- <suite>` (`--list` enumerates suites; `--rebuild`
  forces a fresh run).
- `dev/` — development-only flake inputs and their lock, plus the
  flake-parts partition module for checks, formatting, documentation, slides,
  the dev shell, and apps. The root and dev locks are the only lockfiles;
  nix-unit evaluates the root `tests.systems` output directly.
- `SPEC.md` (repo root) — the normative decision contract AND the status
  authority (implemented vs planned), optimized for agents. Round 14
  (2026-10-24) makes FRR + per-pair host WireGuard + native-routed
  multi-pool Cilium the data-plane target and puts static host networking
  in inventory through `netif` (D47–D50). Round 15 adds `routed-fabric`,
  multi-instance multi-link `netif`, selective ClusterMesh, and
  transport/egress correctness rules (D51–D55). Round 16 adds orthogonal
  `access`/`border` settings and the read-only, non-secret
  `clan.networkFacts` interface (D56–D57). Round 17 implements the generic
  `node_transport` schemaVersion 2 outside `lib/kube-cluster` (D58), the
  `leaf`/`spine` symmetric graph (D59), and ClusterMesh placement/exposure
  (D60). Round 18 (2026-10-27) makes IfState 2.5.1 the exclusive static
  networking renderer (D61): no systemd-networkd, netdevs, or scripted
  network units; live reconciliation replaces reboot-based changes.
  `lib/ifstate.nix` is the shared per-machine base; the artifact flake
  `external-systems/pkgs` owns the IfState and Kubernetes overlays and
  per-system airgap artifacts. FRR/Zebra owns dynamic routes; Cilium
  interfaces and table 200 are ignored by IfState. `wireguard-mesh` is a
  supported tunnel transport. Breaking changes ship without migration
  shims: no external consumers or deployments exist. Round 19
  (2026-10-28, D62) makes `pkgs` the nixpkgs/flake-parts and artifact
  authority and moves every VM suite from `checks` to
  `legacyPackages.<system>.vmTests`. The full netif, routed-fabric, k3s,
  and RKE2 native/tunnel/selective/external VM matrix is green on the
  IfState tree. Round 21 (2026-10-29, D63) adds phase-2 exposure,
  policy/endpoint/mesh/deploy-target assertions, forwarding-safe RA, and
  stable FRR timer/recovery behavior; routes are stable before fast.
  Round 13's Bootstrap +
  Data-plane scope remains: Envoy Gateway, cert-manager, Flux install,
  external-dns, Sealed Secrets, OpenEBS, KubeVirt, Multus are day-2 GitOps
  patterns, never clan-rendered (SPEC.md §3.3, D39–D45).
- `documentation/` — MkDocs site + reveal.js slides (human record, built
  via the `external-systems/presenting` flake). **Edit SPEC.md and
  `documentation/` together.** The old `services/rancher-cluster-spec.*`
  pair is retired.

## Hard rules

1. `git add` new files BEFORE any nix eval — Nix reads the git tree.
2. Static gates before commit: `nix fmt .` then `nix flake check
   --show-trace`. `checks` is static-only since round 19 (eval tests,
   coverage, formatting), so a full `nix flake check` is part of every
   verification; keep statix/deadnix clean and fix all eval warnings.
   Formatting is alejandra, always; `formatter.nix` also enables statix,
   deadnix, shellcheck, sizelint, and nixf-diagnose through treefmt-nix.
   Remove `builtins.` prefixes when the prelude builtin is unshadowed
   (`sema-primop-removed-prefix`).
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
   decision record (D1–D63) first — round 13 revoked the Gateway/Envoy
   layer and other day-2 suites; round 14 superseded BIRD/VXLAN with
   FRR/per-pair WireGuard/native routing; round 15 renamed the fabric
   `routed-fabric` and made `netif` multi-instance/multi-link; round 16
   added orthogonal access/border and `clan.networkFacts`; round 17
   implemented `leaf`/`spine`, generic `node_transport`, and ClusterMesh
   placement/exposure; round 18 made IfState 2.5.1 the only static network
   renderer (D61); round 19 made `pkgs` the artifact/shared-input authority
   and moved VM suites out of `checks` (D62). Do not reintroduce
   systemd-networkd, netdevs, scripted network units, or a second owner for
   Cilium/FRR objects. `wireguard-mesh` is a supported tunnel transport and
   breaking changes carry no compatibility burden (no external consumers or
   deployments, no migration shims). Cilium stays networking-only (D1) and
   multi-pool; Node IPAM is the classless-LB default (D41); `node-bgp` is
   owner-only while `shared-bgp` uses ECMP (D8); servicelb is permanently
   disabled (D42); the control domain is GitOps-neutral
   (`controlDomain.role`, D43).
9. VM suites must NEVER enter `checks`; they live under
   `legacyPackages.<system>.vmTests`. If a VM derivation ever appears in
   `checks`, fix the output boundary; never work around it with
   `--no-build`.
10. VM test logs go to `.baton-pass/vm-logs/<suite>/logs-<n>` (n = 0, 1,
    … per run). `.baton-pass/` is gitignored and never committed; SPEC.md
    cites the suite and its `*_OK` marker, not a log file in git.
11. Breaking changes carry no compatibility burden: there are no external
    consumers or deployments and no real machines use these flakes, so
    never add migration shims, deprecation aliases, or renamed-option
    warnings.
12. Keep the deploy target (`clan.core.networking.targetHost`) on the
    underlay address, never a fabric or tunnel address, so a fabric change
    cannot lock out its own deployment.

## Verified upstream facts the spec depends on

- IfState 2.5.1: `ifstatecli apply` fully reconciles declared objects;
  `ifstatecli check` is the dry run. Runtime `!include` keeps secrets out
  of the store. `KillMode=process` preserves hook daemons; global
  forwarding uses `sysctl_conf`. Package metadata is authoritative even
  though upstream 2.5.1 prints `ifstatecli 2.5.0`.
- Cilium 1.20: native routing delegates non-local pod traffic to the
  kernel FIB; off-L2 nodes therefore need FRR-distributed pod-pool routes.
  Multi-pool uses `CiliumPodIPPool` advertisements. ClusterMesh requires
  the same datapath, non-overlapping pod CIDRs, node connectivity, and
  native-routing CIDRs covering all meshed pods. Cilium has no BFD.
  LB IPAM allocates; delivery is separate. Node IPAM advertises node IPs
  for classless LoadBalancer Services; its ETP-Local EndpointSlice caveat
  affects only Cilium's own Gateway/Ingress (dummy Endpoints), which stay
  disabled (D1/D41). The chart ships no `crds/` dir.
- FRR 10.7: one integrated `services.frr.config`; Zebra installs routes;
  eBGP ECMP needs `maximum-paths` and often multipath-relax; Cilium's
  loopback next hop needs reserved-range/martian handling and rewrite;
  FRR-FRR paths can use BFD. WireGuard ECMP requires one peer per
  interface and multiple interfaces, never overlapping peers on one
  interface. FRR 10.7.1 reload starts newly enabled daemons without
  restarting bgpd (probe-verified 2026-10-24).
- GitOps handoff (D40): Flux prune garbage-collects only the
  Kustomization's own `.status.inventory`; bootstrap with
  `kubectl apply --server-side` avoids CSA→SSA field-ownership friction;
  `cilium install` (CLI) auto-detects hidden values and skews cert
  generation — rejected as the bootstrap mechanism.
- `nix fmt` uses the repo `formatter.nix` (alejandra; see rule 2).
