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
- G22 and G23 are *proposed*: the probes show they work, the owner has
  not confirmed them.

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
  - netif declares the namespace and the veth pair (IfState
    `namespaces`): IfState deletes a namespace it does not know. An
    IfState apply keeps the namespace and the Jool instance (§10.1).
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

- **G5 Pod IPv4 egress in the cloud.**
  - **B, the target:** each node runs a CLAT (Jool SIIT). Pod IPv4
    leaves the node as IPv6 towards the same NAT64. One mechanism, no
    fabric dependency, and IPv4 literals work on the host too.
  - **A, the fallback:** carry pod IPv4 over the fabric to NAT44 on a
    gateway.
  - Probe PR1 decides. Amend this decision with the result before code.
  - The host half is proven (PR2): a CLAT built as G23 carries IPv4
    literals, ping and bulk traffic from an IPv6-only host. Under
    Cilium the open question is whether pod traffic passes the hook
    Jool uses at all.
  *(planned; PR1)*

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
  *(planned)*

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

- **G22 A prefix change is handled, not waited out** (proposed
  2026-11-20; PR3, §10.2). When the ISP delegates another prefix, a
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
  *(proposed; the deprecation and the rule update are probe-verified)*

- **G23 The CLAT** (proposed 2026-11-20; PR2, §10.1). A machine without
  IPv4 that must reach IPv4 literals runs a CLAT:
  - a namespace and a veth pair declared by netif, with Jool SIIT in
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
    that points the CLAT at a live gateway. Asking each nameserver for
    `ipv4only.arpa` (RFC 7050) would test DNS64 and name the prefix in
    one step; that is not probed yet.
  - Rejected for the host path: one shared /96 for all gateways. It
    needs a route that follows gateway health, which is the fabric,
    and G4 keeps the host path off the fabric.
  *(proposed; the CLAT and the switch are probe-verified)*

## 3. Invariants (target)

1. Neither service declares a link, an address or a route: netif does.
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
| PR1 | Node CLAT with Jool SIIT under Cilium: does pod IPv4 egress work? | G5 |
| PR2 | Jool beside the nftables firewall: where is traffic filtered? **Answered, §10.1** | G2 |
| PR3 | corerad with a delegated prefix, PREF64 and DNS options. **Answered, §10.2** | G15, G22 |
| PR4 | k3s and rke2 on an IPv6-only underlay. **k3s answered, §10.5** | SPEC.md D67 |
| PR5 | MAC override and a priority-tagged WAN (VLAN 0). **Answered, §10.4** | netif N43, N44 |
| PR6 | Prefix rewrite for a routed /64 whose public side is a runtime value: is the host part kept, does the client address survive, are unused addresses refused, what happens on a prefix change? **Answered, §10.3** | G20, G16 |
| PR7 | The CLAT's health check: does `ipv4only.arpa` name a live gateway's prefix, and how fast does the CLAT move? | G23 |
| PR8 | The prefix hook end to end: netif's trigger, corerad restarted with the old prefix deprecated, the rule replaced, a reboot in between | G22 |

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

### 10.5 `probe-k3s-v6only` (PR4; SPEC.md D67)

The `k3s-join` suite, unchanged, with two differences: each node's only
NIC address is IPv6 (`2001:db8:1::1/64`, `::2`), and the WireGuard
endpoints are those addresses. Every subtest passed: the dual-stack
mesh, the agent joining through its own HAProxy, both nodes Ready with
dual-stack fabric addresses as InternalIP, Cilium healthy. No IPv4
address was on a NIC at any point.

Not covered by this probe: pulling images (they are preloaded), pod
IPv4 egress (PR1), `routed-fabric` as the transport, and rke2.
