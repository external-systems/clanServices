# Multi-cluster

Clusters in the same mesh group form one Cilium ClusterMesh automatically —
mixed distros included. Add an instance to the group and peering is rendered
from exports; no CLI steps.

## Mesh groups

A mesh group is a set of mutually trusted cluster instances. The default
mesh group is all cluster instances; opting a cluster out separates its
trust domain. Every eligible cluster runs clustermesh-apiserver and mesh
certificates from first boot (a singleton's peer list is simply empty).
Peering is rendered into `clustermesh.config.clusters` from exports. The
datapath, Cilium profile, and `maxConnectedClusters` are uniform across the
mesh.

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

## Mirror Services and hub → spoke reachability (D30)

The hub cluster's Flux delivers workloads to spokes, which requires reaching
each spoke's kube-apiserver. The real `kubernetes.default` Service is never
touched. Instead, per spoke:

- The spoke renders a selectorless mirror Service `kube-api-<spoke>` with
  an EndpointSlice of its API endpoints (the same fan-in pattern as the
  ClusterMesh apiserver exposure, generalized), annotated
  `service.cilium.io/global: "true"`.
- The hub renders a same-named Service with no local backends; ClusterMesh
  merges the remote endpoints, so hub pods reach the spoke API through
  that ClusterIP.
- Hub CoreDNS rewrites `kubernetes.<spoke>.<meta.domain>` to
  `kube-api-<spoke>.<ns>.svc.cluster.local`, rendered from exports.
- A NetworkPolicy restricts access to the Flux namespaces.

Credentials are GitOps-owned kubeconfig Secrets via Sealed Secrets (D35).
The interim path is a documented token-minting runbook; the long-term path
is a clan-operator that mints and rotates spoke credentials (Reserved).

![Hub and spoke delivery](../assets/hub-spoke.svg)

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
