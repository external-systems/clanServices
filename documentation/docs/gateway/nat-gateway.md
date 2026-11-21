# Cloud NAT gateway

Planned. Cloud machines in the clan get **no IPv4 address on their
network cards**, because a public IPv4 costs money. The `nat-gateway`
service gives them a way to IPv4-only sites such as GitHub.

## Roles

| Role | Machine | Does |
|---|---|---|
| `gateway` | a fleet machine with a public IPv4 | translates IPv6 to IPv4 (NAT64) and answers DNS with DNS64 |
| `client` | an IPv6-only machine | uses the gateways as DNS servers |

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

Probes decided on 2026-11-20 and 2026-11-21. B works on both
transports (the routed fabric with native routing and the WireGuard mesh
tunnel) and on k3s and rke2, with IPv6-only network cards. Two ways to
do it both pass:

| | Map the pod pool | Let Cilium hide the pods |
|---|---|---|
| How | the CLAT maps the cluster's pod pool one to one into a prefix of the node | the CLAT link is added to Cilium's devices; Cilium hides pods behind the CLAT's address |
| Needs a prefix routed to each node | yes | no |
| The gateway sees which pod | yes | no |
| Tested | k3s and rke2 | k3s |

The proposal is the second: less to set up. You decide.

Out of the box neither happens: a pod's packet reaches the CLAT with
the pod's own address and gets no answer.

## Redundancy

- **Two gateways by default,** both active.
- Each translates to **its own** public IPv4, so answers come back to
  the gateway that knows the connection. Nothing is synchronized.
- A client lists both gateways as DNS servers. When one dies it stops
  answering DNS, and the client gets addresses that lead to the other.
  Measured: 5.6 seconds.
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
