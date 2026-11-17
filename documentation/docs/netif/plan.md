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
| P3b | Five slices, each merged with its own passing test. **1 dhcpcd:** switch netif to dhcpcd 10.5.2 from pkgs (`dhcpcd_latest`) with a check that it is in use, dhcpcd with its own config and prefix delegation, `ipv4only` on IPv4-only DHCP links, link-flap tests. **2 DNS:** the DNS unit. **3 routes:** default-route metrics, an explicit default-route owner. **4 firewall:** untrusted links by default, a zone per link. **5 the rest:** path MTU, NICs by device path. Fixes found in review (below) go with the slice they touch | `netif-dhcp`, `netif` and `netif-match` extended, every suite green |
| P7 | The `containers` preset; VM hosts: bridge MAC, bridges over VLANs and bonds, guest ports | `netif-containers`, `netif-vmhost` green |
| P2 | NetworkManager renderer, iwd in every mode, hot-plugged dock Ethernet, a check of Steam over the iwd backend on the Deck | `netif-modes`, `netif-wifi`, `netif-hotplug` green |
| P4 | The `modes` service; mode settings on every networking and cluster service, with the rules for spines, borders and voters | eval tests, `netif-modes` with a fabric leaf |
| P8 | The lockout guard | `netif-guard` green |
| P5 | The router module in `modules`, built on P3b's zones and link names | `netif-router` green |
| Contract gate | netif is stable in this repo | every phase above done, every probe-verified claim VM-proven, every invariant tested |
| Field gate | home runs netif on each machine class that exists | each one live |
| Later | a VM-test fixture for other repos; NetBird and Cloudflare WARP presets; a NAT gateway service; the design for a roaming Kubernetes node | each its own decision round |

There are no version numbers yet: netif has no consumers, so it changes
freely. Version rules start with the first real consumer.

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
