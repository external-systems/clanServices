# Phase 7: gateway, single NAT egress and floating IPs

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the block below into a fresh agent session.

```text
Repo: external-systems/clanServices. Read SPEC.md D8/D51/D56 and documentation/docs/plans/data-plane-hardening.md ("Home edge router", "NAT egress and floating IPs"). Load skills: clanservices, ifstate, frr.

Goal: NixOS can be the single home NAT gateway, and floating IPs coexist with clanServices networking.

Do:
1. Amend SPEC.md first: a border egress mode for ONE NAT gateway (default route offered only to opted-in leaves, WireGuard endpoint traffic always via the underlay); HA NAT and floating-IP movement are explicitly out of scope (a supporting NixOS module or Kubernetes operator moves floating IPs; HA NAT is a live-migratable gateway VM or state sync outside clanServices).
2. Implement the egress mode in routed-fabric with eval assertions (opt-in only, default route accepted only from the egress border).
3. A new gateway clanService in this repo: LAN addressing from the netif-delegated prefix, DHCPv4 + RA server, local resolver, NAT44, nftables zones and port forwards.
4. netif floating addresses: declare the address and candidate hosts; render an IfState-created interface whose addresses IfState never strips; firewall and fabric treat the address as present-when-held. No cloud API code.
5. VM scenarios 16 (single NAT gateway), 20 (home edge router with an ISP emulator: DHCPv4, DHCPv6-PD, RA; prefix change; reboot) and 21 (floating IP coexistence with a stub mover).

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
