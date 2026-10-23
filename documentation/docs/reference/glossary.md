# Glossary

One term per concept. Mirrors SPEC.md §10.

- **Bootstrap contract** — the day-1 promise that a declared cluster exists
  and is reachable: distro install/join, PKI, HAProxy kubeapi HA, bootstrap
  bundle, control-domain substrate.
- **Data-plane contract** — the day-1 promise that packets flow correctly:
  Cilium CNI, Node IPAM + pools, BGP/BIRD, ClusterMesh, host WireGuard,
  CoreDNS zones, fleet-routing.
- **Day-2 GitOps** — everything in-cluster that is not the two contracts;
  installed and owned by operator GitOps repos, documented here as recipes
  only.
- **Bootstrap bundle** — the single kubenix-rendered manifest set per
  cluster, applied once via SSA on the `clusterInit` machine (D40).
- **Cluster services** — the public rke2/k3s/kubernetes clanServices plus
  the private shared library; not Rancher Manager.
- **Shared lib** — `lib/kube-cluster/` (renamed from
  `lib/rancher-cluster/`, D45): interfaces, renderers, vars, assertions.
- **Artifact flake** — `external-systems/pkgs`; distro runtimes (last 3
  minors, D34), Cilium chart + committed base manifest, test fixtures.
- **Distro** — the Kubernetes distribution a cluster instance runs:
  `rke2` | `k3s` | `kubernetes` (upstream, kubeadm-based, D23).
- **distroDefaults** — per-distro-service knob; `true` on rke2/k3s restores
  stock packaged components (helm-controller, Traefik, Multus) via the
  distro's own machinery (D42).
- **CNCF posture** — clan-rendered in-cluster components are CNCF projects;
  host-level (BIRD, WireGuard, HAProxy) exempt; rke2 is the documented
  distro exception (D24).
- **Kubenix rendering** — manifests built as typed Nix module resources;
  chart inflation only at artifact-flake update time (D26).
- **IFD (import-from-derivation)** — evaluation reading a derivation's
  output, forcing a build during eval; forbidden in clanServices (D26).
- **Base manifest** — a chart rendered with the canonical fleet-uniform
  profile, committed as source in the artifact flake (D26 layer 1).
- **Control domain** — the set of clusters one GitOps control plane manages:
  a hub plus its spokes (D43). Bounded by a mesh trust domain.
- **Control-domain role** — per-cluster `standalone` (shares nothing) |
  `hub` (holds spoke kubeconfigs) | `spoke` (hub-reconciled) (D43).
- **Trust domain** — the ClusterMesh mesh group string (default
  `meta.domain`); bounds ClusterMesh peering AND control domains (D43).
- **gitops-hub identity** — the per-spoke client certificate (CN
  `gitops-hub-<spoke>`, O `gitops-hub`) signed by the spoke's cluster CA,
  consumed by whatever GitOps tool the hub runs (D43).
- **Read-only credential** — the per-cluster client certificate (CN
  `readonly-<instance>`, O `cluster-readers`) and kubeconfig for no-secrets
  read access, minted for AI agents; synced to the hub for spokes (D38).
- **Mirror Service** — clan-rendered selectorless ClusterMesh-global Service
  + EndpointSlice exposing a cluster's kube-apiserver to mesh members (D30);
  mandatory for spokes.
- **Bootstrap plane** — secrets custody: clan vars own bootstrap secrets
  only (CAs, tokens, admin + read-only kubeconfigs, ClusterMesh material,
  HAProxy health-check material, gitops-hub identities); all
  application-plane secrets are GitOps-owned (D35).
- **Integrated node transport** — per-cluster routed L3 host WireGuard full
  mesh carrying dual-stack node InternalIPs, API, VXLAN.
- **Mesh group** — mutually trusted cluster instances forming one
  ClusterMesh; the trust domain string.
- **Pool scope** — per-machine (node-named) vs cluster-global
  (generic-named); who contributes a pool's addresses.
- **Delivery mode** — node-fate-bound | floating | shared-bgp |
  external-class; how traffic reaches pool addresses + failure semantics.
- **Node IPAM** — Cilium's LoadBalancer feature (helm `nodeIPAM.enabled`)
  that advertises node IPs (ExternalIP, else InternalIP) as a Service's LB
  ingress; the classless-Service default (D41). Distinct from
  `ipam.mode: kubernetes` (pod IPAM), which is an allowed override.
- **LB IPAM pool** — CiliumLoadBalancerIPPool; serves only Services with a
  Cilium-handled `loadBalancerClass` (`io.cilium/lb-ipam`,
  `io.cilium/bgp-control-plane` for BGP-announced draws) (D41/D8); the only
  VIP mechanism.
- **Node-fate-bound delivery** — provider/static routing to one node; no
  failover, no BGP.
- **Floating delivery** — runtime controller moves the address to one node
  at a time; failover is the controller's contract. Without a controller the
  address is node-fate-bound in practice: the documented blackhole window
  when the holder dies.
- **Shared BGP VIP** — address advertised from all healthy nodes (ETP-Local
  withdrawal); the `shared-bgp` mode of a cluster-global pool.
- **Private fleet fabric** — default per-cluster private shared-bgp pool +
  BIRD/BGP base + CoreDNS/mesh VIPs; lets clan machines route into every
  cluster.
- **Fleet-routing service** — clanService (client/admin/router roles) giving
  non-Kubernetes machines routed access to cluster VIPs (client),
  pod/Service CIDRs (admin), or upstream prefix ownership (router).
- **Private-domain zones** — per-cluster DNS zones served by cluster CoreDNS
  on the private VIP: `<instance>.<domain>` (default) and opt-in
  `<instance>.svc.<domain>` and pod zone. `cluster.local` never appears on
  clients.
- **Managed base** — labeled clan-rendered APIs/resources installed once via
  the bootstrap bundle; tenant resources GitOps-owned.
- **Airgap-ready** — all artifacts pinned and local at boot.
- **VM-proven** — behavior passed fresh, sandboxed, hermetic on final tree.
