# Multi-cluster

Clusters in the same mesh group form one Cilium ClusterMesh automatically —
mixed distros included. Add an instance to the group and peering is rendered
from exports; no CLI steps.

## Mesh groups and trust domains

A mesh group is a set of mutually trusted cluster instances — the trust
domain string (default `meta.domain`). The default mesh group is all
cluster instances; opting a cluster out separates its trust domain. The
trust domain also bounds flux control domains (D36): a hub and its spokes
must share one group. But mesh ≠ flux — standalone clusters can be full
mesh members with no flux relationship to anyone.

Every eligible cluster runs clustermesh-apiserver and mesh certificates
from first boot (a singleton's peer list is simply empty). Peering is
rendered into `clustermesh.config.clusters` from exports. The datapath,
Cilium profile, and `maxConnectedClusters` are uniform across the mesh.

The ClusterMesh apiserver stays node-bound (D12): it is exposed on node
mesh addresses (LoadBalancer, ETP Local, ClientIP affinity, all servers as
endpoints, anti-affinity; collision-checked NodePort as the escape hatch).
Consumers are mesh members with direct routes, so the control plane takes
the fewest dependencies.

Mesh identity comes from a shared `rancher-clustermesh-ca-<group>` vars
generator with per-cluster dependent cert generators. SANs include every
exported address; a membership change reissues certificates before the new
endpoint set is advertised. CA and cert material never appear in exports,
Helm values, or the Nix store. CA rotation is a separate two-phase
bundle design — blind regeneration is unsupported.

## Mirror Services (D30)

The real `kubernetes.default` Service is never touched. Any cluster can
export its kube-apiserver to mesh members — and for `flux.mode = "spoke"`
this export is **mandatory**, because the hub reconciles through it:

- The exporting cluster renders a selectorless mirror Service
  `kube-api-<cluster>` with an EndpointSlice of its API endpoints (the same
  fan-in pattern as the ClusterMesh apiserver exposure, generalized),
  annotated `service.cilium.io/global: "true"`.
- A consumer (the hub, admin tooling) renders a same-named Service with no
  local backends; ClusterMesh merges the remote endpoints, so consumer pods
  reach the remote API through that ClusterIP.
- Consumer CoreDNS rewrites `kubernetes.<cluster>.<meta.domain>` to
  `kube-api-<cluster>.<ns>.svc.cluster.local` — the human/tooling path.
- Kubeconfigs (D37) use the mirror DNS name directly as `server`, with no
  rewrite dependency; the cluster's API certificate SANs must include it
  (eval-asserted, deterministic at bootstrap).
- A NetworkPolicy restricts mirror-Service access to the Flux namespaces.

Mesh connectivity is symmetric: spokes reach the hub, and standalone mesh
members reach both, through the same global-service mechanism whenever they
export and consume mirror Services.

![Hub and spoke delivery](../assets/hub-spoke.svg)

## Hub credentials: client-cert identities (D37)

The hub authenticates to each spoke with a clan-minted client certificate
signed by the spoke's cluster CA — CN=`flux-hub-<spoke>`, O=`flux-hub`. The
spoke binds group `flux-hub` to `cluster-admin` by default (configurable),
with optional per-tenant impersonation ServiceAccounts. The kubeconfig
Secret lives in a per-spoke namespace `flux-spoke-<spoke>` on the hub,
delivered via secret-sync; spoke machines never see the client key. These
control-plane credentials are the D35 bootstrap-plane exception — clan is
the issuer, so vars is the only declarative source. Rotation is a vars
regenerate plus secret-sync re-apply; spokes are untouched.

## Global Services

ClusterMesh global Services are opt-in per Service; nothing becomes global
implicitly. The mirror Services above are clan-rendered globals. MCS-API is
reserved (disabled initially).

## Fleet CA and east-west mTLS (D18, D20)

A dedicated fleet root CA (shared vars generator, `share=true`) signs the
private Gateway certificates through cert-manager. Its private key only
leaves vars as the cluster's cert-manager CA-issuer Secret. Client and
admin machines install the CA into their system trust stores; Firefox-family
browsers (including zen-browser) get an enterprise `Certificates.Import`
policy rendered when such a browser module is detected — Linux does not
support `security.enterprise_roots.enabled`.

Fleet-wide east-west mTLS — the private Gateway validating client
certificates against the fleet CA — is the preferred path, gated on a VM
suite that proves accept/reject behavior and client-cert presentation
before it defaults on. Browser client-cert UX is poor, so mTLS is enforced
per listener/hostname for machine and admin endpoints while ordinary
browser endpoints stay terminate-only.
