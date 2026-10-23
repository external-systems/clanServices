# Multi-cluster

Clusters in the same mesh group form one Cilium ClusterMesh automatically —
mixed distros included. Add an instance to the group and peering is rendered
from exports; no CLI steps.

## Mesh groups and trust domains

A mesh group is a set of mutually trusted cluster instances — the trust
domain string (default `meta.domain`, per-cluster `meshGroup` override).
The default mesh group is all cluster instances; opting a cluster out
separates its trust domain. The trust domain also bounds control domains
(D43): a hub and its spokes must share one group. But mesh ≠ control
domain — standalone clusters can be full mesh members with no hub
relationship to anyone.

**One mesh group = one `wireguard-mesh` instance** (phase-4 mapping): a
cluster joins a group by consuming that instance's `node_transport`
exports, so cross-cluster WireGuard peering between group members happens
inside the shared mesh instance (exports + public vars keys). Same-group
clusters consuming different transport instances — or mixing
transport-provided and manual member addresses — fail evaluation.

Every eligible cluster runs clustermesh-apiserver and mesh certificates from
first boot (a singleton's peer list is simply empty). Peering is rendered
into `clustermesh.config.clusters` from exports. The datapath, Cilium
profile, and `maxConnectedClusters` are uniform across the mesh.

The ClusterMesh apiserver stays node-bound (D12): it is exposed on machine
mesh addresses (LoadBalancer, ETP Local, ClientIP affinity, all servers as
endpoints, anti-affinity; collision-checked NodePort as the escape hatch).
Consumers are mesh members with direct routes, so the control plane takes
the fewest dependencies.

Mesh identity comes from a shared `rancher-clustermesh-ca-<group>` vars
generator with per-cluster dependent cert generators. SANs include every
exported address; a membership change reissues certificates before the new
endpoint set is advertised. CA and cert material never appear in exports,
Helm values, or the Nix store. CA rotation is a separate two-phase bundle
design — blind regeneration is unsupported.

## Mirror Services (D30)

The real `kubernetes.default` Service is never touched. Any cluster can
export its kube-apiserver to mesh members — and for
`controlDomain.role = "spoke"` this export is **mandatory**, because the
hub's GitOps tooling reconciles through it:

- The exporting cluster renders a selectorless mirror Service
  `kube-api-<cluster>` with an EndpointSlice of its API endpoints (the same
  fan-in pattern as the ClusterMesh apiserver exposure, generalized),
  annotated `service.cilium.io/global: "true"`, with `loadBalancerClass`
  pinned per D41.
- A consumer (the hub, admin tooling) renders a same-named Service with no
  local backends; ClusterMesh merges the remote endpoints, so consumer pods
  reach the remote API through that ClusterIP.
- Consumer CoreDNS rewrites `kubernetes.<cluster>.<meta.domain>` to
  `kube-api-<cluster>.<ns>.svc.cluster.local` — the human/tooling path.
- Kubeconfigs (D43/D38) use the mirror DNS name directly as `server`, with
  no rewrite dependency; the cluster's API certificate SANs must include it
  (eval-asserted, deterministic at bootstrap).
- A NetworkPolicy restricts mirror-Service access to the GitOps namespaces.

Mesh connectivity is symmetric: spokes reach the hub, and standalone mesh
members reach both, through the same global-service mechanism whenever they
export and consume mirror Services.

![Hub and spoke delivery](../assets/hub-spoke.svg)

## The control domain (D43)

`controlDomain.role = standalone | hub | spoke` is set per cluster instance
(default `standalone`). Clan renders only the GitOps-neutral substrate —
**clan never installs a GitOps controller**:

- **`standalone`** — shares no kubeconfig with any cluster. A singleton
  standalone cluster carries no hub config at all.
- **`hub`** — holds a per-spoke namespace `gitops-spoke-<spoke>` with Secret
  `kubeconfig` (admin) and Secret `kubeconfig-readonly` (D38), delivered via
  vars → hub machines → in-cluster secret-sync, plus the NetworkPolicy.
- **`spoke`** — exports its API via the mirror Service (mandatory), renders
  a ClusterRoleBinding `gitops-hub` binding group `gitops-hub` to
  `cluster-admin` (configurable role) plus optional per-tenant impersonation
  ServiceAccounts, and accepts reconciliation from its group's hub.

Hub and spokes must share one mesh group; at most one hub per group; a spoke
requires a hub in its group — all eval-asserted. Multiple mesh groups are
multiple independent trust domains, each optionally with its own hub.

## Hub credentials: `gitops-hub` client-cert identities

The hub authenticates to each spoke with a clan-minted client certificate
signed by the **spoke's** cluster CA — CN=`gitops-hub-<spoke>`,
O=`gitops-hub`, 365-day validity, from a shared dependent vars generator
`gitops-hub-client-<spoke>` whose validation pins spoke and group. The
kubeconfig Secrets live only on the hub; spoke machines never see the client
key. These control-plane credentials are bootstrap plane (D35): clan is the
issuer, so vars is the only declarative source.

Rotation is `clan vars generate --regenerate` plus a secret-sync re-apply;
spokes are untouched (same CA). Manual SA-token extraction survives only as
the documented emergency runbook; offline-minted SA JWTs and expiring
bearer-token kubeconfigs with refresh CronJobs are rejected.

Any GitOps tool consumes this substrate: Flux via
`Kustomization.spec.kubeConfig.secretRef`, Argo via cluster secrets. The
wiring is day-2, documented in the
[Day-2 GitOps guide](../guides/day-2-gitops.md), not rendered.

## Read-only credential (D38)

Every cluster also mints a read-only, no-secrets identity
(CN=`readonly-<instance>`, O=`cluster-readers`) alongside its admin
kubeconfig. The hub holds each spoke's read-only kubeconfig as Secret
`kubeconfig-readonly` in `gitops-spoke-<spoke>`, giving hub-resident tooling
and AI agents fleet-wide read access without admin keys. Details in
[Security](security.md).

## Global Services

ClusterMesh global Services are opt-in per Service; nothing becomes global
implicitly. The mirror Services above are clan-rendered globals. MCS-API is
reserved (disabled initially).

## The `kube_cluster` export

Both distro services publish a `kube_cluster` export per cluster member
machine (identical content on every member; SPEC.md §6.2). It carries:

- `schemaVersion` (currently `1`);
- cluster identity: `name` (= instance name), the resolved `ciliumId`, and
  the resolved dual-stack `network.{podCIDRv4,podCIDRv6,serviceCIDRv4,serviceCIDRv6,clusterDNS}`;
- `meshGroup` — the trust-domain string (default `meta.domain`);
- `controlDomain.role` — `"standalone"` placeholder until phase 6 (D43);
- `transport.{service,instance}` — the consumed `node_transport` source,
  or nulls for a manual-address cluster (the all-or-none posture fact);
- `members.<machine>` — per-member mesh endpoints: role, node v4/v6,
  endpoint/interface/MTU/port from the consumed transport, and the
  effective `topology.{region,zone}` labels;
- `pools.<name>` — pool handoff facts (scope, delivery mode, blocks,
  serviceSelector) from the pools resolution; the phase-5 fleet-routing
  service consumes these.

The fleet-wide assertions (duplicate cluster names/ids, same-mesh-group
CIDR overlap, node-in-two-clusters across rke2+k3s, mesh-group transport
consistency) are computed from these exports as `clan.checks` by the
shared library's fleet-checks module — wire it into a consumer clan with
`clan.imports = [ <kube-cluster fleetChecksModule> ]` (this flake's own
clan and the eval-test clans already do). No secrets ever appear in
exports.
