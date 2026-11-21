# netif — host networking contract (agent edition)

The normative contract and status authority for how every machine gets its
network configuration: `services/netif`, the shared IfState base
(`lib/ifstate.nix`), the ownership registry and the mode model. `SPEC.md`
keeps the Kubernetes bootstrap and data-plane contracts; `routed-fabric`,
`wireguard-mesh`, `k3s` and `rke2` consume this contract. The human
rendering is `documentation/docs/netif/`. **Edit this file and those pages
together.** Decisions are numbered `N1`–`N45` so they never collide with
SPEC.md's `D1`–`D68` or `specs/gateway.md`'s `G1`–`G23`. Phases are numbered `P0`–`P8` (they were `N0`–`N8`
until the proof round), so a phase and a decision never share a label
(§10).

Round G0 (2026-11-20): **the router moves into this repo; docs only.**
The owner decided that the router and a NAT gateway are clanServices
here (`services/router`, `services/nat-gateway`), governed by
`specs/gateway.md`. For netif:
- **N10** the router's daemons are configured by `services/router`, not
  by `modules`; corerad replaces "radvd or corerad"; CoreDNS is the DNS
  server.
- **N21** will allow one default per WAN link for multi-WAN (planned).
- **N43** a MAC override on a physical link, **N44** a priority-tagged
  WAN, **N45** IPv6-only links as first-class. All planned.
- **N16** will get `prefixDelegation.reserve`: a subnet id that no link
  receives, for a router's service prefix (`specs/gateway.md` G20,
  planned).
- **U13–U18** added; U3 amended (§2).
Nothing is implemented in this round.

Round close-out (2026-11-18): the use cases are restated by the owner
(§2, U12 added) and mapped to the suites that prove them
(`documentation/docs/netif/use-cases.md`). A suite that hangs is stopped
after 45 minutes instead of 2 hours (`vmTests.globalTimeout`).

Round P2-hotplug (2026-11-18): **hot-plugged wired links in an
IfState mode.** Implemented, and proven by the new suite
`netif-hotplug` (`NETIF_HOTPLUG_OK`). With it phase P2 is done in this
repo; only the Deck hardware check is left.
- **N12 as built** (`services/netif/host.nix`):
  `clanServices.netif.hotplug.interfaces` lists name prefixes
  (`^enx`, a dock's USB path prefix). In an IfState mode:
  - the registry owner `wired-hotplug` claims them, so IfState never
    touches the link, its addresses or its routes;
  - a udev rule per prefix starts `netif-hotplug@<name>.service` when
    such a link appears. The unit is bound to the device, so
    unplugging stops it;
  - the unit sets the link up and runs dhcpcd 10.5 (`dhcpcd_latest`)
    with the sandbox of netif's other clients. DHCPv4 with metric
    `routeMetric` + 100 (200); the kernel reads router advertisements,
    with `ra_defrtr_metric` 200 written before the link comes up
    (and `accept_ra` 2 on a machine that forwards IPv6);
  - the lease's DNS servers go to systemd-resolved through netif's
    writer; after a stop the dynamic address, the lease files and the
    link's DNS are removed.
  A pattern that is not a plain `^prefix` is an eval error (udev
  matches a prefix as a glob). In a NetworkManager mode nothing is
  rendered: NetworkManager does this itself (round gate-4).
- **Proof:** QEMU hot-plugs a USB network adapter into a running
  machine. DHCPv4, the advertised IPv6 default and DNS arrive; both
  defaults are at 200 behind the declared link's 100; a reapply and
  the drift watch change nothing; with the declared link down the
  dock carries both families; the client, killed, comes back with its
  lease; unplugging stops the unit and leaves no route, no DNS entry
  and no failed unit; a second plug gives the same result
  (`NETIF_HOTPLUG_PLUG_OK`, `NETIF_HOTPLUG_REAPPLY_OK`,
  `NETIF_HOTPLUG_FALLBACK_OK`, `NETIF_HOTPLUG_UNPLUG_OK`,
  `NETIF_HOTPLUG_AGAIN_OK`).
- **Defect found by the suite:** before every apply netif writes
  `ra_defrtr_metric` 100 to every interface (N18). That reset a
  plugged-in dock to 100, and its next advertised default tied with
  the declared link's. The writer now skips the hot-plug prefixes, and
  the suite asserts the sysctl and a freshly learned default after a
  reapply.
- A built-in NIC that should join any LAN is not a hot-plug case: it
  is a declared netif link with `dhcp.ipv4 = true` (`netif-dhcp`).
- Harness note (§7): a PCI NIC added with `device_add` did not show up
  in the guest (no hot-plug event in the test VM's machine type); a
  USB adapter on a `qemu-xhci` controller does.
- Not proven: DHCPv6 on a hot-plugged link (not rendered: DHCPv4 and
  advertisements only), and a real dock's interface name.

Round P2-wifi (2026-11-18): **Wi-Fi in both kinds of mode.**
Implemented, and proven by the new suite `netif-wifi`
(`NETIF_WIFI_OK`):
- **N5** the `iwd` preset renders iwd's settings for the mode
  (`lib/ownership.nix`), whenever iwd is enabled. IfState mode:
  `EnableNetworkConfiguration = true`, `NameResolvingService =
  systemd`, `RoutePriorityOffset = 300`. NetworkManager mode:
  `EnableNetworkConfiguration = false`, because NetworkManager
  configures the link and iwd is only its backend. A machine turns
  Wi-Fi on with `networking.wireless.iwd.enable = true`; in a
  NetworkManager mode the backend turns it on by itself.
- **A network never seen before, NetworkManager mode:** joined with
  `nmcli device wifi connect` (the call the KDE applet and Steam
  make); DHCPv4, the RA default and DNS arrive on the Wi-Fi link;
  both Wi-Fi defaults are at 600 or more and the wired link at 100
  wins; with the wired link disconnected Wi-Fi carries both families
  (`NETIF_WIFI_NETWORKMANAGER_OK`).
- **Known networks are shared (N5):** rebooted into the IfState mode,
  iwd joins that network with nobody asking; a network joined there
  with `iwctl` is a NetworkManager profile after rebooting back
  (`NETIF_WIFI_IFSTATE_OK`, `NETIF_WIFI_ADHOC_OK`,
  `NETIF_WIFI_SHARED_OK`).
- **N18 in an IfState mode:** iwd's IPv4 and IPv6 defaults are
  between 300 and 600, the wired defaults at 100; traffic leaves
  through the wire in both families, and through Wi-Fi when the cable
  is gone (`NETIF_WIFI_FALLBACK_OK`). A reapply changes nothing: the
  Wi-Fi link, its addresses and routes are iwd's.
- **Roaming:** with two access points of one network, stopping the one
  in use moves the client to the other; address, default and
  reachability hold (`NETIF_WIFI_ROAM_OK`).
- `tests/wifi-ap.nix` is the simulated Wi-Fi fixture (four
  `mac80211_hwsim` radios, the access points in a foreign namespace).
- The `wifi` probe is deleted (N40), and with it the last probe: the
  `netifProbes` output and `services/netif/tests/probes/` are gone.
- Still open in P2 then: hot-plugged wired links in an IfState mode
  (done, round P2-hotplug), and the Deck hardware check of Steam over
  the iwd backend (owner only).

Round P4b (2026-11-18): **every networking and cluster service
follows the mode.** Implemented, and proven by `netif-modes`
(`NETIF_MODES_FABRIC_OK`) and the new suite `k3s-modes`
(`K3S_MODES_OK`):
- **N4** `routed-fabric`, `wireguard-mesh`, `k3s` and `rke2` have the
  per-machine `modes` setting. One helper, `lib/mode-scope.nix`, splits
  each service's configuration: `clan` (vars generators, facts, the
  eval seams), the checks and the package set stay in every mode; units,
  IfState objects, FRR, HAProxy, Kubernetes, firewall rules, sysctls
  and mounts render only in the instance's modes.
- **The rules.** Evaluation rejects: a mode name the machine does not
  have; an instance active in a NetworkManager mode (the message says
  to set `modes`); a spine, a border, or a server of a cluster with
  other machines limited to fewer than all of its machine's modes.
- **N24, amended:** the rules read `clanServices.networking.modes`,
  which every configuration has. The mode list is not copied into
  `clan.networkFacts`: one source is enough.
- **A fabric leaf in one mode** (`netif-modes`): the machine's
  NetworkManager mode has no FRR unit, no tunnel and no fabric
  address; in its IfState mode it dials out from a DHCP address and
  has BGP and BFD with the spine in both families; back in the default
  mode the spine sees the sessions go down and nothing else changes.
- **A cluster in one mode** (`k3s-modes`, use case U2): a single-node
  k3s with Cilium and its `wireguard-mesh` transport exist only in the
  machine's `kubernetes` mode. The default mode has no unit, link,
  mount, firewall rule or forwarding sysctl of the cluster. After a
  round trip through the default mode the same cluster returns: the
  same node UID, its objects, a running pod.
- **Defect found (shared base):** a configuration with no IfState
  interface at all (a NetworkManager mode whose only instances are
  scoped away) failed evaluation on a missing attribute. Fixed in
  `lib/ifstate.nix`.
- Machines without modes are unaffected: the `routed-fabric`,
  `wireguard-mesh`, `k3s-single` and `rke2-single` suite derivations
  are identical before and after.
- The `modes-eval` probe is deleted (N40): `netif-modes` and the eval
  tests `modes.mechanism.*` assert what it showed.
- Not VM-proven: `rke2` and `wireguard-mesh` alone in a mode (eval
  tests `rke2.test_singleNodeClusterRendersOnlyInItsModes`,
  `rke2.test_voterMustBeInEveryMode`, `wireguard-mesh.modes.*`, added
  in the close-out round; `k3s-modes` boots k3s with a `wireguard-mesh`
  transport in one mode), and a routed-fabric leaf together with a
  cluster in one mode.

Round gate-4 (2026-11-18): **netif carries a KDE desktop in both
kinds of mode.** Proven by the new suite `netif-desktop`
(`NETIF_DESKTOP_OK`): one KDE Plasma machine (SDDM, Wayland, a logged-in
user) with a NetworkManager `default` mode and an IfState `developer`
mode, booted into each in turn. This is the third of N14's three
loads; with it the owner definition of stable is VM-proven.
- **A static profile and IPv6 in a NetworkManager mode (N2):** the
  declared link has its static IPv4 and IPv6 address, both gateways at
  metric 100 and its DNS server, from the profile netif wrote; the
  desktop user sees it (`NETIF_DESKTOP_STATIC_OK`).
- **A wired network never seen before (N18, amended):** a NIC netif
  does not declare is joined by NetworkManager's own DHCP profile. Its
  default route has metric 200 (`routeMetric` + 100, a NetworkManager
  connection default for Ethernet), so it sits behind netif's links
  and ahead of Wi-Fi, the order the `wired-hotplug` owner gives an
  IfState mode. With the declared link disconnected the ad hoc link
  carries the default with no reconfiguration (`NETIF_DESKTOP_ADHOC_OK`).
  Before this round both defaults had metric 100.
- **Tailscale beside NetworkManager (N6):** logged in to an offline
  Headscale; `tailscale0` is unmanaged; the tailnet answers in the
  NetworkManager mode, in the IfState mode after a reapply that
  changes nothing, and back (`NETIF_DESKTOP_TAILSCALE_OK`,
  `NETIF_DESKTOP_IFSTATE_OK`, `NETIF_DESKTOP_BACK_OK`).
- **KDE needs nothing special in an IfState mode:** Plasma asks for
  NetworkManager by default; the shared base switches it off there and
  the session starts.
- `tests/headscale-vm.nix` is the Headscale fixture, shared with
  `netif-registry` (its `headscale` node differs only in the order of
  its package list).
- `netif-guard`'s test read the journal before journald had written a
  line the guard had just printed, and failed under load. It syncs the
  journal first.
- Not proven then: Wi-Fi in a NetworkManager mode (done, round
  P2-wifi).

Round gate-3 (2026-11-18): **netif carries FRR alone.** Proven by the
new suite `routed-fabric-netif` (`NETIF_UNDER_FRR_OK`,
`ROUTED_FABRIC_NETIF_OK`): the whole `routed-fabric` suite (two spines,
three leaves, a WireGuard link, two BGP sessions and two BFD peers per
adjacency, ECMP, source-return rules, an FRR reload, a spine failure
and recovery) with every machine's underlay declared through netif, on
links netif does not trust, and with no Kubernetes on the machines.
One phase is added: on all five live machines the dry run proposes
nothing, the drift watch passes and a real reapply leaves the kernel
state identical; no BGP session restarts and a leaf's RIB and FIB are
the same before and after. No defect was found. This is the second of
N14's three loads.
- The suite body is `services/routed-fabric/tests/vm/suite.nix` with
  an `underlay` argument, as the data-plane suites have; `default.nix`
  and `netif.nix` are thin wrappers. The `routed-fabric` suite's node
  derivations and test script are unchanged (`suite-compare`).
- `suite-compare` now accepts a byte-identical test script whatever it
  contains; a baseline that already had subtests was reported as
  different.
- Still open for N14 then: a desktop specialisation (KDE) (done, round
  gate-4).

Round gate-1 (2026-11-17): **netif carries a Cilium Kubernetes
cluster with FRR; three defects found on the way.** Proven by the new
suite `k3s-data-plane-netif` (`NETIF_UNDER_KUBERNETES_OK`,
`K3S_DATA_PLANE_NETIF_OK`): the whole data-plane suite (k3s, Cilium
native routing, the routed-fabric WireGuard and FRR plane, BGP to a
foreign router, load-balancer pools, the firewall phases) with the
nodes' underlay declared through netif, on links netif does not
trust. One phase is added: on both live nodes the dry run proposes
nothing, the drift watch passes, and a real reapply leaves the kernel
state identical, with the cluster and the BGP sessions unaffected.
This is the first part of N14's definition of stable.
- **Defect 1, serious (N6, N8):** IfState would have deleted every
  pod's network namespace. The CNI names them `cni-<uuid>`, and IfState
  removes named namespaces it does not know. No suite saw it, because
  IfState only ran at boot there, before the first pod. The `cilium`
  owner now owns `^cni-`.
- **Defect 2 (routed-fabric):** the IPv6 transfer address was declared
  with `scope = "link"`. The kernel derives an IPv6 scope from the
  address and ignores a declared one, so IfState deleted and re-added
  that address on every apply, under the BGP session. The scope is
  gone from the IPv6 address.
- **Defect 3 (N6):** an address a failover controller puts on a link
  had no owner. Owners can now claim address ranges (`addresses`, to
  IfState `ignore.ipaddr`), and k3s and rke2 claim their floating
  pools on the candidate machines.
- **The dry-run parser was too strict (N38, N42, §7):** a long object
  name leaves one space before its operation, and such lines were read
  as headings. The preview, the drift watch and the suites' helper now
  split on any whitespace, and the preview names the interface a
  change belongs to.
- **RKE2 too** (round gate-2, same day): `rke2-data-plane-netif`
  passes the same suite and the same added phase
  (`RKE2_DATA_PLANE_NETIF_OK`), with no further fix.
- Still open for N14 then: a fabric leaf with FRR alone (done, round
  gate-3), and a desktop
  specialisation (KDE).

Round P4a (2026-11-17): **modes exist: one manager per mode, both
renderers.** Implemented and proven by `netif-modes`
(`NETIF_MODES_OK`):
- **N24** the `modes` clan service and `lib/modes.nix`; every
  configuration has the read-only `clanServices.networking.mode`.
- **N2** the shared base follows the mode's manager. netif has a
  NetworkManager renderer (`services/netif/networkmanager.nix`):
  a profile per plain wired link, iwd as the Wi-Fi backend, registry
  owners unmanaged. Anything only IfState can render is an eval error
  in a NetworkManager mode.
- **N3** one machine is booted into its NetworkManager mode, then its
  IfState mode, then back.
- **N4** `modes` on a netif instance: its links are rendered only in
  those modes. The other services follow in P4b (done, round P4b).
- Two findings from the first boot, both fixed in the renderer:
  NetworkManager's automatic profile took the link before netif's
  existed, and it started DHCP on a NIC that belongs to another mode.
- The k3s, rke2, routed-fabric and wireguard-mesh suite derivations
  are unchanged by the base change.

Round P8 (2026-11-17): **the lockout guard.** Implemented and proven
by `netif-guard` (`NETIF_GUARD_OK`):
- **N25** after every apply the default gateways must answer at layer
  2; if not, the last configuration that passed is re-applied and
  `netif-guard.service` fails. On by default on machines without a
  display manager.
- **A design change found by `netif-dhcp`:** the guard is its own
  unit, not an `ExecStartPost` of `ifstate.service` as probed. Inside
  `ifstate.service` it waited for a DHCP gateway that dhcpcd could
  only learn after `ifstate.service` had finished.
- **N36** `guard.targets` (a TCP port, a layer-2 answer or a ping),
  also checked after a firewall reload, where a failure is reported
  and nothing is rolled back.
- The `guard` probe is deleted (N40). The `netif` suite turns the
  guard off: its gateways do not exist.
- P8 was taken before P2 and P4: it has no dependency on modes, and it
  is the protection N19's untrusted default asked for.

Round P7b (2026-11-17): **VM hosts; P7 is complete.** Implemented and
proven by `netif-vmhost` (`NETIF_VMHOST_OK`):
- **N23** the bridge MAC rule and `links.<n>.mac`; bridge members may
  be physical, VLAN or bond links; `bridge.guestPorts` with the
  run-time include.
- **N37** after each apply every guest port listed before it must
  still be on its bridge, or `ifstate.service` fails and names it.
- The `vmhost` probe is deleted (N40).
- **§7** the suites' reapply helper resets systemd's start limit:
  suites restart `ifstate.service` more often than five times in ten
  seconds, which no operator does.

Round P7a (2026-11-17): **Docker and Podman beside netif.**
Implemented and proven by `netif-containers` (`NETIF_CONTAINERS_OK`):
- **N22** the `containers` preset, on with
  `virtualisation.docker.enable` or `virtualisation.podman.enable`;
  the address-pool check; forwarding only when Docker does IPv6.
- Docker's and Podman's published ports answer on an **untrusted**
  netif link with no port opened in the NixOS firewall: the runtimes'
  own rules forward them (N19).
- The suite found a defect in the tools: with a named network
  namespace present, IfState's dry run calls `mount`, which
  `netif-preview` and the drift unit did not have. Fixed.
- The `containers` probe is deleted (N40). VM hosts (N23, N37) are
  the second half of P7.

Round tools (2026-11-17): **the operator tools and the last
hardening decisions that needed no new phase.** Implemented:
- **N38** `netif-drift.service` and its timer; **N41** `netif-status`;
  **N42** `netif-preview` and the error sweep. Proven by `netif`
  (`NETIF_TOOLS_OK`).
- **N39** is decided: no daemon reads DNS servers from router
  advertisements; a machine that would end up with no DNS source gets
  an eval warning.
- **N40** the five remaining probes are in the repo and run as
  `.#netifProbes.<name>`.
- **§7** the no-op helper ignores LACP negotiation state of bond
  members; it changed between two snapshots with no apply in between.

Round P3b-5 (2026-11-17): **path MTU and cloud NICs; P3b is
complete.** Implemented:
- **N17** `links.<n>.pathMtu`, published per link and per instance in
  the export and in `clan.networkFacts`; never set on the link.
  `routed-fabric` prefers it over the link MTU. `wireguard-mesh`'s
  `mtu` is nullable: null derives it from the machine's netif links
  (path MTU, else link MTU, minus 96, floor 1280; 1420 when netif
  publishes neither). netif warns when a fabric member's DHCP default
  link declares no size. Eval tests cover each step.
- **N26** `links.<n>.match.path` renders a udev `.link` file; proven
  by `netif-match` (`NETIF_MATCH_PATH_OK`) on a virtio NIC in a fixed
  PCI slot. Eval rejects cloud-init's network configuration.
- SPEC.md invariant 21 is closed.

Round P3b-4 (2026-11-17): **links are untrusted by default; the zone
seam exists.** Implemented and proven by `netif-dhcp`
(`NETIF_DHCP_TRUST_OK`):
- **N19** a link is firewall-trusted only when it or its segment says
  so. On an untrusted link SSH answers and an unopened port does not;
  on a trusted link both do. netif opens UDP 546 on its DHCPv6 links.
  DHCPv4, DHCPv6 and prefix delegation work on an untrusted WAN.
  No suite relied on netif's trust: the cluster suites do not use the
  netif service, and every netif suite passed unchanged.
- **N10** `links.<n>.zone`; the read-only options
  `clanServices.networking.links.<instance>.<logical>` and
  `clanServices.netif.zones.<zone>` (the interfaces of a zone, an
  addition to the decision); `zone` and `trusted` in the export and in
  `clan.networkFacts`.

Round P3b-3 (2026-11-17): **default routes: one per family, chosen
explicitly, at a fixed metric.** Implemented and proven by `netif-dhcp`
(`NETIF_DHCP_DEFAULT_OK`) and `netif` (`NETIF_SWITCH_OK`):
- **N21** `links.<n>.defaultRoute.{ipv4,ipv6}`, with a segment default
  (an addition to the decision: a segment that never carries the
  default says so once). A link with `ra = true` now counts as a source
  of an IPv6 default; bond and bridge members never count.
- **N18** metric 100 on every netif default: IfState `preference` for a
  static gateway, dhcpcd `metric`, and `ra_defrtr_metric` for RAs. The
  sysctl is written by `ifstate.service` before each apply and set as
  the `default` for links IfState creates; there is no link hook any
  more (N31).
- **§7** live reconfiguration is proven by switching NixOS generations.
- The export and `clan.networkFacts` carry `defaultRoute` per link.

Round P3b-1 (2026-11-17): **the first code slice: dhcpcd, DNS and
"online" are implemented and VM-proven; the hardening candidates are
decisions.** Owner decisions of this round:
- **H1–H12 are adopted** as decisions **N31–N42** (§3). §11 keeps the
  reasoning.
- **"Stable" has an owner definition** (N14): netif is stable when it
  is proven to carry Cilium Kubernetes, FRR, and desktop
  specialisations such as KDE.
- **dhcpcd for non-netif machines waits for nixpkgs** (N30). Every
  machine moves to netif once it is stable.
- **`match.path` by udev path is confirmed** (N26).
- **Code, VM suites, spec and docs may change together**; breaking
  changes need no shim and no `schemaVersion` bump (N14).
Implemented and proven by `netif-dhcp` (`NETIF_DHCP_OK`):
- **N16, N31** one supervised, sandboxed dhcpcd unit per DHCP link,
  running upstream dhcpcd 10.5.2 with netif's own config. **The
  IfState hook is gone**: a systemd unit bound to the link replaces it.
- **N9** `netif-dns.service`; resolved is on in the base; netif writes
  no global DNS; the cross-instance DNS check is removed.
- **N16** prefix delegation, with its eval errors.
- **N32** `netif-online.service`; **N33** a stable IAID per link;
  **N34** the DHCPv4 backoff cap; **N35** the version envelope.
- **§7** the shared no-op helper, used by four suites; a forwarding
  RA server; the carrier-change assertions.

Round retro (2026-11-17): **netif moves to the unpatched upstream
dhcpcd, and the session's weak spots are written down; docs only
here.**
- **netif runs upstream dhcpcd 10.5.2** (owner decision): `org-pkgs`
  has it as `pkgs.dhcpcd_latest`. It also closes four CVEs (N16).
- **`pkgs.dhcpcd` stays the patched 10.3.2.** A blocker was found
  before the merge: 10.5 does not start under the stock NixOS
  `dhcpcd.service`, so a fleet-wide swap would have cut DHCP on every
  machine with `networking.useDHCP` (§8.4). netif is not affected: it
  starts dhcpcd from an IfState hook.
- **N30** is reworded: the upstream release first, a patch only when
  no release works.
- **This repo still uses `pkgs.dhcpcd`** (the patched 10.3.2). Docs
  only this round; the lock bump and the switch to `dhcpcd_latest` are
  the first step of P3b (§9).
- **§11 (new)** lists the decisions with weak proof and twelve
  hardening candidates `H1`–`H12`. A candidate is not a decision.
- **§7** gains the control rule: a "broken" finding needs a run that
  shows the fixture works.
- **§9** slices P3b into five parts, each with its own green suite.
- Evidence is §8.4.

Round proof-solo (2026-11-16): **the broken and open findings were
rerun alone on euc-hel-0 and researched; docs only here, one package
patch in pkgs.** Evidence is §8.3.
- **dhcpcd's lost leases are real, root-caused and fixed.** Not a noisy
  neighbour: stock 10.3.2 failed in every solo run. A socket is closed
  before it leaves the event loop (upstream issue #596, fix PR #611).
  `org-pkgs` now builds dhcpcd with the two upstream commits; with it
  every carrier change recovered (N16).
- **N30** (new): a package that needs a patch is patched in pkgs,
  never here.
- **The vanishing RA default was the probe's fault.** The simulated ISP
  did not forward IPv6. No solicitation helper is needed, and dhcpcd
  never handles RAs (N16). §7 gains two testing rules.
- **Decided:** `ipv4only` for dhcpcd on links without DHCPv6 (N16).
- **N23** guest ports render through the stock NixOS module as one
  included regex; proven. **N26** IfState can rename by parent device;
  the udev path stays the design because virtio parent names move.
- **N9** names `rdnssd` as the candidate if RA DNS is ever needed.
- A correction to the round below: its 10.5.2 run "got no DHCPv6
  lease" because the probe's kea had not opened its socket, not
  because of dhcpcd.

Round proof (2026-11-16): **the open assumptions were probed on
euc-hel-0 and rough designs written around the results; docs only.**
Five throwaway VM probes and one eval probe ran (§8.2). Phases are
renamed `N…` → `P…`.
- **Proven as designed:** the netif DNS unit (N9); one default route
  with two DHCP links, for IPv4 and IPv6 (N21); iwd's metric offset in
  both families (N18); bridge MAC and a bridge over a VLAN (N23); the
  lockout guard (N25); the `modes` mechanism (N24).
- **Proven after a design change:**
  - **N22** the `containers` preset must also own Podman's named
    namespaces (`^netns-`); owning the links is not enough.
  - **N23** guest ports: IfState has no per-bridge rule, so netif writes
    a run-time ignore list that IfState includes. No owner decision is
    needed.
  - **N26** `match.path` is a udev path rendered as a `.link` rename,
    not IfState `identify`: a virtio NIC's parent name is a counter.
- **Found broken:** dhcpcd 10.3.2 does not recover both protocols
  after a carrier change, and it takes over the link-local address even
  with `noipv6rs` (N16). Both are settled in round proof-solo above.
- **Not covered:** DNS from RAs (N9).


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

Round P3b-spec (2026-11-16): **the contract is refined before P3b code;
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
- **N10**'s zone seam and the export's `schemaVersion` 2 move into P3b.
- **N14** splits 1.0 into a contract gate (N6a, VM-proven) and a field
  gate (N6b, home runs U1–U4).
- **Invariant 5** has a test definition (§7) and one shared helper.
- **N8** records that IfState route ignores match `dev` as a regex, so
  netif anchors its own.
Drift found by the review is listed in §5; P3b fixes it.

Round P3a (2026-11-15): **physical NICs: identity, presence, passthrough
(N15).** Phase P3 is split: P3a (`match.mac`, a missing NIC fails
loudly, the checked `extraSettings` passthrough) is implemented and
VM-proven by `netif-match` (`NETIF_MATCH_OK`). Probing the IfState 2.5.1
source showed a declared physical NIC that is missing only logs
"unable to create physical link" and exits 0, so netif adds its own
post-apply check. P3b (DHCPv6-PD settings, `pathMtu`, per-link resolved
DNS) stays planned.

Round P1 (2026-11-15): **the ownership registry is implemented and
enforced.** `lib/ownership.nix` (imported by the shared IfState base)
holds `clanServices.networking.owners`, the four presets, N7's ordering
and N11's checks; ownership conflicts, IfState Wi-Fi links and daemons
without a preset are eval errors. The suite `netif-registry` proves it
(`NETIF_REGISTRY_OK`). NetworkManager rendering of the registry waits
for phase P2.

Round P0 (2026-11-15): **the contract is split out of SPEC.md and
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
- **eval-probed** — a throwaway evaluation passed on the stated date
  (§8). Same weight as probe-verified, for claims that need no VM.
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
| NAT, NAT64, port forwarding, firewall rules beyond trust | `services/router` and `services/nat-gateway`, built on netif's zones (N10, `specs/gateway.md`) |
| DHCP server, router advertisements sent to others, DNS server | `services/router` (N10, `specs/gateway.md`) |
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
  the LAN: the router has no radio. Router services are
  `services/router` in this repo (`specs/gateway.md`); netif owns the
  links. The LAN is split into zones (G11): routed ports and VLANs on a
  trunk port, no bridge. The WAN presents the ISP gateway's MAC (N43).
  No inbound port by default (G12).
  - Covered by: N10, N15, N16, N19, N25, N43, N44.
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
- **U12 Gaming desktop** (owner, 2026-11-18). No Wi-Fi.
  - Default boot: KDE for Steam, NetworkManager, a static wired LAN
    link.
  - `developer`: IfState, the same static link, Tailscale, a
    `routed-fabric` leaf with client access to pod and Service IPs.
  - Covered by: N2, N3, N4, N24.
- **U13 IPv6-only cloud machine** (owner, 2026-11-20). One public IPv6
  link and no IPv4 address on any NIC, because a public IPv4 costs
  money. It reaches IPv4 through `nat-gateway` (`specs/gateway.md` G4).
  It may be a dual-stack Kubernetes node (SPEC.md D67).
  - Covered by: N45, N15 or N26. *(planned)*
- **U14 Cloud gateway.** A fleet machine with a public IPv4 and the
  `nat-gateway` `gateway` role. For netif it is a dual-stack machine.
  - Covered by: U6's list.
- **U15 On-prem site with two carriers.** Two routers, each with its own
  WAN, serving devices nobody can configure (`specs/gateway.md` G17).
  - Covered by: N10, N21 as amended. *(planned, design only)*
- **U16 Router with a backup WAN.** U3 plus a second WAN link, for
  example a modem that presents Ethernet with DHCP
  (`specs/gateway.md` G16).
  - Covered by: N21 as amended. *(planned)*
- **U17 A public address for a Kubernetes Service at home** (owner,
  2026-11-20). A Service in a cluster behind the home router, for
  example a game server, gets a public IPv6 address out of the block
  the ISP delegates. It works as in the cloud: an LB-IPAM pool,
  Cilium and BGP (SPEC.md D8). Only the edge differs: at home the
  router holds the prefix, in the cloud a node or a floating block
  does.
  - Covered by: `specs/gateway.md` G20; SPEC.md D8; N16 with `reserve`.
    *(planned)*
- **U18 Owned address space** (owner, 2026-11-20). Later the owner
  holds an AS number and IPv6 prefixes from a regional registry
  (Europe, North America or both) through a sponsor, and announces
  them to providers by BGP. Services at any site, the home included,
  then keep their addresses when a provider changes.
  - Covered by: `specs/gateway.md` G21; SPEC.md D8, D9, D56. For netif
    a border is an ordinary machine. *(planned, design only)*

**Owner restatement of 2026-11-18** (additions to the list above; the
per-machine proof table is `documentation/docs/netif/use-cases.md`):
- U2 `developer` also runs Docker, Podman and virtual machines (N22,
  N23); U1 and U2 must join Wi-Fi and wired networks they have never
  seen, in every mode (N5, N12).
- U3 is also a Kubernetes node: it terminates HTTPS (Envoy Gateway,
  CrowdSec in the cluster), reverse-proxies to the nodes behind it and
  load-balances to them by ECMP over FRR. All of that is day-2 or
  SPEC.md's; netif's part is unchanged.
- U4 runs RKE2 with ClusterMesh, Tailscale and WireGuard, and hosts
  guests with provider MACs (U5) through KubeVirt and Multus.
- U6 prefers DHCP.
- Clans with Cilium in tunnel mode and no FRR are a supported shape
  (U7, `wireguard-mesh`).
- **Open point:** the owner wrote that U2's `developer` mode uses
  NetworkManager. N2 and N4 stand: the fabric needs IfState, so
  `developer` and `kubernetes` are IfState modes. Changing that is a
  redesign and an owner decision.

Across all of them: Tailscale is first class in every mode; NetBird and
Cloudflare WARP are planned (N29); WireGuard is `routed-fabric` and
`wireguard-mesh` only (N6).

## 3. Decisions

- **N1 netif is the single contract; the name stays `netif`.** Every link,
  address mode, route, policy rule, MTU, DNS server and firewall trust a
  machine has is declared through netif instances in the inventory, in every
  mode. Supporting services (for example `services/router`)
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
  - **As built** (`services/netif/networkmanager.nix`):
    - one profile `netif-<interface>` per physical link:
      `ipv4.method` `auto`, `manual` or `disabled`; `ipv6.method`
      `auto` (DHCPv6 or RAs), `manual` or `link-local`; the gateway on
      the first address; the link's static routes, DNS servers and MTU;
      `route-metric` 100 (N18); `never-default` from `defaultRoute`
      (N21);
    - `main.no-auto-default` names netif's links, so NetworkManager's
      own "Wired connection" never takes one before netif's profile
      exists;
    - a physical NIC that netif declares only for other modes is
      unmanaged; a link netif never declares (a dock) stays
      NetworkManager's;
    - a NIC found by `match.mac` is renamed by a udev `.link` file, so
      it has the same name in every mode;
    - registry owners become `interface-name:<prefix>*`; an owner
      pattern that is not a plain `^prefix` is an eval error in a
      NetworkManager mode; iwd is never unmanaged;
    - dhcpcd, the DNS writer, "online", the tools and the guard are
      IfState-mode only.
  *(implemented, round P4a: `netif-modes` `NETIF_MODES_NETWORKMANAGER_OK`;
  eval tests in `services/modes/tests`; a static IPv4 and IPv6 profile,
  round gate-4: `netif-desktop` `NETIF_DESKTOP_STATIC_OK`; Wi-Fi,
  round P2-wifi: `netif-wifi` `NETIF_WIFI_NETWORKMANAGER_OK`)*

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
    *(implemented, round P4a: `netif-modes` boots each mode by giving
    the kernel that mode's init, the way the boot menu does —
    `NETIF_MODES_IFSTATE_OK`, `NETIF_MODES_BACK_OK`. A boot loader
    menu itself is not in the suite; the 2026-11-15 probe covered it)*

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
  *(implemented for netif, round P4a: an instance's links, firewall
  trust and `.link` files are rendered only in its modes; its exports
  and facts stay; an unknown mode name is an eval error; the same NIC
  may belong to one instance per mode. Implemented for
  `routed-fabric`, `wireguard-mesh`, `k3s` and `rke2`, round P4b:
  `lib/mode-scope.nix`; eval tests `routed-fabric.modes.*`,
  `k3s.test_singleNodeClusterRendersOnlyInItsModes`,
  `k3s.test_voterMustBeInEveryMode`; `netif-modes`
  `NETIF_MODES_FABRIC_OK`; `k3s-modes` `K3S_MODES_OK`. "An etcd voter
  of a multi-node cluster" is checked as: a server of a cluster with
  more than one machine)*

- **N5 iwd owns Wi-Fi in every mode.**
  - **NetworkManager modes:** NetworkManager drives iwd as its Wi-Fi
    backend. Steam's UI and the KDE applet join networks through
    NetworkManager over D-Bus.
  - **IfState modes:** iwd runs on its own with `EnableNetworkConfiguration
    = true`. It does association, DHCP and roaming, and sends DNS to
    systemd-resolved (`NameResolvingService = systemd`). IfState never
    configures a Wi-Fi link: the link and the routes iwd installs are
    registry-owned (N6). An IfState interface named `wl*` is an eval error
    in every mode, whether or not iwd is enabled (implemented, phase P1).
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
    with iwd. A one-time hardware check on the Deck closes it (phase P2).
  *(probe-verified except Steam itself; planned, phase P2)*

- **N6 Ownership registry.** `clanServices.networking.owners.<name>` is a
  composable NixOS option. Each owner declares the objects it owns:
  - interface-name regexes;
  - named network namespaces;
  - address ranges whose addresses another program places at run time
    (`addresses`, rendered to `ignore.ipaddr`; added in round gate-1);
  - routing tables;
  - policy-rule priorities or tables;
  - route selectors;
  - whether its daemon holds long-lived network sessions (N7).

  The base renders every owner into IfState `parameters.ignore`
  (`ifname`, `netns`, `rules`, `routes`) and, from phase P2, into
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
  | `containers` (`virtualisation.docker.enable` or `virtualisation.podman.enable`) | N22 | planned, phase P7 |
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
  NetworkManager side lands in phase P2)*

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
  `NETIF_REGISTRY_ORDER_OK`; NetworkManager modes: phase P2)*

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
    anchored today; fixed in P3b.)*
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
    first in phase P3b, before anything builds on it. If it fails, phase
    P3b stops for an owner decision instead of falling back to global
    DNS.
  - **Rough design** (DNS probe, §8.2; three runs):
    - *One writer script.* `netif-dns-apply [link…]` is idempotent. For
      each netif link it joins the static servers with the lease files
      under `/run/netif-dns/`. With carrier and at least one server it
      calls `resolvectl dns` and `resolvectl domain`; otherwise
      `resolvectl revert`.
    - *Three callers.* The unit's watcher loop (`ip monitor link`,
      filtered to netif's links); dhcpcd's exit script, after it wrote
      or removed a lease file; `ifstate.service`, as an
      `ExecStartPost`.
    - *Lease files.* dhcpcd's `script` setting points at netif's exit
      script. It writes `<link>.dhcp4.dns` and `.domain` from
      `new_domain_name_servers`, `new_domain_name` and
      `new_domain_search` on `BOUND`, `RENEW`, `REBIND`, `REBOOT`; the
      `.dhcp6` pair from `new_dhcp6_name_servers` and
      `new_dhcp6_domain_search` on the `…6` reasons; and removes them on
      `EXPIRE`, `STOP`, `RELEASE`, `NOCARRIER` and `STOPPED`.
    - *resolved restarts.* The unit is `PartOf` and `After`
      `systemd-resolved.service`, so a resolved restart re-applies.
    - *Gate results.* DNS was on the right link after boot (DHCPv4,
      DHCPv6, static, a second DHCP link), after an IfState reapply,
      after a static link went down and up (also ten times in a row),
      after a resolved restart, and after a lease renewal that brought
      new servers (the old one was removed, the DHCPv6 server kept).
      resolved held no DNS for a link without carrier.
    - **The gate passes for the DNS unit.** What failed in the same
      runs is dhcpcd's recovery after a carrier change, which is N16's
      subject, not this unit's.
  - **RA-only DNS is not covered.** A link that learns IPv6 only from
    RAs gets no DNS from them: the kernel does not act on the RDNSS
    option and no daemon listens (probe: the server in the RA never
    reached resolved). Such a link declares `nameservers`, or uses
    DHCPv4 or DHCPv6 DNS. Reading RDNSS would need a listener:
    systemd-resolved reads no RAs (only systemd-networkd does), and
    dhcpcd reads them only when it handles RAs, which N16 forbids. The
    candidate, if a machine ever needs it, is `rdnssd` from the `ndisc6`
    package (NixOS `services.rdnssd`) feeding the netif DNS writer. It
    is not planned.
  - **As built (P3b-1).** `services/netif/host.nix`. Static servers
    are files under `/etc/netif/dns/`, lease files live in
    `/run/netif-dns/`. The watcher exits non-zero when `ip monitor`
    ends, and the unit has `Restart=always`. Search domains come from
    leases only; a static link sets servers.
  *(implemented; VM-proven by `netif-dhcp` `NETIF_DHCP_DNS_BOOT_OK`,
  `NETIF_DHCP_RENEW_OK`, `NETIF_DHCP_DNS_FLAP_OK`; iwd and
  NetworkManager sides: phase P2. Earlier status:
  probe-verified 2026-11-16: the netif unit design passed its gate in
  a probe; iwd and NetworkManager probe-verified 2026-11-15; planned,
  phase P3b)*

- **N10 Router contract.**
  - **IfState owns** the router's links: the four SFP+ ports and the
    RJ45 port, matched by permanent MAC, VLANs, bridges, LAN addresses,
    forwarding sysctls and static routes.
  - **A per-link dhcpcd hook owns** the WAN DHCPv4 lease and DHCPv6 prefix
    delegation (N16). Delegated LAN addresses and their routes (`proto dhcp`,
    finite lifetimes) are dynamic and survive IfState reapply.
  - **Other daemons, configured by `services/router` in this repo
    (`specs/gateway.md`; amended 2026-11-20, was "in `modules`"):**
    nftables (NAT and the zone firewall), the DHCP server (kea), router
    advertisements (corerad, G15) and DNS (CoreDNS, G14).
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
    - `clanServices.netif.zones.<zone>` is the same seam read the
      other way: the sorted interface names of every link with that
      zone. A NAT rule wants "all `wan` interfaces", not one link.
    - The seam ships in phase P3b with the other export changes (N16,
      N17). *(implemented, round P3b-4; eval tests `test_zoneSeam`,
      `test_zoneNameChecked`)* Phase P5 builds `services/router`
      on it (`specs/gateway.md` §7, slice S2).
  - **NAT is never netif's (N20).** The home router's NAT lives in the
    router service. A NAT gateway for other machines (U9, U13) is the
    separate clanService `nat-gateway`, built on the same seam
    (`specs/gateway.md` G1).
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
  seam planned, phase P3b; `services/router` and `netif-router`, phase P5.
  The probe used radvd; corerad is re-proven by `specs/gateway.md` PR3)*

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
  NetworkManager modes. *(implemented, round P2-hotplug:
  `clanServices.netif.hotplug.interfaces`, `netif-hotplug`
  `NETIF_HOTPLUG_OK`; eval tests
  `modes.netifRendering.test_hotplug*`)*

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
  - **Owner definition of "stable" (2026-11-17).** The contract gate
    is passed only when VM suites prove netif under the three loads
    the fleet needs:
    1. a Cilium Kubernetes node (k3s and RKE2 suites on the netif
       base);
    2. FRR on `routed-fabric` *(proven, round gate-3:
       `routed-fabric-netif`)*;
    3. desktop specialisations such as KDE: NetworkManager modes
       beside IfState modes on one machine (N3, N24) *(proven, round
       gate-4: `netif-desktop`)*.
    Every machine moves to netif once it is stable.

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
  - **Own config file.** Each DHCP link's unit (N31) starts dhcpcd
    with `-f /etc/netif/dhcpcd/<interface>.conf`. dhcpcd never reads
    `/etc/dhcpcd.conf`.
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
  - **Finding the daemon.** Each link's dhcpcd is its own systemd unit
    (N31); nothing searches the process list.
  - **No route ignore.** dhcpcd's routes are `proto dhcp` (16) and the
    kernel's RA routes `proto ra` (9). IfState ignores both by
    default, so netif's `{dev, proto = 4}` ignore is removed.
  - **Prefix delegation settings:**
    `links.<n>.dhcp.prefixDelegation = { enable; hint; assign; }`
    - `hint`: requested length, 48–64, default 56;
    - `assign`: a list of `{ instance ? null; link; subnet; length ? 64; }`.
      `instance = null` means the same instance; WAN and LAN are usually
      separate instances, so naming another instance is allowed.
    - It renders `ia_pd <iaid>/::/<hint>` with one
      `<interface>/<subnet>/<length>` per entry, using resolved
      interface names.
  - **Eval errors** for prefix delegation:
    - it needs `dhcp.ipv6 = true` on the same link;
    - every `assign` target exists on the machine and is not the
      delegating link;
    - subnet ids are unique per delegating link and fit in
      `2^(length - hint)`;
    - a target link receives delegation from at most one link.
  - **To amend for a service prefix (2026-11-20, planned).**
    `prefixDelegation.reserve` is a list of `{ subnet; length ? 64; }`:
    subnet ids that no link receives. They join the uniqueness and size
    checks above and are exported with `assign`. A router routes such a
    subnet to Kubernetes Service addresses (`specs/gateway.md` G20).
    Whether dhcpcd's own route for the delegated prefix already refuses
    unused addresses is part of probe PR6.
  - **Runtime fact.** Delegated prefixes exist only at runtime. Exports and
    `clan.networkFacts` carry
    `prefixDelegation = { enable; hint; assign; dynamic = true; }`,
    where each `assign` entry names the target `instance` and `link`,
    and never a prefix literal. Consumers (the
    router module, phase P5) read the live prefix on the target link. netif
    never invents an address.
  - **Facts from the DNS probe** (§8.2, dhcpcd 10.3.2):
    - Setting `script` to netif's exit script replaces
      `dhcpcd-run-hooks`, so no stock hook runs and `nohook` lines are
      not needed. `/etc/resolv.conf` was not touched.
    - `noipv4ll`: no `169.254` address and no link-local default
      appeared in any run.
    - A dhcpcd started for one link writes `/run/dhcpcd/<link>.pid`.
      The hook tests that file and the process, not a `pgrep` pattern.
    - Its routes are `proto dhcp` with the configured metric, including
      a classless static route. No `static` route was seen, so the
      extra `{dev, proto = 4}` ignore can go.
  - **dhcpcd 10.3.2 loses a protocol after a carrier change. Fixed by
    upstream dhcpcd 10.5.2, `pkgs.dhcpcd_latest` (N30).**
    - *Symptom.* After the link loses and regains carrier, dhcpcd logs
      `eloop_event_add: No such file or directory` and DHCPv4 or DHCPv6
      does not recover. DNS follows the lease, so the link loses that
      DNS too.
    - *Not a noisy neighbour.* Each run below was the only build on
      euc-hel-0 (load average 0.1–0.3 at start and end). Stock 10.3.2
      showed the error after every carrier change in three runs. In
      five `ip link set down` / `up` cycles in a row, DHCPv4 came back
      0 of 5 times and DHCPv6 1 of 5.
    - *Cause, from the source.* `ipv6_freeaddr` (`src/ipv6.c`) closes a
      DHCPv6 address socket and only then deletes it from the event
      loop. `epoll` has already dropped the closed descriptor, the
      delete fails, and the loop keeps a stale entry. The next socket
      that gets the same descriptor number is then "modified" instead
      of added, which fails with `ENOENT`, and nobody reads that
      socket. Which protocol loses depends on which socket reuses the
      number. This is the only such place in 10.3.2.
    - *Upstream.* Issue NetworkConfiguration/dhcpcd#596 reports the
      same three log lines after suspend and after Wi-Fi roaming. PR
      #611 fixes it with two commits (delete before close; always drop
      the entry on delete), released in 10.5.0.
    - *Fix.* netif runs `pkgs.dhcpcd_latest`: the unpatched upstream
      dhcpcd 10.5.2 on the nixpkgs recipe, from `org-pkgs`
      `overlays.ifstate` (owner decision, 2026-11-17, pkgs PR 43).
      Results for 10.5.2 are in §8.4. The first fix, 10.3.2 with the
      two commits (pkgs PR 42), passed the same loop in four runs and
      stays as `pkgs.dhcpcd`.
    - *Why two packages.* From 10.5.1 dhcpcd calls `chown` on its
      control socket. The stock NixOS `dhcpcd.service` filters that
      system call, and dhcpcd dies at start (`dhcpcd manager hungup`;
      §8.4). nixpkgs PR 562813 adds `@chown` to the unit and is open.
      Until it lands, `pkgs.dhcpcd` must stay 10.3.x for machines with
      `networking.useDHCP`. netif never uses that unit (N16), so it
      takes the newer package by name.
    - *Security.* dhcpcd through 10.3.2 has CVE-2026-56113, 56114,
      56116 and 56117, fixed in 10.5.0. netif links get the fix with
      `dhcpcd_latest`. Machines on the stock unit keep 10.3.2 until
      nixpkgs ships 10.5; moving them sooner needs the unit change and
      the package in one deploy, in the modules repo (owner decision).
    - *What 10.5 changes for netif* (upstream release notes):
      - a released lease now runs the hook with reason `RELEASE`, not
        `STOP` (PR 701). The N9 hook treats both as "lease gone";
      - the unprivileged control socket is gone (PR 680). netif calls
        `dhcpcd -x` as root only;
      - prefix-delegation code changed (PRs 649, 665, 672). The
        delegation probe of §8.1 ran on 10.3.2, so `netif-dhcp` must
        prove delegation again on 10.5.2 (§11);
      - DHCPv4 backoff is configurable (PR 593). Not used yet.
    - *Workaround, no longer needed:* stopping that link's dhcpcd and
      rerunning IfState brought both protocols back.
  - **dhcpcd and the link-local address.** dhcpcd sets the link's
    `addr_gen_mode` to 1 and adds the link-local address itself
    whenever IPv6 is enabled for the link, `noipv6rs` or not
    (`if_setup_inet6`, `src/if-linux.c`; it has no option to leave it).
    The value stays after dhcpcd stops.
    - **Decided: `ipv4only` on links without DHCPv6.** dhcpcd then
      leaves IPv6 on that link alone: `addr_gen_mode` stayed 0 and the
      lease, its routes and its DNS were unchanged (§8.3).
    - **Accepted on DHCPv6 links.** There dhcpcd is the writer of the
      link-local address; netif renders no link-local setting for such
      a link. The kernel still solicits routers with that address: a
      router solicitation left the link after every down/up (30 of 30
      cycles), and the RA default was back within 2 seconds.
    - **No solicitation helper.** The first proof round saw the RA
      default stay away after a down/up and blamed the missing
      solicitation. That was a fault of the probe, not of netif: the
      simulated ISP did not forward IPv6, so its neighbour
      advertisements carried no router flag, and the kernel dropped it
      as default router about 10 seconds after first use (RFC 4861
      §7.2.5). It happened with dhcpcd stopped too, and stopped
      happening once the ISP node forwarded. §7 now requires
      RA-sending test nodes to forward.
    - dhcpcd never handles RAs on a netif link; that candidate is
      closed.
  - **Verification gate.** dhcpcd with `noipv6rs` must still run DHCPv6
    and prefix delegation in `netif-dhcp`. The 2026-11-16 probe passed
    this: an address from `ia_na` and a delegated `/60` with a `/64` on
    the LAN, with IfState's `accept_ra = 2` untouched (§8). The suite
    still has to prove it.
  *(implemented; VM-proven by `netif-dhcp`: `NETIF_DHCP_LEASES_OK`,
  `NETIF_DHCP_UNIT_OK`, `NETIF_DHCP_PD_OK`, `NETIF_DHCP_IPV4ONLY_OK`,
  `NETIF_DHCP_CARRIER_OK`, `NETIF_DHCP_FLAP_OK`; `defaultRoute` (N21)
  is slice 3)*

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
  - **As built.** wireguard-mesh reads every netif export of its own
    machine, so the smallest declared size of all its netif instances
    wins. When netif publishes neither a path MTU nor a link MTU the
    mesh keeps 1420.
  *(implemented, round P3b-5: eval tests `test_pathMtuExported`,
  `test_pathMtuAboveMtuRejected`, wireguard-mesh `test_mtuFollowsNetif`,
  routed-fabric `test_netifPathMtuPreferred`)*

- **N18 Default routes from several owners.** D53 still allows at most one
  netif link per family to own the main-table default. Other owners
  (Wi-Fi, a hot-plugged dock, Tailscale) may add defaults too, so every
  default route has a fixed metric. Lower wins:

  | Owner | IPv4 and IPv6 metric | How it is set |
  |---|---|---|
  | netif link (static gateway, DHCP lease, RA) | 100 | IfState route `preference`; dhcpcd `metric`; `ra_defrtr_metric` written by the link hook |
  | `wired-hotplug` owner (N12) | 200 | its dhcpcd `metric` |
  | iwd (Wi-Fi) | 300 and up | iwd `RoutePriorityOffset = 300`, pinned by the `iwd` preset |
  | NetworkManager modes | netif's wired links 100, any other wired link 200, Wi-Fi 600 | the renderer sets its profiles' route metric to 100 explicitly; a connection default for Ethernet (`connection-netif-adhoc-wired`) gives every profile without a metric of its own, such as a dock's, `routeMetric` + 100; NetworkManager's Wi-Fi default is already higher |

  - Effect: with a cable plugged in, wired wins and Wi-Fi stays up as a
    fallback; unplugging falls back with no reconfiguration.
  - Tailscale installs no main-table default. An exit node routes through
    table 52 at rule 5270, ahead of every metric; using one is the
    owner's explicit choice and outside this order.
  - **Who writes `ra_defrtr_metric`.** IfState 2.5.1's schema rejects
    this sysctl (`iface-sysctl-ipv6` allows no extra keys), so IfState
    cannot set it. As built (there is no link hook since N31):
    - `ifstate.service` writes it to every existing interface before
      each apply (`ExecStartPre`), while a new link is still down;
    - `net.ipv6.conf.default.ra_defrtr_metric` covers links IfState
      creates (VLANs, bonds, bridges).
    The value is `clanServices.netif.routeMetric` (100). netif stays the
    one writer. The missing key is worth reporting to IfState upstream;
    netif does not depend on a fix.
  - **Verification gate.** `netif-dhcp` asserts metric 100 for each
    family's default (DHCPv4, RA). `netif-wifi` (phase P2) asserts wired
    over Wi-Fi in both families. If iwd does not apply
    `RoutePriorityOffset` to IPv6, the phase stops for an owner
    decision. The 2026-11-16 probe showed both defaults at metric 100
    (`proto dhcp` and `proto ra`), with the sysctl written by the hook.
  - **iwd applies the offset to both families** (Wi-Fi probe, §8.2).
    With `RoutePriorityOffset = 300`, iwd 3.12 installed its IPv4
    default (`proto dhcp`) and its IPv6 default (`proto ra`) at metric
    307. iwd handles RAs itself and sets the link's `accept_ra` to 0.
    Beside IfState defaults at `preference` 100, both families left
    through the wired link; with the wired link down, both left through
    Wi-Fi with no reconfiguration. Two applies changed no default. The
    stop condition above did not trigger.
  *(netif metrics implemented: `netif-dhcp` `NETIF_DHCP_DEFAULT_OK`
  asserts metric 100 for the DHCPv4 and the RA default, `netif`
  `NETIF_SWITCH_OK` for a static gateway and for a metric changed by a
  generation switch; Wi-Fi probe-verified 2026-11-16; planned: Wi-Fi
  and dock in P2)*

- **N19 Links are untrusted unless declared trusted.**
  - `links.<n>.firewall.trust` and the segment `firewall.trust` default
    to untrusted. Null on a link inherits the segment; null on the
    segment means untrusted.
  - Trust is explicit: set it on a segment (a private LAN) or a link.
  - Services open what they need on their own interfaces and ports:
    - `routed-fabric`: BGP and BFD on fabric WireGuard links (D63);
    - `wireguard-mesh`: its UDP port;
    - `k3s` and `rke2`: their cluster ports.
    No service may rely on netif trusting a link. P3b runs every suite
    to find any that do and fixes them in the owning service.
  - A breaking change with no shims (AGENTS.md rule 10).
  - **Stop condition.** If a cluster service needs a new firewall
    ownership model rather than a missing port opening, P3b stops for an
    owner decision. It did not trigger: no suite relied on trust.
  - **netif's own port.** netif opens UDP 546 on every DHCPv6 link
    (`networking.firewall.interfaces.<link>.allowedUDPPorts`). DHCPv4
    needs none: dhcpcd reads it from a packet socket.
  *(implemented, round P3b-4: `netif-dhcp` `NETIF_DHCP_TRUST_OK`)*

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
  - **To amend for multi-WAN (2026-11-20, planned).** A router with two
    WAN links (U16, `specs/gateway.md` G16) needs one default per WAN
    with distinct metrics. The rule below then becomes "at most one per
    metric". Design it with N18 before any code.
  - **The rule.** Per machine and family, at most one netif link has
    `defaultRoute` true **and** a source for a default. Sources are: a
    static gateway outside a policy table, DHCPv4, DHCPv6 with RA, and
    plain RA (`ra = true` on a link with no static IPv6 gateway). A
    bond or bridge member is never a source.
  - **Segment default.** The instance settings carry the same
    `defaultRoute = { ipv4; ipv6; }` (default true); a link's value is
    nullable and inherits it. A private segment sets
    `defaultRoute.ipv6 = false` once instead of on every link.
  - The export and `clan.networkFacts` say per link which families'
    default it owns (`defaultRoute.{ipv4,ipv6}`).
  - `ra` stays true by default, so a second RA-accepting link must set
    `defaultRoute.ipv6 = false` (or `ra = false`). The eval error names
    both links and says so.
  - Example (Hetzner Cloud, U6): the public NIC keeps the default; the
    private NIC sets `defaultRoute.ipv4 = false` and keeps its lease's
    routes to the private network.
  - **Probe results** (§8.2). A second DHCP link with `nogateway`:
    - kept its lease and address;
    - installed the classless static route the server sent
      (`10.50.0.0/16`, `proto dhcp`, metric 100);
    - installed no default, although the server sent a router option
      and a classless default.
    The same link with `accept_ra = 1`, `autoconf = 1` and
    `accept_ra_defrtr = 0` took a SLAAC address and the on-link prefix
    route from the RA and no default. IfState's schema accepts
    `accept_ra_defrtr`. The machine had exactly one default per family,
    both on the first link at metric 100.
  *(implemented: `netif-dhcp` `NETIF_DHCP_DEFAULT_OK` — a second DHCP
  link with `nogateway` keeps its lease, classless route and DNS, takes
  a SLAAC address and no default in either family, also after a
  renewal; eval tests cover the rule)*

- **N22 Containers: Docker and Podman.**
  - One preset, `containers`, switched on by
    `virtualisation.docker.enable` or `virtualisation.podman.enable`.
  - It owns:
    - links `^docker`, `^br-`, `^podman`, `^veth`, and the routes on
      them;
    - network namespaces `^netns-`. Rootful Podman (netavark) puts each
      container in a named namespace, `netns-<uuid>`, and IfState
      deletes undeclared named namespaces (N8). Docker's namespaces are
      not named, so IfState never sees them.
  - **Why all of them.** IfState's built-in ignores cover `docker0`,
    `br-<12 hex>` and `veth*`, but not `podman0` and no namespace. Three
    probes (§8.1, §8.2) showed the steps:
    - plain IfState: Docker survives two applies; `podman0` is deleted;
    - links owned, namespaces not: `podman0` stays but goes down. Its
      containers' namespaces are deleted, and their `veth` ends with
      them;
    - links and `^netns-` owned: Docker and Podman keep every link,
      their default and user-defined networks, and a published port
      reached from another machine, across two applies. The kernel
      snapshot is identical, with the nftables firewall on.
    The preset names everything so netif does not depend on IfState's
    built-in list, and so NetworkManager modes mark the links unmanaged.
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
  - **As built.** The pool check reads Docker's `bip` and
    `default-address-pools` and Podman's
    `defaultNetwork.settings.subnets` when they are set through NixOS
    options, else the defaults. Its error names both ranges and the
    options that move a pool.
  *(implemented, round P7a: `netif-containers` — default bridges, user
  networks, a published port each reached from another machine, across
  four reapplies, with containers added and removed in between
  (`NETIF_CONTAINERS_NOOP_OK`, `NETIF_CONTAINERS_CHURN_OK`); eval tests
  `test_containersPreset`, `test_containerPoolOverlapRejected`,
  `test_dockerIpv6SetsForwarding`. Not proven: Docker with IPv6 on in
  a VM; rootless Podman, which creates no host links)*

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
    whose undeclared ports belong to a hypervisor. On such a bridge
    netif never deletes, downs or detaches an undeclared port.
    - **IfState has no per-bridge rule.** Its orphan cleanup looks only
      at interface names (`ignore.ifname`) and namespaces
      (`ignore.netns`); a port's bridge plays no part (`libifstate`
      `_apply`). The probes agree: an undeclared port with an unowned
      name was deleted; a `tap0` port matched by `^tap` kept its
      bridge and its state across two applies.
    - **netif builds the rule itself.** IfState reads `!include` files
      at run time. Before every apply, a netif `ExecStartPre` step lists
      the ports of each guest-ports bridge
      (`/sys/class/net/<bridge>/brif/`), drops the declared members,
      and writes **one regex** that names the rest, for example
      `"^(gp0|tap0)$"`, to `/run/netif/guest-ports.yaml`. With no guest
      port it writes `"^$"`, which matches nothing. Dots in names are
      escaped.
    - **Rendering through the stock NixOS module.** The registry's
      static regexes stay in `parameters.ignore.ifname`, and the list
      gets one more entry, the string
      `"!include /run/netif/guest-ports.yaml"`. This shape is forced by
      the nixpkgs module: it checks the settings against IfState's
      schema at build time and only then turns `'!include …'` strings
      into the YAML tag. The schema wants a list of strings there, so
      the whole list cannot be an include, and an included list inside
      the list would not be flat. One included string is both valid at
      build time and a regex at run time.
    - **Proven through that module** (VM-host probe, §8.3): the
      rendered file had `- !include '/run/netif/guest-ports.yaml'` in
      the list; a guest port with an arbitrary name kept its bridge and
      its guest stayed reachable from another machine across two
      applies; a port on a bridge without `guestPorts` was deleted;
      after the guest left, the next apply shrank the regex.
    - The file must exist before any `ifstatecli` run: with it missing,
      `ifstatecli check` fails. The step runs before every apply, and a
      machine with no guest-ports bridge gets no include at all.
    - A guest's **named** network namespace must be owned as well
      (N8). Hypervisors that use unnamed namespaces need nothing.
    - The `vm` preset's names (`^tap`, `^vnet`) stay: they cover a
      port created between the listing and the apply.
    The stop condition "IfState cannot express it per bridge" is
    answered: IfState cannot, netif can, and no owner decision is
    needed.
  - **Guest addresses are not netif's.** A guest's public address and
    its provider MAC are set in the guest and the hypervisor. netif
    renders the host side only. A routed extra subnet (no MAC needed) is
    a static route on the bridge.
  - **Order of proof:** KubeVirt with Multus first, Incus second.
  - The host's own address moves onto the bridge; `targetHost` stays an
    underlay address (N13), which the bridge address is.
  - **Probe results** (§8.2): a bridge with `link.address` set to its
    member's permanent MAC came up with that MAC, kept it across a
    reapply, and another machine learned that MAC for the bridge's
    address. A bridge over a VLAN link (`eth3.100`) carried traffic to a
    peer on the same VLAN. IfState's generated bridge MAC is stable on
    one machine but differed between two builds of the same VM, so it
    is not a value to write down anywhere.
  - **As built.**
    - The pre-apply step writes `/run/netif/guest-ports.yaml` (the
      regex) and `/run/netif/guest-ports.list` (port and bridge per
      line) atomically. The file is a YAML double-quoted string, so a
      dot in a name is written `\\.`.
    - `clanServices.netif.guestBridges` (internal) carries each
      guest-ports bridge with the member interfaces netif declares.
    - `mac` on a physical link is an eval error that points to
      `match.mac`; `bridge.guestPorts` on a link that is not a bridge
      is an eval error.
  *(implemented, round P7b: `netif-vmhost` — `NETIF_VMHOST_MAC_OK` (the
  bridge has its member's MAC and another machine learns it),
  `NETIF_VMHOST_VLAN_OK`, `NETIF_VMHOST_GUEST_PORTS_OK` (a veth guest
  in a named namespace, a tap device and a port with a dot in its name
  survive reapplies; the guest stays reachable from another machine),
  `NETIF_VMHOST_PLAIN_BRIDGE_OK`, `NETIF_VMHOST_SHRINK_OK`. Guests are
  simulated by hand; KubeVirt with Multus and Incus are not proven
  yet and belong to the contract gate)*

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
  - N4's eval rules (spines, borders, voters in every mode) read the
    mode list from `clanServices.networking.modes`, which every
    configuration has. (Amended in round P4b: it was to be copied into
    `clan.networkFacts`; one source is enough.)
  - It is a separate service because modes are per machine, while netif
    settings are per instance and a machine may be in several.
  - **Mechanism** (eval probe, §8.2):
    - A read-only option cannot differ between a parent and its
      specialisation: a second definition is an eval error. So the
      service sets an internal option, `currentMode` (default
      `default`), and each `specialisation.<name>.configuration` sets
      only that. `mode` is derived from it and stays read-only.
    - Specialisations are defined only when `currentMode` is `default`.
      A specialisation inherits the parent's modules, and NixOS clears
      its own `specialisation` set, so nothing nests.
    - The shared base must follow the mode: today it forces IfState on
      and NetworkManager off for every configuration
      (`lib/ifstate.nix`). In the probe it set
      `networking.ifstate.enable` and
      `networking.networkmanager.enable` from `mode.manager`, and
      rendered IfState settings only in IfState modes. Both directions
      evaluated with every assertion passing: NetworkManager by default
      with IfState modes (U1, U2), and IfState by default with a
      NetworkManager mode (U10).
  - **As built.** The mechanism is `lib/modes.nix`, imported by the
    shared base, so `mode` exists on every machine, with or without
    the service. The service (`services/modes`) only fills
    `clanServices.networking.modes`; it rejects a mode list without
    `default`, a mode name that is not `[a-z][a-z0-9-]*`, and a machine
    in two instances.
  *(implemented, round P4a: `netif-modes`; eval tests
  `modes.mechanism.*`)*

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
  - **Mechanism** (guard probe, §8.2):
    - The guard is an `ExecStartPost` of `ifstate.service`. At build
      time it gets the store path of this generation's rendered IfState
      configuration and the static gateways. At run time it adds every
      default gateway in the main table, so DHCP and RA gateways are
      covered.
    - It asks once a second until the deadline: `arping` for IPv4,
      `ndisc6` for IPv6. It returns as soon as every target answers, so
      a good apply is not slowed down.
    - **Kept.** On success it points `/var/lib/netif/guard/last-good` at
      that store path and registers it as a garbage-collector root. The
      state survives reboots.
    - **Rolled back.** On failure it runs
      `ifstatecli --config <last-good> apply` and exits non-zero. The
      unit fails, and `switch-to-configuration` exits 4, so the deploy
      reports the failure.
  - **After a rollback** the kernel has the last-good network, while
    `/etc/ifstate/ifstate.yaml` and the running generation still name
    the bad one. A unit restart or a reboot tries the bad configuration
    again and rolls back again (probe). The fix is a corrected
    generation.
  - **Order.** The guard runs before N15's missing-NIC check, so a
    change that loses both a NIC and the gateway is still rolled back.
  - **Not settled yet** (phase P8): runtime `!include` secrets that a
    rolled-back configuration names but the new generation no longer
    provides; the guard on a machine whose only default route comes
    from Wi-Fi (the guard is off there by default).
  - **As built** (`services/netif/guard.nix`):
    - options `clanServices.netif.guard.{enable, timeout, targets}`;
      `enable` defaults to true unless `services.xserver.enable`,
      `services.displayManager.enable` or `programs.gamescope.enable`
      is set;
    - the state is `/var/lib/netif/guard/last-good`, with the
      garbage-collector root `/nix/var/nix/gcroots/netif-guard-last-good`;
    - a DHCPv4 link that owns the default is waited for: no default
      route on it before the deadline is a failure;
    - **the guard is `netif-guard.service`**, a oneshot unit ordered
      after `ifstate.service` and every `netif-dhcpcd-*` unit. This
      replaces the probed mechanism above (an `ExecStartPost`), which
      deadlocked on a DHCP link: dhcpcd starts only after
      `ifstate.service` is done. `ifstate.service` restarts the guard
      after each apply, and the guard's `restartTriggers` name the
      rendered IfState configuration, so `switch-to-configuration`
      waits for the verdict and exits non-zero on a rollback;
    - **the failed unit is `netif-guard.service`**, not
      `ifstate.service`. N15's missing-NIC check fails
      `ifstate.service` on its own; the guard still runs then, and
      does not record a configuration as good when the apply failed;
    - one deadline (`timeout`, 30 seconds) covers all targets.
  - **Still not settled:** a rolled-back configuration that names a
    runtime `!include` secret the new generation no longer provides
    (the rollback then fails and says so); a machine whose only
    default comes from Wi-Fi.
  *(implemented, round P8: `netif-guard` — `NETIF_GUARD_BOOT_OK` (the
  gateway drops pings and still passes), `NETIF_GUARD_ROLLBACK_OK`
  (the switch exits non-zero, the old address and default are back, a
  restart rolls back again), `NETIF_GUARD_KEPT_OK`,
  `NETIF_GUARD_FIRST_BOOT_OK`; `netif-dhcp` runs with the guard on, so
  the learned DHCP and RA gateways are checked on every reapply there)*

- **N26 Cloud NICs.**
  - `links.<n>.match.path` finds a physical NIC by its udev path
    (`ID_PATH`, for example `pci-0000:00:03.0`). A cloud NIC's MAC is
    unknown before the VM exists; its slot is stable.
  - **Rendering: a udev `.link` file, not IfState `identify`.** The
    probe (§8.2) showed why:
    - IfState's `identify.parent_dev_name` is the PCI address only for
      a NIC that sits on the PCI bus directly (`ifstatecli identify`
      gave `0000:00:10.0` for an e1000). IfState found and renamed
      both a PCI NIC and a virtio NIC by it (§8.3), so the mechanism
      works; what fails is the stability of the virtio name.
    - A virtio NIC's parent is `virtio<N>`. `N` counts every virtio
      device in probe order: disks, the random-number device, consoles
      and file shares too. In the probe VM the NICs were `virtio0`,
      `virtio3`–`virtio6` and `virtio13`. Adding a disk renumbers them.
      Hetzner Cloud, GCP and Proxmox NICs are virtio.
    - udev's `ID_PATH` named the PCI slot for every NIC, virtio
      included. A `.link` file with `Path=pci-0000:00:11.0` and
      `Name=cloud1` renamed the NIC before IfState ran, with
      `net.ifnames=0` set, and IfState configured `cloud1` by name.
    So netif renders `systemd.network.links` for `match.path` and
    declares the link to IfState by its logical name. `.link` files
    belong to udev and work with systemd-networkd off; D61 stays as it
    is (no networkd, no netdevs, no scripted units).
  - `match.mac` keeps IfState `identify.perm_address` (N15).
  - A physical link sets exactly one of `interface`, `match.mac` and
    `match.path`. With either matcher the NIC ends up with the logical
    link name (at most 15 characters).
  - **Not proven yet:** AWS (ENA, on the PCI bus) and Azure
    (`hv_netvsc`, on VMBus) NICs. Their `ID_PATH` values are recorded
    in the provider notes when a machine exists.
  - Eval rejects cloud-init's network configuration next to netif
    (`services.cloud-init.network.enable`): it would be a second writer.
  - Provider facts netif relies on are recorded per provider in the
    human docs as they are proven: gateway outside the subnet
    (`gateway.onLink`), MTU below 1500 (`pathMtu`, N17), a second NIC
    without a default (N21).
  *(probe-verified 2026-11-16; confirmed by the owner 2026-11-17;
  implemented, round P3b-5: `netif-match` `NETIF_MATCH_PATH_OK`; eval
  tests `test_matchPath*`, `test_cloudInitNetworkRejected`)*

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

- **N30 Networking packages come from pkgs: the upstream release
  first, a patch second.**
  - netif runs on the packages of the `org-pkgs` overlay
    `overlays.ifstate`: IfState 2.5.1 (`pkgs.ifstate`) and dhcpcd
    10.5.2 (`pkgs.dhcpcd_latest`). That overlay is the host-networking
    package set.
  - When a package netif depends on is broken or too old in nixpkgs,
    the fix lives in external-systems/pkgs, in that overlay. It is
    never fixed in this repo, in home, or in a machine configuration.
  - **Order of preference:**
    1. the newest upstream release that has the fix, unpatched, on the
       nixpkgs build recipe;
    2. a patch set of upstream commits, only when no release works for
       the consumer.
  - **A package the stock NixOS modules also use is never swapped
    under them without a test of that module.** The newer release
    gets its own attribute (`<name>_latest`) and netif names it. The
    plain attribute changes only when the module's own unit is proven
    with it. dhcpcd is the first case: `dhcpcd_latest` for netif,
    `dhcpcd` (10.3.2 with the two commits) for `networking.useDHCP`.
  - Both carry a version guard that drops the override once nixpkgs
    has caught up. An override that swaps the source also empties
    `patches`: a fix nixpkgs backports to its older version does not
    apply to the newer source.
  - Order of work: probe the fix here with an overlay in a throwaway
    test, land it in pkgs, then `nix flake update org-pkgs` and
    `sync-locks` here (AGENTS.md tool loop). The spec names the pkgs
    change and the upstream reference.
  - The shared base asserts what it needs from a package, as it does
    for IfState (`>= 2.5`). For dhcpcd: netif's units run
    `pkgs.dhcpcd_latest`, and netif asserts it is 10.5.0 or newer.
  - **Owner decision (2026-11-17):** machines on the stock NixOS
    `dhcpcd.service` wait for nixpkgs to ship 10.5. No unit change in
    the modules repo. Every machine moves to netif once it is stable
    (N14), which ends the question.
  - History: dhcpcd 10.3.2 with two upstream commits (pkgs PR 42,
    2026-11-16); `dhcpcd_latest`, upstream 10.5.2, added beside it
    (pkgs PR 43, 2026-11-17).
  *(implemented: netif runs `pkgs.dhcpcd_latest` 10.5.2 and asserts
  the version; VM-proven by `netif-dhcp` `NETIF_DHCP_UNIT_OK`)*

- **N31 dhcpcd is a supervised unit per link (was H1).**
  - One unit per DHCP link, `netif-dhcpcd-<interface>.service`, runs
    `dhcpcd -B` in the foreground. No IfState hook starts dhcpcd.
  - It is bound to the link's device unit, so it stops when the link
    goes away. It is started at boot, by udev when the link appears
    later (`SYSTEMD_WANTS`), and by `ifstate.service` after each apply,
    which covers a link IfState created or renamed.
  - `Restart=on-failure`. After every stop, crash or not, the unit
    flushes the link's dynamic IPv4 addresses and its lease files: a
    dhcpcd that finds its address already on the link does not remove
    it on exit (seen in `netif-dhcp`).
  - Sandbox: capabilities limited to `NET_ADMIN`, `NET_RAW`,
    `NET_BIND_SERVICE` and `CHOWN`; `ProtectSystem=strict` with three
    writable paths; no new privileges; the `@system-service` call
    filter (it includes `chown`, which dhcpcd 10.5 needs).
  - A link that stops being a DHCP link loses its unit on the next
    generation switch; systemd stops it and the lease goes.
  *(implemented; VM-proven by `netif-dhcp` `NETIF_DHCP_UNIT_OK`,
  `NETIF_DHCP_SUPERVISED_OK`)*

- **N32 "Online" on a DHCP link means an address (was H2).**
  - `netif-online.service` is ordered before `network-online.target`.
    It waits for a global address of each requested family on every
    DHCP link with `requiredForOnline`.
  - `links.<n>.requiredForOnline`: null means true for a DHCP link.
    Static links never delay "online".
  - After `clanServices.netif.onlineTimeout` seconds (default 30) it
    logs a warning and lets the machine count as online. A pulled
    cable never blocks a boot.
  *(implemented; VM-proven by `netif-dhcp` `NETIF_DHCP_ONLINE_OK`)*

- **N33 A stable DHCP identity (was H3).**
  - Each link's IAID is derived from its instance and link name, not
    from its MAC address. A bridge that takes the uplink's MAC (N23)
    or a replaced NIC keeps the identity.
  - The DUID stays in `/var/lib/dhcpcd/duid`. Setting it from a clan
    var, so a reinstall keeps it, belongs to the router phase P5.
  *(IAID implemented, eval-tested; DUID planned, phase P5)*

- **N34 DHCPv4 retries are capped (was H4).** dhcpcd runs with
  `backoff_cutoff` 16 seconds (`clanServices.netif.dhcpBackoffCutoff`),
  not the default 64.
  *(implemented, eval-tested; no VM timing test)*

- **N35 A version envelope (was H8).** The base warns at evaluation
  when IfState or dhcpcd is a newer minor than the one the suites last
  passed with (IfState 2.5, dhcpcd 10.5). The warning names the rerun.
  iwd and systemd join the list in phase P2.
  *(implemented)*

- **N36 A wider lockout guard (was H5).** N25's guard also checks
  optional `guard.targets` and runs after firewall changes.
  - A target is `{ address; port?; interface? }`: with `port` a TCP
    connection must open (the deployer's SSH port is the useful one);
    with `interface` a layer-2 answer on that link; with neither a
    ping.
  - After an apply a silent target counts like a silent gateway: roll
    back and fail.
  - After a firewall reload (`nftables.service`) only the targets are
    checked: gateways answer ARP whatever the rules say. A failure
    fails the reload and is logged; netif does not own the firewall
    and rolls nothing back.
  - **Limit.** The check goes outwards. It does not prove that the
    machine still accepts an incoming connection.
  *(implemented, round P8: `netif-guard` `NETIF_GUARD_TARGET_OK`,
  `NETIF_GUARD_FIREWALL_OK`)*

- **N37 Guest ports are compared after each apply (was H6).** Name
  patterns stay the first protection. After the apply netif compares
  each guest-ports bridge's members with the list it computed and
  fails the unit when one is gone.
  - The message names the port and its bridge, and says that a guest
    that stopped during the apply produces the same failure.
  *(implemented, round P7b: `netif-vmhost` `NETIF_VMHOST_CHECK_OK` — a
  port removed between the listing and the check fails the unit; the
  next apply succeeds)*

- **N38 A drift watch (was H7).** A timer runs the dry run and fails
  `netif-drift.service` when IfState would change something. It never
  applies.
  - Interval: `clanServices.netif.driftInterval` (default `1h`; first
    run 15 minutes after boot, up to 5 minutes of random delay).
  - A run during an apply (`ifstate.service` activating) is skipped.
  - The failed unit is the signal (`systemctl --failed`,
    `netif-status`); its journal lists the proposed changes and says
    how to reapply.
  *(implemented: `netif` `NETIF_TOOLS_OK` — a foreign address makes
  the unit fail, the address stays, a reapply clears it)*

- **N39 DNS from router advertisements is not read (was H9).**
  - The kernel ignores the RDNSS option; reading it needs a daemon.
    `rdnssd` was not adopted and not probed: it merges the servers of
    all links into one resolv.conf-style file with no interface names,
    so it cannot feed N9's per-link files without a wrapper that
    listens to the kernel itself.
  - **Rule.** netif warns at evaluation when a machine takes its IPv6
    default from RAs and has no DNS source at all: no link sets
    `nameservers`, none uses DHCP, and `networking.nameservers` is
    empty. The warning names the fix.
  - Open again only when a real network offers DNS through RAs alone.
  *(implemented: eval test `test_raOnlyWithoutDnsWarned`)*

- **N40 Probes live in the repo (was H10).** Probes whose findings no
  suite asserts yet are kept under `services/netif/tests/probes/`,
  outside `checks` and `vmTests`. The DNS and dhcpcd probes are
  retired: `netif-dhcp` asserts what they showed.
  - They are exposed as `legacyPackages.<system>.netifProbes.<name>`
    (`nix build .#netifProbes.<name>`), so they follow the repo's nixpkgs and
    linters. `services/netif/tests/probes/README.md` names the suite
    that takes each one over; the probe is deleted in that change.
  *(implemented, and now empty: every probe is deleted with the suite
  that took it over, the last one, `wifi`, in round P2-wifi. The
  `netifProbes` output and the directory are removed; a new probe
  brings them back)*

- **N41 `netif-status` (was H11).** One read-only command per machine.
  - Per netif link: instance and link name, interface, state, zone,
    trust, the dhcpcd unit's state, global addresses and DNS servers.
    A declared link that does not exist shows as `MISSING`.
  - Per machine: the result and time of the last apply, the drift
    watch's verdict, and each family's default routes with metric.
  - `netif-status --json` gives the same as one JSON object.
  *(implemented: `netif` `NETIF_TOOLS_OK`)*

- **N42 Errors that say what to do, and `netif-preview` (was H12).**
  Every netif eval error names the instance, the link, the decision
  and the option. The old ones were swept: each now ends with what to
  change.
  - **`netif-preview [system]`** prints what an apply would change and
    changes nothing. Without an argument it reads the running
    configuration; with a built system (`./result`, a profile
    generation) it reads that system's IfState config, so a change can
    be read before it is switched to. Exit status: 0 nothing, 2
    changes, 1 the dry run failed. The drift watch runs the same code.
  - It reads `ifstatecli check`'s output (its exit status is always 0),
    with the rule the suites' no-op helper uses, pinned to IfState 2.5.
    N35's version warning is the reminder to recheck it.
  *(implemented: `netif` `NETIF_TOOLS_OK` previews another generation;
  not covered: firewall, DHCP and DNS changes, which IfState does not
  own)*

- **N43 A MAC override on a physical link.** `links.<n>.mac` is applied
  only to non-physical links today. A WAN link that replaces an ISP's
  gateway must present that gateway's MAC, while `match.mac` still finds
  the NIC by its permanent MAC (N15).
  - Probe PR5 showed it with `extraSettings.link.address`
    (`specs/gateway.md` §10.4): IfState sets the MAC before dhcpcd
    starts, the DHCP server sees it, and it holds across an apply and a
    reboot. The change is to apply `mac` to physical links too and to
    drop the assertion that forbids it.
  - dhcpcd's DUID does not follow the override: it came from another
    link's MAC. N33 owns the DHCP identity.
  *(probe-verified, PR5; the option change is planned,
  `specs/gateway.md` S1)*

- **N44 A priority-tagged WAN (VLAN 0).** Some ISPs send and expect
  frames tagged with VLAN 0. netif renders it: a VLAN link with
  `vlan.id = 0` on the WAN port (amended 2026-11-20 after PR5).
  - IfState accepts id 0, the child is named `<parent>.0`, DHCP runs
    over it and the frames carry the tag. Without the child no frame
    passed in either direction (`specs/gateway.md` §10.4).
  - The child gets a generated MAC, so it needs `mac` as well (N43).
  - Open: the 802.1p priority bits (IfState's egress map is not
    probed), and whether an optical module strips or adds the tag
    itself. The second is hardware (`specs/gateway.md` §8).
  *(probe-verified, PR5, for the tag and DHCP; a suite is planned,
  `specs/gateway.md` S1)*

- **N45 An IPv6-only link is first-class.** A machine with no IPv4
  address on any NIC (U13): a static or learned IPv6 address, an on-link
  link-local gateway (`gateway.onLink`), static nameservers, and the
  guard (N25) and "online" working with IPv6 alone. RA-only DNS stays
  uncovered (N39). *(planned; suite `netif-v6only`,
  `specs/gateway.md` S1)*


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

## 5. What exists today (2026-11-16, after the proof round)

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
- **Implemented and VM-proven in P1** (suite `netif-registry`
  `NETIF_REGISTRY_OK`): the ownership registry and its presets (N6), the
  ownership, Wi-Fi and unowned-daemon eval errors, IfState before
  `network-online.target` with session units after it (N7), and the N11
  range check and warning.
- **Implemented and VM-proven in P3b slice 1** (suite `netif-dhcp`
  `NETIF_DHCP_OK`, dhcpcd 10.5.2, IfState 2.5.1): supervised dhcpcd
  units with netif's config (N16, N31), `ipv4only`, prefix delegation,
  per-link DNS through resolved (N9), "online" (N32), carrier-change
  recovery, the no-op helper (§7).
- **Implemented and VM-proven in P3a** (suite `netif-match`
  `NETIF_MATCH_OK`): `match.mac`, the loud missing-NIC check and the
  checked `extraSettings` passthrough (N15).
- **Drift against this contract** (fixed by the phases in §9):
  - iwd's settings for IfState modes and its route metric are not
    rendered yet, and hot-plugged wired links have no owner in IfState
    modes (N5, N12, N18; rest of phase P2);
  - `links.<n>.nameservers` on a link sets servers only; there is no
    static search-domain option (N9).
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
- **A test node that sends RAs forwards IPv6**
  (`net.ipv6.conf.all.forwarding = 1`). A node that advertises itself
  as a router but does not forward answers neighbour solicitations
  without the router flag, and Linux hosts then delete it as default
  router a few seconds after they first use it. The symptom is an RA
  default route that appears and vanishes, depending on timing.
  `netif-dhcp`'s server node forwards since P3b slice 1.
- **Timing-sensitive findings are confirmed alone.** A probe result
  that could depend on load is rerun as the only build on euc-hel-0
  before it changes a design. The test script records the builder's
  load average (`/proc/loadavg`, read by the driver) at start and end.
- **A "broken" finding needs a control.** Before a probe result of
  the form "X does not work" enters this file, one run shows the
  fixture itself works: the same fixture with a known-good client or
  server, or with the suspect part removed. Three round-proof findings
  were fixture faults that a control would have caught (§11).
- **"Changes nothing" (invariant 5)** means both:
  1. a kernel-state snapshot is identical before and after the reapply:
     `ip -j` links, addresses, routes in every table, rules, and
     `ip netns list`, with counters, lifetimes and timestamps stripped;
  2. `ifstatecli check` reports no change for any object. Its exit status
     is not a signal: it exits 0 even when it proposes changes.
  One shared helper, `tests/ifstate-noop.nix`
  (`assert_ifstate_noop(machine)`), does both. `netif`, `netif-dhcp`,
  `netif-match` and `netif-registry` use it. It parses the `check`
  output of IfState 2.5.1: an indented `<object>  <operation>` line
  per object, where `ok`, `= <value>` and `orphan` mean unchanged
  (`libifstate/log.py`). An undeclared physical NIC that is still up
  also prints `orphan`; the kernel snapshot catches that case.
- **Live reconfiguration** is proven by switching NixOS generations
  (`switch-to-configuration test` into a specialisation that changes
  netif settings, then back), not by applying hand-edited YAML. The
  `netif` suite moves to that in P3b. This is a test device only; it
  does not make live mode switching (N3) supported.
- Planned suites, each with a final marker:

  | Suite | Proves | Phase |
  |---|---|---|
  | `netif-registry` | Tailscale and an iwd Wi-Fi link survive two IfState applies; foreign netns kept; ordering | P1 |
  | `netif-modes` | gaming (NetworkManager + iwd + Tailscale) → developer (IfState + iwd + Tailscale) → gaming by reboot; known networks shared both ways | P2, P4 |
  | `netif-wifi` | ad hoc join, roaming between two APs, DNS from DHCP | P2 |
  | `netif-hotplug` | dock ethernet hot-plug in an IfState mode | P2 |
  | `netif-router` | WAN DHCPv4 + DHCPv6-PD hook, kea, radvd, NAT, reapply no-op, prefix change, reboot | P5 |
  | `netif-match` | NIC found by permanent MAC under a different kernel name; missing NIC fails loudly | P3a (green) |
  | `netif-dhcp` (extended) | dhcpcd per-link config; DHCPv6 and a delegated prefix assigned to another instance's link; observed route protocols; per-link DNS in resolved across reapply, link down/up, a resolved restart and a lease renewal (N9); both DHCP protocols and the RA default back after a real carrier loss and after five `ip link set down`/`up` cycles, with no `eloop_event_add` line in the journal (N16); `addr_gen_mode` 0 on a DHCPv4-only link (N16); a forwarding RA server (§7); no IPv4 link-local; metric 100 defaults; an RA default on a forwarding link surviving two RA lifetimes; the no-op helper | P3b |
  | `netif` (extended) | live reconfiguration by generation switch; untrusted default with an explicitly trusted link; two DHCP links with one default (N21); the no-op helper | P3b |
  | `netif-match` (extended) | a virtio NIC found by udev path and renamed before IfState runs (N26) | P3b |
  | `netif-containers` | Docker and rootful Podman keep links, namespaces, default and user-defined networks and a published port reached from another machine across two applies, in an IfState mode; pool-overlap eval error | P7 |
  | `netif-vmhost` | bridge sends from the uplink's MAC; a bridge over a VLAN; guest ports with arbitrary names survive two applies and stay reachable | P7 |
  | `netif-guard` | a change that loses the gateway is rolled back and the unit fails; a good change is kept; a gateway that ignores ping passes; no previous configuration fails loudly | P8 |

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

### 8.2 Probes of 2026-11-16, proof round (euc-hel-0)

Versions: IfState 2.5.1, dhcpcd 10.3.2, systemd 262, iwd 3.12, kea
3.2.1, Docker 29.9.1, Podman 6.1.4 (netavark), kernel 6.18.59.
Throwaway tests under `.baton-pass/netif-probes/` (`dns.nix`,
`vmhost.nix`, `containers2.nix`, `guard.nix`, `wifi.nix`,
`modes-eval.nix`; run with `run-any.nix --argstr probe <name>`). They
print `FACT` lines and do not assert. Plain IfState with the listed
ignores, not the clanServices base.

- **DNS probe** (`NETIF_DNS_PROBE_DONE`, three runs). An ISP node (kea
  DHCPv4 on two networks, kea DHCPv6, radvd) and a router with a DHCP
  WAN (`ia_na`), a static LAN and a second DHCP link (`nogateway`,
  `accept_ra_defrtr = 0`), plus the prototype DNS unit of N9.

  | Question | Result |
  |---|---|
  | DNS on the right link after boot: DHCPv4, DHCPv6, static, second DHCP link; search domains | yes |
  | After an IfState reapply | yes |
  | Static link down and up, once and ten times fast | yes, DNS back; none while down |
  | After a systemd-resolved restart | yes |
  | Lease renewed with changed servers (60 s lease) | yes: new servers set, old removed, DHCPv6 server kept |
  | DNS from an RA (RDNSS) | **no**: nothing reads it |
  | Second DHCP link with `nogateway` | lease and classless route kept, no default |
  | Second link with `accept_ra_defrtr = 0` | SLAAC address and prefix route kept, no default |
  | Defaults per family | one each, on the first link, metric 100 (`proto dhcp`, `proto ra`) |
  | `noipv4ll` | no `169.254` address or route |
  | Stock dhcpcd hooks with `script` set | none ran |
  | dhcpcd pidfile for one link | `/run/dhcpcd/<link>.pid` |
  | Reapply with everything running | no change |
  | Real carrier loss and return (QEMU `set_link`) | **DHCPv4 lost**: no lease within 75 s (run 3; run 2's journal shows the same error and an expired lease). DHCPv6 and the RA default came back |
  | `ip link set down` / `up` on the DHCP link | **one protocol lost** (DHCPv6 twice, DHCPv4 once); the RA default did not return within 30 s |
  | dhcpcd journal after either | `eloop_event_add: No such file or directory` |
  | `addr_gen_mode` of the DHCPv6 link | 1: dhcpcd adds the link-local address itself |
  | One router solicitation by hand after the down/up | RA default back at once |
  | Kill that link's dhcpcd, rerun IfState | both protocols and their DNS back |
  | Same probe with upstream dhcpcd 10.5.2, unpatched | no `eloop` error and DHCPv4 back after carrier loss; DHCPv6 got no lease at all, cause unknown |

- **VM-host probe** (`NETIF_VMHOST_PROBE_DONE`). A host with a bridge
  over a NIC, a bridge over a VLAN, an e1000 and a virtio NIC on fixed
  PCI slots, and a peer.

  | Question | Result |
  |---|---|
  | Bridge with `link.address` = member's permanent MAC | bridge has that MAC, also after a reapply; the peer learned it |
  | Bridge over a VLAN link | peer on the VLAN reached it |
  | `tap0` port with `^tap` ignored, two applies | port, bridge membership and state kept |
  | Port with an unowned name | deleted |
  | Named namespace not in `ignore.netns`, no `namespaces` key | deleted |
  | Run-time `!include` for `ignore.ifname` listing the bridge's ports | port kept, guest reachable from the peer, two applies |
  | Include file missing | `ifstatecli check` fails |
  | `ifstatecli identify`, virtio NIC | `parent_dev_name: virtio<N>`, `parent_dev_bus_name: virtio` |
  | `ifstatecli identify`, e1000 | `parent_dev_name: '0000:00:10.0'`, bus `pci` |
  | virtio numbering | NICs `virtio0`, `3`–`6`, `13`; rng, disk, input, file shares and console in between |
  | udev `ID_PATH` | `pci-0000:00:<slot>.0` for every NIC |
  | `.link` file `Path=pci-0000:00:11.0`, `Name=cloud1` | renamed before IfState ran, with `net.ifnames=0`; IfState configured it |
  | IfState rename by `parent_dev_name` | not proven (probe YAML error) |

- **Containers probe 2** (`NETIF_CONTAINERS2_PROBE_DONE`, two runs).
  Docker and rootful Podman, each with a container on the default
  bridge and one on a user-defined network, published ports, nftables
  firewall on, a peer machine.

  | Ignored | Result after two applies |
  |---|---|
  | links `^docker`, `^br-`, `^podman`, `^veth` | Docker intact. Podman: bridges kept but down, both `netns-<uuid>` namespaces and their `veth` ends deleted, containers and published port dead |
  | the same plus namespaces `^netns-` | kernel snapshot identical; Docker and Podman connectivity and both published ports from the peer intact; a new Podman container worked |

- **Guard probe** (`NETIF_GUARD_PROBE_DONE`). A host with the prototype
  guard of N25 (8 s deadline) and a gateway that ignores ping.

  | Question | Result |
  |---|---|
  | Gateway: ping, `arping`, `ndisc6` | no, yes, yes |
  | Boot | gateways answered; `last-good` recorded; unit succeeded |
  | Generation switch to an address in another subnet | rolled back in 10 s: old address and default route back, unit failed, `switch-to-configuration` exit 4, `last-good` unchanged |
  | Unit restart afterwards | fails and rolls back again |
  | Generation switch that adds an address | kept; `last-good` updated |
  | Bad change with no `last-good` | unit fails, bad configuration stays |

- **Wi-Fi probe** (`NETIF_WIFI_PROBE_DONE`). One machine, a simulated
  access point with DHCPv4 and RAs, iwd with
  `RoutePriorityOffset = 300`, IfState wired defaults at `preference`
  100.

  | Question | Result |
  |---|---|
  | iwd IPv4 default | `proto dhcp`, metric 307 |
  | iwd IPv6 default | `proto ra`, metric 307; `accept_ra` 0 on the link |
  | Route lookup, both up | wired, both families |
  | Route lookup, wired down | Wi-Fi, both families |
  | Two applies | defaults unchanged |

- **Modes eval probe** (`modes-eval.nix`, evaluated locally). The
  prototype of N24 with a base that follows `mode.manager`.

  | Machine | Result |
  |---|---|
  | NetworkManager default, IfState `developer` and `kubernetes` | one manager each; a module gated on `mode.name` was on in `kubernetes` only; no nested specialisations; all assertions pass; the system derivation evaluates |
  | IfState default, NetworkManager `gaming` | the same, the other way round |
  | No modes | one mode `default`, IfState |

- **Probe-writing traps:** the test driver runs commands with `errexit`,
  so `a; b` stops at a failing `a`; `dhcpcd` is not on the VM's `PATH`
  (use the store path); an unquoted PCI address in hand-made YAML is
  read as a number; a peer keeps a stale neighbour entry when a guest
  address moves to a new MAC.

### 8.3 Probes of 2026-11-16, solo runs (euc-hel-0)

Each run was the only build on the builder; the test recorded the
builder's load average, 0.07–0.33 throughout. Same probes as §8.2
(`dns.nix`, `vmhost.nix`), with `run-dhcpcd.nix --argstr variant
stock|patched|new` choosing dhcpcd: nixpkgs 10.3.2, 10.3.2 with the two
upstream commits (the exact `org-pkgs` package), upstream 10.5.2.

- **Carrier changes on a DHCPv4 + DHCPv6 link.** "Back" means the
  lease's DNS was on the link in resolved within 60 s.

  | dhcpcd | Run | Real carrier loss | Five down/up cycles: DHCPv4 back, DHCPv6 back | `eloop_event_add` errors |
  |---|---|---|---|---|
  | 10.3.2 stock | solo 1 | both back | one cycle only: DHCPv4 lost | after every change |
  | 10.3.2 stock | solo 2 | DHCPv4 lost | one cycle only: DHCPv4 lost | after every change |
  | 10.3.2 stock | loop | DHCPv4 lost | 0 of 5, 1 of 5 | 2–5 per cycle |
  | 10.3.2 + two commits | single | both back | one cycle: both back | none |
  | 10.3.2 + two commits (pkgs) | loop | both back | 5 of 5, 5 of 5 | none |
  | 10.3.2 + two commits (pkgs) | timeline, three runs | both back | 5 of 5, 5 of 5 each | none |
  | 10.5.2 | loop | both back | 5 of 5, 5 of 5 | none |

- **Other dhcpcd facts.**

  | Question | Result |
  |---|---|
  | `addr_gen_mode` on a link with DHCPv6 | 1 |
  | `addr_gen_mode` on a DHCPv4-only link, IPv6 enabled in dhcpcd | 1 |
  | The same link with `ipv4only` | 0; lease, classless route and DNS unchanged |
  | `addr_gen_mode` on a static link | 0 |
  | Router solicitation from the DHCPv6 link after down/up | seen on the wire in 30 of 30 cycles |
  | RA default back after down/up | within 2 s, 30 of 30 cycles |
  | `dhcpcd -x <link>` stops that link's daemon | yes |
  | Lease renewal with changed DNS servers (60 s lease) | new servers set, old removed, in every run |

- **The vanishing RA default.** A route monitor, a packet capture and a
  one-second sample of the default route ran across a down/up.

  | Observation | Result |
  |---|---|
  | RAs seen | router lifetime 1800 s every time |
  | Default with dhcpcd running | once kept for 40 s; once deleted 10.7 s after it was added, back with the next RA |
  | Default with dhcpcd stopped and kernel link-local | deleted 10.6 s after it was added |
  | dhcpcd journal at the deletion | nothing |
  | ISP node | radvd on, IPv6 forwarding off |
  | With forwarding on at the ISP node | default kept for the whole 40 s, with dhcpcd and without; the ISP's neighbour advertisements carry the router flag; the final reapply changed nothing |

- **VM-host probe, second run** (`NETIF_VMHOST_PROBE_DONE`).

  | Question | Result |
  |---|---|
  | `ignore.ifname` list with one `"!include /run/netif/guest-ports.yaml"` entry through the NixOS module | builds; rendered as `- !include '…'` |
  | Guest-port file at boot, with a guest, after the guest left | a regex of the current ports each time |
  | Guest port with an arbitrary name, two applies | kept, bridge membership kept, guest reachable from the peer |
  | Port on a bridge without guest ports | deleted |
  | Include file missing | `ifstatecli check` fails |
  | IfState rename by `parent_dev_name`, PCI NIC and virtio NIC | both renamed and configured |

- **Corrections to §8.2.**
  - "Upstream 10.5.2: DHCPv6 got no lease": the probe's kea-dhcp6 had
    failed to open its socket (`DHCPSRV_NO_SOCKETS_OPEN`). The fixture
    now retries, and 10.5.2 passed.
  - "The RA default did not return within 30 s", "one solicitation by
    hand brought it back": see the table above. The kernel solicits by
    itself.
  - "`dhcpcd -x`" and renewal commands were never run in §8.2: `dhcpcd`
    was not on the VM's `PATH`.
- **Source and upstream references.** dhcpcd 10.3.2 `src/ipv6.c`
  `ipv6_freeaddr` (close before `eloop_event_delete`), `src/eloop.c`
  (`EPOLL_CTL_MOD` for a known descriptor), `src/if-linux.c`
  `if_setup_inet6`; upstream issue #596 and PR #611 (commits `3375f52`,
  `cf232b9`); nixpkgs builds dhcpcd with `--disable-privsep` and no
  patches; the nixpkgs IfState module checks the schema before it
  writes `!include` tags.

### 8.4 Probes of 2026-11-17, upstream dhcpcd 10.5.2 (euc-hel-0)

Each run was the only build on the builder (load average 0.03–0.45 at
start). The package under test is the exact `pkgs.dhcpcd_latest` of
pkgs PR 43, applied to stock nixpkgs. Probes: `dns.nix` as in §8.3,
and `stock-module.nix`, a client with only `networking.interfaces.
eth1.useDHCP` (the stock NixOS `dhcpcd.service`, no netif, no IfState)
against a dnsmasq server that forwards IPv6.

- **netif's way of running dhcpcd, 10.5.2** (`NETIF_DNS_PROBE_DONE`).

  | Question | Result |
  |---|---|
  | DHCPv4, DHCPv6 and static DNS at boot, after a reapply, after a renewal with changed servers, after a resolved restart | all correct |
  | Real carrier loss | DHCPv4, DHCPv6, their DNS and the RA default back; no `eloop_event_add` |
  | Five down/up cycles | DHCPv4 5 of 5, DHCPv6 5 of 5, RA default 5 of 5, no error |
  | `dhcpcd -x <link>` as root, then a restart by the hook | stops; both protocols back |
  | Stock hooks, IPv4 link-local, classless route | none ran; none; kept |
  | Final reapply | no change |
  | Same run with `ipv4only` on the DHCPv4-only link | `addr_gen_mode` 0 there; lease, route and DNS unchanged; five cycles 5 of 5 for both protocols |

- **The stock NixOS `dhcpcd.service`.**

  | dhcpcd | Unit | Result |
  |---|---|---|
  | 10.5.2 | stock | does not start: `dhcpcd_fork_cb: dhcpcd manager hungup`, exit 1, restart loop; no lease |
  | 10.5.2 | stock plus `SystemCallFilter = ["@chown"]` (nixpkgs PR 562813) | starts; lease at boot, after five down/up cycles (5 of 5), a real carrier loss, a renewal, a unit restart and a reboot |
  | 10.3.2 with the two commits (`pkgs.dhcpcd`) | stock | the same passes: the control |

- **nixpkgs' own dhcpcd tests** (`dhcpcd.passthru.tests`) do not test
  an overlaid package: their nodes use the stock one, and the results
  came from the binary cache. They are not evidence here.
- **Upstream references.** dhcpcd release notes 10.5.0, 10.5.1 and
  10.5.2 (PRs 593, 611, 649, 665, 672, 680, 701, 705); nixpkgs PR
  555756 (the automatic bump, closed: its tests failed) and PR 562813
  (bump plus `@chown`, open on `staging-nixos` on 2026-11-14).

## 9. Delivery plan

Each phase amends this file first, then code, then suites. Order: P3b,
P7, P2, P4, P8, P5, then the contract gate; the field gate follows the
hardware; N28 and N29 come after. A verification gate that fails, or a
fix that needs a new ownership model, stops the phase for an owner
decision. Phase numbers are labels, not the order.

| Phase | Work | Done when |
|---|---|---|
| P0 | This contract (docs only) | merged |
| P1 | Ownership registry + presets (iwd, tailscale, cilium, vm), N7 ordering, N11 checks, foreign-daemon-without-preset eval error | `netif-registry` green — **done** |
| P3a | `match.mac`, missing NIC fails loudly, checked `extraSettings` passthrough (N15) | `netif-match` green; existing suites green — **done** |
| P3b | **Done: all five slices** (rounds P3b-1, P3b-3, P3b-4, P3b-5). The tools of N38, N41 and N42 follow as their own slice. Five slices, each merged with its own green suite. **1 dhcpcd:** bump `org-pkgs` and `sync-locks`, run netif's hook with `pkgs.dhcpcd_latest` (10.5.2) and assert `>= 10.5.0` in the base (N30), per-link config and PD (N16), `ipv4only` on DHCPv4-only links, a forwarding RA server and the carrier-change assertions in `netif-dhcp`, anchored ignores, the no-op helper. **2 DNS:** the netif DNS unit as probed (N9). **3 routes:** default-route metrics (N18), `defaultRoute` and RA in the one-default rule (N21), live reconfiguration by generation switch. **4 firewall:** untrusted default (N19), zone seam (N10). **5 the rest:** `pathMtu` and its consumers (N17), `match.path` and the cloud-init check (N26). Brief: `documentation/docs/plans/phase-4-netif-underlay/prompt.md` | `netif-dhcp`, `netif` and `netif-match` extended (§7); every existing suite green |
| P7 | **Done** (rounds P7a, P7b): `containers` preset (N22); VM hosts: bridge MAC, VLAN and bond members, guest ports (N23) | `netif-containers`, `netif-vmhost` green |
| P2 | **Renderer done** (round P4a, with P4a because a mode needs it). **Wi-Fi done** (round P2-wifi: iwd settings and metric per mode, `netif-wifi`). **Hot-plug done** (round P2-hotplug: the `wired-hotplug` owner, `netif-hotplug`). **To do:** the Deck check (owner, hardware). Original scope: NetworkManager renderer, iwd in both modes, `wired-hotplug` owner, Deck hardware check of Steam over iwd | `netif-modes`, `netif-wifi`, `netif-hotplug` green |
| P4 | **Done** (rounds P4a and P4b): the `modes` service, the base and netif follow the mode; `modes` on the other services with the spine/border/voter rules (`netif-modes`, `k3s-modes`). Original scope: The `modes` service (N24), `modes` on every networking/cluster service, mode-scoping eval rules, deploy guidance | eval tests; `netif-modes` extended with a fabric leaf |
| P8 | **Done** (round P8). Lockout guard (N25, N36) | `netif-guard` green |
| P5 | Router module in `modules` on the P3b seam | `netif-router` green |
| Contract gate | netif is stable (N14) | every phase above done; every probe-verified claim VM-proven; every §4 invariant asserted by a suite |
| Field gate | home runs netif on each use case that exists (N14) | each use case live, recorded in §5 |
| Later | VM-test fixture (N28); NetBird and WARP presets (N29); a NAT gateway service (N10); the roaming-node design in SPEC.md (N27) | each its own decision round |

## 10. Glossary

Terms as this file uses them. One term per thing.

- **Apply, reapply** — one run of `ifstatecli apply`
  (`ifstate.service`). It converges the whole kernel network state to
  the configuration. A reapply is a run with an unchanged configuration.
- **Contract gate, field gate** — the two conditions for "stable" (N14).
- **Decision** — a numbered rule in §3, written `N1`…`N45`.
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
- **Phase** — a delivery step in §9, written `P0`…`P8` ("phase P2").
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

## 11. Retrospective and hardening candidates (2026-11-17)

Written after the proof rounds, before P3b code. **The owner adopted
every candidate on 2026-11-17: H1–H12 are decisions N31–N42 in §3**
(H1→N31, H2→N32, H3→N33, H4→N34, H8→N35, H5→N36, H6→N37, H7→N38,
H9→N39, H10→N40, H11→N41, H12→N42). This section keeps the reasoning;
§3 holds the rule and the status.

### 11.1 Decisions with weak proof

Each row is a decision above that holds today but rests on less proof
than the others. "Settle by" is the cheapest step that would make it
firm.

| Decision | Why the proof is weak | Settle by |
|---|---|---|
| N16 dhcpcd 10.5.2 on netif links | Proven on 10.5.2: leases, DNS, carrier changes, `ipv4only` (§8.4). Not proven on 10.5.2: prefix delegation, whose code changed in 10.5 | the delegation assertions of `netif-dhcp` (P3b slice 1) |
| N30 two dhcpcd packages | Machines on the stock unit keep 10.3.2 and its four CVEs until nixpkgs ships 10.5. Proven: 10.5.2 starts under that unit once `@chown` is allowed (§8.4) | owner decision: wait for nixpkgs PR 562813, or set the unit change and the package together in the modules repo |
| N16 dhcpcd writes the link-local address on DHCPv6 links | `addr_gen_mode` stays 1 after dhcpcd stops, so a link that moves from DHCPv6 to static keeps no kernel link-local address until reboot. Never probed | a probe: DHCPv6 link → static link by generation switch (P3b slice 3) |
| N9 DNS watcher (`ip monitor link`) | One long-running shell pipeline restores DNS after a link bounce. Probed for down/up, a resolved restart and a renewal; not for the watcher itself dying | `Restart=always` on the unit and a kill-the-watcher step in `netif-dhcp` (P3b slice 2) |
| N23 guest ports as a run-time regex | The list is computed in `ExecStartPre`. A port attached between that and the apply is detached. Never raced on purpose | H6 |
| N22 `^netns-` for Podman | The name is an internal of Podman's network stack, not an interface it promises. Rootless Podman and Docker with IPv6 were not probed | `netif-containers` asserts the namespace name, so a Podman bump that renames it fails the suite (P7) |
| N25 guard checks gateways only | A gateway that answers does not prove the deploy path works. A firewall change is outside the guard | H5 |
| N26 `match.path` by udev path | Proven on one QEMU machine type. Whether a cloud provider keeps the PCI path across instance types is unknown. The owner has not confirmed the design | owner yes; prefer `match.mac` wherever the provider fixes the MAC |
| N19 untrusted default | It closes ports on every link at once, on a machine reached over those links. It is the likeliest lockout in the plan, and N25 does not cover it | land it in its own slice (P3b slice 4) with an assertion that SSH still answers on an untrusted link |
| N24 modes | Eval-probed only. No machine has booted two modes | `netif-modes` (P2, P4) |

### 11.2 Stability candidates

- **H1 Supervise dhcpcd.** *(candidate, P3b slice 1; needs a probe)*
  - Today the IfState hook starts `dhcpcd -b` and `KillMode=process`
    keeps it alive. Nothing restarts it after a crash. It runs as root
    with no sandbox, with privilege separation off in the nixpkgs
    build, and it parses packets from untrusted networks.
  - Candidate: one unit per DHCP link, `netif-dhcpcd@<link>.service`,
    with `Restart=on-failure`, bound to the link's device unit, and
    the capability and filesystem limits the nixpkgs `dhcpcd.service`
    uses. The IfState hook only starts and stops that unit
    (`systemctl --no-block`).
  - Gains: a restart after a crash, one journal per link, a visible
    state (`systemctl status`), a smaller attack surface.
  - To probe: the hook's `start`, `stop` and `check` results when they
    call systemd from inside `ifstate.service`; that a clean stop still
    removes the lease's addresses and a restart after a crash does not
    drop them (dhcpcd de-configures on exit unless `persistent`).
- **H2 Define "online" for DHCP links.** *(candidate, P3b slice 1)*
  - Today `network-online.target` is reached when `ifstate.service`
    ends. `dhcpcd -b` goes to the background at once, so a DHCP link
    may have no address yet. A Kubernetes node or a tailnet login that
    waits for "online" then starts without one.
  - Candidate: `links.<n>.requiredForOnline` (default true for the
    default-route owner, false elsewhere) and a `netif-online` unit
    that waits, with a timeout, for an address on each required link.
    With H1 the unit can use dhcpcd's `waitip` instead.
  - The timeout is the usability half: a machine with the cable
    pulled must still boot. Proposed 30 s, then "online" with a logged
    warning.
- **H3 Keep the DHCP identity stable.** *(candidate, P5; router)*
  - dhcpcd identifies the machine by a DUID stored in
    `/var/lib/dhcpcd/duid` and each link by an IAID that defaults to
    the last four bytes of its MAC address.
  - A reinstall, a wiped state directory or a changed MAC (a bridge
    that takes the uplink's MAC, N23) therefore looks like a new
    client. An ISP then hands out a different delegated prefix and the
    home network renumbers.
  - Candidate: netif sets `duid` and a per-link `iaid` in the per-link
    config from stable values (a clan var for the DUID, a hash of
    instance and link name for the IAID).
- **H4 Recover faster from a DHCP outage.** *(candidate, P3b slice 1)*
  - dhcpcd 10.5 makes the DHCPv4 backoff configurable
    (`backoff_cutoff`, default 64 s). After an ISP or switch outage
    the client can sit up to a minute between tries.
  - Candidate: `backoff_cutoff 16` on netif links. Small, cheap, and
    testable in `netif-dhcp` by stopping the DHCP server for a while.
- **H5 Widen the lockout guard (N25).** *(candidate, P8)*
  - Add optional `guard.targets`: addresses that must answer after an
    apply, besides the gateways. The deployer's address is the useful
    one.
  - Run the guard after a firewall change too, not only after
    `ifstate.service`.
  - Until P8 exists, slice 4 of P3b (N19) is deployed with console
    access at hand.
- **H6 Close the guest-port race (N23).** *(candidate, P7)*
  - Name patterns from the `vm` preset stay the first protection
    (`^vnet`, `^tap`): they have no race.
  - The computed regex stays for arbitrary names. After the apply,
    netif compares each guest-ports bridge's members with the list it
    computed and fails the unit loudly when one is gone.
  - To probe: attach a port in a loop while applying.
- **H7 Watch for drift.** *(candidate, after P3b slice 1)*
  - A timer runs the no-op helper's dry run (`ifstatecli check`) every
    few minutes and fails a `netif-drift` unit when IfState would
    change something. It never applies.
  - It finds a second writer on a netif-owned object in the field,
    which is the fault class every probe round found first in a VM
    (Podman, dhcpcd's link-local address, tailscaled's ordering).
- **H8 A version envelope.** *(candidate, P3b slice 1)*
  - Two findings this month were version-specific (dhcpcd 10.3.2,
    IfState's `--version` string). §5 records the versions each suite
    passed with. The base asserts the minimums (N30) and `check` warns
    when IfState, dhcpcd, iwd or systemd is a newer minor than the
    recorded one, so a nixpkgs bump points at the suites to rerun.
- **H9 Decide DNS from router advertisements (N9).** *(candidate,
  P3b slice 2)*
  - A wired link with RAs and no DHCPv6 gets no DNS today. Either
    probe `rdnssd` as the writer into the N9 files, or make "RA link
    with no DNS source" an eval warning that names the static `dns`
    option.
- **H10 Commit the probes.** *(candidate, P3b slice 1)*
  - The §8 probes live in a gitignored directory on one machine.
    Another clone cannot rerun the evidence. Candidate:
    `services/netif/tests/probes/`, outside `checks` and outside
    `vmTests`, each runnable alone on the builder. A probe is deleted
    when a suite asserts what it showed.

### 11.3 Usability candidates

- **H11 `netif-status`.** *(candidate, P3b slice 2)* One read-only
  command on the machine. Per link: owner, state, each address and
  where it came from (static, DHCP, RA), lease time left, DNS servers,
  and which link holds the default route per family. Then the mode,
  the result of the last apply, and the guard state. It replaces five
  tools (`ip`, `resolvectl`, `dhcpcd -U`, `journalctl`, `ifstatecli`).
- **H12 Errors that say what to do.** *(candidate, every phase)*
  Every netif eval error names the instance, the link, the decision
  (`N…`) and the option to change. The eval tests assert the text of
  each error, so a reworded check cannot lose it. A `netif-preview`
  command wraps `ifstatecli check` and prints only what the next apply
  would delete or shut down.

### 11.4 What a VM cannot prove

The field gate (N14) checks these on real hardware. They are listed
now so the gate has concrete steps:

- suspend and resume on the Deck and kamrui-h1 (the dhcpcd fault was
  reported upstream after suspend);
- a real cable pull and a switch reboot, with a slow link
  negotiation;
- a USB dock NIC that appears under a new name;
- Wi-Fi roaming between two real access points;
- an ISP that changes the delegated prefix.

### 11.5 What went wrong in the proof rounds

- **Three findings were fixture faults**, written into this file one
  round before they were corrected: kea had not opened its socket, the
  simulated ISP did not forward IPv6, and `dhcpcd` was not on the
  VM's `PATH`. The control rule in §7 exists for this.
- **The lock bump of round proof-solo was checked with one suite of
  24.** The bump after this round runs every suite
  (`vm-test --all --remote --rebuild --quiet`).
- **An override that swaps a package's source keeps the old
  `patches`.** The first 10.5.2 probe run failed to build for that
  reason. N30 now says to empty them.
- **The fleet-wide swap to 10.5.2 was one merge away from cutting
  DHCP on every `networking.useDHCP` machine.** The netif probes all
  passed; only a probe of the stock unit showed it. nixpkgs' own
  dhcpcd tests did not help at first: run through the overlay they
  still used the stock package and came from the binary cache. N30
  now requires a test of the stock module before a shared package
  changes.
- **Probe-writing slips cost reruns**: commands not on `PATH`, the
  test driver's `errexit`, `pkill -f` matching its own shell, unquoted
  YAML scalars, stale neighbour entries. They are collected in
  `documentation/docs/guides/stage0-probe-lessons.md`.
