# Services

The public clanServices in this flake. Cluster services (`rke2`, `k3s`, and
the reserved `kubernetes`) are thin distro layers over the private shared
library; host-network services own the inventory-facing data plane. The
generic `node_transport` export feeds both distros, fabric topology is
`leaf`/`spine`, and ClusterMesh has explicit placement/exposure profiles.
IfState 2.5.1 is the exclusive static networking renderer.

| Service | Kind | Status |
| --- | --- | --- |
| [rke2](rke2.md) | cluster distro | bootstrap and the native data plane implemented and VM-proven |
| [k3s](k3s.md) | cluster distro | bootstrap and the native data plane implemented and VM-proven |
| [kubernetes](kubernetes.md) | cluster distro (upstream kubeadm) | fully spec'd, Reserved (D23) |
| [netif](netif.md) | host links and static routes | implemented with IfState; live apply and DHCP/RA VM-proven |
| [routed-fabric](routed-fabric.md) | flat-L3 WG/FRR fabric | `leaf`/`spine` + generic schema implemented; transport and HA VM-proven |
| [remote-builder](remote-builder.md) | fleet utility (nix builds over ssh-ng) | implemented; eval-tested, outside the cluster contracts (D65) |

The obsolete `services/fleet-routing/` code (full-mesh target, BIRD-era
checkpoint) and the legacy `lib/import-flake/` adapter were deleted in the
round-17 cleanup, along with BIRD helpers and BIRD-specific VM fixtures.
There are no archives or commented-out remnants. `wireguard-mesh` and
Cilium tunnel mode were removed by D72 (round 53): native routing on
`routed-fabric` is the only data plane. The last commit with them is
tag `tunnel-mode-final`.

## How the cluster services share code

Distro-specific behavior — bootstrap, TLS directory layout, join semantics —
lives in the thin `rke2` and `k3s` services. Everything shared (interfaces,
renderers, vars generators, assertions) lives once in the private shared
library `lib/kube-cluster/`. A fix in shared behavior lands once, not twice.

The cluster services deliver the Bootstrap and Data-plane contracts and
nothing else in-cluster: one kubenix-rendered bootstrap bundle applied once
via server-side apply. The default is a uniform minimal base across distros;
`distroDefaults` restores stock components through the distro itself. Both
distros consume **only** the generic `node_transport` export for transport —
never branching on service names (D58).

A machine belongs to at most one cluster instance and **at most one**
routed-fabric instance (D53); multiple routed-fabric instances segment
trust domains, one membership per host. Global units, generators, and
interfaces are instance-namespaced; one integrated FRR configuration owns
routing on each host.
