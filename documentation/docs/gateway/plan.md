# Plan and probes

Nothing is built yet. The design was decided on 2026-11-20 and is
written down first; later sessions build and prove it.

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

The home router is installed once the steps it needs are done and
stable. There is no migration plan and no compatibility layer.

## Yours to check

- Whether the network card accepts the optical module, and how hot the
  module runs.
- Whether replacing the ISP's gateway still gets the full /60 prefix.

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
