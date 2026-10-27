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

Status: the round-17 `leaf`/`spine` contract (D59) is implemented —
`roles.leaf`/`roles.spine`, the symmetric derived graph (automatic
spine↔spine pairs, default all-spine leaf attachment, explicit
`settings.spines` subset), and `routed_fabric`/`networkFacts`
schemaVersion 2. Breaking round-16 `member`/`hub` shapes were removed
without shims; no migration is provided. VM evidence: eval suites are
green; the NixOS VM suite is updated to the two-spine/three-leaf HA
shape but has **not** been re-run on the round-17 tree — no VM-green
claim is made here.

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
ACL. `sourceReturn` adds policy-table defaults, never a main-table
fabric default.

## Exports

Per machine: `peer.hosts` (stable dual-stack fabric addresses),
`node_transport` (schemaVersion 2, D58 — native/local-router with
`internalLoadBalancer` + `nodePort`; datapath interfaces keyed by actual
Linux interface name, each with its MTU; exactly one
`directRoutingDevice`), and `routed_fabric` (schemaVersion 2, D59 —
per-node ASN, stable addresses, leaf/spine topology, access, border
facts, loopback, per-adjacency interface/transfer-prefix/MTU/port/
endpoint/AllowedIPs facts). No secrets are exported.

Run `clan vars generate <machine>` for the instance-scoped WireGuard
keypairs before deployment. Public keys are non-secret; private keys
deploy only to their owner.

## Tests

```console
nix build .#checks.x86_64-linux.routed-fabric   # eval suites
nix build .#checks.x86_64-linux.coverage
```
