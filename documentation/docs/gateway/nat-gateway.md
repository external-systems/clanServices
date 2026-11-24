# Cloud NAT gateway

**Built (2026-11-24), first cut.** Cloud machines in the clan get **no
IPv4 address on their network cards**, because a public IPv4 costs
money. The `nat-gateway` service gives them a way to IPv4-only sites
such as GitHub. Contract: `specs/gateway.md` G1–G6, G23, G24.

## Roles

| Role | Machine | Does |
|---|---|---|
| `gateway` | a fleet machine with a public IPv4 | translates IPv6 to IPv4 (NAT64) for its clients |
| `client` | an IPv6-only machine | runs a CLAT that sends its IPv4 to a gateway |

A gateway is a role, not a dedicated machine:

- **gateway:** a machine that **has** a public IPv4 and **lends** it;
- **client:** a machine that **has no** IPv4 and **borrows** it;
- **neither:** a machine with its own IPv4 that lends nothing. Most
  machines, for example the home box behind its ISP.

With three machines, two carry an IPv4 and the gateway role, and one is
IPv6-only and a client. A machine is never both: a gateway has its own
IPv4 (decided 2026-11-24).

**Kubernetes is a separate question.** A pod's IPv4 leaves through its
node. On a node with IPv4 (a gateway, or a machine with no role), Cilium
hides the pod behind that IPv4. Only a node without IPv4 is a client.
A gateway may be a Kubernetes node.

```nix
inventory.instances.nat64 = {
  module.name = "nat-gateway";
  module.input = "clanServices";
  roles.gateway.machines = {
    gw1.settings = {
      pool6 = "2001:db8:a1:0:64::/96";
      address = "2001:db8:a1::1";
      health.targets = ["1.1.1.1" "8.8.8.8" "9.9.9.9"];
    };
    gw2.settings = {
      pool6 = "2001:db8:a2:0:64::/96";
      address = "2001:db8:a2::1";
      health.targets = ["1.0.0.1" "8.8.4.4" "149.112.112.112"];
    };
  };
  roles.client.machines.node1.settings.clat.address = "2001:db8:c::c1a7";
};
```

netif must run on every machine. The gateway's public IPv4 link and the
client's uplink are in the zone `wan` (setting `uplinkZone`).

## How a client reaches an IPv4 site

Every client runs a **CLAT**: a small Jool instance that turns the
machine's own IPv4 packets into IPv6 towards a gateway.

1. A program asks for a name. The client's normal resolver answers
   with the site's IPv4 address.
2. The program sends IPv4. The machine's IPv4 default route leads into
   the CLAT.
3. The CLAT turns the packet into IPv6, addressed into the gateway's
   own prefix.
4. The gateway translates to IPv4 and sends it from its public IPv4.

This covers names, IPv4 addresses written as numbers, and programs that
only speak IPv4. **There is no DNS64** (removed 2026-11-24): name
lookups never depend on a gateway.

The gateway does not sit in the path of other traffic, and no tunnel or
fabric is needed. A machine with a broken fabric can still fetch its
own fix.

## Who translates what

| Traffic | Translator |
|---|---|
| IPv6 to IPv6 | nobody; it goes direct |
| The machine itself to an IPv4 site | its CLAT, then NAT64 on a gateway |
| A pod using its IPv4 address | the same: Cilium hides the pod behind the CLAT |

Jool does all translation. **On the gateway Jool gets a network
namespace of its own.** In the machine's main namespace Jool takes
packets before the firewall's forward rules; a gateway set up that way
relayed traffic from a machine that was not a client.

## Only clients, and only so much

- The gateway's own firewall table lets through only the clients'
  addresses: each client's CLAT address, the IPv6 addresses netif
  declares on its uplink, and its `sources`. Everything else is dropped
  and counted, for every protocol.
- A destination inside a private IPv4 range is refused.
- **A rate limit per client address**, in two tiers:

  | Tier | New connections | Packets |
  |---|---|---|
  | `default` | 50 a second, burst 200 | 20 000 a second, burst 40 000 |
  | `trusted` | 1 000 a second, burst 4 000 | 200 000 a second, burst 400 000 |

  Members of a Kubernetes cluster are `trusted` without a setting. A
  node's pods share its tier. The limit is on a source address, which
  is not a credential: a spoofer of a trusted address gets the higher
  limit.
- **Every number can be changed**, the most specific setting wins:

  ```nix
  # every gateway of the instance
  roles.gateway.settings.limits.default.newFlows = 100;
  # one gateway
  roles.gateway.machines.gw2.settings.limits.trusted.packets = 100000;
  # one client, on every gateway (the other numbers stay its tier's)
  roles.client.machines.node1.settings.limits.packets = 5000;
  ```

## Redundancy

- **Two gateways by default,** both active. Each translates to **its
  own** public IPv4, so answers come back to the gateway that knows the
  connection. Nothing is synchronized.
- **Stability over speed** (decided 2026-11-24). A healthy gateway
  never looks sick, and a sick one never looks healthy, given time to
  settle. Failover takes about a minute and a half.
- **Each gateway checks itself.** Once a second it pings its targets
  (three or more, in different networks) through its own translator.
  A second is good when two targets answer.
  - It counts as **sick** when half of the last 60 seconds were bad: a
    dead upstream after 30 s, a very lossy one soon after.
  - It counts as **healthy again** only after 120 clean seconds. One
    lucky ping does not bring it back.
  - One dead target, or one that flaps, changes nothing.
  - A restart of the check alone (a deploy) keeps its state.
- **A health beacon** tells clients a gateway is fine. While healthy,
  the gateway answers one name, `ipv4only.arpa`, with its own prefix.
  When sick, it stops answering at once. The beacon answers nothing
  else; it is not a DNS server for the client.
- **A client's CLAT follows a live gateway.** A small check asks the
  beacons. When its gateway's beacon has not answered for 60 s, it
  moves the CLAT to a gateway whose beacon answers. It never moves back
  on its own. When no beacon answers it stays where it is.
- **Connections through a dead gateway hang.** Nothing tells the client
  that the gateway is gone, so a program notices through its own
  timeout. New connections go through the other gateway. This is
  failover, not seamless high availability.
- The number of public IPv4 addresses you pay for equals the number of
  gateways.

## Pods and IPv4

Clusters stay dual-stack inside. On an IPv6-only node a pod's IPv4
traffic goes through the node's CLAT:

- the k3s and rke2 services add the CLAT's link and the node's
  IPv6-only network card to Cilium's devices by themselves (SPEC.md
  D71). Nothing is set by hand. On a gateway node they add its uplink,
  so its pods leave with its public IPv4;
- Cilium then hides pods behind the CLAT's address for IPv4, and behind
  the card's address for IPv6;
- a VPN link such as `tailscale0` is never added; the services refuse
  it.

The alternative stays documented and tested: the CLAT maps the whole
pod range one to one into a prefix of the node, so the gateway sees
which pod sent a packet.

## Proof

| Suite | What it shows |
|---|---|
| `nat-gateway` | two gateways, a `default`, a `trusted` and a client with its own limit, an outsider: translation, the allowlist, the limits, the beacon, failover, one target dead or flapping, all targets dead, 80 % loss, a broken translator, a deploy, reboots |
| `nat-gateway-kube` | a gateway that is a k3s node, and a node behind it: pods on both reach IPv4; two masquerades share one public IPv4 under load; no NodePort on the public IPv4 |
| `k3s-clat`, `rke2-clat` | a two-node cluster on IPv6-only cards behind the service: pods reach IPv4 through the node's CLAT, IPv6 through the card |

## Not built yet

- Metrics on the fabric address (G18). The counters have stable names
  and the health check writes its state to a file, ready for an
  exporter.
