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
Proof: the suite `router` runs every check of the former stand-in
suite `gateway-router` on the service.

## A router that is also a Kubernetes node

Your home box is both. Since 2026-11-25 the service is built for it.

- **The router judges its own links only.** A router link is the WAN
  port or a zone's port. Every other link of the machine is *unzoned*:
  the cluster's WireGuard links, Cilium's links, a VPN. The normal
  NixOS firewall judges those, as on any machine.
- **Both firewalls run.** On a router link a packet must pass both.
- **Nothing crosses between the two sides unless you say so:**

| Setting | Default | Meaning |
|---|---|---|
| `unzoned.zones = ["home"]` | none | zone `home` and the cluster's pods and Services may reach each other, both ways |
| `unzoned.source.ipv4`, `.ipv6` | the outgoing port's address | the address such traffic appears to come from. On a node: set it to the node's cluster-network address, or pods on other nodes are unreachable |
| `zones.<zone>.hostPorts` | off | the zone may reach the ports the machine opens to everyone, such as the cluster network's WireGuard ports. Turn it on for the zone that holds your other nodes |
| `wanPorts.tcp`, `wanPorts.udp` | empty | ports of the router itself that the internet may reach |

- **The cluster always reaches the internet.** And a zone in
  `unzoned.zones` is open in both directions: Cilium sends a pod's
  packets straight out of the zone's port, past the router's firewall,
  so the router cannot tell who started a connection. A pod sees the
  router's address as the caller, not the LAN device's: the cluster
  network carries cluster addresses only. Use a Cilium
  network policy to narrow it. For a zone that is not listed the router
  drops what the zone sends to the cluster, so no connection forms.
- **Deploys over the WAN need `wanPorts.tcp = [22]`.** Without it the
  first deploy closes SSH from the internet. SSH from a zone is open by
  default.
- **Pods on the router leave with the WAN address.** The cluster
  service adds the WAN port to Cilium's device list by itself.
- **Port names must differ between the router's zones and other nodes'
  uplinks.** Cilium gets one list of port names for the whole cluster.
  If a zone port of the router has the same name as another node's
  uplink (two identical mini PCs, both `enp2s0`), Cilium would attach
  to the zone port and pass traffic by the router's firewall. The build
  refuses this and names the port; rename one of the two in netif.
- Three checks stop a broken setup before it is deployed: a zone is one
  port (use a bridge for several), a zone port does not accept router
  advertisements (`ra = false`), and the router's own address is in the
  lower half of the zone's IPv4 range (the upper half is handed out).

Before this change the router switched the NixOS firewall off and
dropped everything it did not know. On a node that silently removed the
cluster's firewall rules and blocked the cluster's own traffic.

Proof: suite `router-kube`, a k3s server that is the router, a second
node in a zone behind it, a LAN client and an internet host.

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
