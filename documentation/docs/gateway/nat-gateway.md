# Cloud NAT gateway

Planned. Cloud machines in the clan get **no IPv4 address on their
network cards**, because a public IPv4 costs money. The `nat-gateway`
service gives them a way to IPv4-only sites such as GitHub.

## Roles

| Role | Machine | Does |
|---|---|---|
| `gateway` | a fleet machine with a public IPv4 | translates IPv6 to IPv4 (NAT64) |
| `client` | an IPv6-only machine | runs a CLAT that sends its IPv4 to a gateway |

**Decided 2026-11-23:** the CLAT is the only path. DNS64 is frozen:
it is not built until a machine that cannot run a CLAT needs it
(`specs/gateway.md` §14.1). Clients use any IPv6 resolver. The DNS64
text below describes the frozen design.

A gateway is a role, not a dedicated machine. With three machines, two
carry an IPv4 and the role, and one is IPv6-only.

## How a client reaches an IPv4 site

1. The client asks a gateway's DNS for a name.
2. The name has only an IPv4 address, so the DNS invents an IPv6
   address inside the gateway's own prefix.
3. The client sends plain IPv6 to that address.
4. The gateway translates to IPv4 and sends it from its public IPv4.

The gateway does not sit in the path of other traffic, and no tunnel or
fabric is needed. A machine with a broken fabric can still fetch its own
fix. Each gateway only serves its declared clients, for translation and
for DNS.

A probe proved this path on 2026-11-20, with two gateways.

## Who translates what

| Traffic | Translator |
|---|---|
| IPv6 to IPv6 | nobody; it goes direct |
| The machine itself to an IPv4 site | NAT64 on a gateway |
| A pod using its IPv4 address | see below |

Jool does all translation. It runs in the kernel, and one tool covers
both the stateful and the stateless kind.

**Jool gets a network namespace of its own on the gateway.** A probe
showed why: in the machine's main namespace Jool takes packets before
the firewall's forward rules and hands them back after, so the firewall
never sees them. A gateway set up that way relayed traffic from a
machine that was not a client. In its own namespace the ordinary
firewall rules apply.

## IPv4 addresses written as numbers

DNS64 only helps when a program asks for a name. A program that
connects to `198.51.100.80` directly needs a **CLAT** on the machine:
a small Jool instance that turns the machine's own IPv4 packets into
IPv6 towards a gateway. A probe proved it for a plain machine.

A CLAT points at one gateway. The client therefore runs a health check
that moves it to a live gateway. In the probe one command moved it.

## Pods and IPv4

Clusters stay dual-stack inside. Two ways for a pod's IPv4 traffic to
leave an IPv6-only node:

- **B, chosen:** the node itself turns the pod's IPv4 into IPv6 (a
  CLAT), and it takes the same road as above.
- **A, the fallback, unused:** carry it over the fabric to a gateway
  that does ordinary NAT.

B works on both transports (the routed fabric with native routing and
the WireGuard mesh tunnel) and on k3s and rke2, with IPv6-only network
cards. Test suites keep it proven.

**How, decided 2026-11-21:** the CLAT's link is added to Cilium's
devices. Cilium then hides pods behind the CLAT's address, as it does
for all other traffic that leaves the cluster. A node needs one
address and no extra prefix.

The alternative stays documented: the CLAT maps the cluster's pod pool
one to one into a prefix of the node. The gateway then sees which pod
sent a packet, at the cost of a routed prefix per node.

Out of the box neither happens: a pod's packet reaches the CLAT with
the pod's own address and gets no answer. A suite checks that too, so
a Cilium update that changes it is noticed.

## Redundancy

- **Two gateways by default,** both active.
- Each translates to **its own** public IPv4, so answers come back to
  the gateway that knows the connection. Nothing is synchronized.
- A client lists both gateways as DNS servers. When one dies it stops
  answering DNS, and the client gets addresses that lead to the other.
  Measured: 6 to 10 seconds.
- A machine's CLAT follows one gateway. A small check moves it to the
  other one after 8 failed checks in a row: 13 to 15 seconds after a
  crash, and not at all on a gateway that only loses some packets.
- A gateway checks its own IPv4 upstream. When that fails it stops
  answering DNS, so name lookups move to the other gateway too
  (8 seconds after the upstream died), and CLATs follow.
- The CLAT's check keeps no notes of its own. It reads the translator's
  setting each round, and stays where it is when no gateway answers.
- Only declared clients get through, for every kind of traffic. The
  review of 2026-11-21 found that anyone could ping the IPv4 internet
  through a gateway; that is closed.
- **Open:** each check tests one address. If that address is down, a
  healthy gateway looks sick. A check needs several targets.
- **Connections through a dead gateway hang.** Nothing tells the client
  that the gateway is gone, so a program notices through its own
  timeout. New connections go through the other gateway. This is
  failover, not seamless high availability.
- Gateways keep DNS answers short-lived, so a program that caches them
  does not hold on to a dead gateway for long.
- The number of public IPv4 addresses you pay for equals the number of
  gateways.

## Clusters on IPv6-only machines

A node needs an IPv4 address, but not on its card. Every fabric node
already has a stable private IPv4 and an IPv6 address on a loopback, and
Kubernetes uses those. IPv4 only exists inside the fabric, so it costs
nothing. This is decision D67. A probe showed k3s and rke2 each joining
a second node with no IPv4 on any network card.

## What netif still needs for this

A test suite for a machine with no IPv4 at all (`netif-v6only`):
address, link-local gateway, DNS, the lockout guard and "online".
