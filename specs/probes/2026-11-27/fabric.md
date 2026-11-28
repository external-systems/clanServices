# routed-fabric probes: findings (2026-11-27)

Worktree: `~/external-systems/.worktrees/clanServices/probe-fabric`
(detached at `origin/main` deeaba4, nothing committed, everything staged).
Code that ran: `prototype.patch` in this folder (`git diff --cached
origin/main`; apply to `main` @ deeaba4 with `git apply --index`).
Design file rewritten from these results: `specs/design-routed-fabric.md`
(inside `prototype.patch`).

Every suite ran alone on the remote builder with
`vm-test <suite> --remote --quiet --rebuild`. The verdict and FINDING
lines of a run are in `<suite>.<what>.txt` here. Result words:
**VERIFIED-VM** (a suite showed it), **REFUTED** (a suite disagreed with
the design; the design was changed), **NOT-RUN**.

## 1. Runs

Final prototype tree (the state of `prototype.patch`):

| Suite | File | Result |
|---|---|---|
| `hostile-fabric` | `hostile-fabric.run8-final.txt` | `HOSTILE_FABRIC_OK`: 58 safe, 0 gap |
| `k3s-hostile` | `k3s-hostile.run3-final.txt` | `K3S_HOSTILE_OK`: 64 safe, 0 gap; K41 is an INFO line |
| `routed-fabric` | `routed-fabric.unreachable-psk.txt` | `ROUTED_FABRIC_OK` |
| `routed-fabric-transit` | `routed-fabric-transit.unreachable-psk.txt` | `ROUTED_FABRIC_TRANSIT_OK` |
| `k3s-join` | `k3s-join.unreachable-psk.txt` | `K3S_JOIN_OK` |
| `k3s-data-plane` | `k3s-data-plane.unreachable-psk.txt` | `K3S_DATA_PLANE_OK` |
| `k3s-frr-failure` | `k3s-frr-failure.final-prototype.txt` | `K3S_FRR_FAILURE_OK` |
| `router-kube` | `router-kube.unreachable-psk.txt` | `ROUTER_KUBE_OK` |
| `nat-gateway-kube` | `nat-gateway-kube.unreachable-psk.txt` | `NAT_GATEWAY_KUBE_OK` |
| `probe-fabric-session` | `probe-fabric-session.final.txt` | `PROBE_FABRIC_SESSION_OK` |
| `probe-transit-split` | `probe-transit-split.unreachable-psk.txt` | `PROBE_TRANSIT_SPLIT_OK`, T00..T08 safe |
| `probe-fabric-boot` | `probe-fabric-boot.txt` | `PROBE_FABRIC_BOOT_OK` |

Earlier trees (each shows one step of the way; kept as evidence):

| File | Tree | What it shows |
|---|---|---|
| `hostile-fabric.run2-contract-first.txt` | steps 1 and 2 only | F01..F19, C01..C04, F21, F22 safe; **F20 GAP**: the hub answers ARP for its loopback |
| `hostile-fabric.run3-gtsm-rendered.txt` | plus `ttl-security hops 1`, `arp_ignore` | F20 safe; stopped by a test fault (hijack not undone) |
| `probe-fabric-session.gtsm-rendered.txt` | GTSM rendered | BFD multihop on 4784, down |
| `probe-fabric-session.no-gtsm-then-gtsm.txt` | no GTSM rendered | single hop, 3784; then GTSM set by hand: multihop |
| `hostile-fabric.run4-no-gtsm.txt` | no GTSM; FRR pre-check that fails at once | F23..F27, S01, S03 safe; **the start-limit fault** after F26 |
| `hostile-fabric.run5-guard-wait.txt` | FRR pre-check that waits | F26, F26b safe; F23d GAP is a test fault (1 s epoch jitter) |
| `hostile-fabric.run6-psk-unreachable.txt` | plus preshared keys, unreachable aggregates, link sysctls | P3 safe; A8 shows `rp_filter = 2`; P3b and F21 GAP are test faults (wrong path, wrong error text) |
| `hostile-fabric.run7-controls.txt` | plus positive controls | every control works; **S02's control caught an empty SAFE** (the idle spine was crashed) |
| `k3s-hostile.run1-test-artifact.txt` | steps 1, 2 | K01..K16 safe; stopped by a test fault (hijack not undone) |
| `k3s-hostile.run2-weak-v4-source.txt` | final tree, first K40 | passes, but K40/K41 IPv4 were **empty**: the attacker used a source WireGuard drops |
| `*.contract-prototype.txt` (7 suites) | steps 1, 2 only | the `_OK` marker of each suite |

Note on "final tree": the service code of all twelve runs is the final
one, except that `k3s-data-plane` may still have evaluated the link
sysctl `rp_filter = 0` (dropped minutes earlier as a value that does not
hold). The test scripts of `hostile-fabric` and `k3s-hostile` are the
final ones.

## 2. One row per probe or assumption

| Id | Question | Result | Suite | Log lines that prove it |
|---|---|---|---|---|
| Core-1 | One value per adjacency feeds WireGuard, FRR and nft | VERIFIED-VM | `hostile-fabric` | `HOSTILE SAFE C01 what one end accepts as a source is what the other end is sent routes for: differ: []`; `HOSTILE SAFE C02 the WireGuard ACL of every link equals its source contract: differ: []`; `HOSTILE SAFE C03 the running ACL of hub's link to rogue is the rogue's own addresses and its transfer address`; `HOSTILE SAFE C04 no fabric link has a 0/0 ACL: []` |
| Core-2 | One table (ingress, forward default deny per link, egress) keeps the named suites green | VERIFIED-VM | 9 suites | the `_OK` markers of section 1 |
| I6 | The spine refuses a destination a leaf is sent no route for | VERIFIED-VM | `hostile-fabric` | `HOSTILE SAFE F18 a leaf does not reach an address it is sent no route for (IPv4): ping rc=1, 0 arrived, hub dropped 3` (and IPv6); `HOSTILE SAFE F19 … 0 leaked, hub dropped 3`; controls: `FINDING control F18: without the spine's guard table 3 of 3 echo requests reach the victim's transfer address`, `FINDING control F19: … 3 of 3 packets with the rogue's fabric source reach the victim's underlay address` |
| I8 | A fabric destination stays off the underlay | VERIFIED-VM | `hostile-fabric`, `routed-fabric` | `HOSTILE SAFE F22 … 0 leaked, victim dropped 3`; `FINDING control F22: without the member's guard table 3 of 3 packets for a fabric address arrive on the LAN gateway`; `HOSTILE SAFE F21 … 0 leaked`; `ROUTED_FABRIC_FORWARD_FILTER_OK` |
| I9 | BGP and BFD answer the link's peer address only | VERIFIED-VM | `hostile-fabric` | `HOSTILE SAFE F23 BGP refuses a member on the spine's loopback and from a source that is not the link's peer address: loopback rc=1, loopback source rc=1, v6 loopback rc=1`; `HOSTILE SAFE F24 forged BFD packets change no session: 20 forged packets arrived on hub; bfd before=6 after=6; 4784 open: False`; `HOSTILE SAFE F24b every BFD session of the spine is single hop, bound to its link, and up: 6 of 6` |
| I9-own | A member can disturb a BGP session: its own only | VERIFIED-VM | `hostile-fabric` | `FINDING I9 a TCP connect to 179 from the peer's own address on its own link: rc=0; sessions that restarted: ['198.19.130.133'] (the rogue's own IPv4 session is 198.19.130.133)`; `HOSTILE SAFE F23d a member can disturb no BGP session but its own` |
| I2 | A forged member source on the underlay is refused, also to an underlay address | VERIFIED-VM | `hostile-fabric` | `HOSTILE SAFE F25 … 0 replies reflected, hub dropped 3`; `FINDING control F25: without the hub's guard table it sends 3 echo replies into the victim's link` |
| I12 | The guard is stateless | VERIFIED-VM | `hostile-fabric` | `FINDING S01 packets per spine and direction: {'hub victim->rogue': 36241, 'hub rogue->victim': 0, 'hub2 victim->rogue': 0, 'hub2 rogue->victim': 40570}; asymmetric: True`; `HOSTILE SAFE S01 …` |
| S02 | A TCP stream survives the crash of the spine it uses | VERIFIED-VM | `hostile-fabric` | `FINDING control S02: the stream leaves the victim through hub; 85564 of its packets were seen there before it dies`; `FINDING S02 seconds with no bytes after the spine died: []`; `HOSTILE SAFE S02 a TCP stream survives the loss of one spine` |
| A1 | `iifname vmap { … : goto … }` and wildcard names load | VERIFIED-VM | every suite | the table passes the build-time `nft -c` and loads; its counters move |
| A2 / K40 | On a kube spine nft sees relayed fabric traffic, and the contract stops a client leaf from a pod on another node | VERIFIED-VM | `k3s-hostile` | `HOSTILE SAFE K40a nft on a kube spine sees relayed fabric traffic (prerouting and forward): prerouting +23, forward +3`; `HOSTILE SAFE K40 … (IPv4): http 000, ping rc=1, contract drops +8` (and IPv6 +8); `FINDING control K40: without the spine's guard table the client leaf gets HTTP 404 from the pod on beta` (404 is the pod's httpd answering) |
| P1 / K41 | A client leaf reaches a pod that runs on the kube spine itself | VERIFIED-VM: yes; nft cannot stop it | `k3s-hostile` | `FINDING K41 client leaf -> pod ON the kube spine (IPv4): ping rc=0, echo requests inside the pod: 3; nft prerouting saw +44, contract dropped +0` (IPv6 the same); also `HOSTILE INFO K10n NodePorts of alpha answer a fabric member outside the cluster (ipv4): [30733, 30763]` |
| A3 | A filter chain on `postrouting` is legal in `inet` and sees local packets | VERIFIED-VM | `hostile-fabric` | F21, F22 count the member's own pings in chain `egress` |
| A4 | nftables.service: order, atomic reload, other tables, build check | VERIFIED (nixpkgs module read) and VERIFIED-VM | `hostile-fabric`, `nat-gateway-kube` | `FINDING A4 boot order, monotonic microseconds: nftables active, ifstate done, frr started: {'hub': '7501094 8617846 8710004', …}`; `HOSTILE SAFE F27 reloading nftables keeps every BGP session`; `FINDING I15 a restart (not reload) of nftables.service keeps the sessions: True; frr active: active; guard present: True` |
| A5 | Fabric BFD is single hop on 3784 only | VERIFIED-VM without GTSM; REFUTED with GTSM | `probe-fabric-session` | `FINDING A5 as rendered: BFD ports and TTLs on the fabric link: 12 .3784: 6 hlim 255 6 ttl 255`; `FINDING A5 with ttl-security hops 1, 4784 closed: BFD ports and TTLs on the fabric link: 12 .4784: 6 hlim 255 6 ttl 255` |
| A6 | A member answers ARP for its fabric loopback on the LAN | VERIFIED-VM (a gap); closed by `arp_ignore = 1` | `hostile-fabric` | run 2: `FINDING A6 hub answers ARP for its fabric loopback on the underlay with the kernel default (arp_ignore=0): True`, `HOSTILE GAP  F20 …`; final: `HOSTILE SAFE F20 no member answers ARP for its fabric address on the underlay: answered: {'hub': False, 'hub2': False, 'rogue': False, 'victim': False}` |
| A7 | A spine's ICMP errors carry its loopback | VERIFIED-VM, both families | `hostile-fabric` | `FINDING A7 path-MTU errors seen on victim: ['… IP 198.18.62.232 > 198.18.102.58: ICMP 198.18.49.59 unreachable - need to frag (mtu 1300) …', '… ICMP6, packet too big, mtu 1300 …']`; `HOSTILE SAFE S03 …` twice |
| A8 | IfState accepts the per-link sysctl keys | VERIFIED-VM for five keys; REFUTED for `rp_filter = 0` | `hostile-fabric` | final: `FINDING A8 sysctls IfState set on a fabric link of hub: … accept_redirects = 0 … send_redirects = 0 … accept_source_route = 0 … accept_ra = 0 … accept_redirects = 0`; run 6 (with `rp_filter = 0` declared): `net.ipv4.conf.rf1c60659062973.rp_filter = 2` |
| A9 | Cilium maps an outside packet's pod source to an identity | NOT-RUN | — | needs a kube owner of a transit tunnel (step 4) |
| A10 | GTSM beside BFD and graceful restart on FRR 10.7.1 | REFUTED for BFD; no difference shown for graceful restart | `probe-fabric-session` | `FINDING A10 with ttl-security hops 1, 4784 closed: … 'multihop': True, 'status': 'down', 'interface': None, 'minimum-ttl': 1 … BFD: Type: multi hop`; `FINDING A10 as rendered: … 'multihop': False, 'status': 'up', 'interface': 'rfb59b9d814cb27' … BFD: Type: single hop`; GTSM itself holds: `FINDING A10 GTSM on, the leaf sends BGP at TTL 64: established on hub: 0`. Route kept during a full restart of the leaf's FRR: 20 of 20 s and 9 of 20 s without GTSM (two runs), 10 of 20 s with it: not GTSM's doing |
| 4784 | UDP 4784 can be closed on fabric links | VERIFIED-VM (without GTSM) | all | `4784 open: False` in F24; every session and BFD up in every suite |
| P2 | Unreachable routes for the fabric pools on a kube node | VERIFIED-VM: no disturbance | `k3s-data-plane`, `hostile-fabric`, `probe-fabric-boot` | `K3S_DATA_PLANE_OK` with `FINDING guard drops on alpha at the end of the suite:` (empty) and the same for beta; `FINDING P2 unreachable routes on victim: unreachable 198.18.0.0/17 metric 4294967000 | unreachable 198.19.0.0/16 metric 4294967000 | unreachable fd02:1e22:d2f3::/48 dev lo metric 4294967000 pref medium`; `FINDING P2 a ping to a withdrawn fabric address with a LAN default route: ping: connect: No route to host` |
| I14 | FRR refuses to start without the guard table, and recovers | VERIFIED-VM with a waiting check; the first sketch REFUTED | `hostile-fabric`, `probe-fabric-boot` | run 4: `frr.service: Start request repeated too quickly`, `Failed with result 'start-limit-hit'`; final: `FINDING I14 frr 15 s after a restart without the guard table: activating, 0 routing daemons; kernel BGP routes before 5, after 5 (zebra -r keeps them)`, `HOSTILE SAFE F26 …`, `HOSTILE SAFE F26b … active 2.1 s after the guard loaded`. At boot: `FINDING I14-boot leaf 30 s after boot: guard table present=False; frr is activating; routing daemons 0; kernel BGP routes v4/v6 ['0', '0']; hub sessions established 0 …`, `FINDING I14-boot 230 s after boot: frr is activating, Result=success, NRestarts=2`, `FINDING I14-boot frr became active 0.5 s after the guard loaded` |
| I15 | A firewall reload or restart resets no session | VERIFIED-VM | `hostile-fabric` | F27; FINDING I15 |
| O1 | A transit tunnel as its own outside-class link: derivation, return path, MSS | VERIFIED-VM as a probe | `probe-transit-split` | `FINDING O1-return (IPv4): ping rc=0; home rt0 in requests=3, rt0 out replies=3, eth1 out replies=0; cloud rt0 in replies=3` (and IPv6); `FINDING O1-mss (IPv4): … SYN arriving on the owner has mss 1260; SYN-ACK arriving at the client has mss 1260; tunnel mtu 1300` (IPv6: 1240); `HOSTILE SAFE T00` … `T08` |
| O1-rest | The option, derived ends, keys by clan vars, a kube owner, `fabricInterfaces` | NOT-RUN | — | step 4; the probe declares the tunnel by hand |
| P3 | A secret clan var shared by exactly two machines (preshared key per adjacency) | VERIFIED-VM | `hostile-fabric` | `HOSTILE SAFE P3 every adjacency has its own preshared key, the same on both ends: same=True distinct=True`; `HOSTILE SAFE P3b a member holds the preshared keys of its own adjacencies only: psk files per machine: {'hub': 3, 'hub2': 3, 'victim': 2, 'rogue': 2}`; `FINDING P3 where a preshared key is deployed on hub: /run/secrets/shared/routed-fabric-fleet-adj-…-psk/psk …` |
| P5 | `notrack` for relayed traffic on a spine | VERIFIED-VM on a kube spine; a NAT spine NOT-RUN | `k3s-hostile` | `FINDING P5 conntrack entries on the kube spine for 2000 relayed one-way UDP flows: 2000 (table size before: 131008)`; `FINDING P5 with notrack for fabric-link packets that are not local: conntrack entries for 2000 more flows: 0; relayed ping ok=True; pod->pod on beta ok=True; pod on beta->API ClusterIP (on alpha) ok=True; pod on alpha->pod on beta ok=True; rule counter packets 2006` |
| P6 | Who opens BGP to `::1`; a root-only output rule | VERIFIED-VM | `k3s-hostile` | `FINDING P6 the Cilium session to ::1:179 on alpha: … users:(("cilium-agent",pid=1896,fd=85))`; `FINDING P6 an unprivileged user connects to ::1:179: before the rule True, with the rule False; Cilium's session re-established with the rule after 6 s` |
| Flows | Did the guard drop a legal flow in a kube or gateway suite? | No | `k3s-data-plane`, `router-kube`, `nat-gateway-kube` | `FINDING guard drops on …` lines: none in `k3s-data-plane`; in `router-kube` and `nat-gateway-kube` only `fabric destination on a link outside the fabric` 6 packets per family on the agent: section 3 |
| Unit | The nix-unit tests on the prototype (each `expr` evaluated with `nix eval` and compared with `expected`; the `nix-unit` check itself and `check` NOT-RUN) | `routed-fabric`, `netif`, `nat-gateway`, `router`, `modes`, `kube-cluster`, `k3s`: all pass. `rke2`: 2 fail | — | `rke2`: `test_firewallFabricAgent`, `test_firewallManualBySource`. Both come from the review's kube fix inside `fixes-fabric-kube.patch` (the supervisor front moved to the member-only ports), not from the fabric prototype: the kube step fixes them |
| R-A5 | `node-bgp` owner only in the spine's filter (K42) | NOT-RUN | — | step 3 |
| Steps 3, 8 | typed options, assertions A1..A7, consumption by pool | NOT-RUN | — | no behaviour question in them |
| Keys | one key pair per adjacency end | NOT-RUN | — | step 6; only the preshared key ran |
| I11 | every invariant with `checkReversePath = false` on every member | NOT-RUN for `hostile-fabric`; `probe-transit-split` runs with it off | — | the guard counts at `raw`, before the NixOS reverse-path chain |
| forwardLinks | the guard beside the CLAT's default-deny forward chain | NOT-RUN | — | the fact is the gateway round's; written into the design as an obligation |
| rke2 | `rke2-hostile` and the other suites of the repo | NOT-RUN | — | the brief named seven suites; nine ran |

## 3. Flows the guard met

The brief asked for every flow that needed a decision. No set was
widened.

| Flow | Decision |
|---|---|
| `routed-fabric`: a leaf pings a member's loopback **by its own underlay** through a spine's underlay address (the old "border forward filter" subtest) | Not legal. The leaf's own `egress` rule drops it. The subtest was rewritten to prove that (I8). The spine side needs a non-member: `hostile-fabric` F05..F09. |
| `routed-fabric-transit`: outside traffic to a fabric address through the upstream end | Not legal. Dropped one hop earlier now (the upstream end's `ingress`); the suite reads that counter. |
| `router-kube`, `nat-gateway-kube`: the k3s agent sends to the server's fabric address in the first seconds of boot, before BGP is up (sessions come up at second 19). 6 packets per family counted by `egress` | Not legal, and the point of I8: on `main` those packets follow the default route to the LAN in clear. The suites pass. |
| a member's own TCP connect to 179 on its link | Legal. It restarts that member's own session (FRR graceful restart). Limit L4. |
| `router-kube`: a router zone to the cluster | Legal through `fabricInside`. No change. |
| `nat-gateway-kube`: CLAT and NAT64 host links | Legal through `fabricInside`. No change. |
| `k3s-data-plane`: the upstream router's traffic to a LoadBalancer VIP | Passes: Cilium serves it. No guard counter moved. |

## 4. Positive controls

A verdict that says "the guard stops X" must show X working without the
guard, or its SAFE can be empty. Two empty SAFEs were found and fixed in
this round:

- S02 (run 7): the suite crashed a spine the stream did not use. ECMP
  hashes on the two addresses only, so all flows between two members
  share one spine. The suite now reads the path and crashes that spine.
- K40 and K41 IPv4 (`k3s-hostile` run 2): the attacker's packets left
  with its underlay address as source (a scope-link transfer address is
  not chosen for a routed destination), and the spine's WireGuard
  dropped them before any rule. The attacker now sends from its fabric
  address, and removes its own guard table (a hostile root would).

What each new verdict has: the table in `specs/design-routed-fabric.md`
§6. In short: F18, F19, F22, F25 and K40 run the attack again with the
guard table deleted and print that it works; F20 was a recorded GAP
before the sysctl; F23 has the legal connect; F24 counts the forged
packets that arrived (20 of 20); F26 and the boot probe show FRR up
before and after; T02..T06b have T01 and a counter each.
Not controlled against `main`: nothing new was run on `main` itself.

## 5. Test faults met (keep the fixes)

1. After a BGP hijack verdict the attacker must remove its `network`
   lines: a locally originated /32 of another member replaces its own
   learned route.
2. `ip link set <wg> down` flushes the link's IPv6 addresses; bring it
   back with `systemctl restart ifstate.service`.
3. `peerUptimeEstablishedEpoch` jitters by one second: compare with a
   tolerance.
4. A member cannot play the outsider: its `egress` chain drops what it
   sends to a fabric address by the underlay.
5. The NixOS test driver type-checks the script: a value that may be
   `None` cannot be compared with `<=`.
6. `find -xdev` does not enter `/run/secrets.d`; shared secrets are
   under `/run/secrets/shared/<generator>/`.
7. Never write `''` inside a test script: it ends the Nix string.
