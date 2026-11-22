# netif

`netif` is the inventory-facing clanService for core host network
configuration (D53/D61). It replaces static IP ownership by home's
`hostSpec.networking` and `machines.json`; borg's `lan` service is the
behavioral reference. Today IfState 2.5.1 is the only renderer and applies
changes live without reboot.

The netif contract now has its own spec, `specs/netif.md`, and its own
section, [Host networking](../netif/index.md). It adds modes (gaming,
developer, kubernetes) switched by reboot, a NetworkManager renderer for
gaming modes, iwd for Wi-Fi in every mode, and an ownership registry. This
page describes today's settings; where they differ, the netif section
wins.

## Contract

`netif` is **multi-instance and multi-link** (D53). One instance describes
a network segment — a site LAN, a public uplink, an SFP+ group — and a host
joins as many instances as it has attachments, commonly a public and a
private instance, or several instances for a multi-NIC router. Inventory is
role-scoped: site/segment defaults live on `roles.default.settings`, and
each machine declares one or more logical links under
`roles.default.machines.<name>.settings.links.<logical>` with the physical
`interface` per link. Each instance carries:

- **segment defaults** (site/segment level): addressing mode, base MTU
  (effective per-link values are derived, not hand-set), nameservers,
  gateway, firewall trust;
- **per-machine and per-link overrides**: physical interfaces (by name or
  by permanent MAC with `match.mac`), VLANs,
  bonds, and bridges, each with DHCP/RA or static IPv4/IPv6 addressing and
  prefixes;
- gateways (on-link and default), static and policy routes, table
  selection, MTU, DNS, and firewall trust per link;
- `extraSettings`, a checked IfState passthrough per link (a key netif
  already renders is an eval error);
- optional `clan.core.networking.targetHost` export and SSH user;
- optional `peer` endpoint exports for fabric consumers.

Since 2026-11-17 (P3b slice 1) netif also runs three kinds of unit
beside IfState:

- **`netif-dhcpcd-<interface>.service`**, one per DHCP link. systemd
  restarts it after a crash and limits what it may touch. It runs
  upstream dhcpcd 10.5 with netif's own config.
  `dhcp.prefixDelegation` asks the ISP for a prefix and gives parts of
  it to other links. The prefix it got is written to
  `/run/netif/pd/<interface>`. The file changes only when the prefix
  does, so a router can watch it. It lists only prefixes the ISP still
  prefers. It is removed when the ISP takes the prefix away, and it
  does not exist after boot until the ISP has answered.
- **`defaultRoute.ipv4` / `defaultRoute.ipv6`** say whether a link may
  carry the machine's default route. One link per machine and family
  may. A link that accepts router advertisements (`ra`, on by default)
  counts for IPv6, so other links set `defaultRoute.ipv6 = false`, per
  link or once in the instance settings. Every default route netif
  installs has metric 100.
- **`firewall.trust`** is off unless a link or its segment turns it
  on. An untrusted link only answers on ports a service opened (SSH
  opens its own). Trust a link only on a private network.
- **`zone`** is a free label (`wan`, `lan`). Other modules read
  `clanServices.netif.zones.<zone>` to get the interface names.
- **`match.path`** finds a NIC by its PCI slot (udev `ID_PATH`), for
  cloud machines whose MAC is not known up front. The NIC gets the
  link's name.
- **`pathMtu`** says how large a packet the path really carries when
  that is less than the link's MTU. Tunnels are sized from it.
- **`netif-status`** shows every link with its live state.
  **`netif-preview`** shows what an apply would change without
  applying. **`netif-drift.timer`** runs that preview every hour and
  fails when something else changed the network.
- **Bridges for guests.** A bridge's members can be NICs, VLANs or
  bonds. A bridge over one NIC found by `match.mac` takes that MAC;
  `mac` sets one by hand. On a plain NIC `mac` changes the address the
  port shows on the wire, for a WAN port that stands in for an ISP's
  gateway; `match.mac` still finds the NIC by its real address.
  `bridge.guestPorts = true` tells netif that
  other ports on the bridge belong to a hypervisor and must be left
  alone.
- **The lockout guard** (`clanServices.netif.guard`) checks after
  every network change that the gateways still answer. If not, it puts
  the last working network back and reports the failure. It is on by
  default on machines without a desktop. `guard.targets` adds your own
  addresses to check.
- **Modes.** With the `modes` service a machine can boot into a
  NetworkManager mode or an IfState mode. In a NetworkManager mode
  netif writes one NetworkManager profile per wired link instead of
  running IfState. `modes = ["developer"]` on an instance limits its
  links to those modes.
- **`netif-dns.service`** sets each link's DNS in systemd-resolved: the
  link's `nameservers` plus what its DHCP leases bring. There is no
  global DNS list from netif.
- **`netif-online.service`** makes "online" mean "the DHCP links have
  an address". It waits at most 30 seconds, so a pulled cable never
  blocks a boot.

!!! note "Planned changes (later slices of P3b, `specs/netif.md` N17–N19)"
    - Links become firewall-untrusted by default; set
      `firewall.trust = true` on trusted segments.
    - New link options: `pathMtu`, `zone`, `defaultRoute`, `match.path`.
    - Static default routes get metric 100 (DHCP ones have it).

Cross-instance checks keep the host coherent (D53): an interface/link is
owned by exactly one instance, exactly one link per address family may
provide the host default route (DHCP lease defaults count). DNS is per
link, so instances cannot conflict over it. Policy-routing tables
and every effective from/to rule priority must also be unique across
instances. `routed-fabric` owns fabric policy routing — `netif` never
renders fabric rules — and `netif` links never become a shared-L2
Kubernetes datapath. Within one
instance, a VLAN child names its parent link, and bonds/bridges name
physical member links; a physical link consumed as a member carries no
addressing of its own.

Static core addresses and routes live in `inventory.nix`. A public fleet
repo may obtain sensitive public-topology values from its
`secrets`/`not-secret` input; those values are public on the deployed NixOS
machine and are not clan vars.

Supporting NixOS modules may configure driver quirks or TCP tuning. They
never become a second owner of the static data plane. Wi-Fi belongs to iwd
in every mode, and NetworkManager only runs as netif's renderer in
NetworkManager modes ([Wi-Fi](../netif/wifi.md), [Modes](../netif/modes.md)). Provider-MAC attachment for day-2 KubeVirt
(for example) is `netif` **bridge plumbing**, not a LoadBalancer pool
concern.

## Exports and consumers

`netif` publishes standard `peer` facts for endpoint discovery and a
versioned (`schemaVersion`) `netif` view with per-link kind, interface,
addressing, MTU, gateway, DNS, route, and endpoint facts, plus the
machine's resolved endpoint and the effective underlay MTU.
`routed-fabric` consumes the peer hosts as WireGuard endpoints
(the machine endpoint first, then each `endpoint = true` link's static
addresses) and derives link MTUs from the export. Consumers use
`clanLib` export selectors, never raw scope keys. The same resolved
link/interface/address/gateway/MTU/route configuration is published to the
per-node `clan.networkFacts` interface as underlay graph facts (D57) —
producer-owned, non-secret, and exposed through `readOnly = true` options;
see [Network diagrams](../architecture/network-diagrams.md).

RA-enabled links use `accept_ra = 2` on machines with actual forwarding
intent (spines, borders with `border.forwarding = true`, and k3s/rke2
nodes), so SLAAC default routes survive while forwarding is enabled. The
final literal `targetHost`, including an explicit override without netif,
is rejected if it names a fabric loopback, transfer, or tunnel address;
IPv6 is normalized before comparison and deployment stays on the underlay.
Additional `clanServices.networking.reservedPorts` strings (ports or ranges)
merge with every rendered WireGuard listen port in `ip_local_reserved_ports`.
The option lives in clanServices' own namespace, and the shared IfState
module's stable key makes repeated imports idempotent. Netif and source-return
policy tables both reject `{0,200,201,253,254,255,2004,2005}`; netif tables
and effective rule priorities must also be unique across instances.

## Inventory example

Site/segment defaults with per-machine NIC names, plus a multi-NIC router
joining two instances (one link each, a single default route across the
whole host):

```nix
inventory.instances = {
  # One instance per segment: DHCP defaults on the role, NIC names per link.
  home-net = {
    module.input = "clanServices";
    module.name = "netif";
    roles.default.settings = {              # site/segment defaults
      dhcp.ipv4 = true;
      mtu = 1500;
      nameservers = [ "192.168.10.1" ];
    };
    roles.default.machines = {
      kamrui-h1.settings.links.dock = { interface = "enp4s0"; };  # dock NIC (Wi-Fi is iwd's, N5)
      nas.settings.links.eth = { interface = "enp3s0"; };  # different NIC, same defaults
    };
  };

  # Multi-NIC router: one SFP+ link per uplink instance.
  uplink-a = {
    module.input = "clanServices";
    module.name = "netif";
    roles.default.machines.edge-1.settings.links.sfp0 = {
      interface = "enp1s0f0np0";
      static.ipv4 = [ "203.0.113.2/30" ];
      gateway.ipv4 = "203.0.113.1";        # the host's one default route
      endpoint = true;                     # exported to routed-fabric
    };
  };
  uplink-b = {
    module.input = "clanServices";
    module.name = "netif";
    roles.default.machines.edge-1.settings.links.sfp1 = {
      interface = "enp1s0f1np1";
      static.ipv4 = [ "198.51.100.2/30" ]; # no gateway: cross-instance check
    };
  };
};
```

A second instance may add static routes without adding another default
route. For example, when `home-net` supplies the default through DHCP, a
`lab-net` link uses `routes = [ { destination = "192.0.2.0/24"; gateway =
"192.0.2.1"; } ];` rather than `gateway.ipv4`.

## Status

Multi-instance, multi-link inventory renders exclusively through IfState
2.5.1 (D61). Live static apply/check/restore and DHCPv4/SLAAC/default-route
suites are green. `netif-dhcp` proves leases, per-link DNS, a renewal,
a real cable loss, five link flaps, prefix delegation, restarts after a
crash, and that a reapply changes nothing. Eval and VM coverage includes VLAN/bond/
bridge links, on-link/policy routes, cross-instance ownership/default-route/
DNS checks, export defaults, and routed-fabric endpoint consumption.
