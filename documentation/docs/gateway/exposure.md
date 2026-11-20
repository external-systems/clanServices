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
  the firewall opens one hole.

In the cloud:

- IPv6 goes straight to the service address.
- For IPv4, a gateway maps one public IPv4 to an IPv6 service address,
  without keeping state.

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
