# External Systems clanServices

The canonical home for External Systems' custom [clan services](https://clan.lol/docs/26.05/guides/services/intro-to-services-revised).
This is a standalone flake: consumers do not need to depend on `clan-community`.
Services may still be proposed upstream to `clan-community` as focused, reviewable changes.

## Services

- [k3s](services/k3s/README.md): k3s Kubernetes cluster
- [rke2](services/rke2/README.md): RKE2 Kubernetes cluster
- [netif](services/netif/README.md): inventory-owned, multi-instance host links and static routes rendered by IfState
- [routed-fabric](services/routed-fabric/README.md): per-adjacency WireGuard + FRR
  flat-L3 fabric with `leaf`/`spine` topology, orthogonal access and border
  settings, and dependency-free network facts; the native Cilium transport
- [wireguard-mesh](services/wireguard-mesh/README.md): supported tunnel transport
  (Cilium tunnel/VXLAN + nodePort, D58) — one shared multi-peer WireGuard
  interface per machine
- [kube-cluster](lib/kube-cluster/README.md): private distro-neutral implementation shared by k3s and RKE2

[SPEC.md](SPEC.md) is the canonical architecture, status, and delivery record — a single dense
contract for agents; `documentation/` (MkDocs site + slides) is the human record of the same spec
(edit both together). Round 14 makes FRR + per-pair WireGuard + native multi-pool Cilium the
data-plane target and puts static host networking in inventory through `netif`. Round 15 adds
`routed-fabric`, multi-instance multi-link `netif`, fabric-derived mesh groups, and selective
ClusterMesh. Round 16 adds orthogonal access/border settings and dependency-free network facts.
Round 17 adds the generic `node_transport` schemaVersion 2, `leaf`/`spine` topology, and
ClusterMesh placement/exposure; it is implemented and VM-proven.
Round 19 (2026-10-28) makes `external-systems/pkgs` the shared-input and
artifact authority and moves VM suites to `legacyPackages.<system>.vmTests`.
Round 18 (2026-10-27) replaces all systemd-networkd/netdev and scripted networking with
IfState 2.5.1. Static host links, WireGuard, routes, rules, and sysctls reconcile live without
reboot; FRR/Zebra and Cilium retain their dynamic ownership boundaries. The full netif, fabric,
k3s, and RKE2 native/tunnel/selective/external VM matrix is green.
Breaking renames and renderer changes ship without migration shims — there are no external
consumers or deployments. Round 13's scope remains: everything else in-cluster is a documented
day-2 GitOps pattern, never clan-rendered; member-facing private DNS is wholly day-2.

## Usage

Add this repository as a flake input and use the same `clan-core` instance:

```nix
{
  inputs = {
    clan-core.url = "https://git.clan.lol/clan/clan-core/archive/main.tar.gz";
    clanServices.url = "github:external-systems/clanServices";
    clanServices.inputs.clan-core.follows = "clan-core";
  };
}
```

The locked transitive `external-systems/pkgs` input supplies nixpkgs,
flake-parts, runtime packages, overlays, and airgap artifacts; consumers do
not need to declare it. Its overlays are re-exported as
`clanServices.overlays.{default,kubernetes,ifstate}`. To use a different
artifact repository, declare your own input and set
`clanServices.inputs.pkgs.follows = "pkgs";`.

Instantiate a service in the clan inventory:

```nix
clan.inventory.instances.<instance-name> = {
  module.name = "rke2";
  module.input = "clanServices";
  roles.<role>.machines.<machine-name> = { };
};
```

Run `clan vars generate <machine>` after changing routed-fabric or
wireguard-mesh membership. Their addresses, ASNs, and adjacency ports are
committed public allocations, not name-derived values. Renaming a machine
creates a new clan identity and requires new vars; no migration shim reuses
the old machine's allocations.

## Development

Each service lives under `services/<name>/` with its module, flake-parts registration, README, and tests. Shared cluster behavior lives under `lib/kube-cluster/`. Service directories are auto-discovered; there is no central registration list.

Run the standard static gates before committing:

```bash
nix fmt .            # alejandra
nix flake check --show-trace
```

`checks` is static-only (eval tests, coverage, formatting), so a full
`nix flake check` is safe and required.

Hermetic NixOS VM suites are documented in SPEC.md and built from
`legacyPackages.x86_64-linux.vmTests.<suite>`, one at a time. The pinned
artifact flake supplies distro runtimes, IfState, the committed Cilium
manifest, per-system Cilium/CoreDNS airgap images, and test fixtures.
