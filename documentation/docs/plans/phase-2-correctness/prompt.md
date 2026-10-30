# Phase 2: correctness, assertions and stability

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Status: **merged** in PR #3. Kept as the record of what was asked;
later prompts build on [the agent brief](../agent-brief.md).

```text
Repo: external-systems/clanServices. Read AGENTS.md, SPEC.md (§3.2, §5, §6.3, §6.12, §7, D47–D62) and documentation/docs/plans/data-plane-hardening.md ("Findings", "Proposed contract additions"). Load skills: clanservices, ifstate, frr, nix-style.

Goal: fix the correctness findings, make each one eval-enforced, and make routes stable before fast. No new VM suites in this phase.

Do:
1. routed-fabric firewall: open TCP 179 and UDP 3784/4784 only on fabric WireGuard interfaces and from declared border upstream peers, never globally.
2. Reserve every WireGuard listen port in net.ipv4.ip_local_reserved_ports (routed-fabric and wireguard-mesh).
3. routed-fabric: assert source-return tables are never 200 and never equal a netif routingPolicy.table on the same machine.
4. Assert each adjacency has a shared address family when both endpoints are IP literals; warn when one is a hostname.
5. wireguard-mesh: reject member pairs where neither side has an endpoint; reject overlapping extraAllowedIPs between peers; reject listen-port clashes with routed-fabric on the same host.
6. netif: reject cross-instance policy table and rule-priority collisions; set ipv6 accept_ra = 2 on links of machines that forward (routed-fabric spine/border, k3s/rke2 nodes).
7. Assert that clan.core.networking.targetHost never resolves to a fabric, transfer or tunnel address.
8. Stability: per-adjacency timer profiles `site` (BFD 300 ms x3) and `wan` (BFD 1000 ms x5, BGP 10/30 s backstop) selectable in settings, `wan` the default between different sites; a hold-down before a recovered session is used again (verify FRR 10.7 options such as delay-open; document what you chose and why). maximum-prefix must not leave a session down forever.
9. Positive and negative nix-unit tests for each item. Re-run the netif, routed-fabric and k3s data-plane VM suites and report results.

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
