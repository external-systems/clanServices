# Plan and probes

No service is built yet. The design was decided on 2026-11-20 and is
written down first. Probes answered the open questions; their results
are below and in `specs/gateway.md` §10.

Since 2026-11-21 every probe is a real test suite that checks its
result on every run:

| Suite | What it keeps proven |
|---|---|
| `gateway-wan` | MAC override and VLAN 0 on the WAN port |
| `netif-v6only` | a machine with no IPv4: names, IPv4 literals, path MTU, reboot |
| `gateway-nat64` | two NAT gateways, failover, the CLAT's health check |
| `gateway-router` | zones, DNS, advertisements, a prefix change, public Service addresses |
| `gateway-dual-wan` | two WANs with DHCP, failover and back |
| `k3s-v6only`, `rke2-v6only` | a cluster on IPv6-only machines |
| `k3s-clat`, `rke2-clat`, `k3s-clat-mapped` | pod IPv4 through the node's CLAT, native routing (D72) |

They run on small stand-in modules. When a service is built, its suite
uses the service instead and keeps the checks.

## Probes first

A probe is a throwaway test that answers one question before code
depends on the answer.

| Probe | Question | Decides |
|---|---|---|
| PR1 | Can a node turn pod IPv4 into IPv6 with Jool while Cilium runs? | how pod IPv4 leaves an IPv6-only node |
| PR2 | Where does the firewall see traffic that Jool translates? | how Jool is set up |
| PR3 | Does corerad handle a delegated prefix, the NAT64 hint and DNS options? | corerad instead of radvd |
| PR4 | Do k3s and rke2 run on IPv6-only machines? | clusters in the cloud without IPv4 |
| PR5 | Do a MAC override and VLAN 0 work on the WAN port? | replacing the ISP's gateway |
| PR6 | Can the router swap the prefix of a routed /64 when the public side is only known at runtime? | public Service addresses at home, the backup WAN |

## Probe results (2026-11-20)

| Probe | Answer | Changed |
|---|---|---|
| PR1 | Pod IPv4 leaves an IPv6-only node through the node's CLAT when the pod range is mapped one to one. Hiding pods behind the node's address fails | way B is chosen, without NAT on the node |
| PR2 | In the main namespace Jool bypasses the firewall's forward rules. In a namespace of its own it does not | Jool always gets its own namespace |
| PR3 | corerad handles the delegated prefix, a private prefix, DNS options and the NAT64 hint. It does nothing when the prefix changes | the router handles a prefix change itself |
| PR4 | k3s and rke2 each join a second node with no IPv4 on any network card | nothing |
| PR5 | A port presents another MAC while it is found by its real one. A VLAN 0 link gets a DHCP lease | netif gets both as options |
| PR6 | The prefix swap keeps the host part and the visitor's address, refuses unused addresses, and moves with one rule after a prefix change | nothing |

Found on the way:

- An open connection through a dead gateway hangs; it is not reset.
- A CLAT follows one gateway, so it needs a health check.
- The DNS on a gateway must also be limited to its clients.
- CoreDNS must listen on named addresses: every machine already runs a
  local resolver on port 53.

| Probe | Answer | Changed |
|---|---|---|
| PR7 | A small health check moves a machine's CLAT to a live gateway by itself | the client role runs it |
| PR8 | The router handles a prefix change in 5 seconds, also when it happened while the router was off | netif publishes the prefix as a file |
| PR10 | The routed fabric and the mesh both run on IPv6-only network cards, k3s and rke2. Pod IPv4 leaves through each node's CLAT in both modes. Adding the CLAT link to Cilium's devices works with no address mapping | that simpler way is the design (decided 2026-11-21) (the mesh half went with D72) |
| PR9 | One router with two WANs fails over in 6 seconds and back in 3 to 4, for IPv4 and IPv6, also with DHCP on the WANs | failover changes no route, only one firewall rule |

## Build order

| Step | What | Done when |
|---|---|---|
| S1 | netif: MAC override, IPv6-only machines | `netif-v6only` passes |
| S2 | the `router` service: one WAN, dual-stack, zones, DNS, metrics | `netif-router` passes |
| S3 | router options: private prefix, IPv6-mostly | `router-ipv6-mostly` passes |
| S4 | the `nat-gateway` service with two gateways | `nat-gateway` passes |
| S5 | clusters on IPv6-only machines | a suite per distribution passes |
| S6 | a second WAN on one router | `router-dual-wan` passes |
| S7 | two routers with two carriers | design review first |
| S8 | the service prefix: public Service addresses behind a router | `router-service-prefix` passes |
| S9 | your own address block on a fabric border | design review first, then `routed-fabric-transit` passes |

The home router is installed once the steps it needs are done and
stable. There is no migration plan and no compatibility layer.

## Yours to check

- Whether the network card accepts the optical module, and how hot the
  module runs.
- Whether replacing the ISP's gateway still gets the full /60 prefix.
- Whether the ISP keeps that prefix stable.

## Decided, and why

| Choice | Instead of | Why |
|---|---|---|
| Two services in this repo | a module in `modules` | one flake for all networking |
| Jool | tayga | in the kernel, both translation kinds |
| CoreDNS | unbound, Technitium | one declarative file, plugins, built-in metrics |
| corerad | radvd | built-in metrics |
| No state sync between gateways | conntrackd | simpler; a failover resets connections |
| Headscale in the cloud | at home, in Kubernetes | stable address, survives a home outage |
| Cloudflare Tunnel for public web | open ports | no inbound port at home |
| Prefix rewrite on a backup WAN | advertising two prefixes | devices switch slowly between prefixes |
| A stable private pool behind a prefix rewrite | the ISP's prefix in the cluster's pool | the cluster does not change when the ISP renumbers |
| The fabric border announces your own block | BGP in the router service | one owner for upstream BGP |
