# Host networking: target design (netif, modes, IfState base, registry)

> **Status: target design, not implemented** (SPEC.md round 61). Nothing
> here was run unless a line says "VERIFIED-VM" or names a suite verdict.
> Parts marked "owner decides" are proposals. The index, the cross-area
> contracts and the build order are in `specs/target-design.md`.
> Evidence named here (`reviews/`, `runs/`, the `fix-probe` and
> `fix-nat64` prototypes, patches) is session evidence of the review of
> 2026-11-27. It is not in the repo; the session handoff maps it.

Base: `main` at 4d9c1aa. Read-only work: nothing was built, evaluated or booted.
Builds on `reviews/netif.md` (N-A1..N-A16) and `runs/netif-hostile*.txt`.
Paths are relative to `the repo root`.

Words used below:

- **bundle**: one store directory with everything netif applies for one generation (IfState YAML, dhcpcd files, a manifest).
- **B**: the bundle of the running generation. **L**: the last bundle that passed ("last good").
- **obligation**: one thing the guard tests. Every obligation comes from netif's own declarations.
- "verified": read in code or in a store file. "assumed": kernel, systemd, dhcpcd or IfState behaviour I did not see run.

The owner's rule applies: no compatibility, no shims. Only the safety behaviour is fixed.

---

## 0. The design in one page

1. **One transaction.** `ifstate.service` runs one program, `netif-apply`. It applies, starts DHCP, checks, and rolls back. Program order replaces `ExecStartPre`/`ExecStartPost` lists from three modules. This removes N-A1 and N-A2 by construction.
2. **One bundle.** IfState YAML, dhcpcd files and a guard manifest are one store path. "Roll back" is "activate bundle L". Apply and rollback share one function.
3. **dhcpcd units never change between generations.** One template unit reads its file through `/run/netif/active`. A deploy never stops a DHCP client that has no change (the root cause of N36).
4. **The guard tests only what netif declared.** Its own gateways, its own default routes, its own addresses, the declared targets. Never a route of BGP, Cilium, Tailscale or another owner (N-A3).
5. **B must prove itself.** If B fails and L exists, the kernel ends on L. Always. The "fault is outside, re-apply B" branch is removed: it is a lockout path.
6. **A bundle that failed while L passed is marked bad.** It is not tried again at boot or at the next switch.
7. **One sysctl baseline** for every link: declared, hot-plugged, and links of other owners. Redirects off, source routes off, router advertisements off unless declared.
8. **RA is opt-in per link.** `ra` defaults to false.
9. **DHCP is an untrusted input.** One policy table says what a lease may set. Routes other than the router: no (owner decision). MTU: no. DNS: only on a link that owns a default route.
10. **Guard state is per mode.** A runtime switch to another mode is refused before it starts.

---

## 1. Threat model

| # | Actor | Can do | Must not achieve |
|---|---|---|---|
| T1 | Hostile host on a LAN the machine is on | Send any L2/L3 frame: ARP, ND, RA, ICMP redirect, DHCP offer, spoofed source | Move the host's routes; add an address or route; become DNS for all names; open a port |
| T2 | Rogue DHCP server on a declared DHCP link | Win the DHCP race; send any option | Anything beyond: address, mask, the router (only on the default-owning link), DNS (only on the default-owning link) |
| T3 | Rogue DHCP server on a hot-plug link (dock, USB) | Same | Take traffic from a declared link that is up; change MTU; add routes beside its own default at metric +100 |
| T4 | Rogue RA sender | Send RAs with prefixes, routes, MTU, hop limit | Any effect on a link that did not declare `ra`. On a link that did: no route information routes, no MTU change, no hop-limit change |
| T5 | Hostile Wi-Fi access point | DHCP, RA, DNS on the Wi-Fi link (iwd owns it) | Take traffic from a wired link that is up (metrics, N18). Not netif's client: residual, see §9 |
| T6 | A guest on a guest-ports bridge | RA, ARP, DHCP towards the host | Any route, address or DNS on the host |
| T7 | The owner's bad deploy | Wrong address, gateway, VLAN, bond, a config IfState rejects, a deploy during an outage | Lose the path that worked before the deploy |
| T8 | The owner's bad deploy while booted in another mode | `switch` into a configuration with another manager | Two managers on one running system |

Stated limits (not defended, tested as "documented"):

- On the link that owns the default route, the DHCP server and (with `ra`) any RA sender choose the gateway. L3 cannot stop that. Containment only: they get no extra routes.
- A spoofed ARP or ND answer passes a layer-2 probe. A TCP target does not have that weakness.
- The guard sees outbound reachability only. A firewall rule that closes inbound SSH is invisible to it. §3.9 covers that at evaluation.
- ARP poisoning of the real gateway's entry. Switch features (DAI, RA guard) are the defence.

---

## 2. Invariants (numbered, each testable)

Safety:

- **I1 No lockout by deploy.** After any run of `ifstate.service` on a machine with L, the kernel holds B only if every obligation of B passed in that run (or B is unclean but passed, I3). Otherwise it holds L.
- **I2 Do no harm.** The guard changes the network only when an obligation failed. A failed apply whose obligations pass is reported and left alone.
- **I3 Only proven bundles are recorded.** L is set only after a clean apply (IfState exit 0, every declared physical NIC present, guest ports intact) with every obligation passed.
- **I4 A bad bundle is not retried by itself.** A bundle that failed while L then passed is marked bad. Boot and later switches activate L at once until the bundle changes or the owner runs `netif-guard retry`.
- **I5 Own evidence only.** Every obligation names a netif link. A default route, gateway or neighbour of any other owner never fails or passes the guard.
- **I6 A missing NIC blocks nothing.** Every other link gets its addresses, routes, DHCP client and DNS. The unit fails after all of that ran.
- **I7 No redirect, no source route.** `accept_redirects`, `secure_redirects`, `send_redirects`, `accept_source_route` are 0 on every link of the machine, in every mode.
- **I8 RA only where declared.** `accept_ra` is 0 on every link except: a declared link with `ra = true`, a hot-plug link, a link whose owner handles RAs itself. Where accepted: no route-information routes, no MTU, no hop limit below 64.
- **I9 A lease sets a closed list.** Per §3.5. No option 33/121/249 route without `dhcp.classlessRoutes`. No MTU. No DNS on a link without a default route unless `dhcp.dns = true`.
- **I10 One default per family from netif**, on the declared link (N21, kept).
- **I11 DNS scope.** Lease DNS from a link that owns no default route never answers. A hot-plug link's DNS is not a default DNS route while a declared link has DNS and carrier.
- **I12 One manager per boot.** A switch into a configuration of another mode is refused before activation.
- **I13 Firewall stays closed.** Links are untrusted unless declared (N19, kept). The only port netif opens is UDP 546 on DHCPv6 links.

Stability:

- **S1 A deploy that does not change a link's dhcpcd file does not restart its client.** The lease and address stay.
- **S2 A reapply changes nothing** (kept; `assert_ifstate_noop`).
- **S3 Bounded time.** A passing run returns as soon as all obligations pass. A failing run ends within `2 × timeout` plus two applies.
- **S4 One writer** per kernel object (registry, kept) and per sysctl key (§3.3).
- **S5 Stable source addresses.** `use_tempaddr = 0` on declared links.

---

## 3. Target design

### 3.1 The bundle

New in `services/netif/host.nix` (replaces `dhcpcdConfs`, `guardGeneration`, `host.nix:362-373` and `host.nix:531-539`):

```nix
clanServices.netif.bundle = pkgs.linkFarm "netif-bundle" (
  [
    { name = "ifstate.yaml";  path = config.environment.etc."ifstate/ifstate.yaml".source; }
    { name = "manifest.json"; path = pkgs.writeText "netif-manifest.json" (builtins.toJSON manifest); }
  ]
  ++ lib.mapAttrsToList (interface: l: {
    name = "dhcpcd/${interface}.conf";
    path = dhcpcdConf interface l;
  }) dhcpLinks
  ++ lib.optional (hotplug.interfaces != []) { name = "dhcpcd-hotplug.conf"; path = hotplugConf; }
);
```

The bundle path changes exactly when something netif applies changes. `B == L` is a path compare.

`manifest.json` (built from `cfg.links`, i.e. links with `memberOf == null`):

```json
{
  "version": 1,
  "mode": "default",
  "timeout": 45,
  "physical":  ["enp1s0"],
  "addresses": [{"dev": "enp1s0", "address": "192.0.2.2/24"}],
  "gateways":  [{"family": 4, "dev": "enp1s0", "address": "192.0.2.1"}],
  "defaults":  [{"family": 4, "dev": "enp1s0", "source": "static", "gateway": "192.0.2.1"},
                {"family": 6, "dev": "enp1s0", "source": "ra"}],
  "targets":   [{"kind": "tcp", "address": "192.0.2.10", "port": 22},
                {"kind": "neigh", "address": "192.0.2.9", "dev": "enp1s0"},
                {"kind": "ping", "address": "192.0.2.8"}],
  "dhcp": ["enp2s0"],
  "hotplug": ["enx"],
  "guestBridges": {"br0": ["enp3s0"]},
  "routeMetric": 100
}
```

Rules for the manifest (Nix, in `guard.nix`):

- `gateways`: every declared static gateway of every link, also in a policy table (as `guard.nix:27-34` today).
- `defaults`: one entry per family for the link where `v4Default`/`v6Default` is true (`default.nix:189-193`), and only when the link is `required` (§3.7). `source` is `"static"` (IfState route), `"dhcp"` (DHCPv4 lease) or `"ra"`.
- `addresses`: every static address of a link. Nothing for DHCP or SLAAC addresses.
- `targets`: `guard.targets`, typed as today (`guard.nix:475-506`).
- `physical`: as `lib/ifstate.nix:27-29`.

### 3.2 The transaction (`netif-apply`)

One Python program, `services/netif/apply.py`, built with `pkgs.writers.writePython3Bin` (pyyaml as today's `mergeIgnore`, `guard.nix:63`). Python because the decision is a pure function that a derivation can unit-test without a VM. Bash arrays and file descriptors (`guard.nix:183-226`) are not testable that way.

Runtime state:

| Path | Meaning | Lifetime |
|---|---|---|
| `/run/netif/active` | symlink to the bundle the kernel holds. dhcpcd reads its files through it | boot |
| `/run/netif/lock` | `flock` for the transaction and the DHCP reconcile | boot |
| `/run/netif/guard/status.json` | last outcome, failed obligations, time. Read by `netif-status` | boot |
| `/run/netif/mode` | the mode this boot started in (§3.8) | boot |
| `/var/lib/netif/guard/<mode>/good` | symlink to L | disk |
| `/var/lib/netif/guard/<mode>/bad` | text file: path of the bundle marked bad | disk |
| `/nix/var/nix/gcroots/netif-guard-<mode>-good` | GC root of L | disk |

Deleted state: `/run/netif-guard/{applying,rolled-back,generation,dhcpcd/,rollback.yaml}`, `last-good-dhcpcd`, `last-good-defaults`.

#### Pseudocode

```
main(B, guard_on):
  lock /run/netif/lock
  L   = readlink good        (None when absent or its manifest version is unknown)
  bad = read bad

  if guard_on and bad == B and L and L != B:          # I4
      activate(L, running=B)
      fail = verify(L.manifest, B.targets)
      status("still-rolled-back", fail); exit 1

  clean = activate(B)
  if not guard_on: exit 0 if clean else 1
  fail = verify(B.manifest, B.targets)

  step = decide(clean, fail, B, L)
  commit      -> good := B; remove bad; exit 0
  unclean     -> exit 1          # obligations pass; apply or NIC not clean; nothing touched (I2)
  unverified  -> exit 1          # no L, or L == B: nothing to roll back to
  rollback    ->
      applied = activate(L, running=B)
      fail2   = verify(L.manifest, B.targets) if applied else ["rollback apply failed"]
      step2   = decide_after_rollback(applied, fail2)
      bad        -> bad := B; exit 1      # L passes: B is the fault
      undecided  -> exit 1                # L fails too: stay on L (I1)
      rollback-failed -> exit 1

activate(X, running=None):                 # the one function for apply and rollback
  yaml = X/ifstate.yaml
  if running: yaml = merge_ignore(X yaml, running yaml)   # guard.nix:63-96, kept
  pre_apply()            # ra_defrtr_metric loop (host.nix:584-597), guest-ports list (host.nix:266-296)
  rc = ifstatecli --config yaml apply
  old = readlink /run/netif/active
  symlink /run/netif/active -> X           # atomic: ln -sfn to a temp name, rename
  reconcile_dhcp(old, X)
  dns_apply()                              # host.nix:48-66
  missing = [d for d in X.manifest.physical if not exists /sys/class/net/d]
  guests_ok = guest_ports_check()          # host.nix:297-310
  return rc == 0 and not missing and guests_ok

reconcile_dhcp(old, new):
  for dev, conf in new/dhcpcd/*.conf:
      skip when /sys/class/net/dev is absent
      unit = systemd-escape --template=netif-dhcpcd@.service dev
      if old has the same file content for dev:  systemctl start --no-block unit    # no-op when running (S1)
      else:  systemctl stop unit ; systemctl start --no-block unit                   # stop is blocking: its ExecStopPost flushes the old lease first
  for dev in old/dhcpcd minus new/dhcpcd:  systemctl stop unit
  for dev in /sys/class/net matching new.manifest.hotplug and not in new/dhcpcd:
      systemctl start --no-block netif-hotplug@<escaped dev>.service

verify(manifest, targets):                 # one deadline for everything
  deadline = now + manifest.timeout
  pending = obligations(manifest, targets)
  loop:
      pending = [o for o in pending if not test(o)]
      if not pending: return []
      if now >= deadline: return [describe(o) for o in pending]
      sleep 1
```

Obligation tests:

| Obligation | Test | Notes |
|---|---|---|
| address `A` on `dev` | `ip -j addr show dev <dev>`: an entry with that `local` and `prefixlen`, without `tentative` or `dadfailed` | proves the apply reached the kernel |
| gateway `G` on `dev` | IPv4: `arping -q -c1 -w1 -I <dev> <G>`. IPv6: `ndisc6 -q -1 -r1 -w1000 <G> <dev>` | as `guard.nix:136-137` |
| default, `static` | `ip -j -<f> route show default dev <dev>` has an entry with `gateway == G` | table main |
| default, `dhcp` | same command, an entry with `protocol == "dhcp"`. Then its `gateway` must answer at layer 2 on `<dev>` | the only learned gateways the guard probes |
| default, `ra` | same, `protocol == "ra"`. Then its `gateway` must answer | |
| target `tcp` | `socket.create_connection((address, port), timeout=1)` | no netcat |
| target `neigh` | as gateway | |
| target `ping` | `ping -q -c1 -W1` | |

What is **not** tested: any default route with another protocol or on another device. That is the whole fix for N-A3: the `ip route show default` scan without a filter (`guard.nix:203-207`) is gone.

#### The decision as code (pure, unit-tested)

```python
def decide(clean, failures, bundle, good):
    if not failures:
        return "commit" if clean else "unclean"
    if good is None or good == bundle:
        return "unverified"
    return "rollback"


def decide_after_rollback(applied, failures):
    if not applied:
        return "rollback-failed"
    return "undecided" if failures else "bad"
```

Decision table (this is the test table for `checks.netif-guard-logic`):

| # | apply of B | obligations of B | L | action | outcome | exit | recorded |
|---|---|---|---|---|---|---|---|
| 1 | clean | pass | any | none | `committed` | 0 | `good := B`, `bad` removed |
| 2 | not clean | pass | any | none | `unclean` | 1 | nothing |
| 3 | any | fail | none, or `L == B` | none | `unverified` | 1 | nothing |
| 4 | any | fail | `L != B` | activate L; L passes | `rolled-back` | 1 | `bad := B` |
| 5 | any | fail | `L != B` | activate L; L fails too | `undecided`, kernel stays on L | 1 | nothing |
| 6 | any | fail | `L != B` | activate L; IfState fails | `rollback-failed` | 1 | nothing |
| 7 | not tried | not tried | `bad == B`, `L != B` | activate L | `still-rolled-back` | 1 | nothing |

Every exit 1 prints one line that names the outcome, the failed obligations and the next step. Example for row 5:

```
netif-apply: undecided. With this generation: no answer from 192.0.2.1 on enp1s0. With the last good network too: no answer from 192.0.2.1 on enp1s0. The last good network stays applied. When the gateway answers again: systemctl restart ifstate.service (specs/netif.md N25)
```

`netif-guard` CLI (in `tools.nix`, three verbs):

- `netif-guard status`: prints `status.json`, `good`, `bad`, `active`.
- `netif-guard retry`: removes `bad`, then `systemctl restart ifstate.service`.
- `netif-guard force`: `netif-apply --no-guard B`. For a console session after a planned renumbering. Records nothing.

#### What "the switch succeeded" means

Exit 0 of `ifstate.service` means all of:

1. IfState applied B with exit 0.
2. Every declared physical NIC exists; guest ports are intact.
3. Every declared static address is on its link and usable.
4. Each default route netif declared is in the main table, from the declared source.
5. Each declared gateway, each learned gateway of a netif default, and each target answered.

`switch-to-configuration` starts `ifstate.service` and waits for it, so the deploy's exit status is the verdict. No marker file is needed for ordering, because the check is the last step of the same program that applied.

#### Boot and switch

Same program, same table. Differences come from the inputs only:

- Normal boot: `B == L`. Pass: row 1 (a no-op record). Fail (gateway still booting, DHCP server down): row 3. Nothing changes; dhcpcd keeps trying; the unit shows failed, which is the truth: unverified.
- Boot after `nixos-rebuild boot` with a network change: `B != L`. Full protection, rows 1, 4, 5.
- Boot of a generation whose bundle is marked bad: row 7. No outage window at all.
- First boot: no L. Row 1 or row 3.

### 3.3 Units and ordering

```nix
# services/netif/host.nix, IfState-mode block. Replaces host.nix:582-616 and 630-680,
# guard.nix:511-541 and lib/ifstate.nix:174-177.
systemd.services.ifstate = {
  serviceConfig = {
    ExecStart = lib.mkForce [
      ""    # drop the nixpkgs ExecStart
      "${lib.getExe apply} ${lib.optionalString (!guard.enable) "--no-guard "}${cfg.bundle}"
    ];
    KillMode = "process";
    # udevadm settle (ExecStartPre of nixpkgs, up to 180 s) + two applies + two waits
    TimeoutStartSec = 300 + 2 * guard.timeout;
  };
};

systemd.services."netif-dhcpcd@" = {
  description = "netif: dhcpcd on %I";
  bindsTo = ["sys-subsystem-net-devices-%i.device"];
  after = ["sys-subsystem-net-devices-%i.device" "systemd-tmpfiles-setup.service"];
  # no After= or Wants= on ifstate.service: the transaction starts the client and waits for its lease
  unitConfig = {
    ConditionPathExists = "/run/netif/active/dhcpcd/%I.conf";
    StartLimitIntervalSec = 0;
  };
  stopIfChanged = false;      # a changed template (dhcpcd bump) restarts, never stop-then-start-later
  serviceConfig = {
    ExecStart = "${lib.getExe pkgs.dhcpcd_latest} -B -f /run/netif/active/dhcpcd/%I.conf %I";
    ExecStopPost = "${dhcpcdCleanup} %I";      # host.nix:668-673 with "$1"
    Restart = "on-failure";
    RestartSec = 2;
  } // dhcpcdSandbox;                           # host.nix:169-206, unchanged
};

systemd.services.netif-dhcp-reconcile = {
  description = "netif: start DHCP clients for links that appeared";
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${lib.getExe apply} --reconcile-dhcp";   # takes the lock, runs reconcile_dhcp(active, active)
    TimeoutStartSec = 600;
  };
};

# one rule per declared DHCP link and per hot-plug prefix; replaces host.nix:554-556 and 705-710
services.udev.extraRules = ''
  SUBSYSTEM=="net", ACTION=="add|move", NAME=="${interface}", RUN+="${systemctl} --no-block start netif-dhcp-reconcile.service"
  SUBSYSTEM=="net", ACTION=="add", NAME=="${prefix}*", RUN+="${systemctl} --no-block start netif-dhcp-reconcile.service"
  SUBSYSTEM=="net", ACTION=="add", NAME=="", KERNEL=="${prefix}*", RUN+="${systemctl} --no-block start netif-dhcp-reconcile.service"
'';
```

Why this shape:

- **Instance names are escaped by `systemd-escape`** in one place (the reconcile). udev never builds a unit name. That fixes N-A11 (a `-` in a name) for declared and hot-plug links.
- `ACTION=="add|move"` covers a link that IfState renames by `match.mac` (the unverified half of N-A1).
- `netif-hotplug@` keeps its shape (`host.nix:714-735`) but is started by the reconcile with an escaped name, and reads `/run/netif/active/dhcpcd-hotplug.conf`.
- `netif-guard.service` is deleted. `netif-online.service` stays, with `after = ["ifstate.service"]` only.
- `netif-dns.service` stays (`host.nix:563-576`).
- The nftables `ExecReload` hook (`guard.nix:538-540`) is deleted. See §4 (a).

Order inside one run (program order, not unit-list order):

```
udevadm settle (nixpkgs ExecStartPre)
 -> pre_apply (RA metric, guest-port list)
 -> ifstatecli apply
 -> /run/netif/active := bundle
 -> DHCP reconcile
 -> DNS apply
 -> physical-NIC check, guest-port check   (set "clean"; never skip a later step)
 -> verify
 -> commit, or activate(L) and verify again
```

Order in a deploy (assumed, same mechanism as today): the firewall reload happens before `ifstate.service` is started, so the targets are judged with the new firewall loaded.

### 3.4 Sysctl baseline

One source: new file `lib/sysctl-baseline.nix`, a plain attrset. Three sinks read it.

| Sink | Covers | Where |
|---|---|---|
| `boot.kernel.sysctl` with `all`, `default` and the glob `*` | every link in every mode, links of other owners, links that appear later | `lib/ifstate.nix`, not gated on the mode |
| IfState per-interface `sysctl` | declared links; restored on every apply; seen by `netif-drift` | `default.nix:1110` (`mkIfstateBase`) |
| `hotplugUp` | the RA keys of a hot-plug link | `host.nix:241-250` |

`boot.kernel.sysctl` is the only writer of `all` and `default`. IfState's top-level `sysctl.all`/`sysctl.default` exists in the 2.5.1 schema (verified) and is **not** used: two writers of one key.

IPv4:

| Key | Value | `all` | `default` | `*` glob | per declared link | Why |
|---|---|---|---|---|---|---|
| `accept_redirects` | 0 | yes | yes | yes | yes | T1. A host accepts when `all` OR the link says 1, so both must be 0 (H06) |
| `secure_redirects` | 0 | yes | yes | yes | yes | a redirect "from the gateway" is spoofable |
| `send_redirects` | 0 | yes | yes | yes | yes | a forwarding node must not tell neighbours to route elsewhere |
| `accept_source_route` | 0 | yes | yes | yes | yes | T1. Already the kernel and systemd default; pinned |
| `arp_ignore` | 1 | no | no | no | yes | answer ARP only for an address on the asked link; a LAN host cannot map the machine's other addresses. Own PR, see risk R4 |
| `arp_announce` | 2 | no | no | no | yes | use the link's own address as ARP source |
| `rp_filter` | not set by netif | | | | | see below |

IPv6:

| Key | Value | `all` | `default` | `*` glob | per declared link | Why |
|---|---|---|---|---|---|---|
| `accept_redirects` | 0 | yes | yes | yes | yes | T1 (H07) |
| `accept_source_route` | 0 | no | yes | yes | yes | kernel default; pinned (H08) |
| `accept_ra` | 0; with `ra`: 1, or 2 when the machine forwards | no | **0** | **no** | yes | T4, T6. No glob: a glob would switch RAs off on hot-plug links at every sysctl reload |
| `autoconf` | same as `ra` | no | 0 | no | yes | |
| `accept_ra_defrtr` | 1 only when `ra && default6 && gateway6 == null` | no | 0 | no | yes | N-A5: a static gateway is never joined by an RA default |
| `accept_ra_pinfo` | same as `ra` | no | 0 | no | yes | |
| `accept_ra_rt_info_max_plen` | 0 | no | 0 | no | yes | no more-specific routes from an RA (the IPv6 twin of option 121). Kernel default; pinned (H04) |
| `accept_ra_mtu` | 0 | no | 0 | no | yes | the MTU is declared; a rogue RA cannot shrink it |
| `accept_ra_min_hop_limit` | 64 | no | 64 | no | yes | a rogue RA cannot set hop limit 1 |
| `accept_dad` | 0 when the link has a static IPv6 address, else 1 | no | no | no | yes | a LAN host cannot disable a static address by answering DAD. Cost: a real duplicate is not detected. Owner call, risk R5 |
| `use_tempaddr` | 0 | no | no | no | yes | S5. NixOS default `networking.tempAddresses = "default"` writes 2 by a udev rule on every link (verified, nixpkgs `network-interfaces.nix:1879-1883`); servers and routers need stable source addresses |
| `ra_defrtr_metric` | `routeMetric` | no | yes | no | written in `pre_apply` | not in the IfState schema (N18, kept) |

`rp_filter`: netif does not render it.

- The NixOS firewall does the reverse-path check in nftables (`networking.firewall.checkReversePath`, default strict). netif never sets it (verified in the review).
- The kernel uses the larger of `all` and the link. The kube lib forces `all = 2` and `checkReversePath = "loose"` (`lib/kube-cluster/service.nix:1019,1050`). A per-link 1 from netif would be raised to 2 anyway, and a per-link value on a fabric underlay breaks ECMP return paths.
- So: one mechanism (the firewall), one owner per value. A hostile verdict proves the behaviour on a plain host (§6, H14).

Nix sketch:

```nix
# lib/sysctl-baseline.nix
{
  everyLink4 = { accept_redirects = 0; secure_redirects = 0; send_redirects = 0; accept_source_route = 0; };
  everyLink6 = { accept_redirects = 0; accept_source_route = 0; };
  raOff6 = { accept_ra = 0; autoconf = 0; accept_ra_defrtr = 0; accept_ra_pinfo = 0;
             accept_ra_rt_info_max_plen = 0; accept_ra_mtu = 0; accept_ra_min_hop_limit = 64; };
}
```

```nix
# lib/ifstate.nix config, every mode
boot.kernel.sysctl = lib.mkMerge (
  lib.concatMap (scope:
    [ (lib.mapAttrs' (k: v: lib.nameValuePair "net.ipv4.conf.${scope}.${k}" (lib.mkDefault v)) baseline.everyLink4)
      (lib.mapAttrs' (k: v: lib.nameValuePair "net.ipv6.conf.${scope}.${k}" (lib.mkDefault v)) baseline.everyLink6) ]
  ) ["all" "default" "*"]
  ++ [ (lib.mapAttrs' (k: v: lib.nameValuePair "net.ipv6.conf.default.${k}" (lib.mkDefault v)) baseline.raOff6) ]
);
```

```nix
# default.nix:1110, replaces the sysctl.ipv6 block
sysctl.ipv4 = baseline.everyLink4 // { arp_ignore = 1; arp_announce = 2; };
sysctl.ipv6 = baseline.everyLink6 // baseline.raOff6 // {
  accept_ra = if r.ra then (if forwarding then 2 else 1) else 0;
  autoconf = if r.ra then 1 else 0;
  accept_ra_pinfo = if r.ra then 1 else 0;
  accept_ra_defrtr = if r.ra && r.default6 && r.gateway6 == null then 1 else 0;
  accept_dad = if r.static6 != [] then 0 else 1;
  use_tempaddr = 0;
};
```

Hot-plug (`hotplugUp`, `host.nix:241-250`) writes, before `ip link set up`: `accept_ra` (1, or 2 when forwarding), `autoconf 1`, `accept_ra_pinfo 1`, `accept_ra_defrtr 1`, `ra_defrtr_metric`. The other keys come from `default`.

Verified in IfState source: per-link sysctls are written before the link is set up, on create (`link/base.py:902-903`) and on update (`link/base.py:1237-1239`). So no RA is processed with the old value after an apply.

### 3.5 DHCP: option policy

| Lease content | Declared link | Hot-plug link | How |
|---|---|---|---|
| Address, mask | yes | yes | dhcpcd |
| Router (3) | only when the link owns the IPv4 default | yes, metric `routeMetric + 100` | `nogateway` otherwise (kept, N21) |
| Static routes (33), classless routes (121, 249) | **no**. Yes with `dhcp.classlessRoutes = true` | **never** | `nooption static_routes, classless_static_routes, ms_classless_static_routes` |
| Interface MTU (26) | no | no | `nooption interface_mtu`. The MTU is `links.<n>.mtu` |
| DNS servers (6; DHCPv6 23) | when the link owns a default route, or `dhcp.dns = true` | yes, but see I11 | not requested and `nooption` otherwise |
| Domain, search list (15, 119; DHCPv6 24) | same switch as DNS | no | same |
| NTP, hostname from the server, WPAD, anything else | no | no | not requested; netif's script is the only hook (`host.nix:83-129`) and reads DNS and prefix delegation only |
| Our hostname sent to the server (12) | yes | **no** | drop `hostname` from `hotplugConf` (`host.nix:223`) |
| IPv4LL | no | no | `noipv4ll` (kept) |
| RAs read by dhcpcd | no | no | `noipv6rs` (kept); the kernel reads them under §3.4 |
| DHCPv6 address, delegated prefix | as declared | no (IPv4 only) | kept |

Why routes stay off even on the default-owning link: a route from option 121 can be more specific than a connected route of another link. A WAN lease could pull the traffic for one host of a private segment to the WAN. The router option cannot do that. So the owner's decision (off by default) is also right for the link that owns the default.

`dhcpcdConf` (`host.nix:131-165`) becomes:

```nix
[
  "# netif/${l.instance} link '${l.logical}' (specs/netif.md N16)"
  "duid"
  "hostname"
  "require dhcp_server_identifier"
  "nooption interface_mtu"
  "noipv6rs"
  "noipv4ll"
  "metric ${toString cfg.routeMetric}"
  "backoff_cutoff ${toString cfg.dhcpBackoffCutoff}"
  "script ${dhcpcdScript}"
]
++ (if l.dhcpDns
    then ["option domain_name_servers, domain_name, domain_search" "option dhcp6_name_servers, dhcp6_domain_search"]
    else ["nooption domain_name_servers, domain_name, domain_search" "nooption dhcp6_name_servers, dhcp6_domain_search"])
++ (if l.classlessRoutes
    then ["option classless_static_routes"]
    else ["nooption static_routes, classless_static_routes, ms_classless_static_routes"])
++ lib.optional (!l.default4) "nogateway"
++ ...   # ipv4only / ipv6only / interface / iaid / ia_na / ia_pd as today
```

Verified in the dhcpcd 10.5.2 man page in the store: `nooption` "removes the option from the message before it's processed". Verified in the binary's embedded definitions: options 1 and 3 carry `request`; 33, 121, 249, 26 and 6 do not. So "not requested" alone is not enough against a server that sends them unasked; `nooption` is the control.

DNS scope (`dnsApply`, `host.nix:48-66`):

- New fact per link, set in `hostLinks` (`default.nix:1561`): `dhcpDns = if link.dhcp.dns != null then link.dhcp.dns else (v4Default r || v6Default r);`
- After each successful `resolvectl dns "$l" ...` the script sets `resolvectl default-route "$l" yes`. Explicit, not resolved's guess.
- Hot-plug links: `resolvectl default-route "$l" no` while any declared link has carrier and a non-empty DNS list; `yes` otherwise. The watcher already re-runs on every carrier change (`host.nix:69-79`); extend its pattern to the hot-plug prefixes.
- `set -f` as the second line of `dhcpcdScript` and `dnsApply` (N-A14).

### 3.6 RA policy

- `links.<n>.ra`: `types.bool`, **default `false`**.
- With `true`: prefixes and SLAAC addresses. A default router only when the link owns the IPv6 default and has no static IPv6 gateway.
- `ra = true` is what makes a link a source of an IPv6 default (N21 rule, kept). `v6Default` becomes (replaces `default.nix:192-193`):

```nix
v6Default = r:
  r.memberOf == null && r.default6
  && ((r.gateway6 != null && !r.dhcp6 && r.policy.table == null) || (r.ra && r.gateway6 == null));
```

- Line `default.nix:1191`: drop `|| r.static6 != []` (dead code, N-A10).
- Links nobody declared `ra` on get `accept_ra = 0`: bond and bridge members, VLAN parents without addressing, guest-ports bridges, guest ports, veths, container bridges, fabric links. No special case in code: it is the default.
- Not netif's: iwd and NetworkManager handle RAs in userspace on their links (assumed, probe P4).
- Residual on an RA link: any on-link host can become a default router. That is what `ra = true` means. Documented in the option text.

### 3.7 Option surface

Inventory (`services/netif/default.nix`):

| Change | Option | Type | Default | Notes |
|---|---|---|---|---|
| changed default | `links.<n>.ra` | `bool` | `false` (was `true`) | §3.6 |
| add | `links.<n>.dhcp.classlessRoutes` | `bool` | `false` | owner decision N-A7 |
| add | `links.<n>.dhcp.dns` | `nullOr bool` | `null` = the link owns a default route | N-A4 |
| rename | `links.<n>.requiredForOnline` → `links.<n>.required` | `bool` | `true` | "the machine needs this link's dynamic configuration": `network-online.target` waits for it (N32) **and** the guard requires its DHCP or RA default. `false` = take it when offered |
| text fix | `links.<n>.routes` | | | "always in the main table" (N-A9) |

Machine (`clanServices.netif.*`):

| Change | Option | Type | Default | Notes |
|---|---|---|---|---|
| changed default | `guard.timeout` | `ints.between 5 300` | `45` (was 30) | above the 30 s a spanning-tree port needs after a link flap; there is no "outside" retry any more |
| keep | `guard.enable`, `guard.targets` | | | |
| remove | `guard.script` (internal) | | | eval tests read the manifest instead |
| remove | `guardGeneration`, `dhcpcdConfs` (internal) | | | replaced by `bundle` |
| add | `bundle` (internal, read-only) | `package` | | §3.1 |
| add | `guard.manifest` (internal, read-only) | `attrs` | | what `manifest.json` holds; the eval tests assert on it |

`clanServices.netif.links.<if>` (the host-side facts, `host.nix:374-416`): add `dhcpDns`, `classlessRoutes`, `required`, `static4`, `static6`, `defaultSource4`, `defaultSource6` (`null`, `"static"`, `"dhcp"`, `"ra"`). Drop `requiredForOnline`.

Export and `clan._networkFacts` (`default.nix:1356-1380`): `ra` keeps its meaning with the new default. No schema-version bump is needed for anyone (no consumers); set `schemaVersion = 3` only because the facts module checks it.

### 3.8 Modes and the registry

- **Guard state per mode.** `/var/lib/netif/guard/<mode>/`. Today one `last-good` serves all modes (verified, `guard.nix:123`), so booting mode `developer` could roll back to the network of mode `default`, with another set of owners. First boot of a mode has no L: row 3, loud, no rollback.
- **No manager change on a running system (I12).** New in `lib/modes.nix`:

```nix
systemd.tmpfiles.rules = ["f /run/netif/mode 0644 root root - ${cfg.currentMode}"];   # `f` never overwrites: it keeps the booted mode
system.preSwitchChecks.netif-mode = ''
  booted=$(cat /run/netif/mode 2>/dev/null || echo ${cfg.currentMode})
  if [ "$2" != boot ] && [ "$booted" != ${lib.escapeShellArg cfg.currentMode} ]; then
    echo "netif: this machine is booted in mode '$booted' and the new configuration is mode '${cfg.currentMode}'. Modes change by reboot only (specs/netif.md N3). Use 'boot' and reboot, or switch to this mode's specialisation." >&2
    exit 1
  fi
'';
```

  `system.preSwitchChecks` gets the action as `$2` (verified in nixpkgs `pre-switch-check.nix`). This catches the real hazard: a plain deploy to a Deck that is booted in its NetworkManager mode would switch it to the parent (IfState) configuration live.
- **Registry stays the single source** of "not IfState's" (`lib/ownership.nix:328-348`). Three additions:
  - the sysctl baseline's `default` scope is what covers owner links; no per-owner sysctl option;
  - hot-plug stays a registry owner (`host.nix:699`);
  - `netif-status` prints, per kernel link: `netif/<instance>/<link>`, `owner <name>`, or `UNOWNED`. An unowned virtual link is one IfState will delete at the next apply; the owner sees it before that happens.
- Not added: an overlap check between two owners' regexes. Regex overlap is not computable in Nix, and two owners that both say "ignore" do not conflict in IfState.

### 3.9 Evaluation checks

Add to `linkAssertions` (`default.nix:644-830`) unless noted. Every message names instance, link, machine and remedy, like the existing ones.

| # | Check | Kind | Finding |
|---|---|---|---|
| E1 | static gateway inside a static subnet of the link, unless `gateway.onLink`, DHCP for that family, or an `fe80:` gateway | error | N-A8; code in the review, uses `lib/kube-cluster/cidr.nix` `overlap` |
| E2 | the same for each `routes[].gateway` unless that route's `onLink` | error | new |
| E3 | `dhcp.ipv6 && default6 && !ra && gateway6 == null`: "DHCPv6 carries no router; set 'ra = true' or 'defaultRoute.ipv6 = false'" | error | N-A10 |
| E4 | `ra = true` on a bond or bridge member | error | N-A5 |
| E5 | `ra = true` on a bridge with `bridge.guestPorts` | warning: "guests can send router advertisements to this host" | N-A5 |
| E6 | `dhcp.classlessRoutes` without `dhcp.ipv4`; `dhcp.dns` without any DHCP | error | new |
| E7 | more than one instance sets `targetHost` on one machine (perMachine) | error | N-A13 |
| E8 | guard on and the manifest has no gateway, no default and no target: "the guard has nothing to test on this machine; add 'guard.targets'" | warning | new; covers fabric nodes whose default comes from BGP |
| E9 | `links != {}` and `networking.firewall.enable = false` | warning | N-A15 |
| E10 | netif sets the deploy target, `services.openssh.enable`, and no rule opens an sshd port on that link (`openFirewall`, the link trusted, or the port in `allowedTCPPorts` global or per interface) | error | new; the static half of "no lockout": the guard cannot see inbound rules |
| E11 | a static address that is the network or broadcast address of its IPv4 subnet (prefix below 31) | error | new, cheap |
| E12 | hot-plug prefix regex stays `[A-Za-z0-9_.-]+` (`host.nix:238`) | kept | N-A11 is fixed by escaping, not by forbidding `-` |

Typed addresses: already in place (`lib/ip.nix`); nothing to add.

---

## 4. Verdict on each idea

### (a) Guard redesign instead of patches: ACCEPT, and go further

- The review's three-part patch for N36 keeps four marker files and a generation string inside every dhcpcd unit. Each marker exists to repair an ordering that systemd does not give. One program has the ordering for free.
- **Probe only own declarations: accept.** §3.2 table. Fixes N-A3 without a protocol filter.
- **"Succeeded" is defined** in §3.2.
- **Rollback semantics change in one place.** Today, when both B and L fail, B is applied again ("the fault is outside", `guard.nix:379-406`). That is a lockout path: a wrong address deployed while the gateway reboots ends on the wrong address, and nothing looks again. The target: the kernel stays on L, which has passed before. Cost: a good deploy during an outage is refused and must be repeated. That is the right side to err on.
- **The firewall-reload check (N36 second half) is removed.** Reasons:
  - it rolls nothing back, so it protects nobody;
  - outbound probes cannot see a closed inbound port;
  - `ifstate.service` runs in every switch after the reload, so the targets are still checked with the new firewall loaded, once, in the right order;
  - E10 covers the common case (sshd closed) at evaluation.
- **Boot and switch are the same code.** §3.2.
- Rejected: **commit-confirm** (roll back unless the deployer confirms over a new connection). It is the only test that proves the deployer's path, but `clan machines update` has no confirm step and a boot has no deployer. Revisit if clan gains one.
- Rejected: **automatic retry / flip-flop** between B and L while both fail. It converges without the owner, but every trial flaps a network that may be half working, and a target that fails for a non-network reason would flap it forever. `netif-guard retry` is the manual form.
- Cost: `guard.nix` (544 lines) becomes about 120 lines of Nix and about 250 lines of Python with a table test. `netif-guard`, `netif-dhcp` (guard part) and the eval tests `test_guard*` are rewritten.

### (b) One sysctl baseline: ACCEPT

- §3.4. Refinements over the prototype: the `*` glob for links that exist before `systemd-sysctl` runs (NetworkManager modes have no per-link IfState values); RA keys never in a glob; `rp_filter` deliberately not netif's; `arp_ignore`/`arp_announce` only per declared link and in their own PR.
- Cost: one small file, three call sites. A user `extraSettings.sysctl.*` for a baseline key becomes a collision error; that is intended.

### (c) RA only where declared: ACCEPT

- §3.6. The guest-bridge and VLAN-parent parts of N-A5 need no code: default off covers them. Only the explicit cases get a check (E4, E5).
- Cost: every suite and fixture that relies on the default `ra = true` sets it (`netif-dhcp`, `netif-v6only`, gateway suites). `netif-hostile` drops nothing.

### (d) DHCP as untrusted input: ACCEPT

- §3.5. Beyond the owner's option-121 decision: MTU off, DNS scoped by default-route ownership, hostname not sent on hot-plug links.
- Rejected: `whitelist <server>` per link. The source address of a DHCP reply is trivially spoofed on the same LAN.
- Rejected: filtering option-121 routes by an allow-list. dhcpcd cannot; a hook that deletes routes afterwards is a race. A link that needs a provider's route declares it in `routes`.

### (e) Missing NIC and unit order: ACCEPT, solved by (a)

- Best boot behaviour for a dead NIC: everything else comes up, the guard still judges, the unit ends failed and names the NIC, nothing is recorded as good. §7.
- No new `optional` option. A NIC that may be absent is a hot-plug link (N12).

### (f) Evaluation checks: ACCEPT

- §3.9. E10 is the one with the largest safety value per line.

### (g) dhcpcd or another client: KEEP dhcpcd

- systemd-networkd's client is ruled out by the standing decision and would be a second renderer. NetworkManager is another mode. ISC dhclient is end of life. busybox udhcpc has no DHCPv6 and no prefix delegation.
- Considered: dhcpcd with `noconfigure`, so that only netif's hook writes addresses and routes. It gives full policy control, but netif would re-implement lease lifetimes, renewals and carrier loss. More risk than `nooption` lines. Rejected.
- The safety gain is in the config (§3.5) and the existing sandbox (`host.nix:169-206`).

### (h) Modes and the registry: ACCEPT, small

- §3.8: per-mode guard state, the pre-switch check, `UNOWNED` in `netif-status`.

### Own ideas

- **Bundle and template dhcpcd unit** (§3.1, §3.3): accepted; it is what makes (a) small.
- **Bad mark** (I4): accepted. Today every reboot and every re-switch of a rolled-back generation applies the bad network again for `timeout` seconds.
- **Address obligation** ("declared static addresses are on the link and usable"): accepted; it gives the guard something to test on a machine without a gateway.
- **`required` as one concept** for online and guard: accepted; it removes the history file `last-good-defaults`. An RA default is required because it is declared, not because it was seen once.
- **E10 sshd reachability at evaluation**: accepted.

---

## 5. Deleted, simplified, and what replaces pinned checks

Deleted code:

| What | Where | Why it can go |
|---|---|---|
| `netif-guard.service`, its `restartTriggers` | `guard.nix:514-528` | the check is a step of the apply |
| markers `applying`, `rolled-back`, `generation` | `guard.nix:259-272`, `436-447` | they repaired unit ordering |
| `beforeApply`, `guardAfterFailure`, `resetDhcpcd` | `guard.nix:414-447` | one program |
| kept dhcpcd files in `/run`, the generation compare in each unit | `guard.nix:322-346`, `host.nix:656-663` | `/run/netif/active` |
| transient `netif-guard-dhcpcd-<if>` units | `guard.nix:233-244`, `363-369` | the template unit exists in every generation |
| `last-good-defaults`, `own_defaults`, `may4`, `may6`, `dhcp_defaults` | `guard.nix:51-54`, `165-175`, `278-288` | `manifest.defaults` |
| the unfiltered default-route scan | `guard.nix:203-207` | I5 |
| "fault is outside" re-apply | `guard.nix:379-406` | I1 |
| nftables `ExecReload` hook, `firewall` mode | `guard.nix:246-257`, `538-540` | §4 (a) |
| per-link dhcpcd units, their udev `SYSTEMD_WANTS` rules | `host.nix:554-556`, `630-680` | template + reconcile |
| `ExecStartPre`/`ExecStartPost` lists on `ifstate.service` | `host.nix:582-616`, `lib/ifstate.nix:176` | program order |
| `netcat`, `diffutils` in the guard's path | `guard.nix:108-113` | Python stdlib |

Suite checks that pin a mechanism, and the behaviour check that replaces each:

| Today | Where | Replace with |
|---|---|---|
| `test -e /run/netif-guard/rolled-back` | `tests/vm/guard.nix:280` | old address and default are back; `ifstate.service` is `failed`; `netif-guard status` says `rolled-back` |
| `grep -F owned /run/netif-guard/rollback.yaml` | `guard.nix:262` | the owned link still exists after the rollback (`ip link show`) |
| journal greps on `netif-guard.service` (`journal`, `journal_new`, `count`) | `guard.nix:171-190`, `dhcp.nix:708`, `v6only-host.nix:414` | exit status of the switch, kernel state, and `jq -r .outcome /run/netif/guard/status.json` |
| `LAST_GOOD = /var/lib/netif/guard/last-good`, GC-root readlink | `guard.nix:152`, `211` | `netif-guard status` prints `good`; keep one GC-root check: `nix-store --gc` then the rollback still works |
| "targets answer after the firewall change" in the nftables journal | `guard.nix:317` (`NETIF_GUARD_FIREWALL_OK`) | a switch that changes only the firewall and breaks a TCP target exits non-zero, the network is unchanged, outcome `unverified` |
| `NETIF_GUARD_OUTSIDE_OK`: "the new one stays" | `guard.nix:339-353` | **behaviour changes**: with the gateway down for both, the switch exits non-zero and the kernel holds the *old* address; outcome `undecided`. Then gateway up, `systemctl restart ifstate.service`: exit 0, new address |
| `NETIF_GUARD_TARGET_OK`: "this generation's network stays" | `guard.nix:300-308` | same change: outcome `undecided`, last good network applied |
| `NETIF_GUARD_FAILED_APPLY_OK` via a drop-in `ExecStart=false` and `InvocationID` | `guard.nix:320-337` | a specialisation whose IfState YAML fails at apply (an `!include` of a missing file through `extraSettings`); the switch exits non-zero, outcome `unclean`, gateway still reachable, `good` unchanged |
| `/run/netif-guard/dhcpcd/eth1.conf`, `pgrep ... /run/netif-guard/dhcpcd` | `dhcp.nix:720-726` | after a rollback of a client-only change: the lease is back, `readlink /run/netif/active` is the old bundle |
| `systemctl is-active netif-guard-dhcpcd-eth1.service` | `dhcp.nix:737-744` | after a rollback of "DHCP made static": `netif-dhcpcd@eth1.service` is active and the link has its lease address |
| `grep -x '4 eth1' .../last-good-defaults` | `dhcp.nix:712` | `jq '.defaults' /run/netif/active/manifest.json` has the entry |
| `systemctl cat netif-guard.service` fails in an NM mode | `modes/tests/vm/default.nix:193` | `/run/netif/guard` is absent in the NM mode |
| `netif-guard.service` `ActiveState == active` | `modes/default.nix:232`, `hotplug.nix:204`, `routed-fabric/suite.nix:41` | `ifstate.service` result is `success` and outcome is `committed` |
| "declared physical links missing after IfState apply: ghost" in the `ifstate.service` journal | `match.nix:98` | keep the text (the Python prints it); add: the present DHCP link has its lease while the unit is failed |
| eval `test_guardDefaults`, `test_guardRollbackHardening`, `test_guardTargetsAreShellWords`, the `ExecStartPost` string tests | `tests/eval-tests.nix:906-976`, `1094`, `1326-1331` | assertions on `guard.manifest` (targets, gateways, defaults per fixture), on the bundle's file list, on the template unit's `ExecStart`, and `checks.netif-guard-logic` for the decision table |

New static check `checks.netif-guard-logic` (register in `flake-parts/`, beside `checks.clat-follow` which is the same idea): runs `python -m unittest` on `apply.py` with the seven rows of §3.2 and the obligation list for three manifests. No network, no VM.

---

## 6. Hostile-suite verdicts to add

Suite `netif-hostile` (`services/netif/tests/vm/hostile.nix` in the `fix-probe` worktree). Existing H01–H08 stay. New ids continue from H09. Each is one `verdict(id, safe, detail)`.

Topology to add: a second VLAN with `victim` link `side` (DHCP, `defaultRoute.* = false`), a guest-ports bridge `br0` with a veth guest in a namespace on `victim`, and a hot-plug dummy link `enxtest`.

| Id | Attacker and command | Safe outcome on `victim` |
|---|---|---|
| H09 | rogue DHCP on `side`: `dnsmasq --no-daemon --interface=eth2 --dhcp-range=198.51.100.100,198.51.100.150 --dhcp-option=121,0.0.0.0/1,198.51.100.66,128.0.0.0/1,198.51.100.66,192.168.1.1/32,198.51.100.66` | `ip -4 route show proto dhcp dev eth2` has only the connected prefix; `ip route get 203.0.113.9` and `ip route get 192.168.1.1` leave by `eth1` |
| H10 | same server adds `--dhcp-option=33,203.0.113.9,198.51.100.66` and `--dhcp-option=249,...` | no route to `203.0.113.9` on `eth2` |
| H11 | same server adds `--dhcp-option=26,576` | `cat /sys/class/net/eth2/mtu` is unchanged |
| H12 | same server adds `--dhcp-option=6,198.51.100.66 --address=/#/198.51.100.66` | `resolvectl dns eth2` is empty; `resolvectl query example.test` does not return `198.51.100.66` |
| H13 | same server on a link with `dhcp.dns = true` but `defaultRoute = false` | documents the opt-in: `resolvectl default-route eth2` is `yes`. Verdict text says "declared" |
| H14 | spoofed source: from `attacker` on VLAN 1 send `IP(src='198.51.100.10', dst='192.168.1.2')/ICMP()` with scapy, `tcpdump` on `victim` for a reply | no echo reply leaves `victim` (firewall reverse-path check) |
| H15 | guest in the namespace on `br0`: scapy RA with `routerlifetime=1800` and a prefix option `2001:db8:bad::/64` (L=1, A=1) | no address from the prefix on `br0`; `ip -6 route show dev br0` has no `2001:db8:bad::`; `accept_ra` of `br0` and of the guest port is 0 |
| H16 | RA on an `ra = true` link with a Route Information option for `2001:db8:1::/64` via the attacker, MTU option 1280, `chlim=1` | no such route; `cat /proc/sys/net/ipv6/conf/<if>/mtu` unchanged; `cat /proc/sys/net/ipv6/conf/<if>/hop_limit` is 64 |
| H17 | static IPv6 link: `attacker` answers DAD (`scapy` NA for `2001:db8:1::2` on every NS from `::`), then `systemctl restart ifstate.service` on `victim` | the address is on the link without `dadfailed`; the guard's outcome is `committed` |
| H18 | hot-plug link: rogue DHCP with option 121 and DNS on the dock VLAN while `eth1` is up | no extra route; `resolvectl default-route enxtest` is `no`; `accept_redirects` of `enxtest` is 0 for both families |
| H19 | ARP map: `arping -I eth1 <victim's address on eth2>` from `attacker` | no answer (`arp_ignore = 1`) |
| H20 | every link of the machine except `lo`, including the guest port: loop over `/proc/sys/net/ipv4/conf/*/accept_redirects`, `secure_redirects`, `send_redirects`, `/proc/sys/net/ipv6/conf/*/accept_redirects` | all 0 (I7 as one verdict) |
| H21 | guard under spoofing: `gw` off, `attacker` answers ARP for `192.168.1.1`, switch `victim` to a new address with a TCP target on `gw` | the switch exits non-zero and the old address is back. Documents: with no TCP target the spoof passes (print as `HOSTILE LIMIT`, not a gap) |
| H22 | bad deploy during an outage: `gw` link down, switch `victim` to a specialisation with a wrong subnet, then `gw` link up | `victim` answers on its old address without any action (I1). On `main` today this is a gap: the wrong address stays |

Suite `netif-modes` (I12): booted in the NetworkManager mode, run `switch-to-configuration switch` of the parent: non-zero, the text names both modes, NetworkManager is still active, no `ifstate.service` run.

---

## 7. Failure modes and stability

### Lockout analysis, every guard path

"In" means: the path the owner used before this run still works after it, as far as the obligations can tell.

| Row | Kernel after the run | Owner in? | Residual |
|---|---|---|---|
| 1 committed | B, proven now | yes | a fault no obligation covers (inbound firewall: E10; a spoofed L2 answer: use a TCP target) |
| 2 unclean | B, partly applied or a NIC missing; obligations pass | yes, by evidence | the half-applied part is reported, not repaired. Deploy shows the failure |
| 3 unverified, no L | B | unknown | first install only. Console needed anyway |
| 3 unverified, `L == B` | B = L | as before the run | the fault is not this bundle |
| 4 rolled-back | L, proven now | yes | B marked bad |
| 5 undecided | L, proven earlier | yes, once the outside fault ends | a planned move to a network where L can never work needs the console and `netif-guard force` |
| 6 rollback-failed | unknown mix | unknown | only when IfState rejects L (a runtime `!include` that the generation no longer provides, known open point of N25). The message says so |
| 7 still-rolled-back | L | yes | none; no trial of B, so no outage window |
| killed by `TimeoutStartSec` | whatever the last finished step left | unknown | the timeout is `300 + 2 × timeout`; `KillMode=process` lets a running `ifstatecli` finish |
| guard off (`--no-guard`) | B | not protected | by choice: a machine with a screen |

### Scenarios

- **Boot with a missing NIC.** IfState warns and exits 0. The reconcile starts DHCP on every link that is there, also one found by `match.mac`. DNS is applied. The obligations are judged. The run ends `unclean` (exit 1, the journal names the NIC) when they pass. If the missing NIC carried the default: the obligations fail; with `L == B` it is row 3, nothing changes.
- **DHCP server down at boot.** The DHCP default never comes; row 3 after `timeout` seconds. dhcpcd keeps asking (`backoff_cutoff` 16 s). The lease arrives later without any netif step. `network.target` is delayed by up to `timeout` seconds in this case only.
- **Gateway down during a switch** (reboot of the router, a port in spanning-tree listening):
  - back within `timeout` (45 s): row 1.
  - longer, `B != L`: row 5. Kernel on L. When the gateway is back the owner runs the deploy again or `systemctl restart ifstate.service`.
  - longer, `B == L`: row 3.
- **Bad deploy** (wrong address, VLAN, gateway): row 4. Outage: at most `timeout` plus two applies.
- **Bad deploy during an outage**: row 5. Kernel on L. The owner is in when the outage ends. (Today: B stays. H22.)
- **Reboot after a rollback**: row 7. No outage.
- **A deploy that changes nothing in the network**: the bundle path is the same; the apply is a no-op (S2); the obligations are checked in about a second; no DHCP client is touched (S1).
- **A deploy that changes one dhcpcd file**: that client only is stopped (lease flushed) and started; the guard waits for its default if the link owns it.
- **dhcpcd package update**: the template unit changes; `switch-to-configuration` restarts the running instances once (`stopIfChanged = false`), before `ifstate.service` runs; the guard then waits for the lease.
- **Mode switch mid-flight** (a `switch` into another mode): refused by the pre-switch check before any unit is touched (I12). `boot` is allowed.
- **Two runs at once** (`systemctl restart ifstate.service` during a deploy, or a udev reconcile during an apply): systemd serialises the unit; the reconcile waits on `/run/netif/lock`.
- **Garbage collection**: `good` is a GC root. A `bad` path that was collected is harmless (string compare only).
- **Upgrade across a manifest format change**: an L whose `manifest.json` has an unknown `version` counts as "no L". Logged once.

### Known costs

- A good deploy during an outage must be repeated.
- A false "bad" mark is possible when the gateway returns exactly between the two checks. `netif-guard retry` clears it; the message says so.
- `ifstate.service` now includes the wait, so `network.target` is later by the wait in failing cases.

---

## 8. Implementation order

Every step: spec text first (`specs/netif.md` and `documentation/docs/netif/` together, hard rule 3), then code, then `fmt`, `check`, and the named suites with `--rebuild`. One PR per step.

| # | Step | Proof |
|---|---|---|
| 0 | Spec: add the threat model (§1) and invariants (§2) to `specs/netif.md` as a new decision **N45**; mark N25, N31, N36 "to be rewritten in step 5–6" | `checks.spec-headings` |
| 1 | Sysctl baseline without the ARP keys (§3.4): `lib/sysctl-baseline.nix`, three sinks. Land `netif-hostile` from the `fix-probe` worktree | nix-unit: per-link values and `boot.kernel.sysctl` keys. VM: `netif-hostile` H06, H07, H20 safe; `netif` (`assert_ifstate_noop`); one kube suite (`k3s-single`) to see the glob does not disturb Cilium |
| 2 | RA policy (§3.6): `ra` default false, `v6Default`, E3, E4, E5. Set `ra = true` where suites need it | nix-unit: the four cases in the review's N-A5 proof plus E3–E5 texts. VM: `netif-hostile` H15, H16; `netif-dhcp`, `netif-v6only`, `netif-vmhost`, `netif-wifi`, `netif-hotplug` |
| 3 | Evaluation checks E1, E2, E7, E8, E9, E10, E11; N-A9 text; N-A12 (skip odd guest-port names, `host.nix:283`); N-A14 (`set -f`) | nix-unit `failedAssertion` per check; `netif-vmhost` with a port named `gp(1` |
| 4 | DHCP option policy and DNS scope (§3.5), on the existing per-link units: `dhcp.classlessRoutes`, `dhcp.dns`, the `nooption` lines, `resolvectl default-route`, hot-plug conf | nix-unit on the conf text and `dhcpDns`. VM: `netif-hostile` H09–H13, H18; `netif-dhcp` (move its classless-route assertion to a link with the opt-in) |
| 5 | `apply.py` with `decide`, `decide_after_rollback`, the obligation builder, and `checks.netif-guard-logic`. Not wired yet. Add the internal `bundle` and `guard.manifest` options | `check` (the new derivation); nix-unit on `guard.manifest` for three fixtures |
| 6 | Wire it (the large step): `ExecStart` override, template `netif-dhcpcd@`, `netif-dhcp-reconcile`, udev rules, delete everything in §5, `required` rename, `guard.timeout` 45, per-mode state, bad mark, `netif-guard` CLI. Rewrite the `netif-guard` suite and the guard part of `netif-dhcp` per the §5 table. Rewrite N25, N31, N36 in the spec | VM: `netif-guard`, `netif-dhcp`, `netif-match` (a `match.mac` DHCP link beside a missing NIC), `netif-hotplug` (a prefix with `-`), `netif-v6only`, `netif-hostile` H21, H22; S1 check: `systemctl show -p ActiveEnterTimestampMonotonic netif-dhcpcd@eth1.service` equal before and after a switch that changes another link; then `vm-test --all --remote --rebuild --quiet` |
| 7 | Modes (§3.8): tmpfiles line, pre-switch check, `UNOWNED` in `netif-status` | `netif-modes` verdict in §6; nix-unit on `system.preSwitchChecks` |
| 8 | ARP keys (`arp_ignore`, `arp_announce`) on declared links, alone, so a regression is easy to revert | `netif-hostile` H19; all `k3s-*`, `rke2-*`, `routed-fabric*`, gateway suites |
| 9 | `accept_dad = 0` on static IPv6 links, after the owner's yes (R5) | `netif-hostile` H17 |

Steps 1–4 are independent of the guard and each closes hostile gaps on its own. Step 6 must not be split: the template unit, the bundle and the transaction depend on each other.

Suite refactor rule (AGENTS.md "Test refactors must stay faithful") does not apply to steps 2, 4, 6: they change behaviour on purpose. Say so in each PR.

---

## 9. Open risks and probes

Probes are throwaway suites that print `FINDING` lines (the repo's rule). Run them before the step that depends on them.

| Id | Question | Status | Needed before |
|---|---|---|---|
| P1 | Inside `ifstate.service` (state "activating", `DefaultDependencies=no`, before `network.target`) at **boot**: does `systemctl start --no-block netif-dhcpcd@x` run at once and get a lease inside `timeout`? A cycle through `basic.target` would make every DHCP boot wait the full timeout | assumed; the old design moved the guard out of `ExecStartPost` for a deadlock that came from `After=ifstate.service`, which the template no longer has | step 6 |
| P2 | Does `switch-to-configuration` start the inactive oneshot `ifstate.service` on every switch and wait for it, also when only its `ExecStart` changed? | assumed; it is how the YAML path in `ExecStart` works today | step 6 |
| P3 | Do `systemd-sysctl` glob keys (`net.ipv4.conf.*.accept_redirects`) apply to links present at boot and, through the `99-systemd.rules` udev line, to links added later? | glob syntax and the udev rule verified in the store (`50-default.conf`, `99-systemd.rules:69`); the effect is assumed | step 1 |
| P4 | With `net.ipv6.conf.default.accept_ra = 0`: do Wi-Fi under iwd and links under NetworkManager still get an IPv6 default? (Both are expected to read RAs in userspace.) | assumed | step 2 (`netif-wifi`, `netif-desktop`, `netif-modes` are the probe) |
| P5 | With options 33/121/249 removed: does dhcpcd install the router of a `/32` lease whose gateway is off-subnet (the usual cloud lease)? If not, such a link sets `dhcp.classlessRoutes = true` or declares `gateway.onLink` | assumed | step 4 |
| P6 | Does dhcpcd apply option 26 when it was never requested (i.e. is `nooption interface_mtu` needed or only tidy)? And does `nooption` also stop option 121 from suppressing the router option? | `nooption` semantics verified in the man page; the two effects assumed | step 4 (H09, H11 answer it) |
| P7 | Does `resolvectl default-route <link> no` take effect at once and survive a carrier flap (the DNS watcher re-applies anyway)? | assumed | step 4 |
| P8 | `systemd-escape --template=netif-dhcpcd@.service br-lan`: the instance `br\x2dlan` gives `%I = br-lan` and a device unit name that exists | assumed from systemd's escaping rules | step 6 |
| P9 | udev `RUN+="systemctl --no-block start ..."` on `move`: does a rename by IfState (`match.mac`) emit `move` with the new `NAME`? If not, nothing is lost: the transaction's own reconcile runs after the rename | assumed | step 6 |
| P10 | Does the kernel copy `conf/default` to a link at creation for all baseline keys (veth, WireGuard, bridge ports)? | standard kernel behaviour, assumed | step 1 (H20 answers it) |
| P11 | `arp_ignore = 1` on a kube node's underlay link: any effect on Cilium L2 announcements, NodePort, or a `/32` cloud lease? | unknown | step 8 |

Verified facts this design leans on (add them to `documentation/docs/reference/upstream-facts.md` when a suite confirms the behaviour):

- IfState 2.5.1 schema has per-interface `sysctl.ipv4`/`sysctl.ipv6` with every key in §3.4, and top-level `sysctl.all`/`sysctl.default` (schema file in the store).
- IfState writes `all.ipv6.optimistic_dad = 1` on every apply (`libifstate/sysctl/__init__.py`, `Sysctl.__init__`).
- IfState writes a link's sysctls before it changes the link's state (`link/base.py:902-903`, `1237-1239`).
- IfState only warns for a missing physical link and exits 0 (N15, already in the spec).
- `ifstate.service` from nixpkgs is `Type=oneshot` without `RemainAfterExit`, `After=network-pre.target`, `Before=network.target`, `TimeoutStartSec=2min`, and runs `udevadm settle --timeout=180` first (built unit in the store).
- dhcpcd 10.5.2: `nooption` removes an option before processing; of the options in §3.5, only 1 and 3 carry `request` in the built-in definitions; `whitelist` filters by source address.
- NixOS: `system.preSwitchChecks` gets the action as `$2`; `networking.tempAddresses = "default"` writes `use_tempaddr` on every link by a udev rule.
- The guard on `main` keeps one `last-good` for all modes (`guard.nix:123`).

Risks:

- **R1 Boot-time coupling (P1).** The transaction now sits before `network.target`. If P1 shows a cycle, fall back to: keep the transaction program, but run verify-and-rollback from a second unit `netif-verify.service` that `ifstate.service` starts with `--no-block` and that `switch-to-configuration` waits for through `restartTriggers = [bundle]`. Then one marker returns (`/run/netif/active` already says what was applied, so no extra file). The decision table does not change.
- **R2 The "stay on L" rule refuses good deploys during an outage.** Accepted cost. If it hurts in practice, the answer is an evidence-triggered single retry ("when L's obligations pass again, try B once"), never the old re-apply.
- **R3 RA default off breaks fixtures quietly.** A link that lost its SLAAC address fails late and far from the cause. Step 2 must grep every inventory in the repo for IPv6 without a static gateway.
- **R4 `arp_ignore`.** Hardening, not an invariant. Its own PR, last.
- **R5 `accept_dad = 0`.** Trades duplicate detection for resistance to a DAD attack. Owner decision.
- **R6 Hostile Wi-Fi (T5).** iwd's DHCP client is not under §3.5. A hostile access point's lease can carry option 121. Out of netif's hands; a follow-up for the iwd preset (`lib/ownership.nix:310-320`): check iwd's `[IPv4]`/`[Network]` settings for a route-option switch, and add verdict H11 of the review to `netif-wifi`.
- **R7 One YAML for all IfState writers.** A rollback re-applies the fabric's and the gateways' IfState objects of L too. That is today's behaviour and is kept; the guard never *judges* them.
