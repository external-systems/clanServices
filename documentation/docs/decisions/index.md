# Decision record (D1–D35)

Every normative choice in the project, locked 2026-10-20 after design
rounds 1–8. Round-8 amendments: A1 (artifact flake carries last 3 k8s
minors → D34), A2 (external-dns credentials are not clan-vars-owned → D31),
A3 (clan vars avoid owning in-cluster secrets → D35), A4 (round 8 locked
the spec; no code changes in the same commit).

| ID | Decision | Rationale |
| --- | --- | --- |
| D1 | Cilium is networking-only; its Gateway/Ingress controllers stay off | No Gateway HTTP/3, no mTLS, no DaemonSet mode, no multi-Gateway IP sharing upstream |
| D2 | Envoy Gateway is the default and only ingress/Gateway | Only implementation that satisfies the full TLS-mode set (D15); one upstream profile both distros, airgap-locked |
| D3 | Traefik is removed entirely | Distro-bundled charts always disabled; multi-instance stories move to EG Gateways (D17) |
| D4 | Ingress API deprecated entirely | Gateway API core lacks mTLS/HTTP3; EG policy CRDs are the sanctioned extension until GEP-91 lands |
| D5 | HAProxy edge-proxy scrapped | Edge = EG DaemonSet on labeled workers; HTTP response caching dropped with it |
| D6 | Three-layer Gateway ownership (zero-churn contract) | L1 clan always / L2 clan 0–N / L3 GitOps always — tenants never need a NixOS rebuild |
| D7 | Default Gateway pair: public (NS) + private (EW), identical `web` profile | One cert SAN list, HTTP/3 + terminate + hostname-mandatory passthrough on both |
| D8 | LB pool model: 2 scopes × 4 delivery modes | Pool = inventory + selector; scope (per-machine/cluster-global) and delivery (node-fate-bound/floating/shared-bgp/external-class) are orthogonal |
| D9 | BGP topology + foreign-router contract | Cilium dials out to per-node BIRD; BIRD exports only approved VIPs; upstream ECMPs across healthy nodes |
| D10 | Private fleet routing fabric default-on | One private shared-bgp pool + BIRD per cluster; public BGP is opt-in with hard preconditions |
| D11 | Fleet-routing clanService for non-Kubernetes hosts | Clan hosts reach cluster VIPs; `/etc/hosts` is the zero-BGP fallback (roles revised in D33) |
| D12 | ClusterMesh apiserver exposure stays node-bound | Consumers are mesh members with direct routes; control plane takes fewest dependencies |
| D13 | Pod/ClusterIP advertisement to hosts: opt-in, default off | Ephemeral IPs and trust extension are real costs; the `admin` role (D33) is the exception |
| D14 | Raw L4 (games) = plain LoadBalancer Services, never Gateways | No SNI in Minecraft ⇒ one IP:25565 = one backend or one proxy; ETP Local preserves player IPs |
| D15 | One IP:443 serves all TLS modes; QUIC terminate and passthrough never share an address | Raw UDP has no demux key; QUIC-passthrough Gateways get their own VIP; eval-asserted |
| D16 | One cluster per node | A machine belongs to at most one cluster instance — inventory-wide eval assertion |
| D17 | Gateway classes vs instances are 0–N | Class = isolation domain; instance = one rendered Gateway with address projection and listener profile |
| D18 | Dedicated fleet CA + browser trust | Private Gateway certs from cert-manager; client/admin roles install trust (Firefox via enterprise policy) |
| D19 | BIRD rendered via vendored named-fragment pattern | bird.nix reviewed, not adopted; one BIRD per host, instance-prefixed blocks, `bird -p` validates |
| D20 | Fleet-wide east-west mTLS is preferred, gated on VM proof | Accept/reject must be proven before default-on; browser client-cert UX stays terminate-only |
| D21 | Internal cluster domain pinned to `cluster.local` | The ecosystem hardcodes it; high blast radius, zero benefit; aliasing via CoreDNS rewrites (D22) |
| D22 | Private-domain routing contract | Clients resolve only `<instance>.<domain>` (wildcard → private Gateway); svc/pod zones are opt-in |
| D23 | Upstream `kubernetes` (kubeadm) distro = first-class target, Reserved | Third public clanService; same interfaces and pipeline; implementation waits for rke2/k3s to stabilize |
| D24 | CNCF in-cluster posture | Every in-cluster component is a CNCF project; rke2 is the documented distro exception |
| D25 | RKE2 hardened by default (`profile: cis`) | PSA restricted cluster-wide with rendered host prerequisites; explicit opt-out |
| D26 | Kubenix is the manifest renderer; no IFD | Helm inflation happens at artifact-flake build time; preserves eval speed and airgap |
| D27 | Rancher helm-controller disabled by default | Manifests flow kubenix → manifests dir → optional Flux adoption |
| D28 | Flux everywhere; hub delivers, never installs | Per-cluster autopilot (flux-operator#624 declined remote install); `flux.enable=false` is supported |
| D29 | Cilium lifecycle: bootstrap → Flux adoption | Eval-asserted values parity makes adoption a no-op upgrade, never a dataplane flap |
| D30 | Hub → spoke API via ClusterMesh mirror Services | Selectorless global Service + EndpointSlice + CoreDNS rewrite; `kubernetes.default` never touched |
| D31 | external-dns = optional Flux component, creds via Sealed Secrets | Authoritative providers only; never for inter-cluster DNS; annotation knobs on clan objects |
| D32 | OLM v1 rejected | Catalog coverage gaps, OpenShift-only airgap docs, cert-manager collision risk; duplicates Flux+kubenix |
| D33 | Fleet-routing roles: client / admin / router; node duality legal | admin = client + pod/Service zones and routes; kamrui-h1 (single-node k3s + admin) is the canonical shape |
| D34 | Version policy: last 3 minors, latest patch, support-window gate | kubelets may lag the apiserver 3 minors; eval warns when the pinned k8s minor is ahead of support matrices |
| D35 | Secrets planes: clan vars = bootstrap plane only | If k8s/Flux can rotate or serve it, clan vars does not store it; app secrets via Sealed Secrets |

## Round-8 decisions in detail

### D23 — Upstream `kubernetes` distro

The third public clanService uses kubeadm — the CNCF-sponsored bootstrapper,
wrapped declaratively by the NixOS module. It shares the library interfaces,
invariants, and rendering/GitOps pipeline with rke2 and k3s. It is fully
spec'd but implementation is Reserved until the rke2/k3s core stabilizes.
This is a hard requirement for the project, not optional scope.

### D24 — CNCF in-cluster posture

Every in-cluster component is a CNCF project: Cilium, Envoy Gateway,
cert-manager, Flux, CoreDNS, external-dns, Kubernetes/k3s. Host-level
components (BIRD, WireGuard) are exempt. rke2 is a documented distro-layer
exception (SUSE/Rancher-owned), so a fully-CNCF cluster is expressible as
`kubernetes` or `k3s` plus all defaults.

### D25 — RKE2 CIS defaults

`profile: cis` (v1.29+) is the default: PSA `restricted` cluster-wide
(except `kube-system`), protect-kernel-defaults, etcd user/group, and CIS
sysctls, with host prerequisites rendered by the NixOS module.
`security.cis = false` opts out explicitly. Curated exemptions for system
components come with the upstream profile; tenants get a namespace-exemption
runbook. k3s/kubernetes get equivalent PSA defaults where supported.

### D26 — Kubenix rendering, no IFD

All clan-rendered manifests are kubenix typed resources. Helm chart
inflation happens only at build time inside the artifact flake; clanServices
evaluation composes typed resources and imports pre-rendered YAML, with
eval-asserted rejection of IFD-smuggling manifest paths. This keeps
`nix flake check --no-build` fast and airgap operation intact.

### D27 — Rancher helm-controller off

`disable-helm-controller` is the default on both distros; explicit opt-in
re-enables it. The distro bundled charts (Traefik, servicelb, and friends)
remain disabled per D3. Manifests flow kubenix → distro manifests dir →
optional Flux adoption.

### D28 — Flux everywhere

Every cluster bootstraps its own flux-operator and FluxInstance from pinned
artifacts and manages itself thereafter. The hub cluster only holds spoke
kubeconfigs and delivers workloads via `kubeConfig.secretRef`; it never
installs Flux remotely (upstream declined that model). `flux.enable =
false` renders no Flux at all — the clan applies manifests directly and
Cilium stays clan-owned.

### D29 — Cilium bootstrap → Flux adoption

Bootstrap installs just enough Cilium for Flux pods; a HelmRelease with
matching releaseName/namespace (no `createNamespace`) adopts the release
and owns upgrades. An eval-time assertion proves bootstrap values ≡
HelmRelease values, so adoption is a no-op upgrade and never a dataplane
flap. With `flux.enable = false` the bootstrap install is permanent.

### D30 — Mirror Services for hub → spoke reachability

Per spoke, a clan-rendered selectorless Service `kube-api-<spoke>` plus an
EndpointSlice of the spoke's API endpoints is annotated ClusterMesh-global;
the hub renders the same-named Service with no local backends and ClusterMesh
merges the remote endpoints. Hub CoreDNS rewrites
`kubernetes.<spoke>.<meta.domain>` to the mirror Service, and NetworkPolicy
restricts access to Flux namespaces. Credentials are Sealed-Secrets-owned
kubeconfigs; the long-term mint/rotate path is a clan-operator (Reserved).

### D31 — external-dns as an optional Flux component

external-dns is not clan base; it deploys per cluster through GitOps.
Provider credentials are Sealed-Secrets-owned, never clan vars. Clan
objects get annotation knobs (`dns.hostnames` emits the hostname
annotation, overridable per object). Scope is authoritative providers only
— inter-cluster DNS is covered by ClusterMesh and the D22 zones.

### D32 — OLM v1 rejected

OLM v1 is neither base nor an optional install method. Evidence
(2026-10): the community catalog lacks current Cilium, Envoy Gateway, and
external-dns; cert-manager and OpenEBS entries are stale; airgap workflows
are documented only for OpenShift/OKD; and upstream install depends on
cert-manager, colliding with the base install. Revisit criteria are
recorded: catalog currency, non-OpenShift airgap docs, or a needed operator
that is catalog-only.

### D33 — Fleet-routing roles and node duality

`client` is the D11 behavior (mesh join, BIRD peering, VIP routes,
gateway-zone DNS stub, fleet CA trust). `admin` adds pod/Service
advertisement consumption and svc/pod DNS zones default-on — the developer
profile. `router` owns upstream prefixes with filtered VIP acceptance and
NDP. A machine may be a cluster node and hold fleet-routing roles
simultaneously; on a cluster member the BIRD fragments merge into the
existing host BIRD. The canonical test shape is kamrui-h1: single-node k3s
plus the admin role.

### D34 — Version policy

The artifact flake packages the last three Kubernetes minors per distro at
their latest patch each (today: 1.35.x, 1.36.x, 1.37.x). Servers/managers
upgrade first; agents/workers lag per the upstream version-skew policy
(kubelets may trail the apiserver by up to three minors). Pins are release
tags only — no locked-HEAD constructors. Evaluation emits a warning (not a
failure) when a pinned k8s minor is ahead of the Cilium/Envoy Gateway
support matrices — today 1.37.1 is ahead of EG 1.9's 1.33–1.36 matrix, an
accepted bleeding-edge risk.

### D35 — Secrets planes

Clan vars own the bootstrap plane only: cluster CAs, join tokens, admin
kubeconfigs, fleet CA, ClusterMesh CA/certs, and Sealed-Secrets sealing
keys (including keypair history custody). All in-cluster application
credentials — external-dns provider keys, hub↔spoke kubeconfigs, tenant
secrets — are GitOps-owned via Sealed Secrets. Rule of thumb: if Kubernetes
or Flux can rotate or serve it, clan vars does not store it. A lint rejects
clan vars generators declared for application-plane secrets.
