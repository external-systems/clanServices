# netif — host networking contract (agent edition)

The normative contract and status authority for how every machine gets its
network configuration: `services/netif`, the shared IfState base
(`lib/ifstate.nix`), the ownership registry and the mode model. `SPEC.md`
keeps the Kubernetes bootstrap and data-plane contracts; `routed-fabric`,
`wireguard-mesh`, `k3s` and `rke2` consume this contract. The human
rendering is `documentation/docs/netif/`. **Edit this file and those pages
together.** Decisions are numbered `N1`–`N29` so they never collide with
SPEC.md's `D1`–`D66`. Phases are also numbered `N0`–`N8`; a phase is
always written "phase N2", a decision plain "N2" (§10).

Round use-cases (2026-11-16): **the contract is widened to the owner's
whole fleet and its boundary is written down; docs only.** The owner
listed every machine class netif must serve (§2, U1–U11) and answered 23
design questions. Two throwaway probes ran on euc-hel-0 (§8). New
decisions:
- **N20** the responsibility boundary: what netif owns, what it never
  owns, and who does (§1.1).
- **N21** `defaultRoute` per link and family; RA defaults join the
  one-default rule.
- **N22** a `containers` preset for Docker and Podman. The probe showed
  IfState deletes `podman0`.
- **N23** VM hosts: a bridge takes its uplink's MAC, accepts VLAN and
  bond members, and can hand undeclared ports to the hypervisor.
- **N24** a `modes` clanService holds each machine's mode list.
- **N25** a lockout guard rolls the network back when the gateways stop
  answering after an apply.
- **N26** `match.path` for cloud NICs; cloud-init networking is an eval
  error.
- **N27** a roaming Kubernetes node uses its fabric loopback as node
  address.
- **N28** a VM-test fixture for other repos, after the contract gate.
- **N29** NetBird and Cloudflare WARP presets, after the contract gate.
Changed decisions:
- **N9** per-link DNS failed its gate as designed. A netif unit now
  writes resolved; dhcpcd's resolvconf hook goes away.
- **N14** version rules are dropped until a real consumer exists. The two
  gates stay, named contract gate and field gate.
- **N16** gains `noipv4ll` and loses the resolvconf hook.
- **N18** `ra_defrtr_metric` is written by netif's link hook: IfState
  2.5.1's schema rejects that sysctl.
- **N10** NAT is never netif's (N20); the router has five ports.
A glossary is §10.

Round N3b-spec (2026-11-16): **the contract is refined before N3b code;
docs only.** A review of `main` against this file found gaps, now
decisions:
- **N16** dhcpcd gets a per-link config file and a fixed job: leases,
  DHCPv6 and prefix delegation only, one writer per kernel setting.
  Delegated prefixes are runtime facts, never written into the config.
- **N17** `pathMtu`: the smallest MTU towards fabric peers, which the
  transports prefer.
- **N18** default routes from several owners (wired, Wi-Fi, Tailscale)
  follow a fixed metric order.
- **N19** links are untrusted by the firewall unless declared trusted.
- **N9** is concrete: resolved is on in every IfState mode, static DNS is
  per link, and the cross-instance DNS conflict check goes away.
- **N10**'s zone seam and the export's `schemaVersion` 2 move into N3b.
- **N14** splits 1.0 into a contract gate (N6a, VM-proven) and a field
  gate (N6b, home runs U1–U4).
- **Invariant 5** has a test definition (§7) and one shared helper.
- **N8** records that IfState route ignores match `dev` as a regex, so
  netif anchors its own.
Drift found by the review is listed in §5; N3b fixes it.

Round N3a (2026-11-15): **physical NICs: identity, presence, passthrough
(N15).** Phase N3 is split: N3a (`match.mac`, a missing NIC fails
loudly, the checked `extraSettings` passthrough) is implemented and
VM-proven by `netif-match` (`NETIF_MATCH_OK`). Probing the IfState 2.5.1
source showed a declared physical NIC that is missing only logs
"unable to create physical link" and exits 0, so netif adds its own
post-apply check. N3b (DHCPv6-PD settings, `pathMtu`, per-link resolved
DNS) stays planned.

Round N1 (2026-11-15): **the ownership registry is implemented and
enforced.** `lib/ownership.nix` (imported by the shared IfState base)
holds `clanServices.networking.owners`, the four presets, N7's ordering
and N11's checks; ownership conflicts, IfState Wi-Fi links and daemons
without a preset are eval errors. The suite `netif-registry` proves it
(`NETIF_REGISTRY_OK`). NetworkManager rendering of the registry waits
for N2.

Round N0 (2026-11-15): **the contract is split out of SPEC.md and
revised for the owner's machines** — a Steam Deck and kamrui-h1 that boot
into a gaming mode and offer developer/kubernetes modes, a headless home
router, and servers. Docs only: no code changes in this round. The model
was checked first with two throwaway VM probes on euc-hel-0 (§8). It
supersedes SPEC.md D50, D53 and D61 where they conflict; SPEC.md points
here.

## 0. Status vocabulary

- **implemented** — in `main`, covered by eval tests.
- **VM-proven** — a registered suite in `legacyPackages.<system>.vmTests`
  passes; the status names the suite and its `*_OK` marker.
- **probe-verified** — a throwaway VM probe passed on the stated date (§8).
  It proves feasibility, not the implementation. Every probe-verified
  claim must become VM-proven before the contract gate (N14).
- **planned** — target contract with a delivery phase (§9).

## 1. Model

| Piece | Role |
|---|---|
| `netif` | The only network contract in the inventory, for every machine and mode (N1). |
| IfState 2.5.1 | Renderer in IfState modes: routers, servers, developer and kubernetes modes (N2). |
| NetworkManager | Renderer in NetworkManager modes (gaming); never in the same system configuration as IfState (N2). |
| iwd | Owns every Wi-Fi link in every mode (N5). |
| Ownership registry | Tells IfState and NetworkManager which objects belong to someone else (N6). |
| Modes | NixOS specialisations; the default boot entry is the parent configuration; switching is by reboot (N3). |
| `modes` service | Holds each machine's mode list and manager; every networking and cluster service reads it (N24). |
| Lockout guard | Re-applies the previous network config when the gateways stop answering after an apply (N25). |

### 1.1 Responsibility (N20)

netif answers one question: **which links does this machine have, and
how does each get its addresses, routes, DNS and firewall trust.**

| netif owns | Through |
|---|---|
| Physical NICs, VLANs, bonds, bridges: existence, name, MTU, MAC, state | IfState, or NetworkManager profiles |
| Static addresses; DHCPv4, DHCPv6, prefix-delegation clients; RA acceptance | IfState, dhcpcd under a netif hook |
| Default and static routes, underlay policy routing, route metrics | IfState, dhcpcd, the link hook |
| DNS servers per link | the netif DNS unit writing systemd-resolved (N9) |
| Firewall trust per link, and a zone label | `networking.firewall.trustedInterfaces`; read-only facts |
| The ownership registry, its presets, and the reapply guarantee | `clanServices.networking.owners` |
| Which manager a mode uses | the `modes` service (N24) |
| The lockout guard | N25 |
| Facts for consumers: link names, zones, MTU, endpoints, deploy target | exports, `clan.networkFacts`, read-only NixOS options |

| netif never owns | Owner |
|---|---|
| Wi-Fi association, its DHCP and roaming | iwd (N5) |
| NAT, port forwarding, firewall rules beyond trust | a gateway or router module built on netif's zones (N10) |
| DHCP server, router advertisements sent to others, DNS server | the router module in `modules` (N10) |
| WireGuard tunnels, BGP, fabric addresses | `routed-fabric`, `wireguard-mesh` |
| Pod and Service networking, node addresses | `k3s`, `rke2`, Cilium (SPEC.md) |
| VPN clients | Tailscale and other registry owners (N6, N29) |
| Container and guest ports | Docker, Podman, the hypervisor (N22, N23) |
| Hostname, `/etc/hosts`, mDNS, time, proxies | plain NixOS configuration |
| Desktop, Steam, KDE | the machine's configuration in home |
| Network in the initrd | out of scope (§6) |

Rules that follow:
- A module that needs a link, an address or a route asks netif for it in
  the inventory. It never sets `networking.interfaces`, IfState settings
  or NetworkManager profiles itself.
- A daemon that creates kernel network objects registers an owner.
- netif gives no meaning to a zone and renders no NAT.

## 2. Use cases (first-class)

Every use case names what it needs from netif. "Covered by" lists the
decisions; §9 has the phase. A use case is done when home runs it (the
field gate, N14).

- **U1 Steam Deck.** Jovian NixOS.
  - Default boot: gamescope Steam mode with NetworkManager (Jovian
    requires it for Steam's network UI and first-time setup). Wi-Fi and
    wired ad hoc, Tailscale.
  - `developer`: no Steam. KDE, IfState, Wi-Fi through iwd, a dock ad
    hoc, Tailscale, Docker or Podman, FRR client access (`routed-fabric`
    leaf with `access = "admin"`) to pod and Service IPs of other
    clusters.
  - Covered by: N2, N3, N5, N6, N12, N18, N22, N24.
- **U2 kamrui-h1.**
  - Default boot: a regular KDE desktop for Steam and browsing, with
    NetworkManager; Wi-Fi and wired ad hoc.
  - `developer`: as U1's developer mode, no Kubernetes.
  - `kubernetes`: developer plus a single-node k3s server, FRR client,
    and Cilium ClusterMesh in native-routing mode.
  - Covered by: U1's list, plus N4 and N27.
- **U3 Home router.** Headless. Four SFP+ ports on a PCIe card and one
  10G RJ45 port; one port is the WAN. NAT gateway, DHCP server and IPv6
  for the house, the fleet's edge with ECMP towards the Kubernetes nodes
  behind it. Wi-Fi for the house comes from separate access points on
  the LAN: the router has no radio. Router services live in `modules`;
  netif owns the links.
  - Covered by: N10, N15, N16, N19, N25.
- **U4 Headless servers.** euc-hel-0: a single-node RKE2 server with a
  stable address, FRR, and ClusterMesh in native-routing mode. IfState
  only, no modes.
  - Covered by: N8, N15, N17, N19, N25.
- **U5 VM host with provider MACs.** A bare-metal machine (Hetzner Robot)
  that hosts guests. Each guest gets its own public address and a MAC the
  provider issued, for example a Windows VM. The hypervisor is KubeVirt
  with Multus, or Incus.
  - Covered by: N23.
- **U6 Cloud VMs, native routing.** Hetzner Cloud, AWS, GCP, Azure.
  DHCP underlays, often two NICs (public and private), path MTU below
  1500 on some. Kubernetes with Cilium native routing, FRR, ClusterMesh.
  - Covered by: N16, N17, N21, N26.
- **U7 Proxmox VMs, tunnel mode.** Headless guests with Kubernetes and
  Cilium in tunnel mode, ClusterMesh with clusters of the same kind.
  - Covered by: N15 or N26, N17.
- **U8 Bare-metal Kubernetes nodes at home.** Headless, on the LAN behind
  U3, Cilium native routing with FRR, ClusterMesh.
  - Covered by: U4's list.
- **U9 Machines behind a gateway.** A machine with no public address that
  sends all IPv4 and IPv6 traffic to another machine. For netif this is
  a static default gateway (often on-link). The gateway's NAT is not
  netif's (N20).
  - Covered by: N20, N21.
- **U10 One machine, several roles.** A machine whose modes differ in
  kind: a headless server in one mode, a gamescope box in another. The
  default mode may use either manager.
  - Covered by: N3, N4, N24.
- **U11 VM tests.** Ephemeral NixOS test VMs in this repo and, later, in
  home and modules.
  - Covered by: §7, N28.

Across all of them: Tailscale is first class in every mode; NetBird and
Cloudflare WARP are planned (N29); WireGuard is `routed-fabric` and
`wireguard-mesh` only (N6).

## 3. Decisions

- **N1 netif is the single contract; the name stays `netif`.** Every link,
  address mode, route, policy rule, MTU, DNS server and firewall trust a
  machine has is declared through netif instances in the inventory, in every
  mode. Supporting modules (for example the router services in `modules`)
  consume netif's facts; they never declare links or addresses themselves.
  The service is not renamed to `ifstate`: it also renders NetworkManager
  modes, and the name would collide with the upstream project, the NixOS
  option and the `ifstate.service` unit.

- **N2 One manager per system configuration.** Each mode has exactly one
  manager, `ifstate` or `networkmanager`. A system configuration with both
  enabled is an eval error (the nixpkgs IfState module already asserts this;
  netif adds a clearer message naming the mode). netif keeps the stock
  nixpkgs IfState and NetworkManager modules: no fork, no `disabledModules`.
  - The **IfState renderer** emits `networking.ifstate.settings`, as today.
  - The **NetworkManager renderer** emits declarative NetworkManager
    profiles (`networking.networkmanager.ensureProfiles`) for wired links
    (static or DHCP), sets `wifi.backend = "iwd"`, and marks every
    registry-owned interface unmanaged. It does not render WireGuard,
    VLAN/bond/bridge, policy routing or fabric objects: those require an
    IfState mode (eval error otherwise).
  - The probe (§8) verified the mutual exclusion in both directions: gaming
    boots ran NetworkManager with no `ifstate.service` unit at all; developer
    boots ran IfState with NetworkManager inactive.
  *(probe-verified; renderer planned, phase N2)*

- **N3 Modes are NixOS specialisations, switched by reboot.**
  - The parent configuration is the default boot entry; each further mode is
    `specialisation.<mode>`. The owner picks the mode in the boot menu.
  - Switching modes at runtime (`switch-to-configuration` into another
    specialisation) is **out of scope**. Every mode starts from a fresh
    kernel network state, so no hand-over or cleanup step exists.
  - Deploying to a machine with modes must not switch it into another mode
    live. Supported forms: `clan machines update <machine> --specialisation
    <booted-mode>` (re-activates the booted mode) or `nixos-rebuild boot`
    (applies on the next reboot). A bare `clan machines update` activates the
    parent (default) mode and is the owner's explicit choice only.
  - The probe booted gaming → developer → gaming through systemd-boot entries
    on a persistent disk and verified each mode's state (§8).
    *(probe-verified; mode settings planned, phase N4)*

- **N4 Mode-scoped instances.** A per-machine setting on every networking or
  cluster service instance names the modes it is active in (`modes`,
  default: every mode of the machine; the parent mode is named `default`).
  The machine's mode list comes from the `modes` service (N24).
  - What stays in the parent configuration whatever the mode: vars
    generators, exports, `clan.networkFacts`, assertions, and the generated
    files themselves. clan reads vars and exports from the parent
    configuration, and specialisations inherit it, so secrets (WireGuard
    keys, kubeconfigs) exist in every mode.
  - What the setting gates: units, IfState objects, FRR, HAProxy,
    Kubernetes, firewall openings and sysctls. They render only into the
    named modes' configurations.
  - Services that need IfState (`routed-fabric`, `wireguard-mesh`, `k3s`,
    `rke2`) may only be active in IfState modes: eval error otherwise.
  - Eval rejects scoping a `spine`, a `border`, or an etcd voter of a
    multi-node cluster to fewer than all of a machine's modes: switching it
    off would remove transit or quorum from other machines. Leaves, agents
    and single-node clusters (kamrui-h1's local k3s) may be mode-scoped.
  *(planned, phase N4)*

- **N5 iwd owns Wi-Fi in every mode.**
  - **NetworkManager modes:** NetworkManager drives iwd as its Wi-Fi
    backend. Steam's UI and the KDE applet join networks through
    NetworkManager over D-Bus.
  - **IfState modes:** iwd runs on its own with `EnableNetworkConfiguration
    = true`. It does association, DHCP and roaming, and sends DNS to
    systemd-resolved (`NameResolvingService = systemd`). IfState never
    configures a Wi-Fi link: the link and the routes iwd installs are
    registry-owned (N6). An IfState interface named `wl*` is an eval error
    in every mode, whether or not iwd is enabled (implemented, N1).
  - **Known networks are shared through `/var/lib/iwd`.** NetworkManager's
    default `iwd-config-path = auto` writes each Wi-Fi profile there. With
    the iwd backend, iwd's own autoconnect picks among known networks, and
    NetworkManager lists networks iwd already knows. Effects:
    - a café joined in Steam's UI is joined automatically after rebooting
      into developer mode;
    - a network joined with `iwctl` in developer mode appears in
      NetworkManager, and so in Steam's UI, after rebooting into gaming.
    *(probe-verified both directions)*
  - Unknown networks (cafés, other homes) are joined ad hoc: Steam UI or the
    KDE applet in NetworkManager modes, `iwctl` or an iwd front end in IfState
    modes. Declaring networks in the inventory (PSK as a prompted clan var) is
    optional, for networks that must work on first boot.
  - A Wi-Fi link never carries a static core address, a literal endpoint, or
    the deploy target.
  - **Steam over the iwd backend:** not VM-testable (Steam cannot run in a VM
    test). Evidence: Jovian only requires `networking.networkmanager.enable`,
    Steam talks to NetworkManager's backend-neutral D-Bus API, and Jovian's
    `steamos-manager` ships iwd integration because SteamOS uses NetworkManager
    with iwd. A one-time hardware check on the Deck closes it (phase N2).
  *(probe-verified except Steam itself; planned, phase N2)*

- **N6 Ownership registry.** `clanServices.networking.owners.<name>` is a
  composable NixOS option. Each owner declares the objects it owns:
  - interface-name regexes;
  - named network namespaces;
  - routing tables;
  - policy-rule priorities or tables;
  - route selectors;
  - whether its daemon holds long-lived network sessions (N7).

  The base renders every owner into IfState `parameters.ignore`
  (`ifname`, `netns`, `rules`, `routes`) and, from phase N2, into
  NetworkManager `unmanaged-devices`. Rendering per owner:
  - each interface regex → `ignore.ifname` and a route ignore `{dev}`
    (routes on an owned link are the owner's);
  - each netns regex → `ignore.netns`;
  - each table → a route ignore and a rule ignore `{table}`;
  - each rule priority → a rule ignore `{priority}`;
  - raw `routes`/`rules` selectors pass through;
  - `sessionUnits` get N7's ordering.

  Regexes are POSIX ERE matched from the start (IfState uses Python
  `re.match`), so eval can test them. Presets switch on automatically from
  the NixOS option that enables their daemon (each is `mkDefault`, so a
  machine can switch one off):

  | Preset | Owns | Status |
  |---|---|---|
  | `iwd` (`networking.wireless.iwd.enable`) | `^wl` links and the routes on them | VM-proven |
  | `tailscale` (`services.tailscale.enable`) | `^tailscale`; rules 5210/5230/5250/5270 and table 52 (both families); session unit `tailscaled.service` | VM-proven |
  | `cilium` (`services.k3s.enable` or `services.rke2.enable`) | `^cilium`, `^lxc`; routes on those; table 200 | VM-proven (k3s/rke2 suites) |
  | `vm` (`virtualisation.libvirtd.enable` or `virtualisation.incus.enable`) | `^tap`, `^vnet`; guest ports on bridges are N23's | implemented |
  | `containers` (`virtualisation.docker.enable` or `virtualisation.podman.enable`) | N22 | planned, phase N7 |
  | netbird, cloudflare-warp | N29 | after the contract gate |
  | zerotier | — | not offered until VM-proven |

  The probe ran IfState with the registry stripped (dry run): it would have
  - deleted the foreign `ap` namespace;
  - deleted `tailscale0`;
  - set the Wi-Fi link down;
  - deleted all eight Tailscale rules.

  With the registry, the dry run and two applies changed nothing (§8).

  Eval errors (the base's assertions):
  - an IfState interface or netns matching an enabled owner's regex, or an
    IfState route/rule using an owner's table or rule priority;
  - a daemon enabled without an owner of the same name: `netbird`,
    `cloudflare-warp`, `zerotierone`, and scripted WireGuard
    (`networking.wireguard.interfaces`, `networking.wg-quick.interfaces`;
    D61 makes IfState the only renderer, so use `wireguard-mesh` or
    `routed-fabric`). Declaring `clanServices.networking.owners.<name>`
    by hand accepts the daemon; that is the owner's explicit choice and
    unsupported until a preset is VM-proven.
  *(implemented; VM-proven by `netif-registry` `NETIF_REGISTRY_OK`; the
  NetworkManager side lands in N2)*

- **N7 Each mode provides `network-online.target`; session daemons wait for
  it.**
  - **NetworkManager modes:** `NetworkManager-wait-online`.
  - **IfState modes:** `ifstate.service` is ordered `Before=` and
    `WantedBy=network-online.target`.
  - Registry owners that hold long-lived sessions (Tailscale's control
    connection, the clan deploy path) get `After=` and
    `Wants=network-online.target`.
  - **The probe found this gap:** tailscaled started before IfState
    finished reconfiguring the link it uses. Its control login then stalled
    for about 60 seconds after boot, in both modes. With the ordering, the
    tailnet answered at once after every reboot.
  - Roaming Wi-Fi is not part of "online": iwd reconnects on its own and
    tailscaled follows link changes.
  *(IfState modes: implemented, VM-proven by `netif-registry`
  `NETIF_REGISTRY_ORDER_OK`; NetworkManager modes: phase N2)*

- **N8 IfState reconcile facts netif relies on** (IfState 2.5.1 source
  `libifstate/`, confirmed by the probes):
  - Undeclared virtual interfaces are deleted, and undeclared physical
    interfaces are set down. Every NIC is therefore declared or
    registry-owned in IfState modes.
  - Undeclared named network namespaces are deleted unless
    `ignore.netns` matches.
  - Once any route or rule is declared, every undeclared policy rule is
    deleted unless an ignore matches it. Kernel-default rules are
    proto-ignored.
  - Routes are reconciled only in tables that carry declared routes.
  - Routes with protocols `dhcp` (16), `ra` (9) and the FRR protocols are
    ignored by default. Netif additionally ignores `static` (4) routes on
    its DHCP links.
  - Route ignores match `dev` with Python `re.match`
    (`libifstate/routing/__init__.py`, `route_ignored`): a regex anchored
    only at the start. Owner regexes rely on this. A selector naming one
    link must be the escaped name anchored at both ends (`^eth1$`),
    otherwise `eth1` also covers `eth10` and `eth1.20`, and the `.` in a
    VLAN name matches any character. *(netif's DHCP-link ignore is not
    anchored today; fixed in N3b.)*
  - Addresses with finite lifetimes (DHCP, SLAAC, delegated-prefix
    addresses) are kept; extra permanent addresses on declared links are
    removed.
  - A hook process survives the oneshot with `KillMode=process`.
  - A reapply of an unchanged configuration changes nothing.

- **N9 DNS goes through systemd-resolved in every mode.**
  - **Who turns it on.** The shared base sets `services.resolved.enable`
    in IfState modes; the NetworkManager renderer does the same in
    NetworkManager modes (N2). Today the base does not, so DHCP DNS goes
    through dhcpcd's resolvconf hook into `/etc/resolv.conf`.
  - **Who publishes.** Every writer sets DNS per link in resolved:
    - NetworkManager (gaming);
    - iwd (`NameResolvingService = systemd`);
    - Tailscale MagicDNS;
    - the netif DNS unit, for every netif link (below).
  - **The netif DNS unit.** One unit per machine, `netif-dns.service`. It
    watches link state and, for each netif link that has carrier, sets
    that link's DNS in resolved with `resolvectl dns` and
    `resolvectl domain`:
    - static servers come from `links.<n>.nameservers` (or the segment
      default);
    - DHCP servers come from dhcpcd's lease for that link, which dhcpcd
      hands over through a netif-owned exit hook.
    It re-applies on every carrier change and after every IfState run.
    dhcpcd's resolvconf hook is not used (N16). netif stops writing
    `networking.nameservers`.
  - **Why a unit.** The 2026-11-16 probe (§8) showed resolved forgets a
    link's DNS when the link goes down and up, and the resolvconf path
    left the DHCP link without DNS. A one-shot hook cannot keep it.
  - **No global DNS from netif.** A machine-wide fallback, if wanted, is
    plain `services.resolved` configuration outside netif.
  - **The cross-instance DNS conflict check goes away.** Per-link DNS
    cannot conflict between instances: each link belongs to exactly one
    instance (D53), and resolved routes queries per link.
  - **Verification gate.** In `netif-dhcp`, static and DHCP DNS must be
    on their links in resolved after boot, an IfState reapply, a link
    down/up, and a lease renewal with changed servers. This is proven
    first in phase N3b, before anything builds on it. If it fails, phase
    N3b stops for an owner decision instead of falling back to global
    DNS.
  *(probe-verified for iwd and NetworkManager; the first design failed
  its gate on 2026-11-16; netif unit planned, phase N3b)*

- **N10 Router contract.**
  - **IfState owns** the router's links: the four SFP+ ports and the
    RJ45 port, matched by permanent MAC, VLANs, bridges, LAN addresses,
    forwarding sysctls and static routes.
  - **A per-link dhcpcd hook owns** the WAN DHCPv4 lease and DHCPv6 prefix
    delegation (N16). Delegated LAN addresses and their routes (`proto dhcp`,
    finite lifetimes) are dynamic and survive IfState reapply.
  - **Other daemons, configured in `modules`:** nftables NAT, the DHCP
    server (kea), router advertisements (radvd or corerad) and DNS.
  - **Seam:** netif publishes each link's resolved Linux name and a `zone`
    (`wan`, `lan`, `mgmt`, …) as read-only NixOS options and in
    `clan.networkFacts`. Router modules reference those, never the
    inventory.
    - `links.<n>.zone` is a nullable string (lower-case,
      `[a-z][a-z0-9-]*`). netif gives it no meaning: it is a label for
      consumers.
    - The read-only option is
      `clanServices.networking.links.<instance>.<logical>`, holding
      `{interface, zone, kind}`. The same facts go into
      `clan.networkFacts.netif` and the `netif` export.
    - The seam ships in phase N3b with the other export changes (N16,
      N17), so the export changes once. Phase N5 builds the router
      module in `modules` on it.
  - **NAT is never netif's (N20).** The home router's NAT lives in the
    router module. A NAT gateway for other machines (U9) is a separate
    clanService built on the same seam, planned after the contract gate.
  - **No access point.** The house's Wi-Fi comes from access points on
    the LAN (§6).
  - **ECMP towards Kubernetes nodes** on the LAN is FRR's, through
    `routed-fabric`; whether those sessions run directly on the LAN or
    in tunnels is a SPEC.md decision. netif provides the links.
  - PPPoE, if an ISP needs it, is owned by pppd; IfState already ignores
    `ppp*`.
  - The router probe ran WAN DHCPv4 and DHCPv6-PD through the IfState hook,
    a /60 delegated with a /64 on the LAN, kea, SLAAC from radvd, and NAT
    to the ISP. An IfState reapply changed nothing (§8).
  *(probe-verified; `match.mac` implemented (N15); PD settings and the
  seam planned, phase N3b; the router module and `netif-router`, phase N5)*

- **N11 Tailscale and the fabric.** Tailscale's rule 5270 (`lookup 52`) sits
  before `main`, where FRR installs fabric routes. A subnet route accepted
  through Tailscale therefore wins over a fabric route for the same
  prefix.
  - Eval rejects a Tailscale CGNAT range (`100.64.0.0/10`) overlapping any
    netif, fabric or cluster pool.
  - It warns when a fabric member accepts Tailscale routes
    (`--accept-routes`).
  - Checked ranges: IfState interface addresses and route destinations
    (default routes excluded), `clan.networkFacts.allocationPools`, and the
    pod and Service CIDRs in `clan.networkFacts.clusters`; Tailscale's
    ranges are `100.64.0.0/10` and `fd7a:115c:a1e0::/48`. Both checks run
    only when the `tailscale` owner is enabled.
  *(implemented, eval tests in `services/netif/tests/eval-tests.nix`)*

- **N12 Hot-plugged wired links in IfState modes** (a USB-C dock on the
  Deck). A physical link declared in IfState must exist when IfState runs,
  so hot-plugged links are not IfState's. A `wired-hotplug` registry owner
  (a standalone dhcpcd limited to matching names, for example `^enx`) owns
  them in IfState modes. NetworkManager handles them natively in
  NetworkManager modes. *(planned, phase N2; must be VM-proven with QEMU
  device hot-plug before it is offered)*

- **N13 Deploy target.** Rule 11 stands: `targetHost` is an underlay
  address or name, never a clanServices fabric or tunnel address. A roaming
  machine (Deck) has no stable underlay address and deploys through a name:
  LAN DNS or a Tailscale MagicDNS name. Tailscale is not a clanServices
  tunnel, so rule 11's literal check does not apply to it.

- **N14 Two gates, no versions yet.** netif has no consumers, so
  settings and exports change freely with no shims (AGENTS.md rule 10)
  and no version bumps. Version rules start when the first real consumer
  exists; that is an owner decision then. Until then netif is "stable"
  when it passes two gates:
  - **Contract gate.** Every phase in §9 up to it is done, every
    probe-verified claim is VM-proven, and every invariant in §4 is
    asserted by a suite. This depends only on this repo.
  - **Field gate.** home runs netif on one machine of each use case that
    exists as hardware (§2). Each is recorded in §5 as it goes live. The
    owner does not use netif on real machines before the contract gate.
  The `schemaVersion` fields stay where they are and are not bumped.
  (The gates were called N6a and N6b before this round.)

- **N15 Physical NICs: identity, presence, passthrough.**
  - `links.<name>.match.mac` finds a physical NIC by permanent MAC
    (lower-case, colon-separated; the option type rejects other forms).
    It renders IfState `identify.perm_address`, and IfState renames the
    NIC to the logical link name, so that name is at most 15 characters.
    A physical link sets exactly one of `interface` and `match.mac`;
    `match.mac` on a VLAN, bond or bridge is an eval error.
  - **A missing NIC fails loudly.** IfState 2.5.1 only warns
    ("unable to create physical link") and exits 0 when a declared
    physical NIC is absent. The shared base adds an `ExecStartPost` to
    `ifstate.service` that fails the unit when any declared root-namespace
    physical link is missing after apply, and names it in the journal
    ("declared physical links missing after IfState apply: <names>"). The
    rest of the configuration still applies.
  - `links.<name>.extraSettings` is merged into the link's rendered
    IfState interface. IfState's schema checks it at build time; a key
    netif already renders for that link (a rendered path, or a prefix of
    one that is a leaf) is an eval error naming the path.
  *(implemented; VM-proven by `netif-match` `NETIF_MATCH_MAC_OK`,
  `NETIF_MATCH_MISSING_LOUD_OK`, `NETIF_MATCH_OK`; eval tests `underlay.*`)*

- **N16 dhcpcd's job, and prefix delegation as a runtime fact.**
  - **Own config file.** Each DHCP link's hook starts dhcpcd with `-f`
    and a per-link store file, `netif-dhcpcd-<instance>-<link>.conf`.
    dhcpcd never reads `/etc/dhcpcd.conf`.
  - **dhcpcd does exactly three things:**
    - the DHCPv4 lease: address, default route (unless N21 turns it
      off), and the DNS servers it hands to the netif DNS unit (N9);
    - DHCPv6 addresses (`ia_na`);
    - prefix delegation (`ia_pd`).
  - **One writer per kernel setting.** Kernel RA handling (`accept_ra`,
    `autoconf`, the RA default route) belongs to IfState's per-link
    sysctls. dhcpcd runs with `noipv6rs`: it neither solicits nor
    processes RAs and never touches RA sysctls. DHCPv6 starts because the
    link config asks for it, not because of RA flags.
  - **Hooks.** Every stock dhcpcd hook is off, the resolvconf hook
    included. One netif-owned exit hook passes the lease's DNS servers
    and search domains to the netif DNS unit (N9).
  - **No IPv4 link-local.** dhcpcd runs with `noipv4ll`. In the probe it
    took a `169.254` address and added a default route through it before
    the lease arrived.
  - **Route metric.** dhcpcd's default routes use N18's metric.
  - **Route protocols are observed, not assumed.** `netif-dhcp` records
    the protocols dhcpcd's routes carry (`ip -j route`; `dhcp` is 16,
    `ra` 9, `static` 4). netif's extra `{dev, proto = 4}` ignore stays
    only if dhcpcd still installs `static` routes, anchored per N8.
  - **Finding the daemon.** The hook finds its dhcpcd through dhcpcd's
    per-interface pidfile or an exact, escaped interface match, never a
    regex that matches other links.
  - **Prefix delegation settings:**
    `links.<n>.dhcp.prefixDelegation = { enable; hint; assign; }`
    - `hint`: requested length, 48–64, default 56;
    - `assign`: a list of `{ instance ? null; link; subnet; length ? 64; }`.
      `instance = null` means the same instance; WAN and LAN are usually
      separate instances, so naming another instance is allowed.
    - It renders `ia_pd` with one `<interface>/<subnet>/<length>` per
      entry, using resolved interface names.
  - **Eval errors** for prefix delegation:
    - it needs `dhcp.ipv6 = true` on the same link;
    - every `assign` target exists on the machine and is not the
      delegating link;
    - subnet ids are unique per delegating link and fit in
      `2^(length - hint)`;
    - a target link receives delegation from at most one link.
  - **Runtime fact.** Delegated prefixes exist only at runtime. Exports and
    `clan.networkFacts` carry
    `prefixDelegation = { enable; hint; assign; dynamic = true; }` with
    resolved interface names and never a prefix literal. Consumers (the
    router module, N5) read the live prefix on the target link. netif
    never invents an address.
  - **Verification gate.** dhcpcd with `noipv6rs` must still run DHCPv6
    and prefix delegation in `netif-dhcp`. The 2026-11-16 probe passed
    this: an address from `ia_na` and a delegated `/60` with a `/64` on
    the LAN, with IfState's `accept_ra = 2` untouched (§8). The suite
    still has to prove it.
  *(probe-verified; planned, phase N3b)*

- **N17 Path MTU.**
  - `links.<n>.pathMtu` is a nullable integer, at least 1280 and at most
    the link's effective MTU when both are set. It is the smallest MTU on
    the path to fabric peers, which may be below the link MTU (GCP 1460,
    PPPoE 1492).
  - The `netif` export carries `pathMtu` per link and an instance
    `pathMtu`, the smallest of its links.
  - **Consumers prefer it.** `routed-fabric` and `wireguard-mesh` pick an
    underlay MTU in this order:
    1. `pathMtu`;
    2. the link `mtu`;
    3. their own settings.
  - When the user sets no `mtu`, wireguard-mesh derives it as that
    underlay MTU minus 96, with a floor of 1280. That closes SPEC.md
    invariant 21.
  - **Warning.** netif warns when a fabric member's DHCP link owns the main
    default route and declares neither `mtu` nor `pathMtu`. Transports
    would assume 1500 there, which is wrong on many clouds.
  *(planned, phase N3b)*

- **N18 Default routes from several owners.** D53 still allows at most one
  netif link per family to own the main-table default. Other owners
  (Wi-Fi, a hot-plugged dock, Tailscale) may add defaults too, so every
  default route has a fixed metric. Lower wins:

  | Owner | IPv4 and IPv6 metric | How it is set |
  |---|---|---|
  | netif link (static gateway, DHCP lease, RA) | 100 | IfState route `preference`; dhcpcd `metric`; `ra_defrtr_metric` written by the link hook |
  | `wired-hotplug` owner (N12) | 200 | its dhcpcd `metric` |
  | iwd (Wi-Fi) | 300 and up | iwd `RoutePriorityOffset = 300`, pinned by the `iwd` preset |
  | NetworkManager modes | wired 100, Wi-Fi 600 | the renderer sets wired profiles' route metric to 100 explicitly; NetworkManager's Wi-Fi default is already higher |

  - Effect: with a cable plugged in, wired wins and Wi-Fi stays up as a
    fallback; unplugging falls back with no reconfiguration.
  - Tailscale installs no main-table default. An exit node routes through
    table 52 at rule 5270, ahead of every metric; using one is the
    owner's explicit choice and outside this order.
  - **Who writes `ra_defrtr_metric`.** IfState 2.5.1's schema rejects
    this sysctl (`iface-sysctl-ipv6` allows no extra keys), so IfState
    cannot set it. netif's per-link hook writes
    `/proc/sys/net/ipv6/conf/<link>/ra_defrtr_metric` when it starts,
    for every link that accepts RAs, and the no-op helper (§7) reads it
    back. netif stays the one writer. The missing key is worth reporting
    to IfState upstream; netif does not depend on a fix.
  - **Verification gate.** `netif-dhcp` asserts metric 100 for each
    family's default (DHCPv4, RA). `netif-wifi` (N2) asserts wired
    over Wi-Fi in both families. If iwd does not apply
    `RoutePriorityOffset` to IPv6, the phase stops for an owner
    decision. The 2026-11-16 probe showed both defaults at metric 100
    (`proto dhcp` and `proto ra`), with the sysctl written by the hook.
  *(planned: netif metrics in N3b, Wi-Fi and dock in N2)*

- **N19 Links are untrusted unless declared trusted.**
  - `links.<n>.firewall.trust` and the segment `firewall.trust` default
    to untrusted. Null on a link inherits the segment; null on the
    segment means untrusted.
  - Trust is explicit: set it on a segment (a private LAN) or a link.
  - Services open what they need on their own interfaces and ports:
    - `routed-fabric`: BGP and BFD on fabric WireGuard links (D63);
    - `wireguard-mesh`: its UDP port;
    - `k3s` and `rke2`: their cluster ports.
    No service may rely on netif trusting a link. N3b runs every suite
    to find any that do and fixes them in the owning service.
  - A breaking change with no shims (AGENTS.md rule 10).
  - **Stop condition.** If a cluster service needs a new firewall
    ownership model rather than a missing port opening, N3b stops for an
    owner decision.
  *(planned, phase N3b)*

- **N20 Responsibility boundary.** §1.1 is normative. netif owns links
  and how they are addressed, routed, resolved and trusted; the ownership
  registry; the manager per mode; the lockout guard; and the facts it
  publishes. It never renders NAT, servers (DHCP, RA, DNS), tunnels,
  routing protocols, cluster networking, VPN clients, container or guest
  ports, or host identity. A change that moves one of those into netif
  needs an owner decision first. *(contract; enforced by review and by
  N6's eval errors)*

- **N21 One default route per family, chosen explicitly.**
  - `links.<n>.defaultRoute = { ipv4; ipv6; }`, each a boolean, default
    true. It says whether this link may install a main-table default
    route for that family, from any source: a static gateway, a DHCPv4
    lease, an RA.
  - With `false`:
    - a static `gateway` is still usable by the link's `routes` and
      policy table, but no main-table default is rendered;
    - dhcpcd keeps the lease, its address and its classless routes, and
      drops the router option (`nogateway`);
    - RAs are still accepted for prefixes, but not for a default router
      (`accept_ra_defrtr = 0`, which IfState's schema allows).
  - **The rule.** Per machine and family, at most one netif link has
    `defaultRoute` true **and** a source for a default. Sources are: a
    static gateway outside a policy table, DHCPv4, DHCPv6 with RA, and
    plain RA (`ra = true` on a link with no static IPv6 gateway). Today
    RA defaults are not counted and two DHCPv4 links always fail; both
    are fixed here.
  - `ra` stays true by default, so a second RA-accepting link must set
    `defaultRoute.ipv6 = false` (or `ra = false`). The eval error names
    both links and says so.
  - Example (Hetzner Cloud, U6): the public NIC keeps the default; the
    private NIC sets `defaultRoute.ipv4 = false` and keeps its lease's
    routes to the private network.
  *(planned, phase N3b)*

- **N22 Containers: Docker and Podman.**
  - One preset, `containers`, switched on by
    `virtualisation.docker.enable` or `virtualisation.podman.enable`.
  - It owns: `^docker`, `^br-`, `^podman`, `^veth`, and the routes on
    them. IfState's built-in ignores already cover `docker0`,
    `br-<12 hex>` and `veth*`; **they do not cover `podman0`**. In the
    2026-11-16 probe, Docker survived two IfState applies with
    connectivity and a published port intact; Podman's bridge was
    deleted and its container lost the network (§8). The preset names
    all of them so netif does not depend on IfState's built-in list, and
    so NetworkManager modes mark them unmanaged.
  - Rootless Podman creates no host links and needs nothing.
  - **Address pools.** Eval rejects Docker's and Podman's default pools
    (`172.17.0.0/16`, `10.88.0.0/16`) overlapping any netif, fabric or
    cluster range, with N11's check. Pools changed in the daemon's own
    configuration are checked when they are set through NixOS options.
  - **Forwarding.** Docker turns IPv4 forwarding on at runtime and leaves
    IPv6 forwarding off (probe). netif's RA handling depends on IPv6
    forwarding (`accept_ra` 1 or 2), so the preset sets
    `clan.networkFacts.forwarding` only when the container daemon is
    configured for IPv6.
  - **Firewall.** Container bridges are not netif links and get no
    trust from netif (N19). Docker and Podman manage their own rules.
  *(probe-verified for Docker under plain IfState; planned, phase N7;
  suite `netif-containers`)*

- **N23 VM hosts: bridges for guests (U5).**
  - **Bridge MAC.** IfState 2.5.1 gives every bridge a generated MAC
    (`build_iface_mac`, from the interface name), not its member's. The
    probe confirmed it: bridge `92:83:…`, member NIC `52:54:…` (§8). A
    provider that filters by MAC (Hetzner Robot) would drop the host's
    own traffic. So:
    - a bridge with exactly one physical member that is declared with
      `match.mac` takes that MAC;
    - `links.<n>.mac` sets a MAC explicitly on a bridge, bond or VLAN
      and wins over the rule above (same form as `match.mac`);
    - any other bridge keeps IfState's generated MAC, which is stable
      across reboots and did not change when a lower-MAC port joined.
  - **Members.** A bridge's members may be physical, VLAN or bond links
    of the same instance. A bridge as a member of a bridge is an eval
    error. (Today only physical members are allowed; a Hetzner vSwitch
    needs a bridge over a VLAN.)
  - **Guest ports.** `links.<n>.bridge.guestPorts = true` marks a bridge
    whose undeclared ports belong to a hypervisor. In the probe, IfState
    deleted an undeclared tap on a bridge at the next apply. On a
    guest-ports bridge netif never deletes, downs or detaches an
    undeclared port. How netif renders that is found in phase N7; if
    IfState cannot express it per bridge, the phase stops for an owner
    decision. The `vm` preset's names (`^tap`, `^vnet`) and
    `^veth` (N22) stay as the fallback.
  - **Guest addresses are not netif's.** A guest's public address and
    its provider MAC are set in the guest and the hypervisor. netif
    renders the host side only. A routed extra subnet (no MAC needed) is
    a static route on the bridge.
  - **Order of proof:** KubeVirt with Multus first, Incus second.
  - The host's own address moves onto the bridge; `targetHost` stays an
    underlay address (N13), which the bridge address is.
  *(bridge MAC and tap deletion probe-verified; planned, phase N7;
  suite `netif-vmhost`)*

- **N24 The `modes` service.**
  - A clanService `modes` in this repo, at most one instance per clan.
    Per machine it holds
    `modes.<name>.manager = "ifstate" | "networkmanager"`.
  - The name `default` is the parent configuration and may use either
    manager. A machine with no entry has one mode, `default`, with
    IfState.
  - The service creates `specialisation.<name>` for every other mode and
    sets, in each configuration, the read-only option
    `clanServices.networking.mode = { name; manager; }`.
  - Everything else hooks onto that option:
    - netif picks its renderer from `manager` (N2);
    - `routed-fabric`, `wireguard-mesh`, `k3s` and `rke2` gate their
      rendering on `name` (N4);
    - home's machine configuration adds KDE, Steam or nothing to a mode
      with `lib.mkIf (config.clanServices.networking.mode.name == …)`.
    No other module defines a specialisation for networking purposes.
  - The mode list is also in `clan.networkFacts`, so N4's eval rules
    (spines, borders, voters in every mode) read one source.
  - It is a separate service because modes are per machine, while netif
    settings are per instance and a machine may be in several.
  *(planned, phase N4; the probe's mode mechanics are §8)*

- **N25 Lockout guard.** IfState has no rollback, and a bad change on a
  headless machine cuts the only way in.
  - **When.** After every IfState apply on a machine with the guard on.
    Default: on when the machine has no mode with a display manager or
    gamescope, off otherwise; `guard.enable` overrides.
  - **Test.** Every default gateway netif declares must resolve at layer
    2 within 30 seconds: an ARP or neighbour-discovery answer, not a
    ping, because gateways may drop ICMP. `guard.targets` adds addresses
    that must answer the same way. A DHCP or RA link is checked against
    the gateway it learned.
  - **On failure.** netif re-applies the previous generation's IfState
    configuration, fails `ifstate.service`, and logs which target did
    not answer. It rolls back the network configuration only, not the
    NixOS generation. If there is no previous configuration (first boot,
    install), it only fails loudly.
  - **Limits.** It protects against a change that breaks the path to the
    gateway. It does not detect a broken firewall rule or a wrong
    address that the gateway still answers.
  - How the previous configuration is kept and re-applied is settled in
    phase N8 with a probe first.
  *(planned, phase N8; suite `netif-guard`)*

- **N26 Cloud NICs.**
  - `links.<n>.match.path` finds a physical NIC by its parent device
    name (a PCI or virtio address such as `0000:00:03.0`), rendered as
    IfState `identify.parent_dev_name`. A cloud NIC's MAC is unknown
    before the VM exists; its slot is stable.
  - A physical link sets exactly one of `interface`, `match.mac` and
    `match.path`. With either matcher, IfState renames the NIC to the
    logical link name (at most 15 characters).
  - Eval rejects cloud-init's network configuration next to netif
    (`services.cloud-init.network.enable`): it would be a second writer.
  - Provider facts netif relies on are recorded per provider in the
    human docs as they are proven: gateway outside the subnet
    (`gateway.onLink`), MTU below 1500 (`pathMtu`, N17), a second NIC
    without a default (N21).
  *(planned, phase N3b; `match.path` VM-proven in `netif-match`)*

- **N27 A roaming Kubernetes node uses its fabric loopback (U2).**
  kamrui-h1's `kubernetes` mode runs a k3s server with ClusterMesh while
  its underlay is ad hoc Wi-Fi or a cable. Its node address is the
  `routed-fabric` loopback, never an underlay address, and ClusterMesh
  traffic rides the fabric. netif's part is small: the underlay may have
  no static address at all, and that is valid. The design (node address,
  Cilium devices, what "native routing" means over tunnels) belongs to
  SPEC.md and is not decided here. §6 no longer excludes this case.
  *(requirement recorded; design planned in SPEC.md)*

- **N28 A VM-test fixture for other repos (U11).** After the contract
  gate, this repo exports one documented module that declares the NixOS
  test driver's NICs for netif, so home and modules can boot a machine
  with netif in their own VM tests. Until then, other repos test without
  netif. *(planned, after the contract gate)*

- **N29 More VPN presets.** After the contract gate:
  - **NetBird:** a preset, VM-proven against a self-hosted management
    server, offline.
  - **Cloudflare WARP:** it cannot run offline, so no VM suite can prove
    it. Its preset is marked **field-checked**: verified on a real
    machine, recorded in §5 with the date and versions. This is the one
    exception to "not offered until VM-proven" (N6).
  *(planned, after the contract gate)*

## 4. Invariants

1. Exactly one manager per system configuration (N2).
2. Every interface, namespace, table and rule on a machine has exactly one
   owner: netif's renderer or one registry owner (N6, N8).
3. Every physical NIC is declared or registry-owned in IfState modes (N8).
4. IfState never configures a Wi-Fi link; iwd owns Wi-Fi in every mode (N5).
5. A reapply of an unchanged configuration changes nothing, including on
   routers with dhcpcd, kea, radvd and NAT running (N8, N10). "Changes
   nothing" has the test definition in §7.
6. Session daemons start after the mode's `network-online.target` (N7).
7. Modes switch only by reboot; deploys keep the booted mode (N3).
8. Spines, borders and multi-node etcd voters exist in every mode of their
   machine (N4).
9. No secret appears in the Nix store; WireGuard keys stay runtime
   `!include`s (D61, unchanged).
10. `targetHost` stays on the underlay or a name (N13).
11. Each kernel setting has one writer: IfState owns RA handling, dhcpcd
    owns leases and delegations, resolved holds DNS (N9, N16).
12. Default routes follow N18's metric order; wired beats Wi-Fi in every
    mode (N18).
13. No link is trusted by the firewall unless declared trusted; services
    open their own ports (N19).
14. netif renders no NAT, server, tunnel, routing protocol or guest port
    (N20).
15. Per machine and family, at most one netif link may install a
    main-table default route, whatever its source (N21).
16. Container and guest ports survive an IfState reapply (N22, N23).
17. A bridge that carries a provider-filtered uplink sends from that
    uplink's MAC (N23).
18. One source names a machine's modes and their managers (N24).
19. On a guarded machine, an apply that loses the gateways is rolled
    back (N25).

## 5. What exists today (2026-11-16)

- **Implemented and VM-proven** (SPEC.md D53/D61/D63; suites `netif`
  `NETIF_IFSTATE_LIVE_OK`, `netif-dhcp` `NETIF_DHCP_RA_IFSTATE_OK`):
  - IfState-only rendering through the shared base;
  - multi-link, multi-instance links: physical by name, VLAN, bond and
    bridge;
  - static, DHCP and RA addressing, with dhcpcd hooks;
  - gateways, routes and underlay policy routing;
  - MTU, global DNS servers and firewall trust;
  - cross-instance checks;
  - reserved WireGuard ports;
  - live reconfiguration.
- **Implemented and VM-proven in N1** (suite `netif-registry`
  `NETIF_REGISTRY_OK`): the ownership registry and its presets (N6), the
  ownership, Wi-Fi and unowned-daemon eval errors, IfState before
  `network-online.target` with session units after it (N7), and the N11
  range check and warning.
- **Implemented and VM-proven in N3a** (suite `netif-match`
  `NETIF_MATCH_OK`): `match.mac`, the loud missing-NIC check and the
  checked `extraSettings` passthrough (N15).
- **Drift against this contract** (fixed by the phases in §9):
  - the base force-disables NetworkManager on every machine (conflicts N2);
  - there are no modes (N3/N4), and the registry does not render into
    NetworkManager yet (N6, phase N2);
  - DNS uses global `networking.nameservers`, resolved is not enabled,
    and the cross-instance DNS conflict check still exists (N9; N3b);
  - there are no PD settings, `pathMtu` or zone seam (N10, N16, N17;
    N3b);
  - netif's DHCP-link route ignore `{dev = <interface>; proto = 4}` is
    an unanchored regex, and the hook's `pgrep` match is loose too
    (`services/netif/default.nix`; N8, N16; N3b);
  - the DHCP hook starts dhcpcd with no config file of its own, so
    dhcpcd's own RA handling and hooks are unpinned (N16; N3b);
  - links default to firewall-trusted (N19; N3b);
  - default routes carry no metric (N18; N3b);
  - `netif` and `netif-dhcp` take `ifstatecli check`'s exit status as
    "no change", which it is not (invariant 5, §7; N3b);
  - live reconfiguration is proven by applying hand-edited YAML in the
    `netif` suite, not by switching NixOS generations (§7; N3b);
  - every DHCPv4 link counts as a default-route owner, so two DHCP
    links fail eval, and RA defaults are not counted at all
    (`services/netif/default.nix` `v4Default`, `v6Default`; N21; N3b);
  - bridges accept physical members only and have no MAC setting (N23;
    phase N7);
  - there is no `containers` preset; Podman's bridge is deleted on
    reapply (N22; phase N7);
  - a NIC can be matched by name or MAC only (N26; N3b);
  - nothing rolls back a change that cuts the gateway (N25; phase N8).
- **Field gate (N14):** no use case is live. netif has no consumers.

## 6. Out of scope

- Live mode switching.
- Running NetworkManager and IfState at once.
- Forking the nixpkgs IfState module.
- Untested VPN presets (Cloudflare WARP is the one field-checked
  exception, N29).
- Wi-Fi access-point mode on clan machines. The house's Wi-Fi comes from
  separate access points (U3).
- NAT, port forwarding, DHCP and RA servers (N20).
- Hand-written WireGuard links: WireGuard is `routed-fabric` and
  `wireguard-mesh` only.
- IfState or any netif networking in the initrd. No machine unlocks its
  disk over the network.
- Mobile broadband.
- Guest configuration inside VMs (N23).
- The Cilium datapath of a roaming Kubernetes node. That is a SPEC.md
  concern (N27).

## 7. Testing contract

- Wi-Fi runs in NixOS VM tests through `mac80211_hwsim`. Access points
  (hostapd plus dnsmasq) live in a foreign network namespace that the
  registry owns, so only the client radio is visible to the machine under
  test. qemu-vm disables wireless by default (`mkVMOverride`), so tests
  re-enable it with `lib.mkOverride 0`.
- Tailscale runs against an offline Headscale with its embedded DERP and an
  empty DERP URL list, the same way the nixpkgs `headscale` test does.
- Modes are tested by booting systemd-boot entries on a persistent disk
  (`virtualisation.useBootLoader`, `useEFIBoot`). The test selects the next
  entry by its title in `loader.conf` and power-cycles with `shutdown()` and
  `start()`. Each mode asserts which configuration booted.
- **"Changes nothing" (invariant 5)** means both:
  1. a kernel-state snapshot is identical before and after the reapply:
     `ip -j` links, addresses, routes in every table, rules, and
     `ip netns list`, with counters, lifetimes and timestamps stripped;
  2. `ifstatecli check` reports no change for any object. Its exit status
     is not a signal: it exits 0 even when it proposes changes.
  One shared helper in `tests/` (for example
  `assert_ifstate_noop(machine)`) does both, and every suite that
  asserts a reapply uses it. N3b writes it and pins the `check` output
  format it parses against IfState 2.5.1.
- **Live reconfiguration** is proven by switching NixOS generations
  (`switch-to-configuration test` into a specialisation that changes
  netif settings, then back), not by applying hand-edited YAML. The
  `netif` suite moves to that in N3b. This is a test device only; it
  does not make live mode switching (N3) supported.
- Planned suites, each with a final marker:

  | Suite | Proves | Phase |
  |---|---|---|
  | `netif-registry` | Tailscale and an iwd Wi-Fi link survive two IfState applies; foreign netns kept; ordering | N1 |
  | `netif-modes` | gaming (NetworkManager + iwd + Tailscale) → developer (IfState + iwd + Tailscale) → gaming by reboot; known networks shared both ways | N2, N4 |
  | `netif-wifi` | ad hoc join, roaming between two APs, DNS from DHCP | N2 |
  | `netif-hotplug` | dock ethernet hot-plug in an IfState mode | N2 |
  | `netif-router` | WAN DHCPv4 + DHCPv6-PD hook, kea, radvd, NAT, reapply no-op, prefix change, reboot | N5 |
  | `netif-match` | NIC found by permanent MAC under a different kernel name; missing NIC fails loudly | N3a (green) |
  | `netif-dhcp` (extended) | dhcpcd per-link config; DHCPv6 and a delegated prefix assigned to another instance's link; observed route protocols; per-link DNS in resolved across reapply, link down/up and a lease renewal (N9); no IPv4 link-local; metric 100 defaults; an RA default on a forwarding link surviving two RA lifetimes; the no-op helper | N3b |
  | `netif` (extended) | live reconfiguration by generation switch; untrusted default with an explicitly trusted link; two DHCP links with one default (N21); the no-op helper | N3b |
  | `netif-match` (extended) | NIC found by device path (N26) | N3b |
  | `netif-containers` | Docker and rootful Podman keep links, connectivity and a published port across two applies, in an IfState mode; pool-overlap eval error | N7 |
  | `netif-vmhost` | bridge sends from the uplink's MAC; a bridge over a VLAN; guest ports survive two applies | N7 |
  | `netif-guard` | a change that loses the gateway is rolled back and the unit fails; a good change is kept | N8 |

  Existing suites stay green throughout.

## 8. Probe evidence (2026-11-15, euc-hel-0, IfState 2.5.1, NetworkManager 1.58.1, iwd 3.12, tailscale 1.104.2)

Throwaway tests, not committed; kept for the next agent under
`.baton-pass/` (gitignored).

- **Mode probe** (`NETIF_MODEL_PROBE_OK`; passed twice, the second a fresh
  `--rebuild`, after probe-script fixes; the last fix added N7's ordering). Nodes: headscale, a Tailscale peer, and
  `deck` with three hwsim radios (two APs, `cafe` and `friend`, in netns
  `ap`) and systemd-boot. Steps, all passing:
  1. **gaming (parent).** NetworkManager with the iwd backend; no
     `ifstate.service` unit. `nmcli` joined `cafe`;
     `/var/lib/iwd/cafe.psk` was written. DNS from DHCP resolved through
     resolved. `tailscale up` against Headscale; tailnet ping OK.
  2. **Reboot into `developer`.** NetworkManager inactive; IfState applied
     `eth1`, `dummy0`, a main-table route, a table-100 route and rule 1000.
     iwd rejoined `cafe` on its own with DHCP and DNS. The tailnet answered
     at once (with N7 ordering).
  3. **IfState reapply.** Links, rules, table 52 and the Wi-Fi default
     route were identical; `ifstatecli check` clean. With the registry
     removed, the dry run listed deletion of netns `ap`, `tailscale0` and
     eight Tailscale rules, and `wlan` set down.
  4. **Addresses.** A finite-lifetime address on a declared link survived
     the reapply; an extra permanent address was removed.
  5. **`iwctl` joined `friend`;** `/var/lib/iwd/friend.psk` written.
  6. **Reboot into gaming** (the `cafe` AP switched off).
     - The machine joined `friend`, and NetworkManager listed it as a
       connection.
     - No IfState objects remained.
     - The tailnet answered.
- **Router probe** (`NETIF_ROUTER_PROBE_OK`; passed twice, the second a
  fresh `--rebuild`). Nodes: an ISP (kea DHCPv4,
  kea DHCPv6 with a `/56` PD pool, radvd), the router (IfState: WAN with a
  dhcpcd `ia_pd` hook, static LAN; nftables NAT; kea DHCPv4; radvd), and a
  LAN client. Results:
  - the router got its WAN lease and a delegated `/60`, and assigned a
    dynamic `/64` to the LAN;
  - dhcpcd routes carried `proto dhcp` or `proto ra`;
  - the client got DHCPv4 and SLAAC and reached the ISP through NAT;
  - an IfState reapply changed nothing, and dhcpcd kept running.
- **Gaps the probes found, now decisions:** N7 (ordering), N6 (netns and
  Wi-Fi in the registry, not only tun and rules), N8 (undeclared NICs are
  set down).

### 8.1 Probes of 2026-11-16 (euc-hel-0, IfState 2.5.1, dhcpcd 10.3.2, systemd 262)

Throwaway tests, not committed; `.baton-pass/netif-probes/gates.nix` and
`containers.nix`. They record facts (`FACT` lines) and do not assert.

- **Gates probe** (`NETIF_GATES_PROBE_DONE`). The router probe's nodes,
  with dhcpcd on `noipv6rs`, `metric 100`, IfState `accept_ra = 2`, and
  resolved on.

  | Question | Result |
  |---|---|
  | dhcpcd with `noipv6rs` still runs DHCPv6 `ia_na` and `ia_pd` | yes: address `2001:db8::100`, delegated `/60`, `/64` on the LAN |
  | IfState accepts `sysctl.ipv6.ra_defrtr_metric` | **no**: schema error at build time |
  | The kernel honours `ra_defrtr_metric` written by the hook | yes: `default … proto ra metric 100` |
  | dhcpcd routes | `proto dhcp`, metric 100; no `static` routes seen |
  | Reapply with dhcpcd running changes nothing | yes |
  | DHCP DNS reaches resolved through the resolvconf hook | **no**: the link had no DNS in resolved; cause not found |
  | `resolvectl dns` on a link survives an IfState reapply | yes |
  | `resolvectl dns` on a link survives link down/up | **no** |
  | Other | dhcpcd took an IPv4 link-local address and a default route through it before the lease |

- **Containers probe** (`NETIF_CONTAINERS_PROBE_DONE`). One host with
  plain IfState (built-in ignores only, no registry), nftables firewall,
  Docker, rootful Podman, and a bridge with one physical member.

  | Question | Result |
  |---|---|
  | Bridge MAC equals its member NIC's MAC | **no**: generated (`92:83:58:81:00:61` vs `52:54:00:12:02:01`) |
  | Bridge MAC changes when a lower-MAC tap joins | no |
  | An undeclared tap on the bridge survives a reapply | **no**: deleted |
  | Docker: links, routes and rules identical after two applies | yes |
  | Docker: container connectivity and a published port after | yes |
  | Podman (rootful): links identical after two applies | **no**: `podman0` deleted |
  | Podman: container connectivity after | **no** |
  | Forwarding after dockerd starts | IPv4 on, IPv6 off |

- **Source facts** (IfState 2.5.1 `libifstate/`):
  - built-in `ignore.ifname`: `^br-[\da-f]{12}`, `^docker\d+`,
    `^ppp\d+$`, `^veth`, `^virbr\d+`, `^vrrp\d*\.\d+$`
    (`parser/base.py`);
  - virtual links get a MAC derived from their name
    (`link/base.py` `get_link_address_default`);
  - `identify` accepts `perm_address`, `parent_dev_name`,
    `parent_dev_bus_name`, `phys_port_id` (`util.py`
    `IDENTIFY_LOOKUPS`).

- **What they changed:** N9 (DNS unit), N16 (`noipv4ll`, no resolvconf
  hook), N18 (who writes `ra_defrtr_metric`), N22, N23.

## 9. Delivery plan

Each phase amends this file first, then code, then suites. Order: N3b,
N7, N2, N4, N8, N5, then the contract gate; the field gate follows the
hardware; N28 and N29 come after. A verification gate that fails, or a
fix that needs a new ownership model, stops the phase for an owner
decision. Phase numbers are labels, not the order.

| Phase | Work | Done when |
|---|---|---|
| N0 | This contract (docs only) | merged |
| N1 | Ownership registry + presets (iwd, tailscale, cilium, vm), N7 ordering, N11 checks, foreign-daemon-without-preset eval error | `netif-registry` green — **done** |
| N3a | `match.mac`, missing NIC fails loudly, checked `extraSettings` passthrough (N15) | `netif-match` green; existing suites green — **done** |
| N3b | First: prove the netif DNS unit (N9). Then: dhcpcd per-link config and PD (N16), `pathMtu` and its consumers (N17), default-route metrics (N18), untrusted default (N19), zone seam (N10), `defaultRoute` and RA in the one-default rule (N21), `match.path` and the cloud-init check (N26); fixes: anchored ignores, the no-op helper, live reconfiguration by generation switch. Brief: `documentation/docs/plans/phase-4-netif-underlay/prompt.md` | `netif-dhcp`, `netif` and `netif-match` extended (§7); every existing suite green |
| N7 | `containers` preset (N22); VM hosts: bridge MAC, VLAN and bond members, guest ports (N23) | `netif-containers`, `netif-vmhost` green |
| N2 | NetworkManager renderer, iwd in both modes, `wired-hotplug` owner, Deck hardware check of Steam over iwd | `netif-modes`, `netif-wifi`, `netif-hotplug` green |
| N4 | The `modes` service (N24), `modes` on every networking/cluster service, mode-scoping eval rules, deploy guidance | eval tests; `netif-modes` extended with a fabric leaf |
| N8 | Lockout guard (N25), probe first | `netif-guard` green |
| N5 | Router module in `modules` on the N3b seam | `netif-router` green |
| Contract gate | netif is stable (N14) | every phase above done; every probe-verified claim VM-proven; every §4 invariant asserted by a suite |
| Field gate | home runs netif on each use case that exists (N14) | each use case live, recorded in §5 |
| Later | VM-test fixture (N28); NetBird and WARP presets (N29); a NAT gateway service (N10); the roaming-node design in SPEC.md (N27) | each its own decision round |

## 10. Glossary

Terms as this file uses them. One term per thing.

- **Apply, reapply** — one run of `ifstatecli apply`
  (`ifstate.service`). It converges the whole kernel network state to
  the configuration. A reapply is a run with an unchanged configuration.
- **Contract gate, field gate** — the two conditions for "stable" (N14).
- **Decision** — a numbered rule in §3, written `N1`…`N29`.
- **Default route owner** — the one netif link per family that may
  install a main-table default route (N21).
- **Deploy target** — `clan.core.networking.targetHost`: where clan
  connects to deploy. Always an underlay address or a name (N13).
- **Endpoint** — an address other machines dial to reach this one, for
  example for a fabric tunnel.
- **Fabric** — the routed WireGuard and FRR network between machines,
  owned by `routed-fabric`. It runs on top of the underlay.
- **Field-checked** — verified on a real machine because no VM test can
  (N29).
- **Gate (verification gate)** — a named check a phase must pass before
  it continues; failing it stops the phase for an owner decision.
- **Guest port** — a bridge port a hypervisor created for a VM (N23).
- **IfState mode, NetworkManager mode** — a mode whose manager is
  IfState, or NetworkManager.
- **Instance** — one netif entry in `inventory.instances`: one network
  segment and the machines attached to it.
- **Interface** — the Linux name of a link (`eth1`, `wan`, `br0`), at
  most 15 characters.
- **Link** — one network attachment of one machine in one instance:
  a physical NIC, a VLAN, a bond or a bridge. Keyed by its **logical
  name**, which is the inventory key.
- **Lockout guard** — N25.
- **Manager** — the software that configures links in a mode: IfState or
  NetworkManager. Exactly one per mode (N2).
- **Mode** — a NixOS specialisation of a machine, or its parent
  configuration (named `default`). Switched by reboot (N3, N24).
- **Owner** — an entry in the ownership registry: a daemon and the
  kernel objects that are its, not netif's (N6).
- **Phase** — a delivery step in §9, always written "phase N2".
- **Preset** — an owner that switches on by itself when its daemon is
  enabled (N6).
- **Probe, probe-verified** — a throwaway VM test and what it showed
  (§0, §8). Not yet a suite.
- **Renderer** — the part of netif that turns settings into one
  manager's configuration.
- **Runtime fact** — a value that exists only on the running machine,
  such as a delegated prefix (N16). Never written into configuration.
- **Segment** — the network an instance describes; its settings are the
  defaults for the instance's links.
- **Session unit** — a daemon that holds a long-lived connection and so
  starts after `network-online.target` (N7).
- **Suite, VM-proven** — a registered VM test and what it proves (§0).
- **Trust** — whether the firewall accepts everything arriving on a
  link (N19).
- **Underlay** — the network a machine is plugged into: its NICs, Wi-Fi
  and the addresses on them. netif's territory.
- **Use case** — a machine class in §2, `U1`–`U11`.
- **Zone** — a label on a link (`wan`, `lan`) for consumers; netif gives
  it no meaning (N10).
