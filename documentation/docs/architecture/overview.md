# Architecture overview

The whole design in one paragraph: thin public `rke2` and `k3s` clanServices
(upstream `kubernetes`/kubeadm fully spec'd, implementation reserved — D23)
sit on top of a private shared library (`lib/kube-cluster/` — renamed from
`lib/rancher-cluster/` in delivery phase 1, D45) that owns the shared
interfaces, kubenix renderers, vars generators, and assertions. The library
delivers exactly two contracts: the **Bootstrap contract** (the cluster
exists and is reachable) and the **Data-plane contract** (packets flow
correctly) — D39. Everything else in-cluster is day-2 GitOps, documented as
recipes, never clan-rendered. An artifact flake pins the distro runtimes and
the Cilium chart. Clan never installs a GitOps controller.

## The layers

**Machines and transport.** Machines are NixOS clan machines. `netif` owns
inventory-declared links and static routes, multi-instance and multi-link.
All static networking renders through IfState 2.5.1 and reconciles live;
there is no systemd-networkd, netdev, or scripted network renderer.
`routed-fabric` provides the native overlay: dual-stack, encrypted flat L3
with `leaf`/`spine` topology, one WireGuard interface per adjacency, and
FRR/BFD/Zebra on every fabric machine. `wireguard-mesh` is the supported
tunnel/VXLAN profile over the same generic `node_transport` export.

**Distro runtime.** `rke2` and `k3s` are thin services: they own bootstrap,
TLS directory, and join semantics. Everything shared — interfaces,
rendering, secrets, assertions — lives once in the library, so a fix lands
once, not twice. `distroDefaults.enable` (D42) defaults to `false` for a
uniform minimal base across all three distros; set it `true` on rke2/k3s to
restore stock distro components (helm-controller, Traefik, Multus) through
the distro's own machinery. servicelb stays off in both modes — Node IPAM
replaces it.

**Cilium, networking-only (D1).** Cilium is the CNI, kube-proxy replacement,
multi-pool pod IPAM, Node IPAM for classless LoadBalancer
Services, LB-IPAM pools, BGP v2 speaker, and ClusterMesh control plane.
Native routing is the routed-fabric profile default; the wireguard-mesh
tunnel/VXLAN profile is equally supported — both publish the generic
`node_transport` export that distro services consume. Its
Gateway and Ingress controllers are permanently disabled. See
[Networking](networking.md).

**FRR + Zebra fabric.** Per-node FRR receives pod-pool and VIP routes from
local Cilium, exchanges filtered routes over per-adjacency WireGuard with
`next-hop-self` on spine readvertisement, and uses Zebra to install kernel
routes. BFD detects fabric failures. Spines forward and readvertise; leaves
never transit; there is no iBGP or route reflector. Node-owned BGP pools
have one advertiser; shared pools ECMP across healthy nodes — and across
the two HA spines. See [Routed fabric](routed-fabric.md).

**The bootstrap bundle (D40).** The entire day-1 in-cluster surface is ONE
kubenix-rendered manifest set per cluster — Cilium, pools, ClusterMesh
config, clan CoreDNS (cluster-local), mirror Services, RBAC — applied once by a oneshot on
the `clusterInit` machine via
`kubectl apply --server-side --field-manager=clan-bootstrap`. Nothing is
written to the distro's watched manifests dir. Day 2, your GitOps adopts the
identical published set; the first reconcile is a no-op by construction. See
[GitOps](gitops.md).

**Control domain (D43).** Clusters run `standalone` (default), or as
`hub`/`spoke` control domains bounded by the mesh trust domain. Clan renders
only the tool-agnostic substrate: API mirror Services, the `gitops-hub`
client-cert identities, in-spoke RBAC, and hub-side `gitops-spoke-<spoke>`
kubeconfig Secrets. It installs no GitOps controller — Flux, Argo, or
anything else is your day-2 choice. See [Multi-cluster](multi-cluster.md).

**HAProxy kubeapi HA.** Every machine post-bootstrap runs clan-rendered
HAProxy on loopback, load-balancing that cluster's API endpoints; the join
URL and agent kubeconfigs point at it, so server loss never strands
machines. This is control-plane HA only — there is no edge proxy in the
contract.

**Artifact flake** (`external-systems/pkgs`). Authoritative for nixpkgs and
flake-parts, the IfState/Kubernetes overlays, distro runtimes (last three
Kubernetes minors each, D34), the committed Cilium base manifest, per-system
Cilium/CoreDNS airgap images, and the go-httpbin test fixture (D62).
Rendering is two-layer: the chart is helm-inflated at update time and
committed as source (zero IFD downstream); clanServices follows the shared
inputs, re-exports the overlays, and applies per-cluster variation by kubenix
module merging over the typed resource tree (D26). Hermetic and airgap-ready
by default.

**Secrets planes (D35).** Clan vars own bootstrap secrets only — cluster
CAs, join tokens, admin + read-only kubeconfigs, ClusterMesh material,
HAProxy health-check material, `gitops-hub` identities. Sealed-Secrets
sealing keys and all in-cluster application credentials are day-2
GitOps-owned. See [Secrets](../guides/secrets.md).

## Where things live

| Component | Owned by |
| --- | --- |
| Bootstrap, TLS dir, join semantics | thin distro service (`rke2` / `k3s`) |
| Interfaces, renderers, vars, assertions | shared library (`lib/kube-cluster/`) |
| Shared inputs, overlays, distro runtimes, manifests, airgap images, test fixtures | artifact flake (pinned) |
| Bootstrap bundle delivery (SSA, once) | clan (`clusterInit` oneshot) |
| Everything else in-cluster: proxies, certs, DNS automation, storage, GitOps | your GitOps repos (day 2) |

Misconfiguration fails at evaluation wherever possible and is VM-proven
where it cannot be. The full invariant list is SPEC.md §5.
