# Use cases

Every machine class netif must serve, and what each needs. A use case is
finished when home runs it on a real machine. Nothing runs netif on real
hardware yet; that waits for the contract gate ([plan](plan.md)).

| | Machine | Needs from netif | Phase |
|---|---|---|---|
| U1 | **Steam Deck** | default boot: gamescope with NetworkManager, Wi-Fi and wired ad hoc, Tailscale. `developer` mode: IfState, Wi-Fi through iwd, a dock, Tailscale, Docker or Podman, routed access to pod and Service IPs | N2, N4, N7 |
| U2 | **kamrui-h1** | default boot: KDE desktop with NetworkManager. `developer`: as the Deck. `kubernetes`: plus a single-node k3s server with ClusterMesh | N2, N4, N7 |
| U3 | **Home router** | four SFP+ ports and one 10G RJ45 port, one of them WAN; prefix delegation; zones for the router module; the lockout guard | N3b, N5, N8 |
| U4 | **Headless servers** (euc-hel-0) | a stable address, path MTU, untrusted links, the lockout guard | N3b, N8 |
| U5 | **VM host with provider MACs** (Hetzner Robot) | a bridge that sends from the uplink's MAC, guest ports left to the hypervisor | N7 |
| U6 | **Cloud VMs** (Hetzner Cloud, AWS, GCP, Azure) | DHCP on two NICs with one default route, path MTU, NICs found by device path, no cloud-init networking | N3b |
| U7 | **Proxmox VMs** | static or DHCP underlay, MTU for tunnel mode | N3b |
| U8 | **Bare-metal Kubernetes nodes at home** | as U4, on the LAN behind the router | N3b, N8 |
| U9 | **Machines behind a gateway** | a static default gateway; the gateway's NAT is not netif's | N3b |
| U10 | **One machine, several roles** | modes that differ in kind: a server in one, a gamescope box in another | N4 |
| U11 | **VM tests** | suites here; later a fixture other repos can import | after the contract gate |

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
to the private network.

**Machines behind a gateway.** For netif this is one static default
gateway, often on-link. The machine doing the NAT is covered by a
separate gateway service, planned later.
