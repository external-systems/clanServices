# Phase 9: Proxmox, breadth and home rehearsal

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the block below into a fresh agent session.

```text
Repos: external-systems/clanServices and external-systems/home. Read documentation/docs/plans/data-plane-hardening.md (Proxmox, synthetic inventories, phases).

Goal: Proxmox as a deploy target, plus breadth.

Do:
1. tf/modules/proxmox-node.nix (terranix) with the bpg/proxmox provider: guests with tf-set MACs on a VLAN-aware bridge, facts emitted like the clouds; an env for proxmox-lab against the operator's host (credentials from env, never committed).
2. fleet-100 eval benchmark (eval time, FRR config size) recorded in the plan file.
3. Home fleet rehearsal: in the home repo, a branch that moves the current machines plus the planned servers, router and cloud VMs onto netif + routed-fabric, with every targetHost on the underlay; evaluated, not deployed.
4. Remaining scenarios (3, 5, 7, 10, 11, 12, 14) as time allows, each in its own commit.

One PR per repo, do not merge. In each repo:

Rules (AGENTS.md):
- Amend SPEC.md and documentation/ together before changing code.
- git add new files before any Nix eval.
- Format with alejandra (nix fmt); keep statix and deadnix clean.
- nix flake check --show-trace must pass (checks is static-only).
- VM suites live only under legacyPackages.<system>.vmTests. Save every VM run's log to .baton-pass/vm-logs/<suite>/logs-<n> (n = 0, 1, ...); .baton-pass/ is gitignored and never committed.
- Breaking changes carry no compatibility burden: no migration shims or deprecation aliases.
- Keep targetHost on the underlay address, never a fabric or tunnel address.
```
