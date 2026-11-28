# Host networking: target design (netif, modes, IfState base, registry)

> **Status: target design, prototyped and probed on VMs; not merged**
> (SPEC.md round 61; probe round of 2026-11-27). A line that says
> "VERIFIED-VM" names the suite that proved it on the remote builder.
> "NOT-RUN" means: designed, not built or not booted. The prototype is
> one patch against `main` at deeaba4 (`probes/netif/prototype.patch`
> in the session evidence); its results are
> `specs/probes/2026-11-27/netif.md` (in the repo) and
> `probes/netif/runs/`. The `probes/netif/` folder is not in the repo;
> the session handoff maps it. `specs/netif.md` is still the status
> authority until each step of §8 amends it. The index, the cross-area
> contracts and the build order are in `specs/target-design.md`.

Base: `main` at deeaba4. Builds on `reviews/netif.md` (N-A1..N-A16).
Paths are relative to the repo root.

The owner's decisions are written in: O5 (accept "a new configuration
must prove itself", plus a declared one-shot override, §3.2), O6
(`accept_dad`: no; `arp_ignore`/`arp_announce`: yes, own step, after
P11), DHCP classless routes off by default with a per-link opt-in, and
router advertisements opt-in per link.

Words used below:

- **bundle**: one store directory with everything netif applies for one generation (IfState YAML, dhcpcd files, a manifest).
- **B**: the bundle of the running generation. **L**: the last bundle that passed ("last good").
- **obligation**: one thing the guard tests. Every obligation comes from netif's own declarations.
- "VERIFIED-VM": a suite on the remote builder showed it. "verified": read in code or in a store file. "assumed": kernel, systemd, dhcpcd or IfState behaviour that no suite showed.

The owner's rule applies: no compatibility, no shims. Only the safety behaviour is fixed.

---

## 0. The design in one page

1. **One transaction.** `ifstate.service` runs one program, `netif-apply`. It applies, starts DHCP, checks, and rolls back. Program order replaces `ExecStartPre`/`ExecStartPost` lists from three modules. This removes N-A1 and N-A2 by construction. VERIFIED-VM: it works at boot without an ordering cycle and without a second unit.
2. **One bundle.** IfState YAML, dhcpcd files and a guard manifest are one store path. "Roll back" is "activate bundle L". Apply and rollback share one function.
3. **dhcpcd units never change between generations.** One template unit reads its file through `/run/netif/active`. A deploy never stops a DHCP client that has no change (the root cause of N36).
4. **The guard tests only what netif declared.** Its own gateways, its own default routes, its own addresses, the declared targets. Never a route of BGP, Cilium, Tailscale or another owner (N-A3).
5. **B must prove itself.** If B fails and L exists, the kernel ends on L. The "fault is outside, re-apply B" branch is removed: it is a lockout path. One declared exception: `guard.replaces` names the last good bundle that a planned renumbering may leave, once (owner decision O5).
6. **A bundle that failed while L passed is marked bad.** It is not tried again at boot or at the next switch.
7. **One sysctl baseline** for every link: declared, hot-plugged, and links of other owners. Redirects off, source routes off, router advertisements off unless declared.
8. **RA is opt-in per link.** `ra` defaults to false.
9. **DHCP is an untrusted input.** One policy table says what a lease may set. Routes other than the router: no, unless the link opts in (owner decision). MTU: no. DNS: only on a link that owns a default route, unless the link opts in.
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

- **I1 No lockout by deploy.** After any run of `ifstate.service` on a machine with L, the kernel holds B only if every obligation of B passed in that run (or B is unclean but passed, I3), or the owner named L in `guard.replaces` and L failed too. Otherwise it holds L.
- **I2 Do no harm.** The guard changes the network only when an obligation failed. A failed apply whose obligations pass is reported and left alone.
- **I3 Only proven bundles are recorded.** L is set only after a clean apply (IfState exit 0, every declared physical NIC present, guest ports intact) with every obligation passed. The one exception is the override of I1; its outcome is `committed-unproven`, never `committed`.
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

VERIFIED-VM (`netif-guard`, `netif-probe-tx`). In `services/netif/host.nix`; replaces `dhcpcdConfs`, `guardGeneration` and the per-link units:

```nix
bundle = pkgs.linkFarm "netif-bundle" (
  [
    { name = "ifstate.yaml";  path = config.environment.etc."ifstate/ifstate.yaml".source; }
    { name = "manifest.json"; path = pkgs.writeText "netif-manifest.json" (builtins.toJSON cfg.guard.manifest); }
  ]
  # /etc/netif/dhcpcd/<link>.conf stays: it shows the same file for this generation
  ++ lib.mapAttrsToList (interface: _: {
    name = "dhcpcd/${interface}.conf";
    path = config.environment.etc."netif/dhcpcd/${interface}.conf".source;
  }) dhcpLinks
  ++ lib.optional (hotplug.interfaces != []) { name = "dhcpcd-hotplug.conf"; path = hotplugConf; }
);
```

- The bundle is the option `clanServices.netif.bundle` (internal, read-only). Its store name is always `netif-bundle`.
- The bundle path changes exactly when something netif applies changes. `B == L` is a path compare.
- What belongs to the running generation but is not network state is a second file, `netif-runtime.json`, passed as `--runtime`. It is **not** in the bundle, so the override of §3.2 and a hook's store path never change the bundle:

```json
{
  "mode": "default",
  "timeout": 45,
  "replaces": null,
  "preApply": ["/nix/store/…-netif-ra-metric", "/nix/store/…-netif-guest-ports"],
  "dnsApply": "/nix/store/…-netif-dns-apply",
  "guestCheck": "/nix/store/…-netif-guest-ports-check"
}
```

`manifest.json` is the option `clanServices.netif.guard.manifest` (internal, read-only; `services/netif/guard.nix`). Built from `clanServices.netif.links` (links with `memberOf == null`):

```json
{
  "version": 1,
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

Rules for the manifest:

- `gateways`: every declared static gateway of every link, also one in a policy table.
- `defaults`: one entry per family for the link where `v4Default`/`v6Default` is true. A `"static"` default always. A `"dhcp"` or `"ra"` default only when the link is `required` (§3.7; `requiredForOnline` until step 6 renames it).
- `addresses`: every static address of a link. Nothing for DHCP or SLAAC addresses.
- `targets`: `guard.targets`, typed.
- `physical`: every IfState interface of kind `physical`.
- The host-side facts the manifest needs are new fields of `clanServices.netif.links.<if>`: `static4`, `static6`, `defaultSource4`, `defaultSource6` (`null`, `"static"`, `"dhcp"`, `"ra"`), `dhcpDns`, `classlessRoutes`.

### 3.2 The transaction (`netif-apply`)

VERIFIED-VM: every row of the decision table ran on real `switch-to-configuration` calls in `netif-guard` (markers `NETIF_GUARD_*_OK`); DHCP links in `netif-probe-tx`.

One Python program, `services/netif/apply.py` (about 330 lines), built with `pkgs.writers.writePython3Bin` (pyyaml for the ignore-list merge) and wrapped with its `PATH` (IfState, iproute2, iputils, ndisc6, systemd, util-linux). `ifstate.service` runs it:

```
netif-apply --runtime <netif-runtime.json> [--no-guard] <bundle>
netif-apply --reconcile-dhcp
```

Runtime state:

| Path | Meaning | Lifetime |
|---|---|---|
| `/run/netif/active` | symlink to the bundle the kernel holds. dhcpcd reads its files through it | boot |
| `/run/netif/lock` | `flock` for the transaction and the DHCP reconcile | boot |
| `/run/netif/guard/status.json` | last outcome: `outcome`, `bundle`, `good`, `active`, `failed`, `failedWithLastGood`, `time` | boot |
| `/run/netif/guard/rollback.yaml` | L's YAML with the running ignore lists merged in (written for each rollback) | boot |
| `/run/netif/mode` | the mode this boot started in (§3.8) | boot |
| `/var/lib/netif/guard/<mode>/good` | symlink to L | disk |
| `/var/lib/netif/guard/<mode>/bad` | text file: path of the bundle marked bad | disk |
| `/nix/var/nix/gcroots/netif-guard-<mode>-good` | GC root of L | disk |

Deleted state: `/run/netif-guard/` and everything in it, `last-good`, `last-good-dhcpcd`, `last-good-defaults`.

#### The program

```
main(B, runtime, guard_on):
  lock /run/netif/lock
  L   = readlink good        (None when absent or its manifest version is unknown)
  bad = read bad

  if not guard_on: clean = activate(B); exit 0 if clean else 1

  if bad == B and L and L != B:                       # I4
      activate(L, running=B)
      fail = verify(L.manifest, B.targets)
      status("still-rolled-back"); exit 1

  clean = activate(B)
  fail  = verify(B.manifest, B.targets)

  step = decide(clean, fail, B, L)
  commit      -> good := B; remove bad; exit 0
  unclean     -> exit 1          # obligations pass; apply or NIC not clean; nothing touched (I2)
  unverified  -> exit 1          # no L, or L == B: nothing to roll back to
  rollback    ->
      applied = activate(L, running=B)
      fail2   = verify(L.manifest, B.targets) if applied else ["the rollback apply failed"]
      step2   = decide_after_rollback(applied, fail2, runtime.replaces == L)
      bad              -> bad := B; exit 1          # L passes: B is the fault
      undecided        -> exit 1                    # L fails too: stay on L (I1)
      commit-unproven  -> activate(B, running=L); good := B; remove bad; exit 0   # the owner's override (O5)
      rollback-failed  -> exit 1

activate(X, running=None):                 # the one function for apply and rollback
  yaml = X/ifstate.yaml
  if running and running != X: yaml = merge_ignore(X yaml, running yaml)   # an owner of the failed generation keeps its links (N6)
  run runtime.preApply                     # ra_defrtr_metric loop, guest-port list
  rc = ifstatecli --config yaml apply
  old = readlink /run/netif/active
  symlink /run/netif/active -> X           # atomic: symlink to a temp name, rename
  reconcile_dhcp(old, X)
  run runtime.dnsApply
  missing = [d for d in X.manifest.physical if not exists /sys/class/net/d]
  guests_ok = run runtime.guestCheck
  return rc == 0 and not missing and guests_ok

reconcile_dhcp(old, new):
  for dev, conf in new/dhcpcd/*.conf:
      skip when /sys/class/net/dev is absent
      unit = systemd-escape --template=netif-dhcpcd@.service -- dev
      if old has a file for dev with other content:  systemctl stop unit     # blocking: its ExecStopPost flushes the old lease first
      systemctl start --no-block unit                                          # no-op when running (S1)
  for dev in old/dhcpcd minus new/dhcpcd:  systemctl stop unit
  for dev in /sys/class/net that starts with a prefix of new.manifest.hotplug and has no file in new/dhcpcd:
      (stop first when dhcpcd-hotplug.conf changed)
      systemctl start --no-block netif-hotplug@<escaped dev>.service

verify(manifest, targets):                 # one deadline for everything
  deadline = now + runtime.timeout
  pending = obligations(manifest, targets)
  loop:
      pending = [o for o in pending if not test(o)]
      if not pending: return []
      if now >= deadline: return [describe(o) for o in pending]
      sleep 1
```

Obligation tests (as they ran):

| Obligation | Test | Notes |
|---|---|---|
| address `A` on `dev` | `ip -j addr show dev <dev>`: an entry with that `local` and `prefixlen`, not `dadfailed`; `tentative` is accepted only while the link has `NO-CARRIER` | a bridge with no port yet cannot end duplicate address detection; that is not a fault |
| gateway `G` on `dev` | IPv4: `arping -q -c1 -w1 -I <dev> <G>`. IPv6: `ndisc6 -q -1 -r1 -w1000 <G> <dev>` | gateways may drop pings (`netif-guard` runs with such a gateway) |
| default, `static` | `ip -j -<f> route show default dev <dev>` has an entry with `gateway == G` | table main |
| default, `dhcp` | same command, an entry with `protocol == "dhcp"`. Then its `gateway` must answer at layer 2 on `<dev>` | dhcpcd 10.5.2 installs its routes with `proto dhcp` (VERIFIED-VM) |
| default, `ra` | same, `protocol == "ra"`. Then its `gateway` must answer | |
| target `tcp` | `socket.create_connection((address, port), timeout=1)` | no netcat |
| target `neigh` | as gateway | |
| target `ping` | `ping -q -c1 -W1` | |

What is **not** tested: any default route with another protocol or on another device. VERIFIED-VM (`NETIF_GUARD_FOREIGN_DEFAULT_OK`): with `default via 192.168.1.77 dev eth1 proto bgp metric 20` (a silent gateway) in the main table, the run exits 0 with outcome `committed`, and IfState leaves the route in place. On `main` the same route fails the guard (`runs/probe-N-A3-guard-bgp-default.txt`).

#### The decision as code (pure, unit-tested)

```python
def decide(clean, failures, bundle, good):
    if not failures:
        return "commit" if clean else "unclean"
    if good is None or good == bundle:
        return "unverified"
    return "rollback"


def decide_after_rollback(applied, failures, leave_allowed):
    if not applied:
        return "rollback-failed"
    if not failures:
        return "bad"
    return "commit-unproven" if leave_allowed else "undecided"
```

Decision table (the test table for `checks.netif-guard-logic`; the last column is the `netif-guard` subtest that ran the row on a VM):

| # | apply of B | obligations of B | L | action | outcome | exit | recorded | VERIFIED-VM |
|---|---|---|---|---|---|---|---|---|
| 1 | clean | pass | any | none | `committed` | 0 | `good := B`, `bad` removed | `NETIF_GUARD_BOOT_OK`, `NETIF_GUARD_KEPT_OK` |
| 2 | not clean | pass | any | none | `unclean` | 1 | nothing | `NETIF_GUARD_FAILED_APPLY_OK` (a declared NIC that is missing) |
| 3 | any | fail | none, or `L == B` | none | `unverified` | 1 | nothing | `NETIF_GUARD_FIRST_BOOT_OK`; `netif-v6only` for `L == B` |
| 4 | any | fail | `L != B` | activate L; L passes | `rolled-back` | 1 | `bad := B` | `NETIF_GUARD_ROLLBACK_OK`, `_OWNERS_OK`, `_SECOND_RUN_OK` |
| 5 | any | fail | `L != B` | activate L; L fails too | `undecided`, kernel stays on L | 1 | nothing | `NETIF_GUARD_TARGET_OK`, `_OUTAGE_BAD_OK` (H22), `_OUTAGE_GOOD_OK` |
| 5o | any | fail | `L != B` and `guard.replaces == L` | activate L; L fails too; activate B | `committed-unproven`, kernel on B | 0 | `good := B`, `bad` removed | `NETIF_GUARD_OVERRIDE_OK` |
| 6 | any | fail | `L != B` | activate L; IfState fails | `rollback-failed` | 1 | nothing | NOT-RUN on a VM (needs a YAML that IfState rejects at run time); table test only |
| 7 | not tried | not tried | `bad == B`, `L != B` | activate L | `still-rolled-back` | 1 | nothing | `NETIF_GUARD_ROLLBACK_OK` (`ip monitor` saw no address of B) |

Every exit 1 prints one line that names the outcome, the failed obligations and the next step. The line of row 5, as it ran:

```
netif-apply: undecided. With this generation: no answer from 192.168.6.1 on eth1; … With the last good network too: no answer from 192.168.1.1 on eth1; … The last good network stays applied. When the fault outside is gone: systemctl restart ifstate.service. For a planned move away from the last good network set clanServices.netif.guard.replaces = "/nix/store/…-netif-bundle" (specs/netif.md N25)
```

`switch-to-configuration` exits 4 when `ifstate.service` fails (VERIFIED-VM: every failing row gave `rc=4`).

#### The override for a planned renumbering (owner decision O5)

Rule 5 ("B must prove itself, else the machine stays on L") refuses every move to a network where L can never work again: a renumbering, a new uplink. The owner accepted the rule and asked for a declared, one-shot, visible override. It is one option:

```nix
clanServices.netif.guard.replaces = "/nix/store/…-netif-bundle";   # the value `netif-guard status` prints as `good`
```

- **Explicit.** The value names the one last good bundle that may be left. The type is `nullOr (strMatching "/nix/store/[a-z0-9]{32}-netif-bundle")`.
- **One-shot by construction.** After the override was used, `good` is the new bundle. The value matches nothing any more. No state file says "used". VERIFIED-VM: the next generation with the same value ended `undecided` on L.
- **Visible.** An evaluation warning while the option is set (VERIFIED: `vm-test --check netif-guard` prints it for each such configuration). `netif-guard status` prints `replaces:`. The journal says `committed-unproven … WITHOUT PROOF`, and `status.json` keeps the outcome and both failure lists.
- **Narrow.** It changes row 5 only. While L still answers, a failing B is rolled back and marked bad as always (VERIFIED-VM: `renumber2` with the gateway up ended `rolled-back`). A B that passes commits as always.
- **Not part of the bundle.** It travels in `netif-runtime.json`, so setting or removing it never changes the bundle path.
- The exit status is 0: the owner declared the outage. The next boot has `B == L`: row 1 or row 3.
- How to use it: `netif-guard status` on the machine, copy `good`, set the option together with the new addresses, deploy. Remove the option in the next change.

`netif-guard` CLI (in `guard.nix`, three verbs):

- `netif-guard status`: prints `mode`, `bundle`, `active`, `good`, `bad`, `replaces` and `status.json`.
- `netif-guard retry`: removes `bad`, then `systemctl restart ifstate.service` (VERIFIED-VM: the bad bundle is tried again and rolled back again).
- `netif-guard force`: `netif-apply --no-guard B`. For a console session. Records nothing. NOT-RUN on a VM as a verb; `--no-guard` itself runs in `netif` (guard off).

#### What "the switch succeeded" means

Exit 0 of `ifstate.service` means all of:

1. IfState applied B with exit 0.
2. Every declared physical NIC exists; guest ports are intact.
3. Every declared static address is on its link and usable.
4. Each default route netif declared is in the main table, from the declared source.
5. Each declared gateway, each learned gateway of a netif default, and each target answered.

Or the owner's override of row 5o applied. `switch-to-configuration` starts `ifstate.service` on **every** switch and waits for it (VERIFIED-VM, P2: a switch that changes only the firewall got a new `InvocationID`, exit 0, `committed`). The reason: the unit is a oneshot without `RemainAfterExit`, wanted by `multi-user.target`, so it is inactive after each run and the final "start the active targets" step of the switch starts it again. So the deploy's exit status is the verdict, and every deploy re-proves the network, also one that changed nothing in it.

#### Boot and switch

Same program, same table. Differences come from the inputs only:

- Normal boot: `B == L`. Pass: row 1 (a no-op record). Fail (gateway still booting, DHCP server down): row 3. Nothing changes; dhcpcd keeps trying; the unit shows failed, which is the truth: unverified.
- Boot after `nixos-rebuild boot` with a network change: `B != L`. Full protection, rows 1, 4, 5.
- Boot of a generation whose bundle is marked bad: row 7. No outage window at all.
- First boot: no L. Row 1 or row 3.

### 3.3 Units and ordering

VERIFIED-VM (P1, P8, P9 in `netif-probe-tx`; every netif suite boots with it). The shape of the design held: **no second unit is needed**; the fallback of risk R1 is dropped.

```nix
# services/netif/host.nix
systemd.services = {
  # cfg.transaction = IfState mode && (links != {} || hotplug.interfaces != [])
  ifstate.serviceConfig = {
    ExecStart = lib.mkForce "${cfg.applyCommand} ${lib.optionalString (!cfg.guard.enable) "--no-guard "}${bundle}";
    # udevadm settle (ExecStartPre of nixpkgs, up to 180 s) + two applies + two waits
    TimeoutStartSec = lib.mkForce (300 + 2 * cfg.guard.timeout);
  };

  "netif-dhcpcd@" = {
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
      ExecStopPost = "${dhcpcdCleanup} %I";      # flush the IPv4 lease, drop its DNS files, re-run the DNS writer
      Restart = "on-failure";
      RestartSec = 2;
    } // dhcpcdSandbox;                           # unchanged
  };

  netif-dhcp-reconcile = {
    description = "netif: start DHCP clients for links that appeared";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${apply} --reconcile-dhcp";   # takes the lock, runs reconcile_dhcp(active, active)
      TimeoutStartSec = 600;
    };
  };
};

# one pair of rules per declared DHCP link, one pair per hot-plug prefix
services.udev.extraRules = ''
  SUBSYSTEM=="net", ACTION=="add|move", KERNEL=="${interface}", RUN+="${systemctl} --no-block start netif-dhcp-reconcile.service"
  SUBSYSTEM=="net", ACTION=="add", NAME=="${interface}", RUN+="${systemctl} --no-block start netif-dhcp-reconcile.service"
  SUBSYSTEM=="net", ACTION=="add|move", KERNEL=="${prefix}*", RUN+="${systemctl} --no-block start netif-dhcp-reconcile.service"
  SUBSYSTEM=="net", ACTION=="add", NAME=="${prefix}*", RUN+="${systemctl} --no-block start netif-dhcp-reconcile.service"
'';
```

`lib/ifstate.nix` keeps `KillMode = "process"` and gains the internal option `clanServices.networking.transaction` (set by netif). Its own `ExecStartPost` check for missing physical NICs runs only when that option is false (a machine that uses the IfState base without netif): with the transaction, `netif-apply` does the check itself, after DHCP and DNS.

Why this shape, with the evidence:

- **P1, boot.** `ifstate.service` (activating, before `network.target`) starts `netif-dhcpcd@wan\x2d0.service` with `--no-block`. The client started 1.1 s after the program, the lease was there, the program verified and exited 0 after 11.4 s in total; `network.target` followed at once. No "ordering cycle" line in the boot journal. The 10 s are dhcpcd's own (it probes the offered address by ARP before it uses it). So a machine whose default comes from DHCP reaches `network.target` about 10 s later than one that does not wait. That is the price of "exit 0 means proven".
- **P8, names.** `systemd-escape --template=netif-dhcpcd@.service -- wan-0` gives `netif-dhcpcd@wan\x2d0.service`; `%I` is `wan-0`; the device unit exists; the client ran. Instance names are built in one place (the reconcile). udev never builds a unit name. That fixes N-A11 for declared and hot-plug links.
- **P9, rename.** When IfState renames a `match.mac` link, udev emits `move` with `KERNEL` (and `$name`) equal to the new name: `add kernel=eth1 name=eth1; … move kernel=wan-0 name=wan-0`. So the rule matches `KERNEL` on `add|move`. Proof of the rule: the link was renamed away by hand (the bound client stopped), renamed back, and had its lease again after 6.5 s with no IfState run.
- `netif-hotplug@` keeps its shape but is started by the reconcile with an escaped name, reads `/run/netif/active/dhcpcd-hotplug.conf`, and has `stopIfChanged = false` instead of a restart trigger.
- `netif-guard.service` is deleted. `netif-online.service` stays, with `after = ["ifstate.service"]` only.
- `netif-dns.service` stays.
- The nftables `ExecReload` hook is deleted. See §4 (a).
- The unit name of a DHCP client changes from `netif-dhcpcd-<if>.service` to `netif-dhcpcd@<if>.service`. Suites of other areas name the old one (§8, step 6).

Order inside one run (program order, not unit-list order):

```
udevadm settle (nixpkgs ExecStartPre)
 -> preApply hooks (RA metric, guest-port list)
 -> ifstatecli apply
 -> /run/netif/active := bundle
 -> DHCP reconcile
 -> DNS apply
 -> physical-NIC check, guest-port check   (set "clean"; never skip a later step)
 -> verify
 -> commit, or activate(L) and verify again
```

N-A1 is gone by construction, VERIFIED-VM twice: at boot (`lame`: a declared NIC missing from the first boot; the DHCP link has its lease and its client; outcome `unclean`, nothing recorded) and at a switch (`cloud`, specialisation `ghost`).

S1, VERIFIED-VM: a switch that changes nothing restarts no client (`ActiveEnterTimestampMonotonic` of both clients unchanged). A switch that changes one link's dhcpcd file restarts that client only. This is also the fix of N36: a switch on a machine whose default comes from DHCP reports success (`netif-dhcp`, `NETIF_DHCP_GUARD_SWITCH_OK`).

Order in a deploy: `switch-to-configuration` reloads and restarts changed units (the firewall) before its final "start" step, which is where `ifstate.service` runs. So the targets are judged with the new firewall loaded. VERIFIED-VM for the order (`NETIF_GUARD_FIREWALL_OK`: the new rule is loaded and the run is `committed`). NOT-RUN: a firewall-only change that closes a TCP target (expected: exit 4, `unverified`, network untouched).

### 3.4 Sysctl baseline

VERIFIED-VM (P3, P10; `netif-hostile` H05–H08, H20; `netif` keeps its "a reapply changes nothing" check).

One source: `lib/sysctl-baseline.nix`, a plain attrset. Three sinks read it. All three ran:

| Sink | Covers | Where | Evidence |
|---|---|---|---|
| 1. `boot.kernel.sysctl` with `all`, `default` and the glob `*` | every link in every mode, links of other owners, links that appear later | `lib/ifstate.nix`, not gated on the mode | `eth0` (present at boot, declared by nobody) has all six keys at 0: only the glob reaches it. `default` reaches a veth, a veth bridge port, a dummy, a bridge and a WireGuard link added after boot. A dummy added while `default` was set to 1 by hand still came up 0: udev (`99-systemd.rules`) runs `systemd-sysctl` for the new link and the glob applies. A link set to 1 by hand is 0 again after `systemctl restart systemd-sysctl` |
| 2. IfState per-interface `sysctl` | declared links; restored on every apply; seen by `netif-drift` | `services/netif/default.nix` (`mkIfstateBase`) | H06, H07 on the declared link; `assert_ifstate_noop` in `netif` |
| 3. `hotplugUp` | the RA keys of a hot-plug link | `services/netif/host.nix` | `netif-hostile` H18, `netif-hotplug` |

`boot.kernel.sysctl` is the only writer of `all` and `default`. IfState's top-level `sysctl.all`/`sysctl.default` exists in the 2.5.1 schema and is **not** used: two writers of one key.

IPv4:

| Key | Value | `all` | `default` | `*` glob | per declared link | Why |
|---|---|---|---|---|---|---|
| `accept_redirects` | 0 | yes | yes | yes | yes | T1. A host accepts when `all` OR the link says 1, so both must be 0 (H06) |
| `secure_redirects` | 0 | yes | yes | yes | yes | a redirect "from the gateway" is spoofable |
| `send_redirects` | 0 | yes | yes | yes | yes | a forwarding node must not tell neighbours to route elsewhere |
| `accept_source_route` | 0 | yes | yes | yes | yes | T1. Already the kernel and systemd default; pinned |
| `arp_ignore` | 1 | no | no | no | yes, step 8 | answer ARP only for an address on the asked link; a LAN host cannot map the machine's other addresses (H19). Owner decision O6: yes, after P11, as its own step |
| `arp_announce` | 2 | no | no | no | yes, step 8 | use the link's own address as ARP source |
| `rp_filter` | not set by netif | | | | | see below |

IPv6:

| Key | Value | `all` | `default` | `*` glob | per declared link | Why |
|---|---|---|---|---|---|---|
| `accept_redirects` | 0 | yes | yes | yes | yes | T1 (H07) |
| `accept_source_route` | 0 | yes | yes | yes | yes | kernel default; pinned (H08) |
| `accept_ra` | 0; with `ra`: 1, or 2 when the machine forwards | no | **0** | **no** | yes | T4, T6. No glob: a glob would switch RAs off on hot-plug links at every sysctl reload |
| `autoconf` | same as `ra` | no | 0 | no | yes | |
| `accept_ra_defrtr` | 1 only when `ra && default6 && gateway6 == null` | no | 0 | no | yes | N-A5: a static gateway is never joined by an RA default (H02) |
| `accept_ra_pinfo` | same as `ra` | no | 0 | no | yes | |
| `accept_ra_rt_info_max_plen` | 0 | no | 0 | no | yes | no more-specific routes from an RA (the IPv6 twin of option 121). Kernel default; pinned (H04, H16b) |
| `accept_ra_mtu` | 0 | no | 0 | no | yes | the MTU is declared; a rogue RA cannot shrink it (H16c) |
| `accept_ra_min_hop_limit` | 64 | no | 64 | no | yes | a rogue RA cannot set hop limit 1 (H16d) |
| `use_tempaddr` | 0 | no | no | no | yes | S5. NixOS default `networking.tempAddresses = "default"` writes 2 by a udev rule on every link; servers and routers need stable source addresses |
| `ra_defrtr_metric` | `routeMetric` | no | yes | no | written by the `preApply` hook | not in the IfState schema (N18, kept) |

`accept_dad` is **not** set (owner decision O6: no). A static IPv6 address keeps duplicate address detection. The former step 9 and verdict H17 are dropped.

Residual, measured: a link that exists before `systemd-sysctl` runs and that nobody declares keeps the kernel's `accept_ra = 1` (`eth0` in the suites; `all` is 1 too, and for IPv6 `all.accept_ra` has no effect on a link). `default` cannot reach it and there is no glob for the RA keys. Such a link is down unless something brings it up, and the kernel reads no RA on a link that is down. Not closed here; if it must be closed, the `preApply` hook can write `accept_ra = 0` on every link that is not declared with `ra`, not a hot-plug prefix and not another owner's.

`rp_filter`: netif does not render it.

- The NixOS firewall does the reverse-path check in nftables (`networking.firewall.checkReversePath`, default strict). netif never sets it.
- The kernel uses the larger of `all` and the link. The kube lib forces `all = 2` and `checkReversePath = "loose"`. A per-link 1 from netif would be raised to 2 anyway, and a per-link value on a fabric underlay breaks ECMP return paths.
- So: one mechanism (the firewall), one owner per value. H14 proves the behaviour on a plain host.

The code that ran:

```nix
# lib/sysctl-baseline.nix
{
  everyLink4 = { accept_redirects = 0; secure_redirects = 0; send_redirects = 0; accept_source_route = 0; };
  everyLink6 = { accept_redirects = 0; accept_source_route = 0; };
  raOff6 = { accept_ra = 0; autoconf = 0; accept_ra_defrtr = 0; accept_ra_pinfo = 0;
             accept_ra_rt_info_max_plen = 0; accept_ra_mtu = 0; accept_ra_min_hop_limit = 64; };
  arp4 = { arp_ignore = 1; arp_announce = 2; };   # step 8
}
```

```nix
# lib/ifstate.nix config, every mode
boot.kernel.sysctl = lib.mkMerge (
  [
    { "net.ipv4.ip_local_reserved_ports" = …; }
    (lib.mapAttrs' (key: value: lib.nameValuePair "net.ipv6.conf.default.${key}" (lib.mkDefault value)) baseline.raOff6)
  ]
  ++ lib.concatMap (scope: [
    (lib.mapAttrs' (key: value: lib.nameValuePair "net.ipv4.conf.${scope}.${key}" (lib.mkDefault value)) baseline.everyLink4)
    (lib.mapAttrs' (key: value: lib.nameValuePair "net.ipv6.conf.${scope}.${key}" (lib.mkDefault value)) baseline.everyLink6)
  ]) ["all" "default" "*"]
);
```

```nix
# services/netif/default.nix, mkIfstateBase: replaces the sysctl.ipv6 block
sysctl.ipv4 = baseline.everyLink4;
sysctl.ipv6 = baseline.everyLink6 // baseline.raOff6 // {
  accept_ra = if r.ra then (if forwarding then 2 else 1) else 0;
  autoconf = if r.ra then 1 else 0;
  accept_ra_pinfo = if r.ra then 1 else 0;
  accept_ra_defrtr = if r.ra && r.default6 && r.gateway6 == null then 1 else 0;
  use_tempaddr = 0;
};
```

IfState 2.5.1 accepts every one of these keys in a per-interface `sysctl` (VERIFIED: the build-time schema check passes and the values are in `/proc`).

Hot-plug (`hotplugUp` in `host.nix`) writes, before `ip link set up`: `accept_ra` (1, or 2 when forwarding), `autoconf 1`, `accept_ra_pinfo 1`, `accept_ra_defrtr 1`, `ra_defrtr_metric`. The other keys come from `default`: a hot-plug link showed `accept_ra_rt_info_max_plen = 0` and `accept_ra_mtu = 0`.

IfState writes a link's sysctls before it changes the link's state (read in `link/base.py`). So no RA is processed with the old value after an apply.

### 3.5 DHCP: option policy

VERIFIED-VM (`netif-hostile` H09–H13, H18; P5, P6, P7; `netif-dhcp` with the opt-ins).

| Lease content | Declared link | Hot-plug link | How |
|---|---|---|---|
| Address, mask | yes | yes | dhcpcd |
| Router (3) | only when the link owns the IPv4 default | yes, metric `routeMetric + 100` | `nogateway` otherwise (kept, N21) |
| Static routes (33), classless routes (121, 249) | **no**. Yes with `dhcp.classlessRoutes = true` | **never** | `nooption static_routes, classless_static_routes, ms_classless_static_routes` |
| Interface MTU (26) | no | no | `nooption interface_mtu`. The MTU is `links.<n>.mtu` |
| DNS servers (6; DHCPv6 23) | when the link owns a default route, or `dhcp.dns = true` | yes, but see I11 | `nooption` otherwise |
| Domain, search list (15, 119; DHCPv6 24) | same switch as DNS | yes, with its DNS | same |
| NTP, hostname from the server, WPAD, anything else | no | no | not requested; netif's script is the only hook and reads DNS and prefix delegation only |
| Our hostname sent to the server (12) | yes | **no** | no `hostname` line in the hot-plug file |
| IPv4LL | no | no | `noipv4ll` (kept) |
| RAs read by dhcpcd | no | no | `noipv6rs` (kept); the kernel reads them under §3.4 |
| DHCPv6 address, delegated prefix | as declared | no (IPv4 only) | kept |

Why routes stay off even on the default-owning link: a route from option 121 can be more specific than a connected route of another link. A WAN lease could pull the traffic for one host of a private segment to the WAN. The router option cannot do that.

The dhcpcd.conf lines that ran on dhcpcd 10.5.2 (`dhcpcdConf` in `host.nix`):

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
++ …   # ipv4only / ipv6only / interface / iaid / ia_na / ia_pd as today
```

The hot-plug file: `duid`, `option domain_name_servers, domain_name, domain_search`, `nooption static_routes, classless_static_routes, ms_classless_static_routes`, `nooption interface_mtu`, `require dhcp_server_identifier`, `noipv6rs`, `noipv4ll`, `ipv4only`, `metric`, `backoff_cutoff`, `script`.

What the probes showed:

- **P6: `nooption` is needed, not tidy.** A rogue server sent options 121 and 26 that the client never requested (dnsmasq `--dhcp-option-force`). A dhcpcd with no `nooption` line installed the option-121 route and put `mtu 576` on every route of the lease: `10.66.0.0/16 via 10.8.0.1 proto dhcp … mtu 576`. dhcpcd writes option 26 as a route MTU; the link's own MTU stayed 1500. With the lines above the same kind of lease left only the connected route, with no `mtu` on it (H09, H10, H11). So "not requested" protects nobody.
- **The opt-in works**: with `dhcp.classlessRoutes = true` the route of option 121 is installed (`10.50.0.0/16 via … proto dhcp`), still no MTU (H13).
- **P5: a `/32` lease whose router is off-subnet needs nothing.** Lease `10.3.0.104/32`, router `172.31.1.1`, no option 121: dhcpcd installed `172.31.1.1 dev eth1 scope link` and `default via 172.31.1.1 dev eth1 proto dhcp`; the router answered pings. Such a link declares only `dhcp.ipv4 = true`.
- A lease with option 121 **and** `nooption classless_static_routes`: the router option is used again (H18a: the hot-plug link got `default via … metric 200` from option 3 although option 121 was in the lease).

DNS scope (`dnsApply` in `host.nix`), VERIFIED-VM (H12, H13, H18b, P7):

- New fact per link, set in `hostLinks`: `dhcpDns = if link.dhcp.dns != null then link.dhcp.dns else (v4Default r || v6Default r);`
- After each successful `resolvectl dns "$l" …` on a declared link the script sets `resolvectl default-route "$l" yes`. Explicit, not resolved's guess.
- Hot-plug links: `resolvectl default-route "$l" no` while any declared link has carrier and a non-empty DNS list; `yes` otherwise. Every run of the writer re-judges every present hot-plug link, whatever link it was called for. With hot-plug prefixes the watcher re-runs on every link event.
- P7: `default-route no` took effect at once, was `no` again after a carrier flap of the hot-plug link, and became `yes` within seconds when the last declared link lost its DNS.
- `set -f` as the first step of `dhcpcdScript` and `dnsApply` (N-A14).

### 3.6 RA policy

VERIFIED-VM (`netif-hostile` H02–H04 with their control, H15, H16a–d, H23; the suites of §8 step 2).

- `links.<n>.ra`: `types.bool`, **default `false`**.
- With `true`: prefixes and SLAAC addresses. A default router only when the link owns the IPv6 default and has no static IPv6 gateway.
- `ra = true` is what makes a link a source of an IPv6 default (N21 rule, kept). `v6Default` is now:

```nix
v6Default = r:
  r.memberOf == null && r.default6
  && ((r.gateway6 != null && !r.dhcp6 && r.policy.table == null) || (r.ra && r.gateway6 == null));
```

- Links nobody declared `ra` on get `accept_ra = 0`: bond and bridge members, VLAN parents without addressing (H23), guest-ports bridges and their guest ports (H15), veths, container bridges, fabric links. No special case in code: it is the default.
- On a link with `ra = true` that does not own the default, a rogue advertisement gives a prefix and an address and nothing else: no default router, no route-information route, no MTU change, no hop-limit change (H16a–d).
- Residual on an RA link: any on-link host can become a default router. That is what `ra = true` means. Documented in the option text.
- Not netif's: iwd and NetworkManager on their own links (P4, §9).

**A finding about the evidence of `main`.** The verdicts H02–H04 that the review recorded as "safe on `main`" proved nothing: radvd refused the rogue interface (`MinRtrAdvInterval … must be … no more than 3/4 of MaxRtrAdvInterval`), so no advertisement was ever sent. The suite now has a `control` before each group of verdicts (a packet capture or a positive effect that proves the attack arrived) and fails when a control is missing. `hostile-router` has the same radvd line (`services/router/tests/vm/hostile.nix:161`, `MaxRtrAdvInterval 4` without `MinRtrAdvInterval 3`) and needs the same control.

### 3.7 Option surface

Inventory (`services/netif/default.nix`):

| Change | Option | Type | Default | Status |
|---|---|---|---|---|
| changed default | `links.<n>.ra` | `bool` | `false` (was `true`) | ran |
| add | `links.<n>.dhcp.classlessRoutes` | `bool` | `false` | ran |
| add | `links.<n>.dhcp.dns` | `nullOr bool` | `null` = the link owns a default route | ran |
| rename | `links.<n>.requiredForOnline` → `links.<n>.required` | `bool` | `true` | NOT-RUN: the prototype keeps the old name with the new meaning ("`network-online.target` waits for it **and** the guard requires its DHCP or RA default"). The rename is mechanical; step 6 |
| text fix | `links.<n>.routes` | | | "always in the main table" (N-A9). NOT-RUN |

Machine (`clanServices.netif.*`):

| Change | Option | Type | Default | Status |
|---|---|---|---|---|
| changed | `guard.timeout` | `ints.between 5 300` | `45` (was 30) | ran (suites set 8 and 20) |
| add | `guard.replaces` | `nullOr (strMatching "/nix/store/[a-z0-9]{32}-netif-bundle")` | `null` | ran; §3.2, O5 |
| keep | `guard.enable`, `guard.targets` | | | ran |
| remove | `guard.script`, `guardGeneration`, `dhcpcdConfs` (internal) | | | removed |
| add | `bundle` (internal, read-only) | `package` | | ran |
| add | `guard.manifest` (internal, read-only) | `attrs` | | ran; the eval tests assert on it |
| add | `transaction`, `applyCommand` (internal, read-only) | `bool`, `str` | | ran |
| add, step 8 only | `arpHardening` | `bool` | `false` | probe switch for P11. Step 8 removes the option and renders the two keys always |

`clanServices.netif.links.<if>` (the host-side facts): add `dhcpDns`, `classlessRoutes`, `static4`, `static6`, `defaultSource4`, `defaultSource6`, `onLink`, `policyTable`. `required` replaces `requiredForOnline` in step 6.

Export and `clan._networkFacts`: `ra` keeps its meaning with the new default. Schema versions are reset by the last step of the build order (target-design §6).

### 3.8 Modes and the registry

- **Guard state per mode.** `/var/lib/netif/guard/<mode>/`. On `main` one `last-good` serves all modes, so booting mode `developer` could roll back to the network of mode `default`, with another set of owners. First boot of a mode has no L: row 3, loud, no rollback. VERIFIED-VM in `netif-modes`: booted in mode `developer`, `/var/lib/netif/guard/developer/good` is a symlink and there is no `/var/lib/netif/guard/default` (the default mode of that machine runs NetworkManager).
- **No manager change on a running system (I12).** In `lib/modes.nix`, as it ran:

```nix
systemd.tmpfiles.rules = [
  "d /run/netif 0755 root root -"
  "f /run/netif/mode 0644 root root - ${cfg.currentMode}"   # `f` never overwrites: it keeps the booted mode
];
system.preSwitchChecks.netif-mode = ''
  booted=$(cat /run/netif/mode 2>/dev/null || echo ${lib.escapeShellArg cfg.currentMode})
  if [ "$2" != boot ] && [ "$booted" != ${lib.escapeShellArg cfg.currentMode} ]; then
    echo "netif: this machine is booted in mode '$booted' and the new configuration is mode '${cfg.currentMode}'. Modes change by reboot only (specs/netif.md N3). Use 'boot' and reboot, or switch to the configuration of mode '$booted'." >&2
    exit 1
  fi
'';
```

  This catches the real hazard: a plain deploy to a Deck that is booted in its NetworkManager mode would switch it to the parent (IfState) configuration live.
- **Registry stays the single source** of "not IfState's". Three additions:
  - the sysctl baseline's `default` and glob scopes are what cover owner links; no per-owner sysctl option;
  - hot-plug stays a registry owner;
  - `netif-status` prints, per kernel link: `netif/<instance>/<link>`, `owner <name>`, or `UNOWNED`. NOT-RUN (not built).
- Not added: an overlap check between two owners' regexes.

### 3.9 Evaluation checks

Add to `linkAssertions` (`services/netif/default.nix`) unless noted. Every message names instance, link, machine and remedy, like the existing ones.

| # | Check | Kind | Status |
|---|---|---|---|
| E1 | static gateway inside a static subnet of the link, unless `gateway.onLink`, DHCP for that family, or an `fe80:` gateway | error | VERIFIED by `nix eval` of five nix-unit tests (`designChecks.test_gateway*`: outside fails, inside passes, `onLink` passes, IPv6 outside fails, `fe80::1` passes). Every suite that ran evaluates with it |
| E2 | the same for each `routes[].gateway` unless that route's `onLink` | error | NOT-RUN |
| E3 | `dhcp.ipv6 && default6 && !ra && gateway6 == null`: "DHCPv6 carries no router; set 'ra = true' or 'defaultRoute.ipv6 = false'" | error | VERIFIED by `nix eval` (`designChecks.test_dhcp6NeedsRouter`, `test_dhcp6WithRa`) |
| E4 | `ra = true` on a bond or bridge member | error | code in the tree; the failing fixture is NOT-RUN |
| E5 | `ra = true` on a bridge with `bridge.guestPorts` | warning | NOT-RUN |
| E6 | `dhcp.classlessRoutes` without `dhcp.ipv4`; `dhcp.dns` without any DHCP | error | first half VERIFIED by `nix eval` (`designChecks.test_classlessRoutesNeedDhcp`); second half NOT-RUN |
| E7 | more than one instance sets `targetHost` on one machine (perMachine) | error | NOT-RUN |
| E8 | guard on and the manifest has no address, gateway, default or target: "the guard has nothing to test on this machine; add 'guard.targets'" | warning | NOT-RUN |
| E9 | `links != {}` and `networking.firewall.enable = false` | warning | NOT-RUN |
| E10 | netif sets the deploy target, `services.openssh.enable`, and no rule opens an sshd port on that link | error | NOT-RUN; the static half of "no lockout": the guard cannot see inbound rules |
| E11 | a static address that is the network or broadcast address of its IPv4 subnet (prefix below 31) | error | NOT-RUN |
| E12 | hot-plug prefix regex stays `[A-Za-z0-9_.-]+` | kept | N-A11 is fixed by escaping (P8) |

The nix-unit tests that ran are the group `designChecks` in `services/netif/tests/eval-tests.nix` (eight tests; each was evaluated alone with `nix eval .#tests.systems.x86_64-linux.netif.designChecks.<test>.expr`, because the old guard tests in the same file fail until step 6). The pattern for the checks still to write:

```nix
kamWithLinks = links: kamOf (mkEvaled (lib.recursiveUpdate baseInventory {
  instances.home-net.roles.default.machines.kamrui-h1.settings.links = links;
}));

test_gatewayOutsideSubnet = {
  expr = failedAssertion (kamWithLinks {eth.gateway.ipv4 = "198.51.100.1";}) "outside its static subnets";
  expected = true;
};
test_raOnMember = {   # E4, NOT-RUN: needs a fixture with a bridge member
  expr = failedAssertion (kamWithLinks {nic.interface = "enp9s0"; nic.ra = true; br9.bridge.members = ["nic"];}) "a member carries no addressing";
  expected = true;
};
```

Typed addresses: already in place (`lib/ip.nix`); nothing to add.

---

## 4. Verdict on each idea

### (a) Guard redesign instead of patches: ACCEPT, and go further

- The review's three-part patch for N36 keeps four marker files and a generation string inside every dhcpcd unit. Each marker exists to repair an ordering that systemd does not give. One program has the ordering for free.
- **Probe only own declarations: accept.** §3.2 table. Fixes N-A3 without a protocol filter.
- **"Succeeded" is defined** in §3.2.
- **Rollback semantics change in one place.** Today, when both B and L fail, B is applied again ("the fault is outside", `guard.nix:379-406`). That is a lockout path: a wrong address deployed while the gateway reboots ends on the wrong address, and nothing looks again. The target: the kernel stays on L, which has passed before. Cost: a good deploy during an outage is refused and must be repeated. That is the right side to err on. VERIFIED-VM both ways (`NETIF_GUARD_OUTAGE_BAD_OK`, `NETIF_GUARD_OUTAGE_GOOD_OK`). The owner accepted it (O5) with the override `guard.replaces` for a planned renumbering (§3.2).
- **The firewall-reload check (N36 second half) is removed.** Reasons:
  - it rolls nothing back, so it protects nobody;
  - outbound probes cannot see a closed inbound port;
  - `ifstate.service` runs in every switch after the reload, so the targets are still checked with the new firewall loaded, once, in the right order;
  - E10 covers the common case (sshd closed) at evaluation.
- **Boot and switch are the same code.** §3.2.
- Rejected: **commit-confirm** (roll back unless the deployer confirms over a new connection). It is the only test that proves the deployer's path, but `clan machines update` has no confirm step and a boot has no deployer. Revisit if clan gains one.
- Rejected: **automatic retry / flip-flop** between B and L while both fail. It converges without the owner, but every trial flaps a network that may be half working, and a target that fails for a non-network reason would flap it forever. `netif-guard retry` is the manual form.
- Cost, as built: `guard.nix` went from 544 to about 210 lines of Nix (options, manifest, CLI) and `apply.py` is about 330 lines of Python. `netif-guard` and the guard part of `netif-dhcp` are rewritten as behaviour checks. The eval tests `test_guard*` and the table test are step 5.

### (b) One sysctl baseline: ACCEPT

- §3.4. Refinements over the prototype: the `*` glob for links that exist before `systemd-sysctl` runs (NetworkManager modes have no per-link IfState values); RA keys never in a glob; `rp_filter` deliberately not netif's; `arp_ignore`/`arp_announce` only per declared link and in their own PR.
- Cost: one small file, three call sites. A user `extraSettings.sysctl.*` for a baseline key becomes a collision error; that is intended.

### (c) RA only where declared: ACCEPT

- §3.6. The guest-bridge and VLAN-parent parts of N-A5 need no code: default off covers them. Only the explicit cases get a check (E4, E5).
- Cost: every suite and fixture that relies on the default `ra = true` sets it. The list is in §8, step 2. `netif-hostile` drops nothing.

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

Deleted code. Every row is deleted in the prototype (line numbers are those of `main`). One thing was kept against the first sketch: `/etc/netif/dhcpcd/<link>.conf`. The bundle takes its dhcpcd files from those `environment.etc` sources, so the path still shows this generation's file (tools and suites read it), and a test can still swap one client's file.

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

Suite checks that pin a mechanism, and the behaviour check that replaces each. Rewritten in the prototype and passing: the rows of `tests/vm/guard.nix`, `dhcp.nix`, `v6only-host.nix`, `modes/tests/vm/default.nix`, `hotplug.nix`, `match.nix` (its text check passes unchanged) and `lib/kube-cluster/tests/vm/join.nix:121`. Not rewritten yet: `routed-fabric/suite.nix:41`, `lib/kube-cluster/tests/vm/data-plane.nix:61`, the gateway suites named in §8.7, and the eval tests.

| Today | Where | Replace with |
|---|---|---|
| `test -e /run/netif-guard/rolled-back` | `tests/vm/guard.nix:280` | old address and default are back; `ifstate.service` is `failed`; `netif-guard status` says `rolled-back` |
| `grep -F owned /run/netif-guard/rollback.yaml` | `guard.nix:262` | the owned link still exists after the rollback (`ip link show`) |
| journal greps on `netif-guard.service` (`journal`, `journal_new`, `count`) | `guard.nix:171-190`, `dhcp.nix:708`, `v6only-host.nix:414` | exit status of the switch, kernel state, and `jq -r .outcome /run/netif/guard/status.json` |
| `LAST_GOOD = /var/lib/netif/guard/last-good`, GC-root readlink | `guard.nix:152`, `211` | `netif-guard status` prints `good`; keep one GC-root check: `nix-store --gc` then the rollback still works |
| "targets answer after the firewall change" in the nftables journal | `guard.nix:317` (`NETIF_GUARD_FIREWALL_OK`) | a switch that changes only the firewall and breaks a TCP target exits non-zero, the network is unchanged, outcome `unverified` |
| `NETIF_GUARD_OUTSIDE_OK`: "the new one stays" | `guard.nix:339-353` | **behaviour changes**: with the gateway down for both, the switch exits non-zero and the kernel holds the *old* address; outcome `undecided`. Then gateway up, `systemctl restart ifstate.service`: exit 0, new address |
| `NETIF_GUARD_TARGET_OK`: "this generation's network stays" | `guard.nix:300-308` | same change: outcome `undecided`, last good network applied |
| `NETIF_GUARD_FAILED_APPLY_OK` via a drop-in `ExecStart=false` and `InvocationID` | `guard.nix:320-337` | as built: a specialisation that declares a physical NIC that is not there; the switch exits non-zero, outcome `unclean`, gateway still reachable, `good` unchanged, `/run/netif/active` is that generation's bundle. (A YAML that IfState rejects at run time is still NOT-RUN; it is the same branch, `clean == False`) |
| `/run/netif-guard/dhcpcd/eth1.conf`, `pgrep ... /run/netif-guard/dhcpcd` | `dhcp.nix:720-726` | after a rollback of a client-only change: the lease is back, `readlink /run/netif/active` is the old bundle |
| `systemctl is-active netif-guard-dhcpcd-eth1.service` | `dhcp.nix:737-744` | after a rollback of "DHCP made static": `netif-dhcpcd@eth1.service` is active and the link has its lease address |
| `grep -x '4 eth1' .../last-good-defaults` | `dhcp.nix:712` | `jq '.defaults' /run/netif/active/manifest.json` has the entry |
| `systemctl cat netif-guard.service` fails in an NM mode | `modes/tests/vm/default.nix:193` | `/run/netif/guard` is absent in the NM mode |
| `netif-guard.service` `ActiveState == active` | `modes/default.nix:232`, `hotplug.nix:204`, `routed-fabric/suite.nix:41` | `ifstate.service` result is `success` and outcome is `committed` |
| "declared physical links missing after IfState apply: ghost" in the `ifstate.service` journal | `match.nix:98` | keep the text (the Python prints it); add: the present DHCP link has its lease while the unit is failed |
| eval `test_guardDefaults`, `test_guardRollbackHardening`, `test_guardTargetsAreShellWords`, the `ExecStartPost` string tests | `tests/eval-tests.nix:906-976`, `1094`, `1326-1331` | assertions on `guard.manifest` (targets, gateways, defaults per fixture), on the bundle's file list, on the template unit's `ExecStart`, and `checks.netif-guard-logic` for the decision table |

New static check `checks.netif-guard-logic` (register in `flake-parts/`, beside `checks.clat-follow` which is the same idea): runs `python -m unittest` on `apply.py` with the eight rows of §3.2 and the obligation list for three manifests. No network, no VM. NOT-RUN: not written in the probe round (step 5); the rows except 6 ran on VMs instead.

---

## 6. Hostile-suite verdicts

Suite `netif-hostile` (`services/netif/tests/vm/hostile.nix`). It ran with the prototype; the table is what it printed. Each row is one `verdict(id, safe, detail)`. A `control` before each group proves that the attack reached the victim; a missing control fails the suite. That rule exists because H02–H04 were empty on `main` (§3.6).

Topology as built: `gw` (the real gateway, VLAN 1); `attacker` on VLANs 1–5 (radvd, dnsmasq, scapy, nmap); `victim` with `uplink` (eth1, static, owns both defaults), `side` (eth2, DHCPv4, no default), `ral` (eth3, `ra = true`, no default), `optin` (eth4, DHCPv4 with `dhcp.dns` and `dhcp.classlessRoutes`), `trunk` (eth5, a VLAN parent without addressing) and `v10`, `br0` (guest ports) with a veth guest in a namespace, and the hot-plug prefix `enx` with a veth "dock" whose rogue server sits in a namespace.

| Id | Attack | Result with the prototype |
|---|---|---|
| H01 | full TCP scan of every address of the victim (`nmap -sS -p-`) | SAFE: no open port |
| H02 | radvd on VLAN 1, high preference, beside a static IPv6 gateway | SAFE (control: the RA was captured on eth1): the default stays on the declared gateway |
| H03 | the same RA carries a prefix | SAFE: no address from it |
| H04 | the same RA carries a route-information option | SAFE: no route |
| H05 | forged ICMP redirect in the gateway's name (scapy) | SAFE: the route does not move |
| H06, H07, H08 | read the redirect and source-route sysctls of the declared link and of `all` | SAFE: all 0. On `main`: GAP for H06 and H07 |
| H09 | rogue DHCP on `side`: option 121 with two `/1` routes and a `/32` for the real gateway (`dnsmasq --dhcp-option-force`) | SAFE (control: the rogue lease is on eth2): only the connected route; `ip route get` leaves by eth1 |
| H10 | the same lease with options 33 and 249 | SAFE: no route |
| H11 | the same lease with option 26 = 576 | SAFE: MTU 1500 |
| H12 | the same lease with option 6 and a server that answers every name | SAFE: `resolvectl dns eth2` is empty, `default-route` is `no` |
| H13 | `optin`: the link declared `dhcp.dns` and `dhcp.classlessRoutes` | SAFE as "declared": DNS set, `default-route yes`, the option-121 route installed, MTU still 1500 |
| H14 | spoofed source: a packet on VLAN 1 with a source address of the `side` subnet (scapy) | SAFE (control: an honest echo is answered): no reply leaves the victim (firewall reverse-path check) |
| H15 | a guest on `br0` sends an RA with a prefix (scapy in a namespace) | SAFE (control: the RA was captured on br0): no address, no route; `accept_ra` of `br0` and of the guest port is 0 |
| H16a–d | radvd on `ral` (`ra = true`, not the default owner): default router, route information, MTU 1280, hop limit 1 | SAFE (control: the link took the advertised prefix): no default on eth3, no route, MTU 1500, hop limit 64 |
| H18a–c | rogue DHCP on a hot-plug link: options 121, 3, 26, 6 | SAFE (control: the lease is on the link): only the router at metric 200; `default-route no` while a declared link has DNS; MTU 1500; redirects 0 |
| H19 | `arping` from VLAN 1 for the victim's address on eth2 | SAFE with the step-8 keys on (`Received 0 response(s)`; control: the victim's own address on eth1 answers). Without them Linux answers for any local address |
| H20 | every link of the machine except `lo` (declared, guest port, hot-plug, veth, bridge, dummy, WireGuard): six redirect and source-route keys | SAFE: all 0 on `br0 brx dm0 dm1 enxdock eth0 eth1 eth2 eth3 eth4 eth5 eth5.10 gp0 vt0 vt1 wg9` and on `all` and `default` |
| H21 | guard under a spoofed gateway (suite `netif-guard`: the gateway is down and `spoof` holds its IPv4 and IPv6 address) | SAFE with a TCP target: the switch exits non-zero, outcome `undecided`, the last good network stays. `HOSTILE LIMIT`: with no TCP target the spoofed layer-2 answer passes and the bundle commits |
| H22 | a bad deploy during an outage (suite `netif-guard`) | SAFE: outcome `undecided`, the machine answers on its old address when the gateway is back, with no action. On `main` this is a gap: the wrong address stays |
| H23 | scapy RA with a prefix on the untagged side of `trunk` | SAFE (control: the RA was captured on eth5): nothing taken, `accept_ra` 0 |

Dropped: H17 (`accept_dad = 0`; owner decision O6: no).

Suite `netif-modes` (I12), VERIFIED-VM: booted in the NetworkManager mode, `switch-to-configuration test` of the developer mode's configuration exits 1 with "netif: this machine is booted in mode 'default' and the new configuration is mode 'developer'. Modes change by reboot only …"; NetworkManager is still active, there is no `ifstate.service`, the lease is still there. The other direction (booted in `developer`, the parent's configuration) is refused too.

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
| 5 undecided | L, proven earlier | yes, once the outside fault ends | a planned move to a network where L can never work declares `guard.replaces` (row 5o), or uses the console and `netif-guard force` |
| 5o committed-unproven | B, not proven; L failed too | by the owner's declaration only | the owner named L as "to be left". A wrong B together with a dead L is a lockout the owner signed for. It cannot happen while L answers |
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
- **Bad deploy during an outage**: row 5. Kernel on L. The owner is in when the outage ends. (Today: B stays. H22, VERIFIED-VM: the gateway pinged the machine on its old address after the outage with no action on the machine.)
- **Planned renumbering**: the owner sets `guard.replaces` to the bundle `netif-guard status` shows as `good`, with the new addresses, and deploys. Old gateway still answering and B wrong: row 4, rolled back. Old gateway gone and B's gateway not there yet: row 5o, B stays and is recorded; the deploy exits 0 and the journal says "WITHOUT PROOF". The same option value in a later generation matches nothing (VERIFIED-VM).
- **Reboot after a rollback**: row 7. No outage.
- **A deploy that changes nothing in the network**: the bundle path is the same; the apply is a no-op (S2); the obligations are checked in about a second; no DHCP client is touched (S1). VERIFIED-VM. Note what follows from P2: every deploy re-proves the network, so a deploy during an outage exits non-zero even when it changed nothing in the network (row 3, nothing touched).
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

Every step: spec text first (`specs/netif.md` and `documentation/docs/netif/` together, hard rule 3), then code, then `git add -A`, `fmt`, `check`, and the named suites one at a time with `vm-test <suite> --remote --quiet --rebuild`. One PR per step. Take the code from `probes/netif/prototype.patch` (the session evidence): every file named below is in it, in the state that passed the suites named in §9. Decision ids: take the next free `N…` id in `specs/netif.md` at the time of the PR (`N45` is taken).

How to cut the prototype into steps: apply the whole patch in a scratch worktree, then for each step copy only the files and hunks the step lists. Steps 1, 2 and 4 touch the same two files (`services/netif/default.nix`, `services/netif/host.nix`) in separate hunks.

### 8.1 Step 0: spec

- Files: `specs/netif.md` (a new decision with the threat model of §1 and the invariants of §2; mark N25, N31, N36 "rewritten in step 6"), `documentation/docs/netif/`.
- Proof: `check` (`checks.spec-headings`).

### 8.2 Step 1: the sysctl baseline and the hostile suite

- New file: `lib/sysctl-baseline.nix` (without using `arp4` yet).
- `lib/ifstate.nix`: the `baseline` import and the `boot.kernel.sysctl` block of §3.4.
- `services/netif/default.nix`: in `mkIfstateBase`, `sysctl.ipv4 = baseline.everyLink4;` and `baseline.everyLink6` at the head of `sysctl.ipv6`. Leave the RA keys as they are on `main` (that is step 2).
- `services/netif/host.nix`: nothing.
- Suite: add `services/netif/tests/vm/hostile.nix` and its `clanTests.netif-hostile` entry. In this step keep only the verdicts that this step makes safe: H01, H05–H08, H14, H20 and the P3/P10 findings. The other verdicts arrive with their steps (a red verdict never lands on `main`).
- nix-unit (`services/netif/tests/eval-tests.nix`): a declared link renders `sysctl.ipv4.accept_redirects == 0`, `secure_redirects == 0`, `send_redirects == 0`, `accept_source_route == 0`, `sysctl.ipv6.accept_redirects == 0`; `config.boot.kernel.sysctl` has `net.ipv4.conf.all.accept_redirects`, `net.ipv4.conf.default.accept_redirects` and `"net.ipv4.conf.*.accept_redirects"`, all 0.
- Proof: `netif-hostile`; `netif` (its `assert_ifstate_noop`); one kube suite for the glob beside Cilium (`k3s-join-netif` and `k3s-data-plane-netif` passed with the whole prototype; `k3s-single` was not run).
- Docs: `documentation/docs/reference/upstream-facts.md`, the facts of §9 marked "step 1".

### 8.3 Step 2: router advertisements only where declared

- `services/netif/default.nix`: `ra` default `false` and its description; `v6Default` (§3.6); the full `sysctl.ipv6` block of §3.4 (`raOff6`, `accept_ra_pinfo`, `accept_ra_defrtr` with `gateway6 == null`, `use_tempaddr`); assertions E3 and E4 (§3.9); E5 as a warning.
- `lib/ifstate.nix`: add the `raOff6` line (`net.ipv6.conf.default.*`) to `boot.kernel.sysctl`.
- `services/netif/host.nix`: `hotplugUp` writes `accept_ra`, `autoconf`, `accept_ra_pinfo`, `accept_ra_defrtr` (§3.4).
- Fixtures that need `ra = true` (found by running them; each lost its IPv6 default or SLAAC address without it):
  - `services/netif/tests/vm/default.nix`: `uplink` of `edge-1`;
  - `services/netif/tests/vm/dhcp.nix`: `wan` of `router`, `uplink` and `private` of `client4`;
  - `lib/gateway/tests/vm/v6only-host.nix`: `uplink` of `slaac`;
  - not checked by a run, read them before the PR (risk R3): `lib/gateway/tests/vm/wan.nix`, `services/router/tests/vm/default.nix`, `lib/gateway/tests/vm/dual-wan.nix`, the kube suites with IPv6 over an advertised default. Grep every inventory for a link with IPv6 and no static IPv6 gateway.
  - no change needed: `netif-hotplug` (the dock is a hot-plug link), `netif-match`, `netif-guard`, `netif-vmhost`, `netif-wifi` and `netif-desktop` (they set `ra = false` or use no advertisement on a netif link).
- Suite: `netif-hostile` gains the `ral`, `trunk`, `v10` and `br0` links, the radvd fixture with `MinRtrAdvInterval 3`, the controls, and verdicts H02–H04, H15, H16a–d, H23.
- nix-unit: static `gateway.ipv6` with `ra = true` renders `accept_ra_defrtr == 0`; a bridge with `guestPorts` and a bridge member render `accept_ra == 0`; a link with `ra = true` and no gateway renders `{accept_ra = 1; autoconf = 1; accept_ra_defrtr = 1;}`; the E3 and E4 texts of §3.9.
- Proof: `netif-hostile`, `netif`, `netif-dhcp`, `netif-v6only`, `netif-hotplug`, `netif-vmhost`, `netif-wifi`, `netif-desktop`, `netif-modes`.

### 8.4 Step 3: evaluation checks

- `services/netif/default.nix`: E1 (in the prototype), E2, E6, E11 in `linkAssertions`; E7 in the perMachine module; E8, E9 as warnings; E10; the N-A9 text; N-A12 (skip odd guest-port names in `guestPortsBefore`, `host.nix`).
- nix-unit: one `failedAssertion` per check; the texts for E1, E3, E4 are in §3.9.
- Proof: `check`; `netif-vmhost` with a port named `gp(1`.

### 8.5 Step 4: DHCP option policy and DNS scope

Works on the per-link dhcpcd units of `main`; it does not need the transaction.

- `services/netif/default.nix`: options `dhcp.classlessRoutes`, `dhcp.dns`; the facts `classlessRoutes`, `dhcpDns` in `resolveLinks` and `hostLinks`; E6.
- `services/netif/host.nix`: the two facts in the `links` submodule; `dhcpcdConf` and `hotplugConf` of §3.5; `dnsApply` with `set -f`, `resolvectl default-route` and the hot-plug rule; `watchPattern`; `set -f` in `dhcpcdScript`.
- Fixture: `services/netif/tests/vm/dhcp.nix`, link `private` of `client4`: `dhcp = { ipv4 = true; dns = true; classlessRoutes = true; }` (the suite asserts its classless route and its DNS).
- Suite: `netif-hostile` gains the `side` and `optin` links, the hot-plug prefix, the rogue dnsmasq servers, verdicts H09–H13, H18a–c, and the P6/P7 findings.
- nix-unit: the conf text of a default-owning link has `option domain_name_servers` and `nooption static_routes, classless_static_routes, ms_classless_static_routes`; of a link with `defaultRoute.ipv4 = false` has `nooption domain_name_servers` and `nogateway`; with the two opt-ins has `option classless_static_routes` and `option domain_name_servers`; every conf has `nooption interface_mtu`; `dhcpDns` for the three cases.
- Proof: `netif-hostile`, `netif-dhcp`, `netif-hotplug`.

### 8.6 Step 5: the program and its table test, not wired

- New file `services/netif/apply.py` (from the prototype, unchanged).
- New static check `checks.netif-guard-logic` (register in `flake-parts/`, beside `checks.clat-follow`, which is the same idea): `python -m unittest` on `apply.py`. No network, no VM. Cases: the eight rows of the table in §3.2 through `decide` and `decide_after_rollback` (row 6 can only be tested here); `obligations()` for three manifests (static dual-stack with a TCP target; a DHCP default; nothing declared → empty list); `describe()` texts.
- `services/netif/guard.nix`: the `manifest` option and its builder; `services/netif/host.nix`: the internal `bundle` option. Nothing reads them yet.
- nix-unit on `guard.manifest` for three fixtures: static with gateways (addresses, gateways, two static defaults); DHCPv4 default (`defaults == [{dev; family = 4; source = "dhcp";}]`); a link with `requiredForOnline = false` and DHCP (no default entry).
- Proof: `check`.

### 8.7 Step 6: wire the transaction (one PR, do not split)

The template unit, the bundle and the program depend on each other.

- `services/netif/host.nix`: `bundle`, `runtime`, `apply`, `raMetric`, `dhcpcdCleanup`; options `transaction`, `bundle`, `applyCommand`; the `ifstate.service` `ExecStart` override and `TimeoutStartSec`; `netif-dhcpcd@`; `netif-dhcp-reconcile`; the udev rules; `netif-hotplug@` reading `/run/netif/active/dhcpcd-hotplug.conf`; `netif-online` after `ifstate.service` only. Delete the per-link units, the `SYSTEMD_WANTS` rules, the `ExecStartPre`/`ExecStartPost` lists, `guardGeneration`, `dhcpcdConfs`, `/etc/netif/dhcpcd/hotplug.conf`.
- `services/netif/guard.nix`: replaced by the prototype's file (options `enable`, `timeout` default 45, `replaces`, `manifest`, `targets`; the `netif-guard` CLI). Everything in the "deleted code" table of §5 goes.
- `lib/ifstate.nix`: the `clanServices.networking.transaction` option; `physicalCheck` only without it.
- `services/netif/tools.nix`: `netif-status` reads `netif-dhcpcd@<link>.service`.
- Rename `requiredForOnline` to `required` (option, facts, manifest builder, `onlineLinks`).
- Suites, rewritten per §5: `services/netif/tests/vm/guard.nix` (whole file), the guard part of `dhcp.nix`, `lib/gateway/tests/vm/v6only-host.nix` (guard part), and one line each in `services/netif/tests/vm/hotplug.nix`, `services/modes/tests/vm/default.nix`, `lib/kube-cluster/tests/vm/join.nix`. `netif-hostile` needs only the new unit name (`netif-dhcpcd@eth4.service`). Add the probe's cases to real suites: P1, P8, P9, S1 and the boot with a missing NIC from `services/netif/tests/vm/probe-tx.nix` go into `netif-match` (a `match.mac` DHCP link named with a `-`, beside a missing NIC) and `netif-dhcp`; then delete `probe-tx.nix`.
- **Suites of other areas that still name the old units** (not adapted in the probe round; each is a text change of the same kind): `netif-guard.service` in `lib/gateway/tests/vm/dual-wan.nix`, `lib/kube-cluster/tests/vm/data-plane.nix`, `services/routed-fabric/tests/vm/suite.nix`; `netif-dhcpcd-<if>.service` in `lib/gateway/tests/vm/wan.nix`, `lib/gateway/tests/vm/dual-wan.nix`, `services/router/tests/vm/default.nix`. Replace "the guard unit is active" by "`ifstate.service` result is `success` and `/run/netif/guard/status.json` says `committed`"; replace the unit name by `netif-dhcpcd@<if>.service` (a name with `-` or `.` is escaped: `systemd-escape --template=netif-dhcpcd@.service -- eth2.0`).
- nix-unit (`services/netif/tests/eval-tests.nix`, `services/modes/tests/eval-tests.nix`): replace `test_guardDefaults`, `test_guardRollbackHardening`, `test_guardTargetsAreShellWords` and the `ExecStartPost` string tests by assertions on `guard.manifest`, on the bundle's file list, on `systemd.services."netif-dhcpcd@".serviceConfig.ExecStart`, and on `ifstate.serviceConfig.ExecStart` (contains `--no-guard` exactly when the guard is off; contains the bundle path). The prototype did not touch these files: they fail until rewritten.
- Spec: rewrite N25, N31, N36 in `specs/netif.md`; add the override.
- Proof: `netif-guard`, `netif-dhcp`, `netif-match`, `netif-hotplug`, `netif-v6only`, `netif-modes`, `netif`, `netif-hostile`; then `vm-test --all --remote --rebuild --quiet`.

### 8.8 Step 7: modes

- `lib/modes.nix`: the tmpfiles lines and `system.preSwitchChecks.netif-mode` of §3.8. `services/netif/tools.nix`: `UNOWNED` in `netif-status`.
- Suite: `services/modes/tests/vm/default.nix`, the subtest "I12" and the per-mode check in the developer-mode subtest (both in the prototype).
- nix-unit: `system.preSwitchChecks ? netif-mode`; its text names `cfg.currentMode`.
- Proof: `netif-modes`, `netif-desktop`, `netif-wifi`.

### 8.9 Step 8: ARP keys (owner decision O6: yes, after P11)

- `services/netif/default.nix`: `sysctl.ipv4 = baseline.everyLink4 // baseline.arp4;`. Remove the probe option `clanServices.netif.arpHardening` and its block in `host.nix`.
- Suite: `netif-hostile` H19 (in the prototype, with the probe option on).
- Proof: `netif-hostile`; then every `k3s-*`, `rke2-*`, `routed-fabric*` and gateway suite (`vm-test --all`), because the key changes how every declared underlay link answers ARP. P11 result: §9.
- Alone in its PR, so a regression is one revert.

There is no step 9: `accept_dad = 0` was declined (O6).

Steps 1–4 are independent of the guard and each closes hostile gaps on its own. Step 6 must not be split.

Suite refactor rule (AGENTS.md "Test refactors must stay faithful") does not apply to steps 2, 4, 6: they change behaviour on purpose. Say so in each PR.

---

## 9. Probes, verified facts and open risks

Probe round of 2026-11-27, on the remote builder, with the prototype (`probes/netif/prototype.patch`). Result lines are in `probes/netif/runs/<suite>.<run>.txt`; the table of all of them is `specs/probes/2026-11-27/netif.md`. The probe suite `netif-probe-tx` (`services/netif/tests/vm/probe-tx.nix`) is throwaway: step 6 moves its cases into `netif-match` and `netif-dhcp`.

| Id | Question | Result | Evidence |
|---|---|---|---|
| P1 | Inside `ifstate.service` at **boot**: does `systemctl start --no-block netif-dhcpcd@x` run at once and get a lease inside `timeout`, without an ordering cycle? | **VERIFIED-VM.** Yes. Client started 1.1 s after the program; the run took 11.4 s (apply, lease, verify) and exited 0 with `committed`; 0 "ordering cycle" lines; `network.target` right after. The fallback unit of R1 is not needed | `netif-probe-tx`: `FINDING P1 …`; every DHCP suite boots this way (`netif-dhcp`, `netif-hotplug`, `netif-modes`) |
| P2 | Does `switch-to-configuration` start the inactive oneshot `ifstate.service` on every switch and wait for it? | **VERIFIED-VM.** Yes, also when nothing of the unit changed (a firewall-only switch): new `InvocationID`, exit 0, `committed`. A failing run makes the switch exit 4 | `netif-guard` `NETIF_GUARD_FIREWALL_OK`; `netif-probe-tx` `FINDING P2 …` |
| P3 | Do `systemd-sysctl` glob keys reach links present at boot and links added later? | **VERIFIED-VM.** Both. `eth0` (at boot, undeclared): 0. A link added while `default` was 1: 0 (udev runs `systemd-sysctl` for it). A link set to 1: 0 after a `systemd-sysctl` restart | `netif-hostile`: `FINDING P3 …` |
| P4 | With `net.ipv6.conf.default.accept_ra = 0`: do Wi-Fi under iwd and links under NetworkManager still get an IPv6 default? | **VERIFIED-VM for Wi-Fi**, both ways: in the NetworkManager mode (iwd as backend) and in the IfState mode (iwd alone) the Wi-Fi link gets its IPv6 default route. A hot-plug link gets its advertised default too (`netif-hotplug`). **NOT-RUN for a wired NetworkManager link with SLAAC**: no suite has one (`netif-desktop` uses a static IPv6 address, `netif-modes` IPv4 only) | `netif-wifi` (all seven subtests), `netif-hotplug`, `netif-desktop`, `netif-modes` |
| P5 | Without options 33/121/249: does dhcpcd install the router of a `/32` lease whose gateway is off-subnet? | **VERIFIED-VM.** Yes: `172.31.1.1 dev eth1 scope link` and `default via 172.31.1.1 dev eth1 proto dhcp`; the router answers. Such a link declares nothing extra | `netif-probe-tx`: `FINDING P5 …` |
| P6 | Does dhcpcd apply options 26 and 121 when they were never requested? Does `nooption` for 121 bring the router option back? | **VERIFIED-VM.** Yes to both. Unrequested 121: the route is installed. Unrequested 26: `mtu 576` on the lease's routes (not on the link). So `nooption` is the control, not tidiness. With `nooption classless_static_routes` and a lease that carries 121 and 3, the router of option 3 is installed | `netif-hostile`: `FINDING P6 …`, H09–H11, H18a |
| P7 | Does `resolvectl default-route <link> no` take effect at once and survive a carrier flap? | **VERIFIED-VM.** `no` at once; `no` again after a carrier flap of the hot-plug link; `yes` within 30 s when the last declared link lost its DNS. (The first build missed the last case: `set -f` also stopped the `/sys/class/net/*` loop that finds the hot-plug links. Fixed: the loop runs under `set +f`) | `netif-hostile`: H18b, `FINDING P7 …` |
| P8 | `systemd-escape --template=netif-dhcpcd@.service br-lan` | **VERIFIED-VM** with the link `wan-0`: unit `netif-dhcpcd@wan\x2d0.service` active, client running on `wan-0` | `netif-probe-tx`: `FINDING P8 …` |
| P9 | Does a rename by IfState (`match.mac`) emit a udev `move` with the new name? | **VERIFIED-VM.** `move kernel=wan-0 name=wan-0`. Match `KERNEL==` on `add|move` (the first sketch matched `NAME==`, which is the name a *rule* assigned). A link renamed back by hand had its lease 6.5 s later with no IfState run | `netif-probe-tx`: `FINDING P9 …` |
| P10 | Does the kernel copy `conf/default` to a new link for all baseline keys (veth, WireGuard, bridge ports)? | **VERIFIED-VM.** veth, veth as bridge port, dummy, bridge, WireGuard: all keys 0, `accept_ra` 0 | `netif-hostile`: `FINDING P10 …`, H20 |
| P11 | `arp_ignore = 1`, `arp_announce = 2` on a kube node's underlay link | **VERIFIED-VM for k3s with the routed fabric.** With both keys on every declared link: two nodes join, Cilium is healthy, a reapply changes nothing, a node reboot recovers (`k3s-join-netif`); LoadBalancer addresses by Node IPAM and the floating pool, the node firewall, a node death and ETP-Local withdrawal (`k3s-data-plane-netif`). **NOT-RUN:** rke2, the gateway suites, Cilium L2 announcements (this stack announces by BGP and has none), a `/32` cloud lease with the keys on | `k3s-join-netif`, `k3s-data-plane-netif` (both rc 0 with the probe switch on); `netif-hostile` H19 |

Decision-table evidence beside the probes (all `netif-guard`, real switches): good B commits; bad B with good L rolls back and is marked; bad B during an outage stays on L (H22); a good B during an outage is refused and commits by one restart afterwards; the override commits once (O5); a `proto bgp` default does not fail the guard (N-A3); a missing NIC stops nothing (N-A1, `netif-probe-tx`); a switch with a DHCP-only default reports success (N36, `netif-dhcp`); the last good bundle is per mode (`netif-modes`: `/var/lib/netif/guard/developer/good`, no `default` directory on a machine whose default mode runs NetworkManager).

Suites that ran green with the whole prototype (one at a time, `--rebuild`): `netif-guard`, `netif-probe-tx`, `netif-hostile`, `netif`, `netif-match`, `netif-hotplug`, `netif-dhcp`, `netif-modes`, `netif-vmhost`, `netif-wifi`, `netif-desktop`, `netif-v6only`. With the step-8 keys switched on as well: `k3s-join-netif`, `k3s-data-plane-netif` (so the sysctl glob, the transaction and the RA default also ran beside Cilium and FRR). Not run: every other suite (`vm-test --all` was out of scope), `check` (the nix-unit tests of the old guard fail until step 6 rewrites them).

Verified facts this design leans on. The ones marked **new** go into `documentation/docs/reference/upstream-facts.md` with the step named:

- **new, step 1** systemd-sysctl: a glob key (`net.ipv4.conf.*.accept_redirects`) is applied to every link that exists when `systemd-sysctl.service` runs, and again to each link that appears later, because `99-systemd.rules` runs `systemd-sysctl --prefix=…/<link>` on its `add` event. Suite `netif-hostile` (P3).
- **new, step 1** Linux: a new link takes every `net.ipv{4,6}.conf.default.*` value at creation (veth, bridge, bridge port, dummy, WireGuard). A link that existed before `default` was written keeps the old value: only a glob or a per-link write reaches it. Suite `netif-hostile` (P3, P10).
- **new, step 1** IfState 2.5.1 accepts `accept_redirects`, `secure_redirects`, `send_redirects`, `accept_source_route`, `arp_ignore`, `arp_announce` under an interface's `sysctl.ipv4` and `accept_redirects`, `accept_source_route`, `accept_ra`, `autoconf`, `accept_ra_defrtr`, `accept_ra_pinfo`, `accept_ra_rt_info_max_plen`, `accept_ra_mtu`, `accept_ra_min_hop_limit`, `use_tempaddr` under `sysctl.ipv6`, and a reapply with them changes nothing. Suites `netif-hostile`, `netif`.
- **new, step 2** radvd 2.21 refuses an interface whose `MinRtrAdvInterval` (default about a third of the maximum) is below 3 s or above 3/4 of `MaxRtrAdvInterval`: with `MaxRtrAdvInterval 4` alone it logs the error and sends nothing, and `systemctl start radvd` still succeeds. A rogue-RA fixture needs `MinRtrAdvInterval 3` and a control that the RA arrived. Suite `netif-hostile`.
- **new, step 2** Linux: with `accept_ra = 1` on a link and `accept_ra_defrtr = 0`, `accept_ra_rt_info_max_plen = 0`, `accept_ra_mtu = 0`, `accept_ra_min_hop_limit = 64`, an advertisement gives the prefix and a SLAAC address and nothing else. Suite `netif-hostile` (H16).
- **new, step 4** dhcpcd 10.5.2 applies options it never requested when a server sends them: option 121 as routes, option 26 as the `mtu` attribute of every route of the lease (the link's MTU is not changed). `nooption <name>` is what stops them. Suite `netif-hostile` (P6).
- **new, step 4** dhcpcd 10.5.2: a `/32` lease with a router outside the subnet gets a host route to the router and the default route, without option 121. Suite `netif-probe-tx` (P5).
- **new, step 4** dhcpcd 10.5.2 installs its routes with `proto dhcp`. Suites `netif-probe-tx`, `netif-hostile`.
- **new, step 6** systemd/NixOS: a oneshot unit without `RemainAfterExit` that `multi-user.target` wants is started again by every `switch-to-configuration switch|test`, changed or not, and the switch waits for it and exits 4 when it fails. Suites `netif-guard`, `netif-probe-tx` (P2).
- **new, step 6** systemd: a unit with `DefaultDependencies` started with `--no-block` from inside `ifstate.service` (`Before=network.target`, still activating at boot) runs at once; there is no ordering cycle as long as the started unit has no `After=ifstate.service`. Suite `netif-probe-tx` (P1).
- **new, step 6** udev: when a link is renamed after its `add` event (IfState `identify.perm_address`), udev emits `move` with `KERNEL` equal to the new name. `systemd-escape --template=` gives a usable instance for a name with `-`. Suite `netif-probe-tx` (P8, P9).
- **new, step 6** dhcpcd 10.5.2 takes about 10 s from start to a bound lease with its default settings (it probes the offered address by ARP). Suite `netif-probe-tx` (P1).
- **new, step 7** NixOS: `system.preSwitchChecks` runs before a `switch-to-configuration test` too and gets the action as `$2`; a failing check stops the switch before any unit is touched. A tmpfiles `f` line keeps the content the file got at boot. Suite `netif-modes`.
- IfState 2.5.1 schema has top-level `sysctl.all`/`sysctl.default` (not used).
- IfState writes `all.ipv6.optimistic_dad = 1` on every apply (`libifstate/sysctl/__init__.py`).
- IfState writes a link's sysctls before it changes the link's state (`link/base.py`).
- IfState only warns for a missing physical link and exits 0 (N15, already in the spec; seen again in `netif-probe-tx`).
- IfState leaves a main-table route with `proto bgp` in place on an apply (`netif-guard`, N-A3 case).
- `ifstate.service` from nixpkgs is `Type=oneshot` without `RemainAfterExit`, `After=network-pre.target`, `Before=network.target`, `TimeoutStartSec=2min`, and runs `udevadm settle --timeout=180` first.
- The guard on `main` keeps one `last-good` for all modes (`guard.nix:123`).

Risks:

- **R1 Boot-time coupling (P1): closed.** P1 showed no cycle and a lease inside the run. The one-unit shape is right; the `netif-verify.service` fallback was not needed and is not built. What remains is a cost, not a risk: `network.target` waits for the lease of a required DHCP default (about 10 s with dhcpcd's ARP probe).
- **R2 The "stay on L" rule refuses good deploys during an outage.** Accepted by the owner (O5). A planned move that L can never survive uses `guard.replaces`. If unplanned outages hurt in practice, the answer is an evidence-triggered single retry ("when L's obligations pass again, try B once"), never the old re-apply.
- **R3 RA default off breaks fixtures quietly.** A link that lost its SLAAC address fails late and far from the cause. Step 2 lists the fixtures found by running; the gateway, router and kube inventories were not run and must be read.
- **R4 `arp_ignore`.** Hardening, not an invariant. Its own PR (step 8). P11 found no effect on k3s over the routed fabric; rke2 and the gateway suites are that step's proof.
- **R5 `accept_dad = 0`: closed.** The owner said no (O6). Not built.
- **R6 Hostile Wi-Fi (T5).** iwd's DHCP client is not under §3.5. A hostile access point's lease can carry option 121. Out of netif's hands; a follow-up for the iwd preset (`lib/ownership.nix`): check iwd's `[IPv4]`/`[Network]` settings for a route-option switch, and add a rogue-lease verdict to `netif-wifi`. NOT-RUN.
- **R7 One YAML for all IfState writers.** A rollback re-applies the fabric's and the gateways' IfState objects of L too. That is today's behaviour and is kept; the guard never *judges* them. VERIFIED-VM for the ignore lists: a link of an owner that only the failed generation knows survives the rollback (`NETIF_GUARD_OWNERS_OK`).
- **R8 (new) Every deploy re-proves the network.** Because of P2, a deploy during an outage exits non-zero even when it changed nothing in the network (row 3, nothing touched, the generation is still activated). That is honest, but a deploy tool that treats a failed unit as a failed deploy will say "failed". The owner should know before step 6 lands.
- **R9 (new) A guard target that is down for its own reasons** (the deploy machine's sshd) turns every network change into `undecided` (row 5): the change is refused until the target is back. A TCP target is still the only defence against a spoofed layer-2 answer (H21). Choose targets that are as available as the gateway.
- **R10 (new) The time cost at boot** of a DHCP default (about 10 s before `network.target`). If it matters, `noarp` in the dhcpcd file removes dhcpcd's address probe; NOT-RUN.
- **R11 (new) An undeclared link that exists at boot keeps `accept_ra = 1`** (§3.4, residual). Harmless while the link is down.
