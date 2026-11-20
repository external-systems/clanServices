# Router and NAT gateway

Two services are planned for this repo. Nothing on these pages is built
yet: this is the design you decided on 2026-11-20. The contract is
`specs/gateway.md` (decisions G1 to G19).

| Service | What it is | Who uses it |
|---|---|---|
| `router` | The edge of a LAN: DHCP, router advertisements, DNS, the zone firewall, NAT | Any device, with nothing to set up on it |
| `nat-gateway` | IPv4 reach for clan machines that have no IPv4 address | NixOS machines in the clan |

Both sit on top of [netif](../netif/index.md). netif owns the links and
labels each with a zone. These services read the labels and never
declare a link themselves. They share one private library, so NAT, DNS
and the firewall are written once.

They live here, not in the `modules` repo, so that a consumer needs one
flake for all networking.

## Principles

1. **No IPv4-only networks.** They cannot reach IPv6-only machines.
2. **Clan machines use IPv6 only on their network cards** where
   possible. A public IPv4 costs money in the cloud.
3. **Kubernetes stays dual-stack inside.** Applications hard-code IPv4.
4. **A home or office LAN serves any device** with nothing to set up on
   the device. IPv4 stays on offer there.
5. **Systemd runs what you need to reach or repair a cluster.**
   Everything else runs in Kubernetes.
6. **The safest option wins.**
7. **Components with built-in Prometheus metrics are preferred.**

## What is possible

| Question | Answer |
|---|---|
| Can an IPv6-only machine reach IPv4 sites? | Yes, through a gateway that translates (NAT64) |
| Can an IPv4-only machine reach IPv6 sites? | No, not in general. An IPv6 address does not fit in an IPv4 one |
| Can a machine translate for itself? | Half. Reaching IPv4 needs a public IPv4 somewhere, so the last step runs on a gateway |
| Can a home LAN be IPv6-only? | No. A device that only speaks IPv4 needs IPv4 on its own link. "IPv6-mostly" is the ceiling |
| Can a dual-stack cluster run on IPv6-only machines? | Yes. The IPv4 a node needs is a private fabric address, not a card address. To be proven by a probe |

## Where each network ends up

| Network | Design |
|---|---|
| Home | Dual-stack, split into zones. IPv6-mostly is an option. See [Home and on-prem router](router.md) |
| Cloud | IPv6-only cards, two gateways with a public IPv4 each. See [Cloud NAT gateway](nat-gateway.md) |
| Inside a cluster | Dual-stack, as today |

## Pages

- [Home and on-prem router](router.md) — zones, hardware, DNS, IPv6, a
  second WAN.
- [Cloud NAT gateway](nat-gateway.md) — IPv6-only machines, translation,
  redundancy.
- [Exposing services](exposure.md) — three classes, Headscale, metrics.
- [Plan and probes](plan.md) — what is checked first and the build
  order.
