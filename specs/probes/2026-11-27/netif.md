# netif probe round: findings

Recorded 2026-11-27 by the session lead from the netif probe engineer's
final report. Raw lines: `runs/<suite>.<run>.txt`. Code that ran:
`prototype.patch` (`git diff --cached origin/main` of worktree
`probe-netif`, base deeaba4, 32 files).

## State

- Worktree `~/external-systems/.worktrees/clanServices/probe-netif`:
  detached at deeaba4, everything staged, nothing committed.
- `specs/design-netif.md` rewritten there: status header, §3 with the
  code that ran, §6 verdict table, §8 steps 8.1–8.9, §9 probe table and
  the verified facts.
- NOT run: `check`, `vm-test --all`. The old guard nix-unit tests fail
  until step 6 rewrites them.

## Suites, final result

All rc 0, one at a time, `--rebuild`:
`netif-guard` (rewritten, re-run on the final tree), `netif-probe-tx`
(new, throwaway, re-run on the final tree), `netif-hostile` (extended,
run5 and run6), `netif`, `netif-match`, `netif-hotplug`, `netif-dhcp`,
`netif-modes`, `netif-vmhost`, `netif-wifi`, `netif-desktop`,
`netif-v6only`. With the ARP keys on: `k3s-join-netif`,
`k3s-data-plane-netif`.

Earlier failed runs were test-script faults (kept in `runs/`), except
hostile run1 (REFUTED 1).

## Probes

| Id | Result | Suite | Key lines |
|---|---|---|---|
| P1 boot: the transaction starts dhcpcd, gets a lease, no cycle | VERIFIED-VM. One unit is right; the R1 fallback is dropped | netif-probe-tx | `P1 ifstate.service at boot: Result=success … ExecMainStatus=0`; `ordering cycles in the boot journal: 0`; `seconds the transaction took at boot: 11.4` (11.5 on rerun) |
| P2 every switch starts and waits for `ifstate.service` | VERIFIED-VM; a failing run gives switch exit 4 | netif-guard, netif-probe-tx | `P2 switch with only a firewall change: rc=0 outcome=committed ifstate ran=True` |
| P3 sysctl glob: links at boot and later | VERIFIED-VM | netif-hostile | `P3 eth0 … all six keys '0'`; `P3 dm1, added while default was 1 … '0'`; `P3 dm0 … after a systemd-sysctl restart … '0'` |
| P4 iwd / NetworkManager IPv6 default with `default.accept_ra=0` | VERIFIED-VM for Wi-Fi (NM+iwd and iwd alone) and hot-plug. NOT-RUN: wired NetworkManager link with SLAAC (no suite has one) | netif-wifi, netif-hotplug | both rc 0; `P4 hot-plug accept_ra: {'accept_ra': '1', … 'accept_ra_rt_info_max_plen': '0', 'accept_ra_mtu': '0'}` |
| P5 /32 lease, off-subnet router, no option 121 | VERIFIED-VM: the default installs; the link declares nothing extra | netif-probe-tx | `P5 routes: default via 172.31.1.1 dev eth1 proto dhcp … ; 172.31.1.1 dev eth1 scope link` |
| P6 unrequested options 26/121 | VERIFIED-VM: applied without `nooption`; 26 becomes `mtu 576` on routes, not on the link | netif-hostile | `P6 plain dhcpcd … 10.66.0.0/16 via 10.8.0.1 proto dhcp … mtu 576`; H09–H11 SAFE |
| P7 `resolvectl default-route` | VERIFIED-VM (after a fix) | netif-hostile | `H18b … (enxdock): no`; `P7 … after a carrier flap: … no`; `P7 … when no declared link has DNS: … yes` |
| P8 `-` in a link name | VERIFIED-VM | netif-probe-tx | `P8 units: … netif-dhcpcd@wan\x2d0.service active running` |
| P9 udev `move` on rename | VERIFIED-VM | netif-probe-tx | `move kernel=wan-0 name=wan-0`; `seconds until the lease is back after a rename … no IfState run: 6.5` |
| P10 `default` copied to new links | VERIFIED-VM (veth, bridge port, dummy, bridge, WireGuard) | netif-hostile | `P10 vt0/vt1/dm0/brx/wg9 … '0'`; H20 SAFE on 16 links |
| P11 ARP keys on a kube underlay | VERIFIED-VM for k3s on the routed fabric. NOT-RUN: rke2, gateway suites, a /32 lease with the keys | k3s-join-netif, k3s-data-plane-netif | both rc 0; `HOSTILE SAFE H19 … Received 0 response(s)` |

## Decision table on real switches (netif-guard)

- Good B commits: `switch good: rc=0 outcome=committed`.
- Bad B, good L: `switch bad: rc=4 outcome=rolled-back`; marked bad; a
  restart gives `still-rolled-back` and never applies B (`ip monitor`);
  `netif-guard retry` tries again.
- Bad B during an outage stays on L (H22): `switch bad2: rc=4
  outcome=undecided`; the gateway pings the old address afterwards.
- Good B during an outage: refused (`undecided`); one restart later
  commits.
- O5 override: `switch renumber2: rc=4 rolled-back` (L answers: inert);
  `switch renumber: rc=0 outcome=committed-unproven`; the same value
  again: `rc=4 undecided`.
- N-A3: `guard run with a foreign (proto bgp) default via a silent
  gateway: rc=0 outcome=committed`.
- N-A1: boot with a missing NIC: `outcome unclean`, the DHCP link has
  its /32 address and its client; also at a switch.
- N36: `NETIF_DHCP_GUARD_SWITCH_OK`; `S1 clients restarted: wan-0=False
  side=False`.
- Client-only change and DHCP-made-static: rolled back
  (`NETIF_DHCP_GUARD_KEPT_OK`, `_STATIC_OK`).
- Per-mode last good and I12: `NETIF_MODES_IFSTATE_OK`; `FINDING I12 …
  rc=1: netif: this machine is booted in mode 'default' and the new
  configuration is mode 'developer' …`.
- H21: SAFE with a TCP target; `HOSTILE LIMIT` without one (a spoofed L2
  answer commits).
- NOT-RUN: row 6 `rollback-failed`.
- Eval checks: E1 (v4, v6, onLink, fe80), E3 and half of E6 verified by
  `nix eval` of 8 nix-unit tests. E2, E4 (code in), E5, E7–E11 NOT-RUN.

## REFUTED, and how the design changed

1. **H02–H04 "SAFE on main" were empty.** radvd refused the interface
   (`MinRtrAdvInterval … must be … no more than 3/4 of
   MaxRtrAdvInterval`); no RA was ever sent. Fixed with
   `MinRtrAdvInterval 3`. Every hostile group now has a `control`; a
   missing control fails the suite. By the code, main has that gap.
2. **udev rule:** match `KERNEL==` on `add|move`, not `NAME==`.
3. **MTU check:** dhcpcd writes option 26 as a route `mtu`. H11/H13/H18c
   read the routes too.
4. **Bundle:** hooks, mode, timeout and the override live in
   `netif-runtime.json`, outside the bundle.
   `/etc/netif/dhcpcd/<if>.conf` stays as the source of the bundle's
   files.
5. **Address obligation:** `tentative` is accepted while the link has no
   carrier (a bridge without ports).
6. **DNS writer:** `set -f` killed the hot-plug glob loop; fixed.
7. **Unclean-apply test:** built with a missing NIC, not an `!include`.

## Owner decisions written in

- O5: option `clanServices.netif.guard.replaces = "<last good bundle
  path>"`. Explicit, one-shot by construction (no state file), eval
  warning plus `netif-guard status` plus journal "WITHOUT PROOF".
  Changes row 5 only.
- O6: `accept_dad` removed (no step 9, no H17). ARP keys are step 8,
  behind the probe switch `arpHardening` (default false).
- Classless routes: `dhcp.classlessRoutes`; DNS: `dhcp.dns`; `ra`
  default false.

## NOT-RUN and why

- `checks.netif-guard-logic` table test and the nix-unit rewrite (step
  5/6 work; the rows ran on VMs instead).
- Rename `requiredForOnline` → `required`; `UNOWNED` in `netif-status`;
  `netif-guard force` as a verb.
- Suites of other areas; rke2 with the ARP keys; wired NM SLAAC.

## Things the owner should know

- Every deploy re-proves the network (P2). A deploy during an outage
  exits 4 even with no network change (nothing is touched).
- A guard target that is down turns every network change into
  `undecided`.
- Boot with a required DHCP default: `network.target` waits about 10 s
  (dhcpcd's ARP probe).
- An undeclared link present at boot keeps `accept_ra = 1` (`eth0`);
  harmless while down.

## Cross-area items

- **Router hostile suite:** `services/router/tests/vm/hostile.nix:161`
  has `MaxRtrAdvInterval 4` without `MinRtrAdvInterval 3` and no
  control: its RA verdict is probably empty too.
- **Unit rename** `netif-dhcpcd-<if>.service` →
  `netif-dhcpcd@<if>.service`; `netif-guard.service` is gone. Still
  naming the old ones: `lib/gateway/tests/vm/{dual-wan,wan}.nix`,
  `services/router/tests/vm/default.nix`,
  `services/routed-fabric/tests/vm/suite.nix:41`. Adapted already:
  `lib/kube-cluster/tests/vm/{join,data-plane}.nix`,
  `lib/gateway/tests/vm/v6only-host.nix`.
- **`ra` default false:** fixtures with an RA default need `ra = true`.
  Done: netif, netif-dhcp, v6only-host (`slaac`). To read: `wan.nix`,
  `dual-wan.nix`, the router suite, the kube IPv6 suites.
- **Kube/fabric:** the sysctl glob, the transaction and the ARP keys ran
  beside Cilium and FRR in two k3s suites without effect.

## Facts for upstream-facts.md

Wording: `specs/design-netif.md` §9, list "Verified facts", each marked
"new, step N" (13 entries: systemd-sysctl glob and udev; `default` copy;
IfState sysctl keys; radvd interval rule; RA keys; dhcpcd unrequested
options; /32 lease; `proto dhcp`; oneshot restarted on every switch;
`--no-block` start from inside `ifstate.service`; udev `move`; dhcpcd
10 s; `preSwitchChecks`).
