# Phase 4: netif underlay features (netif phase N3b)

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Hardening phase 4 is netif phase N3b of the [netif plan](../../netif/plan.md).
Its first half, `match.mac` and the loud missing-NIC check, shipped as
N3a (PR #12). Paste the block below into a fresh agent session.

```text
Repo: external-systems/clanServices. Touch external-systems/pkgs only if the IfState or dhcpcd packaging itself needs a change, in its own PR.

Read first, in this order:
1. AGENTS.md, then documentation/docs/plans/agent-brief.md.
2. specs/netif.md: the round N3b-spec summary at the top; N8, N9, N10, N16, N17, N18, N19; invariants 5 and 11–13 in §4; §5 drift; §7 testing; §9 N3b row. This file is the contract. SPEC.md invariant 21 and round 28 point at it.
3. services/netif/default.nix: `linkOptions`, `resolveLinks`, `mkIfstateBase`, `dhcpHookScript`, `parameters.ignore.routes`, the `nameservers` and `trustedInterfaces` wiring, the exports, and the perMachine DNS conflict check.
4. services/netif/netif-interface.nix (the export schema, moving to schemaVersion 2), lib/ifstate.nix, lib/ownership.nix.
5. services/routed-fabric/default.nix `mtuFromSources`/`underlayMtuOf`, services/wireguard-mesh/default.nix `mtu` (fixed 1420): the pathMtu consumers.
6. services/netif/tests/vm/{default,dhcp}.nix, tests/ifstate-vm.nix, services/netif/tests/eval-tests.nix.

Load skills: external-systems, clanservices, ifstate, nix-style, frr (only for routed-fabric MTU).

Goal: phase N3b of specs/netif.md, nothing more. Implement N16, N17, N18 (netif's own metrics only; Wi-Fi and the dock are N2), N19, N9 and the N10 zone seam, plus the §5 drift fixes.

Do, in this order (one branch, one PR):
1. Probe first, in netif-dhcp, before writing the renderer:
   a. dhcpcd with `-f <per-link conf>` and `noipv6rs` still runs DHCPv6 (`ia_na`) and prefix delegation (`ia_pd`) against a delegating server (kea DHCPv6 with a /56 PD pool in the server node);
   b. dhcpcd's resolvconf hook lands per-link DNS in systemd-resolved (`resolvectl dns <if>`);
   c. a per-link `resolvectl dns/domain` set by an IfState hook survives a reapply and a link down/up;
   d. the kernel has `ra_defrtr_metric` and IfState sets it as a per-link sysctl.
   If a, b, c or d fails, STOP and ask the owner: the spec names these as verification gates.
2. Anchor every single-link route ignore and the hook's dhcpcd lookup (N8, N16).
3. dhcpcd per-link config and PD settings with their eval errors; PD exported as a runtime fact (N16).
4. Per-link DNS through resolved; remove `networking.nameservers` and the cross-instance DNS conflict check; the base enables resolved (N9).
5. Default-route metric 100 for both families on every netif default (N18).
6. `pathMtu` with its bounds, the export fields, the consumers' order in routed-fabric and wireguard-mesh, the DHCP-without-MTU warning (N17).
7. Firewall untrusted by default (N19). Run every suite; a service that relied on netif trust opens its own ports. If one needs a new firewall ownership model, STOP and ask.
8. Zone option, the read-only `clanServices.networking.links` option, facts, export schemaVersion 2 (N10).
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

Out of scope: NetworkManager, modes, Wi-Fi and dock metrics (N2); the router module and netif-router (N5); the gateway (hardening phase 7).

Rules: see agent-brief.md "Rules". One branch, one PR; merge only with the owner's per-session approval.
```
