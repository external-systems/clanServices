# Exposing services

Planned. How services on the home network and in the cloud are reached,
and how metrics reach your monitoring cluster.

## Systemd or Kubernetes

Run in systemd what you need in order to reach or repair a cluster. Run
everything else in Kubernetes.

| Systemd, as clan services | Kubernetes |
|---|---|
| routing, NAT, DNS, DHCP, router advertisements | applications |
| Headscale | the cluster's gateway (ingress) |
| the cluster itself, the remote builder | Prometheus and Grafana |

## Three classes

Put every service in one class. The fewer in class 3, the safer.

| Class | Reached by | Open inbound port |
|---|---|---|
| 1 Private | your tailnet; friends and family join Headscale | none |
| 2 Public web | a Cloudflare Tunnel that dials out from the cluster | none |
| 3 Direct | a port on a public address | yes |

**The home router opens no inbound port by default.**

Class 2 has a price: Cloudflare ends the TLS connection and can read the
traffic.

## Headscale

- It runs as a systemd service on a **cloud machine with a public
  IPv4**.
- Not at home: the home has one changing address, and a home outage
  would lock everyone out.
- Not in Kubernetes: it is your way in when a cluster is broken.
- It cannot sit behind Cloudflare, so it is class 3.
- Headscale is the only supported control server. NetBird may come
  later as separate work.

## Class 3, when you need it

At home:

- The router forwards a port to one stable address. It only rewrites the
  destination; it ends no TLS.
- FRR spreads that address over the Kubernetes nodes on equal paths.
- The cluster's gateway routes by hostname. A systemd service on any
  host is just one more backend behind it.
- For IPv6 no sharing is needed: a host has its own public address and
  the firewall opens one hole. A Kubernetes Service can have its own
  public address too, see below.

In the cloud:

- IPv6 goes straight to the service address.
- For IPv4, a gateway maps one public IPv4 to an IPv6 service address,
  without keeping state.

## A public IPv6 address for a Kubernetes Service

Example: a Minecraft server in your home cluster, with its own public
address.

It works the same way at home and in the cloud. You give the cluster a
pool of addresses, a Service takes one, and Cilium announces it by BGP.
Only the edge differs:

| Site | Who sends the block to you | Edge |
|---|---|---|
| Cloud | the provider, to one node or as a floating block | the node, or a fabric border |
| Home | your ISP, to the router | the router |
| Your own block | a transit provider | a fabric border |

At home:

- The router keeps one /64 of the ISP's block free of links: the
  **service prefix**. Your /60 holds 16; six zones and this one use
  seven.
- The router is a member of the fabric, so it learns each Service
  address from the cluster and spreads traffic over the nodes.
- You list what is open: an address, a protocol and ports. Nothing in
  the service prefix is reachable from the internet until you list it.
- An address nobody uses is refused at the router.

The ISP may change your block. So there are two modes:

| Mode | The cluster's pool | Use it when |
|---|---|---|
| `translated` (default) | a stable private /64; the router swaps the prefix and keeps the rest of the address | the ISP's block can change |
| `literal` | the public prefix itself | the block is static, or it is your own |

Limits:

- The address is only as stable as the ISP's block. DNS must follow a
  change; that updater is yours to run.
- A fully static address needs your own block, or a cloud block carried
  home over the fabric.
- IPv4 players still come in through a forwarded port on your one
  home IPv4 address.

## Your own address block

Later you can hold your own IPv6 block and AS number, from the registry
for Europe or North America through a sponsor, and announce it to
providers by BGP.

- The fabric **border** announces it. It already has upstream peers and
  a list of owned prefixes, and pools must lie inside them.
- A home ISP offers no BGP session. So a cloud machine at a provider
  that does offer one announces the block, and the fabric carries it
  home. An office with two carriers can announce it directly.
- A home Service then uses the `literal` mode and keeps its address
  when the ISP changes.

The border was built for a private upstream router. Before it faces a
transit provider it needs:

- your public AS number on the session; the fabric's private numbers
  stay inside;
- only whole blocks announced (a /48 or larger for IPv6), never single
  Service addresses;
- a default route or a full table accepted from the provider;
- per provider: optional BFD, multihop, a session password;
- optional checking of route origins (RPKI).

Two regions need two /48 blocks: a /48 is the smallest block the
internet accepts. One block announced from two regions also works, but
a connection may come in at one and leave at the other.

Registry records (route objects, ROAs, reverse DNS) are yours to keep
at the registry. Nothing here writes them.

## Metrics

Each service can expose Prometheus metrics. Prometheus and Grafana run
in a cluster and are managed by your GitOps repo.

- An endpoint listens only on the machine's fabric address, never on a
  LAN or WAN address.
- The host firewall allows scrapes only from the monitoring cluster's
  pod addresses. In native routing a pod's source address arrives
  unchanged.
- A Cilium policy in the cluster limits which pods may scrape.
- The scrape targets are published for your GitOps repo to use.

| Component | Metrics |
|---|---|
| CoreDNS, corerad | built in |
| kea, FRR | existing exporters |
| links, connection tracking | node exporter |
| firewall counters, Jool | a small collector |

Flow records, firewall drop logs and packet capture are logs, not
metrics. They are a later step: logs first, an intrusion detector on
the WAN as an option, capture only on demand.
