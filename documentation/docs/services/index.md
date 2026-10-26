# Services

The public clanServices in this flake. Cluster services (`rke2`, `k3s`, and
the reserved `kubernetes`) are thin distro layers over the private shared
library; host-network services own the inventory-facing data plane. Round
17 (D58–D60, **planned target**): transport becomes a generic
`node_transport` export consumed by both distros, the fabric topology is
renamed `leaf`/`spine`, and ClusterMesh gains explicit
placement/exposure profiles.

| Service | Kind | Status |
| --- | --- | --- |
| [rke2](rke2.md) | cluster distro | bootstrap implemented; netif + routed-fabric data plane implemented (round-16 shape); round-17 generic `node_transport`/ClusterMesh contract planned |
| [k3s](k3s.md) | cluster distro | bootstrap implemented; netif + routed-fabric data plane implemented (round-16 shape); round-17 generic `node_transport`/ClusterMesh contract planned |
| [kubernetes](kubernetes.md) | cluster distro (upstream kubeadm) | fully spec'd, Reserved (D23) |
| [netif](netif.md) | host links and static routes | **implemented** (5R1, multi-instance/multi-link) |
| [routed-fabric](routed-fabric.md) | flat-L3 WG/FRR fabric | **implemented** (5R1, round-16 `member`/`hub` shape); round-17 `leaf`/`spine` + generic schema planned |
| [wireguard-mesh](wireguard-mesh.md) | host transport | implemented; **supported tunnel/VXLAN profile** (round 17, D58) |

The legacy code still at `services/fleet-routing/` predates the round-15+
design (full-mesh target, BIRD-era checkpoint) and is not the
routed-fabric implementation. The replacement landed under
`services/routed-fabric/` in 5R1, and the obsolete `fleet-routing`
code — like the legacy `lib/import-flake/` adapter — is **deleted
outright** once the replacement suites are green — no archiving, no
commented-out remnants. `wireguard-mesh` is **not** retiring: round 17
keeps it as the validated tunnel/VXLAN profile.

## How the cluster services share code

Distro-specific behavior — bootstrap, TLS directory layout, join semantics —
lives in the thin `rke2` and `k3s` services. Everything shared (interfaces,
renderers, vars generators, assertions) lives once in the private shared
library `lib/kube-cluster/`. A fix in shared behavior lands once, not twice.

The cluster services deliver the Bootstrap and Data-plane contracts and
nothing else in-cluster: one kubenix-rendered bootstrap bundle applied once
via server-side apply. The default is a uniform minimal base across distros;
`distroDefaults` restores stock components through the distro itself.
**Round-17 target (5R5):** both distros consume **only** the generic
`node_transport` export for transport — never branching on service names
(D58); today's code still consumes the provider-specific `routed_fabric`
export from the round-16 implementation.

A machine belongs to at most one cluster instance and **at most one**
routed-fabric instance (D53); multiple routed-fabric instances segment
trust domains, one membership per host. Global units, generators, and
interfaces are instance-namespaced; one integrated FRR configuration owns
routing on each host.
