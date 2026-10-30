# Phase 3: allocation with clan vars

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the block below into a fresh agent session.

```text
Repo: external-systems/clanServices (main includes phases 1 and 2).

Read first, in this order:
1. documentation/docs/plans/agent-brief.md (commands, skills, pitfalls, PR shape).
2. AGENTS.md, all 12 hard rules.
3. documentation/docs/plans/data-plane-hardening.md, sections "Allocation with clan vars" and "Findings > Cross-cutting" items 2 and 3.
4. SPEC.md §6.3 (the paragraph starting "`routed-fabric` is the native overlay transport"), §6.13, D47, D51, D59, D63.
5. lib/kube-cluster/fabric.nix (every function), services/routed-fabric/default.nix (`addressOf`, `mkAdjacency`, `ownAsn`, `table`, `rulePriority`, the `clan.core.vars.generators` block, `publicKeyOf`), services/wireguard-mesh/default.nix (`derivedV4`, `derivedV6`, the generator, the `node_transport` export).
6. Every caller of the hash helpers: `grep -rn "stableIpv\|nodeAsn\|adjacencyPort\|transferAddresses\|derivedV4\|derivedV6" services lib tests`.
   Today that includes services/k3s/tests/vm/data-plane.nix and services/rke2/tests/vm/data-plane.nix (they compute the foreign router's neighbor ASNs with fabric.nodeAsn) and services/routed-fabric/tests/eval-tests.nix (expected ports such as "52679,54843").

Load skills: clanservices (§9 vars, §11 vars vs exports, §17 testing), clan-core (vars generators, storage layout, CLI), nix-style, vm-tests, frr (only if FRR output changes).

Goal: every fabric and mesh address, ASN, and WireGuard port is allocated once by a clan vars generator, committed as a public var, and read at eval. Nothing is recomputed from a machine or instance name.

In scope: routed-fabric loopbacks (IPv4 + IPv6), node ASNs, per-adjacency ports and transfer prefixes, wireguard-mesh addresses.
Out of scope (keep as is): interface names (`adjacencyName`, `rflo<hash>`), FRR symbol names, the per-adjacency IPv6 link-local, the kube-cluster Cilium cluster id, Cilium/host ASNs, and pod/service CIDRs. These are names or cluster-level values with their own pins and fleet checks; record them in SPEC.md as "hash-derived by design" so the done-when below is honest.

Design (write it into SPEC.md first, as decision D64 plus §6.3/§6.13 edits):

Generators (all files `secret = false`, `deploy = false`; scripts use python3 with `ipaddress` and `secrets` from runtimeInputs, never bash arithmetic):
- `routed-fabric-<inst>-prefixes`, `share = true`. Files `ula48` (random fdXX:XXXX:XXXX::/48 per RFC 4193), `loopback4-pool`, `transfer4-pool`. The pools default to 198.18.0.0/16 and 198.19.0.0/16 and come from per-machine settings `loopback4Pool`/`transfer4Pool` that every member must set equally (assert it). Feed them to the generator through `validation` (strings only; validation values cannot be lists).
- `routed-fabric-<inst>-node`, per machine, `dependencies = ["routed-fabric-<inst>-prefixes"]`. Files `ipv4` (random host in loopback4-pool, never network/broadcast), `ipv6` (random host in `<ula48>:0::/64`), `asn` (random in 4200000000..4294967294).
- `routed-fabric-<inst>-adj-<a>-<b>`, `share = true`, one per adjacency, `<a>`/`<b>` sorted. Files `port`, `transfer4` (a /31 from transfer4-pool), `transfer6` (a /127 from `<ula48>:1::/64`). Both endpoints declare this generator; the declarations must be byte-identical (no machine name, no local setting in the script, `files`, `dependencies`, or `validation`), or clan reports a conflicting shared generator.
- `wireguard-mesh-<inst>-prefixes` (shared: `ula48`, `ipv4-pool`, default 198.18.128.0/17) and `wireguard-mesh-<inst>-node` (per machine: `ipv4`, `ipv6`). Change the routed-fabric loopback default to 198.18.0.0/17 so a host in both services never overlaps by default, and update the plan's decision table to match.
- Port range: pick from 10000–32767 by default (below the kernel ephemeral range 32768–60999; phase 2 already reserves rendered ports in ip_local_reserved_ports). Make the range a setting.

Reading values: services get a module-level `directory` argument (see clan-core/clanServices/mycelium: `{ clanLib, directory, ... }` and `clanLib.getPublicValue { flake = directory; machine; generator; file; default = ...; }`). Use it in `perInstance` so FRR config, exports, and networkFacts can read remote machines' allocations; inside `nixosModule` the existing `config.clan.core.settings.directory` pattern also works. Always `lib.trim` the value (files may end in a newline). Shared generators are read with the same call; check the clan-core skill's storage layout (`vars/shared/<generator>/<file>/value`) and confirm how getPublicValue addresses shared values before you rely on it.

Explicit `ipv4`/`ipv6`/`adjacencies.<remote>.port` settings still win over vars (keep them as the collision escape). Delete fabric.stableIpv4/stableIpv6/nodeAsn/adjacencyPort/transferAddresses and the mesh derivedV4/derivedV6/meshHash outright. Keep `adjacencyKey` and `adjacencyName`. The source-return `table`/`rulePriority` defaults currently use `fabric.nodeAsn`; derive them from the allocated remote ASN instead (same formula), and keep the phase-2 collision assertions.

Assertions (each message names the exact fix):
- Missing var: `routed-fabric/<inst>: no allocation for <machine> (<generator>/<file>); run: clan vars generate <machine> --generator <generator>`.
- Duplicates, fleet-wide within an instance: loopback IPv4, loopback IPv6, ASN. Per host: adjacency ports (together with every other rendered WireGuard port), transfer4 and transfer6 prefixes. Message: `... collides with <other>; run: clan vars generate <machine> --generator <generator> --regenerate`. For an adjacency generator name the machine that runs it (either endpoint).
- Pools: loopback and transfer pools are disjoint from each other, from the ULA's derived /64s, from every netif-declared static underlay prefix on members, and from kube-cluster pod/service/fabric pool CIDRs on members. Reuse lib/kube-cluster/cidr.nix overlap helpers.
- Orphans: an eval-free check is not possible, so add a small app or documented command that lists `vars/shared/routed-fabric-*-adj-*` directories with no matching adjacency. A warning in the docs is the minimum.

Collision maths (put it in the SPEC so nobody is surprised): with k random picks among N slots, P(any collision) ≈ 1 − exp(−k(k−1)/2N). 102 loopbacks in a /17: about 15%. A spine with 100 adjacencies: ports in 22768 slots about 20%, transfer /31s in 32768 slots about 14%. Collisions happen once, at generation time; the fix is the printed regenerate command, after which the values are committed and stable.

Fixtures and tests:
- Eval-test fixtures (services/<svc>/tests/fixtures/vars/...) are plain public files. Write them by hand with readable values (198.18.0.1, 4200000001, port 20001, ...) at `vars/per-machine/<machine>/<generator>/<file>/value` and `vars/shared/<generator>/<file>/value`. Add fixtures for k3s and rke2 eval tests too: their throwaway clans include routed-fabric/wireguard-mesh.
- Replace hash-derived expected values in eval tests with the fixture values (for example the reserved-ports string). Do not recompute hashes to fill expectations.
- New eval tests: missing node var, missing adjacency var, duplicate loopback, duplicate ASN, duplicate port on one host, duplicate transfer on one host, unequal pools across members, pool overlapping a netif static prefix, explicit override beating a var, and that a duplicate transfer on two unrelated hosts is accepted.
- VM tests: first find out how they get vars today. services/routed-fabric/tests/vm/ has no vars/ directory yet passes, while services/k3s/tests/vm/vars/ has committed public keys. Read the clan-core nixosTest module in the locked clan-core input (`nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.clan-core.outPath'`, then search for `update-vars`) and write down in testing.md which mechanism applies. If public values must be committed, generate them with `nix run .#legacyPackages.x86_64-linux.vmTests.<suite>.update-vars` (or the mechanism you found), commit only public `value` files and the test sops material the harness expects, and never commit `.baton-pass/`.
- The k3s/rke2 data-plane suites must stop calling fabric.nodeAsn. Read the ASN from `nodes.<machine>.clan.networkFacts.fabric.<inst>.asn` (networkFacts already exports `asn`) or from the fixture value file with builtins.readFile; prefer networkFacts.

Do, in order, one commit each:
1. docs: SPEC.md D64 + §6.3/§6.13/§7 + documentation/docs/services/routed-fabric.md, wireguard-mesh.md, reference/testing.md, and the plan's decision table and "Allocation with clan vars" section.
2. routed-fabric generators and reads, with the old helpers deleted, fixtures and eval tests updated.
3. wireguard-mesh generators and reads, fixtures and eval tests.
4. k3s/rke2 eval fixtures and VM data-plane tests read allocations from facts.
5. Assertions and their positive/negative eval tests.

Verify:
- `grep -rn "hashString" services lib` shows only names (adjacencyName, rflo, FRR symbols, link-local), kube-cluster cluster id/ASNs, and bundle config hashes.
- `nix fmt . && nix flake check --show-trace` passes.
- Every registered suite (`nix run .#vm-test -- --list`, 24 today), one at a time, cheapest first: netif, netif-dhcp, wireguard-mesh, routed-fabric, then k3s-*, then rke2-*. Report a table: suite, exit status, marker if any, log path. A suite that fails for an unrelated, pre-existing reason is reported, not hidden; do not weaken a test to pass.

Pitfalls:
- `getPublicValue` returns the default when the file is missing; always pass a `default = throw "..."` with the generate command, never let null flow into an address.
- A generator only sees its declared dependencies, so cross-machine uniqueness can only be an eval assertion. Never build one allocator for the whole instance: adding a member would renumber everyone.
- Shared generator definitions are compared across machines. Anything per machine (settings, machine name) in a shared generator breaks the second machine's eval.
- Renaming a machine is a new identity: it gets new vars. Say so in the README; do not add migration code.
- `perInstance` cannot read `config`; that is why the module-level `directory` is needed for values used outside `nixosModule`.

Done when: no fabric or mesh address, ASN, or port is derived from a name; every collision class has a positive and a negative eval test; all suites green or explicitly reported.

Rules: see agent-brief.md "Rules". One branch, one PR, do not merge.
```
