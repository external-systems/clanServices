# routed-fabric: target design (best-design review, 2026-11-27)

> **Status: target design, not implemented** (SPEC.md round 61). Nothing
> here was run unless a line says "VERIFIED-VM" or names a suite verdict.
> Parts marked "owner decides" are proposals. The index, the cross-area
> contracts and the build order are in `specs/target-design.md`.
> Evidence named here (`reviews/`, `runs/`, the `fix-probe` and
> `fix-nat64` prototypes, patches) is session evidence of the review of
> 2026-11-27. It is not in the repo; the session handoff maps it.

Base: `main` @ 4d9c1aa. Nothing was run. No nix, no VM.
"Verified" = I read the cited lines. "Assumed" = kernel, FRR, Cilium or
nftables behaviour from memory. Every assumption is listed in §9.

Paths are relative to the repo root. `default.nix` means
`services/routed-fabric/default.nix`. `frr.nix` means
`lib/kube-cluster/frr.nix`.

Read first:
- `reviews/routed-fabric.md` (R-A1..R-A12)
- `runs/hostile-fabric.verdicts.txt`
- the prototype: worktree `fix-probe`, `services/routed-fabric/default.nix`

## 0. The answer in short

Yes, a better design exists. It is not "more drops". It is one rule:

> **A link carries a packet only if BGP may carry its route.**

Today three things are derived apart: the BGP lists, the WireGuard ACL
and the nft rules. The target derives all three from one value per
link, the **link contract** (`from`, `to`). Then:

- "enumerate the bad paths" becomes "name the allowed ones";
- the border guard, the transit filter and the prototype's ingress
  chain become one table with one shape on every member;
- `access` is enforced for free (the `to` set);
- R-A1, R-A2, R-A3, R-A4, R-A6 and F05..F17 close by construction.

Second big change: **an external-transit tunnel is not a fabric link.**
It is an outside link that happens to be a tunnel. So every fabric link
has a finite cryptographic ACL. No 0/0 on a fabric link, ever.

A structural split (VRF or netns) was considered and rejected: §4 (q).

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
  sent to this end's address on that link, with TTL 255.
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
- **I14.** FRR does not start when the guard table is missing.
- **I15.** A deploy that changes nothing restarts nothing. An nft change
  loads atomically. No BGP session resets.
- **I16.** Rotating the keys of one adjacency touches no other
  adjacency.
- **I17 (after step 8).** Adding or removing a member changes rendered
  config only on that member and its spines.

Known limits (state them in SPEC, do not hide them):

- **L1.** On a kube node, pod-bound traffic is taken by Cilium's eBPF
  before nft (verified in repo text: `specs/gateway.md:326`). There
  only the WireGuard ACL (I5) and Cilium policy apply. So I6 does not
  cover pods that run **on a kube spine itself**. See §9 P1.
- **L2.** A kube member can announce any pod block of its own cluster
  (Cilium IPAM is dynamic). R-A5 residual.
- **L3.** A rooted spine. See TCB.

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

- `F` = `loopback4Pool`, `transfer4Pool`, ULA /48. Two v4 prefixes and
  one v6 prefix. **No per-member list** (see 3.7 assertion A5).
- per link: `src` = cidrs(`from`) + the peer's transfer address;
  `dst` = cidrs(`to`) + this end's transfer address.

### 3.2 The link contract (one function, three consumers)

Lands in `mkAdjacency`, replacing `default.nix:782-831`.

```nix
# What the peer may announce to us. Also: every source it may send.
fromBase =
  if ownRole == "spine" && remoteRole == "spine" then spineTransitRoutes
  else if ownRole == "spine" then originRoutesFor remoteName   # see 3.5 (R-A5)
  else consumptionRoutes machine.name;
# What we announce to the peer. Also: every destination it may address.
toBase =
  if ownRole == "spine" && remoteRole == "spine" then spineTransitRoutes
  else if ownRole == "spine" then consumptionRoutes remoteName
  else localRoutes;
contract = {
  from = frr.mergeRoutes [fromBase extraRoutes];
  to = frr.mergeRoutes [toBase extraRoutes];
};
cidrsOf = routes:
  routes.hosts ++ routes.vips ++ map (pod: pod.cidr) routes.pods
  ++ routes.services ++ routes.extra;
peerHost = ["${remoteAddress.ipv4}/32" "${remoteAddress.ipv6}/128"];
localHost = ["${localAddress.ipv4}/32" "${localAddress.ipv6}/128"];
sources = lib.unique (cidrsOf contract.from ++ peerHost);
destinations = lib.unique (cidrsOf contract.to ++ localHost);
allowedIPs = sources;          # WireGuard ACL == nft source set
```

Consumers:

1. **FRR.** `import = contract.from; export = contract.to;` (unchanged
   meaning; `frr.nix:222-250` reads `adjacency.import` / `.export`).
2. **WireGuard.** `allowedips = adjacency.allowedIPs` (`default.nix:1120`).
3. **nft.** Sets `src*_<link>` and `dst*_<link>` (3.3).

Why `allowedIPs = from` is enough on **every** role pair (the prototype
did it for spine→leaf only):

- Inbound: WireGuard checks the source. Legal sources are `from`.
- Outbound: WireGuard needs the destination in the ACL. The kernel only
  routes into the link what BGP learned on it. That is `from` again.
- `export` was in the ACL for no reason. On a leaf it allowed the
  leaf's own addresses as *inbound* sources (self-spoof).

Checked by hand for each pair (verified against `default.nix:595-622`):

| End | `from` (ACL, sources) | `to` (destinations) |
|---|---|---|
| spine, peer leaf | the leaf's /32, /128, its clusters' VIP blocks, pod CIDR, services | all loopbacks; VIPs, pods, services per the leaf's `access` |
| leaf, peer spine | all loopbacks; VIPs, pods, services per own `access` | own /32, /128, own clusters' blocks |
| spine, peer spine | `spineTransitRoutes` | `spineTransitRoutes` |

The two ends mirror: `from(A→B) == to(B→A)`. Pin it with a nix-unit
test (§5), not an assertion (one machine cannot evaluate the other's
`mkAdjacency`).

ICMP errors (path MTU) keep working: zebra installs BGP routes with
`set src <loopback>` (`frr.nix:461-472`), so a spine's ICMP errors
carry its loopback, which is in every `from`. Assumed for the kernel
side, see §9 A7.

### 3.3 nftables: one table, the same shape on every member

Replaces `default.nix:1279-1339` and `1893-1896`. Rendered whenever the
machine has an adjacency (leaf too: a kube leaf forwards).

Placeholders: `<L>` a fabric link name, `<peer>` its remote machine,
`<rflo>` the dummy, `<inside>` = `config.clan.networkFacts.fabricInside`.

```
table inet routed-fabric-<instance> {
  set fabric4 { type ipv4_addr; flags interval; auto-merge;
                elements = { <loopback4Pool>, <transfer4Pool> } }
  set fabric6 { type ipv6_addr; flags interval; auto-merge;
                elements = { <ula>::/48 } }
  # per fabric link <L>:
  set src4_<L> { type ipv4_addr; flags interval; auto-merge; elements = { … } }
  set src6_<L> { type ipv6_addr; flags interval; auto-merge; elements = { … } }
  set dst4_<L> { … }
  set dst6_<L> { … }

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
  chain link_<L> {
    ip  saddr != @src4_<L> counter drop comment "<peer>: source outside its contract"
    ip6 saddr != @src6_<L> counter drop comment "<peer>: source outside its contract"
    ip  daddr != @dst4_<L> counter drop comment "<peer>: destination outside its contract"
    ip6 daddr != @dst6_<L> counter drop comment "<peer>: destination outside its contract"
    accept
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

Notes for the implementer:

- `ip saddr …` in an `inet` table only matches IPv4, `ip6 …` only IPv6.
  That is why each check is written twice and the chain ends in
  `accept`.
- A set with no elements is legal (`nftSet`, `default.nix:1302-1311`,
  already omits `elements`). `!= @empty` then drops everything of that
  family. Correct: a link with no v6 contract carries no v6.
- Default-deny is done with a final `drop` inside `from_fabric` /
  `into_fabric`, **not** with `policy drop` on the base chain. A base
  policy would judge LAN→WAN on a router. Ownership by link, as G25.
- The destination contract is checked **before NAT**. That is why
  `from_fabric` needs no address rule: a reply to a router's
  masqueraded LAN flow arrives addressed to the router's loopback
  (in `dst`), is de-NATed, then leaves by the inside link.
- Counters reset when the table reloads. Tests read a counter before
  and after an attack with no deploy between.
- Many links: equal sets may share one name by content hash, as the
  prefix-lists do (`frr.nix:100-108`). Optional. Do it only if a spine
  with many leaves loads slowly.
- Keep `firewall.extraForwardRules` (`default.nix:1915-1917`). It only
  matters when another service turns on the NixOS forward filter.

What each old gap hits:

| Gap | Rule |
|---|---|
| F05 underlay forwarded into the fabric | `ingress` "outside to a fabric address"; `into_fabric` for any other destination |
| F07 spine answers on its fabric address | `ingress` "outside to a fabric address" |
| F08, F09 forged member source | `ingress` "fabric source from outside" |
| F11 leaf forges another member | WireGuard ACL = `from`; `link_<L>` second layer |
| F17 leaf routed out to the underlay | `link_<L>` destination contract; `from_fabric` final drop |
| R-A4 `access` | `link_<L>` destination contract on the spine |

BGP and BFD, in `networking.firewall.extraInputRules` (replaces
`default.nix:1899-1911`; the prototype has the source half):

```
iifname "<L>" ip  saddr <peer4> ip  daddr <local4> tcp dport 179 accept
iifname "<L>" ip  saddr <peer4> ip  daddr <local4> udp dport 3784 ip ttl 255 accept
iifname "<L>" ip6 saddr <peer6> ip6 daddr <local6> tcp dport 179 accept
iifname "<L>" ip6 saddr <peer6> ip6 daddr <local6> udp dport 3784 ip6 hoplimit 255 accept
```

4784 (multihop BFD) goes: fabric sessions are single hop (§9 A5).
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

If the owner rejects this split, see §9 "Fallback".

### 3.5 FRR policy changes

All in `frr.nix` unless said.

1. **GTSM on fabric sessions.** In `mkNeighbor` (`frr.nix:222-250`),
   for both peers: ` neighbor <peer> ttl-security hops 1`. Both ends
   render from one model, so they cannot disagree. Flag day per link:
   see §7.
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

In `roleInterface` and `adjacencyOptions` (`default.nix:35-248`).

| Option | Change | Type |
|---|---|---|
| `ipv4` | typed | `nullOr ip.types.ipv4` |
| `ipv6` | typed | `nullOr ip.types.ipv6` |
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
  (`network-facts.nix:37-54`): drop `externalTransit`, `sourceReturn`;
  add `sources`, `destinations`.
- `clan._networkFacts.fabricInside` (`strList`): take it from the
  prototype as is, with its three setters (`lib/gateway/clat.nix`,
  `nat64.nix`, `router.nix`).

### 3.7 Eval-time assertions

Add (in the list at `default.nix:1366-1579`):

- **A1.** `border == null || (border.ownedPrefixes != [] && (border.upstreamPeers != [] || border.transit != {}))` (replaces 1508; R-A7).
- **A2.** Every `border.transit` key names a member, is not this
  machine, and that member has no `border.transit` entry back.
- **A3.** No owned prefix is shorter than /8 (v4) or /16 (v6)
  (replaces the string compare at 1512-1516).
- **A4.** No owned prefix overlaps `F` or a cluster pod or service CIDR.
- **A5.** A pinned `ipv4` lies in `loopback4Pool`; a pinned `ipv6` in
  `<ula>:0::/64`. Then `F` needs no member list, and the nft sets of
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
  `forwarding = ownRole == "spine" || transitDown != [];`
- Per fabric and transit link, in the IfState interface (`default.nix:1097-1127`),
  key `sysctl` (the schema has it, verified; key names assumed, §9 A8):
  `ipv4 = { rp_filter = 0; accept_redirects = 0; send_redirects = 0; accept_source_route = 0; };`
  `ipv6 = { accept_ra = 0; accept_redirects = 0; };`
  `rp_filter = 0` says it out loud: the kernel filter is not part of
  the design (I11).
- Global, `mkDefault`: `net.ipv4.conf.all.arp_ignore = 1`,
  `net.ipv4.conf.all.arp_announce = 2`. Without it a member answers ARP
  for its fabric loopback on the underlay NIC (Linux default). The
  address then leaks at L2 (§9 A6).

### 3.9 Keys

- **One key pair per adjacency end** (R-A11). Replaces the machine key
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
- **Preshared key per adjacency: later, after probe P3.** One *shared
  secret* generator per adjacency, rendered as IfState `preshared_key`
  (the schema has the key, verified). It is the only answer to A6.

### 3.10 Fail closed

- **Unreachable aggregates.** IfState routes, main table, high metric:
  `{ to = loopback4Pool; type = "unreachable"; metric = 4294967000; }`,
  the same for `transfer4Pool` and `<ula>::/48`. (`type` is in the
  schema, verified.) A BGP /32 is more specific and wins. When it is
  withdrawn, the packet gets an error at once. It does not follow the
  default route. This also covers Cilium's eBPF path, which the nft
  `egress` chain may not see (§9 A2).
- **FRR needs the guard.**
  ```nix
  systemd.services.frr = {
    after = ["ifstate.service" "nftables.service"];
    serviceConfig.ExecStartPre = lib.mkBefore [
      "${pkgs.runtimeShell} -c '${pkgs.nftables}/bin/nft list table inet routed-fabric-${instanceName} >/dev/null'"
    ];
  };
  ```
  No guard, no routes. The underlay stays up for the repair. Do **not**
  use `requires`: a restart of `nftables.service` would restart FRR.

## 4. The design ideas, one by one

| Idea | Verdict | Why | Cost |
|---|---|---|---|
| (a) default-deny forwarding | **Accept, scoped by link.** | A packet that uses a fabric link must match an allow. Scope it by link (`from_fabric`, `into_fabric`), not by `policy drop`: a router's LAN→WAN is not the fabric's (G25). | 3 small chains. Needs `fabricInside` for router zones and translators. |
| (b) one guard model | **Accept.** | One model: link class × contract. Rendered in three hooks because netfilter has no single hook that sees input, forward and the out-link. Border guard, transit filter and prototype chain all disappear into it. | Rewrite of `default.nix:1279-1339`. |
| (c) key per adjacency, PSK | **Key per adjacency: accept. PSK: accept after P3.** | No security gain against a rooted machine (it holds all its keys). The gain is stability: rotate one link at a time, a dual-homed leaf never goes dark (I16). PSK is the only defence against record-now-decrypt-later (A6). | 1 more generator per adjacency end; eval fixtures. PSK is the service's first shared secret. |
| (d) GTSM, TCP-AO | **GTSM: accept on fabric sessions. TCP-AO and MD5: reject.** | GTSM is one line and both ends are ours. The session already runs inside an authenticated tunnel with a per-link source pin, so AO adds nothing there. On upstream sessions a secret would sit in `frr.conf` in the store (D63 stands). | One flag day per link when it lands. |
| (e) nft `fib` reverse path | **Reject.** | The contract is a reverse-path filter against *policy*, not against the live FIB. It does not flap with routes. Strict `fib` breaks legal flows: leaf X on spines A and B, X sends by A to a leaf only on B; B's best route to X is its direct link, so B drops what arrives from A. On leaf links it would add per-prefix checks, but a rogue kube leaf just announces the block first (L2). | — |
| (f) enforce `access` | **Accept.** | It is the `to` set. No extra mechanism. | Limit L1 (pods on a kube spine). |
| (g) typed prefixes | **Accept.** | `lib/ip.nix:117-126` has the types. | Trivial. |
| (h) no origination of `ownedPrefixes` | **Accept.** | A border ends outside traffic. Who announces the prefix to the Internet is the operator's. | Text only. |

My own:

| Idea | Verdict | Why | Cost |
|---|---|---|---|
| (i) transit tunnel = outside link | **Accept (owner decision).** | 3.4. Gives I7. Kills R-A3, R-A6, R-A7 and a real input-path hole. | New option, a derived end, a rewritten suite. Biggest step. |
| (j) consumption by pool | **Accept, last.** | Every member's import, ACL and nft sets list every loopback today (`stableHosts`, `default.nix:433-440`, `617`). So a new member changes every machine's FRR, IfState and nft, and is unreachable until all are deployed. Use the pools instead (3.11). Origination stays exact. | A spine could announce an unallocated loopback. Spines are TCB. |
| (k) unreachable aggregates + `egress` | **Accept.** | I8. A rogue DHCP route or a withdrawn BGP route must not send fabric traffic to the LAN in clear. | Probe P2 on a kube node. |
| (l) FRR waits for the guard | **Accept.** | A missing nft table fails every invariant silently. | A failed load takes the node off the fabric until fixed. Wanted. |
| (m) `arp_ignore`, link sysctls | **Accept.** | 3.8. | Global sysctl, `mkDefault`. |
| (n) `node-bgp` owner in the spine filter | **Accept.** | R-A5, I10. | Small. |
| (o) MSS clamp on transit | **Accept.** | R-A10. | 2 rules. |
| (p) delete `firewall.trust`, `border.forwarding` | **Accept.** | Unsafe or dead. | Tests that set them. |
| (q) VRF or netns for the fabric | **Reject.** | It is the only truly structural split. But the node address of a kube node is the fabric loopback. Kubelet, API, etcd, HAProxy and Cilium would all live in the VRF. Cilium in a VRF is unknown ground. And the repo wants one shape for a spine and a kube node (node duality, kamrui-h1). Two models is worse than one filter. | — |
| (r) forwarding per interface | **Reject for now.** | On a pure spine, forwarding only on `rf…` links would close F05 without nft. But kube and router nodes force it on everywhere, and IPv6 needs `force_forwarding` (kernel 6.17+). One more model for one role. | — |
| (s) no conntrack for relayed traffic | **Probe P5, then decide.** | A spine relays every pod flow; one-way ECMP flows fill conntrack. `notrack` for `iif rf… → not local` would fix it. Risk: NAT on a gateway spine. | — |
| (t) only root may speak BGP to `::1` | **Probe P6, then decide.** | A local user can open the Cilium session (review note). An output rule `oifname lo tcp dport 179 meta skuid != 0 drop` closes it. | — |
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

Code deleted:

- `default.nix:1279-1339`: `forwarding` comment block, `ownedOf` use in
  the forward table, `infra`, `guardBorder`, `guardTransit`,
  `forwardTable`. Replaced by 3.3.
- `default.nix:744-752`, `828-831`, `836-843`, `982-983`: transit and
  source-return on adjacencies.
- `default.nix:811-821`: `cryptoRoutes`.
- `default.nix:885-896`: `clusterRoutesFor`.
- `default.nix:1068-1069`, `1584-1600`: the machine key.
- `default.nix:1918`: `trustedInterfaces`.
- Options: see 3.6.

nix-unit tests in `services/routed-fabric/tests/eval-tests.nix`:

| Test | Today | Becomes |
|---|---|---|
| `test_forwardFilter` (1738) | pins the table text; `plainSpine = null`, leaf `null` | `test_guardOnEveryMember`: every member with an adjacency has the table and the five chains. Do not compare rule text. |
| `test_spineReadvertisesWithAclParity` (1613) | ACL vs lists on one adjacency | `test_contractMirror`: for every adjacency of the fixture, `from` on one end equals `to` on the other; `allowedIPs == sources`; `sources` = cidrs of the rendered import list + peer host. |
| `test_bgpBfdExposureIsScoped` (1148) | pins `firewall.interfaces.<rf>.allowedTCPPorts` | assert `allowedTCPPorts` has no 179 anywhere and each adjacency has its four input rules. The behaviour proof is F03, F04, F23. |
| trust tests (558, 1705-1712) | `firewall.trust` | delete. Keep the k3s and rke2 checks that no `rf…` link is trusted. |
| new | | `test_clientContractHasNoPods`, `test_nodeBgpOwnerOnly`, `test_noZeroAclOnFabricLink` (no adjacency's `allowedIPs` has a /0), `test_pinnedLoopbackInPool`, `test_transitEndsDerived`, `test_keysPerAdjacency` (two adjacencies of one machine have different public keys), `test_memberJoinTouchesSpinesOnly` (step 8: add a leaf to the fixture; an unrelated leaf's `frr.conf`, IfState and nft are identical). |

VM checks that pin a mechanism:

| Where | Today | Becomes |
|---|---|---|
| `tests/vm/suite.nix:350` | greps `nixos-fw` for "trusted interfaces" | behaviour: from one member, scan another's loopback; only expected ports answer. |
| `tests/vm/suite.nix:355-373` | parses the counter of the rule that names `@infra4` in chain `forward` | behaviour first: the packet does not arrive (tcpdump on the target) and gets no reply. Counter second, found by its `comment`, never by set or chain name. |
| `tests/vm/suite.nix:132` | `sourceReturn` with no transit, checked by `ip route get` | delete (R-A6). The transit suite sends real packets. |
| `tests/vm/transit.nix:77-82` | dummy upstream peer | delete (A1). |
| `tests/vm/transit.nix:196-197` | asserts two rule comments exist on `home` and none on `cloud` | delete. Replaced by T-verdicts (§6). |
| `tests/vm/transit.nix` "fabric's own traffic still crosses the link" | fabric over the transit link | `cloud`–`home` are also adjacent (both spines), so fabric traffic uses the `rf…` link. Assert `far`↔`cloud` still ping, and that the `rt…` tunnel's counters do not move. |

A helper for both suites (put it in `tests/suite-lib.nix`):
`drops(machine, table, comment)` sums `counter packets` of every rule
whose line contains the comment.

## 6. Hostile verdicts to add

Suite `hostile-fabric` (from the prototype: `outsider`, `hub` spine,
`victim` leaf, `rogue` leaf). Add a second spine `hub2` and attach
`victim` to both for S-verdicts. Keep F01..F17.

| ID | Invariant | Attacker, command | Safe outcome |
|---|---|---|---|
| F18 | I6 | `rogue`: `ip route add <victim's transfer address on hub–victim>/32 dev <rf>`; widen its own ACL with `wg set … allowed-ips`; `ping -c3 -W1` it | no reply; `hub` drop counter "destination outside its contract" +3 |
| F19 | I6, I4 | `rogue`: the same towards `192.168.1.66` (the outsider) | `outsider` tcpdump sees 0 packets with rogue's fabric source |
| F20 | I1 | `outsider`: `arping -c3 -I eth1 <hub loopback>` | no reply |
| F21 | I8 | `victim`: `ip link set <rf to hub> down` (and to `hub2`); `ping -c1 -W1 <rogue loopback>` with tcpdump on `outsider` | ping fails with "unreachable" at once; 0 packets to rogue's loopback on the underlay |
| F22 | I8 | `victim`: `ip route add <rogue loopback>/32 via 192.168.1.66` (what a rogue DHCP server would push); ping | 0 packets on the underlay; `victim` counter "fabric destination on a link outside the fabric" +N |
| F23 | I9 | `rogue`: `nc -z -w2 <hub loopback> 179`; and `nc -z -w2 -s <rogue loopback> <hub transfer address on rogue's link> 179` | both refused; hub's session count and uptimes unchanged |
| F24 | I9 | `outsider`: `nping --udp -p 3784 --ttl 255 -c5 <hub underlay>`; `rogue`: the same with `--ttl 64` to hub's transfer address | `show bfd peers brief` on `hub` unchanged |
| F25 | I2 | `outsider`: `ping -I <victim loopback as local address> <hub underlay address>` | `hub` sends no echo reply (tcpdump on `victim` and `outsider`) |
| F26 | I14 | on `victim`: `nft delete table inet routed-fabric-fleet; systemctl restart frr` | `frr.service` fails; no BGP route in `ip route`; then `systemctl reload nftables; systemctl start frr` recovers |
| F27 | I15 | on `hub`: `systemctl reload nftables` | every BGP peer uptime keeps growing |
| S01 | I12 | force `victim`→`rogue` by `hub` and `rogue`→`victim` by `hub2` (shut one session on each); a TCP stream of 5 s | completes |
| S02 | I12 | during a TCP stream, `hub.crash()` | the stream finishes within the `site` BFD budget |
| S03 | I5 | `ping -M do -s <mtu+1>` from `victim` to `rogue` | "frag needed" arrives (the ICMP error from the spine is inside the contract) |

Suite `routed-fabric-transit`, rewritten (`isp` outside, `cloud`
upstream end and spine, `home` owner and spine, `far` leaf on `home`):

| ID | Invariant | Attacker, command | Safe outcome |
|---|---|---|---|
| T01 | I7 | positive: `isp` pings an owned address on `home` | reply; it returned through the tunnel (tcpdump on `cloud`) |
| T02 | I7 | `isp`: route `<far loopback>` via `cloud`; ping | no packet on `home`'s tunnel; `cloud` drop counter "outside to a fabric address" |
| T03 | I2 | `isp`: forged source `<far loopback>`, destination an owned address | 0 packets enter the tunnel on `cloud` |
| T04 | I7 | `isp`: forged source in the pod CIDR of a fixture cluster (or any `ours` prefix), destination owned | `cloud` counter "transit: our own source from outside" +N; 0 on `home` |
| T05 | I3 | `isp` → an owned address `home` does not hold, with a route on `home` into `far`'s link | `home` counter "from outside into a fabric link" +N; `far` sees 0 |
| T06 | I7 | on `home` (as a rooted owner): send a non-owned source into the tunnel | `cloud` `ip -s link show <rt>` rx errors +N; nothing leaves `cloud` |
| T07 | — | TCP from `isp` to `home`; read the SYN-ACK MSS | ≤ tunnel MTU − 40 |
| T08 | I7 | eval: `test_noZeroAclOnFabricLink` | — |

Kube hostile suites (`lib/kube-cluster/tests/vm/hostile.nix`; `alpha`
is server and spine, `beta` agent leaf, `mallory` leaf). Give `mallory`
`access = "client"`:

| ID | Invariant | Command | Safe outcome |
|---|---|---|---|
| K40 | I6 | `mallory`: `ip route add <pod CIDR> via <alpha transfer>`, widen its ACL, `curl` the `web` pod **on beta** | no connection; `alpha` counter "destination outside its contract" |
| K41 | L1 | the same to the `hostile-alpha` pod **on alpha** | `info(...)`, not a verdict, until P1 is decided |
| K42 | I10 | `mallory` announces a `node-bgp` VIP; a non-owner member does too | the spine's route to the VIP has the owner only |

## 7. Failure modes and stability

- **Link flap.** The guard is eval-time data. Nothing in nft or the
  WireGuard ACL follows BGP. A flap moves routes only.
- **Spine loss.** Leaves are dual-homed; ECMP; the guard is stateless
  (I12). Nothing names a spine in the zone rules.
- **Route withdrawn.** The unreachable aggregate answers. No leak (I8).
- **Node reboot.** `nftables.service` loads before the network
  (assumed, §9 A4). Rules match by name (`iifname`), so they load
  before the links exist. FRR starts after IfState and after the guard.
- **nft fails to load.** Build-time: `networking.nftables.checkRuleset`
  catches syntax (assumed on, §9 A4). Run-time: FRR refuses to start
  (I14). Underlay and SSH are untouched.
- **Deploy, nothing changed.** Nothing restarts (I15; FRR reloads,
  `test_frrDeployReloads` exists).
- **Deploy, guard changed.** The table is replaced in one transaction.
  Counters reset. Sessions stay.
- **Partial deploy of this design** (only matters once machines exist):
  - ACL = `from`: safe one end at a time. The old end is only wider.
  - nft contracts: safe one node at a time.
  - GTSM: a link is down from the first end's deploy to the second's.
    Deploy both ends of a link together. The deploy path is the
    underlay, so it still works.
  - Keys per adjacency: the same, per link.
  - Transit tunnels: the tunnel is down until both ends are deployed.
- **Key rotation.** Per adjacency: `clan vars generate <m> --generator
  routed-fabric-<i>-adj-<hash>-key --regenerate`, deploy `<m>`, deploy
  the peer. That link is down in between. A dual-homed leaf keeps its
  other spine. Rotate one link at a time. Document it in
  `documentation/docs/services/routed-fabric.md`.
- **Member joins.** Before step 8: every member must be deployed before
  the new one is reachable everywhere. After step 8: the new member and
  its spines.
- **Lockout (hard rule 11).** Every rule needs a fabric link or a
  fabric address. `targetHost` is never a fabric address (assertion
  exists). The one risk: the underlay LAN's own range overlaps a fabric
  pool. Then LAN hosts look like "fabric source from outside". The
  overlap assertion (`default.nix:1433-1440`) covers declared
  underlays; warning A7 covers DHCP ones. Keep the default pools.
- **`arp_ignore = 1`.** A machine still answers ARP for an address on
  the asking interface. Floating-pool addresses sit on the interface
  that answers, so they keep working (assumed; run a floating suite).

## 8. Implementation order

Each step is one PR. Spec first, every time (hard rule 3): D63 and
§6.12/§6.13 in `SPEC.md`, plus
`documentation/docs/services/routed-fabric.md` and
`documentation/docs/architecture/routed-fabric.md`. I suggest one new
decision, **D73 "link contracts"**, that supersedes D63's R5 and R7
paragraphs.

Static gate for every step: `git add -A`, `fmt`, `check`.
VM gate: `vm-test --check <suite>`, then `vm-test <suite> --remote
--quiet`, one suite per call.

| # | Step | Content | Proof |
|---|---|---|---|
| 1 | Zone guard + source contract | 3.2 (`contract`, `allowedIPs = sources`), chain `ingress` without the `vmap`, BGP/BFD input rules, `fabricInside` fact and its three setters, suite `hostile-fabric` from the prototype. Transit links: `iifname { transit } accept` at the top of `ingress`, today's forward rules unchanged. | `hostile-fabric` (`HOSTILE_FABRIC_OK`, F05..F17 safe); `test_contractMirror`; `routed-fabric`, `routed-fabric-transit`, `k3s-single`, `router-kube`, `nat-gateway-kube` |
| 2 | Link contracts in nft | sets, `link_<L>`, `forward`/`from_fabric`/`into_fabric`, `egress`; delete `guardBorder`. Transit links still exempt (not in the `vmap`; their old rules stay first in `from_fabric`). | F18, F19, F22, S01..S03; K40; `test_guardOnEveryMember`, `test_clientContractHasNoPods`; every kube and gateway suite (`vm-test --all --remote --rebuild --quiet`) |
| 3 | Options and filters | typed prefixes, rename `extraPrefixes`, remove `firewall.trust`, A3..A5, R-A5 `originRoutes`, text for (h). | nix-unit (`test_nodeBgpOwnerOnly`, `test_pinnedLoopbackInPool`, type failures); K42 |
| 4 | Transit tunnels | 3.4 whole; `node_transport` schema 3 and `fabricInterfaces`; MSS clamp; remove `border.forwarding`; A1, A2, A6; rewrite `transit.nix`. | T01..T08; `test_transitEndsDerived`, `test_noZeroAclOnFabricLink`; kube suites (consumer of `fabricInterfaces`) |
| 5 | Session and link hardening | GTSM, drop 4784, link sysctls, `arp_ignore`. | F20, F23, F24; `checks.frr-conf`; `k3s-frr-failure` (graceful restart still holds); one floating-pool suite |
| 6 | Keys per adjacency | 3.9. | `test_keysPerAdjacency`; `routed-fabric` (handshakes per adjacency) |
| 7 | Fail closed | 3.10. Run P2 first. | F21, F26, F27; `k3s-data-plane` |
| 8 | Consumption by pool | 3.11. | `test_memberJoinTouchesSpinesOnly`; `hostile-fabric` (F12..F16 still safe); kube suites |
| 9 | Probes | P1, P3, P5, P6 (§9). Each ends as assertions in a real suite, or as a recorded "no". | `FINDING` lines |

Steps 1 and 2 give most of the safety. Step 4 is the largest and
needs the owner's yes on the option change.

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
- With eBPF host routing pod traffic skips nft (`specs/gateway.md:326`).
- IfState 2.5.1's schema has `preshared_key`, route `type`
  (`unreachable`), and a per-interface `sysctl` object.
- WireGuard drops a source outside `allowed-ips` before tcpdump
  (`documentation/docs/reference/upstream-facts.md:35-40`).
- The prototype closes F05..F11 (`runs/hostile-fabric.with-fix.verdicts.txt`).
- Note: the recorded run on `main` shows F17 **safe**, not a gap.
  The design covers it anyway (I4).

Assumed (check each where it lands):

- **A1.** `iifname vmap { "x" : goto chain }` and `oifname` wildcard
  names in anonymous sets load on nftables 1.1.6. (`nft -c` in the
  build check will tell.)
- **A2.** On a kube node, traffic that is *relayed* (fabric link to
  fabric link) and host-bound traffic still pass nft; only pod-bound
  and pod-sent traffic skip it. If relayed traffic also skips nft on a
  kube spine, I4 and I6 fail there. **K40 is the test.** Run it in
  step 2 before anything else builds on it.
- **A3.** A filter chain on the `postrouting` hook is legal in `inet`
  and sees locally generated packets.
- **A4.** NixOS `nftables.service` is ordered before
  `network-pre.target`, replaces each declared table atomically, leaves
  Cilium's tables alone, and `checkRuleset` is on by default.
- **A5.** FRR's BFD for a directly connected eBGP neighbor uses port
  3784 only. If a suite's BFD goes down after 4784 closes, put it back
  and record the fact.
- **A6.** Linux answers ARP for any local address on any interface by
  default (`arp_ignore = 0`). F20 on `main` should show it as a gap
  first.
- **A7.** ICMP errors a spine generates take the `src` of the BGP route
  (the loopback). S03 tests it. If they carry a transfer address, add
  the fabric transfer pool to every `src` set (a small widening).
- **A8.** IfState's per-interface sysctl object accepts the keys in
  3.8. If not, use `sysctl_conf` lines with the link name.
- **A9.** Cilium maps a packet's source address to an identity also on
  an external device. That is why T04 exists.
- **A10.** `ttl-security hops 1` works together with `bfd` and
  graceful restart on FRR 10.7.1. `checks.frr-conf` proves the syntax
  only; `k3s-frr-failure` proves the rest.

Probes (throwaway suites that print `FINDING`):

- **P1 (limit L1).** Can a `client` leaf with a hand-made route reach a
  pod that runs on a kube spine? Expected: yes. Then the owner chooses:
  (1) document it and leave it to Cilium policy (day 2);
  (2) the bootstrap bundle carries a clusterwide Cilium policy that
  denies the loopbacks of non-admin, non-member fabric members to pods;
  (3) forbid `client` leaves on a spine that is a kube node (this kills
  the kamrui-h1 shape, so likely no).
- **P2.** Does an `unreachable` route for the loopback pool disturb
  Cilium (its `bpf_fib_lookup`, node-to-node health)? Run
  `k3s-data-plane` with it.
- **P3.** A *secret* clan var shared by exactly two machines, in
  `clanTest`: does each end get the file, and only those two?
- **P5.** `notrack` for relayed traffic on a spine: conntrack count
  under a flood stays flat; `router-kube` and `nat-gateway-kube` still
  pass.
- **P6.** Which uid opens the Cilium BGP session to `::1`? Does the
  output rule in (t) break it?

Top risks:

1. **Cilium bypass (A2, L1).** The whole nft half assumes relayed
   traffic is visible on a kube spine. If K40 fails, the destination
   contract cannot live in nft on such a node. Fallback: forbid the
   relay role on kube nodes, or move that check into Cilium policy.
2. **The destination contract breaks a legal flow nobody listed.**
   Anything sent over the fabric without a BGP route (a static route in
   a gateway or CLAT suite) is dropped by `link_<L>`. I found none
   (`lib/gateway/*.nix` has no fabric route), but only the full suite
   run in step 2 proves it. Never widen a set to make a suite pass:
   find the flow and give it a route (`extraPrefixes`).
3. **The transit split (step 4)** changes the option surface and adds a
   second tunnel between two machines that are also adjacent. It needs
   the owner's yes. Failover of a dead tunnel is still static (as
   today).

Fallback, if the owner keeps `externalTransit` on adjacencies: the
transit link stays in the `vmap` with its own chain:

```
chain link_<T> {
  ip  saddr @src4_<T> ip  daddr @dst4_<T> accept      # member traffic, the normal contract
  ip6 saddr @src6_<T> ip6 daddr @dst6_<T> accept
  ip  saddr @ours4 counter drop comment "transit: our own source outside its contract"
  ip6 saddr @ours6 counter drop comment "transit: our own source outside its contract"
  ip  daddr != @owned4 counter drop comment "transit: outside reaches ownedPrefixes only"
  ip6 daddr != @owned6 counter drop comment "transit: outside reaches ownedPrefixes only"
  accept
}
# from_fabric, first rule: an outside source ends here
iifname { <T> } ip  saddr != @ours4 oifname { <all L> } counter drop comment "transit: ends on this border"
iifname { <T> } ip6 saddr != @ours6 oifname { <all L> } counter drop comment "transit: ends on this border"
```

This fixes R-A3 (pods cross under the normal contract) and needs the
R-A6 assertion (`sourceReturn` needs `externalTransit`). It does not
give I7. On a kube owner the link is still a Cilium device with a 0/0
ACL, and the kube input rules still trust its name.
