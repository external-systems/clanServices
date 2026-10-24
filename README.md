# External Systems clanServices

The canonical home for External Systems' custom [clan services](https://clan.lol/docs/26.05/guides/services/intro-to-services-revised).
This is a standalone flake: consumers do not need to depend on `clan-community`.
Services may still be proposed upstream to `clan-community` as focused, reviewable changes.

## Services

- [k3s](services/k3s/README.md): k3s Kubernetes cluster
- [rke2](services/rke2/README.md): RKE2 Kubernetes cluster
- `netif` (planned): inventory-owned, multi-instance host links and static routes
- `routed-fabric` (planned, round-16 target): per-adjacency WireGuard + FRR
  flat-L3 fabric, routed-hub MVP with member/hub topology, orthogonal
  access and border settings, and dependency-free network facts; the legacy
  `services/fleet-routing/` tree predates the round-15/16 design and is not
  its implementation
- [wireguard-mesh](services/wireguard-mesh/README.md): legacy host transport, pending migration/removal
- [kube-cluster](lib/kube-cluster/README.md): private distro-neutral implementation shared by k3s and RKE2

[SPEC.md](SPEC.md) is the canonical architecture, status, and delivery record — a single dense
contract for agents; `documentation/` (MkDocs site + slides) is the human record of the same spec
(edit both together). Round 14 makes FRR + per-pair WireGuard + native multi-pool Cilium the
data-plane target and puts static host networking in inventory through `netif`. Round 15 adds
routed-hub `routed-fabric`, multi-instance multi-link `netif`, fabric-derived mesh groups, and
full-by-default ClusterMesh with selective peers. Round 16 (2026-10-24) refines the fabric into
member/hub topology roles with orthogonal member/client/admin access and optional border
configuration (D56), plus a read-only, non-secret `clan.networkFacts` interface for consumer-owned
nix-topology diagram packages without a nix-topology dependency here (D57). Phases 5R1–5R4 remain
planned, including the `external-systems/pkgs` native Cilium base re-inflation and clanServices pin
update. Round 13's scope remains: everything else in-cluster is a documented day-2 GitOps pattern,
never clan-rendered.

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

Instantiate a service in the clan inventory:

```nix
clan.inventory.instances.<instance-name> = {
  module.name = "rke2";
  module.input = "clanServices";
  roles.<role>.machines.<machine-name> = { };
};
```

## Development

Each service lives under `services/<name>/` with its module, flake-parts registration, README, and tests. Shared cluster behavior lives under `lib/kube-cluster/`. Service directories are auto-discovered; there is no central registration list.

Run the standard static gates before committing:

```bash
nix fmt .
nix flake check --no-build --show-trace
```

Hermetic NixOS VM suites and the delivery roadmap are documented in SPEC.md. The pinned artifact flake is `external-systems/pkgs` — distro runtimes (last three Kubernetes minors each), the Cilium chart with its committed inflated base manifest, and the test fixtures — already consumed by this flake at its lock pin.
