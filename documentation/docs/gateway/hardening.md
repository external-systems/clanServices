# Hardening review

On 2026-11-25 the services were read again with one question: **what
breaks in the two setups you plan to run?**

1. A cloud cluster of three managers. Two or more are NAT gateways.
2. A home box that takes the ISP line, is the router, and is a
   Kubernetes node.

Stability counts more than fast failover. The contract version is
`specs/gateway.md` §16.

## Round G11 (2026-11-26): the whole network stack

A second review read netif, routed-fabric, k3s, rke2 and the gateway
services together. It scored `main` 72 of 100 and found 50 defects,
most of them in what happens *after* something fails: a rollback, a
restart, a re-apply, a failover. You approved every fix. All are in.

- **Lockout guard (netif).** It could record a bad network as good,
  leave a DHCP link with no address after a rollback, and pass with
  nothing to check. Fixed; it now also re-checks a rollback and puts
  the new network back when the fault is outside the machine.
- **Secrets by role.** Agents no longer hold the server join token or
  the ClusterMesh keys.
- **Ports by source.** The cluster ports answer members and pods only;
  etcd answers servers only. Fabric links are no longer trusted.
- **First server fails closed.** A first server that cannot reach its
  peers does not start a second cluster. To force a start, create
  `/var/lib/rancher/<distro>/server/allow-new-cluster-<instance>`.
- **Deploys reach the cluster.** A changed bundle is applied again,
  removed objects are pruned, and failed applies stop retrying.
- **Certificates.** The admin kubeconfig now lasts one year; RKE2 no
  longer copies a new CA into a running cluster (it would not start).
- **Fabric.** Pod routes cross between dedicated spines; hostname
  endpoints are refused; a full FRR restart is documented as a race.
- **Gateways.** The CLAT follower survives a failed restart and moves
  under packet loss; the port pool is protected and its use is shown.

Out of this round: the k3s/rke2 de-duplication and the
`externalTransit` probe, each its own PR. Contract tables: SPEC.md
round 58, `specs/netif.md`, `specs/gateway.md` §17.

## The short answer (round G9/G10)

- **The NAT gateway design held.** Three holes were found and closed.
- **The router did not fit your home box.** It is rebuilt to share a
  machine with a cluster, and a new test proves it.
- **The cluster network had three stability gaps** that are older than
  this work. You said to fix them, and the 13 smaller findings with
  them. All 16 are fixed (round G10, below). All 48 tests pass.

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

## The 16 older findings: all fixed (round G10)

You answered: fix all of them now. Nothing is deployed, so nothing
breaks. Contract: `specs/gateway.md` §16.3 and SPEC.md round 57.

### Stability of the cluster network

| # | What was wrong | Now | Proof |
|---|---|---|---|
| 1 | A restart of Cilium on a node looked like a dead node: its routes vanished from every other node | BGP graceful restart between Cilium and FRR. The routes stay for up to 120 s while Cilium is away | `k3s-frr-failure` (`FRR_CILIUM_RESTART_OK`) |
| 2 | A restart of FRR took a manager off the cluster network | Graceful restart on the cluster-network sessions too. The kernel keeps the routes while bgpd is away. A node that is really dead is still dropped fast: BFD sees it. Corrected in round G11: this covers bgpd only. A restart of all of FRR may look like a dead node (a race); a deploy only reloads FRR | `k3s-frr-failure` (`FRR_DEAD_NODE_OK`, `FRR_FULL_RESTART_OK`, `FRR_DEPLOY_RELOADS_OK`) |
| 3 | Members in different places got LAN timers unless you set `site` | `site` is empty by default. Fast timers only when **both ends name the same site**. Everything else gets the slow, safe timers | eval `test_stabilityProfilesAndRecovery` |

!!! note "What this means for you"
    Set `site` only on machines that share a LAN or a data centre.
    Leave it unset for home-to-cloud links.

### Clusters

| # | What was wrong | Now |
|---|---|---|
| 4 | A reinstalled first manager started a second cluster | It refuses to start when it has no data and another manager answers. The log says what to do |
| 5 | A changed Cilium setting reached no running node | The setting's hash is on the Cilium pods. A change restarts them, one node at a time |
| 6 | The ClusterMesh unit restarted its server at every run | Only when a certificate changed |
| 7 | One Cilium operator | Two, in a cluster of two or more machines |
| 8 | Crossing the route limit dropped the Cilium session for 10 minutes | A warning in the log; the session stays |
| 9 | Pods reached hosts in a `10.x` network with their pod address | A machine with a static `10.x` address outside the cluster's ranges is refused before a deploy, with the address named |

### Machines

| # | What was wrong | Now | Proof |
|---|---|---|---|
| 10 | netif's rollback restored the link file only | It restores the DHCP client settings too, and keeps the links other services own | `netif-guard` (`NETIF_GUARD_OWNERS_OK`) |
| 11 | A missing certificate secret was skipped | The unit fails; the server does not start with its own certificates | eval |
| 12 | `kubectl exec` and `logs -f` ended after one idle minute | One hour | eval |

### Smaller

| # | What was wrong | Now |
|---|---|---|
| 13 | A leaf could pass routes on | What a leaf learns is marked "do not pass on" (BGP `no-export`) |
| 14 | The router read an internal netif option | The option is public. Zone networks must be a `/64` |
| 15 | Every router boot retired the current prefix for a few seconds | The first run after a boot waits 45 s for the ISP's answer before it retires anything |
| 16 | A full rate-limit table stopped limiting | A full table refuses new sources; it is counted |

### One more, found by the test run

**FRR's BGP daemon crashed about once in some dozen boots.** This is
older than this work (it is in a test log from 2026-11-18). Two FRR
timers were both 5 s and ended together, which trips a bug in FRR
10.7.1. FRR restarted itself, so tests passed, but under load it failed
one. One timer is now 10 s. No crash in any log of the last two full
runs. That is good evidence, not proof.

One more, from your third answer: the router now takes the address it
uses towards pods on other nodes **from the cluster network itself**.
You no longer set `unzoned.source`; you can still override it.

### What no test ran

These are checked at build time only, not in a booted test:

- the first manager **refusing** to start (its unit and order are
  checked; every cluster test boots through it);
- a changed Cilium setting rolling the pods;
- a missing certificate secret failing the unit;
- a full rate-limit table.

### What you must know when you deploy

- **The first start of the first manager takes up to 30 s longer.** It
  asks the other managers whether a cluster exists.
- **To rebuild a lost first manager**: move `clusterInit` to a manager
  that has the data. The rebuilt machine then joins it. The refusal in
  the log says so.
- **A changed Cilium setting now rolls the Cilium pods.** One node at
  a time; traffic keeps flowing.

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
