# Home router

The router has four SFP+ ports: one 10G WAN through an XGS-PON stick, three
LAN. It does NAT, hands out DHCP and IPv6 addresses to the house, and runs
headless.

## Who owns what

| Owner | Objects | Lives in |
|---|---|---|
| netif (IfState) | the four ports, found by permanent MAC; VLANs and bridges; LAN addresses; forwarding sysctls; static routes | inventory |
| dhcpcd, started by a netif hook | WAN DHCPv4 lease; DHCPv6 prefix delegation; the delegated `/64`s on LAN links | inventory (netif link settings) |
| nftables | NAT and the firewall | `modules` |
| kea | the DHCP server for the house | `modules` |
| radvd or corerad | router advertisements | `modules` |
| pppd | PPPoE, only if the ISP needs it | `modules` |

netif publishes each link's Linux name and a zone (`wan`, `lan`, `mgmt`) as
read-only NixOS options. The router module in `modules` uses those names and
never reads the inventory.

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

## Planned

- `match.mac` (pick ports by MAC);
- prefix-delegation settings;
- the zone seam;
- a full `netif-router` suite with a prefix change and a reboot.

All in phases N3 and N5 of the [plan](plan.md).
