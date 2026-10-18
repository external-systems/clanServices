# `lib/rancher-cluster` — shared cluster rendering library

This is a **private implementation library** for the public `rke2` and `k3s`
clan services. It is not a clan service itself and is not registered in
`clan.modules`. Services consume it via a relative import:

The [Rancher clanServices specification](../../services/rancher-cluster-spec.html)
is the canonical cross-distro architecture, status, and delivery record.

```nix
rancher = import ../../lib/rancher-cluster { inherit lib; };
```

## Scope

The library exposes:

- shared, JSON-serializable option interfaces for role-level and per-machine
  settings;
- pure render functions for Cilium, Traefik, cert-manager, CoreDNS, and the
  per-node haproxy kube-apiserver load balancer;
- eval-time cluster assertions;
- distro-neutral clan vars generators (join tokens, cluster PKI, haproxy
  healthcheck material, admin kubeconfig, Sealed Secrets keypair);
- NixOS fragment builders for the PKI sync and secret-manifest sync units
  (distro-parameterized by TLS dir / manifests dir / unit names).

Distro-specific config (rke2 config.yaml vs k3s config), the distro NixOS
module wiring, and airgap tarball selection stay OUT of this library.

## API (`default.nix { lib }`)

| Attribute | Purpose |
|---|---|
| `interfaces.cluster` | Deferred module of shared role-level options. |
| `interfaces.node` | Deferred module of shared per-machine options. |
| `render.mkCiliumValues` | Cilium helm values (tunnel VXLAN, KPR, multi-pool IPAM, MTU math). |
| `render.mkCiliumManifests` | `CiliumPodIPPool` CR (LB-IPAM/BGP left to later phases). |
| `render.mkTraefikInstances` | Resolve raw `traefik.instances` into normalized instances. |
| `render.mkTraefikValues` | Helm values for one resolved Traefik instance. |
| `render.mkTraefikManifests` | Gateway, Certificate, and NetworkPolicy manifests. |
| `render.mkCertManagerManifests` | selfsigned CA bootstrap + user Certificate CRs. |
| `render.mkCoreDNSValues` | coredns chart values for custom rewrite support. |
| `render.mkCoreDNSManifests` | `coredns-custom` ConfigMap manifest. |
| `render.mkHaproxyConfig` | Per-node haproxy kube-apiserver LB config, with an optional rke2 supervisor LB. |
| `render.mkManifestLabels` | Common labels for all rendered resources. |
| `assertions.mkClusterAssertions` | Eval-time assertions about cluster shape. |
| `vars.mkTokenGenerators` | Join token generators (`rancher-server-token-<instance>` / `rancher-agent-token-<instance>`). |
| `vars.mkPkiGenerator` | `rancher-pki-<instance>` — the pre-generated cluster CA tree. |
| `vars.mkHaproxyGenerator` | `rancher-haproxy-<instance>` — LB healthcheck client cert + stats password hash. |
| `vars.mkAdminKubeconfigGenerator` | `rancher-admin-kubeconfig-<instance>` — operator kubeconfig (server URL parameterized). |
| `vars.mkSealedSecretsGenerator` | `rancher-sealed-secrets-<instance>` — pre-generated signing keypair. |
| `nixos.mkPkiSync` | systemd service + path unit syncing the PKI vars into the distro TLS dir. |
| `nixos.mkSecretManifestSync` | systemd service + path unit syncing a secret var file into the manifests dir. |

## Vars layout (pre-generated PKI, zero user input)

All generators are `share = true` — one CA tree / token set / keypair per
cluster instance. Role placement is the distro service's job:

- **every node**: `rancher-server-token-*` / `rancher-agent-token-*` and
  `rancher-haproxy-*` (agents join and serve API traffic through their own
  haproxy; the healthcheck client cert deploys to all, 0400 owner haproxy);
- **servers only**: `rancher-admin-kubeconfig-*` and
  `rancher-sealed-secrets-*` when enabled. `rancher-pki-*` is declared on
  rke2 servers but only on k3s's initializing server (CA keys never leave
  the control plane).

`rancher-pki-<instance>` produces a root CA + intermediate CA (both
`deploy = false` — generator inputs only) and the leaf CAs the distro
consumes (`server-ca`, `client-ca`, `request-header-ca`, `etcd-peer-ca`,
`etcd-server-ca`, `service.key`); leaf `.crt` files are full chains. RKE2
installs them with `nixos.mkPkiSync` before the server unit starts. k3s
uses an init-only, non-destructive seed in its public service; joining
servers receive the CA through k3s bootstrap, and live rotation uses
`k3s certificate rotate-ca`.

The haproxy generator's public `password-hash-haproxy` is eval-consumed via
`clanLib.getPublicValue`; the public `kubeapi-ca.crt` is consumed via its
store path (it is a public certificate chain).

## The per-node haproxy LB

`render.mkHaproxyConfig` renders a TCP-mode haproxy config: frontends bound
to the node's OWN transport addresses (both families) on the derived LB
ports, backends = every server-role member's transport addresses targeting
the real apiserver port, with TLS `/readyz` healthchecks (`check check-ssl` —
checks over TLS, data stays raw TCP). RKE2 additionally enables the optional
supervisor frontend/backend; its healthcheck probes the real API port as the
anti-deadlock readiness signal. K3s sets `enableSupervisor = false` and uses
only the kube-apiserver LB. Servers list themselves plain and the remote
servers `backup`; agents list all servers plain. Stats page on the stats port
(default 8404) with the vars-rendered password hash.

## CIDR derivation

When `network.podCIDRv4`/`podCIDRv6`/`serviceCIDRv4`/`serviceCIDRv6` are
`null`, the library derives them from `cilium.id`:

- pods: `10.<2id-1>.0.0/16` + `fd10:<2id-1>::/56`
- services: `10.<2id>.0.0/16` + `fd10:<2id>::/112`
- cluster DNS: `10.<2id>.0.10`

This lets multiple clusters share one transport when their ids differ (the
ClusterMesh groundwork: unique ids ⇒ non-overlapping CIDRs; meshing itself
is a later phase).

## Traefik instances

The library is deliberately distro-neutral:

- `traefik.instances` defaults to `{}`. Distro services supply the default
  instance name (`rke2-traefik`, `k3s-traefik`, etc.).
- `namespace` defaults to the instance name.
- `service.loadBalancerClass` defaults to `null`; distros or external LB
  services set `io.cilium/node` when appropriate.
- `gatewayAPI.enabled` defaults to `false`; at most one instance per cluster
  may enable it.

The caller provides a `getChartSource` function so the resolved instance
records whether it renders as a `HelmChartConfig` (rke2 default instance)
or a standalone `HelmChart` CR (extras / k3s).

## Sealed Secrets

`sealedSecrets.enabled` (default `false`) renders: the
`rancher-sealed-secrets-<instance>` vars generator (4096-bit RSA keypair;
`tls.crt` is PUBLIC plaintext — the offline sealing key), the
secret-manifest sync of the `sealed-secrets-key` Secret into the distro's
manifests dir, and (in the distro service) the pinned sealed-secrets chart
with `keyrenewperiod = "0"` so the controller never rotates the vars-owned
key.
