# Stage-0 probe lessons (FRR, Cilium, WireGuard, MTU)

These lessons came from throwaway Stage-0 probes run on 2026-10-24 before the
round-15/16 implementation. They are implementation and test-design facts —
keep them when writing renderers and VM suites so they are not relearned the
hard way.

## FRR 10.7.1 on NixOS

- One `services.frr.config` renders `/etc/frr/frr.conf`. Do not repeat the
  NixOS wrapper's `hostname`, `log syslog`, or
  `service integrated-vtysh-config`.
- `frr-reload.py --test` exits zero even when it prints a non-empty
  add/delete delta. A convergence probe must inspect the delta, not only the
  process status.
- FRR 10.7.1 reload starts newly enabled daemons; enabling `bfdd` through a
  NixOS switch did not restart `bgpd`. A full `frr` restart is not required
  for a daemon-set change.
- The `::1` Cilium peer requires `neighbor ::1 capability
  extended-nexthop`. Cilium/GoBGP offers the capability automatically; FRR
  only enables it automatically for interface/unnumbered peers.
- `allow-reserved-ranges` is global; `bgp allow-martian-nexthop` is inside
  `router bgp`.
- Zebra holds locally originated Cilium routes as unselected BGP entries
  when Cilium's own kernel route is more specific. That is correct. Assert
  Zebra installation for remote/non-local prefixes, not for locally owned
  pod blocks.
- The kernel rejects IPv6 routes whose next hop is a LOCAL address. A
  rewritten local IPv6 transport next hop is therefore harmless but cannot
  kernel-install a self route.
- `bgpd` refuses `neighbor <own-address>`; only the loopback `::1` peer
  shape works for local Cilium peering.

## Cilium 1.20.3 BGP and the artifact base

- The chart has no `installIptablesRules` Helm value. Setting that value is
  a silent no-op. Use
  `extraConfig."install-iptables-rules" = false`, which renders into
  `cilium-config`.
- The chart always renders an inert `tunnel-protocol: "vxlan"` key in native
  mode. Native mode and no `cilium_vxlan` device are the real datapath
  assertions; do not require the chart template key itself to disappear.
- One Cilium BGP v2 session at `::1`, with no `localPort`, carries both
  address families. IPv4 NLRI rides the IPv6 transport when FRR enables
  extended-next-hop.
- Multi-pool advertisements are `CiliumPodIPPool` advertisements. Cilium
  advertises the node's per-family pool allocations (for example /24 and
  /64), not the whole pool CIDR and not `PodCIDR`.

## WireGuard transit and policy routing

- `AllowedIPs` is both cryptokey selection and an inbound source ACL. A
  hub-facing peer needs the prefixes the peer is authorized to carry through
  that interface; accepted BGP alone is not enough.
- External-transit `0.0.0.0/0` and `::/0` belong only in the WireGuard peer
  ACL. Do not create or accept an installed fabric default route in the
  main table.
- Internet-sourced ingress requires source-policy return routing. Probe
  with `ip route get <external> from <VIP>` and assert the fabric interface;
  also capture traffic on the underlay default interface and assert zero
  return packets.
- An explicit policy-table default route is allowed; the contract is that
  the main RIB/FIB carries no fabric default.
- Kernel WireGuard GSO can mask the IPv6 MTU boundary without DF probes.
  Use `ping -M do` for boundary and PMTU assertions.
- Test-VLAN dhcpcd or router advertisements can install a competing IPv6
  default route. Disable dhcpcd and unsolicited RA acceptance in focused
  route tests for a deterministic FIB.
- IPv4 `ip route get ... iif lo` can return EHOSTUNREACH even while the
  dataplane is live. Use the from-source lookup without `iif lo`.

## MTU

- Underlay 1500 with WireGuard overhead 80 (IPv4) and 96 (IPv6) gives a
  dual-safe WG MTU of 1404. The legacy v4-only `mtu = 1420` derivation is
  too large for IPv6 on a 1500 underlay.
- Boundary probes at MTU 1404 were: IPv4 payload 1376 succeeds, 1377 fails;
  IPv6 payload 1356 succeeds, 1357 fails. Packets recover after the failed
  probe.
- Native Cilium uses the WG MTU directly; there is no VXLAN `-50` budget.

## Scratch-probe hygiene

- Keep probe logs under `.baton-pass/vm-logs/`; `/tmp` is wiped on reboot.
- Run one probe at a time. Remove scratch registrations and probe files after
  extracting the lesson so they cannot leak into a final commit.
- A dirty-tree VM run can invalidate clan-core `merged-test-dir-*` IFD
  products. Materialize every check with `nix eval
  .#checks.x86_64-linux.<name>.drvPath` before `nix flake check --no-build`
  when the store is cold.
