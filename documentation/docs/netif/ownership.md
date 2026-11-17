# Ownership and VPNs

IfState converges the whole network stack to its configuration. That is what
makes it reliable, and it also means it removes things it does not know
about. IfState 2.5.1 does this to anything undeclared:

| Undeclared object | What IfState does |
|---|---|
| Virtual interface (`tailscale0`, a tun or a WireGuard link) | deletes it |
| Physical interface (the Wi-Fi radio, a spare NIC) | sets it down |
| Named network namespace | deletes it |
| Policy rule, once any route or rule is declared | deletes it |
| Route in a table netif declares routes in | deletes it, unless its protocol is `dhcp`, `ra` or an FRR protocol |
| Permanent extra address on a declared link | removes it; addresses with a lifetime (DHCP, SLAAC, delegated prefixes) are kept |

## The ownership registry

Other software tells netif what it owns through
`clanServices.networking.owners.<name>`: interface names, namespaces, tables
and rule priorities. netif turns that into IfState ignore rules (and, from
phase N2, NetworkManager unmanaged devices). A preset switches on
automatically when you enable its daemon:

| Preset | Switched on by | Owns | Status |
|---|---|---|---|
| `iwd` | `networking.wireless.iwd.enable` | Wi-Fi links (`wl*`) | VM-proven |
| `tailscale` | `services.tailscale.enable` | `tailscale0`, rules 5210/5230/5250/5270, table 52 | VM-proven |
| `cilium` | `services.k3s.enable` or `services.rke2.enable` | `cilium_*`, `lxc*`, table 200 | VM-proven |
| `vm` | libvirtd or Incus | `tap*`, `vnet*` | implemented |
| `containers` | Docker or Podman | `docker*`, `br-*`, `podman*`, `veth*` | planned, phase N7 |

The rules are checked when the configuration evaluates. Each of these
fails the build:

- netif declares an interface, namespace, table or rule priority that an
  owner claims;
- netif declares a Wi-Fi link (`wl*`): Wi-Fi is always iwd's;
- NetBird, Cloudflare WARP, ZeroTier, or scripted WireGuard
  (`networking.wireguard`, `wg-quick`) is enabled without an owner of that
  name. Those get presets only once a VM suite proves them; for WireGuard,
  use `wireguard-mesh` or `routed-fabric`.

In the probe, a dry run without the registry would have deleted
`tailscale0`, all eight Tailscale rules and a foreign namespace, and set
the Wi-Fi link down. With the registry, two applies changed nothing.

## Containers

A probe on 2026-11-16 ran Docker and rootful Podman next to plain IfState:

- **Docker survived.** IfState's built-in ignore list already covers
  `docker0`, `br-…` and `veth…`. Containers kept their network and a
  published port kept working across two applies.
- **Podman did not.** `podman0` is not on that list. IfState deleted the
  bridge and the container lost its network.

The `containers` preset (planned, phase N7) names all of them, so netif
does not depend on IfState's built-in list. It also rejects Docker's and
Podman's default address pools when they overlap a fleet range. Rootless
Podman creates no host links and needs nothing.

## VM guests on a bridge

IfState deletes a tap it does not know, even when the tap sits on a
bridge netif declared. A bridge marked `bridge.guestPorts = true`
(planned, phase N7) leaves every port netif did not declare to the
hypervisor. See [Use cases](use-cases.md), VM host.

## Default routes from several owners

netif lets at most one of its links own the default route per address
family. A second link sets `defaultRoute.ipv4 = false` (or `ipv6`) and
keeps its lease and routes without a default (planned, phase N3b). Wi-Fi, a dock and Tailscale can add their own, so every default
route gets a fixed metric (planned: netif's in N3b, the rest in N2).
Lower wins:

| Owner | Metric |
|---|---|
| a netif link | 100 |
| a hot-plugged dock | 200 |
| Wi-Fi (iwd) | 300 and up |

Tailscale adds no default route of its own. An exit node takes over
through Tailscale's policy rules, ahead of every metric; turning one on
is your choice.

## Start order

Each mode provides `network-online.target`:
- **gaming:** NetworkManager's wait-online;
- **IfState modes:** `ifstate.service`.

Tailscale and other daemons that keep a long-lived connection start after
it. Without that order, the probe showed tailscaled's control connection
stalling for about a minute after boot, because IfState reconfigured the
link under it.

## Tailscale and the fabric

Tailscale's policy rules sit in front of the main routing table, where FRR
installs fabric routes. A subnet route you accept through Tailscale
therefore wins over a fabric route for the same prefix. netif:

- reject a Tailscale range that overlaps a netif, fabric or cluster pool;
- warn when a fabric member accepts Tailscale routes (`--accept-routes`).

Tailscale works in gaming mode too: NetworkManager leaves `tailscale0` alone,
and the node identity in `/var/lib/tailscale` is the same in every mode.
