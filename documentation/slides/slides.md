# Kubernetes cluster clanServices

Declare machines in one file. Get clusters with a verifiable bootstrap and data plane.

External Systems — 2026-10-22

Note: Press `S` for the speaker view, `F` for fullscreen.

---

## The problem, solved

- Declare machines and clusters in `inventory.nix` — get working clusters
- Two verifiable day-1 contracts: **the cluster exists and is reachable**, and **packets flow correctly**
- Everything else in-cluster is day-2 GitOps: documented recipes, never clan-rendered, never host-churned

---

## What you get: the two contracts

- **Bootstrap**: distro install/join (rke2, k3s, upstream kubeadm reserved); cluster PKI + rotation runbooks; per-node HAProxy kubeapi HA; one bootstrap bundle applied once
- **Data plane**: Cilium only — KPR/VXLAN, Node IPAM for classless LoadBalancer Services, LB-IPAM pools + BGP v2 + BIRD fleet fabric, ClusterMesh, host WireGuard mesh, CoreDNS private zones
- Airgap-ready: every artifact local at boot; last 3 Kubernetes minors per distro pinned

---

<img src="assets/arch-overview.svg" alt="Architecture overview" style="width: 100%; max-height: 82vh; background: #fff; border-radius: 8px;" />

Note: One inventory in, three cluster kinds out, meshed by default. The GitOps box is operator-owned day two — clan delivers the substrate, not the controller.

---

## One bundle, then GitOps takes over

- The entire day-1 in-cluster surface is ONE kubenix-rendered bundle per cluster
- Applied once via server-side apply on the `clusterInit` node — nothing host-resident, no distro manifests dir
- Day 2: the GitOps repo adopts the identical published manifest set — first reconcile is a no-op by construction
- **Clan never installs a GitOps controller** — Flux or Argo is the operator's choice

---

<img src="assets/stack-layers.svg" alt="Stack layers" style="width: 100%; max-height: 82vh; background: #fff; border-radius: 8px;" />

Note: Bottom layers are the two clan contracts — hosts/transport, distro, Cilium networking. The top layers (GitOps controller, Envoy Gateway, cert-manager, external-dns, Sealed Secrets) are day-2 recipes owned by operator GitOps repos. Secrets: clan vars hold the bootstrap plane only.

---

<img src="assets/hub-spoke.svg" alt="Hub and spoke" style="width: 72%; max-height: 62vh; background: #fff; border-radius: 8px;" />

- `controlDomain.role = standalone | hub | spoke` — a GitOps-neutral substrate
- Clan renders mirror Services, `gitops-hub` client-cert identities, and per-spoke kubeconfig Secrets
- Any GitOps tool consumes them (Flux `kubeConfig.secretRef`, Argo cluster secrets); spokes run no controller
- Admin machines reach everything through the BGP fleet fabric

---

## Detail map: every component by layer

- **Hosts**: NixOS; WireGuard transport; per-node BIRD; fleet-routing (client/admin/router) for non-cluster machines
- **Distro**: k3s / rke2 (CIS default) / kubernetes (kubeadm, reserved); thin clanServices over one shared library; `distroDefaults.enable=true` restores stock Traefik/helm-controller on rke2/k3s; servicelb permanently off (Node IPAM replaces it)
- **Networking** (the whole day-1 in-cluster surface): Cilium — CNI, Node IPAM default, LB IPAM pools (2 scopes × 4 delivery modes), BGP v2, ClusterMesh; networking only, no Gateway/Ingress
- **Day two** (GitOps-owned recipes, never clan-rendered): Envoy Gateway, cert-manager, external-dns, Sealed Secrets, OpenEBS, KubeVirt, provider CCMs
- **Secrets**: clan vars = bootstrap plane only (CAs, tokens, kubeconfigs); all application credentials GitOps-owned; read-only (no-secrets) kubeconfigs for AI agents
- **Packaging**: artifact flake — pinned distro runtimes, Cilium chart + committed base manifest, airgap default

---

## Status and roadmap

- **Done**: canonical import (`896acdf`); wireguard-mesh + rke2/k3s single/join/HA VM suites green; round-13 spec — data-plane-only scope
- **Next**: scope-reduction execution — delete out-of-contract code, `lib/kube-cluster/` rename, `distroDefaults` knob
- **Then**: artifact-flake narrowing; kubenix bootstrap bundle + SSA apply; transport; BGP/BIRD fabric + fleet-routing; ClusterMesh + control domain; PKI ops + GitOps-handoff proof suite
- **Reserved**: upstream `kubernetes` distro implementation, MCS-API, clan-operator (per-agent identity minting)

Note: Full record: SPEC.md + documentation/ in the repo.
