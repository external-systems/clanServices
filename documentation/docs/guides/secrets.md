# Secrets

Two planes, one rule of thumb: **if Kubernetes or Flux can rotate or serve
it, clan vars does not store it** — unless clan is the issuer, in which case
vars is the only declarative source (D35).

## Bootstrap plane — clan vars

Clan vars own the secrets a cluster needs to exist: cluster CAs, join
tokens, admin kubeconfigs, the fleet CA (D18), ClusterMesh CA and
certificates, and the Sealed-Secrets sealing keys (vars keeps custody of
the sealing keypair history). Private material is referenced by deployed
paths only — never in the Nix store. Public certificates are readable as
public values.

Generate machine secrets with `clan vars generate <machine>` after changing
membership, as usual.

### The D37 exception: hub identity certificates

Hub↔spoke Flux control-plane credentials are **bootstrap plane**, not
application plane. They are control-plane secrets, clan is the issuer (the
hub identity cert is signed by the spoke's cluster CA through a dependent
vars generator), and delivery happens at bootstrap via secret-sync into the
hub's per-spoke namespace `flux-spoke-<spoke>`. Rotation is
`clan vars generate --regenerate` plus a secret-sync re-apply; spokes are
unaffected because the CA is unchanged. Manual SA-token extraction is the
documented emergency runbook only.

## Application plane — GitOps + Sealed Secrets

Everything in-cluster that an application or operator consumes lives in the
GitOps repo as Sealed Secrets:

- external-dns provider credentials — GoDaddy/Cloudflare API keys, RFC2136
  keys (D31). Never clan vars generators.
- Tenant secrets of any kind.

## Sealed Secrets workflow

Sealed Secrets is off by default but **required** before the first
GitOps-owned secret — on spokes too, where the hub applies SealedSecrets
remotely (D36). Key management modes:

- **`clan-vars`** (default when enabled) — a persistent keypair owned by
  the bootstrap plane. The public sealing cert is available offline, native
  renewal is disabled, and old keys are retained so existing SealedSecrets
  keep decrypting across rotation.
- **`controller`** — the native Sealed Secrets key lifecycle, plus a
  documented backup runbook.

Sealing keys are never rendered as a plain cert-manager Certificate.

To add an application secret: seal it against the cluster's public cert
(`kubeseal`), commit the SealedSecret to the GitOps repo, and let Flux
apply it (the hub applies it for spokes). The unsealed Secret exists only
inside the cluster.

An eval lint rejects clan vars generators declared for application-plane
secrets (D35), so plane violations fail before anything deploys.
