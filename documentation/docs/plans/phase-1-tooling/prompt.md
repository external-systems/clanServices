# Phase 1: tooling and flake inputs

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the block below into a fresh agent session.

```text
Repo: external-systems/clanServices. Read AGENTS.md, flake.nix, formatter.nix, tests/flake-module.nix, documentation/module.nix and documentation/docs/plans/data-plane-hardening.md ("Flake inputs"). Load skills: flakeparts, nix-style, vm-tests.

Goal: one formatter (alejandra), a leaner input graph, and a standard place for VM logs. No service behavior changes.

Do:
1. formatter.nix: replace nixfmt with alejandra in treefmt-nix; add statix and deadnix; keep shellcheck and sizelint. Reformat the whole tree in its own commit ("treewide: alejandra") so later diffs stay readable.
2. flake.nix: remove the unused nix-github-actions input. Replace pkgs.treefmt in the devShell with the treefmt-nix wrapper (config.treefmt.build.wrapper).
3. Move dev-only inputs (nix-unit, presenting) into a flake-parts partition with its own dev/flake.nix and lock; route checks, formatter, documentation, slides and the nix-unit wiring through partitionedAttrs. Keep the transitive-override block that nix-unit needs, now inside the partition. Confirm with `nix flake metadata` from a throwaway consumer flake that the dev inputs no longer appear in its lock.
4. Re-check whether the data-mesher/disko/nix-darwin/nix-select/sops-nix/systems follows are still required after the move; drop any that are not.
5. Add an app (apps.<system>.vm-test) that builds legacyPackages.<system>.vmTests.<suite> and writes the build log to .baton-pass/vm-logs/<suite>/logs-<n>, picking the next free n. Document it in documentation/docs/reference/testing.md.
6. Run nix flake check --show-trace and one small VM suite through the new app; report both.

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
