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

**Machines and transport.** Machines are NixOS clan machines. Host WireGuard
full mesh is the only tested node transport — dual-stack, all-or-none per
mesh trust domain. `cilium-wireguard` and `unencrypted` survive only as
untested Cilium helm-values overrides.

**Distro runtime.** `rke2` and `k3s` are thin services: they own bootstrap,
TLS directory, and join semantics. Everything shared — interfaces,
rendering, secrets, assertions — lives once in the library, so a fix lands
once, not twice. `distroDefaults.enable` (D42) defaults to `false` for a
uniform minimal base across all three distros; set it `true` on rke2/k3s to
restore stock distro components (helm-controller, Traefik, Multus) through
the distro's own machinery. servicelb stays off in both modes — Node IPAM
replaces it.

**Cilium, networking-only (D1).** Cilium is the CNI, kube-proxy replacement,
VXLAN tunnel, multi-pool pod IPAM, Node IPAM for classless LoadBalancer
Services, LB-IPAM pools, BGP v2 speaker, and ClusterMesh control plane. Its
Gateway and Ingress controllers are permanently disabled. See
[Networking](networking.md).

**BIRD + BGP fabric.** Per-node BIRD receives VIP routes from Cilium agents
and exports exactly those to your upstream router — ECMP across healthy
nodes. A private fleet fabric is on by default (D10); the fleet-routing
clanService extends VIP/pod/Service reachability to non-Kubernetes NixOS
machines. See [Fleet routing](fleet-routing.md).

**The bootstrap bundle (D40).** The entire day-1 in-cluster surface is ONE
kubenix-rendered manifest set per cluster — Cilium, pools, ClusterMesh
config, CoreDNS zones, mirror Services, RBAC — applied once by a oneshot on
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

**Artifact flake** (`external-systems/pkgs`). Pins the distro runtimes (last
three Kubernetes minors each, D34), the Cilium chart with its committed
inflated base manifest, and the go-httpbin test fixture. Rendering is
two-layer: the chart is helm-inflated at update time and committed as source
(zero IFD downstream); clanServices applies per-cluster variation by kubenix
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
| Distro runtimes, Cilium chart + base manifest, test fixtures | artifact flake (pinned) |
| Bootstrap bundle delivery (SSA, once) | clan (`clusterInit` oneshot) |
| Everything else in-cluster: proxies, certs, DNS automation, storage, GitOps | your GitOps repos (day 2) |

Misconfiguration fails at evaluation wherever possible and is VM-proven
where it cannot be. The full invariant list is SPEC.md §5.
