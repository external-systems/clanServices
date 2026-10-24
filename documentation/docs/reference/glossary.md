# Glossary

One term per concept. Mirrors SPEC.md §10.

- **Bootstrap contract** — distro install/join, PKI, HAProxy kubeapi HA,
  bootstrap bundle, and control-domain substrate.
- **Data-plane contract** — native Cilium, Node IPAM + pools, FRR/BGP/Zebra,
  ClusterMesh, per-adjacency WireGuard, CoreDNS zones, and routed-fabric.
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
- **Trust domain** — one routed-fabric instance's membership; also bounds
  control domains and ClusterMesh reachability policy.
- **Mirror Service** — selectorless ClusterMesh-global Service and
  EndpointSlice exposing a cluster's kube-apiserver.
- **Bootstrap plane** — clan vars custody for cluster CAs, tokens,
  kubeconfigs, ClusterMesh material, HAProxy checks, and gitops identities.
- **netif** — inventory-owned, multi-instance/multi-link host attachments:
  physical/VLAN/bond/bridge links, addressing, routes, MTU, DNS, firewall
  trust, and endpoint/deploy-target exports.
- **Fabric adjacency** — a declared hub↔spoke, hub↔hub, or router↔upstream
  relationship; exactly one point-to-point WireGuard interface per
  adjacency, carrying API traffic, native pods, BGP, and BFD.
- **routed-fabric** — the flat-L3 service owning the fabric: four canonical
  roles, explicit hub topology, FRR/BFD/Zebra, and fleet DNS
  consumption (renamed from fleet-routing in round 15).
- **Fabric role** — one of member/client/admin/router, joined per machine;
  member is the base, the others specialized (client + VIP + instance DNS;
  admin + pod/ClusterIP + svc/pod DNS; router + authorized
  external/upstream transit).
- **Routed hub** — a fabric member listed in the instance's explicit hub
  topology (`settings.hubs`) that forwards and readvertises between spokes;
  orthogonal to the router role. Minimum one, HA is two; spokes never
  transit.
- **AllowedIPs / crypto ACL** — WireGuard's outbound peer selection, which
  is also the inbound source ACL; must include authorized transit prefixes.
- **Alternative overlays** — official mycelium/yggdrasil/wireguard meshes;
  overlays, never underlays; the standard `peer` export set is the seam.
- **Pool scope** — per-machine with one owner, or cluster-global.
- **Delivery mode** — node-fate-bound, node-bgp, floating, shared-bgp, or
  external-class.
- **Node IPAM** — Cilium's classless LoadBalancer default; fabric-scoped,
  distinct from pod `ipam.mode`.
- **LB IPAM pool** — CiliumLoadBalancerIPPool serving Cilium-handled
  LoadBalancer classes.
- **Node-fate-bound** — provider/static routing to one node; no BGP.
- **Node BGP** — only the owner advertises exact VIPs from its per-machine
  pool; used only where BGP delivery exists; no cross-node ECMP.
- **Shared BGP VIP** — every healthy eligible node advertises; ETP-Local
  withdraws unhealthy paths; routers ECMP.
- **Floating delivery** — a runtime controller moves one address; without
  it, the documented blackhole window remains.
- **Private fleet fabric** — default private shared-bgp pool, FRR/BGP/Zebra,
  and CoreDNS/mesh VIPs.
- **Private-domain zones** — instance, service, and pod zones on private
  CoreDNS; `cluster.local` never appears on clients.
- **Selective ClusterMesh** — explicit symmetric `mesh.peers` within one
  fabric; non-transitive; full mesh is the default when peers are omitted.
- **Airgap-ready** — every artifact pinned and local at boot.
- **VM-proven** — behavior passed fresh, sandboxed, hermetic on the final
  tree.
