# AGENTS.md

Canonical standalone flake for External Systems' clan services. Consumers
must NOT need `clan-community`. Upstream (`git.clan.lol/clan/clan-community`)
is a review destination, not a dependency. The repo follows the
external-systems org standard (SPEC.md D66): one `org-pkgs` input, whose
`flakeModules.default` supplies formatting, docs, lock sync and the VM-test
runner; a devenv shell; the org CI. external-systems/home consumes it
(`remote-builder` today).

## Layout

- `services/<name>/` — public clanServices (`rke2`, `k3s`, `netif`,
  `routed-fabric`, `remote-builder` (D65); `wireguard-mesh` is a supported
  tunnel transport, D58 — not pending retirement). The obsolete `fleet-routing`,
  `lib/import-flake/`, `lib/inputs-module.nix`, BIRD helpers, and
  BIRD-specific VM fixtures were deleted in the round-17 cleanup;
  their former ghost failures no longer block eval gates. No archives.
  Auto-discovered via `flake-module.nix`; no central registration list.
- `lib/kube-cluster/` — PRIVATE shared implementation for rke2+k3s
  (interfaces, renderers, vars, assertions). Not a clan service. Renamed
  from `lib/rancher-cluster/` in delivery phase 1 (SPEC.md D45).
- `flake-parts/` — root flake-parts modules, auto-imported (import-tree):
  - `clan-tests.nix`: the `clanTests` option and the org `vmTests` settings
    (limits, `parallel` budget, timeout, `flakeChecks`);
  - `nix-unit.nix`: `nix-unit.tests`, `tests.systems` and `checks.nix-unit`;
  - `coverage.nix`: every `clan.modules` entry needs a nix-unit test;
  - `docs.nix`: the site nav and deck settings;
  - `overlays.nix`: re-exports the org-pkgs overlays.
- `tests/ifstate-vm.nix` — the shared IfState node fixture for VM suites.
  Each service registers its suites (24 in all) in its `flake-module.nix`
  under the top-level `clanTests.<suite>`. They land in
  `legacyPackages.<system>.vmTests`, never `checks`. k3s and rke2 suites
  that test one contract share a body in `lib/kube-cluster/tests/vm/<suite>.nix`
  (`single`, `join`, `ha`, `data-plane`, `clustermesh`, `clustermesh-tunnel`,
  `external`, `selective`); `services/{k3s,rke2}/tests/vm/` hold thin
  wrappers, and the body branches on `distro` explicitly.
- `devenv.yaml`/`devenv.nix` — the org dev shell (`fmt`, `check`,
  `sync-locks`, `docs-build`, `docs`, `slides`, `vm-test`). `flake.lock`
  and `devenv.lock` must pin the same nixpkgs (`checks.lock-sync`). After
  `nix flake update org-pkgs`, run `sync-locks` in the same commit.
- `.github/` — the org `ci.yml` (calls pkgs `org-ci.yml`; required check
  `ci / flake-check`) and the branch ruleset. Never add steps or jobs here;
  CI changes are pkgs PRs.
- `SPEC.md` (repo root) — the normative decision contract AND the status
  authority (implemented vs planned), optimized for agents. Its decision
  record (D1–D66) and dated round summaries hold the history; read them
  before changing a design decision. Bootstrap + data plane only: ingress,
  certificates, Flux, storage and the like are day-2 GitOps patterns, never
  clan-rendered (§3.3, D39–D45).
- `documentation/` — the human record: `docs/*.md` (the MkDocs site) and
  `slides/slides.md` (the deck, plus `custom.css` for its own blocks).
  org-pkgs `flakeModules.docs` builds them (`docs-build`); there is no
  `mkdocs.yml` or deck `index.html`. **Edit SPEC.md and
  `documentation/` together.** The old `services/rancher-cluster-spec.*`
  pair is retired.

## Tool loop

- The shell is devenv. If `DEVENV_ROOT` is unset, run commands with
  `devenv shell -- <cmd>`, or the flake apps (`nix run .#vm-test -- ...`).
- `git add -A`, then `fmt`, then `check`. Both must pass before a change is
  done.
- Bump the org input with `nix flake update org-pkgs`, then `sync-locks`
  in the same commit.
- VM suites: `vm-test --check <suite>` before booting anything, then
  `vm-test <suite> --remote --quiet` and read the printed summary
  (`vm-test --summary <suite>` reprints it). The exit status is the result;
  open `.vm-tests/<suite>/build.log` only where the summary points. Every
  suite: `vm-test --all --remote --rebuild --quiet`. Add `--rebuild` to
  boot a suite whose result is already in the store: a `CACHED` result
  booted nothing and is not a pass of this run. An interrupted `--all`
  run continues with `--resume`.
- Test refactors (subtests, shared bodies, rewrites) must stay faithful:
  `nix run .#suite-snapshot -- BASE` before editing, then
  `nix run .#suite-snapshot -- AFTER --pin BASE` and
  `nix run .#suite-compare -- BASE AFTER` (every node derivation and
  normalized test script equal; `reference/testing.md`).

## Hard rules

1. `git add` new files BEFORE any nix eval — Nix reads the git tree.
2. Static gates before commit: `fmt` (`nix fmt`) then `check`
   (`nix run .#flake-check -- --show-trace`). `checks` is static-only: treefmt,
   nix-unit, coverage, lock-sync, the docs and deck builds, and the KVM
   guard. Run a full `check` for every verification: it fails on dangerous
   evaluation warnings (org-pkgs `evalWarnings.deny`: ignored, removed or
   insecure config) and lists the rest, which you fix when convenient.
   Formatting comes from org-pkgs treefmt: alejandra, statix, deadnix,
   shellcheck, sizelint and nixf-diagnose with every rule. Fix nixf
   findings by hand (`nix-style` skill). Formatter changes are pkgs PRs.
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
7. Read SPEC.md's decision record (D1–D66) before implementing a
   Planned/Reserved row. Standing decisions: IfState 2.5.1 is the only
   static network renderer (no systemd-networkd, netdevs or scripted
   network units; D61); one owner each for Cilium and FRR objects; FRR +
   per-pair WireGuard + native routing is the data plane, and
   `wireguard-mesh` is a supported tunnel transport; Cilium is
   networking-only (D1) and multi-pool; Node IPAM is the classless-LB
   default (D41); `node-bgp` is owner-only, `shared-bgp` uses ECMP (D8);
   servicelb stays disabled (D42); the control domain is GitOps-neutral
   (`controlDomain.role`, D43).
8. VM suites must NEVER enter `checks`; they live under
   `legacyPackages.<system>.vmTests`. If a VM derivation ever appears in
   `checks`, fix the output boundary; never work around it with
   `--no-build`.
9. VM suites run on euc-hel-0 (`--remote`). `vm-test --all --remote`
   runs them side by side within `vmTests.parallel` (the vCPUs and memory
   of all running VMs), largest first; a suite that failed beside others
   is rerun alone, and a pass then is `PASS(!)`: a pass with a warning
   that the suite is timing-sensitive under load. `--serial` runs one at a
   time. Each suite writes `.vm-tests/<suite>/{build.log,summary.txt,result.txt}`
   (gitignored). Evaluate suites one per Nix process (`vm-test --check`):
   one process for all of them needs about 3 GB per suite. SPEC.md cites
   the suite and its `*_OK` marker, never a log file.
10. Breaking changes carry no compatibility burden: there are no external
    consumers or deployments and no real machines use these flakes, so
    never add migration shims, deprecation aliases, or renamed-option
    warnings.
11. Keep the deploy target (`clan.core.networking.targetHost`) on the
    underlay address, never a fabric or tunnel address, so a fabric change
    cannot lock out its own deployment.
12. A suite passes when its sandboxed build exits 0. Test scripts group
    their steps in `with subtest("...")` phases, so the summary names the
    failing phase. Every suite still prints one final `<SUITE>_OK` marker
    (suite name upper-cased, `-` → `_`) as the last statement of its
    `testScript`, after every assertion, and intermediate markers stay.
    Readers use them to follow a log; the runner does not check them. In
    test scripts, pipe into `grep PAT >/dev/null` (`vm-test --check`
    rejects `| grep -q`: an early exit SIGPIPEs the writer). Test vars are
    generated during evaluation by clan-core's `clanTest`; there is no
    update-vars step and nothing to commit. The repo's resource limits
    (96 GiB and 36 vCPUs per suite, 16 GiB and 8 vCPUs per VM, 2 h timeout)
    are owner-approved for euc-hel-0, because RKE2 nodes need at least
    4 GiB and 2 vCPUs and planned topologies are larger. Raising them needs
    the owner's yes.

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
- `nix fmt` is org-pkgs treefmt (alejandra and the org linters; see rule 2).
