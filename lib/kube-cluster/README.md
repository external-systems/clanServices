# `lib/kube-cluster` — shared cluster rendering library

This is a **private implementation library** for the public `rke2` and `k3s`
clan services. It is not a clan service itself and is not registered in
`clan.modules`. Services consume it via a relative import:

The [SPEC](../../SPEC.md) is the canonical cross-distro architecture, status,
and delivery record. Renamed from `lib/rancher-cluster/` in delivery phase 1
(SPEC.md D45).

```nix
kube = import ../../lib/kube-cluster { inherit lib; };
```

## Scope

The library covers the bootstrap + data-plane contracts (SPEC.md §3) only.
Day-2 in-cluster software (ingress/Gateway proxies, cert-manager, Sealed
Secrets, storage, GitOps controllers) is never rendered here (SPEC.md §3.3).

The library exposes:

- shared, JSON-serializable option interfaces for role-level and per-machine
  settings;
- the kubenix bootstrap-bundle renderer (`bundle.nix`), the pure-Nix
  YAML-subset parser that ingests the committed base manifest without IFD
  (`yaml.nix`), the pure CIDR overlap math (`cidr.nix`), and the per-node
  haproxy kube-apiserver load balancer renderer;
- eval-time cluster + pool assertions;
- distro-neutral clan vars generators (join tokens, cluster PKI, haproxy
  healthcheck material, admin kubeconfig);
- the NixOS fragment builders for the PKI sync units and the
  bootstrap-apply oneshot (distro-parameterized by TLS dir / unit names).

Distro-specific config (rke2 config.yaml vs k3s config), the distro NixOS
module wiring, and airgap tarball selection stay OUT of this library.

## API (`default.nix { lib }`)

| Attribute | Purpose |
|---|---|
| `interfaces.cluster` | Deferred module of shared role-level options. |
| `interfaces.node` | Deferred module of shared per-machine options. |
| `render.mkCiliumValues` | The canonical Cilium profile tree (tunnel VXLAN, KPR, multi-pool IPAM, Node IPAM default, MTU math) with `cilium.helmValues` folded in. |
| `render.mkBundle` | The kubenix bootstrap bundle (D26 layer 2 / D40): imports the artifact flake's committed Cilium manifest via the pure-Nix YAML-subset parser (`yaml.nix`, zero IFD), merges per-cluster variation into the typed resource tree (`cilium-config` ConfigMap data, KPR env, pod IP pool, LB pools, `coredns-custom`), validates post-merge invariants (`validateBundle`), and emits one multi-doc YAML + object list + config hash. |
| `render.mkLBService` | External-facing Service helper: ETP Local + `loadBalancerClass: io.cilium/lb-ipam` + manifest labels (invariants 5/6). |
| `render.mkHaproxyConfig` | Per-node haproxy kube-apiserver LB config, with an optional rke2 supervisor LB. |
| `render.mkManifestLabels` | §6.11 labels for all rendered resources (managed-by, cluster, component; config-hash is added per object by mkBundle). |
| `render.resolvePools` | D8 pool resolution: auto per-machine node pools (join /32+/128 + `poolBlocks`) plus declared cluster-global pools. |
| `assertions.mkClusterAssertions` | Eval-time assertions about cluster shape. |
| `assertions.mkPoolAssertions` | D8 pool assertions: block overlap (pure-Nix CIDR math, `cidr.nix`), scope⇒mode, floating candidate coverage, node-name collisions. |
| `mkBootstrapApply` | The bootstrap-apply oneshot fragment (bundle etc path + SSA apply unit, D40). |
| `vars.mkTokenGenerators` | Join token generators (`rancher-server-token-<instance>` / `rancher-agent-token-<instance>`). |
| `vars.mkPkiGenerator` | `rancher-pki-<instance>` — the pre-generated cluster CA tree. |
| `vars.mkHaproxyGenerator` | `rancher-haproxy-<instance>` — LB healthcheck client cert + stats password hash. |
| `vars.mkAdminKubeconfigGenerator` | `rancher-admin-kubeconfig-<instance>` — operator kubeconfig (server URL parameterized). |
| `nixos.mkPkiSync` | systemd service + path unit syncing the PKI vars into the distro TLS dir. |

## Vars layout (pre-generated PKI, zero user input)

All generators are `share = true` — one CA tree / token set per cluster
instance. Role placement is the distro service's job:

- **every node**: `rancher-server-token-*` / `rancher-agent-token-*` and
  `rancher-haproxy-*` (agents join and serve API traffic through their own
  haproxy; the healthcheck client cert deploys to all, 0400 owner haproxy);
- **servers only**: `rancher-admin-kubeconfig-*`. `rancher-pki-*` is declared
  on rke2 servers but only on k3s's initializing server (CA keys never leave
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

## distroDefaults

`distroDefaults.enable` (default `false`, SPEC.md D42) selects the distro
base: `false` = the rke2/k3s services pass the flags that disable the
distro's packaged add-ons (Traefik/ingress, metrics-server, local-storage,
snapshot controller) and the embedded helm-controller (the bootstrap bundle
replaced helm-controller delivery in phase 3) for a uniform minimal base;
`true` = the service refrains, so stock components deploy via the distro's
own machinery and are configured day-2 through its HelmChartConfig surface.
servicelb/klipper stays disabled in both modes — Cilium Node IPAM
(`nodeIPAM.enabled = true`, `defaultLBServiceIPAM = "nodeipam"`, D41) is the
classless LoadBalancer mechanism.
