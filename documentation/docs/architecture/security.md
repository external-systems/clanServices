# Security

## Hardened by default

The `rke2` service defaults to `profile: cis` (D25): Pod Security Admission
`restricted` cluster-wide (except `kube-system`), `protect-kernel-defaults`,
a dedicated etcd user/group, and CIS sysctls — the host prerequisites are
rendered by the NixOS module. Opt out explicitly with
`security.cis = false`. The upstream profile carries curated PSA and
NetworkPolicy exemptions for system components (Envoy Gateway,
cert-manager); tenants get a namespace-exemption runbook. k3s and the
upstream `kubernetes` distro get equivalent PSA defaults where the distro
supports them (there is no CIS profile off RKE2).

The firewall contract (SPEC.md §5.12): the API listens on the transport
only, public ports open only where a Service exposes them, mesh and BGP
traffic is restricted to expected peers, HTTP/3 opens UDP and TCP together,
and mirror Services are reachable only from Flux namespaces (D30). VM tests
assert positive connectivity *and* negative exposure.

## Secrets planes (D35)

Two planes, one rule of thumb: **if Kubernetes or Flux can rotate or serve
it, clan vars does not store it.**

- **Bootstrap plane (clan vars)** — cluster CAs, join tokens, admin
  kubeconfigs, per-cluster read-only kubeconfigs (D38), the fleet CA (D18),
  ClusterMesh CA and certs, Sealed-Secrets sealing keys, and the hub↔spoke
  Flux control-plane credentials (client-cert hub identities, D37 — the
  documented exception: clan is the issuer).
- **Application plane (GitOps + Sealed Secrets)** — external-dns provider
  keys and tenant secrets.

The read-only credential (D38) has a hard line: its ClusterRole
`cluster-readonly` is the built-in aggregated `view` role plus explicit
cluster-scoped reads, and it **never** includes `secrets` in any apiGroup
and never a write verb — renderer-fixed and VM-proven (positive and
negative). Read-only is not harmless, though: ConfigMaps, pod specs and
env values, and pod logs are deliberately visible and can carry sensitive
data. Hand read-only kubeconfigs out accordingly.

Public certificates are readable as public values; private material is
referenced by deployed paths only and never enters the Nix store. The full
workflow is in [Secrets](../guides/secrets.md).

## PKI and rotation (SPEC.md §5.10)

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

Deleting an instance from the inventory does **not** garbage-collect a
cluster. Cordon/drain, Node deletion, etcd member removal, and mesh cleanup
are documented runbooks. Disruptive changes — pools, CIDRs, ids, CA roots,
mesh membership — are reviewed operational changes, not incidental edits.

## Airgap

Airgap-ready is the tested default. Every artifact is pinned by the artifact
flake and local at boot; there is one explicit opt-out switch for
non-airgap operation, and overrides are complete replacement sets or
additive lists — no partial drift. See [Airgap operation](../guides/airgap.md).
