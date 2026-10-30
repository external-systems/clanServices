# Phase 7: gateway, single NAT egress and floating IPs

Part of the [data-plane hardening plan](../data-plane-hardening.md).
Paste the block below into a fresh agent session.

```text
Repo: external-systems/clanServices (main includes phases 1–6).

Read first, in this order:
1. documentation/docs/plans/agent-brief.md.
2. AGENTS.md.
3. documentation/docs/plans/data-plane-hardening.md: "NAT egress and floating IPs", "Home edge router", scenarios 16, 20, 21.
4. SPEC.md D8, D51, D56 (border/access), D61 (IfState owns static networking), D63 (exposure, upstream peers), §6.12, §6.13, §9 (out of scope).
5. services/routed-fabric/default.nix: the `border` settings (`ownedPrefixes`, `upstreamPeers`, `forwarding`, `ndpInterfaces`), `externalTransit`, source-return tables, and the firewall block; lib/kube-cluster/frr.nix route maps for borders.
6. services/netif/default.nix: link rendering, the DHCP hook and prefix delegation from phase 4, `nftables.enable`, `firewall.trustedInterfaces`; lib/ifstate.nix `parameters.ignore`.
7. tests/lib/internet.nix and tests/clans/home-edge and tests/clans/floating-ip from phases 5–6.

Load skills: clanservices (new service skeleton, manifest, roles, eval tests), ifstate (defaults and ignores, WireGuard fwmark, routing rules), frr (default-route origination and filtering), nix-style, vm-tests.

Goal: a NixOS machine can be the single home NAT gateway, opted-in leaves can egress through one border, and floating IPs coexist with clanServices networking.

Do:
1. SPEC.md and docs first: new decision(s) for border egress, the gateway service, and floating addresses. HA NAT and floating-IP movement are explicitly out of scope (a supporting NixOS module or Kubernetes operator moves floating IPs; HA NAT is a live-migratable gateway VM or state sync outside clanServices). Add documentation/docs/services/gateway.md and a nav entry in documentation/mkdocs.yml.
2. routed-fabric border egress:
   - `border.egress.enable` on exactly one border per instance (assert); leaves opt in with `defaultRoute = "egress"` (default "none").
   - The border originates 0.0.0.0/0 and ::/0 only toward opted-in leaves (route-map per adjacency); every other adjacency still filters defaults out (keep the D63 negatives green).
   - On an opted-in leaf, install the fabric default route in a dedicated policy table, not main, and steer with an IfState rule `not fwmark <m> lookup <table>` while the leaf's WireGuard interfaces set `fwmark <m>` (the wg-quick pattern), so WireGuard endpoint packets always leave via the underlay and never recurse into the tunnel. Reuse the phase-2 table/priority collision checks (`ip.reservedPolicyTables`, netif tables, source-return tables).
   - Eval tests: second egress border rejected; default refused from a non-egress border; non-opted leaf never accepts a default; table/priority collisions.
3. A new service services/gateway/ (role `gateway`, one machine per instance; register by adding services/gateway/flake-module.nix, which services/flake-module.nix auto-discovers; add nix-unit tests or checks.coverage fails):
   - WAN: an existing netif link name. LAN: an existing netif link (bridge or VLAN) name.
   - IPv6: request PD on the WAN link (phase-4 option), have dhcpcd assign a /64 from it to the LAN link (`ia_pd 1 <lan>/0/64`), and advertise whatever /64 the LAN holds with radvd `prefix ::/64` (or corerad with interface-derived prefixes). Nothing about the delegated prefix is in eval.
   - IPv4: a static LAN /24 from settings; DHCPv4 with kea (`services.kea.dhcp4`); NAT44 masquerade out of the WAN.
   - DNS: unbound listening on LAN addresses only, forwarding upstream, serving local names from the inventory (optional).
   - nftables zones (wan, lan, fabric) in a dedicated table with forward policy drop and explicit lan→wan, lan→fabric allow; port forwards as a list of {proto, port, to, toPort}. Coexist with the NixOS firewall's nftables tables; do not replace them.
   - Assertions: the gateway is not a k3s/rke2 node (Cilium owns iptables-nft rules there); WAN and LAN are different netif links on this machine; LAN /24 does not overlap the fabric pools, pod/service CIDRs, or any netif static prefix.
4. netif floating addresses: `floating.<name> = { address; candidates = [machines]; }` renders on each candidate an IfState dummy interface (name `flt-<name>`, at most 15 characters) with no declared addresses, plus an IfState `parameters.defaults` entry (or ignore rule) for that interface so reapply never removes an address a mover added; firewall and FRR treat the address as present-when-held (advertise the /32 or /128 only when it exists on the host: an FRR `network` statement with a static-route-on-presence, or `redistribute connected` filtered to the floating prefixes). No cloud API code.
5. VM scenarios on the phase-6 harness, each with a unique marker and an entry in SPEC §7:
   - 16 single NAT gateway egress: an opted-in leaf reaches the "Internet" node only via the egress border; its WireGuard endpoint traffic is seen on the underlay, never inside a tunnel (tcpdump on the border's fabric interface sees no UDP to the endpoint port). SCENARIO_16_NAT_EGRESS_OK.
   - 20 home edge router: an ISP emulator (DHCPv4, DHCPv6 with PD, RA); LAN clients get v4 via kea and v6 via RA from the delegated prefix; the ISP changes the delegated prefix and LAN clients renumber; reboot the gateway and everything returns. SCENARIO_20_HOME_EDGE_OK.
   - 21 floating IP coexistence: a stub mover (a shell loop with `ip addr add/del`) moves the address between two candidates; `ifstatecli apply` on the holder keeps it; FRR advertises it only from the holder. SCENARIO_21_FLOATING_IP_OK.

Verify: `nix fmt . && nix flake check --show-trace`; the three scenarios; regressions: routed-fabric, scenario 9 (exposure) and netif-dhcp. Report markers and log paths.

Pitfalls:
- A default route in main on a WireGuard leaf breaks its own endpoint reachability; that is why the egress default lives in a policy table behind a fwmark rule.
- dhcpcd PD and the LAN /64: dhcpcd must not also run on the LAN link; the hook only runs on WAN.
- kea fails to start when its interface has no address yet; order it after IfState (`after = ["ifstate.service"]`).
- Keep port forwards out of the fabric zone unless the user asks: a forward to a fabric address is a new exposure path and needs an S1 negative.

Out of scope: HA NAT, conntrack sync, a cloud floating-IP mover, PPPoE, the XGS-PON stick's ONT identity.

Done when: scenarios 16, 20 and 21 are green with markers and the new decisions are in SPEC.md.

Rules: see agent-brief.md "Rules". One branch, one PR, do not merge.
```
