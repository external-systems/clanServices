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
phase P2, NetworkManager unmanaged devices). A preset switches on
automatically when you enable its daemon:

| Preset | Switched on by | Owns | Status |
|---|---|---|---|
| `iwd` | `networking.wireless.iwd.enable` | Wi-Fi links (`wl*`) | VM-proven |
| `tailscale` | `services.tailscale.enable` | `tailscale0`, rules 5210/5230/5250/5270, table 52 | VM-proven |
| `cilium` | `services.k3s.enable` or `services.rke2.enable` | `cilium_*`, `lxc*`, table 200 | VM-proven |
| `vm` | libvirtd or Incus | `tap*`, `vnet*` | implemented |
| `containers` | Docker or Podman | `docker*`, `br-*`, `podman*`, `veth*` | planned, phase P7 |

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

Three probes on 2026-11-16 ran Docker and rootful Podman next to IfState:

| IfState told to leave alone | Docker | Podman |
|---|---|---|
| nothing extra (its built-in list) | survives | `podman0` deleted, containers offline |
| the container links (`docker*`, `br-*`, `podman*`, `veth*`) | survives | bridge stays, but the containers' namespaces are deleted and they go offline |
| the links **and** Podman's namespaces (`netns-…`) | survives | survives |

In the last run nothing changed across two applies: every link, the
default and a user-made network of each runtime, and a published port
reached from another machine, with the nftables firewall on.

The reason: rootful Podman puts each container in a *named* network
namespace, and IfState deletes named namespaces it does not know.
Docker's namespaces have no name, so IfState never sees them.

The `containers` preset (built 2026-11-17, test `netif-containers`) owns all of it: the four
link patterns and the `netns-` namespaces. It also rejects Docker's and
Podman's default address pools when they overlap a fleet range. Rootless
Podman creates no host links and needs nothing.

## VM guests on a bridge

IfState deletes a port it does not know, even when the port sits on a
bridge netif declared. It decides by interface name only; it has no rule
"leave this bridge's ports alone".

A bridge marked `bridge.guestPorts = true` (planned, phase P7) gets that
rule from netif instead:

1. Before every apply, netif lists the bridge's ports and drops the ones
   it declared itself.
2. It writes the rest, by exact name, into a small file under `/run`.
3. IfState reads that file as part of its "leave alone" list.

A probe on 2026-11-16 proved it: a guest port with an arbitrary name
stayed on its bridge, and its guest stayed reachable from another
machine, across two applies. Ports named `tap*` and `vnet*` are also
left alone by name (the `vm` preset), which covers a port created
between the listing and the apply.

The same probe showed a bridge that takes its uplink's MAC, and a bridge
on top of a VLAN, both carrying traffic. See [Use cases](use-cases.md),
VM host.

## Default routes from several owners

netif lets at most one of its links own the default route per address
family. A second link sets `defaultRoute.ipv4 = false` (or `ipv6`) and
keeps its lease and routes without a default (planned, phase P3b). Wi-Fi, a dock and Tailscale can add their own, so every default
route gets a fixed metric (planned: netif's in P3b, the rest in P2).
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
