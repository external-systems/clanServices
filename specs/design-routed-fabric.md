# routed-fabric: target design (best-design review, 2026-11-27)

> **Status: target design, prototyped and probed, not merged** (SPEC.md
> round 61). Steps 1 and 2 (the link contract and the one guard table),
> and parts of steps 5, 6 and 7, ran as a prototype on real VMs on
> 2026-11-27. The transit split (§3.4, owner decision O1) ran as a
> probe. Each rule, invariant and assumption below carries its result:
> **VERIFIED-VM** (a suite proved it; the suite and verdict are named),
> **REFUTED** (a probe disagreed; the text was changed to what works) or
> **NOT-RUN**. The index, the cross-area contracts and the build order
> are in `specs/target-design.md`.
>
> The findings are `specs/probes/2026-11-27/fabric.md` (one row per
> probe). The rest is session evidence of the review of 2026-11-27. It
> is not in the repo; the session handoff maps it: `probes/fabric/*.txt` (verdict lines per run) and
> `probes/fabric/prototype.patch` (the code that ran, against `main` @
> deeaba4).

Base: `main` @ deeaba4. Line numbers cite `main`.
"VERIFIED-VM" = a VM suite on the remote builder showed it.
"Verified in code" = the cited lines were read. "NOT-RUN" = kernel, FRR,
Cilium or nftables behaviour nobody ran yet. §9 lists every assumption
and probe with its result.

Paths are relative to the repo root. `default.nix` means
`services/routed-fabric/default.nix`. `frr.nix` means
`lib/kube-cluster/frr.nix`.

What ran (one suite per `vm-test` call, `--remote --rebuild`). The
last column is the result on the final prototype tree:

| Suite | What it proves | Result |
|---|---|---|
| `hostile-fabric` (extended: second spine, C01..C04, F18..F27, S01..S03, P3) | the guard, the contract, fail closed, stability | `HOSTILE_FABRIC_OK`: 58 safe, 0 gap |
| `routed-fabric` | the existing behaviour | `ROUTED_FABRIC_OK` |
| `routed-fabric-transit` | R7 on the prototype | `ROUTED_FABRIC_TRANSIT_OK` |
| `k3s-join` | a cluster forms over the guarded fabric | `K3S_JOIN_OK` |
| `k3s-data-plane` | pods, VIPs, an upstream router; the unreachable aggregates (P2) | `K3S_DATA_PLANE_OK` |
| `k3s-frr-failure` | FRR crash, restart, reload, dead node | `K3S_FRR_FAILURE_OK` |
| `k3s-hostile` (K40, K41, P5, P6 added) | the guard on a kube spine | `K3S_HOSTILE_OK` (K01..K33, K40a, K40 safe; K41 reported: §9 P1) |
| `router-kube` | a router zone into the cluster through `fabricInside` | `ROUTER_KUBE_OK` |
| `nat-gateway-kube` | CLAT and NAT64 links through `fabricInside` | `NAT_GATEWAY_KUBE_OK` |
| `probe-fabric-session` (throwaway) | GTSM beside BFD (A5, A10) | REFUTED the GTSM step, §3.5 |
| `probe-transit-split` (throwaway) | a transit tunnel as its own outside link (§3.4) | T00..T08 safe |
| `probe-fabric-boot` (throwaway) | a boot without the guard table (I14) | FRR stays down, then starts by itself |

Not run on the prototype: `rke2-hostile` and the other suites of the
repo (ClusterMesh, NodePort, CLAT, failover, netif). `check` (the
static gate) was not run either; the nix-unit tests of routed-fabric
were evaluated one by one and pass.

Read first:
- `reviews/routed-fabric.md` (R-A1..R-A12)
- `specs/probes/2026-11-27/fabric.md`
- `probes/fabric/prototype.patch`

## 0. The answer in short

Yes, a better design exists. It is not "more drops". It is one rule:

> **A link carries a packet only if BGP may carry its route.**

On `main` three things are derived apart: the BGP lists, the WireGuard
ACL and the nft rules. The target derives all three from one value per
link, the **link contract**: the existing `import` and `export` route
sets of an adjacency (`sources`, `destinations`). Then:

- "enumerate the bad paths" becomes "name the allowed ones";
- the border guard and the review's ingress chain become one table
  with one shape on every member;
- `access` is enforced for free (the `destinations` set);
- R-A1, R-A2, R-A4 and F05..F17 close by construction. R-A3, R-A6 and
  R-A7 close with step 4.

Second big change: **an external-transit tunnel is not a fabric link.**
It is an outside link that happens to be a tunnel. So every fabric link
has a finite cryptographic ACL. No 0/0 on a fabric link, ever. The
owner decided this (O1); the probe of §3.4 shows it works.

A structural split (VRF or netns) was considered and rejected: §4 (q).

What the probes of 2026-11-27 changed in this file:

| Was | Is | Why |
|---|---|---|
| GTSM (`ttl-security hops 1`) on fabric sessions, and 4784 closed | **no GTSM**; 4784 closed; BGP and BFD pinned to the link's two transfer addresses | on FRR 10.7.1 GTSM makes the neighbor's BFD multihop: port 4784, not bound to the link, any TTL (§3.5) |
| FRR's `ExecStartPre` fails when the guard is missing | it **waits** 80 s per attempt | a quick failure hits the unit's start limit; FRR then never returns (§3.10) |
| "No guard, no routes" | true at boot; on a running machine zebra keeps the kernel routes | zebra runs with `-r` (§3.10) |
| unreachable route key `metric` | `preference` | IfState 2.5.1 schema (§3.10) |
| `F` is three prefixes, no member list | the pools **and** the members' addresses, until step 3 | fixtures pin loopbacks outside the pools (§3.1) |
| I9 "with TTL 255" for BGP | TTL 255 for BFD only | eBGP on a connected link sends TTL 1 |
| a leaf's underlay as the "outside" in `routed-fabric` | a non-member only | a member's own `egress` chain drops it first (§3.3) |
| `arp_ignore` "assumed" | set by routed-fabric, proven | every member answered ARP for its loopback on the LAN (§3.8) |
| the fallback for a rejected transit split | removed | O1 is yes |
| "`access` is enforced on the spine", also for pods | enforced for what the spine **relays**; pods and NodePorts on a kube node are kube's to guard (L1) | Cilium delivers to a local pod before netfilter (K41) |
| `rp_filter = 0` per fabric link | not set | the value does not hold (reads 2); the design does not lean on it (§3.8) |
| "A spine can forge": one line | spelled out (L3) | kube's SPEC §6.12 note needs the fabric's side |

## 1. Threat model

Attackers:

| ID | Who | Holds |
|---|---|---|
| A1 | Host on a member's underlay LAN | L2 access. No key. Can forge any source, answer ARP, run a rogue DHCP server or send RAs, use a member as next hop. |
| A2 | Internet host | Reaches WireGuard ports, a border's upstream address, and owned prefixes through a transit tunnel. Can forge sources. |
| A3 | Rogue leaf | Root on a real member. Valid keys, valid BGP session. Any `access`. May be a kube node. |
| A4 | Rogue pod | Pod network identity on a kube member. No host root. |
| A5 | Local user | Unprivileged shell on a member. |
| A6 | Recorder | Captures underlay traffic now, gets a key (or a quantum computer) later. |

Trusted (the TCB). A compromise here is out of scope:

- **Spines.** A spine relays everything. A rooted spine can read, drop
  and forge relayed traffic. Only application TLS helps.
- **The upstream end of a transit tunnel**, for the owner's outside
  traffic only.
- The admin machine and the clan vars store.

Blast-radius goal for A3: a rogue leaf reaches only what its contract
names, and speaks only as itself.

## 2. Invariants

Each is one testable sentence. "Fabric address" = loopback pool,
transfer pool, ULA /48 (set `F`). "Fabric link" = a WireGuard adjacency
interface (`rf…`). "Local link" = `lo`, the fabric dummy, `cilium*`,
`lxc*`. "Inside link" = a link another service declared inside
(`clan._networkFacts.fabricInside`). Every other link is **outside**.

Safety:

- **I1.** A packet from an outside link is never delivered to, or
  forwarded towards, a fabric address.
- **I2.** A packet from an outside or inside link with a fabric source
  is dropped.
- **I3.** A packet from an outside link is never forwarded into a
  fabric link.
- **I4.** A packet from a fabric link leaves only by a fabric link (on a
  spine), a local link or an inside link. A leaf never relays between
  fabric links.
- **I5 (source contract).** On a fabric link a packet is accepted only
  if its source is in the set the peer may announce on that link.
  WireGuard and nft use the same set.
- **I6 (destination contract, `access`).** On a fabric link a packet is
  accepted only if its destination is in the set announced to that
  peer. A `client` cannot reach a pod through a spine. Nobody reaches an
  address it has no route for.
- **I7.** No fabric link has a 0/0 ACL. Outside sources cross only a
  transit tunnel, and end on its owner.
- **I8.** A packet to a fabric address never leaves by an outside link,
  also when its route is gone or a bogus more-specific route exists.
- **I9.** BGP and BFD of a link answer only that link's peer address,
  sent to this end's address on that link. BFD is single hop and has
  TTL 255. (No TTL rule for BGP: GTSM is refuted, §3.5.)
- **I10.** A leaf can originate only: its own /32 and /128; pod blocks
  of its clusters at node mask; `shared-bgp` VIP host routes of its
  clusters; a `node-bgp` VIP only when it is the pool owner. Never a
  default route. Never another member's host route.
- **I11.** I1..I9 hold with `networking.firewall.checkReversePath`
  off, kernel `rp_filter` off, BGP down, and conntrack empty.

Stability:

- **I12.** The guard is stateless. A flow whose two directions use
  different spines passes.
- **I13 (no lockout).** No rule matches a packet that neither uses a
  fabric link nor has a fabric address. The underlay deploy path (hard
  rule 11) cannot be cut by this service.
- **I14.** FRR does not start while the guard table is missing, and
  starts by itself when the table is back (§3.10 says what this does
  not cover).
- **I15.** A deploy that changes nothing restarts nothing. An nft change
  loads atomically. No BGP session resets.
- **I16.** Rotating the keys of one adjacency touches no other
  adjacency.
- **I17 (after step 8).** Adding or removing a member changes rendered
  config only on that member and its spines.

Known limits (state them in SPEC, do not hide them):

- **L1 (the boundary with kube).** Pods are guarded by kube, not by the
  fabric's nft table. With Cilium's eBPF host routing a packet that
  arrives on a Cilium device (every fabric link of a kube node is one)
  for a pod **on that node** is delivered at tcx ingress and never
  enters netfilter (`k3s-hostile` K41: 3 of 3 requests reach the pod,
  the contract rule counts 0; kube probe round). The fabric's table on
  a kube spine sees only what the node **relays**: traffic between
  fabric links, including traffic for pods on other nodes (K40a, K40).
  So:
  - the fabric's table guards the fabric links and, after step 4, the
    transit tunnels: who may send what into a link, and what may leave
    by which link;
  - **"an outsider or a leaf that is no cluster member cannot reach a
    pod" is a kube invariant**, not a fabric one. Kube closes it with a
    `CiliumClusterwideNetworkPolicy` (`ingressDeny` `fromEntities:
    world`; a fabric member outside the cluster is `world` to Cilium).
    That policy covers both cases: the pod on the node itself and the
    pod on another node;
  - I6 on a kube spine is therefore a second layer for pods on other
    nodes and no layer at all for pods on the spine itself. Never claim
    that the fabric table alone protects pods on a Cilium node;
  - what the fabric always gives kube, below Cilium: the WireGuard ACL
    (I5). A leaf's packet reaches Cilium only with a source that leaf
    may announce, so a policy by source address or entity judges the
    real sender.
  NodePorts and LoadBalancer addresses follow the same rule: Cilium
  answers them on the first Cilium node on the path. A spine answers a
  LoadBalancer address for a leaf's traffic and judges the Service's
  source ranges there (kube probe round); the `client` leaf of
  `k3s-hostile` gets an answer from a NodePort on both nodes (K10n,
  K13). `access` does not limit either; kube's NodePort-by-source
  design does (design-kube §3.5).
- **L2.** A kube member can announce any pod block of its own cluster
  (Cilium IPAM is dynamic). R-A5 residual.
- **L3.** A rooted spine, and what "a spine can forge member sources"
  means (SPEC.md §6.12 states it for kube). A spine relays, so on a
  leaf's link from a spine every member address is a legal source: the
  leaf's ACL and its `src` sets hold all loopbacks and, per `access`,
  the pod and VIP blocks. The fabric design does **nothing** against a
  spine that sends a packet with another member's address as source,
  and cannot: the leaf has no way to tell a relayed packet from a
  forged one. What the design does do:
  - only a **spine** can. A leaf cannot (I5: its spine's link accepts
    the leaf's own addresses only; F11, C03), an outsider cannot (I2);
  - a spine cannot forge towards another **spine** more than
    `spineTransitRoutes` allows, and it cannot make a leaf or an
    outsider's forged packet look relayed, because it drops those on
    the way in;
  - a spine cannot forge a BGP or BFD speaker of another link (I9 pins
    each session to its own link and transfer addresses).
  So every by-source rule above the fabric (kube's node firewall,
  Cilium policy by source, a Service's source ranges) protects against
  leaves and outsiders only. Against a rooted spine only TLS, tokens
  and mTLS help. A spine is in the TCB (§1).
- **L4.** A member can reset its **own** BGP session: with graceful
  restart FRR reads a second TCP connection from an established peer as
  "the peer restarted" (`hostile-fabric` FINDING I9, F23d). Nobody else
  can: I9 pins the source to the link's peer address.
- **L5.** I14 guards a start of FRR. A guard table removed at run time
  is not noticed (§3.10).

Each invariant and the verdict that proves it:

| Invariant | Proof on the prototype |
|---|---|
| I1 | `hostile-fabric` F03..F07 (through the spine), F20 (ARP) |
| I2 | F08, F09, F25 |
| I3 | F05; `probe-transit-split` T05 |
| I4 | F17, F19 |
| I5 | F11, C02, C03 |
| I6 | F18, F19; kube K40 (§9 A2) |
| I7 | C04; `probe-transit-split` T08 (step 4 for the rest) |
| I8 | F21, F22; `routed-fabric` `ROUTED_FABRIC_FORWARD_FILTER_OK` |
| I9 | F23, F23d, F24, F24b |
| I10 | F12..F16; `node-bgp` owner: NOT-RUN (step 3) |
| I11 | `probe-transit-split` runs with `checkReversePath = false`; `hostile-fabric` F08, F25 are counted by the guard at `raw`, before any reverse-path check. A run of `hostile-fabric` with `checkReversePath = false` on every member: NOT-RUN |
| I12 | S01 |
| I13 | by construction (every rule names a fabric link or a fabric address). `hostile-fabric` F01, F02 scan the underlay after the guard loaded and the members' underlay still answers ARP and ping. A deploy over the underlay with the guard on: NOT-RUN (no suite deploys) |
| I14 | F26, F26b; `probe-fabric-boot` |
| I15 | F27, FINDING I15 |
| I16, I17 | NOT-RUN (steps 6 and 8) |

## 3. Target design

### 3.1 Trust model

Two link classes carry fabric traffic. Nothing else does.

| Class | Links | Rule |
|---|---|---|
| fabric | `rf…` adjacency | per-link contract (`from`, `to`) |
| local | `lo`, `rflo…`, `cilium*`, `lxc*` | this machine, trusted |
| inside | declared by the owner of the link (router zone, NAT64/CLAT host link) | acts as this machine; may send to the fabric; a fabric source from it is forged |
| outside | everything else: underlay, WAN, **transit tunnel `rt…`** | never touches a fabric address or a fabric link |

Address sets:

- `F` = `loopback4Pool`, `transfer4Pool`, ULA /48, **and every
  member's stable address**. The prototype keeps the member list
  because fixtures pin loopbacks outside the pools (the kube suites use
  `192.168.77.x` and `fd00:77::x`). When assertion A5 lands (§3.7) and
  the fixtures move into the pools, drop the member list: then no nft
  set changes when a member joins.
- per link: `src` = cidrs(`from`) + the peer's transfer address;
  `dst` = cidrs(`to`) + this end's transfer address.

### 3.2 The link contract (one function, three consumers)

**VERIFIED-VM** (`hostile-fabric` C01..C04, F11, F18, F19; every suite
of §6 runs on it). In `mkAdjacency`, replacing `cryptoRoutes` and
`allowedIPs` (`default.nix:811-831`). `importRoutes` and `export` are
the two existing values (`default.nix:782-810`); they stay as they are
and get one more reader. This is the code that ran:

```nix
# D73 (link contract): `import` is what the peer may announce on this
# link, and so every source it may send; `export` is what it is sent
# routes for, and so every destination it may address. WireGuard's
# AllowedIPs, the FRR lists and the nft sets all read these two values.
cidrsOf = routes:
  routes.hosts
  ++ routes.vips
  ++ map (pod: pod.cidr) routes.pods
  ++ routes.services
  ++ routes.extra;
sources = lib.unique (cidrsOf importRoutes ++ [
  "${remoteAddress.ipv4}/32"
  "${remoteAddress.ipv6}/128"
]);
destinations = lib.unique (cidrsOf export ++ [
  "${localAddress.ipv4}/32"
  "${localAddress.ipv6}/128"
]);
allowedIPs =
  sources
  ++ lib.optionals externalTransit ["0.0.0.0/0" "::/0"];   # until step 4
```

`sources` and `destinations` join the `inherit` list of the adjacency
record (`default.nix:853-879`), the fact
`clan._networkFacts.fabric.<i>.adjacencies.<r>` (schema in
`lib/kube-cluster/network-facts.nix:37-54`: two `strList` options) and,
in step 3, the `routed_fabric` export.

Consumers:

1. **FRR.** Unchanged: `frr.nix:222-250` reads `adjacency.import` and
   `adjacency.export`.
2. **WireGuard.** `allowedips = adjacency.allowedIPs` (`default.nix:1120`).
3. **nft.** Sets `src4_<L>`, `src6_<L>`, `dst4_<L>`, `dst6_<L>` (§3.3).

Why `allowedIPs = sources` is enough on **every** role pair:

- Inbound: WireGuard checks the source. Legal sources are `import`.
- Outbound: WireGuard needs the destination in the ACL. The kernel only
  routes into the link what BGP learned on it. That is `import` again.
- `export` was in the ACL for no reason. On a leaf it allowed the
  leaf's own addresses as *inbound* sources (self-spoof).

What each end holds (verified against `default.nix:595-622`, and C03
reads the running ACL of a spine's leaf link: the leaf's /32, /128 and
its two transfer addresses, nothing else):

| End | `import` (ACL, sources) | `export` (destinations) |
|---|---|---|
| spine, peer leaf | the leaf's /32, /128, its clusters' VIP blocks, pod CIDR, services | all loopbacks; VIPs, pods, services per the leaf's `access` |
| leaf, peer spine | all loopbacks; VIPs, pods, services per own `access` | own /32, /128, own clusters' blocks |
| spine, peer spine | `spineTransitRoutes` | `spineTransitRoutes` |

The two ends mirror: `sources(A→B)` without A's view of B's transfer
address equals `destinations(B→A)` without B's own transfer address.
C01 checks it on the running fixture. Pin it with a nix-unit test too
(§5, `test_contractMirror`), not an assertion (one machine cannot
evaluate the other's `mkAdjacency`).

ICMP errors (path MTU) keep working: **VERIFIED-VM** (`hostile-fabric`
S03, FINDING A7). A spine that cannot forward a packet answers from its
**loopback** in both families ("need to frag (mtu 1300)" from the hub's
/32, "packet too big" from its /128), because zebra installs BGP routes
with `set src <loopback>` (`frr.nix:461-472`). The loopback is in every
`import`. No transfer pool is needed in the source sets.

### 3.3 nftables: one table, the same shape on every member

**VERIFIED-VM**: the table below loaded and ran in every suite of §6
(nftables 1.1.x of the pinned nixpkgs). Replaces `default.nix:1279-1339`
and the `firewall.interfaces` block at `1893-1911`. Rendered on every
member that has an adjacency (a leaf too: a kube leaf forwards).

What it looks like on a machine. `<L>` is a fabric link name, `<peer>`
its remote machine, `<rflo>` the dummy, `<inside>` =
`config.clan.networkFacts.fabricInside`:

```
table inet routed-fabric-<instance> {
  set owned4  { … }  set owned6  { … }        # only the R7 transit rules read them (until step 4)
  set fabric4 { type ipv4_addr; flags interval; auto-merge;
                elements = { <loopback4Pool>, <transfer4Pool>, <every member's /32> } }
  set fabric6 { type ipv6_addr; flags interval; auto-merge;
                elements = { <ula>::/48, <every member's /128> } }
  # per fabric link <L>:
  set src4_<L> { type ipv4_addr; flags interval; auto-merge; elements = { … } }
  set src6_<L> { … }  set dst4_<L> { … }  set dst6_<L> { … }
  chain link_<L> {
    ip  saddr != @src4_<L> counter drop comment "<peer>: source outside its contract"
    ip6 saddr != @src6_<L> counter drop comment "<peer>: source outside its contract"
    ip  daddr != @dst4_<L> counter drop comment "<peer>: destination outside its contract"
    ip6 daddr != @dst6_<L> counter drop comment "<peer>: destination outside its contract"
    accept
  }

  # 1. Addresses. Stateless, before conntrack, input and forward alike.
  chain ingress {
    type filter hook prerouting priority raw; policy accept;
    iifname vmap { "<L1>" : goto link_<L1>, "<L2>" : goto link_<L2> }
    iifname { "lo", "<rflo>", "cilium*", "lxc*" } accept
    ip  saddr @fabric4 counter drop comment "fabric source from outside the fabric"
    ip6 saddr @fabric6 counter drop comment "fabric source from outside the fabric"
    iifname { <inside> } accept                       # only if <inside> != []
    ip  daddr @fabric4 counter drop comment "outside to a fabric address"
    ip6 daddr @fabric6 counter drop comment "outside to a fabric address"
  }

  # 2. Topology. Only packets that use a fabric link are judged.
  chain forward {
    type filter hook forward priority filter - 5; policy accept;
    iifname { <all L> } goto from_fabric
    oifname { <all L> } goto into_fabric
  }
  chain from_fabric {
    oifname { <all L> } accept                        # SPINE ONLY: relay
    oifname { "cilium*", "lxc*", <inside> } accept
    counter drop comment "from the fabric to a link outside it"
  }
  chain into_fabric {
    iifname { "cilium*", "lxc*", <inside> } accept
    counter drop comment "from outside into a fabric link"
  }

  # 3. Leak guard. Forwarded and locally generated alike.
  chain egress {
    type filter hook postrouting priority filter; policy accept;
    oifname { <all L>, "lo", "<rflo>", "cilium*", "lxc*" } accept
    ip  daddr @fabric4 counter drop comment "fabric destination on a link outside the fabric"
    ip6 daddr @fabric6 counter drop comment "fabric destination on a link outside the fabric"
  }
}
```

The Nix that renders it (the code that ran; `nftSet`, `quoted`,
`ownedOf`, `stableHosts`, `loopbackName`, `interfaceNames`,
`fabricInterfaces`, `transitInterfaces` exist on `main`):

```nix
isV6 = lib.hasInfix ":";
v4Of = builtins.filter (prefix: !(isV6 prefix));
v6Of = builtins.filter isV6;
# F: the fabric's own addresses. The pools, and the members' addresses
# for a pinned one outside its pool.
fabricAddresses = {
  "4" = lib.unique ([loopback4PoolRecord transfer4PoolRecord] ++ v4Of stableHosts);
  "6" = lib.unique (["${ulaBase}::/48"] ++ v6Of stableHosts);
};
contractLinks = builtins.filter (adjacency: !adjacency.externalTransit) adjacencies;
localLinks = ["lo" loopbackName "cilium*" "lxc*"];
podLinks = ["cilium*" "lxc*"];
declaredInside = config.clan.networkFacts.fabricInside;
guard = adjacencies != [];
guardTransit = transitInterfaces != [] && border != null;       # R7, until step 4
guardTable = ''
  ${nftSet "owned4" "4" (ownedOf 4)}
  ${nftSet "owned6" "6" (ownedOf 6)}
  ${nftSet "fabric4" "4" fabricAddresses."4"}
  ${nftSet "fabric6" "6" fabricAddresses."6"}
  ${lib.concatMapStrings (adjacency: ''
    ${nftSet "src4_${adjacency.name}" "4" (v4Of adjacency.sources)}
    ${nftSet "src6_${adjacency.name}" "6" (v6Of adjacency.sources)}
    ${nftSet "dst4_${adjacency.name}" "4" (v4Of adjacency.destinations)}
    ${nftSet "dst6_${adjacency.name}" "6" (v6Of adjacency.destinations)}
    chain link_${adjacency.name} {
      ip saddr != @src4_${adjacency.name} counter drop comment "${adjacency.remoteName}: source outside its contract"
      ip6 saddr != @src6_${adjacency.name} counter drop comment "${adjacency.remoteName}: source outside its contract"
      ip daddr != @dst4_${adjacency.name} counter drop comment "${adjacency.remoteName}: destination outside its contract"
      ip6 daddr != @dst6_${adjacency.name} counter drop comment "${adjacency.remoteName}: destination outside its contract"
      accept
    }
  '') contractLinks}
  chain ingress {
    type filter hook prerouting priority raw; policy accept;
    ${lib.optionalString (contractLinks != []) ''
      iifname vmap { ${lib.concatMapStringsSep ", " (adjacency: ''"${adjacency.name}" : goto link_${adjacency.name}'') contractLinks} }
    ''}
    iifname ${quoted (localLinks ++ transitInterfaces)} accept
    ip saddr @fabric4 counter drop comment "fabric source from outside the fabric"
    ip6 saddr @fabric6 counter drop comment "fabric source from outside the fabric"
    ${lib.optionalString (declaredInside != []) "iifname ${quoted declaredInside} accept"}
    ip daddr @fabric4 counter drop comment "outside to a fabric address"
    ip6 daddr @fabric6 counter drop comment "outside to a fabric address"
  }
  chain forward {
    type filter hook forward priority filter - 5; policy accept;
    ${lib.optionalString guardTransit ''
      # today's four R7 rules, unchanged but for the set names (default.nix:1321-1329)
    ''}
    ${lib.optionalString (fabricInterfaces != []) ''
      iifname ${quoted fabricInterfaces} goto from_fabric
      oifname ${quoted fabricInterfaces} goto into_fabric
    ''}
  }
  chain from_fabric {
    ${lib.optionalString (ownRole == "spine") "oifname ${quoted interfaceNames} accept"}
    oifname ${quoted (podLinks ++ declaredInside)} accept
    counter drop comment "from the fabric to a link outside it"
  }
  chain into_fabric {
    iifname ${quoted (podLinks ++ declaredInside ++ transitInterfaces)} accept
    counter drop comment "from outside into a fabric link"
  }
  chain egress {
    type filter hook postrouting priority filter; policy accept;
    oifname ${quoted (interfaceNames ++ localLinks)} accept
    ip daddr @fabric4 counter drop comment "fabric destination on a link outside the fabric"
    ip6 daddr @fabric6 counter drop comment "fabric destination on a link outside the fabric"
  }
'';
# …
networking.nftables.tables."routed-fabric-${instanceName}" = lib.mkIf guard {
  family = "inet";
  content = guardTable;
};
```

Until step 4 a transit link (`externalTransit`) is exempt: it is not in
the `vmap`, it is accepted at the top of `ingress`, its R7 rules stay
first in `forward`, and it counts as a fabric link in `from_fabric`
(spine) and in `egress`. `routed-fabric-transit` passes on this
(`ROUTED_FABRIC_TRANSIT_OK`). Step 4 deletes all of that.

Notes for the implementer (each one was met in a run):

- `ip saddr …` in an `inet` table only matches IPv4, `ip6 …` only IPv6.
  That is why each check is written twice and the chain ends in
  `accept`.
- `iifname vmap { "x" : goto chain }` and wildcard names (`"cilium*"`)
  in anonymous sets load (§9 A1). A filter chain on `postrouting` is
  legal in `inet` and sees locally generated packets (§9 A3; F21 and
  F22 count there).
- A set with no elements is legal (`nftSet` omits `elements`).
  `!= @empty` then drops everything of that family. Correct: a link
  with no v6 contract carries no v6.
- Default-deny is done with a final `drop` inside `from_fabric` /
  `into_fabric`, **not** with `policy drop` on the base chain. A base
  policy would judge LAN→WAN on a router. Ownership by link, as G25.
- The destination contract is checked **before NAT**. That is why
  `from_fabric` needs no address rule: a reply to a router's
  masqueraded LAN flow arrives addressed to the router's loopback
  (in `dst`), is de-NATed, then leaves by the inside link
  (`router-kube`).
- The `ingress` chain sits at `raw` (-300), ahead of the NixOS
  reverse-path chain (mangle, -150). Its counters count also where
  `checkReversePath` is strict; tests may rely on them.
- **A member cannot be the test's "outsider".** A packet a member
  sends to a fabric address by its underlay never leaves it: its own
  `egress` chain drops it. A test of "a spine forwards nothing from
  outside" needs a machine that is no member (`hostile-fabric`
  `outsider`). The old `routed-fabric` subtest that used a leaf's
  underlay now proves I8 on the leaf instead.
- Counters reset when the table reloads. Tests read a counter before
  and after an attack with no deploy between, and find the rule by its
  `comment`, never by a set or chain name.
- Many links: equal sets may share one name by content hash, as the
  prefix-lists do (`frr.nix:100-108`). Optional. Do it only if a spine
  with many leaves loads slowly. NOT-RUN.
- Keep `firewall.extraForwardRules` (`default.nix:1915-1917`). It only
  matters when another service turns on the NixOS forward filter.

What each old gap hits (all VERIFIED-VM in `hostile-fabric`):

| Gap | Rule | Verdict |
|---|---|---|
| F05 underlay forwarded into the fabric | `ingress` "outside to a fabric address"; `into_fabric` for any other destination | F05, F06 |
| F07 spine answers on its fabric address | `ingress` "outside to a fabric address" | F07 |
| F08, F09 forged member source | `ingress` "fabric source from outside the fabric" | F08, F09, F25 |
| F11 leaf forges another member | WireGuard ACL = `sources`; `link_<L>` second layer | F11, C03 |
| F17 leaf routed out to the underlay | `link_<L>` destination contract; `from_fabric` final drop | F17, F19 |
| R-A4 `access` | `link_<L>` destination contract on the spine | F18; kube K40 |

BGP and BFD, in `networking.firewall.extraInputRules` (replaces the
`firewall.interfaces` block at `default.nix:1899-1911`). The code that
ran:

```nix
extraInputRules =
  upstreamFirewallRules
  + lib.concatMapStrings (adjacency: ''
    iifname "${adjacency.name}" ip saddr ${adjacency.remote.ipv4} ip daddr ${adjacency.local.ipv4} tcp dport 179 accept
    iifname "${adjacency.name}" ip saddr ${adjacency.remote.ipv4} ip daddr ${adjacency.local.ipv4} udp dport 3784 ip ttl 255 accept
    iifname "${adjacency.name}" ip6 saddr ${adjacency.remote.ipv6} ip6 daddr ${adjacency.local.ipv6} tcp dport 179 accept
    iifname "${adjacency.name}" ip6 saddr ${adjacency.remote.ipv6} ip6 daddr ${adjacency.local.ipv6} udp dport 3784 ip6 hoplimit 255 accept
  '') adjacencies;
```

4784 (multihop BFD) is gone from fabric links: **VERIFIED-VM**. Fabric
BFD is single hop on 3784 with TTL 255 (`probe-fabric-session` "as
rendered": `BFD: Type: single hop`, bound to the link; `hostile-fabric`
F24, F24b). This holds only while no `ttl-security` is rendered on the
neighbor (§3.5). There is no TTL match on 179: eBGP between directly
connected peers sends TTL 1.
Upstream peers keep `upstreamFirewallRules` (`default.nix:1192-1200`).

### 3.4 Transit tunnels are outside links

Today `externalTransit` puts `0.0.0.0/0` and `::/0` on a **fabric**
adjacency (`default.nix:828-831`). Consequences, all verified in code:

- the WireGuard source filter of that link is gone;
- the link is a Cilium device and a kube "transport interface", so the
  kube input rules accept member and pod sources from it
  (`lib/kube-cluster/firewall.nix:44-66`, guard by `iifname`). Today's
  transit filter is in the **forward** hook only (`default.nix:1321`).
  A forged member source from the Internet reaches the owner's
  cluster ports in the input path;
- BGP carries routes the filter drops (R-A3); `sourceReturn` without it
  blackholes (R-A6); a border needs a dummy upstream peer (R-A7).

Target: a transit tunnel is its **own WireGuard interface** `rt<hash>`,
class *outside*. No BGP on it. No transfer prefix. If the same two
machines are also adjacent, they have two tunnels. That costs one UDP
port and one key pair. It buys I7.

Declared on the owner only. The upstream end is derived, like spine
pairs are (`default.nix:341-356`).

```nix
# roleInterface, inside border (default.nix:181-234)
transit = lib.mkOption {
  type = lib.types.attrsOf (lib.types.submodule {
    options = {
      return = lib.mkOption { type = lib.types.bool; default = true;
        description = "Replies from ownedPrefixes leave through this tunnel (a policy table)."; };
      table = lib.mkOption { type = lib.types.nullOr lib.types.ints.u32; default = null; };
      priority = lib.mkOption { type = lib.types.nullOr lib.types.ints.u32; default = null; };
      port = lib.mkOption { type = lib.types.nullOr lib.types.port; default = null; };
      underlayMtu = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; };
    };
  });
  default = {};
  description = "Tunnels that bring outside traffic for ownedPrefixes to this border, keyed by the member that has the public path.";
};
```

```nix
# perInstance let-block, beside peerNames (default.nix:633-639)
transitUp = builtins.attrNames (if border != null then border.transit else {});   # I am the owner
transitDown = builtins.filter                                                      # I am the upstream end
  (name: (allMachines.${name}.settings.border.transit or {}) ? ${machine.name})
  memberNames;
transitKey = a: b: "transit:${fabric.adjacencyKey instanceName a b}";
transitName = key: "rt${builtins.substring 0 13 (builtins.hashString "sha256" key)}";
```

Rendering:

| | Owner end | Upstream end |
|---|---|---|
| WireGuard ACL | `0.0.0.0/0`, `::/0` | the owner's `ownedPrefixes` only |
| Routes (IfState) | if `return`: `from <owned>` → table → `default dev <rt>` (today's `ifstateRules`/`ifstateRoutes`, `default.nix:1131-1165`, without `via`) | `<owned> dev <rt>` in the main table |
| Forwarding sysctl | no change | on (derived: `forwarding = spine \|\| transitDown != []`) |
| nft | below | below |

The upstream end's WireGuard does most of the work: it accepts from the
tunnel only owned sources, and sends into it only owned destinations.

nft additions, same table:

```
# owner end, in chain ingress, before the "fabric source" rule:
iifname { <rt…> } ip  daddr != @owned4 counter drop comment "transit: outside reaches ownedPrefixes only"
iifname { <rt…> } ip6 daddr != @owned6 counter drop comment "transit: outside reaches ownedPrefixes only"
# then it falls through: an outside link. A fabric source from it is
# dropped. into_fabric drops it if it is routed on. Nothing to add.

# upstream end, in chain forward, first rules:
oifname { <rt…> } ip  saddr @ours4 counter drop comment "transit: our own source from outside"
oifname { <rt…> } ip6 saddr @ours6 counter drop comment "transit: our own source from outside"
# ours = F + cidrsOf spineTransitRoutes + the owner's ownedPrefixes

# both ends (R-A10):
chain clamp {
  type filter hook forward priority mangle; policy accept;
  oifname { <rt…> } tcp flags syn tcp option maxseg size set rt mtu
  iifname { <rt…> } tcp flags syn tcp option maxseg size set rt mtu
}
```

`ours` matters because Cilium maps a source address to an identity. A
packet from the Internet with a pod source must not reach the owner
(§9 A9). The upstream end is where nft can still see it.

Cilium must still serve VIPs on the tunnel. Export it, marked:

```nix
# lib/node-transport-interface.nix:47-60, add to the interface submodule
outside = lib.mkOption { type = t.bool; default = false;
  description = "The link carries outside sources (a transit tunnel): a Cilium device, never a trusted source of cluster traffic."; };
```

```nix
# lib/kube-cluster/transport.nix:62-76, add to the result
fabricInterfaces = sorted (builtins.filter (name: !(interfaces.${name}.outside or false)) ifaceNames);
```

`interfaces` (all) still feeds Cilium `devices` and the MTU.
`lib/kube-cluster/service.nix:1050-1054` (reverse-path accept) and the
`mkInputRules` call at `1061` switch to `fabricInterfaces`.
Bump `node_transport.schemaVersion` to 3 (and the check at
`transport.nix:43`).

Deleted with this: adjacency options `externalTransit`, `sourceReturn`,
`sourceReturnTable`, `sourceReturnPriority`; `transitOwners`;
`guardTransit`; the fabric-traffic-over-transit special case; the
`transitCutPeers` assertion proposed in R-A3 (not needed: a fabric link
is never transit).

**Decided: the owner said yes (O1).** The fallback of the first draft
is removed.

**VERIFIED-VM by probe** (`probe-transit-split`, 2026-11-27;
`services/routed-fabric/tests/vm/probe-transit.nix`, verdicts in
`probes/fabric/probe-transit-split.txt`). Topology: `isp` (outside),
`cloud` (spine, upstream end), `home` (spine, owner of
`198.51.100.0/24` and `2001:db8:100::/64`), `far` (leaf on `home`).
`cloud` and `home` are also fabric-adjacent, so they have two tunnels.
The probe declares the tunnel `rt0` by hand exactly as the rendering
table above says, on the prototype of steps 1 and 2:

| Verdict | Shows | Result |
|---|---|---|
| T00 | fabric traffic between the two ends uses the `rf…` link; 0 packets on `rt0` | safe |
| T01 | `isp` reaches an owned address on `home`; the reply leaves `home` by `rt0` (3 of 3), 0 replies on `home`'s underlay; IPv4 and IPv6 | safe |
| T02 | `isp` to a fabric address through `cloud`: `cloud` drops it ("outside to a fabric address" +3), 0 reach `home` | safe |
| T03 | forged member source from `isp`: `cloud` drops it ("fabric source from outside the fabric" +3), 0 enter the tunnel | safe |
| T04 | an owned prefix as a source from `isp`: `cloud` drops it ("transit: our own source from outside" +3) | safe |
| T05 | an owned address `home` routes on into `far`'s link: `home` drops it ("from outside into a fabric link" +3), `far` sees 0 | safe |
| T06 | a rooted `home` sends a source it does not own into the tunnel: `cloud`'s WireGuard counts 3 rx errors, nothing leaves `cloud` | safe |
| T06b | a rooted `cloud` sends a destination `home` does not own: `home` drops it ("transit: outside reaches ownedPrefixes only" +3) | safe |
| T07 | TCP `isp` → `home`: the SYN arrives with MSS 1260 (IPv4) and 1240 (IPv6) for a tunnel MTU of 1300; the SYN-ACK the same | safe |
| T08 | the fabric link between the two ends has no 0/0 ACL | safe |

What the probe settles:

- The derivation works without a `via`: `default dev <rt>` in the
  policy table on the owner, `<owned> dev <rt>` in the main table on
  the upstream end, rendered by IfState (`to`, `dev`, `table`; rules
  `from`, `table`, `priority`).
- The **return path** works with `networking.firewall.checkReversePath
  = false` on both ends (I11). The rule `from <owned>` is enough.
- `tcp option maxseg size set rt mtu` in an `inet` table at
  `forward priority mangle` clamps both families. The clamp on the
  upstream end does the work for the SYN (it is forwarded into the
  tunnel there); the owner's own SYN-ACK already carries the tunnel
  MSS because its route's device is the tunnel.
- The guard of §3.3 needs **no change** for the tunnel: `rt…` is simply
  not in any of its lists, so it is an outside link. T02, T03 and T05
  are counted by the unchanged §3.3 rules. Only the three additions
  above are new.
- T05 answers a question of the brief: outside traffic for an owned
  address **ends on the owner**. It is never forwarded on into a
  fabric link (I3). An owned VIP whose backend is a pod on another node
  is reached because Cilium on the owner translates it first (kube
  design), never by plain forwarding.

What the probe did **not** run (NOT-RUN, all in step 4):

- the option `border.transit`, the derived ends, the key generator and
  the peer rendering by IfState (the probe exchanges keys in the test
  script; the link, routes and rules are IfState's);
- the three nft additions inside the service's own table (the probe
  loads them as a second table `probe-transit` on the same hooks; a
  drop in either table is final, so the result is the same);
- an owner that is a kube node: the tunnel as a Cilium device,
  `fabricInterfaces`, and a pod CIDR in `ours` (§9 A9);
- an upstream end that is not a spine (the derived forwarding sysctl);
- a tunnel MTU derived from the underlay (the probe pins 1300).

### 3.5 FRR policy changes

All in `frr.nix` unless said.

1. **No GTSM on fabric sessions. REFUTED** (`probe-fabric-session`,
   FRR 10.7.1, three runs). `neighbor <peer> ttl-security hops 1` works
   for BGP (the session comes up; a peer that sends BGP at TTL 64 gets
   no session). But it turns the neighbor's BFD session into a
   **multihop** one: `BFD: Type: multi hop`, UDP port 4784, no
   interface binding, `minimum-ttl 1`. So with GTSM:
   - 4784 must be open, or BFD stays down while BGP is up;
   - BFD no longer goes down with its link, and accepts any TTL;
   - a GTSM on one end only keeps the session down (a flag day per
     link).
   The rule is: **render no `ttl-security` on a fabric neighbor.**
   What protects the session instead is I9: the input rule names the
   link, the peer's transfer address, this end's transfer address and
   the port (§3.3). Nobody but the peer can put a packet with that
   source on that link (WireGuard ACL, then the contract). BFD stays
   single hop, bound to the link, port 3784, TTL 255 on the wire and in
   the rule.
   Upstream sessions keep their optional `ttlSecurity` (they have no
   tunnel around them). If an upstream peer uses it together with
   `bfd`, its BFD is multihop: the existing upstream rule already opens
   4784 for the declared upstream addresses.
   **Graceful restart: not decided by GTSM.** The probe restarts all of
   a leaf's FRR and watches the leaf's route on the hub for 20 s. It
   stayed 20 of 20 s in one run without GTSM, 9 of 20 s in another run
   without GTSM, and 10 of 20 s with GTSM. A full restart also restarts
   bfdd; whether the hub's BFD session (3 × 300 ms on `site`) times out
   before the leaf is back decides it, and with
   `bfd check-control-plane-failure` a BFD failure ends the helper
   mode. This is `main`'s behaviour, not the prototype's (the prototype
   changes no FRR line). `k3s-frr-failure` is the suite that pins what
   the repo promises here; it passes on the prototype
   (`FRR_BGPD_CRASH_OK`, `FRR_CILIUM_RESTART_OK`, `FRR_BAD_RELOAD_OK`,
   `FRR_DEPLOY_RELOADS_OK`, `FRR_FULL_RESTART_OK`, `FRR_DEAD_NODE_OK`).
2. **`node-bgp` owner only (R-A5).** In `default.nix`, beside
   `clusterRoutes` (557-582):
   ```nix
   originRoutes = name: facts: let
     routes = clusterRoutes facts;
     pools = lib.filterAttrs (_: pool:
       pool.delivery == "shared-bgp"
       || (pool.delivery == "node-bgp" && pool.owner == name)) facts.pools;
   in routes // {vips = lib.unique (lib.concatMap (pool: pool.blocks) (builtins.attrValues pools));};
   originRoutesFor = name: frr.mergeRoutes ([frr.emptyRoutes]
     ++ map (originRoutes name) (builtins.filter (facts: facts.members ? ${name}) clusterList));
   ```
   Use `originRoutesFor` for: the spine's `fromBase`, `localClusterRoutes`
   (583-585), and the `mkCilium` `routes` argument (942). Keep
   `clusterRoutes` for consumption and `spineTransitRoutes`.
   `clusterRoutesFor` (885-896) is then unused: delete it.
3. **No origination of `ownedPrefixes` (owner decision h).** No code.
   Fix the option text (3.6) and D63.
4. **Upstream sessions.** Unchanged: `acceptedPrefixes`, default deny,
   `maximum-prefix … restart 10`, optional `ttlSecurity`. No password
   (D63 stays).
5. **Unchanged, keep:** `bgp ebgp-requires-policy`, `no-export` on leaf
   import, exact host lists on the spine, `warning-only` limit,
   graceful restart, the `vtysh --dryrun` build check.

### 3.6 Option surface

NOT-RUN: no option changed in the prototype. The facts `sources`,
`destinations` and `fabricInside` did (below).
In `roleInterface` and `adjacencyOptions` (`default.nix:35-248`).

| Option | Change | Type |
|---|---|---|
| `ipv4` | typed | `nullOr ip.types.ipv4` |
| `ipv6` | typed | `nullOr ip.types.ipv6` |
| `loopback6Pool` | **add** (round 66): where pinned IPv6 loopbacks lie; null = `<ula>:0::/64` | `nullOr ip.types.ipv6Cidr` |
| `loopback4Pool`, `transfer4Pool` | typed | `ip.types.ipv4Cidr` |
| `adjacencies.<r>.extraAllowedIPs` | **rename** `extraPrefixes` (it is a route, an ACL and a contract entry) | `listOf ip.types.cidr` |
| `adjacencies.<r>.externalTransit` | **remove** (→ `border.transit`) | |
| `adjacencies.<r>.sourceReturn`, `sourceReturnTable`, `sourceReturnPriority` | **remove** (→ `border.transit.<r>.{return,table,priority}`) | |
| `access` | description: "Enforced on the spine: a member reaches only what it is sent routes for." | same enum |
| `border.ownedPrefixes` | typed; description: "Prefixes that end on this border: the upstream export filter, the transit tunnel's reach, the source-return rules. Nothing originates them." | `listOf ip.types.cidr` |
| `border.upstreamPeers.*.address` | typed (drop the assertion at 1519) | `ip.types.address` |
| `border.upstreamPeers.*.acceptedPrefixes` | stays `str`; assert the shape (R-A9 regex) | |
| `border.transit` | **add** (3.4) | attrs of submodule |
| `border.forwarding` | **remove**. Forwarding is derived: spine, or upstream end of a transit tunnel. A border ends outside traffic; it relays none. Grep the suites first (`eval-tests.nix:1059` sets it). | |
| `firewall.trust` | **remove**. No consumer. A trusted fabric link opens every port to every member and client. Each service opens its own ports by source. | |
| `firewall.openPort` | keep | |

Exports and facts:

- `routed_fabric` export (`routed-fabric-interface.nix`): schema 3; per
  adjacency add `sources`, `destinations` (lists of str); add
  `transit.<remote> = { name; port; mtu; owner = bool; }`.
- `clan._networkFacts.fabric.<i>.adjacencies.<r>`
  (`network-facts.nix:37-54`): add `sources`, `destinations`
  (**done in the prototype**; the hostile suite reads them). Drop
  `externalTransit`, `sourceReturn` in step 4.
- `clan._networkFacts.fabricInside` (`strList`, top level of the fact
  schema): **done in the prototype**. Who sets it (the gateway design
  owns the setters; proven by the gateway probe round):
  - the CLAT host link and the NAT64 host link: always
    (`lib/gateway/clat.nix` `[names.clat.host]`, `nat64.nix`
    `[names.nat64.host]`);
  - a router zone: only with `zones.<name>.fabric = true` (default
    false, H3). `unzoned.zones` is removed and `unzoned.source` is
    renamed `fabricSource` by the gateway design.
  The prototype here ran with the router's old option
  (`fabricInside = zonesOf cfg.unzoned.zones`); `router-kube` and
  `nat-gateway-kube` pass with the full guard on it. The guard reads
  only the fact, so the rename changes nothing in routed-fabric.
- `clan._networkFacts.forwardLinks` (list of interface-name patterns,
  `lib/kube-cluster/network-facts.nix`; owner: the gateway design).
  **A fabric obligation.** A CLAT host forwards IPv6 by default deny
  (`table inet clat`, chain `forward`, priority -10, final
  `counter drop comment "clat-forward"`); only `clat0` and the links in
  `forwardLinks` pass. routed-fabric must put every fabric link there:
  ```nix
  clan._networkFacts.forwardLinks = interfaceNames;   # every rf… (and rt…) link of this member
  ```
  Set it on every member that has an adjacency, not only on spines: a
  kube leaf forwards pod traffic into its fabric links, and a member
  that forwards nothing loses nothing by the entry. Without it a fabric
  member that is also a CLAT host is cut off from the fabric for
  forwarded IPv6.
  It does not conflict with the guard of §3.3. They are two base chains
  on the forward hook (`clat` at -10, the guard at `filter - 5`). A
  packet must be accepted by both, and an `accept` in one never
  overrides the other. The CLAT chain decides "may this link forward at
  all", the guard decides "may this packet use a fabric link". NOT-RUN
  together: `nat-gateway-kube` ran the guard beside the CLAT of `main`,
  which has no default deny yet. Run `nat-gateway-kube` and
  `k3s-clat` again when both land.
  Pin it with one nix-unit test, `test_fabricLinksAreForwardLinks`:
  on every fixture member, each adjacency's `interface` is an element
  of `config.clan.networkFacts.forwardLinks`.

### 3.7 Eval-time assertions

NOT-RUN (steps 3 and 4). Add (in the list at `default.nix:1366-1579`):

- **A1.** `border == null || (border.ownedPrefixes != [] && (border.upstreamPeers != [] || border.transit != {}))` (replaces 1508; R-A7).
- **A2.** Every `border.transit` key names a member, is not this
  machine, and that member has no `border.transit` entry back.
- **A3.** No owned prefix is shorter than /8 (v4) or /16 (v6)
  (replaces the string compare at 1512-1516).
- **A4.** No owned prefix overlaps `F` or a cluster pod or service CIDR.
- **A5.** A pinned `ipv4` lies in `loopback4Pool`; a pinned `ipv6` in
  `loopback6Pool` (round 66; null = `<ula>:0::/64`). Then `F` needs no member list, and the nft sets of
  the zone guard never change when a member joins. (Today the test
  fixtures pin `192.168.77.x` under the default pool; they set
  `loopback4Pool = "192.168.77.0/24"`.)
- **A6.** Transit tunnel names, ports and source-return tables join the
  existing collision checks (1456-1498, 1535-1551).
- **A7 (warning, not assertion).** `loopback4Pool` or `transfer4Pool`
  inside `10/8`, `172.16/12`, `192.168/16` or `100.64/10` on a machine
  whose underlay is DHCP: a LAN in that range would have its hosts
  dropped as "fabric source" (I13 risk). The default pools are in
  `198.18.0.0/15`.

Remove: 1523-1529 (`transitOwners`), 1531-1533 (`sourceReturn requires
border`), 1519.

### 3.8 Sysctls

- Forwarding (`default.nix:1290`, `1887-1890`):
  `forwarding = ownRole == "spine" || transitDown != [];` (step 4;
  until then today's `ownRole == "spine" || border.forwarding`).
- Per fabric and transit link, in the IfState interface
  (`default.nix:1097-1127`), key `sysctl`. **VERIFIED-VM**
  (`hostile-fabric` FINDING A8: on a fabric link of the hub the five
  values read back as set):
  ```nix
  sysctl = {
    ipv4 = { accept_redirects = 0; send_redirects = 0; accept_source_route = 0; };
    ipv6 = { accept_ra = 0; accept_redirects = 0; };
  };
  ```
  **No `rp_filter` here. REFUTED**: the first draft set
  `rp_filter = 0` "to say it out loud". IfState accepts the key, but
  the link reads `rp_filter = 2` afterwards (run 6). The design does
  not lean on the kernel filter (I11), so the key is dropped instead of
  fought for. Loose mode (2) only drops a source the machine has no
  route for at all.
- Global, `mkDefault`, set by routed-fabric (the address that leaks is
  the fabric's): **VERIFIED-VM** (`hostile-fabric` F20).
  ```nix
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.arp_ignore" = lib.mkDefault 1;
    "net.ipv4.conf.all.arp_announce" = lib.mkDefault 2;
  };
  ```
  netif's target baseline sets the same ARP keys; the two must agree
  on the values (1 and 2). routed-fabric keeps its own two lines: it
  also runs on an underlay netif does not manage. netif's sysctl
  baseline and ARP keys ran beside FRR in two k3s fabric suites with
  no effect on the sessions (netif probe round).
  Without it every member answers ARP for its fabric loopback on the
  underlay NIC (Linux default `arp_ignore = 0`): F20 on the prototype
  without the sysctl was a GAP ("Unicast reply" from the hub for its
  loopback). With it no member answers for a fabric address and each
  still answers for its underlay address. The guard table cannot help
  here: an `inet` table never sees ARP. IPv6 needs nothing: the kernel
  answers a neighbour solicitation only for an address of the link it
  arrived on.

### 3.9 Keys

- **One key pair per adjacency end** (R-A11). **NOT-RUN.** Replaces the machine key
  (`default.nix:1068-1079`, `1584-1600`).
  ```nix
  keyGenerator = remoteName: "${adjacencyGeneratorBase remoteName}-key";   # not shared
  privateKeyOf = remoteName: config.clan.core.vars.generators.${keyGenerator remoteName}.files.privatekey.path;
  publicKeyOf = remoteName: lib.trim (clanLib.getPublicValue {
    generator = keyGenerator remoteName;   # same name on both ends; per-machine store
    machine = remoteName; file = "publickey";
    flake = config.clan.core.settings.directory;
    default = throw "routed-fabric/${instanceName}: missing public key of '${remoteName}' for adjacency ${machine.name}<->${remoteName}";
  });
  ```
  One generator per peer in the `lib.concatMap` at `default.nix:1722-1813`
  (same script as today's, `restartUnits = ["ifstate.service"]`).
  Transit tunnels get the same with `transitKey`.
  The committed eval fixtures under `tests/fixtures/vars/per-machine/*`
  need the new generator directories.
- **Preshared key per adjacency. VERIFIED-VM** (probe P3,
  `hostile-fabric` P3 and P3b). One *shared secret* generator per
  adjacency, beside the three shared public ones, rendered as IfState
  `preshared_key`. It is the service's first shared secret and the only
  answer to attacker A6. The code that ran:
  ```nix
  adjacencyPskGeneratorName = remoteName: "${adjacencyGeneratorBase remoteName}-psk";
  # in the per-peer generator list (beside …-transfer4):
  {
    name = adjacencyPskGeneratorName remoteName;
    value = {
      share = true;
      files.psk = { owner = "root"; group = "root"; mode = "0400"; restartUnits = ["ifstate.service"]; };
      runtimeInputs = [pkgs.wireguard-tools];
      script = ''
        wg genpsk > "$out"/psk
      '';
    };
  }
  # on the peer (default.nix:1118-1126):
  preshared_key = "!include ${config.clan.core.vars.generators.${adjacencyPskGeneratorName adjacency.remoteName}.files.psk.path}";
  ```
  In the run every link of the four members had a preshared key, the
  two ends of a link had the same one, and the four adjacencies of the
  leaves had four different ones. The fabric came up and every later
  verdict passed with it. The generator name is derived from the
  adjacency key, so only the two ends declare it.
  Rotation is per link, like the key pair: regenerate, deploy both
  ends.

### 3.10 Fail closed

- **Unreachable aggregates. VERIFIED-VM** (`hostile-fabric` FINDING
  P2, F21; `k3s-data-plane` for the kube node, probe P2). IfState
  routes, main table, a high preference (the IfState key is
  `preference`, not `metric`):
  ```nix
  unreachableRoutes = map (prefix: {
    to = prefix;
    type = "unreachable";
    preference = 4294967000;
  }) [loopback4PoolRecord transfer4PoolRecord "${ulaBase}::/48"];
  ifstateRoutes = unreachableRoutes ++ …;          # default.nix:1131
  ```
  On a member it reads `unreachable 198.18.0.0/17 metric 4294967000`,
  `unreachable 198.19.0.0/16 metric 4294967000`, `unreachable
  <ula>::/48 dev lo metric 4294967000`. A BGP /32 or a connected /31 is
  more specific and wins. When it is withdrawn, the packet gets an
  error at once ("No route to host") and does not follow the default
  route. The `egress` chain of §3.3 is the second layer and the only
  one for a bogus more-specific route (F22).
  A fixture or a test that reads `routing.routes` must expect routes
  without `dev` and without `table` (§8.6).
- **FRR waits for the guard.** The check must **wait**, not fail at
  once. **REFUTED as first written** (`hostile-fabric` F26, run 4): the
  nixpkgs unit has `Restart=always`, `RestartSec=5`,
  `StartLimitBurst=3`, `StartLimitIntervalSec=180`. An `ExecStartPre`
  that exits 1 at once fails three times in ten seconds, the unit ends
  in `start-limit-hit`, and FRR stays down for good, also after the
  guard is back (`systemctl start frr` then fails until
  `systemctl reset-failed`). What ran:
  ```nix
  systemd.services.frr = {
    after = ["ifstate.service" "nftables.service"];
    serviceConfig.ExecStartPre = lib.mkIf guard (lib.mkBefore [
      (pkgs.writeShellScript "routed-fabric-${instanceName}-guard-present" ''
        for _ in $(${pkgs.coreutils}/bin/seq 1 40); do
          ${pkgs.nftables}/bin/nft list table inet routed-fabric-${instanceName} >/dev/null 2>&1 && exit 0
          ${pkgs.coreutils}/bin/sleep 2
        done
        echo "routed-fabric/${instanceName}: the guard table inet routed-fabric-${instanceName} is missing; FRR stays down" >&2
        exit 1
      '')
    ]);
  };
  ```
  One attempt waits 80 s (below the 90 s start timeout), so at most
  three attempts fall into 180 s and the start limit is never hit. FRR
  starts by itself within 2 s of the table loading. Do **not** use
  `requires`: a restart of `nftables.service` would restart FRR.
- **What this does and does not give** (state it in SPEC):
  - At boot, with no guard there are no BGP routes and no sessions:
    **VERIFIED-VM** (`probe-fabric-boot`: the leaf boots with its
    table deleted before FRR; no routing daemon, 0 BGP routes, the
    spine sees no session, the unreachable aggregates answer "No route
    to host"; FRR keeps retrying past the start-limit window and is
    active 0.5 s after the table loads).
  - On a running machine, a restart of FRR without the guard keeps the
    kernel's BGP routes: zebra runs with `-r` and leaves them
    (`hostile-fabric` FINDING I14: 5 routes before, 5 after). The
    sessions drop and the peers withdraw, so nothing arrives any more.
  - A guard table removed while FRR runs is not noticed. Only root can
    do that. `systemctl reload nftables` replaces the table in one
    transaction and resets no session (F27). `systemctl restart
    nftables` deletes and reloads it; the sessions stayed up and the
    guard was back (FINDING I15), with a short window without it.
    NixOS reloads on a deploy; nobody should restart it by hand.

## 4. The design ideas, one by one

| Idea | Verdict | Why | Cost |
|---|---|---|---|
| (a) default-deny forwarding | **Accept, scoped by link. VERIFIED-VM.** | A packet that uses a fabric link must match an allow. Scope it by link (`from_fabric`, `into_fabric`), not by `policy drop`: a router's LAN→WAN is not the fabric's (G25). | 3 small chains. Needs `fabricInside` for router zones and translators (`router-kube`, `nat-gateway-kube` pass with it). |
| (b) one guard model | **Accept.** | One model: link class × contract. Rendered in three hooks because netfilter has no single hook that sees input, forward and the out-link. Border guard, transit filter and prototype chain all disappear into it. | Rewrite of `default.nix:1279-1339`. |
| (c) key per adjacency, PSK | **Key per adjacency: accept (NOT-RUN). PSK: accept, VERIFIED-VM (P3).** | No security gain against a rooted machine (it holds all its keys). The gain is stability: rotate one link at a time, a dual-homed leaf never goes dark (I16). PSK is the only defence against record-now-decrypt-later (A6). | 1 more generator per adjacency end; eval fixtures. PSK is the service's first shared secret. |
| (d) GTSM, TCP-AO | **GTSM: reject on fabric sessions (REFUTED by `probe-fabric-session`). TCP-AO and MD5: reject.** | On FRR 10.7.1 `ttl-security hops 1` makes the neighbor's BFD multihop (port 4784, not bound to the link, `minimum-ttl 1`) and a one-sided deploy keeps the session down. The session already runs inside an authenticated tunnel with a per-link source and destination pin (I9), so GTSM and AO add nothing there. On upstream sessions a secret would sit in `frr.conf` in the store (D63 stands). | None: nothing is rendered. |
| (e) nft `fib` reverse path | **Reject.** | The contract is a reverse-path filter against *policy*, not against the live FIB. It does not flap with routes. Strict `fib` breaks legal flows: leaf X on spines A and B, X sends by A to a leaf only on B; B's best route to X is its direct link, so B drops what arrives from A. On leaf links it would add per-prefix checks, but a rogue kube leaf just announces the block first (L2). | — |
| (f) enforce `access` | **Accept.** | It is the `to` set. No extra mechanism. | Limit L1 (pods on a kube spine). |
| (g) typed prefixes | **Accept.** | `lib/ip.nix:117-126` has the types. | Trivial. |
| (h) no origination of `ownedPrefixes` | **Accept.** | A border ends outside traffic. Who announces the prefix to the Internet is the operator's. | Text only. |

My own:

| Idea | Verdict | Why | Cost |
|---|---|---|---|
| (i) transit tunnel = outside link | **Accept (owner decision O1: yes). VERIFIED-VM as a probe.** | 3.4. Gives I7. Kills R-A3, R-A6, R-A7 and a real input-path hole. `probe-transit-split`: T00..T08 safe, the reply returns through the tunnel, the MSS fits. | New option, a derived end, a rewritten suite. Biggest step. |
| (j) consumption by pool | **Accept, last.** | Every member's import, ACL and nft sets list every loopback today (`stableHosts`, `default.nix:433-440`, `617`). So a new member changes every machine's FRR, IfState and nft, and is unreachable until all are deployed. Use the pools instead (3.11). Origination stays exact. | A spine could announce an unallocated loopback. Spines are TCB. |
| (k) unreachable aggregates + `egress` | **Accept. VERIFIED-VM (F21, F22; P2 on a kube node).** | I8. A rogue DHCP route or a withdrawn BGP route must not send fabric traffic to the LAN in clear. On `main` this is a real leak: with its links down and a LAN default route, a member sends fabric traffic to the LAN gateway. | None met: `k3s-data-plane` passes with the aggregates. |
| (l) FRR waits for the guard | **Accept, as a waiting check. VERIFIED-VM (F26, F26b).** | A missing nft table fails every invariant silently. A check that fails at once hits the unit's start limit and FRR never returns (§3.10). | A failed load keeps the node off the fabric until the table loads; then FRR starts by itself. |
| (m) `arp_ignore`, link sysctls | **Accept. VERIFIED-VM (F20).** | 3.8. Without it every member answers ARP for its fabric loopback on the LAN. | Global sysctl, `mkDefault`. Cross-area: netif's O6 lists the same two sysctls as "off"; routed-fabric sets them, netif leaves them alone. |
| (n) `node-bgp` owner in the spine filter | **Accept.** | R-A5, I10. | Small. |
| (o) MSS clamp on transit | **Accept.** | R-A10. | 2 rules. |
| (p) delete `firewall.trust`, `border.forwarding` | **Accept.** | Unsafe or dead. | Tests that set them. |
| (q) VRF or netns for the fabric | **Reject.** | It is the only truly structural split. But the node address of a kube node is the fabric loopback. Kubelet, API, etcd, HAProxy and Cilium would all live in the VRF. Cilium in a VRF is unknown ground. And the repo wants one shape for a spine and a kube node (node duality, kamrui-h1). Two models is worse than one filter. | — |
| (r) forwarding per interface | **Reject for now.** | On a pure spine, forwarding only on `rf…` links would close F05 without nft. But kube and router nodes force it on everywhere, and IPv6 needs `force_forwarding` (kernel 6.17+). One more model for one role. | — |
| (s) no conntrack for relayed traffic | **Accept for step 9. VERIFIED-VM on a kube spine (probe P5); the rule for a NAT spine is NOT-RUN.** | A spine relays every pod flow; one-way ECMP flows fill conntrack: 2000 relayed flows are 2000 entries, and after the hostile suite's port scans the spine's table held 131008 entries. With `notrack` for fabric-link packets that are not local the count stays flat and the cluster's flows still work. | On a spine that NATs the rule must match only what leaves by a fabric link (`fib daddr oifname { … }`). Run `router-kube` and `nat-gateway-kube` with it before it lands. |
| (t) only root may speak BGP to `::1` | **Accept. VERIFIED-VM (probe P6).** | Cilium's session to `::1:179` is opened by `cilium-agent`, which runs as root in the host network. Before the rule an unprivileged local user (A5) can connect to `::1:179`; with `oifname lo tcp dport 179 meta skuid != 0 reject` in an output chain it cannot, and Cilium's session comes back 6 s after a `clear bgp ::1`. Render the rule in the guard table on every member that has a Cilium neighbor (step 5). | One output chain with one rule. |
| (u) pin the WireGuard port to the peer's endpoint address | **Reject.** | WireGuard is silent to an unknown key (F10 safe). Roaming is how a link recovers; a pin breaks it. | — |

### Detail of (j), cited as 3.11

```nix
# frr.nix:8-14 and 437-443: one more field
emptyRoutes = { hosts = []; hostPools = []; vips = []; pods = []; services = []; extra = []; };
# hostEntries (frr.nix:46-52): add
#   map (pool: "${pool} ge ${len} le ${len}") (ofFamily family routes.hostPools)
# cidrsOf (3.2): add routes.hostPools
```

```nix
# default.nix:595-622, consumptionRoutes
hosts = [];
hostPools = [loopback4PoolRecord "${ulaBase}:0::/64"];
```

`localRoutes.hosts` and the spine's `from` for a leaf stay exact. Needs
assertion A5.

## 5. What is deleted, simplified, rewritten

Done in the prototype (steps 1 and 2):

- `default.nix`: `cryptoRoutes` and the two-direction ACL (811-831)
  → `cidrsOf`, `sources`, `destinations`, `allowedIPs = sources`.
- `default.nix`: `infra`, `guardBorder`, `forwardTable` (1279-1339)
  → `fabricAddresses`, `guard`, `guardTable` (§3.3). `guardTransit`
  and its four rules stay until step 4.
- `default.nix`: `firewall.interfaces.<rf>` with 179, 3784, 4784
  (1899-1911) → four `extraInputRules` lines per adjacency (§3.3).
- `default.nix`: `systemd.services.frr.after` → plus
  `nftables.service` and the waiting `ExecStartPre` (§3.10).
- `default.nix`: `boot.kernel.sysctl` `arp_ignore`, `arp_announce`.
- `lib/kube-cluster/network-facts.nix`: `fabricInside` (top level),
  `sources` and `destinations` (adjacency).
- `lib/gateway/clat.nix`, `nat64.nix`, `router.nix`: the three
  `fabricInside` setters. The router's setter in the prototype is
  `zonesOf cfg.unzoned.zones`; the gateway design replaces it by the
  zones with `fabric = true` (§3.6).

Still to delete (later steps):

- `default.nix:744-752`, `828-831`, `836-843`, `982-983`: transit and
  source-return on adjacencies (step 4).
- `default.nix:885-896`: `clusterRoutesFor` (step 3).
- `default.nix:1068-1069`, `1584-1600`: the machine key (step 6).
- `default.nix:1918`: `trustedInterfaces` (step 3).
- Options: see 3.6.

nix-unit tests in `services/routed-fabric/tests/eval-tests.nix`. On
the prototype every test of the suites `routed-fabric`, `netif`,
`nat-gateway`, `router`, `modes`, `kube-cluster` and `k3s` passes (each
`expr` evaluated with `nix eval` and compared with `expected`; the
`nix-unit` check itself and `check`: NOT-RUN). `rke2` has two failures
(`test_firewallFabricAgent`, `test_firewallManualBySource`); they come
from the review's kube fix that the prototype carries (the supervisor
front moved to the member-only ports) and belong to the kube step.

| Test | On `main` | In the prototype |
|---|---|---|
| `test_forwardFilter` | pins the table text; `plainSpine = null`, leaf `null` | **replaced** by `test_guardOnEveryMember`: every member with an adjacency has the table and its five chains and one `link_<L>` chain per fabric link; only a spine relays; FRR has the waiting pre-check; the R7 rules stay on the owner only. No rule text is compared but the R7 lines. |
| `test_bgpBfdExposureIsScoped` | pins `firewall.interfaces.<rf>.allowedTCPPorts` | **rewritten**: no 179 on any interface or globally; each adjacency has its four input rules with the peer's and the own transfer address; no 4784; no `ttl-security` in `frr.conf`; the upstream rule stays. |
| `test_kubernetesLocalAdvertisements` | reads the pod and Service CIDR out of the node's WireGuard ACL | **rewritten**: reads them out of the link's `destinations` (what the node originates is no source its peer sends). |
| `modes.test_leafRendersOnlyInItsModes` | `firewall.interfaces != {}` | **helper `modeView` rewritten**: the guard table and a 179 input rule exist only in the instance's modes. |
| new | | `test_contractMirror` (mirror on every pair of the fixture; `allowedIPs == sources`; no `/0`), `test_clientContractHasNoPods`. |
| `test_spineReadvertisesWithAclParity` (1613) | ACL vs lists on one adjacency | unchanged, still passes. |
| trust tests (558, 1705-1712) | `firewall.trust` | step 3: delete. Keep the k3s and rke2 checks that no `rf…` link is trusted. |
| new (step 7, 6) | | `test_failClosedRoutesAndPresharedKeys`: three unreachable routes on every member, the same on a leaf and a spine; every peer reads its preshared key with `!include`; one shared `-psk` generator per adjacency. |
| later | | `test_nodeBgpOwnerOnly`, `test_pinnedLoopbackInPool` (step 3), `test_transitEndsDerived` (step 4), `test_keysPerAdjacency` (step 6), `test_memberJoinTouchesSpinesOnly` (step 8). |

VM checks that pinned a mechanism:

| Where | On `main` | Now |
|---|---|---|
| `tests/vm/suite.nix`, subtest "the border does not forward from outside the fabric…" | parses the counter of the rule that names `@infra4` in chain `forward`, with a **leaf** as the sender | **rewritten** as "a fabric destination does not leave by the underlay, also with a bogus route": the leaf's own `egress` rule counts +3, found by its comment; the spine's counter does not move. Marker `ROUTED_FABRIC_FORWARD_FILTER_OK` kept. The spine side is `hostile-fabric` F05..F09. |
| `tests/vm/transit.nix` "outside traffic to an address the owner does not own" | counter of the owner's rule | counter of the upstream end's `ingress` rule "outside to a fabric address" (it drops first); the owner's rule must still exist. |
| `tests/vm/suite.nix:350` | greps `nixos-fw` for "trusted interfaces" | unchanged. Step 3: from one member, scan another's loopback; only expected ports answer. |
| `tests/vm/suite.nix:132` | `sourceReturn` with no transit, checked by `ip route get` | step 4: delete (R-A6). |
| `tests/vm/transit.nix:77-82`, `196-197`, and the whole suite | dummy upstream peer; rule comments | step 4: replace the suite by `probe-transit-split`'s script (T00..T08), with the service rendering the tunnel. |

Unit names the netif design changes (netif's steps, not this
design's; the lines sit in this design's suites, so whoever lands
second edits them): `netif-guard.service` goes away (one transaction
in `ifstate.service`) and `netif-dhcpcd-<if>.service` becomes
`netif-dhcpcd@<if>.service`. `services/routed-fabric/tests/vm/suite.nix:41`
asserts `systemctl is-active netif-guard.service` (suite
`routed-fabric-netif`); `lib/kube-cluster/tests/vm/join.nix:121` and
`data-plane.nix:61` do the same. Replace each by a check of
`ifstate.service`'s result.

The helper both suites want (`drops(machine, comment)`: the sum of
`counter packets` of every rule of the instance's table whose line
has the comment) is in `tests/vm/hostile.nix` and `probe-transit.nix`.
Move it to `tests/suite-lib.nix` in step 1.

## 6. Hostile verdicts: what ran

Every verdict below is in the tree of the prototype. "safe" = the suite
printed `HOSTILE SAFE <id>` on the prototype. Lines are in
`probes/fabric/<suite>.*.txt`.

Suite `hostile-fabric` (`services/routed-fabric/tests/vm/hostile.nix`).
Machines: `outsider` (no member), spines `hub` and `hub2`, leaves
`victim` and `rogue` on both spines. F01..F17 are the review's and stay
(the fixture grew a second spine; the session counts in the first
subtest changed, nothing else).

| ID | Invariant | Attack | Safe outcome | Result |
|---|---|---|---|---|
| F01..F17 | I1..I5, I10 | the review's | as before | safe |
| C01 | I5, I6 | read every adjacency's fact on both ends | one end's `sources` = the other end's `destinations` (transfer addresses aside) | safe |
| C02 | I5 | the same | `allowedIPs == sources` on every link | safe |
| C03 | I5 | `wg show <hub's link to rogue> allowed-ips` | exactly rogue's /32, /128 and its two transfer addresses | safe |
| C04 | I7 | the same facts | no `/0` in any ACL | safe |
| F18 | I6 | `rogue`: route the victim's transfer address (v4, then v6) to `hub`, widen its own ACL with `wg set`, ping | no reply, 0 packets on `victim`, `hub` counter "rogue: destination outside its contract" +3 | safe |
| F19 | I6, I4 | `rogue`: the same towards the victim's **underlay** address | 0 packets on `victim`'s underlay; the same counter +3 | safe |
| F20 | I1 | `outsider`: `arping` every member's fabric loopback | no reply; the underlay address still answers | safe (GAP without `arp_ignore`) |
| F21 | I8 | `victim`: a LAN default route appears, both fabric links go down, ping a member | 0 packets on the LAN | safe |
| F22 | I8 | `victim`: `ip route add <rogue loopback>/32 via <outsider> metric 1`, ping | 0 packets on the LAN; `victim` counter "fabric destination on a link outside the fabric" +3 | safe |
| F23 | I9 | `rogue`: connect to 179 on the hub's loopback (v4, v6) and from its own loopback to the hub's transfer address | all refused | safe |
| F23b | I9 | after F23 and F24 | no session of the hub restarted | safe |
| F23d | L4 | `rogue`: a TCP connect to 179 from its own transfer address | only its own session restarts | safe |
| F24 | I9 | BFD packets: `outsider` to the hub's underlay (TTL 255); `rogue` with TTL 64, to port 4784, and from its loopback | no BFD or BGP session changes; no 4784 rule | safe |
| F24b | I9 | `show bfd peers json` on the hub | 6 of 6 single hop, bound to a link, up | safe |
| F25 | I2 | `outsider`: forged `victim` loopback as source to the hub's **underlay** address | no reply reflected into the fabric; `hub` counter "fabric source from outside the fabric" +3 | safe |
| F26 | I14 | `victim`: delete the guard table, restart FRR | 15 s later FRR is `activating`, no routing daemon runs | safe |
| F26b | I14 | `systemctl reload nftables` | FRR is active 2.2 s later, by itself; 4 sessions back | safe |
| F27 | I15 | `hub`: `systemctl reload nftables` | no session restarts | safe |
| S01 | I12 | weights 255:1 send `victim`→`rogue` through `hub` and the way back through `hub2`; `iperf3` for 5 s | completes; captures show 0 packets of the other direction on each spine | safe |
| S02 | I12 | crash the spine the stream uses, 5 s into a 20 s `iperf3 -P 4` | the stream ends without an error and at most 5 s carry no bytes | safe |
| S03 | I5 | the spines' links to `rogue` get MTU 1300; `ping -M do -s 1340` (v4) and `-s 1320` (v6) from `victim` | "Frag needed (mtu = 1300)" and "Packet too big: mtu=1300" arrive, from the spine's loopback | safe |
| P3, P3b | I16 | `wg show all preshared-keys`; count key files per machine | every link has a key, the same on both ends, different per adjacency; a member holds only its own | safe |

**Positive controls.** A verdict is only worth something when the
attack was real: it must have worked somewhere, or its packets must be
shown to arrive. Without that a SAFE can be empty. What each new
verdict has:

| Verdict | Control |
|---|---|
| F18, F19 | the attack works without the guard: with the spine's guard table deleted 3 of 3 packets reach the victim's transfer address (F18) and its underlay address (F19) (`FINDING control F18`, `F19`). With the guard, the spine's counter "destination outside its contract" moves by the 3 packets sent |
| F20 | the attack worked: on the prototype without `arp_ignore` the hub answered ("Unicast reply", run 2, GAP). In the suite the same `arping` to the underlay address is answered |
| F21 | before the ping `ip route get` shows the LAN gateway as next hop (runs 2..5: "via 192.168.1.66 dev eth1"), and the member's `egress` counter moves; with the unreachable aggregate the lookup itself fails ("No route to host") |
| F22 | the attack works without the guard: with the member's guard table deleted 3 of 3 packets for a fabric address arrive on the LAN gateway (`FINDING control F22`). With the guard the `egress` counter moves by 3 |
| F23 | the same connect from the peer's own address succeeds (FINDING I9, `rc=0`) |
| F24 | captures on the hub count the forged packets that arrived: 20 of 20 |
| F25 | the attack works without the guard: with the hub's guard table deleted it sends 3 echo replies into the victim's link (`FINDING control F25`). With the guard 0, and its counter "fabric source from outside the fabric" moves by 3 |
| F26 | FRR was active with 4 sessions before the table was deleted, and is again after |
| S01 | captures on both spines show each direction on its own spine |
| S02 | the suite reads which spine the stream uses (`ip route get`: ECMP hashes on the two addresses only, so all flows between two members share one spine), counts the stream's packets there, and crashes that one. Run 7 caught the first version crashing the idle spine: its SAFE was empty |
| S03 | the error message itself arrives |
| T02..T06b | T01 shows the path works; each refusal is counted by its rule (or by WireGuard's rx errors) |
| K40 | K40a shows the same link carries legal relayed traffic; the contract counter moves |
| C01..C04, F27, P3 | state checks, not attacks |

F05..F17 have the review's run on `main` as their control
(`runs/hostile-fabric.verdicts.txt`: the gaps were real there). The
new ones carry their control inside the suite: `guard_off(machine)`
deletes the guard table, the attack runs again and its success is
printed, `guard_on(machine)` reloads the table. Keep that pattern for
every verdict that claims "the guard stops X".

Two traps met while writing them (keep the fixes):

- After the hijack verdicts (F12..F16, K14..K16) the rogue must take
  its `network` statements back. A locally originated /32 of another
  member replaces the rogue's own learned route to that member, and
  every later check that needs the rogue to answer fails for no reason.
- `peerUptimeEstablishedEpoch` of FRR moves by a second between reads
  (it is "now minus uptime"). Compare session epochs with a tolerance.

Suite `routed-fabric-transit`: unchanged topology, passes on the
prototype (`ROUTED_FABRIC_TRANSIT_OK`). Step 4 replaces it by the
script of `probe-transit-split` (T00..T08, §3.4), with the tunnel
rendered by the service.

Kube hostile suites (`lib/kube-cluster/tests/vm/hostile.nix`; `alpha`
is server and spine, `beta` agent leaf, `mallory` leaf with
`access = "client"`, no cluster member). Added in the prototype:

| ID | Invariant | Command | Safe outcome | Result |
|---|---|---|---|---|
| K40a | A2 | two probe counters on `alpha` (`ingress`, `forward`, `iifname <link to mallory>`); `mallory` pings `beta` | both counters +3: nft on a kube spine sees relayed fabric traffic | §9 A2 |
| K40 | I6 | `mallory`: route the `web` pod **on beta** (v4, v6) to `alpha`, widen its ACL, `curl` and ping | no connection; `alpha` counter "mallory: destination outside its contract" moves | §9 A2 |
| K41 | L1 | the same to the `hostile-alpha` pod **on alpha**; tcpdump inside the pod | reported with `info(...)`: the kube design's clusterwide policy decides | §9 P1 |
| K43 (planned as K42) | I10 | a non-owner member (beta) exports everything and a VIP of alpha's `node-bgp` pool | the spine takes beta's own routes and not the VIP | in the tree (round 66); `mallory`'s hijacks are K14/K15 |
| K44 (P6 rendered) | I9 | an unprivileged user on the kube spine connects to `::1:179` | refused, counted; Cilium's session back within 30 s | in the tree (round 66) |
| P5, P6 | — | `FINDING` lines only | §9 | §9 |

## 7. Failure modes and stability

- **Link flap.** The guard is eval-time data. Nothing in nft or the
  WireGuard ACL follows BGP. A flap moves routes only.
- **A link that went down by hand** loses its IPv6 addresses (the
  kernel flushes them); the IPv6 session then stays down until IfState
  applies again (`systemctl restart ifstate.service`). Seen in
  `hostile-fabric` (F21). Not new, not the guard's.
- **Spine loss.** Leaves are dual-homed; ECMP; the guard is stateless
  (I12): a TCP stream whose two directions use different spines
  completes (`hostile-fabric` S01: 36241 packets one way through one
  spine, 40570 back through the other, 0 crossed). Nothing names a
  spine in the zone rules. A 20 s stream whose spine is crashed after
  5 s (85564 of its packets had crossed it) ends without an error and
  without a second that carried no bytes (S02).
  ECMP hashes on the two addresses only (the kernel default), so all
  flows between two members share one spine in each direction.
- **Route withdrawn.** The `egress` chain drops what would follow the
  default route (F21: 0 packets on the LAN, counted on the member). The
  unreachable aggregate answers first once it is rendered (§3.10).
- **Node reboot.** Rules match by name (`iifname`), so they load before
  the links exist. FRR starts after IfState and after the guard, and
  waits for the guard.
- **nft fails to load.** Build-time: NixOS checks the ruleset when
  `networking.nftables.checkRuleset` is on (NOT-RUN: nobody fed it a
  broken table). Run-time: FRR waits, then starts by itself (I14,
  F26b). Underlay and SSH are untouched.
- **Deploy, nothing changed.** Nothing restarts (I15; FRR reloads,
  `test_frrDeployReloads` exists).
- **Deploy, guard changed.** `systemctl reload nftables` replaces the
  table in one transaction. Counters reset. Sessions stay (F27: the six
  session epochs of a spine are equal before and after).
- **Partial deploy of this design** (only matters once machines exist):
  - ACL = `sources`: safe one end at a time. The old end is only wider.
  - nft contracts: safe one node at a time.
  - BGP and BFD input rules: safe one end at a time (the old end
    accepts more).
  - Keys per adjacency: a link is down from the first end's deploy to
    the second's. Deploy both ends of a link together. The deploy path
    is the underlay, so it still works.
  - Transit tunnels: the tunnel is down until both ends are deployed.
- **Key rotation.** Per adjacency (after step 6): `clan vars generate
  <m> --generator routed-fabric-<i>-adj-<hash>-key --regenerate`,
  deploy `<m>`, deploy the peer. That link is down in between. A
  dual-homed leaf keeps its other spine. Rotate one link at a time.
  Document it in `documentation/docs/services/routed-fabric.md`.
- **Member joins.** Before step 8: every member must be deployed before
  the new one is reachable everywhere (its address must enter every
  `sources` set). After step 8: the new member and its spines.
- **Lockout (hard rule 11).** Every rule needs a fabric link or a
  fabric address. `targetHost` is never a fabric address (assertion
  exists). The one risk: the underlay LAN's own range overlaps a fabric
  pool. Then LAN hosts look like "fabric source from outside". The
  overlap assertion (`default.nix:1433-1440`) covers declared
  underlays; warning A7 covers DHCP ones. Keep the default pools.
- **`arp_ignore = 1`.** A machine still answers ARP for an address on
  the asking interface (`hostile-fabric` F20: every member still
  answers for its underlay address). The kube and gateway suites of §6
  pass with it. A floating-pool or L2-announcement suite: NOT-RUN.
- **The fabric loopback is an ordering dependency for kube.** Kube's
  HAProxy server lines use `source <node address>`, and the node
  address is the fabric loopback (`rflo…`, rendered by IfState in this
  service). Until the address exists the backends are down. It is
  there as soon as `ifstate.service` has run: it does not wait for
  FRR, for BGP or for the guard (`probe-fabric-boot`: with the guard
  missing and FRR waiting, the leaf has its links and its unreachable
  routes). So a node whose FRR waits for the guard still binds its
  node address; it only reaches nobody. Keep the loopback in IfState
  and never make it depend on `frr.service`.
- **netif's guard and a BGP default.** netif's target guard judges
  only what netif declared. A foreign `proto bgp` default route through
  a gateway that does not answer commits (verified by the netif probe
  round). So an upstream BGP default of a border cannot make netif roll
  a configuration back.
- **A member resets its own session** (L4). Harmless to others; a
  member that does it loses its own routes for the reconnect.

## 8. Implementation order

Each step is one PR. Spec first, every time (hard rule 3): D63 and
§6.12/§6.13 in `SPEC.md`, plus
`documentation/docs/services/routed-fabric.md` and
`documentation/docs/architecture/routed-fabric.md`. One new decision,
**D73 "link contracts"**, supersedes D63's R5 and R7 paragraphs (take
the next free id at the time of the PR).

Static gate for every step: `git add -A`, `fmt`, `check`.
VM gate: `vm-test --check <suite>`, then `vm-test <suite> --remote
--quiet --rebuild`, one suite per call, one at a time.

`probes/fabric/prototype.patch` is the code that ran for steps 1, 2,
5 and 7 and the preshared key of step 6. It applies to `main` @
deeaba4 with `git apply --index`. An implementer takes each step's
hunks from it; the lists below say which.

| # | Step | State | Proof |
|---|---|---|---|
| 1 | Link contract, zone guard, session rules | **implemented** (SPEC.md round 62, D73) | `hostile-fabric` F01..F17, C01..C04, F23..F25 |
| 2 | Link contracts in nft, topology, leak guard | **implemented** (round 62); K40 lands with the kube step | F18, F19, F21, F22, S01..S03, F26, F27; kube K40 |
| 3 | Options and filters | **implemented** (SPEC.md round 66, D75) | nix-unit `hardening.*`; kube K43 (was "K42" here; the kube suite used K42 first) |
| 4 | Transit tunnels | probe ran (§3.4); service NOT-RUN | T00..T08 |
| 5 | Link hardening (no GTSM) | **implemented** (round 66, D75) | F20, F20c (A8 as a verdict); kube K44 (P6 rendered) |
| 6 | Keys per adjacency | preshared key: probe P3; key pairs NOT-RUN | P3, P3b |
| 7 | Fail closed | **implemented** (round 66, D75) | F21, F21b, F26, F26b, F27; P2; `routed-fabric-fail-closed` |
| 8 | Consumption by pool | NOT-RUN | — |
| 9 | Remaining probes | see §9 | `FINDING` lines |

Steps 1 and 2 ran as one change and the extended `hostile-fabric`
needs both. Land them as **one PR** ("fabric steps 1 and 2"). Steps 5
and 7 are small and may ride in the same PR or follow; they are
written apart so each can be reviewed alone.

### 8.1 Steps 1 and 2: the contract and the guard

**Implemented in round 62** (SPEC.md D73). What the PR did beyond the
list below:

- `hostile-fabric` carries a positive control for every verdict group
  (`control(id, worked, detail)`); a control that did not work fails the
  suite (H19). F20 (step 5), P3 and P3b (step 6) are not in it yet.
- FRR's waiting `ExecStartPre` (§3.10) landed with the guard it waits
  for; F26, F26b and F27 prove it. The unreachable aggregates of step 7
  did not: F21 is proven by the `egress` rule alone.
- The router setter is `zones.<name>.fabric` (default false), not the
  prototype's `unzoned.zones`. The option and the fact landed here
  because `router-kube` needs a setter; folding `unzoned.zones` into it
  stays gateway step 6.
- `drops(machine, table, comment)` is in `tests/suite-lib.nix`.
- Item 8 (the kube hostile suite) and item 10 (`forwardLinks`) were left
  to the kube step and the gateway step.

Files and what changes in each (all hunks are in `prototype.patch`):

1. `lib/kube-cluster/network-facts.nix`
   - top level of `schema`: `fabricInside = strList "…"`;
   - `adjacency` submodule: `sources`, `destinations` (`strList`).
2. `lib/gateway/clat.nix`, `lib/gateway/nat64.nix`,
   `lib/gateway/router.nix`: set `clan._networkFacts.fabricInside`
   (§3.6). Nothing else changes in those files.
3. `services/routed-fabric/default.nix`
   - `mkAdjacency`: replace `cryptoRoutes` and `allowedIPs` by the
     block of §3.2; add `destinations` and `sources` to the `inherit`
     list of the record;
   - the fact `clan._networkFacts.fabric.<i>.adjacencies.<r>`: add
     `destinations`, `sources` to its `inherit`;
   - the `let` block of `nixosModule`: replace `infra`, `guardBorder`,
     `forwardTable` by the block of §3.3 (keep `forwarding`, `ownedOf`,
     `quoted`, `nftSet`, `guardTransit`);
   - `networking.nftables.tables."routed-fabric-${instanceName}"`:
     `lib.mkIf guard { family = "inet"; content = guardTable; }`;
   - `networking.firewall`: delete the `interfaces = …` block; set
     `extraInputRules` as in §3.3.
4. `services/routed-fabric/tests/vm/hostile.nix` and its entry
   `clanTests.hostile-fabric` in `services/routed-fabric/flake-module.nix`:
   take the file from the patch. Leave out the subtest "keys: one
   preshared key per adjacency…" (step 6) and the four `FINDING A4 /
   A8 / P2 / P3` print lines if steps 5 to 7 are not in the PR.
5. `services/routed-fabric/tests/vm/suite.nix`: the subtest "a fabric
   destination does not leave by the underlay, also with a bogus
   route" replaces "the border does not forward from outside…" (§5).
6. `services/routed-fabric/tests/vm/transit.nix`: `ingress_counter`
   and the last subtest (§5).
7. `services/routed-fabric/tests/eval-tests.nix`: `modeView`,
   `test_bgpBfdExposureIsScoped`, `test_kubernetesLocalAdvertisements`,
   `test_guardOnEveryMember` (replaces `test_forwardFilter`),
   `test_contractMirror`, `test_clientContractHasNoPods` (§5).
8. `lib/kube-cluster/tests/vm/hostile.nix`: `mallory` gets
   `access = "client"`; the subtest "mallory: a hand-made route to the
   pods through the spine" (K40a, K40, K41). This file is shared with
   the kube design's step 1: whoever lands second merges.
9. `tests/suite-lib.nix`: add `drops(machine, table, comment)` and use
   it in the four suites (the patch still has a local copy in each).
10. `clan._networkFacts.forwardLinks = interfaceNames;` beside the
    fabric fact in `services/routed-fabric/default.nix`, and
    `test_fabricLinksAreForwardLinks` (§3.6). Only when the gateway
    design's fact exists in `network-facts.nix`; if this PR lands
    first, the gateway PR that adds the fact adds this line too.
11. Spec and docs: `SPEC.md` D73 and §6.12/§6.13;
    `specs/gateway.md` (a router zone reaches the fabric only with
    `zones.<name>.fabric = true`; CLAT and NAT64 links are always
    inside);
    `documentation/docs/services/routed-fabric.md`,
    `documentation/docs/architecture/routed-fabric.md`;
    `documentation/docs/reference/upstream-facts.md` (the facts of the
    session handoff).

Do **not** render `ttl-security` (§3.5). Do **not** add a rule for
4784 on a fabric link.

Suites that must pass, in this order (the cheap ones first):
`routed-fabric` (`ROUTED_FABRIC_OK`), `routed-fabric-transit`
(`ROUTED_FABRIC_TRANSIT_OK`), `hostile-fabric` (`HOSTILE_FABRIC_OK`),
`k3s-join`, `router-kube`, `nat-gateway-kube`, `k3s-data-plane`,
`k3s-hostile`, `rke2-hostile`, then every other suite
(`vm-test --all --remote --rebuild --quiet`). The first eight ran on
the prototype (§6). `rke2-hostile` and the rest: NOT-RUN.

If a suite fails on a drop of the guard: read the counter's comment in
the failure dump (`nft list ruleset`), find the flow, and decide. Never
add a prefix to a set to make it pass. A legal flow gets a route (so it
is in the contract by itself) or its link's owner declares the link
inside. The prototype met no such flow in the eight suites.

### 8.2 Step 3: options and filters

**Implemented in round 66** (SPEC.md D75), in one PR with steps 5 and 7.
What the PR decided beyond the list below:

- **IPv6 pins: a new option, `loopback6Pool`** (member-uniform,
  `nullOr ipv6Cidr`, null = the generated `<ula>:0::/64`). The ULA is
  random, so a pin can never lie in it; allowing "any pinned ULA" would
  bring the member list back into `F`. With the option, A5 holds for both
  families and `F` = loopback4 pool, transfer4 pool, ULA /48 and
  `loopback6Pool`. Unpinned members keep a generated address in the ULA
  (inside the /48, so inside `F`). The kube fixtures set
  `loopback4Pool = "192.168.77.0/24"` and `loopback6Pool` to their pin
  prefix (`fd00:77::/64` or `fd77::/64`); `routed-fabric` pins gamma
  inside the default IPv4 pool and `fd77::/64`. The eval fixtures moved
  their pins from `192.168.77.x` into the default pool (`198.18.77.x`):
  their committed pool records stay.
- `border.forwarding`, `externalTransit` and `sourceReturn*` stay until
  step 4 (forwarding is derived from the transit tunnel there).
  A1, A2, A6 are step 4's. A7 is a warning (DHCP read from the member's
  netif export).
- The fabric's node-bgp verdict is **K43** in the kube hostile body
  (K42 was taken by `kubectl exec`): alpha owns a node-bgp pool; beta (a
  member, not the owner) exports everything and the VIP; the spine takes
  beta's own routes (control) and not the VIP.
- `originRoutes` also feeds the import from the local Cilium session, so
  a non-owner's Cilium cannot hand the pool to FRR either.

The original plan:
 As §3.5 point 2 (`originRoutes`), §3.6 and §3.7 (A3..A5).
Files: `services/routed-fabric/default.nix` (options, `originRoutes`,
assertions, delete `clusterRoutesFor`, `firewall.trust`,
`trustedInterfaces`), `routed-fabric-interface.nix` (schema 3),
`README.md`, every fixture that sets `extraAllowedIPs`,
`firewall.trust` or pins a loopback outside its pool (the kube suites
pin `192.168.77.x` and `fd00:77::x`: they must set
`loopback4Pool = "192.168.77.0/24"`, and the IPv6 pins must move into
the generated ULA or A5 must allow a pinned ULA of the operator; decide
in the PR). With A5 in, drop the member list from `fabric4`/`fabric6`
(§3.1). Tests: `test_nodeBgpOwnerOnly`, `test_pinnedLoopbackInPool`,
type failures; K42 in the kube hostile suites.

### 8.3 Step 4: transit tunnels

The probe is the specification of the behaviour (§3.4). Build:
`border.transit` (option), `transitUp`/`transitDown`, the key
generator per tunnel, the IfState link, routes and rules, the three nft
additions **inside** the guard table, the forwarding derivation,
`node_transport.fabricInterfaces` (schema 3) with its two readers in
`lib/kube-cluster/service.nix` and `transport.nix`, assertions A1, A2,
A6. Delete everything §3.4 lists, the transit exemptions of §3.3 and
the sets `owned4`/`owned6` if nothing else reads them.
Tests: replace `tests/vm/transit.nix` by the script of
`tests/vm/probe-transit.nix` (T00..T08) with `border.transit.cloud = {}`
on `home` instead of the hand-made `rt0`; delete `probe-transit.nix`
and its `clanTests` entry; `test_transitEndsDerived`; C04 covers
`test_noZeroAclOnFabricLink`. Then every kube suite (a reader of
`fabricInterfaces`). Open points the probe did not cover are listed at
the end of §3.4.

### 8.4 Step 5: link hardening

**Implemented in round 66** (D75). The link sysctls are the netif
baseline (`lib/sysctl-baseline.nix`, N47) plus `accept_ra = 0`, so the
two never disagree; that adds `secure_redirects` and IPv6
`accept_source_route` to the five keys of §3.8. FINDING A8 became the
verdict F20c. The `local_out` rule is rendered; its proof is K44 in the
kube hostile body (a control without the table, the verdict with it, and
Cilium's session back within 30 s).

The original plan: prototype ran. `services/routed-fabric/default.nix`: the
`boot.kernel.sysctl` block and the per-link `sysctl` of §3.8. No FRR
change. Proof: `hostile-fabric` F20; FINDING A8 prints the five link
sysctls.

Also in this step, from probe P6 (the rule ran by hand on a k3s
server; rendering it is NOT-RUN). On a member that has a Cilium
neighbor (`clusterList` has a cluster with this machine), add to the
guard table:
```
chain local_out {
  type filter hook output priority filter; policy accept;
  oifname "lo" tcp dport 179 meta skuid != 0 counter reject comment "BGP on the loopback is for root"
}
```
Proof: a verdict in the kube hostile suites (`runuser -u nobody` cannot
open `::1:179`; `vtysh -c 'clear bgp ::1'` and the session is back
within 30 s), then `k3s-frr-failure` (`FRR_CILIUM_RESTART_OK`). Tell netif: its baseline (design-netif steps 8, 9, O6) leaves
`arp_ignore` and `arp_announce` alone.

### 8.5 Step 6: keys per adjacency

Key pair per adjacency end: NOT-RUN, as §3.9. The preshared key ran as
a probe (§9 P3); its hunks are in the patch (`adjacencyPskGeneratorName`,
the generator beside `-transfer4`, `preshared_key` on the peer,
`test_failClosedRoutesAndPresharedKeys`, the subtest "keys: …").
The committed eval fixtures under `tests/fixtures/vars/` need the new
generators when the key pair moves (the preshared key needed none:
the eval fixture has no vars backend and reads a placeholder path).

### 8.6 Step 7: fail closed

**Implemented in round 66** (D75). The unreachable routes cover `F`
(with `loopback6Pool` when set). F21 is now two verdicts: F21 (the
aggregate answers "No route to host" in both families, 0 packets on the
LAN) and F21b (with the aggregates deleted, the control shows the LAN
default route, and the `egress` chain drops it). `probe-boot.nix` is
`tests/vm/fail-closed.nix`, suite `routed-fabric-fail-closed`.

The original plan: prototype ran. `services/routed-fabric/default.nix`:
`unreachableRoutes` in front of `ifstateRoutes`; the
`systemd.services.frr` block of §3.10.
Tests that read `networking.ifstate.settings.routing.routes` must
expect routes without `dev` and without `table`: the prototype changed
`services/routed-fabric/tests/eval-tests.nix` (two places) and
`services/netif/tests/eval-tests.nix` (`(r.dev or null) == …`, two
places). Grep for `routing.routes` in every `eval-tests.nix`.
Proof: `hostile-fabric` F21, F22, F26, F26b, F27; `k3s-data-plane`
(P2); `routed-fabric`, `router-kube`, `nat-gateway-kube`;
`probe-fabric-boot` for the boot case. Promote that probe to a real
suite in this step: rename `tests/vm/probe-boot.nix` to
`tests/vm/fail-closed.nix`, suite `routed-fabric-fail-closed`, final
marker `ROUTED_FABRIC_FAIL_CLOSED_OK`; its three subtests already
assert. It is two small VMs and about six minutes.

### 8.7 Step 8: consumption by pool

NOT-RUN. As 3.11. Needs step 3 (A5). `test_memberJoinTouchesSpinesOnly`;
`hostile-fabric` (F12..F16 still safe); kube suites.

### 8.8 Step 9: remaining probes

The throwaway suites of this round and where they end:
`probe-fabric-session` (delete when D73 and the upstream fact are
written: it proves a negative about FRR, rerun it on an FRR bump),
`probe-transit-split` (becomes `routed-fabric-transit` in step 4),
`probe-fabric-boot` (becomes `routed-fabric-fail-closed` in step 7).

§9 says which probes are done. What is left needs a suite of its own:
P5 on a NAT gateway spine, P1's Cilium policy (kube design), I11 with
`checkReversePath = false` on every member of `hostile-fabric`, a
floating-pool suite with `arp_ignore = 1`.

## 9. Open risks, assumptions, probes

Verified in code (read, not run):

- The BGP, ACL and filter derivations cited in §3 (`default.nix`,
  `frr.nix` at the lines given).
- A machine holds one role in at most one instance (`default.nix:2008-2012`).
- The kube service accepts every fabric link in the reverse-path chain
  and sets `checkReversePath = "loose"` (`lib/kube-cluster/service.nix:1050-1054`);
  the router sets it `false` (`lib/gateway/router.nix:387`).
- Kube input rules guard by `iifname` of the transport interfaces
  (`lib/kube-cluster/firewall.nix:44-47`).
- NixOS `nftables.service` (`nixos/modules/services/networking/nftables.nix`
  of the pinned nixpkgs): `before = network-pre.target`,
  `reloadIfChanged = true`, a reload deletes and re-adds each declared
  table in one `nft -f` and leaves other tables alone, `ExecStop`
  deletes the declared tables, `checkRuleset` defaults to `true`.
- The nixpkgs `frr.service`: `Restart=always`, `RestartSec=5`,
  `StartLimitBurst=3`, `StartLimitIntervalSec=180`.
- IfState 2.5.1's schema has the peer key `preshared_key`, the route
  keys `type` (`unreachable`) and `preference`, and a per-interface
  `sysctl` object with `ipv4` and `ipv6` keys.
- WireGuard drops a source outside `allowed-ips` before tcpdump
  (`documentation/docs/reference/upstream-facts.md:35-40`).

Assumptions, each with its result:

| # | Assumption | Result | Proof |
|---|---|---|---|
| A1 | `iifname vmap { "x" : goto chain }` and wildcard names in anonymous sets load | **VERIFIED-VM** | the guard table passes the build-time `nft -c` check and loads in every suite of §6 |
| A2 | On a kube node relayed and host-bound traffic still passes nft | **VERIFIED-VM** for relayed traffic. On the kube spine a probe counter on the client leaf's link moves at `prerouting` and at `forward` for 3 relayed pings (K40a: forward +3). A client leaf that routes a pod **on another node** to the kube spine is stopped there: "destination outside its contract" +8 in each family, no HTTP answer, no ping answer (K40). Control: with the spine's guard table deleted the same request gets an HTTP answer from the pod. **REFUTED for a pod on the kube spine itself**: see P1 | `k3s-hostile` K40a, K40 |
| A3 | A filter chain on `postrouting` is legal in `inet` and sees locally generated packets | **VERIFIED-VM** | `hostile-fabric` F21, F22 (the member's own pings are counted there) |
| A4 | `nftables.service` is ordered before the network, replaces a table atomically, leaves Cilium's tables alone, checks the ruleset at build | **VERIFIED** (code, above) and **VERIFIED-VM** for what a suite can see: a reload resets no session (F27); every kube suite of §6 passes with the table beside Cilium's; at boot `nftables.service` is active before `ifstate.service` finishes and before FRR starts on all four members (FINDING A4: 7.5 s, 8.6 s, 8.7 s on the hub) | F27; `nat-gateway-kube` restarts nftables on a kube gateway |
| A5 | Fabric BFD is single hop and uses port 3784 only | **VERIFIED-VM while no `ttl-security` is set; REFUTED with it** | `probe-fabric-session`: "as rendered" 12 packets to 3784, TTL and hop limit 255, `BFD: Type: single hop`; with `ttl-security hops 1` 12 packets to 4784, `multi hop` |
| A6 | Linux answers ARP for any local address on any interface | **VERIFIED-VM**, and it is a gap without the sysctl | `hostile-fabric` run 2: "hub answers ARP for its fabric loopback … True"; F20 safe with `arp_ignore = 1` |
| A7 | ICMP errors of a spine carry its loopback | **VERIFIED-VM**, both families | `hostile-fabric` S03, FINDING A7 |
| A8 | IfState's per-interface sysctl object accepts the keys of §3.8 | **VERIFIED-VM** for `accept_redirects`, `send_redirects`, `accept_source_route`, `accept_ra`, IPv6 `accept_redirects` (all read back 0). **REFUTED** for `rp_filter = 0`: it reads 2 afterwards; the key is dropped (§3.8) | `hostile-fabric` FINDING A8 (run 6) |
| A9 | Cilium maps a packet's source address to an identity also on an external device | **NOT-RUN** (needs a kube owner of a transit tunnel; step 4). The probe's T04 shows the upstream end's rule that keeps such a packet out. | — |
| A10 | `ttl-security hops 1` works together with `bfd` and graceful restart | **REFUTED for `bfd`** (the session turns multihop, 4784, `minimum-ttl 1`). GTSM itself holds (BGP at TTL 64: 0 sessions). **Graceful restart: no difference shown** (route kept 20/20 s and 9/20 s without GTSM, 10/20 s with it; §3.5) | `probe-fabric-session`, three runs |

Probes:

| # | Question | Result | Proof |
|---|---|---|---|
| P1 (limit L1) | Can a `client` leaf with a hand-made route reach a pod that runs on a kube spine? | **VERIFIED-VM: yes, and nft cannot stop it.** The `client` leaf pings the pod on the kube spine in both families: 3 of 3 echo requests are seen inside the pod, the ping is answered, and the spine's contract rule counts **0**. Cilium's eBPF on the fabric link delivers a packet for a local pod before netfilter's `prerouting`. What still holds there: the WireGuard ACL (the pod sees the leaf's true fabric address). So the owner's O2 ("close it") cannot be met by nft: it needs the clusterwide Cilium policy of the kube design, which denies the fabric addresses of members that are not cluster members to pods. The same holds for NodePorts: they answer the client leaf (`k3s-hostile` K10n, K13), served by Cilium before the node firewall | `k3s-hostile` K41 |
| P2 | Do the `unreachable` aggregates disturb Cilium or node health? | **VERIFIED-VM: no.** `k3s-data-plane` passes with the three unreachable routes on both nodes (`K3S_DATA_PLANE_OK`), and no rule of the guard counted a drop during the suite. On a member whose links are down and whose LAN offers a default route, a ping to a fabric address fails at once with "No route to host" and 0 packets reach the LAN | `k3s-data-plane`; `hostile-fabric` FINDING P2 |
| P3 | A secret clan var shared by exactly two machines | **VERIFIED-VM.** A generator with `share = true` and a secret file, declared by the two ends of an adjacency only, gives both ends the same file and nobody else any. Each member holds exactly the keys of its own adjacencies (spines 3, leaves 2), under `/run/secrets/shared/<generator>/psk`. Every link runs with its preshared key; the four leaf adjacencies have four different keys | `hostile-fabric` P3, P3b |
| P4 | (unused number) | — | — |
| P5 | `notrack` for relayed traffic on a spine | **VERIFIED-VM on a kube spine, with one open point.** 2000 relayed one-way UDP flows leave 2000 conntrack entries on the spine. With `iifname { <fabric links> } fib daddr type != local notrack` at `raw + 1` the next 2000 leave 0, and a relayed ping, pod to pod, a pod to the API's ClusterIP and a pod on the spine to a pod on a leaf all still work. NOT-RUN: a spine that NATs (a router or NAT64 gateway): there the rule must not catch what leaves by a non-fabric link. The rule to render is `iifname { <fabric links> } fib daddr oifname { <fabric links> } notrack`; that exact form is NOT-RUN | `k3s-hostile` FINDING P5 |
| P6 | Who opens BGP to `::1`, and does a root-only output rule break it | **VERIFIED-VM.** The session's client is `cilium-agent` (root). An unprivileged user connects to `::1:179` without the rule and is refused with it; Cilium's session re-establishes in 6 s with the rule in place | `k3s-hostile` FINDING P6 |
| O1 | The transit split | **VERIFIED-VM** as a probe; the service is NOT-RUN | `probe-transit-split` T00..T08 (§3.4) |
| I14 | FRR refuses to start without the guard, at boot and at a restart | **VERIFIED-VM** with the waiting check; the first sketch was REFUTED (§3.10). At boot (`probe-fabric-boot`): 30 s after boot no routing daemon, no BGP route in the kernel, no session on the spine, a ping to a fabric address gets "No route to host"; 230 s after boot FRR still retries (`NRestarts=2`, no `start-limit-hit`); 0.5 s after the table loads FRR is active and the fabric comes up | `probe-fabric-boot`; `hostile-fabric` F26, F26b |
| I15 | A firewall reload or restart resets no session | **VERIFIED-VM** | F27; FINDING I15 |

Top risks, as they stand now:

1. **Cilium bypass (A2, L1).** Settled by K40 and K41. Relayed traffic is visible to nft on a kube spine, so I4 and I6 hold there for everything that passes **through** the node. Traffic **to a pod on the node** skips nft (L1). The guard therefore cannot enforce `access` for pods and NodePorts of a kube node that members reach directly. The kube design's clusterwide Cilium policy is the only place for that rule; until it lands, a `client` leaf reaches every pod on each kube spine it is attached to.
2. **The destination contract breaks a legal flow nobody listed.**
   Checked against `routed-fabric`, `routed-fabric-transit`, `k3s-join`,
   `k3s-data-plane`, `k3s-hostile`, `router-kube` and `nat-gateway-kube`:
   all pass with the full guard and no widened set. The three kube and gateway suites print the guard's non-zero drop counters at their end (`FINDING guard drops …`). `k3s-data-plane`: none. `router-kube`: on the agent 6 IPv4 and 6 IPv6 packets "fabric destination on a link outside the fabric". That is the agent calling the server's node address in the first seconds of boot, before BGP is up (sessions come up at second 19): on `main` those packets follow the default route to the LAN in clear. Dropping them is the design (I8), and the suite passes. The
   other suites (rke2, ClusterMesh, NodePort, CLAT, failover): NOT-RUN.
   Never widen a set to make a suite pass: find the flow and give it a
   route.
3. **The transit split (step 4)** changes the option surface and adds a
   second tunnel between two machines that are also adjacent. The
   behaviour is proven by the probe; the service code is not written.
   Failover of a dead tunnel is still static (as today).
4. ~~Fixtures pin loopbacks outside the pools.~~ Settled in round 66
   (D75): pins lie in their pools (`loopback6Pool` for IPv6) and `F` is
   the pools only.
