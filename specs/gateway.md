# gateway — router and NAT gateway contract (agent edition)

The normative contract and status authority for two planned clanServices:
`services/router` (the edge of a LAN) and `services/nat-gateway` (IPv4
reach for machines that have none), and their private shared
implementation `lib/gateway/`. Both build on netif's zone seam
(`specs/netif.md` N10) and never declare links themselves. The human
rendering is `documentation/docs/gateway/`. **Edit this file and those
pages together.** Decisions are numbered `G1`–`G25`, so they never collide
with `N` (netif) or `D` (SPEC.md) numbers. Use cases stay in
`specs/netif.md` §2 (U3, U13–U18).

Round G0 (2026-11-20): **design round; docs only.** The owner decided the
shape in a deciding session. Nothing in this file is implemented. Every
decision is *(planned)* and several wait for a probe (§6).

Round G1 (2026-11-20): **probe round.** Probes ran on euc-hel-0
(then `lib/gateway/tests/probes/`, suites `probe-*`; suites of
`lib/gateway/tests/vm/` since round G3). Evidence is §10. No
service code exists yet; netif got two small changes (N43, and the
prefix file of N16).
- **PR2 answered:** Jool in the host namespace bypasses the forward
  chain. G2 is amended: Jool runs in a namespace of its own.
- **PR3 answered:** corerad works with a delegated prefix, a ULA, RDNSS,
  DNSSL and PREF64. It does nothing when the prefix changes. G22 is new.
- **PR6 answered:** the prefix rewrite works as G20 describes.
- **New gaps:** a CLAT follows one gateway (G23); open flows stall on a
  gateway failure, they do not reset (G6); the DNS64 listener needs the
  allowlist too (G4).
- **PR5 answered:** a physical link presents another MAC while it is
  found by its permanent one; IfState renders a VLAN 0 child and DHCP
  runs over it (`specs/netif.md` N43, N44).
- G22 and G23 were *proposed* in this round. The owner accepted them,
  and the G16 mechanism, on 2026-11-21 (round G2).

Round G2 (2026-11-21): **retrospective and the routed fabric.**
- The owner accepted G16's mechanism, G22 and G23.
- **PR10 answered (§10.11):** both transports run on IPv6-only NICs,
  k3s and rke2, and pod IPv4 leaves through each node's CLAT in both
  modes. G5 gains a simpler variant (the CLAT link in Cilium's
  `devices`), proposed.
- New suites `k3s-ha-fabric` and `rke2-ha-fabric` (SPEC.md round 49).
- §12 is the retrospective: what is not proven, the design risks, the
  coverage of the two Cilium modes, suite stability.

Round G3 (2026-11-21): **the probes became suites; mode parity.**
- The owner decided G5: the CLAT link joins Cilium's `devices`.
- The probe branch merged into this one. Every probe is now a suite
  that asserts what it showed (§5, §6, §10): `gateway-wan`,
  `gateway-nat64`, `gateway-router`, `gateway-dual-wan`,
  `netif-v6only`, `<distro>-v6only`, `<distro>-clat-<transport>`,
  `k3s-clat-<transport>-mapped`. They run on fixtures in
  `lib/gateway/tests/vm/`; no service code exists yet.
- The suites corrected the design in G16 (four points), G22 (state
  loss across a reboot), G23 (hysteresis, the gateway's own health
  check, an ICMP limit) and §10.4. Each is marked where it stands.
- Both Cilium modes now have the same suites where the mode allows it
  (§12.3): `data-plane-tunnel`, `join-netif`, `k3s-modes-fabric`.
- §12 is updated: closed rows say so, new risks are added.

Round G4 (2026-11-21): **devil's advocate review.** Four reviewers
read every new suite against this file. §13 holds the result.
- Nineteen claims did not hold in the code. All are fixed on this
  branch and asserted (§13.1). The worst: a gateway relayed ICMP for
  any source; a dual-WAN router answered inbound connections through
  the wrong WAN; NodePorts were open past the node firewall.
- G4, G6, G16, G20, G22, G23 and netif N16 are amended where they
  stand. SPEC.md gains D69 and D70.
- Ten points need the owner (§13.2). The first: stop probing and
  build the services.

Round G5 (2026-11-23): **owner decisions; docs only.** §14 locks the
answers to §13.2: build the services (nat-gateway and the CLAT first,
then the router with one WAN), freeze the design-only decisions, the
CLAT as the only path with DNS64 frozen, a per-client rate limit with
a `trusted` tier, rendered Cilium `devices` (SPEC.md D71), and native
routing only (SPEC.md D72). §14.3 sets the direction for each unfixed
finding.

Round G6 (2026-11-23): **native routing only, implemented** (SPEC.md
D72, round 53). Cilium tunnel mode and `wireguard-mesh` are gone.
- The CLAT suites run on the routed fabric only:
  `<distro>-clat-fabric` is now `<distro>-clat`, and
  `k3s-clat-fabric-mapped` is now `k3s-clat-mapped`.
  `<distro>-clat-mesh` and `k3s-clat-mesh-mapped` are deleted.
- `<distro>-v6only` reuses `join`, which now runs on the fabric.
- §12.3 (the two modes) and the mesh rows of §10.11 are history.

Round G7 (2026-11-24): **the services, first cut** (§14.1 point 1).
Code now exists; each mechanism below runs as service code in a suite.
- `lib/gateway/` holds the modules (`nat64.nix`, `clat.nix`,
  `router.nix`, options `clanServices.gateway.*`), their helpers
  (`nat64-health.py`, `clat-follow.py`, `router-prefix.py`) and the
  fixed names (`names.nix`).
- `services/nat-gateway` (roles `gateway`, `client`; G1–G6, G23, G24)
  and its suite `nat-gateway` (§5). No DNS64 (§14.1 point 3).
- **G24, new, proposed (for the owner):** the health beacon. With DNS64
  frozen nothing answered `ipv4only.arpa`, and G23's follower had no
  signal. A gateway now serves that one name and nothing else.
- §14.1 point 4 is built: the tiers and their default numbers.
- SPEC.md D71 is built: k3s and rke2 render Cilium `devices` from the
  netif and `nat_gateway` exports, and §14.2's open question is
  answered: one cluster-wide union (candidate 1).
- `<distro>-clat` runs on the services (netif, `nat-gateway`, the
  rendered `devices`, a plain IPv6 resolver); `k3s-clat-mapped` keeps
  its fixtures and is unchanged (`suite-compare`: same).
- `services/router` (role `router`; G8, G11, G14, G15, G20, G22) with
  one WAN, and its suite `router`, ported from `gateway-router`. It also
  builds §14.3's hairpin rewrite of G20.
- What each suite showed is in §5 and §15.

Round G8 (2026-11-24): **owner decisions on PR #38** (§14.5). Locked:
the CLAT is the only path and our DNS64 is removed; G24 accepted;
stability over fast failover (hysteresis on both sides); limit
overrides per gateway, per client and per instance; a gateway may be a
Kubernetes node and is never a client; no metrics yet (G18 later, the
path kept open); the home box is `router` and a node, no gateway yet.

Round G9 (2026-11-25): **hardening review of PR #38 and of the
networking and cluster services** (§16). Three reviewers read the
existing services, one the gateway code; every finding below was
checked against the code.
- **The owner answered round G8's questions:** windows, not "in a row"
  ("if that is most stable"); the stray-packet check bounds a time
  window; the `nat-gateway` suite is split.
- **G25, new: a router shares its machine.** The largest gap: the
  router turned the NixOS firewall off and dropped by policy whatever
  it did not know, so on the owner's home box (router and node,
  §14.5 point 7) the cluster's and the fabric's rules were void and
  their traffic was dropped. No suite combined them. Now the router's
  table judges its own links only; suite `router-kube`.
- **Three fixes in `nat-gateway`:** the translator was a way into the
  gateway's own IPv4 ports (`nat64-host`); the follower took any /96 a
  beacon named (now only that gateway's own); a `pool6` or CLAT
  address that changed in the configuration was never applied, and one
  written in another spelling failed the unit (now reconciled, compared
  as addresses).
- **Router assertions:** one link per zone, no router advertisements
  accepted on a zone link, the router's own address outside the DHCPv4
  pool; the prefix hook runs after IfState.
- **Suites:** `nat-gateway` is split into `nat-gateway` (function) and
  `nat-gateway-failover` (§14.5 point 4); new `router-kube`.
- **Not fixed, for the owner:** §16.3 ranks what the review found in
  `routed-fabric`, the cluster services and netif.

Round G10 (2026-11-25): **the sixteen findings of §16.3 are fixed.**
The owner: "yes to all 3 ... please apply all fixes"; nothing is
deployed, so no change is breaking (AGENTS.md rule 10).
- **Accepted:** G25 and the default-route rule of SPEC.md D71.
- **Stability first (§16.3 items 1 to 3):** BGP graceful restart on
  the Cilium session and on the fabric sessions; `site` has no
  default, and the fast timers need the same site named on both ends.
  Suite `k3s-frr-failure` gained three phases.
- **Items 4 to 16** are fixed in `lib/kube-cluster`, `routed-fabric`,
  netif, the router and `nat-gateway` (§16.3, SPEC.md round 57,
  `specs/netif.md` N25).
- **G25 amended:** the router takes `unzoned.source` from the
  machine's fabric export; the option is an override.
- Evidence: §16.5.



As in `specs/netif.md` §0: *(planned)*, *(probe-verified)*,
*(implemented; suite and marker)*. A decision that waits for a probe
says which one. When a probe disproves a decision, amend this file before
any code (AGENTS.md rule 3).

## 1. Principles (owner, 2026-11-20)

- **P1** IPv4-only networks are out of scope.
- **P2** Clan machines use an IPv6-only underlay where possible. A public
  IPv4 costs money in the cloud; only gateways carry one.
- **P3** Kubernetes is always dual-stack inside (SPEC.md §3.2, D67):
  applications hard-code IPv4.
- **P4** A home or on-prem LAN serves any device with no configuration on
  the device. IPv4 therefore stays on offer there.
- **P5** Systemd runs what is needed to reach or repair a cluster:
  routing, NAT, DNS, DHCP, router advertisements, the VPN control server.
  Everything else runs in Kubernetes.
- **P6** The safest option wins: default deny between zones, and no
  inbound port unless a service needs one.
- **P7** Prefer components with native Prometheus metrics.
- **P8** No rollout plan, compatibility shim or schema version
  (AGENTS.md rule 10). The owner installs the home router once both
  services are complete and proven.

### 1.1 What is possible (the facts the design rests on)

- **An IPv6-only host can reach IPv4**: NAT64 on a gateway, plus DNS64
  for names or a CLAT on the host for IPv4 literals and IPv4-only
  sockets.
- **An IPv4-only host cannot reach IPv6** in general: a 128-bit
  destination does not fit in 32 bits. Hence P1.
- **A host cannot translate for itself.** Reaching IPv4 needs a public
  IPv4 somewhere. A host can run the stateless half (a CLAT); the
  stateful half (NAT64) runs on a machine that has a public IPv4.
- **A LAN cannot be IPv6-only when unknown devices join it.** A device
  that only speaks IPv4 needs an IPv4 address and gateway on its own
  link. "IPv6-mostly" (RFC 8925) is the ceiling: one LAN offers both,
  and each device that can drop IPv4 does so by itself.
- **A dual-stack cluster runs on an IPv6-only underlay**: the IPv4 a
  node needs is a private fabric address, not a NIC address (D67).

## 2. Decisions

### Structure

- **G1 Two clanServices, one private lib.**
  - `services/router`: the edge of a LAN it owns. One role, `router`.
    Clients are any device; they learn everything from DHCP and router
    advertisements.
  - `services/nat-gateway`: IPv4 reach for clan machines that have none.
    Roles `gateway` (1-n machines) and `client`. Clan configures the
    clients. A machine is never both (§14.5 point 5); a gateway may be
    a Kubernetes node.
  - `lib/gateway/`: the private shared implementation (NAT44, NAT64,
    SIIT, CoreDNS rendering, firewall, metrics). Not a clan service
    (as `lib/kube-cluster/`).
  - Why services, not NixOS modules: a client's configuration depends on
    the gateways' addresses, and a gateway's allowlist on its clients.
    `router` is machine-local, but as a service it gets clan vars and
    exports.
  - Both read `clanServices.netif.zones` and link facts (N10). NAT is
    still never netif's (N20).
  *(planned)*

### Translation

- **G2 Jool is the only translator, in a namespace of its own.**
  - Stateful NAT64 on gateways; SIIT for the CLAT (G5, G23) and for
    inbound IPv4 (G12).
  - Reason (owner): it runs in the kernel, so no per-packet context
    switch, and one tool covers both modes.
  - A machine that runs Jool uses a kernel Jool builds against. Jool
    4.1.15 builds for the 6.18 kernel of the pinned nixpkgs and comes
    from the public cache (§10.1).
  - **Every Jool instance lives in a network namespace of its own**
    (amended 2026-11-20 after PR2). In the host namespace Jool takes a
    packet in PREROUTING (priority -75) and emits the translated one in
    POSTROUTING: the input, forward and output chains never see it. A
    firewall with a forward policy of drop relayed an undeclared source.
  - In a namespace the host forwards to Jool over a veth pair. The
    ordinary forward chain then filters both sides, conntrack sees the
    flow, and the host masquerades Jool's private IPv4 address to the
    public one.
  - The namespace and the veth pair are declared in IfState
    (`namespaces`), because IfState deletes a namespace it does not
    know. `lib/gateway` renders them into the shared IfState base, as
    `routed-fabric` renders its links, and claims them in the
    ownership registry. An IfState apply keeps the namespace and the
    Jool instance (§10.1).
  - `lib/gateway` renders its own Jool units. The NixOS module
    `networking.jool` only creates instances in the host namespace.
    The unit must be idempotent: `instance add` fails when the instance
    exists.
  - Jool refuses a `pool4` port range that overlaps the namespace's
    ephemeral ports. Nothing opens a socket in the Jool namespace, so
    its ephemeral range is shrunk and Jool gets ports 1100–65535. In
    the host namespace Jool would be left with 61001–65535.
  *(probe-verified, PR2; the units are planned)*

- **G3 Who translates what.**

  | Packet | Translator |
  |---|---|
  | IPv6 to IPv6 | none; it goes direct |
  | From something that has only IPv6 (a cloud host) | NAT64 on a gateway |
  | From something with a private IPv4 on a LAN | NAT44 on the router |
  | From a pod's IPv4 in the cloud | G5 |

  *(planned)*

- **G4 Gateways are off-path.** *(DNS64 parts frozen, §14.1 point 3,
  2026-11-23: the first `nat-gateway` serves no DNS.)*
  - Each gateway serves its own /96 out of its public IPv6 prefix, and
    its own DNS64 that synthesizes into that /96.
  - Clients reach both over plain IPv6. A source allowlist, built from
    the `client` role, keeps a gateway from being an open relay. It is
    a rule of the forward chain (G2). It also covers the DNS64
    listener, or the gateway is an open resolver. A client's CLAT
    address (G23) is a second source to allow.
  - **The allowlist is a table of its own, ahead of the firewall**
    (`inet nat64`, forward and input at priority -10; round G4, §13.1).
    The NixOS firewall accepts every ICMPv6 type before a rule in
    `extraForwardRules`: with the allowlist there, an undeclared
    source pinged the IPv4 internet through the gateway. The table
    drops by source for every protocol, covers port 53 for UDP and
    TCP, and holds the refusal of private IPv4 destinations (G5).
  - CoreDNS binds the gateway's address. It cannot take the wildcard:
    netif runs systemd-resolved on every machine (N9) and its stub
    holds port 53. A bind right after boot races duplicate address
    detection; `net.ipv6.ip_nonlocal_bind` avoids it.
  - A client lists every gateway as a nameserver. A dead gateway stops
    answering DNS, so the next gateway's prefix is used. Measured with
    systemd-resolved: 5.6 s to move, and resolved flushes its cache
    when it changes server, so a cached name follows at once (§10.1).
  - Caches the probe did not cover keep a dead gateway's prefix: an
    application's own cache, and a cluster's CoreDNS. Each gateway
    therefore caps the TTL of what it answers (`rewrite ttl`, shown to
    work; the cap is a setting). Without a cap a synthesized answer
    carried a TTL of 600 s.
  - The host path never depends on the fabric, so a broken fabric cannot
    stop a machine from fetching its own fix (the spirit of AGENTS.md
    rule 11).
  *(planned; the path, the allowlist and the failover are
  probe-verified, PR2)*

- **G5 Pod IPv4 egress in the cloud: the node's CLAT, with the CLAT
  link in Cilium's `devices`** (the CLAT path decided by PR1,
  2026-11-20; the variant decided by the owner, 2026-11-21).
  - Each node runs the CLAT of G23. Pod IPv4 that leaves the cluster
    takes the node's IPv4 default route into the CLAT and continues as
    IPv6 to the same NAT64 as the host's own traffic. One mechanism, no
    fabric dependency.
  - **Decided 2026-11-21 (owner): the CLAT link joins Cilium's
    `devices`.** Cilium's own eBPF masquerade hides pods behind the
    CLAT's IPv4 address (`192.0.0.1`). The CLAT needs only its one host
    mapping, the node needs one address and no routed prefix, and the
    gateway's allowlist names node CLAT addresses. The kube service
    adds the link to `devices` on a machine that has a CLAT.
  - Why Cilium must do it (PR1, §10.8; pinned by the `-mapped` suites):
    - Cilium's eBPF masquerade covers only its own devices. Without the
      CLAT link in `devices`, pod packets reach the CLAT with the pod's
      address;
    - an nftables masquerade on the CLAT link counted no packet: with
      eBPF host routing, pod traffic never passes that hook.
  - **The documented alternative: map the pod pool statelessly.** Each
    node maps the whole cluster IPv4 pod pool (a /16) into a /112 of a
    prefix routed to that node (`eamt add <node prefix>::a:0:0/112
    10.1.0.0/16`). No state on the node, and the gateway can tell pods
    from the host by address. It costs a routed prefix per node. For a
    site that wants pod addresses visible at the gateway.
    | | CLAT link in `devices` (decided) | Pod pool mapping |
    |---|---|---|
    | State on the node | Cilium's NAT table (already used for all other egress) | none |
    | Needs a prefix routed to the node | no: one address | yes (a /112) |
    | Gateway allowlist | node CLAT addresses | node prefixes |
    | Gateway can tell pods from the host | no | yes, by address |
    | Cluster configuration | the kube service adds the link to `devices` | none |
  - Masquerading on the CLAT link changes nothing inside the cluster:
    a ClusterIP Service sees the pod's own address in both families,
    and a node never sees `192.0.0.1` as the source of a pod.
  - **Unit order does not matter.** Nothing orders the cluster unit
    after the CLAT, and on the mesh k3s started first. Cilium attaches
    to a `clat0` that appears, or is deleted and made again, after it
    started. An IfState apply does not recreate the link.
  - **The underlay NIC joins `devices` too** (round G4, proposed; the
    design suites do it). On an IPv6-only node, in both modes, pod
    IPv6 that leaves the cluster is masqueraded only on a `devices`
    link. Without the NIC there, the pod's `fd10:` address leaves the
    node and nothing answers; cluster CoreDNS cannot reach the node's
    nameserver, so no external name resolves in any pod. With DNS64
    most pod egress is IPv6, so this is the main path, not a corner.
    - `wireguard-mesh` does not export the NIC as a datapath link, so
      the kube service must add it on such a node (planned; with the
      CLAT link).
    - SPEC.md D69 makes this safe: a NodePort does not answer on the
      NIC address from outside (asserted).
  - **An IPv6-only node's only nameserver is the DNS64, over IPv6**
    (asserted). Cluster CoreDNS forwards to it.
  - **Measured (round G4): the late attach.** After `clat0` is made
    again, Cilium attaches after about 7 s (native) or 15 to 17 s
    (tunnel). Until then pod IPv4 leaves with the pod's address, is
    translated to `<pool6>::<pod IPv4>` and gets no reply. Pod IPv4
    egress is down 9 s, or 17 to 18 s. Not fixed. An IfState apply
    does not recreate the link, so this is a boot and repair window.
  - **On `routed-fabric`, before BGP converges,** a node's IPv4 packet
    to another node address follows the default route into the CLAT.
    The gateway refuses it (1 to 7 packets per boot). Open: an
    unreachable route for the node-address range closes it.
  - **Open: Cilium attaches late.** The agent lists `clat0` as a
    masquerade device, and is Ready, up to about 12 s before its
    program is on the link (measured 0.1 to 12.5 s; the mesh is the
    slow one). A pod's IPv4 packet in that window was not tested; it
    most likely leaves with the pod's address and is lost. The window
    opens at boot and when the link is really recreated.
  - **Proven on native routing** (`routed-fabric`; the VXLAN tunnel
    proof on `wireguard-mesh` was removed with it, SPEC.md D72), two
    nodes, IPv6-only NICs:
    the decided design on k3s and rke2, the alternative on k3s (§10.11).
  - **Found on the way:** the cluster's CoreDNS forwarded to the node's
    IPv4 nameserver, and the gateway translated that private IPv4
    destination. Two rules follow: an IPv6-only machine has IPv6
    nameservers only (G4), and a gateway refuses a /96 destination that
    embeds a non-global IPv4 address. The refusal is a firewall rule
    behind the translator, probed in §10.11; Jool itself translates
    such a packet.
  - **A, the fallback,** stays unused: carry pod IPv4 over the fabric
    to NAT44 on a gateway.
  *(probe-verified on both transports, PR1 and PR10; planned)*

### Redundancy

- **G6 1-n gateways, active-active, no session sync.**
  - Each gateway translates to its own public IPv4, so replies return to
    the gateway that holds the state.
  - Two gateways is the default; one is allowed.
  - Flows on a failed gateway **stall**; they do not reset (amended
    after PR2). Nothing sends a reset for a dead gateway: 20 s after
    the crash the client's TCP connection was still established and
    silent. An application notices through its own timeout or TCP
    keepalive. A gateway that reboots and returns has no
    state: Jool drops the flow's packets without a reset, so the flow
    still stalls (round G4). New connections go through another gateway. This is
    failover, not hitless high availability.
  - The number of public IPv4 addresses equals the number of gateways.
  - Rejected: conntrackd state sync with a shared address (needs a
    movable public IP); MAP-T (heavy machinery).
  *(planned)*

- **G7 How a client finds a live gateway.**
  - Clan clients: G4's nameserver failover. Inside the fabric, FRR ECMP
    with BFD may also carry a default or a /96.
  - Devices nobody can configure (on-prem): the routers must look like
    one gateway. IPv4: a VRRP virtual address per zone (keepalived).
    IPv6: router advertisements from every router. DHCP: kea high
    availability.
  *(planned; the unmanaged set is G17's)*

### Router

- **G8 Dual-stack is the base.** kea for DHCPv4, corerad (G15) for router
  advertisements from the delegated prefix (N10, N16), NAT44, and an
  IPv6 firewall that drops inbound by default. This is the tested
  default. *(planned)*

- **G9 IPv6-mostly is a tested option, default off.**
  - DHCP option 108, PREF64 in router advertisements, NAT64 on the
    router.
  - DNS64 stays off on a LAN: a client that honors option 108 brings its
    own CLAT, and DNS64 would push dual-stack clients through NAT64 too.
  - It brings no speed or resource gain. It reduces IPv4 leases, which
    matters on large sites, and gives the NAT64 code daily use.
  *(planned)*

- **G10 ULA is a tested option; on for the home router.**
  - A generated /48 (a public clan var), one /64 per zone, advertised
    beside the public prefix. Public addresses stay the primary ones.
  - It gives service addresses and firewall rules that survive a change
    of the ISP's delegated prefix, and it is the inside prefix of G16.
  *(planned)*

- **G11 Zones.**
  - A zone is a netif zone label (N10). The router gives it meaning:
    per zone `internet` (bool) and `allowTo` (a list of zones).
  - Default deny between zones. Replies to allowed flows pass.
  - A zone is a routed port or a VLAN on a trunk port. There is no
    software bridge.
  - Each zone has its own IPv4 subnet and its own /64 (and ULA /64).
  - An mDNS reflector between two zones is opt-in per pair.
  - Two devices in one zone are not separated by the router: client
    isolation is the access point's or the switch's job.
  - The home matrix (owner, 2026-11-20):

    | Zone | Who | Internet | May reach |
    |---|---|---|---|
    | `dev` | developer computers | yes | `servers`, `mgmt` |
    | `servers` | Kubernetes nodes | yes | nothing |
    | `home` | phones, watches, laptops | yes | `iot` |
    | `iot` | smart speakers, TVs, consoles | yes | nothing |
    | `guest` | visitors | yes | nothing |
    | `mgmt` | switch, access points, the optical module | no | nothing |

  - A managed switch is not required: a router port is a zone by
    itself, and a router port can be a VLAN trunk straight to an access
    point. One is needed when several zones share one cable through a
    switch (two or more access points).
  *(planned)*

### Exposure

- **G12 Three classes of service.**

  | Class | Reached by | Inbound port |
  |---|---|---|
  | 1 Private | the tailnet (G13) | none |
  | 2 Public web | Cloudflare Tunnel, day-2, from inside the cluster | none |
  | 3 Direct | a forwarded port, or SIIT on a cloud gateway | yes |

  - **The home router's default has no inbound port.**
  - Class 3 stays available:
    - on a router, a port forward to one stable address that FRR spreads
      over the Kubernetes nodes by ECMP (`routed-fabric`). The cluster's
      gateway routes by hostname; a systemd service on any host is one
      more backend. The router terminates no TLS;
    - on a cloud gateway, Jool SIIT maps a public IPv4 to an IPv6
      service address, statelessly.
  - IPv6 needs no sharing: a host has its own public address and the
    firewall opens one pinhole. A Kubernetes Service gets its own
    public IPv6 address through G20.
  - Class 2's cost: Cloudflare terminates the TLS and can read the
    traffic.
  *(planned)*

- **G13 The VPN control server is Headscale, as a systemd service on a
  cloud machine with a public IPv4.**
  - Not at home (one dynamic address, and a home outage would lock
    everyone out) and not in Kubernetes (P5).
  - It cannot sit behind Cloudflare's proxy or tunnel (Headscale's docs
    say so), so it is class 3.
  - Headscale is the only tested and supported control server. NetBird
    is a separate, later piece of work.
  - Its clanService is outside this spec's first scope; `tests/headscale-vm.nix`
    already runs an offline Headscale.
  *(planned)*

### DNS, advertisements, metrics

- **G14 CoreDNS everywhere.**
  - It forwards to Cloudflare over TLS, so the ISP cannot read the
    queries. The ISP still sees destination addresses and most TLS
    server names.
  - On cloud gateways: the `dns64` plugin (G4).
  - On routers: a blocklist through the `hosts` plugin, and static
    records. CoreDNS takes no dynamic updates: device names come from
    mDNS and from static records (the owner keeps machine names in
    Cloudflare).
  - **The blocklist** is HaGeZi's DNS blocklists (GPL-3.0, free and
    open source), packaged in `pkgs` from a pinned input and updated by
    a lock bump. `blocklist.tier` is an enum of HaGeZi's tiers; the
    default is `pro-plus-plus`; `null` turns blocking off. Lists go
    stale in weeks, so the pin needs a regular bump.
  - A device that uses its own DNS over HTTPS skips the blocklist.
  - Reason (owner): one declarative file, plugins, native metrics, the
    DNS server the clusters already run.
  *(planned)*

- **G15 corerad sends router advertisements.** Reason (owner): native
  Prometheus metrics, a modern implementation. The netif router probe
  used radvd, so probe PR3 re-proves prefix delegation, PREF64 and the
  DNS options with corerad.
  - Proven (PR3, §10.2): `prefix = "::/64"` advertises every /64 on the
    link, the delegated one and the ULA, also when the delegated one
    arrives after corerad started. RDNSS, DNSSL and PREF64 reach the
    client. The metrics name each prefix.
  - Name the DNS server address. With the wildcard `::` corerad exits
    at start while the link's address is still tentative.
  - Stopping corerad withdraws the default route from every client at
    once (it sends a final advertisement with a zero lifetime).
  - corerad does not react to a prefix change: G22.
  *(probe-verified, PR3)*

- **G16 Multi-WAN on one router.** Built after single WAN is proven.
  - IPv4: one default route per WAN with different metrics (netif N21,
    to amend); NAT per WAN; a health check that tests the upstream, not
    just the link.
  - IPv6: one inside prefix; prefix translation (NPTv6) on the backup
    WAN. Rejected for now: advertising both prefixes and deprecating
    the dead one (hosts switch slowly).
  - Flows reset on failover. Class 3 services do not survive a backup
    WAN behind carrier NAT; classes 1 and 2 do.
  - A modem that presents Ethernet with DHCP is just a second WAN link.
  - **Mechanism (decided 2026-11-21; PR9, §10.10): failover changes
    no route.**
    - Each WAN has a routing table of its own with its default route
      (netif `routingPolicy.table`), and IfState declares one fwmark
      rule per WAN and family.
    - One nftables rule sets the mark of the active WAN on traffic that
      the main table would send to a WAN. The health check replaces
      that one rule and deletes the conntrack entries of the WAN it
      leaves. IfState never sees a change,
      so an apply cannot undo a failover.
    - The primary's default route stays in the main table: the
      router's own sockets need a route when they connect, before the
      mark exists, and replies must pass the reverse-path check.
    - The health check pings a target through each WAN with that WAN's
      mark. Three failures move traffic off the primary, three
      successes move it back.
    - IPv6 on the backup: a stateful prefix rewrite of the source
      (`snat ip6 prefix to`), from the primary's delegated prefix and
      from the ULA prefix. The host part is kept.
    - Measured: 6.2 s to fail over (dead upstream with the link up, and
      a dead link), 4.4 s to fail back, both families, also for the
      router's own traffic.
  - **Added by the suite (`gateway-dual-wan`, 2026-11-21, DHCPv4 WANs):**
    - The health check deletes only the conntrack entries of the WAN
      it leaves: a new flow copies the packet mark into `ct mark`, and
      the check runs `conntrack -D -m <mark>`. Flows to the router and
      between LANs keep their entries. `conntrack -F` is gone.
    - **Every WAN that can become active has a default route in the
      main table**, the primary's first by metric. With only the
      primary's, an expired DHCP lease on the primary removes it, the
      steering rule matches nothing, and IPv4 is dead for forwarded
      and local traffic. This corrects "the primary's default route
      stays in the main table": it does not stay when the lease ends.
    - A health ping is bound to its WAN's link as well as marked. A
      WAN's table is empty without a lease; a marked packet then falls
      through to the main table and the dead WAN looks healthy.
    - **The forward chain drops WAN to LAN and WAN to WAN for new
      flows.** Inbound to the translated prefix has no LAN route (the
      rewrite is source-only) and would leave through the other WAN:
      without the drop the router is a transit between its ISPs.
    - Start state: the health check must not count failures before
      the primary had time to get its lease. Seen once: the router
      started on the backup and corrected itself after three good
      checks.
    - Hysteresis of three checks is enough: a primary that flapped
      3 s down, 3 s up for 24 s moved nothing; 7 s down, 1 s up moved
      once.
  - **Corrected by the review (round G4, 2026-11-21; §13.1):**
    - **The ruleset is the only record of the active WAN.** The
      steering lives in a table of its own (`inet wan_steer`) that the
      health check owns and loads; `nftables.service` never touches
      it. The check reads the active WAN from that table every round
      and keeps only its counters. Before, the check held the state in
      a variable and the rule sat in the firewall's table: a firewall
      reload while failed over sent traffic into the dead primary, and
      a restart of the check on the backup never moved back.
    - **A flow leaves by the WAN it arrived on.** A new flow that
      arrives on a WAN gets a conntrack mark for that WAN (`0x11`,
      `0x12`); a steered flow gets `1` or `2`. The packet mark is
      restored from conntrack (`ct mark & 0xf`) before steering, and
      only a packet without a mark is steered. Before, a connection to
      the backup's address (SSH, WireGuard, a port forward) was
      answered through the primary and died. A failover deletes marks
      `1` and `2` only, so inbound flows survive it.
    - **The router's firewall is on in the suite**, with
      `checkReversePath = "loose"`. A strict reverse-path check drops
      steered traffic (asserted).
    - **A WAN's own subnet is not steered**: a set of the WAN subnets
      returns before the steering rule. The router and a LAN host
      reach each WAN's gateway in both states. The set is static in
      the suite; for a DHCP or delegated WAN it is a runtime value.
    - **Start:** failures count from the primary's first lease, or
      after 20 s. No move at boot. A boot with a dead primary reaches
      the backup for IPv4 after 6 to 8 s and for IPv6 after about 25 s.
    - **A failed `nft` call** skips the round and deletes no flow.
    - **A dead health target moves nothing** when both WANs are fine.
    - **Three checks of hysteresis do not hold against packet loss:**
      30 % loss on the primary for 60 s gave no move in one run and
      four in the next. Each move resets every steered flow. Open
      (§13.2): several targets, and a longer hold before failback.
  - **Open, before code:**
    - **netif N21 to amend** (proven with a fixture unit, `wan-routes`):
      netif renders a DHCP lease's gateway into the link's
      `routingPolicy.table`, and a second default in the main table
      for a backup link. Today `defaultRoute.ipv4 = false` means
      dhcpcd's `nogateway`, and a DHCP link's table gets no default;
    - **netif's guard and a dead WAN:** the guard requires a DHCP
      default and a neighbour answer per gateway. With the primary's
      cable out, any IfState apply fails `netif-guard` after its 30 s
      timeout ("no DHCP default route on eth1"). Traffic stays on the
      backup. The guard stays failed after the cable returns, until
      the next apply. A new configuration deployed during a primary
      outage would be rolled back (asserted for the unchanged
      configuration: "no earlier network configuration to roll back
      to"). With two WANs the guard must accept one live WAN;
    - an IPv6 default route learned from an advertisement expires as
      the DHCPv4 one did; the suite's IPv6 is static and cannot show
      it. A WAN address from DHCP cannot be named in a static `from`
      rule. A per-ISP resolver is reached through the wrong WAN;
    - the backup's delegated prefix is a runtime value, as in G20: the
      rewrite rule is written by G22's hook. Not proven: the suite's
      WANs have static IPv6.
  *(planned; the mechanism is suite-verified for DHCPv4 WANs with
  static IPv6: `gateway-dual-wan`, `GATEWAY_DUAL_WAN_OK`)*
- **G17 Multi-WAN with several routers (on-prem, two carriers).** Design
  only until G16 is proven.
  - Inside: G7's set for unmanaged devices (VRRP, advertisements from
    every router, kea high availability).
  - A router whose WAN fails lowers its VRRP priority (health-tracked)
    and can still forward through its peer over a link between them.
  - Two WAN modes per site:
    - `dhcp`: each router NATs to its own carrier; IPv6 as in G16.
    - `bgp`: the site owns an AS number and provider-independent
      prefixes; FRR speaks eBGP to both carriers. No NAT for IPv6, and
      inbound addresses survive a carrier failure. The sessions are
      `routed-fabric` border sessions (G21): this mode adds no second
      BGP implementation.
  - No session sync (G6).
  *(planned)*

- **G18 Metrics: expose, don't host.**
  - `metrics.enable` per service.
  - Endpoints listen only on the machine's fabric address. The host
    firewall allows the monitoring cluster's pod CIDR (native routing
    keeps a pod's source address).
  - Scrape targets are a clan export. Prometheus, Grafana and the Cilium
    policy that limits which pods may scrape are day-2 (SPEC.md §3.3).
  - CoreDNS and corerad have native endpoints; kea and FRR have
    exporters; nftables counters and Jool statistics come from a small
    textfile collector.
  *(planned)*

- **G19 Flow records and capture are a later slice.** Firewall drop logs
  and flow records first; Suricata on the WAN optional; packet capture
  on demand only. *(planned)*

### Public addresses for services

- **G20 A public service prefix on a router** (owner, 2026-11-20; use
  case U17). A Kubernetes Service behind a router gets a public IPv6
  address out of the prefix the ISP delegates. Example: a game server
  as a `type: LoadBalancer` Service.
  - **The cluster side is SPEC.md D8, unchanged, and the same at home
    and in the cloud.** An explicit LB-IPAM pool with `shared-bgp` or
    `node-bgp` delivery; Cilium advertises each address as a /128 to
    the node's FRR; the fabric carries it to the edge. Only the edge
    differs:

    | Site | Who routes the prefix to the fleet | Edge |
    |---|---|---|
    | Cloud | the provider, to a node (node-bound) or as a floating block | the node itself, or a border (D8) |
    | Home, on-prem | the ISP, to the router (prefix delegation) | the router (this decision) |
    | Owned space | a transit provider, to a border | the border (G21) |

  - **The service prefix.** `servicePrefix.subnet` reserves one subnet
    id of the delegated prefix (a /64) for Services. No link gets it
    (netif N16, `reserve`, to amend). The home /60 has 16 subnets; six
    zones and one service prefix use seven.
  - **The router learns the /128 routes as a `routed-fabric` member**
    (N10, U3). This decision adds no BGP of its own and no session to
    the ISP. A `shared-bgp` pool gives ECMP over the nodes.
    `externalTrafficPolicy: Local` keeps the client's address.
  - **Two pool modes**, because a delegated prefix is a runtime fact
    (N16) and a pool is a literal (D8):
    - `translated`, the default: the cluster pool is a stable /64 of
      the router's ULA /48 (G10). The router rewrites the prefix of
      inbound destinations, and of the replies, between the public
      service prefix and that /64. The host part is kept. The public
      side of the rule is a runtime value, never a literal. The
      cluster's configuration does not change when the ISP renumbers.
      G16 needs the same mechanism on a backup WAN.
    - `literal`: the owner states that the prefix is static (a static
      ISP assignment, or owned space, G21). The pool is that prefix and
      nothing is rewritten.
  - **Pinholes.** `servicePrefix.expose` is a list of
    `{ host; protocol; ports; }`, empty by default. The router forwards
    from a `wan` zone only to those. A LAN zone reaches an exposed
    service the same way; `allowTo` does not apply to it.
  - **Unused addresses are unreachable** on the router, so a packet to
    one never returns to the ISP.
  - **IPv4 for the same Service** is G12's port forward to its IPv4
    address in the fabric pool. A home has one dynamic IPv4, shared by
    port.
  - **Limits.**
    - The address is as stable as the ISP's delegation. A stable DHCP
      identity helps (netif N33). A fully static address
      needs owned space (G21) or a cloud prefix carried over the
      fabric.
    - DNS must follow a renumbering. Only the router knows the public
      prefix; how a DNS updater learns it is open, and the updater is
      day-2.
    - SPEC.md D10's non-goals stand: no public BGP for a residential
      IPv4 address.
  - Rejected: a slice of a zone's /64 with an NDP proxy (for an ISP
    that delegates a single /64). Design only; not planned.
  - **Proven (PR6, §10.3)** with nftables' stateful prefix NAT
    (`dnat ip6 prefix to ip6 daddr map { <public>/64 : <ULA>/64 }`):
    the host part is kept, the node sees the client's address, a closed
    port is dropped, an unused address answers "no route" at once, a
    LAN zone reaches the service by its public address, and after a
    prefix change one rule replacement moves the service.
  - The rule is replaced as a whole. A named map in that statement is a
    syntax error in nftables 1.1.7.
  - Pinholes match the stable ULA address, after the rewrite. They
    never name the public prefix.
  - dhcpcd installs an unreachable route for the whole delegated
    prefix, so an unassigned subnet is refused without any rule. The
    stable /64 needs its own unreachable route.
  - The rewrite is not RFC 6296 NPTv6: that one changes the host part
    of a /64 to keep checksums. This one is stateful and keeps it.
  - The rule is updated by G22's hook.
  - **Limit (round G4): a backend cannot reach its own public
    address.** A request from the node that holds the Service address
    to `<public>:f::80` is rewritten to the node's own address and
    never answered. Not tested: a second host in the same zone. The
    fix is a source rewrite when a packet leaves by the link it came
    in on.
  - **Each zone has its own resolver address** (round G4): CoreDNS
    binds one address per zone and the input chain accepts port 53
    from a zone only to that zone's address. Before, zone `servers`
    was advertised a resolver nobody served.
  *(probe-verified, PR6; `servicePrefix` is planned)*

- **G21 Owned address space** (owner, 2026-11-20; use case U18). The
  owner will hold an AS number and provider-independent IPv6 prefixes
  from a regional registry (Europe, North America or both), through a
  sponsor. The fleet announces them itself.
  - **One owner for upstream BGP: the `routed-fabric` border**
    (SPEC.md D9, D56). `border.upstreamPeers` and
    `border.ownedPrefixes` exist; pools must lie inside the owned
    prefixes (D8). G17's `bgp` mode is a router that is also a border.
  - **Where the prefixes are announced.** On any border whose provider
    offers a BGP session: a cloud machine first, an on-prem site with
    carriers later (G17). A residential ISP offers none, so a home
    reaches owned space over the fabric, from a border elsewhere. A
    home Service then uses G20's `literal` mode and keeps its address
    when the ISP changes.
  - **What the border lacks today.** It was built for a private
    upstream router. Each point needs its own SPEC.md decision before
    code:
    - a public AS number on upstream sessions; private fabric AS
      numbers (D64) never leave the fleet;
    - only aggregates are announced (IPv6 /48 or shorter, IPv4 /24 or
      shorter); exact Service routes stay inside the fabric. Today the
      filter permits owned prefixes down to /128 and /32;
    - inbound, a default route or a full table, per peer. Today only
      the owned prefixes are accepted, with a limit of 4096 prefixes;
    - per peer: BFD optional (forced today), multihop, and a session
      password as a clan var (AGENTS.md rule 6);
    - route-origin validation (RPKI) on inbound routes, optional.
  - **Kept:** a border announces nothing outside its owned prefixes and
    never passes one upstream's routes to another.
  - **Several sites.** One prefix announced from several borders is
    anycast: a flow may enter at one border and leave at another, so it
    suits stateless services. One prefix per region is the simple
    shape. A /48 is the smallest announcement, so two regions need two
    /48s.
  - **Never rendered:** registry objects (route objects, ROAs, reverse
    DNS delegation). They are the owner's tasks at the registry.
  *(planned; design only, after G16)*

### Found by the probes

- **G22 A prefix change is handled, not waited out** (decided
  2026-11-21; PR3, §10.2). When the ISP delegates another prefix, a
  client keeps its old addresses as preferred for the advertised
  lifetime (4 hours with corerad's defaults) and keeps using them as
  source: IPv6 to the internet is dead until then. Neither daemon
  repairs this by itself:
  - corerad sent no advertisement for 45 s after the change and never
    marked the old prefix;
  - radvd 2.21 copies the lease's lifetimes into its advertisements, so
    an old prefix dies with the lease, which is hours or days at a real
    ISP.
  The router therefore runs a prefix hook. On a change it:
  - writes corerad's configuration with the old prefix listed as
    `deprecated` (preferred lifetime 1 s, valid 2 h; zero is refused)
    and restarts corerad, which advertises at once. In the probe the
    client marked the old addresses deprecated and used the new prefix
    within 5 s;
  - replaces the service prefix rule (G20);
  - keeps the last prefix on disk, so a prefix that changed across a
    reboot is deprecated too.
  corerad's configuration is thus a runtime file, not a store path.
  Advertised lifetimes are also shortened (RFC 9096: preferred 45 min,
  valid 90 min) for the case the hook misses.
  - **netif's part (N16, amended):** netif owns dhcpcd's exit script.
    It writes the delegated prefix to `/run/netif/pd/<interface>`, only
    when it changes. The router watches that file with a systemd path
    unit; nobody else hooks dhcpcd.
  - **Proven from end to end (PR8, §10.7):** 5.1 s from the new
    prefix on the router to a client that prefers it, has retired the
    old one and reaches the internet; the same when the prefix changed
    while the router was off; no run of the hook when dhcpcd restarts
    with the same prefix.
  - The hook restarts corerad with `systemctl --no-block`. corerad is
    ordered after the hook, so a blocking restart from inside the hook
    never returns: in the first run it left corerad stopped and hung
    the next boot.
  - A restart of corerad keeps the clients' default route (the NixOS
    unit restarts it with SIGHUP).
  - **Added by the suite (`gateway-router`, 2026-11-21):**
    - **The hook's state file must be on persistent storage, and that
      is not enough.** With the file lost and the prefix changed while
      the router was off, the router advertises only the new prefix.
      Clients keep the old one preferred beside it (up to the
      advertised 45 min), the kernel picked the old source, and IPv6
      to the internet was dead. Only the shortened lifetimes bound
      it. Open: a way to retire a stale prefix without state (for
      example: retire every global prefix seen on a zone link that is
      not inside the current delegation).
    - A subnet id that does not fit the delegation gets nothing, never
      a wrong prefix: dhcpcd refuses it ("invalid prefix"), the hook
      lists no /64 for the zone and writes no service rule. IPv4 and
      the ULA keep working. The service asserts at evaluation that
      every subnet id fits the delegation hint. Proven with a /56, a
      /60 and a bare /64.
    - Several retired prefixes are advertised together (two changes
      11 s apart); both survive a reboot.
    - corerad counts a deprecated prefix down: clients see a preferred
      lifetime of 1 s or 0, valid at most 2 h.
    - NetworkManager 1.58 follows the retirement like the kernel
      client, 0.1 s behind.
    - Open: a lease shorter than the retirement window.
  - **Corrected by the review (round G4, 2026-11-21; §13.1):**
    - **A stale source is refused at once, not timed out.** The hook
      keeps the set of delegated prefixes in nftables. IPv6 from a LAN
      zone to a WAN with a source outside that set is rejected on
      ingress of the LAN link (`netdev router_src`, `icmpv6
      policy-fail`). A client that still prefers a retired prefix, or
      uses its ULA, gets an error in 0.05 s and tries its next address.
      Before, such packets left the WAN and died: a 5 s timeout per
      connection, for up to 45 minutes in the state-lost case. The ISP
      now never sees a retired or ULA source (asserted).
    - The reject sits on ingress because a reject in the forward hook
      is routed by its destination: the router has no route to a
      retired prefix, so the error left through the WAN.
    - **The state-lost case is bounded by that filter**: a fetch by
      name took 0.07 s (5.09 s before). The stale prefix is still
      preferred on the client until its lifetime ends; it just fails
      fast.
    - **The prefix file is a set** (netif N16): the current prefix
      stays current while it is listed. A missing file retires the
      current prefix and drops the service rule.
    - **A renew in place is tested.** The ISP changes its pool and the
      router renews at T1 by itself: clients were on the new prefix
      3.4 s after the file changed. kea 3.2.1 sends the old prefix
      with both lifetimes 0. An ISP that sends it with a valid
      lifetime left is covered at the exit script only.
    - **A lost path event is handled.** systemd drops an event that
      fires while the hook runs (shown). The hook reads the file again
      and loops until what it handled equals the content.
    - **The hook converges after a failure.** State is synced to disk
      before anything is applied; the tables carry a generation that
      is compared with what is loaded; corerad's applied configuration
      is recorded only after its restart was queued. A failed
      `systemctl` or `nft` is repaired by the next run. An empty or
      corrupt state file counts as no state.
    - corerad and the hook need `StartLimitIntervalSec=0`: six
      restarts in 10 s left corerad down for good.
    - **Open: boot.** The file is absent until dhcpcd's first reply,
      and absent also means "delegation lost". The hook retires the
      stored prefix at boot and restores it a moment later: two
      corerad restarts and a short deprecation on every boot. A boot
      grace period, or a marker from netif for "no reply yet", closes
      it.
  *(planned; suite-verified on a fixture: `gateway-router`,
  `GATEWAY_ROUTER_OK`)*

- **G23 The CLAT** (decided 2026-11-21; PR2, §10.1). A machine without
  IPv4 that must reach IPv4 literals runs a CLAT:
  - a namespace and a veth pair declared as in G2, with Jool SIIT in
    the namespace (Jool does not translate packets the host itself
    generates, so the host routes them into the namespace);
  - `192.0.0.1` on the host side, an IPv4 default route into the
    namespace with MTU 1480, IPv6 forwarding on the host;
  - a second IPv6 address for the CLAT, routed to the machine. A cloud
    machine takes it from its own /64;
  - an explicit address mapping for the host and the gateway's /96 as
    `pool6`.
  - **A CLAT has one `pool6`, so it follows one gateway.** When that
    gateway died, IPv4 literals failed until `pool6` was changed; one
    `jool_siit global update pool6` repaired it without touching the
    namespace. The client role therefore runs a small health check
    that points the CLAT at a live gateway. It asks each nameserver
    for `ipv4only.arpa` (RFC 7050): the answer names that gateway's
    /96, and a ping through the /96 shows that it translates. Proven
    (PR7, §10.9): the follower moved the CLAT by itself after a gateway
    died. Each gateway's DNS therefore serves `ipv4only.arpa`.
  - Rejected for the host path: one shared /96 for all gateways. It
    needs a route that follows gateway health, which is the fabric,
    and G4 keeps the host path off the fabric.
  - **The follower has hysteresis (`gateway-nat64`, 2026-11-21).** It
    checks only its current gateway's nameserver for `ipv4only.arpa`.
    It moves after 8 failed checks in a row (1 s timeout each), to
    another nameserver that answers, and never moves back while the
    current gateway is healthy. It keeps its choice across a restart.
    At 30 % packet loss on the current gateway: no move in 40 s (the
    longest run of failed checks was 5). After a crash: an answer
    through the other gateway in 13 to 15 s, one move.
  - **Each gateway checks its own IPv4 upstream** and serves
    `ipv4only.arpa` only while it answers: it pings a target through
    its own translator; 3 failures withdraw the records, 1 success
    restores them. Records gone after 6 s, the CLAT moved after 11 s.
    The follower's own ping into the /96 is gone.
  - **A sick gateway stops its DNS** (closed in round G4, §13.1). The
    health check stops CoreDNS while the IPv4 upstream is dead and
    starts it again after. A closed port answers with an error at
    once, so systemd-resolved moves on its first query. Measured: DNS
    closed 5.6 to 6.1 s after the upstream died; an uncached IPv4-only
    name answered through the other gateway 8 s after the cut; an IPv4
    literal after 17 to 19 s (the CLAT's 8 rounds).
    - CoreDNS is bound to the health check (`BindsTo`): CoreDNS 1.14.7
      `hosts` keeps the records of a deleted file, so a dead check
      would otherwise leave the gateway "healthy" for ever.
    - Limit: a name cached through the sick gateway stays dead until
      its TTL ends (G4's cap).
    - **Open: the health target.** With one shared target that dies,
      every gateway closes its DNS while translation still works: no
      name resolves (asserted). The CLAT stays put and its flows live.
      Targets must be several and differ per gateway (§13.2).
  - **Amended in round G8 (§14.5 point 4):** the follower moves after
    60 s without an answer from its gateway's beacon (was 8 checks), and
    the gateway's check uses windows: withdrawn when 30 of the last 60
    rounds are bad, back after 120 clean rounds (was 3 failures down, 1
    answer up). The fixture suite `gateway-nat64` that measured the old
    numbers is removed with our DNS64.
  - **The follower keeps no state** (round G4). Jool's `pool6` is the
    truth, read every round. It moves only to a nameserver that names
    a valid /96; when none answers it stays. A CLAT instance that is
    made again with its default prefix is corrected in about 12 s.
    The prefix is parsed as an address (`64:ff9b::/96` and other
    compressed shapes work), never by cutting strings.
  - On a /64 that is advertised, not routed, the machine answers for
    the CLAT address by proxy NDP (`netif-v6only`).
  - **Known limit:** an ICMP echo over 1232 bytes of payload through
    the CLAT gets no answer. The gateway fragments the reply at
    `lowest-ipv6-mtu` 1280 and Jool SIIT drops fragmented ICMP
    (RFC 7915). TCP and UDP, fragments included, pass. Untested
    proposal: set `lowest-ipv6-mtu` to the real IPv6 path MTU.
  *(planned; suite-verified on fixtures: `gateway-nat64`,
  `GATEWAY_NAT64_OK`; `netif-v6only`)*

- **G24 The health beacon** (proposed round G7, 2026-11-24; accepted
  by the owner in round G8, §14.5 point 2). G23's follower asks each gateway's DNS for
  `ipv4only.arpa`. §14.1 point 3 froze DNS64, and with it the only
  thing that answered. Without a signal a CLAT cannot follow a live
  gateway: a design gap, not a choice.
  - Each gateway runs a beacon: a CoreDNS bound to the gateway's
    address that serves the zone `ipv4only.arpa` only, with the two
    RFC 7050 addresses inside the gateway's own /96 (written by the
    health check; no synthesis, no `dns64` plugin). Any other name gets
    REFUSED; it forwards nothing, so it is no resolver.
  - The health check owns it, as G23 says for the DNS64 listener: it
    starts the beacon while the translator answers and stops it when
    every target fails (§14.3); the beacon is bound to the check
    (`BindsTo`).
  - Only declared clients reach it (port 53, UDP and TCP, in the
    gateway's own table, `beacon-undeclared`).
  - Clients use plain resolvers for names; the beacon is asked only by
    the follower.
  - Rejected: the follower pinging a target through each gateway's /96
    (the client would need internet targets of its own, G23 moved that
    check to the gateway); a route that follows gateway health (the
    fabric; G4 keeps the host path off it).
  - **An answer is proof only for the gateway's own /96** (round G9).
    The follower knows each gateway's /96 from the inventory. A beacon
    that names another prefix (forged on the path, or misconfigured) is
    treated as no answer and logged once: the CLAT is never moved to a
    prefix the inventory does not know.
  *(implemented: `nat-gateway`, `NAT_GATEWAY_OK`,
  `NAT_GATEWAY_FOREIGN_PREFIX_OK`)*

- **G25 A router shares its machine: ownership by link** (round G9,
  2026-11-25; found by the review, §16). The owner's home box is a
  router and a Kubernetes node (§14.5 point 7). The first cut's router
  set `networking.firewall.enable = false` and had `policy drop` on
  input and forward for the whole machine. Every other service opens
  its ports through the NixOS firewall (netif N19, `routed-fabric`,
  k3s, rke2): on a router those rules were void, and the router's
  table dropped the fabric's WireGuard and BGP, the API, and every
  forwarded pod packet.
  - **A router link** is the WAN link or a zone's link. **An unzoned
    link** is every other link of the machine: a fabric's WireGuard
    links, Cilium's links, a VPN.
  - **The router's table judges a packet only when it enters or leaves
    through a router link.** Input from an unzoned link, and forwarding
    between two unzoned links, is not the router's: it accepts, and the
    machine's own firewall decides.
  - **The NixOS firewall stays on** (an eval assertion). On a router
    link a packet must pass both. The router gives the NixOS firewall
    what its own table accepts there (the resolver and DHCPv4 ports per
    zone link); reverse path filtering stays off by default, because
    the prefix hook answers a wrong source with an error (G22) and a
    filter would drop it in silence.
  - **Crossing between the two sides is named, default deny:**
    - unzoned links always reach the WAN;
    - `unzoned.zones`: the zones that exchange flows with unzoned
      links (a zone that reaches the cluster's pods and services), **in
      both directions**. Found by `router-kube`: Cilium sends a local
      pod's packets straight out of the zone's link, past netfilter.
      Connection tracking then sees one direction only and calls the
      other invalid, so the first design (a direction per rule) let the
      SYN in and dropped the client's next packet. The rule for packets
      from the zone is therefore stateless and stands before the
      tracking rules. A flow from the zone is also **masqueraded**
      behind the router's address on the unzoned link: the fabric's
      WireGuard accepts cluster sources only (a LAN client's SYN to a
      pod on another node was dropped there), and the answer then
      returns through the router's stack. Pods see the router as the
      source, not the client. The source is the machine's fabric address, read
      from its `node_transport` export (round G10; the fabric's
      links hold transfer addresses a peer does not accept as a source:
      a plain masquerade chose the LAN address, and the peer dropped
      it). `unzoned.source.ipv4`/`.ipv6` override it. No fabric and no
      override: the outgoing link's address. For a zone that is not named, the router drops
      what the zone sends towards unzoned links: no connection forms,
      but it cannot stop a single packet from a pod on the router
      itself into the zone. A Cilium network policy narrows either;
    - `zones.<zone>.hostPorts` (default off): the zone may reach the
      ports the machine opens to everyone
      (`networking.firewall.allowedTCPPorts` and the like), such as the
      fabric's WireGuard ports. For a zone that holds other nodes;
    - `wanPorts.tcp`, `wanPorts.udp` (default empty): ports of the
      router itself that the WAN may reach. Invariant 3 holds until the
      owner names a port (22 for deploys over the WAN; a WireGuard port
      towards a remote site).
  - **SPEC.md D71:** the router exports its WAN zone (`router`); on a
    cluster member that is a router the WAN link joins Cilium's
    `devices`, so its pods are masqueraded there (the same reason as a
    gateway's uplink, §14.5 point 5). A node behind the router gets
    the link of its default route into `devices` (round G9, §16.2).
  - **A zone link is never a Cilium device** (eval assertion in k3s
    and rke2, `routerViolations`). `devices` is one list of names for
    the whole cluster (§14.2), so a zone link of the router whose name
    another member's uplink also has would get Cilium attached, and
    Cilium would pass that zone's traffic by the router's firewall in
    both directions. Evaluation refuses it and says which name; the
    owner gives one of the two links another name. A `CiliumNodeConfig`
    per node (§14.2, candidate 2) would lift the limit.
  - Not covered: a BGP peer inside a zone (the fabric opens such a
    peer with a rule of its own, not with a port everyone may reach);
    a router that is also a `nat-gateway` gateway (both set the
    forward filter; the rules are rendered, no suite).
  *(implemented: `router`, `ROUTER_OK`; `router-kube`,
  `ROUTER_KUBE_OK`)*

## 3. Invariants (target)

1. Neither service declares a physical link, a VLAN, an address on one
   or a default route: netif does. A service declares only its own
   translator namespace and the veth pair into it (G2, G23).
2. A router with default settings accepts no inbound connection from a
   `wan` zone.
3. No flow passes between two zones unless `allowTo` names the pair.
4. A NAT64 gateway translates only for its declared clients.
5. A metrics endpoint is never reachable from a `wan` zone or a LAN zone.
6. Every global is namespaced by `instanceName` (AGENTS.md rule 5).
7. A router forwards from a `wan` zone into the service prefix only to
   the declared `expose` entries (G20).
8. Neither service renders a BGP session: `routed-fabric` does (G21).

## 4. Out of scope

- IPv4-only networks (P1).
- Registry work for owned address space (G21).
- A DNS updater for a renumbered service prefix (G20): day-2.
- Access points and switch configuration.
- Prometheus, Grafana, Cloudflare Tunnel, the cluster's gateway: day-2.
- NetBird; the Headscale service itself (G13).
- Session sync between gateways (G6).

## 5. Testing contract

- Each service registers its suites under `clanTests.<suite>`
  (AGENTS.md rules 8, 9, 12).
- **Suites that exist (round G3).** They pin the mechanisms on
  fixtures: modules in `lib/gateway/tests/vm/` that stand in for the
  services. When a service exists, its suite imports the service in
  place of the fixture and keeps the assertions.

  | Suite | Pins | Marker |
  |---|---|---|
  | `gateway-wan` | netif N43 (MAC override), N44 (VLAN 0) | `GATEWAY_WAN_OK` |
  | `netif-v6only` | netif N45; G4 and G23 from a host's side; path MTU through both translators | `NETIF_V6ONLY_OK` |
  | `router` (round G7; replaced `gateway-router`, same script) | the `router` service: G8, G10, G11, G14, G15, G20, G22, §14.3's hairpin; netif N16: zones, advertisements, the prefix hook, the service prefix | `ROUTER_OK` |
  | `nat-gateway` (round G7; split in round G9) | the `nat-gateway` service, what it does: G2–G6, G24, §14.1 point 4, a client's own limit, nftables ownership, an IfState apply; since round G9 the gateway's own IPv4 ports closed to the translator, a changed `pool6` or CLAT address reconciled, a beacon that names a foreign /96 ignored | `NAT_GATEWAY_OK` |
  | `nat-gateway-failover` (round G9; the second half of the same file) | G6, G23, §14.3, §14.5 point 4: the timings (withdrawn after 30 s, back after 120 s, a move after 60 s), 30 % and 80 % loss, flapping targets and upstream, dead targets and gateways, a deploy that resumes the health state, reboots | `NAT_GATEWAY_FAILOVER_OK` |
  | `router-kube` (round G9) | G25: a router that is a k3s node. Both firewalls loaded; the cluster up through them; D71 puts the WAN in `devices`; NAT44 for a LAN client, a node and pods; default deny between zones, from the WAN and towards pods; DHCPv4 and DNS through both firewalls; no NodePort on the WAN | `ROUTER_KUBE_OK` |
  | `nat-gateway-kube` (round G8) | §14.5 point 5: a gateway that is a k3s node; D71 puts its uplink in `devices`; Cilium's eBPF masquerade and the gateway's nftables masquerade share one public IPv4; the allowlist on a Cilium node; no NodePort on the public IPv4 | `NAT_GATEWAY_KUBE_OK` |
  | `gateway-dual-wan` | G16; netif N21: two DHCPv4 WANs, failover without a route change | `GATEWAY_DUAL_WAN_OK` |
  | `k3s-v6only`, `rke2-v6only` | SPEC.md D67: the `join` contract on IPv6-only NICs | `<DISTRO>_V6ONLY_OK` |
  | `k3s-clat`, `rke2-clat` | G5 as decided, D67, on the routed fabric; since round G7 on the services (netif, `nat-gateway`, D71's rendered `devices`, a plain resolver) | `<DISTRO>_CLAT_OK` |
  | `k3s-clat-mapped` | why G5 is needed (as shipped, pod IPv4 fails) and the documented alternative; since round G8 with a plain resolver (no DNS64) | `K3S_CLAT_MAPPED_OK` |

- A suite asserts a bound with margin (about three times the measured
  sample), never the sample. It prints the measured value.
- Shared helpers: `tests/suite-lib.nix` (`observe`, `print_versions`,
  `seconds_until`, `holds_for`, `state_dump_on_failure`) and
  `tests/ifstate-noop.nix`.
- Still planned, with the services: `router-ipv6-mostly`,
  `router-service-prefix` with a cluster behind the router, and
  `routed-fabric-transit` (a border and two fake transit providers:
  aggregates only, no private AS number, no route passed between them).
- Every `clan.modules` entry needs a nix-unit test (`coverage.nix`).

## 6. Probes

Each ran before the code it gates. A finding goes into this file first.
All ten are answered, and each became a suite in round G3 (§5); the
`probe-*` suites are gone. A new question starts as a probe again: a
throwaway suite that prints `FINDING` lines, and it ends as assertions
in a real suite (as `specs/netif.md` N40).

| Probe | Question | Gates |
|---|---|---|
| PR1 | Node CLAT with Jool SIIT under Cilium: does pod IPv4 egress work? **Answered, §10.8 and §10.11** | G5 |
| PR2 | Jool beside the nftables firewall: where is traffic filtered? **Answered, §10.1** | G2 |
| PR3 | corerad with a delegated prefix, PREF64 and DNS options. **Answered, §10.2** | G15, G22 |
| PR4 | k3s and rke2 on an IPv6-only underlay. **Answered for both transports, §10.5 and §10.11** | SPEC.md D67 |
| PR5 | MAC override and a priority-tagged WAN (VLAN 0). **Answered, §10.4** | netif N43, N44 |
| PR6 | Prefix rewrite for a routed /64 whose public side is a runtime value: is the host part kept, does the client address survive, are unused addresses refused, what happens on a prefix change? **Answered, §10.3** | G20, G16 |
| PR7 | The CLAT's health check: does `ipv4only.arpa` name a live gateway's prefix, and how fast does the CLAT move? **Answered, §10.9** | G23 |
| PR9 | One router, two WANs: failover without changing a route, IPv6 prefix translation on the backup. **Answered, also for DHCPv4 WANs, §10.10** | G16, netif N21 |
| PR10 | Two nodes with IPv6-only NICs on both transports (`routed-fabric` with native routing, `wireguard-mesh` with the tunnel): does the fabric come up, does the pod network work, does pod IPv4 leave through each node's CLAT? **Answered, §10.11** | G5, G23, SPEC.md D67 |
| PR8 | The prefix hook end to end: netif's trigger, corerad restarted with the old prefix deprecated, the rule replaced, a reboot in between. **Answered, §10.7** | G22 |

## 7. Delivery plan

Each slice: spec, code, eval tests, VM suite, docs.

| Slice | Content | Gate |
|---|---|---|
| S1 | netif: N43, N45 (`netif-v6only`), PR5 | suite green |
| S2 | `lib/gateway` and `router`: single WAN, dual-stack, zones, CoreDNS, corerad (PR3), metrics | `netif-router` green |
| S3 | `router` options: ULA, IPv6-mostly | `router-ipv6-mostly` green |
| S4 | `nat-gateway`: NAT64, DNS64, two gateways, clients (PR2) | `nat-gateway` green |
| S5 | SPEC.md D67 and G5: PR4, PR1 | a suite per distro |
| S6 | G16 dual WAN on one router; netif N21 amended | `router-dual-wan` green |
| S7 | G17 several routers | design review first |
| S8 | G20 service prefix (PR6); netif N16 `reserve` | `router-service-prefix` green |
| S9 | G21 owned address space: the border changes in SPEC.md | design review first, then `routed-fabric-transit` |

## 8. Owner hardware (does not gate the spec)

- Whether the planned NIC accepts the XGS-PON module, and the module's
  heat.
- Whether the ISP gateway bypass gets the full /60 (16 /64s: one per
  zone and one for the service prefix, G20).
- Whether the ISP keeps the delegated prefix stable (G20's limits).

## 9. Glossary

- **CLAT** — the stateless translator on a host that turns local IPv4
  into IPv6 (the client half of 464XLAT).
- **DNS64** — a DNS server that invents an IPv6 address inside the NAT64
  prefix for a name that has only an IPv4 address.
- **IPv6-mostly** — a LAN that offers IPv4 and IPv6, and tells devices
  that can cope to drop IPv4 (DHCP option 108).
- **NAT44 / NAT64** — stateful translation from private IPv4, or from
  IPv6, to a public IPv4.
- **NPTv6** — stateless rewrite of an IPv6 prefix.
- **Owned address space** — prefixes and an AS number registered to the
  owner, not lent by a provider (provider-independent).
- **PREF64** — the router-advertisement option that tells a host the
  NAT64 prefix.
- **Service prefix** — the /64 of a router's delegated prefix that is
  reserved for Kubernetes Service addresses (G20).
- **SIIT** — stateless one-to-one translation between IPv4 and IPv6.
- **ULA** — a private IPv6 prefix (`fd00::/8`).
- **VRRP** — a protocol by which routers share one virtual gateway
  address.

## 10. Probe evidence (2026-11-20, euc-hel-0)

Versions: kernel 6.18.59, Jool 4.1.15, nftables 1.1.7, CoreDNS 1.14.7,
corerad 1.4.0, radvd 2.21, kea 3.2.1, IfState 2.5.1, netif's dhcpcd
10.5. Each probe passed as a sandboxed build on the builder.

### 10.1 `gateway-nat64` (PR2; G2, G4, G6, G23)

Topology: an IPv6-only client and an undeclared outsider on one network;
two gateways, each with its own /96 and DNS64; an IPv4-only server
behind them. `gw1` runs Jool in the host namespace (the NixOS module),
`gw2` in a namespace declared in IfState. Both run the NixOS firewall
with a forward policy of drop.

- **Hooks.** Counters at every hook, `gw1`: IPv6 towards the /96 is seen
  only in PREROUTING at priority -300, not at 0; the translated IPv4 is
  seen only in POSTROUTING. Input, forward and output count nothing in
  either direction. `gw2`: every packet passes PREROUTING, the forward
  chain and POSTROUTING, on the IPv6 side and on the IPv4 side.
- **Open relay.** `gw1` without a rule before Jool's hook: the outsider
  fetched a page through it, forward policy drop notwithstanding. With
  a drop rule at priority -300 it timed out. `gw2`: the outsider timed
  out with one ordinary forward rule.
- **DNS64.** A firewall rule limits port 53 to the clients; the
  outsider's query timed out.
- **Jool's limits.** `pool4 add 10.64.0.2 1024-65535` failed: "Port
  range 1024-65535 intersects with the namespace's ephemeral range
  (32768-60999)". With the namespace's range set to 1024–1099, the
  range 1100–65535 was accepted.
- **IfState.** `ifstatecli check` on `gw2` and on the client listed
  the namespaces and veth pairs as unchanged. After a restart of
  `ifstate.service` the Jool instances were still there and traffic
  passed. The probe's own unit failed on that restart ("already has a
  Jool instance"): the real unit must be idempotent.
- **CoreDNS.** The wildcard listener failed: "listen tcp :53: bind:
  address already in use". Bound to the gateway's address it failed
  some boots with "cannot assign requested address" until
  `net.ipv6.ip_nonlocal_bind = 1`.
- **TTL.** A record with TTL 3600 was synthesized with TTL 600;
  `rewrite ttl suffix short.test. 5` gave 5.
- **The gateway's own IPv4** traffic was unaffected on both.
- **CLAT.** From the client: `curl http://198.51.100.80/` answered with
  the gateway's IPv4 address, ping worked, 2 MB in 0.06 s.
- **Failure of `gw1`.** A name not in the cache resolved through `gw2`
  after 5.6 s. Cached names, with TTL 5 s and 3600 s, worked at once:
  systemd-resolved had moved to `gw2` and flushed. The open TCP flow:
  no new data in 20 s, socket state ESTAB, no reset. An IPv4 literal
  timed out until `jool_siit global update pool6 <gw2's /96>`; then it
  answered through `gw2`.

### 10.2 `gateway-router`, advertisements (PR3; G8, G10, G11, G14, G15, G22)

Topology: an ISP (kea DHCPv4 and DHCPv6 with a delegated /60, radvd), a
router whose links netif renders, a client in zone `home`, a node in
zone `servers`. The router runs nftables, kea, corerad and CoreDNS.

- **netif.** WAN lease, a /60, one /64 on each zone link, zone
  interface names read from `clanServices.netif.zones`.
- **dhcpcd's routes.** `unreachable <delegated>/60 dev lo proto dhcp
  metric 1001`, and one route per assigned /64.
- **corerad.** Started before the delegated prefix existed and
  advertised it later. The client got an address in the delegated /64
  and in the ULA /64, the default route, RDNSS (the router's ULA),
  DNSSL and "NAT64 prefix 64:ff9b::/96" (`rdisc6`). With
  `rdnss.servers = ["::"]` it exited twice at boot: "interface has no
  usable IPv6 addresses".
- **Source address choice.** To a public address the client used its
  public address, to the router's ULA its ULA address.
- **netif clients ignore RDNSS** (N39): the client's DNS came from
  DHCPv4 only.
- **Zones.** home to servers and back: timed out in both families. The
  ISP to a client's public IPv6 address and to the router's port 53:
  timed out. NAT44 answered with the router's WAN address.
- **Blocklist size.** CoreDNS with 300 000 names in the `hosts` plugin:
  about 140 MB of memory, ready within 1 s, a blocked name answered in
  0 ms.
- **Prefix change, corerad.** After the router had the new prefix, the
  client had none of it for 45 s. After a solicitation it had both
  prefixes, both preferred, and chose the old one as source: `curl` to
  the ISP timed out. With the old prefix in corerad's file as
  `deprecated` (preferred 1 s, valid 2 h) the client marked it
  deprecated and `curl` worked through the new one. `preferred_lifetime
  = "0s"` is refused: "preferred lifetime must be non-zero".
- **Prefix change, radvd.** radvd advertised the delegated prefix with
  the lease's remaining lifetimes (valid 234 s of a 240 s lease), not
  with fixed ones. The old prefix was not marked either; the client
  kept using it until its lifetime ran out.
- **Probe trap.** A restart of netif's dhcpcd unit is followed by an
  IfState apply, which removes routes added by hand. Routes with
  `proto bgp`, as FRR installs them, stay.

### 10.3 `gateway-router`, service prefix (PR6; G20)

The node holds `fd00:10:5::80/128`; the router has a `proto bgp` route
to it and an unreachable route for `fd00:10:5::/64`. A script reads the
delegated prefix from a zone link, takes subnet `f` and replaces one
rule.

| From the ISP side | Result |
|---|---|
| `<public>:f::80` port 80 | answered; the node saw the ISP's address |
| 2 MB | 0.1 s |
| `<public>:f::80` port 8080 (no pinhole) | timed out |
| `<public>:f::81` (unused) | "Destination unreachable: No route" at once |
| `<public>:7::1` (unassigned subnet) | "No route" from the router's WAN address |

- The home zone reached the service by its public address.
- After the prefix change the same checks passed on the new prefix once
  the script had run. Until then the old address still answered,
  because the probe's ISP routed both blocks.

### 10.4 `gateway-wan` (PR5; netif N43, N44)

Topology: an ISP with one plain port and one port that speaks only
frames tagged with VLAN 0; a router whose links netif renders.

- **MAC override.** The WAN link is declared by `match.mac` (the NIC's
  permanent MAC) and carries `extraSettings.link.address` (the MAC to
  present). `ip -d link` showed the presented MAC and `permaddr` the
  permanent one. IfState set it before dhcpcd started; kea logged the
  lease for the presented MAC. It held after an IfState apply and after
  a reboot, and the lease was the same address.
- **DUID.** dhcpcd's DUID was built from the MAC of another link (the
  VLAN child's generated MAC), not from the presented one. An ISP that
  keys on the DUID needs netif's stable identity (N33), not the MAC.
- **VLAN 0.** IfState's schema accepts `vlan_id: 0`. netif named the
  child `<parent>.0`. It got a DHCPv4 lease from the tagged-only port,
  and every frame on the wire carried "vlan 0, p 0".
- **Without the child** nothing is answered in either direction. The
  router sends untagged frames, which the ISP's port ignores. Linux
  does accept the ISP's VLAN 0 frames on the plain link and answers
  its ARP request, but untagged, so the answer is dropped. (Corrected
  2026-11-21: the probe said the kernel did not answer. It pinged an
  address the router no longer had.)
- **The child's MAC** is one IfState generates, not the parent's. On a
  real WAN the child needs `mac` too.
- Not shown in a VM: the 802.1p priority bits (they were 0), and what
  an optical module does with the tag.

**As a suite (2026-11-21):** `gateway-wan`, `GATEWAY_WAN_OK`, green
twice in a row (85 s, 99 s). It asserts the lines above, and:
- both DHCP servers and the ISP's neighbour table saw only the
  presented MAC, never the permanent one. kea DHCPv6 logs no hardware
  address; the proof is the link-local source of the request;
- IfState's link change came about 340 ms before dhcpcd's first line,
  and the unit is ordered after `ifstate.service`;
- an apply proposes nothing and changes nothing, after first boot and
  after a reboot; MAC and both leases stay;
- one DUID for both dhcpcd instances, the same after a reboot. Which
  MAC it embeds depends on which instance writes the file first.

### 10.5 `k3s-v6only`, `rke2-v6only` (PR4; SPEC.md D67)

The `k3s-join` and `rke2-join` suites, unchanged, with two differences: each node's only
NIC address is IPv6 (`2001:db8:1::1/64`, `::2`), and the WireGuard
endpoints are those addresses. Every subtest passed: the dual-stack
mesh, the agent joining through its own HAProxy, both nodes Ready with
dual-stack fabric addresses as InternalIP, Cilium healthy. No IPv4
address was on a NIC at any point.

Both distributions passed (k3s in 178 s, rke2 in 288 s).

Not covered by this probe: pulling images (they are preloaded), pod
IPv4 egress (PR1), and `routed-fabric` as the transport.

As suites since round G3: `k3s-v6only`, `rke2-v6only`
(`<DISTRO>_V6ONLY_OK`). One more phase asserts that no NIC has an IPv4
address and that the WireGuard endpoints are IPv6.

### 10.6 `netif-v6only` (netif N45; U13)

Topology: a provider node that routes a /64 to a machine and is its
gateway at `fe80::1` (no advertisement, no DHCP), a second machine that
learns everything from router advertisements, and the provider's DNS64
and NAT64 in front of an IPv4-only server. netif renders both machines.

- **netif already brings such a machine up.** Static: one global
  address, `default via fe80::1 dev eth1 metric 100`, an empty IPv4
  routing table, no IPv4 address but loopback. The lockout guard
  accepted the link-local gateway ("gateways and targets answer").
  `ifstatecli check` listed nothing to change. No unit failed.
- **Advertisements only:** an address by SLAAC, the default route from
  the advertisement at netif's metric, DNS from the link's static
  `nameservers`.
- **Names.** `getent ahosts` returned only the synthesized address, and
  `curl` to an IPv4-only name answered through NAT64.
  `resolvectl query` also listed the IPv4 address: a program that picks
  the IPv4 answer itself fails.
- **An IPv4 literal without a CLAT** fails at once ("could not connect",
  no route), not after a timeout.
- **Reaching the machine:** SSH answered over IPv6; an unopened port
  did not.
- Listening sockets on `0.0.0.0` exist (SSH, LLMNR) and harm nothing.

What is left for N45 is a suite, not code: `netif-v6only` asserts the
lines above, and adds a guard rollback over IPv6.

**As a suite (2026-11-21):** `netif-v6only`, `NETIF_V6ONLY_OK`, green
twice in a row (195 s, 204 s). Both machines now run the CLAT of G23,
so "an IPv4 literal without a CLAT fails at once" is no longer
asserted. After boot, after an IfState apply and after a reboot, on
both machines:
- no IPv4 on the NIC, exactly one IPv6 default route, IPv6 nameservers
  only, no failed unit, an apply proposes and changes nothing;
- a name through DNS64 and NAT64, a literal through the CLAT, ping,
  2 MB each way in under 0.1 s;
- the guard over IPv6: with the gateway silent it failed after 31.4 s
  with "no answer from fe80::1 on eth1".

**Path MTU through both translators** (Jool 4.1.15, kernel 6.18):
- An ICMP "fragmentation needed" from a 1400 byte IPv4 hop behind the
  NAT64 reached the machine through both translators (route MTU 1400;
  1420 on the IPv6 path by name). A "packet too big" from a 1400 byte
  IPv6 hop reached the IPv4 server (1380). 2 MB passed each way after.
- UDP echoes of 1200, 1400, 1452 and 4000 bytes passed on both paths.
- **Gap: an ICMP echo over 1232 bytes to an IPv4 literal gets no
  answer**, with every link at 1500. Both Jool instances cut IPv6 at
  `lowest-ipv6-mtu` 1280; the NAT64 fragments the reply and the CLAT
  drops fragmented ICMP (its counter rose). TCP and UDP are fine.
- A 2000 byte UDP datagram mostly failed and once passed. Not
  understood, not pinned.

**Found on the way:**
- **systemd-resolved's fallback servers.** After every reboot of the
  SLAAC machine the first DNS query took 5 s and resolved logged
  "Switching to fallback DNS server 1.1.1.1". With a CLAT the machine
  has an IPv4 default route, so the IPv4 fallback servers are
  reachable through the NAT64. Root cause of the first timeout not
  found. An IPv6-only machine should set `FallbackDNS=` empty (open,
  G4).
- **Proxy NDP.** On a /64 that is advertised, not routed, nobody
  routes the CLAT's second address to the machine. The fixture answers
  for it by proxy NDP. G23 only described the routed cloud /64.

### 10.7 `gateway-router`, the prefix hook (PR8; G22, netif N16)

The same topology as §10.2, with the hook instead of manual steps:
netif's exit script writes `/run/netif/pd/eth1`, a systemd path unit
watches it, and the hook rewrites corerad's configuration (a runtime
file), replaces the service prefix rule and keeps its state in
`/var/lib/router/prefix.json`.

- **No false trigger.** A restart of netif's dhcpcd unit that brought
  the same prefix left the hook's run count at 2.
- **A live change.** 5.1 s after the router had the new prefix, the
  client had a preferred address in it, every address of the old prefix
  was `deprecated`, and `curl` to the ISP answered. corerad logged the
  old /64s as "DEPRECATED, preferred: 1s, valid: 2h0m0s". The client's
  default route was never withdrawn.
- **The service prefix** moved with the same run: the new address
  answered, the old one timed out.
- **A change while the router was off.** After the boot the hook first
  restored its state from disk, then saw the new prefix and retired the
  other one. The client was on the right prefix as soon as the router's
  links were up.
- **The trap.** `systemctl try-restart corerad` from inside the hook
  blocked: corerad is ordered after the hook. corerad stayed stopped
  and the next boot hung for 300 s. `--no-block` fixed it.

**As a suite (2026-11-21):** `gateway-router`, `GATEWAY_ROUTER_OK`,
green twice in a row (207 s, 224 s). It asserts §10.2, §10.3 and this
section, with a NetworkManager laptop beside the kernel client.
- A prefix change reached the clients in 3.6 to 6.9 s over five
  samples (bound 20 s). Boot to `multi-user.target` took 13 to 17 s on
  three boots (bound 90 s), with no failed unit and no queued job.
- **The service rewrite moved to a table of its own**
  (`inet router_svc`), replaced in one transaction. NixOS
  `nftables.service` deletes and recreates its own tables on a
  restart, so a rule the hook adds to the router's table would be
  lost. Rule for the design: one nftables table per owner, never
  `flush ruleset`. With a third, foreign table present, a restart of
  `nftables.service` and a run of the hook each left all three tables
  byte-equal. netif adds no table.
- An IfState apply proposed and changed nothing; the ruleset was
  byte-equal after it and the hook did not run.
- Zones: each allowed flow works and each refused flow is a silent
  drop, both families, with the drop counters asserted.
- The findings on G22 are listed there.

### 10.8 `probe-k3s-clat` (PR1; G5)

Topology: the `k3s-single` node with an IPv6-only NIC and the CLAT of
G23 (Cilium 1.20, tunnel mode over `wireguard-mesh`, eBPF masquerade and
host routing), a NAT64 gateway built as G2, an IPv4-only server.

- **The node itself** reached the server through its CLAT before and
  after Cilium started.
- **Cilium** reported `devices=wg-mesh` and "Masquerading: BPF
  [wg-mesh]". It added no netfilter rule.
- **As shipped: fails.** The pod's SYN arrived on the CLAT link as
  `10.1.0.5 > 198.51.100.80`, with the pod's address. Jool translated
  that source through `pool6` into an address nothing routes back, and
  `wget` timed out.
- **An nftables masquerade on the CLAT link: fails.** Its counter
  stayed at 0 packets while the pod's packets went out of that link.
- **The pod /24 mapped statelessly: works.**
  `eamt add 2001:db8:1::a:0/120 10.1.0.0/24` in the CLAT, the /120
  routed to the node. The capture showed `10.1.0.201` leaving as
  `2001:db8:1::a:c9` and the answer coming back. From a pod: a page,
  2 MB down, ping. Cluster DNS kept answering.
- The gateway saw one conntrack entry per flow, from Jool's private
  address to its public one.

### 10.9 `gateway-nat64`, the CLAT follower (PR7; G23)

Each gateway's CoreDNS serves `ipv4only.arpa`. A unit on the client
asks each nameserver for it every 2 s, takes the /96 of the first
answer, pings the server's address inside that /96, and updates the
CLAT's `pool6` when the /96 differs.

- Both gateways answered `ipv4only.arpa` with addresses inside their
  own /96.
- After `gw1` crashed the follower logged "pool6 ... -> 2001:db8:a2:0:64:0::/96
  (nameserver 2001:db8:c::2)", and an IPv4 literal answered through
  `gw2` with no manual step.
- **Traps.** The first follower built a malformed prefix and exited 22
  on every cycle; a real one validates what it parses. And the CLAT's
  unit must be idempotent, or an IfState apply fails it and everything
  bound to it.

**As a suite (2026-11-21):** `gateway-nat64`, `GATEWAY_NAT64_OK`, green
twice in a row (272 s, 273 s). It asserts §10.1 and this section. Both
gateways are the shared fixture (Jool in a namespace); the
host-namespace case is a second instance added at run time, asserted
(an undeclared source fetched a page past a forward policy of drop,
with every forward counter at 0), then removed.
- Nameserver failover after a crash took 5.6, 10.2 and 5.6 s in three
  runs (bound 30 s). The 5.6 s of §10.1 was one sample.
- An open flow through the dead gateway stalled for the 20 s watched:
  no reset, the socket stayed established (G6).
- Every private IPv4 range embedded in the /96 was refused and
  counted, on both gateways (G5).
- An IfState apply proposed and changed nothing on a gateway and on
  the client. A gateway reboot brought translation back.
- A 2 MB fetch by an IPv4-only name worked with one gateway down (the
  GitHub case of §12.2).
- Traffic shapes: pings of 1400 and 3000 bytes and a 3000 byte UDP
  echo through the NAT64; path MTU discovery behind a 1400 byte hop
  (the client learned 1420 by name and 1400 through the CLAT); a TCP
  flow idle for 48 s. Jool's established timeout is 2 h, conntrack's
  5 days.
- nftables on a gateway: `inet nixos-fw` and `ip nixos-nat`, both
  owned by `nftables.service`. Jool owns no table. A foreign table
  was byte-equal across a firewall restart, and the whole ruleset
  across a restart of the Jool unit; an open flow survived both.
  `hooks` is an nft keyword and cannot name a table.
- Hysteresis, the gateway's own health check and the ICMP limit are
  in G23.

### 10.10 `gateway-dual-wan` (PR9; G16, netif N21)

Topology: a client, a router with two static WANs, two ISPs, and one
server behind both. netif renders every link; each WAN has
`routingPolicy.table`.

- **First run, no default route in the main table: nothing worked.**
  The router's own `curl` failed at once (no route at connect time),
  and replies to forwarded IPv4 were dropped by the reverse-path check.
- **Second run, marking everything from the LAN: IPv6 was dead.** The
  router's own answers to LAN hosts, neighbour advertisements included,
  were marked and left through the WAN, because a WAN's table has no
  LAN route.
- **Third run: works.** The mark is set only on traffic the main table
  would send to a WAN.

| Event | IPv4 | IPv6 |
|---|---|---|
| Both WANs up | from the primary's address | the client's own address |
| Primary's upstream dies, link up | backup after 6.2 s | backup after 6.2 s, source rewritten to the backup's prefix, host part kept |
| Primary returns | primary after 4.4 s | primary after 4.4 s |
| Primary's cable pulled | backup after 6.2 s | backup after 6.2 s |

- The router's own traffic followed in both families.
- A ULA source was rewritten on either WAN.
- An IfState apply during the failover changed nothing: the fwmark
  rules were listed as unchanged and traffic stayed on the backup.
- netif's guard stayed green with a WAN down, **while the dead WAN's
  gateway still answered its neighbours.** With the ISP's box dead the
  guard fails (G16, open).
- **Still wrong:** from the router, a ping to the backup's gateway
  failed while the primary was active. It was steered to the primary.

**As a suite (2026-11-21).** The probe became `gateway-dual-wan`: it
asserts the above and adds DHCPv4 WANs (kea on each ISP, 30 s leases).
Green twice in a row (291 s, 294 s). Measured, each asserted with a
bound of about three times the sample:

| Event | Measured |
|---|---|
| Dead upstream, or dead ISP box, link up | backup after 6.2 s |
| Primary returns | primary after 2.8 to 3.9 s |
| Cable pulled | IPv4 after 1.1 s (dhcpcd empties the WAN's table), IPv6 after 5.9 s |
| Cable back | primary after 9.3 s |
| Dead ISP box returns (new lease) | primary after 21 to 23 s |
| Reboot with the primary dead | on the backup 8 to 10 s after the health check starts |

- Rules and routes of the main table and both WAN tables were
  byte-equal before and after failover, failback, flapping and the
  reboot cycle. A lease renewal on either WAN changed nothing.
- An IfState apply in normal state, in failed-over state and after the
  reboot cycle changed nothing, and left the `proto dhcp` defaults in
  the WAN tables alone.
- Two flows from a client to the router (one per family) kept their
  conntrack id through failover and failback. The flow through the
  dead WAN got a reset on its next send.
- While failed over, from the backup's ISP: the LAN's real prefix, its
  IPv4 subnet and the translated prefix were all refused; the drops
  were counted.
- Six findings changed G16; they are listed there.
- **Not covered:** DHCPv6 and prefix delegation on the WANs, a dead
  backup, both WANs dead, a flow between two LANs, an IfState apply
  after the primary's lease expired.

### 10.11 `<distro>-clat-<transport>` (PR10; G5, G23, SPEC.md D67)

*Since round G6 (SPEC.md D72) only the fabric topology exists, as
`<distro>-clat` and `k3s-clat-mapped`. The mesh rows below are
history.*

One probe body (`kube-clat.nix`) with the same test script on two
topologies: `fabric` is the `data-plane` suite's (routed-fabric, FRR,
per-pair WireGuard, Cilium native routing), `mesh` is the `join`
suite's (wireguard-mesh, VXLAN tunnel). Two nodes, each NIC IPv6 only,
each node with the CLAT of G23; one NAT64 gateway built as G2; an
IPv4-only server. Eight suites, all green on 2026-11-21 (second
round; seconds are the run's wall time):

| Suite | Seconds | As shipped | Pod pool mapped | CLAT link in `devices` |
|---|---|---|---|---|
| `probe-k3s-clat-fabric` | 220 | fails | works | |
| `probe-k3s-clat-mesh` | 175 | fails | works | |
| `probe-rke2-clat-fabric` | 329 | fails | works | |
| `probe-rke2-clat-mesh` | 321 | fails | works | |
| `probe-k3s-clat-fabric-device` | 154 | | | works |
| `probe-k3s-clat-mesh-device` | 149 | | | works |
| `probe-rke2-clat-fabric-device` | 276 | | | works |
| `probe-rke2-clat-mesh-device` | 289 | | | works |

The same day, every suite of the repo ran fresh on euc-hel-0
(`vm-test --all --remote --rebuild`): the 46 suites outside this
probe passed side by side, none needed a rerun alone.

- **The routed fabric runs on IPv6-only NICs.** WireGuard endpoints
  were `[2001:db8:1::N]:port`, the BGP sessions established, node
  addresses stayed dual-stack on the fabric loopback, and Cilium
  reported "Routing: Network: Native, Host: BPF". No code changed: the
  endpoint is an IPv6 literal and the upstream peer list has no IPv4.
- **The pod network works in both families** between the nodes, before
  and after the CLAT change, in both modes.
- **As shipped, both modes fail the same way.** The pod's SYN reached
  the CLAT link with the pod's address (`10.1.0.58`). Cilium masquerades
  only on its `devices`; in native mode those were the fabric loopback,
  the fabric link and `eth1`.
- **Pod pool mapped: works in both modes.** `eamt add
  <node prefix>::a:0:0/112 10.1.0.0/16` on each node. A pod at
  `10.1.1.8` left as `<node prefix>::a:0:108`.
- **CLAT link in `devices`: works in both modes, with no mapping.**
  Cilium reported "Masquerading: BPF [eth1, clat0, ...]" and the pod's
  SYN reached the CLAT link as `192.0.0.1`. The node's own IPv4 kept
  working with Cilium attached to the link.
- From a pod on each node, in every run: a page, 2 MB down, 2 MB up,
  ping, cluster DNS.
- **Not a network fault:** the earlier "upload sent no body" (§10.8)
  was the test tool. busybox `wget --post-file` reads the file as a C
  string, and a file of zero bytes is an empty string.
- **Stray traffic.** The CLAT link carried "ICMP host 192.168.1.254
  unreachable" from the gateway to cluster pods: the test fixture's
  IPv4 nameserver, forwarded to by the cluster's CoreDNS, translated by
  the gateway. See G5 for the two rules this gives.
- **An IfState apply changes nothing for pods** (second round,
  2026-11-21). After `systemctl restart ifstate.service` on each node,
  the CLAT unit was up again, a pod reached the IPv4 server, and pods
  pinged each other in both families.
- **The gateway refuses private IPv4 destinations, in its firewall.**
  The rule sits in the forward chain behind the translator: a
  translated packet to `10.0.0.0/8`, `100.64.0.0/10`, `169.254.0.0/16`,
  `172.16.0.0/12` or `192.168.0.0/16` is rejected with an ICMP error.
  A pod's request to `172.20.0.1` failed at once with "No route to
  host" and the rule counted it. The translator itself translated the
  packet: Jool does not refuse it.
- **A test trap.** The first run of that check counted nothing. The
  fixture's gateway had no IPv4 default route, so the kernel dropped
  the packet at the routing step. A real gateway has a default route.
  The fixture has one now, and the rule is a firewall rule, never a
  missing route.
- **Not covered by the probe:** a node failure; a gateway failure
  under pod load; ClusterMesh on IPv6-only NICs.

**As suites (round G3, 2026-11-21).** The probe names in the table
above are gone. Each suite is green twice in a row:

| Suite | Seconds | Asserts |
|---|---|---|
| `k3s-clat-fabric` | 400, 401 | the decided design (G5), native routing |
| `k3s-clat-mesh` | 423, 459 | the decided design, tunnel |
| `rke2-clat-fabric` | 495, 594 | the decided design, native routing |
| `rke2-clat-mesh` | 425, 520 | the decided design, tunnel |
| `k3s-clat-fabric-mapped` | 193, 233 | as shipped it fails; the pool mapping works |
| `k3s-clat-mesh-mapped` | 231, 243 | the same, tunnel |
| `k3s-v6only` | 98, 153 | the `join` contract on IPv6-only NICs (§10.5) |
| `rke2-v6only` | 236, 269 | the same |

- **Design suites:** `clat0` is in `devices` and in the agent's
  masquerade list, and Cilium's program is attached to it. A pod's
  SYN on the CLAT link has source `192.0.0.1`; the gateway sees the
  node's CLAT address. 2 MB each way with the byte count asserted,
  ping, cluster DNS, pod to pod in both families, before and after
  every phase.
- **Mapped suites:** `clat0` is not a Cilium device. As shipped the
  request fails and the SYN carries the pod's own address; after the
  mapping, the exact mapped address reaches the gateway. These suites
  pin why G5 is needed: a Cilium change shows here first.
- **An IfState apply** proposes and changes nothing; the link, the
  program and pod egress stay.
- **A node reboot:** the CLAT, the node, Cilium on `clat0`, pod IPv4
  egress and (fabric) the BGP sessions come back.
- **The CLAT link deleted and made again under a running Cilium:**
  Cilium attached to the new link by itself in 3.6 to 12.5 s.
- A ClusterIP Service and pod-to-node traffic never see `192.0.0.1`.
  In tunnel mode a node sees the source node's address for a pod:
  Cilium's normal tunnel masquerade, the same without a CLAT.
- A powered-off k3s or rke2 node takes 92 s to stop in every run (a
  stop timeout of the cluster unit; not looked into).
- **Not covered:** a pod request in the seconds before Cilium attaches
  to a new CLAT link; a node or gateway failure under pod load;
  ClusterMesh on IPv6-only NICs; UDP and path MTU from a pod.

## 11. Rough implementation design (draft, 2026-11-20)

A draft for the owner's review, shaped by the probes. Names may change;
nothing here is decided until it moves into §2.

### 11.1 `lib/gateway/`

| File | Renders | Proven by |
|---|---|---|
| `translator.nix` | a namespace and veth pair in IfState, the registry claim, an idempotent Jool unit (`nat64` or `siit`) | §10.1 |
| `nat64.nix` | the gateway side: `pool6`, `pool4` on the namespace's private address, the masquerade, the forward allowlist | §10.1 |
| `clat.nix` | the client side: `192.0.0.1`, the IPv4 default route with MTU 1480, the address mapping, the health check | §10.1, PR7 |
| `dns.nix` | a Corefile: bound addresses, `forward` over TLS, `dns64`, the TTL cap, the `hosts` blocklist, static records | §10.1, §10.2 |
| `firewall.nix` | one nftables table: zones, NAT44, pinholes, the service prefix chain | §10.2, §10.3 |
| `advertise.nix` | corerad's runtime configuration and the prefix hook (G22) | §10.2, PR8 |
| `dhcp.nix` | kea DHCPv4 per zone | §10.2 |
| `metrics.nix` | listeners on the fabric address, the scrape export | not probed |

### 11.2 `services/router`, role `router`

Settings per machine (zone names are netif zone labels):

```nix
{
  zones.<zone> = {
    internet = true;            # may reach the wan zones
    allowTo = [];               # other zones it may open flows to
    ipv4.subnet = "192.168.10.0/24";
    ipv4.pool = null;           # null: the upper half of the subnet
    subnet = 1;                 # subnet id of the delegated and the ULA prefix
    mdnsWith = [];              # zones to reflect mDNS with
  };
  wanZones = ["wan"];
  ula.enable = false;           # the /48 is a generated public clan var
  ipv6Mostly.enable = false;    # option 108, PREF64, NAT64 on the router
  dns = {
    upstream = ["tls://1.1.1.1" "tls://2606:4700:4700::1111"];
    blocklist.tier = "pro-plus-plus";   # null: no blocking
    records = {};
  };
  portForwards = [];            # { zone; protocol; port; to; }
  servicePrefix = {
    subnet = null;              # e.g. 15: reserved through netif (N16)
    mode = "translated";        # or "literal"
    pool = null;                # translated: a /64 of the ULA prefix
    expose = [];                # { host; protocol; ports; }
  };
  metrics.enable = false;
}
```

- The service reads interface names from `clanServices.netif.zones`
  and the delegating link from netif's facts. It asserts that every
  zone it names exists on the machine.
- A zone link's delegated /64 comes from netif (`prefixDelegation.assign`
  with the zone's `subnet`); the router does not repeat it. Open: who
  writes that `assign` entry, the user in netif or the router service
  through an export. A user who must repeat the subnet id in two
  places will get it wrong.
- Exports: the zones and their static subnets, the DNS address per
  zone, and the scrape targets.

### 11.3 `services/nat-gateway`

```nix
# role gateway, per machine
{
  uplinkZone = "wan";           # where the public IPv4 lives
  pool6 = "2001:db8:a1:0:64::/96";   # inside the machine's own prefix
  dns.listen = "2001:db8:a1::53";
  dns.maxTtl = 30;
  metrics.enable = false;
}
# role client, per machine
{
  clat.enable = false;          # true on Kubernetes nodes (G5)
  clat.address = null;          # an address of the machine's /64
}
```

- A gateway exports `pool6` and its DNS address. A client exports its
  source addresses (the NIC address and the CLAT address).
- The gateway's allowlist and every client's nameserver list are built
  from those exports. Client nameservers are set through netif's
  `nameservers`, which the client role cannot write today. Open: a
  netif option that takes nameservers from an export, or the client
  role writing resolved's global DNS.
- A machine may hold both roles (a gateway is its own client).

### 11.4 What netif needs first (slice S1)

1. `mac` on a physical link (N43). **Done.**
2. A VLAN link with id 0 in a suite, with `mac` (N44).
3. The delegated prefix as a runtime file (N16). **Done**; the path in
   netif's facts is left.
4. `prefixDelegation.reserve` (N16).
5. `netif-v6only` (N45). **Done** (§10.6).

### 11.5 Suite topologies

| Suite | Nodes | Draft |
|---|---|---|
| `netif-router` | isp, router, client (home), node (servers) | `gateway-router` |
| `router-service-prefix` | the same, plus a prefix change | `gateway-router` |
| `nat-gateway` | client, outsider, gw1, gw2, server4 | `gateway-nat64` |
| `netif-v6only` | static, slaac, provider, server4 | done: `netif-v6only` |
| `k3s-v6only`, `rke2-v6only` | the join suites on IPv6-only NICs | done: `<distro>-v6only` |

## 12. Retrospective (2026-11-21): what is not proven, and what would harden it

Written after the probe rounds. Each item says what is weak and what
closes it. Nothing here is a decision; the owner picks what becomes one.

### 12.1 How strong the evidence is

- **Round G3 turned every probe into a suite.** The findings of §10
  are assertions now; a nixpkgs bump that undoes one fails a suite.
  Each new suite passed at least twice in a row, alone, on the
  builder. The first full run beside others (2026-11-21, all 57
  suites, `vm-test --all --remote --rebuild`) passed 57 of 57, none
  as `PASS(!)`. One run is one sample, not a flakiness measure (§12.4).
- **Timings are small samples** (two to five). A suite asserts a bound
  of about three times the sample.
- **The suites run on fixtures, not on service code.** They prove the
  mechanism, not an implementation. The fixtures are the first draft
  of `lib/gateway/` (§11).
- **Clients:** Linux with dhcpcd, the kernel's SLAAC, and
  NetworkManager 1.58 (it follows a prefix retirement like the
  kernel). Android, iOS, Windows and consoles are unproven and need
  the owner's devices.
- **Traffic shapes.** Path MTU discovery through the NAT64 and the
  CLAT is proven for TCP and UDP, fragments included (`netif-v6only`,
  `gateway-nat64`). Known limit: ICMP echoes over 1232 bytes through a
  CLAT (G23). Untested: `traceroute`, idle flows near Jool's 2 h and
  conntrack's 5 day timeouts.
- **Four claims are still from memory:** Windows honours DHCP option
  108, the Nintendo Switch has no IPv6, Headscale is unsupported behind
  Cloudflare, the X710 rejects unqualified SFP+ modules. A VM cannot
  prove them. They need a source or the hardware.
- **What the netif suites do not prove** (found while fixing their
  waits): N16's prefix file is written atomically, only on change,
  and survives a dhcpcd restart (only its existence is asserted in
  `netif-dhcp`; `gateway-router` asserts "no hook run on an unchanged
  prefix"); whether a changed nameserver arrives by renew or rebind
  (N9); the sandbox of the dhcpcd unit (N31); guard targets other than
  TCP (N36); a silent IPv6 gateway in `netif-guard` (N25;
  `netif-v6only` covers it).

### 12.2 Design risks

| Risk | Why it matters | What closes it |
|---|---|---|
| Jool is an out-of-tree kernel module | A kernel bump can break the build of every gateway and every CLAT at once. tayga was rejected, so there is no second translator | An evaluation check that `linuxPackages.jool` is not marked broken for the kernel the fleet runs; the NAT64 suite runs on every `org-pkgs` bump; name tayga as the documented emergency fallback for the CLAT only **Round G3: `checks.jool-available` fails the static check when Jool is broken for the default or the latest kernel; `gateway-nat64` proves it loads and translates.** |
| GitHub has no IPv6 (checked 2026-11-21: `github.com`, `api.github.com`, `codeload.github.com` and `ghcr.io` publish no AAAA record; `cache.nixos.org`, `registry.k8s.io`, `quay.io`, Docker Hub, `git.clan.lol` do) | An IPv6-only machine cannot fetch a flake input from GitHub or an image from `ghcr.io` without a NAT64 gateway. The gateways become a dependency of every deploy and of the gateways' own repair | The two gateways are never updated together; a gateway keeps its own public IPv4 and so never needs NAT64 itself (already G3); a suite phase that fetches from an IPv4-only name through DNS64 with one gateway down **Round G3: the fetch by an IPv4-only name with one gateway down is asserted (`gateway-nat64`). The update rule stays a rule.** |
| The CLAT follower has no hysteresis | It polls every 2 s and moves on the first different answer. Two gateways that both answer, one with packet loss, make it flap, and each move stalls open flows (G6) | Move only after N failed checks of the current gateway; prefer the current one while it is healthy; a suite phase with a lossy gateway **Closed in round G3 (G23, `gateway-nat64`).** |
| The health checks test the gateway, not what is behind it | A gateway whose IPv4 upstream is dead still answers `ipv4only.arpa` and a ping inside its /96 only if the target is beyond the gateway. The probes pinged a test server. The real target is not chosen | Decide the target: the gateway withdraws `ipv4only.arpa` when its own IPv4 check fails, so the client needs no internet target **Half closed in round G3: the gateway withdraws `ipv4only.arpa` and CLATs move; its DNS64 keeps answering (G23, open).** |
| One public IPv4 per gateway is about 64,000 flows per protocol | `pool4` is one address, ports 1100–65535. A cluster pulling images through it can exhaust it; conntrack on the gateway has its own limit | Export Jool's and conntrack's counters as metrics; an alert before exhaustion; `pool4` takes a list of addresses in the settings |
| DNS64 breaks a client that validates DNSSEC itself | A synthesised AAAA record has no signature | Document it; such a machine uses the CLAT and plain DNS. Not a blocker for the fleet (systemd-resolved does not validate by default) |
| `conntrack -F` on a WAN failover drops every flow on the router | LAN to LAN and router-local flows are cut too | Delete only entries whose reply direction used the dead WAN (`conntrack -D` by mark or by address) **Closed in round G3 (G16, `gateway-dual-wan`); a flow between two LANs is not yet in the suite.** |
| Dual WAN on the IPv6 backup is stateful prefix translation | Inbound to the backup prefix needs a matching rewrite; class 3 services do not survive (already G16) | Stated in G16; the suite asserts the inbound direction fails closed, not open **Closed in round G3: asserted, and the suite found the WAN-to-WAN transit (G16).** |
| The prefix hook was tested with one /60 and one change | Unproven: a /56 or a bare /64 (no room for zones), two prefixes at once, an ISP that changes the prefix across a router reboot without the old lease on disk, a lease shorter than the retirement window | Phases in `netif-router`; an assertion at evaluation time that the zones fit the smallest expected delegation **Round G3: /56, /60, /64 and two changes are asserted; state loss across a reboot is a new open gap (G22). Open: a short lease, two prefixes at once.** |
| nftables has several writers and no ownership rule | The NixOS firewall, the router's table, Cilium (through iptables-nft) and the dual-WAN steering all add tables. netif has a registry for links; nothing equals it for tables | A rule in the spec: one table per owner, named after the instance, never `flush ruleset`; a suite assertion that a restart of one owner leaves the others' tables byte-equal **Round G3: the rule is "one table per owner, never `flush ruleset`"; asserted on the router and on a gateway. Open: the same assertion on a cluster node with Cilium.** |
| Deploying an IPv6-only fleet needs IPv6 at the deploying machine | `targetHost` is the underlay address (AGENTS.md rule 11). The home router that provides that IPv6 is deployed by the same clan | Keep an IPv4 path to at least the gateways and the Headscale machine (they have public IPv4); document the bootstrap order: gateways, Headscale, router, the rest |
| CoreDNS replicas share one node (found 2026-11-21, both distros, both modes) | The anti-affinity is soft (`lib/kube-cluster/bundle.nix`) and the bundle applies before the second node is Ready. Both replicas start on the first node and stay. When that node died, cluster DNS was gone (`k3s-data-plane-tunnel`, an early run) | A hard spread when the cluster has two or more members (`topologySpreadConstraints` with `minDomains`); until then the tunnel suite moves one replica by hand before the node dies, and asserts DNS after. The native suite does not check DNS after a death **Closed in round G4: SPEC.md D70.** |
| NodePorts bypass the node firewall | On every link in Cilium's `devices`, Cilium serves NodePorts in eBPF before nftables. A machine outside the cluster reached a NodePort on a node's underlay address (`data-plane-tunnel` asserts it). The services list only the transport's links in `devices`; a suite or a site adds the underlay for a floating address, and the G5 decision adds the CLAT link | Decide: keep the underlay out of `devices` where no floating or BGP address must arrive on it, or enable Cilium's host firewall. A SPEC.md decision, before a cluster faces the internet **Closed in round G4: SPEC.md D69, NodePorts answer on the node addresses only.** |
| A BGP pool on a tunnel transport was refused with the wrong reason | The message said `bgp.enable = false`, which the user never set | **Fixed 2026-11-21:** the message names the transport (`lib/kube-cluster/assertions.nix`) |
| A hot path depends on unit ordering | The hook that blocked on `try-restart corerad` hung the next boot for 300 s (§10.7); a Jool unit that was not idempotent broke on an IfState apply (§10.9) | A suite phase in every gateway suite: `systemctl restart ifstate.service`, then a reboot, then the full assertions again **Round G3: every gateway suite and the CLAT suites reapply IfState and reboot, then assert again.** |

### 12.3 The two Cilium modes: what each suite covers

*Superseded by SPEC.md D72 (round G6): tunnel mode and
`wireguard-mesh` are removed, and every suite runs on the routed
fabric. The table is history. The twins merged under the plain name
(`ha`, `clustermesh-external`, `k3s-modes`); the tunnel column's own
suites were deleted.*

The owner uses the routed fabric (FRR, native routing) most, and wants
the tunnel mode kept equal where the mode allows it.

| Contract | Native routing on `routed-fabric` | VXLAN tunnel on `wireguard-mesh` |
|---|---|---|
| One server | covered inside `data-plane` | `single` |
| A second node joins | covered inside `data-plane` | `join` |
| Three servers, one dies | `ha-fabric` (added 2026-11-21; the dead server is a spine) | `ha` |
| LoadBalancer pools, Node IPAM, firewall, a node dies | `data-plane` | `data-plane-tunnel` (added 2026-11-21): the same workload and pools, without BGP delivery |
| netif renders the underlay | `data-plane-netif`, `routed-fabric-netif` | `join-netif` (added 2026-11-21) |
| ClusterMesh | `clustermesh` | `clustermesh-tunnel` |
| ClusterMesh, external and selective | `clustermesh-external-native`, `clustermesh-selective` | `clustermesh-external`, `clustermesh-selective-tunnel` |
| A cluster inside a mode | `k3s-modes-fabric` (added 2026-11-21; the spine is a second, always-on machine) | `k3s-modes` |
| IPv6-only NICs, two nodes | `<distro>-clat-fabric` | `<distro>-v6only`, `<distro>-clat-mesh` |
| Pod IPv4 egress through a CLAT | `<distro>-clat-fabric` | `<distro>-clat-mesh` |

Closing the gaps without doubling the suite count: a suite body takes
`transport` as an argument, as `kube-clat.nix` does, and the same test
script runs on both. Phases that only one mode has branch explicitly,
as bodies already do on `distro`. Proposed order:

1. `ha` on the fabric: **done.** `k3s-ha-fabric` and `rke2-ha-fabric`
   reuse the `ha` test script unchanged and passed on the first run.
2. The mode-neutral phases of `data-plane` on the mesh: **done.**
   `k3s-data-plane-tunnel` and `rke2-data-plane-tunnel`
   (`K3S_DATA_PLANE_TUNNEL_OK`, `RKE2_DATA_PLANE_TUNNEL_OK`), green
   twice in a row each. A body of its own: the native body reads
   fabric facts and a router in most phases. Both bodies share
   `data-plane-fixtures.nix`; the four native suites stayed faithful
   (`suite-compare`).
   - Covered on the tunnel: multi-pool pod IPAM and pod to pod across
     nodes in both families; ClusterIP from pods in both families;
     LB-IPAM allocation from `external-class` and `floating` pools;
     Node IPAM with the ETP-Local restriction and its withdrawal; the
     firewall from the underlay and from the mesh; a node dies.
   - Native only, absent by design: `shared-bgp`, `node-bgp`, the
     fabric pool and its ClusterMesh address, FRR pod routes. A tunnel
     cluster delivers a LoadBalancer address by Node IPAM (mesh
     addresses), by a floating address on the underlay, or by the
     provider. Never by BGP.
   - Parity holds for pools: no setting was silently ignored.
   - A node crash: `Ready=Unknown` after 40 to 46 s, endpoints not
     ready 0.2 s later, Node IPAM withdrawal 0.1 s after that.
   - Three findings went into §12.2 (CoreDNS placement, NodePorts
     and the node firewall, the BGP pool message).
3. netif under the tunnel: **done.** `k3s-join-netif`,
   `rke2-join-netif` (`<DISTRO>_JOIN_NETIF_OK`), green twice each. The
   `join` body takes `underlay = "netif"`; `join` stayed faithful.
   - On a netif-rendered, untrusted link the mesh takes its MTU from
     the link's `pathMtu` (1500 − 96 = 1404, netif N17).
   - Pods on two nodes reach each other in both families through
     VXLAN over `wg-mesh`.
   - `netif-preview` and a real reapply change nothing: `wg-mesh`, the
     `cilium_*` and `lxc*` links keep their ifindex, the `cni-`
     namespaces stay, the WireGuard session is not reset (netif N6).
   - A rebooted agent comes back with its pod network.
   - No `wireguard-mesh-netif`: without a cluster the mesh has no
     state beyond what these suites assert.
4. A cluster inside a mode on the fabric: **done.** `k3s-modes-fabric`
   (`K3S_MODES_FABRIC_OK`), green twice. It shares
   `services/k3s/tests/vm/modes-body.nix` with `k3s-modes`, which
   stayed faithful.
   - The leaf is in the fabric only in its `kubernetes` mode. The
     spine is a second machine: a spine is in every mode (netif N4).
     On the mesh one machine is enough; this asymmetry is by design.
   - In the mode the spine learns the leaf's pod routes over BGP and
     reaches a pod in both families. In the default mode the leaf has
     no FRR, no tunnel and no fabric address, and the spine has no
     session and no pod route.

No parity defect was found in service code on either transport.
Found on the way: `clan.networkFacts.clusters` is declared
(`lib/kube-cluster/network-facts.nix`) and nothing writes it for k3s;
a suite that wants the pod CIDRs must use literals.

### 12.4 Suite stability

- **Fixed sleeps: fixed in `netif-dhcp` and `netif-guard`** (round G3;
  each green three times in a row). Seven sleeps: six became waits
  for the real condition, one is a polling interval. Three of the new
  waits are stricter than the sleep was: a renewal must be seen, the
  nameserver must stay for 6 s after ten flaps, and the guard's second
  run is identified by its invocation id. The new suites have no
  guessed sleep. Left: `clustermesh*` (a 1 s pause in a retry loop)
  and `external` (a retry loop in a unit).
- **Versions in the output: done for the new and the two fixed
  suites** (`print_versions`). The older suites do not print them.
  dhcpcd is not on `PATH` (netif runs `dhcpcd_latest`); a suite reads
  it from the unit.
- **Failure dumps: one shared helper**, `state_dump_on_failure` in
  `tests/suite-lib.nix`. The new suites use it; the cluster suites
  keep their own.
- **A fresh full run before every merge that touches netif or the
  shared base.**
  Last one: 2026-11-21, 57 of 57 `PASS`, no rerun needed, 24 vCPUs
  in use throughout.
- **Flakiness is unmeasured.** `PASS(!)` is recorded per run and then
  forgotten. A log of which suites needed the rerun, kept across runs,
  shows which waits to fix first. Not done.
- **Fixtures are test code.** The CLAT node, the gateway and the
  router's hook live in `lib/gateway/tests/vm/`. They move to
  `lib/gateway/` as modules with the services (S2, S4), and the suites
  import the modules, so a suite tests the code a machine runs.
- **A unit that has not run reads as a success.** `systemctl show -p
  Result` prints `success` before the unit's first run. Right after a
  reboot, a wait on `Result=success` passes at once with the link
  still down. After a reboot, wait for what the unit renders.
- **`hooks` is an nft keyword** and cannot name a table in a suite.

### 12.5 The agent's working environment

- **Number ranges lived in three files.** Done: `AGENTS.md` no longer
  repeats them; each spec file states its own.
- **Section order.** Done: `checks.spec-headings` fails when the
  section numbers of `SPEC.md` or `specs/*.md` do not ascend.
- **The verified upstream facts left `AGENTS.md`.** Done: they are
  `documentation/docs/reference/upstream-facts.md`, and `AGENTS.md`
  points to it.
- **Findings are read out of a 10,000-line build log.** Open: if
  `vm-test` copied lines that start with `FINDING` or `VERSION` into
  `summary.txt`, a result would be one short file. That is an org-pkgs
  change.
- **Several agents on one builder.** Round G3 ran eight agents on one
  worktree with one lock around every `vm-test` call. It worked; each
  suite waited long for its turn. The runner has no queue of its own.

## 13. Devil's advocate review (round G4, 2026-11-21)

The owner asked for the strongest case against the work so far. Four
reviewers read every new suite against the claims of §2 and §10, the
test script, not the summary. This section is the result. §13.1 is
what was wrong and is fixed on this branch. §13.2 is what the owner
must decide. §13.3 is what is still unproven.

### 13.1 Found and fixed in this round

Each row was a claim of this file that the code did not hold. Each fix
is asserted by the suite named.

| Found | Why it would hurt | Fix | Proof |
|---|---|---|---|
| Any IPv6 source could ping the IPv4 internet through a gateway (G4) | The allowlist sat behind a firewall rule that accepts all ICMPv6. The gateway was an open ICMP relay on the owner's public IPv4 | The allowlist is its own table ahead of the firewall, for every protocol | `gateway-nat64`: counted drops for ping, TCP, UDP, DNS over UDP and TCP |
| A sick gateway kept answering DNS (G23, was open) | Names resolved into a dead /96. A machine without a CLAT was stuck | The health check stops CoreDNS; CoreDNS is bound to the check | `gateway-nat64`: a name through the other gateway 8 s after the cut |
| The CLAT follower trusted a state file and cut strings (G23) | A CLAT made again pointed at a dead gateway for good; `64:ff9b::/96` crashed the follower in a loop | No state: Jool's `pool6` is read every round; the prefix is parsed as an address | `gateway-nat64`: instance removed, corrected in 12 s; three prefix shapes |
| The follower jumped on one answer when all gateways looked sick (G23) | One dead health target broke every CLAT flow | It moves only to a gateway that names a valid /96, and stays when none does | `gateway-nat64`: 0 moves in 20 s, the open flow lives |
| The active WAN lived in a script variable (G16) | A firewall reload while failed over sent traffic into the dead WAN; a restart of the check never moved back | The steering is a table the health check owns; the ruleset is the only record | `gateway-dual-wan`: reload, restart, table deleted, `nft` failing once |
| Replies left by the active WAN, not the WAN they arrived on (G16) | SSH, WireGuard or a port forward on the backup's address was dead while the primary was active | A conntrack mark per arrival WAN, restored before steering | `gateway-dual-wan`: inbound from each ISP in both states, both families |
| The dual-WAN suite ran with the firewall off (G16) | A real router's strict reverse-path check drops steered traffic | Firewall on, `checkReversePath = "loose"` | `gateway-dual-wan` asserts strict fails |
| The router and LAN hosts could not reach the inactive WAN's own subnet (G16, was open) | No access to the backup modem's web page | A set of WAN subnets is not steered | `gateway-dual-wan` |
| Stale IPv6 sources left the WAN and timed out (G22) | After a missed retirement, 5 s per connection for up to 45 min | Sources outside the delegation are rejected on LAN ingress | `gateway-router`: an error in 0.05 s; the ISP sees none |
| A dying prefix could be listed first in netif's prefix file (N16) | The hook would keep the old prefix and move nothing | Only prefixes with both lifetimes non-zero; the file is removed when none is left | `netif-dhcp`, `gateway-router` (a renew in place) |
| The prefix file was never removed (N16 said it was) | A consumer could not see a lost delegation | Removed on expiry and on an empty reply | `netif-dhcp`: gone after 40 s, back 2 s after the ISP |
| A path event during a hook run was lost (G22, was "not tested") | A prefix change at boot was never handled | The hook loops until it has handled the file's content | `gateway-router` |
| The hook did not converge after a failed step (G22) | corerad kept an old configuration for good | State first, generation compared with what is loaded | `gateway-router`: `systemctl` and `nft` each failing once |
| Zone `servers` was advertised a resolver nobody served (G11, G15) | No DNS for Kubernetes nodes behind the router | One resolver address per zone, port 53 accepted per zone | `gateway-router`: `dig` from each zone, the other zone refused |
| NodePorts were open on every Cilium device (§12.2) | Every `LoadBalancer` Service opened a port to the outside, past the node firewall | SPEC.md D69: `nodeport-addresses` is the node addresses | `<distro>-data-plane-tunnel`; eval `test_nodePortAddresses` |
| Both CoreDNS replicas on one node (§12.2) | One dead node took cluster DNS | SPEC.md D70: a hard spread with two or more members | `<distro>-data-plane-tunnel`, `<distro>-ha`, `<distro>-ha-fabric` |
| `clan.networkFacts.clusters` was never written (§12.3) | The overlap checks against container and tailnet ranges never saw pod or Service ranges | k3s and rke2 write it | eval `test_clusterRangesFact` |
| `ha` proved less than its name | A clean shutdown, a pod pinned to a node, the API asked on one survivor, no return | A crash; the scheduler places the pod; the API on both survivors; cluster DNS; the dead server returns and serves | `<distro>-ha`, `<distro>-ha-fabric` |
| Two suites patch another suite's script by string replace | A renamed string would drop a phase and stay green | The evaluation fails when a pattern is missing | `<distro>-v6only`, `<distro>-ha-fabric` |

**Found by the cluster suites in this round, pinned, not fixed** (each
needs a decision, G5):

| Found | Why it would hurt | State |
|---|---|---|
| On an IPv6-only node, pod IPv6 egress fails unless the underlay NIC is in Cilium's `devices` | The server saw the pod's own `fd10:` address. Cluster CoreDNS could not reach the node's nameserver either: no external name resolved in any pod. The earlier CLAT suites passed because they tested only an IPv4 literal and `cluster.local` | The design suites add the NIC; the `-mapped` suites run without it and assert the failure. No service renders it yet |
| The CLAT suites kept an IPv4 nameserver on IPv6-only nodes | It broke G5's own rule and hid the DNS path | Nodes use the DNS64 over IPv6 only; a pod fetches by a synthesized address |
| Pod IPv4 leaves with the pod's address while Cilium is not yet on `clat0` (G5, was "not tested") | After the link is made again, pod IPv4 egress is down 9 s (native) or 17 to 18 s (tunnel) | Asserted as it is: the packets leak, none after the attach |
| On the routed fabric, node-to-node IPv4 enters the CLAT before BGP converges | 1 to 7 packets per boot to another node's API address reach the gateway, which refuses them | Asserted: only node addresses, at most 10 |

Also corrected in the text: §12.2 said the underlay link "is in
`devices` in both modes". It is not: the services list only the
transport's links. The underlay was there because two suites add it
for a floating address.

### 13.2 For the owner to decide (ranked by damage to a real deployment)

1. **Stop probing; build the services next.** Every mechanism runs in
   a fixture, and every fix of this round was made in a fixture. A
   fixture is a shell script in a test file; the service will be
   written again from it. Each further round of fixture hardening is
   work done twice, and the largest remaining risk is the rewrite, not
   a mechanism. Recommended order: `lib/gateway/translator.nix` and
   `clat.nix` with the `nat-gateway` service first (S4, then S5: the
   cluster suites already need a CLAT and a `devices` entry that no
   service renders), then `router` single WAN (S2). Each suite then
   imports the module in place of its fixture (§5).
2. **Freeze the design-only decisions.** G9 (IPv6-mostly), G16's open
   points, G17 (several routers), G19 (flow records) and G21 (owned
   address space) are design without code. Each one widens what the
   first two services must not break. They stay written down; nothing
   is built for them until S2 and S4 are green on service code.
3. **Is DNS64 worth its cost on clan machines?** A machine with a CLAT
   needs no DNS64: every IPv4 destination, by name or literal, goes
   through the CLAT. DNS64 adds a failure mode of its own:
   - every name lookup of an IPv6-only machine depends on a gateway,
     also for names that have IPv6 (both gateways down: no DNS at all);
   - a synthesized address names one gateway's /96 and sits in caches
     (the TTL cap of G4, a cluster's CoreDNS with `cache 30`);
   - it breaks a client that validates DNSSEC (§12.2);
   - it needed the fix "a sick gateway stops answering DNS" (§13.1).
   The alternative: the CLAT is the path on every client; resolvers are
   plain (the gateways, or any IPv6 resolver); DNS64 becomes an option
   for a machine that cannot run Jool. Its cost: Jool on every client,
   and double translation for every IPv4 flow. Both are already true
   for every Kubernetes node (G5). **Recommendation: CLAT on every
   client by default, DNS64 optional.** Not changed here: it is G4's
   core and the owner's call.
4. **The allowlist is a source address, not a credential** (G4). A
   gateway is reached over the open IPv6 internet. Whoever can send a
   packet with a client's source address (a network without source
   validation) gets UDP relayed from the gateway's public IPv4 and DNS
   answers reflected at the client. TCP is safe (the handshake fails).
   The abuse is attributed to the owner's IPv4. Options: accept and
   rate-limit per source (cheap, recommended); or carry client traffic
   to the gateway in a WireGuard tunnel of its own (authenticated, but
   a second path to keep alive; not the fabric, so G4's independence
   holds).
5. **A health check needs several targets** (G23, G16). Both checks
   ping one address. One target down means: both gateways withdraw
   together, or a healthy WAN looks dead. The rule to adopt: three or
   more targets in different networks; unhealthy only when all fail.
   The targets are settings; the defaults are the owner's choice.
6. **A Service behind G20's rewrite answers from another address than
   it calls out from.** Inbound, a client reaches `<public>:f::80`.
   Outbound, the same pod leaves from its node's address (Cilium's
   masquerade). A game server that registers with a master server is
   listed under the node's address, where no pinhole is open. Closing
   it needs an egress rule that sends that pod out through its Service
   address (day-2: a Cilium egress policy, or `literal` mode with
   owned space). State it as a limit of `translated` mode.
7. **G16 dual WAN is not ready for a design freeze.** Beyond the open
   points G16 lists: an IPv6 default route learned from an
   advertisement expires like the DHCPv4 one did (the suite's IPv6 is
   static, so it cannot show it); a WAN address from DHCP cannot be
   named in a static `from` rule; a per-ISP resolver is reached
   through the wrong WAN. G16 stays "built after single WAN".
8. **One kernel module holds the fleet.** After D67 every cloud node
   and every gateway needs Jool. `checks.jool-available` covers the
   default and the latest kernel of the pin, not the kernel a machine
   actually runs. The check should read the kernels of the machines
   that enable a translator (an assertion in `lib/gateway`, when it
   exists).
9. **An IPv6-only machine with broken IPv6 has no way in.** There is
   no IPv4 fallback by design (P2). The provider's console is the only
   recovery path; say so in the docs, and keep the guard (netif N25)
   mandatory on such machines.

10. **The underlay NIC in Cilium's `devices` on an IPv6-only node**
    (G5). The suites show it is required for pod IPv6 egress and for
    external names in pods. It should become a rule the kube service
    renders, together with the CLAT link. It changes D58's "devices
    derive from the transport" for such nodes: a SPEC.md decision.

### 13.3 Still unproven after this round

- **Service code.** Unchanged from §12.1: every gateway mechanism is
  a fixture.
- **Health targets** (G16, G23): one address each. See §13.2.
- **Dual WAN under packet loss:** 0 to 4 moves in 60 s at 30 % loss.
- **Dual WAN with learned IPv6** (advertisements, prefix delegation on
  a WAN), a dead backup, both WANs dead.
- **A prefix the ISP deprecates but keeps valid:** covered at netif's
  exit script, not end to end (kea cannot send it).
- **The boot blip of G22** and a backend reaching its own public
  address (G20).
- **Spoofed client sources** at a gateway (§13.2).
- **A 2000 byte UDP datagram** through the CLAT mostly fails; not
  understood (§10.6). "TCP and UDP, fragments included, pass" holds
  for the sizes tested (1200, 1400, 1452, 3000, 4000).
- **`ha`: the `clusterInit` server never dies.** The server that dies
  is always the second one.
- **N43 on the wire:** "the ISP saw only the presented MAC" is read
  from the ISP's tables, not from a capture. Frames sent before
  IfState sets the MAC (router solicitations, duplicate address
  detection) would not show there.
- **Timing bounds in the cluster suites** are looser than "three
  times the sample" (120 to 300 s against 0.1 to 46 s measured).
- **Flakiness:** still one full run per round (§13.4).
- **A pod client that prefers IPv6 by name** through DNS64: busybox
  takes the IPv4 answer and the CLAT. The DNS64 path from a pod is
  proven by the synthesized address only.
- **An image pull** on an IPv6-only node: images are preloaded. The
  node's own 2 MB fetch by an IPv4-only name is asserted instead.

### 13.4 The full run after the fixes (2026-11-22, euc-hel-0)

`vm-test --all --remote --rebuild --quiet`: 57 of 57 passed, every
suite booted fresh. 56 as `PASS`, one as `PASS(!)`.

- **`netif-guard` failed beside others and passed alone.** It read
  the guard's "rolled back" line from the journal right after a sync,
  and under load the line was not there yet. The check now waits for
  the line (30 s). Green twice in a row after the change. This is the
  first entry of the record §12.4 asks for: `netif-guard`, the
  journal read, 2026-11-22.
- The suites that grew in this round, wall time in the full run:
  `k3s-clat-mesh` 721 s, `rke2-clat-mesh` 801 s, `gateway-dual-wan`
  462 s, `gateway-nat64` 427 s, `k3s-data-plane-tunnel` 440 s,
  `rke2-data-plane-tunnel` 553 s.
- Each suite changed in this round also passed twice in a row alone
  before the full run (`gateway-nat64`, `gateway-router`,
  `gateway-dual-wan`, `netif-dhcp`, `k3s-clat-mesh`,
  `k3s-clat-fabric`) or once (`rke2-clat-*`, the `-mapped` suites,
  `<distro>-ha`, `k3s-ha-fabric`, the data-plane suites).

## 14. Owner decisions (round G5, 2026-11-23)

The owner answered §13.2 in a deciding session. Docs only; code starts
in the next session. Each point is **locked**: change it only with the
owner.

### 14.1 Locked

1. **Stop probing; build the services** (§13.2 point 1).
   - Order: `lib/gateway/translator.nix` and `clat.nix` with
     `services/nat-gateway` (S4, then S5); then `services/router` with
     one WAN (S2).
   - No new probes, unless one is the only way to test a service.
   - Keep the existing suites. A suite that tests a fixture switches to
     the service module in place of its fixture (§5). A suite that only
     a frozen decision needs (2.) stays as it is and is not extended.
2. **Freeze the design-only decisions** (point 2): G9, G16's open
   points, G17, G19, G21. Written down; nothing is built for them
   until S2 and S4 are green on service code.
3. **The CLAT is the only path; DNS64 is frozen** (point 3; amended
   by the owner the same day).
   - Every `nat-gateway` client runs a CLAT (G23) and uses plain IPv6
     resolvers, which need not be the gateways. DNS no longer depends
     on a gateway.
   - DNS64 is **not built** in the first `nat-gateway`. It is frozen
     like the decisions of point 2: written down, built only when a
     real client cannot run a CLAT (macOS, an appliance, a kernel
     without Jool). It would then be a per-client option, off by
     default, served by the gateway.
   - DNS64 never runs on a client. On the home router it is needed at
     most for G9 (IPv6-mostly, frozen).
   - G4's DNS64 listener, port 53 allowlist, TTL cap and health
     coupling are frozen with it. The fixture
     `lib/gateway/tests/vm/nat64-gateway.nix` keeps the proof; a suite
     that ported to service code drops its DNS64 subtests, and the
     fixture stays in git.
   - Why: a CLAT covers names, IPv4 literals and IPv4-only sockets;
     DNS64 covers names only. DNS64 costs a gateway dependency for
     every lookup, stale synthesized addresses after a failover,
     broken DNSSEC validation, and its own failure coupling.
4. **Rate-limit per client source at the gateway** (point 4).
   - Every allowlisted source gets a packet and new-flow limit in the
     gateway's `inet nat64` table (nftables `meter`, keyed by source
     /128 or /64).
   - **Two tiers:** `default` and `trusted`. A client's tier is a
     setting; a client that is also a member of a kube cluster
     (`clan._networkFacts.clusters`) defaults to `trusted`.
   - **Limit of the tier, stated:** the gateway sees one source per
     node. Pod IPv4 leaves through the node's CLAT, and pod IPv6
     through Cilium's masquerade, so a node's workloads share its
     tier. `trusted` trusts the machine, not its workloads. Limits per
     workload belong inside the cluster (Cilium bandwidth manager,
     egress policy), day-2.
   - The tier is still a source address, not a credential (G4): a
     spoofer of a trusted source gets the higher limit. Accepted.
   - The numbers are settings. **Defaults (round G7):**

     | Tier | New flows per source | Packets per source |
     |---|---|---|
     | `default` | 50/s, burst 200 | 20 000/s, burst 40 000 |
     | `trusted` | 200/s, burst 4 000 (round G11; was 1 000/s) | 200 000/s, burst 400 000 |

     A source is one /64 (round G11, §17; was one address): a client
     that owns a /64 cannot open a meter entry per address, and
     clients that share a /64 share its limit. The limits count only
     what a client sends towards the translator; replies are not
     limited.
     The `trusted` new-flow default is bounded by the one `pool4`
     address (round G11, §17): burst + rate × 300 s (Jool's UDP
     timeout) = 4 000 + 200 × 300 = 64 000, under the 64 435 ports of
     a protocol, so one source cannot fill the pool alone.
     20 000 packets a second is about 240 Mbit/s of 1 500 byte packets.
   - **Built (round G7):** one meter per tier and kind in `inet nat64`
     (`nat64-flows-<tier>`, `nat64-packets-<tier>`). The gateway learns
     the kube members from the `kube_cluster` exports. Asserted in
     `nat-gateway`: a `default` client loses SYNs and datagrams above
     its limit, a `trusted` one loses none.
5. **The kube services render Cilium's `devices`** (point 10; SPEC.md
   D71). See 14.2.

### 14.2 The rules for Cilium `devices` (SPEC.md D71)

- **Rendered, never hand-set.** k3s and rke2 render `devices` from
  facts. A suite that sets `cilium.helmValues.devices` today switches
  to the rendered value.
- **What goes in, per node:**
  - the transport link(s) (D58, unchanged);
  - the CLAT link, on a node that runs a CLAT (G5);
  - the underlay link(s), on a node whose underlay has no IPv4
    (§13.2 point 10; proven required in `<distro>-clat-*`).
- **Names come from netif**, not from a guess. netif knows each
  machine's underlay links by zone (N10), whatever the kernel calls
  them: `eno1`, `enp0s1`, `wlp2s0`. The fleet is mixed: wired and
  Wi-Fi, different names per machine, in one cluster.
- **Never a VPN link.** A link of a VPN zone (`tailscale0`, any
  Headscale or WireGuard client link that is not the transport) is
  never in `devices`. An eval assertion refuses it.
- **Answered (round G7): candidate 1, the union.** The transport's links
  already differ per node and were already one union; Cilium attaches to
  the names a node has. `<distro>-clat` runs the rendered list
  (`<fabric link> <fabric loopback> clat0 eth1`) and asserts Cilium on
  `clat0` and `eth1` of each node. Built in `lib/kube-cluster/devices.nix`:
  - the CLAT link of a member that is a `nat-gateway` client (its
    `nat_gateway` export);
  - the links of that client's uplink zone that carry no IPv4 (its
    `netif` export: no static IPv4, no DHCPv4);
  - an eval assertion refuses a VPN link: a netif link in zone `vpn` or
    `tailnet`, or a name starting `tailscale`, `wt`, `nb-`, `zt`, `tun`.
  - round G8: every link of a gateway's uplink zone; round G9: a
    router's WAN link, and **the link that owns any member's default
    route** (netif `gatewayInMain`, N21; never a VPN zone's link). The
    first cut covered only a node without IPv4; a pod on a dual-stack
    node needs the same (§16.2).
  - Not yet proven: two nodes with different underlay names in one
    cluster (eval tests only: `test_d71RenderedDevices`).
- Was open: `devices` is one cluster-wide Helm value, and the names
  differ per node. Candidates, in order:
  1. the union of every member's exact names in the one list, if
     Cilium skips a named link that does not exist on a node;
  2. a `CiliumNodeConfig` per node with that node's exact names;
  3. prefix wildcards (`en+`, `wl+`) with an exclusion of VPN links,
     if Cilium supports exclusions (`!tailscale0`). Wildcards also
     match links netif does not own; last choice.
  The suite: two nodes with different underlay names (one wired-style,
  one Wi-Fi-style), a `tailscale0` link present on both. It asserts
  Cilium attached to the expected links on each node and not to
  `tailscale0`.

### 14.3 The unfixed findings: direction

- **Pod IPv4 down for 9 to 18 s after `clat0` is remade** (§13.3).
  Accepted as a blip. Fix it if cheap: the CLAT service must not
  remove and re-add `clat0` on a restart or reapply; a suite measures
  the gap.
- **A healthy gateway must never look sick** (G23; §13.2 point 5).
  Required:
  - three or more health targets in different networks; a round is
    bad when fewer than `quorum` (2) targets answer, and the gateway
    is unhealthy after `down` bad rounds in a window (§14.5 point 4;
    the words "every target fails, in a row" were the first draft,
    corrected in round G11);
  - a suite where one target is dead and the gateway stays healthy,
    and one where the gateway's own translator fails and it withdraws.
  - A sick gateway that looks healthy for a few rounds is the accepted
    price.
- **Dual WAN: stable over fast** (G16; §13.3). Frozen by 14.1 point 2,
  but the criteria are locked now, so the design is built to them:
  - move to the backup only when every target fails through the
    primary, for several rounds;
  - move back only after the primary has been healthy for a hold time
    of minutes, not seconds;
  - a suite with 30 % loss on the primary asserts **zero** moves in
    the window; one with 100 % loss asserts exactly one move, within a
    stated bound.
  - Today's 0 to 4 moves in 60 s at 30 % loss does not meet this.
- **A backend cannot reach its own public service address** (G20).
  - Why: the router rewrites the destination `<public>:f::80` to the
    Service's ULA address, on the node that sent it. The node answers
    locally from the ULA address. The sender waits for an answer from
    `<public>:f::80`, so it drops the reply. A second host in the same
    zone fails the same way: the reply goes to it directly, past the
    router.
  - Fix, decided: hairpin source rewrite on the router. A packet from
    a LAN zone to the service prefix also gets its source rewritten to
    the router's zone address, so the reply comes back through the
    router. Only for sources inside the router's zones; WAN clients
    keep their address (G20's `externalTrafficPolicy: Local`).
  - The router suite asserts it from the backend node and from a
    second host in the same zone.

### 14.4 Cilium tunnel mode

Decided 2026-11-23: native routing only (SPEC.md D72).
**Implemented (round G6):** tunnel mode and `wireguard-mesh` are
removed; the last commit with them is tag `tunnel-mode-final`. The
`<distro>-clat-mesh*` suites went with them; `<distro>-clat` (the
former `-clat-fabric`) is the CLAT proof.

### 14.5 Owner decisions, round G8 (2026-11-24)

Locked, as §14.1. They answer the open questions of round G7.

1. **The CLAT is the only IPv4 path. Our DNS64 is removed** (amends
   §14.1 point 3: from frozen to removed).
   - The `gateway-nat64` suite goes; the fixture
     `nat64-gateway.nix` loses its health check and beacon, and
     `k3s-clat-mapped` resolves at a plain resolver like the others.
   - Kept: the **provider's** DNS64 in `netif-v6only` and
     `<distro>-v6only` (`v6only-host.nix`). It is not ours: it proves
     netif on a provider network that offers DNS64.
   - git keeps the old design (the commit before round G8).
2. **G24 (the beacon) is accepted.**
3. **Limits: the round G7 defaults stay; every number can be
   overridden** at three levels, the most specific wins:
   - the instance: `roles.gateway.settings.limits` (clan's role
     settings apply to every gateway of the instance);
   - one gateway: `roles.gateway.machines.<m>.settings.limits`;
   - one client: `roles.client.machines.<m>.settings.limits` (any of
     the four numbers; the rest come from the client's tier on each
     gateway). A client with an override gets meters of its own.
4. **Stability over fast failover** (sharpens §14.3). A healthy
   gateway never looks sick, and a sick one never looks healthy, given
   time to settle. The price is failover in about a minute and a half,
   not seconds.
   - **Gateway:** one round a second. A round is good when two or more
     targets answer (all of them when fewer than two are set). The
     beacon is withdrawn when **30 of the last 60 rounds** are bad (a
     dead upstream: after 30 s), and comes back only when **the last
     120 rounds** hold at most 5 % bad ones (a clean recovery: after
     120 s). So one lucky ping does not bring a sick gateway back, and
     one dead target does not take a healthy one down.
     - Windows, not "in a row" (found while building it): at 80 % loss
       one lucky round in ten reset a count "in a row", so a lossy
       gateway never went down. Simulated: down after 30 to 36 s at
       80 % loss and never back; no change in 50 min at 30 % loss, with
       one dead target, or with one target flapping every 5 s; a
       gateway whose whole upstream flaps every 5 s goes down and stays
       down.
   - A restart of the health check alone (a deploy) keeps the state
     it had, if it was written less than 60 s before; a reboot starts
     from cold (120 good rounds).
   - **Client:** the follower moves only when its gateway's beacon has
     not answered for **60 s**, and only to a gateway whose beacon
     answered **5 of the last 10 rounds** (amended in round G11, §17).
     A round in which no beacon answers does **not** reset the 60 s:
     the clock starts when the gateway's beacon last named the CLAT's
     /96 and stops only when it names it again (or the CLAT moves, or
     its /96 is changed under it). The first rule ("60 s, then any
     beacon that answers") reset the clock on every silent round, so a
     move needed about 40 answers in a row from the other gateway: at
     10 % loss towards it, a move took many minutes. It never moves
     back on its own. **No hold after a move**
     (the owner, 2026-11-24): a hold could pin a client to a gateway
     that died within it; the gateway's 120 good rounds already keep a
     flapping gateway from attracting clients.
   - Suite cases: 80 % loss on a gateway's upstream, and a target that
     flaps every 5 s; neither may cause a client move or a beacon
     return while sick.
5. **A gateway may be a Kubernetes node; a gateway is never a client**
   (amends G1: a machine is not both).
   - A gateway has its own IPv4: its pods leave through Cilium's
     masquerade to that IPv4 and need no CLAT.
   - Required first: Jool's private IPv4 moves out of `10.0.0.0/8`
     (Cilium's native-routing CIDR and the pod pools) to `192.0.0.0/30`
     (RFC 7335's host-local range, the one a CLAT uses; a gateway is
     never a client, so they never meet; `192.0.0.8/29` is no choice:
     `.9` and `.10` are global anycast addresses), and a suite
     `nat-gateway-kube`: a gateway that is a cluster node, pods on it
     sending IPv4 through Cilium's eBPF masquerade while clients send
     through the gateway's nftables masquerade on the same uplink;
     every flow completes.
6. **No metrics yet** (G18 stays planned). The path stays open: rule
   comments are stable names, and the health check writes its state
   to a file an exporter can read later.
7. **The home box** (the owner's ISP edge, SFP+ WAN, ECMP into the
   cluster): `router` and a Kubernetes node; **no `nat-gateway` role
   for now**. Its LAN is dual-stack through NAT44, so no LAN machine is
   a client.

## 15. Service evidence (round G7, 2026-11-24, euc-hel-0)

The first runs of the services. Each line is one run: a sample, not a
flakiness measure (§12.4).

### 15.1 `nat-gateway` (`NAT_GATEWAY_OK`, passed, 608 s)

- Every phase of `gateway-nat64` that is not DNS64 passes on the
  service: the allowlist for every protocol (ping 2, TCP 3, UDP 1,
  beacon 1 and 2 packets counted per gateway), the namespaced Jool seen
  by the forward chain and conntrack, the two negative proofs, the
  follower's address arithmetic, the CLAT on both clients, path MTU
  (1420 through NAT64, 1400 through the CLAT), nftables ownership, an
  IfState apply, 30 % loss for 40 s without a move, an idle flow of
  40 s, a crash that stalls a flow without a reset, a gateway back
  without state.
- **Rate limits (§14.1 point 4):** a `default` client (gw2 lowered to
  5 new flows/s, burst 10) got 20 of 40 simultaneous connections
  through, 75 SYNs dropped; a `trusted` client got 40 of 40. 2000
  datagrams/s for 3 s against 500/s, burst 1000: 3481 of 5981 dropped
  for `default`, none for `trusted`.
- **Beacon and health (G24, §14.3):** one target of three dead: the
  gateway stayed healthy for 15 s. All of a gateway's targets dead:
  beacon withdrawn after 3.9 s, an IPv4 literal through the other
  gateway after 15.4 s; back 0.6 s after the targets returned. The
  translator removed: withdrawn after 3.4 s, the CLATs moved. Both
  gateways' targets dead: both withdrew, the follower stayed 20 s and a
  CLAT flow got 20 echoes in 20 s. Health check stopped: beacon closed
  at once; killed: restarted, beacon back.
- Failover: an IPv4 literal through the live gateway 14.2 s after a
  crash; a CLAT remade on the dead gateway's /96 corrected after 12.3 s.
- A gateway and a client reboot; everything comes back and no unit
  failed.

### 15.2 `k3s-clat` (`K3S_CLAT_OK`, passed, 613 s)

- The cluster on IPv6-only NICs behind the service, with nothing
  hand-set: each agent masquerades on `[eth1, clat0, <fabric link>,
  <fabric loopback>]`, the rendered D71 list. Cilium attached to `clat0`
  0.2 to 0.3 s after it was asked.
- Nodes resolve at a plain IPv6 resolver; an IPv4-only name goes
  through the CLAT (2 MB), a name with an AAAA record goes direct. Pods
  resolve through cluster DNS and the node's resolver (only with the
  NIC in `devices`) and reach IPv4 by name through the CLAT.
- Every other phase of the fixture version passes: NodePorts (D69),
  ClusterIP, the private-destination refusal, an IfState apply, the
  CLAT link remade under load, both nodes rebooted.
- The gateway trusted both members by itself (`kube_cluster` exports).

### 15.2b `rke2-clat` (`RKE2_CLAT_OK`, passed, 1133 s)

- The same body as `k3s-clat` on rke2: the rendered list
  `[eth1, clat0, <fabric link>, <fabric loopback>]` on both nodes, every
  phase passed.

### 15.3 `router` (`ROUTER_OK`)

- First run (before the hairpin change): passed, 504 s, every phase of
  `gateway-router` on the service.
- With §14.3's hairpin rewrite: passed, 346 s. The backend node reached
  its own public service address in 0.04 s and saw the router's address
  in its zone (`fd00:10:2::1`); the home zone reaches the service the
  same way now (it saw its own address before). WAN clients keep their
  address (asserted: the node saw the ISP's address).
- Two runs in between failed on the suite, not the service: a helper
  that did not skip an `ip -j` entry without `local`, and a check that
  the word `dnat` was gone from the hook's table (the hairpin rule
  holds `ct status dnat`; the check now looks for the rewrite rule).
- **Flake seen once:** right after the ISP fixture switched to another
  delegation (a specialisation switch that restarts its IfState), the
  home client's IPv4 request failed within 1 ms. The check now waits up
  to 30 s. The cause on the ISP side is not proven.
- Not yet tested: a second host in the same zone as the backend (§14.3
  asks for it; the topology has one host in `servers`).

### 15.4 Round G8 (2026-11-24, euc-hel-0)

- **`nat-gateway`** (`NAT_GATEWAY_OK`, passed, 2 234 s; 37 min of the
  45 min timeout, the price of the default timings):
  - Withdrawn 31.9 to 32.4 s after every target or the translator died,
    34.4 to 37.0 s after 80 % loss began; back 113.4 to 113.9 s after
    the upstream was clean (never earlier than 120 clean rounds allow).
  - A client moved 61.7 to 63.4 s after a crash, 93.5 to 94.9 s after
    its gateway's targets died; it corrected a CLAT made again on the
    dead gateway's /96 after 62.4 s.
  - At 80 % loss the gateway stayed withdrawn for 150 s, and while its
    upstream flapped every 5 s for 140 s; one target flapping for 100 s
    on the current gateway moved nothing (`NAT_GATEWAY_LOSSY_OK`,
    `NAT_GATEWAY_FLAPPING_OK`).
  - The capped client's own meter dropped 3 491 of 5 981 datagrams on
    gw1 (500/s, burst 1 000); the tiers' meters counted none.
  - A stopped and restarted health check resumed `up` from its state
    file; the beacon was back in under 20 s.
- **`nat-gateway-kube`** (`NAT_GATEWAY_KUBE_OK`, passed, 214 s): alpha
  is a k3s server and the gateway, beta a k3s agent and its client.
  - Rendered `devices`: `<fabric link> <fabric loopback> clat0 eth1
    eth2`; alpha's agent masquerades on `eth1, eth2` and the fabric
    links (`eth2` holds the public IPv4).
  - alpha's pod leaves with the public IPv4 by eBPF masquerade; beta's
    host and pod through beta's CLAT and alpha's NAT64 (Jool sessions
    from beta's CLAT address).
  - Two masquerades on one public IPv4: 150 long flows (8 s each) from
    each of alpha's pod, alpha's host, beta's pod and beta's host at
    once; all 600 came back, twice. Cilium held 1 796 and 3 094 NAT
    entries while they were open.
  - The router (no client) towards alpha's /96: 6 packets dropped and
    counted (`nat64-undeclared`); its beacon query too.
  - `nodeport-addresses` holds only the fabric addresses; the NodePort
    answered beta on 192.168.77.1 and timed out on the public IPv4 from
    the IPv4 internet.
  - After a restart of nftables, of `nat64-jool`, and an IfState apply
    on alpha, all three egress paths still work.
- **`k3s-clat`** (passed, 735 s), **`rke2-clat`** (passed, 834 s),
  **`k3s-clat-mapped`** (passed, 290 s, now with a plain resolver).
  - Before the fabric converges a node's SYNs to the server's fabric
    address go into its CLAT and the gateway refuses them: 5 packets in
    2.7 s (k3s), 14 to 16 in 2.9 to 3.1 s (rke2). The suite bounds the
    window (20 s) and the targets (node addresses only), not the count:
    the first rke2 run sent 16 against a bound of 10.

## 16. Hardening review (round G9, 2026-11-25)

The owner asked for a devil's advocate review of PR #38 and of the
networking and cluster services, for two use cases: a cloud cluster of
three managers of which two or more are gateways, and a home box that
is a router and a node. Stability comes before fast failover.

### 16.1 Owner answers to round G8

1. **Windows, not "in a row"**: accepted, "if that is most stable".
   §14.5 point 4 stands as written.
2. **The stray-packet check bounds a time window** (20 s), not a
   count: accepted ("build for stability").
3. **The `nat-gateway` suite is split**: `nat-gateway` and
   `nat-gateway-failover`, one file, one topology.

### 16.2 Found in PR #38 and fixed

| Found | What it did | Now | Proof |
|---|---|---|---|
| The router is the machine's only firewall (G25) | On a router that is a node: the cluster's and the fabric's firewall rules void, their traffic dropped by policy | Ownership by link; the NixOS firewall stays on | `router-kube`; eval `test_ownLinksOnly`, `test_node` |
| The translator reaches the gateway itself | A declared client that sends to the /96 with the gateway's own IPv4 (Jool's link address or the public one) inside is delivered to the gateway's input, not forwarded: G5's refusal of private destinations never saw it, and the gateway's IPv4 ports were open to it | Rule `nat64-host`: IPv4 that arrives on Jool's link is refused | `nat-gateway`, in `assert_gateway` on both gateways |
| The follower trusts any answer | A beacon answer names the /96 a CLAT moves to; a forged or wrong answer moved every client's IPv4 to a foreign prefix | G24: only the gateway's own /96 is proof | `NAT_GATEWAY_FOREIGN_PREFIX_OK` |
| A changed `pool6` is never applied | The unit kept a live instance whatever its prefix; the gateway then failed its own health check until a reboot | The instance is made again when the prefix differs, compared as networks | `NAT_GATEWAY_RECONCILE_OK` |
| A CLAT address in another spelling fails the unit | The mapping was matched as a string; `2001:db8:c:0::c1a7` never matched, the second `eamt add` failed, at every start | Compared as addresses; a changed address replaces the mapping | `NAT_GATEWAY_RECONCILE_OK` |
| A zone of two links is half configured | Addresses, DHCPv4 and the resolver came from the first link only | Eval assertion: one link per zone | eval `test_twoLinksInAZone` |
| A zone link accepts router advertisements | netif's default is `ra = true`; a LAN host could give the router addresses and routes | Eval assertion: `ra = false` on zone links | eval `test_zoneAcceptsRa` |
| The DHCPv4 pool can hold the router's address | The pool is the upper half; a router at `.254` could be leased | Eval assertion | eval `test_routerInThePool` |
| The prefix hook may run before IfState | Its netdev chain names the LAN links | Ordered after `ifstate.service` | `router` |
| A missing other link stops the translator | The Jool units required `ifstate.service`, which also fails when any declared physical link is absent (netif P3a), after it applied the namespaces | `Wants` and `PartOf`: an apply still restarts them, a failed check does not stop them | the gateway suites' IfState phases |
| A plain node's pods cannot leave (SPEC.md D71) | `devices` held a member's uplink only for a `nat-gateway` client or gateway. On any other node with a default route the pod's packets left with the pod's address. Found by the first run of `router-kube`: beta's pod reached the internet host through the router's NAT44, and the answer came back over the fabric, whose WireGuard refuses a source that is not the cluster's | The link that owns a member's default route joins `devices` (netif `gatewayInMain`) | `router-kube`; eval `test_d71DefaultRouteLink` |
| One list of device names can attach Cilium to a router's zone link | Two machines with the same link name (identical mini PCs): the router's zone link and another node's uplink. Cilium on the zone link forwards past the router's table | Eval refusal, with the name | eval `test_d71RouterZoneLinkRefused` (k3s, rke2) |
| A gateway needs a client | An instance of gateways only (three managers, all with a public IPv4) failed evaluation | Allowed: an empty allowlist lets nobody through | eval `test_noClients` |

### 16.3 Found in the existing services, fixed in round G10

Read in the code by the reviewers in round G9. The owner's word came
on 2026-11-25: fix all sixteen. Ranked by damage to the two use cases.

| # | Found | Now | Proof |
|---|---|---|---|
| 1 | No BGP graceful restart between Cilium and FRR: a restart of the agent withdrew the node's pod and service routes everywhere | `gracefulRestart` in the `CiliumBGPPeerConfig` (120 s); FRR `bgp graceful-restart` with `preserve-fw-state` | `k3s-frr-failure`, `FRR_CILIUM_RESTART_OK`; eval `test_g10Hardening` |
| 2 | A restart of FRR withdrew the node's fabric address, which etcd and the API ride | Graceful restart on the fabric sessions (restart and stale-path time 60 s, `select-defer-time 0`); zebra keeps its routes over a restart (`-r -K120`). `bfd check-control-plane-failure` on fabric neighbors: a peer whose BFD fails is dropped at once, graceful restart or not | `k3s-frr-failure`: routes kept while bgpd is away; `FRR_DEAD_NODE_OK` (a crashed spine's route gone in under 15 s) |
| 3 | `site` defaulted to `"default"`, so members in different places got the LAN timers | `site` is `null` by default. The `site` profile applies only when both ends name the same site; every other pair gets `wan` | eval `test_stabilityProfilesAndRecovery`; the cluster suites set `site = "lab"` |
| 4 | A reinstalled `clusterInit` server started a second cluster | Unit `<instance>-init-guard`, before the server: with no etcd data it probes every other server's API (10 tries, 3 s apart) and fails when one answers | eval `test_g10Hardening` (k3s, rke2): the unit and its order. The refusal itself is not run in a suite |
| 5 | A change of `cilium-config` reached no running agent | The DaemonSet's pod template carries `clan.lol/cilium-config-hash`; a change rolls the agents, `maxUnavailable: 1` | eval `test_g10Hardening` |
| 6 | The ClusterMesh secrets unit restarted `clustermesh-apiserver` at every run | Restarted only when a secret's `resourceVersion` changed | `<distro>-clustermesh*` |
| 7 | `operator.replicas = 1` | 2 when the cluster has two or more members | eval `test_g10Hardening`; every multi-node cluster suite boots with it |
| 8 | `maximum-prefix 4096 restart 10` on the Cilium session dropped it for 10 minutes | `maximum-prefix 4096 warning-only` | eval `test_localCiliumFrr` (routed-fabric) |
| 9 | A leaf could pass routes on | What a leaf imports is tagged `no-export` | eval `test_stabilityProfilesAndRecovery` |
| 10 | `ipv4NativeRoutingCIDR` is `10.0.0.0/8`: pods reached a host in another 10/8 network unmasqueraded | Eval refusal (`underlayViolations`): a member's static IPv4 netif address inside 10/8 and outside the cluster's ranges, with the address named. A DHCP address cannot be checked | eval `test_underlayInNativeRoutingRange` (k3s, rke2) |
| 11 | netif's guard rolled back the IfState file only | `specs/netif.md` N25: dhcpcd's configurations are recorded and restored; the rollback keeps the running generation's ignore lists | `netif-guard`, `NETIF_GUARD_OWNERS_OK` |
| 12 | The PKI install was skipped when its secret was missing | `AssertPathExists`: the unit fails, and the server with it | eval `test_g10Hardening` |
| 13 | HAProxy had no `timeout tunnel` | `timeout tunnel 1h` | eval `test_g10Hardening` |
| 14 | The router read netif's internal option | `clanServices.netif.links` is public (read-only); the router asserts that a zone's delegated subnet is a /64 | eval `test_zoneNotA64` |
| 15 | Every router boot retired the current prefix for some seconds | The hook's first run after a boot, with no state file and a prefix in use, keeps it for 45 s and runs again then (`router-prefix-recheck`) | `router`, the boot phases |
| 16 | A full rate-limit meter failed open | After each meter: a new flow whose source is not in the meter's set is dropped and counted (`nat64-*-full`) | eval `full` (nat-gateway); `nat-gateway` |

| 17 | Found by this round's first full run, older than the PR (in a suite log of 2026-11-18): **bgpd aborts** (`bgp_connect_timer(): assertion (!connection->t_read)`, FRR 10.7.1) when a neighbor's ConnectRetry timer expires while DelayOpen runs. Both were 5 s. watchfrr started bgpd again, so suites passed; under load it failed `k3s-clat` once | `timers connect 10` on every neighbor with DelayOpen | eval `test_stabilityProfilesAndRecovery` (`connectOutlastsDelayOpen`); no assertion and no core dump in any log of the last two runs. An argument from the timers and two runs, not a proof |

What these cost:

- The first start of a `clusterInit` server takes up to 30 s longer
  (the probe).
- A reinstalled `clusterInit` server does not come up until the owner
  moves `clusterInit` to a server that has the data. That is the point.
- Graceful restart hides a session loss for up to 120 s (Cilium) and
  60 s (fabric). A dead node is still found by BFD.

### 16.4 Evidence (2026-11-25, euc-hel-0)

Each line is one run, a sample (§12.4).

- **`nat-gateway-failover`** (`NAT_GATEWAY_FAILOVER_OK`, passed,
  2 176 s; the run before, beside other suites, 2 123 s). The timings
  of round G8 hold: withdrawn 31.6 s after every target or the
  translator died and 32.6 s after 80 % loss began; back 113.5 to
  114.4 s after a clean upstream; a client moved 62.9 s after a crash
  and 92.5 s after its gateway's targets died; a CLAT made again on
  the dead gateway's /96 corrected after 61.5 s.

- **`router-kube`** (`ROUTER_KUBE_OK`, passed, 326 s): alpha is a k3s
  server, a fabric spine and the router; beta a k3s agent in zone
  `servers`; a client in zone `home`; an internet host on the WAN.
  - Tables on alpha: `inet router`, `inet nixos-fw`, and Cilium's
    (through iptables-nft). The cluster came up through both.
  - Rendered `devices`: `<fabric link> <fabric loopback> eth2`. `eth2`
    is alpha's WAN and beta's uplink; both agents masquerade on it. No
    zone link of alpha is a device.
  - The IPv4 internet saw the WAN address from alpha's pod, beta's
    host, beta's pod, the home client and alpha itself. The IPv6
    internet saw the home client's and beta's own addresses (routed),
    and alpha's WAN address and beta's node address for their pods.
  - Refused: home to servers; the WAN to ports 22, 53, 6443, 10250,
    2379 on both address families (sshd and the kubelet listen on
    every address); a zone to 6443, 10250, 2379; a host in zone
    `servers` (not in `unzoned.zones`) to a pod on either node; the
    other zone's resolver address; a NodePort on the WAN address.
  - Allowed: SSH and the zone's own resolver from each zone; DHCPv4 in
    zone `home`; the home client to a pod on each node.
  - After a restart of nftables and an IfState apply: the same.
- **What the earlier runs of `router-kube` found** (each fixed before
  the next):
  1. beta's pod could not reach the internet: its packets left with
     the pod's address through a link that was no Cilium device. Fixed
     in SPEC.md D71 (the default-route link).
  2. The home client reached no pod on alpha: Cilium answered straight
     out of the zone link, conntrack saw no answer and dropped the
     client's next packets as invalid (12 counted). Fixed: the
     stateless rule ahead of connection tracking, and the masquerade.
  3. The home client reached no pod on beta: the fabric's WireGuard
     dropped a source that is not the cluster's, first the client's own
     address, then the LAN address a plain masquerade chose. Fixed:
     `unzoned.source`.
- **`nat-gateway`** (`NAT_GATEWAY_OK`, passed, 444 s; 2 234 s before
  the split): on both gateways the translator refused the gateway's
  own IPv4 addresses (`nat64-host` counted each try). A Jool instance
  given another pool6 was made again at the next start ("pool6 was
  2001:db8:ffff::/96 ..."), and not again at the start after. A
  mapping for another address was replaced. A beacon made to name
  `2001:db8:bad::/96` was logged once and moved nobody. Limits as in
  round G8: 20 of 40 simultaneous connections, 3 488 of 5 990
  datagrams dropped, the capped client's own meter 3 494 of 5 985.
- **`router`** (`ROUTER_OK`): every phase of round G7 with the NixOS
  firewall on; the tables are now `inet nixos-fw`, `inet router`,
  `inet router_svc`, `netdev router_src`. Passed, 378 s.
- **`k3s-clat`** (passed, 741 s), **`rke2-clat`** (passed, 928 s),
  **`nat-gateway-kube`** (passed, 255 s).
- Untouched suites were not run: `k3s-single`, `k3s-join`,
  `k3s-join-netif`, `k3s-modes`, `k3s-data-plane-netif`, `k3s-v6only`,
  `k3s-clat-mapped` and `netif-v6only` evaluate to the derivations of
  the commit before this round.

### 16.5 Evidence, round G10 (2026-11-25, euc-hel-0)

Each line is one run, a sample (§12.4).

- **All 48 suites passed on the final code**, in four `vm-test --all
  --remote --rebuild` runs joined by `--resume` (a suite ran again
  whenever its derivation changed). The last run: 29 suites, all
  passed, none `PASS(!)`.
- **What the runs found, each fixed before the next:**
  1. 25 suites did not build: the guard's merge script failed its
     lint (two long lines). No suite had booted it.
  2. `netif-dhcp`: two probes read the dhcpcd version from the unit's
     `ExecStart`, which is now a wrapper script. They read the script.
     The checks are the same.
  3. `k3s-clat` failed beside other suites: bgpd on a node aborted
     (item 17) while the other node rebooted.
  4. `k3s-join-netif`: "a reapply changes nothing" compared routes
     while the ClusterMesh apiserver's VIP was still being announced
     (the end of the first server's boot). The phase now waits until
     both nodes finished booting and their routes held still for 5 s.
     Its comparison is unchanged.
- **`k3s-frr-failure`** (`K3S_FRR_FAILURE_OK`, passed, 229 s):
  - a spine's bgpd killed: the leaf kept the spine's routes as stale
    paths (1 IPv4 path counted) and pods kept answering;
  - the Cilium agent restarted on a node: the other node kept that
    node's pod route for the 30 s watched (`FRR_CILIUM_RESTART_OK`);
  - the spine's machine crashed: the leaf dropped its pod route after
    0.6 s (`FRR_DEAD_NODE_OK`; the limit is 15 s). Graceful restart
    did not hide a dead node.
- **`netif-guard`** (`NETIF_GUARD_OK`, passed, 137 s): a rollback kept
  a link the running generation lists as another owner's
  (`NETIF_GUARD_OWNERS_OK`).
- **`router`** (passed, 324 s), with the boot grace of item 15;
  **`router-kube`** (passed, 302 s), with `unzoned.source` read from
  the fabric; **`nat-gateway`** (340 s), **`nat-gateway-failover`**
  (2 099 s), **`nat-gateway-kube`** (203 s), **`k3s-clat`** (653 s),
  **`rke2-clat`** (788 s).
- **Not run in a suite:** the init guard's refusal (item 4; the unit
  and its order are eval-tested, and every cluster suite boots through
  it), a changed `cilium-config` rolling the agents (item 5), the
  PKI assertion failing (item 12), a full meter (item 16; the rules
  are eval-tested and loaded in `nat-gateway`), and the router's
  boot grace with a prefix that really changed while it was off
  beyond the `router` suite's existing phases.

## 17. Round G11 (2026-11-26): hardening of the gateway services

The owner's hardening review of 2026-11-26 (networking and Kubernetes,
one PR in five slices) found G1–G14 in `nat-gateway`, `router` and
`lib/gateway`. The owner approved every fix; decisions 8 (G2) and 9
(G4) amend §14.1 point 4 and §14.5 point 4 (done first, hard rule 3).

### 17.1 Found and fixed

| # | Found | Now | Proof |
|---|---|---|---|
| G1 | `clat-follow` had `Requires=clat.service`. Every IfState apply restarts that oneshot (`PartOf`); one failed start stopped the follower for good ("dependency failed" is no failure `Restart=always` covers). The CLAT kept translating but never moved again | `Wants=` + `After=`; the follower waits by itself while there is no CLAT instance | eval `test_unitsRetry`; `nat-gateway`, `NAT_GATEWAY_CLAT_RETRY_OK`: a CLAT unit that cannot start during an IfState restart, the follower keeps its PID, the unit comes back by itself, the follower still moves |
| G2 | The follower reset its 60 s clock on every round in which no beacon answered. With its gateway dead and loss towards the other, a move needed about 40 answers in a row (simulated on the old script: median 87 s at 2 % loss, 201 s at 5 %, 1 049 s at 10 %) | §14.5 point 4 amended: a silent round keeps the clock; a move needs 60 s of silence and a candidate that named its own /96 in 5 of the last 10 rounds. Never back on its own. The rule is `Follower.step`, without I/O | `checks.clat-follow` (the real script against a fake clock: 200 seeded runs at 10 % loss all move within 64 s; 4 of 10 never moves; silence from 10 to 200 s, then a candidate: a move at 207 s; no move back; a gap under 60 s; a foreign prefix). `nat-gateway-failover`, `NAT_GATEWAY_LOSSY_CANDIDATE_OK` |
| G3 | `pool4` was added only when the instance was made: a start killed half way or one failed `add` left Jool on its fallback of a few thousand ports, and the ICMP health check stayed green | Every start checks that each protocol holds exactly `192.0.0.2 1100-65535`, else flushes and adds all three | eval `test_pool4Reconciled`; `nat-gateway`, `NAT_GATEWAY_POOL4_OK` (a pool4 of ten UDP ports and a flushed pool4 are both made whole by a restart; a whole one is left alone) |
| G4 | One `trusted` source could fill the 64 435 ports of a protocol in about a minute (1 000 new flows/s, Jool's UDP timeout 300 s), invisible to the health check | Decision 9: one `pool4` address stays. (a) `trusted` new flows 200/s, burst 4 000: 4 000 + 200 × 300 = 64 000 < 64 435; still overridable at the three levels of §14.5 point 3. (c) The health check reads Jool's BIB entries per protocol, pool4's size and the session count every 10 rounds into `health.json` (`pool4`) and logs a change of band (50, 80, 95 %). It never withdraws the beacon for it | eval `test_trustedBound`, `test_table`; `nat-gateway`, `NAT_GATEWAY_POOL4_OK`: 10 of 10 UDP ports held, logged at 95 %, the beacon stays |
| G5 | The meters were keyed by address while the allowlist takes prefixes: a client with a /64 had 2^64 meter entries to fill, after which the fail-closed rule refused every other idle client of its tier | Every meter (tiers and clients with their own limit) is keyed by `ip6 saddr & ffff:ffff:ffff:ffff::`; clients that share a /64 share its limit (§14.1 point 4 amended) | eval `test_meterPer64`, `test_table` (`full`) |
| G6 | A CLAT address inside a declared prefix (the documented SLAAC setup) made `conflicting intervals specified`: the source sets were `flags interval` without `auto-merge`; the eval tests' own inventory rendered it | `auto-merge` on `trusted`, `default`, `custom`; an eval refusal when a client with its own limit, or a source of the other tier, overlaps another client's sources | eval `test_sourceInsidePrefix`, `test_customOverlapsTier`; `nft -c` (1.1.6, a user namespace): the old sets fail, the new load |
| G7 | The prefix hook had no retry, and both of its tables loaded in one transaction: a LAN link absent at boot failed both, so no service rewrite and no egress source filter until the delegation changed | `Restart=on-failure`, `RestartSec=10`; one transaction and one generation per table; the run fails (and is retried) when one did not load | eval `test_hookRetries`; `router` (the hook's phases, unchanged log lines) |
| G8 | No retry of `nat64-jool` or `clat` after a failed start | `Restart=on-failure`, `RestartSec=5` on both oneshots | eval `test_unitsRetry`; `NAT_GATEWAY_CLAT_RETRY_OK` |
| G9 | No check that gateways have distinct `pool6`, that `address` is outside `pool6` and on the machine, that CLAT addresses differ, that health targets are public, or that `pool6` is a /96 network | Eval refusals for each; addresses compared normalized | eval `test_samePool6`, `test_addressInPool6`, `test_addressNotOnMachine`, `test_addressOtherSpelling`, `test_badPool6`, `test_privateTarget`, `test_duplicateClat` |
| G10 | A router with no resolver address rendered CoreDNS with an empty `bind` | CoreDNS only when there is an address to bind | eval `test_noZoneNoResolver` |
| G11 | The service's text said "unhealthy only when every target fails"; the check uses a quorum of 2 | Text corrected (§14.3, the option, the docs); `health.quorum`, `health.down`, `health.up` are service settings | eval `test_healthSettings` |
| G12 | The CLAT route's MTU was fixed at 1480 | `clat.mtu`, default the smallest MTU netif sets on the uplink zone (1500 when none) less 20 | eval `test_clatMtu` |
| G13 | Kea subnet ids were positional: a new zone renumbered the leases of the zones after it | The id is the first 28 bits of the SHA-256 of the zone's name, plus one; an eval refusal on a collision | eval `test_keaStableIds` |
| G14 | Small hardening: `nat64-health` and `clat-follow` ran as root with no sandbox; `ping.wait()`, `systemctl`, `jool` had no timeout; a beacon that could not bind was started and logged every second; `servicePrefix.expose` could lie outside `stable`; the hook's tables stayed after its removal; with rp_filter off machine-wide, the WAN could bring a source of the router's own networks | `lib/gateway/sandbox.nix` (strict file system, a capability bounding set per unit); timeouts on every call; the beacon is started again at most every 10 s and logged once a minute (`beacon_restarts` in `health.json`); an eval refusal for a pinhole outside `stable`; `router-prefix-tables` (`ExecStop` deletes both tables, never restarted on a change); `inet router` chain `wan` (priority raw) drops a WAN source in a zone's static networks, the stable /64, loopback or multicast, and the hook's `router_svc` drops one in the delegated prefix | eval `test_sandboxed`, `test_exposeOutsideStable`, `test_hookTablesRemoved`, `test_wanSpoofedSource`; every gateway and router suite runs the sandboxed units |

What these cost:

- A `trusted` source opens 200 new flows a second after its burst,
  not 1 000. A busy cluster node can be given more per client
  (`limits.newFlows`); it then owns that share of the pool.
- Clients in one /64 share one limit per tier.
- After a total outage, the first gateway whose beacon is back for 5
  rounds takes the clients whose gateway is still silent past 60 s.

### 17.2 Evidence (2026-11-26, euc-hel-0)

Each line is one run, a sample (§12.4). Every suite ran alone on
euc-hel-0 with `--rebuild`.

- **`checks.clat-follow`** (`CLAT_FOLLOW_SIM_OK`, static, no VM): 200
  seeded runs at 10 % loss towards the candidate, the slowest move
  64.0 s after the gateway went silent. The old script, 40 seeded
  runs each: median 87 s at 2 % loss, 201 s at 5 %, 1 049 s at 10 %
  (the slowest at 10 % had not moved after an hour).
- **`nat-gateway`** (`NAT_GATEWAY_OK`, passed, 536 s):
  - `NAT_GATEWAY_CLAT_RETRY_OK`: an IfState restart while the CLAT
    unit could not start; the follower kept its PID, the unit came
    back by itself (`NRestarts` grew), and the follower then moved a
    CLAT off a /96 nobody names after 61.1 s.
  - `NAT_GATEWAY_POOL4_OK`: the health state read 64 436 ports per
    protocol; with ten UDP ports and twenty flows it read
    `{"ports": 10, "used": 10, "percent": 100.0}`, logged the 95 %
    band, and the beacon stayed. A restart made a ten-port pool4 and a
    flushed pool4 whole again; a third restart left it alone.
  - The first run failed in this phase: the health check read pool4's
    port range from the wrong CSV columns (fixed; the columns are in
    `upstream-facts.md`).
- **`nat-gateway-failover`** (`NAT_GATEWAY_FAILOVER_OK`, passed,
  2 223 s): `NAT_GATEWAY_LOSSY_CANDIDATE_OK`: the current gateway's
  beacon dropped in silence and 10 % loss towards the other: the CLAT
  moved 67.2 s later, once, and stayed when the old beacon answered
  again. The timings of round G8 held: a client moved 62.8 s after a
  crash; withdrawn 32.4 s after the targets died, 31.5 s after the
  translator went, 36.2 s after 80 % loss began; back 113.6 to
  114.2 s after a clean upstream. The first run failed one check of
  the deploy phase: "resumed up" is no longer the journal's last line
  (the pool4 line follows); the check now reads the first line of
  that run of the unit.
- **`router`** (`ROUTER_OK`, passed, 380 s). The first run failed the
  hook's failure phase: a failed run is now retried by systemd, so
  the unit waits in `auto-restart` instead of `failed`; the helper
  accepts both, and corerad's restart still waits for a run that
  loads every table.
- **`router-kube`** (passed, 384 s), **`nat-gateway-kube`** (passed,
  282 s), **`rke2-clat`** (passed, 887 s), **`k3s-clat-mapped`**
  (passed, 321 s; it shares the changed reboot phase).
- **`k3s-clat`** (passed, 684 s). Two runs before it failed in
  "alpha reboots": the pod check's `kubectl exec` into beta's pod got
  `502 ... failed to find Session for client beta`. Beta's k3s agent
  had not yet dialled its tunnel to the rebooted server (it waits
  behind TCP's SYN backoff, up to about 2 min; in the passing run on
  `main` beside it, beta also sat in one dial for 134 s and connected
  by luck of timing). Nothing of this round is on that path (the
  CLAT and the follower were up 2 s into the boot). The phase now
  waits up to 180 s for `kubectl exec` into each pod before the
  unchanged pod-network assertion.
- **Grepped for crashes:** every Python traceback in these logs is a
  test client's expected timeout (`must fail`, the pool4 exhaustion)
  or the router suite's injected `systemctl` failure; no bgpd
  assertion, no core dump.
- **Not run:** `gateway-dual-wan`, `gateway-wan`, `netif-v6only`,
  `<distro>-v6only` use none of the changed code.
