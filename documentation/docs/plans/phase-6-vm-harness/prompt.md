# Phase 6: internet harness and priority scenarios

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste one block below into a fresh agent session. The phase is split in two
PRs because one agent session rarely finishes nine scenarios plus a
30-minute soak: run 6a, merge it, then run 6b.

## 6a: harness and the four short scenarios

```text
Repo: external-systems/clanServices (main includes phases 1–5).

Read first, in this order:
1. documentation/docs/plans/agent-brief.md.
2. AGENTS.md.
3. documentation/docs/plans/data-plane-hardening.md: "VM test scenarios", "Proposed contract additions" (S1, C1, U1–U4), "Synthetic inventories", "OpenTofu workflow" (facts.json is emitted by this harness too).
4. SPEC.md §7 and D63 (exposure and timer profiles).
5. The existing harness pieces: tests/ifstate-vm.nix (a reusable VM fixture with addresses and a DHCP server), tests/clan-nixos-test.nix (how clan.nixosTests become legacyPackages.vmTests), services/routed-fabric/tests/vm/default.nix (the most complete suite: endpoints from the clan-core `internet` service, networkFacts reads, RIB/FIB checks, DelayOpen-aware waits), services/netif/tests/vm/dhcp.nix.
6. lib/underlay-facts.nix and tests/clans/*/ from phase 5.

Load skills: vm-tests (the patterns and anti-patterns apply; its file layout and sm/md/lg wiring describe the home repo, not this one), ifstate, frr (references/operations.md for vtysh JSON), clanservices, clan-core.

Goal: tests/lib/internet.nix exists and four scenarios boot tests/clans inventories on it and print unique markers.

Do:
1. SPEC.md §7 and documentation/docs/reference/testing.md first: name each new suite and its marker as planned.
2. tests/lib/internet.nix, a function returning NixOS test node modules and helpers:
   - wan router: forwards between "sites", `tc qdisc ... netem` profiles selectable per link (lan: none; wan: delay 130ms 20ms distribution normal loss 2% with Gilbert-Elliott bursts approximating 1–2 s outages; document the exact tc line);
   - nat routers: nftables masquerade in endpoint-independent mode and a symmetric mode (random source ports per destination);
   - cloud DHCP emulators: GCP-shaped (a /32 lease, option 121 classless static route to the gateway, option 26 MTU 1460) and Hetzner-shaped (static /32 with an on-link gateway);
   - a scanner node with nmap that can address every untrusted link;
   - a probe helper (a small Python script installed on nodes) that timestamps route and session changes from `ip -j monitor route` and `vtysh -c 'show bgp neighbors json'`, so convergence is measured, never slept;
   - a facts.json emitter that writes the phase-5 schema from the running VMs (real MACs, addresses, MTU) and validates it against the schema package.
   Routing-only nodes use virtualisation.memorySize = 1024 and cores = 1.
3. Scenario suites, each in tests/scenarios/<n>-<name>.nix and registered under clan.nixosTests (legacyPackages.<system>.vmTests), each booting a tests/clans inventory through the materializer with harness facts:
   - 9 exposure (S1): only WireGuard UDP ports answer on untrusted links; TCP 179 and UDP 3784/4784 are closed from the scanner and open only on fabric interfaces. Marker SCENARIO_9_EXPOSURE_OK.
   - 4 SLAAC on forwarding nodes: a spine and a k3s-free forwarding leaf keep their IPv6 default route past three short RA lifetimes. Marker SCENARIO_4_SLAAC_FORWARDING_OK.
   - 19 match.mac: a NIC renamed between boots is still found; the old name is not used. Marker SCENARIO_19_MATCH_MAC_OK.
   - 22 Proxmox guest shape: virtio NICs with fixed MACs on a VLAN-aware bridge in the host test network, VLAN links from netif, never Proxmox VE itself. Marker SCENARIO_22_PROXMOX_SHAPE_OK.
4. Update SPEC.md §7 so each claim names its test file and marker.

Verify: `nix fmt . && nix flake check --show-trace`, then each scenario through `nix run .#vm-test -- <suite>`, plus `routed-fabric` and `netif-dhcp` as regressions. Report markers, log paths, wall time, and peak memory (sum of memorySize).

Budget: one suite at most 30 GiB of VM memory in total.

Pitfalls:
- Hostnames in endpoints race LLMNR during bring-up; the existing routed-fabric suite uses literal addresses for this reason.
- netem on the router's egress only shapes one direction; shape both interfaces for symmetric delay.
- After any session reset wait out DelayOpen (5 s) before RIB comparisons.
- Read ASNs, loopbacks, and interface names from `nodes.<m>.clan.networkFacts`, never from hashes or fixture constants.
- VM tests need secret vars (private keys). Use the mechanism phase 3 documented in reference/testing.md; do not invent a second one.

Done when: the harness exists, scenarios 9, 4, 19 and 22 are green with markers, and SPEC §7 cites them.

Rules: see agent-brief.md "Rules". One branch, one PR, do not merge.
```

## 6b: WAN, NAT and live-change scenarios

```text
Repo: external-systems/clanServices (main includes phase 6a).

Read first: documentation/docs/plans/agent-brief.md, AGENTS.md, this page's 6a block (for the harness), tests/lib/internet.nix, the four 6a scenarios, documentation/docs/plans/data-plane-hardening.md ("VM test scenarios" rows 1, 2, 6, 8, 13 and clause C1/C2), SPEC.md D63 (timer profiles, DelayOpen).

Load skills: vm-tests, frr, ifstate, clanservices.

Goal: the remaining priority scenarios are green with markers, and C1 is measured.

Do:
1. Scenario 1 (triad: home NAT leaf + Hetzner-shaped spine + GCP-shaped spine): NAT keepalive keeps the session up, endpoints are chosen by scope, WireGuard MTU follows the GCP path MTU (`ping -M do -s <mtu-28>` succeeds, one byte more fails). Marker SCENARIO_1_TRIAD_OK.
2. Scenario 2 (nat-pair): two NAT leaves reach each other only through spines (traceroute hops are spine loopbacks; no direct WG peer exists). Marker SCENARIO_2_NAT_PAIR_OK.
3. Scenario 13 (wireguard-mesh NAT): every NAT↔public pair handshakes through the NAT and carries pod traffic over VXLAN; a mesh containing two NAT members with no public side between them is an eval failure (the phase-2 wireguard-mesh assertion; cite its eval test). wireguard-mesh is a full mesh with no relaying, so do not try to route NAT↔NAT through the public member. Marker SCENARIO_13_MESH_NAT_OK.
4. Scenario 8 (live change): change an inventory value (add a leaf adjacency or change an MTU) through a NixOS specialisation and `switch-to-configuration test`; a background SSH loop to targetHost keeps running without a dropped iteration; no reboot; `ifstatecli check` is clean afterwards. Marker SCENARIO_8_LIVE_CHANGE_OK.
5. Scenario 6 (WAN soak, C1): the Texas–Helsinki netem profile for 30 minutes on a wan adjacency: zero BGP session flaps and zero FIB changes (from the probe helper's log); then cut the link: withdrawal within 15 s on wan and within 3 s on a site adjacency; restore: the path returns only after the DelayOpen hold-down. Make the soak duration a parameter so a 3-minute variant runs during development; the PR must include one full 30-minute run. Marker SCENARIO_6_WAN_SOAK_OK.
6. SPEC.md §7: each claim names its file and marker; move C1/C2 from planned to VM-proven only for what the logs show.

Verify: each scenario through the vm-test app, plus the four 6a scenarios and `routed-fabric` as regressions. Report markers, log paths, and wall time.

Pitfalls:
- A 2% loss profile will drop single BFD packets; the wan BFD profile (1000 ms x5) is designed to tolerate that. If the soak flaps, report it as a finding with the probe log; do not loosen timers without amending D63 first.
- Nix's default test timeout may kill a 30-minute soak; set `meta.timeout` on that suite.
- Specialisation switches restart units whose config changed; assert FRR peers' uptimes for unchanged adjacencies to prove nothing else reset.

Done when: scenarios 1, 2, 6, 8 and 13 are green with markers and C1 is measured from probe logs.

Rules: see agent-brief.md "Rules". One branch, one PR, do not merge.
```
