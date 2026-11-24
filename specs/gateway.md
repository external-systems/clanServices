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
CLAT as default path with DNS64 optional, a per-client rate limit with
a `trusted` tier, rendered Cilium `devices` (SPEC.md D71), and native
routing only (SPEC.md D72). §14.3 sets the direction for each unfixed
finding.



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
  - **Proven on both transports** (native routing on `routed-fabric`,
    the VXLAN tunnel on `wireguard-mesh`), two nodes, IPv6-only NICs:
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
  | `gateway-nat64` | G2, G3, G4, G6, G23: two gateways, a client with a CLAT, an outsider; failover, hysteresis, the health check | `GATEWAY_NAT64_OK` |
  | `gateway-router` | G8, G10, G11, G14, G15, G20, G22; netif N16: zones, advertisements, the prefix hook, the service prefix | `GATEWAY_ROUTER_OK` |
  | `gateway-dual-wan` | G16; netif N21: two DHCPv4 WANs, failover without a route change | `GATEWAY_DUAL_WAN_OK` |
  | `k3s-v6only`, `rke2-v6only` | SPEC.md D67: the `join` contract on IPv6-only NICs | `<DISTRO>_V6ONLY_OK` |
  | `<distro>-clat-<transport>` (4) | G5 as decided, D67, on both transports | `<DISTRO>_CLAT_<TRANSPORT>_OK` |
  | `k3s-clat-<transport>-mapped` (2) | why G5 is needed (as shipped, pod IPv4 fails) and the documented alternative | `K3S_CLAT_<TRANSPORT>_MAPPED_OK` |

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
3. **The CLAT is the default path; DNS64 is optional** (point 3).
   - Every `nat-gateway` client runs a CLAT (G23) and uses plain
     resolvers.
   - DNS64 is a per-client option, off by default, for a machine that
     cannot run Jool. A gateway serves DNS64 only when a client asks
     for it.
   - G4's DNS64 listener, its TTL cap and its health coupling apply
     only then.
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
   - The numbers are settings; the defaults are chosen in the next
     session and written here.
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
- **Open, to settle first in the next session (one suite):**
  `devices` is one cluster-wide Helm value, and the names differ per
  node. Candidates, in order:
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
  - three or more health targets in different networks; unhealthy
    only when every target fails, for several rounds in a row;
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

Decided 2026-11-23: native routing only (SPEC.md D72). Tunnel mode
and `wireguard-mesh` are removed in the next session, after the tag
`tunnel-mode-final`. The `<distro>-clat-mesh*` suites go with them;
`<distro>-clat-fabric` remains the CLAT proof.
