# Home router

The router has four SFP+ ports on a PCIe card and one 10G RJ45 port. One
port is the WAN, through an XGS-PON stick. It does NAT, hands out DHCP and
IPv6 addresses to the house, and runs headless. It is also the fleet's
edge: FRR sends traffic for pod and Service IPs to the Kubernetes nodes
behind it over several equal paths.

Wi-Fi for the house comes from separate access points on the LAN. The
router has no radio.

## Who owns what

| Owner | Objects | Lives in |
|---|---|---|
| netif (IfState) | the five ports, found by permanent MAC; VLANs and bridges; LAN addresses; forwarding sysctls; static routes | inventory |
| dhcpcd, started by a netif hook | WAN DHCPv4 lease; DHCPv6 prefix delegation; the delegated `/64`s on LAN links | inventory (netif link settings) |
| nftables | NAT and the zone firewall | the `router` service |
| kea | the DHCP server for the house | the `router` service |
| corerad | router advertisements | the `router` service |
| CoreDNS | DNS for the house, with a blocklist | the `router` service |
| pppd | PPPoE, only if the ISP needs it | the `router` service |

netif publishes each link's Linux name and a zone (`wan`, `lan`, `mgmt`) as
read-only NixOS options. The `router` service uses those names and
never reads the inventory.

Since 2026-11-20 the router's services are planned as a clanService in
this repo, not in the `modules` repo, so a consumer needs one flake. The
design (zones, DNS, IPv6, a backup WAN) is on
[Router and NAT gateway](../gateway/index.md).

## What the probe showed

A router VM ran IfState with a dhcpcd hook on the WAN, nftables NAT, kea and
radvd, behind a simulated ISP that delegates a `/56`. The router:

- got its WAN lease and a delegated `/60`;
- put a `/64` on the LAN;
- served a LAN client DHCPv4 and SLAAC, and NATed the client to the ISP.

Rerunning IfState afterwards changed nothing: dhcpcd kept running, and the
delegated addresses and their routes stayed.

Two rules follow:
- **Declare every NIC.** IfState sets undeclared NICs down, so every port
  must be declared, even unused ones.
- **Nothing configures LAN links but IfState and dhcpcd.** Kea, radvd and
  nftables only read them.

## Ports by MAC

Each SFP+ port is declared with `match.mac` and a short logical name
(`wan`, `lan1`, …). IfState finds the NIC by its permanent MAC and renames
it, so a kernel or driver change cannot swap ports. If a declared port is
missing, `ifstate.service` fails and the journal names it
(`netif-match` suite).

## Prefix delegation (planned, P3b)

The WAN link asks for a prefix and hands `/64`s to LAN links, which may
sit in another netif instance:

```nix
links.wan.dhcp = {
  ipv4 = true;
  ipv6 = true;
  prefixDelegation = {
    enable = true;
    hint = 56;
    assign = [
      { instance = "lan"; link = "lan1"; subnet = 0; }
      { instance = "lan"; link = "lan2"; subnet = 1; }
    ];
  };
};
```

The delegated prefix only exists at runtime. netif publishes that a
link gets a delegation, never the prefix itself; the router module reads
the live prefix from the LAN link.

dhcpcd only handles leases and delegations here. The kernel's router
advertisement handling stays with IfState. A netif unit puts each link's
DNS servers into systemd-resolved.

A probe on 2026-11-16 confirmed that dhcpcd still gets a DHCPv6 address
and a delegated prefix when it is told to ignore router advertisements.

A second probe that day found a weakness that matters for a WAN port:
after the link lost and regained carrier, dhcpcd 10.3.2 did not get both
its DHCPv4 and its DHCPv6 lease back. It is a bug in dhcpcd, fixed
upstream. Our pkgs repo builds the upstream release that has the fix
(10.5.2, as `dhcpcd_latest`), and with it every flap recovered
([Plan and evidence](plan.md)).

## Zones (built 2026-11-17)

Each link can carry a `zone` label (`wan`, `lan`, `mgmt`). netif does not
interpret it. It publishes two read-only options, and the router module
uses those:

- `clanServices.netif.zones.<zone>`: the interface names of every link
  with that zone, for example `zones.wan = ["enp1s0f0np0"]`;
- `clanServices.networking.links.<instance>.<link>`: one link's Linux
  name, kind and zone.

## Lockout guard

The router is headless and remote changes are risky. After every apply,
netif checks that each default gateway still answers. If one does not
within 30 seconds, netif re-applies the previous network configuration
and fails the unit with the reason in the journal.

A probe on 2026-11-16 ran a prototype:

- **The check is layer 2.** The gateway in the probe ignored ping, and
  still answered `arping` (IPv4) and `ndisc6` (IPv6).
- **A bad change was rolled back.** A change that moved the machine to
  another subnet was undone: the old address and default route came
  back, the unit failed, and the deploy command reported a failure.
- **A good change was kept**, and became the new "last good"
  configuration.
- **A first boot has nothing to roll back to.** The guard then only
  fails loudly.
- **The rollback is whole** (2026-11-25). It also puts back the DHCP
  client settings, and it keeps the links that other services own
  (WireGuard, Cilium). Before, it restored the link file only.

After a rollback the machine runs the old network, but the new
generation is still the current one. A reboot tries the new
configuration again and rolls back again. Fix it by deploying a
corrected configuration.

The hardening round of 2026-11-26 closed the ways the guard could end
wrong:

- **A second check after a rollback records nothing.** Before, a
  restarted guard saw the old network answer and saved the bad
  configuration as "last good"; the next boot then applied it with
  nothing to go back to.
- **The guard judges only a configuration that was applied.** A deploy
  can start the guard before the network apply; that early run now
  waits for the real one.
- **A default route that was there must come back.** This catches an
  IPv6-only machine that loses its router advertisements, where the
  guard had nothing to check. To drop a default on purpose, set
  `defaultRoute.ipv4` or `defaultRoute.ipv6` to false on that link.
- **A DHCP link made static** gets its DHCP client back on a rollback.
- **A fault outside the machine** (a gateway that reboots during the
  deploy) no longer leaves the old network in place: when the old
  configuration cannot reach the gateway either, the guard puts the new
  one back and fails, so the deploy still reports it.
- **A failed apply** is checked too, and a gateway or address written
  wrong (for example with a prefix length) fails at evaluation.

## Done since

- the `router` service ([design](../gateway/router.md)), with its RA
  daemon CoreRAD (never radvd; radvd is only a test fixture);
- a MAC override on the WAN port, so it can stand in for the ISP's
  gateway, and a check of VLAN 0 on the WAN (`gateway-wan`);
- the `router` suite with a prefix change and a reboot. It replaces
  the planned `netif-router` suite.

These were phase P5 of the [plan](plan.md).
