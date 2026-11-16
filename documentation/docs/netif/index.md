# Host networking with netif

`netif` is how every machine gets its network configuration: a router with
four SFP+ ports, a cloud server, a Steam Deck in gamescope mode. You declare
links, addresses and routes once in `inventory.nix`. netif renders them for
whichever network manager the machine's current mode uses.

This section is the human version of the netif contract. The agent edition,
with numbered decisions `N1`–`N14`, is
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
`netif-registry`). Modes and the NetworkManager renderer are planned in
phases N2–N6.

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
