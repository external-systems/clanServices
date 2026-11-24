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
- IfState 2.5.1 ignores routes of `proto dhcp` (16) and `proto ra` (9)
  and dynamic addresses by default. `ifstatecli check` prints `ok`,
  `= <value>` or `orphan` for unchanged objects and exits 0 either
  way; tests use `tests/ifstate-noop.nix`.
- A test node that sends RAs must forward IPv6, or Linux hosts drop it
  as default router seconds after first use (`specs/netif.md` §7).
- `nix fmt` is org-pkgs treefmt (alejandra and the org linters; see rule 2).
