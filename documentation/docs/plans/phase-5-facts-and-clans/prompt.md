# Phase 5: facts schema, materializer and synthetic clans

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the block below into a fresh agent session.

```text
Repo: external-systems/clanServices (main includes phases 1–4).

Read first, in this order:
1. documentation/docs/plans/agent-brief.md.
2. AGENTS.md.
3. documentation/docs/plans/data-plane-hardening.md: "Synthetic inventories", "OpenTofu workflow" (the value-ownership table), "Proposed contract additions" U1–U3 and F1.
4. SPEC.md D57 (networkFacts), D63 (the declared-endpoint AF check and its note that the per-host reachability matrix is phase 5), §6.15.
5. lib/kube-cluster/network-facts.nix (the existing typed, versioned, secret-free schema: copy its style), services/netif/netif-interface.nix (export schema), services/routed-fabric/default.nix (`endpointFamily`, `addressFamilyMismatch`, `hostnameEndpoint`, `endpointFromSources`).
6. One existing eval test that builds a throwaway clan: services/routed-fabric/tests/eval-tests.nix (`mkEvaledWith`, `clanLib.clan { directory = ./fixtures; ... }`).

Load skills: clan-core (inventory, vars layout), clanservices (§16 inventory authoring, §17 testing), nix-style, flakeparts (if you add outputs or apps).

Goal: the underlay facts contract and the ten synthetic clans exist and evaluate, and the reachability matrix (U1/U3) is enforced at eval from facts. No VMs in this phase.

Do:
1. SPEC.md and docs first: a decision for the facts schema, the materializer, and the reachability matrix; §7 lists the synthetic clans; documentation/docs/reference/testing.md gets a "Synthetic clans" section.
2. lib/underlay-facts.nix: option types for one facts.json document. Per machine: arch (x86_64-linux | aarch64-linux), provider (qemu | hetzner | gcp | proxmox | baremetal), per link {mac, kernel name, addresses (v4/v6 with prefix), gateway, mtu, pathMtu, dhcp flags}, public endpoints (v4/v6 literal or null), nat ("none" | "endpoint-independent" | "symmetric"), disk device, boot mode (uefi | bios). Top level: schemaVersion = 1, runId, site per machine. No secrets, no free-form attrs. Add a `packages.<system>.underlay-facts-schema` (JSON Schema generated from the option types, for example by walking `options` with lib) in the dev partition so tf output can be validated later.
3. lib/materialize.nix, a pure function `{ inventory, facts } -> inventory`: fills netif links (match.mac from facts, addresses, gateways, mtu/pathMtu), routed-fabric/wireguard-mesh `endpoint`, and `clan.core.networking.targetHost` from the public or private underlay address (never a fabric/transfer/tunnel address; the phase-2 assertion will catch it). It never invents values that are not in facts. Expose it as `lib.materialize` in the flake.
4. An app `materialize` in the dev partition: `nix run .#materialize -- <clan-dir> <facts.json> <out-dir>` writes `<out-dir>/inventory.nix` (render with lib.generators.toPretty, then run alejandra on it) and refuses an out-dir inside the git tree (`git rev-parse --show-toplevel` comparison).
5. Reachability matrix (U1/U3) in routed-fabric and wireguard-mesh: when facts or explicit settings give both sides' endpoints and NAT type, assert each adjacency has a usable direction (a public endpoint in a shared address family on at least one side; NAT↔NAT with no public side is an error naming both machines). Keep the phase-2 literal check; this extends it with NAT and per-family public reachability. Hostnames still warn.
6. tests/clans/<name>/ for triad, nat-pair, af-split (plus af-split-negative), edge-isp, two-fabrics, home-edge, floating-ip, arm-mix, proxmox-lab, fleet-100. Each has: inventory.nix (a literal attrset, no lib.genAttrs or other generators; fleet-100 is long, that is intended), README.md (shape, what it proves, which VM scenario boots it later), facts.json (QEMU-shaped facts used by the eval tests; the phase-6 harness emits the same schema), vars/ (public values only), expected.json ({ adjacencies: int, reachability: [[a, b, "ok" | "via-spine" | "rejected"]], evalFailure: null | "message substring" }). targetHost is always an underlay address. Use the plan's "Synthetic inventories" table for each shape; home-edge and floating-ip reference services that arrive in phase 7, so model them with today's services and note the gap in their README.
7. Vars for tests/clans: decide and document how they are produced. Prefer the real generators through the clan CLI (check what the locked clan-core CLI accepts for selecting a clan output, for example `clan vars generate --flake .#<attr>`); if that is not possible without a per-clan flake and lock (AGENTS.md: the root and dev locks are the only lockfiles), add a dev app that runs the same generator scripts. Commit only public `value` files. fleet-100 will hit allocation collisions (see the phase-3 SPEC maths); regenerate until clean and say how many rounds it took.
8. Eval tests under tests/clans/eval-tests.nix registered as nix-unit tests: every clan evaluates (all nixosConfigurations' `config.assertions` hold and `system.build.toplevel.drvPath` evaluates); af-split-negative fails with expected.json's message; adjacency counts from the derived graph match expected.json; the reachability classification matches; materializer round-trip (materialize(inventory, facts) evaluates and `materialize` is idempotent when applied twice); the schema rejects an unknown field and a missing required one.

Verify: `nix fmt . && nix flake check --show-trace` (the clans evaluate inside nix-unit). Record eval time for fleet-100 (`time nix eval ...toplevel.drvPath` for one leaf and one spine) in the PR; phase 9 benchmarks it properly.

Pitfalls:
- Evaluating 102 machines inside nix-unit can be slow; test fleet-100 with a few representative machines plus graph-level counts rather than every toplevel.
- Synthetic inventories must not depend on the test harness: they are also the input to phase 8's real deployments.
- getPublicValue reads from the clan's `directory`; point each throwaway clan's `directory` at its tests/clans/<name> folder.
- Secret vars (WireGuard private keys) are not needed to evaluate. Do not commit private keys or a sops tree in this phase; phase 6 decides how VMs get them.
- Keep facts.json and expected.json formatted (`jq --sort-keys .`) so diffs stay readable.

Out of scope: VM scenarios (phase 6), OpenTofu (phase 8), the gateway service (phase 7).

Done when: every tests/clans inventory evaluates (and af-split-negative fails as expected), the reachability matrix is eval-enforced, the materializer round-trips, and the schema is published as a package.

Rules: see agent-brief.md "Rules". One branch, one PR, do not merge.
```
