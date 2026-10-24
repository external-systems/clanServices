# Services

The public clanServices in this flake. Cluster services (`rke2`, `k3s`, and
the reserved `kubernetes`) are thin distro layers over the private shared
library; host-network services own the inventory-facing data plane.

| Service | Kind | Status |
| --- | --- | --- |
| [rke2](rke2.md) | cluster distro | bootstrap implemented; round-14 native/FRR data plane planned |
| [k3s](k3s.md) | cluster distro | bootstrap implemented; round-14 native/FRR data plane planned |
| [kubernetes](kubernetes.md) | cluster distro (upstream kubeadm) | fully spec'd, Reserved (D23) |
| [netif](netif.md) | host links and static routes | planned (phase 5R1) |
| [fleet-routing](fleet-routing.md) | flat-L3 WG/FRR fabric | round-14 target (phases 5R1–5R3) |
| [wireguard-mesh](wireguard-mesh.md) | legacy host transport | implemented; superseded, pending migration/removal |

## How the cluster services share code

Distro-specific behavior — bootstrap, TLS directory layout, join semantics —
lives in the thin `rke2` and `k3s` services. Everything shared (interfaces,
renderers, vars generators, assertions) lives once in the private shared
library `lib/kube-cluster/`. A fix in shared behavior lands once, not twice.

The cluster services deliver the Bootstrap and Data-plane contracts and
nothing else in-cluster: one kubenix-rendered bootstrap bundle applied once
via server-side apply. The default is a uniform minimal base across distros;
`distroDefaults` restores stock components through the distro itself.

A machine belongs to at most one cluster instance and at most one
fleet-routing instance. Global units, generators, and interfaces are
instance-namespaced; one integrated FRR configuration owns routing on each
host.
