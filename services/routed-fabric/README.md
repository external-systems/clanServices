# routed-fabric

Routed, dual-stack host networking with one WireGuard interface per
fabric adjacency and one FRR routing stack per machine. Spines forward
and readvertise; leaves do not provide transit. Orthogonal `access`
controls route consumption and optional `border` configuration controls
external transit.

This service is the **native Cilium transport** (D58, round-17 target):
Cilium native
routing, `local-router` route exchange (daemon-neutral — never
`local-frr`/`local-bgp`), and the `internalLoadBalancer` + `nodePort`
exposure capabilities. Native-mode Cilium MTU = the minimum interface
MTU.

Status: the implemented service is the round-16 `member`/`hub` fabric
(`roles.member` machines declare `settings.hubs`; hubs are declared
directly; hub↔hub adjacencies are explicit mutual lists). The
`leaf`/`spine` shape in the example below is the LOCKED ROUND-17 TARGET
(D59, planned in 5R5): symmetric derived graph, automatic spine pairs,
default all-spine leaf attachment. `routed_fabric` exports move to
schemaVersion 2 with that rename.

## Inventory

Round-17 target shape (D59):

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
subset. Two spines are the HA profile; there is no arbitrary maximum.
Kubernetes machines consume their cluster's pod and VIP routes
regardless of `access` on this native transport; ordinary clients
receive only fabric pool VIP routes and admins additionally receive pod
and ClusterIP routes. No member-facing DNS service is rendered.

`border.ownedPrefixes` and `border.upstreamPeers` enable external BGP
transit independently of spine membership. Per-adjacency
`externalTransit` permits default entries only in the WireGuard crypto
ACL. `sourceReturn` adds policy-table defaults, never a main-table
fabric default.

Run `clan vars generate <machine>` for the instance-scoped WireGuard
keypairs before deployment. Public keys are non-secret; private keys
deploy only to their owner.
