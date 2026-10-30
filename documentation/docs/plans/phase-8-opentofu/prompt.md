# Phase 8: terranix and OpenTofu on Hetzner and GCP

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the first block into a fresh agent session. 8a needs no cloud
account. 8b spends money and needs credentials from the operator, so it
starts only after 8a is merged and the operator has exported them.

## 8a: generated tf, offline validation and the run app

```text
Repo: external-systems/clanServices (main includes phases 1–7). OpenTofu only, never Terraform.

Read first, in this order:
1. documentation/docs/plans/agent-brief.md.
2. AGENTS.md.
3. documentation/docs/plans/data-plane-hardening.md: "OpenTofu workflow", "Terranix", "Flake inputs", the cost and expiry decisions in "Decisions".
4. flake.nix (`partitionedAttrs`, `partitions.dev`), dev/flake.nix, dev/flake-module.nix: how the dev partition gets its own inputs and lock.
5. lib/underlay-facts.nix, lib/materialize.nix, the `materialize` app, tests/clans/triad and tests/clans/arm-mix (phase 5).

Load skills: terranix (SKILL.md, then references/flake-parts.md, providers.md, state-and-operations.md), flakeparts, clan-core (vars, `clan machines install`), disko, nix-style.

Goal: `nix build .#tf-triad` and `.#tf-arm-mix` produce config.tf.json from the clan's own evaluation, `tofu validate` runs offline in checks, and a run app can drive a full ephemeral deployment.

Partition decision (record it in SPEC.md and the plan before coding): `partitionedAttrs` maps each flake attribute (`apps`, `checks`, `packages`, ...) to exactly one partition, and today they all map to `dev`. A separate `tf` partition therefore cannot also expose `packages.tf-*`, `apps.tf-run`, or `checks`. Add terranix as an input in dev/flake.nix (dev-only, consumers never lock it) and keep the tf code in tf/, imported from dev/flake-module.nix. AGENTS.md's "root and dev locks are the only lockfiles" stays true; update the plan's "Flake inputs" table, which still says "separate tf partition".

Do:
1. dev/flake.nix: add `terranix` (inputs.nixpkgs.follows = "dev-nixpkgs"); `nix flake lock ./dev`. Use `inputs.terranix.flakeModule` (not `flakeModules.default`) or `terranix.lib.terranixConfiguration` directly. Never name a configuration `default` (its apps break `nix flake check`).
2. tf/modules/hcloud-node.nix and tf/modules/gcp-node.nix: typed options for the fields we use (name, site/location, server type or machine type, arch x86_64 | aarch64, image, labels, firewall rules, ssh key), emitting `output.facts` in the phase-5 facts schema shape. Hetzner arm64 types are CAX*, GCP arm64 is t2a/c4a; pick the cheapest that boots NixOS via nixos-anywhere.
3. tf/envs/<clan>.nix reads the evaluated clan directly (machine list, sites, arch, WireGuard ports from the allocated vars, firewall rules from routed-fabric's rendered listen ports). No hand-written HCL, no plan.json, no tf variables for values the inventory already holds.
4. Providers through `opentofu.withPlugins (p: [ p.hcloud p.google ])` from nixpkgs (check the attribute names exist in the locked nixpkgs); `tofu init` must download nothing.
5. checks.tf-validate-<clan>: copy config.tf.json into $TMPDIR, `tofu init -backend=false`, `tofu validate`. Runs offline in the sandbox.
6. apps.tf-run (`nix run .#tf-run -- <clan> [--keep 4h]`):
   - refuses to run inside the git tree; works in `mktemp -d`;
   - copies tests/clans/<clan> there and points it at the local clanServices checkout;
   - creates a per-run age key and runs `clan vars generate` for all machines;
   - writes config.tf.json and runs `tofu init -backend-config=key=runs/<run-id>/terraform.tfstate` (the S3 backend block stays static in JSON: bucket, Hetzner path-style endpoint `endpoints.s3`, `use_path_style = true`, the four `skip_*` flags, `use_lockfile = true`; OpenTofu ≥ 1.10);
   - `tofu plan -out plan.bin`, then `tofu apply plan.bin` (never -auto-approve on an unreviewed plan; the app's apply step is the approval because the operator ran it for an ephemeral run);
   - `tofu output -json facts > facts.json`, validate against the schema package;
   - materialize, `clan machines install <m> --target-host <public underlay address> --update-hardware-config nixos-facter` (disko layout chosen from facts: disk device, boot mode);
   - smoke probes from expected.json (fabric reachability, BGP established, MTU ping);
   - `tofu destroy` in a trap so a failure still destroys; `--keep` skips destroy but sets the expiry label.
   Credentials come only from env: HCLOUD_TOKEN, GOOGLE_APPLICATION_CREDENTIALS (or GOOGLE_CREDENTIALS), AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY for the Hetzner bucket. Nothing is written back to the repo.
7. Cost guards in the modules: every resource labelled `run-id` and `expires` (unix seconds as a string; GCP label values are lowercase, at most 63 chars), default expiry 4 h, maximum 24 h asserted at eval; apps.tf-janitor deletes expired servers, networks, firewalls and state keys by label using hcloud and gcloud CLIs; a `google_billing_budget` module for the $100/month alert (behind an option, since it needs billing-account permissions).
8. Docs: documentation/docs/guides/cloud-runs.md (prerequisites, env vars, run, keep, janitor) and a nav entry.

Verify: `nix fmt . && nix flake check --show-trace` (includes tf-validate checks); `nix build .#tf-triad .#tf-arm-mix` and `jq` the JSON; a consumer flake `nix flake metadata` shows no terranix; `nix run .#tf-run -- triad` without credentials fails early with a message naming the missing variables.

Pitfalls:
- Terranix knows no provider schemas: a typo is caught by `tofu validate`, not by Nix. That is why the check exists.
- Secrets in Nix or config.tf.json land in the world-readable store. Only env.
- `lib.tf.ref` for values tf resolves at apply time; plain Nix strings for everything known at eval.
- Native S3 locking on Hetzner is best effort; test acquire/release once and document the result.

Done when: both envs build and validate offline, the run app works end to end up to the credential check, and the docs explain a run.

Rules: see agent-brief.md "Rules". One branch, one PR, do not merge.
```

## 8b: real runs

```text
Repo: external-systems/clanServices (main includes 8a). Requires HCLOUD_TOKEN, Google credentials, and the Hetzner bucket keys in the environment; if any is missing, stop and ask the operator.

Read: documentation/docs/plans/agent-brief.md, documentation/docs/guides/cloud-runs.md, tf/, the tf-run and tf-janitor apps.
Load skills: terranix, clan-core, disko, frr.

Do: run `nix run .#tf-run -- triad` once and `nix run .#tf-run -- arm-mix` once. Fix what breaks in small commits (each with an eval or check that would have caught it). After each run, confirm with the hcloud and gcloud CLIs and the bucket listing that nothing is left except state you intentionally kept. Record wall time and actual cost from the provider consoles or billing exports.

Report: per run: the smoke probe results, the facts.json shape (redact public IPs), wall time, cost, and the janitor's output. Update the plan's phase table.

Rules: see agent-brief.md "Rules". Never commit run output, state, keys, or facts. One branch, one PR, do not merge.
```
