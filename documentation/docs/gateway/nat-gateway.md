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
fix. Each gateway only serves its declared clients.

## Who translates what

| Traffic | Translator |
|---|---|
| IPv6 to IPv6 | nobody; it goes direct |
| The machine itself to an IPv4 site | NAT64 on a gateway |
| A pod using its IPv4 address | see below |

Jool does all translation. It runs in the kernel, and one tool covers
both the stateful and the stateless kind.

## Pods and IPv4

Clusters stay dual-stack inside. Two ways for a pod's IPv4 traffic to
leave an IPv6-only node:

- **B, the target:** the node itself turns the pod's IPv4 into IPv6 (a
  CLAT), and it takes the same road as above.
- **A, the fallback:** carry it over the fabric to a gateway that does
  ordinary NAT.

A probe decides. B needs no fabric and uses one mechanism for
everything, but it is untested with Cilium.

## Redundancy

- **Two gateways by default,** both active.
- Each translates to **its own** public IPv4, so answers come back to
  the gateway that knows the connection. Nothing is synchronized.
- A client lists both gateways as DNS servers. When one dies it stops
  answering DNS, and the client gets addresses that lead to the other.
- **Connections through a dead gateway reset** and are opened again
  through the other. This is failover, not seamless high availability.
- The number of public IPv4 addresses you pay for equals the number of
  gateways.

## Clusters on IPv6-only machines

A node needs an IPv4 address, but not on its card. Every fabric node
already has a stable private IPv4 and an IPv6 address on a loopback, and
Kubernetes uses those. IPv4 only exists inside the fabric, so it costs
nothing. This is decision D67, and a probe comes before any code.

## What netif still needs for this

A test suite for a machine with no IPv4 at all (`netif-v6only`):
address, link-local gateway, DNS, the lockout guard and "online".
