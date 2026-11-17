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

Link kinds: `physical` (a named `interface`, or `match.mac` to find the
NIC by permanent MAC and rename it to the logical link name, at most 15
characters), `vlan` (`vlan.id` +
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

`extraSettings` is a checked IfState passthrough merged into the link's
interface: IfState's schema validates it at build time, and setting a
key netif already renders is an eval error. A declared physical NIC that
is missing after IfState applies fails `ifstate.service` and is named in
the journal (specs/netif.md N15).

## Cross-instance checks (D53)

A machine may join several netif instances. Eval rejects: the same
interface owned by more than one instance, more than one default route
per address family (DHCP lease defaults count), a delegated prefix
assigned to a missing link or to two links' worth of sources, and
cross-instance policy-table or effective rule-priority collisions. DNS
is per link, so instances cannot conflict over it. RA-enabled links use `accept_ra = 2` on
forwarding machines. Literal deploy targets may not name fabric, transfer,
or tunnel addresses.

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

Everything renders to `networking.ifstate.settings` for IfState 2.5.1 —
no systemd-networkd, netdevs, scripted network units, or IFD. Applying a
new generation reconciles links, addresses, routes, rules, and sysctls live
through `ifstate.service`; no reboot is needed.

Beside IfState, netif runs (`host.nix`):

- one supervised `netif-dhcpcd-<interface>.service` per DHCP link, with
  its own config (upstream dhcpcd 10.5, no RA handling, no stock hooks).
  `dhcp.prefixDelegation` asks for a prefix and assigns subnets of it to
  other links of the machine;
- `defaultRoute.{ipv4,ipv6}` per link (and as a segment default) say
  whether the link may carry the machine's default route; one link per
  family may, and a link with `ra = true` counts for IPv6. Every
  default route has metric 100 (`clanServices.netif.routeMetric`);
- links are firewall-untrusted unless `firewall.trust` is set on the
  link or the segment; netif opens UDP 546 on DHCPv6 links itself;
- `zone` labels a link for other modules, which read
  `clanServices.netif.zones.<zone>` (interface names) or
  `clanServices.networking.links.<instance>.<link>`;
- `match.path` finds a physical NIC by its udev path (a `.link` file
  renames it before IfState runs); cloud-init's network configuration
  is rejected next to netif;
- `pathMtu` is published per link and instance; routed-fabric and
  wireguard-mesh prefer it over the link MTU;
- the operator tools (`tools.nix`): `netif-status [--json]`,
  `netif-preview [system]` and the hourly `netif-drift.timer`, all
  read-only;
- `netif-dns.service`, which sets each link's DNS in systemd-resolved:
  the link's `nameservers` plus the servers of its DHCP leases;
- `netif-online.service`, which holds `network-online.target` until the
  DHCP links have an address, for at most
  `clanServices.netif.onlineTimeout` seconds.

IPv6 SLAAC uses the kernel's RA settings.
`targetHost = true` exports the machine as its own clan deploy target
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
      links.eth = {
        interface = "enp3s0";
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
