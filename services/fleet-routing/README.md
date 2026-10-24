# fleet-routing

Routed access to cluster VIPs (and optionally pod/Service CIDRs) for
non-Kubernetes clan machines, over the same per-node BIRD / BGP v2 fabric
the clusters run (SPEC.md §6.13, D11/D13/D19/D22/D33).

## Roles

- **`client`** — join a WireGuard mesh, accept the consumed clusters' VIP
  routes (their `shared-bgp` pool blocks, exact /32+/128, installed into
  the kernel with ECMP across the advertising nodes), and resolve ONLY
  `<instance>.<domain>` via the cluster's private CoreDNS VIP
  (global systemd-resolved route-only domain using the per-member routes).
- **`admin`** — everything `client` does, plus D13 route consumption (pod
  CIDRs / ClusterIPs from clusters that opted in) and the D22 svc/pod
  zone stubs (default-on for admin).
- **`router`** — upstream prefix ownership (`prefixes`, exported as
  `fleet_routing.routerPrefixes` — the fleet-wide check rejects cluster
  shared-bgp pools outside them), the same filtered VIP acceptance,
  optional re-advertisement to further `upstreamPeers`, IP forwarding,
  and optional proxy-NDP (`ndpInterfaces`) for on-LAN VIPs.

## Wiring (both sides are explicit)

1. Add the fleet machine to the WireGuard mesh instance the cluster
   consumes (`roles.peer.machines.<machine>`), and point the role's
   `mesh.service`/`mesh.instance` at it.
2. List the clusters in the role's `clusters` (`{ service; instance; }`).
3. On the CLUSTER side, list the fleet machine's mesh addresses in
   `bgp.upstreamPeers` with this fleet-routing instance's ASN — read it
   from the `fleet_routing.asn` export (a deterministic hash of the
   instance name). Cluster nodes dial out; fleet machines listen on their
   mesh addresses only. For `admin` machines, also set
   `receivePodCIDRs`/`receiveClusterIPs` on the peer entry when the
   cluster opted into D13 advertisement.

## Routed WireGuard data plane

The existing mesh interface remains node transport and the BGP control
path. Each fleet host also creates one point-to-point WireGuard interface
per remote cluster member for routed VIP/pod/Service traffic. One member
peer per interface is required: WireGuard selects peers by the original
destination address, so duplicate shared-VIP `AllowedIPs` on the ordinary
mesh interface cannot provide ECMP.

Routed interfaces reuse the mesh identity, addresses, endpoint facts, and
deployed private-key path, with ephemeral listen ports. Every remote member
must publish a reachable endpoint; missing endpoints fail evaluation. Their `AllowedIPs`
are restricted to member-eligible shared-pool and admin-consumed prefixes,
and BIRD resolves each member's next hop through the matching interface.
Names are deterministic, fleet-instance-namespaced, collision-checked, and
at most 15 characters. Dual-role hosts exclude themselves; cluster members
keep only their existing mesh interface.

Node duality is legal (D33): a cluster member may hold a fleet-routing
role; the BIRD fragments merge into the host's single BIRD (D19).
