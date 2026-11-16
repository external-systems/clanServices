# Plan and evidence

netif is the foundation every machine uses, so it is made stable before
other clanServices work continues.

## Phases

Each phase updates `specs/netif.md` first, then the code, then the VM
suites. The order is N3b, N2, N4, N5, then N6a; N6b follows the hardware.
If a check a phase depends on fails, or a fix would need a new ownership
model, the phase stops and the owner decides.

| Phase | Work | Done when |
|---|---|---|
| N0 | The netif contract (docs only) | merged |
| N1 | Ownership registry with presets (iwd, Tailscale, Cilium, VM taps), start ordering after `network-online.target`, Tailscale range and route checks | `netif-registry` green — done |
| N2 | NetworkManager renderer, one manager per mode, iwd in every mode, hot-plugged dock Ethernet, a check of Steam over the iwd backend on the Deck | `netif-modes`, `netif-wifi`, `netif-hotplug` green |
| N3a | NICs by MAC, a missing NIC fails loudly, a checked IfState passthrough | `netif-match` green, existing suites green — done |
| N3b | dhcpcd with its own config and prefix delegation, path MTU used by the fabric and the mesh, per-link DNS through resolved, default-route metrics, untrusted links by default, a zone per link; fixes found in review (below) | `netif-dhcp` and `netif` extended, every suite green |
| N4 | Mode settings on every networking and cluster service, with the rules for spines, borders and voters | eval tests, `netif-modes` with a fabric leaf |
| N5 | The router module in `modules`, built on N3b's zones and link names | `netif-router` green |
| N6a | netif 1.0 | N1–N5 done, every probe-verified claim VM-proven, every invariant tested |
| N6b | home runs netif on a Deck, kamrui-h1, the router and a server | each one live; does not block 1.0 |

## What the 2026-11-16 review found

A review of `main` against the contract found these. All are fixed in N3b:

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
