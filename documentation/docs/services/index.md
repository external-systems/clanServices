# Services

The public clanServices in this flake. Cluster services (`rke2`, `k3s`, and
the reserved `kubernetes`) are thin distro layers over the private shared
library; the others stand alone.

| Service | Kind | Status |
| --- | --- | --- |
| [rke2](rke2.md) | cluster distro | implemented; VM suites green |
| [k3s](k3s.md) | cluster distro | implemented; VM suites green |
| [kubernetes](kubernetes.md) | cluster distro (upstream kubeadm) | fully spec'd, Reserved (D23) |
| [wireguard-mesh](wireguard-mesh.md) | machine transport | implemented; VM suites green |
| [fleet-routing](fleet-routing.md) | machine → fleet routing | planned (phase 5) |

## How the cluster services share code

Distro-specific behavior — bootstrap, TLS directory layout, join semantics —
lives in the thin `rke2` and `k3s` services. Everything else (interfaces,
renderers, vars generators, assertions) lives once in the private shared
library `lib/kube-cluster/` (renamed from `lib/rancher-cluster/` at spec
level in round 13, D45; the code rename lands with delivery phase 1). A fix
in shared behavior lands once, not twice.

The cluster services deliver the two contracts — bootstrap and data plane —
and nothing else in-cluster: the entire day-1 surface is one kubenix-rendered
bootstrap bundle applied once via server-side apply on the `clusterInit`
machine (D40). The default is a uniform minimal base across distros
(`distroDefaults.enable = false`, D42); opting in on rke2/k3s restores stock
distro components through the distro's own machinery.

A machine belongs to at most one cluster instance across all distros (D16),
and every global (systemd units, vars generators, interfaces) is namespaced
by instance name, so multiple clusters coexist safely in one inventory.
