# Secrets

One plane, one rule of thumb: **if Kubernetes or GitOps can rotate or serve
it, clan vars does not store it** — unless clan is the issuer, in which case
vars is the only declarative source (D35).

## Bootstrap plane — clan vars

Clan vars own the secrets a cluster needs to exist and be reached — nothing
else:

- cluster CAs and join tokens
- admin kubeconfigs
- per-cluster read-only kubeconfigs (D38)
- ClusterMesh CA and certificates
- HAProxy health-check material (§6.6)
- `gitops-hub` control-domain identities (D43)

Private material is referenced by deployed paths only — never in the Nix
store. Public certificates are readable as public values.

Generate machine secrets with `clan vars generate <machine>` after changing
membership, as usual. An eval lint rejects clan vars generators declared for
application-plane secrets (D35), so plane violations fail before anything
deploys.

!!! note "Sealing keys left the vars plane in round 13"
    Sealed Secrets is wholly day-2, **keys included**. The sealing keypair
    history lives in your own custody (see the
    [Day-2 GitOps guide](day-2-gitops.md)), not in clan vars.

### Read-only kubeconfigs for AI agents (D38)

Every cluster mints a read-only, no-secrets identity
(CN=`readonly-<instance>`, O=`cluster-readers`) whose kubeconfig deploys
alongside the admin kubeconfig on server machines. To hand one to an AI
agent operating outside the cluster, run
`clan vars get <machine> <generator>` for the cluster's
`cluster-readonly-<instance>` generator and pass the kubeconfig to the
agent. It can list and read everything except Secrets — the hard line — but
ConfigMaps, pod specs/env, and logs remain visible, so treat it as sensitive
anyway. On a hub, each spoke's read-only kubeconfig is also available
in-cluster as Secret `kubeconfig-readonly` in `gitops-spoke-<spoke>`.

### The `gitops-hub` identities (D43)

Hub↔spoke control-plane credentials are **bootstrap plane**: they are
control-plane secrets, clan is the issuer (the hub identity cert is signed
by the spoke's cluster CA through a dependent vars generator
`gitops-hub-client-<spoke>`), and delivery happens at bootstrap via
secret-sync into the hub's per-spoke namespace `gitops-spoke-<spoke>`.
Rotation is `clan vars generate --regenerate` plus a secret-sync re-apply;
spokes are unaffected because the CA is unchanged. Manual SA-token
extraction is the documented emergency runbook only.

## Application plane — your GitOps repos

Everything in-cluster that an application or operator consumes — external-dns
provider keys, tenant secrets, Sealed-Secrets sealing keys — lives in your
GitOps repos, typically as Sealed Secrets. None of it is clan vars
generators. The recipes are in the [Day-2 GitOps guide](day-2-gitops.md).

## Certificate rotation runbooks

- **Leaf certificates** — 365-day upstream lifetime, renewed at startup;
  manual rotation with `rke2 certificate rotate` / `k3s certificate rotate`
  (kubeadm: `kubeadm certs renew`). No blanket 100-year leaf default.
- **CA rotation** — staged directory plus `rotate-ca`. Rotating to the same
  root can be non-disruptive; rotating to a new root is disruptive — tokens,
  kubeconfigs, and restarts. Service-account signing keys are append/retain.
- **Client-identity certs** (`gitops-hub`, read-only) — regenerate via
  `clan vars generate --regenerate` plus secret-sync re-apply; clusters are
  untouched (same CA).
- **ClusterMesh CA** — a separate two-phase CA-bundle design; blind
  regeneration is unsupported.
- **Node/cluster removal** — inventory deletion does not garbage-collect:
  cordon/drain, delete the Node objects, remove etcd members, clean up mesh
  peering, and remove the spoke's kubeconfig Secret and ClusterRoleBinding
  from the hub.
