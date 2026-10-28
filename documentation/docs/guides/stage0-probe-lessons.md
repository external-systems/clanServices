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
  pod blocks. FRR prints the route type before the prefix (`B>* ...`),
  followed by the metric; RIB assertions must match `B>.*<prefix>`, not
  `<prefix>.*B>`.
- The kernel rejects IPv6 routes whose next hop is a LOCAL address. A
  rewritten local IPv6 transport next hop is therefore harmless but cannot
  kernel-install a self route.
- `bgpd` refuses `neighbor <own-address>`; only the loopback `::1` peer
  shape works for local Cilium peering.
- Numbered IPv6 eBGP over point-to-point WireGuard requires an IPv6
  link-local address on the local interface in FRR 10.7.1; without one,
  bgpd reports `nexthop_set failed` and resets the session. networkd does
  not supply one automatically with `LinkLocalAddressing=no`. Assign a
  deterministic per-adjacency `fe80::…/64` in the same networkd `address`
  list as the `/31` + `/127` transfer addresses. A separate `ip addr`
  oneshot races networkd, which removes the unmanaged address.
- IPv6 text generated from a hash must retain the four-hex-digit group
  boundaries: `fe80::624375b692d8c54c` is invalid, while
  `fe80::6243:75b6:92d8:c54c` is valid. Changing `/64` to `/128` cannot
  repair malformed address text.
- FRR 10.7.1 installs received IPv6 routes through the peer's scoped
  link-local next hop by default. Assert `via fe80::… dev <wg>` and packet
  forwarding rather than requiring the ULA transfer next hop.
- Point-to-point transfer addresses are link-scoped. Fabric-originated
  traffic must use the stable global `/32` + `/128`, not an adjacency or
  underlay source. Scope alone is insufficient on a multihomed host:
  `ip protocol bgp route-map` and `ipv6 protocol bgp route-map` apply
  route-maps with `set src <stable-address>`, so Zebra installs both
  families with the correct preferred source. This fixed member-to-member
  return routing without redistributing transfer prefixes.
- The two-node sandboxed probe proved the existing two numbered eBGP
  sessions, both BFD monitors, dual-AF RIB/FIB installation, and IPv4/IPv6
  forwarding. Both sessions and monitors remained up throughout a
  30-second continuous check (`ROUTED_FABRIC_LINK_LOCAL_OK`). The full
  four-node suite subsequently passed all member/hub and member/member
  pings, both AFs and BFD, RIB/FIB, and MTU checks
  (`ROUTED_FABRIC_TRANSPORT_OK`).

## IfState 2.5.1 migration probes (2026-10-27)

- Pin the package with `overridePythonAttrs`, not a version-only
  `overrideAttrs`: 2.5 moved to the `src/` layout and `uv_build`. The pure
  pyroute2 variant built successfully. Package metadata is authoritative:
  upstream 2.5.1 still prints `ifstatecli 2.5.0`.
- Import the shared IfState base once per machine, not once per service
  instance. Set `nixpkgs.overlays` instead of assigning
  `networking.ifstate.package`; overlays compose across netif,
  routed-fabric, and wireguard-mesh while package options are unique.
  `perInstance` is the right place for links/routes, `perMachine` for the
  base and cross-instance checks.
- IfState settings must be keyed by actual Linux interface names, not netif
  logical labels. Also stringify hook derivations (`"${script}"`): placing a
  derivation directly in the YAML settings tree recurses during
  serialization. `lib/ifstate.nix`, `inputs.pkgs.overlays.ifstate`, and
  `tests/ifstate-vm.nix` are the current composition points; the package
  overlay itself lives in the external-systems/pkgs artifact repo.
- IfState is a full reconcile, so VM proof must include a changed candidate,
  `ifstatecli check`, and restoration, not just initial boot. The netif VM
  changed an address live with no reboot, preserved the other links, and
  restored the original (`NETIF_IFSTATE_LIVE_OK`, log
  `.baton-pass/vm-logs/ifstate-netif-live-17.log`). Candidate YAML copied
  from the Nix store must be made writable. The packaged `yq` is the Python
  variant and requires `-y` with `-i`; `yq -i` alone is rejected.
- Global forwarding belongs in `sysctl_conf`. The structured global IPv4
  lookup failed with `reading sysctl ipv4/ip_forward failed: No such file or
  directory`, leaving `net.ipv4.ip_forward = 0` and dropping transit at a
  spine. Rendering
  `net.ipv4.ip_forward = 1` and `net.ipv6.conf.all.forwarding = 1` through
  `sysctl_conf` fixed it. Failure evidence:
  `.baton-pass/vm-logs/ifstate-routed-fabric-23.log`; passing transport and
  spine-HA evidence: `.baton-pass/vm-logs/ifstate-routed-fabric-24.log`.
  Packet capture before the fix showed the frame arriving at the spine with
  no forwarding, despite correct RIB/FIB and WireGuard ACLs.
- WireGuard private keys use a runtime `!include` string and root-owned
  `0400` vars files with `restartUnits = [ "ifstate.service" ]`. Do not put
  keys in settings or store text. IfState creates transfer addresses and
  peers correctly; the mesh suite passed real dual-stack handshakes
  (`.baton-pass/vm-logs/ifstate-wireguard-mesh-20.log`).
- The shared base ignores Cilium interface names and table 200 so live apply
  does not delete Cilium-owned links or policy rules. FRR BGP routes need no
  duplicate IfState routes: Zebra owns them. k3s and RKE2 single-node tunnel
  suites subsequently passed API, Cilium health, Service, and DNS probes
  (`.baton-pass/vm-logs/ifstate-k3s-single-28.log` and
  `.baton-pass/vm-logs/ifstate-rke2-single-30.log`).
- Test underlays need the same dual-stack addresses as the inventory's BGP
  peers. Replacing the test driver's addresses with IPv4-only left the
  `2001:db8:1::/64` upstream session `Active`; restore both families before
  diagnosing FRR. Static VM underlays also need a deterministic resolver:
  CoreDNS otherwise exits with `plugin/forward: no valid upstream addresses
  found`. The external-DNS suites must still use their dedicated DNS VM, not
  the placeholder, to avoid a `plugin/loop`.
- A oneshot's `Result=success` can be observed while it is still activating.
  Wait for the actual resource or inactive state before asserting bundle or
  manifest contents. k3s's ConfigMap appeared after the first premature
  query, and RKE2's deployer removed `rke2-cilium.yaml` after the first
  premature query.
- A per-interface hook's `name` must exactly match its key under
  `parameters.hooks`: keying the definition by the logical link while the
  reference used the namespaced hook name produced `Hook ... is unknown!`
  and no client. The eval suite now checks that registration/reference
  parity. Failure: `.baton-pass/vm-logs/ifstate-netif-dhcp-39.log`.
- systemd's default `KillMode=control-group` kills hook-started DHCP
  clients when the IfState oneshot deactivates. Set
  `systemd.services.ifstate.serviceConfig.KillMode = "process"` so
  persistent hook daemons survive. The DHCP suite re-applies IfState,
  requires exactly one client, preserves DHCPv4/default-route and SLAAC,
  and finishes with a clean check. Evidence:
  `.baton-pass/vm-logs/ifstate-netif-dhcp-final-48.log`.
  `dhcpcd -p` did not yield a usable pidfile record here; per-interface
  process detection made start/check actions idempotent instead.
- `wg show all latest-handshakes` fields are interface, peer public key,
  timestamp: check `$3`, never `$2`. Four-node endpoint fixtures should
  export literal underlay IPs, not VM hostnames whose default gamma/delta
  mappings can contradict forced addresses. Wrong endpoints repeatedly
  failed `/cacerts` with EOF before Kubernetes started; literal IPs fixed
  it. Both fixes are in the native/tunnel data-plane and ClusterMesh
  fixtures.
- Default ClusterMesh `placement = "voters"` selects server nodes only.
  A one-server/one-agent fixture has one apiserver replica and one
  advertiser, not two. Assert desired replicas and placement before
  checking its route; do not invent ECMP for an agent with no backend.
- Global-Service backends are eventually consistent. Twenty immediate
  requests can see only the local backend even with healthy peering. Use a
  bounded poll that still requires both backends. The final IfState
  native/tunnel/selective/external ClusterMesh matrix and both native
  data-plane suites pass with these assertions.

## systemd-networkd and netif

- NixOS VM networking renders generic `40-ethN.network` units. Netif units
  must sort before them: `40-netif-*` loses first-match selection, so the
  trunk never receives its VLAN drop-in. `10-netif-*` preserves coherent
  instance namespacing while taking precedence; the sandboxed VM proved
  `eth4.10` creation and addressing with this prefix.
- An empty bridge has no carrier, and networkd therefore leaves its static
  address unconfigured by default. Bridge links need
  `ConfigureWithoutCarrier=yes`; this made the provider-MAC-style empty
  `virbr0` receive its declared address in the netif VM.
- Link existence is not address-readiness. Wait for all required addresses
  and policy rules before asserting them; the first immediate IPv4 check
  raced networkd even though the address appeared moments later.

## Cilium 1.20.3 BGP and the artifact base

- With `defaultLBServiceIPAM=nodeipam`, Cilium 1.20 sends every unset-class
  Service to Node IPAM, even when its labels match a pool. The k3s runtime
  probe showed pool-labelled Services receiving node IPs instead of their
  requested VIPs. Every explicit pool draw therefore uses
  `io.cilium/bgp-control-plane`, one of only two recognized LB-IPAM classes;
  `io.cilium/lb-ipam` does not exist. The class requests allocation, not
  automatic advertisement, so non-BGP pools remain unannounced unless a BGP
  advertisement selects them. Keep `bgpControlPlane.enabled=true` to
  register the class even when `bgp.enable=false` renders no BGP resources.
  The failed evidence is in
  `.baton-pass/vm-logs/k3s-data-plane-resume-17.log`.
- `ip route show <prefix>` and `ip -6 route show <prefix>` exit zero even
  when no route matches and output is empty. Negative route assertions and
  withdrawal waits must pipe through `grep -q .` (or explicitly test for
  empty output); exit status alone proves nothing. JSON multipath routes
  have `.nexthops`, but a single-path route has a direct `.gateway`; using
  the multipath shape for owner-only routes times out despite the correct
  FIB.
  Evidence: `.baton-pass/vm-logs/k3s-data-plane-explicit-pool-class-18.log`
  and `k3s-data-plane-route-absence-19.log`.
- Requested dual-stack VIPs must each belong to a matching pool block.
  `fd20:db8:2::130` and `fd20:db8:1::100` are outside `/120` blocks; Cilium
  allocated only the valid IPv4 request. The fixtures now use `/112`, and
  both the IPv4 and IPv6 routes are asserted. Border `ownedPrefixes` must
  cover the same blocks or FRR suppresses the upstream route.
- RKE2 agent nodes must wait for `rke2-agent.service`, not
  `rke2-server.service`. The wrong unit produces a misleading
  `inactive and there are no pending jobs` failure after slow image imports.
- Early Zebra `Gateway can not be a local address` / `Route install failed`
  messages can be startup races while stable addresses appear. Do not use
  log absence as acceptance: require the final RIB/FIB and packet probes.
  `.baton-pass/vm-logs/k3s-data-plane-gateway-and-border-21.log` contains
  those early errors and later reaches `K3S_DATA_PLANE_OK`.
- The chart has no `installIptablesRules` Helm value. Setting that value is
  a silent no-op. Use `extraConfig."install-iptables-rules"`, which renders
  into `cilium-config`. Cilium 1.20.3 exits fatally when KPR/BPF masquerade
  is combined with `install-iptables-rules=false`: its startup validation
  requires the rules. The Stage-0 native/FRR probe had not changed the
  default and therefore did not prove the disabled-rules combination. The
  canonical profile uses `true`; VM tests require the `iptables-nft`
  backend, Cilium datapath rules, and no legacy-iptables or kube-proxy
  rules. Do not reject every `KUBE-*` chain: the kubelet creates
  `KUBE-FIREWALL`, `KUBE-IPTABLES-HINT`, and `KUBE-KUBELET-CANARY` even
  without kube-proxy. Match kube-proxy chains specifically. The failed
  startup evidence is preserved in
  `.baton-pass/vm-logs/k3s-data-plane-iptables-startup-failure.log`.
- `cilium status` can return while its own output still reports the agent
  DaemonSet unavailable. Wait for `kubectl -n kube-system rollout status
  daemonset/cilium` before asserting agent-created iptables rules or other
  datapath state; otherwise the test races agent initialization.
- Setting `nodePort.directRoutingDevice` in the profile is insufficient:
  layer 2 must also emit `direct-routing-device` in `cilium-config`. Without
  that translation Cilium 1.20.3 repeatedly exits with `unable to determine
  direct routing device` after initially starting its BGP session.
- `cilium-config` is cluster-wide, but per-adjacency WireGuard interface
  names are machine-local. Copying the cluster-init node's direct device to
  every agent makes the other agents fail startup. Always export the stable
  routed-fabric loopback and use it as the uniform `directRoutingDevice`;
  retain the per-adjacency interfaces in the broader `devices` set. More
  generally, never put `eth0` on one machine and `eno1` on another into a
  shared direct-device value. A shared `devices` union and a uniform direct
  device are separate concerns. Do not assume that auto-detection or a
  wildcard will choose the intended interface on a multihomed host.
- ClusterMesh certificates need both upstream's mandatory loopback SANs and
  the published endpoint SANs. Cilium 1.20.3's
  [certificate helper](https://github.com/cilium/cilium/blob/v1.20.3/install/kubernetes/cilium/templates/clustermesh-apiserver/_helpers.tpl)
  always adds `127.0.0.1` and `::1`; local apiserver/etcd clients fail
  without them. Include those plus the internal VIP, selected NodePort
  addresses, or external DNS name as applicable, and regenerate certificates
  when that endpoint set changes.
- Vars files marked `deploy = false` do not exist on the target machine. A
  runtime Secret-apply unit cannot read them from a generator's `$out` or
  `$in` directory: those paths exist only during generation. Deploy the leaf
  certificates and keys needed at runtime, but keep the CA private key
  generation-only. Also check every input with `test -s` before encoding:
  `set -e` did not stop a `base64` failure inside a command substitution used
  as a `jq` argument, and the unit applied an empty `tls.key`, causing
  `tls: failed to find any PEM data in key input`.
- `kubectl` finding the Rancher kubeconfig by default does not configure the
  Cilium CLI. Set `KUBECONFIG` explicitly in VM nodes; otherwise `cilium
  status` tries `localhost:8080`, which is a harness configuration error,
  not evidence of an unhealthy agent. Bound diagnostic `cilium` commands
  with `timeout`, and collect agent and every apiserver container's logs so
  the failure dump itself cannot hide the original failure behind a hang.
- Peering success is not exposure-path success. Keep direct health checks
  from every node, cross-cluster traffic, global-Service, and withdrawal
  assertions separate so a working control plane cannot mask an untested
  Service path. The ClusterMesh etcd endpoint requires a client certificate:
  an unauthenticated health probe can complete TCP and begin TLS, then fail
  with `tlsv13 alert certificate required`. VM health checks must use the
  deployed CA/client certificate/key and require HTTP 200; accepting a
  timeout or treating that TLS failure as a datapath outage hides the actual
  result. Evidence: `.baton-pass/vm-logs/k3s-clustermesh-native-round17-12.log`.
- JSONPath assertions must match Kubernetes output, not YAML intuition:
  `.spec.ipFamilies` prints `["IPv4"]`, not `[IPv4]`. Asserting element zero
  is the simpler exact check when only single-stack is allowed.
- The chart always renders an inert `tunnel-protocol: "vxlan"` key in native
  mode. Native mode and no `cilium_vxlan` device are the real datapath
  assertions; do not require the chart template key itself to disappear.
- One Cilium BGP v2 session at `::1`, with no `localPort`, carries both
  address families. IPv4 NLRI rides the IPv6 transport when FRR enables
  extended-next-hop.
- Multi-pool advertisements are `CiliumPodIPPool` advertisements. Cilium
  advertises the node's per-family pool allocations (for example /24 and
  /64), not the whole pool CIDR and not `PodCIDR`.
- `node-bgp` ownership cannot come from a shared PeerConfig plus ETP Local:
  every healthy node would advertise the VIP. Render one PeerConfig per node
  and select common pod/shared advertisements plus only that node's
  owner-pool advertisements with a per-node label. The eval suite proves the
  owner has the node-VIP object and the other node does not.
- Cilium's `peerASN` is the per-machine `routed_fabric.asn`, not a
  cluster-wide fallback host ASN. Thread that export through both distros
  into each node's ClusterConfig; the reverse direction is the cluster's
  `kube_cluster.bgp.ciliumAsn` consumed by routed-fabric.
- The host-side Cilium neighbor is not an FRR fabric adjacency: it needs
  `neighbor ::1 capability extended-nexthop`, strict import/export
  route-maps, and stable-address next-hop rewriting, but no `bfd` (Cilium
  has no BFD). Keep its timers on the Cilium PeerConfig. FRR 10.7.1 rejects
  `set ipv6 next-hop <addr>` as an unknown command; use `set ipv6 next-hop
  global <addr>`. A running `frr.service` and Established sessions do not
  prove the whole integrated config loaded — also reject `Unknown command`
  and `Configuration file ... processing failure` in the FRR journal.
- A successful bootstrap SSA apply does not mean Cilium CRDs or their
  custom resources are ready for queries. Wait for every required pool/BGP
  object with `wait_until_succeeds`; the presence of one pool does not imply
  that per-node ClusterConfigs, PeerConfigs, and Advertisements all exist.
- Native-routing CIDR containment and BGP⇒fabric belong in eval assertions:
  manual-address clusters have no routed-fabric-owned FRR at `::1`, so the
  default fabric/BGP plane must be explicitly disabled there.
- Do not collect same-fabric `kube_cluster` exports into an attrset keyed by
  the fabric reference: every cluster has the same key, so `listToAttrs`
  silently discards all but one. Preserve a list. Otherwise only one cluster
  gets local `::1` neighbors and cross-cluster pod routes; the native VM
  exposed this as two active (never established) sessions. The regression
  needs two clusters in one fabric, not two nodes in one cluster.
- `cilium bgp peers` is cluster-wide, not local-node-only. A two-node cluster
  reports two rows; require both to be `established` instead of expecting
  one. Evidence: `.baton-pass/vm-logs/k3s-clustermesh-native-round17-22.log`.
- Rolling replacements make raw pod counts racy: a ready deployment can
  briefly have an extra terminating pod. Assert the Deployment's desired
  replica count plus per-node placement, not the total number of pod objects.
- Generate nontrivial JSON patches with `jq` rather than balancing shell and
  Nix braces. The external-LB fixture's hand-written status patch repeatedly
  failed API decoding; `jq -nc --arg ip "$ip" ...` made the payload directly
  validatable. Also use `test -z "$(...jsonpath...)"` for absent values —
  zero-byte output does not give `grep '^$'` a line to match.
- The external suites had three independent fixture failures. Per-node
  dnsmasq on each node's own resolver address caused a fatal CoreDNS
  `plugin/loop`; the completed `deployment/coredns` capture proved it.
  Starting the fake external LoadBalancer only after both clusters and
  Cilium are healthy also let the previously stalled RKE2 etcd joins finish.
  A dedicated transport-attached DNS VM with `no-resolv` now serves the real
  A records (native `access = "admin"`; explicit pod return routes for the
  tunnel profile). Use `bind-dynamic` while its stable address appears, and
  keep the address in the same first-match `10-dns.network` unit as its
  routes: a routes-only unit shadows `40-eth1.network` and silently leaves
  the underlay unnumbered.
- Explicit per-node underlay addresses must REPLACE the NixOS VM defaults,
  not merge with them. Plain `networking.interfaces.eth1.ipv4.addresses`
  left default addresses on gamma and delta, duplicating `192.168.1.3` on
  both. Delta then routed gamma's WireGuard endpoint to itself and repeated
  k3s `/cacerts` failures until the join timeout. `lib.mkForce` on the
  explicit address list removed the duplicate; both tunnel suites then
  passed. Evidence: failure
  `.baton-pass/vm-logs/k3s-clustermesh-external-tunnel-initial-54.log`;
  passing `.baton-pass/vm-logs/k3s-clustermesh-external-tunnel-underlay-force-56.log`.
- All four external suites pass on the final shared fixture: k3s/RKE2,
  native/tunnel, with real DNS, authenticated external-LB health checks and
  bidirectional ClusterMesh status. The tunnel runs also assert
  `routing-mode=tunnel`, `tunnel-protocol=vxlan`, and MTU 1370. Final
  evidence is linked from SPEC.md §7.
- A Nix substituter timeout is not VM evidence. Keep its log separate from
  behavioral failures and materialize the required derivation before judging
  a rerun; one external-native attempt spent five retries in fetch stalls
  before the actual suite ran.

## Selective ClusterMesh and transit

- Filter selective peers in the shared mesh resolver so the remote agent and
  kvstoremesh configs plus the apiserver's remote-etcd users all see the same
  edge set. Leaving `mesh.peers = null` must keep full peering; the native and
  tunnel full-default regressions prove that path separately.
- A Kubernetes spine cannot both omit a non-peer prefix from its only kernel
  table and forward that prefix to another leaf. Keep the spine's transit
  union intact and prove A/C route isolation on non-transit leaves. This is
  the D54 routed-only exception, not a second routing stack or a reason to
  filter the spine out of B's path. ClusterMesh and global-Service isolation
  still applies on every node, including dual-shape spines.
- Cilium advertises per-node `/24` and `/64` pod allocations, not the whole
  pool. Native selective-route assertions must match those exact prefixes in
  both families; `ip route show <whole-pool>` can be empty while the intended
  allocation route exists.
- The four-node selective fixture also needed forced underlay addresses:
  alphabetical VM defaults gave gamma `.4` and delta `.3`, opposite the
  inventory. `lib.mkForce` on every node's explicit eth1 address list fixed
  the WireGuard endpoint path. Evidence:
  `.baton-pass/vm-logs/k3s-clustermesh-selective-native-readiness-24.log`.
- Do not accept a ClusterMesh name or `status --wait` alone. Authenticated
  HTTP 200 checks prove each published endpoint, and global-Service backend
  sets prove non-transitive synchronization. All four selective suites and
  the four full-default suites pass on the final tree; evidence is linked
  from SPEC.md §7.

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

- Declare every required test NIC with `virtualisation.vlans`: `eth0` is
  the management NIC and `eth1`…`ethN` follow the declared VLANs. A netif
  test that expects `eth2`…`eth4` but declares only the default topology
  fails before exercising the service renderer.
- `wg show interfaces` prints one space-separated line. Count interfaces
  with `wc -w`, not `wc -l`. Interface existence is not transport readiness:
  wait for a nonzero timestamp in `wg show all latest-handshakes` before
  ping/BGP assertions, and capture full `wg show` on failure. Its fields are
  interface, peer public key, timestamp: check `$3`, not `$2`. Build the
  test's `.driver` after generated-Python edits so type checking and linting
  fail before an expensive VM boot.
- `kubectl apply -f` does not accept a bare JSON array of resources. Render
  either multi-document YAML or a Kubernetes `v1/List` object with `items`;
  otherwise validation fails with `invalid object to validate`. Raw API
  fixtures must also use arrays for `containers` and `ports`, not kubenix's
  name-keyed merge-map form.
- Keep probe logs under `.baton-pass/vm-logs/`; `/tmp` is wiped on reboot.
- Run one probe at a time. Remove scratch registrations and probe files after
  extracting the lesson so they cannot leak into a final commit.
- A dirty-tree VM run can invalidate clan-core `merged-test-dir-*` IFD
  products. Materialize every check with `nix eval
  .#legacyPackages.x86_64-linux.vmTests.<name>.drvPath` before a VM build
  when the store is cold.
