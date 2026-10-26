# External Systems clanServices

The canonical home for External Systems' custom [clan services](https://clan.lol/docs/26.05/guides/services/intro-to-services-revised).
This is a standalone flake: consumers do not need to depend on `clan-community`.
Services may still be proposed upstream to `clan-community` as focused, reviewable changes.

## Services

- [k3s](services/k3s/README.md): k3s Kubernetes cluster
- [rke2](services/rke2/README.md): RKE2 Kubernetes cluster
- [netif](services/netif/README.md): inventory-owned, multi-instance host links and static routes
- [routed-fabric](services/routed-fabric/README.md): per-adjacency WireGuard + FRR
  flat-L3 fabric — implemented with the round-16 `member`/`hub` topology,
  orthogonal access and border settings, and dependency-free network
  facts; the native Cilium data-plane transport. The round-17 `leaf`/`spine`
  rename (D59) is the locked target, planned in 5R5.
- [wireguard-mesh](services/wireguard-mesh/README.md): supported tunnel transport
  (Cilium tunnel/VXLAN + nodePort, D58) — one shared multi-peer WireGuard
  interface per machine; no longer pending retirement
- [kube-cluster](lib/kube-cluster/README.md): private distro-neutral implementation shared by k3s and RKE2

[SPEC.md](SPEC.md) is the canonical architecture, status, and delivery record — a single dense
contract for agents; `documentation/` (MkDocs site + slides) is the human record of the same spec
(edit both together). Round 14 makes FRR + per-pair WireGuard + native multi-pool Cilium the
data-plane target and puts static host networking in inventory through `netif`. Round 15 adds
routed-hub `routed-fabric`, multi-instance multi-link `netif`, fabric-derived mesh groups, and
full-by-default ClusterMesh with selective peers. Round 16 (2026-10-24) refines the fabric into
member/hub topology roles with orthogonal member/client/admin access and optional border
configuration (D56), plus a read-only, non-secret `clan.networkFacts` interface for consumer-owned
nix-topology diagram packages without a nix-topology dependency here (D57).
Round 17 (2026-10-25) is a docs-only contract lock: a generic
`node_transport` schemaVersion 2 outside `lib/kube-cluster` will be the
only transport seam k3s/rke2 consume (D58, round-17 target — 5R5); fabric
roles are renamed
`leaf`/`spine` with a symmetric derived graph (D59); ClusterMesh
placement/exposure is locked (D60); and `wireguard-mesh` becomes a
supported tunnel transport. Current status: `netif` and the round-16 `member`/`hub` `routed-fabric`
are implemented, and the native k3s/rke2 data plane is implemented
(5R1 + 5R2(1)–(3)); the round-17 contract (leaf/spine rename, generic
`node_transport` schemaVersion 2, ClusterMesh placement/exposure) and
the remaining 5R phases are planned.
Breaking round-17 renames ship without migration shims — there
are no external consumers or deployments. Round 13's scope
remains: everything else in-cluster is a documented day-2 GitOps
pattern, never clan-rendered; member-facing private DNS is wholly
day-2 (no clan-rendered member zones, private DNS service, or private
CoreDNS VIP in the MVP).

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
