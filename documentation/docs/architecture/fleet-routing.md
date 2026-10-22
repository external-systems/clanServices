# Fleet routing

The fleet-routing clanService gives non-Kubernetes NixOS machines routed
access to the fleet — cluster VIPs, and optionally pod and Service CIDRs —
through the same BIRD/BGP fabric the clusters use. `/etc/hosts` entries are
the zero-BGP fallback (D11).

## Roles (D33)

- **`client`** — mesh join, BIRD peering, VIP route install, and a DNS stub
  for the private zone `<instance>.<meta.domain>`. This is the base profile
  for a machine that needs to reach cluster services.
- **`admin`** — everything `client` does, plus consumption of pod and
  Service CIDR advertisements (D13) and the svc/pod DNS zones default-on
  (D22). This is the developer/admin machine profile.
- **`router`** — upstream prefix ownership, filtered VIP acceptance, and
  NDP. The router role can define pools for its downstream cluster(s) and
  advertise service VIPs and pod IPs upstream. This is the role a gateway
  machine (or a documented foreign router) plays.

!!! note
    Edge proxies on a router machine — for example Traefik with the
    Kubernetes provider — are your own nixosModules, not fleet-routing's
    concern. Fleet-routing owns routes and DNS, never a data-plane proxy.

## Node duality

A machine may be a cluster node (of exactly one cluster — D16) **and** hold
fleet-routing roles. On a cluster member, the fleet-routing BIRD fragments
merge into the machine's existing BIRD (D19); its own cluster's pod and
Service CIDRs are local routes anyway, and the admin role teaches it the
*other* clusters' CIDRs. Fleet-wide PodCIDR non-overlap — asserted wherever
clusters mesh — is what makes cross-cluster pod routing coherent.

The canonical test shape is exactly that: **kamrui-h1** is a single-node k3s
cluster *and* an admin-role machine. One box, both hats, VM-proven.

## Private-domain zones (D21, D22)

`cluster.local` is pinned, never changed, and **never served to clients** —
the ecosystem hardcodes it, and the blast radius of changing it is high with
zero benefit (D21). Client-facing naming uses private-domain zones served by
cluster CoreDNS on the private VIP:

- **Instance zone** `<instance>.<meta.domain>` (default for clients): a
  wildcard pointing at whatever day-2 proxy you install (previously the
  private Gateway VIP — D22 revised in round 13). The zone and its VIP exist
  regardless; the proxy behind them is GitOps-owned.
- **Service zone** `<instance>.svc.<meta.domain>` (opt-in; default-on for
  `admin`): CoreDNS rewrites to `<name>.<ns>.svc.cluster.local` with
  answer-name reversal, resolving to Service IPs. Private-pool LB VIPs work
  out of the box (the fabric already routes them); ClusterIPs additionally
  require the D13 service advertisement.
- **Pod zone** (opt-in; default-on for `admin`): CoreDNS `pods insecure`
  plus dash-form rewrites, with pod advertisement (D13).

Pod and ClusterIP advertisement to machines is opt-in and default-off (D13)
— machines reach Services through VIPs, never pods directly — except that
the `admin` role turns these opt-ins on per machine. The caveats are real:
ephemeral IPs, `world` policy identity, trust extension, and no readiness
signal.
