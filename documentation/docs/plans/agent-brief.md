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
| `flakeparts` | you edit `flake.nix`, `dev/`, or add a partition |
| `terranix` | phases 8 and 9 (`tf/`, providers, S3 backend, `tofu`) |
| `disko` | anything that runs `clan machines install` on a fresh disk |
| `baton-pass` | you must stop mid-phase and hand the work to another agent |

`declarative-runtime`, `kubenix`, `envoy-gateway`, and `openebs` are
day-2 or bundle concerns and are out of scope for the hardening plan.

## Repository map

| Path | What lives there |
| --- | --- |
| `SPEC.md` | normative contract and status authority; decisions D1–D63, invariants §5, subsystems §6, testing §7 |
| `AGENTS.md` | hard rules (read all 12) |
| `services/netif/` | underlay links, addressing, DHCP hook, policy routing, deploy-target export |
| `services/routed-fabric/` | leaf/spine fabric: per-adjacency WireGuard, FRR, border, source return |
| `services/wireguard-mesh/` | tunnel transport (full mesh, VXLAN profile) |
| `services/k3s/`, `services/rke2/` | thin distro services; shared code goes in `lib/kube-cluster/` |
| `lib/kube-cluster/fabric.nix` | today's hash-derived fabric addresses, ASNs, ports, transfer prefixes, interface names |
| `lib/kube-cluster/frr.nix` | the integrated FRR config renderer (timer profiles, DelayOpen, maximum-prefix) |
| `lib/kube-cluster/network-facts.nix` | the read-only `clan.networkFacts` schema (version 2) |
| `lib/ifstate.nix` | shared IfState base with stable module key `clanServices:lib/ifstate.nix`; reserved ports |
| `lib/ip.nix` | IP literal helpers and `reservedPolicyTables` |
| `services/<name>/tests/eval-tests.nix` | nix-unit tests; throwaway clans via `clanLib.clan` with `directory = ./fixtures` |
| `services/<name>/tests/fixtures/vars/` | committed public var values the eval tests read |
| `services/<name>/tests/vm/` | VM suites (`clan.nixosTests`), registered in `services/<name>/flake-module.nix` |
| `tests/vm-test-app.nix` | the `vm-test` app |
| `dev/` | dev-only partition (nix-unit, presenting): checks, formatter, docs, apps |
| `documentation/docs/` | MkDocs site; edit together with SPEC.md |

## Commands

```bash
git add -A                              # Nix only sees tracked files; do this before every eval
nix fmt .                               # alejandra + statix + deadnix + nixf-diagnose + shellcheck + sizelint
nix flake check --show-trace            # static gate: nix-unit, coverage, formatting (no VMs)
nix build .#checks.x86_64-linux.nix-unit -L   # only the eval tests, with output
nix run .#vm-test -- --list             # registered VM suites
nix run .#vm-test -- <suite>            # one suite; log in .baton-pass/vm-logs/<suite>/logs-<n>
nix run .#vm-test -- --rebuild <suite>  # force a fresh run of a cached suite
nix build .#legacyPackages.x86_64-linux.vmTests.<suite>.driver && ./result/bin/nixos-test-driver --interactive   # debug only
statix check . && deadnix -l -L --fail . && git diff --check
```

After a successful cached build with no live marker, `vm-test` appends `nix log
<target>` under a `--- cached build log ---` header and checks that log. It
prints `marker found in cached build log` on success. If no cached log exists,
it fails closed and asks for `--rebuild`; it never passes without seeing the
expected marker in either log.

Registered suites today (24): `netif`, `netif-dhcp`, `routed-fabric`,
`wireguard-mesh`, and for each of `k3s` and `rke2`: `-single`, `-join`,
`-ha`, `-data-plane`, `-clustermesh`, `-clustermesh-tunnel`,
`-clustermesh-external`, `-clustermesh-external-native`,
`-clustermesh-selective`, `-clustermesh-selective-tunnel`. Every suite prints
exactly one final `<SUITE>_OK` (suite name upper-cased, `-` → `_`) as the last
statement of its `testScript`, after every assertion; intermediate markers
stay. `vm-test --list` shows each expected marker, and the runner rejects a
zero-exit log that lacks it. Run k3s and rke2 suites one at a time: they are
the heaviest.

## Workflow that worked in phases 1 and 2

1. Read the prompt's files, then write the SPEC.md amendment (a new
   decision row or a revised one, plus §5/§6/§7 text) and the matching
   `documentation/` page **before** touching code. Commit it on its own
   (`docs: lock phase N <topic> contract`).
2. Implement in small commits. After each: `git add -A`, `nix fmt .`,
   `nix flake check --show-trace`.
3. For every new assertion write one positive and one negative nix-unit
   test. Negative tests use the existing helper pattern
   `failedAssertion = config: needle: lib.any (item: !item.assertion && lib.hasInfix needle item.message) config.assertions;`
   and match a stable part of the message.
4. Run the affected VM suites through `nix run .#vm-test`. Cite each
   suite's marker and log number in the PR.
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
- **Remove redundant `builtins.` prefixes** (nixf-diagnose
  `sema-primop-removed-prefix`).
- **Collision checks need both directions and every namespace:** same
  host, across instances, and against kernel/Cilium reserved values
  (`ip.reservedPolicyTables` = `{0,200,201,253,254,255,2004,2005}`).
- **`ifstatecli check` exit status is not a diff signal.** It reports
  parser/execution failures only; assert "clean" by parsing its output.
- **The `vm-tests` and `clanservices` skills describe the home repo's
  layout** (auto-discovered `vm-tests/*.nix`, sm/md/lg variants,
  `clanServices/` registration). Here, suites register in
  `services/<name>/flake-module.nix` under `clan.nixosTests.<suite>` and
  services are auto-discovered by `services/flake-module.nix`. Follow the
  skills' patterns, not their paths.
- **Hostnames are not resolved at eval.** Literal checks apply to IP
  literals; a hostname gets a warning, not an error.

## Rules (AGENTS.md)

- Amend SPEC.md and `documentation/` together before changing code.
- `git add` new files before any Nix eval.
- Format with alejandra (`nix fmt`); keep statix and deadnix clean.
- `nix flake check --show-trace` must pass (`checks` is static only).
- VM suites live only under `legacyPackages.<system>.vmTests`. Every VM
  run's log goes to `.baton-pass/vm-logs/<suite>/logs-<n>`; `.baton-pass/`
  is gitignored and never committed.
- Breaking changes carry no compatibility burden: no migration shims,
  deprecation aliases, or renamed-option warnings.
- Keep `targetHost` on the underlay address, never a fabric, transfer, or
  tunnel address.
- One branch, one PR, do not merge.

## Pull request shape

Match PRs #2 and #3:

- **Summary:** a short tree or diff block of what moved, then bullets.
- **Evidence:** the exact commands, the suites with marker and
  `logs-<n>`, and at least one *Before → After* pair for each bug you fixed.
- **Merge Danger:** door (one-way or two-way) and blast radius.

State anything you could not run (no KVM, no network, no credentials) and
why. Never claim a suite passed without its log.
