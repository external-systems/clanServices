# Review: the case against the work so far

On 2026-11-21 four reviewers read every new test against the design
and tried to break it. The contract version is `specs/gateway.md` §13.

## The short answer

- The **direction holds**: an IPv6-only underlay, clusters that stay
  dual-stack inside, Jool in its own namespace, a router built on
  netif's zones. No review finding argues against one of these.
- The **evidence was weaker than the summaries said**. Nineteen claims
  did not hold in the code. All nineteen are fixed and now tested.
- The **biggest risk left is not a mechanism**. Everything runs in
  test stand-ins. No `router` or `nat-gateway` service exists.

## What was wrong and is fixed

| Area | What was wrong | Now |
|---|---|---|
| NAT gateway | anyone could ping the IPv4 internet through it | only declared clients, every protocol |
| NAT gateway | a gateway that lost its IPv4 kept answering DNS | it stops DNS; clients move in 8 s |
| CLAT | its health check trusted a file and broke on common prefixes | it reads the translator itself; all prefix shapes work |
| CLAT | one dead test address moved every machine | it stays when no gateway answers |
| Two WANs | a firewall reload while on the backup sent traffic into the dead WAN | the router reads the active WAN from the ruleset each round |
| Two WANs | a connection to the backup's address was answered through the primary | answers leave by the WAN the connection came in on |
| Two WANs | tested with the firewall off | firewall on; the needed setting is written down |
| Two WANs | the backup modem's own web page was unreachable | reachable from the router and the LAN |
| Router | devices with a stale address waited 5 s per connection | they get an error in 0.05 s and try the next address |
| Router | zone `servers` was told a DNS server that did not exist | each zone has its own |
| Router | a prefix change during boot could be missed | the hook checks again before it ends |
| Router | a failed step left old settings for good | the next run repairs it |
| netif | the prefix file could list a dying prefix first, and was never removed | only usable prefixes; removed when the ISP takes the prefix away |
| Clusters | NodePorts were open past the node firewall | only on node addresses (D69) |
| Clusters | both DNS copies on one node | one per node (D70) |
| Clusters | pod and Service ranges were invisible to the overlap checks | they are checked |
| Tests | the "three servers, one dies" test shut the server down politely and never brought it back | a real crash, then the server returns |

## Yours to decide

1. **Stop probing. Build the services.** Recommended order: the NAT
   gateway and the CLAT first, because the cluster tests already need
   them; then the router with one WAN.
2. **Freeze what is design only**: IPv6-mostly, several routers, your
   own address block, flow records. Written down, not built, until the
   first two services pass on real code.
3. **Is DNS64 worth it on your own machines?** A machine with a CLAT
   does not need it. DNS64 makes every name lookup depend on a gateway.
   Recommended: a CLAT on every client, DNS64 as an option.
4. **A client is known by its address only.** Someone who can fake a
   client's address can send UDP through your gateway. Recommended: a
   rate limit per client. Stronger: a WireGuard tunnel to the gateway.
5. **Health checks need several targets**, in different networks.
6. **A public Service at home answers from one address and calls out
   from another.** A game server that registers itself is listed under
   the wrong address.
7. **Two WANs is not ready to freeze.** Under 30 % packet loss it moved
   0 to 4 times a minute. Build it after one WAN works.
8. **One kernel module (Jool) holds every cloud machine.** The check
   should look at the kernels your machines really run.
9. **An IPv6-only machine with broken IPv6 has no way in** but the
   provider's console. Keep netif's guard on such machines.

10. **On an IPv6-only node, Cilium must also be attached to the
    machine's network card.** Without it, pods cannot reach IPv6
    addresses outside the cluster and cannot resolve outside names.
    The tests set this by hand. It should become a rule the cluster
    service applies by itself.

## Found, tested, not fixed yet

- After a node's CLAT link is made again, pod IPv4 to the outside is
  down for 9 seconds (routed fabric) or 17 to 18 seconds (mesh).
- On the routed fabric, a few packets between nodes take the wrong
  path at boot, before routing is up. The gateway refuses them.

## Still not proven

- Any of this on service code, real hardware or a real ISP.
- Two WANs with IPv6 learned from the ISP; a dead backup; both dead.
- A short blip of the old prefix on every router boot.
- A Service behind the router reaching its own public address.
- A 2000 byte UDP packet through the CLAT (most fail; not understood).
- How often tests fail under load: still one full run per round.

## What the owner decided (2026-11-23)

The contract version is `specs/gateway.md` §14.

- **Build the services now.** No new probes. NAT gateway and CLAT
  first, then the router with one WAN. Existing tests stay; tests of
  stand-ins switch to the service code.
- **Freeze the design-only parts:** IPv6-mostly, the open points of two
  WANs, several routers, flow records, owned address space.
- **The CLAT is the default path.** DNS64 is an option for a machine
  that cannot run the CLAT.
- **A rate limit per client at the gateway.** Kube nodes get a higher
  tier. It trusts the machine, not the workloads on it: the gateway
  sees one address per node.
- **Cilium's network cards are filled in by k3s and RKE2** (D71), from
  netif, never a VPN link.
- **Native routing only** (D72): tunnel mode and `wireguard-mesh` go.

How the open findings will be closed:

- **The CLAT blip:** accepted; fixed if the CLAT can avoid making its
  link again.
- **A healthy gateway never looks sick:** three or more health targets
  in different networks; sick only when all fail, several rounds in a
  row.
- **Two WANs: stable over fast.** Move only when every target fails;
  move back only after minutes of health. At 30 % loss the test
  expects zero moves.
- **A backend reaching its own public address:** the router also
  rewrites the source of such a packet from inside the LAN, so the
  answer comes back through the router.
