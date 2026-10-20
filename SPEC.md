# Kubernetes cluster clanServices — Full Specification (agent edition)

Single dense contract for agents; `documentation/` (MkDocs) is the human
record. **Same spec, two renderings — edit both together.** This file is
both the *target contract* and the *status authority* (the old HTML spec is
retired). Baseline: `692807c` (imported); recorded green: wireguard-mesh +
rke2/k3s single/join/HA VM suites in the source fork. Revised 2026-10-20
(design rounds 1–8; round 8 locked with amendments A1–A4 below).

Round-8 amendments (user, 2026-10-20):
- **A1** Artifact flake packages the last 3 k8s minors per distro (latest
  patch each) for version-skew upgrade cadence. → D34.
- **A2** external-dns is an optional Flux component; its credentials are
  NOT clan-vars-owned; annotations where needed, overridable. → D31.
- **A3** Clan vars avoid owning in-cluster secrets better managed by
  Sealed Secrets. → D35.
- **A4** Round 8 locked the spec; no code changes in the same commit.

## 1. Problem (condensed)

Declare machines + cluster instances in `inventory.nix`, receive working,
secure, interconnected Kubernetes clusters (rke2, k3s, upstream kubeadm).
Hard interacting requirements: multi-cluster identity/CIDR coherence;
mandatory dual-stack regardless of underlay; bare-metal LoadBalancing =
allocation + delivery + datapath (three different things); ingress is not
only HTTP (TCP/UDP/TLS-passthrough/mTLS/QUIC); source preservation (ETP
Local) changes routing behavior; address families asymmetric in the real
world; artifacts and services have different release cycles;
batteries-included without host-coupled day two (GitOps); Gateway/LB
ownership must not force NixOS churn; misconfiguration must fail at eval
where possible, VM-proven where not.

## 2. Architecture in one paragraph

Thin public `rke2` + `k3s` clanServices (upstream `kubernetes`/kubeadm
spec'd, Reserved) over a private shared library (`lib/rancher-cluster/`
today; target rename `lib/kube-cluster/`): shared interfaces, kubenix
renderers, vars generators, assertions. Integrated dual-stack transport
(host WireGuard default; native Cilium WireGuard; explicit unencrypted
underlay). Cilium = CNI + KPR + VXLAN tunnel + multi-pool IPAM + LB IPAM +
BGP v2 + ClusterMesh — networking only. Envoy Gateway = the only
ingress/Gateway implementation (0–N). cert-manager always on. Per-node
BIRD + default private BGP fleet fabric; a fleet-routing clanService
extends VIP/pod/Service reachability to non-Kubernetes NixOS hosts.
Artifact flake (`external-systems/pkgs`) pins every chart/image/CRD and
source-builds the last 3 minors of each distro; airgap-ready is the tested
default. Manifests are kubenix-rendered (no IFD here; Helm inflation is
the artifact flake's build-time job). Day two = Flux (default on):
flux-operator + FluxInstance bootstrapped on every cluster, Cilium adopted
by Flux after bootstrap, hub cluster delivers workloads to spokes through
ClusterMesh-reachable API endpoints.

## 3. Decision record (D1–D35; rounds 1–8, locked 2026-10-20)

### Rounds 1–7 (unchanged)

- **D1 Cilium is networking-only.** `gatewayAPI.enabled=false`,
  `ingressController.enabled=false` permanently. Reasons: no Gateway
  HTTP/3 (cilium#28497), no Gateway mTLS (GEP-91), no DaemonSet mode, no
  multi-Gateway IP sharing (cilium#25567).
- **D2 Envoy Gateway = default ingress/Gateway.** EG controller + CRDs +
  Gateway API CRDs (standard + experimental) are always-rendered base
  (like cert-manager); atomic `gateway-envoy` artifact component (EG
  chart + envoy image + CRDs), one upstream profile both distros,
  airgap-locked. Data plane via `EnvoyProxy`: DaemonSet on labeled
  workers, `envoyService.externalTrafficPolicy: Local` (EG default),
  pool labels + `lbipam.cilium.io/ips` projections via
  `envoyService.labels/annotations` — never annotate the
  controller-managed Service directly. `mergeGateways` only on a separate
  opt-in class (blast radius: one bad tenant listener NACKs the merged
  fleet). Known bug: http3+proxyProtocol on one ClientTrafficPolicy →
  invalid QUIC listener (envoyproxy/gateway#9798).
- **D3 Traefik is REMOVED** (revised round 7; was "first-class 0–N").
  Distro-bundled Traefik charts always disabled on both distros;
  `traefik.instances` deleted; no `ingressGateway.controller` selector
  remains; multi-instance/IPv6-carve-out stories move to EG Gateways
  (D17); `*-traefik-multi` suites replaced by EG multi-Gateway suites.
  Stack becomes pure Gateway API + EG policy CRDs.
- **D4 Ingress API deprecated entirely.** No `networking.k8s.io/v1
  Ingress`, no Cilium Ingress, no Traefik IngressRoute in base or
  recommended tenant path. Gateway API core lacks mTLS/HTTP3 → controller
  **policy** CRDs (ClientTrafficPolicy etc.) are the sanctioned extension
  until GEP-91/HTTP3 GEP land.
- **D5 HAProxy edge-proxy scrapped.** Edge = EG DaemonSet on labeled
  workers. Dropped requirement recorded: HTTP response caching.
  Cloudflare mTLS = ClientTrafficPolicy `tls.clientValidation` +
  Cloudflare client CA; Cloudflare Origin CA issuer is
  Flux/Sealed-Secrets-owned.
- **D6 Three-layer Gateway ownership (zero-churn contract).** L1 clan
  always: EG controller, CRDs, pools. L2 clan 0–N: `gateway.classes` +
  `gateway.instances` (empty = fully GitOps-owned Gateway layer —
  first-class shape). L3 GitOps always: Routes, certs, tenant Gateways,
  raw L4 Services. Tenants draw from labeled pools (one IP per family) or
  write explicit `lbipam.cilium.io/ips` — no NixOS rebuild. EG controller
  itself never Flux-managed (artifact pinning is the point); Gateway
  configuration may be.
- **D7 Default Gateway pair (0–1 each) — NS + EW.** Default-on when L2
  non-empty: a **public** Gateway (north-south, primary IPv4 :443
  maximizer) and a **private** Gateway (east-west, private fleet-fabric
  VIP, fleet-CA wildcard cert — D18). Listener profile `web`: `:80`
  redirect; catch-all `HTTPS:443` terminate (default cert); `TLS:443`
  passthrough (hostname MANDATORY); HTTP/3 UDP/443 + TCP/443 + firewall
  both. `domains = [...]` → ONE cert-manager Certificate SAN list;
  cert-manager Gateway annotation (`cert-manager.io/issuer`); no
  ListenerSets (experimental). Optional named extra listeners (e.g.
  `cloudflare`). Tenants own Routes; platform owns listeners. Fluid
  domains → Flux-owned Gateway with own address. The `web` profile is
  IDENTICAL on both default Gateways (HTTP/3, terminate-default,
  hostname-mandatory passthrough, per-listener mTLS); only class, address
  source, and issuing CA differ.
- **D8 Pool model: 2 scopes × 4 delivery modes.** Pool = address
  inventory + `serviceSelector` only. Scope: *per-machine* → node-named
  pools (auto join-address /32+/128 + declared primary/extra blocks;
  always node-fate-bound); *cluster-global* → generic-named pools
  (`helsinki-ipv4-1`, `fsn-ipv6`; never node-fate-bound). Delivery:
  `node-fate-bound` (no failover, no BGP) | `floating` (runtime
  controller moves IP, one node at a time; no route withdrawal;
  blackhole window; requires full local proxy coverage on candidate set)
  | `shared-bgp` (all healthy nodes advertise /32+/128; router ECMPs;
  ETP-Local withdrawal) | `external-class` (cloud CCM).
  `public=true`/`private=true`/`games=true` = selector labels on pools of
  any scope/mode, not a category. Dynamic draw = one IP per family;
  multi-IP explicit annotation = deliberate projection. Assertions:
  blocks non-overlapping; scope⇒mode validity; BGP only for `shared-bgp`;
  floating ⇒ candidate-set coverage; `shared-bgp` blocks ⊆ router-role
  prefixes when router in same inventory.
- **D9 BGP topology + foreign-router contract.** Cilium GoBGP originates
  VIP routes, dials OUT over loopback to per-node BIRD (no :179
  listener); BIRD imports only approved exact VIPs, exports only those
  upstream (never default/mesh/primary/transit), no broad kernel install
  on cluster nodes; upstream router (NixOS BIRD host | MikroTik | switch)
  hears the same route from every healthy node → ECMP. Cilium agents
  never peer with each other. Deterministic 2 private 32-bit ASNs per
  cluster (BIRD-side, Cilium-side) + per-node router id; uniform ASN ⇒
  no multipath-relax. Timers not BFD (none in 1.20): hold 9 / keepalive
  3 / connect-retry 5. Foreign-router contract (published): ASNs, timers,
  accept only pool blocks as /32+/128 with max-prefix + prefix filters,
  ECMP path count ≥ node count, proxy-NDP if on-LAN. BIRD config rendered
  via a vendored named-fragment module pattern (D19).
- **D10 Private fleet routing fabric DEFAULT ON.** Per cluster by
  default: per-node BIRD + BGP v2 resources, one private `shared-bgp`
  pool (ULA + RFC1918 from derived cluster CIDR space), core VIPs on it
  (private Gateway, CoreDNS). Public `shared-bgp` opt-in; preconditions:
  upstream-routed space (DHCPv6-PD carve-out / static / PI) + controlled
  router. Non-goals: single dynamic residential IPv4 public BGP;
  heterogeneous multi-WAN inbound failover (DNS failover instead).
  Hetzner public edge = node-bound + floating + Cloudflare-healthcheck
  DNS failover. One VIP per cluster — never advertise the same VIP from
  two clusters (cross-cluster = ClusterMesh global services or DNS).
- **D11 Fleet-routing clanService (working name `cluster-client`).**
  Non-Kubernetes clan hosts → cluster VIPs. Roles revised round 8 → D33
  (client/admin/router). /etc/hosts = zero-BGP fallback.
- **D12 ClusterMesh apiserver exposure stays node-bound** mesh addresses
  + selectorless-Service DNS fan-in. Not a shared-BGP VIP: consumers are
  mesh members with direct routes; control plane takes fewest
  dependencies. Round 8: the same fan-in pattern is generalized for the
  kube-apiserver mirror Services (D30).
- **D13 Pod/ClusterIP advertisement to hosts: opt-in, default off.**
  Hosts reach Services via VIPs, never pods or ClusterIPs directly —
  except via the fleet-routing `admin` role (D33), which turns these
  opt-ins on per machine. Caveats: ephemeral IPs, `world` policy
  identity, trust extension, no readiness.
- **D14 Raw L4 (Minecraft/Simple Voice Chat/games).** Plain
  `type: LoadBalancer` Services, NEVER Gateways (no SNI in Minecraft ⇒
  one IP:25565 = one backend or one Velocity proxy). Mixed TCP+UDP on one
  Service/IP (25565/TCP + 24454/UDP). ETP Local preserves player IPs.
  Address: labeled pool draw, floating pool, or explicit projection.
- **D15 One IP:443, all TLS modes.** One IP:443 simultaneously: SNI
  multi-cert HTTPS terminate + hostname-filtered TLS passthrough +
  per-listener mTLS + HTTP/3 (UDP/443 beside TCP/443). Only EG satisfies
  the full set (see D1) ⇒ EG owns the default web path. **TCP/443
  terminate + passthrough share an address via SNI; QUIC terminate and
  QUIC passthrough NEVER share an address** — raw UDP/QUIC has no demux
  key (Envoy does not parse SNI from QUIC Initials), so a UDPRoute
  listener and an H3-terminating listener on one IP:UDP:443 would be two
  owners of one IP:port. QUIC-passthrough Gateways get their own VIP; the
  `web` profile's UDP/443 is always termination. Eval-asserted.
- **D16 One cluster per node.** A machine belongs to at most one cluster
  instance (rke2, k3s, or kubernetes) — inventory-wide eval assertion.
  Fleet-routing roles may coexist with cluster membership (D33).
- **D17 Gateway classes vs instances (0–N structure).**
  `gateway.classes.<name>` (0–N): one GatewayClass + one EnvoyProxy per
  class — the isolation domain: daemonset/deployment, node-label
  placement, pool selector labels, base annotations, mergeGateways
  opt-in. `gateway.instances.<name>` (0–N): one clan-rendered Gateway
  bound to a class — address projection (explicit per-node addresses;
  deterministic IPv6 carve-outs live HERE now: stable hash of
  cluster+node+instance, explicit offset override, collision = eval
  error), listener profile (`web` | custom), domains→SAN cert,
  namespace, allowedRoutes, external-dns annotations (D31). Defaults:
  classes `public` (DaemonSet on edge workers, `public=true` pools) +
  `private` (private fabric VIP, `private=true` pools); instances
  `public` + `private` (D7). Tenant isolation ladder: listener < Gateway
  < class. Tenants create Gateways against clan classes via GitOps (zero
  churn); creating classes is platform work.
- **D18 Fleet CA + browser trust.** Dedicated fleet root CA (shared vars
  generator `fleet-ca-<group>`, `share=true`; private key only leaves
  vars as the cluster's cert-manager CA-issuer Secret via secret-sync).
  Private Gateway certs issued by cert-manager from it. fleet-routing
  `client`/`admin` roles install the CA into
  `security.pki.certificateFiles` (covers Chromium/curl/most tooling).
  Firefox-family (incl. zen-browser): Linux does NOT support
  `security.enterprise_roots.enabled`; use enterprise policy
  `Certificates.Import` (zen/firefox Nix wrappers expose `policies`) —
  rendered by the client/admin role when such a browser module is
  detected; per-profile NSS (certutil) is the documented fallback.
- **D19 BIRD rendering: vendored named-fragment pattern.** Reviewed
  NuschtOS/bird.nix (alpha, MIT): its `templates`/`protocols`
  `attrsOf lines` composition model is the right idea (multiple
  clanServices contribute named blocks to ONE bird daemon), but it lacks
  top-level `filter`/`function` blocks and typed fields — do not take as
  an input. Vendor the pattern into the shared lib with added
  `filters`/`functions` maps; keys namespace-prefixed per instance
  (`bgp.<instance>_cilium`, `bgp.<instance>_upstream`); same-key = text
  concat (avoid); `routerId` set exactly once; nixpkgs `bird -p`
  pre-start check remains the validator. One BIRD per host; fleet-routing
  roles on a cluster member merge into its existing BIRD; eval asserts no
  second BGP stack / ASN conflict.
- **D20 Fleet-wide east-west mTLS is the PREFERRED path, gated on
  proof.** Private-Gateway ClientTrafficPolicy `clientValidation` against
  the fleet CA + per-machine client-cert vars generators gives mutual TLS
  on the east-west path. Default-on only after a VM suite proves
  accept/reject and client-cert presentation from clan machines. Honest
  caveat: browser client-cert UX is poor — mTLS is enforced per
  listener/hostname for machine/admin endpoints while ordinary browser
  endpoints stay terminate-only.
- **D21 The internal cluster domain is pinned to `cluster.local`.** Never
  changed, eval-asserted. ClusterMesh does not depend on it (mesh
  discovery uses its own identities/zone), but the ecosystem (charts,
  CSI, cert-manager webhook FQDNs, app configs) hardcodes
  `cluster.local` — high blast radius, zero benefit. All aliasing needs
  are served by CoreDNS rewrites (D22) instead.
- **D22 Private-domain routing contract.** Default: client machines
  resolve ONLY the zone `<instance>.<meta.domain>` — a clan-rendered
  CoreDNS zone (served on the cluster's private CoreDNS VIP) with a
  wildcard → private Gateway VIP; east-west traffic enters through the
  Gateway, mirroring how internet traffic enters. Per-client-machine
  opt-ins (default-on for the `admin` role, D33): (a) service zone
  `<instance>.svc.<meta.domain>` — CoreDNS rewrites to
  `<name>.<ns>.svc.cluster.local` with answer-name reversal, resolving to
  Service IPs (works out of the box for private-pool LB VIPs, which the
  fabric already routes; ClusterIPs additionally require the D13 service
  advertisement opt-in); (b) pod zone (CoreDNS `pods insecure` +
  dash-form rewrites + D13 pod advertisement). `cluster.local` is NEVER
  served to clients (D21).

### Round 8 (2026-10-20; locked)

- **D23 Upstream `kubernetes` distro = first-class target, Reserved.**
  Third public clanService, kubeadm-based (kubeadm is the CNCF-sponsored
  bootstrapper; the NixOS module wraps `kubeadm init/join`
  declaratively). Same shared-lib interfaces, same invariants, same
  rendering/GitOps pipeline as rke2/k3s. Spec'd fully; implementation is
  a Reserved phase after the rke2/k3s core stabilizes. Hard requirement
  for the project, not optional scope.
- **D24 CNCF in-cluster posture.** Invariant: every in-cluster component
  is a CNCF project (Cilium, Envoy Gateway, cert-manager, Flux, CoreDNS,
  external-dns, Kubernetes/k3s qualify). Host-level components (BIRD,
  WireGuard) are exempt. rke2 is a documented distro-layer exception
  (SUSE/Rancher-owned); `k3s` and `kubernetes` are the CNCF distro paths.
  A fully-CNCF cluster must be expressible: `kubernetes` or `k3s` distro
  + all defaults.
- **D25 RKE2 hardened by default (CIS).** The `rke2` service defaults to
  `profile: cis` (v1.29+ value): PSA `restricted` cluster-wide (except
  `kube-system`), `protect-kernel-defaults`, etcd user/group, CIS
  sysctls — host prerequisites rendered by the NixOS module. Explicit
  `security.cis = false` opt-out. Fallout recorded: curated PSA/
  NetworkPolicy exemptions for system components (EG, cert-manager) are
  part of the upstream profile; tenants get a namespace-exemption
  runbook. k3s/kubernetes get equivalent PSA defaults where the distro
  supports them (no CIS profile off-RKE2).
- **D26 Kubenix is the manifest renderer.** All clan-rendered manifests
  are built with kubenix typed resources (`kubernetes.resources` + CRD
  `customTypes`). HARD CONSTRAINT: no import-from-derivation during
  clanServices evaluation — Helm chart inflation happens at build time in
  the artifact flake (pkgs renders pinned charts into manifest artifacts);
  clanServices composes typed resources + imports pre-rendered YAML.
  Preserves `nix flake check --no-build` and airgap.
- **D27 Rancher helm-controller disabled by default** on both distros
  (`disable-helm-controller`); manifests flow kubenix → distro manifests
  dir → optional Flux adoption. Explicit opt-in re-enables it. Distro
  bundled charts (Traefik, servicelb, etc.) remain disabled per D3.
- **D28 Flux everywhere; hub delivers, never installs.** Every cluster
  bootstraps its own flux-operator + FluxInstance from pinned artifacts
  (clan-rendered; self-managing thereafter). Evidence:
  flux-operator#624 closed not_planned — FluxInstance has no remote
  field; the fleet model is per-cluster autopilot. The **hub** cluster is
  distinguished only by holding spoke kubeconfigs and delivering
  workloads via `Kustomization/HelmRelease.spec.kubeConfig.secretRef`
  (ResourceSet matrix templating optional). `flux.enable` default `true`;
  `false` = no Flux rendered anywhere, clan applies all manifests
  directly via the distro manifests dir, Cilium stays clan-owned.
- **D29 Cilium lifecycle: bootstrap → Flux adoption.** Bootstrap installs
  Cilium from the pinned chart/values (enough for Flux pods); a Flux
  HelmRelease then adopts the release (matching releaseName/namespace —
  no `createNamespace`) and owns upgrades. Eval-time assertion:
  bootstrap-rendered values ≡ HelmRelease values, so adoption is a no-op
  upgrade, never a dataplane flap. When `flux.enable = false` the
  bootstrap install is permanent.
- **D30 Hub → spoke API reachability via ClusterMesh mirror Services.**
  Never touch the real `kubernetes.default` Service. Per spoke cluster:
  clan-rendered selectorless mirror Service `kube-api-<spoke>` +
  EndpointSlice of the spoke's API endpoints (D12 fan-in pattern,
  generalized), annotated `service.cilium.io/global: "true"`. Hub
  renders the same-name Service (no local backends), ClusterMesh merges
  remote endpoints, hub pods reach the spoke API via that ClusterIP. Hub
  CoreDNS rewrite (rendered from exports):
  `kubernetes.<spoke>.<meta.domain>` →
  `kube-api-<spoke>.<ns>.svc.cluster.local`. NetworkPolicy restricts
  access to flux namespaces. Credentials: GitOps-owned kubeconfig Secrets
  via Sealed Secrets (D35); interim = documented token-minting runbook;
  long-term = clan-operator mints/rotates (Reserved).
- **D31 external-dns = optional Flux component, creds via Sealed
  Secrets.** Not clan base; deployed per cluster through the GitOps
  layer. Provider credentials (GoDaddy/Cloudflare API keys, RFC2136
  keys) are NEVER clan vars generators (A2/D35) — they are
  Sealed-Secrets-owned in the GitOps repo. Clan provides annotation knobs
  on clan-rendered objects: `dns.hostnames` on `gateway.instances` and
  LB Service renderings emits
  `external-dns.alpha.kubernetes.io/hostname` (+ labels/annotations
  pass-through), always overridable per object. Scope = authoritative
  providers only; NOT used for inter-cluster DNS (its CoreDNS provider
  needs an etcd backend clusters don't run; ClusterMesh + D22 zones cover
  private naming). Multi-cluster value = same public hostname with
  per-cluster targets.
- **D32 OLM v1 rejected (revisit criteria recorded).** Not base, not an
  optional install method. Evidence (2026-10): OperatorHub community
  catalog lacks Cilium, Envoy Gateway, external-dns; cert-manager stale
  (v1.16.5); OpenEBS stale (v3.0.0); only flux-operator and KubeVirt-HCO
  current. Airgap workflow (oc-mirror, IDMS/ITMS) documented only for
  OpenShift/OKD. Upstream install depends on cert-manager (collision risk
  with our base cert-manager). It duplicates Flux+kubenix rather than
  extending them. Revisit when: (a) catalogs carry current versions of
  our stack, (b) upstream (non-OpenShift) airgap docs exist, (c) a needed
  operator is catalog-only.
- **D33 Fleet-routing roles: `client`, `admin`, `router`.** `client` =
  D11 behavior (mesh join, BIRD peering, VIP routes, gateway-zone DNS
  stub, fleet CA trust). `admin` = client + D13 pod/Service advertisement
  consumption + D22 svc/pod DNS zones default-on — the developer/admin
  machine profile (e.g. kamrui-h1). `router` = unchanged (upstream prefix
  ownership, filtered VIP acceptance, NDP). **Node duality is legal**: a
  machine may be a cluster node (one cluster, D16) AND hold fleet-routing
  roles; on a cluster member the BIRD fragments merge into the existing
  host BIRD (D19), its own cluster's pod/Service CIDRs are local routes
  anyway, and admin mode teaches it OTHER clusters' CIDRs. Fleet-wide
  PodCIDR non-overlap (ClusterMesh assertion) is what makes cross-cluster
  pod routing coherent. Canonical test shape: kamrui-h1 = single-node k3s
  + admin role.
- **D34 Version policy: last 3 minors, latest + support-window gate.**
  The artifact flake packages the last 3 k8s minors per distro, latest
  patch each (today: 1.35.x, 1.36.x, 1.37.x) — servers/managers upgrade
  first, agents/workers lag per upstream version-skew policy. Release-tag
  pins ONLY (no locked-HEAD constructors). k8s minor parity across
  distros enforced per minor (existing `k8s-version-parity` check,
  extended). Eval WARNING (not failure) when the pinned Cilium/Envoy
  Gateway support matrices don't list a pinned k8s minor (today: 1.37.1
  is ahead of EG 1.9's 1.33–1.36 matrix — accepted bleeding-edge risk).
- **D35 Secrets planes: clan vars = bootstrap plane only.** Clan vars own
  node/cluster bootstrap secrets: cluster CAs, join tokens, admin
  kubeconfigs, fleet CA (D18), ClusterMesh CA/certs, Sealed-Secrets
  sealing keys (D35 owns custody of the sealing keypair history). All
  in-cluster application credentials — external-dns provider keys,
  hub↔spoke kubeconfigs, tenant secrets — are GitOps-owned via Sealed
  Secrets (A3). Rule of thumb: if k8s/Flux can rotate or serve it, clan
  vars does not store it.

## 4. Invariants (target; eval-asserted or VM-proven)

1. One declarative fleet: instance declaration ⇒ stable identity,
   non-overlapping defaults, integrated transport, automatic ClusterMesh
   when mesh group has peers.
2. Dual-stack inside, always (nodes/pods/Services); public exposure
   varies per node/Service (v4-only, v6-only, both, neither).
3. Cilium is the only CNI base: one upstream 1.20+ profile, KPR, VXLAN,
   multi-pool; networking-only (D1).
4. L3 only: no VLAN/L2-announce/VRRP/shared-L2. Transport =
   host-wireguard (default) | cilium-wireguard | unencrypted; every mode
   dual-stack.
5. ETP Local on every clan-rendered external proxy Service; no silent
   Cluster fallback.
6. One LB-IPAM model: 2 scopes × 4 delivery modes (D8); explicit per-node
   projection for clan-managed multi-node proxies; no Node IPAM.
7. BGP ownership unambiguous: only `shared-bgp` pools advertised;
   private fabric default; public opt-in (D9/D10).
8. Envoy Gateway by default and only; 0–N classes/instances; default
   NS+EW pair (D2/D7/D17).
9. Topology always labeled: region/zone default to instance name,
   per-machine overrides, non-empty.
10. cert-manager is base (no disable); fleet CA for EW trust (D18);
    Sealed Secrets optional with vars-owned key history (bootstrap plane,
    D35).
11. Hermetic proof: pinned artifacts, eval rejection of invalid
    inventories, hermetic VM suites.
12. Three-layer ownership / zero-churn (D6); Ingress API deprecated (D4).
13. One cluster per node (D16); fleet-routing roles may coexist (D33);
    one BIRD per host (D19); one proxy implementation per IP:port (D15).
14. `cluster.local` is pinned and never served to clients (D21); private
    domains route through the private Gateway by default (D22).
15. Kubenix renders everything; no IFD in clanServices eval (D26); no
    Rancher helm-controller by default (D27).
16. Flux default-on, per-cluster bootstrap; hub delivers workloads only
    (D28); Cilium adopted by Flux with values parity (D29).
17. CNCF in-cluster posture (D24); rke2 CIS-hardened by default (D25).
18. Clan vars = bootstrap plane only; app secrets via Sealed Secrets
    (D35).
19. Artifact flake carries the last 3 k8s minors per distro (D34).

## 5. Subsystem contracts (condensed)

### 5.1 Ownership boundaries
Canonical repo = external-systems/clanServices; thin distro services own
bootstrap/TLS-dir/join semantics; shared lib owns parity; artifact flake =
only packaging input (granular atomic component sets; source-built
RKE2/k3s at release tags, last 3 minors — D34; build-time Helm inflation
for kubenix consumption — D26); consumers pin immutable revisions;
fleet-routing and tenant resources are consumers, never hidden
dependencies.

### 5.2 Identity, CIDRs, topology, exports
Cluster name = instance name (≤32 chars, DNS-style). `cilium.id`
nullable; default = stable hash of instance name → 1–127; collision =
eval error; explicit 1–255 override requires explicit v4 CIDRs above 127.
Migration: pin existing ids/CIDRs before hashed defaults land. One
resolved dual-stack CIDR structure feeds distro, Cilium, DNS, pools,
assertions, exports. region/zone labels default to instance name,
per-machine overrides. `rancher_cluster` instance export: identity, mesh
group, CIDRs, mesh endpoints, pool handoff, API mirror facts (D30),
schema version. `node_transport` per-node export: mesh/underlay
addresses, interface, MTU, primary/external facts, delivery modes,
topology. No secrets in exports. Inventory-wide assertions: duplicate
names/ids/CIDRs, overlapping CIDRs (incl. fleet-wide PodCIDR non-overlap
for meshed clusters, D33), duplicate NodePorts, missing peers, missing
labels, node-in-two-clusters (D16).

### 5.3 Transport
`transport.mode = host-wireguard | cilium-wireguard | unencrypted`.
host-wireguard: every node gets mesh v4+v6 (deterministic from id +
machine name); per-machine overrides (addresses, port, endpoint,
interface, MTU, routes, pool blocks). cilium-wireguard: no host WG
resources, Cilium transparent encryption, explicit dual-stack node facts
required. unencrypted: no confidentiality claim, explicit facts required,
missing family = eval error. Mesh groups: cross-cluster peering from
exports + public vars keys, remote prefixes only in AllowedIPs; every
remote node InternalIP reachable before ClusterMesh ready. MTU:
transport MTU −50 = tunnel budget. Distro HTTP-proxy setting = documented
escape only.

### 5.4 Cilium base
Same canonical upstream Cilium 1.20+ chart/images both distros; RKE2
bundled Cilium disabled. Always: KPR, VXLAN, multi-pool IPAM, BPF
masquerade+tproxy, Maglev, pmtu, default dual-stack pod pool. Post-merge
validation rejects helmValues violating routing/tunnel/IPAM/dual-stack/
CNI-chaining/artifact/ETP invariants. Multus optional: chaining switch is
explicit + atomic. Lifecycle: bootstrap → Flux adoption (D29); values
parity asserted at eval.

### 5.5 ClusterMesh (automatic, mixed-distro)
Mesh groups (default = all cluster instances; opt-out separates trust).
Every eligible cluster runs clustermesh-apiserver + mesh certs from first
boot; singleton peer list empty. Peering rendered from exports into
`clustermesh.config.clusters` — no CLI. Exposure: LoadBalancer (default,
node-bound mesh addresses + ETP Local + ClientIP affinity, all servers as
endpoints, anti-affinity) with collision-checked NodePort escape. DNS
fan-in: selectorless local ClusterIP Service + eval-rendered
EndpointSlice per remote cluster — the same pattern, generalized, carries
the kube-apiserver mirror Services (D30). Shared
`rancher-clustermesh-ca-<group>` vars generator (share=true); per-cluster
dependent cert generators; SANs include every exported address + fan-in
name; endpoint set is a public validation input (membership change ⇒
reissue before advertise). CA/cert material never in exports/helm/store.
Same datapath, same Cilium profile, maxConnectedClusters uniform. Global
Services opt-in per Service (mirror Services are clan-rendered globals,
D30). MCS-API reserved (disabled initially). Rotation = separate
two-phase CA-bundle design; blind regeneration unsupported.

### 5.6 Pools, LB, BGP, BIRD
Per D8/D9/D10/D19. Zero-config single-node example: node-1 with join
addresses 10.0.0.1/32 + fd0::1/128 ⇒ pool `node-1` with exactly those
blocks. Declared public primary wins over mesh fallback for the default
Gateway projection. Generic tenant draw = one IP per family. Pool updates
may reassign IPs (Cilium-side) ⇒ reviewed network changes. Floating
pools: runtime controllers (e.g. hcloud-ip-floater) move addresses; clan
asserts shape + coverage only; failover timing is the controller's
contract. BIRD-on-hosts (client/admin/router roles) installs routes into
the kernel; cluster nodes do not broadly install — except `admin` role
consumption of D13 advertisements (D33).

### 5.7 Gateways (Envoy Gateway)
Per D2/D6/D7/D14/D15/D17/D18. Port uniqueness evaluated per
node/address/family/protocol (TCP and UDP may share a number). HTTP/3 =
QUIC listener + TCP+UDP Service ports + NetworkPolicy + firewall
together. TLS passthrough ⇒ backend terminates; source seen by backend =
proxy IP (no client-IP promise). XFF/X-Envoy-External-Address documented
separately from raw-L4 source preservation. Default cert from
cert-manager; custom certs render once in consumer namespace and suppress
defaults. `gateway.instances = {}` = fully GitOps-owned, first-class.
external-dns annotation knobs on instances (D31).

### 5.8 Base and add-ons
Base (always rendered): cert-manager (pinned, bootstrap selfsigned CA,
voter placement, arbitrary issuer refs), CoreDNS rewrites (distro-
appropriate ConfigMaps), EG + Gateway API CRDs (D2), flux-operator +
FluxInstance (D28; only absent when `flux.enable = false`). Sealed
Secrets: off by default but REQUIRED before any GitOps-owned secret
(D35); `keyManagement = clan-vars` (default when enabled; persistent
keypair, offline public cert, native renewal disabled, old keys
retained) | `controller` (native + backup runbook). Never a plain
cert-manager Certificate for sealing keys. Optional add-ons (Flux-owned
unless noted): external-dns (D31), Multus, OpenEBS-LVM, OpenEBS-ZFS,
KubeVirt+CDI — per-engine artifacts, host prep, and VM suites per the old
HTML §5.8 table (unchanged). OLM: rejected (D32).

### 5.9 Secrets / PKI / airgap
Two planes (D35). Bootstrap plane (clan vars): cluster CAs, tokens, admin
kubeconfigs, Sealed-Secrets sealing keys, ClusterMesh CA/certs, fleet CA.
Application plane (GitOps + Sealed Secrets): provider credentials,
hub↔spoke kubeconfigs (D30), tenant secrets. Public certs readable as
public values; private material referenced by deployed paths only. RKE2
PKI sync non-destructive; k3s init-only seed + native replication.
Airgap-ready default; one explicit opt-out switch; overrides = complete
replacement sets or additive lists.

### 5.10 Rotation and imperative lifecycle
Leaf certs: upstream 365-day, renew at startup; manual via
`{rke2,k3s} certificate rotate` (kubeadm: `kubeadm certs renew`). CA
rotation: staged dir + `rotate-ca`; same-root can be non-disruptive; new
root disruptive (tokens, kubeconfigs, restarts). Service-account signing
key: append/retain. No blanket 100-year leaf default; long-lived offline
root = explicit risk decision. Inventory deletion ≠ cluster GC:
cordon/drain, Node deletion, etcd member removal, mesh cleanup =
documented runbooks. Disruptive changes (pools, CIDRs, ids, CA roots,
mesh membership) = reviewed operational changes.

### 5.11 CCM, managed manifests, GitOps
`cloudController = none | rancher | external`; provider CCMs never
bundled; hermetic fake-CCM VM test. Every clan-rendered manifest labeled
(managed-by, instance, component, config-hash; never in selectors).
Rendering = kubenix (D26); delivery = distro manifests dir; Rancher
helm-controller disabled by default (D27). Managed base installs APIs +
small base set; Flux owns lifecycle post-bootstrap (D28/D29); tenants use
Flux/Argo without NixOS activation; base upgrades preserve tenant CRDs.

### 5.12 Assertions and firewall
Eval rejects: multiple bootstraps, duplicate ids/CIDRs/ports, missing
dual-stack facts, missing topology labels, invalid TLS/entrypoint combos,
duplicate certs, uncovered cert refs, pool overlap, scope⇒mode
violations, floating without candidate coverage, `shared-bgp` ⊄ router
prefixes, node-in-two-clusters, second BGP stack per host, two proxy
implementations per IP:port, QUIC terminate + passthrough sharing one
address (D15), passthrough listener without hostname, mergeGateways on
non-opt-in class, ETP Cluster / Node IPAM / host-network mode on clan
proxies, Cilium bootstrap/HelmRelease values drift (D29), IFD-smuggling
manifest paths (D26), unsupported k8s minor without acknowledgment (D34
warning), clan vars generators declared for application-plane secrets
(D35 lint). Firewall: API on transport only; public ports only where a
Service exposes them; mesh/BGP restricted to expected peers; HTTP/3 opens
UDP+TCP; mirror Services reachable only from flux namespaces (D30). VM
tests assert positive connectivity AND negative exposure.

### 5.13 Fleet-routing service
Per D11/D13/D18/D19/D20/D22/D33. `client` role: mesh join, BIRD peering,
route install, fleet CA trust; DNS stub = `<instance>.<domain>` gateway
zone only. `admin` role: client + D13/D22 svc/pod zones + pod/service
route consumption. `router` role: prefix ownership, filtered VIP
acceptance, NDP. Node duality legal (D33). Acceptance: client role
reaches cluster VIPs (routes + DNS stub) on a non-cluster host; admin
role resolves svc/pod zones and routes pod/Service CIDRs of OTHER
clusters; router role accepts only owned prefixes; cross-inventory prefix
assertions; MikroTik-style foreign-router runbook; browser trust install;
east-west mTLS accept/reject proof (D20) before it defaults on;
cluster-member + admin dual-role suite (kamrui-h1 shape).

### 5.14 Flux hub-spoke (D28/D29/D30)
Every cluster: flux-operator + FluxInstance from pinned artifacts at
bootstrap. Adoption set (Flux owns post-bootstrap): Cilium (D29),
external-dns (D31), add-ons. Never Flux-owned: EG controller (D6),
distro runtime, cluster PKI. Hub cluster: spoke kubeconfigs as Sealed
Secrets in the flux namespace (D35), ResourceSet/Kustomization/HelmRelease
with `kubeConfig.secretRef` per spoke; spoke API reachable via mirror
Service + CoreDNS rewrite `kubernetes.<spoke>.<meta.domain>` (D30).
Singleton cluster = no hub config, Flux manages only itself.

## 6. Testing contract

Seams: pure renderer nix-unit tests (kubenix render determinism included);
throwaway clans via `clanLib.clan` (inventory boundary); `clan.nixosTests`
hermetic VM suites (one at a time, sandboxed authoritative); artifact
source/hash/render gates (incl. build-time Helm inflation proofs, D26).
Standard internal HTTP/HTTPS test workload: **go-httpbin**
(zero-dependency Go stdlib httpbin port; pinned + airgap-carried as a
test-fixture artifact; HTTPS fixtures use generated certs). go-httpbin
speaks HTTP/1.1 + HTTP/2 only (no QUIC in Go stdlib) ⇒ HTTP/3 termination
suites use an HTTP/3-capable client against the Gateway with go-httpbin
as plain backend — QUIC terminates at EG, which is the architecture under
test. HTTP/3 client: nixpkgs `curlHTTP3` run by the VM test driver
directly on the node (`curl --http3`); if an in-cluster client is needed,
the artifact repo builds its own image from `pkgs.curlHTTP3` via
`dockerTools` — never third-party http3 curl images (unpinned).
**QUIC passthrough suite** (required): UDPRoute (raw L4 UDP — QUIC cannot
be SNI-routed at L7; TLS lives inside QUIC) through an EG UDP listener on
its OWN VIP (D15) to a pinned **Caddy** fixture serving HTTP/3
end-to-end; one UDP/443 listener per address per backend class (no
hostname multiplexing on raw UDP). Two fixtures, no replacement: Caddy
serves QUIC only; go-httpbin remains the L7 oracle (header/status/delay/
echo assertions) — Caddy is not a test oracle. HTTP/3 advertisement:
`Alt-Svc` response header via the core `ResponseHeaderModifier` HTTPRoute
filter (backend needs no awareness), or DNS `HTTPS`/SVCB records with
`alpn="h3"` in the private-domain zones (D22). Rules: hermetic/offline;
eval-deterministic addresses; dual-stack asserted in every boot test;
round-trips + failure behavior (HTTPS validates CA, UDP echo, HTTP/3 uses
QUIC, BGP withdrawal keeps VIP via healthy nodes); negative assertions;
operational postconditions; fail fast. Suites: existing single/join/HA
(keep); transport matrix; artifact matrix (3-minor version pins eval,
D34); EG gateway matrix (replaces Cilium gateway + Traefik multi):
DaemonSet placement, ETP Local, projections, L4+L7 one Gateway, HTTP/3
QUIC, mTLS accept/reject, cert-manager Gateway integration, source
preservation, 0–N multi-Gateway isolation, zero-clan-Gateway tenant
round-trip; lb-pool suite (exact defaults, carve-outs, floating
semantics — documented blackhole window, no withdrawal claim); bgp-ecmp
suite (+ private fabric, MikroTik-style foreign-router fixture);
ClusterMesh matrix (+ kube-api mirror Service reachability, D30); PKI
rotation; CCM/GitOps handoff (Flux adoption no-op proof, D29);
flux-enable=false direct-apply suite (D28); rke2 CIS profile suite (D25:
PSA restricted enforced, exemptions work); external-dns annotation
rendering suite (D31); sealed-secrets plane separation eval (D35);
multus; openEBS; kubevirt; fleet-routing suite (incl. client/admin split,
dual-role cluster member, opt-in svc/pod rewrite zones, east-west mTLS
accept/reject, D20/D22/D33). Reserved: MCS-API, upstream-kubernetes
distro suites (D23).

## 7. Delivery plan (phases; each lands lib + both distros + docs + pins +
tests together)

- **0 done** — canonical import (through 692807c).
- **1 planned** — correctness/permanent-base gate (follows the artifact
  bootstrap and lands against pinned artifacts): ETP Local rendering,
  override rejection, CIDR/id unification, cert-manager permanent +
  duplication fixes, Traefik always-off, managed labels.
- **2 NEXT — ACTIVE (first order of business)** — artifact flake
  (external-systems/pkgs): granular components incl. distro runtimes
  (source-built RKE2/k3s, release tags, LAST 3 MINORS each — D34), one
  upstream Cilium 1.20+ profile, Multus, `gateway-envoy` (EG chart +
  envoy image + Gateway API/EG CRDs), flux-operator + Flux distribution
  (incl. `flux-operator distro mirror`-style airgap set), external-dns,
  Sealed Secrets, test fixtures (go-httpbin; `curlHTTP3`-based HTTP/3
  client image via dockerTools; Caddy for QUIC passthrough); build-time
  Helm inflation → manifest artifacts (D26); atomic updaters, artifact
  checks (version parity per minor, D34; support-window warning, D34),
  clean-public-fetch proof.
- **3** — transport modes, hashed ids, topology, dual-stack exports;
  one-cluster-per-node assertion.
- **4** — pools + default EG datapath: node pools, carve-outs in
  `gateway.instances`, `gateway.classes`, default NS+EW Gateway pair,
  fleet CA, browser trust.
- **5** — EG 0–N completion + external CCM + GitOps handoff (zero-churn
  proofs; Flux bootstrap + Cilium adoption parity, D28/D29;
  flux-enable=false path).
- **6** — BGP v2 + BIRD + private fleet fabric (MOVED before ClusterMesh;
  default-on private pool + CoreDNS/private-Gateway VIPs; vendored BIRD
  fragment renderer).
- **7** — automatic ClusterMesh (apiserver stays node-bound + fan-in;
  kube-api mirror Services + hub CoreDNS rewrites, D30).
- **8** — PKI ops, Sealed Secrets (plane separation, D35), Multus
  completion, RKE2 CIS defaults (D25).
- **9** — OpenEBS Local PV. **10** — KubeVirt + CDI.
- **11** — fleet-routing service (client/admin/router; replaces
  edge-proxy; dual-role suite).
- **12** — borg migration + upstream review (suites incl.
  `rke2-gateway-envoy`, no `*-traefik-*`; production shape = default EG
  on node addresses + primary IPv4 :443, additional IPv6 EG Gateways).
- **13** — kubenix renderer migration + helm-controller default-off
  (D26/D27; may land earlier per-phase as rendering is touched).
- **14** — external-dns add-on + hub-spoke workload delivery proofs
  (D30/D31).
- Reserved: upstream `kubernetes` distro implementation (D23; spec'd,
  hard requirement), MCS-API, clan-operator (spoke credential
  minting/rotation, D30).

## 8. Out of scope

Alternative CNIs / native-routing base / L2 announcements / VRRP /
Keepalived / host-network Gateways; single-stack internals; Node IPAM for
clan proxies; Rancher Manager; cross-inventory automatic mesh; implicit
global Services; early/default-on MCS-API; bundled provider CCMs;
replicated storage (Longhorn/Mayastor); provider-specific issuers or
Cloudflare account resources in base; Windows guests / every KubeVirt
feature; direct-to-pod routing from edges; NAT64/app egress remediation;
HTTP response caching at the edge (dropped with edge-proxy); ListenerSets
while experimental; same VIP advertised from two clusters; pod-CIDR
advertisement to hosts by default (admin role excepted, D33); public
shared-BGP without upstream-routed space (incl. single dynamic
residential IPv4); heterogeneous multi-WAN inbound failover (use DNS
failover); Flux-managed EG controller; hub-side remote Flux INSTALLATION
(upstream-declined, D28); Cilium Ingress/Gateway and the Ingress API as
supported surfaces; Traefik; generic UDP relay; untested optional
protocol profiles; blanket 100-year leaves; cert-manager-generated
Sealed-Secrets keys; blind live CA regeneration; fully declarative
node/etcd/cluster deletion; in-place RKE2↔k3s↔kubernetes conversion;
locked-HEAD distro constructors (D34); OLM v1 as install method (D32);
clan vars ownership of application-plane secrets (D35); external-dns for
inter-cluster DNS (D31).

## 9. Glossary

- **Cluster services** — public rke2/k3s/kubernetes clanServices +
  private shared library; not Rancher Manager.
- **Artifact flake** — external-systems/pkgs; pinned packages/charts/
  images/CRDs without fleet policy; last 3 k8s minors per distro (D34).
- **Distro** — the Kubernetes distribution a cluster instance runs:
  `rke2` | `k3s` | `kubernetes` (upstream, kubeadm-based, D23).
- **CNCF posture** — in-cluster components are CNCF projects; host-level
  (BIRD, WireGuard) exempt; rke2 is the documented distro exception
  (D24).
- **Kubenix rendering** — manifests built as typed Nix module resources;
  Helm inflation only at artifact-flake build time (D26).
- **Flux bootstrap** — clan-rendered flux-operator + FluxInstance present
  from first boot on every cluster (D28).
- **Hub cluster** — the cluster holding spoke kubeconfigs and delivering
  workloads fleet-wide via Flux `kubeConfig.secretRef`; never installs
  Flux remotely (D28).
- **Mirror Service** — clan-rendered selectorless ClusterMesh-global
  Service + EndpointSlice exposing a cluster's kube-apiserver to mesh
  members (D30).
- **Bootstrap plane / application plane** — secrets custody split: clan
  vars own bootstrap secrets (CAs, tokens, kubeconfigs, sealing keys);
  GitOps + Sealed Secrets own in-cluster application credentials (D35).
- **Integrated node transport** — per-cluster routed L3 (host WG default
  | cilium-wireguard | unencrypted) carrying dual-stack node InternalIPs,
  API, VXLAN.
- **Mesh group** — mutually trusted cluster instances forming one
  ClusterMesh.
- **Pool scope** — per-machine (node-named) vs cluster-global
  (generic-named); who contributes a pool's addresses.
- **Delivery mode** — node-fate-bound | floating | shared-bgp |
  external-class; how traffic reaches pool addresses + failure semantics.
- **Node-fate-bound delivery** — provider/static routing to one node; no
  failover, no BGP.
- **Floating delivery** — runtime controller moves the address to one
  node at a time; failover is the controller's contract, not
  eval-visible.
- **Shared BGP VIP** — address advertised from all healthy nodes
  (ETP-Local withdrawal); the `shared-bgp` mode of a cluster-global pool.
- **Private fleet fabric** — default per-cluster private shared-bgp pool
  + BIRD/BGP base + CoreDNS/private-Gateway VIPs; lets clan hosts route
  into every cluster.
- **Node-named pool** — per-machine pool of join + declared extra blocks.
- **Explicit projection** — eval-time `lbipam.cilium.io/ips` list of
  per-node addresses for deterministic multi-IP Service status.
- **ETP Local** — externalTrafficPolicy: Local; traffic accepted only
  with ready local endpoints; direct node traffic avoids SNAT.
- **Gateway class / instance** — class = GatewayClass + EnvoyProxy
  (isolation domain); instance = one clan-rendered Gateway bound to a
  class.
- **Shared-gateway model** — platform owns Gateway + listeners, tenants
  own Routes; cert-manager Gateway integration provisions certs.
- **Zero-churn contract** — `gateway.instances = {}` + clan pools ⇒ full
  tenant Gateway stack via GitOps, no NixOS rebuild.
- **Fleet CA** — dedicated shared root CA signing private-Gateway certs;
  installed into clan hosts' trust stores by the client/admin roles.
- **Fleet-routing service** — clanService (client/admin/router roles)
  giving non-Kubernetes hosts routed access to cluster VIPs (client),
  pod/Service CIDRs (admin), or upstream prefix ownership (router).
- **Private-domain zones** — per-cluster DNS zones served by cluster
  CoreDNS on the private VIP: `<instance>.<domain>` (wildcard → Gateway,
  default) and opt-in `<instance>.svc.<domain>` (rewrite to Service IPs)
  and pod zone. `cluster.local` never appears on clients.
- **Fleet-wide mTLS (east-west)** — preferred path: private Gateway
  validates client certs against the fleet CA; clan machines hold
  per-machine client certs. Gated on VM proof before default-on.
- **Managed base** — labeled clan-rendered APIs/resources installed once;
  tenant resources GitOps-owned.
- **Airgap-ready** — all artifacts pinned and local at boot.
- **VM-proven** — behavior passed fresh, sandboxed, hermetic on final
  tree.

## 10. Key upstream references

- Cilium 1.20: LB IPAM, BGP v2, ClusterMesh (global Services +
  `service.cilium.io/global|shared|affinity`, EndpointSlice sync), Gateway
  gaps (cilium#28497 HTTP/3; cilium#25567 Gateway IP sharing; GEP-91
  mTLS).
- Envoy Gateway (gateway.envoyproxy.io): deployment modes/DaemonSet,
  mergeGateways, customize EnvoyProxy (envoyService), ClientTrafficPolicy
  (mTLS, HTTP/3; bug envoyproxy/gateway#9798), ETP Local default; k8s
  support matrix 1.33–1.36 at v1.9 (D34 warning gate).
- Gateway API: GEP-91 (client cert validation, experimental).
- Flux: flux-operator fleet model (flux-operator#624 not_planned —
  FluxInstance local-only); `Kustomization/HelmRelease.spec.kubeConfig`
  remote delivery; `flux-operator distro mirror` airgap; HelmRelease
  adoption via matching releaseName/namespace (no createNamespace).
- external-dns (kubernetes-sigs): provider model (GoDaddy, Cloudflare,
  RFC2136); CoreDNS provider requires etcd backend — rejected for
  inter-cluster (D31).
- OLM v1 (operator-controller): ClusterExtension/ClusterCatalog;
  OpenShift-only airgap; catalog coverage gaps (D32).
- RKE2 hardening: `profile: cis` (v1.29+), PSA restricted, host
  sysctl/etcd-user prerequisites (D25).
- Kubernetes version skew: kubelets may lag apiserver up to 3 minors
  (motivates D34).
- BIRD 2 + vendored fragment pattern (D19; NuschtOS/bird.nix reviewed,
  not adopted).
- Mozilla: enterprise_roots is Windows/macOS-only; Linux = Certificates.
  Import policy / per-profile NSS (zen-browser is Firefox-based).
- go-httpbin (github.com/mccutchen/go-httpbin): standard airgapped
  HTTP/HTTPS VM-test workload; Caddy = QUIC-passthrough server fixture;
  nixpkgs curlHTTP3 = HTTP/3 test client.
