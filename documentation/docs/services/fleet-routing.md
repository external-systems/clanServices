# fleet-routing

The fleet-routing clanService gives non-Kubernetes NixOS machines routed
access to the fleet: cluster VIPs for everyone, pod and Service CIDRs for
admins, upstream prefix ownership for routers (D11, D33).

## Roles

- **`client`** — mesh join, BIRD peering, VIP route install, and a DNS stub
  for the private zone `<instance>.<meta.domain>` (D22). The base profile
  for reaching cluster services.
- **`admin`** — client plus pod/Service advertisement consumption (D13) and
  the svc/pod DNS zones default-on (D22). The developer/admin profile.
- **`router`** — upstream prefix ownership, filtered VIP acceptance, NDP, and
  pool definitions for its downstream cluster(s). Foreign routers
  (MikroTik-style) follow a published runbook (D9). Edge proxies on a router
  machine are your own nixosModules, not fleet-routing's concern.

Node duality is legal: a machine may be a cluster node (one cluster — D16)
and hold fleet-routing roles at the same time. On a cluster member the
service's BIRD fragments merge into the existing machine BIRD (D19).

## Status

Planned (delivery phase 5, together with the BGP/BIRD fabric). The
architecture and acceptance criteria are in
[Fleet routing](../architecture/fleet-routing.md) and SPEC.md §6.13.
