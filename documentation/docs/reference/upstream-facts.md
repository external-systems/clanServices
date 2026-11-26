# Verified upstream facts

Upstream behaviour that the specs depend on. Each fact was verified by
a probe or a VM suite; the place is named where it is known. Agents:
read the section of a component before changing code that touches it.

- IfState 2.5.1 deletes every named network namespace it does not
  know, including the CNI's `cni-<uuid>` pod namespaces; the `cilium`
  registry owner claims `^cni-`. An address declared with a `scope`
  that the kernel does not keep (any IPv6 address) is deleted and
  re-added on every apply. `ifstatecli check` pads its columns, so a
  long object name leaves one space before its operation
  (`k3s-data-plane-netif`, 2026-11-17).
- IfState 2.5.1: `ifstatecli apply` fully reconciles declared objects;
  `ifstatecli check` is the dry run. Runtime `!include` keeps secrets out
  of the store. `KillMode=process` preserves hook daemons; global
  forwarding uses `sysctl_conf`. Package metadata is authoritative even
  though upstream 2.5.1 prints `ifstatecli 2.5.0`.
- Cilium 1.20: native routing delegates non-local pod traffic to the
  kernel FIB; off-L2 nodes therefore need FRR-distributed pod-pool routes.
  Multi-pool uses `CiliumPodIPPool` advertisements. ClusterMesh requires
  the same datapath, non-overlapping pod CIDRs, node connectivity, and
  native-routing CIDRs covering all meshed pods. Cilium has no BFD.
  LB IPAM allocates; delivery is separate. Node IPAM advertises node IPs
  for classless LoadBalancer Services; its ETP-Local EndpointSlice caveat
  affects only Cilium's own Gateway/Ingress (dummy Endpoints), which stay
  disabled (D1/D41). The chart ships no `crds/` dir.
- FRR 10.7: one integrated `services.frr.config`; Zebra installs routes;
  eBGP ECMP needs `maximum-paths` and often multipath-relax; Cilium's
  loopback next hop needs reserved-range/martian handling and rewrite;
  FRR-FRR paths can use BFD. WireGuard ECMP requires one peer per
  interface and multiple interfaces, never overlapping peers on one
  interface. FRR 10.7.1 reload starts newly enabled daemons without
  restarting bgpd (probe-verified 2026-10-24).
- FRR 10.7.1 on NixOS: when `frr.conf` has a line vtysh rejects,
  `frrinit.sh reload` (the unit's `ExecReload`) logs
  "vtysh failed to process new configuration" and still exits 0. systemd
  logs "Reloaded FRRouting" and `switch-to-configuration` exits 0. FRR
  keeps the running config, bgpd and every session. A broken FRR config
  deploys green; only the journal shows it. nixpkgs has no build-time
  check (`k3s-frr-failure`, `FRR_BAD_RELOAD_OK`); this repo adds one
  (`lib/frr-check.nix`).
- FRR 10.7.1: `vtysh --config_dir DIR --dryrun --inputfile FILE` runs
  in the Nix sandbox and exits non-zero on a line it rejects (2 for an
  unknown command, 4 for an incomplete one). It checks syntax only: a
  neighbor command for an undefined peer exits 0 (`checks.frr-conf`).
- FRR 10.7.1: bgpd aborts with `bgp_fsm.c:541: bgp_connect_timer():
  assertion (!connection->t_read) failed` when a neighbor's
  ConnectRetry timer expires while its DelayOpen timer runs. With
  `timers connect 5` beside `timers delayopen 5` both end together:
  seen in suite logs since 2026-11-18 (`rke2-clustermesh`,
  `netif-modes`, `k3s-clat`), about one boot in some dozens. watchfrr
  starts bgpd again, so most suites passed. This repo renders
  `timers connect 10` on every neighbor with DelayOpen. Whether that
  closes it is a claim from the timer arithmetic and one full run
  without the assertion, not a proof.
- FRR 10.7.1 graceful restart: with `bgp graceful-restart` on both
  ends, a peer keeps the routes of a bgpd that was killed
  (`k3s-frr-failure`); with `neighbor … bfd
  check-control-plane-failure` a peer whose machine died is dropped
  when BFD fails, not after the restart time (`FRR_DEAD_NODE_OK`).
- FRR 10.7.1: watchfrr restarts a bgpd killed by SIGKILL; every
  session comes back without action (`k3s-frr-failure`,
  `FRR_BGPD_CRASH_OK`).
- GitOps handoff (D40): Flux prune garbage-collects only the
  Kustomization's own `.status.inventory`; bootstrap with
  `kubectl apply --server-side` avoids CSA→SSA field-ownership friction;
  `cilium install` (CLI) auto-detects hidden values and skews cert
  generation — rejected as the bootstrap mechanism.
- dhcpcd 10.3.2: a DHCPv6 address socket is closed before it leaves the
  event loop (`ipv6_freeaddr`), so after a carrier change DHCPv4 or
  DHCPv6 does not recover (`eloop_event_add: No such file or directory`;
  upstream issue 596, fixed in 10.5.0). org-pkgs `overlays.ifstate`
  has upstream 10.5.2 as `pkgs.dhcpcd_latest`, which netif's dhcpcd
  units run; `pkgs.dhcpcd` stays 10.3.2 with the two fix commits,
  because 10.5 does not start under the stock NixOS `dhcpcd.service`
  (nixpkgs PR 562813). dhcpcd sets `addr_gen_mode` to 1 on
  every link it runs IPv6 on, `noipv6rs` or not; `ipv4only` avoids it.
  A broken networking package is fixed in pkgs, never here: the
  upstream release first, a patch second (`specs/netif.md` N30).
- dhcpcd does not remove an address it found already on the link when
  it exits; netif's unit flushes dynamic IPv4 addresses after every
  stop (`specs/netif.md` N31). A unit file's `WantedBy=<device>` did
  not start a service in the VM; udev `SYSTEMD_WANTS` does.
- systemd 262 and `switch-to-configuration`: a unit restarted for its
  `restartTriggers` (`netif-guard.service`) can start before the
  oneshot `ifstate.service` that a switch also starts; `After=` orders
  only jobs that are queued together. netif's guard therefore names the
  configuration each apply is of (`/run/netif-guard/applying`) and
  judges nothing else (`netif-guard`, round G11). A oneshot whose
  `ExecStart` fails skips `ExecStartPost` and runs `ExecStopPost` with
  `SERVICE_RESULT` other than `success` (`NETIF_GUARD_FAILED_APPLY_OK`).
  A start or restart of a unit that `Wants=` a oneshot without
  `RemainAfterExit` starts that oneshot again: a plain restart of a netif
  dhcpcd unit runs a new IfState apply; `systemctl restart
  --job-mode=ignore-requirements` does not (`netif-dhcp`,
  `NETIF_DHCP_GUARD_KEPT_OK`).
- IfState 2.5.1 `ifstatecli apply` runs `mount` for a configuration
  with a network namespace (`FileNotFoundError: 'mount'` without it);
  the NixOS unit puts `/run/wrappers` on its path, and netif's guard
  carries util-linux for its rollback (`netif-v6only`,
  `NETIF_V6ONLY_GUARD_OK`).
- IfState 2.5.1 ignores routes of `proto dhcp` (16) and `proto ra` (9)
  and dynamic addresses by default. `ifstatecli check` prints `ok`,
  `= <value>` or `orphan` for unchanged objects and exits 0 either
  way; tests use `tests/ifstate-noop.nix`.
- A test node that sends RAs must forward IPv6, or Linux hosts drop it
  as default router seconds after first use (`specs/netif.md` §7).
- nftables 1.1.6: a named set with `flags interval` refuses two
  elements that overlap (an address inside a prefix) with
  `conflicting intervals specified`; with `auto-merge` they load as one
  interval, and an anonymous set merges them by itself. A dynamic set
  takes `ip6 saddr & ffff:ffff:ffff:ffff::` as its key in `update`
  and in a lookup (`nft -c` in a user namespace, 2026-11-26;
  `nat-gateway` loads the rules, specs/gateway.md §17).
- Jool 4.1.15: `jool pool4 display --csv --no-headers` prints
  `Mark,Protocol,Address,Min port,Max port,Iterations,Iterations fixed`,
  one line per range; `jool bib display --csv --no-headers` one line per
  held transport address, so its line count is the ports in use; `jool
  stats display --all --csv` has `JSTAT_BIB_ENTRIES` and
  `JSTAT_SESSIONS` (`nat-gateway`, `NAT_GATEWAY_POOL4_OK`).
- `nix fmt` is org-pkgs treefmt (alejandra and the org linters; see rule 2).
