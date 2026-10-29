# Phase 6: internet harness and priority scenarios

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the block below into a fresh agent session.

```text
Repo: external-systems/clanServices. Read documentation/docs/plans/data-plane-hardening.md ("VM test scenarios", "Proposed contract additions"). Load skills: vm-tests, ifstate, frr, clanservices.

Goal: a reusable internet harness and the first scenarios, each booting a tests/clans inventory.

Do:
1. tests/lib/internet.nix: a WAN router with tc netem profiles (including the Texas-Helsinki profile: 130 ms +/- 20, <= 2% loss, 1-2 s bursts), NAT routers (endpoint-independent and symmetric), cloud DHCP emulators (GCP /32 + option 121 + MTU 1460; Hetzner static /32 onlink), a public scanner, a timed probe helper and a facts.json emitter.
2. Scenarios 9 (exposure scan), 4 (SLAAC on forwarding nodes), 1 (home + Hetzner + GCP shapes), 2 (NAT pair), 6 (WAN soak: zero flaps and zero FIB changes for 30 minutes), 8 (live change via a specialisation switch with a live SSH loop to targetHost), 13 (wireguard-mesh NAT), 19 (match.mac) and 22 (Proxmox guest shape; never Proxmox VE inside the VM). Each prints a unique *_OK marker.
3. Measure C1 with the probe helper, never sleep: zero flaps under the WAN profile, withdrawal <= 15 s on WAN and <= 3 s on same-site adjacencies, hold-down respected on recovery.
4. Stay within the CI box: <= 30 GiB total, routing-only VMs at 1 GiB.
5. Update SPEC.md §7 so each claim names its test file and marker. Run each suite sandboxed through the vm-test app and report.

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
