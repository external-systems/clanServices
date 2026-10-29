# Phase 5: facts schema, materializer and synthetic clans

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the block below into a fresh agent session.

```text
Repo: external-systems/clanServices. Read documentation/docs/plans/data-plane-hardening.md ("Synthetic inventories", "OpenTofu workflow"). Load skills: clan-core, clanservices, nix-style.

Goal: the underlay facts contract and the synthetic clans exist and evaluate; no VMs yet.

Do:
1. Define the underlay facts schema as Nix option types under lib/, plus a generated JSON schema output.
2. Write a pure materializer: (literal inventory, facts.json) -> full literal inventory attrset, and an app that writes it as an alejandra-formatted inventory.nix outside the git tree.
3. Create tests/clans/<name>/ for triad, nat-pair, af-split, edge-isp, two-fabrics, home-edge, floating-ip, arm-mix, proxmox-lab and fleet-100: a literal inventory.nix (no generators), a README, committed vars/ and expected.json. targetHost is always an underlay address.
4. Eval tests: every clan evaluates (af-split's negative variant must fail with the expected message); expected.json adjacency counts match the derived graph; materializer round-trip test.

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
