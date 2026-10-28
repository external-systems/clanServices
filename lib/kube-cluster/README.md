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

Both distro services consume the generic `node_transport` schemaVersion 2
(SPEC.md D58) — stable dual-stack node addresses, per-interface MTU keyed
by Linux name, one `directRoutingDevice`, `datapath.mode native|tunnel`
(+ protocol), native `routeExchange = local-router`, and the
`internalLoadBalancer`/`nodePort` exposure capabilities — and never branch
on provider service names. The schema is declared by the transport
services, not by this library. The Cilium profile (mode, protocol,
devices, MTU) derives from the transport; admin overrides cannot
contradict the derived values. Shared fabric/FRR/facts helpers
(`fabric.nix`, `frr.nix`, `network-facts.nix`) are imported directly by
`routed-fabric`; they are not part of the `default.nix` attrset below.

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
| `interfaces.node` | Deferred module of shared per-machine options (incl. `topology.region`/`zone`, invariant 7). |
| `interfaces.kube_cluster` | The custom export interface (§6.2, D45) published by both distro services. |
| `hashCiliumId` / `resolveCiliumId` | Stable sha256-based hash of the instance name → 1–127 (pure Nix, no IFD); resolution of the nullable `cilium.id` pin. |
| `render.mkCiliumValues` | The canonical Cilium profile tree (datapath mode derived from `node_transport` — native or tunnel/VXLAN; KPR, multi-pool IPAM, Node IPAM default, MTU math: native = minimum interface MTU, VXLAN = minimum minus 50, D58) with `cilium.helmValues` folded in. |
| `render.resolveCidrs` | Resolved dual-stack CIDR structure from the resolved id + explicit overrides (combined strings, per-family components, clusterDNS). |
| `render.mkBundle` | The kubenix bootstrap bundle (D26 layer 2 / D40): imports the artifact flake's committed Cilium manifest via the pure-Nix YAML-subset parser (`yaml.nix`, zero IFD), merges per-cluster variation into the typed resource tree (`cilium-config` ConfigMap data, KPR env, pod IP pool, LB pools, `coredns-custom`), validates post-merge invariants (`validateBundle`), and emits one multi-doc YAML + object list + config hash. |
| `render.mkLBService` | External-facing Service helper: ETP Local + manifest labels; explicit pool draws default to `io.cilium/bgp-control-plane` so they bypass the classless Node-IPAM default (invariants 5/6). |
| `render.mkHaproxyConfig` | Per-node haproxy kube-apiserver LB config, with an optional rke2 supervisor LB. |
| `render.mkManifestLabels` | §6.11 labels for all rendered resources (managed-by, cluster, component; mkBundle adds a per-object `clan.lol/config-hash` label — first 32 hex chars of the full sha256, since Kubernetes label values cap at 63 bytes; the full hash stays on the bundle's `configHash` output). |
| `render.resolvePools` | D8 pool resolution: auto per-machine node pools (join /32+/128 + `poolBlocks`) plus declared cluster-global pools and `extraPools` (the fabric pool). |
| `resolveDataPlane` | Phase-5 seam (D9/D10/D19/D22): ASNs, fabric pool, shared-bgp sets, the mkBundle `bgp` params, and the export facts — one resolution shared by bundle, assertions, and export. (The legacy `privateCoreDNS` bundle params are removal-planned with the day-2 member-DNS work, SPEC.md D22.) The per-cluster routing-daemon text is FRR, rendered by `routed-fabric` via `frr.nix`; this lib renders ONLY Cilium-side BGP v2 resources and publishes the facts routed-fabric consumes (D19). |
| `bgp.hashBgpAsns` / `bgp.resolveBgpAsns` | Deterministic private 32-bit ASN pairs per cluster (sha256 of salted instance name → RFC 6996 range; pins override). |
| `bgp.mkFabricPool` / `bgp.fabricBlocks` | The default private fabric pool (D10): `172.16.<id>.0/24` + `fd11:<id>::/64`; internal ClusterMesh VIPs are pinned at host offset 79 / 0x79 (D60). |
| `bgp.mkBgpResources` | The BGP v2 CR set (ClusterConfig per node, PeerConfig timers 9/3/5, Advertisements; D13 opt-ins). |
| `assertions.mkClusterAssertions` | Eval-time assertions about cluster shape (clusterInit count, addresses, resolved-id uniformity, id>127 ⇒ explicit v4 CIDRs, all-or-none transport posture, topology non-empty). |
| `assertions.mkPoolAssertions` | D8 pool assertions: block overlap (incl. against pod/service CIDRs), scope⇒mode, floating coverage, node-name collisions, bgp.enable⇔shared-bgp coupling, fabric block size (§6.12). |
| `mkFleetChecks` / `fleetChecksModule` | Fleet-wide assertions (§6.2) computed from the `kube_cluster` exports as `clan.checks`: duplicate names/ids, same-group CIDR overlap, node-in-two-clusters (D16, cross-service), mesh-group transport consistency. Wire into a clan with `clan.imports = [ kube.fleetChecksModule ]`. |
| `mkBootstrapApply` | The bootstrap-apply oneshot fragment (bundle etc path + SSA apply unit, D40). |
| `mkImageDigestAliases` | Per-node oneshot tagging each preloaded pinned image under its `name@digest` alias — the bundle references images digest-pinned, and containerd's CRI resolves digested references only via that canonical alias (offline airgap would otherwise ImagePullBackOff). |
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

`cilium.id` is nullable: when unset, the resolved id is a stable hash of the
instance name mapped into 1–127 (first 8 hex chars of sha256(instanceName),
mod 127, +1 — pure Nix, no IFD). An explicit id above 127 requires explicit
v4 CIDRs (the derived space overflows the /8). **Migration**: deployments
predating the hashed default must pin their current `cilium.id` (and v4
CIDRs when > 127) before upgrading — the resolved id drives CIDRs,
clusterDNS, and the HAProxy ports (`7442 + id`, `+1000`).

When `network.podCIDRv4`/`podCIDRv6`/`serviceCIDRv4`/`serviceCIDRv6` are
`null`, the library derives them from the resolved id:

- pods: `10.<2id-1>.0.0/16` + `fd10:<2id-1>::/56`
- services: `10.<2id>.0.0/16` + `fd10:<2id>::/112`
- cluster DNS: `10.<2id>.0.10` (the 10th address of an explicit service v4
  CIDR when one is pinned)

This lets multiple clusters share one transport when their ids differ (the
ClusterMesh groundwork: unique ids ⇒ non-overlapping CIDRs; meshing itself
is a later phase). Resolved-id collisions between instances are a fleet-wide
eval error (`mkFleetChecks`).

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
