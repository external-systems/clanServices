# gateway — router and NAT gateway contract (agent edition)

The normative contract and status authority for two planned clanServices:
`services/router` (the edge of a LAN) and `services/nat-gateway` (IPv4
reach for machines that have none), and their private shared
implementation `lib/gateway/`. Both build on netif's zone seam
(`specs/netif.md` N10) and never declare links themselves. The human
rendering is `documentation/docs/gateway/`. **Edit this file and those
pages together.** Decisions are numbered `G1`–`G19`, so they never collide
with `N` (netif) or `D` (SPEC.md) numbers. Use cases stay in
`specs/netif.md` §2 (U3, U13–U16).

Round G0 (2026-11-20): **design round; docs only.** The owner decided the
shape in a deciding session. Nothing in this file is implemented. Every
decision is *(planned)* and several wait for a probe (§6).

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

- **G2 Jool is the only translator.**
  - Stateful NAT64 on gateways; SIIT for the node CLAT (G5) and for
    inbound IPv4 (G12).
  - Reason (owner): it runs in the kernel, so no per-packet context
    switch, and one tool covers both modes.
  - A machine that runs Jool uses a kernel Jool builds against.
  - Jool translates in a netfilter hook. Where the nftables firewall
    sees translated packets is settled by probe PR2; a network namespace
    of its own for Jool is the expected answer.
  *(planned; PR2)*

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
    the `client` role, keeps a gateway from being an open relay.
  - A client lists every gateway as a nameserver. A dead gateway stops
    answering DNS, so the next gateway's prefix is used.
  - The host path never depends on the fabric, so a broken fabric cannot
    stop a machine from fetching its own fix (the spirit of AGENTS.md
    rule 11).
  *(planned)*

- **G5 Pod IPv4 egress in the cloud.**
  - **B, the target:** each node runs a CLAT (Jool SIIT). Pod IPv4
    leaves the node as IPv6 towards the same NAT64. One mechanism, no
    fabric dependency, and IPv4 literals work on the host too.
  - **A, the fallback:** carry pod IPv4 over the fabric to NAT44 on a
    gateway.
  - Probe PR1 decides. Amend this decision with the result before code.
  *(planned; PR1)*

### Redundancy

- **G6 1-n gateways, active-active, no session sync.**
  - Each gateway translates to its own public IPv4, so replies return to
    the gateway that holds the state.
  - Two gateways is the default; one is allowed.
  - Flows on a failed gateway reset; clients reconnect through another.
    This is failover, not hitless high availability.
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
    firewall opens one pinhole.
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
  DNS options with corerad. *(planned; PR3)*

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
      inbound addresses survive a carrier failure.
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

## 3. Invariants (target)

1. Neither service declares a link, an address or a route: netif does.
2. A router with default settings accepts no inbound connection from a
   `wan` zone.
3. No flow passes between two zones unless `allowTo` names the pair.
4. A NAT64 gateway translates only for its declared clients.
5. A metrics endpoint is never reachable from a `wan` zone or a LAN zone.
6. Every global is namespaced by `instanceName` (AGENTS.md rule 5).

## 4. Out of scope

- IPv4-only networks (P1).
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
  `router-dual-wan`.
- Every `clan.modules` entry needs a nix-unit test (`coverage.nix`).

## 6. Probes

Each runs before the code it gates. A finding goes into this file first.

| Probe | Question | Gates |
|---|---|---|
| PR1 | Node CLAT with Jool SIIT under Cilium: does pod IPv4 egress work? | G5 |
| PR2 | Jool beside the nftables firewall: where is traffic filtered? | G2 |
| PR3 | corerad with a delegated prefix, PREF64 and DNS options | G15 |
| PR4 | k3s and rke2 on an IPv6-only underlay | SPEC.md D67 |
| PR5 | MAC override and a priority-tagged WAN (VLAN 0) | netif N43, N44 |

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

## 8. Owner hardware (does not gate the spec)

- Whether the planned NIC accepts the XGS-PON module, and the module's
  heat.
- Whether the ISP gateway bypass gets the full /60 (16 zones' worth of
  /64s).

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
- **PREF64** — the router-advertisement option that tells a host the
  NAT64 prefix.
- **SIIT** — stateless one-to-one translation between IPv4 and IPv6.
- **ULA** — a private IPv6 prefix (`fd00::/8`).
- **VRRP** — a protocol by which routers share one virtual gateway
  address.
