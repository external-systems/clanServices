# fleet-routing

The fleet-routing clanService gives non-Kubernetes NixOS hosts routed access
to the fleet: cluster VIPs for everyone, pod and Service CIDRs for admins,
upstream prefix ownership for routers (D11, D33).

## Roles

- **`client`** — mesh join, BIRD peering, VIP route install, fleet CA trust
  (D18), and a DNS stub for the gateway zone `<instance>.<meta.domain>`
  (D22). The base profile for reaching cluster services.
- **`admin`** — client plus pod/Service advertisement consumption (D13) and
  the svc/pod DNS zones default-on (D22). The developer/admin profile.
- **`router`** — upstream prefix ownership, filtered VIP acceptance, NDP.
  Foreign routers (MikroTik-style) follow a published runbook (D9).

Node duality is legal: a machine may be a cluster node (one cluster — D16)
and hold fleet-routing roles at the same time. On a cluster member the
service's BIRD fragments merge into the existing host BIRD (D19).

## Status

Planned (delivery phase 11, where it replaces the scrapped edge-proxy
concept — D5). The architecture and acceptance criteria are in
[Fleet routing](../architecture/fleet-routing.md) and SPEC.md §5.13.
