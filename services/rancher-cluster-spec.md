# Rancher clanServices — Full Specification (agent edition)

Token-efficient companion to `rancher-cluster-spec.html`. **Same spec, two
renderings — edit both together.** HTML = rich human record (figures,
evidence, prose rationale); this file = the full contract in dense form for
agents (later: mkdocs source). HTML §1 is the *status* authority; this file's
decisions are the *target* contract. Baseline: `692807c` (imported); recorded
green: wireguard-mesh + rke2/k3s single/join/HA VM suites in the source fork.
Revised 2026-10-19 (design rounds 1–7).

## 1. Problem (condensed)

Declare machines + cluster instances in `inventory.nix`, receive working,
secure, interconnected k3s/RKE2 clusters. Hard interacting requirements:
multi-cluster identity/CIDR coherence; mandatory dual-stack regardless of
underlay; bare-metal LoadBalancing = allocation + delivery + datapath (three
different things); ingress is not only HTTP (TCP/UDP/TLS-passthrough/mTLS/
QUIC); source preservation (ETP Local) changes routing behavior; address
families asymmetric in the real world; artifacts and services have different
release cycles; batteries-included without host-coupled day two (GitOps);
Gateway/LB ownership must not force NixOS churn; misconfiguration must fail
at eval where possible, VM-proven where not.

## 2. Architecture in one paragraph

Thin public `rke2` + `k3s` clanServices over a private shared library
(`lib/rancher-cluster/`): shared interfaces, pure renderers, vars generators,
assertions. Integrated dual-stack transport (host WireGuard default; native
Cilium WireGuard; explicit unencrypted underlay). Cilium = CNI + KPR + VXLAN
tunnel + multi-pool IPAM + LB IPAM + BGP v2 + ClusterMesh — networking only.
Envoy Gateway = the only ingress/Gateway implementation (0–N). cert-manager
always on. Per-node BIRD + default private BGP fleet fabric; a fleet-routing
clanService extends VIP reachability to non-Kubernetes NixOS hosts. Artifact
flake (`external-systems/pkgs`) pins every chart/image/CRD; airgap-ready is
the tested default. Day two = Flux/Argo against base APIs.

## 3. Decision record (D1–D22; rounds 1–8, locked 2026-10-19)

- **D1 Cilium is networking-only.** `gatewayAPI.enabled=false`,
  `ingressController.enabled=false` permanently. Reasons: no Gateway HTTP/3
  (cilium#28497), no Gateway mTLS (GEP-91), no DaemonSet mode, no
  multi-Gateway IP sharing (cilium#25567).
- **D2 Envoy Gateway = default ingress/Gateway.** EG controller + CRDs +
  Gateway API CRDs (standard + experimental) are always-rendered base (like
  cert-manager); atomic `gateway-envoy` artifact component (EG chart + envoy
  image + CRDs), one upstream profile both distros, airgap-locked.
  Data plane via `EnvoyProxy`: DaemonSet on labeled workers,
  `envoyService.externalTrafficPolicy: Local` (EG default), pool labels +
  `lbipam.cilium.io/ips` projections via `envoyService.labels/annotations` —
  never annotate the controller-managed Service directly. `mergeGateways`
  only on a separate opt-in class (blast radius: one bad tenant listener
  NACKs the merged fleet). Known bug: http3+proxyProtocol on one
  ClientTrafficPolicy → invalid QUIC listener (envoyproxy/gateway#9798).
- **D3 Traefik is REMOVED** (revised round 7; was "first-class 0–N").
  Distro-bundled Traefik charts always disabled on both distros;
  `traefik.instances` deleted; no `ingressGateway.controller` selector
  remains; multi-instance/IPv6-carve-out stories move to EG Gateways (D17);
  `*-traefik-multi` suites replaced by EG multi-Gateway suites. Stack becomes
  pure Gateway API + EG policy CRDs.
- **D4 Ingress API deprecated entirely.** No `networking.k8s.io/v1 Ingress`,
  no Cilium Ingress, no Traefik IngressRoute in base or recommended tenant
  path. Gateway API core lacks mTLS/HTTP3 → controller **policy** CRDs
  (ClientTrafficPolicy etc.) are the sanctioned extension until GEP-91/HTTP3
  GEP land.
- **D5 HAProxy edge-proxy scrapped.** Edge = EG DaemonSet on labeled
  workers. Dropped requirement recorded: HTTP response caching. Cloudflare
  mTLS = ClientTrafficPolicy `tls.clientValidation` + Cloudflare client CA;
  Cloudflare Origin CA issuer is Flux/Sealed-Secrets-owned.
- **D6 Three-layer Gateway ownership (zero-churn contract).** L1 clan
  always: EG controller, CRDs, pools. L2 clan 0–N: `gateway.classes` +
  `gateway.instances` (empty = fully GitOps-owned Gateway layer —
  first-class shape). L3 GitOps always: Routes, certs, tenant Gateways, raw
  L4 Services. Tenants draw from labeled pools (one IP per family) or write
  explicit `lbipam.cilium.io/ips` — no NixOS rebuild. EG controller itself
  never Flux-managed (artifact pinning is the point); Gateway configuration
  may be.
- **D7 Default Gateway pair (0–1 each) — NS + EW.** Default-on when L2
  non-empty: a **public** Gateway (north-south, primary IPv4 :443 maximizer)
  and a **private** Gateway (east-west, private fleet-fabric VIP, fleet-CA
  wildcard cert — D18). Listener profile `web`: `:80` redirect; catch-all
  `HTTPS:443` terminate (default cert); `TLS:443` passthrough (hostname
  MANDATORY); HTTP/3 UDP/443 + TCP/443 + firewall both. `domains = [...]` →
  ONE cert-manager Certificate SAN list; cert-manager Gateway annotation
  (`cert-manager.io/issuer`); no ListenerSets (experimental). Optional named
  extra listeners (e.g. `cloudflare`). Tenants own Routes; platform owns
  listeners. Fluid domains → Flux-owned Gateway with own address. The `web`
  profile is IDENTICAL on both default Gateways (HTTP/3, terminate-default,
  hostname-mandatory passthrough, per-listener mTLS); only class, address
  source, and issuing CA differ.
- **D8 Pool model: 2 scopes × 4 delivery modes.** Pool = address inventory +
  `serviceSelector` only. Scope: *per-machine* → node-named pools (auto
  join-address /32+/128 + declared primary/extra blocks; always
  node-fate-bound); *cluster-global* → generic-named pools
  (`helsinki-ipv4-1`, `fsn-ipv6`; never node-fate-bound). Delivery:
  `node-fate-bound` (no failover, no BGP) | `floating` (runtime controller
  moves IP, one node at a time; no route withdrawal; blackhole window;
  requires full local proxy coverage on candidate set) | `shared-bgp` (all
  healthy nodes advertise /32+/128; router ECMPs; ETP-Local withdrawal) |
  `external-class` (cloud CCM). `public=true`/`private=true`/`games=true` =
  selector labels on pools of any scope/mode, not a category. Dynamic draw =
  one IP per family; multi-IP explicit annotation = deliberate projection.
  Assertions: blocks non-overlapping; scope⇒mode validity; BGP only for
  `shared-bgp`; floating ⇒ candidate-set coverage; `shared-bgp` blocks ⊆
  router-role prefixes when router in same inventory.
- **D9 BGP topology + foreign-router contract.** Cilium GoBGP originates
  VIP routes, dials OUT over loopback to per-node BIRD (no :179 listener);
  BIRD imports only approved exact VIPs, exports only those upstream (never
  default/mesh/primary/transit), no broad kernel install on cluster nodes;
  upstream router (NixOS BIRD host | MikroTik | switch) hears the same
  route from every healthy node → ECMP. Cilium agents never peer with each
  other. Deterministic 2 private 32-bit ASNs per cluster (BIRD-side,
  Cilium-side) + per-node router id; uniform ASN ⇒ no multipath-relax.
  Timers not BFD (none in 1.20): hold 9 / keepalive 3 / connect-retry 5.
  Foreign-router contract (published): ASNs, timers, accept only pool
  blocks as /32+/128 with max-prefix + prefix filters, ECMP path count ≥
  node count, proxy-NDP if on-LAN. BIRD config rendered via a vendored
  named-fragment module pattern (D19).
- **D10 Private fleet routing fabric DEFAULT ON.** Per cluster by default:
  per-node BIRD + BGP v2 resources, one private `shared-bgp` pool (ULA +
  RFC1918 from derived cluster CIDR space), core VIPs on it (private
  Gateway, CoreDNS). Public `shared-bgp` opt-in; preconditions:
  upstream-routed space (DHCPv6-PD carve-out / static / PI) + controlled
  router. Non-goals: single dynamic residential IPv4 public BGP;
  heterogeneous multi-WAN inbound failover (DNS failover instead). Hetzner
  public edge = node-bound + floating + Cloudflare-healthcheck DNS
  failover. One VIP per cluster — never advertise the same VIP from two
  clusters (cross-cluster = ClusterMesh global services or DNS).
- **D11 Fleet-routing clanService (working name `cluster-client`).**
  Non-Kubernetes clan hosts → cluster VIPs. Role `client`: join
  wireguard-mesh, BIRD-peer with cluster nodes, install learned routes,
  DNS stub (resolved/unbound) per cluster domain → cluster CoreDNS VIP,
  fleet CA trust install (D18); /etc/hosts = zero-BGP fallback. Role
  `router`: owns prefixes (PD carve-outs, static), accepts prefix-filtered
  VIP advertisements, NDP, optional default origination. One host may hold
  both roles (client and upstream router = same BIRD, different peers).
- **D12 ClusterMesh apiserver exposure stays node-bound** mesh addresses +
  selectorless-Service DNS fan-in. Not a shared-BGP VIP: consumers are mesh
  members with direct routes; control plane takes fewest dependencies.
- **D13 Pod/ClusterIP advertisement to hosts: opt-in, default off.**
  Hosts reach Services via VIPs, never pods or ClusterIPs directly.
  Per-cluster opt-ins may advertise `CiliumPodIPPool` prefixes (pods) and
  Service ClusterIPs/CIDR (services) to the host routing domain for
  deliberate admin use. Caveats: ephemeral IPs, `world` policy identity,
  trust extension, no readiness. Pairs with the client-role opt-in DNS
  zones (D22).
- **D14 Raw L4 (Minecraft/Simple Voice Chat/games).** Plain
  `type: LoadBalancer` Services, NEVER Gateways (no SNI in Minecraft ⇒ one
  IP:25565 = one backend or one Velocity proxy). Mixed TCP+UDP on one
  Service/IP (25565/TCP + 24454/UDP). ETP Local preserves player IPs.
  Address: labeled pool draw, floating pool, or explicit projection.
- **D15 One IP:443, all TLS modes.** One IP:443 simultaneously: SNI
  multi-cert HTTPS terminate + hostname-filtered TLS passthrough +
  per-listener mTLS + HTTP/3 (UDP/443 beside TCP/443). Only EG satisfies
  the full set (see D1) ⇒ EG owns the default web path.
- **D16 One cluster per node.** A machine belongs to at most one cluster
  instance (rke2 or k3s) — inventory-wide eval assertion.
- **D17 Gateway classes vs instances (0–N structure).** `gateway.classes.
  <name>` (0–N): one GatewayClass + one EnvoyProxy per class — the
  isolation domain: daemonset/deployment, node-label placement, pool
  selector labels, base annotations, mergeGateways opt-in. `gateway.
  instances.<name>` (0–N): one clan-rendered Gateway bound to a class —
  address projection (explicit per-node addresses; deterministic IPv6
  carve-outs live HERE now: stable hash of cluster+node+instance, explicit
  offset override, collision = eval error), listener profile (`web` |
  custom), domains→SAN cert, namespace, allowedRoutes. Defaults: classes
  `public` (DaemonSet on edge workers, `public=true` pools) + `private`
  (private fabric VIP, `private=true` pools); instances `public` +
  `private` (D7). Tenant isolation ladder: listener < Gateway < class.
  Tenants create Gateways against clan classes via GitOps (zero churn);
  creating classes is platform work.
- **D18 Fleet CA + browser trust.** Dedicated fleet root CA (shared vars
  generator `fleet-ca-<group>`, `share=true`; private key only leaves vars
  as the cluster's cert-manager CA-issuer Secret via secret-sync). Private
  Gateway certs issued by cert-manager from it. fleet-routing `client` role
  installs the CA into `security.pki.certificateFiles` (covers
  Chromium/curl/most tooling). Firefox-family (incl. zen-browser): Linux
  does NOT support `security.enterprise_roots.enabled`; use enterprise
  policy `Certificates.Import` (zen/firefox Nix wrappers expose
  `policies`) — rendered by the client role when such a browser module is
  detected; per-profile NSS (certutil) is the documented fallback.
- **D19 BIRD rendering: vendored named-fragment pattern.** Reviewed
  NuschtOS/bird.nix (alpha, MIT): its `templates`/`protocols`
  `attrsOf lines` composition model is the right idea (multiple
  clanServices contribute named blocks to ONE bird daemon), but it lacks
  top-level `filter`/`function` blocks and typed fields — do not take as an
  input. Vendor the pattern into `lib/rancher-cluster` with added
  `filters`/`functions` maps; keys namespace-prefixed per instance
  (`bgp.<instance>_cilium`, `bgp.<instance>_upstream`); same-key = text
  concat (avoid); `routerId` set exactly once; nixpkgs `bird -p` pre-start
  check remains the validator. One BIRD per host; fleet-routing roles on a
  cluster member merge into its existing BIRD; eval asserts no second BGP
  stack / ASN conflict.
- **D20 Fleet-wide east-west mTLS is the PREFERRED path, gated on proof.**
  Private-Gateway ClientTrafficPolicy `clientValidation` against the fleet
  CA + per-machine client-cert vars generators gives mutual TLS on the
  east-west path. Default-on only after a VM suite proves accept/reject and
  client-cert presentation from clan machines. Honest caveat: browser
  client-cert UX is poor — mTLS is enforced per listener/hostname for
  machine/admin endpoints while ordinary browser endpoints stay
  terminate-only.
- **D21 The internal cluster domain is pinned to `cluster.local`.** Never
  changed, eval-asserted. ClusterMesh does not depend on it (mesh discovery
  uses its own identities/zone), but the ecosystem (charts, CSI,
  cert-manager webhook FQDNs, app configs) hardcodes `cluster.local` — high
  blast radius, zero benefit. All aliasing needs are served by CoreDNS
  rewrites (D22) instead.
- **D22 Private-domain routing contract.** Default: client machines resolve
  ONLY the zone `<instance>.<meta.domain>` — a clan-rendered CoreDNS zone
  (served on the cluster's private CoreDNS VIP) with a wildcard → private
  Gateway VIP; east-west traffic enters through the Gateway, mirroring how
  internet traffic enters. Per-client-machine opt-ins: (a) service zone
  `<instance>.svc.<meta.domain>` — CoreDNS rewrites to
  `<name>.<ns>.svc.cluster.local` with answer-name reversal, resolving to
  Service IPs (works out of the box for private-pool LB VIPs, which the
  fabric already routes; ClusterIPs additionally require the D13 service
  advertisement opt-in); (b) pod zone (CoreDNS `pods insecure` + dash-form
  rewrites + D13 pod advertisement). `cluster.local` is NEVER served to
  clients (D21).

## 4. Invariants (target; eval-asserted or VM-proven)

1. One declarative fleet: instance declaration ⇒ stable identity,
   non-overlapping defaults, integrated transport, automatic ClusterMesh
   when mesh group has peers.
2. Dual-stack inside, always (nodes/pods/Services); public exposure varies
   per node/Service (v4-only, v6-only, both, neither).
3. Cilium is the only CNI base: one upstream 1.20+ profile, KPR, VXLAN,
   multi-pool; networking-only (D1).
4. L3 only: no VLAN/L2-announce/VRRP/shared-L2. Transport =
   host-wireguard (default) | cilium-wireguard | unencrypted; every mode
   dual-stack.
5. ETP Local on every clan-rendered external proxy Service; no silent
   Cluster fallback.
6. One LB-IPAM model: 2 scopes × 4 delivery modes (D8); explicit per-node
   projection for clan-managed multi-node proxies; no Node IPAM.
7. BGP ownership unambiguous: only `shared-bgp` pools advertised; private
   fabric default; public opt-in (D9/D10).
8. Envoy Gateway by default and only; 0–N classes/instances; default NS+EW
   pair (D2/D7/D17).
9. Topology always labeled: region/zone default to instance name,
   per-machine overrides, non-empty.
10. cert-manager is base (no disable); fleet CA for EW trust (D18);
    Sealed Secrets optional with vars-owned key history.
11. Hermetic proof: pinned artifacts, eval rejection of invalid
    inventories, hermetic VM suites.
12. Three-layer ownership / zero-churn (D6); Ingress API deprecated (D4).
13. One cluster per node (D16); one BIRD per host (D19); one proxy
    implementation per IP:port (D15).
14. `cluster.local` is pinned and never served to clients (D21); private
    domains route through the private Gateway by default (D22).

## 5. Subsystem contracts (condensed)

### 5.1 Ownership boundaries
Canonical repo = external-systems/clanServices; thin distro services own
bootstrap/TLS-dir/join semantics; shared lib owns parity; artifact flake =
only packaging input (granular atomic component sets; source-built
RKE2/k3s; locked HEADs); consumers pin immutable revisions; fleet-routing
and tenant resources are consumers, never hidden dependencies.

### 5.2 Identity, CIDRs, topology, exports
Cluster name = instance name (≤32 chars, DNS-style). `cilium.id` nullable;
default = stable hash of instance name → 1–127; collision = eval error;
explicit 1–255 override requires explicit v4 CIDRs above 127. Migration:
pin existing ids/CIDRs before hashed defaults land. One resolved dual-stack
CIDR structure feeds distro, Cilium, DNS, pools, assertions, exports.
region/zone labels default to instance name, per-machine overrides.
`rancher_cluster` instance export: identity, mesh group, CIDRs, mesh
endpoints, pool handoff, schema version. `node_transport` per-node export:
mesh/underlay addresses, interface, MTU, primary/external facts, delivery
modes, topology. No secrets in exports. Inventory-wide assertions:
duplicate names/ids/CIDRs, overlapping CIDRs, duplicate NodePorts, missing
peers, missing labels, node-in-two-clusters (D16).

### 5.3 Transport
`transport.mode = host-wireguard | cilium-wireguard | unencrypted`.
host-wireguard: every node gets mesh v4+v6 (deterministic from id + machine
name); per-machine overrides (addresses, port, endpoint, interface, MTU,
routes, pool blocks). cilium-wireguard: no host WG resources, Cilium
transparent encryption, explicit dual-stack node facts required.
unencrypted: no confidentiality claim, explicit facts required, missing
family = eval error. Mesh groups: cross-cluster peering from exports +
public vars keys, remote prefixes only in AllowedIPs; every remote node
InternalIP reachable before ClusterMesh ready. MTU: transport MTU −50 =
tunnel budget. Distro HTTP-proxy setting = documented escape only.

### 5.4 Cilium base
Same canonical upstream Cilium 1.20+ chart/images both distros; RKE2
bundled Cilium disabled. Always: KPR, VXLAN, multi-pool IPAM, BPF
masquerade+tproxy, Maglev, pmtu, default dual-stack pod pool. Post-merge
validation rejects helmValues violating routing/tunnel/IPAM/dual-stack/
CNI-chaining/artifact/ETP invariants. Multus optional: chaining switch is
explicit + atomic.

### 5.5 ClusterMesh (automatic, mixed-distro)
Mesh groups (default = all Rancher instances; opt-out separates trust).
Every eligible cluster runs clustermesh-apiserver + mesh certs from first
boot; singleton peer list empty. Peering rendered from exports into
`clustermesh.config.clusters` — no CLI. Exposure: LoadBalancer (default,
node-bound mesh addresses + ETP Local + ClientIP affinity, all servers as
endpoints, anti-affinity) with collision-checked NodePort escape.
DNS fan-in: selectorless local ClusterIP Service + eval-rendered
EndpointSlice per remote cluster. Shared `rancher-clustermesh-ca-<group>`
vars generator (share=true); per-cluster dependent cert generators; SANs
include every exported address + fan-in name; endpoint set is a public
validation input (membership change ⇒ reissue before advertise). CA/cert
material never in exports/helm/store. Same datapath, same Cilium profile,
maxConnectedClusters uniform. Global Services opt-in per Service. MCS-API
reserved (disabled initially). Rotation = separate two-phase CA-bundle
design; blind regeneration unsupported.

### 5.6 Pools, LB, BGP, BIRD
Per D8/D9/D10/D19. Zero-config single-node example: node-1 with join
addresses 10.0.0.1/32 + fd0::1/128 ⇒ pool `node-1` with exactly those
blocks. Declared public primary wins over mesh fallback for the default
Gateway projection. Generic tenant draw = one IP per family. Pool updates
may reassign IPs (Cilium-side) ⇒ reviewed network changes. Floating pools:
runtime controllers (e.g. hcloud-ip-floater) move addresses; clan asserts
shape + coverage only; failover timing is the controller's contract.
BIRD-on-hosts (client/router roles) installs routes into the kernel;
cluster nodes do not broadly install.

### 5.7 Gateways (Envoy Gateway)
Per D2/D6/D7/D14/D15/D17/D18. Port uniqueness evaluated per
node/address/family/protocol (TCP and UDP may share a number). HTTP/3 =
QUIC listener + TCP+UDP Service ports + NetworkPolicy + firewall together.
TLS passthrough ⇒ backend terminates; source seen by backend = proxy IP
(no client-IP promise). XFF/X-Envoy-External-Address documented separately
from raw-L4 source preservation. Default cert from cert-manager; custom
certs render once in consumer namespace and suppress defaults.
`gateway.instances = {}` = fully GitOps-owned, first-class.

### 5.8 Base and add-ons
cert-manager: always on (pinned, bootstrap selfsigned CA, voter placement,
arbitrary issuer refs). CoreDNS rewrites: on, distro-appropriate ConfigMaps.
Sealed Secrets: off; `keyManagement = clan-vars` (default when enabled;
persistent keypair, offline public cert, native renewal disabled, old keys
retained) | `controller` (native + backup runbook). Never a plain
cert-manager Certificate for sealing keys. Multus/OpenEBS-LVM/OpenEBS-ZFS/
KubeVirt+CDI: optional add-ons with per-engine artifacts, host prep, and VM
suites per the HTML §5.8 table (unchanged).

### 5.9 Secrets / PKI / airgap
Clan vars own cluster CAs, tokens, haproxy material, admin kubeconfigs,
Sealed-Secrets keys, ClusterMesh CA/certs, fleet CA (D18). Public certs
readable as public values; private material referenced by deployed paths
only. RKE2 PKI sync non-destructive; k3s init-only seed + native
replication. Airgap-ready default; one explicit opt-out switch; overrides =
complete replacement sets or additive lists.

### 5.10 Rotation and imperative lifecycle
Leaf certs: upstream 365-day, renew at startup; manual via
`{rke2,k3s} certificate rotate`. CA rotation: staged dir + `rotate-ca`;
same-root can be non-disruptive; new root disruptive (tokens, kubeconfigs,
restarts). Service-account signing key: append/retain. No blanket 100-year
leaf default; long-lived offline root = explicit risk decision. Inventory
deletion ≠ cluster GC: cordon/drain, Node deletion, etcd member removal,
mesh cleanup = documented runbooks. Disruptive changes (pools, CIDRs, ids,
CA roots, mesh membership) = reviewed operational changes.

### 5.11 CCM, managed manifests, GitOps
`cloudController = none | rancher | external`; provider CCMs never bundled;
hermetic fake-CCM VM test. Every clan-rendered manifest labeled
(managed-by, instance, component, config-hash; never in selectors).
Managed base installs APIs + small base set; tenants use Flux/Argo without
NixOS activation; base upgrades preserve tenant CRDs.

### 5.12 Assertions and firewall
Eval rejects: multiple bootstraps, duplicate ids/CIDRs/ports, missing
dual-stack facts, missing topology labels, invalid TLS/entrypoint combos,
duplicate certs, uncovered cert refs, pool overlap, scope⇒mode violations,
floating without candidate coverage, `shared-bgp` ⊄ router prefixes,
node-in-two-clusters, second BGP stack per host, two proxy implementations
per IP:port, passthrough listener without hostname, mergeGateways on
non-opt-in class, ETP Cluster / Node IPAM / host-network mode on clan
proxies. Firewall: API/haproxy on transport only; public ports only where
a Service exposes them; mesh/BGP restricted to expected peers; HTTP/3
opens UDP+TCP. VM tests assert positive connectivity AND negative exposure.

### 5.13 Fleet-routing service
Per D11/D13/D18/D19/D20/D22. Client role: mesh join, BIRD peering, route
install, fleet CA trust; DNS stub defaults to the `<instance>.<domain>`
gateway zone only (D22), with per-machine opt-in service/pod rewrite zones.
Router role: prefix ownership, filtered VIP acceptance, NDP. Acceptance:
client role reaches cluster VIPs (routes + DNS stub) on a non-cluster host;
opt-in svc/pod zones resolve and route only when enabled; router role
accepts only owned prefixes; cross-inventory prefix assertions; MikroTik-
style foreign-router runbook; browser trust install; east-west mTLS
accept/reject proof (D20) before it defaults on.

## 6. Testing contract

Seams: pure renderer nix-unit tests; throwaway clans via `clanLib.clan`
(inventory boundary); `clan.nixosTests` hermetic VM suites (one at a time,
sandboxed authoritative); artifact source/hash/render gates. Standard
internal HTTP/HTTPS test workload: **go-httpbin** (zero-dependency Go
stdlib httpbin port; pinned + airgap-carried as a test-fixture artifact;
HTTPS fixtures use generated certs). go-httpbin speaks HTTP/1.1 + HTTP/2
only (no QUIC in Go stdlib) ⇒ HTTP/3 termination suites use an
HTTP/3-capable client against the Gateway with go-httpbin as plain
backend — QUIC terminates at EG, which is the architecture under test.
HTTP/3 client: nixpkgs `curlHTTP3` run by the VM test driver directly on
the node (`curl --http3`); if an in-cluster client is needed, the
artifact repo builds its own image from `pkgs.curlHTTP3` via
`dockerTools` — never third-party http3 curl images (unpinned).
**QUIC passthrough suite** (required): UDPRoute (raw L4 UDP — QUIC cannot
be SNI-routed at L7; TLS lives inside QUIC) through an EG UDP listener to
a pinned **Caddy** fixture serving HTTP/3 end-to-end; one UDP/443
listener per address per backend class (no hostname multiplexing on raw
UDP). HTTP/3 advertisement: `Alt-Svc` response header via the core
`ResponseHeaderModifier` HTTPRoute filter (backend needs no awareness),
or DNS `HTTPS`/SVCB records with `alpn="h3"` in the private-domain zones
(D22). Rules:
hermetic/offline; eval-deterministic addresses; dual-stack asserted in
every boot test; round-trips + failure behavior (HTTPS validates CA, UDP
echo, HTTP/3 uses QUIC, BGP withdrawal keeps VIP via healthy nodes);
negative assertions; operational postconditions; fail fast. Suites:
existing single/join/HA (keep); transport matrix; artifact matrix; EG
gateway matrix (replaces Cilium gateway + Traefik multi): DaemonSet
placement, ETP Local, projections, L4+L7 one Gateway, HTTP/3 QUIC, mTLS
accept/reject, cert-manager Gateway integration, source preservation, 0–N
multi-Gateway isolation, zero-clan-Gateway tenant round-trip; lb-pool
suite (exact defaults, carve-outs, floating semantics — documented
blackhole window, no withdrawal claim); bgp-ecmp suite (+ private fabric,
MikroTik-style foreign-router fixture); ClusterMesh matrix; PKI rotation;
CCM/GitOps handoff; multus + sealed-secrets; openEBS; kubevirt;
fleet-routing suite (incl. opt-in svc/pod rewrite zones and east-west mTLS
accept/reject, D20/D22). Reserved: MCS-API, upstream-Kubernetes distro.

## 7. Delivery plan (phases; each lands lib + both distros + docs + pins +
tests together)

- **0 done** — canonical import (through 692807c).
- **1 planned** — correctness/permanent-base gate (follows the artifact
  bootstrap and lands against pinned artifacts): ETP Local rendering,
  override rejection, CIDR/id unification, cert-manager permanent +
  duplication fixes, Traefik always-off, managed labels.
- **2 NEXT — ACTIVE (first order of business)** — artifact flake
  (external-systems/pkgs): granular components incl. distro runtimes
  (source-built RKE2/k3s, release + locked HEAD constructors), one
  upstream Cilium 1.20+ profile, Multus, `gateway-envoy` (EG chart +
  envoy image + Gateway API/EG CRDs), test fixtures (go-httpbin;
  `curlHTTP3`-based HTTP/3 client image via dockerTools; Caddy for QUIC
  passthrough); atomic
  updaters, artifact checks, clean-public-fetch proof.
- **3** — transport modes, hashed ids, topology, dual-stack exports;
  one-cluster-per-node assertion.
- **4** — pools + default EG datapath: node pools, carve-outs in
  `gateway.instances`, `gateway.classes`, default NS+EW Gateway pair, fleet
  CA, browser trust.
- **5** — EG 0–N completion + external CCM + GitOps handoff (zero-churn
  proofs).
- **6** — BGP v2 + BIRD + private fleet fabric (MOVED before ClusterMesh;
  default-on private pool + CoreDNS/private-Gateway VIPs; vendored BIRD
  fragment renderer).
- **7** — automatic ClusterMesh (apiserver stays node-bound + fan-in).
- **8** — PKI ops, Sealed Secrets, Multus completion.
- **9** — OpenEBS Local PV. **10** — KubeVirt + CDI.
- **11** — fleet-routing service (client/router; replaces edge-proxy).
- **12** — borg migration + upstream review (suites incl.
  `rke2-gateway-envoy`, no `*-traefik-*`; production shape = default EG on
  node addresses + primary IPv4 :443, additional IPv6 EG Gateways).
- Reserved: upstream Kubernetes distro, MCS-API, clan-operator.

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
advertisement to hosts by default; public shared-BGP without
upstream-routed space (incl. single dynamic residential IPv4);
heterogeneous multi-WAN inbound failover (use DNS failover); Flux-managed
EG controller; Cilium Ingress/Gateway and the Ingress API as supported
surfaces; Traefik; generic UDP relay; untested optional protocol profiles;
blanket 100-year leaves; cert-manager-generated Sealed-Secrets keys;
blind live CA regeneration; fully declarative node/etcd/cluster deletion;
in-place RKE2↔k3s conversion.

## 9. Glossary

- **Rancher services** — public rke2/k3s clanServices + private shared
  library; not Rancher Manager.
- **Artifact flake** — external-systems/pkgs; pinned packages/charts/
  images/CRDs without fleet policy.
- **Integrated node transport** — per-cluster routed L3 (host WG default |
  cilium-wireguard | unencrypted) carrying dual-stack node InternalIPs,
  API, VXLAN.
- **Mesh group** — mutually trusted Rancher instances forming one
  ClusterMesh.
- **Pool scope** — per-machine (node-named) vs cluster-global
  (generic-named); who contributes a pool's addresses.
- **Delivery mode** — node-fate-bound | floating | shared-bgp |
  external-class; how traffic reaches pool addresses + failure semantics.
- **Node-fate-bound delivery** — provider/static routing to one node; no
  failover, no BGP.
- **Floating delivery** — runtime controller moves the address to one node
  at a time; failover is the controller's contract, not eval-visible.
- **Shared BGP VIP** — address advertised from all healthy nodes (ETP-Local
  withdrawal); the `shared-bgp` mode of a cluster-global pool.
- **Private fleet fabric** — default per-cluster private shared-bgp pool +
  BIRD/BGP base + CoreDNS/private-Gateway VIPs; lets clan hosts route into
  every cluster.
- **Node-named pool** — per-machine pool of join + declared extra blocks.
- **Explicit projection** — eval-time `lbipam.cilium.io/ips` list of
  per-node addresses for deterministic multi-IP Service status.
- **ETP Local** — externalTrafficPolicy: Local; traffic accepted only with
  ready local endpoints; direct node traffic avoids SNAT.
- **Gateway class / instance** — class = GatewayClass + EnvoyProxy
  (isolation domain); instance = one clan-rendered Gateway bound to a
  class.
- **Shared-gateway model** — platform owns Gateway + listeners, tenants own
  Routes; cert-manager Gateway integration provisions certs.
- **Zero-churn contract** — `gateway.instances = {}` + clan pools ⇒ full
  tenant Gateway stack via GitOps, no NixOS rebuild.
- **Fleet CA** — dedicated shared root CA signing private-Gateway certs;
  installed into clan hosts' trust stores by the client role.
- **Fleet-routing service** — clanService (client/router roles) giving
  non-Kubernetes hosts routed access to cluster VIPs.
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
- **VM-proven** — behavior passed fresh, sandboxed, hermetic on final tree.

## 10. Key upstream references

- Cilium 1.20: LB IPAM, BGP v2, ClusterMesh, Gateway gaps (cilium#28497
  HTTP/3; cilium#25567 Gateway IP sharing; GEP-91 mTLS).
- Envoy Gateway (gateway.envoyproxy.io): deployment modes/DaemonSet,
  mergeGateways, customize EnvoyProxy (envoyService), ClientTrafficPolicy
  (mTLS, HTTP/3; bug envoyproxy/gateway#9798), ETP Local default.
- Gateway API: GEP-91 (client cert validation, experimental).
- BIRD 2 + vendored fragment pattern (D19; NuschtOS/bird.nix reviewed,
  not adopted).
- Mozilla: enterprise_roots is Windows/macOS-only; Linux = Certificates.
  Import policy / per-profile NSS (zen-browser is Firefox-based).
- go-httpbin (github.com/mccutchen/go-httpbin): standard airgapped
  HTTP/HTTPS VM-test workload; Caddy = QUIC-passthrough server fixture;
  nixpkgs curlHTTP3 = HTTP/3 test client.
