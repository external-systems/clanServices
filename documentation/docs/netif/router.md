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

## Ports by MAC

Each SFP+ port is declared with `match.mac` and a short logical name
(`wan`, `lan1`, …). IfState finds the NIC by its permanent MAC and renames
it, so a kernel or driver change cannot swap ports. If a declared port is
missing, `ifstate.service` fails and the journal names it
(`netif-match` suite).

## Prefix delegation (planned, N3b)

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
advertisement handling stays with IfState, and DNS goes to
systemd-resolved.

## Zones (planned, N3b)

Each link can carry a `zone` label (`wan`, `lan`, `mgmt`). netif does not
interpret it. It publishes each link's Linux name, kind and zone under
`clanServices.networking.links.<instance>.<link>`, and the router module
uses those.

## Planned later

- the router module in `modules`;
- a full `netif-router` suite with a prefix change and a reboot.

Both are phase N5 of the [plan](plan.md).
