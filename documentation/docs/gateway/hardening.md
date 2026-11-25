# Hardening review

On 2026-11-25 the services were read again with one question: **what
breaks in the two setups you plan to run?**

1. A cloud cluster of three managers. Two or more are NAT gateways.
2. A home box that takes the ISP line, is the router, and is a
   Kubernetes node.

Stability counts more than fast failover. The contract version is
`specs/gateway.md` §16.

## The short answer

- **The NAT gateway design held.** Three holes were found and closed.
- **The router did not fit your home box.** It is rebuilt to share a
  machine with a cluster, and a new test proves it.
- **The cluster network has three stability gaps** that are older than
  this work. They are listed, not changed: each one touches every
  cluster test and needs your word first.

## Found and fixed

| Where | What was wrong | Now |
|---|---|---|
| Router | It switched the NixOS firewall off and dropped all it did not know. On a node, the cluster's firewall rules vanished and the cluster's own traffic was blocked | It judges its own ports only; both firewalls run. See [the router page](router.md) |
| NAT gateway | A client could reach the gateway's own IPv4 ports through the translator | Refused and counted |
| NAT gateway | A client moved to whatever prefix a beacon named | Only a gateway's own prefix is believed |
| NAT gateway | A changed prefix was never applied; the gateway then failed its own health check until a reboot | Applied at the next start |
| NAT gateway | A CLAT address written in another spelling made the unit fail at every start | Addresses are compared as addresses |
| Router | A zone of two ports was half set up; a zone port accepted router advertisements; the DHCP range could hold the router's own address | Each is refused before a deploy |
| Clusters | Pods on a normal node (not a gateway, not a NAT client) could not reach the internet: Cilium was not attached to the node's uplink. The new router test found it | The cluster attaches Cilium to every node's default-route link |
| NAT gateway | One missing network card anywhere on the machine stopped the translator | It starts whenever its own links exist |
| NAT gateway | A setup of gateways only (no client) was refused | Allowed |
| Tests | One 37 minute test held everything | Two tests: what it does (6 min), and what it does when something fails |

## Your answers from the round before

1. Health check over **windows**, not "in a row": accepted.
2. The stray-packet check bounds **time**, not a count: accepted.
3. The long test is **split**.

## Found, not fixed: yours to decide

Ranked by how much they can hurt. All were read in the code; none was
run.

### Stability of the cluster network

1. **A restart of Cilium on a node looks like a dead node.** Traffic
   keeps flowing, but the node's routes are withdrawn from every other
   node until Cilium is back. Fix: BGP graceful restart between Cilium
   and FRR, and a test that restarts Cilium under traffic.
2. **A restart of FRR takes a manager off the cluster network.** etcd
   and the API ride that network. Restarting FRR on all three managers
   at once can cost quorum for some seconds. Fix: graceful restart
   there too. Until then: deploy an FRR change **one manager at a
   time**.
3. **Members in different places use LAN timers unless you set
   `site`.** Every member's `site` is `"default"`, so two machines in
   different data centres, or home and cloud, expect an answer within
   0.9 s. A second of jitter drops a healthy link. Fix: slow timers
   unless both ends name the same site. Until then: **set `site` on
   every member.**

### Clusters

4. **A reinstalled first manager starts a second cluster.** It finds
   no data, has the same certificates, and the other nodes accept it.
   Until fixed: before reinstalling the first manager, move
   `clusterInit` or join it as a normal server.
5. **A changed Cilium setting reaches no running node.** A manager
   that becomes a gateway masquerades on its uplink only after its
   Cilium restarts. Restart it by hand, one node at a time.
6. **The ClusterMesh certificates unit restarts its server at every
   run**, so each restart of the first manager drops the mesh sessions.
7. **One Cilium operator** in a three-manager cluster. While its node
   is down, no new LoadBalancer address and no new pod range.
8. **The route limit on the Cilium session** drops the whole session
   for 10 minutes when crossed (4 096 routes).
9. **Pods reach hosts in a `10.x` network with their pod address.**
    Avoid `10.x` for a home LAN or a cloud private network.

### Machines

10. **netif's rollback restores the link file only**, not a DHCP
    client setting.
11. **A missing certificate secret is skipped, not refused**: the
    server then makes its own certificates.
12. **`kubectl exec` and `logs -f` through the load balancer end after
    one idle minute.**

### Smaller

13. A leaf of the cluster network can pass routes on.
14. The router reads an internal netif option.
15. Every router boot retires the current prefix for a few seconds.
16. A rate limit whose table is full stops limiting (more than 65 535
    live addresses in one client prefix).

## What was checked and is sound

- Secrets: no key or token reaches the Nix store.
- Node addresses: the public IPv4 and the translator's private
  addresses never become node addresses or NodePort addresses.
- The cluster network accepts no default route and opens BGP only on
  its own links.
- A deploy target on a cluster-network address is refused, so a change
  there cannot lock you out.
- The translators' namespaces and links are declared, so a network
  reapply keeps them.
- A gateway that withdraws its beacon keeps translating: when every
  beacon is gone, clients stay where they are.
