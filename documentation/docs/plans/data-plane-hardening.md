# Data-plane hardening plan

Status: **planned** (phase 0, docs only). Nothing in this file is
implemented or VM-proven yet; SPEC.md stays the status authority, and each
phase below amends SPEC.md before it changes code (AGENTS.md rule 3).

Goal: make the Data-plane contract (SPEC.md §3.2) enforceable and stable on
any underlay — bare metal, Proxmox, Hetzner, GCP, later AWS and Azure — by
testing it under real-world conditions instead of one flat L2 segment.

Reviewed at `clanServices` `9e704ea` and `pkgs` `9d3976c`.

## Decisions

| Question | Decision |
| --- | --- |
| Where synthetic inventories and tf live | `tests/clans/` and `tf/` in this repo |
| tf hand-off | OpenTofu writes `facts.json`; a pure Nix materializer builds the inventory; tf never writes `inventory.nix` |
| tf runs | ephemeral: nothing is committed back; state in a Hetzner Object Storage (S3) bucket; infrastructure lives at most 24 h |
| Materialized `inventory.<env>.nix` | build artifact of a run, never committed |
| Address, ASN and port derivation | allocate-once clan vars instead of name hashing |
| Default ranges | `198.18.0.0/16` stable loopbacks, `198.19.0.0/16` transfer /31s, one random ULA /48 per clan; overridable per instance; disjointness from the declared underlay is asserted |
| Route behavior | stability over failover speed (clause C1) |
| NAT egress | a single NAT gateway is supported from day one; HA NAT is planned but lives outside clanServices |
| Floating IPs | supported from day one (Hetzner); clanServices declares and coexists with them, a supporting NixOS module or Kubernetes operator moves them |
| Home router | a NixOS router (XGS-PON SFP+ stick, X710-DA4) replacing the ISP gateway is a tested target |
| Gateway service | lives in this repo |
| Deploy targets | Hetzner and GCP first, then Proxmox and bare metal, then AWS and Azure |
| Proxmox testing | QEMU guests shaped like Proxmox VMs plus a tf target; never Proxmox VE inside a VM test |
| Architecture | x86_64 is the default; aarch64 is first-class from day one and proven in the cloud until an aarch64 KVM builder exists |
| IaC tool | OpenTofu only |
| netif interface matching | add `match.mac` |
| Cloud budget | $100/month for ephemeral runs |

## Findings

### Status drift (corrected in SPEC.md by phase 0)

| Claim | What the code and tests do |
| --- | --- |
| §7 routed-fabric suite covers NAT/outbound-only, external-transit 0/0 ACL, Internet source/return, route-filter negatives | `services/routed-fabric/tests/vm/default.nix` runs five VMs on one flat `192.168.1.0/24`; every node has an endpoint; no NAT, border, upstream or filter negatives |
| §6.13 two NAT sites communicating through spines | no VM has a NAT router; the unreachable-adjacency assertion has no negative eval test |
| §6.12 eval rejects leaf-transit configurations, asymmetric source/return, HA profiles without two reachable spines, duplicate ASNs | no such assertions exist; there is no HA-profile concept in the code |
| §6.12 firewall: BGP/BFD only on loopback and expected WG/upstream peers | TCP 179 and UDP 3784/4784 are opened on every interface, including untrusted WAN links |
| Invariant 21: WG MTU derives per link from the underlay | wireguard-mesh defaults to a fixed 1420; routed-fabric assumes 1500 when netif exports no MTU (every DHCP link) |
| §6.3 WG overhead 80 bytes v4 / 96 v6 | the code always subtracts 96 (safe, but the assertion uses 80) |
| §7 netif live static reconfiguration | proven with hand-edited YAML and `ifstatecli apply`, not through a NixOS generation switch |
| `pkgs` README: canonical profile has Cilium iptables rules off | layer 2 forces `install-iptables-rules=true` (D55); the raw committed manifest differs from the canonical profile |

New rule: a status of *VM-proven* names its test file and a unique
`*_OK` marker that the test prints.

### Cross-cutting

1. **IPv6 RA on forwarding nodes.** netif sets per-link `accept_ra = 1`;
   k3s/rke2 and spines/borders enable IPv6 forwarding. Linux ignores RAs at
   `accept_ra = 1` when forwarding is on (`2` is required), so a forwarding
   node on an RA underlay loses its IPv6 default route when the RA lifetime
   expires.
2. **Derived addresses overlap real networks.** Stable addresses hash into
   `192.168.0.0/16` (common home LANs); transfer /31s come from
   `100.64.0.0/10` (CGNAT and Tailscale). Nothing asserts underlay/overlay
   disjointness, and every VM test pins addresses, so the defaults are
   untested.
3. **Birthday collisions.** Ports are `base + hash mod 10000`: a spine with
   50 leaves has about an 11% chance of a collision, 100 leaves about 39%.
   The port range overlaps the kernel ephemeral range `32768–60999`.
4. **One endpoint string per machine.** Private-vs-public endpoint choice
   needs per-adjacency overrides; address family is not modeled, so an
   IPv6-only node and an IPv4-only CGNAT node pass eval and never handshake.
5. **Path MTU is per path, not per node.** GCP is 1460, AWS VPC 9001, the
   Internet 1500 or less; DHCP-learned MTU never reaches the WG MTU.
6. **Reverse-path filtering differs by node type.** Kubernetes nodes use
   loose rpfilter; other fabric nodes keep the NixOS strict default.

### netif

- Physical links require a kernel interface name, which differs per cloud
  and instance type; no MAC matching.
- A missing NIC yields a partial IfState apply; no test proves activation
  fails loudly.
- No cross-instance checks for policy tables, rule priorities or
  overlapping static routes.
- The DHCP route ignore uses `proto 4`; verify which protocol dhcpcd stamps.
- DHCPv6, prefix delegation, DHCP option 121 and option 26 are unexercised.

### routed-fabric

- Source-return tables are `200 + asn mod 40000`: one can land on 200
  (flushed by Cilium) or collide with a netif table.
- FRR default BFD timers (300 ms × 3) on every adjacency, including
  intercontinental and residential links.
- `maximum-prefix 4096` without restart leaves a session down after an
  overflow.
- Border accepts only owned prefixes upstream, so NAT egress cannot be
  expressed today.
- Pod egress to a non-Kubernetes member: masquerade source selection on WG
  devices with only scope-link addresses is untested.

### wireguard-mesh

- Only a mesh-wide "at least one endpoint" check; two NAT'd members never
  connect and VXLAN between them blackholes.
- Overlapping `extraAllowedIPs` between peers silently shadow each other.
- The fixed listen port is not checked against routed-fabric ports on the
  same host.

## Proposed contract additions

| ID | Clause | Enforced by |
| --- | --- | --- |
| U1 Underlay requirements | per adjacency: a shared reachable address family, UDP to the allocated port, path MTU ≥ 1280 + overhead; no L2, multicast or provider anti-spoofing changes | eval (facts), cloud smoke test |
| U2 Address-plan disjointness | underlay prefixes never overlap stable, transfer, pod, Service or pool prefixes | eval |
| U3 Reachability matrix | every adjacency has an endpoint in a shared family and scope; NAT-to-NAT is rejected on both transports | eval, VM negatives |
| U4 Path MTU per adjacency | WG MTU = min(path MTU) − 96, from facts when links are DHCP | eval, `ping -M do` VM |
| C1 Stable convergence | under the Texas–Helsinki WAN profile (≈130 ms RTT, ±20 ms jitter, ≤ 2% loss, 1–2 s loss bursts) for 30 minutes: zero session flaps and zero FIB changes; a dead path is withdrawn within ≤ 15 s on WAN adjacencies and ≤ 3 s on same-site ones; a recovered path returns only after a hold-down; FRR reload loses nothing | VM with timed probes |
| C2 Live change | any inventory change applied by a NixOS generation switch converges without reboot, keeps the deploy SSH session alive, and leaves `ifstatecli check` clean | VM |
| C3 Restart safety | rebooting any single node restores the identical RIB/FIB | VM |
| S1 Exposure | only WireGuard ports answer on untrusted links; BGP/BFD only on fabric interfaces and declared upstream peers | VM negative scans |
| S2 Isolation | separate fabric instances, non-peered clusters and access levels cannot reach what they are not granted | VM |
| F1 Facts completeness | `clan.networkFacts` plus underlay facts drive the reachability matrix and tf firewall rules | eval |

C1 implies two timer profiles chosen per adjacency — same-site (for example
BFD 300 ms × 3) and WAN (for example BFD 1000 ms × 5 with BGP 10/30 s as a
backstop) — plus a hold-down before a recovered path is used again. The
exact FRR mechanisms are chosen and documented in phase 1.

## NAT egress and floating IPs

| Topic | In clanServices | Outside clanServices |
| --- | --- | --- |
| Single NAT gateway (home router, a cloud egress border) | gateway service plus a border egress mode: NAT44, a default route offered only to opted-in leaves, WireGuard endpoint traffic pinned to the underlay | — |
| HA NAT | only "do not break it" | a live-migratable gateway VM (NixOS or a router OS) that looks like one machine, or state sync; planned, not day one |
| Floating IPs | declare the address and its candidate hosts; render an interface IfState creates but never strips addresses from; firewall and fabric treat the address as present-when-held | the mover: a specialized NixOS module or a Kubernetes operator calling the provider API |

## Home edge router

Target: an XGS-PON SFP+ stick in one X710-DA4 port as WAN, the other ports
as LAN (bridge, optionally VLAN-tagged), downstream NixOS servers and PCs
plus non-NixOS devices.

| Function | Owner |
| --- | --- |
| WAN DHCPv4 | netif |
| WAN DHCPv6 + prefix delegation | netif (dhcpcd `ia_pd` in the per-link hook) |
| RA on WAN while forwarding | netif (`accept_ra = 2` when forwarding) |
| LAN addressing from the delegated prefix, DHCPv4 + RA server, local resolver | gateway service |
| NAT44, nftables zones, port forwards | gateway service |
| Fabric membership | routed-fabric |

Hardware risks to check first: X710 firmware and SFP+ compatibility with the
PON stick, the stick's ONT identity setup (outside NixOS), and a fallback
WAN path while iterating.

## Allocation with clan vars

Each allocated number is generated once, stored as a public var, read at eval
with `getPublicValue`, and never recomputed from a machine name.

| Generator | Scope | Files (public) | Notes |
| --- | --- | --- | --- |
| `routed-fabric-<inst>-prefixes` | shared | `ula48`, `loopback4-pool`, `transfer4-pool` | pools default to `198.18.0.0/16` and `198.19.0.0/16` |
| `routed-fabric-<inst>-node` | per machine | `ipv4`, `ipv6`, `asn` | random pick inside the pools |
| `routed-fabric-<inst>-adj-<a>-<b>` | shared, one per adjacency | `port`, `transfer4`, `transfer6` | named by the sorted pair |
| `wireguard-mesh-<inst>-node` | per machine | `ipv4`, `ipv6` | same scheme for the tunnel profile |

Explicit `ipv4`/`ipv6`/`port` settings remain overrides. Caveats: a
generator sees only its dependencies, so uniqueness is enforced by eval
assertions plus a targeted `--regenerate`; never one allocator per instance
(membership changes would renumber everyone); vars must exist before eval;
renaming a machine regenerates its vars; orphaned adjacency vars need a
cleanup check.

## VM test scenarios

All scenarios boot an inventory from `tests/clans/` on a shared harness,
`tests/lib/internet.nix`: a WAN router with `tc netem` profiles, NAT routers
(endpoint-independent and symmetric), cloud DHCP emulators (GCP /32 +
option 121 + MTU 1460; Hetzner static /32 on-link), a public scanner, a
timed probe helper, and a `facts.json` emitter. Routing-only VMs use 1 GiB.

| # | Scenario | Proves |
| --- | --- | --- |
| 1 | home NAT leaf + Hetzner-shaped spine + GCP-shaped spine | NAT keepalive, endpoint scope, per-path MTU (U1, U3, U4) |
| 2 | two NAT sites through two spines | leaf↔leaf only via spines |
| 3 | address-family split | v6-only↔v4-only rejected at eval (U3) |
| 4 | SLAAC on forwarding nodes | IPv6 default route survives RA lifetimes |
| 5 | cloud DHCP fidelity | /32 + option 121, DHCPv6, MTU reaches WG (U4) |
| 6 | Texas–Helsinki WAN soak | zero flaps, WAN withdrawal budget, hold-down (C1) |
| 7 | spine failure matrix | link/VM/partition failures and reboots (C1, C3) |
| 8 | live change via generation switch | SSH survives, no reboot, clean check (C2) |
| 9 | exposure scan | only WG ports answer on untrusted links (S1) |
| 10 | border + upstream + source return | ingress, symmetric return, prefix filtering |
| 11 | two fabrics on one site | no cross-instance reachability (S2) |
| 12 | pod to fabric member | masquerade source and return path |
| 13 | wireguard-mesh NAT matrix | VXLAN via public node; NAT↔NAT rejected |
| 14 | underlay renumbering | re-handshake after an endpoint change |
| 15 | 100-leaf eval (no VMs) | eval time, collisions, FRR config size |
| 16 | single NAT gateway egress | egress only via the border; no tunnel recursion |
| 17 | mixed architecture (cloud first) | identical behavior on aarch64 |
| 18 | allocation hygiene (eval) | collision and missing-var messages |
| 19 | interface by MAC | `match.mac` survives NIC renames |
| 20 | home edge router | NAT44, DHCPv6-PD, RA, prefix change, reboot |
| 21 | floating IP coexistence | IfState reapply keeps a mover-owned address |
| 22 | Proxmox guest shape | `match.mac` and VLAN links on Proxmox-style plumbing |

## Synthetic inventories

Each `tests/clans/<name>/` holds a literal `inventory.nix` (no generators),
a README, committed `vars/` (public allocations and keys) and an
`expected.json` (adjacency counts, reachability matrix, expected failures).

| Name | Shape |
| --- | --- |
| `triad` | home NAT leaf + Hetzner spine + GCP spine, one k3s cluster |
| `nat-pair` | two spines, two NAT leaves, one public leaf |
| `af-split` | v6-only spine, v4-only leaf, dual-stack spine |
| `edge-isp` | border spine, ISP router, client and admin leaves |
| `two-fabrics` | two fabric instances on one site, two clusters |
| `home-edge` | NixOS home router with downstream hosts and a fabric leaf |
| `floating-ip` | two candidates for one floating IP and a stub mover |
| `arm-mix` | `triad` plus one aarch64 leaf |
| `proxmox-lab` | three guests on one Proxmox host |
| `fleet-100` | two spines, 100 leaves, three clusters |

## OpenTofu workflow

```
inventory.nix (literal intent)
  -> clan vars generate (allocations, keys)
  -> plan.json (nix eval: machines, sites, sizes, arch, WG ports)
  -> tofu apply (per-provider modules)
  -> facts.json (public IPs, subnets, MTU, MACs, IPv6; schema-validated)
  -> materialize (pure Nix) -> inventory.<env>.nix (full literal, not committed)
  -> clan machines install (nixos-anywhere)
  -> smoke probes from expected.json
  -> tofu destroy
```

The QEMU harness emits the same `facts.json`, so the schema and materializer
are exercised on every VM run.

| Value | Decided by | Flow |
| --- | --- | --- |
| machine names, roles, sites, sizes, arch | inventory | inventory → plan.json → tf |
| private IPs and subnets | inventory | inventory → tf |
| WireGuard ports and cloud firewall rules | allocated vars | plan.json → tf |
| public IPv4, provider IPv6 | provider | tf → facts → inventory |
| MACs, path MTU, NAT, CPU arch | provider and image | tf → facts |
| disk device, boot mode | provider and instance type | tf → facts → disko/facter |

Runs are ephemeral: each works in a throwaway directory outside the repo
(copied clan, per-run age key, fresh vars), keeps state in the Hetzner S3
bucket under its run id with locking, labels every resource with an expiry
(4 h default, 24 h maximum), and ends with `tofu destroy`; a janitor removes
anything expired. Only inputs are committed: `tests/clans/` and `tf/`.
Modules: `hcloud-node`, `gcp-node`, `proxmox-node` (`bpg/proxmox` provider,
tf-chosen MACs), `baremetal` (reads a hand-written facts stub), later
`aws-node` and `azure-node`.

## Phases

| Phase | Scope | Done when |
| --- | --- | --- |
| 0 | this file + SPEC.md status corrections (docs only) | merged; every VM-proven claim names a marker or is marked planned |
| 1 | correctness fixes + eval assertions + stability timers | each finding has a fix or an assertion with positive and negative tests |
| 2 | allocation through clan vars, new ranges | no hash-derived address, ASN or port remains; all suites green |
| 3 | netif underlay features | `match.mac`, DHCPv6 + PD, forwarding-safe RA, declared path MTU |
| 4 | facts schema, materializer, synthetic inventories | every `tests/clans/` inventory evaluates; materializer round-trips |
| 5 | VM harness + priority scenarios | scenarios 1, 2, 4, 6, 8, 9, 13, 19, 22 green with markers |
| 6 | gateway service, single NAT egress, floating IP coexistence | scenarios 16, 20, 21 green |
| 7 | OpenTofu: Hetzner + GCP | `triad` and `arm-mix` pass smoke probes and destroy within budget |
| 8 | Proxmox lab, breadth, home fleet rehearsal | `proxmox-lab` passes; 100-leaf eval recorded; home repo rehearsal evaluates |

No phase needs a cloud account before phase 7.

## Hand-off prompts

Each prompt is self-contained; paste it into a fresh agent session with
`external-systems/clanServices`, `external-systems/pkgs` and
`external-systems/home` checked out.

### Phase 1

```text
Repo: external-systems/clanServices. Read AGENTS.md, SPEC.md (§3.2, §5, §6.3, §6.12, §7, D47–D62) and documentation/docs/plans/data-plane-hardening.md (Phase 1). Load skills: clanservices, ifstate, frr, nix-style.

Goal: fix the correctness findings, make each one eval-enforced, and make routes stable before fast. No new VM suites in this phase.

Do:
1. routed-fabric firewall: open TCP 179 and UDP 3784/4784 only on fabric WireGuard interfaces and from declared border upstream peers, never globally.
2. Reserve every WireGuard listen port in net.ipv4.ip_local_reserved_ports (routed-fabric and wireguard-mesh).
3. routed-fabric: assert source-return tables are never 200 and never equal a netif routingPolicy.table on the same machine.
4. Assert each adjacency has a shared address family when both endpoints are IP literals; warn when one is a hostname.
5. wireguard-mesh: reject member pairs where neither side has an endpoint; reject overlapping extraAllowedIPs between peers; reject listen-port clashes with routed-fabric on the same host.
6. netif: reject cross-instance policy table and rule-priority collisions; set ipv6 accept_ra = 2 on links of machines that forward (routed-fabric spine/border, k3s/rke2 nodes).
7. Stability: per-adjacency timer profiles `site` (BFD 300 ms x3) and `wan` (BFD 1000 ms x5, BGP 10/30 s backstop) selectable in settings, `wan` the default for adjacencies between different sites; a hold-down before a recovered session is used again (verify FRR 10.7 options such as delay-open; document what you chose and why). maximum-prefix must not leave a session down forever.
8. Add positive and negative nix-unit tests for each item.

Rules: amend SPEC.md and documentation together first; git add before eval; nix fmt; nix flake check --no-build --show-trace (never plain flake check); VM tests stay under legacyPackages.<system>.vmTests. Re-run the netif, routed-fabric and k3s-data-plane VM suites and report results. One branch, one PR, do not merge.
```

### Phase 2

```text
Repo: external-systems/clanServices. Read AGENTS.md, SPEC.md (§6.3, D47, D51, D59), and documentation/docs/plans/data-plane-hardening.md ("Allocation with clan vars"). Load skills: clanservices, clan-core, nix-style.

Goal: replace name-hash derivation with allocate-once clan vars.

Do:
1. Shared generator routed-fabric-<inst>-prefixes: random ULA /48, loopback pool 198.18.0.0/16, transfer pool 198.19.0.0/16 (pools overridable by settings).
2. Per-machine generator routed-fabric-<inst>-node: ipv4, ipv6, asn picked at random inside the pools; one shared generator per adjacency (sorted pair) for port and transfer /31 + /127. All files public.
3. Same per-machine scheme for wireguard-mesh addresses.
4. Existing ipv4/ipv6/port settings remain explicit overrides. Delete the hash functions (no shims).
5. Eval assertions for duplicates name the exact `clan vars generate <machine> --generator <g> --regenerate` command.
6. Regenerate committed test fixture vars for every suite; add eval tests for collision and missing-var messages.

Rules as in AGENTS.md (SPEC first, git add, nix fmt, flake check --no-build, VM suites outside checks). Re-run every registered VM suite and report pass/fail per suite. One PR, do not merge.
```

### Phase 3

```text
Repos: external-systems/clanServices (and external-systems/pkgs only if IfState or dhcpcd packaging needs a change). Read AGENTS.md, SPEC.md D50/D53/D61, and documentation/docs/plans/data-plane-hardening.md (netif findings, "Home edge router"). Load skills: ifstate, clanservices, nix-style.

Goal: netif can describe real cloud, Proxmox and home-router underlays.

Do:
1. Add links.<name>.match.mac, rendered with IfState's permanent-address identification (check the 2.5.1 schema for the exact key); `interface` and `match.mac` are mutually exclusive for physical links.
2. DHCPv6 address + prefix delegation in the per-link dhcpcd hook (ia_pd), with the delegated prefix exposed as a declared-dynamic fact (never an invented address).
3. Per-link `pathMtu` override, exported so routed-fabric uses it instead of assuming 1500 on DHCP links.
4. Eval tests for each; extend the netif DHCP VM suite to cover DHCPv6, PD and an RA-only link on a forwarding machine.

Rules as in AGENTS.md. One PR, do not merge.
```

### Phase 4

```text
Repo: external-systems/clanServices. Read documentation/docs/plans/data-plane-hardening.md ("Synthetic inventories", "OpenTofu workflow"). Load skills: clan-core, clanservices, nix-style.

Goal: the underlay facts contract and the synthetic clans exist and evaluate; no VMs yet.

Do:
1. Define the underlay facts schema as Nix option types under lib/, plus a generated JSON schema output.
2. Write a pure materializer: (literal inventory, facts.json) -> full literal inventory attrset, and an app that writes it as a formatted inventory.nix outside the git tree.
3. Create tests/clans/<name>/ for triad, nat-pair, af-split, edge-isp, two-fabrics, home-edge, floating-ip, arm-mix, proxmox-lab, fleet-100: literal inventory.nix (no generators), README, committed vars/, expected.json.
4. Eval tests: every clan evaluates (af-split's negative variant must fail with the expected message); expected.json adjacency counts match the derived graph; materializer round-trip test.

Rules as in AGENTS.md. One PR, do not merge.
```

### Phase 5

```text
Repo: external-systems/clanServices. Read documentation/docs/plans/data-plane-hardening.md ("VM test scenarios", "Proposed contract additions"). Load skills: vm-tests, ifstate, frr, clanservices.

Goal: a reusable internet harness and the first scenarios, each booting a tests/clans inventory.

Do:
1. tests/lib/internet.nix: wan router with tc netem profiles (including the Texas-Helsinki profile: 130 ms +/- 20, <= 2% loss, 1-2 s bursts), NAT routers (endpoint-independent and symmetric), cloud DHCP emulators (GCP /32 + option 121 + MTU 1460; Hetzner static /32 onlink), a public scanner, a timed probe helper, and a facts.json emitter.
2. Scenarios 9 (exposure scan), 4 (SLAAC on forwarding nodes), 1 (home + Hetzner + GCP shapes), 2 (NAT pair), 6 (WAN soak: zero flaps and zero FIB changes for 30 minutes), 8 (live change via specialisation switch with a live SSH loop), 13 (wireguard-mesh NAT), 19 (match.mac), 22 (Proxmox guest shape; never Proxmox VE inside the VM). Each prints a unique *_OK marker.
3. Measure C1 with the probe helper, never sleep: zero flaps under the WAN profile, withdrawal <= 15 s on WAN and <= 3 s on same-site adjacencies, hold-down respected on recovery.
4. Stay within the CI box: <= 30 GiB total, routing-only VMs at 1 GiB.

Update SPEC.md §7 so each claim names its test file and marker. Run each suite sandboxed and report. One PR, do not merge.
```

### Phase 6

```text
Repo: external-systems/clanServices. Read SPEC.md D8/D51/D56 and documentation/docs/plans/data-plane-hardening.md ("Home edge router", "NAT egress and floating IPs"). Load skills: clanservices, ifstate, frr.

Goal: NixOS can be the single home NAT gateway, and floating IPs can coexist with clanServices networking.

Do:
1. Amend SPEC.md first: border egress mode for ONE NAT gateway (default route offered only to opted-in leaves, WireGuard endpoint traffic always via the underlay); HA NAT and floating-IP movement are explicitly out of scope (a supporting NixOS module or a Kubernetes operator moves floating IPs; HA NAT is a live-migratable gateway VM or state sync outside clanServices).
2. Implement the egress mode in routed-fabric with eval assertions (opt-in only, default route accepted only from the egress border).
3. New gateway clanService in this repo: LAN addressing from the netif-delegated prefix, DHCPv4 + RA server, local resolver, NAT44, nftables zones and port forwards.
4. netif floating addresses: declare the address and candidate hosts; render an IfState-created interface whose addresses IfState never strips; firewall/fabric treat the address as present-when-held. No cloud API code.
5. VM scenarios 16 (single NAT gateway), 20 (home edge router with ISP emulator: DHCPv4, DHCPv6-PD, RA; prefix change; reboot) and 21 (floating IP coexistence with a stub mover).

Rules as in AGENTS.md. One PR, do not merge.
```

### Phase 7

```text
Repo: external-systems/clanServices. Read documentation/docs/plans/data-plane-hardening.md ("OpenTofu workflow"). OpenTofu only.

Goal: deploy a synthetic clan to Hetzner and GCP and prove it with the VM probes, without ever committing run output.

Do:
1. tf/modules/hcloud-node and tf/modules/gcp-node (x86_64 default, aarch64 selectable), each emitting the shared facts object; tf/envs/triad-hz-gcp and tf/envs/arm-mix.
2. A plan export (nix eval -> plan.json) that tf reads for machines, sites, sizes, arch and WireGuard ports (firewall rules).
3. A run script that works in a throwaway directory outside the git tree: copy tests/clans/<name>, point it at the local clanServices checkout, create a per-run age key, clan vars generate -> plan.json -> tofu apply -> facts.json (schema-validated) -> materialize -> clan machines install -> smoke probes from expected.json -> tofu destroy. Nothing is written back to the repo.
4. State in the Hetzner Object Storage S3 bucket, one key per run id, with state locking (check OpenTofu's S3 lockfile support). Credentials only from env.
5. Cost guards: every resource labelled with run id and expiry (default 4 h, maximum 24 h for kept-up infra), a janitor that deletes expired resources and state, a GCP budget alert; total budget $100/month.

Run triad once and arm-mix once; report results and actual cost. One PR, do not merge.
```

### Phase 8

```text
Repos: external-systems/clanServices and external-systems/home. Read documentation/docs/plans/data-plane-hardening.md (Proxmox, synthetic inventories, phases).

Goal: Proxmox as a deploy target, plus breadth.

Do:
1. tf/modules/proxmox-node with the bpg/proxmox provider: guests with tf-set MACs on a VLAN-aware bridge, facts emitted like the clouds; tf/envs/proxmox-lab against the operator's host (credentials from env, never committed).
2. fleet-100 eval benchmark (eval time, FRR config size) recorded in the plan file.
3. Home fleet rehearsal: in the home repo, a branch that moves the current machines plus planned servers, router and cloud VMs onto netif + routed-fabric, evaluated but not deployed.
4. Remaining scenarios (3, 5, 7, 10, 11, 12, 14) as time allows, each in its own commit.

Rules as in AGENTS.md in each repo. One PR per repo, do not merge.
```

## Later concerns

- With spines only in Helsinki, Texas traffic to future North American
  cloud machines would hairpin through Europe; add a North American spine
  when the first one arrives.
- Keep the deploy target (`targetHost`) on the underlay address so a fabric
  change cannot lock out its own deployment.
