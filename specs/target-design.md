# Target design for networking and Kubernetes (round 61)

**Status: target design, not implemented.** Decided as the direction by
the owner on 2026-11-27 (SPEC.md round 61, H1). The four area files hold
the detail:

| Area | File |
|---|---|
| routed-fabric, FRR, WireGuard | `specs/design-routed-fabric.md` |
| k3s, rke2, `lib/kube-cluster` | `specs/design-kube.md` |
| nat-gateway, router, `lib/gateway`, remote-builder | `specs/design-gateway.md` |
| netif, modes, the IfState base | `specs/design-netif.md` |

This file is the index: what the four share, what the owner still
decides, and the order to build in. Where an area file and this file
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
   route.** One "link contract" per adjacency feeds the FRR lists, the
   WireGuard ACL and the nft sets. One nft table with the same shape on
   every member replaces the border guard, the transit filter and the
   prototype's ingress chain. Forwarding over a fabric link is default
   deny. `access` is enforced on the spine by the same contract.
2. **kube: the node says what may come in.** One port and source matrix
   renders the node firewall. HAProxy fronts bind loopback only. Cluster
   CIDRs are accepted from inside links only, and a clusterwide Cilium
   policy refuses the outside for pods (the nft rule alone does not see
   traffic that arrives on a Cilium device). NodePorts answer by source.
   Founding a cluster needs every member to say it is empty.
3. **gateway: policy before translation, default deny after.** The host
   refuses a packet while it is still IPv6. Inside the translator and
   CLAT namespaces a guard drops whatever Jool did not translate. A
   gateway without its guard is unhealthy and withdraws.
4. **netif: one transaction, and DHCP and RA are untrusted input.** One
   program applies, verifies and rolls back. The guard judges only what
   netif declared. A new configuration must prove itself, or the machine
   stays on the last good one. One sysctl baseline covers every link.
   Router advertisements and classless DHCP routes are opt-in.

## 3. Contracts between the areas

These cross a file boundary. Build them once, in the step named.

| Contract | Owner | Readers | Lands in |
|---|---|---|---|
| Fact `clan.networkFacts.fabricInside` (links, beside a fabric's own, whose hosts may reach fabric and pod addresses through this machine) | `lib/kube-cluster/network-facts.nix` | routed-fabric guard, kube guard | fabric step 1 |
| Who sets `fabricInside`: the CLAT link and the NAT64 link always; a router zone only with `fabric = true` (default false; H3) | `lib/gateway/{clat,nat64,router}.nix` | — | fabric step 1 (CLAT, NAT64), gateway step 6 (zones) |
| `node_transport` gains `fabricInterfaces`; a transit tunnel is not in it | routed-fabric | `lib/kube-cluster/transport.nix` | fabric step 4 |
| Manual-address mode is removed; `network.fabric` is required | kube | routed-fabric may drop `firewall.trust` | kube step 3, fabric step 3 |
| Empty file under `/run/netif/pd/<link>` means "delegation lost"; no file means "no answer yet" | netif (N16 amended) | the router's prefix hook | gateway step 5, with the netif spec in the same PR |
| Reverse-path filtering is not netif's; the fabric and the cluster set it | routed-fabric, kube | netif baseline leaves `rp_filter` alone | netif step 1 |
| A spine can forge member sources: by-source rules protect against leaves and outsiders only; TLS, tokens and mTLS cover the rest | — | SPEC.md §6.12 states it | kube step 4 |

Numbering: the area files suggest decision ids (D73, N45). Take the
next free id at the time of the PR; `N45` is already used.

## 4. What the owner still decides

Nothing here blocks the first steps of any area.

| # | Question | Where | Default until decided |
|---|---|---|---|
| O1 | Transit tunnels become their own outside-class link (`border.transit.<remote>`), replacing `externalTransit` and `sourceReturn` | design-routed-fabric §3.4, step 4 | keep today's transit rules, exempt from the contract (steps 1–3 work without it) |
| O2 | A `client` leaf may reach pods that run on a kube spine itself (Cilium handles them before nft): accept, or one of the three options of probe P1 | design-routed-fabric §9 | stated as a limit |
| O3 | NodePorts by source need a small custom eBPF guard ahead of Cilium (it fails open). Or the fallback: an admission policy that restricts by existence, not by source | design-kube §3.5, step 8 | probe P3 first |
| O4 | A Pod Security default for new namespaces | design-kube step 9 | none |
| O5 | netif "stay on the last good configuration" can refuse a good deploy during an outage; a planned renumbering then needs the console | design-netif §7, R2 | as designed |
| O6 | `accept_dad = 0` on static IPv6 links; `arp_ignore`/`arp_announce` | design-netif steps 8, 9 | off |
| O7 | A CLAT turns its host into a machine-wide IPv6 forwarder | design-gateway R5 | not fixed |
| O8 | **remote-builder has a real consumer**: external-systems/home. Its redesign (own sshd, port, alias, host-key name) needs a matching change in `home` | design-gateway step 7, R7 | **do not build step 7 until the owner schedules it with `home`** |

Decided already (SPEC.md round 61, H2–H9): NodePorts for members only
by default; router zones opt in to the fabric; `access` enforced on the
spine; `ownedPrefixes` not originated; DHCP classless routes ignored by
default; the README quick start must evaluate; rogue RA between LAN
neighbours is out of scope; schema versions reset to 1.

## 5. Probes come first

No design here was run. Each area file lists its probes in its §9 (a
probe is a throwaway suite that prints `FINDING` lines). A step that
depends on a probe names it. When a probe disagrees with a design, amend
the design file in the same PR as the finding, then build. The ones
that decide the most:

- kube P1, P2: does the nft rule miss outside-to-pod traffic on a
  Cilium device, and does the clusterwide policy stop it.
- kube P3: tcx ordering of a guard ahead of Cilium.
- gateway P1, P6: the masked set match loads, and the namespace guard
  sees exactly what Jool hands back.
- netif P1: starting DHCP from inside `ifstate.service` at boot.
- routed-fabric K40: a kube spine still shows relayed traffic to nft.

## 6. Build order

One PR per step. Spec and docs first, then code, `fmt`, `check`, the
named suites. Each area file has its own step table (§8); this is the
order across areas.

| Wave | Steps | Why this order |
|---|---|---|
| 1 | The hostile suites with the fixes that make them pass: fabric step 1; kube step 1 (with `packages.rke2`, K-A1); netif step 1; gateway steps 0 and P, then 1; the `hostile-router` suite alone | Closes every proven gap. Small. Puts the judges in the tree |
| 2 | Probes: kube step 2, fabric step 9, netif P1–P11 as needed | Decides the shape of wave 3 |
| 3 | The structural steps: fabric 2 and 3; kube 3 and 4; netif 2, 3, 4; gateway 2, 3, 4 | Each is independent of the other areas, except the contracts of §3 |
| 4 | The large steps: netif 5, 6, 7 (the transaction); kube 5, 6, 7; fabric 4 (after O1), 5, 6, 7; gateway 5, 6 | Need the probes and the wave-3 structure |
| 5 | kube 8, 9; fabric 8; netif 8, 9; gateway 8; gateway 7 (after O8) | Optional or owner-gated |
| last | Reset every interface schema version to 1 (H9) | Touches the files of every other step |

Rules for every step:

- A hostile suite and the change that makes it pass go in the same PR.
  `main` never holds a red suite.
- Never widen an allow-set to make a suite pass. Give the flow a route
  or a declared source, or record why it is not legal.
- A suite check that pins a mechanism is rewritten as a behaviour check
  (each area file lists them in its §5). A safety behaviour is never
  dropped.
- Run VM suites one at a time on the builder.
