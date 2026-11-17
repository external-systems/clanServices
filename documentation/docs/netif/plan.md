# Plan and evidence

netif is the foundation every machine uses, so it is made stable before
other clanServices work continues.

## Phases

Each phase updates `specs/netif.md` first, then the code, then the VM
suites. The order is P3b, P7, P2, P4, P8, P5, then the contract gate.
Phase numbers are labels, not the order. (Phases were called N0–N8
until 2026-11-16; they are P0–P8 now, so a phase and a decision never
share a label.) If a check a phase depends on
fails, or a fix would need a new ownership model, the phase stops and the
owner decides.

| Phase | Work | Done when |
|---|---|---|
| P0 | The netif contract (docs only) | merged |
| P1 | Ownership registry with presets (iwd, Tailscale, Cilium, VM taps), start ordering after `network-online.target`, Tailscale range and route checks | `netif-registry` green — done |
| P3a | NICs by MAC, a missing NIC fails loudly, a checked IfState passthrough | `netif-match` green — done |
| P3b | **Done**, all five slices (2026-11-17; `netif-dhcp`, `netif` and `netif-match` green). Five slices, each merged with its own passing test. **1 dhcpcd:** switch netif to dhcpcd 10.5.2 from pkgs (`dhcpcd_latest`) with a check that it is in use, dhcpcd with its own config and prefix delegation, `ipv4only` on IPv4-only DHCP links, link-flap tests. **2 DNS:** the DNS unit. **3 routes:** default-route metrics, an explicit default-route owner. **4 firewall:** untrusted links by default, a zone per link. **5 the rest:** path MTU, NICs by device path. Fixes found in review (below) go with the slice they touch | `netif-dhcp`, `netif` and `netif-match` extended, every suite green |
| P7 | **Done** (2026-11-17; `netif-containers` and `netif-vmhost` green). The `containers` preset; VM hosts: bridge MAC, bridges over VLANs and bonds, guest ports | `netif-containers`, `netif-vmhost` green |
| P2 | The NetworkManager part is **done** (2026-11-17, `netif-modes` green). Still to do: Wi-Fi settings for IfState modes, hot-plugged dock Ethernet, the Deck check. Original scope: NetworkManager renderer, iwd in every mode, hot-plugged dock Ethernet, a check of Steam over the iwd backend on the Deck | `netif-modes`, `netif-wifi`, `netif-hotplug` green |
| P4 | First half **done** (2026-11-17, `netif-modes` green): the `modes` service, and netif follows the mode. Still to do: the mode setting on the fabric and cluster services. Original scope: The `modes` service; mode settings on every networking and cluster service, with the rules for spines, borders and voters | eval tests, `netif-modes` with a fabric leaf |
| P8 | **Done** (2026-11-17, `netif-guard` green). The lockout guard | `netif-guard` green |
| P5 | The router module in `modules`, built on P3b's zones and link names | `netif-router` green |
| Contract gate | netif is stable in this repo | every phase above done, every probe-verified claim VM-proven, every invariant tested |
| Field gate | home runs netif on each machine class that exists | each one live |
| Later | a VM-test fixture for other repos; NetBird and Cloudflare WARP presets; a NAT gateway service; the design for a roaming Kubernetes node | each its own decision round |

There are no version numbers yet: netif has no consumers, so it changes
freely. Version rules start with the first real consumer.

## What is built (2026-11-17, first code slice)

Proven by the `netif-dhcp` test on the builder, with dhcpcd 10.5.2:

| Feature | What the test shows |
|---|---|
| dhcpcd as a watched service, one per DHCP link | it runs upstream 10.5 with netif's config; killed, it comes back and the lease returns |
| DHCPv4 and DHCPv6 leases, router advertisements | address and default route for both; dhcpcd handles leases, the kernel handles advertisements |
| Prefix delegation | the LAN link gets a /64 out of the /60 the ISP hands out |
| A DHCPv4-only link | lease and DNS; IPv6 on the link is left alone |
| DNS per link | DHCP and static servers are on the right link after boot, a reapply, a renewal with new servers, a link flap, ten fast flaps and a restart of the resolver |
| "Online" | the machine counts as online only once the DHCP link has its address |
| A real cable loss and five down/up cycles | both leases, DNS and the IPv6 default return every time, with no internal errors |
| Reapply | changes nothing, checked by one shared helper that four tests now use |

Added the same day (slice 3), proven by `netif-dhcp` and `netif`:

| Feature | What the test shows |
|---|---|
| One default route per family | a second DHCP link with `defaultRoute` off keeps its lease, its routes and its DNS, and adds no default, also after a renewal |
| A fixed metric (100) on every default | static gateway, DHCPv4 lease and router advertisement all land at 100, so Wi-Fi and docks can sit behind them later |
| Live changes | switching to another NixOS generation moves an address and a metric with no reboot and without touching other links; switching back restores the first state |

Slice 4, the same day, proven by `netif-dhcp`:

| Feature | What the test shows |
|---|---|
| Links are untrusted unless you say so | on an untrusted link SSH answers and a port nobody opened does not; on a trusted link both do |
| DHCP on an untrusted WAN | DHCPv4, DHCPv6 and the delegated prefix all still arrive; netif opens the one port DHCPv6 needs |
| Zones | a link can carry a label such as `wan` or `lan`; a router module reads the interface names from it |

This is the change most likely to lock someone out of a real machine:
a service that silently relied on an open link now needs its own port.
No test relied on it. On a real machine, apply it with console access
until the lockout guard (P8) exists.

Slice 5, the same day:

| Feature | What shows it |
|---|---|
| Cloud NICs matched by PCI slot (`match.path`) | `netif-match`: a virtio NIC in a fixed slot is renamed by udev before IfState runs, with systemd-networkd off |
| cloud-init may not also configure the network | the build fails with a message that says what to do |
| Path MTU (`pathMtu`) | you declare the real size of the path (GCP 1460, PPPoE 1492); routed-fabric and wireguard-mesh size their tunnels from it. Build-time tests cover each step |

The tools slice, the same day, proven by `netif`:

| Tool | What it does |
|---|---|
| `netif-status` | one table per machine: every link with its state, addresses, DNS, DHCP, zone and trust, plus the default routes and whether drift was found. `--json` for scripts |
| `netif-preview` | shows what applying the configuration would change, and changes nothing. Give it a built system (`./result`) to read a change before switching to it |
| `netif-drift` (a timer, hourly) | runs the same preview and fails when the network no longer matches the configuration. It never repairs anything by itself |

Also in this slice: every older build error now ends with what to
change; a machine that would have no DNS server at all gets a
warning; and the five remaining test probes are in the repository
(`nix build .#netifProbes.<name>`).

P7, first half (containers), the same day, proven by the new
`netif-containers` test:

| Feature | What the test shows |
|---|---|
| Docker and Podman next to netif | turning either on is enough; netif leaves their bridges, container links and namespaces alone |
| Reapplying the network | four reapplies with containers running, added and removed: nothing changes, every container still reaches another machine |
| Published ports | a port published by Docker and one by Podman answer from another machine, on a link netif does not trust |
| Address clashes | the build fails when one of your networks overlaps Docker's or Podman's default range, and says how to move it |

The test also found a bug in the new tools (the hourly drift check
failed on machines running Podman) before it reached a machine.

P7, second half (VM hosts), the same day, proven by the new
`netif-vmhost` test:

| Feature | What the test shows |
|---|---|
| A bridge keeps its NIC's MAC | a bridge over one NIC found by MAC takes that MAC, and another machine sees it. Providers that filter by MAC (Hetzner) keep accepting the host |
| A bridge over a VLAN or a bond | traffic flows through a bridge whose member is a VLAN (what a Hetzner vSwitch needs) |
| Guest ports | ports a hypervisor adds to a bridge marked `guestPorts` survive every reapply, whatever their name, and the guest stays reachable |
| Other bridges stay strict | a stray port on a bridge without `guestPorts` is removed |
| A check after every apply | if a guest port is gone after an apply, the apply fails and names it |

Guests are simulated in the test. Real KubeVirt and Incus guests are
part of the final proof.

P8 (the lockout guard), the same day, proven by the new `netif-guard`
test. It was taken ahead of P2 and P4 because it does not depend on
them and it protects the firewall change of slice 4.

| Feature | What the test shows |
|---|---|
| A bad change is undone | a change that moves the machine off its gateway's network is rolled back within the timeout; the deploy reports a failure; the old address and route are back |
| Gateways that ignore pings | the check uses ARP and neighbour discovery, so such a gateway still passes |
| A good change is kept | it becomes the new "last good" configuration, also across reboots |
| Your own check targets | you can name an address and port that must stay reachable, such as the machine you deploy from |
| Firewall changes | the targets are checked again after the firewall reloads; a failure is reported, nothing is rolled back |
| First install | with nothing to go back to, the failure is only reported |

One design change came out of testing: the guard is its own service
(`netif-guard.service`) that runs after the network is applied and
after DHCP has started. As first built it sat inside the apply step
and could never see a DHCP gateway; the DHCP test caught that.

The guard is on by default on machines without a screen session and
off on desktops. It cannot see a firewall rule that blocks incoming
connections: its checks go outwards.

Modes (first half of P4, with the NetworkManager part of P2), the same
day, proven by the new `netif-modes` test:

| Feature | What the test shows |
|---|---|
| A machine with two modes | one machine boots into its NetworkManager mode, then into its IfState mode, then back; each boot runs exactly one network manager |
| The same wired link in both | NetworkManager brings it up from a profile netif wrote; in the other mode netif's own DHCP does. Same address source, same route metric, DNS in both |
| Things only one mode has | a VLAN declared for the developer mode exists only there; in the other mode its network card is left alone |
| A clear error | a VLAN, bond, bridge or tunnel in a NetworkManager mode fails the build and says how to limit it to an IfState mode |

How you write it: one `modes` entry per machine names each mode and
its manager; a netif instance can say `modes = ["developer"]`.
Anything of your own that belongs to one mode hangs on
`config.clanServices.networking.mode.name`.

Not done yet: tunnels and clusters cannot be limited to a mode, so a
machine that runs them cannot have a NetworkManager mode today.

The first part of the final proof, the same day: **netif under a
Kubernetes cluster**. The new test `k3s-data-plane-netif` runs the
whole cluster data-plane test (k3s, Cilium, the FRR and WireGuard
fabric, BGP to an outside router, load balancers, the firewall checks)
on network links declared through netif, and then reapplies the
network on both running nodes. Everything passed, after it found three
real defects that no earlier test could see:

| Defect | What would have happened on a real node |
|---|---|
| Pod network namespaces had no owner | any network reapply after the first pod started would have cut every pod off the network |
| The fabric's IPv6 link address was re-created on every apply | a short gap under the BGP session at each deploy |
| A floating IP placed by a failover tool had no owner | a reapply would have removed it |

All three are fixed, and the tools that show "what would change" now
catch such cases. Still to prove: RKE2 on netif, a machine that only
runs FRR, and a desktop mode such as KDE.

One thing to know when writing a config: a link accepts router
advertisements unless you say `ra = false`, so it counts as a possible
IPv6 default. On a machine with several links, all but one need
`defaultRoute.ipv6 = false`. Set it once for a whole segment in the
instance settings. The build error names the links.

One design change from the earlier notes: IfState no longer starts
dhcpcd through a hook. A systemd service bound to the link does it.
That gives restarts, a sandbox and a clear state for free.

Your decisions of 2026-11-17 are recorded: all twelve hardening ideas
are adopted (N31 to N42); netif counts as stable when it is proven
under Cilium Kubernetes, FRR and desktop specialisations such as KDE;
machines outside netif wait for nixpkgs for the newer dhcpcd; cloud
NICs are matched by udev path.

## What the 2026-11-16 review found

A review of `main` against the contract found these. All are fixed in P3b:

- netif's route ignore for DHCP links is a regex anchored only at the
  start, so the rule for `eth1` also covers `eth10`.
- dhcpcd runs without its own config file, so its own RA handling and
  hooks are not pinned down.
- Links are firewall-trusted unless told otherwise.
- Two suites treat `ifstatecli check` exiting 0 as "nothing changed",
  which it does not mean.
- Live reconfiguration is tested with hand-edited YAML, not a generation
  switch.

## What "reapplying changes nothing" means in a test

Two checks, done by one shared test helper:

1. A snapshot of links, addresses, routes in every table, rules and
   namespaces is the same before and after.
2. `ifstatecli check` reports no change. Its exit status alone proves
   nothing.

## How Wi-Fi, Tailscale and modes are tested

- **Wi-Fi.** The kernel's `mac80211_hwsim` module gives a VM simulated
  radios. hostapd and dnsmasq run access points in a separate network
  namespace, and the machine under test only sees its own client radio.
- **Tailscale.** A Headscale VM with its built-in relay serves the tailnet,
  fully offline.
- **Modes.** The VM boots with systemd-boot on a persistent disk. The test
  picks the next boot entry by its title and power-cycles the VM, just like
  choosing an entry in the boot menu.

## Probe evidence (2026-11-16, proof round)

Five throwaway VM tests and one evaluation ran on euc-hel-0 to prove or
disprove what the later phases assume. Versions: IfState 2.5.1, dhcpcd
10.3.2, systemd 262, iwd 3.12, Docker 29.9.1, Podman 6.1.4.

**What held as designed**

| Assumption | Result |
|---|---|
| A netif unit can keep each link's DNS in systemd-resolved | Yes: after boot, a reapply, a link going down and up, a resolved restart, and a lease renewal with new servers |
| Two DHCP NICs, one default route | Yes, for IPv4 and IPv6. The second NIC kept its lease, a pushed route and its SLAAC address |
| No IPv4 link-local address with `noipv4ll` | Yes |
| iwd puts both its default routes above netif's | Yes: metric 307 for IPv4 and IPv6; the cable wins, Wi-Fi takes over when it is unplugged |
| A bridge can carry its uplink's MAC | Yes, and another machine saw that MAC |
| A bridge on top of a VLAN | Yes |
| The lockout guard | Yes: a bad change was rolled back in 10 seconds, a good one kept. The gateway ignored ping and still passed |
| One `modes` service for both managers | Yes, evaluated both ways round |

**What needed a design change**

| Assumption | What the probe showed | Design now |
|---|---|---|
| Owning Podman's links is enough | Podman's containers still died: IfState deleted their named namespaces | The `containers` preset also owns `netns-…` namespaces |
| IfState can leave one bridge's ports alone | It cannot: it only knows names | netif lists the bridge's ports before each apply and hands IfState the list |
| A cloud NIC can be found by its parent device in IfState | For virtio NICs the parent is a counter (`virtio3`) that shifts when a disk is added | `match.path` is a udev path, and udev renames the NIC before IfState runs |

**What was broken** (settled the same day, see the next section)

- dhcpcd lost DHCPv4 or DHCPv6 after a link flap.
- The IPv6 default route seemed to stay away after a link went down and
  up.
- DNS from router advertisements is not read by anything. A link that
  gets IPv6 only from advertisements needs static nameservers or DHCP
  DNS. If a machine ever needs it, the `rdnssd` daemon is the candidate.

## Solo runs and research (2026-11-16)

The two broken findings were rerun with nothing else on the builder, to
rule out a noisy neighbour, and researched in the source and upstream.
The builder's load average was 0.1 to 0.3 during every run.

**dhcpcd after a link flap: a real bug, fixed upstream**

| dhcpcd | Five down/up cycles in a row: DHCPv4 back, DHCPv6 back | Internal errors |
|---|---|---|
| 10.3.2 from nixpkgs | 0 of 5, 1 of 5 | in every cycle |
| 10.3.2 with the fix (the pkgs package) | 5 of 5, 5 of 5, in four runs | none |
| 10.5.2 from upstream | 5 of 5, 5 of 5 | none |

- **Cause.** dhcpcd closes one of its sockets before it takes the socket
  out of its event loop. The loop keeps a stale entry. The next socket
  that gets the same number is then never read. Which protocol loses
  depends on which socket that is.
- **Upstream** knows it as issue 596 and fixed it in 10.5.0 with two
  small commits.
- **Fix.** Our pkgs repo builds dhcpcd 10.3.2 with those two
  commits. Since 2026-11-17 it also builds the upstream release
  10.5.2 for netif (see below). The rule for every such case: a broken
  package is fixed in pkgs, never in this repo or on a machine.

**Upstream dhcpcd 10.5.2 (2026-11-17)**

You chose the upstream release over our patch. It was tested alone on
the builder before any merge.

| Test | dhcpcd 10.5.2 |
|---|---|
| netif's way of running it: leases, DNS, renewal, real cable loss, five down/up cycles | all passed, no internal errors |
| The same with `ipv4only` | passed; IPv6 on that link left alone |
| The normal NixOS DHCP service, as non-netif machines use it | **does not start** |
| The normal NixOS DHCP service with the fix from nixpkgs PR 562813 | passed |

- **Why it fails there.** From 10.5.1 dhcpcd changes the owner of its
  control socket. The NixOS service forbids that system call, so
  dhcpcd dies at start. nixpkgs has an open change for it.
- **What we did.** pkgs now has two packages. `dhcpcd_latest` is the
  unchanged upstream 10.5.2; netif will use it (first step of P3b).
  `dhcpcd` stays 10.3.2 with the two-commit fix, so machines on the
  normal NixOS DHCP setting keep working.
- **What is left.** Those machines keep 10.3.2, and its four security
  holes, until nixpkgs ships 10.5. Moving them sooner means changing
  the DHCP service and the package together, in the modules repo.
  That is your call.
- 10.5.2 also closes four security holes (CVE-2026-56113, 56114,
  56116, 56117) for netif links.

A list of weak spots and ideas for hardening is on
[Retrospective and hardening](hardening.md).

**The IPv6 default route: a fault in the test, not in netif**

The simulated ISP in the probe sent router advertisements but did not
forward IPv6. Such a machine tells its neighbours "I am not a router",
and Linux then drops it as default router about ten seconds after first
use. It happened with dhcpcd stopped too. With forwarding switched on at
the ISP, the route stayed. The kernel also asked for a router by itself
after every one of 30 down/up cycles, so no helper is needed.

Two test rules came out of it: a test machine that advertises itself as
a router must forward, and a timing-sensitive finding is confirmed in a
run of its own before it changes a design.

**Decisions**

- dhcpcd runs with `ipv4only` on links that do not use DHCPv6. It then
  leaves IPv6 on that link alone (proven).
- dhcpcd never handles router advertisements on a netif link. IfState
  keeps that job.
- Guest ports are rendered through the normal NixOS IfState module, as
  one small included file. Proven.

## Probe evidence (2026-11-16)

Two more throwaway tests ran on euc-hel-0 while the contract was widened
to the whole fleet. Versions: IfState 2.5.1, dhcpcd 10.3.2, systemd 262.

**Gates probe.** It checked the assumptions phase P3b rests on.

| Question | Result |
|---|---|
| Does dhcpcd still do DHCPv6 and prefix delegation when it ignores router advertisements? | Yes |
| Can IfState set the metric of the router-advertisement default route? | No: its schema rejects the `ra_defrtr_metric` sysctl. netif's link hook writes it, and the route then had metric 100 |
| Does a reapply change nothing while dhcpcd runs? | Yes |
| Does DHCP DNS reach systemd-resolved through dhcpcd's resolvconf hook? | No |
| Does DNS set on a link survive an IfState reapply? | Yes |
| Does DNS set on a link survive the link going down and up? | No |

The two DNS failures changed the design: a netif unit now watches links
and writes their DNS into resolved, and dhcpcd's resolvconf hook is not
used. dhcpcd also took an IPv4 link-local address before its lease
arrived, so that is switched off.

**Containers probe.** One host with plain IfState, Docker, rootful
Podman and a bridge with one NIC in it.

| Question | Result |
|---|---|
| Does a bridge take its NIC's MAC? | No: IfState generates one |
| Does an unknown tap on the bridge survive a reapply? | No: deleted |
| Does Docker survive two applies, with connectivity and a published port? | Yes |
| Does rootful Podman survive? | No: `podman0` deleted, container offline |

These became the `containers` preset and the VM-host rules.

## Probe evidence (2026-11-15)

Two throwaway VM tests ran on euc-hel-0. Versions: IfState 2.5.1,
NetworkManager 1.58.1, iwd 3.12, Tailscale 1.104.2.

**Mode probe: passed twice** (the second a fresh rebuild). One machine with three simulated radios (two access
points, `cafe` and `friend`), Headscale and a Tailscale peer:

1. **Gaming.** NetworkManager with iwd, no IfState unit. Joined `cafe`, got
   DHCP and DNS, joined the tailnet.
2. **Rebooted into developer.** NetworkManager off and IfState applied. iwd
   rejoined `cafe` by itself, and the tailnet answered at once.
3. **IfState reapplied.** Nothing changed. Without the ownership registry,
   a dry run would have deleted Tailscale's interface and rules and a
   foreign namespace, and set the Wi-Fi link down.
4. **Addresses.** Ones with a lifetime survived the reapply; a stray
   permanent one was removed.
5. **Joined `friend` with `iwctl`.**
6. **Rebooted into gaming.** The machine joined `friend`, NetworkManager
   listed it, nothing from IfState remained, and the tailnet answered.

**Router probe: passed twice.** WAN DHCPv4 and DHCPv6 prefix delegation ran
through the IfState hook. Kea served DHCPv4, radvd served SLAAC, and NAT
reached the ISP. An IfState reapply changed nothing.

**Gaps the probes found**, now part of the contract:

- Daemons with long-lived connections must start after the mode's
  `network-online.target`. Without that, Tailscale stalled for about a
  minute after boot.
- The registry must cover network namespaces and Wi-Fi links, not only
  tunnels and rules.
- IfState sets undeclared NICs down, so every NIC is declared or owned.
