# Phase 4: netif underlay features

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the block below into a fresh agent session.

```text
Repos: external-systems/clanServices (and external-systems/pkgs only if IfState or dhcpcd packaging needs a change). Read AGENTS.md, SPEC.md D50/D53/D61 and documentation/docs/plans/data-plane-hardening.md (netif findings, "Home edge router"). Load skills: ifstate, clanservices, nix-style.

Goal: netif can describe real cloud, Proxmox and home-router underlays.

Do:
1. Add links.<name>.match.mac, rendered with IfState's permanent-address identification (check the 2.5.1 schema for the exact key); `interface` and `match.mac` are mutually exclusive for physical links.
2. DHCPv6 address + prefix delegation in the per-link dhcpcd hook (ia_pd), with the delegated prefix exposed as a declared-dynamic fact (never an invented address).
3. A per-link pathMtu override, exported so routed-fabric and wireguard-mesh use it instead of assuming 1500 on DHCP links (invariant 21).
4. Eval tests for each; extend the netif DHCP VM suite to cover DHCPv6, PD and an RA-only link on a forwarding machine.

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
