# Services

The public clanServices in this flake. Cluster services (`rke2`, `k3s`, and
the reserved `kubernetes`) are thin distro layers over the private shared
library; the others stand alone.

| Service | Kind | Status |
| --- | --- | --- |
| [rke2](rke2.md) | cluster distro | implemented; VM suites green |
| [k3s](k3s.md) | cluster distro | implemented; VM suites green |
| [kubernetes](kubernetes.md) | cluster distro (upstream kubeadm) | fully spec'd, Reserved (D23) |
| [wireguard-mesh](wireguard-mesh.md) | host transport | implemented; VM suites green |
| [fleet-routing](fleet-routing.md) | host → fleet routing | planned (phase 11) |

## How the cluster services share code

Distro-specific behavior — bootstrap, TLS directory layout, join semantics —
lives in the thin `rke2` and `k3s` services. Everything else (interfaces,
renderers, vars generators, assertions) lives once in the private
`lib/rancher-cluster/` library, with a planned rename to
`lib/kube-cluster/` when the upstream `kubernetes` distro lands (D23). A fix
in shared behavior lands once, not twice.

A machine belongs to at most one cluster instance across all distros (D16),
and every global (systemd units, vars generators, interfaces) is namespaced
by instance name, so multiple clusters coexist safely in one inventory.
