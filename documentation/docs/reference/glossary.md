# Glossary

One term per concept. Mirrors SPEC.md §10.

- **Bootstrap contract** — distro install/join, PKI, HAProxy kubeapi HA,
  bootstrap bundle, and control-domain substrate.
- **Data-plane contract** — native Cilium, Node IPAM + pools, FRR/BGP/Zebra,
  ClusterMesh, per-pair WireGuard, CoreDNS zones, and fleet-routing.
- **Day-2 GitOps** — everything in-cluster outside those contracts.
- **Bootstrap bundle** — one kubenix manifest set applied once by SSA on
  the clusterInit node.
- **Shared lib** — `lib/kube-cluster/`: interfaces, renderers, vars, and
  assertions shared by distro services.
- **Artifact flake** — `external-systems/pkgs`: distro runtimes, Cilium
  chart + committed base manifest, and test fixtures.
- **Distro** — `rke2`, `k3s`, or reserved upstream `kubernetes`.
- **distroDefaults** — opt-in stock rke2/k3s packaged components;
  servicelb remains off.
- **CNCF posture** — CNCF projects for clan-rendered in-cluster components;
  host FRR, WireGuard, and HAProxy are exempt.
- **Kubenix rendering** — typed Nix module resources; chart inflation only
  in the artifact flake at update time.
- **IFD** — import-from-derivation, forbidden in clanServices evaluation.
- **Control domain** — standalone/hub/spoke clusters managed by one GitOps
  control plane, bounded by a mesh trust domain.
- **Trust domain** — the ClusterMesh group; also bounds control domains.
- **Mirror Service** — selectorless ClusterMesh-global Service and
  EndpointSlice exposing a cluster's kube-apiserver.
- **Bootstrap plane** — clan vars custody for cluster CAs, tokens,
  kubeconfigs, ClusterMesh material, HAProxy checks, and gitops identities.
- **netif** — inventory-owned host links, addressing, routes, MTU, DNS,
  firewall trust, and endpoint/deploy-target exports.
- **Integrated node transport** — stable dual-stack node addresses and one
  routed WireGuard interface per node pair carrying API, native pods, BGP,
  and BFD.
- **Fleet-routing** — the flat-L3 service with member/client/admin/router
  roles and one integrated FRR configuration per host.
- **Pool scope** — per-machine with one owner, or cluster-global.
- **Delivery mode** — node-fate-bound, node-bgp, floating, shared-bgp, or
  external-class.
- **Node IPAM** — Cilium's classless LoadBalancer default; distinct from
  pod `ipam.mode`.
- **LB IPAM pool** — CiliumLoadBalancerIPPool serving Cilium-handled
  LoadBalancer classes.
- **Node-fate-bound** — provider/static routing to one node; no BGP.
- **Node BGP** — only the owner advertises exact VIPs from its per-machine
  pool; no cross-node ECMP.
- **Shared BGP VIP** — every healthy eligible node advertises; ETP-Local
  withdraws unhealthy paths; routers ECMP.
- **Floating delivery** — a runtime controller moves one address; without
  it, the documented blackhole window remains.
- **Private fleet fabric** — default private shared-bgp pool, FRR/BGP/Zebra,
  and CoreDNS/mesh VIPs.
- **Private-domain zones** — instance, service, and pod zones on private
  CoreDNS; `cluster.local` never appears on clients.
- **Airgap-ready** — every artifact pinned and local at boot.
- **VM-proven** — behavior passed fresh, sandboxed, hermetic on the final
  tree.
