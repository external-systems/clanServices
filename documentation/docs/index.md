# Kubernetes cluster clanServices

You declare machines and cluster instances in one `inventory.nix`. You get
working, secure, interconnected Kubernetes clusters — rke2, k3s, or upstream
kubeadm — whose **bootstrap** and **data plane** are a verifiable contract.
Everything else in-cluster — ingress, certificates, storage, the GitOps
controller itself — is a documented day-2 pattern your GitOps repos own,
never something clan renders.

## The two contracts

- **Bootstrap contract — the cluster exists and is reachable.** Distro
  install/join for rke2, k3s, and (reserved) kubeadm `kubernetes`; cluster
  PKI with documented rotation runbooks; per-node HAProxy kubeapi HA with the
  join URL pointed at it; and one kubenix-rendered bootstrap bundle applied
  once via server-side apply on the first server. RKE2 is CIS-hardened by
  default. Every cluster mints a read-only, no-secrets kubeconfig your AI
  agents can use.
- **Data-plane contract — packets flow correctly.** Cilium-only networking
  (kube-proxy replacement, native routing, multi-pool pod IPAM), Node IPAM
  for classless LoadBalancer Services, LB-IPAM pools with BGP v2 and
  per-node FRR/Zebra, a private fleet fabric on by default, native
  ClusterMesh, one host WireGuard interface per node pair, private CoreDNS
  zones, and routed fleet access for Kubernetes and ordinary machines.

## Day 2 is yours

Clan never installs a GitOps controller. Clusters run standalone or form
hub/spoke control domains: clan mints the kubeconfigs, RBAC, and API mirror
Services that let any GitOps tool manage spokes from a hub — which tool runs
on the hub is your repo's decision. After bootstrap, your GitOps adopts the
identical published Cilium manifest set, so the first reconcile is a no-op
by construction, and owns everything else: Envoy Gateway, cert-manager,
external-dns, Sealed Secrets, storage, CCMs. The recipes are in the
[Day-2 GitOps guide](guides/day-2-gitops.md).

## What you also get

- **Secure by default.** Dual-stack everywhere, host WireGuard transport,
  secrets only through clan vars on the bootstrap plane — never in the Nix
  store.
- **Airgap-capable.** An artifact flake pins the distro runtimes (last three
  Kubernetes minors each), the Cilium chart with its committed inflated base
  manifest, and the test fixtures. Everything is local at boot.

## For engineers

The engineering version — thin distro services over a shared library, the
bootstrap bundle and its GitOps handoff, Node IPAM and the FRR/native
fabric, and the artifact flake — is in
[Architecture → Overview](architecture/overview.md). Every normative choice
is recorded in the [decision record](decisions/index.md) (D1–D50), and
[SPEC.md](https://github.com/external-systems/clanServices/blob/main/SPEC.md)
in the repo root is the agent-facing contract this site renders for humans.
