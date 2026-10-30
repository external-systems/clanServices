# Phase 4: netif underlay features

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the block below into a fresh agent session.

```text
Repos: external-systems/clanServices (main includes phases 1–3). Touch external-systems/pkgs only if the IfState or dhcpcd packaging itself needs a change, in its own PR.

Read first, in this order:
1. documentation/docs/plans/agent-brief.md.
2. AGENTS.md.
3. documentation/docs/plans/data-plane-hardening.md: "Findings > netif", "Findings > Cross-cutting" items 1 and 5, "Home edge router", "Proposed contract additions" U4.
4. SPEC.md D50, D53, D61, D63, invariant 21 in §5, §6.3 first paragraph.
5. services/netif/default.nix: the link option submodule (`interface`, `kind`, `dhcp`, `ra`, `mtu`), `mkIfstateInterfaces`, `dhcpHookScript`, the `parameters.ignore.routes` block with `proto = 4`, and the netif export. services/netif/netif-interface.nix (the export schema: `mtu`, `links.<name>`).
6. services/routed-fabric/default.nix `mtuFromSources`/`underlayMtuOf` and services/wireguard-mesh/default.nix `mtu` (fixed default 1420) — the consumers of the MTU you add.
7. services/netif/tests/vm/dhcp.nix and tests/ifstate-vm.nix (the DHCP server fixture you will extend).

Load skills: ifstate (references/configuration.md "Physical interfaces and stable identity", references/nixos.md, DHCP hooks), clanservices, nix-style, vm-tests.

Goal: netif describes real cloud, Proxmox, and home-router underlays: NICs found by MAC, DHCPv6 with prefix delegation, and a declared path MTU that the transports use.

What already exists (do not rebuild it): `dhcp.ipv6` starts dhcpcd with -6; per-link `mtu`; the export's `mtu` is the instance's smallest link MTU and routed-fabric already prefers it; RA links on forwarding machines use accept_ra = 2 (phase 2).

Do:
1. SPEC.md and docs first: a D65 (or the next free number) covering match.mac, PD as a dynamic fact, and pathMtu; update §6.3, invariant 21, documentation/docs/services/netif.md.
2. `links.<name>.match.mac` (lower-case colon form, validated by a regex). Render it as IfState `identify.perm_address` (IfState 2.5.1 matches `identify`, then a configured permanent address, then the name; confirm against the ifstate skill and the 2.5.1 schema https://ifstate.net/schema/2/ifstate.conf.schema.json). Physical links need exactly one of `interface` or `match.mac` (assert). IfState still needs an interface key: use the logical link name, at most 15 characters, and assert the length. Everything that today reads `r.interface` (DHCP hook names, ignore rules, firewall trust, routed-fabric endpoints) must use the resolved name.
3. A missing NIC must fail loudly: add a VM negative where `match.mac` names a MAC that does not exist and assert that the activation reports failure (ifstate.service failed, or the journal names the unmatched link), not a silent partial apply. `ifstatecli check` exits 0 even when it proposes changes, so parse its output; never use its exit status as a "no diff" signal.
4. DHCPv6 prefix delegation: `links.<name>.dhcp.prefixDelegation = { enable; length ? 56..64; }`. dhcpcd needs a config file for `ia_pd`, so render a per-link, instance-namespaced dhcpcd.conf in the Nix store and pass it with `-f` from the hook. Keep the delegated prefix out of eval: export it as declared-dynamic (`dynamic = true`, no literal), the same way DHCP addresses are labeled in networkFacts. Never invent an address.
5. Verify which route protocol dhcpcd stamps (`ip -j route show dev <if>` in the VM: proto dhcp is 16, static is 4, ra is 9) and fix `ignore.routes` so IfState reapply never removes dhcpcd or kernel RA routes. Add the observed protocols to the VM assertions.
6. `links.<name>.pathMtu` (nullable int, >= 1280): the smallest MTU on the path to fabric peers, which may be below the link MTU (GCP 1460, PPPoE 1492). Export it per link and as the instance minimum. routed-fabric and wireguard-mesh prefer it over link `mtu`, then their own settings. wireguard-mesh derives its MTU from it (minus 96, floor 1280) when the user did not set `mtu`. Emit an eval warning when an endpoint-bearing link uses DHCP and declares neither `mtu` nor `pathMtu` (the 1500 assumption is the bug from the findings).
7. Eval tests, positive and negative, for: mac format, interface/mac exclusivity, name length, PD option rendering, pathMtu < 1280 rejected, pathMtu winning in routed-fabric and wireguard-mesh, the DHCP-without-MTU warning.
8. Extend the netif-dhcp VM suite (or add `netif-dhcp6` if the runtime exceeds about 10 minutes) with: a DHCPv6 server that delegates a /56 (kea or dnsmasq in the server node; the netif VM fixture already runs a DHCPv4 server), a client receiving an address and a prefix, an RA-only link on a forwarding machine (accept_ra = 2) whose default route survives at least two RA lifetimes (set a short AdvDefaultLifetime, poll with a deadline, no sleeps), and a match.mac link whose kernel name differs from the logical name (set the MAC with `virtualisation.interfaces` or a udev rename). Print a new marker, for example NETIF_DHCP6_PD_OK, alongside NETIF_DHCP_RA_IFSTATE_OK.

Verify: `nix fmt . && nix flake check --show-trace`; `nix run .#vm-test -- netif`, `netif-dhcp` (and the new suite), `routed-fabric`, `wireguard-mesh`, `k3s-data-plane`. Report markers and log paths.

Pitfalls:
- QEMU NICs in VM tests have deterministic MACs; read the actual MAC from the node (`cat /sys/class/net/eth1/address`) at test time or set it explicitly; do not guess.
- dhcpcd started by the hook must keep running across `ifstatecli apply` (KillMode=process in the shared base); do not add a second DHCP owner (no networking.dhcpcd, no systemd-networkd).
- The hook runs as root with IFS_* variables; quote everything, it is checked by shellcheck through treefmt.
- PD is runtime state. Consumers (phase 7 gateway) read it at runtime from a file or hook, not from eval.

Out of scope: the gateway's LAN side (phase 7), facts.json (phase 5), cloud DHCP emulators (phase 6).

Done when: match.mac, DHCPv6 + PD, and declared path MTU are in SPEC, implemented, eval-tested, and VM-proven with a marker.

Rules: see agent-brief.md "Rules". One branch, one PR, do not merge.
```
