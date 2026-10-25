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
  ping/BGP assertions, and capture full `wg show` on failure.
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
  .#checks.x86_64-linux.<name>.drvPath` before `nix flake check --no-build`
  when the store is cold.
