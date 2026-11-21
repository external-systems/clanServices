# gateway — router and NAT gateway contract (agent edition)

The normative contract and status authority for two planned clanServices:
`services/router` (the edge of a LAN) and `services/nat-gateway` (IPv4
reach for machines that have none), and their private shared
implementation `lib/gateway/`. Both build on netif's zone seam
(`specs/netif.md` N10) and never declare links themselves. The human
rendering is `documentation/docs/gateway/`. **Edit this file and those
pages together.** Decisions are numbered `G1`–`G23`, so they never collide
with `N` (netif) or `D` (SPEC.md) numbers. Use cases stay in
`specs/netif.md` §2 (U3, U13–U18).

Round G0 (2026-11-20): **design round; docs only.** The owner decided the
shape in a deciding session. Nothing in this file is implemented. Every
decision is *(planned)* and several wait for a probe (§6).

Round G1 (2026-11-20): **probe round.** Probes ran on euc-hel-0 from the
branch `gateway-probes` (`lib/gateway/tests/probes/`, suites `probe-*`).
Evidence is §10. No service code exists yet.
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

## 0. Status vocabulary

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
    clients.
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
    `wireguard-mesh` renders its tunnel, and claims them in the
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

- **G4 Gateways are off-path.**
  - Each gateway serves its own /96 out of its public IPv6 prefix, and
    its own DNS64 that synthesizes into that /96.
  - Clients reach both over plain IPv6. A source allowlist, built from
    the `client` role, keeps a gateway from being an open relay. It is
    a rule of the forward chain (G2). It also covers the DNS64
    listener, or the gateway is an open resolver. A client's CLAT
    address (G23) is a second source to allow.
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

- **G5 Pod IPv4 egress in the cloud: the node's CLAT, with the pod
  range mapped statelessly** (decided by PR1, 2026-11-20).
  - Each node runs the CLAT of G23. Pod IPv4 that leaves the cluster
    takes the node's IPv4 default route into the CLAT and continues as
    IPv6 to the same NAT64 as the host's own traffic. One mechanism, no
    fabric dependency.
  - **Pod addresses are not masqueraded on the node.** The CLAT maps
    the pod range one to one into IPv6 (an explicit address mapping: a
    pod /24 to a /120 of the node's own /64). The gateway is the only
    place that keeps state. Its allowlist names that range, and the
    range is routed to the node.
  - Why not a masquerade (PR1, §10.8):
    - Cilium's eBPF masquerade covers only Cilium's own devices. Pod
      packets reached the CLAT with the pod's address;
    - an nftables masquerade on the CLAT link counted no packet: with
      eBPF host routing, pod traffic never passes that hook.
  - **Open, before code:**
    - the pod range per node is not static with multi-pool IPAM. The
      mapping either follows the node's allocations, or maps the whole
      cluster pool on every node into that node's /64 (a /16 needs a
      /112). The second needs no daemon and is the proposal;
    - the probe ran in tunnel mode (`wireguard-mesh`). Native routing
      (`routed-fabric`) sets a native-routing CIDR and is not probed;
    - uploads from a pod were not measured (the probe's tool sent no
      body).
  - **A, the fallback,** stays unused: carry pod IPv4 over the fabric
    to NAT44 on a gateway.
  *(probe-verified in tunnel mode, PR1; planned)*

### Redundancy

- **G6 1-n gateways, active-active, no session sync.**
  - Each gateway translates to its own public IPv4, so replies return to
    the gateway that holds the state.
  - Two gateways is the default; one is allowed.
  - Flows on a failed gateway **stall**; they do not reset (amended
    after PR2). Nothing sends a reset for a dead gateway: 20 s after
    the crash the client's TCP connection was still established and
    silent. An application notices through its own timeout or TCP
    keepalive. New connections go through another gateway. This is
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
      that one rule and flushes conntrack. IfState never sees a change,
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
  - **Open, before code:**
    - traffic from the router to a neighbour on a WAN's own subnet is
      steered to the active WAN too, and fails for the other WAN. The
      clean fix is a rule "main table, ignore default routes" before
      the mark rules; IfState 2.5.1 cannot declare it
      (`suppress_prefixlength`). The alternative is an nftables set of
      the WANs' subnets;
    - the probe's WANs were static. A DHCP WAN's gateway must reach
      its table: netif renders a table's default only for a static
      gateway today (N21, to amend);
    - the backup's delegated prefix is a runtime value, as in G20: the
      rewrite rule is written by G22's hook.
  *(planned; the mechanism is probe-verified for static WANs, PR9)*

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
  *(planned; probe-verified, PR8)*

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
  *(planned; probe-verified, PR2 and PR7)*

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
- Planned suites: `netif-router` (ISP, router, clients in two zones:
  DHCPv4, prefix delegation, advertisements, NAT44, zone isolation,
  blocklist, a prefix change and a reboot), `router-ipv6-mostly`,
  `nat-gateway` (two gateways, an IPv6-only client, a gateway failure),
  `router-dual-wan`, `router-service-prefix` (ISP, router, a cluster
  with a Service: reached from the ISP side on its public address, a
  closed port and an unused address refused, a prefix change),
  `routed-fabric-transit` (a border and two fake transit providers:
  aggregates only, no private AS number, no route passed between them).
- Every `clan.modules` entry needs a nix-unit test (`coverage.nix`).

## 6. Probes

Each runs before the code it gates. A finding goes into this file first.
Probes live in `lib/gateway/tests/probes/` and register as `probe-<name>`
suites, so `vm-test probe-<name> --remote --quiet` runs one. A probe
prints `FINDING` lines and asserts little. It is deleted when a real
suite asserts what it showed (as `specs/netif.md` N40).

| Probe | Question | Gates |
|---|---|---|
| PR1 | Node CLAT with Jool SIIT under Cilium: does pod IPv4 egress work? **Answered for tunnel mode, §10.8** | G5 |
| PR2 | Jool beside the nftables firewall: where is traffic filtered? **Answered, §10.1** | G2 |
| PR3 | corerad with a delegated prefix, PREF64 and DNS options. **Answered, §10.2** | G15, G22 |
| PR4 | k3s and rke2 on an IPv6-only underlay. **Answered for the join topology, §10.5** | SPEC.md D67 |
| PR5 | MAC override and a priority-tagged WAN (VLAN 0). **Answered, §10.4** | netif N43, N44 |
| PR6 | Prefix rewrite for a routed /64 whose public side is a runtime value: is the host part kept, does the client address survive, are unused addresses refused, what happens on a prefix change? **Answered, §10.3** | G20, G16 |
| PR7 | The CLAT's health check: does `ipv4only.arpa` name a live gateway's prefix, and how fast does the CLAT move? **Answered, §10.9** | G23 |
| PR9 | One router, two WANs: failover without changing a route, IPv6 prefix translation on the backup. **Answered for static WANs, §10.10** | G16, netif N21 |
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

### 10.1 `probe-nat64` (PR2; G2, G4, G6, G23)

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

### 10.2 `probe-router`, advertisements (PR3; G8, G10, G11, G14, G15, G22)

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

### 10.3 `probe-router`, service prefix (PR6; G20)

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

### 10.4 `probe-wan` (PR5; netif N43, N44)

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
- **Without the child** nothing passed in either direction: the router
  sent untagged frames, which the ISP's port ignored, and the kernel
  did not answer the ISP's tagged ARP on the plain link.
- **The child's MAC** is one IfState generates, not the parent's. On a
  real WAN the child needs `mac` too.
- Not shown in a VM: the 802.1p priority bits (they were 0), and what
  an optical module does with the tag.

### 10.5 `probe-k3s-v6only`, `probe-rke2-v6only` (PR4; SPEC.md D67)

The `k3s-join` and `rke2-join` suites, unchanged, with two differences: each node's only
NIC address is IPv6 (`2001:db8:1::1/64`, `::2`), and the WireGuard
endpoints are those addresses. Every subtest passed: the dual-stack
mesh, the agent joining through its own HAProxy, both nodes Ready with
dual-stack fabric addresses as InternalIP, Cilium healthy. No IPv4
address was on a NIC at any point.

Both distributions passed (k3s in 178 s, rke2 in 288 s).

Not covered by this probe: pulling images (they are preloaded), pod
IPv4 egress (PR1), and `routed-fabric` as the transport.

### 10.6 `probe-v6only-host` (netif N45; U13)

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

### 10.7 `probe-router`, the prefix hook (PR8; G22, netif N16)

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

### 10.9 `probe-nat64`, the CLAT follower (PR7; G23)

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

### 10.10 `probe-dual-wan` (PR9; G16, netif N21)

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
- netif's guard stayed green with a WAN down.
- **Still wrong:** from the router, a ping to the backup's gateway
  failed while the primary was active. It was steered to the primary.

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

1. `mac` on a physical link (N43).
2. A VLAN link with id 0 in a suite, with `mac` (N44).
3. The delegated prefix as a runtime file (N16).
4. `prefixDelegation.reserve` (N16).
5. `netif-v6only` (N45): the probe `probe-v6only-host` is its draft.

### 11.5 Suite topologies

| Suite | Nodes | Draft |
|---|---|---|
| `netif-router` | isp, router, client (home), node (servers) | `probe-router` |
| `router-service-prefix` | the same, plus a prefix change | `probe-router` |
| `nat-gateway` | client, outsider, gw1, gw2, server4 | `probe-nat64` |
| `netif-v6only` | static, slaac, provider, server4 | `probe-v6only-host` |
| `k3s-v6only`, `rke2-v6only` | the join suites on IPv6-only NICs | `probe-<distro>-v6only` |

## 12. Retrospective (2026-11-21): what is not proven, and what would harden it

Written after the probe rounds. Each item says what is weak and what
closes it. Nothing here is a decision; the owner picks what becomes one.

### 12.1 How strong the probe evidence is

- **Every probe ran once, alone, on an idle builder.** The timings in
  §10 (5 s, 5.6 s, 6.2 s, 4.4 s) are single samples. A suite asserts a
  bound with margin, never the sample.
- **A probe asserts little.** A green probe means its script ran to the
  end; the finding was read from `FINDING` lines by hand. A finding is
  only safe from regression once a suite asserts it. Until then, a
  nixpkgs bump can undo it silently.
- **All clients were Linux with dhcpcd or the kernel's own SLAAC.** The
  prefix retirement of G22, PREF64 and option 108 behave per operating
  system (RFC 9096 leaves room). NetworkManager, Android, iOS, Windows
  and consoles are unproven. NetworkManager can be put in a suite
  (`modes-desktop` has it); the others need the owner's devices.
- **All traffic was TCP of 2 MB, ping and DNS.** Not tested: large UDP,
  fragments, an ICMP "packet too big" crossing a translator (path MTU
  discovery through NAT64 and the CLAT), `traceroute`, long-lived idle
  flows against the conntrack timeout.
- **Four claims are still from memory:** Windows honours DHCP option
  108, the Nintendo Switch has no IPv6, Headscale is unsupported behind
  Cloudflare, the X710 rejects unqualified SFP+ modules. A VM cannot
  prove them. They need a source or the hardware.

### 12.2 Design risks

| Risk | Why it matters | What closes it |
|---|---|---|
| Jool is an out-of-tree kernel module | A kernel bump can break the build of every gateway and every CLAT at once. tayga was rejected, so there is no second translator | An evaluation check that `linuxPackages.jool` is not marked broken for the kernel the fleet runs; the NAT64 suite runs on every `org-pkgs` bump; name tayga as the documented emergency fallback for the CLAT only |
| GitHub has no IPv6 (checked 2026-11-21: `github.com`, `api.github.com`, `codeload.github.com` and `ghcr.io` publish no AAAA record; `cache.nixos.org`, `registry.k8s.io`, `quay.io`, Docker Hub, `git.clan.lol` do) | An IPv6-only machine cannot fetch a flake input from GitHub or an image from `ghcr.io` without a NAT64 gateway. The gateways become a dependency of every deploy and of the gateways' own repair | The two gateways are never updated together; a gateway keeps its own public IPv4 and so never needs NAT64 itself (already G3); a suite phase that fetches from an IPv4-only name through DNS64 with one gateway down |
| The CLAT follower has no hysteresis | It polls every 2 s and moves on the first different answer. Two gateways that both answer, one with packet loss, make it flap, and each move stalls open flows (G6) | Move only after N failed checks of the current gateway; prefer the current one while it is healthy; a suite phase with a lossy gateway |
| The health checks test the gateway, not what is behind it | A gateway whose IPv4 upstream is dead still answers `ipv4only.arpa` and a ping inside its /96 only if the target is beyond the gateway. The probes pinged a test server. The real target is not chosen | Decide the target: the gateway withdraws `ipv4only.arpa` when its own IPv4 check fails, so the client needs no internet target |
| One public IPv4 per gateway is about 64,000 flows per protocol | `pool4` is one address, ports 1100–65535. A cluster pulling images through it can exhaust it; conntrack on the gateway has its own limit | Export Jool's and conntrack's counters as metrics; an alert before exhaustion; `pool4` takes a list of addresses in the settings |
| DNS64 breaks a client that validates DNSSEC itself | A synthesised AAAA record has no signature | Document it; such a machine uses the CLAT and plain DNS. Not a blocker for the fleet (systemd-resolved does not validate by default) |
| `conntrack -F` on a WAN failover drops every flow on the router | LAN to LAN and router-local flows are cut too | Delete only entries whose reply direction used the dead WAN (`conntrack -D` by mark or by address) |
| Dual WAN on the IPv6 backup is stateful prefix translation | Inbound to the backup prefix needs a matching rewrite; class 3 services do not survive (already G16) | Stated in G16; the suite asserts the inbound direction fails closed, not open |
| The prefix hook was tested with one /60 and one change | Unproven: a /56 or a bare /64 (no room for zones), two prefixes at once, an ISP that changes the prefix across a router reboot without the old lease on disk, a lease shorter than the retirement window | Phases in `netif-router`; an assertion at evaluation time that the zones fit the smallest expected delegation |
| nftables has several writers and no ownership rule | The NixOS firewall, the router's table, Cilium (through iptables-nft) and the dual-WAN steering all add tables. netif has a registry for links; nothing equals it for tables | A rule in the spec: one table per owner, named after the instance, never `flush ruleset`; a suite assertion that a restart of one owner leaves the others' tables byte-equal |
| Deploying an IPv6-only fleet needs IPv6 at the deploying machine | `targetHost` is the underlay address (AGENTS.md rule 11). The home router that provides that IPv6 is deployed by the same clan | Keep an IPv4 path to at least the gateways and the Headscale machine (they have public IPv4); document the bootstrap order: gateways, Headscale, router, the rest |
| A hot path depends on unit ordering | The hook that blocked on `try-restart corerad` hung the next boot for 300 s (§10.7); a Jool unit that was not idempotent broke on an IfState apply (§10.9) | A suite phase in every gateway suite: `systemctl restart ifstate.service`, then a reboot, then the full assertions again |

### 12.3 The two Cilium modes: what each suite covers

The owner uses the routed fabric (FRR, native routing) most, and wants
the tunnel mode kept equal where the mode allows it.

| Contract | Native routing on `routed-fabric` | VXLAN tunnel on `wireguard-mesh` |
|---|---|---|
| One server | covered inside `data-plane` | `single` |
| A second node joins | covered inside `data-plane` | `join` |
| Three servers, one dies | **no suite** | `ha` |
| LoadBalancer pools, Node IPAM, firewall, a node dies | `data-plane` | **no suite** (BGP delivery cannot apply; pool allocation, Node IPAM and the firewall can) |
| netif renders the underlay | `data-plane-netif`, `routed-fabric-netif` | **no suite** |
| ClusterMesh | `clustermesh` | `clustermesh-tunnel` |
| ClusterMesh, external and selective | `clustermesh-external-native`, `clustermesh-selective` | `clustermesh-external`, `clustermesh-selective-tunnel` |
| A cluster inside a mode | **no suite** (`modes` has a fabric, no cluster) | `k3s-modes` |
| IPv6-only NICs, two nodes | PR10 | PR4, PR10 |
| Pod IPv4 egress through a CLAT | PR10 | PR1, PR10 |

Closing the gaps without doubling the suite count: a suite body takes
`transport` as an argument, as `kube-clat.nix` does, and the same test
script runs on both. Phases that only one mode has branch explicitly,
as bodies already do on `distro`. Proposed order:

1. `ha` on the fabric: the control plane losing a server is the
   failure the owner's clusters will see most.
2. The mode-neutral phases of `data-plane` on the mesh.
3. `data-plane-netif` on the mesh.

### 12.4 Suite stability

- **Fixed sleeps.** 9 suite files (4 of netif, 5 cluster bodies) and 6
  probes call `sleep` in their test script. Each is a
  guess about the builder's speed. A suite waits for the condition
  (`wait_until_succeeds`) or, to prove something does *not* happen,
  watches for a stated time and says so in the subtest name.
- **No versions in the output.** A suite that prints the kernel, Jool,
  Cilium, FRR, IfState and dhcpcd versions in its first subtest ties a
  regression to the bump that caused it.
- **A fresh full run before every merge that touches netif or the
  shared base.** The netif change of this round ran one suite, not 37.
- **Flakiness is unmeasured.** `PASS(!)` is recorded per run and then
  forgotten. A log of which suites needed the rerun, kept across runs,
  shows which waits to fix first.
- **Probes copy fixture code.** The CLAT node appears in two probes and
  the gateway in a third file. They move to `lib/gateway/` as modules
  in S4, and the suites import the modules, so a suite tests the code
  a machine runs.
- **Failure dumps.** The cluster suites dump state on failure; the
  probes and netif suites mostly do not. One shared helper in `tests/`.

### 12.5 The agent's working environment

Found while doing the work; each costs time or correctness on every
session.

- **Number ranges live in three files** (`AGENTS.md`, this file's
  header, `decisions/index.md`). Each new decision edits all three. Keep the range in this file only.
- **This file's sections were out of order** (§11 sat before §10.6)
  until this round. A check that heading numbers ascend is cheap.
- **Findings are read out of a 10,000-line build log.** If `vm-test`
  copied lines that start with `FINDING` into `summary.txt`, a probe's
  result would be one short file. That is an org-pkgs change.
- **`AGENTS.md` carries a growing list of verified upstream facts** on
  every turn of every session. Most are needed in one service. They
  belong in a reference page that `AGENTS.md` points to.
