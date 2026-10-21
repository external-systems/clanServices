# Upstream references

The upstream facts the spec depends on (SPEC.md §10). When upstream changes,
check these first.

- **Cilium 1.20** — LB IPAM, BGP v2, ClusterMesh (global Services with
  `service.cilium.io/global|shared|affinity`, EndpointSlice sync). Known
  Gateway gaps behind D1: no HTTP/3 (cilium#28497), no multi-Gateway IP
  sharing (cilium#25567), no mTLS (GEP-91). No BFD. Configuration via the
  rendered `cilium-config` ConfigMap (the D26 layer-2 override seam).
- **Kubenix** (hall/kubenix) — helm inflation via
  `kubernetes.helm.releases` is IFD at eval, which is why it lives in pkgs
  at update time; patching chart output by re-declaring rendered objects in
  the typed resource tree is the D26 layer-2 mechanism; includeCRDs
  discipline.
- **Envoy Gateway** (gateway.envoyproxy.io) — deployment modes including
  DaemonSet, mergeGateways, EnvoyProxy customization (`envoyService` —
  labels/annotations only, never annotate the managed Service directly),
  ClientTrafficPolicy (mTLS, HTTP/3; known bug envoyproxy/gateway#9798:
  http3+proxyProtocol on one ClientTrafficPolicy produces an invalid QUIC
  listener), ETP Local default. Kubernetes support matrix at v1.9:
  1.33–1.36 (feeds the D34 warning gate).
- **Gateway API** — GEP-91 (client certificate validation) is experimental;
  until it lands, EG policy CRDs carry mTLS (D4).
- **Flux** — the flux-operator fleet model: flux-operator#624 closed
  not_planned, FluxInstance is local-only (motivates D28 per-cluster
  bootstrap). Remote delivery via
  `Kustomization/HelmRelease.spec.kubeConfig.secretRef`. Airgap via
  `flux-operator distro mirror`. Helm ownership metadata makes HelmRelease
  adoption of non-helm-installed resources impossible — why D29 uses the
  Kustomization handoff.
- **external-dns** (kubernetes-sigs) — provider model (GoDaddy, Cloudflare,
  RFC2136). The CoreDNS provider requires an etcd backend the clusters do
  not run — rejected for inter-cluster DNS (D31).
- **OLM v1** (operator-controller) — ClusterExtension/ClusterCatalog;
  OpenShift-only airgap documentation; catalog coverage gaps. Rejected
  (D32) with revisit criteria recorded.
- **RKE2 hardening** — `profile: cis` (v1.29+), PSA restricted, host
  sysctl and etcd-user prerequisites (D25).
- **Kubernetes version skew** — kubelets may lag the apiserver up to three
  minors (motivates D34).
- **BIRD 2** — the vendored named-fragment rendering pattern (D19);
  NuschtOS/bird.nix was reviewed and not adopted.
- **Mozilla trust stores** — `security.enterprise_roots.enabled` is
  Windows/macOS-only; on Linux use the enterprise `Certificates.Import`
  policy or per-profile NSS (zen-browser is Firefox-based) (D18).
- **Test fixtures** — go-httpbin (github.com/mccutchen/go-httpbin) is the
  standard airgapped HTTP/HTTPS VM-test workload; Caddy is the
  QUIC-passthrough server fixture; nixpkgs `curlHTTP3` is the HTTP/3 test
  client.
