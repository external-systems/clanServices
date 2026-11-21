# Retrospective: what is not proven yet

Written on 2026-11-21, after the probe rounds. The contract is
`specs/gateway.md` §12. This page is the short version.

## How strong the evidence is

- Every probe ran once, alone, on an idle builder. The timings are
  single samples.
- A probe checks little by itself. Its result was read from the log. A
  result is safe only once a real suite asserts it.
- All clients were Linux. Phones, Windows, consoles and NetworkManager
  may treat a prefix change differently.
- Traffic was TCP, ping and DNS. Large UDP, fragments and path MTU
  discovery through a translator are untested.
- Four claims still come from memory and need a source or the hardware:
  Windows and DHCP option 108, the Nintendo Switch and IPv6, Headscale
  behind Cloudflare, the X710 and SFP+ modules.

## The risks that matter most

1. **GitHub has no IPv6.** An IPv6-only machine cannot fetch a flake
   input or a `ghcr.io` image without a NAT gateway. The gateways are a
   dependency of every deploy. Never update both at once.
2. **Jool is a kernel module outside the kernel tree.** A kernel update
   can break every gateway and every CLAT. Check that it builds on every
   update of the package set.
3. **The CLAT's health check can flap** between two gateways, and every
   move stalls open connections.
4. **A health check tests the gateway, not the internet behind it.**
5. **One public IPv4 address carries about 64,000 connections** per
   protocol.
6. **Several programs write firewall tables** and no rule says who owns
   which.
7. **A WAN failover drops every connection on the router**, also the
   ones that never used the dead WAN.
8. **Deploying an IPv6-only fleet needs IPv6 where you deploy from.**
   Keep an IPv4 path to the gateways and the Headscale machine.

## The two Cilium modes

| What is tested | Routed fabric, native routing | WireGuard mesh, tunnel |
|---|---|---|
| One server, a second node | yes | yes |
| Three servers, one dies | yes, since 2026-11-21 | yes |
| LoadBalancer pools, Node IPAM, firewall | yes | **no** |
| netif renders the underlay | yes | **no** |
| ClusterMesh, all three kinds | yes | yes |
| A cluster inside a network mode | **no** | yes |
| IPv6-only network cards | probe | probe |
| Pod IPv4 through a CLAT | probe | probe |

The plan: one test body takes the transport as an argument and runs the
same script on both. The three-server suite on the fabric is done and
passed first time, for k3s and rke2. Next: LoadBalancer pools and the
firewall on the mesh.

## Making the suites more stable

- Replace fixed waits with waits for a condition.
- Print the versions of the kernel, Jool, Cilium, FRR, IfState and
  dhcpcd at the start of every suite.
- Run every suite before a merge that touches netif or the shared base.
- Keep a record of which suites needed a second run under load.
- Add a phase to every gateway suite: reapply the network, reboot, and
  assert everything again.
