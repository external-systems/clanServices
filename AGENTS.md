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
  `modes` (network modes per machine, `specs/netif.md` N24; mechanism in
  `lib/modes.nix`), `routed-fabric`, `remote-builder` (D65),
  `nat-gateway` and `router` (`specs/gateway.md`; mechanism in
  `lib/gateway/`)).
  `routed-fabric` is the only transport: `wireguard-mesh` and Cilium
  tunnel mode were removed (SPEC.md D72; the last commit with them is
  tag `tunnel-mode-final`). The obsolete `fleet-routing`,
  `lib/import-flake/`, `lib/inputs-module.nix`, BIRD helpers, and
  BIRD-specific VM fixtures were deleted in the round-17 cleanup;
  their former ghost failures no longer block eval gates. No archives.
  Auto-discovered via `flake-module.nix`; no central registration list.
- `lib/gateway/` — the private implementation of `nat-gateway` and
  `router` (`specs/gateway.md` G1): NixOS modules under
  `clanServices.gateway.*` (`nat64.nix`, `clat.nix`, `router.nix`), their
  Python helpers (health check, CLAT follower, prefix hook) and the
  fixed names (`names.nix`). One translator, one CLAT and one router per
  machine; the services assert it. It also holds the fixture suites
  (`tests/vm/*.nix`, registered in its `flake-module.nix`): dual WAN
  (frozen), the WAN link, IPv6-only hosts and clusters behind a
  provider's NAT64 and DNS64, `<distro>-clat` and `nat-gateway-kube`,
  which run on the services (`k3s-clat-mapped` keeps its fixtures). Our
  own DNS64 is removed (`specs/gateway.md` §14.5 point 1). A new design
  question starts as a probe (a throwaway suite that prints `FINDING`
  lines) and ends as assertions in a real suite. `checks.clat-follow`
  simulates the CLAT follower's move rule under loss (round G11).
- `lib/kube-cluster/` — PRIVATE shared implementation for rke2+k3s
  (interfaces, renderers, vars, assertions, the cluster firewall
  rules in `firewall.nix`). Not a clan service. Renamed
  from `lib/rancher-cluster/` in delivery phase 1 (SPEC.md D45).
  `service.nix` is the ONE implementation of both clan services
  (round 59, K13): `services/{k3s,rke2}/default.nix` only pass it a
  distro record (name, units, add-ons, config keys, the runtime and
  PKI pieces). A fix to either service goes in `service.nix` unless
  it is one of those distro fields.
- `flake-parts/` — root flake-parts modules, auto-imported (import-tree):
  - `clan-tests.nix`: the `clanTests` option and the org `vmTests` settings
    (limits, `parallel` budget, timeout, `flakeChecks`);
  - `nix-unit.nix`: `nix-unit.tests`, `tests.systems` and `checks.nix-unit`;
  - `coverage.nix`: every `clan.modules` entry needs a nix-unit test;
  - `docs.nix`: the site nav and deck settings;
  - `overlays.nix`: re-exports the org-pkgs overlays.
  - `spec-checks.nix`: `checks.spec-headings` (section numbers of
    `SPEC.md` and `specs/*.md` ascend) and `checks.jool-available`;
  - `frr-checks.nix`: `checks.frr-conf`, the self-test of the
    build-time `vtysh --dryrun` check (`lib/frr-check.nix`) that every
    `routed-fabric` machine runs on its rendered `frr.conf`.
- `tests/` — fixtures shared by VM suites: `ifstate-vm.nix` (the
  IfState node), `ifstate-noop.nix` (the "a reapply changes nothing"
  helper), `headscale-vm.nix` (an offline Headscale), `wifi-ap.nix`
  (simulated access points), `suite-lib.nix` (test-script helpers:
  `observe`, `print_versions`, `seconds_until`, `holds_for`,
  `state_dump_on_failure`; use them in new suites).
  Each service, and `lib/gateway`, registers its suites in its
  `flake-module.nix` (49 in all; `vm-test --list` counts them)
  under the top-level `clanTests.<suite>`. They land in
  `legacyPackages.<system>.vmTests`, never `checks`. k3s and rke2 suites
  that test one contract share a body in `lib/kube-cluster/tests/vm/<suite>.nix`
  (`single`, `join`, `ha`, `data-plane`, `clustermesh`,
  `clustermesh-nodeport`, `external`, `selective`); `services/{k3s,rke2}/tests/vm/` hold thin
  wrappers, and the body branches on `distro` explicitly.
- `devenv.yaml`/`devenv.nix` — the org dev shell (`fmt`, `check`,
  `sync-locks`, `docs-build`, `docs`, `slides`, `vm-test`). `flake.lock`
  and `devenv.lock` must pin the same nixpkgs (`checks.lock-sync`). After
  `nix flake update org-pkgs`, run `sync-locks` in the same commit.
- `.github/` — the org `ci.yml` (calls pkgs `org-ci.yml`; required check
  `ci / flake-check`) and the branch ruleset. Never add steps or jobs here;
  CI changes are pkgs PRs.
- `specs/netif.md` — the host-networking contract and status authority
  (decisions N…, use cases U…, the responsibility boundary
  in §1.1): netif, the shared IfState base, modes, the
  ownership registry. It supersedes SPEC.md D50/D53/D61 where they
  conflict; its human pages are `documentation/docs/netif/`. Edit them
  together.
- `specs/gateway.md` — the contract and status authority for the
  `router` and `nat-gateway` services and `lib/gateway/` (decisions
  G…, probes PR…, slices S…). Both services exist; their suites and
  the fixture suites that remain are its §5. Its §16 is the hardening
  review of round G9 and its fixes (G10); §17 is round G11 for the
  gateway services. Round G11 for netif, routed-fabric and the kube
  services is SPEC.md round 58. A router judges its own
  links only and the NixOS firewall stays on (G25): never set
  `networking.firewall.enable = false` in a service.
  Its human pages are `documentation/docs/gateway/`. Edit them together.
- `specs/target-design.md` and `specs/design-{routed-fabric,kube,gateway,netif}.md`
  — the target design of round 61 (best design first). Not implemented.
  The index holds the shared contracts, the owner's open decisions and
  the build order; each area file holds invariants, rule sets, code
  sketches, probes and its PR steps. Read the index and the area file
  before a hardening change. A probe that disagrees amends the design
  file first. Its human page is `documentation/docs/plans/target-design.md`.
- `SPEC.md` (repo root) — the normative decision contract AND the status
  authority (implemented vs planned), optimized for agents. Its decision
  record (D1–D72) and dated round summaries hold the history; read them
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

## Current phase: best design first

Owner's decision, 2026-11-27. It holds until the owner says the design is
frozen (planned for the 0.1.x release).

- There are NO consumers and NO deployed machines. Nothing needs protecting.
- The goal is the BEST design for safety and stability of every clanService.
  Judge a design on its merits, never on how many suites it would change.
- The VM suites and nix-unit tests exist to PROVE BEHAVIOUR. They are not
  regression protection yet. Do not baby-sit them: when a better design
  needs a suite, a fixture, a counter name, a rendered string or a whole
  suite to change or go, change it.
- Order of work: amend the spec, build the best design, then make the
  suites prove its behaviour. Regression protection is added by the owner
  only after that.
- What stays fixed: the safety behaviour itself. A change may replace a
  check with a stronger or equal behaviour check (for example "an outsider
  cannot reach a pod"). It may never drop a safety behaviour to make a
  design pass. The hostile suites (`*-hostile`, `hostile-*`) state that
  behaviour: extend them, do not weaken them.
- Checks that pin a mechanism (a rule's comment, a counter's chain, "this
  ruleset is empty", an exact rendered string) are free to rewrite.

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
   Rewriting a test for a better design is not weakening it, as long as
   the safety behaviour it proved is still proved ("Current phase" above).
4. Distro-specific config lives in the thin `rke2`/`k3s` services; shared
   behavior goes in the shared lib (`lib/kube-cluster/`) — fix once, not
   twice.
5. Multi-instance safe: namespace every global (systemd units, generators,
   interfaces) by `instanceName`.
6. Secrets: clan vars own the bootstrap plane only (CAs, tokens,
   kubeconfigs, ClusterMesh material, gitops-hub identities) — never in
   the Nix store. Sealing keys and all in-cluster application credentials
   are day-2 GitOps-owned (SPEC.md D35 revised, round 13).
7. Read SPEC.md's decision record (D1–D72) before implementing a
   Planned/Reserved row. Standing decisions: IfState 2.5.1 is the only
   static network renderer (no systemd-networkd, netdevs or scripted
   network units; D61); one owner each for Cilium and FRR objects; FRR +
   per-pair WireGuard + native routing is the only data plane (D72:
   tunnel mode and `wireguard-mesh` were removed); Cilium is
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
    (96 GiB and 36 vCPUs per suite, 16 GiB and 8 vCPUs per VM, 45 min timeout)
    are owner-approved for euc-hel-0, because RKE2 nodes need at least
    4 GiB and 2 vCPUs and planned topologies are larger. Raising them needs
    the owner's yes.

## Verified upstream facts

Upstream behaviour the specs depend on, each verified by a probe or a
suite (IfState, Cilium, FRR, dhcpcd, Jool, the GitOps handoff):
`documentation/docs/reference/upstream-facts.md`. Read the section of a
component before changing code that touches it; add a fact there when a
suite or probe proves one.
