# External Systems clanServices

[![ci](https://img.shields.io/github/actions/workflow/status/external-systems/clanServices/ci.yml?branch=main&label=ci&logo=github)](https://github.com/external-systems/clanServices/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/external-systems/clanServices?label=release&color=d97757)](https://github.com/external-systems/clanServices/releases/latest)
[![docs](https://img.shields.io/website?url=https%3A%2F%2Fclanservices.external.systems%2F&label=docs&up_message=online&down_message=offline)](https://clanservices.external.systems/)
[![license](https://img.shields.io/github/license/external-systems/clanServices)](https://github.com/external-systems/clanServices/blob/main/LICENSE)
[![built with Nix](https://img.shields.io/badge/built_with-Nix-5277C3?logo=nixos&logoColor=white)](https://nixos.org)

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
- [remote-builder](services/remote-builder/README.md): a Nix remote builder
  served over `ssh-ng`, with pinned host keys for its clients (D65)
- [kube-cluster](lib/kube-cluster/README.md): private distro-neutral implementation shared by k3s and RKE2

[SPEC.md](SPEC.md) is the canonical architecture, status, and delivery record — a single dense
contract for agents; `documentation/` (MkDocs site + slides) is the human record of the same spec
(edit both together). Round 14 makes FRR + per-pair WireGuard + native multi-pool Cilium the
data-plane target and puts static host networking in inventory through `netif`. Round 15 adds
`routed-fabric`, multi-instance multi-link `netif`, fabric-derived mesh groups, and selective
ClusterMesh. Round 16 adds orthogonal access/border settings and dependency-free network facts.
Round 17 adds the generic `node_transport` schemaVersion 2, `leaf`/`spine` topology, and
ClusterMesh placement/exposure; it is implemented and VM-proven.
Round 24 (2026-11-11) brings the repo onto the external-systems org
standard (one `org-pkgs` input, devenv, org CI and docs). Round 19
(2026-10-28) makes `external-systems/pkgs` the shared-input and
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

The locked transitive `external-systems/pkgs` input (named `org-pkgs`) supplies nixpkgs,
flake-parts, runtime packages, overlays, and airgap artifacts; consumers do
not need to declare it. Its overlays are re-exported unchanged as
`clanServices.overlays` (`default`, `kubernetes`, `ifstate`, ...). To use a different
artifact repository, or to share one with your own flake, declare it and set
`clanServices.inputs.org-pkgs.follows = "org-pkgs";`.

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

Needs Nix and devenv. The shell (`devenv allow` once per checkout) has the
org scripts:

```bash
fmt                      # treefmt: alejandra + org linters
check                    # nix flake check: static gates, eval tests, docs
docs-build               # static docs to ./result-docs; open index.html from disk
devenv up                # live docs on :8981 and slides on :8982
vm-test --list           # the 24 VM suites
vm-test --check <suite>  # evaluates and fits the caps; boots nothing
vm-test <suite> --remote --quiet  # one suite on the remote builder; prints the summary
vm-test --summary <suite>  # the last run's summary (subtests, failures)
vm-test --all --remote --rebuild --quiet  # every suite, side by side, fresh
```

`checks` is static-only (eval tests, coverage, formatting, lock sync, docs),
so a full `nix flake check` is safe and required. VM suites live under
`legacyPackages.x86_64-linux.vmTests.<suite>`, never in `checks` or CI. They
boot whole clusters, so they run on the remote builder (euc-hel-0): `--all`
runs as many side by side as fit the `vmTests.parallel` budget, largest
first, and reruns a suite that failed under load alone (`PASS(!)` when it
then passes); `--serial` runs one at a time. A `CACHED` result booted
nothing; `--rebuild` boots it again. Each suite's log, summary and result
land in `.vm-tests/<suite>/`. The pinned
artifact flake supplies distro runtimes, IfState, the committed Cilium
manifest, per-system Cilium/CoreDNS airgap images, and test fixtures.
