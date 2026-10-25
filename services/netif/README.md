# netif

`netif` is the inventory-facing clanService for core host network
configuration (round 15/16, D50/D53). It replaces static IP ownership by
home's `hostSpec.networking` and `machines.json`; borg's `lan` service is
the behavioral reference. It is **multi-instance and multi-link**: one
instance describes a network segment (a site LAN, a public uplink, an
SFP+ group) with segment defaults plus per-machine and per-link
overrides, and a host joins as many instances as it has attachments.

## Roles

- `default` — a machine attached to this segment. Exactly one role;
  every machine declares one or more logical links under
  `roles.default.machines.<name>.settings.links.<logical>`.

## Links

Link kinds: `physical` (a named `interface`), `vlan` (`vlan.id` +
`vlan.parent` naming another link in the same instance), `bond` and
`bridge` (`bond.members` / `bridge.members` naming physical links in the
same instance; an empty bridge is declared with `kind = "bridge"` for
provider-MAC plumbing). VLAN parents and bond/bridge members must be
links of the same instance on the same machine; a physical link consumed
as a member carries no addressing of its own.

Addressing per link: static IPv4/IPv6 (`static.ipv4` / `static.ipv6`
with prefixes), `dhcp.ipv4` / `dhcp.ipv6` (null inherits the segment
default), and IPv6 router advertisements (`ra`). Exactly one mode per
address family. Gateways (`gateway.ipv4` / `gateway.ipv6`, optionally
`gateway.onLink`), static `routes`, underlay `routingPolicy` (source and
destination selectors into a non-200 table; netif owns underlay policy
routing — routed-fabric owns fabric policy), per-link `mtu`, `nameservers`
(segment defaults apply when empty), and `firewall.trust`.

Segment defaults live on `roles.default.settings`: `mtu`, `nameservers`,
`dhcp.ipv4` / `dhcp.ipv6`, `gateway.ipv4` / `gateway.ipv6`, and
`firewall.trust`; per-link values override them.

## Cross-instance checks (D53)

A machine may join several netif instances. Eval rejects: the same
interface owned by more than one instance, more than one default route
per address family (DHCP lease defaults count), and DNS nameserver sets
that overlap while differing between instances (identical or disjoint
sets are allowed). Every rendered unit is instance-namespaced
(`40-netif-<instance>-<link>`).

## Exports

- `peer` (standard): `peer.hosts` carries the machine endpoint first
  (explicit `endpoint`, else ordered `endpointSources` peer exports),
  then each `endpoint = true` link's static addresses (IPv4 then IPv6).
  `peer.user` carries the SSH user. routed-fabric consumes these for
  WireGuard endpoint discovery.
- `netif` (custom, versioned `schemaVersion = 1`): resolved per-link
  kind/interface/MTU/addresses/gateways/DNS plus the machine `endpoint`
  and the effective underlay `mtu` (smallest link MTU) that routed-fabric
  derives WireGuard MTUs from.
- `networking` (standard): instance priority 1100 (direct underlay,
  before VPN overlays).

Everything renders with systemd-networkd and normal NixOS options — no
IFD, no parallel option namespace. `targetHost = true` exports the
machine as its own clan deploy target
(`clan.core.networking.targetHost`), resolved from the endpoint.

## Inventory example

```nix
inventory.instances = {
  home-net = {
    module.input = "clanServices";
    module.name = "netif";
    roles.default.settings = {
      mtu = 1500;
      nameservers = [ "192.168.10.1" ];
    };
    roles.default.machines.kamrui-h1.settings = {
      targetHost = true;
      links.wifi = {
        interface = "wlp2s0";
        dhcp.ipv4 = true; # inherits the site mtu default
      };
    };
  };
  uplink-a = {
    module.input = "clanServices";
    module.name = "netif";
    roles.default.machines.edge-1.settings.links.sfp0 = {
      interface = "enp1s0f0np0";
      static.ipv4 = [ "203.0.113.2/30" ];
      gateway.ipv4 = "203.0.113.1"; # the host's one default route
      endpoint = true; # exported to routed-fabric
    };
  };
};
```

Static core addresses and routes live in `inventory.nix`; a public fleet
repo may interpolate sensitive public-topology values from its
`secrets`/`not-secret` input (public on the deployed machine, not clan
vars). Supporting NixOS modules may configure Wi-Fi association or driver
quirks, never a parallel static data plane.
