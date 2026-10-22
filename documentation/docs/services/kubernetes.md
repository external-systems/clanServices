# kubernetes (upstream)

The third public clanService: upstream Kubernetes bootstrapped with kubeadm
— the CNCF-sponsored bootstrapper, wrapped declaratively by the NixOS
module (`kubeadm init` / `kubeadm join`).

## Status: fully spec'd, Reserved (D23)

The service is specified to the same depth as `rke2` and `k3s`: same shared
library interfaces, same invariants, same bootstrap-bundle delivery and
data-plane contract. Implementation is a Reserved phase that starts after
the rke2/k3s core stabilizes. This is a hard requirement for the project,
not optional scope.

## Why it exists

- **CNCF posture (D24).** Together with k3s, it is a fully-CNCF distro
  path — every clan-rendered in-cluster component a CNCF project.
- **No distro layer exception.** Unlike rke2, there is no vendor-owned
  runtime in the stack.
- **Version policy (D34).** The artifact flake source-builds the last three
  minors at release tags, same as the other distros; kubelets lag the
  apiserver per upstream skew policy, and `kubeadm certs renew` covers
  manual leaf rotation.

## Distro notes

- **No `distroDefaults` knob.** Upstream Kubernetes ships no packaged
  add-ons, so there are no distro defaults to restore (D42) — which keeps
  the minimal base honest across all three distros.
- **Same control domain.** `controlDomain.role = standalone | hub | spoke`
  (D43) applies unchanged; clan renders the GitOps-neutral substrate and
  never installs a GitOps controller.

The private shared library is already renamed `lib/kube-cluster/` at spec
level (D45) because it serves all three distros; the code rename lands with
delivery phase 1.
