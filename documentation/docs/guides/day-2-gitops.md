# Day-2 GitOps

Everything in-cluster beyond the two contracts is yours: installed and owned
by your GitOps repos, never clan-rendered (D39). This page collects the
recipes. Each assumes the bootstrap bundle has run (D40) and your GitOps
controller of choice is installed by you.

## Take over the Cilium bundle

The bootstrap bundle is published to your GitOps repo as the identical
rendered manifest set. Adopt it; the first reconcile is a no-op by
construction (identical bytes, one Nix source). Upgrades afterwards flow
pkgs bump → rebuild → republish → GitOps applies.

### With Flux

Point a Kustomization with prune on at the published set:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cilium-bootstrap
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/prod/bootstrap
  prune: true
  sourceRef:
    kind: GitRepository
    name: fleet
```

Flux prune garbage-collects only the Kustomization's own
`.status.inventory`, so adopting the pre-applied objects is safe.

### With Argo CD

Adopt by resource tracking: apply the published set through an Application
whose source is the same directory; Argo labels/annotates the existing
objects with its tracking metadata and takes ownership without recreating
them.

### HelmRelease variant

HelmRelease adoption of the bootstrap bundle is impossible — there is no
helm release storage to adopt. If you want HelmRelease ownership of Cilium,
bootstrap with plain `helm install` from the pinned chart yourself (the
Flux-maintainer-recommended pattern), then manage upgrades with a
HelmRelease. Do not use the `cilium` CLI: its environment-autodetected
values and cert-generation mode skew make parity fragile (D40).

## Envoy Gateway

Envoy Gateway is the recommended day-2 ingress/Gateway implementation
(D2 revoked as clan surface; the recipe survives). Install it from your
GitOps repo with the pinned chart of your choice, then:

- Run the data plane as a **DaemonSet** EnvoyProxy on labeled worker
  machines with `externalTrafficPolicy: Local` (the EG default). ETP Local
  is safe with Node IPAM: real backends produce real EndpointSlices, and the
  Cilium dummy-Endpoints caveat only affects Cilium's own Gateway/Ingress,
  which stay disabled (D1/D41).
- Draw addresses through pools: set `loadBalancerClass: io.cilium/lb-ipam`
  plus pool-label selectors, or explicit `lbipam.cilium.io/ips` projections,
  on the EnvoyProxy `envoyService` labels/annotations — never annotate the
  controller-managed Service directly.
- Keep **one proxy implementation per IP:port**. SNI demuxes TCP/443
  (terminate, passthrough, mTLS) on one address, but QUIC terminate and QUIC
  passthrough never share an address — raw UDP has no demux key. Give a
  QUIC-passthrough listener its own VIP.

The wildcard target of the `<instance>.<meta.domain>` private zone (D22) is
whatever proxy you install here; the zone and its VIP exist regardless.

## cert-manager, external-dns, Sealed Secrets

All three are ordinary GitOps-managed installs:

- **cert-manager** — install from your repo; issue whatever in-cluster
  certificates you need. Clan renders no certificates beyond the bootstrap
  plane.
- **external-dns** — deploy per cluster against authoritative providers
  only (GoDaddy, Cloudflare, RFC2136). Provider credentials are Secrets in
  your GitOps repo (sealed), never clan vars. Do not use external-dns for
  inter-cluster DNS — ClusterMesh plus the D22 private zones cover private
  naming.
- **Sealed Secrets** — install the controller from your repo and own the
  **sealing-key custody yourself** (D35 revised): back up the keypair
  history in your own secret store, retain old keys so existing
  SealedSecrets keep decrypting across rotation. Seal with `kubeseal`
  against the cluster's public cert, commit the SealedSecret, let GitOps
  apply it. The unsealed Secret exists only inside the cluster.

## Provider CCMs

Set `cloudController = external` on the cluster instance: the clanService
renders the day-1 boot config (kubelet args, the uninitialized-taint flow)
and nothing else. Deploy the provider CCM itself (hcloud, and friends) from
your GitOps repo. The default `cloudController = none` fits bare metal;
`rancher` keeps the distro's bundled cloud handling.

## Floating-IP movers

Floating pools (D8) need a runtime controller that moves the address to one
machine at a time. The reference implementation is the
hcloud-ip-floater pattern — but the upstream project is effectively
unmaintained (last non-dependabot commit 2023), so treat it as a **fork
reference only**: fork it, pin it, own it. Clan asserts pool shape and
candidate coverage; failover timing is the controller's contract, including
its blackhole window.

## Stock Traefik via distroDefaults

If you want the distro's packaged defaults instead of the minimal base, set
`distroDefaults.enable = true` on the rke2/k3s service (D42). The distro's
own helm-controller then deploys stock Traefik (and optional Multus), and
you configure it through the distro's own HelmChartConfig surface — your
day-2 concern, not clan's. Traefik's classless LoadBalancer Service gets
node IPs from Node IPAM automatically; servicelb stays off in both modes.
Most fleets should leave `distroDefaults.enable = false` and run Envoy
Gateway via GitOps instead.

## Flux hub/spoke wiring

On a hub/spoke control domain (D43), clan has already rendered the
substrate: per-spoke namespace `gitops-spoke-<spoke>` on the hub holding
Secrets `kubeconfig` and `kubeconfig-readonly`, and in-spoke RBAC for group
`gitops-hub`. You install Flux on the hub only and wire every spoke-bound
object to the remote cluster:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: gitops-spoke-east
spec:
  interval: 10m
  path: ./clusters/east/apps
  prune: true
  kubeConfig:
    secretRef:
      name: kubeconfig
  sourceRef:
    kind: GitRepository
    name: fleet
```

Order the hub tree with `dependsOn` as **tenants → infra-controllers →
infra-configs → apps**, with per-spoke overlays under
`clusters/<spoke>/` — the flux2-hub-spoke-example convention. Spokes run no
Flux at all; the hub's controllers reconcile into them through the mirror
Service DNS name embedded in the kubeconfig. Use the
`kubeconfig-readonly` Secret for hub-resident tooling and AI agents that
need fleet-wide read access without admin keys (D38).
