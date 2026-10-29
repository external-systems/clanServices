# Phase 3: allocation with clan vars

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the block below into a fresh agent session.

```text
Repo: external-systems/clanServices. Read AGENTS.md, SPEC.md (§6.3, D47, D51, D59) and documentation/docs/plans/data-plane-hardening.md ("Allocation with clan vars"). Load skills: clanservices, clan-core, nix-style.

Goal: replace name-hash derivation with allocate-once clan vars.

Do:
1. Shared generator routed-fabric-<inst>-prefixes: random ULA /48, loopback pool 198.18.0.0/16, transfer pool 198.19.0.0/16 (pools overridable by settings). Assert the pools are disjoint from every declared underlay prefix.
2. Per-machine generator routed-fabric-<inst>-node: ipv4, ipv6 and asn picked at random inside the pools; one shared generator per adjacency (sorted pair) for the port and the transfer /31 + /127. All files public. Ports avoid the kernel ephemeral range.
3. The same per-machine scheme for wireguard-mesh addresses.
4. Existing ipv4/ipv6/port settings remain explicit overrides. Delete the hash functions outright (no shims).
5. Eval assertions for duplicates name the exact `clan vars generate <machine> --generator <g> --regenerate` command.
6. Regenerate committed fixture vars for every suite; add eval tests for the collision and missing-var messages. Re-run every registered VM suite and report pass/fail per suite.

Rules (AGENTS.md):
- Amend SPEC.md and documentation/ together before changing code.
- git add new files before any Nix eval.
- Format with alejandra (nix fmt); keep statix and deadnix clean.
- nix flake check --show-trace must pass (checks is static-only).
- VM suites live only under legacyPackages.<system>.vmTests. Save every VM run's log to .baton-pass/vm-logs/<suite>/logs-<n> (n = 0, 1, ...); .baton-pass/ is gitignored and never committed.
- Breaking changes carry no compatibility burden: no migration shims or deprecation aliases.
- Keep targetHost on the underlay address, never a fabric or tunnel address.
- One branch, one PR, do not merge.
```
