# Kubernetes cluster clanServices

Declare machines and clusters in one file. Get clusters with a verifiable bootstrap and data plane.

External Systems — 2026-10-24

Note: Press `S` for the speaker view, `F` for fullscreen.

---

## The problem, solved

- Declare host networking, machines, and clusters in `inventory.nix`
- Two verifiable day-1 contracts: **the cluster exists and is reachable**, and **packets flow correctly**
- Everything else in-cluster is day-2 GitOps: documented recipes, never clan-rendered, never host-churned

---

## What you get: the two contracts

- **Bootstrap**: distro install/join (rke2, k3s, upstream kubeadm reserved); cluster PKI + rotation runbooks; per-node HAProxy kubeapi HA; one bootstrap bundle applied once
- **Data plane**: native multi-pool Cilium, Node IPAM, five LB delivery modes, per-node FRR/BFD/Zebra, native ClusterMesh, one WireGuard interface per node pair, private CoreDNS zones
- **Host network**: `netif` owns links/static routes; `fleet-routing` owns the flat-L3 fabric
- Airgap-ready: every artifact local at boot; last 3 Kubernetes minors per distro pinned

---

<img src="assets/arch-overview.svg" alt="Architecture overview" style="width: 100%; max-height: 82vh; background: #fff; border-radius: 8px;" />

Note: One inventory in, three cluster kinds out, connected by native routing and encrypted per-pair transport. GitOps owns day two.

---

## One bundle, then GitOps takes over

- The entire day-1 in-cluster surface is ONE kubenix-rendered manifest set per cluster
- Applied once via server-side apply on the `clusterInit` node — nothing host-resident, no distro manifests dir
- Day 2, the GitOps repo adopts the identical published manifest set — first reconcile is a no-op by construction
- **Clan never installs a GitOps controller** — Flux or Argo is the operator's choice

---

<img src="assets/stack-layers.svg" alt="Stack layers" style="width: 100%; max-height: 82vh; background: #fff; border-radius: 8px;" />

Note: Bottom layers are the two clan contracts — host links/transport, distro, Cilium networking. The top layers are day-2 recipes owned by operator GitOps repos.

---

<img src="assets/hub-spoke.svg" alt="Hub and spoke" style="width: 72%; max-height: 62vh; background: #fff; border-radius: 8px;" />

- `controlDomain.role = standalone | hub | spoke` — a GitOps-neutral substrate
- Clan renders mirror Services, `gitops-hub` identities, and per-spoke kubeconfig Secrets
- Any GitOps tool consumes them; spokes run no controller
- Admin machines reach authorized pod/Service routes through FRR and per-pair WireGuard

---

## Why per-pair WireGuard + FRR?

- WireGuard `AllowedIPs` is cryptokey routing: duplicate peers on one interface cannot provide ECMP
- One peer per interface makes each path explicit; Linux ECMP works across interfaces
- FRR exchanges filtered routes; BFD detects path failure; Zebra installs the kernel FIB
- Cilium native routing forwards remote pods through that FIB — no VXLAN, multi-pool retained
- `node-bgp` has one owner; `shared-bgp` advertises from every healthy node

---

## Detail map: every component by layer

- **Hosts**: NixOS; `netif`; per-pair WireGuard; per-node FRR/BFD/Zebra; fleet-routing member/client/admin/router
- **Distro**: k3s / rke2 (CIS default) / kubernetes (reserved); thin clanServices; `distroDefaults` restores stock components; servicelb off
- **Networking**: native multi-pool Cilium, Node IPAM, five pool delivery modes, BGP v2, native ClusterMesh; no Gateway/Ingress/L7
- **Day two**: GitOps-owned proxies, cert-manager, external-dns, Sealed Secrets, storage, KubeVirt, CCMs
- **Secrets**: clan vars = bootstrap plane only; application credentials GitOps-owned
- **Packaging**: pinned distro runtimes, Cilium chart + committed base manifest, airgap default

---

## Status and roadmap

- **Done**: phases 0–4 bootstrap/base; round-14 contract and docs
- **Legacy**: BIRD/VXLAN checkpoint `2995ac3`, 5 green / 7 red — superseded, not acceptance evidence
- **Next**: 5R1 netif + per-pair FRR transport; 5R2 native Cilium and both distros; 5R3 ClusterMesh/fleet/failure acceptance
- **Then**: control domain, PKI/GitOps-handoff suites, home migration and borg archival
- **Reserved**: upstream `kubernetes` distro, MCS-API, clan-operator

Note: Full record: SPEC.md + documentation/ in the repo.
