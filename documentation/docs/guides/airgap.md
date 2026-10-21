# Airgap operation

Airgap-ready is the tested default: every artifact a cluster needs is pinned
and local at boot.

## How it works

The artifact flake (`external-systems/pkgs`) is the only packaging input.
It pins every chart, image, and CRD, source-builds the distro runtimes
(RKE2/k3s at release tags, last three minors each — D34), and renders each
pinned chart with the canonical fleet profile at **update time**, committing
the rendered base manifests as source next to the version pins (D26).
Consumers read committed files, so clanServices evaluation never fetches
and never uses import-from-derivation. A clean-public-fetch proof and the
publish-freshness gate (published manifest ≡ fresh render, D29) are part
of the artifact checks.

Envoy Gateway ships as one atomic `gateway-envoy` component (EG chart +
envoy image + Gateway API/EG CRDs), airgap-locked with one upstream profile
for both distros (D2). The Flux distribution includes a
`flux-operator distro mirror`-style airgap set (SPEC.md §7, phase 2).

## Operating airgapped

- Boot with the defaults. There is one explicit opt-out switch for
  non-airgap operation.
- When you override artifact pins, provide complete replacement sets or
  additive lists — partial overrides are not a supported shape
  (SPEC.md §5.9).
- Secrets work the same as online: clan vars for the bootstrap plane,
  Sealed Secrets (with the offline public sealing cert) for the application
  plane. See [Secrets](secrets.md).

## Test fixtures

Airgap extends to the test rigs: go-httpbin is the standard HTTP/HTTPS
workload (pinned and airgap-carried), Caddy is the QUIC-passthrough server
fixture, and the HTTP/3 test client is built from nixpkgs `curlHTTP3` via
`dockerTools` — never third-party images (SPEC.md §6).
