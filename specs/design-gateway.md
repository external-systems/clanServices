# Target design: gateway services and remote-builder

> **Status: target design, not implemented** (SPEC.md round 61). Nothing
> here was run unless a line says "VERIFIED-VM" or names a suite verdict.
> Parts marked "owner decides" are proposals. The index, the cross-area
> contracts and the build order are in `specs/target-design.md`.
> Evidence named here (`reviews/`, `runs/`, the `fix-probe` and
> `fix-nat64` prototypes, patches) is session evidence of the review of
> 2026-11-27. It is not in the repo; the session handoff maps it.

Area: `services/nat-gateway/`, `services/router/`, `lib/gateway/`, `services/remote-builder/`.
Base: `main` at `4d9c1aa`. Line numbers are of that commit.
Written for the next implementer. Read §0 first, then implement §8 in order.

Owner's rule for this round: no consumers, no deployed machines. Suites, eval
tests, option names and schema versions are not protected. Only safety
behaviour is fixed.

---

## 0. The design in one page

1. **Keep Jool in a namespace behind a veth pair.** It is the best model here (§4b). Fix its two holes instead of replacing it.
2. **Policy before translation.** The host's `inet nat64` table refuses what must not be translated while the packet is still IPv6: undeclared source, embedded private IPv4, protocols Jool cannot translate. Today the private check runs after translation and misses `127.0.0.0/8` (N05).
3. **A default-deny guard inside each namespace.** A small nft table `inet guard` drops (a) everything Jool handed back to the kernel and (b) everything that would leave the namespace and is not a translated packet. This closes N05, N06, N07 by construction, also when no Jool instance exists.
4. **Structural loop breakers stay as a second layer.** `unreachable` routes for `pool6` and the CLAT address inside the namespaces (the prototype). No IPv4 default route in the CLAT namespace.
5. **A CLAT host gets its own table `inet clat`.** Only a gateway's `/96` with a public embedded IPv4 may reach the CLAT. Nothing unsolicited arrives as IPv4.
6. **The health check also checks the guard.** A gateway without its guard withdraws its beacon.
7. **Router: one function renders both firewalls.** The ports the router's table accepts on a link are the ports the NixOS firewall opens on that link. `wanPorts` then works (G-A3). A zone reaches the fabric only with `zones.<name>.fabric = true` (default false).
8. **Prefix hook: no boot marker.** netif writes an empty file for "delegation lost". An absent file means "no answer yet". A static timer rechecks once after boot. The hook is sandboxed and validates prefixes.
9. **remote-builder: a build sshd of its own.** One dedicated `sshd` per machine, own port, own host key, only the `nix-ssh` user, keys only. The machine's admin sshd is not touched.
10. **Rate limits: assert the pool4 bound at eval** for every rendered limit, pin Jool's timeouts, fail fast on exhaustion.

Status words used below:
- **VERIFIED-SRC**: read in Jool 4.1.15 source (`NICMx/Jool` tag `v4.1.15`, files named).
- **VERIFIED-CODE**: read in this repo.
- **VERIFIED-VM**: shown by the hostile runs in `runs/`.
- **ASSUMED**: kernel or tool behaviour not run. Has a probe in §9.

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
- **I3** The namespace kernel never answers, forwards or delivers a packet. Only ND on `jool1` and Jool's own ICMP errors exist besides translated packets.
- **I4** Only two kinds of packet leave the namespace: IPv4 with source in pool4, IPv6 with source in `pool6`. (Plus ND and Jool's ICMP errors.)
- **I5** The translator is no way into the gateway itself: nothing that left the namespace is delivered to a local socket of the gateway, except replies to the gateway's own health pings.
- **I6** Translated IPv4 leaves through an uplink only, masqueraded.
- **I7** One source /64 cannot exhaust pool4: for every rendered limit, `newFlowsBurst + newFlows × udpTimeout ≤ pool4 ports`. Checked at eval.
- **I8** A full pool4 never withdraws the beacon, and never makes a packet loop.
- **I9** A gateway is advertised (beacon up) only while: its health rounds are good, the guard table is loaded in the namespace, and pool4 is whole.
- **I10** A restart of `nftables.service`, an IfState apply, or a restart of `nat64-jool` never leaves a moment in which I1 to I5 do not hold.

### CLAT (client)

- **I11** A packet reaches the CLAT namespace from outside only if: destination is the CLAT address, source is inside a gateway's `/96` of the inventory, and the embedded IPv4 is public.
- **I12** Any single packet crosses `clat0`/`clat1` at most once per direction.
- **I13** Nothing unsolicited arrives as IPv4 from `clat0` on a host socket.
- **I14** The CLAT's `pool6` is always one of the inventory's gateways. Only `clat-follow` changes it. RAs, PREF64 and resolvers are never read.
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

### 3.1 Why packets behave as they do (facts the design rests on)

- **VERIFIED-SRC** Jool registers one netfilter hook per family at `NF_INET_PRE_ROUTING`, priority `NF_IP_PRI_NAT_DST + 25` and `NF_IP6_PRI_NAT_DST + 25`, that is **-75** (`src/mod/common/xlator.c:28-34`).
- **VERIFIED-SRC** A packet Jool does not translate gets `NF_ACCEPT`: "Returning the packet to the kernel" (`kernel_hook_netfilter.c`, `verdict2netfilter`). No ICMP error is sent for `VERDICT_UNTRANSLATABLE` (`core.c`, `send_icmp6_error`: "Linux will decide what to do").
- **VERIFIED-SRC** Unknown L4 protocol in NAT64 is `untranslatable_icmp` (`determine_incoming_tuple.c:328-331`). So protocol 253 goes back to the kernel. This is N07.
- **VERIFIED-SRC** No instance in the namespace is `VERDICT_UNTRANSLATABLE` too (`find_instance`, `-ESRCH`). So "instance missing" behaves like "untranslatable".
- **VERIFIED-SRC** A translated packet is sent with `dst_output()` (`send_packet.c`). It passes the namespace's **POSTROUTING** hook only. It never passes FORWARD or OUTPUT there.
- **VERIFIED-SRC** NAT64 hairpinning exists (`handling_hairpinning_nat64.c`): a 6→4 result whose destination is in pool4 is turned around inside Jool.
- **VERIFIED-VM** N05: `pool6::7f00:1` is translated to `127.0.0.1`, the namespace's loopback answers, Jool translates the answer back. N06 and N07: 32 crossings.
- **VERIFIED-CODE** The host's `nat64-private` rule matches `iifname jool0 ip daddr …` (`nat64.nix:311`), after translation. A packet to `127.0.0.0/8` never leaves the namespace, so the rule never sees it.

Consequence: an nft base chain in the namespace at **prerouting, priority 0** sees exactly the packets Jool gave back. A base chain at **postrouting** sees exactly what leaves (translated packets, ND, Jool's ICMP errors). Two small chains with `policy drop` make the namespace default-deny without touching translated traffic and without conntrack.

### 3.2 Namespace layout (unchanged shape)

```
gateway host                              namespace "nat64"
  jool0  192.0.0.1/30  fd64::1/64  <veth>  jool1  192.0.0.2/30  fd64::2/64
  route  <pool6> via fd64::2               route ::/0 via fd64::1
                                           route 0.0.0.0/0 via 192.0.0.1
                                           route <pool6> unreachable      (new)
                                           nft table inet guard           (new)
                                           Jool instance "default", pool4 192.0.0.2 1100-65535

client host                               namespace "clat"
  clat0  192.0.0.1/29  fd00:c1a7::1/64 <veth> clat1  192.0.0.2/29  fd00:c1a7::2/64
  route  0.0.0.0/0 via 192.0.0.2 mtu N     route ::/0 via fd00:c1a7::1
  route  <clat address>/128 via fd00:c1a7::2   route <clat address>/128 unreachable (new)
  nft table inet clat (new)                (IPv4 default route removed)
                                           nft table inet guard           (new)
                                           Jool SIIT instance "clat"
```

Not kept from the prototype: the namespace loopback with only `::1/128`. The pre-translation refusal (§3.3) and the guard's postrouting chain (§3.4) both stop `127.0.0.0/8`. One mechanism less for IfState to own.

### 3.3 Host table `inet nat64` (gateway), as it should render

Replace `nat64.nix:250-329`. New names in `names.nix`: none needed.

```nft
table inet nat64 {
  set trusted { type ipv6_addr; flags interval; auto-merge; elements = { … } }
  set default { type ipv6_addr; flags interval; auto-merge; elements = { … } }
  set custom  { type ipv6_addr; flags interval; auto-merge; elements = { … } }
  # the embedded IPv4 of a pool6 destination, as the low 32 bits
  set private6 { type ipv6_addr; flags interval;
    elements = { ::/104, ::a00:0/104, ::6440:0/106, ::7f00:0/104, ::a9fe:0/112,
                 ::ac10:0/108, ::c000:0/120, ::c0a8:0/112, ::c612:0/111, ::e000:0/99 } }
  set private4 { type ipv4_addr; flags interval;
    elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
                 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/3 } }
  # meters: unchanged (flows_*, packets_*, per /64, fail closed)

  chain forward {
    type filter hook forward priority -10; policy accept;
    oifname "jool0" jump to_translator
    iifname "jool0" jump from_translator
  }

  chain to_translator {
    # IPv4 towards pool4: only answers to masqueraded flows
    meta nfproto ipv4 ct state established,related accept
    meta nfproto ipv4 counter drop comment "nat64-unsolicited4"
    ip6 daddr != <pool6> counter drop comment "nat64-not-pool6"
    # an ICMPv6 error about an open flow may come from a router on the path
    ip6 saddr != @trusted ip6 saddr != @default ip6 saddr != @custom ct state related icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept
    ip6 saddr != @trusted ip6 saddr != @default ip6 saddr != @custom counter drop comment "nat64-undeclared"
    # before translation: what Jool cannot translate never enters (I1, N07)
    meta l4proto != { tcp, udp, ipv6-icmp } counter reject with icmpv6 admin-prohibited comment "nat64-protocol"
    meta l4proto ipv6-icmp icmpv6 type != { echo-request, echo-reply, destination-unreachable, packet-too-big, time-exceeded, parameter-problem } counter drop comment "nat64-icmp-type"
    # before translation: the embedded IPv4 is public (I1, N05, hairpin G-A2)
    ip6 daddr & ::ffff:ffff @private6 counter reject with icmpv6 admin-prohibited comment "nat64-private"
    # the meters, unchanged text, in this chain (custom clients, trusted, default)
    …
  }

  chain from_translator {
    ip6 saddr fd64::2 meta l4proto ipv6-icmp accept comment "Jool's own errors"
    ip6 saddr != <pool6> counter drop comment "nat64-return-source"
    ip6 daddr != @trusted ip6 daddr != @default ip6 daddr != @custom counter drop comment "nat64-return-undeclared"
    ip saddr != 192.0.0.2 counter drop comment "nat64-pool4-source"
    oifname != { <uplinks> } meta nfproto ipv4 counter drop comment "nat64-not-uplink"
    # second layer; stays at 0 because "nat64-private" refuses first
    ip daddr @private4 counter reject with icmp type net-prohibited comment "nat64-private-post"
  }

  chain input {
    type filter hook input priority -10; policy accept;
    ip6 daddr <address> meta l4proto { tcp, udp } th dport 53 ip6 saddr != @trusted ip6 saddr != @default ip6 saddr != @custom counter drop comment "beacon-undeclared"
    iifname "jool0" ct state established,related accept comment "answers to the health check"
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

Notes for the implementer:
- `ip6 daddr & ::ffff:ffff @private6` uses the same bitwise-then-lookup form the meters already use (`nat64.nix:295`, `${per64} != @flows_…`). **VERIFIED-CODE** for the form; **ASSUMED** for this exact mask with an interval set. Check with `nft -c` first (probe P1).
- Render `private6` from the existing `private` list (`nat64.nix:31`), so the two sets cannot drift:
  ```nix
  # nat64.nix, beside `private`
  embedded = range: let
    p = c.parse range;                       # p.start is the IPv4 as an integer
    length = lib.toInt (lib.last (lib.splitString "/" range));
    hex = n: lib.toLower (lib.toHexString n);
  in "::${hex (p.start / 65536)}:${hex (lib.mod p.start 65536)}/${toString (96 + length)}";
  private6 = map embedded private;
  ```
  nix-unit: `embedded "127.0.0.0/8" == "::7f00:0/104"`, `embedded "224.0.0.0/3" == "::e000:0/99"`, `embedded "0.0.0.0/8" == "::0:0/104"`.
- The NixOS forward rules (`nat64.nix:242-245`) and `filterForward = true` stay. They accept what this table let pass.
- The health check's pings leave through OUTPUT, not FORWARD. They are not judged here. Their answers match `ct state established` in `input`.
- Documentation ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) are **not** added to `private`: every suite uses them as its "Internet". Add them only with a suite-wide change of address plan.

### 3.4 Namespace table `inet guard` (gateway)

A plain file, loaded with `ip netns exec nat64 nft -f`. One transaction, so there is never a moment without it once it was loaded.

```nix
# nat64.nix, in `let`
guard = pkgs.writeText "nat64-guard.nft" ''
  table inet guard
  delete table inet guard
  table inet guard {
    # Jool's hook is prerouting priority -75 (Jool 4.1.15 xlator.c). What
    # reaches priority 0 is what Jool handed back: nothing may go on.
    chain leftover {
      type filter hook prerouting priority 0; policy drop;
      iifname "${inside}" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } ip6 hoplimit 255 accept
      counter comment "guard-leftover"
    }
    # Jool sends a translated packet with dst_output(): postrouting only.
    chain leaving {
      type filter hook postrouting priority 0; policy drop;
      oifname "${inside}" ip saddr 192.0.0.2 accept
      oifname "${inside}" ip6 saddr ${cfg.pool6} accept
      oifname "${inside}" ip6 saddr fd64::2 meta l4proto ipv6-icmp accept
      oifname "${inside}" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept
      counter comment "guard-leaving"
    }
  }
'';
```

What each chain stops:
- `leftover`: protocol 253 to `pool6` (N07), every packet while no instance exists, an IPv4 packet that is not for pool4, the `127.0.0.1` packet when it comes back in on `lo` (N05).
- `leaving`: anything towards `lo` (the first hop of N05), any source that is not pool4 or `pool6`.

No conntrack is used, so no conntrack hooks are registered in the namespace. ARP is not in the `inet` family and is not filtered.

Who loads it, in `nat64-jool` (`nat64.nix:408-444`), as the **first** command after `modprobe`:

```sh
modprobe jool
ip netns exec ${netns} nft -f ${guard}          # new: before any instance exists
ip netns exec ${netns} sysctl -w …              # as today
```

Add `pkgs.nftables` to the unit's `path`. Same unit, not a new one: a second oneshot with `Requires=` brings back the "dependency failed is not retried" trap of §17 G1.

Also in the script, after pool4 is whole (after `nat64.nix:443`), pin what the limits rest on (idempotent):

```sh
ip netns exec ${netns} jool -i default global update udp-timeout 0:05:00
ip netns exec ${netns} jool -i default global update icmp-timeout 0:01:00
ip netns exec ${netns} jool -i default global update address-dependent-filtering true
ip netns exec ${netns} jool -i default global update drop-externally-initiated-tcp true
```

- The two timeouts are Jool's defaults; they are written so that I7's number is the configured one. **ASSUMED**: option spelling and time format of 4.1.15 (`jool global update --help` in the suite's `print_versions`).
- The two filtering flags cost nothing: the host's masquerade is already address-and-port restricted. They are a second layer for G-A2, which the hostile run did not reproduce.

Routes, in `namespaces.${netns}.routing.routes` (`nat64.nix:359-368`), add (the prototype's line):

```nix
{ to = cfg.pool6; type = "unreachable"; }
```

### 3.5 Client: table `inet clat` and the CLAT guard

New in `clat.nix`. `names.nix` gains `clat.table = "clat"`.

```nix
# clat.nix `let`
pool6s = lib.unique (map (b: b.pool6) cfg.beacons);
private6 = …;   # same helper as nat64.nix; move `private` and `embedded` to lib/gateway/private.nix
```

```nft
table inet clat {
  set gateways { type ipv6_addr; flags interval; auto-merge; elements = { <every gateway's pool6> } }
  set private6 { … as §3.3 … }
  chain forward {
    type filter hook forward priority -10; policy accept;
    oifname "clat0" meta nfproto ipv6 jump to_clat
    iifname "clat0" meta nfproto ipv6 jump from_clat
  }
  chain to_clat {
    ip6 daddr != <clat address> counter drop comment "clat-not-address"
    ip6 saddr != @gateways counter drop comment "clat-foreign-source"
    ip6 saddr & ::ffff:ffff @private6 counter drop comment "clat-private-source"
  }
  chain from_clat {
    ip6 saddr != <clat address> counter drop comment "clat-spoof"
    ip6 daddr != @gateways counter drop comment "clat-not-gateway"
  }
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "clat0" ct state established,related accept
    iifname "clat0" meta nfproto ipv4 counter drop comment "clat-unsolicited"
    iifname "clat0" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept
    iifname "clat0" meta nfproto ipv6 counter drop comment "clat-host6"
  }
}
```

- The forward chain is **stateless** on purpose: Cilium attaches to `clat0` and the uplink, and conntrack in FORWARD is not reliable there (§16.4).
- The `input` chain uses conntrack for the host's own sockets only. A stateful NAT64 never opens a flow inwards, so "nothing unsolicited as IPv4" is true by design. **ASSUMED** to hold with Cilium's eBPF masquerade (pod answers are redirected by eBPF before INPUT). Proof: `k3s-clat` and `rke2-clat` must pass unchanged (§8 step 3). If they do not, drop the `clat-unsolicited` line of `input`, keep the rest, and write the finding into `upstream-facts.md`.
- `clat-private-source` matters: a spoofed `pool6::10.x.y.z` source would arrive on the host as IPv4 from a pod or node range (T5).
- Set `networking.nftables.enable = true` in `clat.nix`.

CLAT namespace guard, loaded first in the `clat` unit (`clat.nix:172-191`):

```nft
table inet guard
delete table inet guard
table inet guard {
  chain leftover {
    type filter hook prerouting priority 0; policy drop;
    iifname "clat1" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } ip6 hoplimit 255 accept
    counter comment "guard-leftover"
  }
  chain leaving {
    type filter hook postrouting priority 0; policy drop;
    oifname "clat1" ip6 saddr <clat address> accept          # 4→6
    oifname "clat1" ip daddr 192.0.0.1 accept                # 6→4
    oifname "clat1" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept
    oifname "clat1" ip6 saddr fd00:c1a7::2 meta l4proto ipv6-icmp accept
    oifname "clat1" ip saddr 192.0.0.2 meta l4proto icmp accept
    counter comment "guard-leaving"
  }
}
```

The guard does not name `pool6`, so the follower's moves need no reload.

Routes in `clat.nix:124-133`:
- add `{ to = "${cfg.address}/128"; type = "unreachable"; }` (prototype);
- **remove** `{ to = "0.0.0.0/0"; via = "192.0.0.1"; }`. The only IPv4 destination Jool SIIT emits is the on-link `192.0.0.1`. `k3s-clat-mapped` runs on fixtures and keeps its own routes.

### 3.6 Units and ordering

| Piece | Owner | Ordering | Survives |
|---|---|---|---|
| namespace, veth, addresses, routes (incl. `unreachable`) | IfState (`ifstate.service`) | after `nftables.service` (new, I22) | an apply keeps them |
| host tables `inet nat64`, `inet clat`, `inet router` | NixOS `nftables.service` | before `network-pre.target` | atomic reload per table; meters reset (accepted) |
| `inet guard` in `nat64` | `nat64-jool.service`, first step | `After=ifstate`, `PartOf=ifstate`, `Restart=on-failure` | firewall restart does not touch a namespace's ruleset; reloaded atomically on every start |
| Jool instance, pool4, globals | `nat64-jool.service` | after the guard, same script | idempotent |
| `inet guard` in `clat` | `clat.service`, first step | same | same |
| health check | `nat64-health.service` | `After=`/`Wants=nat64-jool` | resumes state younger than `resume` |
| beacon | `nat64-beacon.service` | `BindsTo=nat64-health` | stops with the check |
| follower | `clat-follow.service` | `Wants=clat` (never `Requires`) | waits while no instance |
| hook tables `router_svc`, `router_src` | `router-prefix.service` | after `nftables`, `ifstate` | each in its own transaction |
| recheck after boot | `router-prefix-recheck.timer` (new, static) | `OnBootSec` | no runtime `systemd-run` |
| build sshd | `remote-builder-sshd.service` (new) | `After=network.target` | independent of `sshd.service` |

New on gateway, client and router machines:

```nix
# nat64.nix, clat.nix, router.nix
systemd.services.ifstate.after = ["nftables.service"];
```

nix-unit: `lib.elem "nftables.service" config.systemd.services.ifstate.after` for one machine of each role.

### 3.7 Health check additions (`nat64-health.py`)

In the `count % POOL_EVERY == 0` block (`nat64-health.py:180-189`), add a guard check and a pool4 wholeness check. Both make the **round bad**, so the existing windows decide (no new state machine):

```python
def guarded():
    """The namespace's guard table is loaded with both chains."""
    shown = lines(["ip", "netns", "exec", config["netns"], "nft", "list", "table", "inet", "guard"])
    return shown is not None and any("hook prerouting" in l for l in shown) and any("hook postrouting" in l for l in shown)
```

- `sound = guarded()` is read every `POOL_EVERY` rounds and kept between reads.
- `rounds.append(len(alive) >= QUORUM and sound)`.
- When `sound` turns false: log once, and `subprocess.run(["systemctl", "--no-block", "restart", "nat64-jool.service"])` at most every 60 s. The unit reloads the guard.
- Write `"guard": sound` into `health.json`.
- Add `pkgs.nftables` to the unit's `path` (`nat64.nix:457-462`).

A full pool4 still never withdraws the beacon (I8).

### 3.8 Option surface, nat-gateway

| Change | Where | Type / default | Why |
|---|---|---|---|
| **add** eval assertion I7 | `nat64.nix` assertions | for `limits.default`, `limits.trusted`, each `custom[].limits`: `newFlowsBurst + newFlows * 300 <= 64436` | today only the default numbers satisfy it; an override can break it silently |
| **add** `clanServices.gateway.clat.table` | `names.nix` | `"clat"` | the new table |
| **remove** CLAT namespace IPv4 default route | `clat.nix:129-132` | | no loop surface |
| **keep** `address`, `allow`, `custom`, `limits`, `health.*` | | | no reason to rename |
| **later (step 8, optional)** remove role option `address`; the beacon listens at `pool6::192.0.0.170` | `services/nat-gateway/default.nix:107-111` | | beacon reachability then proves the `pool6` route (§4d) |

Eval assertion sketch (`nat64.nix`, in `assertions`):

```nix
(let
  ports = 65535 - 1100 + 1;
  udpTimeout = 300;
  over = lib.filter (l: l.limits.newFlowsBurst + l.limits.newFlows * udpTimeout > ports) (
    [{name = "tier default"; limits = cfg.limits.default;} {name = "tier trusted"; limits = cfg.limits.trusted;}]
    ++ map (client: {name = "client ${client.name}"; inherit (client) limits;}) cfg.custom
  );
in {
  assertion = over == [];
  message = "nat-gateway: ${lib.concatMapStringsSep ", " (l: l.name) over}: newFlowsBurst + newFlows x ${toString udpTimeout} s is more than pool4's ${toString ports} ports of a protocol; one source could fill the pool (specs/gateway.md §17 G4)";
})
```

### 3.9 Router changes (`router.nix`, `services/router/default.nix`)

**(a) One renderer for both firewalls (G-A3, I19).** Replace `wanPortRules`, `dnsRules`, the DHCP line, the SSH line and `firewall.interfaces` (`router.nix:52-58,154-163,389-395,423-427`) with one data structure:

```nix
# link -> what the router itself offers on that link
offered = let
  zoneOf = link: lib.findFirst (zone: lib.elem link zone.interfaces) null (builtins.attrValues lanZones);
  lan = link: let zone = zoneOf link; dns = zone.dns.ipv4 != null || zone.dns.ipv6 != null; in {
    tcp = lib.optional dns 53 ++ lib.optional zone.ssh 22;
    udp = lib.optional dns 53 ++ lib.optional (zone.dhcp4 != null) 67;
  };
in
  lib.genAttrs lanLinks lan // {${cfg.wan} = {inherit (cfg.wanPorts) tcp udp;};};
```

- NixOS side: `firewall.interfaces = lib.mapAttrs (_: p: {allowedTCPPorts = p.tcp; allowedUDPPorts = p.udp;}) offered;`
- Router table side: one rule per link and protocol from `offered` (`iifname "<link>" tcp dport { … } accept`). The DNS rules keep their `ip daddr <zone address>` match: render them from `offered` plus the zone's address, as today.
- nix-unit `test_bothFirewallsAgree`: for every link, the ports in `firewall.interfaces.<link>` equal the ports of that link's accept rules. `test_wanPortsBothFirewalls` from the review.

**(b) Zones reach the fabric by opt-in (owner decision).**

| Change | Where | Type / default |
|---|---|---|
| **add** `zones.<name>.fabric` | `services/router/default.nix:42-69` and `router.nix:213-247` | `bool`, default `false`: "The zone exchanges flows with the machine's links that are in no zone (a fabric, a cluster's pods), in both directions." |
| **remove** `unzoned.zones` | `services/router/default.nix:101-113`, `router.nix:262-266` | replaced by the per-zone option |
| **rename** `unzoned.source.{ipv4,ipv6}` → `fabricSource.{ipv4,ipv6}` | same files | unchanged type and default |
| **add** fact `clan._networkFacts.fabricInside` | `lib/kube-cluster/network-facts.nix` (beside the other `strList` facts) | `strList "Links whose hosts count as inside the fabric: a router's zones with fabric = true."` |

```nix
# router.nix
fabricZones = lib.attrNames (lib.filterAttrs (_: zone: zone.fabric) lanZones);
# replaces every `cfg.unzoned.zones` (lines 68-93, 339-341)
clan._networkFacts.fabricInside = zonesOf fabricZones;
```

- The consumer is routed-fabric's border guard (`services/routed-fabric/default.nix:1332-1336`): it accepts `iifname` in `fabricInside` beside `cilium*` and `lxc*`. That edit belongs to the routed-fabric design; this design only publishes the fact.
- "Unzoned links always reach the WAN" stays (owner-accepted, G25).
- Delete eval test `test_unknownUnzoned`; add `test_fabricZoneFact` (a zone with `fabric = true` → its link in `config.clan.networkFacts.fabricInside`; default → `[]`) and `test_fabricDefaultOff` (no `zone to unzoned` rule renders).

**(c) Empty LAN (G-A7, I23).**
- `services/router/default.nix` assertions: `settings.zones != {}` with "router/<instance>: a router needs one LAN zone or more".
- `router.nix:388`: `extraReversePathFilterRules = lib.optionalString (lanLinks != []) "iifname ${lans} accept";`

**(d) `servicePrefix` without an advertised zone (G-A8).** Replace the three `lib.mkIf (advertised != {})` at `router.nix:502,512,537` by `lib.mkIf (advertised != {} || cfg.servicePrefix.subnet != null)`. `corerad` keeps `advertised != {}`.

**(e) ICMP from router links (I16).** Replace `meta l4proto { icmp, ipv6-icmp } accept` (`router.nix:421`):

```nft
ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
ip protocol icmp icmp type echo-request limit rate 20/second burst 40 packets accept
icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem,
              nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit,
              mld-listener-query, mld-listener-report, mld-listener-done, mld2-listener-report } accept
icmpv6 type echo-request limit rate 20/second burst 40 packets accept
```

And pin, in `boot.kernel.sysctl` (`router.nix:365-370`):

```nix
"net.ipv4.conf.all.accept_redirects" = 0;
"net.ipv4.conf.default.accept_redirects" = 0;
"net.ipv4.conf.all.secure_redirects" = 0;
"net.ipv4.conf.all.send_redirects" = 0;
"net.ipv6.conf.all.accept_redirects" = 0;
"net.ipv6.conf.default.accept_redirects" = 0;
```

A forwarding machine ignores redirects by default. The lines make it a stated fact, not a kernel default.

**(f) Prefix hook.**

1. *Validation (G-A6, I20)*, `router-prefix.py:104-114`:
   ```python
   GLOBAL = ipaddress.IPv6Network("2000::/3")
   OWN = [ipaddress.ip_network(p) for p in CONFIG["own"] if ":" in p]   # zone prefixes + stable, from Nix
   MAX_PREFIXES = 8

   def delegated(text):
       found = []
       for word in (text or "").split():
           try:
               net = ipaddress.IPv6Network(word)
           except ValueError:
               continue
           if not net.subnet_of(GLOBAL) or not 32 <= net.prefixlen <= 64 or any(net.overlaps(own) for own in OWN):
               print(f"router-prefix: {word} is not a delegation to use (not global unicast, not /32 to /64, or one of the router's own prefixes): skipped", flush=True)
               continue
           if str(net) not in found:
               found.append(str(net))
       return found[:MAX_PREFIXES]
   ```
   `hookConfig` (`router.nix:117-134`) gains `own = ownPrefixes "ipv6";`.

2. *Boot grace without a marker (G-A4, I21).* Two changes.
   - **netif (N16 amendment, `services/netif/host.nix:117-125`)**: on "no preferred prefix in the reply" and on `EXPIRE6`, write an **empty file** by rename. Never remove it. Meaning: absent = no answer since boot (`/run` is new); empty = the ISP says none.
   - **hook** (`router-prefix.py:141-158`): delete `BOOT`, `GRACE`, the `systemd-run` call and its two branches. Replace with:
     ```python
     def handle(text):
         state = load_state()
         if text is None and state["current"] and uptime() < WAIT:
             # no answer yet since the boot: the prefix on disk stays (I21)
             prefixes = [state["current"]]
         else:
             prefixes = delegated(text)
         …
     def uptime():
         return time.clock_gettime(time.CLOCK_BOOTTIME)
     WAIT = 120
     ```
   - **static timer** in `router.nix` (replaces the runtime `systemd-run`):
     ```nix
     # hookWanted = advertised != {} || cfg.servicePrefix.subnet != null   (see d)
     systemd.timers.router-prefix-recheck = lib.mkIf hookWanted {
       wantedBy = ["timers.target"];
       timerConfig = { OnBootSec = "125s"; Unit = "router-prefix.service"; };
     };
     ```
   - Why this is better: the grace no longer depends on which run was "first". A retry (`Restart=on-failure`), a deploy or a manual start inside the window all keep the prefix. A real loss is explicit (empty file), so the window can be long without delaying a real change.
   - If the netif change is refused: keep "absent = none after `WAIT`". The uptime rule and the static timer still fix G-A4.

3. *Sandbox (G-A5)*, `router.nix:554-559`:
   ```nix
   serviceConfig = (import ./sandbox.nix) // {
     Type = "oneshot";
     ExecStart = "${hook} ${hookConfig}";
     Restart = "on-failure";
     RestartSec = 10;
     ReadWritePaths = ["/run/router" "/var/lib/router"];
     CapabilityBoundingSet = ["CAP_NET_ADMIN"];
     RestrictAddressFamilies = ["AF_UNIX" "AF_NETLINK"];
     IPAddressDeny = "any";
   };
   ```
   The hook still calls `systemctl --no-block try-restart corerad.service` (AF_UNIX). Keep that: a path unit for corerad would lose a change that lands while it runs; the digest file is self-healing.

### 3.10 remote-builder: target shape

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
- Firewall restart: `nftables.service` acts in the host namespace. **ASSUMED** (netfilter tables are per network namespace); the suite asserts it (§5).
- Hook priority: guard at 0, Jool at -75. Never use -75 itself: the order of equal priorities is not defined.
- Cost: about 40 lines of Nix, one health-check function, one suite assertion flipped. No conntrack in the namespace, so no new state.
- The earlier rejection ("the suite asserts the namespace ruleset is empty") was a test protecting a mechanism. Replaced in §5.

### (b) Is namespace + veth the best model? **KEEP it**

| Alternative | Verdict | Reason |
|---|---|---|
| Jool in the host namespace, netfilter mode | reject | It steals in PREROUTING and emits in POSTROUTING: the forward chain never sees it (§10.1, proven by the suite's negative proof). A prerouting filter would see every packet of a flow as `new` (the entry is never confirmed), so the flow meters break. pool4 would be the host's public IPv4: port clashes with Cilium's eBPF SNAT on a gateway that is a node (§14.5 point 5). |
| Jool iptables mode (`-j JOOL`) | reject | Same PREROUTING steal. Needs xtables rules beside nftables: a second rule language on the machine. Solves neither gap. |
| A VRF | reject | Jool instances are per network namespace (`xlator_find_netfilter(dev_net(skb->dev))`, **VERIFIED-SRC**), not per VRF. A VRF gives no hook separation. |
| nftables-native NAT64 | not available | Linux 6.18 has no NAT64/SIIT expression in nf_tables. The kernel config was not in the store to grep; **ASSUMED** from upstream. Re-check on each kernel bump. |
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
- Exhaustion behaviour, target: existing flows continue; new flows fail; the beacon stays; nothing loops. Whether Jool answers a new flow on a full pool4 with `drop` or `untranslatable` is **ASSUMED** unknown; with the guard both end at one crossing (probe P3 records which).
- Limit of the model, stated: several sources together can still fill one pool4 address (5 default sources at full rate). The scale knob, if ever needed, is more pool4 addresses on `jool1` (`192.0.0.2` to `192.0.0.6` with a `/29`), not higher limits. Not built now (owner decision §17 G4: one address).

### Own ideas

- **(i) Translate-or-drop as a stated namespace property** (I3, I4): the guard's `leaving` chain. It also turns "what Jool may emit" into a testable list.
- **(j) `from_translator` and `nat64-return-undeclared`**: the translator only ever talks back to declared clients. Stateless, cheap, symmetric with the allowlist.
- **(k) No IPv4 default route in the CLAT namespace.**
- **(l) `ifstate` after `nftables`** on every machine of this area (I22).
- **(m) Probe: `forwarding=0` inside both namespaces** (P2). If Jool still translates, the namespace kernel cannot forward at all: a third, independent loop breaker, and two `sysctl -w` lines go.
- **(n) A CLAT turns a client into an IPv6 router** (`clat.nix:92`, `forwarding=1` machine-wide). A two-NIC client then forwards between its NICs. Target: on a client that sets no forwarding fact of its own, `networking.firewall.filterForward = lib.mkDefault true` with accepts for `clat0` only. Needs a look at Docker and kube clients first (open risk R5).

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

---

## 7. Failure modes and stability

| Event | What happens in the target design | Invariant | Proof |
|---|---|---|---|
| `systemctl restart nftables` on a gateway | Host tables are replaced atomically. Meters and their dynamic sets start empty: every source gets a fresh burst (accepted). Conntrack entries stay, so open flows continue. The namespace's guard is not touched. | I10 | suite: ownership phase; a TCP flow open across the restart continues |
| IfState apply | Namespace, veth, routes stay. `nat64-jool` reruns (PartOf): guard reloaded atomically, instance found, pool4 checked. | I10 | suite phase "an IfState apply keeps …", plus guard listing |
| IfState fails on another link | Jool unit is `Wants`, not `Requires`: it still runs. | | existing |
| `nat64-jool` restart | Guard first, atomic. No moment without it. | I10 | N10, ownership phase |
| Jool instance removed (pool6 change, operator) | Packets get `NF_ACCEPT` from Jool, the guard drops them. Second layer: the `unreachable` route. One crossing. | I2 | N10 |
| Guard deleted by hand | `unreachable` routes still stop loops for `pool6`. The health check sees it within 10 s, rounds turn bad, `nat64-jool` is restarted (reloads the guard); if it stays away 30 s the beacon is withdrawn. | I9 | N11 |
| Jool module fails to load at boot | Unit fails, retried every 5 s. No instance: the guard cannot load either if the namespace is missing; if the namespace exists the guard loads first and everything is dropped. Health never comes up: no beacon. Clients stay on or move to the other gateway. | I2, I9 | eval `test_unitsRetry`; VM: block `modprobe jool` once |
| Gateway dies | Unchanged: flows stall, followers move after 60 s to a gateway heard 5 of 10. | I15 | failover suite |
| Gateway reboots | 120 s without beacon. Its translator works as soon as `nat64-jool` ran. No client moves back. | | failover suite |
| Both gateways lose upstream | Both withdraw. Followers stay. | | existing phase |
| Health check crashes | Beacon stops with it (`BindsTo`). Restart resumes a state younger than 60 s. | | existing phase |
| pool4 full | New flows fail; one crossing; band logged; beacon stays. | I8 | N16 |
| Meter set full | Fail closed for sources without an entry (unchanged). | | eval `test_table` successor |
| Client: `clat` unit restart | Guard first; instance and its pool6 (the follower's choice) stay. | I12 | existing retry phase + C06 |
| Client: follower dies | `Restart=always`. pool6 stays where it was. | I14 | existing |
| Router boot, ISP slow | No PD file. Prefix on disk stays. Recheck at 125 s of uptime retires it only if still absent. | I21 | R23, R24 |
| Router boot, LAN link late | `router_src` fails to load, the run exits non-zero, retried after 10 s. The retry is inside the uptime window: prefix kept. | I21 | R23 |
| WAN prefix change | netif rewrites the file; the path unit fires; old prefix retired for 2 h, new one current; tables replaced one transaction each. | | existing hook phases |
| WAN delegation lost | netif writes an empty file; the hook retires the prefix at once. | | R24 |
| Rogue delegation | Skipped with a log line. Sets unchanged. | I20 | R18 |
| Boot order on a router | `nftables.service` before `ifstate.service`: links come up behind loaded tables. | I22 | nix-unit; VM: `systemd-analyze dot` or unit timestamps |
| Build sshd crashes | `Restart=always`. Admin sshd unaffected. Clients fall back after `ConnectTimeout 5`. | I24 | B07 |
| Builder host key var not generated yet | Client renders no `knownHosts` entry; with `StrictHostKeyChecking yes` the connection fails closed. | I26 | eval `test_noKnownHostBeforeGeneration` (kept) |

---

## 8. Implementation order

Every step: amend `specs/gateway.md` (and `SPEC.md` D65 for step 7) **first** (AGENTS.md rule 3), edit `documentation/docs/gateway/` with it, `git add -A`, `fmt`, `check`, then the named suite with `vm-test <suite> --remote --quiet`.

Bring the hostile suites over from the worktree `fix-nat64` (`hostile-suites.v1.patch`) as step 0, unchanged, so that each later step turns a GAP into SAFE.

| # | PR | Content | Proof |
|---|---|---|---|
| 0 | Hostile suites | `nat-gateway-hostile`, `hostile-router` as in the patch. No fix. | They run; verdicts equal `runs/*.verdicts.txt` (N05, N06, N07 are GAP). |
| P | Probes (one throwaway suite, prints `FINDING`) | P1 to P5 of §9. | Findings written into `upstream-facts.md` (Jool section). Amend this design where a probe disagrees. |
| 1 | Namespace guard + loop breakers | §3.4, the CLAT guard of §3.5, `unreachable` routes, CLAT IPv4 default route removed, guard check in the health script (§3.7). | nix-unit: guard text has both chains and the right link names; routes present; unit script loads the guard before `instance add`. VM: `nat-gateway` (line 782 flipped per §5), `nat-gateway-hostile`: N06 and N07 SAFE, N10, N11, C06 SAFE; `nat-gateway-failover`; `k3s-clat`. |
| 2 | Host table rework, gateway | §3.3: `to_translator`, `from_translator`, `input`, `private6`, Jool globals, I7 assertion. | nix-unit: `embedded` cases, structure tests, `test_limitBound` (an override over the bound fails). VM: `nat-gateway` with re-pointed counters, hostile N05, N09, N12 to N17 SAFE, `nat-gateway-kube`, `rke2-clat`. |
| 3 | Client table `inet clat` | §3.5. | nix-unit: sets hold every gateway's pool6. VM: hostile N06 stopped on the host (nothing on `clat0`), C01 to C05, C07; `k3s-clat`, `rke2-clat`, `k3s-clat-mapped` unchanged (it uses fixtures: `suite-compare` says same). |
| 4 | Router firewalls from one value | §3.9 a, c, d, e; I22. | nix-unit: `test_bothFirewallsAgree`, `test_wanPortsBothFirewalls`, `test_noZones`, `test_serviceWithoutAdvertisedZone`, `ifstate` after `nftables`. VM: `router`, `hostile-router` R17, R19, R20; `router-kube`. |
| 5 | Prefix hook | §3.9 f, with the netif N16 amendment (empty file) in the same PR; amend `specs/netif.md` too. | nix-unit: `test_sandboxed` covers the hook; the timer exists. VM: `router` hook phases rewritten per §5; R18, R23, R24. `netif` suites that read the PD file. |
| 6 | Zones to the fabric | §3.9 b: `fabric`, fact `fabricInside`, `fabricSource`. Consumer edit in routed-fabric comes with its own design. | nix-unit: `test_fabricZoneFact`, `test_fabricDefaultOff`. VM: `router-kube` (R21, R22). |
| 7 | remote-builder | §3.10. | nix-unit list of §5. VM: new suite `remote-builder` (B01 to B07), registered in `services/remote-builder/flake-module.nix` under `clanTests`. |
| 8 | Optional: beacon inside pool6 | §4d. Only after P4. Removes the role option `address`. | nix-unit: the three `address` tests deleted, `test_beaconInPool6`. VM: `nat-gateway`, `nat-gateway-failover` (all phases), `nat-gateway-kube`; new phase "pool6 route withdrawn upstream while the gateway is healthy: its clients move". |

Rules for the implementer:
- Do not merge steps. Each one must leave every suite of the area green.
- A suite that fails beside others and passes alone is a pass with a warning (owner policy). A guard counter that is not 0 after a function suite is a failure, not noise: find the packet.
- `vm-test` takes one suite per call.
- Steps 1 to 3 change node derivations: `suite-snapshot`/`suite-compare` do not apply (not a refactor), except for `k3s-clat-mapped` in step 3.

---

## 9. Open risks and probes

### Probes (run before step 1; one throwaway suite on the `nat-gateway` topology)

| ID | Question | How | Decides |
|---|---|---|---|
| P1 | Does `ip6 daddr & ::ffff:ffff @private6` load, and match `pool6::7f00:1`? | `nft -c -f` on the rendered table; then one ping with a counter | the form of `nat64-private`. Fallback: one rule per range with `ip6 daddr & ::ff00:0 == ::7f00:0` style masks. |
| P2 | Does Jool translate with `forwarding=0` in the namespace (both families, NAT64 and SIIT)? | set it, run `assert_gateway` and a CLAT curl | idea (m). If yes: set 0 and drop the `sysctl -w … forwarding=1` lines (`nat64.nix:411`, `clat.nix:174`). |
| P3 | What does Jool 4.1.15 do with a new flow on a full pool4: drop, ICMP error, or hand back? | pool4 of 10 ports, an 11th flow, `jool stats display --all`, count crossings without the guard | the wording of I8; no design change either way |
| P4 | DNAT of the beacon to `fd64::1:5364` on a gateway that is a kube node (Cilium on the uplink) | `nat-gateway-kube` topology, `dig @pool6::c000:aa` | step 8 |
| P5 | Is there a moment at boot with links up and no tables? | on a router VM: compare `systemctl show -p ActiveEnterTimestampMonotonic nftables ifstate` over 5 boots | whether I22's ordering line is enough |
| P6 | Do the guard's two base chains see what §3.1 says? | with the guard loaded and `counter` on both policies: run `assert_gateway`, PMTUD and fragment shapes | confirms the Jool priority reading on the pinned kernel (6.18) |

### Verified vs assumed

| Claim | Status |
|---|---|
| Jool hook: PRE_ROUTING, priority -75, both families | VERIFIED-SRC (`xlator.c:28-34`) |
| Untranslatable and "no instance" → `NF_ACCEPT` to the kernel | VERIFIED-SRC |
| Unknown L4 in NAT64 is untranslatable, no ICMP sent | VERIFIED-SRC |
| Translated packets leave via `dst_output` (POSTROUTING only) | VERIFIED-SRC; hook traversal on 6.18 ASSUMED → P6 |
| Jool's own ICMP errors use the kernel's `icmp_send`/`icmpv6_send` and pass POSTROUTING with the namespace's addresses as source | ASSUMED → P6 (PMTUD shapes must still pass) |
| N05/N06/N07 mechanics | VERIFIED-VM |
| The `127.0.0.1` packet re-enters PREROUTING on `lo` | ASSUMED (kernel loopback path); N05 SAFE proves the fix whichever layer stops it |
| nft rulesets are per network namespace; a host `nftables.service` restart leaves the guard | ASSUMED; asserted in the suite (§5) |
| IfState 2.5.1 accepts `type = "unreachable"` routes in a namespace | VERIFIED by the prototype's hostile runs (`runs/*.with-fix.*` exist for other suites; the nat-gateway fix run is not in `runs/`) → treat as ASSUMED until step 1's suite |
| Bitwise-then-set-lookup on `ip6 daddr` | ASSUMED → P1 |
| Jool global names (`udp-timeout`, `address-dependent-filtering`, `drop-externally-initiated-tcp`) | ASSUMED for 4.1.15 spelling → step 2's suite |
| Host conntrack on `clat0` INPUT is reliable beside Cilium | ASSUMED → step 3 (`k3s-clat`, `rke2-clat`) |
| `HostKeyAlias` lookup ignores the port | ASSUMED → B04 |
| `sshd -f <own config>` runs beside the main sshd with `UsePAM no` on NixOS | ASSUMED → step 7 suite |
| Linux 6.18 has no nf_tables NAT64 | ASSUMED (kernel config not in the store) |

### Open risks

- **R1 The guard hides a Jool regression.** If a Jool update starts returning packets it used to translate, the guard drops them silently. Mitigation: `guard-leftover` and `guard-leaving` counters must be 0 after the function suite; the health file carries the guard state; add both counters to `health.json` so a later exporter sees them.
- **R2 More rules before the meters cost CPU per packet.** Four extra matches and two set lookups per packet. Not measured. The suite's throughput shape (2 MB download, `kube-clat.nix:790`) must not slow down noticeably; record the time in the PR.
- **R3 `ct state related` for foreign ICMPv6 errors.** It depends on conntrack having seen the flow on the IPv6 side. It does today (the same expression is in the current rule). Unchanged risk.
- **R4 Step 8 changes the failover signal.** A beacon inside `pool6` makes beacon loss and route loss one event. That is the goal, but it also means a short route flap silences the beacon. The 60 s follower clock absorbs flaps under a minute. Simulate in `checks.clat-follow` before building.
- **R5 Clients forward IPv6 machine-wide** (idea n). Not fixed by this design. Needs an owner decision: default `filterForward` on CLAT clients, or a netif-level statement.
- **R6 netif contract change (empty PD file).** Other readers of `/run/netif/pd/<link>` must treat an empty file as "none". Today the only reader in this repo is the hook (**VERIFIED-CODE**: grep finds `router.nix:118,504` and `router-prefix.py`).
- **R7 remote-builder and external-systems/home.** `home` consumes this service. The redesign changes the port, the alias, the host-key generator name and the CI key default. The owner must update `home` in the same session as step 7 merges.
- **R8 Second sshd and clan's own sshd service.** If a machine also runs clan-core's `sshd` service with certificates, the build sshd does not use them. Intended (I24), but worth one README line.
- **R9 `ICMP` type list on the router.** A too-short ICMPv6 list breaks ND or PMTUD. The list in §3.9 e follows RFC 4890's must-not-drop set. The `router` suite's SLAAC, DHCPv6-PD and PMTU phases are the proof; if one fails, add the missing type, do not go back to "accept all".
