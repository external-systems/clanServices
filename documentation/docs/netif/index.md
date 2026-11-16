# Host networking with netif

`netif` is how every machine gets its network configuration: a router with
four SFP+ ports, a cloud server, a Steam Deck in gamescope mode. You declare
links, addresses and routes once in `inventory.nix`. netif renders them for
whichever network manager the machine's current mode uses.

This section is the human version of the netif contract. The agent edition,
with numbered decisions `N1`–`N19`, is
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

## Supported machines

- **Steam Deck.** Boots into gamescope Steam mode, which uses NetworkManager,
  Wi-Fi and Tailscale. A `developer` mode adds KDE, IfState, Tailscale and
  routed access to pod and Service IPs in other clusters.
- **kamrui-h1.** Boots into gaming with Wi-Fi. `developer` matches the Deck.
  `kubernetes` adds a single-node k3s server for local testing.
- **Home router.** Headless, four SFP+ ports, NAT, DHCP server, DHCPv6
  prefix delegation. See [Home router](router.md).
- **Servers and cloud nodes.** IfState only, no modes.

## Status

The contract was split out of SPEC.md on 2026-11-15 and checked with two VM
probes before it was written down: [Plan and evidence](plan.md). What runs
in `main` today is IfState-only networking with multi-link,
multi-instance links (D53/D61), plus the ownership registry with its
presets, start ordering and Tailscale checks (phase N1, suite
`netif-registry`), and NICs found by MAC (phase N3a, suite `netif-match`).

Next is phase N3b. It brings:
- DNS per link through systemd-resolved;
- DHCPv6 prefix delegation;
- a declared path MTU;
- fixed default-route metrics, so wired beats Wi-Fi;
- links that the firewall does not trust unless you say so;
- a zone label per link for the router.

Modes and the NetworkManager renderer follow in phase N2. See the
[plan](plan.md).

## Defaults worth knowing

- **Firewall:** a link is untrusted unless its segment or the link sets
  `firewall.trust = true` (from N3b). Services open their own ports.
- **DNS:** each link's nameservers go to that link in systemd-resolved,
  never to a global list (from N3b).
- **Default routes:** netif's default route has metric 100, a dock 200,
  and Wi-Fi 300 or more, so a cable wins and Wi-Fi stays as a fallback
  (netif's metrics from N3b, Wi-Fi and the dock from N2).

## Pages

- [Modes and reboots](modes.md) — how gaming, developer and kubernetes modes
  work, and how to deploy without switching modes by accident.
- [Wi-Fi](wifi.md) — iwd in every mode, cafés and other people's homes.
- [Ownership and VPNs](ownership.md) — what IfState deletes unless told not
  to, and how Tailscale fits in.
- [Home router](router.md) — the router split between netif and the
  `modules` repo.
- [Plan and evidence](plan.md) — delivery phases, probe results and test
  suites.
- [netif service reference](../services/netif.md) — today's settings.
