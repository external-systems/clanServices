# Phase 8: terranix and OpenTofu on Hetzner and GCP

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the block below into a fresh agent session.

```text
Repo: external-systems/clanServices. Read documentation/docs/plans/data-plane-hardening.md ("OpenTofu workflow", "Terranix", "Flake inputs"). OpenTofu only.

Goal: deploy a synthetic clan to Hetzner and GCP and prove it with the VM probes, without ever committing run output.

Do:
1. Add terranix as a dev-only input in a `tf` flake-parts partition (nixpkgs, flake-parts and systems follow ours).
2. terranix modules tf/modules/hcloud-node.nix and tf/modules/gcp-node.nix (x86_64 default, aarch64 selectable), each emitting the shared facts output; env modules that read the clan's evaluated inventory and allocated vars directly (machines, sites, sizes, arch, WireGuard ports and firewall rules). Expose packages.<system>.tf-triad and tf-arm-mix (config.tf.json) and run `tofu validate` on each in checks.
3. Pin providers with opentofu.withPlugins (hcloud, google); tofu init must not download anything.
4. A run app that works in a throwaway directory outside the git tree: copy tests/clans/<name>, point it at the local clanServices checkout, create a per-run age key, clan vars generate -> config.tf.json -> tofu apply -> tofu output -json -> facts.json (schema-validated) -> materialize -> clan machines install (targetHost = the public underlay address) -> smoke probes from expected.json -> tofu destroy. Nothing is written back to the repo.
5. State in the Hetzner Object Storage S3 bucket, one key per run id, with state locking (check OpenTofu's S3 lockfile support). Credentials only from env.
6. Cost guards: every resource labelled with run id and expiry (default 4 h, maximum 24 h for kept-up infra), a janitor that deletes expired resources and state, a GCP budget alert; total budget $100/month.
7. Run triad once and arm-mix once; report results and actual cost.

Rules (AGENTS.md):
- Amend SPEC.md and documentation/ together before changing code.
- git add new files before any Nix eval.
- Format with alejandra (nix fmt); keep statix and deadnix clean.
- nix flake check --show-trace must pass (checks is static-only).
- VM suites live only under legacyPackages.<system>.vmTests. Save every VM run's log to .baton-pass/vm-logs/<suite>/logs-<n> (n = 0, 1, ...); .baton-pass/ is gitignored and never committed.
- Breaking changes carry no compatibility burden: no migration shims or deprecation aliases.
- Keep targetHost on the underlay address, never a fabric or tunnel address.
- One branch, one PR, do not merge.
```
