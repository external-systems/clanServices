# Retrospective and hardening

Written on 2026-11-17, after the proof rounds and before the next code
phase (P3b). It answers three questions:

- Which decisions rest on thin proof?
- What would make the network more stable?
- What would make it easier to use?

**Update, same day:** you adopted all twelve ideas. They are now
decisions N31 to N42 in `specs/netif.md`. H1, H2, H4 and H8 are built
and tested, and H3 in part (see [Plan and evidence](plan.md)). The
others have a phase.

Each idea has a label (`H1` to `H12`). The agent version is
`specs/netif.md` §11.

## Threat model (2026-11-27)

The target design (`specs/design-netif.md`) names who may attack a
netif machine and what they must not achieve. It is decision N46.

- A hostile host on a LAN of the machine may send any frame. It must
  not move a route, add an address or a route, answer DNS for all
  names, or open a port.
- A rogue DHCP server or router-advertisement sender gets an address
  and, on the link that owns the default route, the gateway. Nothing
  more.
- A guest on a guest-ports bridge gets nothing on the host.
- A bad deploy must not lose the path that worked before it, also when
  the machine is booted in another mode.

Limits: on the link that owns the default route its DHCP server picks
the gateway; a spoofed ARP answer passes a layer-2 check (a TCP target
does not); ARP poisoning of the real gateway is the switch's to stop.

The suite `netif-hostile` proves each part as it is built. The first
part (N47): no link takes or sends an ICMP redirect or accepts a
source-routed packet.

## Decisions with thin proof

These hold today. Each has less proof behind it than the rest of the
contract.

| Decision | The weak spot | What settles it |
|---|---|---|
| dhcpcd 10.5.2 on netif links | Leases, DNS and link flaps are proven on 10.5.2. Prefix delegation is not: its code changed in 10.5 | the delegation tests in `netif-dhcp` |
| Two dhcpcd packages | Machines on the normal NixOS DHCP setting keep 10.3.2 and its four security holes until nixpkgs ships 10.5 | wait for nixpkgs, or change the DHCP service and the package together in the modules repo |
| dhcpcd sets the link-local address on DHCPv6 links | The setting stays after dhcpcd stops. A link that changes from DHCPv6 to static may have no link-local address until reboot | one probe |
| The DNS watcher | One small background process restores DNS after a link flap. Nothing was tested for the watcher itself dying | restart it automatically, and kill it once in the test |
| Guest ports on VM hosts | The list of guest ports is read just before an apply. A guest that starts in that moment loses its port | H6 |
| Podman's namespaces | netif keeps namespaces named `netns-…`. That name is Podman's internal choice and can change | the container test checks the name |
| The lockout guard | It checks that the gateways answer. That does not prove you can still deploy | H5 |
| Cloud NICs by path | Proven on one virtual machine type. Not confirmed by you yet | your yes; use the MAC where the provider fixes it |
| Links untrusted by default | It closes ports on every link at once. It is the likeliest way to lock yourself out in the whole plan | ship it alone, with a test that SSH still answers |
| Modes | Checked by evaluation only. No machine has booted two modes | the modes test |

## Stability

**H1. Watch dhcpcd.**

- Today netif starts dhcpcd in the background and nothing watches it.
- If it crashes, the link has no lease until the next apply.
- It runs as root with no sandbox and reads packets from networks you
  do not control.
- Idea: one systemd unit per DHCP link. systemd restarts it, limits
  what it can touch, and `systemctl status` shows its state.

**H2. Say what "online" means on a DHCP link.**

- Today the machine counts as online when IfState has finished. A DHCP
  link may have no address yet.
- A Kubernetes node or a Tailscale login that waits for "online" can
  then start too early.
- Idea: mark the links that must have an address, and wait for them
  for up to 30 seconds. After that the machine boots anyway and logs a
  warning, so a pulled cable never blocks a boot.

**H3. Keep the same DHCP identity.**

- The ISP recognises the router by an id that dhcpcd stores on disk,
  and each link by an id taken from its MAC address.
- A reinstall or a changed MAC looks like a new customer. The ISP then
  hands out a different IPv6 prefix and the whole home network gets
  new addresses.
- Idea: netif sets both ids from fixed values.

**H4. Come back faster after an outage.**

- After the ISP or a switch was down, dhcpcd waits up to 64 seconds
  between tries.
- dhcpcd 10.5 can cap that wait. Idea: 16 seconds.

**H5. A wider lockout guard.**

- Also check addresses you name, such as the machine you deploy from.
- Also run after a firewall change.

**H6. Close the guest-port gap.**

- Ports with the usual names (`vnet…`, `tap…`) are safe already.
- For other names: after each apply, compare the bridge's ports with
  the list from before and fail loudly if one is gone.

**H7. Notice drift.**

- A timer asks IfState every few minutes: "would you change
  anything?" It never changes anything itself.
- If the answer is yes, some other program is writing to a link netif
  owns. That is the kind of fault every probe round found first.

**H8. Know which versions were proven.**

- Two findings this month depended on a package version.
- Idea: record the versions each test passed with. Warn when a
  package update moves IfState, dhcpcd, iwd or systemd past them, so
  it is clear which tests to run again.

**H9. DNS from router advertisements.**

- A wired link that gets IPv6 only from advertisements has no DNS
  today.
- Either test `rdnssd` for that job, or warn at build time and point
  to the static DNS option.

**H10. Keep the probes in the repo.**

- The probes behind the evidence tables live in an ignored folder on
  one machine. Nobody else can rerun them.
- Idea: a `probes` folder beside the tests. A probe is deleted once a
  real test covers it.

## Ease of use

**H11. One status command.** `netif-status` on the machine shows, per
link: who owns it, its addresses and where each came from, how long
the lease lasts, its DNS servers, and which link holds the default
route. Then the mode, the last apply and the guard. Today that takes
five tools.

**H12. Errors that say what to do.** Every netif error names the
link, the rule it broke and the option to change. A `netif-preview`
command shows only what the next apply would delete or switch off.

## What only real hardware can show

These go on the checklist for the first real machines:

- suspend and resume on the Deck and kamrui-h1;
- a pulled cable and a rebooted switch;
- a USB dock whose network port gets a new name;
- roaming between two real Wi-Fi access points;
- an ISP that changes the IPv6 prefix.

## What went wrong in the proof rounds

- **Three "broken" findings were faults in the test setup.** They were
  written down one round before they were corrected. New rule: a
  "broken" finding needs one run that shows the test setup works.
- **The last package update was checked with one test of 24.** The
  next one runs all of them.
- **Swapping dhcpcd for every machine would have cut DHCP on the
  machines that do not use netif.** Every netif test passed. Only a
  test of the normal NixOS DHCP service showed it, just before the
  merge. New rule: a package that NixOS itself also uses is not
  swapped without a test of the NixOS service.
- **Small slips in probe scripts cost reruns.** They are now listed in
  [Stage-0 probe lessons](../guides/stage0-probe-lessons.md).

## Suggested order

P3b is large. The plan now cuts it into five slices, each merged with
its own passing test: dhcpcd, DNS, routes, firewall, the rest.

For the first slice, the ideas that fit best are H1, H2, H4, H8 and
H10.
