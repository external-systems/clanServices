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
- **Data plane**: native multi-pool Cilium, Node IPAM, five LB delivery modes, per-node FRR/BFD/Zebra, native ClusterMesh with selective peers, one WireGuard interface per declared adjacency, private CoreDNS zones
- **Host network**: `netif` owns links/static routes (multi-instance); `routed-fabric` owns the flat-L3 fabric, routed-hub MVP
- Airgap-ready: every artifact local at boot; last 3 Kubernetes minors per distro pinned

---

<img src="assets/arch-overview.svg" alt="Architecture overview" style="width: 100%; max-height: 82vh; background: #fff; border-radius: 8px;" />

Note: One inventory in, three cluster kinds out, connected by native routing and encrypted per-adjacency fabric transport. GitOps owns day two.

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
- Admin machines reach authorized pod/Service routes through FRR and per-adjacency WireGuard

---

## Why per-adjacency WireGuard + FRR?

- WireGuard `AllowedIPs` is cryptokey routing and the inbound source ACL: duplicate peers on one interface cannot provide ECMP — and a hub's AllowedIPs must include the transit prefixes it readvertises
- One peer per interface, one interface per declared adjacency (member↔hub, hub↔hub, border↔upstream); Linux ECMP works across interfaces — two hubs = active-active via BFD/ECMP
- eBGP + BFD + Zebra, `next-hop-self` on hub readvertisement; no iBGP, no route reflectors; members never provide spoke transit
- Cilium native routing forwards remote pods through that FIB — no VXLAN, multi-pool retained
- `node-bgp` has one owner; `shared-bgp` advertises from every healthy node

---

## Detail map: every component by layer

- **Hosts**: NixOS; `netif` (multi-instance); per-adjacency WireGuard; per-node FRR/BFD/Zebra; routed-fabric member/hub roles + orthogonal access/border switches (D56); `clan.networkFacts` network-facts seam (D57, planned)
- **Distro**: k3s / rke2 (CIS default) / kubernetes (reserved); thin clanServices; `distroDefaults` restores stock components; servicelb off
- **Networking**: native multi-pool Cilium, Node IPAM, five pool delivery modes, BGP v2, native ClusterMesh; no Gateway/Ingress/L7
- **Day two**: GitOps-owned proxies, cert-manager, external-dns, Sealed Secrets, storage, KubeVirt, CCMs
- **Secrets**: clan vars = bootstrap plane only; application credentials GitOps-owned
- **Packaging**: pinned distro runtimes, Cilium chart + committed base manifest, airgap default

---

## Status and roadmap

- **Done**: phases 0–4 bootstrap/base; round-14 contract; round-15 docs (D51–D55); round-16 docs (D56–D57: two topology roles + access/border, network-facts seam)
- **Legacy**: BIRD/VXLAN checkpoint `2995ac3`, 5 green / 7 red — superseded, not acceptance evidence
- **Next**: round-15 one-session complete overhaul — 5R1 multi-instance netif + routed-fabric (routed-hub MVP); 5R2 native Cilium and both distros; 5R3 full + selective ClusterMesh and failure acceptance; plus the pkgs native Cilium base re-inflation and clanServices pin update — all planned, no implementation or VM evidence yet
- **Then**: control domain, PKI/GitOps-handoff suites, home migration and borg archival
- **Reserved**: upstream `kubernetes` distro, MCS-API, clan-operator

Note: Full record: SPEC.md + documentation/ in the repo.
