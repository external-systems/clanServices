# Gateways

Envoy Gateway is the only ingress/Gateway implementation (D2). Traefik is
removed (D3), Cilium's Gateway and Ingress controllers are disabled (D1),
and the Kubernetes Ingress API is deprecated entirely (D4). The stack is
pure Gateway API plus Envoy Gateway policy CRDs.

## Classes and instances (D17)

The model is 0–N in both dimensions:

- **`gateway.classes.<name>`** — one GatewayClass plus one EnvoyProxy. The
  class is the isolation domain: DaemonSet or Deployment mode, node-label
  placement, pool selector labels, base annotations, and opt-in
  `mergeGateways` (kept on a separate opt-in class — one bad tenant
  listener must not NACK a merged fleet).
- **`gateway.instances.<name>`** — one clan-rendered Gateway bound to a
  class: address projection (explicit per-node addresses, or deterministic
  IPv6 carve-outs hashed from cluster+node+instance with eval-caught
  collisions), a listener profile (`web` or custom), domains rendered to
  one cert-manager SAN certificate, namespace, allowedRoutes, and
  external-dns annotations (D31).

Default classes: `public` (DaemonSet on labeled edge workers, drawing from
`public=true` pools) and `private` (private fabric VIP, `private=true`
pools). The tenant isolation ladder is listener < Gateway < class: tenants
create Gateways against clan classes through GitOps; creating classes is
platform work.

The data plane runs as a DaemonSet on labeled workers with
`externalTrafficPolicy: Local` (the EG default). Pool labels and
`lbipam.cilium.io/ips` projections go through EnvoyProxy
`envoyService.labels/annotations` — never annotate the controller-managed
Service directly.

## The default NS + EW pair (D7)

When L2 is non-empty you get two default Gateways:

- **public** — north-south, maximizer for the primary IPv4 :443 address.
- **private** — east-west, a private fleet-fabric VIP serving a fleet-CA
  wildcard certificate (D18).

Both share the identical `web` listener profile: `:80` redirect, catch-all
`HTTPS:443` terminate (default cert), hostname-mandatory `TLS:443`
passthrough, HTTP/3 (UDP/443 beside TCP/443, with NetworkPolicy and
firewall opened together), and per-listener mTLS support. Only the class,
address source, and issuing CA differ. `domains = [...]` renders one
cert-manager Certificate SAN list via the cert-manager Gateway annotation;
ListenerSets are not used while experimental. Tenants own Routes; the
platform owns listeners. Fluid domain sets belong on a Flux-owned Gateway
with its own address.

## One IP, all TLS modes (D15)

One IP:443 simultaneously serves SNI multi-cert HTTPS termination,
hostname-filtered TLS passthrough, per-listener mTLS, and HTTP/3. Only
Envoy Gateway satisfies the full set, which is why it owns the default web
path.

The hard asymmetry: TCP/443 terminate and passthrough share an address via
SNI, but **QUIC terminate and QUIC passthrough never share an address** —
raw UDP has no demux key (Envoy does not parse SNI from QUIC Initials).
QUIC-passthrough Gateways get their own VIP; the `web` profile's UDP/443 is
always termination. This is eval-asserted, along with port uniqueness per
node/address/family/protocol (TCP and UDP may share a port number).

## The zero-churn contract (D6)

Three layers of ownership:

1. **L1 — clan, always.** EG controller, CRDs, pools. The controller itself
   is never Flux-managed; artifact pinning is the point.
2. **L2 — clan, 0–N.** `gateway.classes` and `gateway.instances`. Empty
   means the entire Gateway layer is GitOps-owned — a first-class shape,
   not a degraded one.
3. **L3 — GitOps, always.** Routes, certificates, tenant Gateways, raw L4
   Services.

Tenants draw from labeled pools (one IP per family) or write explicit
`lbipam.cilium.io/ips` — no NixOS rebuild for any of it.

Raw L4 workloads (games like Minecraft with Simple Voice Chat) are plain
`type: LoadBalancer` Services, never Gateways — there is no SNI to route
on. ETP Local preserves player source IPs (D14).
