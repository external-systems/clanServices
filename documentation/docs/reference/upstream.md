# Upstream references

The upstream facts the spec depends on (SPEC.md §11). When upstream changes,
check these first.

- **Cilium 1.20** — LB IPAM, Node IPAM
  (docs.cilium.io/en/latest/network/node-ipam/ — the ETP-Local EndpointSlice
  caveat affects only Cilium's own Gateway/Ingress, D41), BGP v2,
  ClusterMesh (global Services with
  `service.cilium.io/global|shared|affinity`, EndpointSlice sync). Known
  Gateway gaps behind D1: no HTTP/3 (cilium#28497), no multi-Gateway IP
  sharing (cilium#25567), no mTLS (GEP-91). No BFD. Configuration via the
  rendered `cilium-config` ConfigMap (the D26 layer-2 seam). Official
  install is Helm, cosign-signed digest-pinnable OCI charts; the chart ships
  no `crds/` dir — the operator manages CRDs at runtime, which is why
  manifest rendering loses nothing (D40).
- **Cilium bootstrap/handoff evidence (D40)** — Flux prune garbage-collects
  only the Kustomization's own `.status.inventory` (fluxcd.io Kustomization
  docs); SSA vs client-side-apply field-manager friction and the
  `--server-side` bootstrap avoidance (same docs + Flux FAQ); Argo CD
  adoption via tracking annotation/label (Argo resource-tracking docs); Flux
  maintainer on CNI takeover (fluxcd/flux2#3070); cilium-cli helm mode +
  value auto-detection + cert-mode skew (cilium-cli README, cilium-cli#300,
  and a documented crash-loop migration report).
- **Kubenix** (hall/kubenix) — helm inflation at update time is IFD at eval,
  which is why it lives in pkgs; patching chart output by re-declaring
  rendered objects in the typed resource tree is the D26 layer-2 mechanism;
  `includeCRDs = false` default loses nothing for Cilium.
- **Kubernetes RBAC** — the built-in aggregated `view` ClusterRole excludes
  Secrets by design (the basis of D38).
- **Kubernetes CCM** — the `--cloud-provider=external` uninitialized-taint
  flow; no Cilium-specific caveat (the agent tolerates `Exists`) (§6.11).
- **RKE2 hardening** — `profile: cis` (v1.29+), PSA restricted, host sysctl
  and etcd-user prerequisites (D25).
- **Kubernetes version skew** — kubelets may lag the apiserver up to three
  minors (motivates D34).
- **BIRD 2** — the vendored named-fragment rendering pattern (D19).
- **hcloud-ip-floater** (costela) — floating-IP mover reference; upstream
  effectively unmaintained (last non-dependabot commit 2023) —
  fork-don't-depend.
- **go-httpbin** (mccutchen) — the standard airgapped HTTP VM-test workload.
