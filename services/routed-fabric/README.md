# routed-fabric

Routed, dual-stack host networking with one WireGuard interface per
fabric adjacency and one FRR routing stack per machine. Spines forward
and readvertise; leaves do not provide transit. Orthogonal `access`
controls route consumption and optional `border` configuration controls
external transit.

This service is the **native Cilium transport** (D58): Cilium native
routing, `local-router` route exchange (daemon-neutral — never
`local-frr`/`local-bgp`), and the `internalLoadBalancer` + `nodePort`
exposure capabilities. Native-mode Cilium MTU = the minimum interface
MTU.

Status: the `leaf`/`spine` contract (D59) is implemented —
`roles.leaf`/`roles.spine`, the symmetric derived graph (automatic
spine↔spine pairs, default all-spine leaf attachment, explicit
`settings.spines` subset), and `routed_fabric`/`networkFacts`
schemaVersion 2. IfState owns the loopback, per-adjacency WireGuard
links, static policy routes/rules, and forwarding sysctls; FRR/Zebra owns
dynamic routes. The hermetic two-spine/three-leaf VM suite passes
transport, RIB/FIB, MTU, and spine HA failure/restore checks.

## Inventory

```nix
inventory.instances.fabric = {
  module.input = "clanServices";
  module.name = "routed-fabric";
  roles.spine.machines.spine-a.settings.endpoint = "spine-a.example.net";
  roles.leaf.machines.node-a.settings = {
    spines = [ "spine-a" ];  # explicit subset; default = every spine
    access = "admin";
  };
};
```

Spines are declared directly; every unordered spine pair is adjacent
automatically (symmetric graph derivation — no mutual lists). Every leaf
attaches every spine by default; a leaf may declare an explicit `spines`
subset (an explicit single-homed leaf proves spine↔spine
readvertisement). Two spines are the HA profile; there is no arbitrary
maximum. `access = member|client|admin` is orthogonal membership, not
topology. Kubernetes machines consume their cluster's pod and VIP routes
regardless of `access` on this native transport; ordinary clients
receive only fabric pool VIP routes and admins additionally receive pod
and ClusterIP routes. No member-facing DNS service is rendered.

`border.ownedPrefixes` and `border.upstreamPeers` enable external BGP
transit independently of spine membership. Per-adjacency
`externalTransit` permits default entries only in the WireGuard crypto
ACL. `sourceReturn` adds policy-table defaults, never a main-table fabric
default. Source-return tables avoid reserved kernel/Cilium owners and
netif/source-return collisions; independent rule priorities stay below
32766 and unique across netif and fabric. `sourceReturnTable` and
`sourceReturnPriority` are the explicit per-adjacency pins.

Equal `settings.site` values default to the `site` timer profile (BFD 300
ms x3), different sites to `wan` (BFD 1000 ms x5 plus BGP 10/30 seconds).
`adjacencies.<remote>.timerProfile` overrides the default symmetrically.
Upstreams use `wan`. Both ends and upstreams use a five-second fixed
DelayOpen recovery hold-down, and every maximum-prefix limit restarts after
ten minutes. Plain `bfd` accompanies each profile, site defaults stay
implicit, and `use-underlays-nexthop-weight` is explicit; unchanged reloads
have an empty dry-run diff and preserve peer uptimes and the immediate RIB.
BGP/BFD ports are scoped to fabric interfaces and declared literal
upstream source addresses, never opened globally. All WireGuard listen
ports are unique and reserved in `net.ipv4.ip_local_reserved_ports`;
additional ports or ranges merge through `clanServices.networking.reservedPorts`.

## Allocation

Run `clan vars generate <machine>` after changing machines or adjacencies and
before evaluation. Public non-deployed vars allocate loopback IPv4/IPv6,
node ASNs, and each adjacency's port and transfer prefixes. Defaults are
`198.18.0.0/17` for loopbacks, `198.19.0.0/16` for transfers, a random RFC
4193 ULA /48, and ports 10000–29999. The ULA and IPv4 pools have independent
generators, and the ASN is independent of the node addresses. Member-uniform
`loopback4Pool`, `transfer4Pool`, and `portRange` settings override those
defaults; custom port ranges avoid reserved ports and Kubernetes NodePorts.
Explicit `ipv4`, `ipv6`, and per-adjacency `port` settings win over vars.

Eval rejects missing or duplicate allocations and pool collisions with a
targeted `clan vars generate <machine> --generator <generator> --regenerate`
or settings remedy. A machine rename is a new clan identity: generate new vars
for the new name. There is no migration shim and no renumbering of other
members. Remove orphaned shared adjacency vars only after confirming that the
pair is absent from inventory; see the service documentation for the cleanup
command.

## Exports

Per machine: `peer.hosts` (stable dual-stack fabric addresses),
`node_transport` (schemaVersion 2, D58 — native/local-router with
`internalLoadBalancer` + `nodePort`; datapath interfaces keyed by actual
Linux interface name, each with its MTU; exactly one
`directRoutingDevice`), and `routed_fabric` (schemaVersion 2, D59 —
per-node ASN, stable addresses, leaf/spine topology, access, border
facts, loopback, per-adjacency interface/transfer-prefix/MTU/port/
endpoint/AllowedIPs facts). No secrets are exported.

The same generation command creates the instance-scoped WireGuard keypairs.
Public keys and allocations are non-secret and are not deployed; private keys
deploy only to their owner.

## Tests

```console
nix build .#legacyPackages.x86_64-linux.vmTests.routed-fabric   # hermetic VM suite
nix build .#checks.x86_64-linux.coverage
```
