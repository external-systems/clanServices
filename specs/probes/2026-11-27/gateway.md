# Gateway probes: findings (2026-11-27)

Probe engineer for `specs/design-gateway.md`. Worktree
`~/external-systems/.worktrees/clanServices/probe-gateway`, detached at
`origin/main` `deeaba4`, nothing committed.

- `prototype.patch`: `git diff --cached origin/main` at the end. It holds
  the hostile suites, `patches/fixes-fabric-kube.patch` (the consumers of
  `fabricInside`), the gateway prototype (design steps 1 to 6, without
  3.9 c, d and f point 2) and the amended `specs/design-gateway.md`.
- `runs/`: the `FINDING`, `HOSTILE`, `subtest`, `*_OK` and `!!!` lines of
  every run, in order. `queue-<suite>.out` beside them: the runner's
  output of the last run of that suite.
- Versions in every run: kernel 6.18, Jool 4.1.15, IfState 2.5.1.
- The final tree (`prototype.patch`) passed, each in its last run: `nat-gateway` (04), `nat-gateway-hostile` (04), `nat-gateway-kube` (04), `nat-gateway-failover` (05), `router` (06), `k3s-clat` (07), `hostile-router` (08), `router-kube` (09). The runs before a later edit of `router.nix`, `router-prefix.py` or a router suite (04, 05 of the nat-gateway suites) do not build those files into their machines.
- Not run: `check` (nix-unit, coverage), `vm-test --all`, `rke2-clat`,
  `k3s-clat-mapped`, anything of remote-builder (owner-gated, O8).
  `fmt` was run on the edited files.

## Runs

| File in `runs/` | Suite | Result | What it was |
|---|---|---|---|
| `01-nat-gateway.first-core.FAILED-negative-proof.txt` | `nat-gateway` | FAILED at one subtest | first boot of the core. Every assertion of the basic phase passed. The suite's old negative proof failed: with the allowlist chain emptied the answer is still dropped (`nat64-return-undeclared`). A finding, then a test fix |
| `02-nat-gateway.core.PASSED.txt` | `nat-gateway` | passed (506 s) | the core, guard leftover printed only |
| `03-nat-gateway-hostile.core.one-test-bug-N06-layer.txt` | `nat-gateway-hostile` | FAILED on one verdict | 40 SAFE, 1 GAP that was a test bug (an emptied `to_clat` ends at `clat-forward`, the packet never reached the guard). Holds the P2 probe lines |
| `04-nat-gateway.PASSED.txt` | `nat-gateway` | passed (611 s) | final core: forwarding 0 in the namespaces, link chatter counted apart, guard counters asserted 0 |
| `04-nat-gateway-hostile.PASSED.txt` | `nat-gateway-hostile` | passed (729 s) | 41 SAFE, 0 GAP |
| `04-k3s-clat.PASSED.txt` | `k3s-clat` | passed (792 s) | CLAT hosts that are kube nodes (alpha a fabric spine, beta a leaf) with `inet clat`, O7, the CLAT guard |
| `04-nat-gateway-kube.PASSED.txt` | `nat-gateway-kube` | passed (304 s) | a gateway that is a kube node |
| `04-hostile-router.FAILED.txt` | `hostile-router` | did not boot | the test driver's type check refused two `re.search(...).group` lines of the new phases. Fixed |
| `04-router.PASSED.txt` | `router` | passed (410 s) | one renderer for both firewalls, the ICMP type list, redirect sysctls, hook validation and sandbox, `ifstate` after `nftables` |
| `04-router-kube.PASSED.txt` | `router-kube` | passed (351 s) | `zones.home.fabric = true` in place of `unzoned.zones` |
| `05-hostile-router.FAILED.txt` | `hostile-router` | FAILED | R17, R19 SAFE; **R20 GAP: 200 of 200 flood pings answered** (the echo limit sat behind `ct state established`): a design finding. R18 timed out on a test bug (a prefix with host bits set was skipped without a journal line) |
| `06-hostile-router.FAILED.txt` | `hostile-router` | FAILED on one verdict | R20 SAFE with the limit ahead of conntrack (69 of 200). R18's sets were right, its reachability check failed because the test had stopped the DHCP client (a test bug). Holds the P5 lines |
| `06-router.PASSED.txt` | `router` | passed (394 s) | the router suite again with the echo limit ahead of conntrack and the hook's new journal line |
| `09-router-kube.PASSED.txt` | `router-kube` | passed (333 s) | again on the final tree (the echo limit moved after run 04) |
| `08-hostile-router.PASSED.txt` | `hostile-router` | passed (1068 s) | 36 SAFE, 0 GAP. R15 with a working rogue radvd and a control (the session lead's finding), R17 to R20, P5 |
| `05-k3s-clat.FAILED.txt` | `k3s-clat` | FAILED on a new assertion | the test's own bug: it asserted that no Jool counter moved, and the health check's pings moved them. Replaced by "Jool holds no TCP session to the private address" |
| `07-k3s-clat.PASSED.txt` | `k3s-clat` | passed (660 s) | the suite with one more subtest that prints the CLAT table's counters on the nodes |
| `05-nat-gateway-failover.*.txt` | `nat-gateway-failover` | passed (2299 s) | every failover phase on the prototype |

## Probes of design §9

| ID | Question | Result | Suite | Log lines |
|---|---|---|---|---|
| P1 | Does `ip6 daddr & ::ffff:ffff @private6` load and match? | VERIFIED-VM | `nat-gateway`, `nat-gateway-hostile` | builds pass NixOS's `nft --check`; `HOSTILE SAFE N05 every private destination was refused while the packet was IPv6: … {'nat64-private': 16, 'nat64-private-post': 0, 'nat64-host': 10}, guard {…'guard-leftover': 0, … 'guard-leaving': 0}`; `HOSTILE SAFE C01 … clat-private-source +1, let through: 0` (the `ip6 saddr` form) |
| P2 | Does Jool translate with `forwarding=0` in its namespace? | VERIFIED-VM, NAT64 and SIIT. Built in afterwards | `nat-gateway-hostile` (run 03), then `nat-gateway` (run 04) | `FINDING P2 NAT64 with forwarding=0 in the namespace (both families): {'page': True, 'ping': True, 'udp': True, 'udp 3000 bytes (fragments)': True, '2 MB download': True}; guard {'guard-noise-in': 0, 'guard-leftover': 0, 'guard-noise-out': 2, 'guard-leaving': 0}`; the same line for `SIIT (CLAT)`. Run 04 asserts both sysctls are 0 and passes every shape and path MTU discovery |
| P3 | What does Jool do with a new flow on a full pool4? | VERIFIED-VM: drops it itself, no error, no hand-back | `nat-gateway-hostile` | `FINDING P3 a full pool4 (10 UDP ports) and 300 new flows: 300 packets crossed towards the translator; Jool counters that moved: {'JSTAT_RECEIVED6': 316, 'JSTAT_RECEIVED4': 18, 'JSTAT_SUCCESS': 44, 'JSTAT_BIB_ENTRIES': 10, 'JSTAT_SESSIONS': 10, 'JSTAT_BIB6_NOT_FOUND': 290}; guard … 'guard-leftover': 0 … -> … 'guard-leftover': 0 …; ICMPv6 errors back to the client: 0`; `HOSTILE SAFE N16 …` |
| P4 | Beacon inside pool6 by DNAT on a kube gateway | NOT-RUN | | step 8 was out of reach of this round |
| P5 | A moment at boot with links up and no tables on a router? | VERIFIED-VM: none in five boots | `hostile-router` (runs 06, 08) | `FINDING P5 boot 1: nftables.service active at 7.141 s, ifstate.service started at 7.297 s: the tables were loaded 0.156 s before the first link was configured` (boots 2 to 5: 0.096 s, 0.156 s, 0.109 s, 0.143 s); `FINDING P5 ifstate.service is ordered after: ['network-pre.target', 'nftables.service', 'system.slice', 'systemd-journald.socket', 'systemd-sysctl.service', 'systemd-sysusers.service']`. `systemd-sysctl` finishes about 1.7 s before the tables load, with no link configured |
| P6 | Do the guard's chains see exactly what Jool hands back; do PMTUD, fragments, Jool's ICMP errors pass? | VERIFIED-VM | `nat-gateway` (run 04) | `FINDING P6 gw1 nat64 guard counters after every protocol from both tiers and a 2 MB download: {'guard-noise-in': 18, 'guard-leftover': 0, 'guard-noise-out': 8, 'guard-leaving': 0}` (the same for gw2, client, trusted); `FINDING P6 gw1 guard after fragments and path MTU discovery: {… 'guard-leftover': 0, … 'guard-leaving': 0}; Jool's own ICMPv6 errors forwarded: 0`; `… after the rate limit floods: {… 'guard-leftover': 0 … 'guard-leaving': 0}`; `HOSTILE SAFE N10 … Jool handed 1 packet of the client back to the kernel; 0 packets left the namespace behind the guard; guard-leftover +4 (with the health check's pings)`; `HOSTILE SAFE C06 … sent 1, came back 0, guard-leftover +1` |

## Assumptions of the design's table

| Claim | Result | Suite and lines |
|---|---|---|
| Untranslatable and "no instance" go back to the kernel | VERIFIED-VM | N10, C06 (above) |
| Translated packets pass postrouting only | VERIFIED-VM | P6 |
| Jool's own ICMP errors pass the guard | NOT-RUN | no shape made Jool send one (`nat64-jool-error` 0 in every run). PMTUD works by translated errors |
| nft rulesets are per namespace; a host firewall restart leaves the guard | VERIFIED-VM | `nat-gateway`: `NAT_GATEWAY_GUARD_RESTARTS_OK` (JSON of `inet guard` equal across `systemctl restart nftables.service` and `systemctl restart nat64-jool.service`; an open TCP flow goes on) |
| The guard survives an IfState apply | VERIFIED-VM | `nat-gateway`: `NAT_GATEWAY_IFSTATE_OK` (gateway and client) |
| IfState 2.5.1 takes `unreachable` routes in a namespace | VERIFIED-VM | same marker (`assert_ifstate_noop`) |
| Jool global names and time format | VERIFIED-VM | the unit runs the four `global update` lines at every start in every run; `jool global update` lists the names |
| A gateway without its guard is unhealthy and withdraws | VERIFIED-VM | `HOSTILE SAFE N11 a deleted guard shows in the health state and is loaded again without an operator: health.json said guard false after 0.0 s; the guard was back 2.3 s after it was deleted; journal lines: 1`; `HOSTILE SAFE N11 a guard that is back within the down window never withdraws the beacon: health: up, bad rounds of the last 60: 12`; `HOSTILE SAFE N11 a gateway that cannot load its guard withdraws its beacon: beacon closed 29.9 s after the guard was deleted; health: state down, guard False; journal: nat64-health: 30 of the last 60 rounds bad (the namespace's guard is not loaded), beacon withdrawn`; `HOSTILE SAFE N11 the gateway advertises itself again once its guard is back and UP rounds were good: beacon back after 121.0 s` (values of run 03; run 04 repeats the verdicts) |
| Each layer alone ends a packet (host table, guard, namespace forwarding off and the unreachable route) | VERIFIED-VM | `HOSTILE SAFE N06 …` (four lines), `HOSTILE SAFE N07 …` (two lines), `HOSTILE SAFE N11 without the gateway's table and without the guard the namespace still forwards nothing …: 1 crossings of one packet` |
| The CLAT namespace needs no IPv4 default route | VERIFIED-VM | `nat-gateway` CLAT phases, `k3s-clat` |
| Conntrack on `clat0` INPUT beside Cilium (`clat-unsolicited`) | VERIFIED-VM as behaviour | `k3s-clat` passes: `K3S_CLAT_OK`. Run 07: `FINDING O7 alpha: forward links "cilium*", "lxc*", "rf66cac445797bf"; table inet clat counters {'clat-forward': 0, 'clat-not-address': 0, 'clat-foreign-source': 0, 'clat-private-source': 0, 'clat-spoof': 0, 'clat-not-gateway': 0, 'clat-unsolicited': 8}; CLAT guard {'guard-noise-in': 18, 'guard-leftover': 0, 'guard-noise-out': 9, 'guard-leaving': 0}` (beta the same). The 8 packets were not captured |
| O7: default-deny IPv6 forwarding on a CLAT host | VERIFIED-VM | `HOSTILE SAFE C08 a CLAT host forwards IPv6 for its CLAT only: a second link is not reachable through it, in either direction: outsider to the second link: rc=1; second link to the outsider: rc=1; clat-forward +4`; `HOSTILE INFO C08 negative proof: without table inet clat the same pings end with rc=(0, 0) …`; `HOSTILE SAFE C08 the CLAT still carries IPv4 …: the page says 198.51.100.1`; on a kube node `k3s-clat` passes |
| Private destinations are refused before translation on a cluster's gateway too | VERIFIED-VM | `k3s-clat`: `FINDING alpha: 172.20.0.1: gateway NAT64 counters that moved: {}` (four such lines), `CLAT_PRIVATE_REFUSED_OK` |
| A gateway that is a kube node works with the reworked table | VERIFIED-VM | `nat-gateway-kube`: `NAT_GATEWAY_KUBE_OK` |
| The router's ICMP type list keeps SLAAC, DHCPv6-PD, PMTUD | VERIFIED-VM | `router`: `ROUTER_LINKS_OK`, `ROUTER_RA_OK`, `ROUTER_HOOK_OK`, `ROUTER_OK` |
| The sandboxed prefix hook still does its work | VERIFIED-VM | `router`: `ROUTER_HOOK_OK` (every G22 phase) |
| `wanPorts` connect through both firewalls | VERIFIED-VM | `hostile-router`: `HOSTILE SAFE R17 a port in `wanPorts` connects from the WAN in both families (both firewalls open it); a listening port that is not in it does not: {'8443 IPv4': True, '8443 IPv6': True, '8444 IPv4': False, '8444 IPv6': False}` |
| An echo rate limit behind `ct state established` limits a flood | REFUTED | `hostile-router` run 05: `HOSTILE GAP  R20 … 200 of 200 echo requests answered`. With `limit rate over 20/second burst 40 packets … drop` ahead of the established accept: `HOSTILE SAFE R20 …: 69 of 200 echo requests answered; over the rate: … counter packets 131 …` |
| No ICMP timestamp answer, no redirects on a router | VERIFIED-VM | `HOSTILE SAFE R19 the router answers no ICMP timestamp request from the WAN: answers: ['0']; input icmp dropped +3`; `HOSTILE SAFE R19 the router accepts and sends no ICMP redirect: … ['0', '0', '0', '0']` (forged redirect packets were not sent) |
| The router takes nothing from a rogue RA on a LAN link (R15) | VERIFIED-VM, and only since run 08 | on `main`'s copy of the suite radvd never advertised (`MaxRtrAdvInterval 4` without `MinRtrAdvInterval`). Run 08: `HOSTILE INFO R15 control: the rogue advertisement reached a LAN neighbour: True; radvd: active`, `HOSTILE SAFE R15 the router takes no route or address from a router advertisement on a LAN link:`, R16 shows the neighbour's rogue default route `via fe80::5054:ff:fe12:202` and two `2001:db8:bad::` addresses |
| Rogue delegations never enter the hook's sets | VERIFIED-VM | `hostile-router` run 08: `HOSTILE SAFE R18 rogue delegations (::/0, a ULA, link-local, a /24, a /72, multicast, the well-known NAT64 prefix) never enter the router's sets; the real one stays and WAN IPv6 keeps working: inet router_svc holds ['2001:db8:1000::/60'], netdev router_src holds ['2001:db8:1000::/60']; a LAN host's IPv6 page: rc=0`; `HOSTILE INFO R18 the hook's sandbox: IPAddressDeny=::/0 0.0.0.0/0 | CapabilityBoundingSet=cap_net_admin | ProtectSystem=strict | RestrictAddressFamilies=AF_NETLINK AF_UNIX`. The test writes netif's PD file; a DHCPv6 server that delegates such prefixes was not built |
| A zone reaches pods only with `fabric = true` | VERIFIED-VM | `router-kube`: `ROUTER_KUBE_DENY_OK`, `ROUTER_KUBE_OK` |
| Failover is unchanged | VERIFIED-VM: `NAT_GATEWAY_CRASH_OK`, `NAT_GATEWAY_LOSSY_OK`, `NAT_GATEWAY_FLAPPING_OK`, `NAT_GATEWAY_LOSSY_CANDIDATE_OK`, `NAT_GATEWAY_FAILOVER_OK` | `nat-gateway-failover` |
| ICMPv6 errors from outside the gateways' /96 reach the CLAT and are translated | VERIFIED-VM for the gateway's own refusal; NOT-RUN for "packet too big" from a router on the path | `k3s-clat`: `FINDING pod on alpha to the private IPv4 address 172.20.0.1: rc=1 wget: can't connect to remote host (172.20.0.1): No route to host`, `FINDING alpha: 172.20.0.1: CLAT counters that moved: {'JSTAT_RECEIVED6': 1, 'JSTAT_RECEIVED4': 1, 'JSTAT_SUCCESS': 2}` |
| Empty PD file means "delegation lost" (netif N16) | NOT-RUN, not built | netif's area |
| remote-builder (`HostKeyAlias`, second sshd) | NOT-RUN | owner-gated (O8) |
| Linux 6.18 has no nf_tables NAT64 | NOT-RUN | |
| Throughput cost of the extra rules (R2) | NOT-RUN | |

## What the probes changed in the design

1. The guard got one more rule per chain. On every namespace `guard-leftover` read 13 to 14 from boot on (runs 01, 02), constant under traffic. It is multicast link chatter on the veth. `meta pkttype != host counter drop comment "guard-noise-in"` and `ip6 daddr ff00::/8 counter drop comment "guard-noise-out"` take it; then `guard-leftover` and `guard-leaving` are 0 and the suite asserts it.
2. Forwarding is off in both namespaces (P2). A third layer.
3. `to_clat` lets ICMPv6 errors in from any source (path MTU discovery through routers; reasoned, not run).
4. `input` of `inet nat64` accepts established packets from `jool0` in IPv6 only.
5. `nat64-return-undeclared` is a layer of its own: the suite's negative proof needs both chains emptied.
6. O7 is designed and built: `clat-forward`, fact `clan.networkFacts.forwardLinks`, option `clat.forwardLinks`.
7. "Fail fast on pool4 exhaustion" is not available from Jool (P3).
8. Health: the guard read also reports the two counters in `health.json` (`guard_dropped`).
9. Router: the echo rate limit is a `limit rate over … drop` rule ahead of the `established` accept (R20).
10. Prefix hook: a word that is not a valid prefix is skipped with a journal line too.

## Not built in the prototype

- §3.9 c (empty LAN assertion), d (`servicePrefix` alone), f point 2 (boot grace by an empty PD file; netif).
- Every nix-unit change (`check` not run). Expect `test_table`, `test_meterPer64`, `test_clientOverride`, `test_instanceLimits`, the router's input-chain texts, `test_unknownUnzoned` and the netif/k3s/rke2 tests that compare whole fact sets to need edits.
- Spec and docs amendments (`specs/gateway.md`, `documentation/docs/gateway/`, `upstream-facts.md`).
- remote-builder.
