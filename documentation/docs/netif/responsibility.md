# What netif is responsible for

netif answers one question: **which links does this machine have, and how
does each one get its addresses, routes, DNS and firewall trust?**

Everything else belongs to something else. This page is the human version
of decision N20 in the contract.

## netif owns

| Thing | How |
|---|---|
| Network cards, VLANs, bonds and bridges: that they exist, their name, MTU, MAC and state | IfState, or NetworkManager profiles in NetworkManager modes |
| Static addresses; DHCP, DHCPv6 and prefix-delegation clients; accepting router advertisements | IfState, and dhcpcd started by netif |
| Default routes, static routes, policy routing on the underlay, route metrics | IfState, dhcpcd, netif's link hook |
| DNS servers per link | a netif unit that writes systemd-resolved |
| Whether the firewall trusts a link, and a zone label | NixOS firewall settings; read-only facts |
| The ownership registry and the promise that a reapply changes nothing | `clanServices.networking.owners` |
| Which network manager a mode uses | the `modes` service |
| The lockout guard on headless machines | netif |
| Facts for other services: link names, zones, MTU, endpoints, the deploy target | exports and read-only options |

## netif never owns

| Thing | Who does |
|---|---|
| Joining Wi-Fi, and DHCP and roaming on Wi-Fi | iwd |
| NAT, port forwarding, firewall rules beyond "trusted or not" | the router module, or a gateway service, built on netif's zones |
| DHCP server, router advertisements for others, DNS server | the router module in `modules` |
| WireGuard tunnels, BGP, fabric addresses | `routed-fabric`, `wireguard-mesh` |
| Pod and Service networking, node addresses | `k3s`, `rke2`, Cilium |
| VPN clients | Tailscale, and later NetBird and Cloudflare WARP |
| Container and VM ports | Docker, Podman, the hypervisor |
| Hostname, `/etc/hosts`, mDNS, time, proxies | plain NixOS configuration |
| Desktop, Steam, KDE | the machine's configuration in home |
| Network before the root disk is unlocked | nobody: out of scope |

## Three rules

1. **Ask netif.** A module that needs a link, an address or a route
   declares it through netif in the inventory. It never writes IfState
   settings, NetworkManager profiles or `networking.interfaces` itself.
2. **Register what you create.** A daemon that creates links, routes,
   rules or namespaces registers an owner, so IfState leaves them alone.
   See [Ownership and VPNs](ownership.md).
3. **netif renders no NAT and gives a zone no meaning.** A zone is a
   label that the router module or a gateway service reads.

## Where a change goes

| You want to | Change |
|---|---|
| add a NIC, VLAN, bond or bridge to a machine | the machine's netif instance in the inventory |
| give a second NIC a lease but no default route | `links.<name>.defaultRoute` (planned) |
| add NAT or a port forward | the router module or gateway service, never netif |
| run a new VPN client | a registry owner; a preset once it is proven |
| run VMs with their own public addresses | a netif bridge with guest ports; the guest's address is set in the guest |
| add a mode to a machine | the `modes` service |
| reach pod IPs from a laptop | `routed-fabric`, in an IfState mode |
