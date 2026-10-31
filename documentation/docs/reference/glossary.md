# Glossary

One term per concept. Mirrors SPEC.md §10.

- **Bootstrap contract** — distro install/join, PKI, HAProxy kubeapi HA,
  bootstrap bundle, and control-domain substrate.
- **Data-plane contract** — Cilium (native or tunnel/VXLAN profile), Node
  IPAM + pools, FRR/BGP/Zebra, ClusterMesh, per-adjacency WireGuard,
  in-cluster CoreDNS (cluster.local), and the fabric transport.
- **Day-2 GitOps** — everything in-cluster outside those contracts.
- **Bootstrap bundle** — one kubenix manifest set applied once by SSA on
  the clusterInit node.
- **Shared lib** — `lib/kube-cluster/`: interfaces, renderers, vars, and
  assertions shared by distro services.
- **Artifact flake** — `external-systems/pkgs`: nixpkgs/flake-parts
  authority, distro and IfState overlays, runtime packages, committed
  manifests, per-system airgap images, and test fixtures (D62).
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
- **IfState** — the exclusive static network renderer (D61), pinned to
  2.5.1. It reconciles links, addresses, WireGuard, static/policy routes,
  rules, and sysctls live without reboot; no systemd-networkd, netdevs, or
  scripted network units. FRR/Zebra and Cilium retain dynamic ownership.
- **netif** — inventory-owned, multi-instance/multi-link host attachments:
  physical/VLAN/bond/bridge links, addressing, routes, MTU, DNS, firewall
  trust, and endpoint/deploy-target exports, rendered through IfState.
- **Fabric adjacency** — a derived leaf↔spine, spine↔spine, or
  border↔upstream relationship; exactly one point-to-point WireGuard
  interface per adjacency, carrying API traffic, native pods, BGP, and BFD.
- **routed-fabric** — the flat-L3 service owning the fabric: two topology
  roles (leaf/spine, renamed from member/hub in round 17, D59), orthogonal
  per-machine `access`/`border` settings, the automatically derived
  spine/leaf graph, FRR/BFD/Zebra, and fleet route
  consumption (renamed from fleet-routing in round 15; native Cilium
  profile per D58).
- **Fabric role** — one of the two topology roles, `leaf` or `spine`,
  joined per machine; every spine pair is automatically adjacent and spines
  forward/readvertise between leaves.
- **Fabric access** — the per-machine orthogonal setting `member`
  (default)/`client`/`admin` controlling route consumption (D56; baseline
  membership, not topology — the enum is unchanged by the round-17 role
  rename): client adds fabric-pool LoadBalancer-VIP routes only; admin adds
  pod/ClusterIP routes; Kubernetes nodes install pod/VIP routes
  regardless (D49). Member DNS is day-2 (D22 amended).
- **Fabric border** — the optional per-machine orthogonal attrset (D56)
  for upstream transit: upstream BGP peers, owned-prefix filtering,
  forwarding, optional NDP, authorized external/fabric transit; no
  automatic admin DNS; a border need not be a spine and vice versa.
- **Routed spine** — a fabric machine in the `spine` role: automatically
  adjacent to every other spine, forwarding and readvertising between
  leaves with `next-hop-self`. Two spines are the HA default with no
  arbitrary maximum; leaves never provide transit.
- **node_transport** — the generic shared neutral transport export
  (schemaVersion 2, D58) consumed by both distro services: stable
  dual-stack node addresses/service/instance/endpoint, datapath interfaces keyed
  by Linux name with MTU, one `directRoutingDevice`,
  `datapath.mode` (`native`|`tunnel`) with sibling `datapath.tunnelProtocol`,
  `native.routeExchange = local-router`, the independent
  `internalLoadBalancer`/`nodePort` exposure capabilities, and a `port`
  plus nullable endpoint. k3s/rke2 never
  branch on service names. The wireguard-mesh profile exports its ONE
  full-mesh multi-peer interface; routed-fabric exports one interface per
  derived adjacency.
- **ClusterMesh exposure** — the apiserver exposure enum (D60):
  `auto` (default; internal-load-balancer when capable, else node-port),
  `internal-load-balancer` (ONE pinned IPv4 VIP locked at host offset
  `0x79` in the `<instance>-fabric` private pool, `lbipam.cilium.io/ips`
  projection; control-plane exposure is IPv4-only on the pinned Cilium
  1.20.3 profile — no ClusterMesh IPv6 VIP, no `RequireDualStack`
  advertisement — while the data plane stays dual-stack),
  `node-port` (exactly one apiserver per selected node,
  default NodePort `32379`, selected nodes' stable IPv4 addresses
  published), or
  `external-load-balancer` (explicit non-clan class + DNS name, always
  wins; runtime A record). Cert SANs carry published IPv4/DNS endpoints
  only. ETP Local applies to every method; placement selectors are
  voters (default)/workers/all/labels.
- **AllowedIPs / crypto ACL** — WireGuard's outbound peer selection, which
  is also the inbound source ACL; must include authorized transit prefixes.
- **Network facts** — the per-node `clan.networkFacts` NixOS interface
  (D57): versioned, JSON-serializable, non-secret, producer-owned
  build-time topology facts (underlay/fabric/ClusterMesh/control-domain
  graphs) populated through `readOnly = true` options by the service
  owning each fact; read by consumer-owned diagram wrappers and
  complementary to exports. The schema is version 2 (D59).
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
  and the pinned clustermesh-apiserver internal IPv4 VIP (host offset
  `0x79` — that apiserver VIP ONLY; kube-api mirror Services allocate
  separately and cannot share it, D30) — never a
  member-facing DNS VIP; member DNS is day-2.
- **Private-domain zones** — day-2 member-facing DNS (NOT in the MVP):
  instance, service, and pod zones published by Kubernetes-side automation
  such as external-dns; `cluster.local` never appears on clients.
- **Selective ClusterMesh** — explicit symmetric `mesh.peers` within one
  fabric; non-transitive; full mesh is the default when peers are omitted.
  Native leaf route policy follows the same edges; spine carriage of the
  union its leaves consume is the eval-visible routed-only exception.
- **Airgap-ready** — every artifact pinned and local at boot.
- **VM-proven** — behavior passed fresh, sandboxed, hermetic on the final
  tree.
