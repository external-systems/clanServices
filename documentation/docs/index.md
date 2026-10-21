# Kubernetes cluster clanServices

You declare machines and cluster instances in one `inventory.nix`. You get
working, secure, interconnected Kubernetes clusters — rke2, k3s, or upstream
kubeadm — that bootstrap themselves, network together, and manage themselves
from day two onward. No cloud provider required, no server rebuilds to change
an application.

## What you get

- **Clusters bootstrap themselves.** Declare a cluster and its machines; the
  clanServices handle identity, CIDRs, join tokens, certificates, and
  integrated transport. First boot produces a running cluster.
- **Secure by default.** Dual-stack everywhere, encrypted transport, RKE2
  CIS-hardened by default, secrets only through clan vars and Sealed Secrets
  — never in the Nix store.
- **GitOps day two.** A hub cluster runs the Flux control plane and pushes
  workloads to spoke clusters — spokes run no Flux at all. Standalone
  clusters run their own Flux. Either way, tenant changes are git commits,
  not NixOS rebuilds.
- **Multi-cluster networking built in.** Clusters mesh automatically
  (Cilium ClusterMesh), share a private BGP-routed fleet fabric, and expose
  a default pair of gateways — one public, one private — with one IP
  serving HTTPS, TLS passthrough, mTLS, and HTTP/3 simultaneously.
- **Airgap-capable.** An artifact flake pins every chart, image, and CRD and
  source-builds the last three Kubernetes minors of each distro. Everything
  is local at boot; no internet fetch is required.

![Architecture overview](assets/arch-overview.svg)

## For engineers

The paragraph above is the marketing version. The engineering version —
thin distro services over a shared library, Cilium networking-only, Envoy
Gateway, the BIRD/BGP fabric, Flux day two, and the artifact flake — is in
[Architecture → Overview](architecture/overview.md). Every normative choice
is recorded in the [decision record](decisions/index.md) (D1–D35), and
[SPEC.md](https://github.com/external-systems/clanServices/blob/main/SPEC.md)
in the repo root is the agent-facing contract this site renders for humans.
