# Security

## Hardened by default

The plan (D25, not yet the default): the `rke2` service defaults to
`profile: cis` — Pod Security Admission `restricted` cluster-wide (except
`kube-system`), `protect-kernel-defaults`, a dedicated etcd user/group, and
CIS sysctls — with a namespace-exemption runbook for tenants, and k3s and
the upstream `kubernetes` distro get equivalent PSA defaults where the
distro supports them. Today `profile = "cis"` is opt-in (default `null`)
and no suite runs it. Both distros encrypt Secrets at rest in etcd (rke2 by
default, k3s with `secrets-encryption: true`).

The firewall contract (SPEC.md §6.12): the API listens on the transport
only, public ports open only where a Service exposes them, mesh and BGP
traffic is restricted to expected peers, and mirror Services are reachable
only from GitOps namespaces (D30). The cluster ports open by source: the
API, the HAProxy LB ports, the kubelet and Cilium's health port to the
members' node addresses and the cluster's pod CIDRs, etcd to the servers
only; on a fabric only on the fabric links and the local pod links. A pod
reaches no other port of its node, and the cluster services never trust a
fabric link. VM tests assert positive connectivity *and* negative exposure
(`<distro>-single`: an outside host reaches no cluster port, a pod no
other host port).

A machine holds only the secrets its role reads: an agent has the agent
token and the HAProxy health-check certificate, never the server token or
the ClusterMesh keys (`<distro>-join`).

## Secrets planes (D35)

One rule of thumb: **if Kubernetes or GitOps can rotate or serve it, clan
vars does not store it** — unless clan is the issuer.

- **Bootstrap plane (clan vars)** — cluster CAs, join tokens, admin
  kubeconfigs, per-cluster read-only kubeconfigs (D38), ClusterMesh CA and
  certs, HAProxy health-check material, and the `gitops-hub` control-domain
  identities (D43).
- **Application plane (GitOps-owned)** — everything else, Sealed-Secrets
  sealing keys included. Sealed Secrets is wholly day-2, keys included;
  custody is the operator's GitOps repo, never clan vars. See the
  [Day-2 GitOps guide](../guides/day-2-gitops.md).

An eval lint rejects clan vars generators declared for application-plane
secrets, so plane violations fail before anything deploys.

The read-only credential (D38) has a hard line: its ClusterRole
`cluster-readonly` is the built-in aggregated `view` role plus explicit
cluster-scoped reads, and it **never** includes `secrets` in any apiGroup
and never a write verb — renderer-fixed and VM-proven (positive and
negative). Read-only is not harmless, though: ConfigMaps, pod specs and env
values, and pod logs are deliberately visible and can carry sensitive data.
Hand read-only kubeconfigs out accordingly.

Public certificates are readable as public values; private material is
referenced by deployed paths only and never enters the Nix store. The full
workflow is in [Secrets](../guides/secrets.md).

## PKI and rotation (SPEC.md §6.10)

Leaf certificates follow upstream defaults: 365-day lifetime, renewed at
startup, with manual rotation via `rke2 certificate rotate` /
`k3s certificate rotate` (kubeadm: `kubeadm certs renew`). There is no
blanket 100-year leaf default; a long-lived offline root is an explicit,
documented risk decision.

CA rotation is staged (staging directory + `rotate-ca`): rotating to the
same root can be non-disruptive; rotating to a new root is disruptive —
tokens, kubeconfigs, and restarts. Service-account signing keys are
append/retain. RKE2 PKI sync is non-destructive; k3s uses init-only seeding
plus native replication.

Client-identity certs — the `gitops-hub` identities (D43) and the read-only
credential (D38) — are 365-day vars-signed certificates: regenerate via vars
plus a secret-sync re-apply; clusters are untouched because the CA is
unchanged.

Deleting an instance from the inventory does **not** garbage-collect a
cluster. Cordon/drain, Node deletion, etcd member removal, mesh cleanup, and
hub kubeconfig/ClusterRoleBinding removal are documented runbooks.
Disruptive changes — pools, CIDRs, ids, CA roots, mesh membership — are
reviewed operational changes, not incidental edits.

## Airgap

Airgap-ready is the tested default. Every artifact is pinned by the artifact
flake and local at boot; there is one explicit opt-out switch for
non-airgap operation, and overrides are complete replacement sets or
additive lists — no partial drift. See [Airgap operation](../guides/airgap.md).
