# Host networking with netif

`netif` is how every machine gets its network configuration: a router with
four SFP+ ports, a cloud server, a Steam Deck in gamescope mode. You declare
links, addresses and routes once in `inventory.nix`. netif renders them for
whichever network manager the machine's current mode uses.

This section is the human version of the netif contract. The agent edition,
with numbered decisions `N1`–`N45`, is
[`specs/netif.md`](https://github.com/external-systems/clanServices/blob/main/specs/netif.md).

## The model

| Piece | Role |
|---|---|
| `netif` | The only network contract in the inventory, for every machine and mode. |
| IfState 2.5.1 | Renders the network on routers, servers, and developer and kubernetes modes. |
| NetworkManager | Renders the network in gaming modes. Never runs at the same time as IfState. |
| iwd | Owns Wi-Fi in every mode. |
| Ownership registry | Keeps IfState and NetworkManager away from what other software owns: Tailscale, iwd, Cilium. |
| Modes | NixOS specialisations. You switch by rebooting and picking an entry in the boot menu. |
| `modes` service | Names each machine's modes and their network manager (planned). |
| Lockout guard | Rolls the network back on a headless machine when a change cuts its gateway. |

netif owns links and how they are addressed, routed, resolved and
trusted. It does not do NAT, tunnels, Wi-Fi or cluster networking: see
[What netif is responsible for](responsibility.md).

## Supported machines

The full list is on [Use cases](use-cases.md). In short:

- **Steam Deck and kamrui-h1.** Boot into a NetworkManager mode for Steam
  and the desktop. A `developer` mode adds IfState, Tailscale, containers
  and routed access to pod and Service IPs. kamrui-h1 adds a `kubernetes`
  mode.
- **Home router.** Headless, five ports, NAT, DHCP server, DHCPv6 prefix
  delegation. See [Home router](router.md).
- **Servers, cloud VMs, Proxmox VMs, bare-metal nodes.** IfState only, no
  modes.
- **VM hosts.** Bridges whose guests have their own public addresses and
  provider MACs.

## Status

The contract was split out of SPEC.md on 2026-11-15 and checked with two VM
probes before it was written down: [Plan and evidence](plan.md). What runs
in `main` today is IfState-only networking with multi-link,
multi-instance links (D53/D61), plus the ownership registry with its
presets, start ordering and Tailscale checks (phase P1, suite
`netif-registry`), and NICs found by MAC (phase P3a, suite `netif-match`).

A proof round on 2026-11-16 tested the assumptions of the later phases
in throwaway VMs: [Plan and evidence](plan.md). Most held. Three designs
changed (Podman, guest ports, cloud NICs). dhcpcd lost leases after a
link flap; solo runs proved it is a dhcpcd bug, and our pkgs repo now
builds dhcpcd with the upstream fix.

Next is phase P3b. It brings:
- DNS per link through systemd-resolved;
- DHCPv6 prefix delegation;
- a declared path MTU;
- fixed default-route metrics, so wired beats Wi-Fi;
- links that the firewall does not trust unless you say so;
- a zone label per link for the router.

It also brings an explicit default-route owner per link, so two DHCP
NICs can coexist, and NICs found by device path for cloud VMs.

After it come containers and VM hosts (phase P7), the NetworkManager
renderer (P2), modes (P4), the lockout guard (P8) and the router service
(P5). See the [plan](plan.md).

netif has no consumers yet. It is not used on real machines until it
passes the contract gate.

## Defaults worth knowing

- **Redirects and source routes:** no link takes or sends an ICMP
  redirect or accepts a source-routed packet, in every mode, also links
  netif does not declare and links that appear later (N47). The suite
  `netif-hostile` attacks a netif machine to prove it.

- **Firewall:** a link is untrusted unless its segment or the link sets
  `firewall.trust = true` (from P3b). Services open their own ports.
- **DNS:** each link's nameservers go to that link in systemd-resolved,
  never to a global list (from P3b).
- **Default routes:** netif's default route has metric 100, a dock 200,
  and Wi-Fi 300 or more, so a cable wins and Wi-Fi stays as a fallback
  (netif's metrics from P3b, Wi-Fi and the dock from P2).

## Pages

- [What netif is responsible for](responsibility.md) — what it owns, what
  it never owns, and where a change goes.
- [Use cases](use-cases.md) — every machine class and what it needs.
- [Glossary](glossary.md) — the words these pages use.
- [Modes and reboots](modes.md) — how gaming, developer and kubernetes modes
  work, and how to deploy without switching modes by accident.
- [Wi-Fi](wifi.md) — iwd in every mode, cafés and other people's homes.
- [Ownership and VPNs](ownership.md) — what IfState deletes unless told not
  to, and how Tailscale fits in.
- [Home router](router.md) — the router split between netif and the
  `router` service. Its design is in
  [Router and NAT gateway](../gateway/index.md).
- [Plan and evidence](plan.md) — delivery phases, probe results and test
  suites.
- [netif service reference](../services/netif.md) — today's settings.
