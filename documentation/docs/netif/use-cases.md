# Use cases

Every machine class netif must serve, and what each needs. A use case is
finished when home runs it on a real machine. Nothing runs netif on real
hardware yet; that waits for the contract gate ([plan](plan.md)).

| | Machine | Needs from netif | Phase |
|---|---|---|---|
| U1 | **Steam Deck** | default boot: gamescope with NetworkManager, Wi-Fi and wired ad hoc, Tailscale. `developer` mode: IfState, Wi-Fi through iwd, a dock, Tailscale, Docker or Podman, routed access to pod and Service IPs | P2, P4, P7 |
| U2 | **kamrui-h1** | default boot: KDE desktop with NetworkManager. `developer`: as the Deck. `kubernetes`: plus a single-node k3s server with ClusterMesh | P2, P4, P7 |
| U3 | **Home router** | four SFP+ ports and one 10G RJ45 port, one of them WAN; prefix delegation; zones for the router module; the lockout guard | P3b, P5, P8 |
| U4 | **Headless servers** (euc-hel-0) | a stable address, path MTU, untrusted links, the lockout guard | P3b, P8 |
| U5 | **VM host with provider MACs** (Hetzner Robot) | a bridge that sends from the uplink's MAC, guest ports left to the hypervisor | P7 |
| U6 | **Cloud VMs** (Hetzner Cloud, AWS, GCP, Azure) | DHCP on two NICs with one default route, path MTU, NICs found by device path, no cloud-init networking | P3b |
| U7 | **Proxmox VMs** | static or DHCP underlay, MTU for tunnel mode | P3b |
| U8 | **Bare-metal Kubernetes nodes at home** | as U4, on the LAN behind the router | P3b, P8 |
| U9 | **Machines behind a gateway** | a static default gateway; the gateway's NAT is not netif's | P3b |
| U10 | **One machine, several roles** | modes that differ in kind: a server in one, a gamescope box in another | P4 |
| U11 | **VM tests** | suites here; later a fixture other repos can import | after the contract gate |
| U12 | **Gaming desktop** | default boot: KDE with NetworkManager on a static wired LAN, no Wi-Fi. `developer` mode: IfState, the same static link, Tailscale, a fabric leaf | P2, P4 |
| U13 | **IPv6-only cloud machine** | one public IPv6 link, no IPv4 on any NIC; reaches IPv4 through the [NAT gateway](../gateway/nat-gateway.md) | planned |
| U14 | **Cloud gateway** | as U6, with a public IPv4; carries the NAT gateway role | planned |
| U15 | **On-prem site with two carriers** | two routers, each with its own WAN | planned, design only |
| U16 | **Router with a backup WAN** | U3 plus a second WAN link; one default route per WAN | planned |

## What is proven, per machine (2026-11-18)

Your list of machines from 2026-11-18, and the VM test that proves each
part. "Open" is what no test shows yet.

| Machine | Part | Proven by | Open |
|---|---|---|---|
| **kamrui-h1** | default: KDE, NetworkManager, Tailscale | `netif-desktop` | Steam itself (cannot run in a VM) |
| | joins unknown Wi-Fi and wired networks, any mode | `netif-wifi`, `netif-desktop` (wired, NetworkManager), `netif-hotplug` (dock, IfState) | |
| | `developer`: fabric leaf with FRR and WireGuard in one mode | `netif-modes` | reaching another cluster's pod and Service IPs from that leaf, in one test |
| | `developer`: Tailscale, Docker, Podman, virtual machines | `netif-registry`, `netif-containers`, `netif-vmhost` | all of them on one machine at once |
| | `kubernetes`: a single-node k3s with Cilium in one mode | `k3s-modes` | that cluster in a ClusterMesh while its machine roams (N27) |
| | ClusterMesh, native routing with FRR | `k3s-clustermesh*`, `k3s-data-plane-netif` | |
| **Steam Deck** | default: NetworkManager, Tailscale, Wi-Fi and wired ad hoc | `netif-desktop`, `netif-wifi` | gamescope and Steam's own network settings: one check on the Deck |
| | `developer`: fabric leaf, Tailscale, WireGuard, a dock | `netif-modes`, `netif-registry`, `netif-hotplug` | |
| **euc-hel-0** (Hetzner bare metal) | RKE2 with Cilium on netif, FRR, static addresses | `rke2-data-plane-netif` | |
| | ClusterMesh, Tailscale, WireGuard | `rke2-clustermesh*`, `netif-registry`, `routed-fabric-netif` | |
| | guests with their own public address and MAC | `netif-vmhost` (bridge MAC, VLAN members, guest ports kept) | a real KubeVirt with Multus guest |
| | a bad change does not lock you out | `netif-guard` | |
| **Gaming desktop** | default: KDE, NetworkManager, static LAN | `netif-desktop` (static IPv4 and IPv6 profile) | |
| | `developer`: fabric leaf, Tailscale | `netif-modes`, `netif-desktop` | |
| **Home router** | WAN by DHCP with prefix delegation, zones, untrusted WAN | `netif-dhcp` | the [router service](../gateway/router.md) itself (NAT, DHCP server, advertisements): phase P5, in this repo |
| | fabric border, ECMP towards Kubernetes nodes | `routed-fabric`, `k3s-data-plane`, `rke2-data-plane` | the router as a Kubernetes node behind its own NAT, in one test |
| **Cloud VMs** | DHCP (preferred) and static addresses, two NICs, NICs by slot | `netif-dhcp`, `netif-match`, `netif` | a run on a real cloud |
| **Any cluster** | Cilium native routing with FRR | `k3s-data-plane-netif`, `rke2-data-plane-netif` | |
| | Cilium tunnel mode without FRR | `k3s-clustermesh-tunnel`, `rke2-clustermesh-tunnel` and the single, join and HA tests | tunnel mode on a netif underlay (those tests use the bare fixture) |

One point differs from how you wrote it on 2026-11-18: kamrui-h1's
`developer` and `kubernetes` modes use IfState, not NetworkManager. The
fabric's WireGuard links and FRR routes can only be rendered by IfState.
Joining unknown Wi-Fi and wired networks works in those modes too
(`iwctl` or an iwd front end, and the hot-plug owner). If you want
NetworkManager there, that is a redesign: say so.

Across all of them:

- **Tailscale** is supported in every mode. NetBird and Cloudflare WARP
  are planned after the contract gate.
- **WireGuard** is `routed-fabric` and `wireguard-mesh` only. netif has no
  hand-written WireGuard links.
- **Docker and Podman** get one `containers` preset.

## Notes per use case

**Steam Deck and kamrui-h1.** The default mode uses NetworkManager, so
Steam's network settings and the KDE applet work. Developer and
kubernetes modes use IfState, because the fabric needs it. Wi-Fi is iwd's
in every mode ([Wi-Fi](wifi.md)).

**kamrui-h1 as a Kubernetes node.** Its underlay changes with every café.
Its node address is therefore its fabric loopback, never a Wi-Fi address,
and ClusterMesh runs over the fabric. The design is a SPEC.md topic; netif
only has to accept an underlay with no static address.

**Home router.** Wi-Fi for the house comes from separate access points on
the LAN. The router has no radio, and netif does not do access points.

**VM host.** IfState gives a bridge a generated MAC. A provider that
filters by MAC would then drop the host's own traffic. netif pins the
bridge to its uplink's MAC, and leaves ports it did not declare to the
hypervisor. The guest's public address and its provider MAC are set in the
guest and the hypervisor, not in netif.

**Cloud VMs.** Two DHCP NICs are normal. One keeps the default route; the
other sets `defaultRoute.ipv4 = false` and keeps its lease and the routes
to the private network. A probe on 2026-11-16 showed exactly that: the
second NIC kept its address and a route the DHCP server pushed, and
installed no default.

A cloud NIC is found by its slot (`match.path`, for example
`pci-0000:00:03.0`), because its MAC is unknown before the VM exists.
netif does this with a udev rename, not with IfState: for the virtio
NICs most clouds use, IfState can only see a counter (`virtio3`) that
changes when a disk is added.

**Machines behind a gateway.** For netif this is one static default
gateway, often on-link. The machine doing the NAT is covered by a
separate gateway service, planned later.
