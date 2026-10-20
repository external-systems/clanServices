# kubernetes (upstream)

The third public clanService: upstream Kubernetes bootstrapped with kubeadm
— the CNCF-sponsored bootstrapper, wrapped declaratively by the NixOS
module (`kubeadm init` / `kubeadm join`).

## Status: fully spec'd, Reserved (D23)

The service is specified to the same depth as `rke2` and `k3s`: same shared
library interfaces, same invariants, same rendering and GitOps pipeline.
Implementation is a Reserved phase that starts after the rke2/k3s core
stabilizes. This is a hard requirement for the project, not optional scope.

## Why it exists

- **CNCF posture (D24).** Together with k3s, it is a fully-CNCF distro
  path — every in-cluster component a CNCF project.
- **No distro layer exception.** Unlike rke2, there is no vendor-owned
  runtime in the stack.
- **Version policy (D34).** The artifact flake source-builds the last three
  minors at release tags, same as the other distros; kubelets lag the
  apiserver per upstream skew policy, and `kubeadm certs renew` covers
  manual leaf rotation.

When it lands, the private shared library renames from
`lib/rancher-cluster/` to `lib/kube-cluster/`.
