# Phase 9: Proxmox, breadth and home rehearsal

Part of the [data-plane hardening plan](../data-plane-hardening.md).
The three parts are independent; paste each block into its own fresh agent
session. 9c needs Andrew at the keyboard for one step.

## 9a: Proxmox target and the fleet-100 benchmark

```text
Repo: external-systems/clanServices (main includes phases 1–8).

Read first: documentation/docs/plans/agent-brief.md; AGENTS.md; documentation/docs/plans/data-plane-hardening.md ("OpenTofu workflow", "Synthetic inventories" proxmox-lab and fleet-100, scenario 22); tf/ and the tf-run/tf-janitor apps from phase 8; documentation/docs/guides/cloud-runs.md; tests/clans/proxmox-lab and tests/clans/fleet-100.

Load skills: terranix (references/providers.md "Proxmox VE"), clan-core, disko, nix-style.

Do:
1. tf/modules/proxmox-node.nix with the bpg/proxmox provider (check the nixpkgs attribute for `withPlugins`): guests with tf-chosen MACs on a VLAN-aware bridge, cloud-init or an ISO boot that nixos-anywhere can reach, and `output.facts` in the phase-5 schema (MACs are the tf-chosen ones; `match.mac` in the materialized inventory uses them).
2. tf/envs/proxmox-lab.nix plus a tf-validate check. The run uses PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN from env against the operator's host; the state key and expiry labels follow phase 8 (Proxmox tags for run-id and expires). The janitor learns to delete expired Proxmox guests.
3. If credentials are present, run `nix run .#tf-run -- proxmox-lab` once and report; if not, stop after validation and list what the operator must export.
4. fleet-100 benchmark, recorded in the plan file under a new "Benchmarks" section: wall time and peak RSS of `nix eval` for one leaf toplevel drvPath and one spine (use `/usr/bin/time -v` or `command time -v`), the size in bytes and line count of a spine's rendered FRR config, adjacency count, and the number of allocation-collision regenerate rounds it took in phase 5. Run each measurement three times and report the median.

Rules: see agent-brief.md "Rules". Never commit run output. One branch, one PR, do not merge.
```

## 9b: remaining scenarios

```text
Repo: external-systems/clanServices (main includes phases 1–8).

Read first: documentation/docs/plans/agent-brief.md; AGENTS.md; documentation/docs/plans/data-plane-hardening.md "VM test scenarios"; the phase-6 harness tests/lib/internet.nix and two existing scenarios as templates.

Load skills: vm-tests, frr, ifstate, cilium (scenario 12), clanservices.

Do, one scenario per commit, cheapest first, each with a unique SCENARIO_<n>_<NAME>_OK marker and an entry in SPEC.md §7:
- 3 address-family split: the af-split-negative eval failure is linked; the positive af-split clan boots and the v4-only leaf reaches the v6-only spine only through the dual-stack spine.
- 11 two fabrics on one site: no reachability between instances (S2), proven by negative pings and absent routes.
- 10 border + upstream + source return: ingress to an owned prefix through the border, symmetric return through the source-return table, upstream prefix filtering both ways.
- 14 underlay renumbering: change a node's public endpoint (facts → materialize → switch) and prove re-handshake without manual steps.
- 12 pod to fabric member: a pod reaches a non-Kubernetes fabric member; the masquerade source is the node's fabric loopback and the reply path is symmetric.
- 7 spine failure matrix: link down, VM crash, partition, reboot (C1 withdrawal budgets, C3 identical RIB/FIB after reboot, compared after DelayOpen recovery).
- 5 cloud DHCP fidelity: /32 + option 121, DHCPv6, and the DHCP MTU reaching the WireGuard MTU (U4).
Stop when time runs out; say which scenarios remain.

Rules: see agent-brief.md "Rules". One branch, one PR, do not merge.
```

## 9c: home fleet rehearsal

```text
Repos: external-systems/home (work here) and external-systems/clanServices (read only).

Read first: home's AGENTS.md completely. It differs from clanServices: agents never deploy, never run `clan vars generate` or `clan vars set` (human only), and run only cheap checks locally (`nix build .#checks.x86_64-linux.lint -L` plus the lightest targeted eval). Then home's inventory.nix, flake.nix, clanServices/ (the machine-type and tags services), machines/*/; then clanServices' services/netif/README.md, services/routed-fabric/README.md, and documentation/docs/plans/data-plane-hardening.md "Home edge router".

Load skills: clan-core, clanservices, ifstate, frr, flakeparts, import-tree, lib, nix-style.

Goal: a branch in home that moves today's machines (nixos, kamrui-h1, ghost, hp-notebook, beelink) plus the planned servers, home router, and cloud VMs onto netif + routed-fabric, with every targetHost on the underlay. Evaluated, not deployed.

Do:
1. Add clanServices as an input of home (follow home's nixpkgs/clan-core rules in its AGENTS.md); keep clan-community where it is still used.
2. netif instances per site (home LAN, and one per planned cloud provider) and one routed-fabric instance; planned machines enter inventory.nix with a comment marking them planned. Use `match.mac` only where the MAC is known; otherwise `interface`.
3. targetHost stays on underlay addresses or LAN hostnames (today `root@<name>`); the phase-2 assertion must stay green.
4. Allocation vars: routed-fabric and wireguard-mesh now read allocated vars at eval, and agents may not generate vars in home. Write the exact `clan vars generate <machine>` command list for Andrew in the PR description and stop there; evaluate machines only after he has run it and pushed the vars. Do not pin addresses by hand to get around this.
5. After Andrew's vars land: evaluate each machine's toplevel drvPath (not a full build) and the lint check; report any assertion that fires as a finding, not as a reason to weaken settings.

Rules: home's AGENTS.md rules apply in home. Never deploy. One branch, one PR, do not merge.
```
