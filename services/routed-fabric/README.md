# routed-fabric

Routed-hub, dual-stack host networking with one WireGuard interface per declared adjacency and one FRR routing stack per machine. Hubs forward and readvertise; members do not provide spoke transit. Orthogonal `access` controls route consumption and optional `border` configuration controls external transit.

## Inventory

```nix
inventory.instances.fabric = {
  module.input = "clanServices";
  module.name = "routed-fabric";
  roles.hub.machines.hub-a.settings.endpoint = "hub-a.example.net";
  roles.member.machines.node-a.settings = {
    hubs = [ "hub-a" ];
    access = "admin";
  };
};
```

Every member names at least one hub. Two hubs are the HA profile. Hub-to-hub adjacencies are declared by listing the other hub in each hub's `hubs` list. Kubernetes machines consume their cluster's pod and VIP routes regardless of `access`; ordinary clients receive only fabric pool VIP routes and admins additionally receive pod and ClusterIP routes. No member-facing DNS service is rendered.

`border.ownedPrefixes` and `border.upstreamPeers` enable external BGP transit independently of hub membership. Per-adjacency `externalTransit` permits default entries only in the WireGuard crypto ACL. `sourceReturn` adds policy-table defaults, never a main-table fabric default.

Run `clan vars generate <machine>` for the instance-scoped WireGuard keypairs before deployment. Public keys are non-secret; private keys deploy only to their owner.
