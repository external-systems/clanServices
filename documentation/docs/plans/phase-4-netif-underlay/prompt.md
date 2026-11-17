# Phase 4: netif underlay features (netif phase P3b)

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Hardening phase 4 is netif phase P3b of the [netif plan](../../netif/plan.md).
Its first half, `match.mac` and the loud missing-NIC check, shipped as
P3a (PR #12). Paste the block below into a fresh agent session.

```text
Repo: external-systems/clanServices. Touch external-systems/pkgs only if the IfState or dhcpcd packaging itself needs a change, in its own PR.

Read first, in this order:
1. AGENTS.md, then documentation/docs/plans/agent-brief.md.
2. specs/netif.md: the round proof-solo, proof, use-cases and P3b-spec summaries at the top; §1.1; N8, N9, N10, N16, N17, N18, N19, N21, N26; invariants 5, 11–13 and 15 in §4; §5 drift; §7 testing; §8.1 to §8.3 (the 2026-11-16 probes); §9 P3b row. This file is the contract. SPEC.md invariant 21 and round 28 point at it.
3. services/netif/default.nix: `linkOptions`, `resolveLinks`, `mkIfstateBase`, `dhcpHookScript`, `parameters.ignore.routes`, the `nameservers` and `trustedInterfaces` wiring, the exports, and the perMachine DNS conflict check.
4. services/netif/netif-interface.nix (the export schema; no version bump, N14), lib/ifstate.nix, lib/ownership.nix.
5. services/routed-fabric/default.nix `mtuFromSources`/`underlayMtuOf`, services/wireguard-mesh/default.nix `mtu` (fixed 1420): the pathMtu consumers.
6. services/netif/tests/vm/{default,dhcp}.nix, tests/ifstate-vm.nix, services/netif/tests/eval-tests.nix.

Load skills: external-systems, clanservices, ifstate, nix-style, frr (only for routed-fabric MTU).

Goal: phase P3b of specs/netif.md, nothing more. Implement N9 (the netif DNS unit), N16, N17, N18 (netif's own metrics only; Wi-Fi and the dock are N2), N19, N21, N26 and the N10 zone seam, plus the §5 drift fixes.

Do, in this order. specs/netif.md §9 slices P3b into five parts, each its own branch and PR with a green suite: slice 1 is steps 0–3 and the no-op helper of step 9, slice 2 is step 4, slice 3 is step 5 and the generation-switch test, slice 4 is step 7 and the zone half of step 8, slice 5 is step 6 and `match.path`. Read specs/netif.md §11 first: it lists the decisions with weak proof and the hardening candidates H1–H12. Ask the owner which candidates to adopt before slice 1; H1, H2, H4, H8 and H10 belong to it.
0. `nix flake update org-pkgs`, then `sync-locks`. The lock then has `pkgs.dhcpcd_latest`, upstream dhcpcd 10.5.2 (pkgs PR 43). Change netif's hook from `pkgs.dhcpcd` to `pkgs.dhcpcd_latest`. Never point the stock NixOS `dhcpcd.service` at it: 10.5 dies there until nixpkgs PR 562813 (specs/netif.md N16, N30). Run every suite once: `vm-test --all --remote --rebuild --quiet`.
1. Start with dhcpcd (N16, N30), in netif-dhcp, before writing the renderer. The 2026-11-16 solo runs (specs/netif.md §8.3; `.baton-pass/netif-probes/dns.nix` and `run-dhcpcd.nix` if present) settled:
   - dhcpcd 10.3.2 loses DHCPv4 or DHCPv6 after a carrier change (`eloop_event_add: No such file or directory`). `pkgs.dhcpcd_latest` (upstream 10.5.2) has the fix. After step 0, add the base assertion of N30 (netif's dhcpcd is 10.5.0 or newer). In 10.5 a released lease runs the hook with reason `RELEASE`, not `STOP`: handle both. Prefix delegation is not yet proven on 10.5.2: the delegation assertions of netif-dhcp are the proof.
   - Render `ipv4only` for dhcpcd on links without DHCPv6; assert `addr_gen_mode` 0 there.
   - No router-solicitation helper and no dhcpcd RA handling: both are closed in N16.
   - Give netif-dhcp's RA-sending server `net.ipv6.conf.all.forwarding = 1` (§7), then assert: a real carrier loss (QEMU `set_link`, `machine.send_monitor_command`) and five `ip link set down`/`up` cycles, each followed by DHCPv4, DHCPv6, their DNS and the RA default back, with no `eloop_event_add` line in the journal.
   Then build the netif DNS unit as probed (N9 "Rough design"): one idempotent writer script, called by a link watcher, by dhcpcd's exit script (set with `script`, which also switches every stock hook off) and by `ifstate.service`; the unit is `PartOf` systemd-resolved. It passed boot, reapply, link down/up, a resolved restart and a lease renewal with changed servers. Earlier facts that still hold (§8.1): dhcpcd with `noipv6rs` runs `ia_na` and `ia_pd`; the link hook writes `ra_defrtr_metric` (N18).
2. Anchor every single-link route ignore and the hook's dhcpcd lookup (N8, N16).
3. dhcpcd per-link config (`noipv6rs`, `noipv4ll`, every stock hook off, one netif exit hook for DNS) and PD settings with their eval errors; PD exported as a runtime fact (N16).
4. Per-link DNS through resolved by `netif-dns.service`; remove `networking.nameservers` and the cross-instance DNS conflict check; the base enables resolved (N9).
5. Default-route metric 100 for both families on every netif default (N18). `defaultRoute` per link and family, `nogateway` and `accept_ra_defrtr = 0` when off, and RA sources in the one-default check (N21).
6. `pathMtu` with its bounds, the export fields, the consumers' order in routed-fabric and wireguard-mesh, the DHCP-without-MTU warning (N17).
7. Firewall untrusted by default (N19). Run every suite; a service that relied on netif trust opens its own ports. If one needs a new firewall ownership model, STOP and ask.
8. Zone option, the read-only `clanServices.networking.links` option, facts and export fields (N10). `match.path` (a udev `.link` rename by `ID_PATH`, not IfState `identify`) and the cloud-init eval error (N26).
9. Tests: eval tests positive and negative for every new option and error; the shared no-op helper (§7) used by netif, netif-dhcp and netif-registry; netif's live reconfiguration by generation switch; netif-dhcp extended per §7 with its markers.
10. Amend specs/netif.md statuses (planned → implemented/VM-proven with markers), SPEC.md round, documentation/docs/netif/ and services/netif.md together.

Verify: `git add -A`, `fmt`, `check`; `vm-test --check <suite>` then `vm-test <suite> --remote --quiet` for netif, netif-dhcp, netif-match, netif-registry, routed-fabric, wireguard-mesh while iterating; finally `vm-test --all --remote --rebuild --quiet`. Report every marker.

Pitfalls:
- QEMU NIC MACs are deterministic; read them from the node, never guess.
- dhcpcd started by the hook must survive `ifstatecli apply` (KillMode=process in the base); never add a second DHCP owner (no networking.dhcpcd, no systemd-networkd).
- `ifstatecli check` exits 0 when it proposes changes; parse output (§7).
- `systemctl show -p Result` is "success" for a unit that never ran; wait on ExecMainExitTimestampMonotonic first.
- The hook runs as root with IFS_* variables; quote everything (shellcheck runs through treefmt).
- PD is runtime state: never put a prefix literal in eval, exports or facts.

Out of scope: containers and VM hosts (phase P7); NetworkManager, Wi-Fi and dock metrics (phase P2); modes (phase P4); the lockout guard (phase P8); the router module and netif-router (phase P5); the gateway (hardening phase 7).

Rules: see agent-brief.md "Rules". One branch, one PR; merge only with the owner's per-session approval.
```
