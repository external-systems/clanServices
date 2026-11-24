# Home and on-prem router

**Built (2026-11-24), first cut: one WAN.** The `router` service turns
a NixOS machine with several network ports into the edge of a LAN. The
ports, their names, their addresses and the WAN lease are netif's
([Home router](../netif/router.md)); the router reads them and never
repeats them.

```nix
inventory.instances.edge = {
  module.name = "router";
  module.input = "clanServices";
  roles.router.machines.router.settings = {
    zones = {
      dev.allowTo = ["servers" "mgmt"];
      servers = {};
      home.allowTo = ["iot"];
      iot = {};
      guest = {};
      mgmt.internet = false;
    };
    domain = "home.arpa";
  };
};
```

Each zone name is a netif zone label. From netif the router takes:

- the zone's links;
- its own address in the zone (the first IPv4 and IPv6 address of the
  zone's link): the gateway, the DHCP router and the zone's resolver;
- the zone's /64 of the delegated prefix (netif's
  `prefixDelegation.assign`).

DHCP hands out the upper half of the zone's IPv4 subnet. SSH to the
router is open from every zone (`ssh = false` closes it for a zone).
Proof: the suite `router`, the checks of the stand-in suite
`gateway-router` run on the service.

## What runs on it

| Job | Tool |
|---|---|
| IPv4 addresses for devices | kea |
| IPv6 router advertisements | corerad |
| DNS, with ad blocking | CoreDNS |
| Firewall between zones, NAT | nftables |
| Translation from IPv6 to IPv4 (optional) | Jool |

## Dual-stack is the base

Every zone offers IPv4 (DHCP, private addresses, NAT) and IPv6 (public
addresses from the prefix your ISP delegates). This is the default and
the first thing tested.

IPv6 has no NAT in front of devices, so the firewall drops inbound IPv6
unless you open something.

A probe on 2026-11-20 ran this base with netif's links: leases, a
delegated prefix on two zones, advertisements from corerad, NAT, and
no traffic between the zones.

## When the ISP changes your prefix

Your devices build their IPv6 addresses from the ISP's prefix. When the
ISP hands out another one, devices keep using the old addresses for
hours, and IPv6 to the internet stops working for them. The probe
showed this with corerad and with radvd.

The router therefore reacts to the change itself:

- it tells devices that the old prefix is retired (they switch within
  seconds);
- it moves the public Service addresses to the new prefix;
- it remembers the last prefix across a reboot.

## Zones

The LAN is split into zones. Traffic between two zones must pass the
router's firewall, and the default is deny.

| Zone | Who | Internet | May reach |
|---|---|---|---|
| `dev` | developer computers | yes | `servers`, `mgmt` |
| `servers` | Kubernetes nodes | yes | nothing |
| `home` | phones, watches, laptops | yes | `iot` |
| `iot` | smart speakers, TVs, consoles | yes | nothing |
| `guest` | visitors | yes | nothing |
| `mgmt` | switch, access points, the optical module | no | nothing |

So a smart speaker or a phone cannot reach a Kubernetes node or a
developer computer, and both still have internet.

What to know:

- **A zone is a port or a VLAN.** A router port is a zone by itself. A
  port can also be a trunk that carries several zones as VLANs.
- **Wi-Fi: one network name per zone.** The access point maps each name
  to a VLAN. You pick the name once per device; nothing else is set up.
- **The router cannot separate two devices in the same zone.** Turn on
  client isolation on the access point for `guest` and `iot`.
- **Finding a TV from a phone** across zones needs an mDNS reflector.
  It is off unless you turn it on for a pair of zones.
- **Each zone needs its own IPv6 /64.** A delegated /60 gives 16.

## Hardware

```
router ── port 1 ── WAN (optical module)
       ── port 2 ── servers (Kubernetes nodes)
       ── port 3 ── dev
       ── port 4 ── trunk ── PoE switch ── access points
                                            ├ network "home"  → VLAN home
                                            ├ network "iot"   → VLAN iot
                                            └ network "guest" → VLAN guest
```

- A managed switch is not strictly needed: a trunk port can go straight
  to one access point.
- You need one when several zones share a cable through a switch, which
  is the case with two or more access points. Access points also need
  power over Ethernet, so one small managed PoE switch is the usual
  answer.
- An unmanaged switch on a router port puts all its devices in that
  port's zone.

## DNS

CoreDNS answers for the house and forwards to Cloudflare over TLS.

- Your ISP cannot read the queries. It still sees which addresses you
  connect to.
- **Ad blocking** takes a hosts file today (setting `dns.blocklist`).
  The plan: HaGeZi's blocklists, which are free and open source
  (GPL-3.0), pinned in the `pkgs` repo and updated with a lock bump,
  with a strictness tier (default Pro++). That package does not exist
  yet. A list of 300 000 names cost about 140 MB of memory in the probe
  and answered at once.
- Each zone has its own resolver address, and only that zone may ask
  it. Nothing on the WAN side can.
- A device that uses its own encrypted DNS skips the blocklist.
- Device names come from mDNS and from static records. Machines you
  name are kept in Cloudflare.

## Options

| Option | Default | What it does |
|---|---|---|
| Private IPv6 prefix (ULA) | what netif declares | A second, stable prefix beside the public one: give each zone link a ULA address in netif. Service addresses and firewall rules survive a change of the ISP's prefix. A generated /48 is planned |
| IPv6-mostly | off, **frozen** | Devices that can cope drop IPv4 by themselves (DHCP option 108). Not built; `pref64` only advertises a NAT64 prefix |
| Service prefix | off | `servicePrefix`: one /64 of the ISP's block for public Kubernetes Service addresses, rewritten to a stable private /64; `expose` opens pinholes. A LAN host that calls a public Service address is answered through the router (hairpin). See [Exposing services](exposure.md) |
| Metrics | localhost only | CoreDNS on `[::1]:9153`, corerad on `[::1]:9430`. On the fabric address: planned (G18) |

IPv6-mostly brings no speed. It saves IPv4 leases, which matters on
large sites, not at home.

## A second WAN

Frozen: built after the single-WAN router is proven (decided
2026-11-23).

**One router, two WANs** (fiber plus a SIM or satellite modem):

- IPv4: both WANs get a default route; the backup has a higher metric.
  A health check tests the upstream, not just the cable.
- IPv6: the LAN keeps one prefix. On the backup WAN the router rewrites
  the prefix (NPTv6).
- Open connections reset on failover.
- A probe on 2026-11-20 showed it with fixed addresses: 6 seconds to
  the backup, 4 seconds back, for both IPv4 and IPv6. The switch
  changes one firewall rule and no route, so nothing else on the router
  can undo it.
- A modem that offers plain Ethernet with DHCP is the simplest: to netif
  it is just one more WAN port.

**Two routers, two carriers** (an office with two fibers), design only:

- Devices see one gateway: a shared virtual IPv4 address (VRRP), IPv6
  advertisements from both routers, and a DHCP server pair.
- A router whose fiber fails steps back and can still forward through
  the other.
- Two ways to face the carriers:

| Mode | How | Inbound addresses on failover |
|---|---|---|
| `dhcp` | each router NATs to its own carrier | change |
| `bgp` | the site has its own AS number and prefixes; FRR peers with both carriers | stay |

The `bgp` mode uses the fabric border, see
[Your own address block](exposure.md#your-own-address-block).

## What netif still needs for this

- A MAC override on the WAN port, so the router can stand in for the
  ISP's gateway. Proven in a probe; the option is a small change.
- VLAN 0 on the WAN, which some ISPs use. Proven in a probe: netif
  renders a VLAN link with id 0, and the ISP's side ignores the router
  without it.
- A signal when the delegated prefix changes, for the section above.
- One default route per WAN, for the second WAN.
- A subnet of the ISP's block that no link receives, for the service
  prefix.
