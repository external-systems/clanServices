# Target design: gateway services and remote-builder

> **Status: target design, steps 1 to 6 prototyped and probed on VMs on
> 2026-11-27. Steps 0 to 3 are implemented (SPEC.md round 65,
> `specs/gateway.md` round G12, G26–G28); steps 4 to 8 are not
> implemented on `main`.** (SPEC.md round 61.) A line
> that says **VERIFIED-VM** names the suite or verdict that showed it on
> the remote builder, with the prototype applied to `origin/main`
> `deeaba4`. A line that says **NOT-RUN** was not shown. §9 holds one row
> per probe and assumption. The remote-builder part (§3.10, step 7) is
> **owner-gated (O8) and was not probed**.
> The index, the cross-area contracts and the build order are in
> `specs/target-design.md`.
> The findings are `specs/probes/2026-11-27/gateway.md`. The other
> evidence named here (`probes/gateway/runs/`,
> `probes/gateway/prototype.patch`, `reviews/`, `runs/`, `patches/`) is
> session evidence of 2026-11-27. It is not in the repo; the session
> handoff maps it.

Area: `services/nat-gateway/`, `services/router/`, `lib/gateway/`, `services/remote-builder/`.
Base: `main` at `deeaba4`. File and option names are of that commit.
Written for the next implementer. Read §0 first, then implement §8 in order.

Owner's rule for this round: no consumers, no deployed machines. Suites, eval
tests, option names and schema versions are not protected. Only safety
behaviour is fixed.

---

## 0. The design in one page

1. **Keep Jool in a namespace behind a veth pair.** It is the best model here (§4b). Fix its two holes instead of replacing it.
2. **Policy before translation.** The host's `inet nat64` table refuses what must not be translated while the packet is still IPv6: undeclared source, embedded private IPv4, protocols and ICMPv6 types Jool cannot translate. What comes back out of the namespace is checked against what a translator may emit. **VERIFIED-VM.**
3. **A default-deny guard inside each namespace.** A small nft table `inet guard` drops (a) everything Jool handed back to the kernel and (b) everything that would leave the namespace and is not a translated packet. The Jool unit loads it before an instance exists. **VERIFIED-VM.**
4. **The namespace forwards nothing.** Forwarding is off in both namespaces (Jool does not need it), and `pool6` and the CLAT address are `unreachable` routes there. No IPv4 default route in the CLAT namespace. **VERIFIED-VM.**
5. **A CLAT host gets its own table `inet clat`.** Only a gateway's `/96` with a public embedded IPv4 may reach the CLAT. Nothing unsolicited arrives as IPv4. **The host forwards IPv6 for its CLAT only (O7)**; other links forward only where a service declared them (`clan.networkFacts.forwardLinks`). **VERIFIED-VM.**
6. **The health check also checks the guard.** A gateway without its guard asks the Jool unit to load it; if that fails it withdraws its beacon after the `down` window. **VERIFIED-VM.**
7. **Router: one value renders both firewalls.** The ports the router's table accepts on a link are the ports the NixOS firewall opens on that link. `wanPorts` then works (G-A3). A zone reaches the fabric only with `zones.<name>.fabric = true` (default false).
8. **Prefix hook: validated and sandboxed.** A delegation is global unicast, a /32 to a /64, none of the router's own prefixes. The boot grace without a marker (an empty file means "delegation lost") waits for netif's N16 amendment: NOT-RUN.
9. **remote-builder: a build sshd of its own.** Owner-gated (O8), not probed.
10. **Rate limits: the pool4 bound is asserted at eval** for every rendered limit, and Jool's timeouts are pinned. On a full pool4 Jool drops a new flow in silence (no loop, no error to the client): "fail fast" is not available from Jool 4.1.15.

Status words used below:
- **VERIFIED-SRC**: read in Jool 4.1.15 source (`NICMx/Jool` tag `v4.1.15`, files named).
- **VERIFIED-CODE**: read in this repo.
- **VERIFIED-VM**: shown by a VM suite on the remote builder; the suite, verdict or marker is named.
- **REFUTED**: a probe disagreed; the text was changed to what works.
- **NOT-RUN**: not shown by a run. Still an assumption.
- **NOT-BUILT**: designed here, not in the prototype.
- **ASSUMED**: only in §3.10 (remote-builder, not probed): behaviour that was not run.

---

## 1. Threat model

| # | Actor | Position | Can do | Must not achieve |
|---|---|---|---|---|
| T1 | Hostile WAN host | IPv4 or IPv6 Internet, off-path | Send any packet, any source (spoofing) | Open a flow into a LAN, a client, a gateway port, or the namespace. Make a packet cross a veth more than once. |
| T2 | Hostile LAN client | Inside a router zone | Any packet, forged sources, rogue RA or DHCP on its link | Reach another zone, the router's ports beyond DNS/DHCP (and SSH if allowed), the fabric (unless `fabric = true`), or send a forged source to the WAN. |
| T3 | Undeclared host | Can route to a gateway's `pool6` and beacon | Any IPv6 packet | Use the translator. Learn the beacon. Consume meter entries or pool4 ports. |
| T4 | Declared client (or a spoofer of its source) | In the allowlist | Any IPv6 packet to `pool6`, any protocol, any embedded IPv4 | Reach a non-public IPv4 (loopback, RFC 1918, link-local, the gateway itself, Jool's own addresses). Reach another client's mappings. Exhaust pool4 alone. Trigger a loop or an amplification. |
| T5 | Rogue RA or DNS next to a CLAT host | Same L2 segment as a client | Rogue RA, forged DNS answers, forged beacon answers, spoofed `pool6` sources | Move the CLAT to a prefix that is not a gateway of the inventory. Deliver IPv4 with a private or local source to the host. Open an unsolicited IPv4 flow into the host. |
| T6 | Rogue or broken DHCPv6 server on the router's WAN | WAN segment | Delegate any prefix | Disable the router's source filters or blackhole WAN IPv6 (`::/0`, ULA, link-local, own prefixes). |
| T7 | Holder of one build key | Any network that reaches the builder | Log in as `nix-ssh` | Get a shell, a forward, or a tunnel. (It is store-root by design: `trusted`. Documented, not prevented.) |
| T8 | Network scanner at the builder | Any | Connect to the build port | Password guessing, another user, the admin sshd's configuration. |

Out of scope (accepted, already written down):
- A declared source is an address, not a credential (§14.1 point 4).
- T5 can hijack a neighbour's default route by RA. That is layer 2 (switch RA guard) and netif's `ra` setting.
- T7: every build key is root on the builder.

---

## 2. Invariants (numbered, testable)

Each one names its test in §6 or §8.

### Translator (gateway)

- **I1** A packet enters the translator namespace only if: IPv6, destination in `pool6`, source declared (or an ICMPv6 error `related` to an open flow), L4 is TCP, UDP or a translatable ICMPv6 type, and the embedded IPv4 is public. Everything else is refused on the host, in IPv6, before translation.
- **I2** Any single packet crosses the `jool0`/`jool1` link at most once per direction. True with a Jool instance, without one, and while it is replaced.
- **I3** The namespace kernel never answers, forwards or delivers a packet: the guard drops what Jool handed back, and forwarding is off in the namespace. Only ND on `jool1` and Jool's own ICMP errors exist besides translated packets.
- **I4** Only two kinds of packet leave the namespace: IPv4 with source in pool4, IPv6 with source in `pool6`. (Plus ND and Jool's ICMP errors.)
- **I5** The translator is no way into the gateway itself: nothing that left the namespace is delivered to a local socket of the gateway, except replies to the gateway's own health pings.
- **I6** Translated IPv4 leaves through an uplink only, masqueraded.
- **I7** One source /64 cannot exhaust pool4: for every rendered limit, `newFlowsBurst + newFlows × udpTimeout ≤ pool4 ports`. Checked at eval.
- **I8** A full pool4 never withdraws the beacon, and never makes a packet loop.
- **I9** A gateway is advertised (beacon up) only while its health rounds are good, and a round is good only while the guard table is loaded in the namespace. (pool4 wholeness is repaired by every start of the Jool unit; it is not part of a round.)
- **I10** A restart of `nftables.service`, an IfState apply, or a restart of `nat64-jool` never leaves a moment in which I1 to I5 do not hold.

### CLAT (client)

- **I11** A packet reaches the CLAT namespace from outside only if: destination is the CLAT address, source is inside a gateway's `/96` of the inventory, and the embedded IPv4 is public.
- **I12** Any single packet crosses `clat0`/`clat1` at most once per direction.
- **I13** Nothing unsolicited arrives as IPv4 from `clat0` on a host socket.
- **I14** The CLAT's `pool6` is always one of the inventory's gateways. Only `clat-follow` changes it. RAs, PREF64 and resolvers are never read.
- **I28** The CLAT namespace kernel never answers, forwards or delivers a packet (as I3: the guard, forwarding off).
- **I29** (O7) A CLAT host forwards IPv6 between `clat0` and its uplink for the CLAT's own packets only. Between two other links it forwards IPv6 only when one of them is a forward link (`clan.networkFacts.forwardLinks`, option `forwardLinks`).
- **I15** The follower moves only after `followAfter` seconds of silence from its gateway, only to a gateway that named its own `/96` in 5 of the last 10 rounds, never back on its own. (Unchanged.)

### Router

- **I16** From the WAN the router accepts: established/related, a fixed list of ICMP types, DHCP client replies, and `wanPorts`. Nothing else. `wanPorts` actually connect.
- **I17** WAN to LAN: only established/related and `expose` pinholes.
- **I18** Zone to zone: default deny. Zone to fabric: only with `fabric = true`.
- **I19** A packet on a router link is accepted only if the router's table and the NixOS firewall both accept it, and both are rendered from the same data.
- **I20** The delegated-prefix set holds only global unicast prefixes of length 32 to 64 that overlap none of the router's own static prefixes. At most 8.
- **I21** A restart or a failed run of the prefix hook within the boot window never retires the prefix on disk.
- **I22** Links are configured only after the firewall tables are loaded (`ifstate.service` after `nftables.service`).
- **I23** A router has one zone or more. A config without one fails at eval.

### remote-builder

- **I24** The service changes nothing of the machine's own sshd (host keys, settings, port 22).
- **I25** The build port accepts public keys only, the user `nix-ssh` only, and runs `nix-daemon --stdio` only. No TTY, no forwarding, no tunnel.
- **I26** A server has one build host key, whatever the number of instances. A client pins it. No TOFU.
- **I27** A client's ssh alias is `<instance>-<server>`. No `Host <machine name>` block is written.

---

## 3. Target design

§3.1 to §3.9 describe what the prototype builds and what the suites
proved. Rule sets are the rendered text of a run, not sketches. §3.10 is
unchanged and owner-gated.

### 3.1 Why packets behave as they do (facts the design rests on)

- **VERIFIED-SRC** Jool registers one netfilter hook per family at `NF_INET_PRE_ROUTING`, priority `NF_IP_PRI_NAT_DST + 25` and `NF_IP6_PRI_NAT_DST + 25`, that is **-75** (`src/mod/common/xlator.c:28-34`).
- **VERIFIED-SRC, VERIFIED-VM (N10, C06)** A packet Jool does not translate gets `NF_ACCEPT`. With no instance in the namespace every packet is handed back: a counter at prerouting priority -5 in the namespace saw the client's one packet, and `guard-leftover` moved.
- **VERIFIED-SRC** Unknown L4 protocol in NAT64 is untranslatable (`determine_incoming_tuple.c:328-331`). No ICMP error is sent.
- **VERIFIED-SRC, VERIFIED-VM (P6)** A translated packet is sent with `dst_output()`. It passes the namespace's **postrouting** hook only. With both guard chains at `policy drop`, every traffic shape of `nat-gateway` passes (TCP, UDP, ICMP, 2 MB down, 300 kB up, fragments of 3000 bytes, path MTU discovery across a 1400 byte hop) and the guard's two counters stay 0.
- **VERIFIED-VM (P2)** Jool translates with `net.ipv4.conf.all.forwarding=0` and `net.ipv6.conf.all.forwarding=0` in its namespace, NAT64 and SIIT, every shape above. The namespaces run with forwarding off.
- **VERIFIED-VM (P3, N16)** A new flow on a full pool4 is dropped by Jool itself (`JSTAT_BIB6_NOT_FOUND`). It is not handed back (`guard-leftover` +0), it does not loop (one crossing each), and the client gets no ICMPv6 error: it times out.
- **VERIFIED-VM (P1)** `ip6 daddr & ::ffff:ffff @private6` loads (build-time `nft --check` and at boot) and matches: `pool6::7f00:1` and eleven other private embeddings move the `nat64-private` counter by one each.
- **VERIFIED-VM** nft rulesets are per network namespace: `systemctl restart nftables.service` on the host leaves the namespace's `inet guard` byte-equal (JSON, without counters).
- **VERIFIED-VM** A veth end receives link chatter that nobody sent to the namespace (MLD reports, LLMNR, router solicitations: about 14 to 19 packets in the first minute). It is multicast. The guard counts it apart (`guard-noise-in`), so `guard-leftover` counts only what Jool handed back.
- **VERIFIED-VM (N05 on `main`)** `pool6::7f00:1` was translated to `127.0.0.1` and answered by the namespace's loopback. N06 and N07 on `main`: 32 crossings.

Consequence: a base chain in the namespace at **prerouting, priority 0** sees exactly the packets Jool gave back. A base chain at **postrouting** sees exactly what leaves. Two small chains with `policy drop` make the namespace default deny without conntrack.

### 3.2 Namespace layout

```
gateway host                              namespace "nat64"
  jool0  192.0.0.1/30  fd64::1/64  <veth>  jool1  192.0.0.2/30  fd64::2/64
  route  <pool6> via fd64::2               route ::/0 via fd64::1
  table inet nat64 (reworked)              route 0.0.0.0/0 via 192.0.0.1
                                           route <pool6> unreachable      (new)
                                           forwarding 0, both families    (new)
                                           nft table inet guard           (new)
                                           Jool instance "default", pool4 192.0.0.2 1100-65535

client host                               namespace "clat"
  clat0  192.0.0.1/29  fd00:c1a7::1/64 <veth> clat1  192.0.0.2/29  fd00:c1a7::2/64
  route  0.0.0.0/0 via 192.0.0.2 mtu N     route ::/0 via fd00:c1a7::1
  route  <clat address>/128 via fd00:c1a7::2   route <clat address>/128 unreachable (new)
  table inet clat (new)                    (IPv4 default route removed)
                                           forwarding 0, both families    (new)
                                           nft table inet guard           (new)
                                           Jool SIIT instance "clat"
```

Layers, outermost first. Each one alone ends a packet that must not pass (VERIFIED-VM, N06, N07, N10, N11, C06):

1. the host table (`inet nat64`, `inet clat`) refuses it while it is IPv6;
2. the namespace guard drops what Jool handed back;
3. forwarding is off in the namespace, and the destination (`pool6`, the CLAT address) is an `unreachable` route there.

Not taken over from the minimal fix: the namespace loopback without IPv4. `127.0.0.0/8` is refused by layer 1 (`nat64-private`) and by the guard's `leaving` chain.

### 3.3 Host table `inet nat64` (gateway)

In `lib/gateway/nat64.nix`. The ranges come from `lib/gateway/private.nix` (`private`, `embedded`, `private6`, `sets`): one list renders `private4` and `private6`. Rendered on gw2 of `nat-gateway` (sets shortened):

```nft
table inet nat64 {
  set trusted { type ipv6_addr; flags interval; auto-merge; elements = { … } }
  set default { type ipv6_addr; flags interval; auto-merge; elements = { … } }
  set custom  { type ipv6_addr; flags interval; auto-merge; elements = { … } }
  set private4 { type ipv4_addr; flags interval;
    elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
                 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/3 } }
  # the same ranges as the low 32 bits of a pool6 destination
  set private6 { type ipv6_addr; flags interval;
    elements = { ::0:0/104, ::a00:0/104, ::6440:0/106, ::7f00:0/104, ::a9fe:0/112,
                 ::ac10:0/108, ::c000:0/120, ::c0a8:0/112, ::c612:0/111, ::e000:0/99 } }
  # meters: unchanged (flows_*, packets_*, per /64, fail closed)

  chain forward {
    type filter hook forward priority -10; policy accept;
    oifname "jool0" jump to_translator
    iifname "jool0" jump from_translator
  }
  chain to_translator {
    meta nfproto ipv4 ct state established,related accept
    meta nfproto ipv4 counter drop comment "nat64-unsolicited4"
    ip6 daddr != <pool6> counter drop comment "nat64-not-pool6"
    ip6 saddr != @trusted ip6 saddr != @default ip6 saddr != @custom ct state related icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept
    ip6 saddr != @trusted ip6 saddr != @default ip6 saddr != @custom counter drop comment "nat64-undeclared"
    meta l4proto != { tcp, udp, ipv6-icmp } counter reject with icmpv6 type admin-prohibited comment "nat64-protocol"
    icmpv6 type != { echo-request, echo-reply, destination-unreachable, packet-too-big, time-exceeded, parameter-problem } counter drop comment "nat64-icmp-type"
    ip6 daddr & ::ffff:ffff @private6 counter reject with icmpv6 type admin-prohibited comment "nat64-private"
    # the meters, unchanged text, without `oifname "jool0"`
    …
  }
  chain from_translator {
    ip6 daddr != @trusted ip6 daddr != @default ip6 daddr != @custom counter drop comment "nat64-return-undeclared"
    ip6 saddr fd64::2 meta l4proto ipv6-icmp counter accept comment "nat64-jool-error"
    ip6 saddr != <pool6> counter drop comment "nat64-return-source"
    ip saddr != 192.0.0.2 counter drop comment "nat64-pool4-source"
    meta nfproto ipv4 oifname != { <uplinks> } counter drop comment "nat64-not-uplink"
    ip daddr @private4 counter reject with icmp type net-prohibited comment "nat64-private-post"
  }
  chain input {
    type filter hook input priority -10; policy accept;
    ip6 daddr <address> meta l4proto { tcp, udp } th dport 53 ip6 saddr != @trusted ip6 saddr != @default ip6 saddr != @custom counter drop comment "beacon-undeclared"
    iifname "jool0" meta nfproto ipv6 ct state established,related accept
    iifname "jool0" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept
    iifname "jool0" meta nfproto ipv4 counter reject with icmp type host-prohibited comment "nat64-host"
    iifname "jool0" counter drop comment "nat64-host6"
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    iifname "jool0" oifname { <uplinks> } masquerade comment "nat64-masquerade"
  }
}
```

What the suites proved of it:

- `nat64-private` refuses before translation: loopback, RFC 1918, link-local, CGN, Jool's own link (`192.0.0.1`) and pool4 address (`192.0.0.2`, the hairpin of G-A2), multicast. The client's `curl` ends with code 7 at once, not with a timeout. `nat64-private-post` stays 0. A refused packet takes no pool4 port (`k3s-clat`: `JSTAT_SUCCESS` does not move).
- The gateway's public IPv4 cannot be in `private6` (it can be dynamic). It is translated, delivered to the host and refused by `nat64-host` (N05, 10 packets).
- `nat64-return-undeclared` is a layer of its own: with `to_translator` emptied, an undeclared source's ping is translated and the answer is dropped (`nat-gateway`, the second negative proof).
- `nat64-jool-error` stayed 0 in every run. Kept: it costs one rule and names what may leave with Jool's own address.
- Fragments are judged as one reassembled packet (N15: 3000 bytes to a private destination move `nat64-private` by 1).
- The accept of the established input is IPv6 only. The design draft accepted both families; nothing legitimate arrives as IPv4 on `jool0`.

Notes for the implementer:

- The NixOS forward rules and `filterForward = true` stay. They accept what this table let pass.
- The health check's pings leave through OUTPUT. They are not judged here. Their answers match `ct state established` in `input`.
- Documentation ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) are **not** in `private`: every suite uses them as its "Internet".
- nix-unit to add (NOT-RUN, `check` was not run in the probe round): `embedded "127.0.0.0/8" == "::7f00:0/104"`, `embedded "224.0.0.0/3" == "::e000:0/99"`, `embedded "0.0.0.0/8" == "::0:0/104"`.

### 3.4 Namespace table `inet guard` (gateway)

`lib/gateway/guard.nix` writes the file and checks it at build time the way NixOS checks the host's ruleset (`nft --check` under `lklWithFirewall`). `names.nix` gains `guard = "guard"`.

```nft
table inet guard
delete table inet guard
table inet guard {
  chain leftover {
    type filter hook prerouting priority 0; policy drop;
    iifname "jool1" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } ip6 hoplimit 255 accept
    meta pkttype != host counter drop comment "guard-noise-in"
    counter comment "guard-leftover"
  }
  chain leaving {
    type filter hook postrouting priority 0; policy drop;
    oifname "jool1" ip saddr 192.0.0.2 accept
    oifname "jool1" ip6 saddr <pool6> accept
    oifname "jool1" ip6 saddr fd64::2 meta l4proto ipv6-icmp accept
    oifname "jool1" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept
    ip6 daddr ff00::/8 counter drop comment "guard-noise-out"
    counter comment "guard-leaving"
  }
}
```

- `guard-leftover`: what Jool handed back. 0 in every function run. It moves only when an attack got past the host table (N10: no instance).
- `guard-leaving`: 0 in every run, also after every attack (N17).
- `guard-noise-in`, `guard-noise-out`: link chatter and the namespace kernel's own MLD. Not a signal.
- A suite asserts `guard-leftover == 0 and guard-leaving == 0` after real traffic. A value that is not 0 is a failure: find the packet.
- **Amended (round 65, `k3s-clat`):** on a kube node the CLAT guard's `guard-leaving` read 5 to 7: one API server reply to a pod address (`192.168.77.1:6443` to `10.1.0.178`, retransmitted) took the node's IPv4 default route into the CLAT during cluster start, Jool translated it with `pool6` on both sides, and the guard stopped it (on `main` the gateway refused it as `nat64-private`). It is not CLAT traffic. On a kube node the suite logs every packet the guard stops and asserts none has the CLAT address as source or a public embedded destination; on plain clients and gateways (`nat-gateway`) both counters stay asserted 0.

The unit `nat64-jool` (`pkgs.nftables` in its `path`), in this order:

```sh
modprobe jool
ip netns exec nat64 nft -f <guard>          # first: no moment with an instance and no guard
ip netns exec nat64 sysctl -w net.ipv4.conf.all.forwarding=0 net.ipv6.conf.all.forwarding=0
ip netns exec nat64 sysctl -w net.ipv4.ip_local_port_range="1024 1099"
# instance, pool4: as before
ip netns exec nat64 jool -i default global update udp-timeout 0:05:00
ip netns exec nat64 jool -i default global update icmp-timeout 0:01:00
ip netns exec nat64 jool -i default global update address-dependent-filtering true
ip netns exec nat64 jool -i default global update drop-externally-initiated-tcp true
```

- **VERIFIED-VM** The four `global update` lines run on Jool 4.1.15 at every start (the suites boot through them; a restart with them is in the ownership phase).
- Same unit, not a new one: a second oneshot with `Requires=` brings back the "dependency failed is not retried" trap of §17 G1.
- Robustness, **VERIFIED-VM** (`nat-gateway`, marker `NAT_GATEWAY_GUARD_RESTARTS_OK`, and the IfState phase): the guard is byte-equal after `systemctl restart nftables.service`, after `systemctl restart nat64-jool.service` and after an IfState apply, and a TCP flow that is open across the first two goes on without an error line.

Route, in `namespaces.nat64.routing.routes`: `{ to = cfg.pool6; type = "unreachable"; }`. **VERIFIED-VM**: IfState 2.5.1 applies it and `assert_ifstate_noop` holds.

### 3.5 Client: table `inet clat`, the CLAT guard, and forwarding (O7)

`names.nix` gains `clat.table = "clat"`. `clat.nix` sets `networking.nftables.enable = true`. Rendered on the client of `nat-gateway`:

```nft
table inet clat {
  set gateways { type ipv6_addr; flags interval; auto-merge; elements = { <every gateway's pool6> } }
  set private4 { … as §3.3 … }
  set private6 { … as §3.3 … }
  chain forward {
    type filter hook forward priority -10; policy accept;
    meta nfproto != ipv6 accept
    oifname "clat0" jump to_clat
    iifname "clat0" jump from_clat
    # only when the machine has links in `clan.networkFacts.forwardLinks` or `forwardLinks`
    iifname { <forward links> } accept
    oifname { <forward links> } accept
    counter drop comment "clat-forward"
  }
  chain to_clat {
    ip6 daddr != <clat address> counter drop comment "clat-not-address"
    ip6 saddr != @gateways icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept
    ip6 saddr != @gateways counter drop comment "clat-foreign-source"
    ip6 saddr & ::ffff:ffff @private6 counter drop comment "clat-private-source"
    accept
  }
  chain from_clat {
    ip6 saddr != <clat address> counter drop comment "clat-spoof"
    ip6 daddr != @gateways counter drop comment "clat-not-gateway"
    accept
  }
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "clat0" ct state established,related accept
    iifname "clat0" meta nfproto ipv4 counter drop comment "clat-unsolicited"
    iifname "clat0" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept
    iifname "clat0" counter drop comment "clat-host6"
  }
}
```

- The forward chain is **stateless** on purpose: Cilium attaches to `clat0` and the uplink, and conntrack in FORWARD is not reliable there (§16.4).
- Changed against the draft: an ICMPv6 error from a source outside every gateway's `/96` is let in. A router on the path to a gateway answers "packet too big" with its own address; without the rule the CLAT has no path MTU discovery beyond the first hop. Any IPv6 host takes such errors; the host's stack checks them against its flows. **VERIFIED-VM** for one such error: the gateway's own refusal (`nat64-private`, ICMPv6 admin-prohibited from the gateway's link address, which is outside its `/96`) passes the rule, is translated by the CLAT (`JSTAT_RECEIVED6: 1`) and reaches a pod at once (`k3s-clat`: `wget: can't connect to remote host (172.20.0.1): No route to host`). "Packet too big" from a router between client and gateway is NOT-RUN (no suite has such a router).
- `clat-private-source`: a forged `/96` source that embeds a private IPv4 address would arrive on the host as a pod or a LAN address (C01).
- `input`: a stateful NAT64 opens no flow inwards. Forged packets from a gateway's `/96` are translated once and dropped as `clat-unsolicited`: no answer, no datagram at an open UDP port, no loop (C02, C03, C07).

**O7, decided by the owner: a CLAT host does not forward IPv6 machine-wide.** The CLAT needs `net.ipv6.conf.all.forwarding = 1` (packets between `clat0` and the uplink are forwarded). The table makes that the only forwarding:

- IPv6 between `clat0` and another link passes only by `to_clat` and `from_clat`.
- IPv6 between two other links is dropped (`clat-forward`), unless one of the two links is a **forward link**: a link whose owner declared that it forwards there and judges it by its own rules.
- IPv4 is not touched (a plain client has IPv4 forwarding off; a kube node's pods need it).

New fact `clan.networkFacts.forwardLinks` (`lib/kube-cluster/network-facts.nix`, a list of nft interface names, a trailing `*` is a wildcard). Who sets it in the prototype:

| Owner | Value | File |
|---|---|---|
| k3s, rke2 | `["cilium*" "lxc*"]` | `lib/kube-cluster/service.nix` |
| routed-fabric, when it forwards | its fabric interfaces | `services/routed-fabric/default.nix` |
| router | its zone links and the WAN | `lib/gateway/router.nix` |

New option `clanServices.gateway.clat.forwardLinks` (list of links, default `[]`) for a link no service declares (a container bridge). Docker with IPv6 on a CLAT host needs it; **NOT-RUN**.

Proof:

- C08 (`nat-gateway-hostile`): a second link behind the client (a namespace on a veth). From the outsider to it and from it to the outsider: both fail, `clat-forward` +4. Negative proof in the same phase: with `table inet clat` deleted both pings pass, so on `main` a CLAT host is an IPv6 router between all its links. The CLAT still carries IPv4.
- `k3s-clat` passes on nodes that are CLAT hosts (alpha is a fabric spine, beta a leaf). After pod traffic in both families, the pod network between the nodes, ClusterIP and NodePort: `FINDING O7 alpha: forward links "cilium*", "lxc*", "rf66cac445797bf"; table inet clat counters {'clat-forward': 0, 'clat-not-address': 0, 'clat-foreign-source': 0, 'clat-private-source': 0, 'clat-spoof': 0, 'clat-not-gateway': 0, 'clat-unsolicited': 8}; CLAT guard {… 'guard-leftover': 0, … 'guard-leaving': 0}` (beta the same). Nothing the cluster needs was refused. The 8 `clat-unsolicited` packets per node were not captured: IPv4 that arrived on `clat0` for no flow of the host and that Cilium did not hand to a pod. Every pod and node check passes with them dropped.

CLAT namespace guard, loaded first in the `clat` unit, then forwarding off (as §3.4):

```nft
table inet guard
delete table inet guard
table inet guard {
  chain leftover {
    type filter hook prerouting priority 0; policy drop;
    iifname "clat1" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } ip6 hoplimit 255 accept
    meta pkttype != host counter drop comment "guard-noise-in"
    counter comment "guard-leftover"
  }
  chain leaving {
    type filter hook postrouting priority 0; policy drop;
    oifname "clat1" ip6 saddr <clat address> accept          # IPv4 that became IPv6
    oifname "clat1" ip daddr 192.0.0.1 accept                # IPv6 that became IPv4
    oifname "clat1" ip6 saddr fd00:c1a7::2 meta l4proto ipv6-icmp accept
    oifname "clat1" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept
    ip6 daddr ff00::/8 counter drop comment "guard-noise-out"
    counter comment "guard-leaving"
  }
}
```

The guard does not name `pool6`, so the follower's moves need no reload. The draft's rule `ip saddr 192.0.0.2 meta l4proto icmp accept` is covered by `ip daddr 192.0.0.1 accept`.

Routes in the CLAT namespace:

- added: `{ to = "${cfg.address}/128"; type = "unreachable"; }`;
- **removed**: `{ to = "0.0.0.0/0"; via = "192.0.0.1"; }`. **VERIFIED-VM**: every CLAT shape of `nat-gateway` passes without it. `k3s-clat-mapped` runs on fixtures and keeps its own routes.

### 3.6 Units and ordering

| Piece | Owner | Ordering | Survives |
|---|---|---|---|
| namespace, veth, addresses, routes (incl. `unreachable`) | IfState (`ifstate.service`) | after `nftables.service` (stated; see P5) | an apply keeps them |
| host tables `inet nat64`, `inet clat`, `inet router` | NixOS `nftables.service` | before `network-pre.target` | atomic reload per table; meters reset (accepted) |
| `inet guard` in `nat64` | `nat64-jool.service`, first step | `After=ifstate`, `PartOf=ifstate`, `Restart=on-failure` | a firewall restart does not touch it; reloaded atomically on every start |
| Jool instance, pool4, globals | `nat64-jool.service` | after the guard, same script | idempotent |
| `inet guard` in `clat` | `clat.service`, first step | same | same |
| health check | `nat64-health.service` | `After=`/`Wants=nat64-jool` | resumes state younger than `resume` |
| beacon | `nat64-beacon.service` | `BindsTo=nat64-health` | stops with the check |
| follower | `clat-follow.service` | `Wants=clat` (never `Requires`) | waits while no instance |
| hook tables `router_svc`, `router_src` | `router-prefix.service` (sandboxed) | after `nftables`, `ifstate` | each in its own transaction |
| build sshd | owner-gated (O8) | | |

On gateway, client and router machines, inside the existing `systemd.services` block (a second `systemd.services.…` attribute path beside it is a duplicate for `nixf-diagnose`):

```nix
ifstate.after = ["nftables.service"];
```

### 3.7 Health check (`nat64-health.py`)

Built as drafted, with one function that reads the guard and its counters:

```python
GUARD = ["ip", "netns", "exec", config["netns"], "nft", "list", "table", "inet", config["guard"]]
RESTART = config["restart"]          # "nat64-jool.service"
GUARD_RETRY = 60

def guard():
    """None when a chain is missing, else what the two counters dropped."""
    shown = lines(GUARD)
    if shown is None or not any("hook prerouting" in line for line in shown) or not any("hook postrouting" in line for line in shown):
        return None
    dropped = {}
    for line in shown:
        for name in ["guard-leftover", "guard-leaving"]:
            if f'comment "{name}"' in line and "packets" in line:
                dropped[name] = int(line.split("packets")[1].split()[0])
    return dropped
```

- Read every `POOL_EVERY` (10) rounds, in the pool4 block.
- A round is good when `len(alive) >= QUORUM and guarded is not None`. The existing windows decide; there is no new state machine.
- When the guard is missing: one journal line, and `systemctl --no-block restart nat64-jool.service`, at most every 60 s. The unit loads the guard first.
- `health.json` gains `"guard": true|false` and `"guard_dropped": {"guard-leftover": n, "guard-leaving": n}` (risk R1: an exporter sees a guard that drops).
- `pkgs.nftables` in the unit's `path`; the health config gains `guard` and `restart`.

**VERIFIED-VM** (`nat-gateway-hostile`, N11):

- guard deleted by hand: `health.json` says `"guard": false`, the guard is back 2.3 s after the deletion, one journal line, 12 bad rounds of the last 60, the beacon stays;
- guard deleted and the Jool unit unable to start: the beacon is closed 29.9 s later, state `down`, journal `30 of the last 60 rounds bad (the namespace's guard is not loaded), beacon withdrawn`. The translator still translates meanwhile (the host table and layer 3 remain). When the unit can start again, `Restart=on-failure` loads the guard and the beacon returns after `up` good rounds.

A full pool4 still never withdraws the beacon (I8, N16).

### 3.8 Option surface, nat-gateway

| Change | Where | Type / default | Status |
|---|---|---|---|
| **add** eval assertion I7 | `nat64.nix` assertions | for `limits.default`, `limits.trusted`, each `custom[].limits`: `newFlowsBurst + newFlows * 300 <= 64436` | built; every suite's limits pass it; the failing case is a nix-unit test to add (`test_limitBound`, NOT-RUN) |
| **add** `names.guard`, `names.clat.table` | `names.nix` | `"guard"`, `"clat"` | built |
| **add** `clanServices.gateway.clat.forwardLinks` | `clat.nix` | `listOf str`, `[]` | built (O7) |
| **add** fact `clan.networkFacts.forwardLinks` | `lib/kube-cluster/network-facts.nix` | `listOf str`, `[]` | built (O7); a cross-area contract |
| **remove** CLAT namespace IPv4 default route | `clat.nix` | | built |
| **keep** `address`, `allow`, `custom`, `limits`, `health.*` | | | |
| **later (step 8, optional)** the beacon at `pool6::192.0.0.170` | `services/nat-gateway/default.nix` | | NOT-RUN (P4) |

### 3.9 Router changes (`router.nix`, `services/router/default.nix`)

**(a) One renderer for both firewalls (G-A3, I19).** Built. `wanPortRules`, the DHCP line, the SSH line and the old `firewall.interfaces` are gone:

```nix
zoneOf = link: lib.findFirst (zone: lib.elem link zone.interfaces) null (builtins.attrValues lanZones);
offered =
  lib.genAttrs lanLinks (link: let
    zone = zoneOf link;
    dns = zone.dns.ipv4 != null || zone.dns.ipv6 != null;
  in {
    tcp = lib.optional dns 53 ++ lib.optional zone.ssh 22;
    udp = lib.optional dns 53 ++ lib.optional (zone.dhcp4 != null) 67;
  })
  // {${cfg.wan} = {inherit (cfg.wanPorts) tcp udp;};};
# NixOS side
networking.firewall.interfaces = lib.mapAttrs (_: offer: {allowedTCPPorts = offer.tcp; allowedUDPPorts = offer.udp;}) offered;
# router table side: one rule per link and protocol; DNS keeps its `ip daddr <zone address>` rule (`dnsRules`)
offeredRules = … ''iifname "<link>" tcp dport { … } accept comment "offered on <link>"'' …;
```

On `main` a zone's SSH worked only because `services.openssh.openFirewall` opens 22 on every link; `wanPorts` did not work at all (G-A3).

**(b) Zones reach the fabric by opt-in (owner decision H3).** Built.

| Change | Where | Type / default |
|---|---|---|
| **add** `zones.<name>.fabric` (**done** with fabric steps 1 and 2, round 62: the option and the fact; `router-kube` sets it on `home`) | `services/router/default.nix`, `router.nix` | `bool`, default `false` |
| **remove** `unzoned.zones` and its assertion | same | replaced by the per-zone option |
| **rename** `unzoned.source.{ipv4,ipv6}` → `fabricSource.{ipv4,ipv6}` | same | unchanged type and default |
| **set** fact `clan._networkFacts.fabricInside = zonesOf fabricZones` (**done**, round 62) | `router.nix` | the fact itself is fabric step 1 |

- The consumers are routed-fabric's border guard and the kube ingress chain (`patches/fixes-fabric-kube.patch`, applied in the prototype). They belong to those designs.
- "Unzoned links always reach the WAN" stays (owner-accepted, G25).

**(c) Empty LAN (G-A7, I23).** NOT-BUILT in the prototype. As drafted: `settings.zones != {}` assertion in `services/router/default.nix`; `extraReversePathFilterRules = lib.optionalString (lanLinks != []) "iifname ${lans} accept";`.

**(d) `servicePrefix` without an advertised zone (G-A8).** NOT-BUILT. As drafted: `hookWanted = advertised != {} || cfg.servicePrefix.subnet != null` in place of the three `lib.mkIf (advertised != {})` of the hook's path unit, tables unit and service. `corerad` keeps `advertised != {}`.

**(e) ICMP from router links (I16).** Built, in the router table's `input` chain in place of `meta l4proto { icmp, ipv6-icmp } accept`. The two limit rules stand **ahead of** `ct state established,related accept`:

```nft
icmp type echo-request limit rate over 20/second burst 40 packets counter drop comment "input echo over the rate"
icmpv6 type echo-request limit rate over 20/second burst 40 packets counter drop comment "input echo over the rate"
ct state established,related accept
icmp type { destination-unreachable, time-exceeded, parameter-problem, echo-request } accept
icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request,
              nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit,
              mld-listener-query, mld-listener-report, mld-listener-done, mld2-listener-report } accept
meta l4proto { icmp, ipv6-icmp } counter drop comment "input icmp dropped"
```

- **REFUTED**: the draft's `icmp type echo-request limit rate 20/second burst 40 packets accept` behind the `established` accept. The echo requests of one flood are one tracked flow: after the first they are `established` and never meet the limit (`hostile-router`, first run: 200 of 200 answered).
- The limit is one bucket for all router links, not per source.
- And the six redirect sysctls of the draft in `boot.kernel.sysctl` (`accept_redirects` for `all` and `default`, `secure_redirects`, `send_redirects` for IPv4; `accept_redirects` for `all` and `default` for IPv6).

**(f) Prefix hook.**

1. *Validation (G-A6, I20).* Built in `router-prefix.py`; `hookConfig` gains `own = ownPrefixes "ipv6"`:
   ```python
   GLOBAL = ipaddress.IPv6Network("2000::/3")
   OWN = [ipaddress.IPv6Network(prefix, strict=False) for prefix in CONFIG["own"]]
   MAX_PREFIXES = 8

   def delegated(text):
       found = []
       for word in (text or "").split():
           try:
               network = ipaddress.IPv6Network(word)
           except ValueError:          # also a prefix with host bits set
               print(f"router-prefix: {word[:64]!r} is not a delegation to use (…): skipped", flush=True)
               continue
           if not network.subnet_of(GLOBAL) or not 32 <= network.prefixlen <= 64 or any(network.overlaps(own) for own in OWN):
               print(f"router-prefix: {word} is not a delegation to use (…): skipped", flush=True)
               continue
           if str(network) not in found:
               found.append(str(network))
       return found[:MAX_PREFIXES]
   ```
2. *Boot grace without a marker (G-A4, I21).* **NOT-BUILT, NOT-RUN.** It needs the netif N16 amendment (an empty file means "delegation lost"), which is netif's. The draft stands:
   - netif (`services/netif/host.nix`): on "no preferred prefix in the reply" and on `EXPIRE6`, write an **empty file** by rename; never remove it;
   - hook: delete `BOOT`, `GRACE` and the `systemd-run` call; keep the prefix on disk while the file is absent and `time.clock_gettime(time.CLOCK_BOOTTIME) < 120`;
   - a static `router-prefix-recheck.timer` with `OnBootSec = "125s"`.
3. *Sandbox (G-A5).* Built:
   ```nix
   serviceConfig = (import ./sandbox.nix) // {
     ReadWritePaths = ["/run/router" "/var/lib/router"];
     CapabilityBoundingSet = ["CAP_NET_ADMIN"];
     RestrictAddressFamilies = ["AF_UNIX" "AF_NETLINK"];
     IPAddressDeny = "any";
     Type = "oneshot"; ExecStart = "${hook} ${hookConfig}"; Restart = "on-failure"; RestartSec = 10;
   };
   ```
   The hook still calls `systemctl` and, until point 2 is built, `systemd-run` (both AF_UNIX).

### 3.10 remote-builder: target shape

> **Owner-gated (O8), not probed.** external-systems/home consumes this service. Nothing below was built or run in the probe round. Do not build it until the owner schedules it with `home`.

Replace `services/remote-builder/default.nix` roles' modules. Keep the role names and the trust model.

**Server, per machine (one daemon, one host key):**

```nix
# perMachine.nixosModule for machines that are a server in any instance
let
  mine = lib.filterAttrs (_: i: i.roles.server.machines or {} ? ${machine.name}) instances;
  settingsOf = name: mine.${name}.roles.server.machines.${machine.name}.settings;
  ports = lib.unique (map (name: (settingsOf name).port) (lib.attrNames mine));
  port = builtins.head ports;
  hostKey = config.clan.core.vars.generators.remote-builder-host-key.files.ssh_host_ed25519_key.path;
  sshdConfig = pkgs.writeText "remote-builder-sshd_config" ''
    Port ${toString port}
    HostKey ${hostKey}
    PidFile none
    UsePAM no
    AllowUsers nix-ssh
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    AuthorizedKeysFile /etc/ssh/remote-builder/authorized_keys
    ForceCommand ${config.nix.package}/bin/nix-daemon --stdio
    PermitTTY no
    PermitUserRC no
    PermitTunnel no
    AllowTcpForwarding no
    AllowStreamLocalForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    LoginGraceTime 20
    MaxAuthTries 3
    MaxStartups 32:30:128
    ClientAliveInterval 15
    ClientAliveCountMax 3
    LogLevel VERBOSE
  '';
in {
  assertions = [{
    assertion = lib.length ports <= 1;
    message = "remote-builder: machine '${machine.name}' is a server in several instances with different ports (${toString ports}); a machine runs one build sshd";
  }];
  clan.core.vars.generators.remote-builder-host-key = { … as today, fixed name … };
  users.users.nix-ssh = { isSystemUser = true; group = "nix-ssh"; shell = pkgs.bashInteractive; };
  users.groups.nix-ssh = {};
  users.users.sshd = lib.mkIf (!config.services.openssh.enable) { isSystemUser = true; group = "sshd"; };
  users.groups.sshd = lib.mkIf (!config.services.openssh.enable) {};
  nix.settings.trusted-users = ["nix-ssh"];
  environment.etc."ssh/remote-builder/authorized_keys".text = lib.concatLines keys;   # union over the instances
  systemd.services.remote-builder-sshd = {
    description = "sshd for remote builds: nix-ssh only, keys only";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      ExecStartPre = "${pkgs.openssh}/bin/sshd -t -f ${sshdConfig}";
      ExecStart = "${pkgs.openssh}/bin/sshd -D -e -f ${sshdConfig}";
      Restart = "always";
      RestartSec = 2;
    };
  };
  networking.firewall = lib.mkIf openFirewall (
    if interfaces == [] then {allowedTCPPorts = [port];}
    else {interfaces = lib.genAttrs interfaces (_: {allowedTCPPorts = [port];});}
  );
}
```

In the sketch, `keys` is the union over the machine's instances of: every client's public key, the CI key when enabled, `authorizedKeys`. `openFirewall` and `interfaces` come from the settings (assert that the instances agree, as for `port`). sshd's privilege-separation directory is `/var/empty` on NixOS (**ASSUMED**; the suite proves the daemon starts on a machine with `services.openssh.enable = false`).

Removed from the server: `services.openssh.enable`, `services.openssh.hostKeys`, `nix.sshServe.*` (`default.nix:127-151`). The perInstance server module keeps only: `system-features`, `binfmt`, `gc`, and contributes its keys. The four nix settings (`max-jobs`, `cores`, `min-free`, `max-free`, lines 155-163) become `lib.mkDefault`.

**Server options (role `server`):**

| Change | Type / default |
|---|---|
| **add** `port` | `types.port`, default `2222` |
| **add** `openFirewall` | `bool`, default `true` |
| **add** `interfaces` | `listOf str`, default `[]`: "Open the build port on these links only. Empty: on every link." |
| **change** `ciKey.enabled` default | `false` (was `true`): no root-equivalent key exists unless asked for |

**Client (`default.nix:226-266`):**

```nix
alias = server: "${instanceName}-${server.name}";
nix.buildMachines = map (server: {
  hostName = alias server;  protocol = "ssh-ng";  sshUser = "nix-ssh";  sshKey = keyFile;
  inherit (server.settings) systems maxJobs speedFactor supportedFeatures;
}) servers;
programs.ssh.extraConfig = lib.concatMapStrings (server: ''
  Host ${alias server}
    HostName ${server.address}
    Port ${toString server.settings.port}
    User nix-ssh
    IdentityFile ${keyFile}
    IdentitiesOnly yes
    HostKeyAlias ${alias server}
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 5
    ConnectionAttempts 1
    ServerAliveInterval 15
    ServerAliveCountMax 3
'') servers;
programs.ssh.knownHosts = lib.listToAttrs (map (server: {
  name = alias server;
  value = { hostNames = [(alias server)]; publicKey = server.hostKey; };
}) (lib.filter (server: server.hostKey != null) servers));
```

- The client reads the host key from generator `remote-builder-host-key` (fixed name).
- No `Host <machine name>` block: `ssh builder` by a human reaches the admin sshd as before (I27).
- **ASSUMED**: with `HostKeyAlias`, the known-hosts lookup uses the alias without a `[host]:port` form. The VM suite proves it (§8 step 7).

Note for the owner: external-systems/home uses this service today. After this change it must set `ciKey.enabled = true` if it uses the CI key, and regenerate the host key var (new generator name). The rule of this round says not to shim it.

---

## 4. The ideas, one verdict each

### (a) Default-deny ruleset inside the namespaces: **ACCEPT, refined**

- Refined shape: not `input`/`forward`/`output` with policy drop. Two chains: **prerouting at priority 0** (after Jool's -75) and **postrouting**. Reason: translated packets pass POSTROUTING only (**VERIFIED-SRC**), and one prerouting chain stops delivery and forwarding in one place.
- Who loads it: the Jool unit itself, first step, one atomic `nft -f` (§3.4). Not IfState (it has no nft). Not NixOS nftables (host namespace only).
- IfState apply: does not touch nft. The Jool unit is `PartOf=ifstate.service`, so it reruns and reloads the guard atomically. A namespace made again loses instance and guard together; the unit makes the guard first.
- Firewall restart: `nftables.service` acts in the host namespace. **VERIFIED-VM**: the guard is byte-equal after it (`nat-gateway`, `NAT_GATEWAY_GUARD_RESTARTS_OK`).
- Hook priority: guard at 0, Jool at -75. Never use -75 itself: the order of equal priorities is not defined.
- Cost: about 40 lines of Nix, one health-check function, one suite assertion flipped. No conntrack in the namespace, so no new state.
- Result: built and **VERIFIED-VM** (§3.4, §9 P6). One rule was added: link chatter is counted apart from what Jool handed back.
- The earlier rejection ("the suite asserts the namespace ruleset is empty") was a test protecting a mechanism. Replaced in §5.

### (b) Is namespace + veth the best model? **KEEP it**

| Alternative | Verdict | Reason |
|---|---|---|
| Jool in the host namespace, netfilter mode | reject | It steals in PREROUTING and emits in POSTROUTING: the forward chain never sees it (§10.1, proven by the suite's negative proof). A prerouting filter would see every packet of a flow as `new` (the entry is never confirmed), so the flow meters break. pool4 would be the host's public IPv4: port clashes with Cilium's eBPF SNAT on a gateway that is a node (§14.5 point 5). |
| Jool iptables mode (`-j JOOL`) | reject | Same PREROUTING steal. Needs xtables rules beside nftables: a second rule language on the machine. Solves neither gap. |
| A VRF | reject | Jool instances are per network namespace (`xlator_find_netfilter(dev_net(skb->dev))`, **VERIFIED-SRC**), not per VRF. A VRF gives no hook separation. |
| nftables-native NAT64 | not available | Linux 6.18 has no NAT64/SIIT expression in nf_tables. The kernel config was not in the store to grep; **NOT-RUN**, taken from upstream. Re-check on each kernel bump. |
| tayga (userspace, tun) + conntrack masquerade | reject for now, keep as the named fallback | For: no out-of-tree module, a crash fails closed, packets pass FORWARD on both sides so no namespace is needed. Against: single-threaded userspace on the path of every cluster image pull; one private IPv4 per client address from a dynamic pool; no BIB to read for pool accounting; it was rejected before (§12.2) and every failover suite is built on Jool. |
| eBPF CLAT/NAT64 | reject | Nothing packaged in the pinned set; Cilium's NAT46x64 is for services only. |

What flips the decision to tayga: Jool marked broken for the fleet kernel twice in a row (`checks.jool-available`), or one kernel oops traced to Jool. The design keeps that door open: all policy is in the host tables and the guard, none in Jool's own settings.

Cost of keeping: zero migration. The guard and the pre-translation rules are the whole change.

### (c) Host-side filter set: **REWORK into one model** (§3.3)

- Today: `nat64-undeclared` (before), `nat64-private` (after translation), `nat64-host` (input). Three rules at three points, one hole (`127/8`).
- Target: every refusal that can be decided in IPv6 is decided before translation (`to_translator`). What comes out of the namespace is checked against what may come out (`from_translator`, `input`). The post-translation private rule stays as a counter that must read 0.
- Gains: N05 closed at the first hop. Hairpin to pool4 (`192.0.0.0/24`) refused before Jool sees it. A refused packet no longer takes a BIB entry and a pool4 port. The client gets an ICMPv6 error at once.
- `nat64-host` stays in `input`: the gateway's public IPv4 can be dynamic, so it cannot be in `private6`.
- Cost: a rewrite of one table (about 80 lines), `test_table` rewritten.

### (d) CLAT follower trust: **KEEP the rule, ADD host filters, one optional improvement**

- Who may move `pool6`: only `clat-follow` (root, sandboxed). The `clat` unit never resets it. Correct.
- Rogue DNS: the follower asks the beacons by address with `dig @beacon`; resolvers are never used. An answer counts only when it is that gateway's inventory `/96`. A forger can at worst keep a dead gateway looking alive, or name another real gateway. Both need an on-path attacker, who can drop the traffic anyway. No authentication is added: it would buy nothing against that attacker.
- Rogue RA: never read by the follower. A hijacked default route is netif's (`ra`) and layer 2.
- New: `inet clat` (§3.5). Sources outside every gateway's `/96`, and `/96` sources that embed a private IPv4, never reach the CLAT.
- Optional improvement (step 8): **put the beacon inside `pool6`**, at `pool6::192.0.0.170` (the RFC 7050 address itself). Then a beacon answer proves that the `pool6` route to that gateway works. Today the beacon address is a different address: a gateway whose `pool6` route is black-holed upstream still looks alive, and its clients stay on it for ever. Mechanism: `dnat ip6 to [fd64::1]:5364` in a `nat prerouting` chain of `inet nat64` for declared sources, CoreDNS on `fd64::1:5364`. Removes the role option `address`, the "address on the machine" assertion, `ip_nonlocal_bind` and `CAP_NET_BIND_SERVICE`. Cost: the failover suite's addresses change; needs probe P4 on a gateway that is a kube node.

### (e) Health check, failover, boot grace: **KEEP windows; three additions**

- The windows (30 of 60 down, 120 up, 5 of 10 candidate, no move back) are simulated and tested. No change.
- Add: the guard and pool4 wholeness are part of "healthy" (§3.7, I9).
- Add: the hook's boot grace by uptime and explicit-empty file (§3.9 f). This is G-A4.
- Not added: withdraw on a full pool4 (it would move every client to the other gateway and fill that one; §17 G4 stands).
- Known and accepted: a gateway reboot gives 120 s without a beacon. Its clients keep translating through it (the CLAT's `pool6` is static) and do not move unless another beacon is up and theirs is silent for 60 s.

### (f) Router: **ACCEPT all, with one structural change**

- `wanPorts` (G-A3): fixed by rendering both firewalls from one value (§3.9 a), not by adding one more line. The bug class (two lists that must agree) goes away.
- Considered and rejected: making router links `trustedInterfaces` so that only the router's table judges them. It is one judge, but it fails open if the router's table is ever missing. Two judges fail closed.
- Hook sandbox (G-A5), validation (G-A6), empty LAN (G-A7), `servicePrefix` alone (G-A8): accept as specified in §3.9.
- Zones to the fabric: per-zone `fabric`, default off, fact `fabricInside` (§3.9 b).
- Added by this design: ICMP type list and redirect sysctls (I16), `ifstate` after `nftables` (I22).
- Considered and rejected: a "forwarding gate" unit that sets `forwarding=1` only after the tables load. On a machine that is also a kube node other services set forwarding anyway; the ordering I22 plus the build-time ruleset check cover a pure router. Revisit if a probe shows a boot window (P5).

### (g) remote-builder: **REDESIGN the server side** (§3.10)

- Root cause of B-A1 and B-A3: the service changes a daemon it does not own (the machine's sshd). The best design owns its own daemon.
- B-A1: one host key per machine, fixed generator name.
- B-A2: alias `<instance>-<server>`, `HostKeyAlias`, no bare-name block.
- B-A3: keys only, one user, strict sshd options, `mkDefault` nix settings.
- Alternative considered: keep the main sshd and read its host key from clan-core's `sshd` service vars. Smaller, but couples this service to another service being present and still shares port 22 and its settings. Rejected.
- Not solved, stated: `trusted` makes every key store-root on the builder. Dropping it needs signed inputs per client; out of scope.
- Cost: about 90 lines changed, eval tests rewritten, one new VM suite (2 VMs, no Jool, cheap).

### (h) Rate limits and pool4 exhaustion: **KEEP the meters; assert the bound; pin the timeouts**

- Keep: per-/64 meters, fail closed when a meter is full.
- Add I7 as an eval assertion for every rendered limit (§3.8). Today a client override can break the bound with no message.
- Pin Jool's `udp-timeout` and `icmp-timeout` in the unit, so the assertion's 300 s is the configured value.
- Exhaustion behaviour, **VERIFIED-VM** (P3, N16): existing flows continue; new flows are dropped by Jool in silence (`JSTAT_BIB6_NOT_FOUND`, no ICMPv6 error, not handed back); the beacon stays; nothing loops.
- Limit of the model, stated: several sources together can still fill one pool4 address (5 default sources at full rate). The scale knob, if ever needed, is more pool4 addresses on `jool1` (`192.0.0.2` to `192.0.0.6` with a `/29`), not higher limits. Not built now (owner decision §17 G4: one address).

### Own ideas

- **(i) Translate-or-drop as a stated namespace property** (I3, I4): the guard's `leaving` chain. It also turns "what Jool may emit" into a testable list.
- **(j) `from_translator` and `nat64-return-undeclared`**: the translator only ever talks back to declared clients. Stateless, cheap, symmetric with the allowlist.
- **(k) No IPv4 default route in the CLAT namespace.**
- **(l) `ifstate` after `nftables`** on every machine of this area (I22).
- **(m) `forwarding=0` inside both namespaces**: **VERIFIED-VM** (P2) and built. Jool translates; the namespace kernel cannot forward at all. The `sysctl -w` lines stay and write 0 (a namespace of an older generation may hold 1).
- **(n) A CLAT turns a client into an IPv6 router** (`forwarding=1` machine-wide): **decided by the owner (O7) and built** (§3.5, C08). Not `filterForward`: that is stateful and covers IPv4 too, and conntrack in FORWARD is not reliable beside Cilium. The CLAT's own stateless chain drops IPv6 between links nobody declared.

---

## 5. Deleted, simplified, and re-pinned checks

### Deleted or simplified code

| What | Where | Replaced by |
|---|---|---|
| post-translation-only private check | `nat64.nix:309-311` | `nat64-private` before translation; the old rule stays as `nat64-private-post` |
| `ct state != related` inside the undeclared rule | `nat64.nix:283` | two explicit rules (related ICMPv6 errors accept; undeclared drop) |
| CLAT namespace IPv4 default route | `clat.nix:129-132` | nothing |
| prototype's namespace `lo` declaration | worktree `fix-nat64`, `nat64.nix` | not taken over |
| `BOOT` marker, `GRACE`, runtime `systemd-run` | `router-prefix.py:50-55,145-158` | uptime rule + static timer + empty-file meaning |
| `unzoned.zones` | router service and module | `zones.<name>.fabric` |
| `wanPortRules`, `dnsRules`, DHCP and SSH lines, `firewall.interfaces` as separate renderers | `router.nix:52-58,154-163,389-395,425-427` | `offered` |
| `services.openssh.*` and `nix.sshServe.*` on the server | `remote-builder/default.nix:127-151` | `remote-builder-sshd` |
| per-instance host key generator `<instance>-host-key` | `remote-builder/default.nix:81,102-111` | per-machine `remote-builder-host-key` |
| header claim "Multi-instance safe … ssh alias" | `remote-builder/default.nix:7-10` | rewritten to what is true |

### Suite and eval checks that pin a mechanism

| Check today | Where | Replace with (behaviour) |
|---|---|---|
| `ip netns exec nat64 nft list ruleset` is empty | `services/nat-gateway/tests/vm/default.nix:782` | The guard is present with both chains before and after `systemctl restart nftables.service`, after `systemctl restart nat64-jool.service`, and after an IfState apply. Its `guard-leftover` and `guard-leaving` counters are 0 after the whole function suite (nothing legitimate ever hits them). |
| `ruleset(gw2)` identical across a Jool restart | same, `:789-791` | Keep for the host ruleset. Add the same for the namespace ruleset without counters. |
| `counted(machine, "forward", "nat64-private")` moves | `:472` and `kube-clat.nix:811` | The counter of `nat64-private` in chain `to_translator` moves; `nat64-private-post` stays 0; the client gets ICMPv6 admin-prohibited (curl fails at once, not by timeout). |
| `counted(machine, "forward", "nat64-undeclared")` | `:579,660`, `kube-gateway.nix:443` | Same name, chain `to_translator`. Update the helper `counted` to search the table, not one chain. |
| `counted(machine, "input", "nat64-host")` for `192.0.0.1` and the public IPv4 | `:599-602` | `192.0.0.1` is now refused by `nat64-private` (before translation). The public IPv4 still hits `nat64-host`. Assert each at its own counter. |
| eval `test_table` (text of the table) | `services/nat-gateway/tests/eval-tests.nix` | Structure tests: the chain names exist; `private6` has as many elements as `private`; every meter rule is in `to_translator`; `embedded` unit tests. Plus the build-time ruleset check NixOS already runs for `networking.nftables.tables`. |
| eval `test_addressInPool6`, `test_addressNotOnMachine`, `test_addressOtherSpelling` | same | Stay until step 8. Deleted with the `address` option. |
| eval `test_unknownUnzoned` | `services/router/tests/eval-tests.nix` | `test_fabricZoneFact`, `test_fabricDefaultOff`. |
| eval `test_forwardRules`, `test_ownLinksOnly` | same | Keep; update for `fabric`. Add `test_bothFirewallsAgree`. |
| router suite: boot-grace phase uses `/run/router/first-run-done` | `services/router/tests/vm/default.nix` (hook phases, near `:1063`) | "A failed first run and its retry keep the prefix" and "an empty PD file retires it at once" and "an absent file retires it after the recheck timer". |
| `kube-router.nix:194` `unzoned.zones = ["home"]` | `lib/gateway/tests/vm/kube-router.nix` | `zones.home.fabric = true`; add a negative: a zone without it reaches no pod (the suite has this at `:29`). |
| eval `test_generatorsNamespacedByInstance`, `test_sshServe`, `test_buildMachine`, `test_sshAliasFailsFast` | `services/remote-builder/tests/eval-tests.nix` | `test_oneHostKey`, `test_oneDaemonTwoInstances`, `test_mainSshdUntouched` (`services.openssh.hostKeys` and `.enable` not defined by the service), `test_aliasNamespaced`, `test_noBareAlias`, `test_keysOnly`. |

Checks that pin behaviour and must stay as they are: the two "G2 negative proof" subtests, PMTUD and fragments, the limits phase, every failover phase, `checks.clat-follow`.

### Status after the probe round (2026-11-27)

Rewritten in the prototype's suites, and passing:

| Check | File | Now |
|---|---|---|
| namespace ruleset is empty | `services/nat-gateway/tests/vm/default.nix`, ownership phase | `nft list tables` in the namespace is exactly `table inet guard`; its JSON without counters is equal before and after a restart of `nftables.service`, a restart of `nat64-jool.service` and an IfState apply (gateway and client); a TCP flow open across the restarts gets its echoes and no error line. Marker `NAT_GATEWAY_GUARD_RESTARTS_OK` |
| `counted(machine, chain, comment)` | same; `lib/gateway/tests/vm/kube-gateway.nix` | `counted(machine, comment, table="nat64")`: a rule is found by its comment (with its quotes) in the whole table |
| private destinations move `nat64-private` in chain `forward` | same, `assert_gateway` | twelve embeddings (the five of before, `127.0.0.1`, `192.0.0.1`, `192.0.0.2` among them) move `nat64-private` by one each; `curl` ends with code 7; `nat64-private-post == 0` |
| `192.0.0.1` and the public IPv4 both hit `nat64-host` | same | `192.0.0.1` is private (refused before translation); the public IPv4 hits `nat64-host` |
| negative proof "the NixOS forward chain alone lets an undeclared source ping through" | same | two stages: `to_translator` emptied → still no answer, `nat64-return-undeclared` +2; `from_translator` emptied too → the ping passes |
| guard counters | same, helper `guard_quiet` | `guard-leftover == 0 and guard-leaving == 0` after the basic phase, the CLAT phase, the traffic shapes and the rate limit floods; `health.json` says `"guard": true` |
| namespace forwarding | same | `net.ipv4.conf.all.forwarding` and `net.ipv6.conf.all.forwarding` are 0 in `nat64` and `clat` |
| `nat64-private` counted after translation (`kube-clat.nix`) | `lib/gateway/tests/vm/kube-clat.nix` | service mode: the stray packets are captured as IPv6 on the gateway's inside link (the IPv4 address is bytes 36 to 39 of the header); one pod request moves the counter by one; `JSTAT_SUCCESS` does not move. Fixture mode (`k3s-clat-mapped`) is unchanged |
| `unzoned.zones = ["home"]` | `lib/gateway/tests/vm/kube-router.nix` | `zones.home.fabric = true` |

Not rewritten yet (NOT-RUN; `check` was not run in the probe round, so every nix-unit row of the table above is open): `test_table`, `test_unknownUnzoned`, `test_forwardRules`, `test_ownLinksOnly`, the remote-builder tests, and the router suite's boot-grace phase (waits for §3.9 f point 2). Expect the nix-unit tests that read rule text (`test_table`, `test_meterPer64`, the router's input chain texts) to fail on the prototype until they are rewritten.

---

## 6. Hostile verdicts to add

Format as in `runs/*.verdicts.txt`: `HOSTILE SAFE|GAP <id> <claim>: <evidence>`. N05 to N07 exist and must turn SAFE.

### NAT gateway (suite `nat-gateway-hostile`)

| ID | Attacker | Command | Safe outcome |
|---|---|---|---|
| N05 | declared client | exists | `ping` and `curl` to `pool6::7f00:1` fail; `nat64-private` +1; `guard-leaving` 0 |
| N06 | outsider | exists | the probe chain (priority -300) counts the packet once; `clat-foreign-source` +1; `tcpdump -i clat0` sees nothing |
| N07 | declared client | exists | the probe chain counts the packet once; `nat64-protocol` +1; `tcpdump -i jool0` sees nothing; the client gets ICMPv6 admin-prohibited |
| N09 | declared client | `curl -m2 http://[pool6::c000:2]:1100/` and a UDP datagram to `pool6::c000:2` port P (P = another client's mapped port from `jool bib display`) | refused; `nat64-private` +1; the other client receives nothing |
| N10 | declared client, instance removed | on gw1: `ip netns exec nat64 jool instance remove default`; client: `ping -c1 -t 64 pool6::198.51.100.80`; count on `jool0` | exactly 1 crossing; `guard-leftover` +1; then `systemctl restart nat64-jool` and the suite's `assert_gateway` |
| N11 | declared client, guard removed | gw1: `ip netns exec nat64 nft delete table inet guard`; wait 15 s | `jq .guard /run/nat64-gateway/health.json` is `false`; the guard is back within 75 s without operator action; while it is away, N07's packet crosses at most twice (the `unreachable` route answers) |
| N12 | declared client | scapy: ICMPv6 type 135 (NS), 133 (RS), 130 (MLD query) to `pool6::198.51.100.80` | 0 crossings of `jool0`; `nat64-icmp-type` +3 |
| N13 | undeclared host | spoofed ICMPv6 `packet-too-big` about no flow, to `pool6::198.51.100.80` | dropped by `nat64-undeclared` (not `related`) |
| N14 | IPv4 side (`server4`) | `nping --udp -p 1100-1200 <gw public v4>` and a SYN to a port a client has mapped | nothing on `jool0` (`tcpdump -c1` times out); no `nat64-unsolicited4` needed because the masquerade's conntrack refuses first; assert both |
| N15 | declared client | IPv6 fragments: a 3000-byte UDP datagram to an allowed and to a private embedded IPv4 | allowed: delivered once; private: refused, 0 crossings |
| N16 | declared client | 300 parallel UDP flows against a `pool4` reduced to 10 ports (the suite's existing trick) | each refused new flow crosses `jool0` once; beacon stays; an existing TCP flow of another client continues |
| N17 | anyone | after N05 to N16: `nft list table inet guard` counters | `guard-leaving` is 0 (the host refused everything first); `guard-leftover` equals the count from N10 and N11 only |

### CLAT client (same suite, node `client`, attacker `outsider` or a new node `rogue` on the clients' segment)

| ID | Attacker | Command | Safe outcome |
|---|---|---|---|
| C01 | outsider | scapy `IPv6(src="<gw1 pool6>::a00:1", dst="<clat address>")/UDP(dport=53)/"x"` | `clat-private-source` +1; `tcpdump -i clat0` sees nothing |
| C02 | outsider | scapy `IPv6(src="<gw1 pool6>::c633:6450", dst="<clat address>")/TCP(dport=22, flags="S")` (public embedded, spoofed) | translated once; the host drops it: `clat-unsolicited` +1; no SYN-ACK leaves |
| C03 | outsider | same with `UDP(dport=<an open UDP port of the client, if any>)` | `clat-unsolicited` +1; the listener receives nothing |
| C04 | rogue | radvd with `nat64prefix 2001:db8:bad:64::/96` and a high-preference default route | `jool_siit -i clat global display` pool6 unchanged for 90 s (I14). The default-route result is printed as `HOSTILE INFO` (netif's area). |
| C05 | rogue | forged beacon answers naming `2001:db8:bad::c000:aa` from a gateway's address (the suite's existing foreign-prefix trick) | follower logs "ignored" once; no move |
| C06 | local root simulation | `ip netns exec clat jool_siit instance remove clat`; then `ping -c1 198.51.100.80` on the client | 1 crossing of `clat0`, no loop; `guard-leftover` +1 |
| C07 | outsider | `ping -c1 -t 64 <clat address>` from a source inside a gateway's `/96` that embeds a public IPv4 nobody talks to | translated once, the host answers or drops by its IPv4 rules; never more than 1 crossing per direction |

### Router (suite `hostile-router`)

| ID | Attacker | Command | Safe outcome |
|---|---|---|---|
| R17 | isp | with `wanPorts.tcp = [8443]` and `nc -l 8443` on the router: `nc -z -w2 <wan v4> 8443` and over IPv6; `nc -z <wan v4> 8444` | 8443 connects on both families; 8444 does not (I16, the positive case) |
| R18 | isp (DHCPv6 server) | delegate `::/0`, then `fd00::/8`, then `fe80::/10`, then the home zone's own static prefix, then `2001:db8:5::/56` | `nft list set inet router_svc delegated` holds only the last; WAN IPv6 keeps working throughout |
| R19 | isp | `nping --icmp --icmp-type timestamp <wan v4>`; ICMP redirect for a LAN host's route; ICMPv6 redirect | no reply; router's routing table unchanged; "input dropped" counter moves |
| R20 | isp | 200 echo requests in 1 s | at most burst + rate answers |
| R21 | home host | reach a pod / a fabric address with `fabric = false` (default) | no answer; "forward dropped" moves; `networkFacts.fabricInside == []` |
| R22 | home host | the same with `fabric = true` on its zone | connects (positive case) |
| R23 | operator error | first hook run fails (LAN link missing), systemd retries inside the boot window with no PD file | `.current` unchanged, `.retired == {}` |
| R24 | isp | stop answering DHCPv6 after boot; then send a reply with no preferred prefix | absent file: prefix kept until the recheck; empty file: retired at once and advertised deprecated |

### remote-builder (new suite `remote-builder`, nodes `builder`, `laptop`, `stranger`)

| ID | Attacker | Command | Safe outcome |
|---|---|---|---|
| B01 | stranger (no key) | `ssh -p 2222 -o BatchMode=yes nix-ssh@builder true` | `Permission denied (publickey)` |
| B02 | stranger | `ssh -p 2222 -o PreferredAuthentications=password,keyboard-interactive nix-ssh@builder` | no password method offered |
| B03 | laptop (valid key) | `ssh remote-builder-builder -tt bash`, `ssh remote-builder-builder -L 9999:127.0.0.1:22 -N`, `ssh -p 2222 -i <key> root@builder` | no shell (nix-daemon protocol only), forward refused, `root` refused |
| B04 | laptop | `nix build --max-jobs 0 --builders '' …` of a fresh derivation (`builtins.currentTime` in the name) through the configured builder | builds on `builder`: the output exists in the builder's store |
| B05 | laptop | `ssh builder true` as a normal user | goes to port 22 as that user, not as `nix-ssh` (I27) |
| B06 | builder in two instances | eval + VM: both instances' clients build | one daemon, one host key, both clients connect (I26) |
| B07 | scanner | `ssh-keyscan -p 22 builder` before and after enabling the service | port 22's keys are identical (I24) |

### Results of the hostile runs (2026-11-27, prototype applied)

The tables above are the draft. What ran, and how a verdict differs from its draft row:

| ID | Result | Suite | As run |
|---|---|---|---|
| N01 to N04 | SAFE | `nat-gateway-hostile` | unchanged scans |
| N05 | SAFE, ten verdicts | same | every target ends `curl rc=7, ping rc=1`, also `127.0.0.1` (on `main`: answered). One verdict more reads the mechanism: `nat64-private` 16, `nat64-private-post` 0, `nat64-host` 10, guard counters 0 |
| N06 | SAFE, four verdicts | same | (1) one crossing; (2) `clat-foreign-source` +1 and nothing let through to `clat0`; (3) with `to_clat` replaced by `accept`: `guard-leftover` +1, still one crossing each; (4) with the guard deleted too: still one crossing (forwarding off and the `unreachable` route) |
| N07 | SAFE, two verdicts | same | one crossing; `nat64-protocol` +1, nothing let through |
| N08 | SAFE | same | unchanged |
| N09 | SAFE | same | three datagrams to `pool6::192.0.0.2` at another client's mapped port: `nat64-private` +3 (the TCP half of the draft row is covered by N05's `192.0.0.1`) |
| N10 | SAFE | same | instance removed: one crossing, Jool handed the client's one packet back (a counter at prerouting -5 in the namespace), nothing left the namespace. `guard-leftover` moves by more than one: the health check's pings end there too |
| N11 | SAFE, five verdicts | same | see §3.7. The draft's "N07's packet crosses at most twice" ran as: host chain emptied and guard deleted, one crossing |
| N12 | SAFE | same | NS, RS and an MLD query to a pool6 address: `nat64-icmp-type` +3, nothing let through |
| N13 | SAFE | same | forged "packet too big" from the outsider: `nat64-undeclared` +1 |
| N14 | SAFE | same | UDP to 101 ports and SYNs from an IPv4 address no flow goes to: 0 packets towards `jool0`, the client's listener hears nothing, `nat64-unsolicited4` 0 (the masquerade's conntrack refuses first) |
| N15 | SAFE | same | 3000 bytes echoed to an allowed destination; to a private one `nat64-private` +1, nothing let through |
| N16 | SAFE | same | see P3 |
| N17 | SAFE | same | `guard-leaving` 0 on both gateways and both clients after every attack |
| C01 | SAFE | same | `clat-private-source` +1, nothing let through |
| C02, C03, C07 | SAFE, one verdict | same | three forged packets from a gateway's `/96` with a public IPv4 inside (SYN to 22, a datagram to an open UDP port, an echo request): let through 3, `clat-unsolicited` +3, the open port heard nothing, no answer sent, nothing forwarded back |
| C04 | SAFE | same | forged RA with a PREF64 option and a high-preference default route, three times: the CLAT's pool6 does not move in 20 s (the draft said 90 s). INFO: the client took no default route (`ra = false`) |
| C05 | SAFE, in the function suite | `nat-gateway` | marker `NAT_GATEWAY_FOREIGN_PREFIX_OK` (the existing foreign-prefix phase) |
| C06 | SAFE | `nat-gateway-hostile` | instance removed: the host's ping is sent once, comes back 0 times, `guard-leftover` +1 |
| C08 (new, O7) | SAFE, two verdicts | same | §3.5 |
| R01 to R14, R16 | SAFE (R16 is an INFO line) | `hostile-router` | unchanged |
| R15 | SAFE, **and only now a real verdict** | same | On `main`'s copy of the suite the rogue radvd had `MaxRtrAdvInterval 4` and no `MinRtrAdvInterval`: radvd refuses such an interface, no advertisement was ever sent, and SAFE meant nothing (the first runs' R16 line shows only the router's own default route). Fixed with `MinRtrAdvInterval 3` and a control: a LAN neighbour must take the rogue prefix, else the suite fails. Run 08: `R15 control: the rogue advertisement reached a LAN neighbour: True`; the router's routes and addresses are unchanged; R16 shows the neighbour's rogue default route and two `2001:db8:bad::` addresses |
| R17 | SAFE | same | a listener on 8443 and 8444, `wanPorts.tcp = [8443]` |
| R18 | SAFE | same | as run: the test writes netif's PD file (the DHCP client stopped) with `::/0`, `fd00::/8`, `fe80::/10`, a /24, a /72, `ff00::/8`, `64:ff9b::/96` beside the real prefix. The draft's DHCPv6 server on the ISP was not built |
| R19 | SAFE, two verdicts | same | ICMP timestamp requests; the redirect sysctls are read. Forged redirect packets were not sent |
| R20 | SAFE after a design change: 69 of 200 answered, 131 dropped by the rate rule (first run: 200 of 200, §3.9 e) | same | `ping -f -c 200` |
| R21, R22 | SAFE (`ROUTER_KUBE_DENY_OK`, `ROUTER_KUBE_OK`) | `router-kube` | the suite's existing checks with the new option: zone `home` (`fabric = true`) reaches pods on both nodes, zone `servers` (default) does not |
| R23, R24 | NOT-RUN | | need §3.9 f point 2 |
| B01 to B07 | NOT-RUN | | owner-gated (O8) |

---

## 7. Failure modes and stability

| Event | What happens in the target design | Invariant | Proof |
|---|---|---|---|
| `systemctl restart nftables` on a gateway | Host tables are replaced atomically. Meters and their dynamic sets start empty: every source gets a fresh burst (accepted). Conntrack entries stay, so open flows continue. The namespace's guard is not touched. | I10 | suite: ownership phase; a TCP flow open across the restart continues |
| IfState apply | Namespace, veth, routes stay. `nat64-jool` reruns (PartOf): guard reloaded atomically, instance found, pool4 checked. | I10 | suite phase "an IfState apply keeps …", plus guard listing |
| IfState fails on another link | Jool unit is `Wants`, not `Requires`: it still runs. | | existing |
| `nat64-jool` restart | Guard first, atomic. No moment without it. | I10 | N10, ownership phase |
| Jool instance removed (pool6 change, operator) | Packets get `NF_ACCEPT` from Jool, the guard drops them. Second layer: the `unreachable` route. One crossing. | I2 | N10 |
| Guard deleted by hand | Forwarding is off in the namespace and `pool6` is unreachable there: still no loop. The health check sees it within 10 s (run: 2.3 s until it was back), rounds turn bad, `nat64-jool` is restarted (reloads the guard); if it cannot be loaded the beacon is withdrawn after the `down` window (run: 29.9 s). VERIFIED-VM | I9 | N11 |
| Jool module fails to load at boot | Unit fails, retried every 5 s. No instance: the guard cannot load either if the namespace is missing; if the namespace exists the guard loads first and everything is dropped. Health never comes up: no beacon. Clients stay on or move to the other gateway. | I2, I9 | eval `test_unitsRetry`; VM: block `modprobe jool` once |
| Gateway dies | Unchanged: flows stall, followers move after 60 s to a gateway heard 5 of 10. | I15 | failover suite |
| Gateway reboots | 120 s without beacon. Its translator works as soon as `nat64-jool` ran. No client moves back. | | failover suite |
| Both gateways lose upstream | Both withdraw. Followers stay. | | existing phase |
| Health check crashes | Beacon stops with it (`BindsTo`). Restart resumes a state younger than 60 s. | | existing phase |
| pool4 full | New flows are dropped by Jool in silence; one crossing; band logged; beacon stays; open flows go on. VERIFIED-VM | I8 | N16 |
| Meter set full | Fail closed for sources without an entry (unchanged). | | eval `test_table` successor |
| Client: `clat` unit restart | Guard first; instance and its pool6 (the follower's choice) stay. | I12 | existing retry phase + C06 |
| Client: follower dies | `Restart=always`. pool6 stays where it was. | I14 | existing |
| Router boot, ISP slow | No PD file. Prefix on disk stays. Recheck at 125 s of uptime retires it only if still absent. | I21 | R23, R24 |
| Router boot, LAN link late | `router_src` fails to load, the run exits non-zero, retried after 10 s. The retry is inside the uptime window: prefix kept. | I21 | R23 |
| WAN prefix change | netif rewrites the file; the path unit fires; old prefix retired for 2 h, new one current; tables replaced one transaction each. | | existing hook phases |
| WAN delegation lost | netif writes an empty file; the hook retires the prefix at once. | | R24 |
| Rogue delegation | Skipped with a log line. Sets unchanged. | I20 | R18 |
| Boot order on a router | `nftables.service` before `ifstate.service`: links come up behind loaded tables. VERIFIED-VM: five boots, the tables were loaded 0.10 s to 0.16 s before IfState started | I22 | P5 (`hostile-router`); nix-unit to add |
| Build sshd crashes | `Restart=always`. Admin sshd unaffected. Clients fall back after `ConnectTimeout 5`. | I24 | B07 |
| Builder host key var not generated yet | Client renders no `knownHosts` entry; with `StrictHostKeyChecking yes` the connection fails closed. | I26 | eval `test_noKnownHostBeforeGeneration` (kept) |

---

## 8. Implementation order

A prototype of steps 1 to 6 exists as one patch (`probes/gateway/prototype.patch` in the session handoff, against `origin/main` `deeaba4`). It is evidence, not a PR: it has no spec amendment, no docs, no nix-unit updates, and `check` was not run on it (`fmt` was). Cut each step out of it, or write the step again from this section.

Every step, in this order:

1. amend `specs/gateway.md` (and `specs/netif.md` where named) **first** (AGENTS.md rule 3), and `documentation/docs/gateway/` with it;
2. edit the files named;
3. update the nix-unit tests named (`services/<service>/tests/eval-tests.nix`);
4. `git add -A`, `fmt`, `check`;
5. `vm-test --check <suite>`, then `vm-test <suite> --remote --quiet --rebuild` for every suite named, one at a time.

| # | PR | Files | What to build | nix-unit to change | Suites that prove it |
|---|---|---|---|---|---|
| 0 (**done**, round 65) | Hostile suites | `services/nat-gateway/tests/vm/default.nix` (`phases = "hostile"`), `services/nat-gateway/flake-module.nix`, `services/router/tests/vm/hostile.nix`, `services/router/flake-module.nix` | As in `patches/hostile-suites.patch`. No fix. | none | They run; N05 (`127.0.0.1`), N06, N07 are GAP on `main`. Never merge step 0 alone: `main` never holds a red suite. Merge it with step 1. |
| 1 (**done**, round 65) | Namespace guard, forwarding off, loop breakers, health | `lib/gateway/guard.nix` (new), `lib/gateway/names.nix` (`guard`), `lib/gateway/nat64.nix` (guard text, unit script, routes, health config and path), `lib/gateway/clat.nix` (guard text, unit script, routes), `lib/gateway/nat64-health.py` | §3.4, the CLAT guard and routes of §3.5, §3.7. `sysctl … forwarding=0` in both units. | `test_unitsRetry` (script order: `nft -f` before `instance add`), `test_clat`, `test_gatewayRenders` (routes: `unreachable` present, the CLAT's `0.0.0.0/0` absent), `test_healthSettings` (config has `guard`, `restart`). New: `test_guardText` (both chains, the link name, the pool6). | `nat-gateway` (ownership phase rewritten: guard equal across restarts, a flow goes on; guard counters 0; namespace forwarding 0); `nat-gateway-hostile` N06, N07, N10, N11 (five verdicts), C06, N17; `nat-gateway-failover`; `k3s-clat`. |
| 2 (**done**, round 65) | Host table rework, gateway | `lib/gateway/private.nix` (new), `lib/gateway/nat64.nix` (table, I7 assertion, Jool globals in the unit) | §3.3, §3.8 I7. | `test_table` → structure tests (the chains `to_translator`, `from_translator`, `input`, `postrouting` exist; every meter rule is in `to_translator`; `private6` has as many elements as `private`); `test_meterPer64`, `test_clientOverride`, `test_instanceLimits` (rule text without `oifname`); new `test_embedded` (the three cases of §3.3), `test_limitBound` (an override over the bound fails). | `nat-gateway` (`counted` finds a rule by its comment in the whole table; private refusal with curl code 7; `nat64-private-post` 0; the second negative proof empties both chains); `nat-gateway-hostile` N05 (eleven verdicts), N08, N09, N12 to N16; `nat-gateway-kube` (helper `counted`); `k3s-clat` and `rke2-clat` (private-refusal subtest: capture IPv6 on the gateway's inside link; `JSTAT_SUCCESS` must not move). |
| 3 (**done**, round 65) | Client table `inet clat` and O7 | `lib/gateway/names.nix` (`clat.table`), `lib/gateway/clat.nix` (table, option `forwardLinks`), `lib/kube-cluster/network-facts.nix` (fact `forwardLinks`), `lib/kube-cluster/service.nix`, `services/routed-fabric/default.nix`, `lib/gateway/router.nix` (each sets the fact) | §3.5. The fact is a cross-area contract: agree it with the fabric and kube designs first (`specs/target-design.md` §3). | `test_clat` (set `gateways` holds every gateway's pool6; `clat-forward` present), new `test_forwardLinks` (a kube node's table accepts `cilium*`, `lxc*`; a plain client's has no such accept). k3s, rke2, routed-fabric: one assertion each on the fact. | `nat-gateway-hostile` N06 (first two verdicts), C01, C02/C03/C07, C04, C08; `k3s-clat`, `rke2-clat`; `k3s-clat-mapped` unchanged (fixtures: `suite-compare` says same). |
| 4 (**done**, round 68, G29) | Router firewalls from one value | `lib/gateway/router.nix` | §3.9 a, c, d, e; `ifstate.after`. | `test_bothFirewallsAgree` (for every link, `firewall.interfaces.<link>` ports equal that link's accept rules), `test_wanPortsBothFirewalls`, `test_noZones`, `test_serviceWithoutAdvertisedZone`; update every test that reads the input chain's text. | `router`; `hostile-router` R01 to R16 unchanged, R17, R19, R20, the P5 phase; `router-kube`. |
| 5 (points 1 and 3 **done**, round 68, G30; point 2 is wave 3) | Prefix hook | `lib/gateway/router-prefix.py`, `lib/gateway/router.nix`; for point 2 also `services/netif/host.nix` and `specs/netif.md` N16 | §3.9 f. Points 1 and 3 are in the prototype. Point 2 needs netif's amendment in the same PR. | `test_sandboxed` covers the hook; the hook config has `own`; (point 2) the timer exists. | `router` (every G22 phase; for point 2 the boot-grace phases rewritten per §5); `hostile-router` R18; (point 2) R23, R24 and the `netif` suites that read the PD file. |
| 6 | Zones to the fabric | `services/router/default.nix`, `lib/gateway/router.nix`, `lib/gateway/tests/vm/kube-router.nix` | §3.9 b. Needs fabric step 1 (the fact `fabricInside` and its consumers). | delete `test_unknownUnzoned`; add `test_fabricZoneFact`, `test_fabricDefaultOff`; update the `unzoned` texts in `test_forwardRules`. | `router-kube` (zone `home` with `fabric = true` reaches pods on both nodes; zone `servers` without it does not); `router`. |
| 7 | remote-builder | **owner-gated (O8), not probed.** §3.10 is the draft. | | | new suite `remote-builder` (B01 to B07) |
| 8 | Optional: beacon inside pool6 | `lib/gateway/nat64.nix`, `services/nat-gateway/default.nix` | §4d. Only after P4 (NOT-RUN). | the three `address` tests deleted, `test_beaconInPool6` | `nat-gateway`, `nat-gateway-failover`, `nat-gateway-kube` |

Dependencies on the other areas. Each lands with its own design; adapt the gateway side in the PR that lands it:

- **netif target design** renames `netif-dhcpcd-<if>.service` to `netif-dhcpcd@<if>.service`, drops `netif-guard.service` (one transaction inside `ifstate.service`), and makes RA acceptance opt-in (`ra = true` per link, default false). Gateway suites that name the old units or rely on an RA default must adapt then: `services/router/tests/vm/default.nix` (the hook phases stop and restart `netif-dhcpcd-eth1.service`), `lib/gateway/tests/vm/wan.nix`, `lib/gateway/tests/vm/dual-wan.nix`. The line `ifstate.after = ["nftables.service"]` (§3.6) must survive netif's new unit.
- **netif N16 amendment** (an empty PD file means "delegation lost"): step 5 point 2.
- **fabric step 1** (the fact `fabricInside` and its consumers in routed-fabric and kube): step 6. The prototype carries `patches/fixes-fabric-kube.patch` for it.
- **kube and fabric** set the fact `forwardLinks`: step 3.

Rules for the implementer:

- Steps 1, 2 and 3 can be one PR or three. If three: after step 1 alone, `127.0.0.1` is stopped by the guard's `leaving` chain, not by the host; the N05 verdict that reads `nat64-private` belongs to step 2, and N06's "the client's own table refuses" to step 3.
- A suite that fails beside others and passes alone is a pass with a warning (owner policy). A guard counter (`guard-leftover`, `guard-leaving`) that is not 0 after a function suite is a failure, not noise: find the packet.
- `vm-test` takes one suite per call.
- Steps 1 to 3 change node derivations: `suite-snapshot`/`suite-compare` do not apply (not a refactor), except for `k3s-clat-mapped` in step 3.
- Test traps met while probing:
  - A hostile verdict needs a control that shows the attack ran. `hostile-router` R15 was SAFE for no reason until its radvd config was valid (§6). Give every hostile group one positive control; a missing control fails the suite.
  - Stopping `netif-dhcpcd-<if>.service` on a router takes the WAN's IPv6 away. A test that writes netif's PD file and then checks connectivity must leave the client running.
  - The test driver type-checks the script: `re.search(…).group(1)` on an optional match is refused. Use `re.findall(…)[0]`.
  - An emptied `to_clat` chain does not open the CLAT (the packet ends at `clat-forward`). To take that layer away, flush the chain and add `accept`.
  - While no Jool instance exists, the health check's own pings also end at the guard. Read a client's packet with a counter of its own in the namespace (prerouting, priority -5).
  - `nft log` inside a namespace needs `net.netfilter.nf_log_all_netns=1`.
  - A second `systemd.services.<unit>` attribute path beside an existing `systemd.services = { … }` block is a duplicate attribute for `nixf-diagnose`.

---

## 9. Probes, results and open risks

All runs: 2026-11-27, remote builder, kernel 6.18, Jool 4.1.15, IfState 2.5.1, the prototype on `origin/main` `deeaba4` with `patches/fixes-fabric-kube.patch` (the consumers of `fabricInside`). Log lines are in `probes/gateway/runs/` and `specs/probes/2026-11-27/gateway.md`.

### Probes

| ID | Question | Result | Evidence | Effect on the design |
|---|---|---|---|---|
| P1 | Does `ip6 daddr & ::ffff:ffff @private6` load and match? | **VERIFIED-VM** | Build-time `nft --check` passes; `nat-gateway`: twelve private embeddings move `nat64-private` by one each; `nat-gateway-hostile` N05 (ten verdicts), N15; C01 for the source form `ip6 saddr & ::ffff:ffff @private6` | None. No fallback form needed. |
| P2 | Does Jool translate with `forwarding=0` in the namespace? | **VERIFIED-VM**, NAT64 and SIIT | `nat-gateway-hostile` (run 03): `FINDING P2 … {'page': True, 'ping': True, 'udp': True, 'udp 3000 bytes (fragments)': True, '2 MB download': True}` for both. Then built in: `nat-gateway` passes every shape, path MTU discovery too, with forwarding 0 asserted | **Design changed**: forwarding is off in both namespaces (§3.2 layer 3). |
| P3 | What does Jool do with a new flow on a full pool4? | **VERIFIED-VM**: it drops it itself, in silence | `nat-gateway-hostile` N16: 300 datagrams, 300 crossings, `JSTAT_BIB6_NOT_FOUND: 290`, `guard-leftover` +0, ICMPv6 errors to the client: 0; an open TCP flow of another client goes on; the beacon stays | I8 holds without the guard. "Fail fast on exhaustion" is not available: the client times out. Stated in §0 point 10. |
| P4 | DNAT of the beacon into `pool6` on a gateway that is a kube node | **NOT-RUN** | | Step 8 stays optional and unproven. |
| P5 | Is there a moment at boot with links up and no tables on a router? | **VERIFIED-VM**: no such moment in five boots | `hostile-router`: `FINDING P5 boot 1: nftables.service active at 7.141 s, ifstate.service started at 7.297 s: the tables were loaded 0.156 s before the first link was configured` (0.096 s to 0.156 s in all five boots); `FINDING P5 ifstate.service is ordered after: ['network-pre.target', 'nftables.service', …]` | The order holds already through `network-pre.target` (nftables is before it, IfState after it); the explicit `ifstate.after = ["nftables.service"]` states it. No "forwarding gate" unit is needed. `systemd-sysctl` turns forwarding on about 1.7 s before the tables load, while no link is configured: nothing can be forwarded then |
| P6 | Do the guard's two chains see exactly what Jool hands back; do PMTUD, fragments and Jool's own ICMP errors pass? | **VERIFIED-VM** | `nat-gateway`: `guard-leftover` 0 and `guard-leaving` 0 on both gateways and both clients after every protocol, 2 MB down, 300 kB up, fragments, a 1400 byte hop (path MTU 1420 learned through NAT64, 1400 through the CLAT), the rate limit floods (asserted). N10 and C06: with no instance the client's one packet is handed back and ends at `guard-leftover`. `nat64-jool-error` 0: Jool sent no ICMPv6 error of its own in any shape | The guard is as drafted, plus one rule: link chatter (multicast) is counted apart, so `guard-leftover == 0` can be asserted. |

### Verified, refuted, not run

| Claim | Status |
|---|---|
| Jool hook: PRE_ROUTING, priority -75, both families | VERIFIED-SRC; consistent with every run (a chain at priority -5 sees only handed-back packets) |
| Untranslatable and "no instance" → `NF_ACCEPT` to the kernel | VERIFIED-SRC, VERIFIED-VM (N10, C06; N06 and N07 on `main`) |
| Unknown L4 in NAT64 is untranslatable, no ICMP sent | VERIFIED-SRC; with the design the host refuses it first with ICMPv6 admin-prohibited (N07: `nat64-protocol` +1, let through 0) |
| Translated packets leave via `dst_output` (postrouting only) on 6.18 | VERIFIED-VM (P6) |
| Jool's own ICMP errors pass postrouting with the namespace's addresses as source | **NOT-RUN as stated**: no run made Jool send one (`nat64-jool-error` 0). Path MTU discovery passes because the ICMP errors of the path are *translated* packets (source in `pool6` or pool4). The accept rules for `fd64::2` and `fd00:c1a7::2` stay, unproven |
| The `127.0.0.1` packet re-enters prerouting on `lo` | NOT-RUN (moot: refused on the host, N05; the guard's `leaving` chain is the second layer) |
| nft rulesets are per network namespace; a host `nftables.service` restart leaves the guard | VERIFIED-VM (`nat-gateway`, `NAT_GATEWAY_GUARD_RESTARTS_OK`) |
| The guard survives an IfState apply and a Jool unit restart | VERIFIED-VM (same phase and the IfState phase: JSON of the table equal) |
| IfState 2.5.1 accepts `type = "unreachable"` routes in a namespace and an apply stays a no-op | VERIFIED-VM (`nat-gateway`, `NAT_GATEWAY_IFSTATE_OK`) |
| The CLAT namespace needs no IPv4 default route | VERIFIED-VM (`nat-gateway`, every CLAT shape; `k3s-clat`: passes) |
| Bitwise-then-set-lookup on `ip6 daddr` and `ip6 saddr` | VERIFIED-VM (P1) |
| Jool global names (`udp-timeout`, `icmp-timeout`, `address-dependent-filtering`, `drop-externally-initiated-tcp`), time format `H:MM:SS` | VERIFIED-VM (the unit runs them at every start; `jool global update` lists the names) |
| A gateway without its guard is unhealthy; the check has it loaded again; if it cannot, the beacon is withdrawn | VERIFIED-VM (N11, four verdicts) |
| Host conntrack on `clat0` INPUT is reliable beside Cilium (`clat-unsolicited`) | **VERIFIED-VM** as behaviour: `k3s-clat` passes with the rule (a node's own IPv4 through its CLAT with Cilium up, pod egress, 2 MB down and up, a remade CLAT link, reboots). The counter read 8 on each node (R12). `rke2-clat` NOT-RUN |
| Default-deny IPv6 forwarding on a CLAT host (O7) | VERIFIED-VM on a plain client (C08, with the negative proof); on a kube node: **VERIFIED-VM**: `k3s-clat` passes (alpha is a fabric spine, beta a leaf; pods reach IPv4 and IPv6, the pod network between the nodes in both families, ClusterIP, NodePort, reboots; `clat-forward` 0 on both nodes). `rke2-clat` NOT-RUN |
| A gateway that is a kube node still works with the reworked table | **VERIFIED-VM**: `nat-gateway-kube` passes (`NAT_GATEWAY_KUBE_OK`: Cilium devices, pod egress, the shared IPv4) |
| `wanPorts` connect through both firewalls | **VERIFIED-VM**: `hostile-router` R17 `{'8443 IPv4': True, '8443 IPv6': True, '8444 IPv4': False, '8444 IPv6': False}` (a listener on both ports, `wanPorts.tcp = [8443]`) |
| The ICMPv6 type list does not break SLAAC, DHCPv6-PD, PMTUD on a router | **VERIFIED-VM**: `router` passes with the list (`ROUTER_LINKS_OK`, `ROUTER_RA_OK`, `ROUTER_HOOK_OK`, `ROUTER_OK`: DHCPv4 and DHCPv6-PD on the WAN, SLAAC and RDNSS in the zones, NAT44, native IPv6, every prefix-change phase) |
| A zone reaches pods only with `fabric = true` | **VERIFIED-VM**: `router-kube` passes (`ROUTER_KUBE_DENY_OK`): the zone `home` with `fabric = true` reaches pods on both nodes; the zone `servers` (default) does not, though it has a route. A fabric address as the target was not tried |
| Rogue delegations never enter the hook's sets; the sandboxed hook still works | **VERIFIED-VM**: `hostile-router` R18 (`inet router_svc holds ['2001:db8:1000::/60'], netdev router_src holds ['2001:db8:1000::/60']; a LAN host's IPv6 page: rc=0`); `router` passes every hook phase with the sandbox (`ROUTER_HOOK_OK`) |
| Failover behaviour is unchanged by the guard and the health addition | **VERIFIED-VM**: `nat-gateway-failover` passes every phase on the prototype (`NAT_GATEWAY_CRASH_OK`, `NAT_GATEWAY_LOSSY_OK`, `NAT_GATEWAY_FLAPPING_OK`, `NAT_GATEWAY_LOSSY_CANDIDATE_OK`, `NAT_GATEWAY_FAILOVER_OK`; 2299 s) |
| An ICMPv6 error from a source outside the gateways' `/96` reaches the CLAT and is translated | VERIFIED-VM for the gateway's own refusal (`k3s-clat`: a pod gets "No route to host" at once). "Packet too big" from a router on the path: NOT-RUN |
| `HostKeyAlias`, a second sshd with `UsePAM no` (remote-builder) | NOT-RUN, owner-gated (O8) |
| Linux 6.18 has no nf_tables NAT64 | NOT-RUN (kernel config not read) |
| Empty file under `/run/netif/pd/<link>` means "delegation lost" | NOT-RUN, NOT-BUILT (netif's N16 amendment) |
| The rules before the meters cost no noticeable throughput (R2) | NOT-RUN as a measurement; the 2 MB download of every suite passes |

### Refuted or changed by the probe round

| Draft | What the run showed | Now |
|---|---|---|
| "`guard-leftover` is 0 after the function suite" with the draft's two-rule chain | 13 to 14 packets on every namespace, constant from boot on: multicast link chatter on the veth, not Jool | `meta pkttype != host counter drop comment "guard-noise-in"` before the counted rule; `ip6 daddr ff00::/8 … "guard-noise-out"` in `leaving`. Then both counters are 0 and asserted |
| The namespace keeps `forwarding=1` | Jool translates with 0 (P2) | 0 in both namespaces; a third layer |
| "Fail fast on exhaustion" (§0 point 10) | Jool drops in silence (P3) | Stated as not available |
| `to_clat`: only a gateway's `/96` may send to the CLAT | Would drop "packet too big" from a router on the path (reasoned, not run) | ICMPv6 errors from any source are let in |
| `input` of `inet nat64` accepts established IPv4 from `jool0` | Not needed: the health check's answers are IPv6 | IPv6 only |
| With the allowlist chain emptied an undeclared source pings through (the suite's negative proof) | The answer is dropped by `nat64-return-undeclared` | The proof empties both chains; the single-chain case is a positive check |
| Router: an echo rate limit as an `accept` rule behind `ct state established` | 200 of 200 flood pings answered: one flood is one tracked flow | The limit is a `limit rate over … drop` rule ahead of the `established` accept (§3.9 e) |
| R5: clients forward IPv6 machine-wide, "not fixed" | The owner decided O7 | `clat-forward` and the fact `forwardLinks` (§3.5) |

### Open risks

- **R1 The guard hides a Jool regression.** Mitigated: the suites assert both counters 0 after real traffic, and `health.json` carries `guard` and `guard_dropped`. Open: nothing alerts on a counter that moves in production (an exporter is day-2).
- **R2 More rules before the meters cost CPU per packet.** Not measured.
- **R3 `ct state related` for foreign ICMPv6 errors.** Unchanged. N13: a forged error about no flow is dropped.
- **R4 Step 8 changes the failover signal.** Unchanged, NOT-RUN.
- **R5 closed** by O7 (§3.5).
- **R6 netif contract change (empty PD file).** Open, NOT-BUILT.
- **R7, R8 remote-builder.** Owner-gated (O8).
- **R9 ICMP type list on the router.** **VERIFIED-VM**: `router` passes with the list of §3.9 e. If a later suite fails on it, add the missing type; do not go back to "accept all".
- **R10 `forwardLinks` is a new cross-area fact.** A service that forwards IPv6 and does not set it is cut off on a CLAT host (`clat-forward` counts it). Today's setters: k3s/rke2, routed-fabric, router. Docker with IPv6 and Tailscale subnet routing on a CLAT host need the option `forwardLinks`; NOT-RUN.
- **R11 The guard's accept for Jool's own ICMP errors is unproven** (no run produced one). If Jool sends them with another source they are dropped and counted in `guard-leaving`: the suite assertion would show it.
- **R12 `clat-unsolicited` on a kube node** rests on Cilium handling pod return traffic before netfilter INPUT. `k3s-clat` passes with it. The counter is not 0 there (8 packets per node in the suite, not captured): do not assert it 0 on a kube node, and capture once before step 3 merges to name those packets. `rke2-clat` NOT-RUN.
- **R13 A gateway whose guard cannot load keeps translating** until its clients move (the beacon is the only signal, and a client moves only when another gateway is up). Accepted: the host table and layer 3 still hold. Stopping the translator instead would turn a missing second layer into an outage.
