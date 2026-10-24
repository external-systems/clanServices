# netif

`netif` is the planned inventory-facing clanService for core host network
configuration. It replaces static IP ownership by home's
`hostSpec.networking` and `machines.json`; borg's `lan` service is the
behavioral reference.

## Contract

Each instance describes a host's attachment to a network segment:

- interface name and optional logical-link relationship;
- static IPv4/IPv6 addresses and prefixes, or DHCP/RA;
- default and static routes, including on-link gateways;
- source/destination policy routing and table selection;
- MTU and nameservers;
- firewall trust;
- optional `clan.core.networking.targetHost` export and SSH user.

Static core addresses and routes live in `inventory.nix`. A public fleet
repo may obtain sensitive public-topology values from its
`secrets`/`not-secret` input; those values are public on the deployed NixOS
machine and are not clan vars.

Supporting NixOS modules may configure Wi-Fi association, NetworkManager,
driver quirks, or TCP tuning. They must not become a second owner of the
static data plane. VLAN configuration is available only as underlay link
configuration; it does not create a shared-L2 Kubernetes datapath.

## Exports and consumers

`netif` publishes standard `peer` facts for endpoint discovery and a
versioned `netif` view containing interface, subnets, MTU, and gateway
facts. `fleet-routing` consumes the peer hosts as WireGuard endpoints.
Consumers use `clanLib` export selectors, never raw scope keys.

## Status

Planned for phase 5R1. Evaluation and hermetic VM coverage include static
and DHCP/RA rendering, on-link and policy routes, export defaults, and
fleet-routing endpoint consumption.
