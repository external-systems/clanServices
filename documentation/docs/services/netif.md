# netif

`netif` is the planned inventory-facing clanService for core host network
configuration (round 15, D53). It replaces static IP ownership by home's
`hostSpec.networking` and `machines.json`; borg's `lan` service is the
behavioral reference.

## Contract

`netif` is **multi-instance and multi-link** (D53). One instance describes
a network segment — a site LAN, a public uplink, an SFP+ group — and a host
joins as many instances as it has attachments, commonly a public and a
private instance, or several instances for a multi-NIC router. Inventory is
role-scoped: site/segment defaults live on `roles.default.settings`, and
each machine declares one or more logical links under
`roles.default.machines.<name>.settings.links.<logical>` with the physical
`interface` per link. Each instance carries:

- **segment defaults** (site/segment level): addressing mode, base MTU
  (effective per-link values are derived, not hand-set), nameservers,
  gateway, firewall trust;
- **per-machine and per-link overrides**: physical interfaces, VLANs,
  bonds, and bridges, each with DHCP/RA or static IPv4/IPv6 addressing and
  prefixes;
- gateways (on-link and default), static and policy routes, table
  selection, MTU, DNS, and firewall trust per link;
- optional `clan.core.networking.targetHost` export and SSH user;
- optional `peer` endpoint exports for fabric consumers.

Cross-instance checks keep the host coherent (D53): an interface/link is
owned by exactly one instance, exactly one instance may provide the host
default route, and DNS declarations must not conflict. `routed-fabric`
owns fabric policy routing — `netif` never renders fabric rules — and
`netif` links never become a shared-L2 Kubernetes datapath.

Static core addresses and routes live in `inventory.nix`. A public fleet
repo may obtain sensitive public-topology values from its
`secrets`/`not-secret` input; those values are public on the deployed NixOS
machine and are not clan vars.

Supporting NixOS modules may configure Wi-Fi association, NetworkManager,
driver quirks, or TCP tuning. They must not become a second owner of the
static data plane. Provider-MAC attachment for day-2 KubeVirt (for example)
is `netif` **bridge plumbing**, not a LoadBalancer pool concern.

## Exports and consumers

`netif` publishes standard `peer` facts for endpoint discovery and a
versioned `netif` view containing interface, subnets, MTU, gateway, and
route facts. `routed-fabric` consumes the peer hosts as WireGuard endpoints
and derives link MTUs from them. Consumers use `clanLib` export selectors,
never raw scope keys. The same resolved link/interface/address/gateway/MTU/
route configuration is what `netif` will publish to the per-node
`clan.networkFacts` interface as underlay graph facts (D57, planned) —
producer-owned, non-secret, and exposed through `readOnly = true` options;
see [Network diagrams](../architecture/network-diagrams.md).

## Inventory example

Site/segment defaults with per-machine NIC names, plus a multi-NIC router
joining two instances (one link each, a single default route across the
whole host):

```nix
inventory.instances = {
  # One instance per segment: DHCP defaults on the role, NIC names per link.
  home-net = {
    module.input = "clanServices";
    module.name = "netif";
    roles.default.settings = {              # site/segment defaults
      dhcp.ipv4 = true;
      mtu = 1500;
      nameservers = [ "192.168.10.1" ];
    };
    roles.default.machines = {
      kamrui-h1.settings.links.wifi = { interface = "wlp2s0"; };  # Wi-Fi NIC
      nas.settings.links.eth = { interface = "enp3s0"; };  # different NIC, same defaults
    };
  };

  # Multi-NIC router: one SFP+ link per uplink instance.
  uplink-a = {
    module.input = "clanServices";
    module.name = "netif";
    roles.default.machines.edge-1.settings.links.sfp0 = {
      interface = "enp1s0f0np0";
      static.ipv4 = [ "203.0.113.2/30" ];
      gateway.ipv4 = "203.0.113.1";        # the host's one default route
      endpoint = true;                     # exported to routed-fabric
    };
  };
  uplink-b = {
    module.input = "clanServices";
    module.name = "netif";
    roles.default.machines.edge-1.settings.links.sfp1 = {
      interface = "enp1s0f1np1";
      static.ipv4 = [ "198.51.100.2/30" ]; # no gateway: cross-instance check
    };
  };
};
```

## Status

Planned for phase 5R1. Evaluation and hermetic VM coverage include static
and DHCP/RA rendering, VLAN/bond/bridge links, on-link and policy routes,
cross-instance ownership/default-route/DNS checks, export defaults, and
routed-fabric endpoint consumption.
