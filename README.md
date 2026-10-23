# External Systems clanServices

The canonical home for External Systems' custom [clan services](https://clan.lol/docs/26.05/guides/services/intro-to-services-revised).
This is a standalone flake: consumers do not need to depend on `clan-community`.
Services may still be proposed upstream to `clan-community` as focused, reviewable changes.

## Services

- [k3s](services/k3s/README.md): k3s Kubernetes cluster
- [rke2](services/rke2/README.md): RKE2 Kubernetes cluster
- [wireguard-mesh](services/wireguard-mesh/README.md): dual-stack host-level WireGuard full mesh
- [kube-cluster](lib/kube-cluster/README.md): private distro-neutral implementation shared by k3s and RKE2

[SPEC.md](SPEC.md) is the canonical architecture, status, and delivery record — a single dense
contract for agents; `documentation/` (MkDocs site + slides) is the human record of the same spec
(edit both together). Round 13 narrowed the contract to the bootstrap + data-plane promises;
everything else in-cluster (Envoy Gateway, cert-manager, Sealed Secrets, Flux, external-dns,
storage, CCMs) is a documented day-2 GitOps pattern, never clan-rendered.

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

Hermetic NixOS VM suites and the delivery roadmap are documented in SPEC.md. Artifact packaging has a separate planned home in `external-systems/pkgs`; the imported implementation has not completed that migration yet.
