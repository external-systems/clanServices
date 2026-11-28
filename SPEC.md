# Kubernetes cluster clanServices — Full Specification (agent edition)

Single dense contract for agents; `documentation/` (MkDocs) is the human
record. **Same spec, two renderings — edit both together.** This file is
both the *target contract* and the *status authority*.

**Round 68 (2026-11-28): wave 2 of the round-61 target design for
netif (steps 2 to 4) and the gateway (steps 4 and 5).** One PR, one
commit per step (`specs/design-netif.md` §8.3 to §8.5,
`specs/design-gateway.md` §8 rows 4 and 5). The contracts are
`specs/netif.md` and `specs/gateway.md`:

- **Test tooling.** `VM_PHASES='word|word' vm-test <suite> --rebuild`
  runs only the named subtests of any suite (an impure evaluation; the
  suite derivation is unchanged without it); `soft_checks` collects
  independent failures (`documentation/docs/reference/testing.md`).
- **N48** router advertisements only where declared: `ra` defaults to
  false, the kernel's `default` scope takes none, an `ra` link takes a
  prefix and (only when it may own the IPv6 default and has no static
  gateway) the default router, never route information, an MTU or a
  low hop limit.
- **N49** evaluation checks (design §3.9): gateways and route gateways
  inside the link's subnets, no network or broadcast host address, one
  deploy-target instance, an sshd port open on the deploy link (errors);
  a guard with nothing to test, links with the firewall off (warnings).
- **N50** DHCP is untrusted input: no lease routes (options 33, 121,
  249) without `dhcp.classlessRoutes`, never a lease MTU, lease DNS
  only on a default-owning link or with `dhcp.dns`; a hot-plug link's
  DNS is no default route while a declared link has DNS.
- **G29** (`specs/gateway.md`) the router's table and the NixOS
  firewall render from one value per link (`wanPorts` now connects);
  ICMP by type with the echo rate ahead of the connection tracking; a
  router needs a zone; the service /64 alone runs the prefix hook;
  links come up after the tables.

| ID | Was | Now | Proof |
|---|---|---|---|
| G29 | `wanPorts` reached one of two firewalls; every ICMP type accepted, an echo flood answered in full; a router without zones rendered broken nft; a service /64 without an advertised zone had no hook | One value for both firewalls; ICMP by type, a rate ahead of `established`; I23; `hookWanted` | `hostile-router` (R17, R19, R20 with controls, P5), `router`, `router-kube`; nix-unit `test_bothFirewallsAgree`, `test_wanPortsBothFirewalls`, `test_icmpAndRedirects`, `test_noZones` |
| N50 | A lease installed its option-121, 33 and 249 routes and an MTU on its routes; any DHCP link's server became DNS for all names | A closed list per link, opt-ins `dhcp.classlessRoutes` and `dhcp.dns`; DNS scope explicit | `netif-hostile` (H09–H13, H18a–c, each group with a control), `netif-dhcp`, `netif-hotplug`; nix-unit `test_dhcpOptionPolicy`, `test_dhcpOptInsNeedDhcp` |
| N49 | A wrong gateway, a network address, two deploy targets or a closed sshd port on the deploy link reached the machine | Build errors (warnings for an empty guard and a closed-off firewall) | nix-unit `test_gatewayChecks`, `test_routeGatewayChecks`, `test_networkAddressRejected`, `test_twoTargetHostsRejected`, `test_deployLinkOpensSsh`, `test_checkWarnings`; `netif-vmhost` (guest port `gp(1`) |
| N48 | Every link took router advertisements, beside a static IPv6 gateway too; a guest port, a VLAN parent or a member took them | Only links with `ra = true` and hot-plug links; there no route information, MTU or hop limit | `netif-hostile` (H02, H03, H04, H15, H16a–d, H23 and the RA survey, each with a control), `netif`, `netif-dhcp`, `netif-v6only`, `netif-hotplug`, `router`, `hostile-router`, `gateway-wan`; nix-unit `test_raOffByDefault`, `test_raOptIn`, `test_raOnMember`, `test_dhcp6NeedsRouter` |

**Round 67 (2026-11-28): kube steps 3 and 4, a fabric always, typed
options, HAProxy on loopback, one firewall matrix (D76).** Wave 2 of the
round-61 target design for the kube services (`specs/design-kube.md`
§8 items 3 and 4):

- **Manual-address mode is gone.** `network.fabric` is required (no
  default); `network.ipv4`, `network.ipv6`, the `eth0`/1500 guesses and
  the "bgp needs a fabric" and all-or-none posture assertions are
  deleted. A member without a `node_transport` export is an eval error.
  A one-machine cluster is a one-machine fabric. The kube guard table
  (D74) is rendered on every member.
- **Typed options (K-A7).** `domain` is a DNS name; the pod, Service and
  fabric-pool CIDRs use the `lib/ip.nix` prefix types.
- **Parity (K-A8).** A distro's own options (rke2 `profile`) and the new
  `firewall` group are cluster-level: every machine of every role must
  agree.
- **The READMEs evaluate (H7, K-A4).** Both quick starts are a
  one-machine `routed-fabric` instance plus the cluster; the inventory
  lives in `services/<distro>/tests/readme-inventory.nix`, the README
  shows it verbatim, and `test_readmeQuickStart` evaluates it with no
  failed assertion of the services.
- **HAProxy fronts on loopback** (§6.6). The kubeapi name resolves to
  `127.0.0.1` and `::1`; every server line pins `source` to the node's
  fabric address. An rke2 agent's supervisor front takes port 9345 (its
  tunnel, which `kubectl logs` and `exec` ride, dials the servers on the
  port of its join URL).
- **One firewall matrix** (§6.12, `lib/kube-cluster/firewall.nix`):
  `api` 6443 (servers; members and pods), `supervisor` 9345 (rke2
  servers; members), `kubelet` 10250 (every node; servers, pods only
  with `firewall.kubeletFromPods`), `cilium-health` 4240 (every node;
  members), `etcd` 2379, 2380 (servers; servers). No row for the fronts
  or 2381; `trustedInterfaces` for `cilium_host`/`cilium_net` is gone.
  A pod reaches the API on a server and nothing else of a node.

Not in this round (later kube steps): the state beacon and decider
(step 5; until then the `ha` suite's "peers refuse" phase uses a test
port the peers reset), CA-pinned tokens (step 6), the outside-to-pods
policy (step 7), Service fronts by source (step 8), Pod Security (step
9).

| ID | Was | Now | Proof |
|---|---|---|---|
| D76 | Manual addresses beside the fabric (unbooted, `eth0` pinned, an unguarded firewall branch); untyped CIDRs and domain; `profile` outside parity; a README that failed its own assertion; HAProxy fronts on the node addresses, open to members and pods; the kubelet and 4240 open to pods; 2381 open to servers; Cilium's host links trusted | `network.fabric` required; typed options; parity for distro options; README evaluated; loopback fronts with `source`; the matrix; no trusted link | `k3s-hostile`, `rke2-hostile` (K20, K21: `[6443]` on a server, nothing on an agent; K27: loopback binds, a member and a fabric leaf outside the cluster do not reach a front, each with a control; K41, K42); `<distro>-single`, `<distro>-join`, `<distro>-ha`, `k3s-data-plane`, `k3s-clustermesh`; nix-unit `test_firewallMatrixRows`, `test_firewallBySource`, `test_firewallRenderMatrix`, `test_readmeQuickStart`, `test_typedOptions`, `test_fabricRequired`, `test_profileParity` |

**Round 66 (2026-11-28): fabric steps 3, 5 and 7, options and filters,
link hardening, fail closed (D75).** Wave 2 of the round-61 target
design for routed-fabric (`specs/design-routed-fabric.md` §8.2, §8.4,
§8.6):

- **Typed options.** `ipv4`, `ipv6`, the pools, `ownedPrefixes`,
  `extraPrefixes` (renamed from `extraAllowedIPs`: it is a route, an ACL
  entry and a contract entry) and an upstream's `address` are typed; an
  `acceptedPrefixes` entry is asserted to be a prefix with optional
  `ge`/`le`. `firewall.trust` is gone: the fabric is never a trust
  zone.
- **A pinned loopback lies in its pool** (A5). New member-uniform
  `loopback6Pool` for pinned IPv6 loopbacks (the generated ULA cannot be
  known in advance). The guard's fabric set is the pools and nothing
  else: a member that joins changes no other member's table.
- **`node-bgp` is owner-only in the fabric** (R-A5): only the owner may
  originate the pool, so a spine imports it from the owner's link only,
  no other member's WireGuard ACL carries it, and a non-owner's Cilium
  session cannot hand it to FRR. Consumption is unchanged.
- **Bug fixed on the way:** the `kube_cluster` export carried
  `owner = null` for every pool (`resolvePools` keeps blocks and
  selector only), so the fabric never knew a `node-bgp` pool's owner.
  The export now takes the owner from the declared pool (nix-unit
  `test_nodeBgpOwnerExported`; `k3s-data-plane` "node-bgp owner-only
  delivery" failed without it).
- **Owned prefixes** are no shorter than /8 or /16 and overlap neither
  the fabric's pools nor a cluster's pod or Service CIDRs (A3, A4). A
  warning names a pool in a private range on a DHCP underlay (A7).
- **Link hardening.** Fabric links take no redirect, source route or
  router advertisement (IfState per link, the netif N47 baseline plus
  `accept_ra = 0`); every member sets `arp_ignore = 1`,
  `arp_announce = 2` (`mkDefault`, the same values as netif's later
  baseline, H16). On a member with a Cilium neighbor only root may open
  BGP on the loopback.
- **Fail closed.** The fabric's pools are `unreachable` in the main
  table (metric 4294967000) until BGP or a link says otherwise. The new
  suite `routed-fabric-fail-closed` boots a member without its guard:
  no routing daemon, no BGP route, "No route to host", and FRR starts
  by itself when the table loads.

Not in this round (later fabric steps): transit tunnels, `border.transit`
and the removal of `externalTransit`, `sourceReturn*` and
`border.forwarding` (step 4); keys per adjacency (step 6); consumption by
pool (step 8).

| ID | Was | Now | Proof |
|---|---|---|---|
| D75 | Untyped addresses; pins anywhere, so `F` listed every member; any cluster member could originate a `node-bgp` pool into the fabric; `firewall.trust`; ARP answered for the loopback on the underlay; a withdrawn fabric route fell to the default route | typed options, pins in pools (`loopback6Pool`), `F` = the pools; `node-bgp` owner-only; no trust option; link sysctls and ARP keys; root-only BGP on the loopback; unreachable aggregates | `hostile-fabric` F20, F20c, F21, F21b, F26, F27; `routed-fabric-fail-closed` (`ROUTED_FABRIC_FAIL_CLOSED_OK`); `k3s-hostile` K43, K44; `k3s-data-plane`, `k3s-join`, `k3s-frr-failure`, `routed-fabric`, `routed-fabric-transit`; nix-unit `hardening.*` |

**Round 65 (2026-11-28): gateway steps 0 to 3, the guards of the
translators and of a CLAT host.** The gateway part of wave 1 of the
round-61 target design (`specs/design-gateway.md` §8 rows 0 to 3). The
contract is `specs/gateway.md` (round G12, decisions G26–G28):

- **The hostile suites** `nat-gateway-hostile` and `hostile-router`
  are in the tree. Every verdict group has a positive control that
  gates the suite (H19). `hostile-router` R15 was empty on every run
  before: the attacker's radvd refused its config (no
  `MinRtrAdvInterval`) and sent nothing; now a capture on the router's
  link and a LAN neighbour that takes the rogue prefix prove the attack
  ran.
- **G26** a default-deny table `inet guard` in the `nat64` and `clat`
  namespaces, loaded by the Jool unit before an instance exists;
  forwarding off in both; `pool6` and the CLAT address `unreachable`
  there. A gateway whose guard cannot be loaded withdraws its beacon.
  Closes N05 (`127.0.0.1` of the translator answered), N06 and N07 (one
  packet crossed the veth 32 times).
- **G27** the gateway's host table refuses while the packet is still
  IPv6 (a private embedded IPv4, other protocols, untranslatable ICMPv6
  types) and checks what leaves the namespace; eval assertion I7 (one
  source /64 cannot fill pool4); Jool's timeouts pinned.
- **G28 (H17, O7)** a CLAT host forwards IPv6 only for its CLAT and for
  the links a service declares in the new fact
  `clan.networkFacts.forwardLinks` (§6.15): k3s and rke2 `cilium*`,
  `lxc*`; routed-fabric its fabric and transit links; the router its
  links. The CLAT host's table `inet clat` also lets only a gateway's
  `/96` with a public embedded IPv4 reach the CLAT.

Not in this round (later gateway steps): the router's two firewalls
from one value, ICMP limits and redirect sysctls (step 4), the prefix
hook's validation and sandbox (step 5), `unzoned.zones` folded into
`zones.<name>.fabric` (step 6).

| ID | Was | Now | Proof |
|---|---|---|---|
| G26–G28 (`specs/gateway.md`) | Jool's hand-backs delivered and forwarded in its namespace (loopback answered, 32 crossings); private destinations refused after translation; a CLAT host an IPv6 router between all its links | guard table and forwarding off in both namespaces; refusal before translation; `inet clat` with forward links | `nat-gateway-hostile` (`NAT_GATEWAY_HOSTILE_OK`, no gap, every control works), `hostile-router` (`HOSTILE_ROUTER_OK`), `nat-gateway`, `nat-gateway-failover`, `nat-gateway-kube`, `k3s-clat`, `rke2-clat`, `k3s-clat-mapped`, `router`, `router-kube`; nix-unit `test_guardText`, `test_table`, `test_limitBound`, `test_forwardLinks`, `test_fabricLinksAreForwardLinks`, `test_forwardLinksFact` |

**Round 64 (2026-11-27): netif steps 0 and 1, the threat model, one
sysctl baseline and `netif-hostile`.** First netif step of the round-61
target design (`specs/design-netif.md` §8.1, §8.2). The contract is
`specs/netif.md` (status authority for host networking):

- **N46** the threat model (T1–T8) and the invariants (I1–I13, S1–S5)
  of the design are part of the netif contract; each invariant names
  the step that implements it.
- **N47** one sysctl baseline for every link of every IfState-base
  machine, in every mode: no ICMP redirect taken or sent, no
  source-routed packet. `lib/ifstate.nix` writes `all`, `default` and
  the glob `*`; netif writes the same keys on each declared link. It
  reaches fabric and kube nodes too (they import the same base).
- **`netif-hostile`**: every verdict group with a positive control that
  gates the suite (H19). What netif step 2 closes (an RA default and a
  SLAAC address beside a static IPv6 gateway) is an `info` line naming
  the step. The attacker's radvd is a test fixture (H23).

| ID | Was | Now | Proof |
|---|---|---|---|
| N47 | Redirects accepted (kernel default 1 on a link) and sent; nothing pinned source routes | 0 on every link, every mode, from two sinks | `netif-hostile` (`NETIF_HOSTILE_OK`, no gap, every control works), `netif`, `netif-guard`, `netif-dhcp`, `netif-hotplug`, `k3s-join`, `routed-fabric`; nix-unit `test_sysctlBaseline` |

**Round 63 (2026-11-27): kube step 1, the hostile suites and the first
kube guards (D74).** First kube step of the round-61 target design
(`specs/design-kube.md` §8 item 1). It puts `k3s-hostile` and
`rke2-hostile` in the tree (one body,
`lib/kube-cluster/tests/vm/hostile.nix`) and lands the minimal fixes
that make them pass with no gap:

- **The kube guard table** `inet kube-<instance>` (L1, design §3.3) on
  every member with fabric links: raw prerouting accepts the fabric
  links, `lo`, `cilium*`, `lxc*` and the `fabricInside` links, and drops
  and counts any other link's packet to the cluster's pod or Service
  CIDRs ("outside to the cluster's pods and Services"). An outsider on
  the node LAN that routes a pod address to a node no longer reaches it
  (K05, K06).
- **The rke2 supervisor front is member-only** (K-A2): its HAProxy
  front (`8442 + cilium.id`) moved from the ports open to members and
  pods to `memberOnlyPorts`, beside the supervisor itself. A pod
  reaches neither (K24).
- **`packages.rke2` is the runtime** (K-A1): `services.rke2.package`
  is the effective package, the same one the airgap images come from.
- **The spec text matches the code** (K-A10): §6.6 says where HAProxy
  binds today, §6.12 names the API front and the member-only
  supervisor front, and the 2381 rule is explained.
- **`<distro>-single` reads a certificate's lifetime as notAfter minus
  notBefore.** It checked "valid for 364 more days from now", which
  fails a day after the test vars were generated: clan reuses them
  while their inputs stay the same. The behaviour proved (the admin
  identity lives 365 days, the health-check certificate about ten
  years) is unchanged.

The suites merge the kube prototype (K05d..K53) and the fabric
prototype (`mallory` as an `access = "client"` leaf, K40a, K40, K41,
P5, P6). Every verdict group has a positive control (`control(...)`):
the attack runs without the guard table, its packets are seen to
arrive and be counted, or the same probe finds a legal target. A
failed control fails the suite (H19). What a later kube step closes is
an `info` line that names the step: NodePorts answer a fabric leaf
outside the cluster (K10n, K13: step 8), a pod on a kube spine and a
LAN link that is a Cilium device (K41, K05d: step 7), the fronts bind
the node addresses (K27: step 4), tokens without the CA pin (K34: step
6), Pod Security (K50: step 9).

| ID | Was | Now | Proof |
|---|---|---|---|
| D74 | No guard for pod and Service CIDRs from a non-fabric link; the rke2 supervisor front open to pods; `packages.rke2` set the images only | `inet kube-<instance>` drops them; the front answers members only; `packages.rke2` is the runtime | `k3s-hostile`, `rke2-hostile` (`<DISTRO>_HOSTILE_OK`, no gap, every control works), `<distro>-join`, `<distro>-single`, `k3s-data-plane`; nix-unit `test_kubeIngressTable`, `test_packageOverrideIsRuntime`, the firewall tests |

**Round 62 (2026-11-27): fabric steps 1 and 2, the link contract and
the guard (D73).** First implementation step of the round-61 target
design (`specs/design-routed-fabric.md` §8.1). routed-fabric now names
what is allowed instead of what is bad:

- **One link contract per adjacency.** `sources` (what the peer may
  announce, plus its transfer address) and `destinations` (what the
  peer is sent routes for, plus this end's transfer address) are the
  adjacency's existing `import` and `export` sets. WireGuard's
  AllowedIPs is `sources` (plus 0/0 on an `externalTransit` link until
  transit tunnels become their own link class), the FRR lists read the
  same two sets, and so does the guard table. `export` left the ACL: on
  a leaf it let the leaf's own addresses in as sources.
- **One guard table on every member with an adjacency**
  (`inet routed-fabric-<instance>`), the same shape on a leaf and a
  spine: `ingress` (raw prerouting: a fabric link carries only its
  contract; another link carries no fabric source and reaches no
  fabric address unless its owner declared it inside), `forward`
  (default deny for a packet that uses a fabric link: only a spine
  relays between fabric links; pod links and inside links pass) and
  `egress` (a fabric destination never leaves by another link). It
  replaces round G11's border forward filter.
- **`access` is enforced on the spine** (H4): a leaf reaches only
  what it is sent routes for. This covers what a spine relays; a pod on
  a kube spine is kube's to guard (limit L1, H12).
- **BGP and BFD answer the link's peer address only**, sent to this
  end's address on the link; BFD single hop on 3784 with TTL 255. UDP
  4784 is closed on fabric links and no `ttl-security` is rendered
  (H20).
- **FRR waits for the guard table** (an `ExecStartPre` that waits
  80 s per attempt, never `requires`).
- **The fact `clan.networkFacts.fabricInside`** (H3): the CLAT and
  NAT64 host links always; a router zone only with
  `zones.<name>.fabric = true` (default false). The router option lands
  here because `router-kube` needs it; the rest of the router's zone
  rework (`unzoned.zones` folded into it) stays gateway step 6.

Not in this round (later fabric steps): `arp_ignore`, link sysctls
(step 5), keys per adjacency and preshared keys (step 6), unreachable
aggregates (step 7), typed options (step 3), transit tunnels (step 4).

| ID | Was | Now | Proof |
|---|---|---|---|
| D73 | ACL = import ∪ export; a forward filter on forwarding borders only; 179 and BFD (3784, 4784) open on every fabric interface | link contract feeds WireGuard, FRR and nft; one guard table on every member; BGP/BFD pinned per link; FRR waits for the guard | `hostile-fabric` (`HOSTILE_FABRIC_OK`, every verdict with its positive control), `routed-fabric`, `routed-fabric-transit`, the kube and gateway suites of the PR; nix-unit |

**Round 61 (2026-11-27): best design first; owner decisions of the
hardening review.** No code changed in this round. The owner set the
phase rule for the work up to the 0.1.x release (§7 "Current phase"):
there are no consumers and no deployed machines, so every clanService
is judged on the best design for safety and stability, and the suites
are rewritten to prove that design's behaviour. A whole-repo review
with hostile-actor VM suites (an attacker VM; hermetic) found gaps on
`main`; their fixes land in later rounds, each with its suite. The
decisions below are **decided, not implemented**. The target design
that follows from the rule is `specs/target-design.md` (index, shared
contracts, owner decisions O1–O8, probe results, build order) with one
file per area: `specs/design-routed-fabric.md`, `specs/design-kube.md`,
`specs/design-gateway.md`, `specs/design-netif.md`. A probe round on
the same day ran a prototype of each area in VM suites on the remote
builder; each design line says VERIFIED-VM, REFUTED or NOT-RUN, and the
findings are `specs/probes/2026-11-27/`. The prototypes are not on
`main`. Until a step implements a part and amends this file or
`specs/{netif,gateway}.md`, those stay the status authority.

| ID | Decision | Status |
|---|---|---|
| H1 | Best design first: tests prove behaviour and may be rewritten; a safety behaviour is never dropped; hostile suites are extended, never weakened (§7) | active |
| H2 | NodePorts answer cluster members only by default; an opt-in list names other sources. Published services use LB VIPs | decided, not implemented |
| H3 | Links that may reach fabric and pod addresses through a machine: the fabric's own, the CLAT link and the NAT64 link always; a router zone only when it opts in (default off) | implemented round 62 (D73, `zones.<name>.fabric`) |
| H4 | `access = client\|member` is enforced on the spine, not only by the leaf's imports | implemented round 62 (D73) for what a spine relays; a pod on a kube spine is H12's |
| H5 | routed-fabric does not originate `ownedPrefixes` into the fabric: the upstream's route to them is the operator's (R7). Eval warning when a prefix is owned and no upstream is declared | no origination: as built (the option text says so since round 66); the warning comes with transit tunnels (fabric step 4) |
| H6 | netif ignores DHCP classless routes (option 121) by default; a link may opt in | decided, not implemented |
| H7 | The README quick start must evaluate (a nix-unit test evaluates it); its assertion stays | implemented round 67 (D76, `test_readmeQuickStart`) |
| H8 | A rogue router advertisement between two LAN neighbours is layer 2 and out of scope for the router; documented as a limit | active |
| H9 | Every interface schema version is reset to 1 before the 0.1.x release, with no migration (hard rule 10) | decided, not implemented |
| H10 | The target design of `specs/target-design.md` is the direction for netif, routed-fabric, the kube services and the gateways: allow-lists, not drop-lists | decided, not implemented |
| H11 | (O1) A transit tunnel is its own outside-class link type; `externalTransit` and `sourceReturn` go | decided, probed, not implemented |
| H12 | (O2) A non-member must not reach a pod, also on a kube spine. The guard is a clusterwide Cilium policy rendered by the bootstrap: nft does not see a packet for a pod on the receiving node. This policy is part of the data plane (it amends §3.3 "policy is day-2" when it lands) | decided, probed, not implemented |
| H13 | (O3, refines H2) No custom eBPF. Every outside-facing Service is type LoadBalancer with source ranges; Cilium guards every front by them; admission policies refuse NodePort Services, `externalIPs` and missing ranges, and fill in the default (members and pods) | decided, probed, not implemented |
| H14 | (O4) Pod Security default: enforce `baseline`, warn `restricted`; a namespace label opts out | decided, probed, not implemented |
| H15 | (O5) netif: a new configuration must prove itself or the machine stays on the last good one; a declared one-shot override covers a planned move | decided, probed, not implemented |
| H16 | (O6) No `accept_dad = 0`. `arp_ignore = 1` and `arp_announce = 2` on fabric members and netif links | fabric members implemented round 66 (D75); netif links: netif step 8 |
| H17 | (O7) A CLAT host forwards IPv6 only for the CLAT and for links a service declares (`forwardLinks`) | implemented round 65 (`specs/gateway.md` G28) |
| H18 | (O8) remote-builder is redesigned apart, with the matching change in external-systems/home; not before the owner schedules it | decided, not implemented |
| H19 | Every hostile verdict has a positive control; a missing control fails the suite. Two RA verdicts were empty without one | active for new suites |
| H20 | No GTSM on fabric sessions: on FRR 10.7.1 it turns the neighbor's BFD multihop. Sessions are pinned by link, peer address and own address | implemented round 62 (D73) |
| H21 | A host of a router zone with `fabric = true` is `world` for Cilium: it reaches only pods labelled `clan.lol/outside=allow` (or in a labelled namespace), through a Service whose source ranges hold it | decided; the zone option is in (round 62), the Cilium policy is kube step 7 |
| H22 | The ClusterMesh API Service is type LoadBalancer with source ranges on every exposure mode, node-port too (a class no controller serves, its fixed NodePort answers the ranges only). On node-port exposure `cilium clustermesh status` cannot read it; `cilium-dbg status` on the agents replaces it | decided (owner, 2026-11-27); kube step 8 |
| H23 | (O11) CoreRAD is the router's RA daemon, never radvd. radvd appears only as a test fixture (the ISP simulator, the attacker's rogue RA sender) | active (owner, 2026-11-27) |

**Round 60 (2026-11-26): R7, external transit.** A probe sent an
outside client through upstream → border leaf → dedicated spine →
VIP leaf. Nothing arrived: the spine's transit filter dropped every
packet from the link (its `ownedPrefixes` set was empty, so fabric
traffic died too); past it, the VIP leaf's WireGuard ACL dropped the
outside source; replies left by the leaf's underlay default; with
source-return on every hop, the border's filter dropped the replies.
The reverse-path filter dropped nothing. Decision (D63 amended): an
`externalTransit` link has exactly one owner end with
`ownedPrefixes`, the transit filter lives only there, and external
sources end on that owner (eval assertion; counted drop for the rest).

| ID | Was | Now | Proof |
|---|---|---|---|
| R7 | `externalTransit` had eval coverage only; the filter on the non-owner end dropped all forwarded traffic, fabric too; multi-hop transit silently failed | One owner end (eval error otherwise); filter on the owner only; fabric↔fabric crosses; onward forwarding into the fabric dropped and counted | `routed-fabric-transit` (`ROUTED_FABRIC_TRANSIT_OK`), nix-unit |

**Round 59 (2026-11-26): K13, one implementation of k3s and rke2.**
The two services were ~1 200 lines each, ~95 % the same (K13 of
round 58; hard rule 4). `lib/kube-cluster/service.nix` now holds the
whole service; `services/{k3s,rke2}/default.nix` are ~180-line distro
records. No behaviour changed: `suite-compare` of every suite against
`main` shows equal node derivations and test scripts. Fixes found
while moving the code are recorded for the next review, not made
here (a faithful refactor changes nothing).

**Round 58 (2026-11-26): round G11, hardening of the network stack
under Kubernetes.** A review of `main` (score 72/100) found 50
defects, most in the recovery paths (rollback, restart, re-apply,
failover). The owner approved all of them; K13 (k3s/rke2
de-duplication) and R7 (`externalTransit` probe) are their own PRs.
Where each contract lives: netif `specs/netif.md` (round G11 summary,
N25), gateway `specs/gateway.md` §17, kube and fabric below (D25,
D40, D63, §6.9–§6.12).

| ID | Was | Now | Proof |
|---|---|---|---|
| N1–N4, N6, N8 | The lockout guard could record a bad config as last-good, left a rolled-back DHCP link without a client, passed with nothing to check, never re-checked a rollback | Rollback marker; transient dhcpcd on rollback; last-good defaults per family; re-probe and re-apply when the fault is outside; `ExecStopPost` runs the guard after a failed apply | `netif-guard`, `netif-dhcp`, `netif-v6only` |
| N5, N7, N9, N10 | Members inherited a default route; an absent NIC held `network-online` 90 s; IPv6 spellings compared unequal; addresses were plain strings | Fixed; address option types from `lib/ip.nix` | nix-unit (netif `underlay.*`) |
| K1 | Server token and mesh keys on every node | Server token on servers, mesh material on the `clusterInit` server only | `<distro>-join` |
| K2 | Cluster ports open on every interface in manual mode; pods reached every host port | `lib/kube-cluster/firewall.nix`: ports by source (members, pod CIDRs); etcd servers-only | `<distro>-single` (outside host refused) |
| K3 | Init guard failed open | Ordered after IfState/FRR; refuses unless every peer refuses the connection; override file `/var/lib/rancher/<distro>/server/allow-new-cluster-<instance>` | `<distro>-ha` (five phases) |
| K4, K5, K8 | Bundle not re-applied on deploy; no prune; endless retry; keys on a command line | D40 revised: re-applied on change, CRDs awaited, labelled prune while `bootstrap.apply`, bounded retry, `data` Secrets, `--rawfile` | `<distro>-single` |
| K6, K7, K9, K11, K12, K14, K15 | Missing CIDR/voter/name checks; no k3s secrets encryption; dead `kubelet.extraArgs`; `"1"` booleans; overridable rendered keys; dead HAProxy stats admin | Assertions; two servers refused; k3s `secrets-encryption`; D25 marked planned; stats on loopback; `verifyhost` | nix-unit |
| K10 | 10-year admin certificate, fixed serials, rke2 CA copied into the live TLS dir | Admin 365 days (renew: `clan vars generate --regenerate --generator rancher-admin-kubeconfig-<i>` on a branch); random serials; rke2 stages a new CA set | `<distro>-single`; probe (rke2 refuses CAs newer than its datastore) |
| R1 | Pod routes did not cross between dedicated spines | One transit set on both ends | nix-unit `spinePair` |
| R2 | §16.3 said GR covers an FRR restart | GR covers a bgpd restart; a full restart is a race at the peer; a deploy reloads | `k3s-frr-failure` (`FRR_DEPLOY_RELOADS_OK`, `FRR_FULL_RESTART_OK`) |
| R3–R6, R8–R11 | Restarting route limits; hostname endpoints dropped silently; fabric links trusted; one-sided overrides; duplicated FRR config; open upstream import; hard-coded pod masks | `warning-only`; hostnames an eval error; `trust = false`, forward filter; symmetric overrides; shared prefix-lists; `acceptedPrefixes`, `ttlSecurity`; `podMaskSize*` export | `routed-fabric` (`ROUTED_FABRIC_UNTRUSTED_OK`, `ROUTED_FABRIC_FORWARD_FILTER_OK`), nix-unit |
| G1–G14 | See `specs/gateway.md` §17 | — | `nat-gateway*`, `router*`, `*-clat` |

K7 changed the clustermesh fixtures to one server and one agent per
cluster. Evidence of the full run: the PR of this round.

**Round 57 (2026-11-25): the review's findings are fixed**
(`specs/gateway.md` round G10, §16.3; owner: "apply all fixes").
- **Graceful restart.** The Cilium session: `gracefulRestart` in the
  `CiliumBGPPeerConfig`, 120 s. The fabric sessions: `bgp
  graceful-restart preserve-fw-state`, restart and stale-path time
  60 s, `select-defer-time 0`; zebra keeps its routes over a restart
  (`-r -K120`). Fabric neighbors carry `bfd
  check-control-plane-failure`, so a peer whose BFD fails is dropped
  at once. Suite `k3s-frr-failure` (`FRR_CILIUM_RESTART_OK`,
  `FRR_DEAD_NODE_OK`).
- **D63 amended: `site` has no default** (`null`). The `site` timer
  profile needs the same site named on both ends; every other pair
  gets `wan`. Eval test `test_stabilityProfilesAndRecovery`.
- **The Cilium session's route limit warns** (`maximum-prefix 4096
  warning-only`); fabric and upstream limits still restart after ten
  minutes. **What a leaf imports is tagged `no-export`.**
- **A `clusterInit` server without etcd data does not start beside a
  live cluster** (unit `<distro>-<instance>-init-guard`: 10 probes of
  every other server's API, 3 s apart).
- **A changed `cilium-config` rolls the agents** (pod-template
  annotation `clan.lol/cilium-config-hash`, `maxUnavailable: 1`).
  `clustermesh-apiserver` is restarted only when a ClusterMesh secret
  changed. `operator.replicas` is 2 for two or more members.
- **The PKI install asserts its secret** (`AssertPathExists`).
  HAProxy: `timeout tunnel 1h`.
- **A static IPv4 underlay inside 10.0.0.0/8 and outside the
  cluster's ranges is an eval error** (`underlayViolations`; Cilium's
  `ipv4NativeRoutingCIDR` is 10.0.0.0/8).
- **`timers connect 10`** beside `timers delayopen 5`: FRR 10.7.1
  aborts bgpd when both end together (`upstream-facts.md`).
- Eval test `test_g10Hardening` (k3s, rke2). All 48 suites passed
  (`specs/gateway.md` §16.5).
- Header range D1–D72 (unchanged).

**Round 56 (2026-11-25): D71 covers a router that is a node; a
hardening review** (`specs/gateway.md` round G9, G25, §16).
- A `router` exports its WAN zone (`router`, new export interface;
  k3s and rke2 take it as an input). On a cluster member that is a
  router the WAN link joins `devices`, for the reason a gateway's
  uplink does. Suite `router-kube`.
- **Every member's default-route link joins `devices`** (netif
  `gatewayInMain`; never a VPN zone's link). Found by `router-kube`:
  a pod on a plain dual-stack node left with its pod address, because
  Cilium masquerades on a `devices` link only. Eval test
  `test_d71DefaultRouteLink` (k3s, rke2). The other cluster suites
  render the same list as before (their derivations are unchanged).
- The review read `routed-fabric`, `lib/kube-cluster`, k3s, rke2 and
  netif. Nothing in them changed in this round. Its findings are
  ranked in `specs/gateway.md` §16.3 and wait for the owner; the first
  three concern stability: no BGP graceful restart between Cilium and
  FRR, a restart of FRR that withdraws a manager's fabric address, and
  LAN timers between members that never set `site`.
- Header range D1–D72 (unchanged).

**Round 55 (2026-11-24): D71 covers a gateway that is a node**
(`specs/gateway.md` round G8, §14.5 point 5).
- A `nat-gateway` gateway exports its uplink zone (`nat_gateway`,
  `gateway = true`). On a cluster member that is a gateway, every link
  of that zone joins `devices`: its public IPv4 is there, and Cilium
  masquerades pod IPv4 only on a `devices` link. Eval test
  `test_d71GatewayUplink` (k3s, rke2); suite `nat-gateway-kube`.
- A gateway is never a client, so it runs no CLAT.

**Round 54 (2026-11-24): D71 implemented; the gateway services exist**
(`specs/gateway.md` round G7).
- **D71 implemented:** k3s and rke2 render Cilium `devices` as the
  union, over the members, of the transport's links, each
  `nat-gateway` client's CLAT link and the links of its uplink zone
  that carry no IPv4 (`lib/kube-cluster/devices.nix`, from the `netif`
  and `nat_gateway` exports; both services now take those exports as
  inputs). A VPN link is refused at eval. Eval tests
  `test_d71RenderedDevices`, `test_d71VpnLinkRefused`,
  `test_d71NoVpnByDefault`, `test_clusterMembersTrusted` (k3s, rke2).
- **`<distro>-clat` runs on the services:** netif renders every link,
  `nat-gateway` the gateway and each node's CLAT, and nothing sets
  `devices` by hand (it renders `<fabric link> <fabric loopback> clat0
  eth1`). The nodes use a plain IPv6 resolver (no DNS64). The
  `-mapped` suite keeps its fixtures, unchanged (`suite-compare`).
- New services `nat-gateway` and `router`; their contract and status
  is `specs/gateway.md`.
- Header range D1–D72 (unchanged).

**Round 53 (2026-11-23): native routing only (D72 implemented).**
Cilium tunnel mode and `wireguard-mesh` are gone. The last `main`
commit with them is tag `tunnel-mode-final`.
- **What went:**
  - `services/wireguard-mesh` and its docs page;
  - Cilium `routingMode: tunnel` and `tunnelProtocol` (an override to
    tunnel mode is an eval error);
  - `datapath.mode` and `datapath.tunnelProtocol` in `node_transport`
    and in the `kube_cluster` export, no shim (AGENTS.md rule 10);
  - the tunnel branches in `lib/kube-cluster` and the
    `networkFacts.mesh` facts;
  - the suites `<distro>-data-plane-tunnel`,
    `<distro>-clustermesh-selective-tunnel`, `<distro>-clat-mesh`,
    `k3s-clat-mesh-mapped` and `wireguard-mesh`;
    `<distro>-clustermesh-tunnel` was ported, see below.
- **What moved onto `routed-fabric`:** `<distro>-single` (a lone
  spine), `<distro>-join` and `-join-netif` (server spine, agent
  leaf), `<distro>-v6only` (it reuses `join`). Each keeps its contract
  and its `*_OK` marker.
- **Merged twins, plain name kept:**
  - `<distro>-ha-fabric` → `<distro>-ha` (`<DISTRO>_HA_OK`);
  - `<distro>-clustermesh-external-native` →
    `<distro>-clustermesh-external` (`<DISTRO>_CLUSTERMESH_EXTERNAL_OK`);
  - `k3s-modes-fabric` → `k3s-modes` (`K3S_MODES_OK`).
- **Renamed:** `<distro>-clat-fabric` → `<distro>-clat`
  (`<DISTRO>_CLAT_OK`); `k3s-clat-fabric-mapped` → `k3s-clat-mapped`
  (`K3S_CLAT_MAPPED_OK`).
- **New:** `k3s-frr-failure` (`K3S_FRR_FAILURE_OK`), D72's accepted
  cost. It runs the `k3s-join` cluster, then on the spine `alpha`:
  - bgpd gets SIGKILL; watchfrr restarts it; every BGP session (fabric
    and Cilium) is Established again; the leaf's BGP routes to the
    spine's pod /24 and /64 come back; pod pings recover in both
    families (`FRR_BGPD_CRASH_OK`);
  - a switch to a configuration with a line FRR rejects: the reload
    refuses it, but the switch still exits 0 (an upstream fact: the
    refusal shows only in the journal). FRR stays active, the bgpd PID
    is unchanged, the running config has no bad line, sessions and pods
    are fine; switching back leaves `frr-reload` nothing to change
    (`FRR_BAD_RELOAD_OK`).
  - **Finding, closed by a build-time check (owner decision):** a
    broken FRR config deploys green at runtime. Every `routed-fabric`
    machine now parses its rendered `/etc/frr/frr.conf` with
    `vtysh --dryrun` in `system.checks` (`lib/frr-check.nix`, option
    `clanServices.frr.checkConfig`, default on), so a line FRR rejects
    fails the system build before a switch. It checks syntax only:
    unknown neighbor, route-map or prefix-list names still pass.
    `checks.frr-conf` proves the renderer's output passes against the
    pinned FRR and a rejected line fails; nix-unit pins the wiring
    (`test_frrConfigCheckedAtBuild`). The suite's `bad-frr`
    specialisation turns the check off to reach the runtime path.
  - The suite also proves the crash is an outage (the leaf's
    `connectionsDropped` rises) and that Cilium's `::1` session is
    among the sessions checked.
- **Ported:** `<distro>-clustermesh-tunnel` →
  `<distro>-clustermesh-nodeport` (`<DISTRO>_CLUSTERMESH_NODEPORT_OK`,
  body `lib/kube-cluster/tests/vm/clustermesh-nodeport.nix`). It sets
  `mesh.exposure = "node-port"` explicitly (`auto` picks the internal
  LB on the fabric) and keeps the whole contract: NodePort 32379, ETP
  Local, two replicas one per voter, mTLS on every node's NodePort,
  peering on both sides, a cross-cluster pod ping, a global Service.
- D69 stays VM-proven on native routing by `<distro>-clat`
  (`CLAT_NODEPORT_OK`) and by `<distro>-data-plane`, whose firewall
  phase was ported from the tunnel suite: the underlay refuses the
  kubelet, the API, etcd, the API LB port and the NodePort from the
  other node and from outside; the same ports answer over the fabric.
  Its Kubernetes phases were ported too: pod to pod across nodes in both
  families with a 200 KB body (the pod MTU equals Cilium's and fits the
  fabric link), a slice of the pod pool per node, ClusterIP from pods
  with backends on both nodes and DNS by name, Node IPAM publishing
  every node of a Service with a backend on each; and when beta is
  gone: Node NotReady, EndpointSlice withdrawal, ClusterIP served only
  by alpha, Node IPAM dropping beta, a new pod using the Service.
- Cilium helm overrides of `ipv4NativeRoutingCIDR` or
  `ipv6NativeRoutingCIDR` now fail eval (D49/D72): pod CIDR containment
  is asserted against those constants.
- 45 suites in all. No VM run is claimed in this entry.

**Round 52 (2026-11-23): owner decisions; docs only.** The owner
answered the open points of round 51 and decided on tunnel mode.
- **Locked** (`specs/gateway.md` §14): build the services, no more
  probes; freeze the design-only decisions; the CLAT is the default
  path and DNS64 is frozen (not built until a client cannot run a
  CLAT); a rate limit per client at the gateway,
  with a `trusted` tier for kube nodes; the kube services render
  Cilium's `devices`.
- **D71, new, planned:** `devices` rendered per node from netif facts,
  never a VPN link. Amends D58.
- **D72, new, planned:** native routing only. Cilium tunnel mode and
  `wireguard-mesh` are removed; the last commit with them is tagged
  `tunnel-mode-final`.
- Directions for the unfixed findings (the `clat0` blip, health
  targets, dual-WAN stability, the hairpin of G20):
  `specs/gateway.md` §14.3.
- Header range D1–D72. No code changed.

**Round 51 (2026-11-21): devil's advocate review** (`specs/gateway.md`
round G4, §13). Points that touch this file:
- **D69, new, implemented:** NodePorts answer on the node addresses
  only (`nodeport-addresses`). Closes "NodePorts bypass the node
  firewall" of round 50.
- **D70, new, implemented:** the clan CoreDNS replicas never share a
  node when the cluster has two or more members. Closes "CoreDNS
  replicas share one node" of round 50.
- `clan.networkFacts.clusters` is written by k3s and rke2 (eval
  `test_clusterRangesFact`). Closes the third finding of round 50.
- The `ha` body is stricter: the server crashes, the scheduler places
  the pod, the API answers on both survivors, cluster DNS answers, and
  the dead server returns as a Ready node that serves the API.
  `<distro>-ha` and `<distro>-ha-fabric` run it.
- D67's status line now says what is proven and what a service must
  still render (the CLAT and its `devices` entry).
- **Found, needs a decision here:** on an IPv6-only node the underlay
  NIC must be in Cilium's `devices` in both modes, or pod IPv6 egress
  and external names in pods fail (`specs/gateway.md` G5, §13.2
  point 10). D58 derives `devices` from the transport only. The
  `<distro>-clat-<transport>` suites add the NIC by hand.
- Open for the owner: `specs/gateway.md` §13.2.

Round 50 (2026-11-21): **probes became suites; both Cilium modes have
the same suites (`specs/gateway.md` round G3, §5, §12.3). Points that
touch this file:
- D67 is suite-verified: `<distro>-v6only` and
  `<distro>-clat-<transport>` (k3s and rke2; `routed-fabric` with
  native routing and `wireguard-mesh` with the tunnel). Pod IPv4
  leaves through the node's CLAT, whose link is in Cilium's `devices`
  (`specs/gateway.md` G5, decided). The kube services do not render
  that yet: the suites set `cilium.helmValues.devices`.
- New suites for mode parity: `<distro>-data-plane-tunnel`,
  `<distro>-join-netif`, `k3s-modes-fabric`. No parity defect was found
  in service code.
- Three findings, open, each needs a decision here before code
  (`specs/gateway.md` §12.2):
  - CoreDNS replicas share one node after bootstrap (soft
    anti-affinity; the bundle applies before the second node is
    Ready). When that node dies, cluster DNS is gone.
  - Cilium serves NodePorts in eBPF before nftables on every link in
    `devices`; the underlay link is one. A machine outside the cluster
    reaches a NodePort on a node's underlay address.
  - `clan.networkFacts.clusters` is declared and nothing writes it.
- The assertion that refuses a BGP pool on a tunnel transport now
  names the transport.

Round 49 (2026-11-21): **both transports proven on IPv6-only NICs; the
HA contract on the routed fabric** (`specs/gateway.md` round G2, §10.11,
§12.3). Points that touch this file:
- D67 is probe-verified on both transports: `routed-fabric` with
  native routing and `wireguard-mesh` with the tunnel, k3s and rke2,
  two nodes whose NICs have no IPv4 (probes then; suites since round
  50). No code changed.
- New suites `k3s-ha-fabric` and `rke2-ha-fabric`
  (`K3S_HA_FABRIC_OK`, `RKE2_HA_FABRIC_OK`): the `ha` contract and its
  test script, on the routed fabric. alpha and beta are spines, gamma
  is a leaf; the manager that dies is a spine. Body:
  `lib/kube-cluster/tests/vm/ha-fabric.nix`.
- The coverage of each Cilium mode is the table in
  `specs/gateway.md` §12.3.

Round 48 (2026-11-20): **router and NAT gateway designed; docs only.**
The owner decided that the home router and a NAT gateway are
clanServices in this repo, with their own contract `specs/gateway.md`
(D68). Points that touch this file:
- Cloud clan machines get an IPv6-only underlay; clusters stay
  dual-stack inside, on fabric addresses (D67, planned, probe first).
- Pod IPv4 egress on such nodes is `specs/gateway.md` G5.
- Exposure has three classes (G12); the home router opens no inbound
  port by default. ECMP from the router to a cluster gateway stays
  available as class 3.
- A Service behind a router gets a public IPv6 address from the ISP's
  delegated prefix (G20). The pool model is D8, unchanged; the router
  is the edge and joins `routed-fabric`. D10's non-goals stand.
- Owned address space is announced by `routed-fabric` borders only
  (G21). The border was built for a private upstream router; what it
  lacks for a transit provider (a public AS number, aggregates only, a
  default or full table inbound, per-peer session options, RPKI) is
  listed in G21 and needs a decision here before code.
- Metrics endpoints of host services are scraped from a monitoring
  cluster over the fabric; Prometheus and Grafana are day-2 (G18).
Nothing is implemented in this round.
Round 47 (2026-11-18): **hot-plugged wired links**
(`specs/netif.md` round P2-hotplug, N12).
`clanServices.netif.hotplug.interfaces` names the prefixes of links
that come and go; in an IfState mode the `wired-hotplug` owner keeps
IfState away and a supervised DHCP client runs on each while it is
plugged in, with its defaults at metric 200. New suite `netif-hotplug`
(`NETIF_HOTPLUG_OK`), with a USB adapter hot-plugged by QEMU.

Round 46 (2026-11-18): **Wi-Fi in NetworkManager and IfState modes**
(`specs/netif.md` round P2-wifi, N5, N18). The `iwd` preset renders
iwd's settings for the mode. New suite `netif-wifi` (`NETIF_WIFI_OK`):
an unknown network joined in each mode, known networks shared between
modes, wired before Wi-Fi in both families, roaming. The last netif
probe is deleted.

Round 45 (2026-11-18): **mode scoping on routed-fabric,
wireguard-mesh, k3s and rke2** (`specs/netif.md` round P4b, N4). Each
has a per-machine `modes` setting; `lib/mode-scope.nix` keeps vars,
facts and checks in every mode and renders the rest only in the named
modes. Evaluation rejects a spine, a border or a server of a
multi-machine cluster that is limited to some modes, and any of these
services active in a NetworkManager mode. Suites: `netif-modes`
(`NETIF_MODES_FABRIC_OK`), new `k3s-modes` (`K3S_MODES_OK`). Machines
without modes render exactly as before.

Round 44 (2026-11-18): **a KDE desktop on netif, in a NetworkManager
and an IfState mode** (`specs/netif.md` round gate-4). New suite
`netif-desktop` (`NETIF_DESKTOP_OK`). netif's NetworkManager renderer
gives wired links it does not declare route metric 200. With rounds
42 and 43 the owner definition of a stable netif (N14) is VM-proven.

Round 43 (2026-11-18): **routed-fabric on a netif underlay**
(`specs/netif.md` round gate-3). The `routed-fabric` suite body takes
an `underlay` argument (`services/routed-fabric/tests/vm/suite.nix`);
the new suite `routed-fabric-netif` runs it with every machine's
underlay declared through netif and adds a reapply-changes-nothing
phase (`NETIF_UNDER_FRR_OK`, `ROUTED_FABRIC_NETIF_OK`). No service
code changed; the `routed-fabric` suite is unchanged (`suite-compare`).

Round 42 (2026-11-17): **netif under Kubernetes: first gate, three
fixes in this file's services** (`specs/netif.md` round gate-1).
- **New suite `k3s-data-plane-netif`:** the data-plane suite with the
  nodes' underlay declared through netif. It adds a phase that reapplies
  the network on both live nodes and asserts that nothing changes.
- **Pod namespaces are owned.** The `cilium` registry owner claims
  `^cni-`. Before, any IfState apply after the first pod started would
  have deleted every pod's network namespace. The cluster suites did
  not see it: IfState ran only at boot.
- **routed-fabric:** the IPv6 transfer address no longer carries
  `scope = "link"`; IfState re-added it on every apply because the
  kernel ignores an IPv6 scope.
- **Floating pools (D8) are owned.** k3s and rke2 register a floating
  pool's blocks as owned address ranges on its candidate machines, so
  the address a failover controller places survives a network reapply.
- k3s and rke2 import the ownership registry themselves.
- `rke2-data-plane-netif` (added the same day) passes the same suite
  on RKE2.

Round 41 (2026-11-17): **netif P4a: modes** (`specs/netif.md` round
P4a). Points that touch this file:
- The shared IfState base follows the machine's mode: IfState in an
  `ifstate` mode, NetworkManager otherwise. A machine with no modes
  entry has one IfState mode, so every cluster suite is unchanged
  (their test derivations are identical to before).
- k3s, rke2, routed-fabric and wireguard-mesh need an IfState mode.
  Until P4b gives them a `modes` setting, a machine that runs one of
  them cannot have a NetworkManager mode: evaluation rejects it.
- New public service: `modes`.

Round 40 (2026-11-17): **netif P8: lockout guard** (`specs/netif.md`
round P8). Nothing in this file's contract changes. A headless
cluster node with a netif link now rolls a network change back when
its gateway stops answering (N25).

Round 39 (2026-11-17): **netif P7b: VM hosts** (`specs/netif.md`
round P7b). Nothing in this file's contract changes. For KubeVirt
nodes later: a netif bridge marked `bridge.guestPorts` keeps the ports
a hypervisor adds, and a bridge over one NIC keeps that NIC's MAC.

Round 38 (2026-11-17): **netif P7a: containers** (`specs/netif.md`
round P7a). The ownership registry in the shared IfState base gains a
`containers` preset (Docker, rootful Podman). It is off unless one of
them is enabled; the k3s, rke2, routed-fabric and wireguard-mesh suite
derivations are unchanged.

Round 37 (2026-11-17): **netif tools** (`specs/netif.md` round tools).
Nothing in this file's contract changes. For operators of cluster
nodes: `netif-status`, `netif-preview` and the `netif-drift` timer
exist on every machine with a netif link.

Round 36 (2026-11-17): **netif P3b slice 5: path MTU, cloud NICs**
(`specs/netif.md` round P3b-5). Points that touch this file:
- Invariant 21 is closed for WireGuard: both transports size their
  tunnels from netif's `pathMtu`, then the link `mtu`.
- `wireguard-mesh`'s `mtu` option is nullable (null derives it).
- The `netif` export and `clan.networkFacts.netif` carry `pathMtu`
  per link and per instance.

Round 35 (2026-11-17): **netif P3b slice 4: untrusted links**
(`specs/netif.md` round P3b-4). Points that touch this file:
- A netif link is firewall-trusted only when declared so (N19). k3s,
  rke2, routed-fabric and wireguard-mesh already open their own ports;
  none relied on netif's trust.
- The `netif` export and `clan.networkFacts.netif` carry `zone` and
  `trusted` per link (N10).

Round 34 (2026-11-17): **netif P3b slice 3: default routes**
(`specs/netif.md` round P3b-3). Points that touch this file:
- The `netif` export and `clan.networkFacts.netif` carry
  `defaultRoute.{ipv4,ipv6}` per link: which link owns each family's
  main-table default. `gatewayInMain` stays.
- Every netif default route has metric 100 (N18); a machine with
  several netif links names the one that carries the IPv6 default
  (N21).

Round 33 (2026-11-17): **netif P3b slice 1: code** (`specs/netif.md`
round P3b-1). Points that touch this file:
- **The shared IfState base enables systemd-resolved** (N9). Every
  cluster suite runs on it. k3s and RKE2 hand the kubelet resolved's
  upstream file, not the stub.
- netif starts dhcpcd as a supervised unit per link and holds
  `network-online.target` until DHCP links have an address (N31,
  N32). A k3s or RKE2 node on a DHCP underlay now starts with its
  address.
- The owner's definition of "netif stable" names this file's subject:
  proven under Cilium Kubernetes and FRR, and under desktop
  specialisations (N14).
- `flake.lock` moves to the org-pkgs with `dhcpcd_latest`; every suite
  was rerun on it.

Round 32 (2026-11-17): **netif retrospective; dhcpcd moves to
upstream 10.5.2 in pkgs; docs only here** (`specs/netif.md` round
retro, §8.4, §11). Points that touch this file:
- org-pkgs `overlays.ifstate` gains `dhcpcd_latest`: the unpatched
  upstream dhcpcd 10.5.2 (owner decision), for netif's hook-started
  dhcpcd. It fixes the lost leases of round 31 and four CVEs.
  `pkgs.dhcpcd` stays the patched 10.3.2: 10.5 does not start under
  the stock NixOS `dhcpcd.service` until nixpkgs PR 562813 lands.
  This repo still runs `pkgs.dhcpcd`; the lock bump and the switch
  are the first step of netif phase P3b and run every suite.
- N30 is reworded: the upstream release first, a patch only when no
  release works; a package the stock NixOS modules share is never
  swapped under them without a test of that module.
- `network-online.target` is reached before a DHCP underlay has a
  lease (`specs/netif.md` §11 H2). A k3s or RKE2 node on a DHCP
  underlay can start without its address until that is settled.
- A "broken" probe finding needs a control run that shows the fixture
  works (`specs/netif.md` §7).

Round 31 (2026-11-16): **netif solo runs and research; docs only here,
one package patch in pkgs** (`specs/netif.md` round proof-solo, §8.3,
N30). Points that touch this file:
- The dhcpcd fault of round 30 is a dhcpcd 10.3.2 bug (upstream issue
  596). org-pkgs `overlays.ifstate` now builds dhcpcd with the two
  upstream commits. Cluster nodes on DHCP underlays get it with the
  next `org-pkgs` bump.
- Packages that need a patch are patched in pkgs, never in this repo
  (N30). That covers the Kubernetes artifacts' host dependencies too.
- A VM suite node that sends RAs must forward IPv6 (`specs/netif.md`
  §7); suites with a simulated router are checked for it in netif
  phase P3b.

Round 30 (2026-11-16): **netif proof round; docs only**
(`specs/netif.md` round proof, §8.2). Throwaway probes on euc-hel-0
tested the open netif assumptions. netif's delivery phases are renamed
`N0`–`N8` → `P0`–`P8`. Points that touch this file:
- The `cilium` preset's neighbours matter: IfState deletes any named
  network namespace no owner claims. Rootful Podman's `netns-<uuid>`
  needed its own ignore (N22); a new runtime on a cluster node needs
  the same check.
- dhcpcd 10.3.2 loses DHCPv4 or DHCPv6 after a carrier change (N16).
  Every DHCP underlay of a cluster node is affected until netif phase
  P3b fixes it.
- A virtio NIC cannot be matched through IfState `identify` by its
  parent device; netif will use a udev `.link` rename for `match.path`
  (N26). D61 is unchanged: `.link` files are udev's, not networkd's.

Round 29 (2026-11-16): **the netif contract is widened to the whole
fleet; docs only** (`specs/netif.md` round use-cases, decisions N20–N29,
use cases U1–U11). Points that touch this file:
- netif never renders NAT, tunnels, routing protocols or cluster
  networking (N20). A NAT gateway for other machines is a separate
  service, planned later.
- A `modes` clanService names each machine's modes; routed-fabric,
  wireguard-mesh, k3s and rke2 gate on it (N24).
- **Open design, owned by this file:** a roaming single-node cluster
  (kamrui-h1's `kubernetes` mode) uses its routed-fabric loopback as
  node address and runs ClusterMesh over the fabric (N27). Not designed
  yet.
- **Open design, owned by this file:** the home router's ECMP towards
  Kubernetes nodes on its LAN, and whether those BGP sessions run
  directly on the LAN or in tunnels (N10).
- The netif export is not version-bumped: version rules wait for a real
  consumer (N14). This replaces round 28's `schemaVersion` 2 note.

Round 28 (2026-11-16): **the netif contract is refined before phase P3b;
docs only** (`specs/netif.md` round P3b-spec, decisions N16–N19). Points
that touch this file:
- netif links become firewall-untrusted by default (N19). routed-fabric,
  wireguard-mesh, k3s and rke2 open their own ports and never rely on
  netif trust.
- `pathMtu` (N17) is the underlay MTU routed-fabric and wireguard-mesh
  prefer; it closes invariant 21's gap in P3b.
- The netif export moves to `schemaVersion` 2 (zones, `pathMtu`,
  prefix delegation as a runtime fact).

Round 27 (2026-11-15): **netif phase P3a is implemented** (`specs/netif.md`
N15): `match.mac`, a missing NIC fails `ifstate.service`, and the checked
`extraSettings` passthrough. Suite `netif-match`.

Round 26 (2026-11-15): **netif phase P1 is implemented** (`specs/netif.md`
round P1). The Cilium and VM ignores that D61 hard-coded in the shared
IfState base are now presets of the ownership registry (`lib/ownership.nix`);
the Cilium preset is on wherever k3s or RKE2 runs. Suite `netif-registry`.

Round 25 (2026-11-15): **host networking has its own contract,
`specs/netif.md` (decisions N1–N14); docs only.** It is the status authority
for netif, the shared IfState base and the ownership registry, and it
supersedes D50, D53 and D61 where they conflict. In short:
- each mode (a NixOS specialisation, switched by reboot) has one manager,
  IfState or NetworkManager;
- iwd owns Wi-Fi in every mode;
- an ownership registry keeps IfState away from Tailscale, iwd, Cilium and
  VM taps;
- each mode provides `network-online.target` for session daemons.

The model was probe-verified on euc-hel-0 before it was written down. netif
stability work (phases P1–P6) comes before further cluster work. The
data-plane hardening plan's phase 4 is folded into netif phase P3.

Round 24 (2026-11-11): **the repo follows the external-systems org standard
(D66); no service behavior change.** The artifact flake is the input
`org-pkgs` (never `pkgs`), and `nixpkgs`, `flake-parts` and `import-tree`
follow it. `org-pkgs` `flakeModules.default` provides treefmt (every nixf
rule), the docs site and deck, the lock-sync check and the VM-test runner,
so the `dev` partition, `formatter.nix`, the `presenting` docs builder, the
local VM adapter and the local `vm-test` app are gone. Root modules live in
`flake-parts/` (import-tree). The dev shell is devenv. CI is the org
`ci.yml`. VM suites are registered in `clanTests` and run through the org
`vm-test` on euc-hel-0: one suite per sandboxed build, and `vm-test --all`
runs suites side by side within the `vmTests.parallel` budget, rerunning a
suite that failed under load alone (`PASS(!)`). A run passes on a zero exit
status, and logs go to `.vm-tests/<suite>/`. Test scripts group steps in
`subtest` phases; `*_OK` markers stay as progress lines that the runner no
longer reads. k3s and RKE2 suites testing one contract share one body in
`lib/kube-cluster/tests/vm/`.

Round 22 (2026-10-30): **allocate fabric and mesh values once with clan vars
(D64).** Public, non-deployed generators allocate routed-fabric loopbacks,
node ASNs, adjacency ports and transfer prefixes, and wireguard-mesh node
addresses. Evaluation reads the committed values instead of recomputing them
from machine or instance names. Explicit per-machine and per-adjacency pins
remain collision escapes. Fleet/host collision and pool-disjointness checks
name the targeted regeneration or settings fix; interface names, FRR symbols,
link-local addresses, and cluster-level derived identities remain hash-derived
by design.

Round 21 (2026-10-29): **data-plane correctness and stable convergence
(D63).** BGP/BFD exposure is limited to fabric WireGuard interfaces and
source-restricted declared upstream peers; every IfState WireGuard listen
port is reserved against ephemeral-port reuse. Eval rejects source-return
and netif policy collisions, incompatible literal endpoint families,
unreachable mesh pairs, overlapping mesh AllowedIPs, cross-transport listen
ports, and overlay deploy targets. Forwarding nodes accept RAs with
`accept_ra = 2`. Fabric adjacencies use symmetric `site`/`wan` timer
profiles, a bilateral five-second FRR DelayOpen hold-down, and automatic
maximum-prefix restart. Hostname address families remain a warning because
hermetic eval never performs DNS resolution. Positive and negative nix-unit
coverage and the full static `nix flake check --show-trace` pass. Fresh VM
runs pass `netif` (`NETIF_IFSTATE_LIVE_OK`), `netif-dhcp`
(`NETIF_DHCP_RA_IFSTATE_OK`), `routed-fabric`
(`ROUTED_FABRIC_TRANSPORT_OK`, `ROUTED_FABRIC_SPINE_HA_OK`), and
`k3s-data-plane` (`K3S_DATA_PLANE_OK`). The routed-fabric suite also proves
source-return selection before `main`, negative underlay exposure, an empty
reload diff, preserved peer uptimes, and an immediately identical RIB.

Round 20 (2026-10-29): **status corrections and tooling-only phase 1; no
service behavior change.** A review found routed-fabric and netif claims that
the code or VM suites do not yet meet. Those claims stay in the target
contract and are now marked *(planned)* where they appear; the work to close
them is phased in `documentation/docs/plans/data-plane-hardening.md`, with
one hand-off prompt per phase under `documentation/docs/plans/phase-*/`. From
this round, a *VM-proven* status names its test file and a unique `*_OK`
marker the test prints; VM logs live in
`.baton-pass/vm-logs/<suite>/logs-<n>` (never committed). Verification is a
full `nix flake check` (`checks` is static-only), formatting is alejandra,
breaking changes need no shims, and `targetHost` stays on the underlay
(AGENTS.md rules 2 and 9–11).

Phase 1 is implemented on PR #2 (pending merge). It uses alejandra, statix,
deadnix, and nixf-diagnose through treefmt-nix. The nixf-diagnose gate is
limited to `sema-primop-removed-prefix`, rejecting redundant `builtins.`
prefixes when the prelude builtin is unshadowed. Development inputs and the
checks, formatter,
documentation, slides, and development shell outputs live in a flake-parts
`dev` partition so consumers do not lock `nix-unit` or `presenting`. The root
flake has no test-only follows or nix-unit wrapper: the check evaluates the
root `tests.systems` output directly with offline input overrides. Direct
evaluation exposed two malformed fleet-check diagnostic renderers; their
message formatting is corrected without changing any assertion, and eval tests
cover both collision messages. `apps.<system>.vm-test` builds one suite from
`legacyPackages.<system>.vmTests`, atomically allocates the next numbered
build log under `.baton-pass/vm-logs/<suite>/`, fails on log-creation errors,
records cached output paths, and uses a plain build for `--rebuild` when no
cached output exists; VM suites remain outside `checks`.

Round 19 (2026-10-28): **the artifact flake is the packaging and shared-input
authority (D62).** `external-systems/pkgs` pins nixpkgs and flake-parts, owns
the IfState/Kubernetes overlays and per-system airgap artifacts, and remains a
replaceable transitive input. `clanServices` follows those shared inputs,
re-exports the overlays, and consumes published manifests and images instead
of rebuilding them. VM suites now live only under
`legacyPackages.<system>.vmTests`; `checks` is static-only.

Round 18 (2026-10-27): **IfState 2.5.1 is the exclusive static networking
renderer (D61).** `netif`, `routed-fabric`, and `wireguard-mesh` render
`networking.ifstate.settings`; systemd-networkd, netdevs, scripted network
units, and `networking.interfaces` ownership are removed without shims.
The shared per-machine base applies `inputs.pkgs.overlays.ifstate`,
disables competing managers, ignores Cilium-owned interfaces/table 200,
and preserves hook daemons with `KillMode=process`. Inventory remains the
source of truth for links, addresses, WireGuard peers, static/policy routes,
rules, and sysctls; `ifstate.service` reconciles changes live without
reboot. DHCPv4/DHCPv6 uses per-link hooks, IPv6 SLAAC uses kernel RA, and
WireGuard private keys remain runtime includes from clan vars. FRR/Zebra
owns dynamic routes; Cilium owns its datapath. The complete netif,
routed-fabric, k3s, and RKE2 native/tunnel/selective/external VM matrix is
green on this tree. Round 17's generic transport, leaf/spine fabric, and
ClusterMesh contracts are implemented; historical target wording below is
updated to that status.

Revised 2026-10-24 (round 16, after `1291c21`): **composable fabric
roles and dependency-free network diagrams.** `routed-fabric` now has two
mutually exclusive topology roles, `member` and `hub`; per-machine
`access = member | client | admin` controls route consumption, and
optional `border` configuration owns external/upstream transit. These
three axes are orthogonal: borders need not be hubs, hubs need not be
borders, and access no longer consumes a topology role (D56). Fabric
hubs, borders, default gateways, DHCP, NAT, and Kubernetes Gateway API
remain distinct concepts. Two hubs are the HA profile, not a maximum;
stateful NAT failover is not implied by routed ECMP. A versioned,
non-secret, read-only (`readOnly = true`) `clan.networkFacts` NixOS interface is
the neutral seam from which a consumer-owned nix-topology wrapper can
render buildable diagrams without adding a nix-topology dependency to
clanServices (D57). The facts cover all build-time-declared networking;
dynamic runtime state is labeled, never invented. New decisions D56–D57;
revised: D8, D9, D11, D13, D33, D44, D51, D52. Docs-only under A4 — no
implementation or VM evidence is claimed; the retained baseline stays
5 green / 7 red VM suites.

Amended 2026-10-25 (round 16, member DNS deferral): **no member-facing
cluster DNS in the MVP.** `access` governs ROUTES only — `client` adds
VIP routes, `admin` adds pod/ClusterIP routes; the fabric and the
bootstrap bundle render NO CoreDNS zones for members (no instance-zone,
svc, or pod zones, to any access level). Admin machines still reach
pod/Service IPs over those routes and resolve their names day-2 through
Kubernetes-side automation such as external-dns. In-cluster DNS is
unchanged: the clan-rendered CoreDNS still serves `cluster.local` inside
every cluster (D46). Revised: D13, D22, D33; §3.1–§3.3, §5 invariant
10, §6.8, §6.13, §7, §8, §9, §10.

Round 17 (2026-10-25, retained): **docs-only contract lock — generic
node transport, spine/leaf fabric, ClusterMesh placement/exposure.**
Under A4 this round lands without code changes; no implementation or
new VM evidence is claimed. **D58** defines a generic, shared, neutral
`node_transport` schemaVersion 2, declared OUTSIDE `lib/kube-cluster`:
stable dual-stack node addresses per instance/endpoint; every datapath
interface keyed by its Linux interface name, each with its MTU; exactly
one `directRoutingDevice` naming one of the exported interfaces;
`datapath.mode = native | tunnel` plus the tunnel protocol; for native
mode `routeExchange = local-router` — daemon-neutral, never
`local-frr`/`local-bgp`; and the independent exposure capabilities
`internalLoadBalancer` and `nodePort`. The schema is open — other
route-exchange or tunnel modes are representable — but strict validated
profiles are the initial surface: unsupported profiles are eval-rejected
until implemented and tested. From 5R5, k3s/rke2 consume ONLY
`node_transport`
and never branch on provider service names. **D59** renames the fabric
topology roles `member`/`hub` → `leaf`/`spine` (`access =
member|client|admin` stays — membership, not topology); the adjacency
graph is derived symmetrically — every unordered spine pair is adjacent
automatically, every leaf attaches every spine by default (an explicit
spine subset is allowed), and mutual hub lists are gone; spine-only full
peering is NOT a full fabric mesh (there are no leaf-leaf edges).
`routed_fabric` and `networkFacts` moved to schemaVersion 2, and
`kube_cluster` moved from schemaVersion 3 to 4 in 5R5 with revised
datapath/exposure facts and no shims.
**D60**
locks ClusterMesh placement and exposure: mesh groups require identical
datapath mode, tunnel protocol, and maxConnectedClusters; apiserver
exposure is `auto | internal-load-balancer | node-port |
external-load-balancer` with pinned-VIP internal for the
clustermesh-apiserver ONLY (host offset 79 / 0x79
in the D10 pool, explicit `lbipam.cilium.io/ips` projection; mirror
Services get a separate, future allocation — no offset-79 sharing),
no-replica NodePort (default 32379, optional explicit override), and
external class+DNS semantics; normalized `mesh.*` settings carry the
contract. Member-facing private DNS is wholly day-2 — the MVP renders no
member zones, no private DNS service, and no private CoreDNS VIP (D22
revised again). `wireguard-mesh` is now a SUPPORTED
tunnel transport (Cilium tunnel/VXLAN + nodePort), not pending
retirement. Native-mode Cilium MTU = the minimum interface MTU; VXLAN =
minimum minus 50. There are no external consumers or deployments of
these schemas, so the breaking renames ship without migration shims. New
decisions D58–D60; revised: D9, D11, D12, D33, D44, D47, D49, D51, D52,
D54, D56, D57.

Amended 2026-10-26 (round 17 correction, retained): **ClusterMesh
control-plane exposure is IPv4-only.** The pinned Cilium v1.20.3 chart
proves the round-17 dual-stack control-plane VIP assumption false: the
clustermesh-apiserver Deployment embeds etcd with
`--listen-client-urls=https://0.0.0.0:2379` (IPv4 wildcard;
`--advertise-client-urls=https://localhost:2379`) and the template has
no dual-stack listener knob, so an IPv6 control-plane VIP would be
undialable. D60/D10 internal exposure therefore pins ONE IPv4 VIP at
host offset 79 / 0x79 — `172.16.<id>.79` — with no ClusterMesh IPv6 VIP
and no `RequireDualStack` advertisement; NodePort publishes every
selected node's stable IPv4 address; external exposure uses DNS (a
runtime A record); certificate SANs carry published IPv4/DNS endpoints
only, never unreachable IPv6. The ClusterMesh DATA plane remains
dual-stack (§3.2, §5 invariant 2); no unrelated dual-stack data-plane
or BGP requirement changes. Revised: D10, D30, D44, D60; §3.2, §6.5,
§7, §10, §11.

Round 15 (2026-10-24, retained): **routed-hub MVP, routed-fabric,
multi-instance netif, selective ClusterMesh, nftables-only.** The
supported fabric topology became routed hub/spoke only: one WireGuard
interface per declared adjacency, full mesh dropped from the supported
and tested surface (D51); `fleet-routing` was renamed `routed-fabric`;
`netif` became multi-link and multi-instance with cross-instance
assertions (D53); ClusterMesh defaulted to full peering within one fabric
with explicit symmetric selective peers (D54); AllowedIPs/MTU/source-return
transport blockers, nftables-only firewall with kube-proxy off and
`install-iptables-rules=true`, fabric-scoped Node IPAM, netif bridge
plumbing for KubeVirt attachment, and the dual-AF local Cilium↔FRR
session were closed contractually (D51/D55). New decisions D51–D55;
revised: D8, D9, D11, D13, D33, D41, D43, D44, D47, D50. Round 16
supersedes its four-role and inferred-hub-membership model.

Round 14 (2026-10-24, retained): **FRR, routed WireGuard, and native
Cilium.** The data plane moved to point-to-point host WireGuard, one FRR
routing stack per host with Zebra-owned kernel routes, and Cilium native
routing with multi-pool IPAM. BIRD, VXLAN, and the
ordinary-mesh-plus-auxiliary-routed-interface model are superseded. New
decisions D47–D50; revised: D8, D9, D11, D13, D19, D33, D41, D44. This
round landed docs-only under A4; the BIRD implementation at checkpoint
`2995ac3` is legacy and is not round-14 acceptance evidence. Its
retained baseline is 5 green / 7 red VM suites. The per-remote-machine
interface model and the `fleet-routing` name were revised again in round
15 (D51/D52).

Round 13 (2026-10-22, retained): **data-plane-only scope reduction.** The
contract has exactly two verifiable promises — the Bootstrap contract and
the Data-plane contract (D39). Everything else that was spec'd as
clan-rendered in-cluster software is revoked and becomes documented day-2
GitOps patterns. Round history is retained in §4 with per-decision status.

Round-8 amendments (2026-10-20, retained): **A1** artifact flake packages
the last 3 k8s minors per distro (→ D34). **A2/A3** application-plane
credentials are never clan vars (→ D35, narrowed further in round 13).
**A4** spec locks land without code changes in the same commit — rounds
13, 14, 15, and 16 land docs-only; code changes are scheduled in §8.

## 1. Problem (condensed)

Declare machines, their core host networking, and cluster instances in
`inventory.nix`; receive working, secure, interconnected Kubernetes
clusters (rke2, k3s, upstream kubeadm — D23 Reserved) whose **bootstrap
and data plane are a verifiable contract**. Hard interacting requirements:
multi-cluster identity/CIDR coherence; mandatory dual-stack regardless of
underlay; encrypted flat-L3 reachability across Internet and NAT
boundaries; bare-metal LoadBalancing = allocation + delivery + datapath
(three different things); address families asymmetric in the real world;
artifacts and services have different release cycles; misconfiguration
must fail at eval where possible, VM-proven where not. **Explicitly not
the problem**: which ingress/Gateway/proxy, certificate, storage,
virtualization, or GitOps software runs in the cluster — that is day-2,
owned by GitOps repositories, never by NixOS host configuration. Applying
manifests via `clan machines update` (host churn for in-cluster state) is
the anti-goal this revision removes.

## 2. Architecture in one paragraph

Thin public `rke2` + `k3s` clanServices (upstream `kubernetes`/kubeadm
spec'd, Reserved) sit over a private shared library (`lib/kube-cluster/`,
D45). `netif` owns inventory-declared links — multi-link, multi-instance:
physical, VLAN, bond, bridge; static/DHCP/RA addressing, gateways, MTU,
DNS, underlay routes and underlay policy routing (D53) — plus
deploy-target exports. All three networking services render their static
configuration exclusively through IfState 2.5.1 (D61), which reconciles
live without reboot; no systemd-networkd, netdev, or scripted network
renderer remains. `routed-fabric` owns the flat-L3 fabric: a derived
symmetric spine/leaf graph with one WireGuard interface per adjacency
(leaf↔spine attachments, automatic spine↔spine pairs), per-node FRR/bfdd,
and Zebra-installed routes (D51/D59). Cilium = CNI
+ KPR + **native routing only** (D72; tunnel mode and `wireguard-mesh`
were removed, last kept at tag `tunnel-mode-final`) + multi-pool pod
IPAM + Node IPAM for classless
LoadBalancer Services + LB-IPAM pools + BGP v2 + ClusterMesh — networking
only (D1); kube-proxy is off and Cilium's required datapath rules use
iptables-nft (D55). Every transport publishes the generic, neutral
`node_transport` schemaVersion 2 (D58) and k3s/rke2 consume only that
schema and never branch on provider service names.
Local Cilium agents advertise pod pools and Service VIPs only to their
node-local FRR over one dual-AF session; FRR exchanges filtered routes
across the encrypted fabric — spines forward and readvertise with
next-hop-self, leaves never provide transit — and programs the kernel.
`routed-fabric` has two topology roles: non-transit `leaf` and
forwarding/readvertising `spine`. Per-machine `access` selects member,
VIP, or admin route consumption (membership, not topology; member DNS
is day-2, D22 amended); optional
`border` configuration selects external/upstream transit. Topology, access,
and border are orthogonal (D56). HAProxy on every node gives HA kubeapi access and the join URL. The entire day-1 in-cluster surface is ONE
kubenix-rendered bootstrap bundle, applied once via server-side apply on
the `clusterInit` node (D40) — no Rancher helm-controller, no host-resident
manifest dirs. Clusters run standalone, or as hub/spoke control domains
(D43): clan mints the kubeconfigs, RBAC, and API mirror Services that let
any GitOps tool manage spokes from a hub, but installs no GitOps controller
itself. Day 2 = GitOps takes over: Cilium ownership transfers by adopting
the identical published manifest set, and all other cluster software is
installed and owned by GitOps repos. Artifact flake
(`external-systems/pkgs`) owns shared inputs, overlays, distro runtimes,
committed manifests, per-system airgap images, and test fixtures (D62);
airgap-ready is the tested default. Every networking service also publishes its resolved
build-time facts through dependency-free `clan.networkFacts` NixOS
options; a consumer-owned nix-topology wrapper translates those facts to
buildable diagrams without becoming a clanServices dependency (D57).

## 3. The two contracts (D39)

### 3.1 Bootstrap contract — "the cluster exists and is reachable"

- Distro install/join for rke2, k3s, and (Reserved) kubeadm `kubernetes`;
  mixed distros in one fleet; one cluster per node (D16); RKE2's CIS
  profile is opt-in today, CIS by default is planned (D25).
- Cluster PKI: CAs, join tokens, admin kubeconfig, read-only
  (no-secrets) kubeconfig (D38); cert generation at bootstrap plus
  documented rotation runbooks and scripts (§6.9/§6.10).
- HAProxy on every node (post-bootstrap) load-balancing that cluster's API
  endpoints rendered from exports; join URL and agent kubeconfigs point at
  it (§6.6).
- The bootstrap bundle: one kubenix-rendered manifest set per cluster
  (Cilium, clan CoreDNS (D46), pools, ClusterMesh config,
  mirror Services, RBAC), applied once by a oneshot on the
  `clusterInit` node via
  `kubectl apply --server-side --field-manager=clan-bootstrap`; nothing
  written to the distro's watched manifests dir; `bootstrap.apply = false`
  is the day-2 off-ramp (D40).
- Control domain (`controlDomain.role = standalone | hub | spoke`, D43):
  API mirror Services (D30; mandatory for spokes), `gitops-hub`
  client-cert identities + in-spoke RBAC + hub-side `gitops-spoke-<spoke>`
  kubeconfig Secrets (D37 revised), read-only credential (D38). **Clan
  never installs a GitOps controller.**
- External CCM knob (`cloudController = none | rancher | external`,
  §6.11): day-1 boot config (kubelet args, uninitialized-taint flow). The
  CCM itself deploys day-2.
- `distroDefaults.enable` (D42): `false` (default) = uniform minimal base
  across all three distros; `true` on rke2/k3s restores stock distro
  behavior (helm-controller, Traefik, optional Multus) via the distro's
  own machinery. servicelb is permanently disabled (Node IPAM replaces
  it, D41/D42).

### 3.2 Data-plane contract — "packets flow correctly"

- Cilium only: one canonical upstream 1.20+ profile — KPR, **native
  routing only** (D72), multi-pool pod IPAM with derived non-clashing
  dual-stack CIDRs, BPF masquerade+tproxy, Maglev, pmtu, kube-proxy off,
  `install-iptables-rules=true` (nftables-only, D55). Native mode:
  `auto-direct-node-routes` is false and FRR/Zebra owns remote pod-pool
  routes through the daemon-neutral `local-router` exchange (D58).
  `ipam.mode: kubernetes` remains an explicit override. Admin
  helm-values overrides pass post-merge invariant validation and cannot
  set tunnel mode (D72) or contradict the transport-derived devices,
  `directRoutingDevice`, MTU, or exposure (§6.4).
- **Node IPAM on by default** (`nodeIPAM.enabled=true`,
  `defaultLBServiceIPAM=nodeipam`, D41): classless `type: LoadBalancer`
  Services get node IPs, ServiceLB-style; ETP-Local-aware candidate
  selection. Every explicit pool VIP draw pins
  `io.cilium/bgp-control-plane` to bypass that default and select LB IPAM;
  the class alone does not advertise. BGP advertisements select only
  `node-bgp` and `shared-bgp` pools. `bgpControlPlane.enabled=true` keeps
  the class registered even when `bgp.enable=false` renders no BGP
  resources.
- LB-IPAM pool model with five delivery modes (D8 revised round 15:
  `node-bgp` only where BGP delivery actually exists), BGP v2 +
  per-node FRR/Zebra (D9/D19/D48), default private fleet fabric (D10),
  node-owned BGP pools and shared ECMP pools, plus floating pools via
  runtime controllers.
- ClusterMesh automatic per mesh group (default = fabric instance,
  D54), mixed-distro, uniform per group (§6.5, D60). Full
  peering is the default; explicit symmetric selective peers are
  supported and peering bounds automatic cross-cluster route policy.
  Native groups need mesh-wide native-routing CIDRs covering every pod
  CIDR of every peered cluster and cross-cluster pod routes before
  readiness. The mesh DATA plane
  stays dual-stack; apiserver control-plane exposure is IPv4-only on the
  validated Cilium 1.20.3 profile (D60).
- Routed spine/leaf host WireGuard fabric: exactly one point-to-point
  interface per adjacency — leaf↔spine attachments plus automatic
  spine↔spine pairs — never one per remote machine (§6.3, D51/D59).
  eBGP per adjacency with unique node ASNs;
  FRR-BFD monitors every fabric path; spines readvertise with
  next-hop-self, leaves never provide transit. One link contract per
  adjacency (D73: `sources`, `destinations`) feeds WireGuard `AllowedIPs`
  — outbound cryptokey selection AND inbound source ACL — the BGP filters
  and the nft guard table; external-transit adjacencies may
  carry 0.0.0.0/0 + ::/0 crypto ACL without an IP default route. D63 scopes
  BGP/BFD exposure, reserves listen ports, validates endpoint/policy
  coherence, and uses stable `site`/`wan` timers with DelayOpen and a
  fabric route limit that warns (round G11). A spine↔spine session carries
  the union of what every member consumes or originates, the same on both
  ends, so leaves on different dedicated spines reach each other (round
  G11, R1).
- Access-scoped route consumption (D13): Kubernetes machines always
  install remote pod-pool blocks and advertised-VIP routes (native-
  routing requirement, D49); non-Kubernetes `access = "client"` machines
  receive fabric-pool LoadBalancer-VIP routes only; `access = "admin"`
  machines additionally receive pod-pool and ClusterIP routes.
  Member-facing DNS is NOT part of the MVP
  data plane: no CoreDNS zones are served to fabric members; admin
  machines reach pod/Service IPs by address and resolve cluster names
  day-2 via Kubernetes-side automation such as external-dns (D22 amended
  2026-10-25).
- **netif** (multi-link, multi-instance) for inventory-owned
  links/routes (D50/D53) and **routed-fabric** (`leaf`/`spine` topology
  roles plus orthogonal `access` and `border`, D56/D59) for the flat L3
  fabric. `routed-fabric` is the only transport (D72): `wireguard-mesh`
  and Cilium tunnel mode were removed.
- No Gateway, no Ingress, no proxy implementation in the contract. The
  data-plane proof uses native pod round trips, plain `type: LoadBalancer`
  Services, and firewall positive/negative assertions (§7).

### 3.3 Day-2 GitOps — documented patterns, never clan-rendered

GitOps-controller install (Flux or Argo) and takeover of the Cilium
bundle (adopt the identical published set; Kustomization+prune or Argo
tracking — first reconcile is a no-op by construction, D40), Envoy
Gateway (incl. the Node IPAM + ETP Local + `loadBalancerClass` recipe),
cert-manager, external-dns (member-facing cluster DNS lands here per the
D22 amendment), custom in-cluster DNS via the GitOps-managed
`coredns-custom` ConfigMap (imported by the clan CoreDNS, D46 amended),
Sealed Secrets (incl. sealing-key custody),
OpenEBS, KubeVirt, Multus, provider CCMs, hcloud-ip-floater-style
floating-IP movers. These live in `documentation/` as recipes and are
pinned/consumed by the operator's GitOps repos — not by this repo, not by
the artifact flake (D44/pkgs narrowing).

## 4. Decision record (D1–D76)

Statuses: **active** | **REVISED** (round noted) | **REVOKED** (round 13
unless noted) — revoked entries keep one-line reasons for history.

### Active decisions (rounds 1–12, with round-14/15/16/17 revisions)

- **D1 Cilium is networking-only.** (REVISED round 13: reaffirmed, and now
  the ONLY in-cluster Cilium surface.) `gatewayAPI.enabled=false`,
  `ingressController.enabled=false` permanently. Reasons: no Gateway
  HTTP/3 (cilium#28497), no Gateway mTLS (GEP-91), no DaemonSet mode, no
  multi-Gateway IP sharing (cilium#25567). Round-13 consequence: the
  Cilium dummy-Endpoints Node-IPAM limitation never applies here (D41).
- **D8 Pool model: 2 scopes × 5 delivery modes.** (REVISED round 14;
  narrowed round 15; round 16: border-owned prefixes.) Pool = address inventory + `serviceSelector`.
  Scope: *per-machine* → node-named pools with exactly one owner;
  *cluster-global* → generic pools. Delivery: `node-fate-bound`
  (provider/static route, no BGP) | `node-bgp` (only where BGP delivery
  actually exists; only the owner advertises exact /32+/128 VIPs; for
  node-owned IPv4 extras and routed IPv6-subnet carve-outs;
  provider-static node-bound extras remain node-fate-bound) | `floating`
  (runtime controller moves one address; blackhole window) |
  `shared-bgp` (every healthy eligible node advertises; upstream ECMP;
  ETP-Local withdrawal) | `external-class` (cloud CCM). REVISED
  2026-10-25 after the k3s runtime probe: every explicit pool draw pins
  `io.cilium/bgp-control-plane`; `io.cilium/lb-ipam` is not Cilium-handled.
  With Node IPAM as the unset-class default, an unset class cannot draw
  from a pool. The BGP class requests LB-IPAM allocation; advertisement
  remains selector-driven, so non-BGP pools stay unannounced. Assertions:
  non-overlap; scope⇒mode
  validity; `node-bgp` exactly one owner and never shared; `shared-bgp`
  only cluster-global; floating candidate coverage; BGP pool blocks ⊆
  `border.ownedPrefixes` when a border is declared. Classless Node-IPAM
  Services are fabric-scoped and public exposure uses explicit pools
  (D41/D55). One VIP is never advertised by two clusters.
- **D9 BGP topology + foreign-router contract.** (REVISED round 14;
  round 15; round 16: border configuration replaces the router role;
  round 17: leaf/spine naming + local-router exchange, D58/D59.) Every
  fabric node runs FRR/bgpd+bfdd+Zebra with a
  deterministic unique private 32-bit node ASN and a stable mesh IPv4
  router ID. eBGP runs per declared fabric adjacency (D51/D59) — one
  session per address family over each adjacency's WireGuard interface —
  with unique node ASNs, `next-hop-self` toward leaves, and no iBGP,
  route reflectors, or route servers. `bgp ebgp-requires-policy`,
  explicit AF activation, prefix-lists/route-maps, maximum-prefix,
  `maximum-paths`, `bgp bestpath as-path multipath-relax`, and fast
  convergence are mandatory. BFD monitors every fabric adjacency;
  Cilium uses hold 9 / keepalive 3 / connect-retry 5 because Cilium
  1.20 has no BFD. Each cluster has a separate deterministic
  Cilium-side ASN. Cilium dials only its node-local FRR at `::1` in one
  session carrying both address families (no `localPort`) — the
  daemon-neutral `local-router` route-exchange profile (D58); FRR is not
  passive, sets `allow-reserved-ranges` and `bgp allow-martian-nexthop`,
  and rewrites the loopback next hop to the node's stable transport
  address. Spines forward and readvertise with next-hop-self so every
  readvertised path has a directly resolvable next hop; leaves never
  provide transit. Zebra installs accepted remote routes. Cilium agents never
  peer with each other. Foreign routers consume the published
  ASN/CIDR/pool facts, accept only approved exact VIPs and opted-in
  prefixes, and peer through `border.upstreamPeers` (orthogonal to
  spine/leaf topology, D56/D59); cluster-side `bgp.upstreamPeers`
  duplication is removed. Shared VIPs ECMP across advertisers; `node-bgp` VIPs have one
  advertiser.
- **D10 Private fleet routing fabric DEFAULT ON; internal VIPs pinned at
  offset 79.** (REVISED round 17: no private CoreDNS VIP — member-facing
  DNS is wholly day-2, D22.) Per cluster by
  default: local Cilium↔FRR + BGP v2 resources and one private
  `shared-bgp` pool (ULA + RFC1918 from derived cluster CIDR space), with
  a pinned internal VIP for the clustermesh-apiserver (D60).
  Mirror-Service VIP allocation is SEPARATE and FUTURE — it must NOT
  share offset 79 (D30).
  Public `shared-bgp` and `node-bgp` are opt-in; preconditions are
  upstream-routed space plus a controlled router. Non-goals: single
  dynamic residential IPv4 public BGP; heterogeneous multi-WAN inbound
  failover (DNS failover instead). Hetzner public edge = node-bound,
  node-bgp, floating + DNS failover. The fabric pool remains
  `<instance>-fabric` with blocks `172.16.<ciliumId>.0/24` +
  `fd11:<ciliumId>::/64` (overridable; non-overlap and capacity asserted
  — the IPv4 block MUST contain host offset 79, i.e. hold at least 128
  addresses; the default /24 satisfies this, and the old offset-53/
  64-address rule is retired).
  The clustermesh-apiserver VIP is a pinned literal at host offset 79
  decimal
  / 0x79 — `172.16.<ciliumId>.79`, IPv4 ONLY (the pinned Cilium 1.20.3
  clustermesh-apiserver etcd listens on an IPv4 wildcard with no
  dual-stack listener knob, D60) — drawn by
  explicit `lbipam.cilium.io/ips` projection, asserted pool-contained and
  collision-checked against every other pinned clan VIP (D60). No CoreDNS
  VIP is pinned or rendered, and no ClusterMesh IPv6 VIP /
  `RequireDualStack` advertisement exists. `bgp.enable` ⇔
  "any node-bgp or shared-bgp pool exists" is eval-locked (§6.12).
- **D11 routed-fabric is the flat-L3 fabric.** (REVISED round 14:
  fleet-routing; round 15: renamed + routed-hub; round 16: composable
  roles; round 17: leaf/spine naming, D59.) The service (renamed from
  `fleet-routing`, D52) is one trust
  domain per instance; it owns per-adjacency WireGuard (leaf↔spine
  attachments, automatic spine↔spine pairs), FRR, BFD, Zebra route
  installation, topology/access/
  border policy, and fleet route consumption for Kubernetes and
  non-Kubernetes machines (member DNS is day-2, D22 amended). Derived
  spine/leaf is the only supported MVP
  topology (D51/D59); full mesh is deferred, and spine-only full peering
  is not a full fabric mesh (no leaf-leaf edges, D59). `wireguard-mesh`
  is a supported tunnel transport (D58); only its
  ordinary-mesh-plus-auxiliary-routed-interface extension is retired.
  Roles per D33/D56/D59.
- **D12 ClusterMesh apiserver exposure.** (REVISED round 17: exposure
  methods and placement per D60.) Exposure follows the D60 contract —
  `auto | internal-load-balancer | node-port | external-load-balancer` —
  with ETP Local on every method: mTLS identity does not depend on
  source IP, but Local preserves the source, avoids a second hop,
  supports ClientIP affinity, and enables internal-LB withdrawal. The
  same shape generalizes to the kube-apiserver mirror Services (D30)
  and their selectorless-Service DNS fan-in.
- **D13 Pod/ClusterIP consumption is access-scoped.** (REVISED round 14;
  round 15: roles; round 16: `access` setting; 2026-10-25: client/admin
  semantics sharpened; round 17: pod-route exchange is native-mode-only,
  D58.) On native transports Cilium advertises local multi-pool
  allocations to node-local FRR because native routing requires them;
  on tunnel transports pod traffic is encapsulated and no pod routes are
  exchanged. FRR distributes pod routes to all Kubernetes members in the trust
  domain, and every Kubernetes machine installs remote pod-pool blocks
  and advertised-VIP routes REGARDLESS of `access` — native routing
  delegates non-local pod traffic to the kernel FIB (D49), so this is a
  transport requirement, not a consumption choice; ClusterIP routes are
  never installed on Kubernetes nodes (kube-proxy replacement handles
  ClusterIP in eBPF locally). For non-Kubernetes hosts, `access =
  "client"` receives routes to shared-bgp fabric-pool VIPs only — exact
  /32+/128 advertisements for `type: LoadBalancer` Services that drew
  from an explicit pool (pool `serviceSelector` or explicit address
  projection) — never pod blocks, never ClusterIP CIDRs. `access =
  "admin"` consumes every explicitly advertised prefix: pod-pool
  allocation blocks (per-node allocations of every advertised
  `CiliumPodIPPool`), authorized ClusterIP CIDRs, and the pool VIPs.
  Pod-advertisement granularity is the pool's per-node allocation
  block; per-pod selection is not a Cilium BGP feature — bounding pod
  reachability is done by pool design or a deliberate FRR route-policy
  exception (D54). No access level receives cluster DNS in the MVP —
  member name resolution is day-2, delivered by Kubernetes-side
  automation such as external-dns (D22 amended 2026-10-25). `border`
  carries NO automatic admin DNS or pod/ClusterIP consumption; access
  remains an independent least-privilege choice (D56). There is no
  default direct pod/ClusterIP access for ordinary hosts.
- **D14 Raw L4 (games).** Plain `type: LoadBalancer` Services, never
  Gateways. Round-13 note: these are tenant/day-2 objects; the contract
  only guarantees the LB data plane they rely on (D41/D8).
- **D16 One cluster per node.** Inventory-wide eval assertion.
  routed-fabric membership may coexist with cluster membership (D33).
- **D19 One integrated FRR configuration per host.** (REVISED round 14.)
  `routed-fabric` atomically renders `services.frr.config` from inventory
  and exports; distro services publish facts and render Cilium resources,
  never a second routing stack or independent FRR text fragments. Zebra
  owns kernel installation. `bgpd` and `bfdd` are enabled from the first
  implementation. Configuration previews use `frr-reload.py --test`; a
  non-empty add/delete delta still exits zero, so convergence checks inspect
  the delta rather than only the exit status. The 2026-10-24 FRR 10.7.1
  probe proved that NixOS reload starts newly enabled daemons while bgpd
  keeps its PID; a full `frr` restart is not required for daemon-set changes.
  The legacy `clan.bird.fragments` renderer is removed after migration.
- **D21 The internal cluster domain is pinned to `cluster.local`.**
  Never changed, eval-asserted. Aliasing via CoreDNS rewrites (D22).
- **D22 Private-domain routing contract.** (REVISED 2026-10-25, twice:
  member-facing DNS is wholly day-2 — the MVP renders NO member DNS
  zones, NO private DNS service, and NO private CoreDNS VIP; members
  receive routes only, D13.) The day-2 pattern (operator-owned,
  e.g. external-dns publication): client machines resolve ONLY the zone
  `<instance>.<meta.domain>`; the zone's wildcard target is whatever
  day-2
  proxy the operator installs. Per-client opt-ins (default-on for
  `access = "admin"`,
  D33): (a) service zone `<instance>.svc.<meta.domain>` → rewrites to
  `<name>.<ns>.svc.cluster.local` with answer-name reversal;
  (b) pod zone (`pods insecure` + dash-form rewrites + D13 pod
  advertisement). `cluster.local` is NEVER served to clients. MVP: admin
  machines reach pod/Service IPs via D13 routes and resolve their names
  via day-2 automation (e.g. external-dns); nothing in the fabric or the
  bootstrap bundle renders member DNS zones, a private DNS service, or a
  private CoreDNS VIP.
- **D23 Upstream `kubernetes` distro = first-class target, Reserved.**
  kubeadm-based; same shared-lib interfaces, invariants, and rendering
  pipeline. Spec'd fully; implementation Reserved after rke2/k3s
  stabilize. Hard requirement, not optional scope.
- **D24 CNCF in-cluster posture.** Every clan-rendered in-cluster
  component is a CNCF project (Cilium, CoreDNS). Host-level components
  (FRR, WireGuard, HAProxy) exempt. rke2 = documented distro-layer
  exception; `k3s` and `kubernetes` are the CNCF distro paths.
- **D25 RKE2 hardened by default (CIS).** *Status (round G11): planned.
  The `rke2` service's `profile` defaults to `null`; `profile = "cis"` is
  opt-in and maps to the nixpkgs `cisHardening`; no suite runs it, and
  there is no `security.cis` option.* `profile: cis` (v1.29+): PSA
  `restricted` cluster-wide (except `kube-system`),
  protect-kernel-defaults, etcd user/group, CIS sysctls — host
  prerequisites rendered by the NixOS module. Explicit `security.cis =
  false` opt-out. Tenants get a namespace-exemption runbook. k3s/
  kubernetes get equivalent PSA defaults where the distro supports them.
- **D26 Kubenix is the manifest renderer; inflation is an UPDATE-time
  act in the artifact flake.** (REVISED round 13: scope shrinks to the
  bootstrap bundle — Cilium, pools, ClusterMesh config, CoreDNS, mirror
  Services, RBAC — but both layers and the zero-IFD rule are unchanged.)
  Layer 1: the atomic updater renders each pinned chart with the
  canonical fleet-uniform profile via `helm template` semantics and
  COMMITS the manifest into the pkgs repo (`manifests/cilium/
  <version>.yaml`); consumers read committed source — zero IFD.
  Layer 2: kubenix imports the base manifest and applies cluster
  variation by Nix module merging over the typed resource tree (cluster
  name/id, pod CIDRs, nodeipam, mesh peers land in `cilium-config` and
  sibling CRs, NOT in re-run helm values). Post-merge validation rejects
  invariant violations. **IFD defined**: evaluation reading a
  derivation's output — forbidden in clanServices (breaks `--no-build`
  gates).
- **D27 Rancher helm-controller disabled by default** on both distros.
  (REVISED round 13: folded into `distroDefaults`, D42 — the controller
  returns only when the operator opts into stock distro behavior.)
- **D30 Hub → spoke API reachability via ClusterMesh mirror Services.**
  Never touch the real `kubernetes.default` Service. Per cluster that
  exports its API (mandatory for `controlDomain.role = "spoke"`):
  clan-rendered selectorless mirror Service `kube-api-<cluster>` +
  EndpointSlice of API endpoints (D12 fan-in), annotated
  `service.cilium.io/global: "true"`, with `loadBalancerClass` pinned per
  D41/D8. Mirror-Service allocation is separate from D60 and MUST NOT use
  the clustermesh-apiserver's offset-79 VIP.
  Consumers render the same-name Service; ClusterMesh merges endpoints.
  Consumer CoreDNS rewrite (rendered from exports):
  `kubernetes.<cluster>.<meta.domain>` → `kube-api-<cluster>.<ns>.
  svc.cluster.local`. Kubeconfigs (D37/D38) use the mirror DNS name
  directly as `server`; the cluster's API certificate SANs MUST include
  it (eval-asserted). NetworkPolicy restricts mirror-Service access to
  GitOps namespaces. Mesh connectivity is symmetric.
- **D33 routed-fabric topology, access, and border are composable.**
  (REVISED round 14; round 15; round 16: two roles plus settings, D56;
  round 17: roles renamed leaf/spine + symmetric derivation, D59.)
  Two mutually exclusive topology roles, with no default role: `leaf`
  is the non-transit base = fabric membership (per-adjacency WG,
  FRR/BFD/Zebra) and, on a Kubernetes machine, automatic native
  pod-route exchange on native transports (D58); `spine` adds authorized
  forwarding and readvertisement between adjacencies. Per-machine
  `access = "member" | "client" | "admin"`
  defaults to `member` (membership, not topology): `client` adds
  fabric-pool LoadBalancer-VIP routes
  only (D13: Services that drew from an explicit private pool — never
  pods or ClusterIPs); `admin` adds D13 pod/ClusterIP route consumption
  (kamrui-h1); Kubernetes nodes on native transports install pod/VIP
  routes regardless of
  access (native-routing requirement, D49); the D22 zones are day-2, not
  MVP. Optional `border` adds upstream prefix
  ownership, filtered route exchange, forwarding, optional NDP, and
  authorized external/fabric transit — explicitly NOT automatic admin
  DNS. Topology, access, and border are orthogonal. Leaves attach to
  spines — every leaf attaches every spine by default and may declare an
  explicit spine subset; spines are declared directly by the spine role;
  every unordered spine pair is adjacent automatically (symmetric
  derivation, no mutual lists, D59). Every interface has
  one peer and a deterministic instance/adjacency-derived collision-
  checked name ≤15 characters. One machine joins at most one
  `routed-fabric` instance (one trust domain) and holds one topology role
  there. **Node duality is legal** (D16): the same FRR handles local
  Cilium and fabric peers; no self-interface or second BGP stack.
  Kubernetes managers are not spines by default (D51). Canonical test
  shape: kamrui-h1 = single-node k3s + spine role + admin access.
- **D34 Version policy: last 3 minors, latest + support-window gate.**
  Artifact flake packages the last 3 k8s minors per distro, latest patch
  each; servers upgrade first, agents lag per version-skew policy.
  Release-tag pins ONLY. k8s minor parity across distros enforced per
  minor. Eval WARNING when pinned Cilium support matrices don't list a
  pinned k8s minor.
- **D35 Secrets planes: clan vars = bootstrap plane only.** (REVISED
  round 13: the bootstrap plane shrinks to cluster CAs, join tokens,
  admin + read-only kubeconfigs, ClusterMesh CA/certs, HAProxy
  health-check material, and `gitops-hub` control-plane identities.
  Sealed-Secrets sealing keys LEAVE the vars plane — Sealed Secrets is
  wholly day-2, keys included.) All in-cluster application credentials
  are GitOps-owned (A3). Rule of thumb: if k8s/GitOps can rotate or
  serve it, clan vars does not store it — unless clan is the issuer.
- **D36/D37 → superseded by D43** (kept for history): Flux control
  domain modes and hub credential plane — renamed and de-Fluxed in
  round 13; semantics carried into D43.
- **D38 Read-only cluster credential (AI-agent access).** Every cluster
  auto-renders a read-only, no-secrets identity. ClusterRole
  `cluster-readonly` = aggregated `view` PLUS cluster-scoped reads
  (nodes, namespaces, persistentvolumes, storageclasses, ingressclasses,
  gatewayclasses, CRDs, clusterroles, clusterrolebindings,
  priorityclasses) — NEVER `secrets`, never any write verb;
  ClusterRoleBinding `cluster-readonly` binds group `cluster-readers`.
  Shared dependent vars generator `cluster-readonly-<instance>` signs a
  client cert with the cluster CA (CN=`readonly-<instance>`,
  O=`cluster-readers`, 365-day, `validation` pins instance); kubeconfig
  deploys alongside the admin one on server machines. Primary consumer:
  AI agents (handout via `clan vars get`). Hub extension: each spoke's
  read-only kubeconfig synced as Secret `kubeconfig-readonly` in
  `gitops-spoke-<spoke>` (D43). Caveat documented: read-only ≠ harmless;
  the `secrets` exclusion is the hard line. VM-proven positive + negative.

### Revoked in round 13 (retained for history)

- **D2 REVOKED** — Envoy Gateway as clan-rendered base ingress/Gateway.
  Reason: data-plane-only scope; EG is a day-2 GitOps recipe.
- **D4 REVOKED** — Ingress API deprecation posture. Moot: no
  ingress/Gateway surface remains in the contract to deprecate.
- **D5 REVOKED** (already scrapped round 5–7) — HAProxy edge-proxy.
  Unrelated to the retained per-node kubeapi HAProxy (§6.6).
- **D6 REVOKED** — three-layer Gateway ownership / zero-churn contract.
- **D7 REVOKED** — default NS+EW Gateway pair and `web` listener profile.
- **D15 REVOKED** — one IP:443 all-TLS-modes rule set (belongs to the EG
  layer). The underlying principle (one proxy implementation per IP:port)
  survives as the day-2 recipe's constraint.
- **D17 REVOKED** — `gateway.classes`/`gateway.instances` 0–N structure.
- **D18 REVOKED** — fleet CA + browser trust. No clan-issued in-cluster
  TLS remains; ClusterMesh CA (bootstrap plane) is unaffected.
- **D20 REVOKED** — fleet-wide east-west mTLS path (gated, never proven;
  its fleet CA prerequisite is revoked).
- **D28 REVOKED** — clan-rendered flux-operator + FluxInstance. Clan
  never installs a GitOps controller (D43).
- **D29 REVOKED** — replaced by D40 (same Kustomization-handoff idea,
  generalized to any GitOps tool and pinned to the bootstrap-bundle
  mechanism; HelmRelease adoption remains rejected unless the operator
  bootstraps via plain `helm install` themselves — day-2 choice).
- **D31 REVOKED** — external-dns as optional Flux component with
  clan-provided annotation knobs. Wholly day-2; no clan-rendered objects
  remain to annotate.
- **D32 REVOKED** — OLM rejection record. Moot under day-2 scope (the
  reasoning stands if ever re-proposed).

### Round 13 decisions (2026-10-22) — active

- **D39 Two-contract scope.** The clanServices promise exactly two
  verifiable contracts: the Bootstrap contract (§3.1) and the Data-plane
  contract (§3.2). Everything else in-cluster is a documented day-2
  GitOps pattern (§3.3), never clan-rendered, never host-churned.
  Rationale: keeping uniform state through host-resident YAML manifests
  on multiple manager nodes is bad practice — untracked, unsynchronized,
  and redundant once a GitOps repo exists. Test surface narrows to the
  two contracts (D44).
- **D40 Cilium lifecycle: rendered bootstrap bundle → GitOps adoption.**
  The whole day-1 in-cluster surface is ONE kubenix-rendered bundle per
  cluster (D26 layers), applied by a systemd oneshot on the
  `clusterInit` node: wait for apiserver health, then
  `kubectl apply --server-side --force-conflicts
  --field-manager=clan-bootstrap`. Never the distro manifests dir
  (nothing host-resident to track or redeploy); idempotent (SSA no-op
  when state matches); `bootstrap.apply = false` removes the unit on
  day 2. (REVISED round G11, K4/K5.) The unit runs at every start of the
  server and again on every deploy that changes the deployed bundle
  file (`restartTriggers`), without restarting the server; a regenerated
  ClusterMesh leaf re-runs the mesh secrets unit (`restartUnits`). It
  applies the non-CR documents first, waits (bounded) until the CRDs of
  the CR documents are `Established`, then applies the CRs. While
  `bootstrap.apply` is true clan owns the bundle, so after a successful
  apply it prunes: it deletes an object only when it carries
  `clan.lol/cluster=<instance>`, has a `clan-bootstrap` managed-fields
  entry, and is no longer in the bundle. A hand-made object, or one
  another manager owns alone, is never pruned; after the GitOps handoff
  (`bootstrap.apply = false`, D43) nothing is pruned because the unit is
  gone. Retries are bounded and grow (10 s up to 2 min, at most 12 starts
  an hour); then the unit stays `failed`, visible in `systemctl --failed`.
  Peer Secrets render as `data`, so SSA removes a key that left the
  bundle. Handoff: the identical set is published to
  the GitOps repo; Flux Kustomization (prune on) or Argo CD adopts it.
  First reconcile is a no-op BY CONSTRUCTION (identical bytes, one Nix
  source). Evidence (2026-10-22 research): Flux prune garbage-collects
  only its own `.status.inventory`, so adopting pre-applied objects is
  safe; the Cilium chart ships no `crds/` dir (the operator manages CRDs
  at runtime), so manifest rendering loses nothing and no helm hooks are
  needed; SSA bootstrap (`--server-side`) avoids CSA→SSA field-ownership
  friction. Alternatives rejected: `cilium install` CLI (hidden
  environment-autodetected values make HelmRelease parity fragile —
  documented crash-loop migrations; cert-generation mode skew
  cilium-cli#300); Rancher helm-controller (off per D42); HelmRelease
  adoption without helm release storage (impossible) — operators who
  want HelmRelease ownership bootstrap with plain `helm install` from
  the pinned chart themselves (Flux-maintainer-recommended pattern), a
  documented day-2 variant. Upgrades post-handoff: pkgs bump → rebuild →
  republish → GitOps applies. Publish-freshness gate (published ≡ fresh
  render) lives in the artifact/CI checks, not eval.
- **D41 Node IPAM default; pools keep the VIP plane.** (REVISED round 15:
  fabric-scoped.) Canonical profile sets `nodeIPAM.enabled=true` +
  `defaultLBServiceIPAM=nodeipam`: classless `type: LoadBalancer` Services
  receive node IPs (ExternalIP preferred, else InternalIP), the
  k3s-ServiceLB experience on every distro — including stock Traefik
  under `distroDefaults` — **fabric-scoped**: classless Services are a
  fabric-internal exposure and never a public-exposure mechanism; public
  exposure uses explicit pools (D8/D52). With
  `externalTrafficPolicy: Local` the advertised node set follows real
  EndpointSlices (pod placement); the documented Cilium dummy-Endpoints
  limitation affects only Cilium's own Gateway/Ingress implementations,
  which are permanently disabled (D1) — third-party proxies with real
  backends (Envoy Gateway day-2) are unaffected. Clan-rendered VIP
  consumers (ClusterMesh apiserver, mirror Services)
  draw from pools (D8/D9/D10): every explicit pool draw pins
  `io.cilium/bgp-control-plane`, because the Node-IPAM default owns every
  unset-class Service. This class selects LB-IPAM allocation, not automatic
  advertisement; only `node-bgp` and `shared-bgp` pools are selected by the
  rendered BGP advertisements. `bgpControlPlane.enabled=true` registers
  the class independently of `bgp.enable`, which controls BGP resources.
  KubeVirt Hetzner/provider-MAC attachment is netif host-bridge
  plumbing, never a Cilium pool/BGP delivery; KubeVirt stays day-2
  (D52). Multi-pool remains the
  default pod IPAM with
  derived non-clashing CIDRs; `ipam.mode: kubernetes` is an allowed
  explicit override (the old Node-IPAM ban referred to pod IPAM; both
  readings are now permitted/overridden explicitly).
- **D42 `distroDefaults` knob; servicelb permanently off.** Default
  `distroDefaults.enable = false` gives a uniform minimal base across
  rke2/k3s/kubernetes: no helm-controller, no Traefik, no servicelb, no
  distro add-ons. (Phase-3 reality note: rke2 deploys every packaged
  component as a HelmChart — including rke2-coredns — so D46's uniform
  clan-rendered CoreDNS is also what gives minimal rke2 cluster DNS at
  all; k3s's CoreDNS is a plain AddOn manifest but is disabled too, for
  uniformity.) `true` (rke2/k3s only): the service refrains from
  passing the distro `--disable`/`disable-helm-controller` flags, so the
  distro's packaged components deploy stock and are configured through
  the distro's own HelmChartConfig surface — the operator's day-2
  concern, not clan's. The `kubernetes` distro has no such knob (no
  distro defaults exist — which keeps the minimal base honest).
  servicelb/klipper stays disabled in BOTH modes: Node IPAM (D41) is its
  replacement and two controllers racing on `status.loadBalancer.ingress`
  is a contract violation. Traefik is no longer "removed" (old D3) — it
  is simply never clan-rendered and only exists when the distro itself
  ships it under `distroDefaults`.
- **D43 GitOps-neutral control domain.** (Supersedes D36/D37 naming and
  D28's controller install; REVISED round 15: meshGroup default.)
  `controlDomain.role = standalone | hub | spoke` per cluster instance
  (default `standalone`), bounded by the mesh trust domain (meshGroup
  defaults from the fabric instance — no repeated value; hub+spokes same
  fabric instance; ≤1 hub per group; spoke ⇒ hub exists; eval-asserted). Clan renders ONLY the
  tool-agnostic substrate: mirror Services (D30), in-spoke
  ClusterRoleBinding `gitops-hub` binding group `gitops-hub` →
  `cluster-admin` (configurable role) plus optional per-tenant
  impersonation SAs; per-spoke shared dependent vars generator
  `gitops-hub-client-<spoke>` (CN=`gitops-hub-<spoke>`, O=`gitops-hub`,
  365-day, signed by the SPOKE's cluster CA, `validation` pins
  spoke+group); hub-side namespace `gitops-spoke-<spoke>` holding Secret
  `kubeconfig` (admin) + `kubeconfig-readonly` (D38), delivered via
  vars→hub-machines→in-cluster secret-sync; kubeconfigs use the mirror
  DNS name as `server`. Any GitOps tool consumes this: Flux via
  `KubeConfig.secretRef`, Argo via cluster secrets — day-2 wiring
  documented, not rendered. Rotation = `clan vars generate --regenerate`
  + secret-sync re-apply; spokes unaffected (same CA). Alternatives
  rejected remain rejected (manual SA-token extraction = emergency
  runbook only; offline-minted SA JWTs; expiring bearer tokens + refresh
  CronJobs). Flux-specific hub tree conventions (tenants →
  infra-controllers → …) move to the day-2 docs as examples.
- **D44 Test-surface reduction.** (REVISED rounds 14–17; suite list
  updated for composable roles, network-facts parity, and the round-17
  transport/ClusterMesh contract. Round 20: the routed-fabric NAT-site,
  source/return and filter-negative items are target scope; §7 holds
  their status.) VM suites kept: single/join/HA per distro; netif
  (multi-NIC, VLAN/bond/bridge, multi-instance on one host,
  static/DHCP/RA, exports, cross-instance conflict negatives);
  routed-fabric transport/FRR (two spines + leaves, one WG interface per
  adjacency incl. automatic spine↔spine pairs, two NAT sites via spines,
  BFD both sides,
  RIB-to-FIB, next-hop-self, spine readvertise/leaf no-transit,
  route-filter and default-route negatives, 0/0 crypto ACL without IP
  default route, Internet source/return path, MTU floor + path-MTU);
  data-plane suite per distro (pool allocation + nodeipam + ETP-Local +
  native pod routes + node-bgp ownership + shared-bgp ECMP/withdrawal +
  firewall positive/negative + iptables-nft assertion + dual-AF local
  Cilium↔FRR session); bgp-ecmp (two spines active-active + single-spine
  failure/restore, upstream ECMP, border-not-spine, MikroTik-style FRR
  foreign-router fixture); selective ClusterMesh (full-peering default +
  explicit selective peers + selective isolation); native
  ClusterMesh + mirror-Service reachability; fabric topology/access/border
  (leaf/spine, border-not-spine, composable admin-border and the cluster-node
  dual-shape, client pod isolation, admin svc/pod/ClusterIP, border
  filtering, border-without-automatic-admin-DNS); network-facts eval
  parity across every networking service and a consumer-wrapper diagram
  render test (D57);
  PKI rotation; **GitOps-handoff
  proof** (bootstrap bundle applied, then re-applied SSA under a second
  field manager — strict no-op, dataplane green before/after; no Flux in
  VMs, Flux artifacts were cut from pkgs); rke2 CIS profile. Round-17
  additions (status by suite; k3s/RKE2 native and tunnel external class+DNS
  are VM-proven):
  eval third-party
  node_transport overlay with NO provider service-name branching;
  native internal-load-balancer ClusterMesh (pinned IPv4 VIP + class +
  SANs);
  tunnel NodePort ClusterMesh (one pod per selected node, deterministic
  collision-checked NodePort); external class+DNS exposure on both
  profiles; ClusterMesh placement (voters/workers/all/labels + zero-match
  negative) and group-uniformity negatives; internal-VIP pool membership/
  collision checks; spine/leaf HA ECMP failure/restore with FRR
  reload/restart keeping RIB/FIB stable. Retired:
  full-mesh transport suite (superseded by derived spine/leaf, D51/D59;
  historical), EG gateway matrix, QUIC/Caddy fixtures, flux
  control-domain suite, external-dns, OpenEBS, KubeVirt, Multus,
  sealed-secrets suites.
  go-httpbin remains the one workload fixture.
- **D45 Shared lib renamed `lib/kube-cluster/`.** Supersedes the D23
  rename gate (was: on kubernetes-distro landing). The lib serves all
  three distros' bootstrap+data-plane; "rancher" is the misleading name.
  Code rename landed in phase 1 (§8).
- **D46 Uniform clan-rendered CoreDNS (2026-10-23).** The minimal base
  ships ONE clan-rendered CoreDNS on every distro — rke2, k3s, and the
  Reserved `kubernetes` (kubeadm addon phase skipped) — rendered into the
  bootstrap bundle via kubenix typed resources (no chart, no IFD):
  Deployment + Service (pinned to the derived clusterDNS IP) + Corefile
  ConfigMap + RBAC, digest-pinned image airgap-carried by the artifact
  flake. The distro's bundled CoreDNS is disabled in minimal mode (k3s
  `--disable=coredns`, rke2 `rke2-coredns` always disabled);
  `distroDefaults.enable = true` restores the distro's stock CoreDNS for
  `cluster.local` and skips the clan one. Either mode renders ONLY the
  in-cluster `cluster.local` CoreDNS; member-facing DNS (D22) is wholly
  day-2 — no private CoreDNS service or VIP is rendered in either mode.
  Rationale:
  rke2's bundled CoreDNS cannot carry the rewrite/custom-import
  uniformly; one DNS implementation makes the base identical across
  distros and anticipates D23. NOT bundled, ever: etcd (the distro's
  datastore, not an addon), metrics-server (kubectl top/HPA only,
  non-CNCF, day-2), local-storage/snapshot controllers (day-2). The
  uniform minimal base = distro runtime + Cilium + clan CoreDNS. The clan
  CoreDNS serves `cluster.local` in-cluster only; member-facing private
  zones (D22) are day-2, never in the bootstrap bundle.
  **Custom-config seam (2026-10-25 amendment, k3s convention):** the
  clan-rendered Corefile MUST support the k3s `coredns-custom` import
  convention so day-2 GitOps can extend DNS without clan: the main
  `:53` server block ends with `import /etc/coredns/custom/*.override`;
  additional server blocks are imported via `import /etc/coredns/custom/
  *.server` at Corefile top level; the Deployment mounts ConfigMap
  `coredns-custom` (`kube-system`) read-only at `/etc/coredns/custom`
  as an OPTIONAL volume — pods must boot cleanly with the ConfigMap
  absent. Clan NEVER renders `coredns-custom` itself; it is a
  GitOps-owned day-2 object, exactly as with k3s. Under
  `distroDefaults`, k3s's stock CoreDNS already follows this
  convention; rke2's stock chart does not import `coredns-custom`,
  which is another reason the minimal base renders the clan CoreDNS.

### Round 14 decisions (2026-10-24) — active

- **D47 Per-adjacency routed WireGuard is the only fabric datapath.**
  (REVISED round 15: per-remote-machine full mesh superseded; round 17:
  leaf/spine naming, D59; round 22: committed vars allocate transfers, D64.)
  Every fabric machine has a stable
  dual-stack `/32` + `/128` on a fabric loopback/dummy interface and
  exactly one point-to-point WireGuard interface per **fabric
  adjacency** (leaf↔spine attachments; every unordered spine pair
  automatically, D59) — never one per remote
  machine. Each interface has one peer and transfer prefixes allocated once
  in shared public vars; duplicate prefixes on one host are rejected, while
  overlapping peers on one interface are forbidden. One UDP session per
  adjacency removes the legacy shared-identity roaming collision.
  AllowedIPs is both outbound cryptokey selection and the inbound source
  ACL: it carries the remote stable host addresses plus every approved
  transit source/destination prefix on that adjacency, and
  external-transit adjacencies may include 0.0.0.0/0 and ::/0 as crypto
  ACL without creating or accepting an IP default route (D51). NAT
  members dial reachable members with keepalive 25; two NAT sites never
  peer directly — they communicate through spines; an adjacency with no
  reachable endpoint on either side is an eval error. Per-link WG MTU
  derives from the underlay MTU minus WireGuard overhead with a safe
  floor, and VMs assert path MTU (D51). Endpoint reachability is per
  declared adjacency; private endpoints are allowed when actually
  reachable; netif peer exports provide automatic endpoint selection
  with explicit overrides. Derived spine/leaf is the supported MVP
  topology (D59); full mesh is deferred. (Round-14 history: one interface per
  remote machine in an encrypted full mesh, identical prefixes as ECMP,
  hidden hub-and-spoke/route-reflector variants excluded.)
- **D48 FRR + Zebra owns the routing control plane and kernel FIB.** FRR
  10.7+ uses one integrated config, eBGP per AF per WG link, BFD on every
  FRR path, strict bidirectional policy, and ECMP across interfaces.
  Cilium only advertises to local FRR. Rejected: BIRD (superseded),
  Cilium agents peering directly across the fleet (couples manifests to
  transport and lacks BFD), and treating BGP itself as the datapath
  (Zebra/kernel forwarding is the datapath).
- **D49 Native-routed multi-pool Cilium is mandatory on native
  transports.** (REVISED round 17: datapath mode is transport-derived,
  D58.) On a native transport (routed-fabric): `routing-mode:
  native`, no tunnel, `auto-direct-node-routes=false`, dual-stack
  mesh-wide native-routing CIDRs, and Cilium devices covering every
  fabric WG interface (one per adjacency, D51/D59). FRR distributes
  remote `CiliumPodIPPool` routes over the `local-router` exchange (D58);
  native ClusterMesh groups need non-overlap and working pod routes in
  every member (D60). On a tunnel transport (wireguard-mesh): Cilium
  tunnel/VXLAN with node connectivity only; no pod routes are exchanged.
  Multi-pool remains the default pod IPAM on both; `ipam.mode: kubernetes`
  remains an explicit override. Cilium stays networking-only and no L7
  feature is enabled.
- **D50 Inventory owns the core host data plane.** (REVISED round 15:
  multi-link, multi-instance; round 18: IfState-only rendering, D61;
  round 25: `specs/netif.md` is the authority for host networking, and its
  N5 replaces the Wi-Fi sentence below.)
  `netif` declares links, static/DHCP/RA addressing, gateways, routes,
  MTU, DNS, firewall trust, underlay policy routing, and deploy-target
  exports in `inventory.nix` — multi-link and multi-instance, including
  multiple netif instances on one host (D53). An instance is a
  site/segment with shared defaults plus per-machine and per-link
  overrides; links may be physical, VLAN, bond, or bridge. `netif` owns
  underlay policy routing; `routed-fabric` owns fabric-specific policy
  routing (D53). `routed-fabric` consumes its peer facts. Cross-instance
  assertions: unique link ownership (one link, one instance), no
  default-route conflicts, no DNS conflicts, and instance-namespaced
  DHCP hooks (rule 5). Supporting NixOS modules may handle Wi-Fi
  association or platform quirks, but cannot own static core
  addresses/routes or enable a competing network manager. Home's
  `hostSpec.networking`/`machines.json` static-IP ownership is removed;
  borg's `lan` is a behavioral reference, not code to preserve.

### Round 15 decisions (2026-10-24) — active

- **D51 Derived spine/leaf is the only MVP transport topology.** (REVISED
  round 16: direct hub role and member attachment; round 17: renamed
  leaf/spine with a symmetric derived graph, D59; round 22: node ASNs are
  allocated public vars, D64.) Exactly one WireGuard
  interface per fabric adjacency — leaf↔spine attachments plus automatic
  spine↔spine pairs (D59) — never one per remote machine; full mesh
  is deferred beyond MVP and leaves the supported and tested surface
  (round-14 per-pair full-mesh text retained historically in D47). Every
  fabric node keeps its stable dual-stack `/32`+`/128` loopback (D47) and
  runs FRR bgpd+bfdd+Zebra (D48). eBGP per adjacency with committed,
  fleet-unique private 32-bit node ASNs, one session per address family per
  adjacency interface, BFD on every adjacency, and `next-hop-self` on
  spine
  readvertisement so every distributed next hop is directly resolvable.
  Spine-role machines forward and readvertise; leaf-role machines never
  transit except for explicitly authorized border traffic. No iBGP, no
  route reflectors, no route servers. The graph is derived symmetrically:
  every leaf attaches every spine by default (an explicit spine subset is
  allowed) and every unordered spine pair is adjacent automatically — no
  mutual hub lists. One spine is the minimum, two are the HA profile, and
  there is no arbitrary
  maximum: additional spines must be an explicit capacity/failure-domain
  choice. Spine-only full peering is NOT a full fabric mesh: there are no
  leaf-leaf edges. Public endpoints alone do not imply spine or border
  placement.
  Kubernetes managers are not spines by default. Active-active spine HA is
  pure fabric ECMP — every leaf links both spines, eBGP/BFD on both, FRR
  `maximum-paths` + multipath-relax; no shared gateway VIP, no VRRP.
  Upstream active-active requires upstream ECMP. Transparent active-active
  default gateway for ordinary non-fabric LAN clients is OUTSIDE MVP: it
  needs client routing or an L2/VRRP-like mechanism. AllowedIPs is both
  outbound cryptokey selection and the inbound source ACL, so it carries
  every approved transit source/destination prefix on the adjacency;
  external-transit adjacencies may include 0.0.0.0/0 and ::/0 as crypto
  ACL WITHOUT creating or accepting an IP default route. Internet ingress
  through a border requires source-policy return routing through the
  correct fabric egress — no asymmetric local-WAN reply. Pure routed HA
  does not imply stateful NAT failover: multiple NAT borders do not
  preserve conntrack state or guarantee existing-flow continuity without
  a separate state mechanism. Fabric-originated routes are stable
  /32+/128. NAT members keepalive 25; two NAT sites never peer directly —
  they communicate through spines. Per-link WG MTU derives from the underlay
  MTU minus WireGuard overhead (80 bytes v4 / 96 v6) with a 1280 floor,
  and VMs assert path MTU. Endpoint reachability is evaluated per
  adjacency; private endpoints are allowed when actually reachable; netif
  peer exports provide automatic endpoint selection with explicit
  per-adjacency overrides. Making every node a spine and linking every
  pair is full mesh, not a way around the deferred-topology boundary.
- **D52 `routed-fabric` replaces `fleet-routing`.** (REVISED round 16:
  four-role model superseded by D56; round 17: spine/leaf naming, D59.)
  The service name and trust-domain
  boundary remain; topology/access/border semantics are defined by
  D33/D56/D59. Fabric spine/leaf is distinct from control-domain hub/spoke of
  D43 (GitOps control, §6.14 naming note). Pool/exposure scope: Node IPAM
  classless Services are fabric-scoped; public exposure uses explicit
  pools; `node-bgp` exists only where BGP delivery actually exists and
  provider-static node-bound extras remain node-fate-bound;
  Hetzner/provider-MAC KubeVirt attachment is netif host-bridge plumbing,
  never a Cilium pool/BGP delivery — KubeVirt remains day-2
  (D8/D41 revised).
- **D53 netif is multi-link and multi-instance.** An instance = one
  site/segment with shared defaults plus per-machine and per-link
  overrides; multiple netif instances may coexist on one host. Links:
  physical, VLAN, bond, bridge; addressing static/DHCP/RA; gateways,
  MTU, DNS, underlay routes, endpoint exports. Cross-instance
  assertions: unique link ownership (one link, one instance), no
  default-route conflicts, no DNS conflicts, instance-namespaced units
  (rule 5). Ownership split: netif owns underlay policy routing;
  `routed-fabric` owns fabric-specific policy routing. Multiple
  `routed-fabric` instances are separate trust domains, and a machine
  joins at most one (its meshGroup defaults from it, D43/D54).
- **D54 ClusterMesh: full peering by default, selective peers
  supported.** (REVISED round 17: group datapath uniformity, D60.)
  Within one fabric instance the default is full peering
  among its clusters; explicit symmetric selective peers are supported —
  a central cluster may peer A↔B and B↔C while A and C do not peer.
  ClusterMesh groups require identical datapath mode, tunnel protocol,
  and maxConnectedClusters across members: native groups need
  cross-cluster pod routes and mesh-wide native CIDRs (D49); tunnel
  groups need node connectivity.
  Peering state is non-transitive. Peering alone is not isolation:
  selective peers also bound the automatic cross-cluster pod/Service
  route policy rendered into fabric filters; a routed-only exception
  between non-peered clusters must be deliberate and eval-visible. Spine
  transit is that exception: a spine carries the union its attached leaves
  consume, even when a cluster on that spine does not peer with the route's
  origin. A single kernel FIB cannot both withhold such a route locally and
  forward it, so leaf-local route isolation is proven on non-transit leaves;
  ClusterMesh/global-Service isolation still applies on every node.
  Separate `routed-fabric` instances provide HARD trust-domain
  separation (no mesh, no routes, no DNS across instances). Three
  distinct graphs: the **underlay graph** (netif links), the **fabric
  graph** (routed-fabric adjacencies), the **ClusterMesh graph**
  (peering edges) — similar shapes, independent edges. `meshGroup`
  defaults from the fabric instance; no repeated value required.
- **D55 Host datapath hygiene: nftables-only firewall + dual-AF local
  Cilium session.** (REVISED 2026-10-25 from the k3s data-plane VM failure.)
  (i) Host firewall is nftables-only; kube-proxy is off. Cilium 1.20.3
  rejects KPR/BPF masquerade with `install-iptables-rules=false`, so the
  canonical profile sets the supported `extraConfig."install-iptables-rules"
  = true` key and layer 2 preserves it. Cilium's required datapath rules use
  `iptables-nft`; legacy iptables and kube-proxy rules are forbidden.
  Cilium 1.20.3 exposes no `installIptablesRules` Helm value. Official
  mycelium/yggdrasil/wireguard overlays are NOT dependencies or underlays —
  peer exports are the integration seam.
  (ii) The local Cilium↔FRR `::1` session carries BOTH address
  families; advertisement selectors and the `CiliumPodIPPool` type are
  pinned; explicit `extended-nexthop` capability and v4-over-v6 /
  v6-over-v4 next-hop behavior must be PROBED before the renderer locks
  (5R2); the Cilium GR posture (timers, restart behavior, capability
  fallback) is explicit enough for tests.

### Round 16 decisions (2026-10-24) — active

- **D56 Two fabric topology roles plus orthogonal access and border.**
  (REVISED round 17: roles renamed `leaf`/`spine`, D59.)
  `routed-fabric` roles are exactly `leaf` and `spine` (rounds 15–16
  called them `member`/`hub`); no role is
  selected by default. `leaf` is a non-transit participant; `spine`
  forwards and
  readvertises between authorized adjacencies. Spine↔spine adjacencies
  are automatic for every unordered spine pair; every leaf attaches every
  spine by default and may declare an explicit spine subset; the graph is
  derived symmetrically — no mutual lists (D59). Spine-ness is directly
  visible in the spine machine's role, not inferred only from the union
  of leaf settings. Per-machine `access =
  "member" | "client" | "admin"` defaults to `member` — membership, not
  topology — and implements
  D13/D22; it does not alter topology. Optional `border` configuration
  contains upstream peers, `ownedPrefixes`, filtered route exchange,
  forwarding/NDP policy, and authorized external/fabric transit. Border
  is not a role and grants no automatic admin DNS or route consumption.
  Topology, access, and border may be combined on one machine without
  weakening least-privilege defaults. A fabric spine is internal transit; a
  border is external transit; a default gateway is a route next hop; DHCP
  and NAT are separate functions; Kubernetes Gateway API is day-2
  application traffic management. None is a synonym for another. A border
  is not necessarily a spine, is not inherently a public-WAN node, and does
  not automatically supply public addresses, NAT, or a default route. A
  border leaf remains non-transit for ordinary fabric routes; only its
  explicitly authorized upstream policy is added. Kubernetes leaves can
  originate private pod/VIP pools without any border; border configuration
  is needed only when selected prefixes cross the fabric boundary through
  an upstream router, and public reachability requires actual upstream
  routing and return policy. Automatic spine-pair and leaf-spine adjacency
  derivation is instance-scoped: spines in different routed-fabric
  instances never auto-peer, even when an operator describes them as one
  administrative domain. Separate instances remain hard trust-domain
  boundaries; cross-instance connectivity requires deliberate external
  routing through border/upstream policy.
- **D57 Dependency-free network facts; consumer-owned nix-topology.**
  (REVISED round 17: `networkFacts` moves to schemaVersion 2 with
  leaf/spine fabric facts, D59.)
  ClanServices expose a versioned, JSON-serializable, non-secret,
  per-node `clan.networkFacts` NixOS interface. Producers populate only
  facts they own; leaves use `readOnly = true`, have safe defaults for
  deep evaluation, and derive from the SAME resolved configuration that
  renders functional NixOS networking and public exports. Consumers never
  define or override them. The schema is declared without importing
  nix-topology and covers node identity; netif networks/links/interfaces/
  addressing/gateways/routes/policy routes/MTU/DNS/firewall trust; fabric
  topology/access/border, stable addresses, per-adjacency WireGuard
  interfaces/transfer prefixes/public endpoints/MTU/AllowedIPs, ASNs,
  upstreams, FRR prefix policy, NAT/source-return intent; Kubernetes
  distro/cluster membership/CIDRs/pools/Node-IPAM facts and
  API/mirror endpoints; and the independent underlay, fabric, ClusterMesh,
  and control-domain graphs. No private keys, certificates, tokens,
  kubeconfigs, or other secrets enter facts. Facts are complete and
  accurate for build-time-declared configuration, not a claim about
  runtime: DHCP/RA modes, learned routes, handshakes, reachability,
  health, and failover state are represented as declared intent or left
  unknown, never invented. ClanServices never depend on nix-topology,
  set its `topology.*` options, supply icons/renderers, or own diagram
  packages. A consumer-owned wrapper supplies nix-topology and its
  NixOS/flake integration, translates `clan.networkFacts` into
  `topology.*`, and may expose `topology.<system>.config.output` and
  `packages.<diagram>` as buildable SVG artifacts. Automatic NixOS
  extraction may supplement, but never replace or contradict, these
  authoritative facts. Facts/export/render parity is eval-tested; one
  consumer-wrapper build proves the translation seam.

### Round 17 decisions (2026-10-25) — active

- **D58 Generic `node_transport` schemaVersion 2 — the only transport
  seam.** Supersedes the ad-hoc per-service transport exports: k3s/rke2
  consume ONLY `node_transport` and never branch on provider service
  names. The schema is shared, neutral, and declared OUTSIDE
  `lib/kube-cluster` so third-party overlays can implement it. Per
  instance and endpoint it pins: stable dual-stack node addresses; the
  service and instance identity used for targeted allocation remedies;
  every datapath interface keyed by its Linux
  interface name, each with its MTU; exactly one `directRoutingDevice`
  naming one of the exported interfaces; `datapath.mode = native |
  tunnel` with sibling `datapath.tunnelProtocol` (vxlan for the only
  supported tunnel initially) and, for native mode, `native.routeExchange
  = local-router` — daemon-neutral, never `local-frr`/`local-bgp`
  (`native.routeExchange` is null on tunnel transports); and the
  independent
  exposure capabilities `internalLoadBalancer` and `nodePort`; and
  `port`. The
  schema is open — other route-exchange or tunnel modes are
  representable — but strict validated profiles are the initial
  surface: unsupported profiles are eval-rejected until implemented and
  tested. Provider-specific `routed_fabric` remains the source for
  ASN/topology/adjacencies/ACL/access/border. Admin overrides cannot
  contradict the derived mode, protocol, devices, `directRoutingDevice`,
  MTU, or exposure. Supported profiles: `routed-fabric` ⇒ Cilium native
  + `local-router` route exchange + `internalLoadBalancer` AND
  `nodePort` capabilities; `wireguard-mesh` ⇒ Cilium tunnel/VXLAN +
  `nodePort`. Native-mode Cilium MTU = the minimum interface MTU; VXLAN
  = minimum minus 50. Because `cilium-config` is cluster-wide,
  `directRoutingDevice` must be identical and present on every cluster node;
  routed-fabric therefore always exports its stable loopback and uses it as
  the direct device, while the broader `devices` set also retains every
  per-adjacency interface. Machine-local adjacency names must not be copied
  from the cluster-init node into the shared direct-device value.
  - **Revoked in part by D72 (round 53):** the tunnel profile, the
    `datapath.mode`/`datapath.tunnelProtocol` fields and the
    `wireguard-mesh` profile are gone. Every transport is native
    routing with `local-router`; the Cilium MTU is the minimum
    interface MTU. The text above is kept as history.
- **D59 Spine/leaf symmetric fabric graph; schema renames.** Fabric
  topology roles are `leaf` and `spine` (renamed from `member`/`hub` in
  rounds 15–16; the rename is breaking and ships without migration
  shims — no external consumers or deployments exist). Per-machine
  `access = member|client|admin` is unchanged and is membership, not
  topology. The adjacency graph is DERIVED symmetrically: every
  unordered spine pair is adjacent automatically; every leaf attaches
  every spine by default and may declare an explicit spine subset; there
  are no mutual hub lists to drift. One WireGuard interface per
  adjacency (D47). Making every node a spine and linking every pair is
  full mesh, not a way around the topology boundary — spine-only full
  peering is not a full fabric mesh: there are no leaf-leaf edges.
  Spines forward and readvertise with next-hop-self; leaves never
  provide transit; two spines are the HA profile with no arbitrary
  maximum. `routed_fabric` and `networkFacts` move to schemaVersion 2.
- **D60 ClusterMesh placement and exposure.** ClusterMesh groups
  require identical datapath mode, tunnel protocol, and
  maxConnectedClusters across members (D54 uniformity; since D72 only
  maxConnectedClusters can differ, routing is always native); full peering
  remains the default and explicit selective peers stay symmetric and
  non-transitive. Native groups need cross-cluster pod routes and
  mesh-wide native-routing CIDRs (D49); tunnel groups need node
  connectivity only. The clustermesh-apiserver runs with ETP Local on
  EVERY exposure method: mTLS identity does not depend on source IP, but
  Local preserves the source, avoids a second hop, supports ClientIP
  affinity, and enables internal-LB withdrawal. Placement = `voters`
  (default — server nodes), `workers` (agent nodes), `all`, or `labels`;
  label selection uses only clan-declared/generated labels and a
  selector matching zero nodes is an eval error. Exposure = `auto |
  internal-load-balancer | node-port | external-load-balancer`, default
  `auto`: `auto`
  picks internal-load-balancer when the transport exposes that
  capability, else node-port; unsupported or no-method selections are
  eval errors. Node-port has NO replica knob: the Deployment replicas
  equal the selected node count with required hostname anti-affinity +
  nodeSelector (one pod per selected node), all selected nodes' stable
  IPv4 addresses are advertised; the NodePort defaults to 32379 with an
  optional explicit port override, collision-checked per machine; and
  rolling updates use maxSurge=0 /
  maxUnavailable=1. Internal (and external) LB exposure has an
  independent replica count: default min(3, eligible), user positive ≤
  eligible, required anti-affinity, no per-node remote endpoints, and
  the same rolling update. Explicit external always wins on every
  overlay: it requires an explicit non-clan `loadBalancerClass` and a
  `dnsName` (DNS name ONLY — no literal IP), allows provider annotations
  (external-dns is day-2), needs no internal capability — it works
  regardless of transport capabilities — and puts the
  DNS name in peers and certificate SANs; DNS (A record) resolution is a
  runtime prerequisite. Internal exposure (clustermesh-apiserver ONLY —
  mirror
  Services get a separate, future allocation and must NOT share offset
  79, D30) pins ONE IPv4-only literal VIP at
  the D10-locked host offset 79 / 0x79 — `172.16.<id>.79` — drawn from
  the existing `<instance>-fabric` private pool's IPv4 block by explicit
  `lbipam.cilium.io/ips` projection, class
  `io.cilium/bgp-control-plane`; the VIP is asserted pool-contained and
  collision-checked against every other pinned clan VIP; remote peers
  consume the VIP
  directly (no DNS needed); pool names are unchanged and pool
  membership/collision assertions stay. Control-plane exposure is
  IPv4-only on the validated Cilium 1.20.3 profile (the pinned chart's
  clustermesh-apiserver Deployment embeds etcd with
  `--listen-client-urls=https://0.0.0.0:2379` and no dual-stack
  listener knob): there is NO ClusterMesh IPv6 VIP and NO
  `RequireDualStack` advertisement, while the ClusterMesh data plane
  stays dual-stack; certificate SANs carry published IPv4/DNS endpoints
  only, never unreachable IPv6. Normalized settings: `mesh.peers`
  (explicit symmetric selective peers; default full),
  `mesh.placement = voters | workers | all | labels` (default `voters`),
  `mesh.placementLabels` (clan-declared/generated only),
  `mesh.exposure = auto | internal-load-balancer | node-port |
  external-load-balancer` (default `auto`), `mesh.replicas`
  (internal/external LB only;
  null default = min(3, eligible); FORBIDDEN on node-port),
  `mesh.nodePort` (default 32379, optional explicit override), and
  `mesh.external.{loadBalancerClass, dnsName, annotations}` (external
  only). The `kube_cluster` export uses schemaVersion 4 for the revised
  datapath/exposure facts — no shims.

### Round 18 decisions (2026-10-27) — active

- **D61 IfState is the only static host-network renderer.** (REVISED
  round 25: `specs/netif.md` N2/N5/N6 — IfState is the renderer in IfState
  modes; NetworkManager renders NetworkManager modes and is never enabled
  together with IfState; iwd owns Wi-Fi. The rest of D61 stands for IfState
  modes.) IfState 2.5.1
  owns physical/VLAN/bond/bridge/dummy/WireGuard links, static addresses,
  static and policy routes, rules, and network sysctls for every machine
  managed by these clanServices. `netif`, `routed-fabric`, and
  `wireguard-mesh` compose one shared per-machine base through
  `lib/ifstate.nix`; `inputs.org-pkgs.overlays.ifstate` supplies the pinned
  pure-pyroute2 package and the base asserts IfState >= 2.5. systemd-networkd, netdevs, scripted network units,
  NetworkManager, global `networking.useDHCP`, and parallel
  `networking.interfaces` ownership are forbidden — no compatibility
  renderer or migration shim. Changes apply through `ifstate.service`
  during normal NixOS activation and converge live without reboot; dry-run
  `ifstatecli check` is the convergence assertion. DHCP clients run in
  per-link IfState hooks and persist across the oneshot via
  `KillMode=process`; IPv6 SLAAC uses per-link RA sysctls. WireGuard
  private keys are root-owned `0400` clan-vars files referenced only by
  runtime `!include`, never store text. FRR/Zebra owns dynamic routes;
  IfState's built-in protocol ignores preserve them. Cilium-owned
  interfaces and table 200 are explicitly ignored, while netif's DHCP
  routes and other declared static ownership remain reconciled. Global
  forwarding uses `sysctl_conf`. The hermetic proof covers live static
  reconfiguration, DHCPv4/default-route and SLAAC convergence with one
  persistent client, real WireGuard handshakes, fabric HA, and every
  dependent k3s/RKE2 native/tunnel/selective/external suite.

### Round 19 decisions (2026-10-28) — active

- **D62 `pkgs` owns artifacts and shared inputs; VM tests stay out of
  `checks`** (REVISED round 24, D66: the input is named `org-pkgs`; suites
  are declared in `clanTests` and run on the org runner).
  `external-systems/pkgs` pins nixpkgs and flake-parts;
  clanServices follows `org-pkgs/nixpkgs` and `org-pkgs/flake-parts` so artifact and
  nixpkgs updates do not require an independent clanServices update. The
  artifact flake owns the composed/default, Kubernetes, and IfState overlays,
  the committed Cilium manifest, distro runtime packages, and amd64/arm64
  airgap outputs for x86_64-linux and aarch64-linux. clanServices re-exports
  those overlays and consumes the published manifest and per-system image
  outputs; consumers may replace the transitive `org-pkgs` input but do not need
  to declare it. Distro defaults come from the receiving machine's overlaid
  `pkgs.k3s`/`pkgs.rke2`, with explicit package and image overrides retained.
  `clanTests` is the declaration interface, and org-pkgs `flakeModules.vmTests`
  emits `legacyPackages.<system>.vmTests`; `checks` contains only lightweight
  static checks. VM derivations must never return to `checks`.

### Round 21 decisions (2026-10-29) — active

- **D63 Correct exposure, collision-free ownership, and stable convergence.**
  TCP 179 and UDP 3784/4784 are never opened globally by routed-fabric:
  they are allowed on fabric WireGuard interfaces and, for external
  sessions, only from declared literal `border.upstreamPeers` addresses.
  Hostnames, zones, and malformed upstream literals are eval errors.
  **Amended round G11 (R5): the fabric is no trust zone.**
  `firewall.trust` defaults to false: a fabric link opens 179 and BFD
  only, and each service opens its own ports there (k3s/rke2: the
  cluster's ports and Cilium health 4240). `trust = true` never reaches an
  `externalTransit` link (D75 removed `firewall.trust`: the fabric is
  never a trust zone). Forwarding nodes carry a stateless forward
  filter in their own table `inet routed-fabric-<instance>` (it only
  drops; stateless so ECMP that splits a flow over two spines passes): an
  `externalTransit` link forwards only to the border's `ownedPrefixes`, and
  a forwarding border forwards nothing from outside the fabric (any link
  but its fabric links and Cilium's) to the fabric's own addresses
  (member loopbacks, transfer pool, ULA /48). Where another service turns
  on the NixOS forward filter, routed-fabric accepts fabric↔fabric transit.
  **Amended round 60 (R7): external transit ends on its border.** An
  `externalTransit` adjacency has `border.ownedPrefixes` on exactly one
  end, the *owner*; the other end is the *upstream* end (where the
  outside is). External sources cross that one WireGuard link and end on
  the owner: its own addresses, or VIPs its Cilium delivers. They are
  never forwarded on into the fabric: every other link's crypto ACL
  drops a source outside the fabric, so the owner drops it first and
  counts it (`externalTransit: ends on this border`). Replies leave the
  owner by `sourceReturn` over the same link. The transit filter is
  rendered on the owner only; on the upstream end it would drop every
  packet the link forwards, fabric traffic too (probe, round 60). On the
  owner, fabric-to-fabric traffic (source and destination in the
  fabric's own addresses) still crosses the link; cluster pod and VIP
  routes do not. Multi-hop external transit (derived `sourceReturn` and
  0/0 ACLs on every hop) is not built; a case that needs it starts as a
  new probe.
  **Superseded in part by D73 (round 62):** BGP and BFD of a fabric
  link answer that link's peer address only (no port per interface, no
  4784 on fabric links), and the forward filter above is replaced by
  D73's guard table on every member. The R7 transit rules stay until
  transit tunnels become their own link class.
  **Amended round G11 (R9): upstream policy.** A border announces its
  `ownedPrefixes` and accepts only the peer's `acceptedPrefixes` (default
  nothing). `ttlSecurity` (GTSM, both ends) is per peer, default off. No
  session password: FRR reads it from `frr.conf`, which is in the Nix
  store, and a password added at runtime would be removed by the next
  reload. The
  shared IfState base has a stable module key so repeated service imports
  deduplicate, requires globally unique rendered WireGuard listen ports, and
  reserves them, together with entries from the composable clanServices-owned
  `clanServices.networking.reservedPorts` list, in
  `net.ipv4.ip_local_reserved_ports`.

  Source-return and netif policy tables never use the shared kernel/Cilium
  reserved set `{0,200,201,253,254,255,2004,2005}`. Source-return tables also
  avoid same-host netif policy tables and other source-return tables. Their
  independent rule priorities occupy a deterministic band below kernel `main`
  (32766) and are unique across all source-return and effective netif rules.
  `sourceReturnTable` and `sourceReturnPriority` pin either derived value.
  Netif policy tables and effective rule priorities are unique across
  instances. Every adjacency with two
  declared literal endpoints must share an address family. **Amended
  round G11 (R4): a hostname endpoint is an eval error.** IfState 2.5.1
  resolves a WireGuard endpoint name once, at apply, drops the endpoint
  when DNS fails then, and never resolves it again. The side whose address
  changes sets `endpoint = null` and dials out to the fixed side; a
  re-resolve timer is built only when a real case needs it.
  **Round G11 (R6): per-adjacency overrides bind both ends.** Two
  different `port` overrides are an eval error, the smaller `underlayMtu`
  override of the two ends applies to both, and `extraAllowedIPs` (D75:
  `extraPrefixes`, also a contract entry) is the union of both ends' lists, in both ACLs and in both ends' import and
  export prefix-lists (exact match). This is a
  declared-endpoint check, not the phase-5 per-host underlay reachability
  matrix. Wireguard-mesh rejects pairs with no endpoint on either side,
  overlapping `extraAllowedIPs`, and same-host routed-fabric listen-port
  clashes. The final literal `clan.core.networking.targetHost`, including an
  explicit override on a machine without netif, never names a fabric
  loopback, transfer, or tunnel address; optional user/brackets/port are
  parsed and IPv6 is normalized before comparison.
  `clan.networkFacts.forwarding` exports actual host forwarding intent from
  spines, borders with `border.forwarding`, and k3s/rke2 nodes without a
  sysctl evaluation cycle; RA-enabled links on forwarding machines use
  `accept_ra = 2`.

  Each fabric adjacency has a symmetric timer profile: `site` = BFD 300 ms
  x3, `wan` = BFD 1000 ms x5 plus BGP keepalive/hold 10/30 seconds. Equal
  non-null `settings.site` values default to `site`; every other pair,
  and a member that names no site (the default, round 57), defaults to
  `wan`; an explicit per-adjacency profile overrides the default and two
  conflicting overrides are eval errors. Border upstream sessions always
  use `wan`. Both fabric ends and upstreams render FRR 10.7
  `neighbor <peer> timers delayopen 5`: DelayOpen applies on each inbound
  and outbound session recovery and delays establishment for up to five
  seconds. FRR 10.7.1 `bgp_bfd.c` starts BFD strict hold-time only when the
  effective BGP hold timer is zero, so strict hold-time is not this recovery
  hold-down. DelayOpen is fixed, not exponential flap damping; FRR route
  dampening is not substituted because upstream discourages it and its
  dual-stack coverage is incomplete. Periodic-flap behavior belongs to the
  phase-6 WAN soak. **Amended round G11 (R3):** fabric and Cilium
  sessions render `maximum-prefix 4096 warning-only` (a reset fabric session
  takes the node's loopback, API and etcd with it); an eval warning names
  an adjacency whose countable prefixes (members plus Kubernetes nodes)
  reach 80 % of the limit. Upstream sessions keep `restart 10`.
  `maximum-paths` is rendered once per address family, from
  `maximumPaths` (R8). Each distinct prefix set is one shared prefix-list
  (R10). Pod routes take their length from the cluster's published
  `network.podMaskSizeV4/V6` (`lib/kube-cluster/pod-mask.nix`, the
  CiliumPodIPPool `maskSize`, R11). **Supported size (R10):** about 30
  adjacencies on one machine; random ports and transfer /31s then collide
  on one machine with about 2 % and 1 % chance (an eval error naming the
  generator), at 100 about 22 % and 14 %. **Graceful restart (round G11,
  R2, accepted):** it is promised for a bgpd restart only. A restart of
  all of FRR stops bfdd too; whether the peers then drop the node at once,
  as for a dead node, or hold its routes stale is a race (`k3s-frr-failure`
  saw both). Accepted: BFD must still find a dead node fast. Drain a node
  before restarting FRR by hand. A deploy reloads FRR (nixpkgs
  `reloadIfChanged`) and restarts nothing.
  Every profiled neighbor also renders plain `bfd`; site profile defaults
  stay implicit and `use-underlays-nexthop-weight` is explicit, matching FRR
  running-config serialization. A no-op FRR reload therefore has an empty
  `frr-reload.py --test` diff, preserves peer uptimes, and leaves the RIB
  immediately identical; DelayOpen must never excuse reload-induced
  recovery. Stability takes precedence over faster reconvergence.

### Round 22 decisions (2026-10-30) — active

- **D64 Fabric and mesh allocations are committed public clan vars.** Every
  routed-fabric loopback IPv4/IPv6 address, node ASN, per-adjacency UDP port
  and transfer prefix, and every wireguard-mesh node IPv4/IPv6 address is
  generated once and read from vars at eval; none is recomputed from a
  machine or instance name. All allocation files set `secret = false` and
  `deploy = false`. Generator scripts use Python `ipaddress` and `secrets`,
  never shell arithmetic. Services receive the module-level `directory`
  argument and read values with `clanLib.getPublicValue` in `perInstance`;
  shared reads pass `machine = null`, selecting
  `vars/shared/<generator>/<file>/value`. Every value is trimmed and every
  missing value throws the exact `clan vars generate <machine> --generator
  <generator>` remedy rather than flowing into an address as null.

  `routed-fabric-<inst>-ula` is shared, has no validation, and is the only
  generator that writes the random RFC 4193 `fdXX:XXXX:XXXX::/48` `ula48`.
  `routed-fabric-<inst>-loopback4-pool` and
  `routed-fabric-<inst>-transfer4-pool` are separate shared generators, each
  writing one public non-deployed `pool` file with string-only
  `validation.pool`. Pool defaults are `198.18.0.0/17` and `198.19.0.0/16`.
  Member settings `loopback4Pool` and `transfer4Pool` must be equal on every
  member and must equal their recorded pool vars. Each per-machine
  `routed-fabric-<inst>-node4` depends only on `-loopback4-pool` and writes
  `ipv4` (a random non-network/non-broadcast host in the loopback pool);
  `routed-fabric-<inst>-node6` depends only on `-ula` and writes `ipv6` (a
  random host in `<ula48>:0::/64`). `routed-fabric-<inst>-asn` is an
  independent per-machine generator writing `asn` randomly in
  4200000000..4294967294, so repairing an address collision cannot reset BGP
  sessions or ASN-derived source-return defaults.

  Each sorted adjacency `<a>`, `<b>` declares three byte-identical shared
  generators on both endpoints, where the short hash names the canonical
  adjacency key and cannot alias hyphenated machine-name pairs:
  `routed-fabric-<inst>-adj-<hash>-port` has no dependencies, validates only
  `portStart`/`portEnd`, and writes `port`;
  `routed-fabric-<inst>-adj-<hash>-transfer4` depends only on
  `-transfer4-pool` and writes a `/31` `transfer4` from the transfer pool;
  `routed-fabric-<inst>-adj-<hash>-transfer6` depends only on `-ula` and
  writes a `/127` `transfer6` from `<ula48>:1::/64`. The `portRange` setting
  defaults to 10000–29999, below both the Kubernetes NodePort range and the
  kernel ephemeral range, and is member-uniform. Custom ranges must be
  disjoint from `clanServices.networking.reservedPorts` and, on Kubernetes
  members, 30000–32767. No machine name or machine-local value may differ in
  a shared generator's script, files, dependencies, or validation.

  `wireguard-mesh-<inst>-ula` and `wireguard-mesh-<inst>-prefixes` have the
  same independent lifecycle; the latter writes `ipv4-pool`, defaulting to
  `198.18.128.0/17`, disjoint from the routed-fabric loopback default. The
  per-machine `wireguard-mesh-<inst>-node4` depends only on `-prefixes` and
  writes `ipv4`; `wireguard-mesh-<inst>-node6` depends only on `-ula` and
  writes `ipv6`. A `loopback4Pool` or mesh `ipv4Pool` change therefore
  re-rolls only unpinned IPv4 loopbacks through `node4`; a `transfer4Pool`
  change re-rolls only adjacency `transfer4` prefixes; a `portRange` change
  re-rolls only adjacency ports. None re-rolls ULA, IPv6, ASNs, or unrelated
  adjacency values. Drift remedies state these exact effects. Explicit
  `ipv4`, `ipv6`, and `adjacencies.<remote>.port`
  settings override vars and remain the collision escape. Source-return
  table and rule-priority defaults use the allocated remote ASN with their
  existing formulas and retain all D63 collision assertions; their collision
  remedies name the existing per-adjacency pins rather than ASN
  regeneration. The generic `node_transport` export carries that allocated
  host ASN for local-router consumers, so k3s/RKE2 never recompute it. On a
  local-router member, `bgp.hostASN` is only a consistency pin: it must be
  null or exactly equal to the transport's allocated `asn`. It cannot renumber
  FRR, whose `router bgp` always uses the routed-fabric allocation. A differing
  pin is an eval error naming the machine, both ASNs, and the remedies (remove
  the pin or regenerate the member's `<service>-<instance>-asn` generator,
  with both name parts read from its resolved `node_transport` facts). A
  Cilium/host ASN collision remedy offers `bgp.ciliumASN` or that same
  facts-derived targeted ASN regeneration, never a `bgp.hostASN` pin or a
  hard-coded transport service name.

  IPv4 pool validation checks the lexical shape first: exactly one slash, a
  dotted-quad address, and prefix length 0–30. Only a matching value is parsed
  and checked for canonical network address and capacity, so malformed input
  produces the canonical-CIDR assertion rather than an uncatchable Nix error.

  Eval rejects missing allocations; allocated values outside their recorded
  pool or ULA `/64`; recorded pools that differ from current settings;
  fleet-wide duplicate loopback IPv4, loopback IPv6, and ASNs within an
  instance; per-host adjacency-port collisions with every other rendered
  WireGuard port; per-host duplicate transfer prefixes; unequal member
  pools; and allocation-pool overlap with each other, the ULA-derived `/64`s,
  member netif static underlay prefixes, and member kube-cluster
  pod/service/fabric-pool CIDRs. Network facts publish allocation pools and,
  in each adjacency's `generator` list, all three adjacency generator names
  (port, transfer4, transfer6) so same-host checks also reject overlaps across
  instances and services and explicit addresses in foreign pools. Duplicate
  transfer prefixes on unrelated hosts are valid. k3s/RKE2 reject a
  local-router host ASN equal to their Cilium ASN. Duplicate messages name
  both owners and direct regeneration at the newer machine; an adjacency
  command may name either endpoint. Regenerating a ULA is an explicit
  instance-wide IPv6 loopback/transfer renumber, never the remedy for an
  IPv4 pool edit. Orphaned `vars/shared/routed-fabric-*-adj-*` directories
  require an operator cleanup check because eval cannot enumerate the vars
  tree; the exported generator names provide the expected set.

  Random collisions are resolved once at generation time and then remain
  stable. With `k` random picks among `N` slots, the birthday approximation
  is `P(any collision) ≈ 1 − exp(−k(k−1)/2N)`: 102 loopbacks in a `/17` have
  about a 15% collision probability; a spine with 100 adjacencies has about
  22% for ports in 20000 slots and 14% for transfer `/31`s in 32768 slots.
  A generator cannot enforce cross-machine uniqueness because it sees only
  declared dependencies; a single whole-instance allocator is forbidden
  because adding a member would renumber everyone. Renaming a machine creates
  a new clan identity and new vars; no migration or rename shim exists.

  Hash-derived by design, and therefore outside D64: `adjacencyName`,
  `rflo<hash>`, FRR symbol names, per-adjacency IPv6 link-local addresses,
  the kube-cluster Cilium cluster id, Cilium ASNs, fallback local-router host
  ASNs, and pod/service CIDRs. Fabric-member local-router ASNs are allocated
  vars, not hashes. These remaining names and cluster-level values have
  separate pins and fleet checks.

### Round 23 decisions (2026-11-02) — active

- **D65 `remote-builder` is a fleet utility outside the cluster contracts.**
  Moved from external-systems/home. A `server` serves its store over
  `ssh-ng` to the restricted `nix-ssh` user (trusted, write) for every
  client key and an optional shared CI key whose private half is never
  deployed; `client`s get `nix.buildMachines`, a fail-fast ssh alias and the
  server's pinned host key. Every generator, alias and known-hosts entry is
  named `<instance>-…` (rule 5), so an instance named `remote-builder` keeps
  the vars it had in home. It touches no network renderer, FRR, Cilium or
  cluster object, and no D1–D64 decision constrains it. Eval-tested
  (`tests.systems.<system>.remote-builder`); no VM suite.

### Round 24 decisions (2026-11-11) — active

- **D66 The repo follows the external-systems org standard.**
  - **Inputs.** One org input, `org-pkgs` (`github:external-systems/pkgs`).
    `nixpkgs`, `flake-parts` and `import-tree` follow it; clan-core and
    kubenix follow those and `org-pkgs/treefmt-nix`.
  - **No dev partition.** `inputs.org-pkgs.flakeModules.default` supplies:
    - the formatter (`checks.treefmt`, every nixf-diagnose rule);
    - the docs site and deck (`documentation/docs`, `documentation/slides`,
      settings in `flake-parts/docs.nix`);
    - `checks.lock-sync`;
    - the VM-test runner.

    `checks.nix-unit` uses nixpkgs' `nix-unit` and walks `flake.lock` for its
    offline overrides.
  - **VM suites.** Each service registers its suites in the top-level
    `clanTests.<suite>` (24 today). `flake-parts/clan-tests.nix` wraps each
    one in clan-core's `clanTest` and passes it to `vmTests.tests`, so
    suites stay under `legacyPackages.<system>.vmTests` (D62). k3s and RKE2
    suites that test one contract (`single`, `join`, `ha`, `data-plane`,
    `clustermesh`, `external`, `selective`) share one
    body in `lib/kube-cluster/tests/vm/<suite>.nix` behind thin per-service
    wrappers; every distro difference is an explicit `distro` branch. Test
    scripts group their steps in `with subtest(...)` phases, so a run
    summary names the failing phase, and still end with their `<SUITE>_OK`
    marker. Test vars are generated during evaluation by clan-core's
    `clanTest`; there is no update-vars step.
  - **Owner-approved limits for this repo,** sized for euc-hel-0 (128 GiB,
    36 threads):
    - 96 GiB and 36 vCPUs per suite;
    - 16 GiB and 8 vCPUs per VM;
    - a 2-hour default timeout.

    RKE2 nodes need at least 4 GiB and 2 vCPUs, and planned topologies are
    larger than today's. Raising the limits needs the owner's yes.
  - **Parallel runs.** `vm-test --all --remote` boots suites side by side,
    largest first, while their VMs fit `vmTests.parallel` (24 vCPUs and
    96 GiB); a suite larger than the budget runs alone. A suite that fails
    beside others is rerun alone; passing then is `PASS(!)`, a pass with a
    warning that it is timing-sensitive under load. A result already in the
    store is `CACHED`: nothing booted, so it is not a pass of this run.
    `--rebuild` boots a fresh copy and works with `--remote`; `--serial`
    runs one suite at a time; `--resume` continues an interrupted `--all`
    run, skipping suites whose last result passed for the same test
    derivation.
  - **Faithful test refactors.** A refactor of suites (subtests, shared
    k3s/RKE2 bodies, rewrites) is proven with `nix run .#suite-snapshot`
    before and after (`--pin` the baseline's `clan.directory`) and
    `nix run .#suite-compare`: every node derivation and every normalized
    test script equal the baseline. `vm-test --check` rejects `| grep -q`
    in test scripts.
  - **Evaluation warnings.** `check` and CI run `nix run .#flake-check`:
    warnings matching org-pkgs `evalWarnings.deny` (ignored, removed or
    insecure config) fail; the rest are listed.
  - **Eval checks off in CI.** `vmTests.flakeChecks.enable = false` keeps the
    whole-suite evaluation out of CI. `vm-test --check` runs the same checks
    one suite per process.
  - **Results.** The result is the exit status of the sandboxed build. Each
    suite writes `.vm-tests/<suite>/{build.log,summary.txt,result.txt}`
    (gitignored). This replaces the
    `.baton-pass/vm-logs` path and the runner's marker check from round 20.
  - **Editor, CI and dev shell.** The dev shell is devenv (`devenv.yaml`
    imports `org-pkgs/devenv`). CI is the org `ci.yml` (`ci / flake-check`;
    Pages at `clanservices.external.systems`; `0.0.<commits>` releases).
    nixd settings are in `.vscode/`.

- **D67 Clusters run on an IPv6-only underlay.** *(suite-verified, no
  service code needed for the join; `<distro>-v6only`,
  `<distro>-clat-<transport>`. The CLAT itself and its `devices` entry
  are still set by the suites, not rendered by a service:
  `specs/gateway.md` G5, planned)*
  - **Why.** A public IPv4 costs money in the cloud. Clan machines
    there have no IPv4 address on any NIC (`specs/netif.md` U13, N45).
  - **Clusters stay dual-stack inside** (§3.2): applications hard-code
    IPv4, so single-stack IPv6 clusters are not a goal.
  - **How.** Node addresses stay the stable dual-stack fabric loopbacks
    (D47); the control-plane endpoint stays IPv4 on the fabric (D60).
    The IPv4 a node needs is a private fabric address. IPv4 routes ride
    IPv6 BGP sessions (`extended-nexthop`) and tunnels with IPv6
    endpoints.
  - **IPv4 egress.** The host uses `nat-gateway` (NAT64 and DNS64). Pod
    IPv4 egress is `specs/gateway.md` G5: a CLAT on the node, or NAT44
    over the fabric as the fallback.
  - Proven by suites on both transports and both distros (rounds 49
    to 51): see the status line. What they do not cover is listed in
    `specs/gateway.md` §13.

- **D68 `router` and `nat-gateway` are governed by `specs/gateway.md`.**
  *(planned, 2026-11-20)* Two clanServices over the private
  `lib/gateway/`: the edge of a LAN, and IPv4 reach for machines that
  have none. They are host networking, outside the two cluster
  contracts (D39). That file is their contract and status authority
  (decisions G1–G23), as `specs/netif.md` is for netif.

- **D69 NodePorts answer on the node addresses only.** *(implemented,
  2026-11-21; eval `test_nodePortAddresses`; suites `<distro>-clat`,
  subtest "a NodePort answers on the node addresses from the other
  node, and not on a NIC address from outside the cluster (D69)",
  `CLAT_NODEPORT_OK`; the former `<distro>-data-plane-tunnel` proof
  went with D72)*
  - **Why.** Cilium serves a NodePort in eBPF, before nftables, on the
    first address of every link in `devices`. A link in `devices` that
    faces the outside (the underlay for a floating address, the CLAT
    link of `specs/gateway.md` G5) therefore opened every NodePort to
    the outside, past the node firewall. Every `LoadBalancer` Service
    allocates a NodePort, so this was the common case, not a corner.
  - **How.** The profile renders `nodePort.addresses` (ConfigMap key
    `nodeport-addresses`): each member's node addresses as host
    prefixes (`/32`, `/128`). A NodePort answers there and on no other
    address. A packet to another address of a `devices` link reaches
    the host stack, where the node firewall decides.
  - **Unchanged.** LoadBalancer addresses (LB-IPAM pools, floating
    addresses, Node IPAM) are their own frontends, not NodePorts.
    ClusterMesh `node-port` exposure publishes node addresses (D60),
    which are in the list.
  - `cilium.helmValues.nodePort.addresses` overrides the list. Cilium's
    host firewall was the rejected alternative: it needs node policies
    and can lock out SSH, WireGuard and BGP.

- **D70 CoreDNS replicas never share a node.** *(implemented,
  2026-11-21; eval `test_coreDNSSpread`; suites
  `<distro>-ha`)*
  - **Why.** The anti-affinity was soft and the bundle applies before
    the second node is Ready: both replicas started on the first node
    and stayed. When that node died, cluster DNS was gone.
  - **How.** A cluster with two or more members renders
    `topologySpreadConstraints` on the clan CoreDNS Deployment: one
    replica per node, `DoNotSchedule`, `minDomains: 2`. The second
    replica stays Pending until a second node is Ready. A one-member
    cluster keeps the soft rule and both replicas.
  - While a node is down its replica is Pending, not moved: one replica
    serves. That is the price of never sharing a node in a two-node
    cluster.
  - Not covered: `distroDefaults.enable = true` keeps the distro's own
    CoreDNS and its placement.

- **D71 The kube services render Cilium's `devices` from netif facts.**
  *(owner, 2026-11-23; implemented round 54)* Amends D58, where
  `devices` derive from the transport only. Full rules:
  `specs/gateway.md` §14.2.
  - Per node: the transport link(s), the CLAT link where a CLAT runs
    (G5), the underlay link(s) where the underlay has no IPv4, and on
    a `nat-gateway` gateway the links of its uplink zone (round 55),
    and on a `router` its WAN link (round 56; `specs/gateway.md` G25).
    On every node: the link that owns its default route (round 56).
  - Names come from netif's zones (N10), so a mixed fleet works:
    `eno1`, `enp0s1`, `wlp2s0` in one cluster.
  - A VPN link (`tailscale0` and the like) is never in `devices`; an
    eval assertion refuses it.
  - Settled (round 54): one cluster-wide list, the union of exact
    names, as the transport's links already were. Rejected for now: a
    `CiliumNodeConfig` per node, wildcards.
  - Built in `lib/kube-cluster/devices.nix`; the CLAT link comes from a
    member's `nat_gateway` export, the IPv6-only underlay from its
    `netif` export (links of the client's uplink zone with no static
    IPv4 and no DHCPv4). A VPN link (zone `vpn` or `tailnet`, or a name
    starting `tailscale`, `wt`, `nb-`, `zt`, `tun`) fails eval, also
    when set in `cilium.helmValues.devices`.
  - Hand-set `cilium.helmValues.devices` is gone from `<distro>-clat`.
    `k3s-clat-mapped` keeps it: it proves the alternative in which the
    CLAT link is not a device. `<distro>-data-plane` still adds `eth1`
    by hand for its foreign router's VIP ingress (allowed: a superset).

- **D72 Native routing only; Cilium tunnel mode and `wireguard-mesh`
  are removed.** *(owner, 2026-11-23; implemented round 53)* Revokes D58's tunnel
  profile and "`wireguard-mesh` is a supported tunnel transport".
  - **Why (owner):** native routing is always preferred; VXLAN adds
    overhead and sits inside WireGuard anyway; FRR makes BGP, outside
    services and the flat layer-3 fabric easy; tunnel mode cannot use
    BGP pools, fabric pools, G20's service prefix or the router as a
    fabric member; two modes double the suites, wall time and code for
    every new feature (CLAT, D71).
  - **Accepted cost:** FRR is on every node, with no second data plane
    to fall back on. Answered by suites for FRR failure (bgpd crash,
    bad reload), not by a second mode. Upstream users who want VXLAN
    are not a goal (AGENTS.md rule 10).
  - **What goes:** `services/wireguard-mesh`; Cilium `routingMode:
    tunnel` and `tunnelProtocol`; the tunnel branches in
    `lib/kube-cluster` (`cilium.nix`, `bundle.nix`, `assertions.nix`,
    `fleet-checks.nix`, `mesh.nix`, `transport.nix`); `mode` and
    `tunnelProtocol` in `node_transport` (one mode needs no field, no
    shim); the suites `<distro>-data-plane-tunnel`,
    `<distro>-clustermesh-tunnel`, `<distro>-clustermesh-selective-tunnel`,
    `<distro>-clat-mesh`, `k3s-clat-mesh-mapped`, `wireguard-mesh`.
  - **What moves onto `routed-fabric`:** the suites that use the mesh
    only as their base: `<distro>-single`, `-join`, `-join-netif`, `-ha`,
    `-clustermesh-external`, `k3s-modes`, and `routed-fabric` as base in
    `selective` and `data-plane-fixtures`. They keep their contract and
    their `*_OK` marker. Where a `-fabric`/`-native` twin already exists
    (`ha-fabric`, `clustermesh-external-native`, `modes-fabric`), the
    two merge into one suite under the plain name.
  - **Nothing is lost:** before the removal, tag the last `main` commit
    that has tunnel mode `tunnel-mode-final` and push the tag.
  - **Order:** after PR 35 merges, the removal is the first PR of the
    next session, before any service code, so the CLAT and D71 are
    built once.
  - **Done (round 53):** the code above is gone. The suites moved or
    merged as listed; `<distro>-clat-fabric` became `<distro>-clat`
    and `k3s-clat-fabric-mapped` became `k3s-clat-mapped`. The FRR
    failure suite is `k3s-frr-failure` (`K3S_FRR_FAILURE_OK`).
    `<distro>-clustermesh-tunnel` was not dropped but ported to the
    fabric as `<distro>-clustermesh-nodeport`. The tag
    `tunnel-mode-final` is pushed.

### Round 62 decisions (2026-11-27) — active

- **D73 Link contracts and one guard table** *(round 62; design
  `specs/design-routed-fabric.md` §2, §3.2, §3.3, §3.10; owner H3, H4,
  H10, H20)*. A link carries a packet only if BGP may carry its route.
  - **Contract.** Per adjacency `sources` = cidrs of `import` plus the
    peer's transfer /32 and /128; `destinations` = cidrs of `export`
    plus this end's transfer addresses. WireGuard AllowedIPs =
    `sources` (an `externalTransit` link adds 0/0 until transit tunnels
    land). The FRR lists read `import`/`export` as before. Both sets
    are in the fact `clan.networkFacts.fabric.<i>.adjacencies.<r>`. The
    two ends mirror (nix-unit `test_contractMirror`, `hostile-fabric`
    C01).
  - **Guard.** One table `inet routed-fabric-<instance>` on every
    member with an adjacency. `F` = loopback pool, transfer pool, ULA
    /48 and every member's stable address (D75 removed the member
    list: pinned loopbacks lie in their pool). Chains: `ingress` (filter,
    prerouting, priority raw) jumps each fabric link to its
    `link_<L>` chain (source not in `src_<L>` or destination not in
    `dst_<L>`: counted drop), accepts local links (`lo`, the fabric
    dummy, `cilium*`, `lxc*`), drops a fabric source from any other
    link, accepts `fabricInside` links, drops any other link's packet to
    `F`; `forward` (priority filter − 5) sends packets from a fabric
    link to `from_fabric` (a spine relays to fabric links; pod and
    inside links pass; else counted drop) and packets into a fabric link
    to `into_fabric` (pod and inside links pass; else counted drop);
    `egress` (postrouting) drops a packet to `F` that leaves by a link
    outside the fabric. Stateless, default deny only by a final drop in
    the two link chains (never `policy drop`: a router's LAN to WAN is
    not the fabric's, G25). Rules are found by their comment.
  - **Sessions.** Per adjacency four input rules: TCP 179 and UDP 3784
    (TTL / hop limit 255) from the peer's transfer address to this
    end's, on that link. No 4784 and no `ttl-security` on fabric
    sessions (H20). Upstream peers keep D63's rules.
  - **Fail closed.** FRR is ordered after `nftables.service` and its
    `ExecStartPre` waits up to 80 s for the guard table (the unit's
    start limit would end a check that fails at once). A guard removed
    at run time is not noticed; on a running machine zebra `-r` keeps
    the kernel routes while FRR waits.
  - **Inside links.** `clan.networkFacts.fabricInside` lists links whose
    hosts may reach fabric addresses through this machine: the CLAT and
    NAT64 host links always, a router zone with `fabric = true`.
  - **Limits.** L1: a packet for a pod on a kube node enters Cilium
    before netfilter, so pods are kube's to guard (H12). L3: a rooted
    spine can forge member sources (§6.12). L4: a member can reset its
    own BGP session.

### Round 63 decisions (2026-11-27) — active

- **D74 The kube guard table; the rke2 supervisor front for members**
  *(round 63; design `specs/design-kube.md` §3.3, §8 item 1; owner H1,
  H10, H19)*.
  - **Guard.** One table `inet kube-<instance>` on every member with
    fabric links (a manual-address node had none until kube step 3
    removes that mode). Chain `ingress` (filter, prerouting, priority
    raw, policy accept): `iifname` in the fabric links, `lo`,
    `cilium*`, `lxc*` and `clan.networkFacts.fabricInside` accepts;
    a packet to the pod or Service CIDRs from any other link is a
    counted drop with the comment "outside to the cluster's pods and
    Services". Readers find the rule by that comment.
  - **Limit.** A packet that a Cilium device delivers to a local pod
    never enters netfilter (design §3.1, probe P1): the table guards
    non-Cilium links and packets for a pod on another node. The
    clusterwide policy (kube step 7, H12) guards the rest.
  - **Supervisor front.** The rke2 supervisor's HAProxy front
    (`8442 + cilium.id`) is in `memberOnlyPorts` with the supervisor
    (9345): members only, never the pod CIDRs (K-A2).
  - **Runtime.** `services.rke2.package` is the effective
    `packages.rke2`, as k3s already did (K-A1).
  - **Suites.** `<distro>-hostile`, one body; every verdict group has a
    positive control that gates the suite like a verdict (H19).

### Round 66 decisions (2026-11-28) — active

- **D75 Fabric options, link hardening, fail closed** *(round 66;
  design `specs/design-routed-fabric.md` §3.5 point 2, §3.6, §3.7,
  §3.8, §3.10; owner H5, H16)*. Amends D73.
  - **Options.** Addresses and prefixes typed (`lib/ip.nix` types).
    `adjacencies.<r>.extraPrefixes` replaces `extraAllowedIPs`.
    `firewall.trust` removed. `acceptedPrefixes` entries asserted:
    `<prefix>( (ge|le) N){0,2}`.
  - **Pins (A5).** A pinned `ipv4` lies in `loopback4Pool`; a pinned
    `ipv6` lies in `loopback6Pool` (new, member-uniform, null = the
    generated `<ula>:0::/64`). `F` = loopback4 pool, transfer4 pool,
    ULA /48 and `loopback6Pool`: D73's member list is gone.
  - **Origin (R-A5, I10).** What a member may originate
    (`originRoutes`): every `shared-bgp` pool of its clusters and the
    `node-bgp` pools it owns. It feeds the spine's import from a leaf,
    the leaf's export, the spine pair, and the import from the local
    Cilium session. Consumption reads every pool.
  - **Owned prefixes (A3, A4).** No prefix shorter than /8 (IPv4) or
    /16 (IPv6); no overlap with `F` or a cluster's pod or Service
    CIDRs. A7 is a warning: a pool in 10/8, 172.16/12, 192.168/16 or
    100.64/10 on a member whose underlay takes DHCP.
  - **Link hardening.** Per fabric link (IfState `sysctl`): the netif
    baseline (N47) and `accept_ra = 0`; no `rp_filter` (a per-link value
    does not hold). Global `arp_ignore = 1`, `arp_announce = 2` with
    `mkDefault`. On a member with a Cilium neighbor the guard has a
    chain `local_out` (output): TCP to port 179 on `lo` from a non-root
    user is a counted reject.
  - **Fail closed.** IfState routes `type = "unreachable"`,
    `preference = 4294967000`, for every prefix of `F`, main table, no
    `dev`. Readers of `routing.routes` accept routes without `dev` and
    `table`.

### Round 67 decisions (2026-11-28) — active

- **D76 A fabric always; HAProxy on loopback; one firewall matrix**
  *(round 67; design `specs/design-kube.md` §3.2, §3.6, §3.9, §8 items 3
  and 4; owner H7, H10)*. Amends §6.3, §6.6, §6.12 and D74.
  - **Fabric.** `network.fabric` is required; there are no manual
    addresses. Every member's node addresses, links and MTU come from
    its `node_transport` export; a member without one is an eval error.
    The mesh group defaults to the fabric instance.
  - **Options.** `domain` matches `[a-z0-9]([-a-z0-9.]*[a-z0-9])?`; the
    pod, Service and fabric-pool CIDRs are `lib/ip.nix` prefixes. The
    parity check covers `firewall` and a distro's own options (K-A8).
  - **README (H7).** The quick start evaluates in a nix-unit test with no
    failed assertion of the services.
  - **HAProxy.** Fronts bind `127.0.0.1` and `::1` only; the kubeapi name
    resolves there. Server lines pin `source` to the node's fabric
    address. A server's fronts are `7442 + id` and `+1000`; an rke2
    agent's supervisor front is 9345. haproxy stays ordered after
    `ifstate.service` (ordering, not a requirement; the `source`
    contract of `specs/target-design.md` §3).
  - **Firewall.** One matrix of rows (`matrix`, `renderMatrix`); each row
    names ports and source classes (`members`, `servers`, `pods`).
    Rows: `api`, `supervisor`, `kubelet`, `cilium-health`, `etcd`. Every
    rule is guarded by the fabric links and the local pod links; no link
    is trusted. New option `firewall.kubeletFromPods` (default false).

## 5. Invariants (target; eval-asserted or VM-proven)

1. One declarative fleet: instance declaration ⇒ stable identity,
   non-overlapping defaults, integrated transport, automatic ClusterMesh
   when the mesh group has peers (full peering default; selective peers
   explicit and symmetric, D54).
2. Dual-stack inside, always (nodes/pods/Services); public exposure
   varies per node/Service (v4-only, v6-only, both, neither).
3. Cilium is the only CNI base: one upstream 1.20+ profile, KPR,
   native routing only (D72), multi-pool;
   networking-only (D1/D49/D58).
4. L3 only: no L2-announce/VRRP/shared-L2. Tested fabric transport =
   derived spine/leaf with one host WireGuard interface per adjacency
   (D51/D59; full mesh is not the supported MVP topology); every cluster
   dual-stack. `netif` may configure VLAN parents/children, bonds, and
   bridges as underlay links, never as a shared cluster datapath.
5. ETP Local on every clan-rendered external-facing Service (mirror
   Services, ClusterMesh apiserver); no silent
   Cluster fallback.
6. LB IPAM ownership unambiguous: classless Services → Node IPAM (D41);
   every explicit pool draw → `io.cilium/bgp-control-plane`; BGP
   advertisements select `node-bgp` or `shared-bgp` pools only, with
   owner/advertiser coherence (D8).
7. Topology always labeled: region/zone default to instance name,
   per-machine overrides, non-empty.
8. Hermetic proof: pinned artifacts, eval rejection of invalid
   inventories, hermetic VM suites.
9. One cluster per node (D16); one routed-fabric membership (at most one
   instance/trust domain) and one FRR per host (D19/D33/D52); exactly
   one classless-LB implementation per cluster (Node IPAM; servicelb
   never — D42).
10. `cluster.local` is pinned and never served to clients (D21);
    member-facing private DNS is deferred to day-2 — the MVP serves no
    cluster DNS to fabric members (D22 amended 2026-10-25).
11. Kubenix renders every clan manifest; two-layer pipeline, zero IFD in
    clanServices eval (D26); delivery = one bootstrap bundle, SSA, once
    (D40); Rancher helm-controller off by default (D42).
12. Control domain without clan-installed GitOps: standalone/hub/spoke
    (D43); mirror Service + mirror SAN mandatory for spokes (D30);
    hub+spokes share one fabric instance (meshGroup defaults to it);
    ≤1 hub per group; spoke ⇒ hub exists (eval-asserted).
13. Clan vars = bootstrap plane only (D35 revised); no clan vars
    generators for application-plane secrets (lint).
14. Artifact flake carries the last 3 k8s minors per distro (D34);
    airgap-ready is the tested default.
15. Every cluster mints admin + read-only (no-secrets) kubeconfigs
    (D38); the hub holds both for every spoke.
16. CNCF in-cluster posture for clan-rendered components (D24); rke2
    CIS-hardened by default (D25; planned: `profile = "cis"` is opt-in
    today).
17. Every static core link/address/route is inventory-owned through
    `netif` (multi-instance; cross-instance conflicts eval-rejected,
    D50/D53); every fabric AllowedIP and BGP filter derives from one
    route policy; no default route or unapproved prefix leaks, and a 0/0
    crypto ACL never creates or accepts an IP default route (D47/D51).
18. Spine/leaf transit rule: spine-role machines forward and readvertise
    with next-hop-self; leaf-role machines never provide transit;
    every leaf reaches ≥1 spine (every spine by default, explicit subset
    allowed) and every unordered spine pair is adjacent automatically;
    HA profiles use two spines with no arbitrary maximum, eBGP/BFD/ECMP
    and no shared gateway VIP/VRRP (D51/D59). Access and border never
    silently change this topology.
19. ClusterMesh peering is full within one fabric by default; selective
    peers are explicit, symmetric, and non-transitive; group members share
    maxConnectedClusters and need mesh-wide native CIDRs (D49, D72);
    peering bounds
    automatic cross-cluster pod/Service route policy; separate
    routed-fabric instances are hard trust-domain separation (D54/D60).
20. Host firewall is nftables-only; kube-proxy is off; Cilium
    `install-iptables-rules=true` for KPR/BPF masquerade through
    iptables-nft; VMs assert Cilium datapath rules and no legacy-iptables
    or kube-proxy rules (D55).
21. WireGuard MTU derives per link from the underlay minus WireGuard
    overhead with a 1280 floor; Cilium MTU = the minimum interface MTU
    (no VXLAN since D72); VMs assert path MTU
    (D51/D58). *(Implemented for WireGuard, `specs/netif.md` N17, round
    P3b-5: routed-fabric prefers netif's `pathMtu`, then the link
    `mtu`, minus 96, floor 1280. Eval test
    `test_netifPathMtuPreferred`; `<distro>-join-netif` asserts the
    adjacency MTU.)*
22. `clan.networkFacts` is versioned (schemaVersion 2), non-secret,
    deep-evaluable, and
    identical in meaning to the functional configuration and exports;
    clanServices has no nix-topology dependency, and unknown runtime state
    is never rendered as build-time fact (D57/D59).
23. k3s/rke2 consume ONLY the generic `node_transport` schemaVersion 2
    and never branch on provider service names; admin overrides cannot
    contradict the transport-derived datapath mode, protocol, devices,
    `directRoutingDevice`, MTU, or exposure capabilities (D58).
24. Exposure and convergence follow D63: BGP/BFD are interface/source
    scoped, WireGuard ports are reserved, policy/endpoint/AllowedIP/deploy
    collisions fail eval, forwarding-safe RA is used, and symmetric BFD/BGP
    profiles plus DelayOpen and a warning-only fabric route limit favor
    stability over speed. The fabric is no trust zone (R5).
25. A fabric link carries a packet only if its source is in the link's
    `sources` and its destination in its `destinations`; another link
    carries no fabric source and reaches no fabric address unless its
    owner declared it inside; a fabric destination never leaves by a
    link outside the fabric; only a spine relays between fabric links
    (D73, `hostile-fabric`).
26. On a cluster member with fabric links, a packet for the cluster's
    pod or Service CIDRs that arrives by a link that is not a fabric
    link, a pod link, loopback or a declared inside link is dropped
    and counted; the rke2 supervisor and its HAProxy front answer
    members only (D74, `<distro>-hostile`).

## 6. Subsystem contracts (condensed)

### 6.1 Ownership boundaries
Canonical repo = external-systems/clanServices. IfState exclusively owns
the static kernel network configuration rendered by these services (D61);
no second network manager is permitted. `netif` owns inventory-declared
links (multi-link, multi-instance), underlay policy routing, and static
host routes; `routed-fabric` owns the encrypted spine/leaf fabric,
per-adjacency WireGuard, fabric-specific policy routing, and one
integrated FRR configuration; thin distro services own
bootstrap/TLS-dir/join semantics and Cilium resources; shared lib
(`lib/kube-cluster/`) owns parity. Both services are ONE module,
`lib/kube-cluster/service.nix`, called with a distro record
(round 59, K13): the record holds only what differs (unit names,
supervisor port, add-ons, distro config keys, `services.<distro>`,
how the CA tree is seeded or synced). FRR/Zebra owns dynamic routes and
Cilium owns its datapath; the IfState ignore rules preserve those
ownership boundaries. The generic `node_transport` schemaVersion 2 is
declared OUTSIDE `lib/kube-cluster` as the neutral transport seam (D58).
Artifact flake = only packaging input and shared nixpkgs/flake-parts
authority (overlays, distro runtimes, committed manifests, per-system airgap
images, test fixtures); consumers lock immutable revisions and may replace
the transitive input. Supporting NixOS modules may implement platform-specific
association/tuning, never a parallel static data plane. Day-2 software is
pinned by operator GitOps repos, never here (D39). The shared neutral
`clan.networkFacts` schema belongs to clanServices; each producer owns its
leaves, while nix-topology, translation modules, icons, renderers, and
diagram packages belong to the consumer wrapper (D57).

### 6.2 Identity, CIDRs, topology, exports
Cluster name = instance name (≤32 chars, DNS-style). The instance name
is Cilium's `cluster-name`: at most 32 lower-case letters, digits and
`-`, starting and ending with a letter or digit (eval-asserted). `cilium.id`
nullable; default = stable hash of instance name → 1–127 (pure Nix, no
IFD); collisions are eval errors. Explicit 1–255 override requires
explicit v4 CIDRs above 127. Deployments predating hashed defaults must
pin current ids/CIDRs before upgrading. One resolved dual-stack CIDR
structure feeds distro, Cilium, DNS, pools, assertions, exports, and
`clan.networkFacts` (D57). An explicit CIDR family pair is set as a
whole (`podCIDRv4` with `podCIDRv6`, `serviceCIDRv4` with
`serviceCIDRv6`) or derived as a whole; the pod and service CIDRs never
overlap; the pod CIDRs are at least a /24 and a /64, the block Cilium's
pod pool hands each node (eval-asserted).
region/zone labels default to instance name and must be non-empty.
`kube_cluster` publishes schemaVersion 4 (revised datapath/exposure
facts per D58/D60 — no shims). It carries identity,
pod/service CIDRs,
clusterDNS, mesh group (default = fabric instance), control-domain role,
fabric source, per-member stable fabric endpoints/topology, pool
handoff (scope, delivery, blocks, selectors, owner), Cilium-side ASN,
advertisement facts, and API mirror facts.
`routed_fabric` (schemaVersion 2) publishes per-node ASN,
loopback/per-adjacency interface facts, leaf/spine topology, access, and
border-owned prefixes.
`node_transport` publishes the generic schemaVersion 2 transport view
(D58): stable dual-stack node addresses,
instance/endpoint identity,
every datapath interface keyed by Linux interface name with its MTU,
exactly one `directRoutingDevice`, `native.routeExchange =
local-router` (no datapath mode field: routing is always native, D72), the
exposure capabilities `internalLoadBalancer` and `nodePort`, `port`, and
nullable `endpoint`. No secrets in exports; every leaf has a
default (clan CLI deep-eval). `clan.networkFacts` presents the same
resolved facts per node for optional diagram consumers; it is not a
second configuration source (D57).
Inventory-wide assertions cover duplicate names/ids/CIDRs/ASNs/interface
names/transfer prefixes, overlapping CIDRs, duplicate NodePorts, missing
peers/labels/endpoints, adjacencies with no reachable endpoint on either
side, leaves with no reachable spine or invalid spine-role references,
HA profiles without two reachable spines, leaf-transit configurations,
multiple fabric memberships per
machine, node-in-two-clusters, second routing stacks, native-routing
CIDR containment, control-domain⇔fabric-instance consistency, netif
cross-instance conflicts (unique link ownership, default-route, DNS),
non-namespaced netif units, WG MTU below the derived floor, firewall
posture violations, overrides that set tunnel mode or contradict the
transport-derived devices/MTU/exposure, ClusterMesh groups with mixed
maxConnectedClusters, placement selectors
matching zero nodes, external exposure without a non-clan class+dnsName,
and internal exposure VIPs outside the fabric pool (D51/D53/D55/D58/
D60). Fleet checks read exports;
per-instance/per-machine checks stay in the services.

### 6.3 Host networking and routed WireGuard transport
`netif` is the inventory-facing link service: multi-link and
multi-instance — an instance = one site/segment with shared defaults and
per-machine/per-link overrides, and several netif instances may coexist
on one host (D53). It covers physical links, VLANs, bonds, bridges,
static/DHCP/RA addressing, prefixes, default/static routes, on-link
gateways, MTU, DNS, firewall trust, underlay policy routing, and
optional deploy-target export. Its `peer`/`netif` exports feed adjacency
endpoint selection automatically, with explicit per-adjacency overrides.
Static values may be interpolated from the consumer's `secrets`/
`not-secret` input; exports still contain no private keys.
Cross-instance assertions: a link is owned by exactly one instance;
default-route, DNS, policy-table, and effective rule-priority conflicts
between instances are eval errors; and every DHCP hook is
instance-namespaced (rule 5). All netif settings render through IfState
(D61), which applies address/link/route changes live. RA-enabled links use
`accept_ra = 2` on forwarding machines. A literal deploy target is rejected
when it matches any declared fabric or tunnel address.

`routed-fabric` is the only transport (D72; `wireguard-mesh` was
removed). Its `leaf`/`spine` symmetric graph is
implemented and VM-proven (D59). Every fabric machine gets stable dual-stack
host addresses on a fabric loopback/dummy interface from its public
`routed-fabric-<inst>-node4` and `-node6` vars (default pool `198.18.0.0/17`
plus the shared ULA's `:0::/64`; explicit pins win). For each fabric adjacency — every leaf↔spine attachment (every leaf
attaches every spine by default; a leaf may declare an explicit spine subset
via `settings.spines`) plus every unordered spine pair, adjacent automatically
— it renders exactly one point-to-point WG interface with a deterministic
≤15-character name, transfer prefixes and a UDP port read from the sorted
pair's shared public adjacency vars, one peer, and one UDP session; it never
renders one interface per remote machine (D51/D59/D64). Spines are declared
directly with `roles.spine.machines.<name>`; leaves use `roles.leaf`; there is
NO instance-level `settings.spines` and no mutual spine lists — the graph is
derived symmetrically (D59).
The canonical adjacency key remains
`<instance>:<sorted-endpoint-a>:<sorted-endpoint-b>`; the key names the shared
generator and hash-derived interface, while its transfer `/31` and `/127` come
from vars (default `198.19.0.0/16` and the shared ULA's `:1::/64`). Sorted
endpoint order selects the first or second transfer host. Explicit
per-adjacency port pins are the collision escape. Missing allocations,
adjacency/name/address collisions, and pool overlap are eval errors with
targeted remedies. The node keypair is instance-scoped clan vars; public keys
are public vars, private keys only deploy to their owner. Interface names,
FRR symbols, and per-adjacency link-local addresses remain hash-derived by
design (D64).

AllowedIPs carry the remote stable host addresses plus exactly the
prefixes that adjacency is authorized to transit — AllowedIPs is both
outbound cryptokey selection and the inbound source ACL. External-transit
adjacencies (`border`, D56) may include 0.0.0.0/0 and ::/0 as crypto ACL
without creating or accepting an IP default route. The same resolved
policy renders FRR filters, preventing cryptokey/routing drift. Internet
ingress through a border requires source-policy return routing through
the correct fabric egress — no asymmetric local-WAN reply.
Fabric-originated routes are stable /32+/128, and next-hop-self on spine
readvertisement keeps every next hop directly resolvable.
An adjacency needs at least one reachable endpoint; NAT/outbound-only
members omit endpoints and keepalive every 25 seconds; two NAT sites
never peer directly — they communicate through spines. Per-link WG MTU
derives from the underlay MTU minus WireGuard overhead (80 bytes v4 /
96 v6) with a 1280 floor; VMs assert path MTU. Endpoint reachability is
evaluated per adjacency; private endpoints are allowed when
actually reachable. One `routed-fabric` instance = one trust domain; one
machine has at most one membership and one topology role. Declared literal
endpoints on one adjacency must share an address family; hostname endpoints
are an eval error (round G11, R4). Source-return
tables have an explicit per-adjacency pin, avoid all kernel/Cilium owners
and netif/source-return collisions, and use independent unique rule
priorities below 32766. `settings.site` (default `null`) selects the default timer profile:
two ends that name the same site use `site` (BFD 300 ms x3), every
other pair uses `wan` (BFD 1000 ms x5 and BGP 10/30 seconds), and
`adjacencies.<remote>.timerProfile` overrides either. Upstreams use `wan`.
Both ends and upstreams use a five-second fixed DelayOpen hold-down;
upstream maximum-prefix limits restart after ten minutes, fabric and
Cilium limits only warn (round G11). Fabric sessions use BGP graceful
restart (60 s) for a bgpd restart, with BFD as the authority on a dead
peer (round 57); a restart of all of FRR may look like a dead node (a
race, round G11). No-op reloads preserve
peer uptimes and the immediate RIB (D63).

```nix
inventory.instances = {
  home-net = {  # netif instance: role-wide site defaults + per-machine links
    module.input = "clanServices";
    module.name = "netif";
    roles.default.settings = {  # site-wide defaults (every machine/link)
      mtu = 1500;
    };
    roles.default.machines.kamrui-h1.settings = {
      targetHost = true;
      links.wifi = {
        interface = "wlp2s0";
        dhcp.ipv4 = true;  # inherits the site mtu default
      };
    };
  };
  lab-net = {  # second netif instance on the SAME host: separate site/segment
    module.input = "clanServices";
    module.name = "netif";
    roles.default.settings = {
      mtu = 9000;  # segment-wide default
    };
    roles.default.machines.kamrui-h1.settings.links.lab = {
      interface = "enp3s0";
      static.ipv4 = [ "192.0.2.10/24" ];
      # No default gateway here: home-net's DHCP link owns the host default.
      routes = [ { destination = "192.0.2.0/24"; gateway = "192.0.2.1"; } ];
    };
  };
  fleet = {  # leaf/spine shape (D59)
    module.input = "clanServices";
    module.name = "routed-fabric";  # leaf/spine + access + border
    roles = {
      spine.machines = {
        # Spine topology and external-border policy are independent.
        edge-1.settings.border.ownedPrefixes = [
          "203.0.113.0/24"
          "2001:db8:100::/48"
        ];
        edge-2 = { };  # second spine = the HA profile; no border
        # edge-1↔edge-2 adjacency is automatic (every spine pair is).
      };
      leaf.machines = {
        helsinki-manager-1 = { };  # default: attaches every spine
        kamrui-h1.settings = {
          spines = [ "edge-1" "edge-2" ];  # explicit subset; default = all
          access = "admin";
          endpointSources = [
            { service = "netif"; instance = "home-net"; }
          ];
        };
      };
    };
  };
  spoke = {
    module.input = "clanServices";
    module.name = "k3s";
    roles.server.machines.kamrui-h1.settings.network.fabric = {
      service = "routed-fabric";
      instance = "fleet";
    };
  };
};
```

All actual static addresses/routes live in inventory settings, not
supporting NixOS modules. Cilium MTU = the minimum interface MTU
(D58; no tunnel mode since D72).

### 6.4 Cilium base
Same canonical upstream Cilium 1.20+ chart/images both distros; RKE2
bundled Cilium disabled. Always: KPR, multi-pool pod IPAM (default;
derived non-clashing dual-stack CIDRs), BPF masquerade+tproxy, Maglev,
pmtu, Node IPAM (D41), kube-proxy off, `install-iptables-rules=true`
(D55). Routing is always native (D72): `routing-mode: native`, no
tunnel, `auto-direct-node-routes: false`; an override to tunnel mode is
an eval error. Devices, `directRoutingDevice`, and MTU derive from
`node_transport` (D58) and admin overrides cannot contradict them; dual-stack
native-routing CIDRs cover all pod CIDRs in the mesh trust domain
(default `10.0.0.0/8` + `fd10::/16` for derived space; explicit overrides
must contain every explicit pod CIDR). Cilium device configuration covers
every fabric WG interface (one per adjacency, D51/D59). Cilium
advertises local `CiliumPodIPPool`
allocations and authorized Service routes to local FRR over the
`local-router` exchange; FRR/Zebra owns remote routes. Native ClusterMesh
requires non-overlap, node InternalIP connectivity, and working
cross-cluster pod routes (D60).
Local Cilium↔FRR peering is ONE `::1` session carrying both address
families; advertisement selectors and the `CiliumPodIPPool` type are
pinned; explicit `extended-nexthop` capability and v4-over-v6 /
v6-over-v4 next-hop behavior must be probed before the renderer locks,
and the Cilium GR posture (timers, restart behavior, capability
fallback) is explicit enough for tests (D55). Per-cluster variation lands
in `cilium-config` and CRs through kubenix merging over the committed
base manifest (D26). Admin helm-values
overrides remain limited to layer-2-expressible keys and are post-merge
validated against the native-routing/no-contradiction/IPAM/
dual-stack/device/CNI/artifact/ETP invariants. Multus follows D42.
Lifecycle: bootstrap bundle
apply → GitOps adoption (D40); publish-freshness gated in CI.

### 6.5 ClusterMesh (full peering default, selective peers supported)
Mesh groups default from the fabric instance: the clusters under one
`routed-fabric` instance form one mesh group (no repeated value
required; a different fabric instance — or explicit opt-out — separates
trust and bounds control domains, D43). Separate `routed-fabric`
instances are HARD trust-domain separation: no mesh, no routes, no DNS
across them. Three distinct graphs: the **underlay graph** (netif
links), the **fabric graph** (routed-fabric adjacencies), and the
**ClusterMesh graph** (peering edges) — similar shapes, independent
edges (D54). Every eligible cluster runs clustermesh-apiserver + mesh
certs from first boot; singleton peer list empty. Default peering is
FULL among the fabric instance's clusters; explicit symmetric selective
peers are supported — a central cluster may peer A↔B and B↔C while A
and C do not peer; peering state is non-transitive, and selective peers
also bound the automatic cross-cluster pod/Service route policy rendered
into fabric filters (a routed-only exception between non-peered
clusters must be deliberate and eval-visible). Peering rendered from
exports into `clustermesh.config.clusters` — no CLI. Group uniformity
(D60): identical maxConnectedClusters in every member (routing is
always native, D72). Placement: `voters` (default —
server nodes), `workers` (agent nodes), `all`, or `labels`
(clan-declared/generated labels only; zero matches = eval error).
Exposure (D60): `auto` (default) | internal-load-balancer | node-port |
external-load-balancer`. `auto` = internal-load-balancer when the
transport exposes that capability, else node-port; unsupported or
no-method selections are eval errors. `internal-load-balancer`
(clustermesh-apiserver ONLY — mirror Services get a separate, future
allocation and must NOT share offset 79, D30) pins
ONE IPv4-only literal VIP at the D10-locked host offset 79 / 0x79 —
`172.16.<id>.79` — drawn from the `<instance>-fabric`
private pool's IPv4 block
by explicit `lbipam.cilium.io/ips` projection,
class `io.cilium/bgp-control-plane`; the VIP is asserted pool-contained
and collision-checked against every other pinned clan VIP; remote peers
consume the
VIP (no DNS needed); control-plane exposure is IPv4-only on the
validated Cilium 1.20.3 profile (the pinned chart's
clustermesh-apiserver etcd listens on `https://0.0.0.0:2379` with no
dual-stack listener knob) — NO ClusterMesh IPv6 VIP, NO
`RequireDualStack` advertisement, data plane stays dual-stack;
independent replica count — default
min(3, eligible), user positive ≤ eligible, required anti-affinity, no
per-node remote endpoints, rolling update maxSurge=0 / maxUnavailable=1.
`node-port` has NO replica knob: replicas = selected node count,
required hostname anti-affinity + nodeSelector (one pod per selected
node), all selected nodes' stable IPv4 addresses advertised; the NodePort
defaults to 32379 with an optional explicit port override,
collision-checked per machine. `external-load-balancer` always wins on
every overlay: explicit non-clan `loadBalancerClass` + `dnsName` (DNS
ONLY, no literal IP), provider annotations allowed (external-dns is
day-2), no internal capability needed, DNS name in peers and cert SANs,
resolution (a runtime A record) a prerequisite. ETP Local on every method: mTLS
identity does not depend on source IP, but Local preserves the source,
avoids a second hop, supports ClientIP affinity, and enables
internal-LB withdrawal. DNS fan-in: selectorless local ClusterIP Service
+ eval-rendered EndpointSlice per remote cluster — the same pattern,
generalized, carries the kube-apiserver mirror Services (D30; mandatory
for spokes). Shared `rancher-clustermesh-ca-<group>` vars generator
(share=true); per-cluster dependent cert generators; SANs include every
published IPv4/DNS endpoint + fan-in name + external dnsName — never an
unreachable IPv6 endpoint; endpoint set is a
public validation
input (membership change ⇒ reissue before advertise). CA/cert material
never in exports/helm/store. Global Services opt-in per Service (mirror
Services are clan-rendered globals, D30). MCS-API reserved. Rotation =
separate two-phase CA-bundle design; blind regeneration unsupported.

### 6.6 HAProxy kubeapi HA (bootstrap contract)
Every node runs clan-rendered HAProxy, load-balancing that cluster's
server API endpoints. Its fronts bind loopback only (`127.0.0.1`,
`::1`; D76) and the kubeapi FQDN resolves there through `/etc/hosts`,
so the kubelet, the distro's join and Cilium (host-network pods read the
node's `/etc/hosts`) use the local front; no other host and no pod
reaches it. The backends are every server's node address, rendered from
exports, each with `source` set to this node's fabric address, and
health-checked with the per-node health-check client certificate
(`mkHaproxyGenerator`). Join URL and agent kubeconfigs point at it:
server loss never strands nodes. Ports derive deterministically from
`cilium.id` (7442+id, +1000 for the rke2 supervisor front on a server).
An rke2 agent's supervisor front listens on 9345, the supervisor's own
port: the agent's tunnel (`kubectl logs`, `exec`) dials every server on
the port of its join URL, and 9345 is the server row of §6.12. haproxy
is ordered after `ifstate.service`; loopback always exists, so it starts
without the fabric and a backend is DOWN until the fabric carries the
node's address. This is control-plane HA — unrelated to the revoked D5
edge-proxy. The health check verifies the serving chain and that the
certificate names the kubeapi FQDN (`verifyhost`). The stats page is
read-only and listens on loopback only (`127.0.0.1`/`::1`, port 8404),
so it has no password; `/run/haproxy/haproxy.sock` stays the admin path.

### 6.7 Pools, LB, BGP, FRR
Per D8/D9/D10/D19/D41. Node IPAM serves classless Services with node IPs
(no pools/BGP) — fabric-scoped; public exposure uses explicit pools
(D41/D52). Every explicit pool draw uses
`io.cilium/bgp-control-plane`; Cilium allocates through LB IPAM but only
`node-bgp` and `shared-bgp` pools are selected for announcement. Pool
updates may reassign IPs and are reviewed changes.

| Delivery | Scope | Advertiser / failure semantics |
| --- | --- | --- |
| `node-fate-bound` | per-machine | Provider/static delivery; no BGP; follows owner |
| `node-bgp` | per-machine | Only owner advertises exact VIPs; no cross-node ECMP |
| `shared-bgp` | cluster-global | Every healthy eligible node advertises; FRR/upstream ECMP |
| `floating` | cluster-global | Runtime controller moves one address; blackhole window without it |
| `external-class` | cluster-global | Cloud CCM owns delivery |

`node-bgp` is the contract for node-owned public IPv4 extras and
carve-outs of a node's routed IPv6 subnet — only where BGP delivery
actually exists; provider-static node-bound extras remain
node-fate-bound (D8). Hetzner/provider-MAC KubeVirt attachment is netif
host-bridge plumbing, NOT a Cilium pool or BGP delivery; KubeVirt stays
day-2 (D52/D55). Per-node BGP resources select
only that owner's pool. ETP Local withdraws when no eligible local
backend exists; consumers that require the address must keep eligible
backends on the owner. Other nodes must not re-advertise the route as if
shared. `shared-bgp` is the contract for private fabric VIPs and
upstream-router pools; all healthy eligible nodes originate the same
/32+/128 and FRR uses `maximum-paths` plus multipath-relax to retain
interfaces as ECMP members.

Local Cilium advertisements terminate on node-local FRR. FRR accepts only
owned node-bgp/shared-bgp VIPs, local multi-pool allocations, and
authorized ClusterIPs, then exports according to the receiving machine's
`access` (D33/D56) and the adjacency policy (D51). Zebra installs remote
routes on Kubernetes and fleet hosts alike; Cilium's local endpoint
routes remain more specific. FRR next-hop rewriting resolves each path
through its per-adjacency interface. Foreign upstreams are configured
only under `border`, with strict prefix and maximum-prefix policy (in:
`acceptedPrefixes`, nothing by default; out: `ownedPrefixes`), optional
GTSM and optional proxy-NDP for on-LAN prefixes.

### 6.8 Day-2 proxy layer (out of contract)
No Gateway API, Ingress, or proxy implementation is clan-rendered
(revoked D2/D6/D7/D15/D17). The day-2 guide carries the Envoy Gateway
recipe: DaemonSet-mode EnvoyProxy on labeled workers, ETP Local (safe
with Node IPAM — real EndpointSlices, D41),
`loadBalancerClass: io.cilium/bgp-control-plane` + pool-label selectors or
explicit `lbipam.cilium.io/ips` projections for every explicit pool draw.
BGP advertisements still select only `node-bgp` and `shared-bgp` pools —
one proxy
implementation per IP:port, QUIC-passthrough on its own VIP. The
contract guarantees the substrate (pools, BGP, firewall); the proxy
is GitOps-owned.

### 6.9 Secrets / PKI / airgap
One plane (D35 revised). Clan vars: cluster CAs, join tokens, admin +
read-only kubeconfigs (D38), ClusterMesh CA/certs, HAProxy health-check
material, `gitops-hub` identities (D43). A machine holds only what its
role reads (round G11): the agent token and the HAProxy health-check
certificate on every node; the server token, the admin kubeconfig and
(rke2) the PKI on servers; the PKI seed on the k3s `clusterInit` server;
the ClusterMesh CA generator and leaf set on the `clusterInit` server
only, whose secrets oneshot is their one reader. An agent never holds
the server token, which joins the control plane. Secrets are encrypted
at rest in etcd on both distros (rke2 by default, k3s
`secrets-encryption: true`). Everything else — Sealed
Secrets keys included — is day-2 GitOps custody. Public certs readable
as public values; private material referenced by deployed paths only.
RKE2 PKI sync non-destructive: it installs the vars CAs before a
server's first start only; a later, different set is staged in
`<tls>-staged` for `rke2 certificate rotate-ca`, never copied into the
live TLS dir (round G11, K10: a copied set makes the next start fatal,
"newer than datastore"); k3s init-only seed + native replication.
Airgap-ready default; one explicit opt-out switch; overrides = complete
replacement sets or additive lists.

### 6.10 Rotation and imperative lifecycle
Leaf certs: upstream 365-day, renew at startup; manual via
`{rke2,k3s} certificate rotate` (kubeadm: `kubeadm certs renew`). CA
rotation: staged dir + `rotate-ca`; same-root can be non-disruptive; new
root disruptive (tokens, kubeconfigs, restarts). Service-account signing
key: append/retain. Client-identity certs (`gitops-hub` D43, read-only
D38, and the admin kubeconfig, a `system:masters` identity): 365-day,
regenerate via vars (+ secret-sync where one exists), clusters untouched
(same CA). The admin kubeconfig: the owner runs `clan vars generate
--regenerate --generator rancher-admin-kubeconfig-<instance>` on a branch
and deploys the servers (round G11, K10). The HAProxy health-check
certificate, the ClusterMesh leaves and the CAs keep long lives (3650
days, CAs 3700/7300): each sits on every node or peer and expires there
on one day, so a short life is an outage of its own. Every serial is
random. Cert bootstrap/rotation runbooks + scripts ship in
documentation. No blanket 100-year leaf default. Inventory deletion ≠
cluster GC: cordon/drain, Node deletion, etcd member removal, mesh
cleanup, hub kubeconfig/CRB removal = documented runbooks. Disruptive
changes (pools, CIDRs, ids, CA roots, mesh membership) = reviewed
operational changes.

The first-server guard (round G11): a `clusterInit` server whose etcd
directory is missing never starts a second cluster beside a live one.
Unit `<distro>-<instance>-init-guard` runs before the server, after
`network-online.target`, `ifstate.service` and `frr.service` (the peers
are fabric addresses). It dials every other server's API port: a
connection means a cluster is alive and the guard refuses; "connection
refused" from every peer means no cluster and the server starts;
anything else (a timeout, no route) is unknown, and the guard keeps
trying for 300 s, then refuses. It fails closed. The operator who knows
no cluster is alive (the first install of an HA cluster whose other
servers are not up yet, a cluster rebuilt from scratch) creates
`/var/lib/rancher/<distro>/server/allow-new-cluster-<instance>` and
restarts the server; the guard deletes the file when it lets the server
start. Suite `<distro>-ha`.

### 6.11 CCM, managed manifests, GitOps
`cloudController = none | rancher | external`; provider CCMs never
bundled, deployed day-2; hermetic fake-CCM VM test. Every clan-rendered
manifest labeled (managed-by, instance, component, config-hash; never in
selectors). Rendering = kubenix (D26); delivery = bootstrap bundle SSA
on boot and on every deploy that changes it, pruning only its own
labelled objects (D40); Rancher helm-controller disabled by default (D42). Day-2
GitOps owns all lifecycle post-bootstrap; base upgrades preserve
operator CRDs.

### 6.12 Assertions and firewall
*Status (round 21): D63 exposure, policy, endpoint, mesh, RA, deploy-target,
and timer invariants are eval-enforced. The leaf-transit, asymmetric
source/return, HA-profile and duplicate-ASN rejections below remain planned;
see the later hardening phases.*

Eval rejects: multiple bootstraps; exactly two servers (etcd needs both
for quorum: worse than one; an even count above two warns; to replace a
dead server of three, add the new one and remove the old in one commit);
an instance
name that is no Cilium cluster name; half-explicit CIDR pairs,
overlapping pod and service CIDRs, and pod CIDRs smaller than the per-node
/24 and /64; `configOverrides` keys the service renders, or a token
(`token`, `agent-token` and their `-file` keys, `server`, `cluster-init`,
the CIDRs, `cluster-dns`, `node-ip`: an override would replace them
silently, and a token would land in the Nix store);
duplicate ids/CIDRs/ports/ASNs/
interface names/transfer prefixes; missing dual-stack or topology facts;
pool overlap; scope⇒mode violations; floating without candidates;
`node-bgp` without exactly one owner, with non-local advertisers, or
where no BGP delivery exists; BGP pools without `bgp.enable` or BGP
without any `node-bgp`/`shared-bgp` pool; fabric blocks too small — the
fabric IPv4 block MUST contain host offset 79 (at least 128 addresses;
the default /24 satisfies this; the old offset-53 / 64-address rule is
retired); BGP pools outside border-owned prefixes; node-in-two-clusters; multiple
fabric memberships or routing stacks per host; adjacencies with no
reachable endpoint on either side or with mismatched literal address
families; leaves with no reachable spine or spines not declared with the
spine role; HA profiles without two reachable spines;
leaf-transit configurations (a non-border leaf readvertising fabric
routes); default-route/AllowedIP leaks — a
0.0.0.0/0 or ::/0 crypto ACL must not create or accept an IP default
route; asymmetric Internet source/return paths; WG MTU below the derived
floor; source-return kernel/Cilium/netif/source-return table collisions or
rule priorities at/above 32766 and any netif/fabric priority collisions;
netif cross-instance conflicts (link ownership, default-route, DNS, policy
tables, effective rule priorities) and non-namespaced netif units;
any same-host WireGuard listen-port clashes;
non-literal upstream peers; final literal overlay deploy targets;
conflicting adjacency timer overrides;
missing native CIDR containment;
tunnel mode (any `routingMode` but native, any `tunnelProtocol`), or
`auto-direct-node-routes` in the canonical profile;
Cilium devices missing WG links; ETP Cluster on clan-rendered external
Services; base-manifest drift; IFD smuggling; unsupported k8s minor
without acknowledgment; application-secret vars; control-domain
violations; spoke without mirror/SAN; servicelb; distro-manifests-dir
delivery; kube-proxy enabled or `install-iptables-rules=false` in the
canonical profile. The read-only ClusterRole never contains `secrets`
or write verbs (D38). Firewall: nftables-only — Cilium's required
KPR/BPF-masquerade rules use iptables-nft; legacy iptables and
kube-proxy rules are forbidden (D55); API on transport only; the
cluster ports by source, from one matrix (D76,
`lib/kube-cluster/firewall.nix`): the API (6443) on servers from the
members' node addresses and the cluster's pod CIDRs; the rke2
supervisor (9345) on servers from the members; the kubelet (10250) on
every node from the servers (and the pod CIDRs only with
`firewall.kubeletFromPods`); Cilium's health port (4240) on every node
from the members; etcd (2379, 2380) on servers from the servers. The
HAProxy fronts and etcd's metrics port (2381) listen on loopback and
have no row. Every rule also needs a fabric link or a local pod link
(`lxc*`, `cilium*`). The cluster's
pod and Service CIDRs are reached only over the fabric links, the pod
links, loopback and declared inside links (`inet kube-<instance>`,
D74). The cluster services never
trust a link: neither a fabric link (routed-fabric has no option to
trust one, D75) nor Cilium's host links (D76), and never
accept everything from a pod: a pod is a source like any other. Public
ports only where exposed; WireGuard only on configured underlays;
By-source rules hold against leaves and outsiders only: a spine
forwards for everyone and can forge a member source; against a spine,
TLS, tokens and mTLS hold. BGP/BFD only from a fabric link's peer address to this end's address on
that link (D73) and from declared upstream peers, never globally (D63); mirror Services restricted to GitOps
namespaces. VMs assert positive AND negative exposure, the nft backend,
Cilium datapath rules, and no kube-proxy rules.

### 6.13 routed-fabric service
Per D11/D13/D19/D22/D33/D47/D48/D51/D52/D53/D56/D59. Two topology roles,
no
default role: `leaf` = stable loopback addressing, one WG interface
per spine attachment, FRR/BFD/Zebra, automatic pod routes on native
transports when
also a Kubernetes node (D58), and no transit; `spine` adds forwarding
and
readvertisement. Per-machine `access` defaults to `member` (membership,
not topology); `client`
adds fabric-pool LoadBalancer-VIP routes only (never pods or ClusterIPs);
`admin` adds D13 pod/ClusterIP route consumption; Kubernetes nodes on
native transports
install remote pod-pool blocks and advertised VIPs regardless of
`access` (native-routing requirement, D49). Member-facing DNS zones,
any private DNS service, and any private CoreDNS VIP are NOT rendered
in the MVP (D22 day-2).
Optional `border` adds upstream peers, owned-prefix filtering,
forwarding, optional NDP, and authorized external/fabric transit — NOT
automatic admin DNS. Leaves attach every spine by default and may
declare an explicit spine subset; spine pairs are adjacent
automatically (symmetric derivation, D59); spines are
directly declared and may independently have any access or border
configuration. Kubernetes managers are not spines by default. Active-active
spine HA is fabric ECMP — every leaf links both spines with eBGP/BFD and
FRR `maximum-paths` + multipath-relax; no shared gateway VIP, no VRRP;
two spines are the HA profile with no arbitrary maximum.
Upstream active-active requires upstream ECMP; transparent active-active
default gateway for ordinary non-fabric LAN clients is outside MVP.
Node duality uses the same FRR, never a second stack. Members get
routes only — their name resolution is a day-2 concern (external-dns-
style automation), never a fabric render.

The guard (D73, round 62): every member with an adjacency renders
`inet routed-fabric-<instance>` from the link contracts. A spine refuses
a destination it sends a leaf no route for (`access` on the spine), a
leaf's forged source, an outsider's packet to a fabric address or with a
fabric source, and relaying by a leaf; a fabric destination never leaves
by the underlay. Pods on a kube node are guarded by kube (L1). FRR does
not start without the table, and the fabric's pools are `unreachable`
until BGP or a link says otherwise (D75): a withdrawn route fails closed.
Fabric links take no redirect, source route or router advertisement,
members answer ARP only for a link's own addresses, and a `node-bgp`
pool enters the fabric from its owner only. A spine can forge member sources (L3), so
by-source rules above the fabric protect against leaves and outsiders
only; against a rooted spine only TLS, tokens and mTLS help.

Acceptance (target; round 20 status: the NAT-site, Internet source/return,
border-filter and route-filter-negative items are not yet VM-proven, see
the hardening plan, phase 6): eval proves deterministic names, committed
loopback/ASN/port/transfer allocations, explicit overrides, missing-var and
duplicate/pool negatives (D64), adjacency/AllowedIP/filter equivalence,
self-exclusion, topology/access/
border checks, spine references and reachability (every leaf reaches ≥1
spine; HA = 2, no arbitrary maximum), symmetric graph derivation, and
export/facts defaults. Hermetic VMs prove
real WG handshakes per adjacency, FRR sessions and BFD on both sides,
RIB-to-FIB installation, spine readvertise with next-hop-self and leaf
no-transit, two NAT sites communicating through spines, Internet ingress
source/return path, native pod round trips, client VIP ECMP, admin
svc/pod/ClusterIP route access to local and foreign clusters, no
member-facing cluster DNS in the MVP (day-2 external-dns concern),
client pod-route isolation, selective isolation, node-bgp
owner-only and shared-bgp
ECMP withdrawal, border filtering, border-not-spine without automatic
admin DNS, composable admin-border, spine active-active + single-spine
failure/restore with FRR reload/restart keeping RIB/FIB stable,
NAT membership, MTU floor/path MTU, no legacy-iptables or kube-proxy rules,
and the kamrui-h1 dual-shape with local Cilium behavior intact.

### 6.14 Control domain (D43)
Per-cluster `controlDomain.role`: **standalone** (default) — shares no
kubeconfig with any cluster; **hub** — holds `gitops-spoke-<spoke>`
namespaces with per-spoke `kubeconfig` + `kubeconfig-readonly` Secrets
(secret-sync from vars), NetworkPolicy; **spoke** — exports its API via
a mirror Service (D30), renders CRB `gitops-hub` + optional tenant
impersonation SAs, accepts reconciliation from its group's hub. All
spoke-bound day-2 objects carry the tool's remote-kubeconfig mechanism
(Flux `kubeConfig.secretRef`, Argo cluster secrets) — wired by the
operator, documented in the day-2 guide. Standalone clusters may still
join the mesh and consume/export mirror Services — mesh ≠ control
domain. Singleton standalone = no hub config. **Naming note (rounds
16–17):**
control-domain hub/spoke (this section, D43) is a GitOps-control
concept; fabric spine/leaf (§6.3, D51/D56/D59) is a packet-transit
concept.
A cluster may be either, both, or neither; only `roles.spine` makes a
fabric transit spine.

### 6.15 Network facts and diagrams (D57)
`clan.networkFacts` is a neutral NixOS-option interface, not a
nix-topology interface. Its versioned (schemaVersion 2, D59) schema and
read-only leaf options
are declared by clanServices without any diagram dependency. The service
that owns a fact populates it from the same resolved configuration used
for its functional NixOS settings and exports; consumers only read it.
Every leaf has a safe default for deep evaluation. The facts preserve
separate underlay, fabric, ClusterMesh, and control-domain graphs rather
than flattening them into one misleading edge set.

`netif` publishes declared networks, links, interface kinds, addressing
modes and known addresses, gateways, routes, MTU, and attachments.
`routed-fabric` publishes leaf/spine/access/border, stable loopbacks,
per-adjacency WireGuard interfaces, transfer prefixes, public endpoints,
MTU, ASNs, upstreams, and authorized public prefixes. (The
`mesh.<instance>` facts of `wireguard-mesh` went with it, D72.) Distro
services
publish cluster identity, distro, node membership, pod/Service CIDRs,
pools, mesh peers, and control-domain relationships. Nothing in the
schema admits secret material.

Two facts cross service boundaries as contracts (round-61 target
design, `specs/target-design.md` §3): `fabricInside` (links, beside a
fabric's own, whose hosts may reach fabric and pod addresses through
the machine; set by the CLAT and NAT64 links and by a router zone with
`fabric = true`; read by routed-fabric's and kube's guards, D73, D74)
and `forwardLinks` (links between which the machine forwards IPv6 by
its owner's rules; set by k3s and rke2, routed-fabric and the router;
read by the CLAT host's table `inet clat`, round 65). A setter writes
`clan._networkFacts.<fact>`; readers use `clan.networkFacts.<fact>`.

A consumer-owned nix-topology wrapper imports its own NixOS module and
translates these facts into `topology.networks`, `topology.nodes`,
interface addresses/network assignments/connections, and service details.
It may use nix-topology's automatic extraction as a supplement, but the
clan facts are authoritative for clan-owned configuration. Flake-parts
integration can expose `topology.<system>.config.output`; assigning that
derivation to `packages.<name>` yields an ordinary `nix build
.#<name>` artifact. Multiple clans or synthetic inventories can be
rendered as separate topology evaluations and packages. Diagram builds
do not boot VMs and do not query live machines.

The completeness guarantee is deliberately bounded: every build-time-
declared network fact must be represented faithfully. DHCP/RA addresses
not known until runtime, BGP-learned routes, WireGuard handshakes,
reachability, health, and failover state are not claimed as known.
Rendering must show the declared dynamic mode or unknown state instead
of inventing addresses or runtime edges.

## 7. Testing contract (D44)

**Current phase: best design first (round 61, H1).** Until the owner
freezes the design for the 0.1.x release, the suites and nix-unit tests
prove behaviour; they are not regression protection. A better design
may change or remove any suite, fixture, counter name or rendered
string. The spec is amended first, then the design is built, then the
suites prove its behaviour. What stays fixed is the safety behaviour: a
check is replaced only by an equal or stronger behaviour check, and a
hostile-actor suite (an attacker VM that scans, spoofs and hijacks; it
collects every verdict and fails at the end) is extended, never
weakened. Checks that pin a mechanism are free to rewrite.

Seams: pure renderer nix-unit tests (kubenix render determinism
included); throwaway clans via `clanLib.clan` (inventory boundary);
`clanTests` hermetic VM suites exposed only through
`legacyPackages.<system>.vmTests` (sandboxed authoritative, side by side
only within `vmTests.parallel`; never `checks`, D66); artifact source/hash/render gates (incl.
committed-manifest inflation proofs and publish-freshness checks,
D26/D40). Standard internal HTTP test workload: **go-httpbin** (pinned,
airgap-carried as a test-fixture artifact). Rules: hermetic/offline;
committed-var or fixture-pinned eval-deterministic addresses; VM allocations
are freshly generated, printed for diagnosis, and asserted through network
facts in the routed-fabric suites; dual-stack asserted in
every boot test; round-trips + failure behavior (BGP withdrawal keeps VIP via
healthy nodes); negative assertions; operational postconditions; fail fast.
Minimal airgapped artifacts for hermetic VM tests is a hard requirement.
A suite passes when its sandboxed build exits 0 (`vm-test <suite>
--remote`, or `PASS`/`PASS(!)` in a `vm-test --all --remote --rebuild`
run; `CACHED` booted nothing and proves nothing new); the build log is
`.vm-tests/<suite>/build.log` and the run summary (subtests, `!!!`
failures, first build errors) is `.vm-tests/<suite>/summary.txt`. Test
scripts group their steps in `with subtest(...)` phases, and pipelines in
them read whole streams (`grep PAT >/dev/null`, never `grep -q`). Every suite
still prints a final `<SUITE>_OK` marker (suite name upper-cased, `-` →
`_`) as the last statement of its `testScript`, after every assertion, and
intermediate markers remain. They help a reader follow the log, but the
runner does not check them (D66). A *VM-proven* status names the suite and
its marker.

Eval tests commit readable public allocation fixtures under
`services/<svc>/tests/fixtures/vars/{per-machine,shared}` and never recompute
hash-derived expectations. Positive and negative tests cover every D64
collision class and explicit overrides. The locked clan-core `clanTest`
harness executes VM generators through its Nix vars executor, encrypts test
secrets with its fixed test recipient, and merges generated `vars/` and
`secrets/` into a temporary directory used by `getPublicValue`. It replaces
the suite's source `vars/` tree, so these VM suites need no committed
allocation files, legacy public-key fixtures, or separate `update-vars` run.
Routed-fabric prints the fresh allocations and proves them with
`ROUTED_FABRIC_ALLOCATED_OK`.

Current registered VM suites:
- **single/join/HA per distro** on `routed-fabric` (D72; `single` is a
  lone spine, `join` a spine and a leaf, `ha` two spines and a leaf):
  bootstrap, local HAProxy, node readiness, Cilium health, Service/DNS,
  etcd quorum and failure behavior; `ha` also proves the fabric routes
  around a dead spine (D58).
- **FRR failure** (`k3s-frr-failure`, D72's accepted cost): on the
  `k3s-join` cluster, bgpd SIGKILL on the spine is restarted by
  watchfrr and sessions, pod routes and pod traffic recover; a
  configuration FRR rejects is refused at reload and leaves FRR, its
  running config and the sessions as they were. The switch still exits
  0 (upstream fact), so every `routed-fabric` machine checks its
  rendered `frr.conf` with `vtysh --dryrun` at build time
  (`lib/frr-check.nix`, `checks.frr-conf`): a rejected line fails the
  build, not the deploy.
- **netif**: multi-NIC physical/VLAN/bond/bridge links, multi-instance
  ownership, static/DHCP/RA addressing, on-link/policy routes, exports,
  and conflict negatives. Live static reconfiguration is applied, checked,
  and restored without reboot. The DHCP/RA suite proves a real lease,
  default routes, one persistent client across reapply, and clean
  `ifstatecli check` convergence (D61).
- **routed-fabric transport/FRR**: two spines + leaves with derived
  adjacencies (D59), one IfState-owned WG interface per pair, real
  handshakes, no `(none)` AllowedIPs, FRR/BFD, RIB-vs-kernel FIB,
  next-hop-self, spine readvertise/leaf no-transit, MTU, and spine HA
  failure/restore, on one flat underlay where every node has an endpoint.
  *Planned (not yet VM-proven):* NAT/outbound-only keepalive,
  external-transit crypto ACL without an IP default route, Internet
  source/return path, and route-filter/default-route negatives (hardening
  plan, phase 6).
- artifact matrix (3-minor version pins eval, D34);
- **native data-plane suite per distro** on `routed-fabric`: native
  pod-to-pod without VXLAN, multi-pool remote routes, pool allocation,
  classless Node IPAM (fabric-scoped), ETP-Local candidate restriction,
  node-bgp owner-only advertisement and withdrawal, shared-bgp dual-stack
  ECMP and single-path withdrawal (including Linux `ip -j` single-path
  shape), floating-pool blackhole window, firewall positive/negative
  exposure, iptables-nft Cilium rules plus NO legacy-iptables or
  kube-proxy rules, and dual-AF local Cilium↔FRR;
- **fabric/BGP HA**: two spines active-active ECMP + single-spine
  failure/restore with FRR reload/restart keeping RIB/FIB stable (D59),
  private fabric, upstream ECMP, border-not-transit-role, MikroTik-style
  FRR foreign-router fixture, upstream border pools and node-owned IPv6
  pools;
- **selective ClusterMesh suite**: full-peering default, explicit
  selective peers (A↔B, B↔C) with A/C selective isolation on non-transit
  leaves; the dedicated spine's union-of-leaf-consumers carriage is the
  deliberate routed-only exception. k3s and RKE2 are VM-proven on the
  native profile (the tunnel twins were removed by D72): selective edges synchronize only their
  intended global-Service backends, native A/C leaves install no routes for
  each other (dual-stack /24 + /64 allocation assertions), and the full-peering
  defaults remain green. Final selective evidence:
  `.baton-pass/vm-logs/ifstate-k3s-clustermesh-selective-final.log`,
  and `.baton-pass/vm-logs/ifstate-rke2-clustermesh-selective-final.log`;
  full-default regression evidence:
  `.baton-pass/vm-logs/ifstate-k3s-clustermesh-final.log`,
  and `.baton-pass/vm-logs/ifstate-rke2-clustermesh-final.log`;
- **ClusterMesh suites**: native
  internal-load-balancer exposure (D10-locked offset-79 IPv4 VIP +
  `lbipam.cilium.io/ips` projection +
  `io.cilium/bgp-control-plane` class + SANs covering published IPv4/DNS
  endpoints only + pool membership/
  collision checks; NO ClusterMesh IPv6 VIP and NO `RequireDualStack`
  advertisement — control-plane exposure is IPv4-only on the pinned
  Cilium 1.20.3 profile). NodePort exposure (replicas = selected
  nodes, one pod per selected node, NodePort default 32379 with
  optional explicit override, selected nodes' stable IPv4 addresses
  published) is VM-proven by `<distro>-clustermesh-nodeport`
  (`<DISTRO>_CLUSTERMESH_NODEPORT_OK`; ported from the removed
  `-clustermesh-tunnel` by D72, with `mesh.exposure = "node-port"` set
  explicitly because `auto` picks the internal LB on the fabric).
  External class+DNS exposure
  (non-clan class + dnsName in peers/SANs, runtime A record); placement
  voters/workers/all/labels with zero-match negatives; group-uniformity
  negatives (mixed maxConnectedClusters);
  cross-cluster pod routes + kube-api mirror Service reachability (D30)
  in native groups. `<distro>-clustermesh-external`
  (`<DISTRO>_CLUSTERMESH_EXTERNAL_OK`; the former `-native` twin, merged
  by D72) uses a dedicated transport-attached DNS VM, real A-record
  resolution, authenticated external-LB health checks, and
  bidirectional ClusterMesh status;
- eval seam suite: a third-party overlay implementing `node_transport`
  schemaVersion 2 is consumed by k3s/rke2 with NO provider service-name
  branching, and contradicting overrides eval-fail (D58);
- **fabric-topology suite** (D33/D56/D59): member/client/admin
  access independent of topology (route-level only), border filtering,
  border WITHOUT transit role and without automatic admin DNS,
  composable
  admin-border, kamrui-h1 dual-shape; member-facing DNS is not asserted
  (day-2, D22 amended);
- **network-facts suite** (D57): deep eval, JSON serializability,
  secret-free and versioned schema, facts/export/functional-render parity,
  dynamic-state labeling, and one consumer-owned nix-topology wrapper
  build proving SVG output without adding a clanServices dependency;
- PKI rotation (+ cert bootstrap runbook execution);
- CCM knob suite (hermetic fake-CCM);
- **GitOps-handoff suite** (D40/D44): strict no-op under a second SSA
  field manager, dataplane green before/after; no Flux in VMs;
- `distroDefaults` suite (D42) and rke2 CIS profile suite (D25);
- control-domain suite (D43/D30/D38): hub + two spokes + standalone,
  mirror-SAN and read-only positive/negative, rotation, offline spoke.

Round-18 acceptance evidence: 276/276 eval tests pass
(`.baton-pass/vm-logs/ifstate-eval-dhcp-killmode-46.log`); netif live
apply/check/restore passes (`.baton-pass/vm-logs/ifstate-netif-live-17.log`);
DHCP/RA and live reapply pass
(`.baton-pass/vm-logs/ifstate-netif-dhcp-final-48.log`); native data planes
pass (`.baton-pass/vm-logs/ifstate-k3s-data-plane-52.log` and
`.baton-pass/vm-logs/ifstate-rke2-data-plane-51.log`); all join/HA and all
twelve ClusterMesh variants pass on IfState (final logs named
`.baton-pass/vm-logs/ifstate-<suite>-final.log`). PKI rotation, fake CCM,
GitOps SSA no-op handoff, distroDefaults, RKE2 CIS, and control-domain
runtime behavior are not claimed by this acceptance matrix.

Retired suites: full-mesh transport suite (round 15 — superseded by
derived spine/leaf, D51/D59; historical); round-13 retirements: EG
gateway matrix, QUIC/Caddy fixtures, flux control-domain suite,
external-dns, OpenEBS, KubeVirt, Multus, sealed-secrets. Reserved:
MCS-API, upstream-kubernetes distro suites (D23).

## 8. Delivery plan (phases; each lands lib + both distros + docs + pins +
tests together)

- **0 done** — canonical import (`896acdf`).
- **1 done** — scope-reduction execution (docs-only round 13 landed first,
  per A4): out-of-contract code deleted (traefik renderers and inputs,
  cert-manager + sealed-secrets renderers/inputs, gateway-api-crds input);
  `lib/rancher-cluster/` renamed to `lib/kube-cluster/` (D45); interfaces
  pruned to bootstrap + data plane; `distroDefaults` knob (D42); static
  gates green.
- **2 done** — artifact flake narrowing (external-systems/pkgs): drop
  envoy-gateway/cert-manager/flux/external-dns/multus/sealed-secrets
  components + freshness checks; keep distro runtimes (3 minors), Cilium
  chart + committed inflated manifest, go-httpbin; add Cilium image
  airgap set; clean-public-fetch proof; CoreDNS image artifact added for
  D46 (2026-10-23). Consumed at pinned rev
  `feb7946fa83769f839ab5f835d3c84bd93b43fa5`.
- **3 done** — kubenix bootstrap bundle + bootstrap-apply oneshot
  (`clusterInit` node, SSA, `bootstrap.apply` off-ramp, D40); canonical
  Cilium profile with Node IPAM (D41); pools (D8); ETP-Local rendering;
  override validation. Implementation notes: the committed base manifest is
  imported into kubenix's typed tree with a pure-Nix YAML-subset parser
  (kubenix's own importYAML is yq-based IFD — forbidden by D26);
  `cilium.helmValues` overrides are limited to the layer-2-expressible
  profile tree (untranslatable keys throw at eval — §6.4 wording adjusted);
  clan-rendered CoreDNS in the bundle gives every distro the same DNS
  base (D46, added 2026-10-23 — supersedes the interim "minimal rke2 runs
  no distro CoreDNS" state); data-plane VM suite registered per distro
  (`k3s-data-plane`, `rke2-data-plane`).
- **4 done** — host-wireguard transport, hashed ids, topology, dual-stack
  exports; one-cluster-per-node assertion. Implementation notes
  (2026-10-23): `cilium.id` defaults to the sha256-based hash of the
  instance name mapped into 1–127 (pure Nix, no IFD); all id consumers
  (CIDRs, clusterDNS — 10th address of an explicit service v4 CIDR — and
  HAProxy ports) use the resolved id; explicit ids > 127 require explicit
  v4 CIDRs. Topology labels (`topology.kubernetes.io/region|zone`,
  default = instance name, per-machine overrides, empty = eval error,
  invariant 7) render into the distro node labels. The `kube_cluster`
  custom export interface (renamed from `rancher_cluster`, D45) publishes
  schemaVersion/identity/CIDRs/meshGroup/fabric source/member mesh
  endpoints incl. effective topology/pool handoff facts from both distro
  services; `node_transport` gained topology fields. Fleet-wide
  assertions (id collisions, duplicate names, same-group pod/service CIDR
  overlap, node-in-two-clusters across rke2+k3s (D16), mesh-group
  transport consistency) are `clan.checks` computed from the
  `kube_cluster` exports by the shared lib's fleet-checks module
  (wired into this flake's own clan and into the eval-test throwaway
  clans; consumers wire `clan.imports = [ fleetChecksModule ]`).
  All-or-none transport posture (§6.3) was a per-instance assertion;
  since round 67 every member rides the fabric (D76).
  Wireguard-mesh addresses were historically hash-derived; D64 replaces
  that derivation with committed public node allocations while preserving
  the one-shared-multi-peer-interface transport model.
- **5R0 done (docs only)** — round-14 FRR/per-pair-WG/native-Cilium
  contract, inventory-owned netif family, node-bgp delivery, and delivery
  re-plan. No implementation or VM claim. Rounds 15–16 supersede its
  per-remote-machine transport and fleet-routing naming (5R1–5R4 below).
- **5 legacy checkpoint, not accepted** — `2995ac3` contains BIRD/VXLAN
  Phase 5 work; retained baseline 5 green / 7 red. It is superseded by
  rounds 14–16 and is not a base for further BIRD debugging.
- **5R1 done (implementation + suites registered 2026-10-25; no new
  green claim)** — `netif` (multi-link, multi-instance,
  cross-instance assertions, endpoint exports) and the ROUND-16
  `routed-fabric` (per-adjacency WireGuard member↔hub + optional
  hub↔hub; eBGP/BFD/
  Zebra with next-hop-self; AllowedIPs dual semantics incl. 0/0 crypto
  ACL; source-policy return routing; underlay-derived MTU) implemented
  with versioned exports/network facts, eval tests, and hermetic
  transport/netif suites registered. The leaf/spine symmetric graph is
  the round-17 TARGET (D59) — implemented in 5R5, not here. Round 17 is
  docs-only, so suite
  green-ness is not re-claimed here; the retained baseline stands.
- **5R2 done — both repos** — the pinned Cilium base manifest was
  re-inflated and committed with native-routing defaults (D26 layer 1);
  the local Cilium↔FRR dual-AF session, multi-pool exchange,
  native CIDR/device/MTU invariants, iptables-nft assertion, and
  node-bgp/shared-bgp delivery landed in the shared lib + both distros.
  The full ClusterMesh phase landed with D60 in 5R5.
- **5R3 done** — selective ClusterMesh policy, topology/access/border
  filtering, and full/external regressions are implemented and VM-proven
  for k3s/RKE2 on native and tunnel profiles. The obsolete
  BIRD/VXLAN/fleet-routing modules, helpers, fixtures,
  `lib/import-flake/`, and `lib/inputs-module.nix` are deleted outright.
  `wireguard-mesh` is the supported tunnel transport (D58; revoked by
  D72, removed in round 53).
- **5R4 done** — `clan.networkFacts` schemaVersion 2 parity, deep-eval,
  secret-free/dynamic-state invariants, and the consumer-wrapper diagram
  proof are covered by eval tests (D57/D59); nix-topology remains
  consumer-owned.
- **5R5 done — round-17 contract** — generic `node_transport`
  schemaVersion 2 outside `lib/kube-cluster` with no provider-name
  branching (D58); `leaf`/`spine` with the symmetric derived graph (D59);
  full/selective ClusterMesh placement/exposure (D60); and the supported
  `wireguard-mesh` tunnel/VXLAN profile (removed by D72, round 53). The
  native, tunnel, selective, and external eval/VM suites were green.
  Breaking schema changes shipped without migration shims.
- **5R6 done — IfState-only networking (round 18, D61)** — replaced all
  systemd-networkd/netdev and scripted network rendering with IfState
  2.5.1; added the shared overlay/base, runtime-secret includes, DHCP/RA
  hooks, Cilium/FRR ownership ignores, live reconfiguration, and hermetic
  dependent regressions. No machines were deployed and no compatibility
  renderer remains.
- **6** — control domain: mirror Services (D30), `gitops-hub` identities
  + secret-sync + read-only credential (D43/D38). (The ClusterMesh data
  plane itself is 5R2(4) → 5R5, D60.)
- **7** — PKI ops + rotation runbooks/scripts, RKE2 CIS suite (D25),
  CCM knob + fake-CCM test, GitOps-handoff proof suite (D44),
  `distroDefaults` suite.
- **8** — borg migration + upstream review: home consumes `netif` and
  `routed-fabric`, removes `hostSpec.networking`/`machines.json` static-IP
  ownership, and salvages borg facts/runbooks only before archival.
- Reserved: upstream `kubernetes` distro implementation (D23; spec'd,
  hard requirement), MCS-API, clan-operator (per-agent read-only
  identities beyond D38, tenant lifecycle).

## 9. Out of scope

Everything day-2 (§3.3) as clan-rendered surface: Envoy Gateway and all
Gateway API rendering; the Ingress API; cert-manager; Flux/Argo
installation; external-dns; Sealed Secrets (controller AND sealing-key
custody); OpenEBS and any storage provisioner; KubeVirt/CDI (kubelet
CPU-pinning = generic distro config passthrough only); Multus as clan
rendering (distro-stock Multus via `distroDefaults` excepted); provider
CCM deployments (the `cloudController = external` knob is bootstrap
config and stays); hcloud-ip-floater deployment (floating-pool contract
stays; the controller is day-2 and upstream-unmaintained — fork
reference only). Also: alternative CNIs / Cilium tunnel mode of any
protocol (VXLAN, Geneve; D72) / BIRD / L2 announcements / VRRP /
Keepalived (spine HA is fabric ECMP, D51/D59); full-mesh fabric topology
and per-remote-machine WireGuard links (deferred beyond MVP, D51/D59 —
spine-only full peering is not a full fabric mesh); iBGP / route
reflectors / route servers (D51); shared gateway VIP / VRRP-style spine
HA and transparent active-active default gateway for ordinary non-fabric
LAN clients
(outside MVP — needs client routing or an L2/VRRP-like mechanism, D51);
other route-exchange profiles representable in the `node_transport`
schema (rejected until implemented and tested, D58); migration shims or
a compatibility burden for the round-17 schema/role renames (no external
consumers or deployments exist, D58/D59);
official mycelium/yggdrasil/wireguard overlays as dependencies or
underlays (peer exports are the integration seam, D55); mandatory
all-to-all ClusterMesh as the only peering mode (full is the default,
selective peers supported, D54); more than one routed-fabric membership
per machine (D53); legacy-iptables or kube-proxy-owned firewall rules
(D55); single-stack internals; Rancher
Manager; cross-inventory automatic mesh; implicit global Services;
early/default-on MCS-API; bundled provider CCMs; replicated storage;
Windows guests; direct-to-pod routing from edges; NAT64/app egress
remediation; same VIP advertised from two clusters; pod/ClusterIP routes
to non-Kubernetes hosts by default (`access = "admin"` excepted, D33);
clanServices-owned nix-topology dependencies, `topology.*` rendering, or
diagram packages (the neutral facts seam and consumer wrapper are D57);
public
node-bgp/shared-bgp without upstream-routed space; heterogeneous multi-WAN
inbound failover (use DNS failover); cilium CLI installs (D40);
HelmRelease adoption without helm release storage (D40); Rancher
helm-controller in the minimal base (D42); servicelb/klipper in any
mode (D42); clan rendering of Traefik (stock distro Traefik via
`distroDefaults` excepted, D42); delivery of clan manifests via distro
manifests dirs (D40); cilium-wireguard/unencrypted as tested transports
(§6.3); offline-minted SA JWTs and expiring bearer-token kubeconfigs
with refresh CronJobs (D43); secret-reading "read-only" roles (D38's
hard line); per-agent identity minting (clan-operator, Reserved);
blanket 100-year leaves; blind live CA regeneration; fully declarative
node/etcd/cluster deletion; in-place rke2↔k3s↔kubernetes conversion;
locked-HEAD distro constructors (D34); OLM v1 (D32 reasoning retained);
clan vars ownership of application-plane secrets incl. sealing keys
(D35); member-facing cluster DNS as a clan-rendered/fabric service
(D22 deferred — day-2 delivers member DNS via Kubernetes-side automation
such as external-dns).

## 10. Glossary

- **Bootstrap contract** — the day-1 promise that a declared cluster
  exists and is reachable: distro install/join, PKI, HAProxy kubeapi HA,
  bootstrap bundle, control-domain substrate (§3.1).
- **Data-plane contract** — the day-1 promise that packets flow
  correctly: native Cilium CNI, Node IPAM + pools, FRR/BGP/Zebra,
  ClusterMesh, per-adjacency host WireGuard, in-cluster CoreDNS
  (cluster.local), routed-fabric (§3.2).
- **Day-2 GitOps** — everything in-cluster that is not the two
  contracts; installed and owned by operator GitOps repos, documented
  here as recipes only (§3.3).
- **Bootstrap bundle** — the single kubenix-rendered manifest set per
  cluster, applied once via SSA on the `clusterInit` node (D40).
- **Cluster services** — public rke2/k3s/kubernetes clanServices +
  private shared library; not Rancher Manager.
- **Shared lib** — `lib/kube-cluster/` (renamed from
  `lib/rancher-cluster/`, D45): interfaces, renderers, vars, assertions.
- **Artifact flake** — external-systems/pkgs; nixpkgs/flake-parts authority,
  overlays, distro runtimes (last 3 minors, D34), committed manifests,
  per-system airgap images, test fixtures (D62).
- **Distro** — the Kubernetes distribution a cluster instance runs:
  `rke2` | `k3s` | `kubernetes` (upstream, kubeadm-based, D23).
- **distroDefaults** — per-distro-service knob; `true` on rke2/k3s
  restores stock packaged components (helm-controller, Traefik, Multus)
  via the distro's own machinery (D42).
- **CNCF posture** — clan-rendered in-cluster components are CNCF
  projects; host-level (FRR, WireGuard, HAProxy) exempt; rke2 is the
  documented distro exception (D24).
- **Kubenix rendering** — manifests built as typed Nix module resources;
  chart inflation only at artifact-flake update time (D26).
- **IFD (import-from-derivation)** — evaluation reading a derivation's
  output, forcing a build during eval; forbidden in clanServices (D26).
- **Base manifest** — a chart rendered with the canonical fleet-uniform
  profile, committed as source in the artifact flake (D26 layer 1).
- **Control domain** — the set of clusters one GitOps control plane
  manages: a hub plus its spokes (D43). Bounded by a mesh trust domain.
- **Control-domain role** — per-cluster `standalone` (shares nothing) |
  `hub` (holds spoke kubeconfigs) | `spoke` (hub-reconciled) (D43).
- **Trust domain** — the `routed-fabric` instance and its ClusterMesh
  mesh group (meshGroup defaults from the fabric instance); bounds
  fabric membership, ClusterMesh peering + route policy, AND control
  domains (D43/D53/D54).
- **gitops-hub identity** — the per-spoke client certificate (CN
  `gitops-hub-<spoke>`, O `gitops-hub`) signed by the spoke's cluster
  CA, consumed by whatever GitOps tool the hub runs (D43).
- **Read-only credential** — the per-cluster client certificate (CN
  `readonly-<instance>`, O `cluster-readers`) and kubeconfig for
  no-secrets read access, minted for AI agents; synced to the hub for
  spokes (D38).
- **Mirror Service** — clan-rendered selectorless ClusterMesh-global
  Service + EndpointSlice exposing a cluster's kube-apiserver to mesh
  members (D30); mandatory for spokes.
- **Bootstrap plane** — secrets custody: clan vars own bootstrap secrets
  only (CAs, tokens, admin + read-only kubeconfigs, ClusterMesh
  material, HAProxy health-check material, gitops-hub identities); all
  application-plane secrets are GitOps-owned (D35).
- **Integrated node transport** — the generic `node_transport`
  schemaVersion 2 contract (D58) and its one supported profile (D72):
  routed-fabric (per-adjacency routed L3 host WireGuard — leaf↔spine
  attachments plus automatic spine↔spine pairs, D51/D59 — carrying
  dual-stack node InternalIPs, API, native pod traffic, FRR/BGP, and
  BFD). (`wireguard-mesh` with Cilium tunnel/VXLAN was removed. Round-14
  "per-pair full mesh" phrasing is historical.)
- **node_transport (schema)** — the shared, neutral, open transport
  export schema declared outside `lib/kube-cluster` (D58): stable
  dual-stack node addresses, instance/endpoint identity, every datapath
  interface keyed by Linux name with its MTU, exactly one
  `directRoutingDevice`, `routeExchange = local-router` (routing is
  always native, D72; never `local-frr`/
  `local-bgp`), and the independent exposure capabilities
  `internalLoadBalancer` and `nodePort`. k3s/rke2 consume only this
  schema and never branch on provider service names.
- **Mesh group** — mutually trusted cluster instances forming one
  ClusterMesh; defaults from the fabric instance (no repeated value
  required). (Round-14 default `meta.domain` is historical.) Members
  share maxConnectedClusters (D60; routing is always native, D72).
- **ClusterMesh exposure** — how the clustermesh-apiserver is reached:
  `auto | internal-load-balancer | node-port | external-load-balancer`
  (D60). Internal pins ONE IPv4 literal VIP from the D10
  `<instance>-fabric` pool (class `io.cilium/bgp-control-plane`) —
  control-plane exposure is IPv4-only on the validated Cilium 1.20.3
  profile, while the ClusterMesh data plane stays dual-stack; node-port
  advertises selected nodes' stable IPv4 addresses with replicas = selected
  count and no replica knob; external always wins, requires a non-clan
  `loadBalancerClass` + a DNS-only `dnsName` (runtime A record), and needs
  no internal capability. Certificate SANs carry published IPv4/DNS
  endpoints only. ETP Local on every method. Mirror-Service allocation is
  separate and never uses the clustermesh-apiserver's VIP.
- **ClusterMesh placement** — which nodes run the clustermesh-apiserver:
  `voters` (default — servers), `workers` (agents), `all`, or `labels`
  (clan-declared/generated only; zero matches = eval error) (D60).
- **Pool scope** — per-machine (node-named, one owner) vs cluster-global
  (generic-named); who contributes a pool's addresses.
- **Delivery mode** — node-fate-bound | node-bgp | floating | shared-bgp |
  external-class; how traffic reaches pool addresses + failure semantics.
- **Node IPAM** — Cilium's LoadBalancer feature (helm `nodeIPAM.enabled`)
  that advertises node IPs (ExternalIP, else InternalIP) as a Service's
  LB ingress; the classless-Service default (D41). Distinct from
  `ipam.mode: kubernetes` (pod IPAM), which is an allowed override.
- **LB IPAM pool** — CiliumLoadBalancerIPPool; explicit draws use
  `io.cilium/bgp-control-plane`, while advertisement remains selector-driven.
- **Node-fate-bound delivery** — provider/static routing to one node; no
  failover, no BGP.
- **Node BGP delivery** — only the owner node advertises exact VIPs from
  its per-machine pool; no cross-node ECMP.
- **Floating delivery** — runtime controller moves the address to one
  node at a time; failover is the controller's contract.
- **Shared BGP VIP** — address advertised from all healthy nodes
  (ETP-Local withdrawal); the `shared-bgp` mode of a cluster-global pool.
- **Private fleet fabric** — default per-cluster private shared-bgp pool
  + FRR/BGP/Zebra + the clustermesh-apiserver VIP (pinned at host offset
  79, D10/D60); lets clan
  hosts route into every
  cluster. Mirror-Service VIP allocation is separate/future and must not
  share offset 79 (D30). No CoreDNS VIP — member DNS is wholly day-2
  (D22).
- **routed-fabric service** — clanService providing the flat-L3
  spine/leaf fabric: one WireGuard interface per adjacency (leaf↔spine
  attachments, automatic spine↔spine pairs),
  FRR/BFD/Zebra, orthogonal access and border policy, and the native
  Cilium profile (local-router exchange + internalLoadBalancer/nodePort
  capabilities, D58). Renamed from
  `fleet-routing` in round 15 (D52); roles revised in round 16 (D56) and
  renamed `leaf`/`spine` in round 17 (D59).
- **Fabric adjacency** — a leaf↔spine attachment or an automatic
  spine↔spine pair
  in a routed-fabric instance; owns exactly one WireGuard interface, one
  eBGP session pair (one per AF), and one BFD monitor (D51/D59).
- **Leaf / spine** — mutually exclusive fabric topology roles (renamed
  from member/hub in round 17, D59): spines
  forward and readvertise (next-hop-self); leaves never provide transit
  and reach ≥1 spine — every spine by default, explicit subset allowed;
  HA profiles use two spines with no arbitrary maximum
  (D51/D59). Orthogonal to control-domain hub/spoke (D43), access, and
  border. Spine-only full peering is not a full fabric mesh: there are
  no leaf-leaf edges.
- **Fabric access** — per-machine `member | client | admin` route
  consumption (member DNS is day-2, D22 amended): `client` = fabric-pool
  LoadBalancer-VIP routes only; `admin` = + pod-pool and ClusterIP
  routes; Kubernetes nodes on native transports install pod/VIP routes
  regardless (D49). Membership, not topology — independent of leaf/spine
  roles and border (D56/D59).
- **Border** — optional per-machine external/upstream transit
  configuration, not a topology role, default gateway, NAT device, DHCP
  server, or Kubernetes Gateway API implementation (D56).
- **Underlay / fabric / ClusterMesh graphs** — three distinct graphs:
  netif links; routed-fabric adjacencies; ClusterMesh peering edges.
  Similar shapes, independent edges (D54). Control-domain edges are a
  fourth, also independent graph (D43/D57).
- **Network facts** — versioned (schemaVersion 2), non-secret, read-only
  `clan.networkFacts` NixOS options describing resolved build-time
  networking for optional consumers; runtime-unknown state is explicit
  (D57/D59).
- **nix-topology wrapper** — consumer-owned integration translating
  network facts into buildable diagrams; never a clanServices dependency
  (D57).
- **IfState** — the exclusive static network renderer (D61), pinned to
  2.5.1. It owns links, addresses, WireGuard, static/policy routes, rules,
  and sysctls and reconciles them live without reboot; FRR/Zebra and
  Cilium retain dynamic ownership. No systemd-networkd, netdevs, or
  scripted network units.
- **netif contract** — `specs/netif.md` (N1–N30): netif is the only
  network contract in the inventory; IfState renders IfState modes and
  NetworkManager renders NetworkManager modes, never both in one system
  configuration; iwd owns Wi-Fi in every mode.
- **Mode** — a NixOS specialisation (gaming, developer, kubernetes); the
  parent configuration is the default boot entry; switching is by reboot
  only (N3).
- **Ownership registry** — `clanServices.networking.owners`: objects owned
  by other software (iwd, Tailscale, Cilium, VM taps), rendered into IfState
  ignores and NetworkManager unmanaged devices (N6).
- **netif instance** — one site/segment declaration of the netif
  service with shared defaults and per-machine/link overrides; several
  may coexist on one host (D53).
- **Private-domain zones** — day-2 member-facing DNS zones (D22
  amended; NOT served in the MVP): `<instance>.<domain>` (default) and
  opt-in `<instance>.svc.<domain>` and pod zone, published by
  Kubernetes-side automation such as external-dns. `cluster.local` never
  appears on clients.
- **Managed base** — labeled clan-rendered APIs/resources installed once
  via the bootstrap bundle; tenant resources GitOps-owned.
- **Airgap-ready** — all artifacts pinned and local at boot.
- **VM-proven** — behavior passed fresh, sandboxed, hermetic on final
  tree.

## 11. Key upstream references

- IfState 2.5.1 (D61): declarative netlink reconciliation for links,
  addresses, routes/rules, sysctls, and WireGuard; runtime `!include` for
  secrets; interface hooks for DHCP; built-in ignores for dynamic routing
  protocols. Source/tag: <https://codeberg.org/routerkit/ifstate/src/tag/2.5.1>.
- Cilium 1.20: native routing (`routing-mode: native`; remote pod routes
  require a system routing daemon when nodes are not on one L2),
  multi-pool `CiliumPodIPPool` advertisements, LB IPAM, Node IPAM (the
  ETP-Local EndpointSlice caveat affects only Cilium's own
  Gateway/Ingress, D41), BGP v2, ClusterMesh (identical datapath per
  group, non-overlap,
  node connectivity, mesh-wide native-routing CIDR, D58/D60; this repo
  uses native routing only, D72), and the Gateway gaps
  behind D1. Configuration uses the rendered `cilium-config` ConfigMap
  (D26 layer-2 seam); official install = Helm, cosign-signed
  digest-pinnable OCI charts; the chart ships no `crds/` dir — the
  operator manages CRDs at runtime (D40).
- Cilium ClusterMesh control plane (D10/D60): the pinned chart's
  v1.20.3 clustermesh-apiserver Deployment embeds etcd with
  `--listen-client-urls=https://0.0.0.0:2379` (IPv4 wildcard;
  `--advertise-client-urls=https://localhost:2379`) and the template has
  no dual-stack listener knob — control-plane exposure is IPv4-only on
  the validated profile: ONE pinned IPv4 VIP internally, selected nodes'
  stable IPv4 addresses on NodePort, DNS (A record) externally, and cert
  SANs covering published IPv4/DNS endpoints only. The ClusterMesh data
  plane stays dual-stack.
- Cilium bootstrap/handoff evidence (D40): Flux prune only touches the
  Kustomization's own `.status.inventory` (fluxcd.io Kustomization
  docs); SSA vs client-side-apply field-manager friction and
  `--server-side` bootstrap avoidance (same docs + Flux FAQ); Argo CD
  adoption via tracking annotation/label (Argo resource-tracking docs);
  Flux maintainer on CNI takeover (fluxcd/flux2#3070); cilium-cli helm
  mode + value auto-detection + cert-mode skew (cilium-cli README,
  cilium-cli#300; Reddit crash-loop migration report).
- Kubenix (hall/kubenix): helm inflation at update time (IFD — why it
  lives in pkgs); patching chart output via typed resource tree
  re-declaration (D26 layer 2); `includeCRDs = false` default (loses
  nothing for Cilium).
- Kubernetes RBAC: built-in aggregated `view` ClusterRole excludes
  Secrets by design (basis of D38).
- Kubernetes CCM: `--cloud-provider=external` uninitialized-taint flow;
  no Cilium-specific caveat (agent tolerates `Exists`) (§6.11).
- RKE2 hardening: `profile: cis` (v1.29+), PSA restricted, host
  sysctl/etcd-user prerequisites (D25).
- Kubernetes version skew: kubelets may lag apiserver up to 3 minors
  (motivates D34).
- FRR 10.7+: integrated NixOS `services.frr` config; BGP eBGP/ECMP,
  prefix-lists/route-maps, martian/loopback next-hop handling, BFD,
  `frr-reload.py --test`, Zebra RIB-to-kernel installation; Cilium local
  `::1` peering and next-hop rewrite (D9/D19/D48).
- WireGuard cryptokey routing: one peer per interface; ECMP across
  interfaces, never overlapping AllowedIPs across peers on one interface;
  AllowedIPs is outbound cryptokey selection AND the inbound source ACL
  — every approved transit prefix must appear, and 0/0 is a crypto ACL,
  not a routing decision (D47/D51).
- hcloud-ip-floater (costela): floating-IP mover reference; upstream
  effectively unmaintained (last non-dependabot commit 2023) —
  fork-don't-depend.
- go-httpbin (mccutchen): standard airgapped HTTP VM-test workload.
- Host firewall: nftables-only; Cilium 1.20.3 KPR/BPF masquerade requires
  `install-iptables-rules=true` through iptables-nft; legacy iptables and
  kube-proxy rules are forbidden (D55).
- Cilium BGP session: one local `::1` session carrying both AFs;
  `extended-nexthop` capability and v4/v6 next-hop interworking are
  probed before renderer lock (D55).
- WireGuard MTU: underlay MTU minus WireGuard overhead (80 bytes v4 /
  96 v6); 1280 floor; path-MTU asserted in VMs (D51). Cilium MTU = the
  minimum interface MTU (D58; native routing only, D72).
- nix-topology: evaluated `nixosConfigurations` plus explicit networks,
  nodes, interfaces, connections, and service details produce SVGs;
  `topology.<system>.config.output` is a derivation and may be exposed as
  `packages.<diagram>`. Its flake-parts module selects compatible
  `self.nixosConfigurations`; clan's evaluated hosts therefore fit the
  consumer-owned wrapper without making raw inventory a nix-topology
  input (D57).
