# Agent brief for phase prompts

Every phase prompt starts by telling the agent to read this page. It holds
the context that is the same for every phase, so each prompt can focus on
its own work. Phases 1 and 2 are merged (PRs #2 and #3); the lessons below
come from those two deliveries and their review rounds.

## Checkouts and skills

Work in `external-systems/clanServices`. `external-systems/pkgs` (artifacts,
IfState/dhcpcd/Kubernetes overlays, airgap images) and
`external-systems/home` (the real fleet and the agent skills) are checked
out next to it. Only change `pkgs` or `home` when the prompt says so.

Load skills by name with the Skill tool before you edit anything they cover.
A skill is a reference, not a plan: when a skill and SPEC.md disagree,
SPEC.md wins for this repo, and you say so in the PR.

| Skill | Load it when |
| --- | --- |
| `clanservices` | you touch `services/*` (roles, `perInstance`, vars generators, exports, eval tests) |
| `clan-core` | vars CLI and storage layout, inventory, `clan machines install`, clan test harness |
| `nix-style` | you edit any `.nix` file (alejandra/statix/deadnix loop, attribute style) |
| `vm-tests` | you create, run, or debug a VM suite |
| `ifstate` | you touch netif, `lib/ifstate.nix`, links, addresses, routes, DHCP hooks |
| `frr` | you touch `lib/kube-cluster/frr.nix`, BGP/BFD timers, route maps, FRR VM probes |
| `cilium` | you touch Cilium values, BGP CRs, ClusterMesh, pools |
| `rancher-kubernetes` | you touch k3s/rke2 services or their VM suites |
| `flakeparts` | you edit `flake.nix` or `flake-parts/` |
| `external-systems` | org wiring: `org-pkgs`, devenv, CI, lock sync, PRs and merge order |
| `remote-builder` | you run VM suites on euc-hel-0 or debug remote builds |
| `terranix` | phases 8 and 9 (`tf/`, providers, S3 backend, `tofu`) |
| `disko` | anything that runs `clan machines install` on a fresh disk |
| `baton-pass` | you must stop mid-phase and hand the work to another agent |

`declarative-runtime`, `kubenix`, `envoy-gateway`, and `openebs` are
day-2 or bundle concerns and are out of scope for the hardening plan.

## Repository map

| Path | What lives there |
| --- | --- |
| `SPEC.md` | normative contract and status authority; decisions D1–D66, invariants §5, subsystems §6, testing §7 |
| `AGENTS.md` | layout, tool loop and hard rules (read all of them) |
| `services/netif/` | underlay links, addressing, DHCP hook, policy routing, deploy-target export |
| `services/routed-fabric/` | leaf/spine fabric: per-adjacency WireGuard, FRR, border, source return |
| `services/wireguard-mesh/` | tunnel transport (full mesh, VXLAN profile) |
| `services/k3s/`, `services/rke2/` | thin distro services; shared code goes in `lib/kube-cluster/` |
| `services/remote-builder/` | Nix remote builder over `ssh-ng` (D65); eval-tested, no VM suite |
| `lib/kube-cluster/fabric.nix` | adjacency keys, hash-derived adjacency interface names, adjacency MTU (addresses, ASNs, ports and transfer prefixes are clan vars, D64) |
| `lib/kube-cluster/frr.nix` | the integrated FRR config renderer (timer profiles, DelayOpen, maximum-prefix) |
| `lib/kube-cluster/network-facts.nix` | the read-only `clan.networkFacts` schema (version 2) |
| `lib/ifstate.nix` | shared IfState base with stable module key `clanServices:lib/ifstate.nix`; reserved ports |
| `lib/ip.nix` | IP literal helpers and `reservedPolicyTables` |
| `services/<name>/tests/eval-tests.nix` | nix-unit tests; throwaway clans via `clanLib.clan` with `directory = ./fixtures` |
| `services/<name>/tests/fixtures/vars/` | committed public var values the eval tests read |
| `services/<name>/tests/vm/` | VM suites, registered in `services/<name>/flake-module.nix` under `clanTests.<suite>` |
| `lib/kube-cluster/tests/vm/` | suite bodies shared by k3s and RKE2 (`single`, `join`, `ha`, `data-plane`, `clustermesh`, `clustermesh-tunnel`, `external`, `selective`); the per-service files are thin wrappers passing `distro` |
| `flake-parts/clan-tests.nix` | wraps `clanTests` in clan-core's `clanTest` for the org `vm-test` runner; resource limits, `parallel` budget and timeout |
| `flake-parts/nix-unit.nix` | `nix-unit.tests`, `tests.systems`, `checks.nix-unit` |
| `devenv.yaml`, `devenv.nix` | the org dev shell (`fmt`, `check`, `docs-build`, `vm-test`) |
| `documentation/docs/` | MkDocs site; edit together with SPEC.md |

## Commands

```bash
git add -A                        # Nix only sees tracked files; do this before every eval
fmt                               # nix fmt: org treefmt (alejandra, statix, deadnix, nixf-diagnose, ...)
check                             # nix flake check: nix-unit, coverage, treefmt, lock-sync, docs (no VMs)
nix build .#checks.x86_64-linux.nix-unit -L   # only the eval tests, with output
vm-test --list                    # registered VM suites
vm-test --check [<suite>]         # suites evaluate and fit the caps, one Nix process each
vm-test <suite> --remote          # one suite on euc-hel-0; log in .vm-tests/<suite>/build.log
vm-test <suite> --remote --quiet  # same, printing only the run summary (.vm-tests/<suite>/summary.txt)
vm-test --summary <suite>         # the last run's summary again, without building
vm-test --all --remote --rebuild --quiet  # every suite, side by side within vmTests.parallel
vm-test --all --serial --remote   # every suite, one at a time
vm-test <suite> --remote --rebuild  # boot a suite whose result is already in the store
vm-test <suite> --driver --interactive   # debug only, runs VMs locally
```

Outside the devenv shell, use `nix run .#vm-test -- <args>`.

Registered suites today (24): `netif`, `netif-dhcp`, `routed-fabric`,
`wireguard-mesh`, and for each of `k3s` and `rke2`: `-single`, `-join`,
`-ha`, `-data-plane`, `-clustermesh`, `-clustermesh-tunnel`,
`-clustermesh-external`, `-clustermesh-external-native`,
`-clustermesh-selective`, `-clustermesh-selective-tunnel`.

- **Pass/fail:** a suite passes when its sandboxed build exits 0. With
  `--all`, each suite ends `PASS`, `PASS(!)` (failed beside other suites,
  passed when rerun alone: timing-sensitive under load), `CACHED` (already
  in the store; nothing booted, so not a pass of this run: add `--rebuild`)
  or `FAIL`. Test scripts group steps in `with subtest("...")` phases so the
  summary names the failing phase. Every suite prints one final
  `<SUITE>_OK` (suite name upper-cased, `-` → `_`) as the last statement of
  its `testScript`, after every assertion, and intermediate markers stay.
  They are for readers; the runner does not check them.
- **On euc-hel-0.** A clustermesh suite boots up to five 3.5 GiB VMs, and
  evaluating one takes about 3 GB on the client. `vm-test --all` boots
  suites side by side only within the `vmTests.parallel` budget; never
  evaluate every suite in one Nix process on a laptop (`vm-test --check`
  uses one process per suite).
- **Test vars** are generated during evaluation by clan-core's `clanTest`;
  there is no update-vars step and no VM vars to commit.
- **Pipes in test scripts:** `cmd | grep PAT >/dev/null`, never `grep -q`
  (its early exit SIGPIPEs the writer under `pipefail`).

## Workflow that worked in phases 1 and 2

1. Read the prompt's files, then write the SPEC.md amendment (a new
   decision row or a revised one, plus §5/§6/§7 text) and the matching
   `documentation/` page **before** touching code. Commit it on its own
   (`docs: lock phase N <topic> contract`).
2. Implement in small commits. After each: `git add -A`, `fmt`,
   `nix flake check --show-trace`.
3. For every new assertion write one positive and one negative nix-unit
   test. Negative tests use the existing helper pattern
   `failedAssertion = config: needle: lib.any (item: !item.assertion && lib.hasInfix needle item.message) config.assertions;`
   and match a stable part of the message.
4. Run the affected VM suites with `vm-test <suite> --remote --quiet` (or
   `vm-test --all --remote --rebuild --quiet`). Cite each suite's marker and
   result in the PR.
5. Review your own diff as a hostile reviewer before opening the PR. Both
   earlier phases needed two review rounds for things a self-review would
   have caught: collisions checked in one namespace but not the other
   (tables vs rule priorities), options written into clan-core's
   namespace, modules imported twice without a key, and VM tests that
   hard-coded a hash.

## Pitfalls already paid for

- **Never hard-code a derived value in a VM test.** Read it from the
  evaluated node instead, for example
  `config.clan.networkFacts.fabric.<instance>.loopback` or `.asn`, through
  `nodes.<machine>.…` in the test module. Phase 2's review rejected a
  hard-coded `rflo<hash>` name.
- **DelayOpen is five seconds.** After any session reset, wait for the
  session to be Established and the RIB to be replayed before comparing
  RIBs; a diff taken during the hold-down fails.
- **No-op FRR reloads must be empty.** `frr-reload.py --test` must show no
  add/delete lines; peer uptimes must survive. If you change FRR
  rendering, match FRR's running-config serialization (plain `bfd` next to
  `bfd profile`, implicit defaults) or the reload diff stops being empty.
- **Our options live under `clanServices.*`**, never `clan.core.*`
  (`clanServices.networking.reservedPorts`, for example).
- **Shared NixOS modules imported by several services need a stable
  `key`** or their options are declared twice.
- **`checks` is static only.** A VM derivation in `checks` is a bug in the
  output wiring; never work around it with `--no-build`.
- **Every `clan.modules` entry needs a nix-unit test** (`checks.coverage`).
- **nixf-diagnose runs every rule** (org treefmt): no redundant
  `builtins.` prefixes, no unused formals, no needless `rec`, no shadowed
  builtins. Fix findings by hand.
- **Collision checks need both directions and every namespace:** same
  host, across instances, and against kernel/Cilium reserved values
  (`ip.reservedPolicyTables` = `{0,200,201,253,254,255,2004,2005}`).
- **`ifstatecli check` exit status is not a diff signal.** It reports
  parser/execution failures only; assert "clean" by parsing its output.
- **Suites are not in `vm-tests/`.** The `vm-tests` skill describes the
  org default, where each `vm-tests/*.nix` file is one test. Here, suites
  are clan tests registered in `services/<name>/flake-module.nix` under
  `clanTests.<suite>` (`vmTests.dir = null`), and services are
  auto-discovered by `services/flake-module.nix`. The runner, its flags and
  the rules are the org ones.
- **Hostnames are not resolved at eval.** Literal checks apply to IP
  literals; a hostname gets a warning, not an error.

## Rules (AGENTS.md)

- Amend SPEC.md and `documentation/` together before changing code.
- `git add` new files before any Nix eval.
- Format and lint with `fmt` (org treefmt); fix every finding.
- `nix flake check --show-trace` must pass (`checks` is static only).
- VM suites live only under `legacyPackages.<system>.vmTests` and run on
  euc-hel-0, side by side only within `vmTests.parallel`. Logs land in
  `.vm-tests/<suite>/` (gitignored).
- Breaking changes carry no compatibility burden: no migration shims,
  deprecation aliases, or renamed-option warnings.
- Keep `targetHost` on the underlay address, never a fabric, transfer, or
  tunnel address.
- One branch, one PR, do not merge.

## Pull request shape

Match PRs #2 and #3:

- **Summary:** a short tree or diff block of what moved, then bullets.
- **Evidence:** the exact commands, each suite with its marker and result
  line (`PASS`, `PASS(!)`, `FAIL`; never `CACHED` as proof), and at least one *Before → After* pair for each bug you fixed.
- **Merge Danger:** door (one-way or two-way) and blast radius.

State anything you could not run (no KVM, no network, no credentials) and
why. Never claim a suite passed without a sandboxed run of it.
