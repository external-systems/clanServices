# Glossary

One term per concept. From SPEC.md §9.

- **Cluster services** — the public rke2/k3s/kubernetes clanServices plus
  the private shared library; not Rancher Manager.
- **Artifact flake** — `external-systems/pkgs`; pinned packages, charts,
  images, and CRDs without fleet policy; carries the last 3 k8s minors per
  distro (D34).
- **Distro** — the Kubernetes distribution a cluster instance runs:
  `rke2` | `k3s` | `kubernetes` (upstream, kubeadm-based, D23).
- **CNCF posture** — in-cluster components are CNCF projects; host-level
  components (BIRD, WireGuard) are exempt; rke2 is the documented distro
  exception (D24).
- **Kubenix rendering** — manifests built as typed Nix module resources;
  Helm inflation only at artifact-flake build time (D26).
- **Flux bootstrap** — clan-rendered flux-operator + FluxInstance present
  from first boot on every cluster (D28).
- **Hub cluster** — the cluster holding spoke kubeconfigs and delivering
  workloads fleet-wide via Flux `kubeConfig.secretRef`; never installs Flux
  remotely (D28).
- **Mirror Service** — clan-rendered selectorless ClusterMesh-global
  Service + EndpointSlice exposing a cluster's kube-apiserver to mesh
  members (D30).
- **Bootstrap plane / application plane** — secrets custody split: clan
  vars own bootstrap secrets (CAs, tokens, kubeconfigs, sealing keys);
  GitOps + Sealed Secrets own in-cluster application credentials (D35).
- **Integrated node transport** — per-cluster routed L3 (host WireGuard
  default | cilium-wireguard | unencrypted) carrying dual-stack node
  InternalIPs, API, and VXLAN.
- **Mesh group** — mutually trusted cluster instances forming one
  ClusterMesh.
- **Pool scope** — per-machine (node-named) vs cluster-global
  (generic-named); who contributes a pool's addresses.
- **Delivery mode** — node-fate-bound | floating | shared-bgp |
  external-class; how traffic reaches pool addresses, and its failure
  semantics.
- **Node-fate-bound delivery** — provider/static routing to one node; no
  failover, no BGP.
- **Floating delivery** — a runtime controller moves the address to one
  node at a time; failover is the controller's contract, not eval-visible.
- **Shared BGP VIP** — an address advertised from all healthy nodes
  (ETP-Local withdrawal); the `shared-bgp` mode of a cluster-global pool.
- **Private fleet fabric** — the default per-cluster private shared-bgp
  pool + BIRD/BGP base + CoreDNS/private-Gateway VIPs; lets clan hosts
  route into every cluster.
- **Node-named pool** — a per-machine pool of join + declared extra blocks.
- **Explicit projection** — an eval-time `lbipam.cilium.io/ips` list of
  per-node addresses for deterministic multi-IP Service status.
- **ETP Local** — `externalTrafficPolicy: Local`; traffic accepted only
  with ready local endpoints; direct node traffic avoids SNAT.
- **Gateway class / instance** — class = GatewayClass + EnvoyProxy (the
  isolation domain); instance = one clan-rendered Gateway bound to a class.
- **Shared-gateway model** — the platform owns the Gateway and listeners;
  tenants own Routes; cert-manager Gateway integration provisions certs.
- **Zero-churn contract** — `gateway.instances = {}` + clan pools ⇒ a full
  tenant Gateway stack via GitOps, no NixOS rebuild.
- **Fleet CA** — a dedicated shared root CA signing private-Gateway certs;
  installed into clan hosts' trust stores by the client/admin roles.
- **Fleet-routing service** — clanService (client/admin/router roles)
  giving non-Kubernetes hosts routed access to cluster VIPs (client),
  pod/Service CIDRs (admin), or upstream prefix ownership (router).
- **Private-domain zones** — per-cluster DNS zones served by cluster
  CoreDNS on the private VIP: `<instance>.<domain>` (wildcard → Gateway,
  default) and the opt-in `<instance>.svc.<domain>` (rewrite to Service
  IPs) and pod zone. `cluster.local` never appears on clients.
- **Fleet-wide mTLS (east-west)** — the preferred path: the private
  Gateway validates client certs against the fleet CA; clan machines hold
  per-machine client certs. Gated on VM proof before default-on.
- **Managed base** — labeled clan-rendered APIs/resources installed once;
  tenant resources are GitOps-owned.
- **Airgap-ready** — all artifacts pinned and local at boot.
- **VM-proven** — behavior passed fresh, sandboxed, hermetic on the final
  tree.
