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
- WireGuard (Linux 6.18): a packet that arrives from a peer with a
  source outside that peer's `allowed-ips` is dropped silently and
  counted only as an rx error of the interface (`ip -s link`); tcpdump
  on the interface never sees it. So an outside source crosses exactly
  the links whose ACL is 0/0 (routed-fabric `externalTransit`)
  (`routed-fabric-transit` probe, round 60, 2026-11-26).
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
- FRR 10.7.1 graceful restart is reliable for bgpd alone. `systemctl
  restart frr` stops bfdd with bgpd, and with
  `check-control-plane-failure` the outcome at the peer is a race: in
  one run the leaf dropped the node's routes at once (0.0 s), as for a
  dead node; in the next it kept them stale for over 60 s. Every
  session and route comes back after the restart either way
  (`k3s-frr-failure`, `FRR_FULL_RESTART_OK`). A
  switch to a generation with a changed valid `frr.conf` reloads FRR
  (nixpkgs `reloadIfChanged`): the bgpd PID and every session stay
  (`FRR_DEPLOY_RELOADS_OK`).
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
- k3s and RKE2 embedded etcd: the metrics port 2381 listens on loopback
  only; a peer that dials a server's node address on 2381 gets
  "connection refused" while the server runs. A k3s or RKE2 agent writes
  no kubeconfig of its own (`/etc/rancher/<distro>/<distro>.yaml` exists on
  servers only). Suites `<distro>-ha` (the init guard phases) and
  `<distro>-clustermesh`, round G11.
- `nix fmt` is org-pkgs treefmt (alejandra and the org linters; see rule 2).
- rke2 v1.37.1: CA files written into the TLS directory of a running
  server (`/var/lib/rancher/rke2/server/tls`) change nothing at once: old
  client certificates keep working, the node stays Ready and HAProxy keeps
  the backend UP for minutes. The next start is fatal and crash-loops:
  "… newer than datastore and could cause a cluster outage. Remove the
  file(s) from disk and restart to be recreated from datastore." The
  datastore holds the CA set; rotation goes through
  `rke2 certificate rotate-ca` (probe `rke2-probe-pki-sync`, 2026-11-26;
  the assertion now lives in `rke2-single`).
- kubectl 1.36: `kubectl get -o json` leaves out `metadata.managedFields`
  unless `--show-managed-fields` is given, so a filter on the field
  manager sees nothing without it. The bootstrap prune (D40) passes it
  (`k3s-single`, 2026-11-26).

## Probe round of 2026-11-27 (SPEC.md round 61)

Verified on prototypes of the target design, in VM suites on the remote
builder. A suite named `*-probe-*` or `probe-*` was a throwaway probe;
its lines are in `specs/probes/2026-11-27/`.

### Cilium 1.20.3

- With BPF host routing (`Host: BPF`), a packet that arrives on a Cilium
  device for a pod on that node is delivered by `cil_from_netdev` at tcx
  ingress. It never enters netfilter: no nft rule, in any hook, sees it.
  A packet for a pod on another node, and a packet the node relays, go
  to the stack (`k3s-probe-net`; `k3s-hostile` K40a, K41).
- Cilium gives the identity `world` to every address that is no cluster
  node and no pod, a fabric member outside the cluster included. Cluster
  nodes are `remote-node` (`k3s-probe-net`).
- A CiliumClusterwideNetworkPolicy with only `ingressDeny: fromEntities:
  [world]` and `enableDefaultDeny.ingress: false` drops new connections
  from outside to the selected pods and leaves them default-allow for
  the rest. It is stateful. The selector keys `<label>` and
  `io.cilium.k8s.namespace.labels.<label>` match pod and namespace
  labels (`k3s-probe-net`; `<distro>-hostile` K05d, K11f).
- Without `bpf-lb-source-range-all-types=true`,
  `loadBalancerSourceRanges` guards the LoadBalancer address only; the
  Service's NodePort answers every source. With it, every front is
  guarded, in both families, with `externalTrafficPolicy` Cluster and
  Local (`k3s-probe-net`).
- Source ranges never restrict a host or a pod of the cluster: their
  connections are translated at `connect()` (`k3s-probe-net`).
- A LoadBalancer address is answered by the first Cilium node on the
  path, which also judges the source ranges. A front on a node without a
  backend forwards with its own address as source (`k3s-probe-net`).
- A LoadBalancer Service with a `loadBalancerClass` that no controller
  serves gets no address, and Cilium still serves its NodePort. `cilium
  clustermesh status` cannot read such a Service; `cilium-dbg status`
  can (`k3s-clustermesh-nodeport`).
- For some seconds after an agent restart a device may hand packets for
  local pods to the stack (`k3s-probe-net`).
- Cilium's BGP client to `::1:179` runs as root: a root-only output rule
  blocks an unprivileged user and keeps the session (`k3s-hostile` P6).

### Kubernetes, k3s and rke2 1.37.1

- `spec.loadBalancerSourceRanges` and the annotation
  `service.beta.kubernetes.io/load-balancer-source-ranges` are refused
  on every Service type but LoadBalancer.
- ValidatingAdmissionPolicy and MutatingAdmissionPolicy are
  `admissionregistration.k8s.io/v1` and served by default on k3s and
  rke2. The CEL functions `isCIDR` and `cidr(a).containsCIDR(b)` work.
- A MutatingAdmissionPolicy cannot set `spec.loadBalancerSourceRanges`
  with `patchType: ApplyConfiguration` (atomic list); `patchType:
  JSONPatch` works.
- A Pod Security default is set with an AdmissionConfiguration file:
  k3s `kube-apiserver-arg: admission-control-config-file=<file>`, rke2
  `pod-security-admission-config-file: <file>`. The file must be a real
  file, not a link (`<distro>-hostile` K50–K53).
- The CA pin of a full token (`K10<pin>::<user>:<secret>`) is the
  SHA-256 of the served bundle only when it holds one certificate. For a
  chain it is the SHA-256 of the DER of the chain's root. A node with a
  pin that does not match trusts no root and stops at `/cacerts`
  (`k3s-probe-net`).
- Both distros take full tokens as `token-file` and `agent-token-file`
  on the founding server and on joiners.
- `config.yaml.d/*.yaml` beats `config.yaml`. A command-line flag beats
  both: the nixpkgs option `services.k3s.clusterInit` renders
  `--cluster-init`.
- rke2 does not know the keys `cluster-init` and
  `disable-helm-controller` (`Unknown flag … skipping`). An rke2 server
  founds a cluster when it has no `server:`. A k3s server does not know
  `disable-apiserver-lb`.
- A server whose etcd data is gone rejoins as a new member when it has
  `server:` set and its node object was deleted on a live server. With
  the old node object: `etcd cluster join failed: duplicate node name
  found`. The live servers remove the stale etcd member and the
  node-password secret with the node (`<distro>-probe-rejoin`).
- A join that fails leaves `server/db/etcd` behind. If that server then
  starts without `server:`, k3s starts an etcd for a new cluster
  (`k3s-probe-rejoin`).
- An rke2 agent's tunnel to the servers (logs, exec) dials each server's
  node address on the port of the agent's `server:` URL
  (`rke2-hostile`).
- A host-network pod reads the node's `/etc/hosts`.
- rke2 with `--profile=cis` boots with Cilium from the bundle, runs etcd
  as the user `etcd`, and creates `default-network-policy` objects in
  `default`, `kube-public` and `kube-system` (`rke2-probe-cis`).

### FRR 10.7.1 and its nixpkgs unit

- `neighbor X ttl-security hops 1` on an eBGP neighbor with `bfd` makes
  its BFD session multihop (`BFD: Type: multi hop`, UDP 4784, no
  interface, `minimum-ttl 1`). With 4784 closed BFD stays down while BGP
  is Established. Without it the session is single hop on 3784 with TTL
  255 (`probe-fabric-session`).
- With graceful restart, a second TCP connection to 179 from an
  Established peer's address restarts that session (`hostile-fabric`
  F23d).
- `frr.service` has `Restart=always`, `RestartSec=5`,
  `StartLimitBurst=3`, `StartLimitIntervalSec=180`. An `ExecStartPre`
  that fails at once ends in `start-limit-hit`; one that waits 80 s is
  retried forever (`hostile-fabric` F26, `probe-fabric-boot`).
- zebra with `-r`: the kernel keeps BGP routes when FRR stops or fails
  to start (`hostile-fabric`).

### Jool 4.1.15

- In netfilter mode Jool translates with
  `net.ipv4.conf.all.forwarding=0` and
  `net.ipv6.conf.all.forwarding=0` in its namespace, NAT64 and SIIT
  (`nat-gateway`, `nat-gateway-hostile`).
- In Jool's namespace a netfilter base chain at prerouting priority 0
  sees only packets Jool did not translate; a chain at postrouting sees
  every translated packet. With both at `policy drop` and accepts for
  the translator's own sources no legitimate packet is dropped
  (`nat-gateway`: `guard-leftover` and `guard-leaving` are 0 after every
  traffic shape).
- With no instance in a namespace Jool hands every packet back to the
  kernel (`nat-gateway-hostile` N10, C06).
- On a full pool4 Jool drops a new flow in silence:
  `JSTAT_BIB6_NOT_FOUND` counts it, no ICMPv6 error is sent, the packet
  is not handed back (`nat-gateway-hostile` N16).
- `jool -i <instance> global update` takes `udp-timeout 0:05:00`,
  `icmp-timeout 0:01:00`, `address-dependent-filtering true`,
  `drop-externally-initiated-tcp true`, and can be run at every start.

### nftables

- `ip6 daddr & ::ffff:ffff @set` (bitwise AND, then a lookup in an
  interval set of `ipv6_addr`) loads and matches the embedded IPv4
  address of an RFC 6052 /96 (`nat-gateway-hostile` N05, C01).
- Rulesets are per network namespace: a restart of `nftables.service`
  leaves a namespace's tables byte-equal (`nat-gateway`,
  `NAT_GATEWAY_GUARD_RESTARTS_OK`).
- A veth end in a quiet namespace receives multicast link chatter after
  boot (13 to 19 packets). `meta pkttype != host` matches it
  (`nat-gateway`).
- In one flood all echo requests are one conntrack flow: a rate limit
  behind `ct state established accept` never applies (`hostile-router`
  R20).
- `iifname vmap { "x" : goto c }`, wildcard names in anonymous sets, and
  a filter chain on `postrouting` in `inet` (it sees local packets) all
  load. A chain at `prerouting priority raw` counts before the NixOS
  reverse-path chain (`hostile-fabric`).
- `tcp option maxseg size set rt mtu` at `forward priority mangle` in an
  `inet` table clamps both families (`probe-transit-split` T07).
- A reload or restart of `nftables.service` resets no BGP or BFD session
  (`hostile-fabric` F27).

### IfState 2.5.1

- Routes with `type = "unreachable"` apply in the main table and in
  `namespaces.<ns>.routing.routes`; the metric key is `preference`; a
  reapply is a no-op (`nat-gateway`, `NAT_GATEWAY_IFSTATE_OK`;
  `k3s-data-plane`).
- A per-interface `sysctl.ipv4` takes `accept_redirects`,
  `secure_redirects`, `send_redirects`, `accept_source_route`,
  `arp_ignore`, `arp_announce`; `sysctl.ipv6` takes `accept_redirects`,
  `accept_source_route`, `accept_ra`, `autoconf`, `accept_ra_defrtr`,
  `accept_ra_pinfo`, `accept_ra_rt_info_max_plen`, `accept_ra_mtu`,
  `accept_ra_min_hop_limit`, `use_tempaddr`; a reapply with them changes
  nothing (`netif-hostile`, `netif`). A per-link `rp_filter = 0` reads 2
  afterwards (`hostile-fabric`).
- A WireGuard peer takes `preshared_key` with `!include`
  (`hostile-fabric` P3).
- A missing physical link is a warning and exit 0; a main-table route
  with `proto bgp` is left in place on an apply (`netif-probe-tx`,
  `netif-guard`).

### Linux 6.18, systemd, udev

- With `net.ipv6.conf.all.forwarding=1` (a CLAT) a host forwards IPv6
  between all its links (`nat-gateway-hostile` C08, negative proof).
- With `arp_ignore = 0` a host answers ARP on its LAN NIC for an address
  of a dummy link; `arp_ignore = 1` stops that and keeps the NIC's own
  address answering (`hostile-fabric` F20).
- `ip link set <wireguard> down` flushes the link's IPv6 addresses; an
  IfState apply restores them.
- ECMP hashes on source and destination address by default: all flows
  between two members share one next hop.
- A new link takes every `net.ipv{4,6}.conf.default.*` value at creation
  (veth, bridge, bridge port, dummy, WireGuard). A link that existed
  before `default` was written keeps the old value (`netif-hostile`).
- With `accept_ra = 1` and `accept_ra_defrtr = 0`,
  `accept_ra_rt_info_max_plen = 0`, `accept_ra_mtu = 0`,
  `accept_ra_min_hop_limit = 64`, an advertisement gives the prefix and
  a SLAAC address and nothing else (`netif-hostile` H16).
- systemd-sysctl: a glob key (`net.ipv4.conf.*.accept_redirects`) is
  applied to every link that exists when `systemd-sysctl.service` runs,
  and to each link that appears later (`99-systemd.rules` runs it on the
  `add` event) (`netif-hostile`).
- A oneshot unit without `RemainAfterExit` that `multi-user.target`
  wants is started again by every `switch-to-configuration
  switch|test`, changed or not; the switch waits for it and exits 4 when
  it fails (`netif-guard`, `netif-probe-tx`).
- A unit started with `--no-block` from inside `ifstate.service` (still
  activating at boot) runs at once; there is no ordering cycle as long
  as the started unit has no `After=ifstate.service` (`netif-probe-tx`).
- When a link is renamed after its `add` event, udev emits `move` with
  `KERNEL` equal to the new name. `systemd-escape --template=` gives a
  usable instance for a name with `-` (`netif-probe-tx`).
- NixOS `system.preSwitchChecks` runs before a `switch-to-configuration
  test` too and gets the action as `$2`; a failing check stops the
  switch before any unit is touched (`netif-modes`).

### dhcpcd 10.5.2 and radvd 2.21

- dhcpcd applies options it never requested when a server sends them:
  option 121 as routes, option 26 as the `mtu` attribute of every route
  of the lease (the link's MTU is not changed). `nooption <name>` stops
  them (`netif-hostile`).
- A `/32` lease with a router outside the subnet gets a host route to
  the router and the default route, without option 121; routes carry
  `proto dhcp` (`netif-probe-tx`).
- dhcpcd takes about 10 s from start to a bound lease with its default
  settings (it probes the offered address by ARP) (`netif-probe-tx`).
- radvd refuses an interface whose `MinRtrAdvInterval` is below 3 s or
  above 3/4 of `MaxRtrAdvInterval`: with `MaxRtrAdvInterval 4` alone it
  logs the error and sends nothing, and `systemctl start radvd` still
  succeeds. A rogue-RA fixture needs `MinRtrAdvInterval 3` and a control
  that the RA arrived (`netif-hostile`, `hostile-router` R15).

### clan vars

- A generator with `share = true` and a secret file, declared on two
  machines, deploys to those two only, under
  `/run/secrets/shared/<generator>/` (`hostile-fabric` P3).
