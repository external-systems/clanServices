# Target design for networking and Kubernetes

Decided by the owner on 2026-11-27 as the direction. A prototype of
each area ran in VM suites the same day. **Not implemented on `main`
yet.** The agent contract is `specs/target-design.md` and the four
`specs/design-*.md` files. The probe findings are in
`specs/probes/2026-11-27/`.

## Why

A review put an attacker VM beside each service. It found gaps:

- A spine forwarded traffic from the underlay into the fabric.
- A host on the node LAN could reach a pod.
- A pod could reach BGP on other nodes.
- One packet could loop 32 times through a NAT64 gateway or a CLAT.
- Hosts accepted ICMP redirects.

The cause was the same each time. The stack named what is bad and
trusted the underlay for the rest. The target design names what is
allowed.

## The design in four lines

| Area | Rule |
|---|---|
| routed-fabric | A link carries a packet only if BGP may carry its route. One contract per link feeds FRR, WireGuard and the firewall |
| k3s and rke2 | The node says what may come in. Pods refuse the outside unless they are labelled. Every outside-facing Service names its sources |
| gateways | Policy is checked before translation. Inside the translator, anything that was not translated is dropped |
| netif | One program applies, checks and rolls back. DHCP and router advertisements are untrusted input |

## What changes for a user

- Router advertisements are off unless a link says `ra = true`.
- DHCP classless routes are ignored unless a link opts in.
- A router zone reaches the fabric only with `fabric = true`.
- A pod answers the outside only with the label `clan.lol/outside=allow`
  (on the pod or its namespace).
- A Service that faces the outside is type LoadBalancer with source
  ranges. Without ranges it answers cluster members and pods only.
  Plain NodePort Services are refused.
- New namespaces enforce the Pod Security level `baseline`.
- Manual-address clusters go away. A cluster needs a fabric.
- A deploy whose new network does not work stays on the last good one.
  A deploy during a network outage reports a failure and changes
  nothing.
- A CLAT host no longer forwards IPv6 between its other links.
- The ClusterMesh API Service is type LoadBalancer with source ranges,
  also on node-port exposure. There `cilium clustermesh status` cannot
  read it; use `cilium-dbg status` on the agents.

## What the probes proved

- Every hostile suite passes on the prototype of its area, with no gap.
- A firewall rule cannot protect a pod on a Cilium node: Cilium
  delivers the packet first. The Cilium policy can, and does.
- Source ranges on Services hold on every front, in both families.
- The guard inside the translator drops nothing legitimate.
- The netif transaction boots without an ordering cycle and rolls a
  bad configuration back.
- Two older "safe" verdicts were empty: the attack had never run. Every
  hostile check now has a control that shows the attack works first.

Some parts were refuted and changed. BGP TTL security (GTSM) is out,
because it breaks the link binding of BFD in FRR 10.7.1. A custom eBPF
guard for NodePorts is not needed.

## What is still open

No owner decision is open. Some parts were designed and not run yet,
for example the cluster-founding beacon, transit tunnels as service
code, and remote-builder (waits for a change in the `home` repo). Each
is marked NOT-RUN in its design file, and the step that builds it must
prove it.

## How it gets built

In waves, one PR per step:

1. The hostile suites, with the first guards of each area.
2. The structural steps of each area.
3. The large steps (the netif transaction, the pod policy and Service
   fronts, transit).
4. New code without a prototype, and optional steps.

Done so far:

- Fabric steps 1 and 2 (SPEC.md D73): the link contract, one guard
  table on every fabric member, BGP and BFD pinned to the link's peer,
  FRR waits for the guard, and `zones.<name>.fabric` on the router.
  Proven by the suite `hostile-fabric`.
- Kube step 1 (SPEC.md D74): the suites `k3s-hostile` and `rke2-hostile`,
  the table `inet kube-<instance>` (a host on the node LAN no longer
  reaches a pod), the rke2 supervisor front for members only, and
  `packages.rke2` as the runtime.

Until the design is frozen, tests prove behaviour and may be rewritten
(see [Testing](../reference/testing.md)).
