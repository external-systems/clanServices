# Airgap operation

Airgap-ready is the tested default: every artifact a cluster needs is pinned
and local at boot.

## How it works

The artifact flake (`external-systems/pkgs`) is the only packaging input,
narrowed in round 13 to the two contracts (D44):

- **Distro runtimes** — RKE2/k3s source-built at release tags, the last
  three Kubernetes minors each (D34).
- **Cilium** — the pinned chart plus its committed inflated base manifest,
  rendered with the canonical fleet profile at **update time** and committed
  as source next to the version pins (D26), plus the Cilium image airgap
  set.
- **Test fixtures** — go-httpbin, pinned and airgap-carried.

Consumers read committed files, so clanServices evaluation never fetches and
never uses import-from-derivation. A clean-public-fetch proof and the
publish-freshness gate (published manifest ≡ fresh render, D40) are part of
the artifact checks.

Day-2 software — Envoy Gateway, cert-manager, Flux, external-dns, Sealed
Secrets, CCMs — is **not** in the artifact flake. Pin and carry it in your
own GitOps repos and registries if you run airgapped.

## Operating airgapped

- Boot with the defaults. There is one explicit opt-out switch for
  non-airgap operation.
- When you override artifact pins, provide complete replacement sets or
  additive lists — partial overrides are not a supported shape
  (SPEC.md §6.9).
- Secrets work the same as online: clan vars for the bootstrap plane only.
  Sealed Secrets (with the offline public sealing cert) is a day-2 install
  you operate yourself. See [Secrets](secrets.md).

## Test fixtures

Airgap extends to the test rigs: go-httpbin is the one standard HTTP
workload, pinned and airgap-carried as a test-fixture artifact — never
third-party images (SPEC.md §7).
