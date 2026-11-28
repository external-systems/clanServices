# Target design for networking and Kubernetes (round 61)

**Status: target design, prototyped and probed on VMs, not implemented
on `main`.** Decided as the direction by the owner on 2026-11-27
(SPEC.md round 61, H1). A probe round on the same day ran a prototype
of each area on the remote builder (§5). Every open owner decision is
decided (§4). The four area files hold the detail; each line in them
says VERIFIED-VM, REFUTED or NOT-RUN:

| Area | File |
|---|---|
| routed-fabric, FRR, WireGuard | `specs/design-routed-fabric.md` |
| k3s, rke2, `lib/kube-cluster` | `specs/design-kube.md` |
| nat-gateway, router, `lib/gateway`, remote-builder | `specs/design-gateway.md` |
| netif, modes, the IfState base | `specs/design-netif.md` |

The findings of the probe round are `specs/probes/2026-11-27/` (one
file per area, with the suite and log lines of each result).

This file is the index: what the four share, what the owner decided,
what the probes showed, and the order to build in. Where an area file and this file
disagree, this file wins. Where a design and SPEC.md or `specs/*.md`
disagree, the older spec is still the status authority until the step
that implements the design amends it (hard rule 3).

## 1. Why a new design

A review with hostile-actor VM suites (an attacker VM beside the
system; hermetic) ran against `main`. Verdicts:

| Suite | Result on `main` |
|---|---|
| `hostile-router` | safe (31 verdicts) |
| `hostile-fabric` | gaps: a plain spine forwards underlay traffic into the fabric, answers outsiders on fabric addresses, accepts forged member sources, and routes a leaf out to the underlay |
| `k3s-hostile`, `rke2-hostile` | gaps: an outsider on the node LAN reaches a pod; a pod reaches BGP on other nodes; on rke2 a pod reaches the supervisor front |
| `nat-gateway-hostile` | gaps: `127.0.0.1` of the translator is reachable; one packet loops 32 times (CLAT and NAT64) |
| `netif-hostile` | gaps: ICMP redirects are accepted |

Minimal fixes ("add a drop for each bad path") were prototyped and close
every gap above in the suites. They are the fallback. The owner asked
for the best design instead, with no regard for the shape of today's
tests (§7 of SPEC.md, "Current phase"). The common cause of the gaps is
that the stack **named what is bad** and trusted the underlay for the
rest. The target design **names what is allowed**.

## 2. The design in one page

1. **routed-fabric: a link carries a packet only if BGP may carry its
   route.** One "link contract" per adjacency (`sources`,
   `destinations`) feeds the FRR lists, the WireGuard ACL and the nft
   sets. One nft table with the same shape on every member (`ingress`,
   `forward`, `egress`) replaces the border guard, the transit filter
   and the prototype's ingress chain. Forwarding over a fabric link is
   default deny. `access` is enforced on the spine by the same
   contract. BGP and BFD answer only the link's peer address. FRR does
   not start without the guard table. No GTSM (refuted, §5).
2. **kube: the node says what may come in, and Cilium says who may
   reach a pod.** One port and source matrix renders the node firewall.
   HAProxy fronts bind loopback only. A clusterwide Cilium policy
   refuses the outside for pods; it is the guard, because nft does not
   see a packet for a pod on the receiving node (§5). Every
   outside-facing Service is type LoadBalancer with source ranges;
   admission refuses the rest and fills in the default. Pod Security
   baseline is enforced. A wiped server rejoins through a drop-in.
3. **gateway: policy before translation, default deny after.** The host
   refuses a packet while it is still IPv6. Inside the translator and
   CLAT namespaces forwarding is off and a guard table drops whatever
   Jool did not translate. A gateway without its guard is unhealthy and
   withdraws. A CLAT host forwards IPv6 only for the CLAT and for
   declared forward links.
4. **netif: one transaction, and DHCP and RA are untrusted input.** One
   program inside `ifstate.service` applies, verifies and rolls back.
   The guard judges only what netif declared. A new configuration must
   prove itself, or the machine stays on the last good one; a declared
   one-shot override covers a planned move. One sysctl baseline covers
   every link. Router advertisements and classless DHCP routes are
   opt-in.

## 3. Contracts between the areas

These cross a file boundary. Build them once, in the step named.

| Contract | Owner | Readers | Lands in |
|---|---|---|---|
| Fact `clan.networkFacts.fabricInside` (links, beside a fabric's own, whose hosts may reach fabric and pod addresses through this machine) | `lib/kube-cluster/network-facts.nix` | routed-fabric guard, kube guard | fabric steps 1 and 2 (**done**, round 62) |
| Who sets `fabricInside`: the CLAT link and the NAT64 link always; a router zone only with `zones.<name>.fabric = true` (default false; H3). `unzoned.zones` is removed, `unzoned.source` becomes `fabricSource` | `lib/gateway/{clat,nat64,router}.nix` | — | fabric steps 1 and 2 (CLAT, NAT64 and the zone option: **done**, round 62), gateway step 6 (removes `unzoned.zones`) |
| Fact `clan.networkFacts.forwardLinks` (interface-name patterns that may forward IPv6 on a CLAT host). A CLAT host drops all other forwarded IPv6 (O7). Kube sets `["cilium*" "lxc*"]`; routed-fabric sets its fabric (and transit) links when the member forwards; the router sets its links. One nix-unit assertion each. A service that forwards and does not set it is cut off on a CLAT host | `lib/kube-cluster/network-facts.nix`; enforced by `lib/gateway/clat.nix` | kube, routed-fabric, router | gateway step 3, with the three setters in the same PR |
| "An outsider or a non-member cannot reach a pod" is a **kube** invariant (the clusterwide policy). The fabric table guards fabric links and relayed traffic only. The fabric gives kube the true sender (WireGuard ACL) | kube | routed-fabric states the limit | kube step 7 |
| A host of a router zone with `fabric = true` is `world` for Cilium: it reaches only pods labelled `clan.lol/outside=allow` (or in a labelled namespace), through a Service whose ranges hold it. Proven apart, NOT-RUN together: gateway step 6 adds the combined verdict to `router-kube` | kube (policy), gateway (zone) | READMEs of both | kube step 7, gateway step 6, whichever lands second |
| `arp_ignore = 1`, `arp_announce = 2`: routed-fabric sets them with `mkDefault` (proven needed, F20); netif renders the same values per link in its step 8 | routed-fabric, netif | — | fabric step 5, netif step 8 |
| Reverse-path filtering is not netif's and not the fabric's: a per-link `rp_filter = 0` does not hold (reads 2). No design leans on it | — | netif baseline leaves `rp_filter` alone | netif step 1 |
| Unreachable aggregates: readers of IfState `routing.routes` must accept a route with `type = "unreachable"` and no `dev` or `table` | routed-fabric, gateway | netif's guard and status | fabric step 7, gateway step 1 |
| Units: `netif-dhcpcd-<if>.service` becomes `netif-dhcpcd@<if>.service`; `netif-guard.service` is gone. Suites of the other areas that name them change in the netif PR (`lib/kube-cluster/tests/vm/{join,data-plane}.nix`, `services/routed-fabric/tests/vm/suite.nix`, `lib/gateway/tests/vm/{wan,dual-wan}.nix`, `services/router/tests/vm/default.nix`) | netif | kube, fabric, gateway suites | netif step 6 |
| `ifstate.service` stays ordered after `nftables.service` on a router and keeps its one-transaction shape | netif | gateway | netif step 6 |
| RA is opt-in per link (`ra = true`). Fixtures of other areas that take an RA default must set it | netif | gateway, router, kube IPv6 fixtures | netif step 2 |
| HAProxy server lines use `source <node address>`: the fabric loopback must exist (after `ifstate.service`); it does while FRR still waits for its guard | kube | routed-fabric | kube step 4 |
| `node_transport` gains `fabricInterfaces`; a transit tunnel is not in it | routed-fabric | `lib/kube-cluster/transport.nix` | fabric step 4 |
| Manual-address mode is removed; `network.fabric` is required | kube | routed-fabric may drop `firewall.trust` | kube step 3, fabric step 3 |
| Empty file under `/run/netif/pd/<link>` means "delegation lost"; no file means "no answer yet" | netif (N16 amended) | the router's prefix hook | gateway step 5 point 2, with the netif spec in the same PR |
| A spine can forge member sources: by-source rules protect against leaves and outsiders only; TLS, tokens and mTLS cover the rest | — | SPEC.md §6.12 states it | kube step 4 |
| The shared hostile suite `lib/kube-cluster/tests/vm/hostile.nix` was extended by two prototypes (kube: K05d..K53; fabric: `mallory` as `client`, K40a, K40, K41, P5, P6). Merge both sets; kube's file is the base | kube | routed-fabric | kube step 1 (**done**, round 63: merged; verdicts that need a later kube step are `info` lines naming it) |

Numbering: the area files suggest decision ids (D73, N45). Take the
next free id at the time of the PR; `N45` is already used.

## 4. The owner's decisions

All decided on 2026-11-27. None is open. H2–H10 are in SPEC.md round
61; O1–O11 are below, with what the probe round showed.

| # | Decision | Probe result | Where |
|---|---|---|---|
| O1 | Yes: a transit tunnel is its own outside-class link (`border.transit.<remote>`), replacing `externalTransit` and `sourceReturn` | probed (`probe-transit-split` T00..T08 safe; replies return through the tunnel; the guard needs no change). The service code is NOT-RUN | design-routed-fabric §3.4, step 4 |
| O2 | Close it: a non-member must not reach a pod on a kube spine | nft cannot (K41: Cilium delivers first). The clusterwide Cilium policy does (K05d, K06d, K11f) | design-kube §3.4, step 7 |
| O3 | No custom eBPF. Service fronts by source: Cilium `bpf-lb-source-range-all-types=true`, every outside-facing Service is type LoadBalancer with `loadBalancerSourceRanges`, a ValidatingAdmissionPolicy refuses NodePort Services, `externalIPs`, missing or too wide ranges, a MutatingAdmissionPolicy fills in the default (members and pods). H2's opt-in list is `nodePorts.allowedSources` | VERIFIED-VM on both distros. A plain NodePort Service cannot carry ranges (the API refuses), so "NodePort by source" became "LoadBalancer with ranges". No org-pkgs PR | design-kube §3.5, step 8 |
| O4 | Pod Security: enforce `baseline`, warn `restricted`; a namespace label opts out | VERIFIED-VM on both distros (K50–K53) | design-kube §3.11, step 9 |
| O5 | Accept "stay on the last good configuration", plus a declared one-shot override `clanServices.netif.guard.replaces = "<last good bundle>"` | VERIFIED-VM (`netif-guard`: the whole decision table but the `rollback-failed` row) | design-netif §3.2, step 6 |
| O6 | `accept_dad = 0`: no. `arp_ignore`/`arp_announce`: yes | VERIFIED-VM for k3s on the fabric (P11) and needed by the fabric (F20). rke2 and the gateway suites NOT-RUN | design-netif step 8, design-routed-fabric §3.8 |
| O7 | Default-deny IPv6 forwarding on a CLAT host, opened by `forwardLinks` | VERIFIED-VM (`nat-gateway-hostile` C08 with negative proof; `k3s-clat` with pods) | design-gateway §3.5, step 3 |
| O8 | remote-builder is redesigned apart, together with the change in external-systems/home | not probed. **Do not build gateway step 7 until the owner schedules it** | design-gateway §3.10, step 7 |
| O9 | A router zone with `fabric = true` reaches only pods labelled `clan.lol/outside=allow` (or in a labelled namespace), through a Service whose source ranges hold it (SPEC.md H21) | the zone option landed with fabric steps 1 and 2 (round 62); the policy is NOT-RUN together with it | design-kube §3.4, step 7; gateway step 6 |
| O10 | The ClusterMesh API Service is type LoadBalancer with source ranges on every exposure mode, node-port too; `cilium-dbg status` replaces `cilium clustermesh status` there (SPEC.md H22) | VERIFIED-VM on the prototype (`k3s-clustermesh-nodeport`); the NodePort answered the attacker on main | design-kube §3.5 part 4, step 8 |
| O11 | CoreRAD is the router's RA daemon, never radvd. radvd appears only as a test fixture: the ISP simulator and the attacker's rogue RA sender in the hostile suites (SPEC.md H23) | the router already runs CoreRAD (`specs/gateway.md` G15); `netif-hostile` names its radvd a fixture (round 64) | design-netif §3.6; design-gateway |

O10 began as a design choice of the probe round. The owner made it a
decision: one rule holds for every Service, the ClusterMesh API
included, and the plain NodePort behind mTLS is rejected.

## 5. What the probes showed

Probe round of 2026-11-27. One prototype per area, applied to `main` at
`deeaba4`, one VM suite at a time on the remote builder. Findings:
`specs/probes/2026-11-27/<area>.md`. Facts about upstream components
are in `documentation/docs/reference/upstream-facts.md`.

Suites that pass on the prototype of their area:

| Area | Suites |
|---|---|
| routed-fabric | `hostile-fabric` (58 safe, 0 gap), `k3s-hostile` with the fabric verdicts, `routed-fabric`, `routed-fabric-transit`, `k3s-join`, `k3s-data-plane`, `k3s-frr-failure`, `router-kube`, `nat-gateway-kube` |
| kube | `k3s-hostile` (105 safe, 0 gap), `rke2-hostile` (109 safe, 0 gap), `k3s-clustermesh-nodeport`, `<distro>-join`, `<distro>-single` |
| gateway | `nat-gateway-hostile` (41 safe, 0 gap), `hostile-router` (36 safe, 0 gap), `nat-gateway`, `nat-gateway-failover`, `nat-gateway-kube`, `k3s-clat`, `router`, `router-kube` |
| netif | `netif-hostile`, `netif-guard`, `netif`, `netif-match`, `netif-hotplug`, `netif-dhcp`, `netif-modes`, `netif-vmhost`, `netif-wifi`, `netif-desktop`, `netif-v6only`; with the ARP keys `k3s-join-netif`, `k3s-data-plane-netif` |

The four prototypes were never applied together. `check` ran on none of
them. The first PR of each area proves its own step again.

What was refuted, and what the design does now:

| Was | Probe showed | Now |
|---|---|---|
| The nft table keeps outsiders from pods | With BPF host routing a packet for a pod on the receiving node never enters netfilter (kube P1, fabric K41) | The clusterwide Cilium policy is the guard; nft covers non-Cilium links and relayed traffic |
| NodePorts answer by source | The API refuses source ranges on any Service type but LoadBalancer | LoadBalancer with ranges plus admission (O3) |
| A custom eBPF guard ahead of Cilium | Not needed | Withdrawn |
| GTSM on fabric BGP sessions | FRR 10.7.1 turns the neighbor's BFD multihop (port 4784, no link binding) | No GTSM; sessions pinned by link, peer address and own address |
| An FRR pre-check that fails at once | The unit's start limit ends in `start-limit-hit` for good | The check waits 80 s per attempt |
| "No guard, no routes" | True at boot only; zebra `-r` keeps kernel routes on a running machine | Stated as a limit |
| "Fail fast when pool4 is full" | Jool drops a new flow in silence | Stated; the counter is exported |
| The guard's leftover counter is 0 | Multicast link chatter counted | Two noise rules ahead of the counter |
| The router's echo limit | Behind `ct state established` it never applied (200 of 200) | A `limit rate over` drop ahead of it (69 of 200) |
| Token pin = hash of the CA bundle file | It is the SHA-256 of the root's DER | Keep and use the PKI's `ca-hash` |
| "No other host dials a front" (rke2) | An rke2 agent's tunnel dials servers on the port of its join URL | The rke2 agent's supervisor front listens on loopback 9345 |
| Decider rules "start a rejoiner once" and "etcd directory exists, so remove the drop-in" | Both wrong; the second founded a new cluster | The drop-in is the joiner state and is never removed by the decider |
| A netif fallback unit for boot (`netif-verify`) | Not needed: no cycle, lease inside the run | One unit |
| Hostile RA verdicts on `main` (netif H02–H04, router R15) | Empty: radvd refused its config and sent nothing | Fixed; **every hostile group has a positive control, and a missing control fails the suite** |

What nobody ran yet (each is named NOT-RUN in its area file):

- routed-fabric: step 3 (typed options), step 4 as service code, key
  pairs per adjacency, `notrack` on a NAT spine, the guard beside the
  CLAT forward chain.
- kube: the state beacon and the full decider (step 5), UDP and SCTP
  fronts, `<distro>-ha`, `-data-plane` and the other clustermesh suites
  on the prototype, a positive control for K08, K11o in the hostile
  suite.
- gateway: the beacon inside pool6 (P4, step 8), the empty PD file
  (step 5 point 2), `rke2-clat`, `k3s-clat-mapped`, remote-builder.
  Open detail: `clat-unsolicited` read 8 on each kube node in
  `k3s-clat`; do not assert it 0 there until the packets are named.
- netif: the `rollback-failed` row, the table test
  `checks.netif-guard-logic`, eval checks E2, E4, E5, E7–E11, ARP keys
  with rke2 and the gateways, a wired NetworkManager link with SLAAC.

## 6. Build order

One PR per step. Spec and docs first, then code, `fmt`, `check`, the
named suites. Each area file has its own step table (§8); this is the
order across areas. A prototype is a worked example: cut the step's
hunks out of it, then write the spec amendment, the docs and the
nix-unit tests that it lacks.

| Wave | Steps | Why this order |
|---|---|---|
| 1 | The judges and the first guards: fabric steps 1 and 2 as one PR (with `fabricInside`; **done**, round 62); kube step 1 (with `packages.rke2`, K-A1; **done**, round 63); netif step 1 (sysctl baseline, `netif-hostile` with controls; **done**, round 64); gateway steps 0 to 3 (one PR or three; step 3 carries `forwardLinks` and its three setters); `hostile-router` with the R15 fix | Closes every proven gap. Puts the hostile suites in the tree |
| 2 | The structural steps: fabric 5 and 7 (may ride with wave 1), fabric 3; kube 3 and 4; netif 2, 3, 4; gateway 4, 5 (points 1 and 3) | Each is independent of the other areas, except the contracts of §3 |
| 3 | The large steps: netif 5, 6, 7 (the transaction; the unit renames reach the other areas' suites); kube 7 and 8 (policy and Service fronts; READMEs explain both gates together), kube 6; fabric 4 (transit, O1), 6; gateway 6 (zones; adds the zone-and-policy verdict) and 5 point 2 | Need the wave-2 structure |
| 4 | kube 5 (beacon and decider: new code, prove first), kube 9; fabric 8; netif 8 (ARP keys); gateway 8 (after P4) | New code without a prototype, or optional |
| gated | gateway 7 (remote-builder), with external-systems/home (O8) | Owner schedules it |
| last | Reset every interface schema version to 1 (H9) | Touches the files of every other step |

Rules for every step:

- A hostile suite and the change that makes it pass go in the same PR.
  `main` never holds a red suite.
- Every hostile verdict has a positive control: the attack works
  somewhere first (without the guard, or against an opted-in target).
- Never widen an allow-set to make a suite pass. Give the flow a route
  or a declared source, or record why it is not legal.
- A suite check that pins a mechanism is rewritten as a behaviour check
  (each area file lists them in its §5). A safety behaviour is never
  dropped.
- A NOT-RUN line is proven by the step that builds it, in a suite, and
  its fact goes into `upstream-facts.md`.
- Run VM suites one at a time on the builder.
