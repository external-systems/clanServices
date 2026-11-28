# Best-design target: k3s / rke2 services (`lib/kube-cluster`, `services/{k3s,rke2}`)

> **Status: target design, probed, not merged** (SPEC.md round 61).
> The probes of 2026-11-27 ran on a prototype of this design, in VM
> suites on the builder. A line marked **VERIFIED-VM** names the suite
> that proved it. A line marked **REFUTED** names what the probe showed
> instead; the design below already follows the probe. **NOT-RUN** means
> no VM saw it. The owner's decisions O2, O3 and O4
> (`specs/target-design.md` §4) are written in: §3.4, §3.5, §3.11.
> The index, the cross-area contracts and the build order are in
> `specs/target-design.md`.
> `specs/probes/2026-11-27/kube.md` has one row per probe with the log
> lines. The other evidence named here (`reviews/`, `runs/`,
> `probes/kube/`, patches) is session evidence of 2026-11-27. It is not
> in the repo; the session handoff maps it.
> `probes/kube/prototype.patch` is the prototype.
>
> **Implemented:** step 1 (round 63, SPEC.md D74); steps 3 and 4
> (round 67, SPEC.md D76: no manual mode, typed options, the README
> test, HAProxy on loopback, the firewall matrix).

Base: main at `deeaba4`. Paths are relative to the repo root.
Builds on `reviews/kube.md` (K-A1..K-A10), the hostile verdicts in `runs/`, and the probe runs in `probes/kube/runs/`.

Owner rule for this design: no consumers, no deployed machines. Tests, option names and code structure are free to change. Only safety behaviour is fixed.

Versions the probes ran on: Kubernetes 1.37.1 (k3s `v1.37.1+k3s1`, the rke2 of the same pin), Cilium 1.20.3, kernel 6.18.

## 0. How to read the evidence marks

- **VERIFIED-VM `<suite>`**: seen in that VM suite on the prototype. The suites: `<distro>-hostile` (verdicts `K..`), `<distro>-probe-net`, `<distro>-probe-rejoin` (throwaway probes, `FINDING` lines), `<distro>-clustermesh-nodeport`.
- **REFUTED**: a probe disagreed with the earlier design. The text states what the probe showed.
- **NOT-RUN**: designed, not booted.
- **[code]**: read in this repo at the given file.
- **[cilium-src]**: read in the Cilium 1.20.3 datapath source. It ships inside the agent image in the Nix store. To read it again:
  - image: `/nix/store/7f9vkaf6cf3hdn4a25fv5b0f8q85j9v5-docker-image-quay.io-cilium-cilium-v1.20.3.tar`
  - layer: `8eabe133386e20fe581c46c12d04197b25f19ea9a0bec01115f55e60aff044e4.tar`
  - files: `var/lib/cilium/bpf/bpf_host.c`, `lib/nodeport.h`, `lib/lb.h`, `lib/host_firewall.h`, `lib/local_delivery.h`
  - command: `tar xOf <image> <layer> | tar x --wildcards 'var/lib/cilium/bpf/*'` (into a scratch directory).
- **[k3s-src]**: read in k3s `pkg/clientaccess/token.go` (`hashCA`, `appendCertsFromPEM`, `getCACerts`). rke2 uses the same package.
- **[manifest]**: read in the committed Cilium manifest, `<org-pkgs>/manifests/cilium/1.20.3.yaml` (`cilium-config`).

## 1. Threat model

| ID | Attacker | Has | Does not have |
|---|---|---|---|
| A1 | Outsider on a node's LAN | L2 access to an underlay link. Can route any destination to the node's underlay address. Can forge any source address. | Any key, token or certificate. No WireGuard key. |
| A2 | Fabric member outside the cluster (a leaf) | A valid fabric identity. Root on its machine: it can widen its own WireGuard AllowedIPs and add any route into its fabric link. Its source is limited to its own prefixes (WireGuard AllowedIPs at the spine). | Cluster credentials. A member source address. |
| A3 | Hostile pod | Code execution in an unprivileged pod. The default service account token. A pod-CIDR source address. | Host access. Other service accounts. |
| A4 | Compromised agent node | Root on one agent: the agent token, the kubelet credentials, the HAProxy health-check client certificate (`CN=haproxy-healthcheck`, no group), a member source address. | The server token, any CA key, the admin kubeconfig, etcd access. |

Trusted, out of scope:
- Servers. They hold the CA keys.
- Spines. A spine forwards for everyone and can forge a member source. Against a spine only TLS, tokens and mTLS hold. By-source rules do not.
- The operator and the deploy path.
- A cluster admin. Whoever may create a Service in `kube-system` or label a namespace can open what this design closes.

## 2. Invariants

Each one is a hostile-suite verdict or a suite assertion. "Outside" means: not a member of this cluster, not one of its pods, not a ClusterMesh peer. A fabric member that is no cluster member is outside (owner decision O2).

Safety:
- **S1** No TCP or UDP port of a node answers A1 on any underlay address. (K01, K02) VERIFIED-VM `k3s-hostile`, `rke2-hostile`.
- **S2** No cluster port of a node address answers A1 or A2. Cluster ports: API, supervisor, kubelet, etcd, Cilium health, state beacon. (K03, K04, K10) VERIFIED-VM `k3s-hostile`, `rke2-hostile`.
- **S3** No pod answers a new connection from outside on its pod address. This holds on every link, also on a link that is a Cilium device, and for a pod that runs on a spine. Opt-out per pod or namespace by label. (K05, K06, K11, K05d, K06d, K11f) VERIFIED-VM `k3s-hostile`, `rke2-hostile`, `k3s-probe-net`.
- **S4** No ClusterIP answers from outside. (K07, K12) VERIFIED-VM `k3s-hostile`, `rke2-hostile`.
- **S5** A Service front (a LoadBalancer address or a NodePort) answers the Service's source ranges only. Without a choice the ranges are the members and the pods. A Service that cannot carry ranges (type NodePort, `externalIPs`) is refused at admission. (K08, K10n, K13, K17, K18) VERIFIED-VM `k3s-hostile`, `rke2-hostile`.
- **S6** A range on a Service holds on every front of that Service, in both families, with `externalTrafficPolicy` Cluster and Local. VERIFIED-VM `k3s-probe-net` phase D.
- **S7** A pod reaches on a node only: the API on servers (6443). Nothing else, unless `firewall.kubeletFromPods` is on. (K20, K21) VERIFIED-VM `k3s-hostile`, `rke2-hostile`.
- **S8** The API and supervisor load-balancer fronts listen on loopback only. No other host and no pod reaches them. (K27) VERIFIED-VM `k3s-hostile`, `rke2-hostile`.
- **S9** etcd answers servers only. The etcd metrics port answers nobody. (K24) VERIFIED-VM `k3s-hostile`, `rke2-hostile`.
- **S10** The kubelet refuses anonymous requests. Its read-only port is closed. The API refuses anonymous reads of resources. The default service account reads nothing. (K22, K23, K25, K26) VERIFIED-VM `k3s-hostile`, `rke2-hostile`.
- **S11** An agent holds no server token, no CA key, no admin kubeconfig, no mesh key. No secret is in the Nix store, in a process argument, or readable without root. (K30–K33) VERIFIED-VM `k3s-hostile`, `rke2-hostile`.
- **S12** A joining node verifies the cluster CA before it sends its token. (K34) VERIFIED-VM `k3s-hostile`, `rke2-hostile`; the refusal of a wrong pin: `k3s-probe-net` run 3.
- **S13** A server never founds a second cluster while any member remembers the first one. (suite phases of §7) NOT-RUN: the beacon and the decider are new code.
- **S14** BGP and BFD answer the link's peer only. (K20/K21 on 179; owned by routed-fabric, checked here) VERIFIED-VM `k3s-hostile`, `rke2-hostile`.
- **S15** A namespace enforces the Pod Security level `baseline` unless its own label says otherwise. (K50–K53; owner decision O4) VERIFIED-VM `k3s-hostile`, `rke2-hostile`.

Stability:
- **T1** Loss of any one server, the init server included, leaves the API reachable from every other node.
- **T2** A cold boot of all nodes at once brings the cluster back with no operator step.
- **T3** A node's HAProxy does not depend on the fabric being up to start.
- **T4** A changed token var never takes down a running control plane silently at the next restart.
- **T5** A partial deploy (some members on the old member list) never opens a port. It may delay a join.

## 3. Target design

### 3.1 Layers at a glance

| Layer | Mechanism | Closes | Result |
|---|---|---|---|
| L0 | NixOS firewall, input default-drop, by-source accepts rendered from one matrix (§3.2) | S1, S2, S7, S9 | VERIFIED-VM `k3s-hostile` K01–K04, K10, K20, K21, K24 |
| L1 | nft table `kube-<i>`, prerouting raw: cluster CIDRs only from inside links (§3.3) | S3, S4 on links that are **not** Cilium devices | VERIFIED-VM K05, K06, K07. It does **not** hold on a Cilium device: `k3s-probe-net` phase B |
| L2 | One CiliumClusterwideNetworkPolicy: pods refuse `world` unless labelled (§3.4) | S3 on **every** link, and the O2 case | VERIFIED-VM `k3s-probe-net` C and C2, `k3s-hostile` K05d, K06d, K11f |
| L3 | Source ranges on every Service front: `bpf-lb-source-range-all-types=true`, a default by a MutatingAdmissionPolicy, a ValidatingAdmissionPolicy that refuses what cannot carry ranges (§3.5) | S5, S6 | VERIFIED-VM `k3s-probe-net` D and E, `k3s-hostile` K08, K10n, K13, K17, K18 |
| L5 | HAProxy fronts on loopback (§3.6) | S8, T3, K-A2 | VERIFIED-VM `k3s-hostile` K27, K41, K42 |
| L6 | State beacon + init decider (§3.7) | S13, T2 | NOT-RUN (new code). The upstream behaviour it rests on: probe P4 |
| L7 | CA-pinned tokens (§3.8) | S12 | VERIFIED-VM `k3s-hostile` K34 |
| L8 | Pod Security default `baseline` (§3.11) | S15 | VERIFIED-VM `k3s-hostile` K50–K53 |

(There is no L4: the earlier draft's L3, a custom tcx guard, is gone. Owner decision O3: no custom eBPF.)

Why L1 alone is not enough. **VERIFIED-VM `k3s-probe-net`** (probe P1):
- BPF host routing is active: `cilium-dbg status` prints `Routing: Network: Native   Host: BPF` and `Attach Mode: TCX` on both nodes.
- D71 puts the link that holds the default route into `devices` (`lib/kube-cluster/devices.nix`). On a real machine that link is the node LAN.
- The probe adds `eth1` (the node LAN) to `devices`. `bpftool net show dev eth1` then lists `tcx/ingress cil_from_netdev`.
- With the nft table in place, the outsider then connects to a pod on that node: `outsider -> pod on beta, routed to beta's LAN address: CONNECTS`, and ping answers. The same on alpha.
- The netfilter counters prove the path. A counter at `prerouting priority -500` for `ip saddr <outsider> ip daddr <pod CIDR>` and the table's own drop counter both stay at their old value (11 packets before, 11 after) while the connection succeeds. The packet never enters netfilter.
- The path that bypasses netfilter: `cil_from_netdev` on the device runs at tcx ingress, ahead of every netfilter hook. For a destination that is a local endpoint it calls `ipv4_local_delivery` and redirects into the pod (`bpf_host.c:788-822`, `lib/local_delivery.h` `redirect_ep` with `redirect_peer`) [cilium-src]. Nothing of the host stack sees it.
- A packet for a pod on **another** node is not delivered by eBPF: it goes to the stack, and the nft table drops it (`outsider -> pod on beta via alpha: blocked`, alpha's drop counter rises by 3).
- Just after a Cilium agent restarts, a device can pass packets to the stack for some seconds (run 1: alpha's nft counter rose, the connection failed). Do not build on that.
- The same path opens the O2 case on main and on the minimal prototype: mallory, with a forced route, reaches a pod on the spine and, through the spine, a pod on a leaf (`mallory (forced route) -> pod on alpha, the spine: CONNECTS`, both families). The fabric links are Cilium devices.

Why the Cilium host firewall is not the answer:
- NodePort DNAT runs before the host firewall: `bpf_host.c:654-674` then `:676-711` [cilium-src].
- Host policy is enforced only when the destination identity is the host: `lib/host_firewall.h:509-511` [cilium-src]. After DNAT the destination is a pod.
- So a host policy never sees NodePort or LoadBalancer traffic. Keep `enable-host-firewall: "false"`.

Why the source of a Service front is judged per Service:
- The only source check in the service path is per Service: `lib/nodeport.h:2613` calls `lb4_src_range_ok`, which returns true unless the Service has `SVC_FLAG_SOURCE_RANGE` (`lib/lb.h:1798-1816`) [cilium-src].
- Kubernetes takes source ranges on `type: LoadBalancer` only. Both the field and the legacy annotation are refused on another type. VERIFIED-VM `k3s-probe-net`: `spec.LoadBalancerSourceRanges: Forbidden: may only be used when type is 'LoadBalancer'` and the same text for `metadata.annotations[service.beta.kubernetes.io/load-balancer-source-ranges]`.
- So every Service that answers from outside must be of type LoadBalancer and carry ranges. §3.5 makes that a rule the API server enforces.
- `nodePort.addresses` (D69) limits destination addresses, not sources. `bpf-lb-external-clusterip=false` keeps ClusterIPs unroutable from outside and is why K07 and K12 are safe.

### 3.2 L0: the node firewall as one matrix

VERIFIED-VM `k3s-hostile` (K01–K04, K10, K20, K21, K24, K27, K41, K42) and `k3s-clustermesh-nodeport`.

Keep: NixOS firewall on, nftables, by-source accepts in `extraInputRules`, the `iifname { fabric links, "lxc*", "cilium*" }` guard on every rule.

Change: `firewall.nix` takes rows of data, not port lists. nix-unit tests assert the rows. The hostile suite asserts the behaviour. No test compares nft text.

Port and source matrix:

| Row | Port | On | From | Why |
|---|---|---|---|---|
| `api` | 6443/tcp | servers | members, pod CIDRs | Every member's HAProxy; pods through the `kubernetes` ClusterIP (DNAT keeps the pod source). |
| `supervisor` | 9345/tcp | rke2 servers | members | Joins, through the joiner's loopback HAProxy. |
| `kubelet` | 10250/tcp | every node | servers; pod CIDRs only if `firewall.kubeletFromPods` | The API server reads logs and runs exec. Pods need it only for a metrics scraper. `kubectl logs` and `exec` on an agent's pod work with this row: K42. |
| `cilium-health` | 4240/tcp | every node | members | Node-to-node health probe. `Cluster health: 2/2 reachable` with this row: K41. |
| `etcd` | 2379, 2380/tcp | servers | servers | Client and peer. |
| `state-beacon` | 9442 + cilium id | every node | servers | §3.7. NOT-RUN. |
| removed | 2381 | – | – | Loopback-only metrics port. It was open only so a suite got a "refused". |
| removed | 7442+id, 8442+id | – | – | HAProxy fronts bind loopback (§3.6). |
| not ours | 179/tcp, 3784, 4784/udp | – | the link's peer | routed-fabric (prototype H1). |
| eBPF | Service fronts (LoadBalancer addresses, NodePorts) | node addresses, VIPs | the Service's source ranges | §3.5. nft never sees them. |

What a pod sees after the change (K20, K21): on a server `[6443]` plus Service fronts; on an agent only Service fronts. On main it was `[179, 4240, 6443, 7443, 10250]`.

`lib/kube-cluster/firewall.nix` (prototype, booted):

```nix
{lib}: let
  setOf = xs: "{ ${lib.concatStringsSep ", " xs} }";
  quoted = map (i: ''"${i}"'');
  portSet = ports: setOf (map toString ports);
in {
  # One row per listener. `from` names source classes, never addresses.
  matrix = {
    isServer, supervisor, kubeapiPort, supervisorPort, kubeletFromPods ? false,
  }:
    lib.filter (row: row.on) [
      { name = "api";           ports = [kubeapiPort];    from = ["members" "pods"]; on = isServer; }
      { name = "supervisor";    ports = [supervisorPort]; from = ["members"];        on = isServer && supervisor; }
      { name = "kubelet";       ports = [10250];          from = ["servers"] ++ lib.optional kubeletFromPods "pods"; on = true; }
      { name = "cilium-health"; ports = [4240];           from = ["members"];        on = true; }
      { name = "etcd";          ports = [2379 2380];      from = ["servers"];        on = isServer; }
    ];

  # sources = { members = { v4 = [..]; v6 = [..]; }; servers = ..; pods = ..; }
  renderMatrix = { rows, sources, guardInterfaces }: let
    guard = lib.optionalString (guardInterfaces != []) "iifname ${setOf (quoted (guardInterfaces ++ ["lxc*" "cilium*"]))} ";
    line = family: key: row: let
      from = lib.unique (lib.concatMap (class: sources.${class}.${key}) row.from);
    in
      lib.optionalString (from != [])
      "${guard}${family} saddr ${setOf from} tcp dport ${portSet row.ports} accept";
  in
    lib.concatStringsSep "\n" (
      lib.filter (l: l != "") (lib.concatMap (row: [(line "ip" "v4" row) (line "ip6" "v6" row)]) rows)
    )
    + "\n";
}
```

- Step 5 adds the row `state-beacon` (`ports = [beaconPort]; from = ["servers"]; on = true;`).
- Step 3 deletes manual-address mode; then `guardInterfaces` is never empty: replace the `optionalString` by `assert guardInterfaces != []`. **Done in round 67** (D76): `renderMatrix` asserts it, `mkInputRules` is deleted, and the matrix takes `kubeletFromPods` from the option `firewall.kubeletFromPods`.
- Caller: `lib/kube-cluster/service.nix`, `networking.firewall.extraInputRules`. It builds `sources` from `roleMembers`/`memberAddr` and `resolvedCidrs` (prototype).
- `trustedInterfaces = ["cilium_host" "cilium_net"]` is removed. A trusted link accepts every port. VERIFIED-VM: with it gone K20 is safe, and DNS, pod-to-pod, host-to-pod, logs, exec and node health work (`k3s-hostile`, `k3s-probe-net`, `k3s-clustermesh-nodeport`).

### 3.3 L1: the nft table `kube-<instance>`

VERIFIED-VM `k3s-hostile` K05, K06, K07 and `k3s-probe-net` phase A (`blocked`, the drop counter counts).

**Implemented in round 63 (SPEC.md D74, kube step 1)**, from the minimal prototype (`patches/fixes-fabric-kube.patch`: `lib/kube-cluster/service.nix`; the fact `clan.networkFacts.fabricInside` landed with fabric steps 1 and 2). It renders:

```
table inet kube-<i> {
  chain ingress {
    type filter hook prerouting priority raw; policy accept;
    iifname { "rf…a", "rf…b", "lo", "cilium*", "lxc*", <fabricInside> } accept
    ip  daddr { <podCIDRv4>, <serviceCIDRv4> } counter drop comment "outside to the cluster's pods and Services"
    ip6 daddr { <podCIDRv6>, <serviceCIDRv6> } counter drop comment "outside to the cluster's pods and Services"
  }
}
```

- Shape: default-deny for cluster destinations. Inside links are listed; everything else is dropped.
- What it is for, now that L2 exists: links that are no Cilium device (eBPF does not judge there), packets that a device hands to the stack (a pod on another node), and the day a cluster admin deletes the policy.
- What it cannot do: judge a packet that a Cilium device delivers to a local pod (§3.1). Do not add this node's D71 links to the accept list, and do not expect the table to count there.
- Why not `networking.firewall.filterForward = true` instead: the NixOS forward chain drops `ct state invalid` before the extra rules. With BPF host routing, netfilter sees only one direction of some pod flows. A reply that falls back to the stack would be invalid and dropped. Rejected.
- The table is always rendered once manual mode is gone (step 3 removes the `mkIf (transportInterfaces != [])`).

### 3.4 L2: pods refuse the outside (one clusterwide policy)

VERIFIED-VM `k3s-probe-net` phases C and C2 (applied by hand), `k3s-hostile` K05d, K06d, K11f (rendered by the bundle), `k3s-clustermesh-nodeport` (the mesh still forms).

The object, exactly as proven:

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: clan-outside-to-pods
spec:
  description: "No pod takes traffic from outside the cluster unless it, or its namespace, says so."
  endpointSelector:
    matchExpressions:
      - {key: clan.lol/outside, operator: DoesNotExist}
      - {key: io.cilium.k8s.namespace.labels.clan.lol/outside, operator: DoesNotExist}
  enableDefaultDeny:
    ingress: false
    egress: false
  ingressDeny:
    - fromEntities: [world]
```

What the probes showed:
- `world` is the right entity for both attackers. Cilium knows the members' node addresses as `remote-node` (identity 6) and everything else as `world` (identity 9 for IPv4): `cilium-dbg bpf ipcache get <mallory>` prints `identity=9`, `<beta>` prints `identity=6`. A fabric member that is no cluster member is `world`. No CIDR list is needed, and O2 needs no second rule.
- With the policy, and with the nft table **removed** (phase C2): the outsider on a Cilium device, mallory with a forced route to a pod on the spine and through the spine, TCP and ping, IPv4 and IPv6: all `blocked`. Cilium counts them as `Policy denied by denylist`.
- `enableDefaultDeny: false` keeps every pod default-allow for the rest: `cilium-dbg endpoint list` still shows `POLICY (ingress) ENFORCEMENT Disabled` for the pods.
- What still works with the policy (phase C and `k3s-hostile`): pod to pod on one node and across nodes in both families, host to its own pod, host to a pod on another node in both families (the API server to a webhook), ClusterIP, the API ClusterIP, cluster DNS, `kubectl logs` and `exec`, Service fronts for members and pods, a pod's connection to an outside host and its replies (the deny is stateful), Cilium node health `2/2 reachable`.
- The two labels work as written. A pod with `clan.lol/outside: allow` and a pod in a namespace labelled `clan.lol/outside=allow` answer the outsider; the pods beside them do not.
- ClusterMesh still forms (`k3s-clustermesh-nodeport`): peering `1/1 remote clusters ready` on both sides, a pod of one cluster pings a pod of the other, a global Service merges backends. Pods of a mesh peer carry cluster identities, not `world`.

Where it is rendered (prototype, booted):
- `lib/kube-cluster/bundle.nix`: `mkOutsidePolicyResource`, the custom type `CiliumClusterwideNetworkPolicy` (`cilium.io/v2`, attribute `ciliumClusterwideNetworkPolicies`) beside the pool types, and the resource `clan-outside-to-pods` in `mkBundle` when `outsidePolicy` is true. It carries the manifest labels and follows the bundle's prune rule.
- `lib/kube-cluster/service.nix` passes `outsidePolicy = settings.outsideIngress.policy` (option, default `true`).
- `lib/kube-cluster/mesh.nix` `apiserverDeploymentPatch` labels the `clustermesh-apiserver` pods `clan.lol/outside: "allow"`: a peer's agents dial that pod before the mesh knows them. mTLS guards the port.
- When: the bootstrap-apply unit on the init server, in the first minute of the cluster. The Cilium operator creates the CRD; the unit retries until the object sticks, as it does for the pools. Day-2 workloads come later. A pod that starts before the object exists is covered from the moment the object exists.

What the operator must know (write it in the service READMEs and `documentation/docs/`):
- Two gates, two purposes. The policy guards **pod addresses** and every path that keeps the client's source. The source ranges of §3.5 guard **Service fronts**.
- To expose a workload to a source outside the cluster: put the source into the Service's ranges (§3.5) **and** label the pods or the namespace `clan.lol/outside: "allow"`.
- Why both: a front on a node that holds no backend forwards with its own address as source, so the backend sees `remote-node` and answers without the label. A front on the backend's node keeps the client source, so an unlabelled backend drops it. VERIFIED-VM `k3s-probe-net` (`lb-unlabelled`): mallory, inside the ranges, connects on the LoadBalancer address and on alpha's NodePort, and is blocked on beta's NodePort, where the unlabelled backend runs. Fail-safe, but confusing. The README must lead with: label what you expose.
- A LoadBalancer address is answered by the first Cilium node on the path. That node judges the source ranges. For mallory that node is the spine.

This is a new decision: SPEC §3.3 says policy is day-2. Record it as a decision ("one exposure guard is part of the data plane") before code (hard rule 3). It stays inside D1: Cilium remains networking-only.

### 3.5 L3: Service fronts by source (owner decision O3)

Owner decision: an enforceable contract, no custom eBPF. Service fronts answer cluster members by default, plus an opt-in list. This replaces the tcx guard of the earlier draft.

VERIFIED-VM `k3s-probe-net` phases D and E, `k3s-hostile` K08, K10n, K13, K13m, K13p, K17, K18, `k3s-clustermesh-nodeport`.

What the probes showed:

| Question | Result |
|---|---|
| Does a NodePort Service take source ranges? | No. The field and the legacy annotation are both `Forbidden` on any type but LoadBalancer. |
| Cilium default (`bpf-lb-source-range-all-types=false`): a LoadBalancer Service with ranges | The LoadBalancer address refuses mallory. The Service's **NodePort still answers mallory**, both families, both nodes. |
| With `bpf-lb-source-range-all-types=true` | Every front refuses mallory: the address and the NodePort, IPv4 and IPv6, on both nodes, `externalTrafficPolicy` Cluster and Local. |
| Members and pods with the flag | All connect: host to its own node and to the other node, pods to both nodes, the address, the NodePort and the ClusterIP. |
| A Service whose ranges hold only mallory | mallory connects. Members and pods connect too. |
| So: who do ranges restrict? | Sources outside the cluster only. A host or a pod of the cluster is translated at `connect()` (socket load balancing) and is never judged by ranges. Ranges cannot lock the cluster out of its own Services. |
| A Service of type NodePort (no ranges possible), flag on | mallory connects on alpha's NodePort. That is the gap the admission policy closes. |
| ValidatingAdmissionPolicy and MutatingAdmissionPolicy | Both are `admissionregistration.k8s.io/v1` on Kubernetes 1.37.1, served by default. |
| MutatingAdmissionPolicy with `patchType: ApplyConfiguration` | REFUTED: `invalid ApplyConfiguration: may not mutate atomic arrays, maps or structs: .spec.loadBalancerSourceRanges`. `patchType: JSONPatch` works. |

The design, four parts:

1. **Cilium enforces ranges on every front.** `cilium-config` gets `bpf-lb-source-range-all-types: "true"`. `lib/kube-cluster/cilium.nix`: `extraConfig."bpf-lb-source-range-all-types" = true;`, and `contradictions` refuses an override that turns it off. `lib/kube-cluster/bundle.nix`: the key in `profilePatches` and in `knownProfilePaths`.

2. **A LoadBalancer Service without ranges gets the default set.** A MutatingAdmissionPolicy sets `loadBalancerSourceRanges` to the allowed sources: every member's node addresses, the pod CIDRs, and `nodePorts.allowedSources`.

3. **A Service that would answer every source is refused.** A ValidatingAdmissionPolicy with `failurePolicy: Fail`:
   - `type: NodePort` is refused (it cannot carry ranges);
   - `externalIPs` are refused (they answer every source);
   - a LoadBalancer Service must have ranges, and every range must lie inside the allowed sources.
   A namespace labelled `clan.lol/service-sources=any` is not judged: that is the opt-out for a Service that must face the world. `kube-system` is not judged either.

4. **The ClusterMesh API Service carries ranges too.** It is always of type LoadBalancer (`lib/kube-cluster/mesh.nix` `apiserverServicePatch`). Its ranges are this cluster's members, the members of every cluster of the mesh group, and the pod CIDRs of all of them (`sourceRanges` in `mesh.resolve`).
   - `internal-load-balancer` (what `auto` picks on a fabric): `allocateLoadBalancerNodePorts: false`. The peers dial the address; there is no NodePort. On main its NodePort answered mallory (K10n on the first prototype run: `open: [31368]`).
   - `node-port`: `loadBalancerClass: clan.lol/node-port`, a class no controller serves, with the fixed `nodePort`. The Service gets no address and answers on its NodePort only, to its ranges. VERIFIED-VM `k3s-clustermesh-nodeport`: the NodePort answers both clusters over mTLS and the mesh forms.
   - `external-load-balancer`: unchanged. The provider's balancer is the operator's (day-2).
   - Cost: `cilium clustermesh status` (cilium-cli) fails on node-port exposure with `unable to derive service IPs automatically`, because the Service has no address. Read the agents instead: `cilium-dbg status` prints `ClusterMesh: 1/1 remote clusters ready`, and `cilium-dbg troubleshoot clustermesh`. Say so in the README.

The admission objects, exactly as the bundle renders them for the test fixture (members `192.168.77.1`, `192.168.77.2`, `fd00:77::1`, `fd00:77::2`; pods `10.1.0.0/16`, `fd10:1::/56`):

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: clan-service-sources
spec:
  failurePolicy: Fail
  reinvocationPolicy: Never
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["services"]
  matchConditions:
    - name: load-balancer-without-ranges
      expression: "object.spec.type == 'LoadBalancer' && (!has(object.spec.loadBalancerSourceRanges) || size(object.spec.loadBalancerSourceRanges) == 0)"
  mutations:
    - patchType: JSONPatch
      jsonPatch:
        expression: "[JSONPatch{op: 'add', path: '/spec/loadBalancerSourceRanges', value: ['192.168.77.1/32', 'fd00:77::1/128', '192.168.77.2/32', 'fd00:77::2/128', '10.1.0.0/16', 'fd10:1::/56']}]"
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: clan-service-sources
spec:
  policyName: clan-service-sources
  matchResources:
    namespaceSelector:
      matchExpressions:
        - {key: clan.lol/service-sources, operator: NotIn, values: ["any"]}
        - {key: kubernetes.io/metadata.name, operator: NotIn, values: ["kube-system"]}
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: clan-service-sources
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["services"]
  variables:
    - name: allowed
      expression: "['192.168.77.1/32', 'fd00:77::1/128', '192.168.77.2/32', 'fd00:77::2/128', '10.1.0.0/16', 'fd10:1::/56']"
    - name: ranges
      expression: "has(object.spec.loadBalancerSourceRanges) ? object.spec.loadBalancerSourceRanges : []"
  validations:
    - expression: "object.spec.type != 'NodePort'"
      message: "type NodePort cannot carry source ranges: use type LoadBalancer (its NodePort then answers loadBalancerSourceRanges only)"
    - expression: "!has(object.spec.externalIPs) || size(object.spec.externalIPs) == 0"
      message: "externalIPs answer every source and are not allowed"
    - expression: "object.spec.type != 'LoadBalancer' || size(variables.ranges) > 0"
      message: "a LoadBalancer Service must set loadBalancerSourceRanges"
    - expression: "object.spec.type != 'LoadBalancer' || variables.ranges.all(r, isCIDR(r) && variables.allowed.exists(a, cidr(a).containsCIDR(r)))"
      message: "every loadBalancerSourceRanges entry must lie inside the cluster's allowed sources (the members, the pods, nodePorts.allowedSources)"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: clan-service-sources
spec:
  policyName: clan-service-sources
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - {key: clan.lol/service-sources, operator: NotIn, values: ["any"]}
        - {key: kubernetes.io/metadata.name, operator: NotIn, values: ["kube-system"]}
```

What admission did in the VM (`k3s-probe-net` phase E, `k3s-hostile` K18):

| Request | Result |
|---|---|
| a NodePort Service; `kubectl expose --type=NodePort` | refused, with the message above |
| a LoadBalancer Service without ranges, validating policy only | refused |
| a LoadBalancer Service without ranges, both policies | admitted with the default ranges (`k3s-hostile`: `["192.168.77.1/32","fd00:77::1/128","192.168.77.2/32","fd00:77::2/128","10.1.0.0/16","fd10:1::/56"]`) |
| ranges that hold an address outside the allowed set; `0.0.0.0/0` | refused |
| ranges inside the allowed set (a member `/32`, a `/24` inside the pod CIDR) | admitted |
| a ClusterIP Service | admitted |
| a ClusterIP Service with `externalIPs` | refused |
| a NodePort Service in a namespace labelled `clan.lol/service-sources=any`; in `kube-system` | admitted |
| an update of a NodePort Service that existed before the policy | refused. The policy also freezes old Services of that type. |

Where it is rendered (prototype, booted): `lib/kube-cluster/bundle.nix` `mkServiceSourceResources` (typed kubenix objects under `"admissionregistration.k8s.io"."v1"`), called in `mkBundle` when `serviceSources != null`. `lib/kube-cluster/service.nix` builds `serviceSources` from `roleMembers`/`memberAddr`, `resolvedCidrs` and `settings.nodePorts.allowedSources`; `nodePorts.admission = false` renders none.

Fail modes:
- The API server refuses, or the Service has ranges. There is no state in which a new Service of a judged namespace answers every source. `failurePolicy: Fail`: a policy that cannot be evaluated refuses the request.
- A new policy takes some seconds to act. The suite waits until a dry run carries the default ranges, then creates the Service. The bundle applies both policies in the first minute of the cluster, before day-2 workloads.
- A cluster admin can delete the policies, label a namespace, or create a Service in `kube-system`. That is the admin's right (§1).
- A member that joins later is not in the ranges of Services that already exist. It matters only for traffic that the new member forwards from outside; its own connections are never judged. Deploy, then re-apply those Services. Doc.

Limits, stated plainly:
- "NodePorts answer by source" holds because type NodePort is refused, not because Cilium filters every NodePort. A Service in an exempt namespace answers whoever reaches a Cilium device.
- UDP and SCTP fronts: NOT-RUN. The source check is in the same code path for all three [cilium-src]; add K13u before relying on it.
- IPv6 with extension headers before the L4 header (K13x): NOT-RUN.
- `nodePorts.allowedSources` with a real outside source (K13a): the admission half is VERIFIED-VM (a range outside the set is refused, one inside is admitted) and the datapath half is VERIFIED-VM (`lb-mallory`: a source inside a Service's ranges connects). One suite phase with the option set: NOT-RUN.

### 3.6 L5: the HAProxy fronts on loopback

VERIFIED-VM `k3s-hostile` and `rke2-hostile` (K27, K41, K42, the join itself), `k3s-probe-net`, `k3s-clustermesh-nodeport` (four nodes, two clusters), `<distro>-probe-rejoin` (three servers).

- Who dials a node's own fronts [code]: the kubelet, the distro's join, and the Cilium agent and operator. Both Cilium pods are `hostNetwork: true` [manifest] and only they get `KUBERNETES_SERVICE_HOST`. The clan CoreDNS and every normal pod use the `kubernetes` ClusterIP, which goes to the servers' 6443.
- **REFUTED for rke2: "no other host dials a front".** An rke2 agent keeps a tunnel to every server, and `kubectl logs` and `exec` ride it. The agent dials each server's **node address on the port of its own join URL**. On main that is the server's supervisor front (8443 on the node address). With loopback fronts the first rke2 run logged on the agent `Connecting to proxy url="wss://192.168.77.1:8443/v1-rke2/connect"`, then `dial tcp 192.168.77.1:8443: connect: connection timed out`, and `kubectl exec` on a pod of the agent failed: `proxy error from 127.0.0.1:9345 while dialing 192.168.77.2:10250, code 502` (`failed to find Session for client beta`). k3s has no such dependency (its agent dials the API port).
- The fix, in the design: **an rke2 agent's supervisor front listens on the supervisor's real port, 9345, on loopback.** An agent has no supervisor of its own, so the port is free there. Its join URL is `https://<kubeapi name>:9345`, so its tunnel dials `<server>:9345`: the real supervisor, which the firewall row `supervisor` opens to members. A server keeps the derived front port (8442 + id): its own supervisor owns 9345. `lib/kube-cluster/service.nix`: `haproxySupervisorPort = if distro.supervisor && !isServer then supervisorPort else haproxyKubeapiPort + 1000;` (prototype). Result on rke2: VERIFIED-VM `rke2-hostile` run 2: the agent logs `Remotedialer connected to proxy url="wss://192.168.77.1:9345/v1-rke2/connect"`, K42 is safe, and K27 shows `the front 9345 of beta listens on loopback only`.
- Probe P7, VERIFIED-VM: a host-network pod reads the node's `/etc/hosts`. Inside the Cilium agent `grep kubeapi /etc/hosts` prints `127.0.0.1 kubeapi-k3s.test.clan` and `::1 kubeapi-k3s.test.clan`. The agents and the operator run; no `hostAliases` is needed.
- Changes (prototype, booted):
  - `lib/kube-cluster/haproxy.nix`: `bind 127.0.0.1:<port>` and `bind [::1]:<port>` for both fronts.
  - `lib/kube-cluster/haproxy.nix`: every server line pins its source: `server <n>-4 <ip4>:<port> source <nodeIPv4>` and `server <n>-6 [<ip6>]:<port> source [<nodeIPv6>]`. The health check and the data path leave with the node address whatever the route says. The servers accept members only. In the VM a backend is `DOWN … Network is unreachable` until the fabric holds the address, then `UP`, with no restart.
  - `lib/kube-cluster/service.nix`: `extraHosts` maps the kubeapi name to `127.0.0.1` and `::1`.
  - `lib/kube-cluster/service.nix`: the two front ports have no firewall row (§3.2). This closes K-A2 by construction: the supervisor front is unreachable from anywhere but the node itself.
  - Amended in round 67 (D76): the ordering `after = ["ifstate.service"]` **stays**. It orders and requires nothing, so T3 holds (loopback always exists, haproxy starts without the fabric); and the `source` of every server line is the fabric address that IfState creates, the cross-area contract of `specs/target-design.md` §3 (the index wins). The comment about the bind race is gone: the fronts bind loopback.
- On the nodes: `ss -Hltn` shows `127.0.0.1:7443` and `[::1]:7443` only (rke2: also 8443 on a server, 9345 on an agent). A member, a pod and mallory do not connect to another node's front (K27, K20).
- The derived ports (7442 + id, + 1000) stay. They keep `k8sServicePort` stable.
- `tls-san` keeps the kubeapi name. Clients verify by name.

### 3.7 L6: bootstrap, join and the init decider

NOT-RUN as a whole: the beacon and the decider are new code. Probe P4 covers the upstream behaviour they rest on; its results are in §9.

Today (`lib/kube-cluster/nixos.nix` `mkInitGuard`): the init server without an etcd directory dials the other servers' API port. All "refused" in one pass means "no cluster" and it founds one. A peer whose service is down or still starting looks the same as a peer with no cluster (K-A3). Agents are never asked.

Target rule: **founding needs a positive "I remember no cluster" from every other member.** A closed port proves nothing.

Part 1, the state beacon, on every member (servers and agents):
- `kube-<i>-state.socket`: `ListenStream=<nodeIPv4>:<beaconPort>` and `[<nodeIPv6>]:<beaconPort>`, `FreeBind=true`, `Accept=yes`, `MaxConnections=8`. `beaconPort = 9442 + resolvedCiliumId` (define beside `haproxyKubeapiPort` in `service.nix`).
- `kube-<i>-state@.service`: `StandardOutput=socket`, read-only sandbox (`ProtectSystem=strict`, `NoNewPrivileges`), one line then exit:
  - `data` if `<dataDir>/server/db/etcd` exists (a failed join leaves it too: the answer then errs to the safe side);
  - else `joined` if `<dataDir>/agent/client-kubelet.crt` exists;
  - else `empty`.
- It answers whether the distro unit runs or not. It carries no secret. Firewall row `state-beacon`: servers only.

Part 2, the decider (same unit name `<distro>-<i>-init-guard`, still only on the `clusterInit` server, still `requiredBy` the server unit):

```sh
# replaces the loop of mkInitGuard in lib/kube-cluster/nixos.nix
if [ -e "$REJOIN_MARK" ]; then                                           # operator: join the live cluster
  mkdir -p "$(dirname "$REJOIN_DROPIN")"
  printf 'server: %s\ncluster-init: false\n' "$JOIN_URL" > "$REJOIN_DROPIN"
  rm -f "$REJOIN_MARK"
fi
if [ -e "$REJOIN_DROPIN" ]; then exit 0; fi                              # a joiner, in progress or done: start
if [ -d "$ETCD_DIR" ]; then exit 0; fi                                   # the founder with its data: start
if [ -e "$FOUND_MARK" ]; then rm -f "$FOUND_MARK"; exit 0; fi            # operator: found a new one
deadline=$(( $(date +%s) + WAIT ))
while :; do
  silent=""; remembered=""
  for peer in $PEERS; do                                                  # every other member, agents too
    answer=$(timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2" && read -r -t 4 a <&3 && echo "$a"' _ "$peer" "$BEACON_PORT" 2>/dev/null)
    case "$answer" in
      empty) ;;
      data|joined) remembered="$remembered $peer($answer)" ;;
      *) silent="$silent $peer" ;;
    esac
  done
  if [ -n "$remembered" ]; then
    echo "…no etcd data here, but these members remember a cluster:$remembered. Not founding a second one. To rejoin: on a live server run 'kubectl delete node <this node>', then create $REJOIN_MARK here and restart. To restore instead: use the distro's cluster-reset with a snapshot." >&2
    exit 1
  fi
  if [ -z "$silent" ]; then exit 0; fi                                    # every member said "empty": found
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "…these members did not answer for $WAIT s:$silent. If no cluster exists, create $FOUND_MARK and restart." >&2
    exit 1
  fi
  sleep 3
done
```

Three rules of this script come from probe P4 (k3s: VERIFIED-VM `k3s-probe-rejoin`; the prototype's guard has the first two as its `rejoinDropin` argument):

- **The drop-in is the state "this server is a joiner", and it is checked first.** A rejoining server does not join at its first start. In the VM its first two starts ended with `failed to bootstrap cluster data: Get "https://kubeapi-…:7443/v1-k3s/server-bootstrap": EOF`: its HAProxy had no backend yet, nine seconds after boot. systemd restarts the unit and the guard runs again. An earlier draft let the server pass once and then forgot the rejoin: the second guard run found no data and no marker, and refused for good (run 1).
- **The etcd directory proves nothing while the drop-in exists, and the decider never removes the drop-in.** REFUTED: the earlier draft said "the directory exists: I have the data, remove the drop-in". A join that fails leaves the directory behind without data. In the VM (run 2) the join failed with `etcd cluster join failed: duplicate node name found`, the guard then saw the directory and removed the drop-in, and the next start logged `Managed etcd cluster initializing` and `Starting etcd for new cluster, cluster-reset=false`: the server had started an etcd of its own. It then looped on `no bootstrap data found in datastore` and served nothing, but that is luck, not design. A server that has joined keeps `server:` set for good; every other server of the cluster is in that state. The operator may delete the drop-in later (probe: a restart with data and without the drop-in works, `cluster-init: true` is ignored when data exists).
- **The node object must be deleted before the rejoin, and nothing else.** With the old node object the join fails, again and again, with `duplicate node name found, please use a unique name for this node`. After `kubectl delete node alpha` on a live server, k3s removes the stale etcd member itself (`Removing etcd member from cluster due to node delete`) and the node-password secret goes with the node (it has an owner reference). The waiting server then joins at its next restart with no further step: `Adding member alpha-… to etcd cluster [beta-… gamma-…]`, three etcd members, three Ready nodes, the first cluster's data on the rejoined server.

- Keep full store paths for every tool, as today.
- `PEERS` = every other member (`roleMembers` minus self), not only servers.
- `REJOIN_DROPIN` = `/etc/rancher/<distro>/config.yaml.d/90-rejoin.yaml`. `FOUND_MARK` = today's `allow-new-cluster-<i>`. `REJOIN_MARK` = `<dataDir>/server/rejoin-<i>`. `JOIN_URL` = the node's own front: `https://<kubeapi name>:<7442+id>` on k3s, `https://<kubeapi name>:<8442+id>` on rke2.
- k3s: `services.k3s.clusterInit` is `false` on every node (`services/k3s/default.nix`, prototype), because the nixpkgs module turns it into the command-line flag `--cluster-init` (`nixos/modules/services/cluster/rancher/k3s.nix:12`) and a flag beats the drop-in. `cluster-init: true` is in the rendered `config.yaml` of the init server, so nothing is lost. VERIFIED-VM: every k3s suite of this round founded its cluster that way (`k3s-hostile`, `k3s-probe-net`, `k3s-clustermesh-nodeport`). rke2 has no such flag.
- Why agents are asked: in a one-server cluster with agents, a server that lost its disk would found an empty cluster. The agents trust the same CAs, join it, and their kubelets delete every running pod. With the beacon the agents say `joined` and the server refuses.
- Why "rejoin" replaces "move `clusterInit`": moving the option is a config change and a deploy of several machines during an incident. A marker file on the broken node is one step. Moving `clusterInit` still works (the new init server has data and starts).

What stays: PKI seeding (`AssertPathExists`, staged CA set), the bootstrap-apply and clustermesh-secrets units on the init server.

### 3.8 L7: tokens

VERIFIED-VM `k3s-hostile` K34 (every token file starts with `K10`, no "does not include a CA hash" line, the cluster founds and the agent joins). The refusal: `k3s-probe-net` run 3.

- Format: `K10<pin>::server:<64 hex>` and `K10<pin>::node:<64 hex>`.
- **The pin is the PKI's `ca-hash`**: the SHA-256 of the DER of the **root** certificate. REFUTED: the earlier draft and `reviews/kube.md` K-A6 said "the SHA-256 of the bytes of `server-ca.crt`" and "delete `ca-hash`, it is the wrong value". The probe booted that: the agent logged `CA cert validation failed: … x509: certificate signed by unknown authority` 294 times in ten minutes and never joined. The reason [k3s-src]: for a bundle of more than one certificate `hashCA` hashes the DER of the bundle's root, and `appendCertsFromPEM` trusts only a root with that hash. Our `server-ca.crt` is a chain of three (leaf CA, intermediate, root). The whole-file hash is only for a bundle of one certificate.
- So a wrong pin fails closed, before the node sends its secret: the node trusts no root, cannot verify the server, and stops at the `/cacerts` request.
- `lib/kube-cluster/vars.nix` (prototype, booted): both token generators get `dependencies = ["rancher-pki-<i>"]` and write

  ```sh
  pin=$(tr -d '\n' < "$in/rancher-pki-<i>/ca-hash")
  printf 'K10%s::server:%s\n' "$pin" "$(openssl rand -hex 32)" > $out/server-token   # agent: ::node:
  ```

  A shared generator may depend on `rancher-pki-<i>` on a machine that does not define it (the HAProxy generator already does, on agents). Keep `ca-hash` in the PKI generator; fix its comment.
- Both distros take the full form as `token-file` and `agent-token-file` on the founding server, and as `token-file` on a joining server and a joining agent. VERIFIED-VM on both (`<distro>-hostile` K34, `<distro>-probe-rejoin` with three servers).
- A side effect to know: a pin on the root lets the cluster CA below it be rotated without new tokens. A new root needs new tokens on every node.
- T4, a token stamp (NOT-RUN): a oneshot before the server unit writes `sha256(token file)` to `<dataDir>/server/.token-stamp-<i>` after a good start, and at the next start refuses with a clear message when the etcd directory exists and the stamp differs ("the server token var changed; run `<distro> token rotate --new-token …` on a live server first, runbook …"). The distro would fail anyway, later and less clearly, on every server at its next restart.

### 3.9 Option surface

| Change | Option | Type | Default | Level | State |
|---|---|---|---|---|---|
| remove | `network.ipv4`, `network.ipv6` (`node-interface.nix`) | – | – | manual mode is gone | step 3 |
| change | `network.fabric` (`cluster-interface.nix`) | submodule `{service, instance}`, not nullable, no default | required | cluster | step 3 |
| change | `domain` (`cluster-interface.nix`) | `nullOr (strMatching "[a-z0-9]([-a-z0-9.]*[a-z0-9])?")` | `null` | cluster | step 3 |
| change | `network.{pod,service}CIDRv{4,6}` | `nullOr` the CIDR types of `lib/ip.nix` | `null` | cluster | step 3 |
| change | rke2 `profile` (`services/rke2/default.nix`) | `nullOr (enum ["cis"])` | `null` | cluster (add to parity) | step 9 |
| add | `outsideIngress.policy` | `bool` | `true` | cluster | prototype |
| add | `nodePorts.allowedSources` | `listOf` CIDR (both families) | `[]` | cluster | prototype (as `listOf str`; type it in step 7) |
| add | `nodePorts.admission` | `bool` | `true` | cluster | prototype |
| add | `podSecurity.enforce` | `enum ["privileged" "baseline" "restricted"]` | `"baseline"` | cluster | prototype |
| add | `firewall.kubeletFromPods` | `bool` | `false` | cluster | step 4 (the matrix takes the argument) |
| add | `audit.enable` | `bool` | `true` | cluster | step 9 |
| keep | `clusterInit` | `bool` | `false` | node. New meaning: the server that founds the cluster when no member remembers one, and that applies the bundle. | – |
| keep | `configOverrides` | `attrs` | `{}` | add the new owned keys to the refusal list | – |

Parity: `assertions.nix` gets `nodePorts`, `outsideIngress`, `firewall`, `audit`, `podSecurity` and `distro.extraOptions` names (K-A8).

### 3.10 Eval assertions (new or changed)

- `network.fabric` is set and every member has a `node_transport` export (already asserted when a fabric is set; now unconditional). Delete the "bgp needs fabric" assertion and the manual branches.
- Every `nodePorts.allowedSources` entry parses as a CIDR.
- `cilium.helmValues` may not turn off `extraConfig."bpf-lb-source-range-all-types"` (prototype: `cilium.nix` `contradictions`). Add the same for `bpf.hostLegacyRouting`, `nodePort.addresses`, `extraConfig."bpf-lb-external-clusterip"`, `hostFirewall`: each one moves an enforcement point this design relies on.
- `configOverrides` may not set `pod-security-admission-config-file` (rke2), `profile`, or a `kube-apiserver-arg` entry that starts with `admission-control-config-file` or, once audit lands, `audit-`.
  - Prototype state: on k3s the service owns `kube-apiserver-arg` (it holds one entry), so an operator cannot set that key at all. Step 9 must merge the lists instead: owned entries first, then the operator's, and refuse only the two prefixes.
- The bundle check `clustermesh-apiserver Service type` expects `LoadBalancer` on every method (prototype: `bundle.nix` `expectedType`).
- rke2 `profile` equal on every member.
- Keep: one `clusterInit`, never two servers, the instance-name regex, CIDR rules.

### 3.11 L8: Pod Security default (owner decision O4)

VERIFIED-VM `k3s-hostile` and `rke2-hostile` K50–K53.

Owner decision: enforce `baseline`, warn `restricted`, a namespace label opts out.

One admission configuration file on every server, `/etc/rancher/<distro>/pod-security.yaml`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: baseline
        enforce-version: latest
        warn: restricted
        warn-version: latest
        audit: restricted
        audit-version: latest
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces: [kube-system]
```

- Rendered by `lib/kube-cluster/service.nix` (prototype, booted): `environment.etc."rancher/<distro>/pod-security.yaml"` with `mode = "0644"`, so it is a real file and not a link into `/etc/static` (rke2 mounts it into the API server's static pod). `enforce` comes from `podSecurity.enforce`.
- k3s (`services/k3s/default.nix` `serverConfig`): `kube-apiserver-arg = ["admission-control-config-file=/etc/rancher/k3s/pod-security.yaml"]`. The API server logs it in its command line and loads the `PodSecurity` plugin.
- rke2 (`services/rke2/default.nix` `serverConfig`): `pod-security-admission-config-file = "/etc/rancher/rke2/pod-security.yaml"`. VERIFIED-VM `rke2-hostile` K50–K53.
- The opt-out is the standard label: a namespace with `pod-security.kubernetes.io/enforce=privileged` takes privileged pods. The defaults apply only where a namespace has no label of its own.
- `kube-system` is exempt: the Cilium agent is privileged and on the host network. Nothing else is exempt; `cilium-secrets` holds no pods.
- In the VM, in a fresh namespace:
  - a privileged pod: `Error from server (Forbidden): pods "privileged" is forbidden: violates PodSecurity "baseline:latest": privileged`;
  - a host-network pod: `violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true)`;
  - a plain busybox pod: admitted, with `Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false …`;
  - a privileged pod in a namespace labelled `enforce=privileged`: admitted;
  - every pod of `kube-system` runs (Cilium agent, operator, CoreDNS, the ClusterMesh API server).
- This is policy, and it is the owner's decision (O4). Record it as a SPEC decision before code.

### 3.12 Contracts with the other areas

Proven by the gateway and netif probe rounds of 2026-11-27, on their prototypes. Not run again here. Each one is an obligation of the kube code or of its suites.

| Contract | Kube obligation | Proof in the other round |
|---|---|---|
| New fact `clan.networkFacts.forwardLinks` (a list of interface-name patterns, declared in `lib/kube-cluster/network-facts.nix`). A CLAT host forwards IPv6 by default-deny (`table inet clat`, chain forward, final `counter drop` with the comment `clat-forward`); only `clat0` and the forward links pass | Every cluster member sets `clan.networkFacts.forwardLinks = ["cilium*" "lxc*"]` (in `lib/kube-cluster/service.nix`, beside the nft table). Without it the pods of a CLAT node are cut off. One nix-unit assertion: a cluster member's `forwardLinks` holds both patterns | `k3s-clat` with that value: the `clat-forward` counter stays 0 and all pod traffic works |
| `clan.networkFacts.fabricInside`: the CLAT link and the NAT64 link always; a router zone only with `zones.<name>.fabric = true` | The nft table `kube-<i>` (§3.3) reads the fact as it does in the prototype. Nothing else | `router-kube`: a zone with `fabric = true` reaches pods, a default zone does not |
| The same, seen from the policy of §3.4 | **Open.** `fabricInside` opens L1 only. For Cilium a host of a router zone is `world`, so with the policy it reaches labelled pods only. `router-kube` ran without the policy; with both together: NOT-RUN. Decide in the PR of step 7: either the README says "a zone with `fabric = true` reaches pods labelled `clan.lol/outside=allow`", or the policy gets an allow list of zone prefixes (those can be delegated prefixes, known only at run time, which speaks for the README) | – |
| netif target design: the unit `netif-dhcpcd-<if>.service` becomes `netif-dhcpcd@<if>.service`; `netif-guard.service` is gone (one transaction in `ifstate.service`) | No kube module names either unit. Two suites do: `lib/kube-cluster/tests/vm/join.nix` and `data-plane.nix` assert `systemctl is-active netif-guard.service` in their netif variants. Replace both with a behaviour check when netif step 5 lands | netif probes |
| netif: accepting router advertisements is opt-in per link (`ra = true`) | A kube IPv6 fixture that gets its default route from an RA must set `ra = true` on that link (`<distro>-join-netif`, `-data-plane-netif`, the CLAT and router fixtures) | netif probes |
| netif: the sysctl baseline and the ARP keys | None. They ran beside Cilium with no effect | `k3s-join-netif`, `k3s-data-plane-netif` |
| Reverse-path filtering is not netif's | Kube keeps `net.ipv4.conf.all.rp_filter = 2` and its `extraReversePathFilterRules` (`service.nix`) | `specs/target-design.md` §3 |

A rule both rounds learned, and this file follows: **a hostile verdict needs a positive control.** The attack must be seen to work somewhere, or `SAFE` can be empty (two RA verdicts on main were). The controls of the new verdicts are in §6.

## 4. Verdicts on the ideas

| Idea | Verdict | Reasoning | Cost |
|---|---|---|---|
| (a) default-deny node firewall | **Done in the prototype.** | Input is already default-deny (NixOS firewall); the by-source accepts come from one matrix (§3.2). The real hole was forwarding to pods, which is default-accept: cluster destinations are default-deny by inside-link list (§3.3), and pods refuse `world` (§3.4). A full `filterForward` default-deny is rejected: conntrack sees half of the BPF-routed flows. | Small. |
| (b) NodePort / LB VIP by source | **Accept, without a new component** (owner decision O3). | nft cannot see it, the host firewall cannot see it, and Kubernetes takes ranges on type LoadBalancer only. So: Cilium enforces ranges on every front, admission makes every front carry ranges (§3.5). All proven in VMs. | Medium: four bundle objects, one ConfigMap key, the mesh Service. No C code, no org-pkgs package. |
| (c) do pods need the API LB front | **No. Removed from the network.** | Only host-network clients dial it. Loopback (§3.6). | Small. Removes two firewall ports and a bind race. |
| (d) init guard redesign | **Accept: beacon + decider.** | A closed port is not evidence. A member's own statement is. Asking agents protects one-server clusters too. | Medium. One socket unit, one script, suite phases. NOT-RUN. |
| (e) tokens with CA pin | **Done in the prototype.** | The PKI exists before the tokens, so the pin is free. The pin is the root's hash, which the PKI already wrote (§3.8). | Small. |
| (f) manual-address mode | **Delete.** | D72: routed-fabric is the only transport. The mode is unbooted, pinned to `eth0`, has no pod routes, and is where four findings live (K-A4, K-A5, part of K-A7, the unguarded firewall branch). | Medium: many nix-unit fixtures move to a fabric fixture. Net code removal. |
| (g) rke2 `cis`, Pod Security | **Pod Security: done in the prototype** (owner decision O4). `cis`: refine. | `profile` becomes an enum, cluster-level. It gets a suite (`rke2-cis`) or it is removed: no untested hardening mode. | Medium. |
| (h) typed options | **Accept.** | With (f) the address options vanish. Type the rest (§3.9). | Small. |
| (i) etcd, control plane, kubelet, audit | **Mostly done.** | etcd: 2381 dropped. Kubelet: 10250 for servers only (K42 proves logs and exec). Audit: on by default, metadata level, rotated: NOT-RUN. | Small each. |
| (j) HAProxy vs the distro's client LB | **Keep HAProxy, on loopback.** | One endpoint that is the same on servers and agents, `/readyz` with mTLS, an HA first join. | None beyond (c). |

Own ideas:
- **Token stamp** (§3.8, T4). Small. NOT-RUN.
- **Remove `trustedInterfaces`** (§3.2). Done, VERIFIED-VM.
- **Deploy order rule** in the runbook: deploy existing members before a new member (T5). A new member's address reaches the old members' source sets only when they are deployed. Doc only.

## 5. Deleted or simplified

Deleted:
- The NodePort tcx guard of the earlier draft (C program, loader, three units, an org-pkgs package). Owner decision O3.
- Manual-address mode: `network.ipv4/ipv6`, every `fabric == null` branch in `service.nix`, the `["eth0"]` fallbacks, the "bgp needs fabric" assertion, the unguarded firewall branch.
- Firewall rows: 2381, the API front, the supervisor front, the kubelet and the health port for pods. `mkInputRules` with its `memberOnlyPorts` / `clusterPorts` arguments (the prototype keeps the function unused beside the matrix; step 4 deletes it).
- The guard's port probing and `INIT_GUARD_PORT`.
- `trustedInterfaces` for `cilium_host` / `cilium_net`.
- HAProxy's ordering after `ifstate.service`.
- README quick starts that set `network.fabric = null` (K-A4): rewrite on a one-machine fabric. Keep a nix-unit test that evaluates the README inventory with zero failed assertions.

Not deleted, against the earlier draft: `ca-hash` in the PKI generator. It is the token pin (§3.8).

Tests that pin a mechanism today and should check behaviour instead:

| Today | Problem | Becomes |
|---|---|---|
| `services/rke2/tests/eval-tests.nix` and k3s (`test_firewallManualBySource`, `test_firewallFabricAgent`): compare nft rule text | Any renderer change breaks them; one of them pins the K-A2 leak as correct | nix-unit on the matrix rows (data). Behaviour in K10, K20, K24. |
| nix-unit tests that expect `clusterPorts` with the HAProxy port, the kubelet and 4240 for pods, or `2381` | Pin the old rows | The rows of §3.2. |
| nix-unit tests on HAProxy `bind <node address>` and on `extraHosts` with the node address | Pin the address | `bind 127.0.0.1` / `[::1]`, `source <node address>` on the server lines; K27 in the VM. |
| nix-unit tests that expect a 32-character token or `services.k3s.clusterInit = true` | Pin the old token and the flag | Token matches `^K10[0-9a-f]{64}::(server\|node):[0-9a-f]{64}$`; `clusterInit` false, `cluster-init = true` in the rendered config of the init server. |
| nix-unit and bundle tests that expect `clustermesh-apiserver` of type NodePort | Pin the type | Type LoadBalancer on every method, the class `clan.lol/node-port` on node-port exposure, `loadBalancerSourceRanges` present. |
| `lib/kube-cluster/tests/vm/join.nix`: `grep '^<node address> kubeapi-…'` in `/etc/hosts`; the rke2 agent's join port 8443 | Pins the address and the port | Done in the prototype: loopback entries, `ss` shows the two loopback binds, the rke2 agent joins on 9345. `k3s-join` and `rke2-join` pass. |
| `lib/kube-cluster/tests/vm/clustermesh-nodeport.nix`: Service type NodePort, `cilium clustermesh status` | Pins the type; the CLI cannot read a Service without an address | Done in the prototype: type LoadBalancer, the ranges hold all four members, `cilium-dbg status` shows `1/1 remote clusters ready`. |
| `test_initGuardWaitsForFabric`: environment variable values | Pins the probe mechanism | Unit ordering only. Behaviour in `<distro>-ha`. |
| `lib/kube-cluster/tests/vm/ha.nix`, the init-guard phases: drop-ins that point the guard at port 2381 | Tests the mechanism through a fake. Port 2381 is closed now, so the phase "reachable peers with no API let the server start" fails on the prototype | Real phases: stop a peer's service, wipe the init server's etcd directory, see the refusal; then the rejoin (§7). Until step 5, that phase must use a port that servers still open to servers. |
| `lib/kube-cluster/tests/vm/single.nix`: a list of six closed ports | A deny-list | The hostile suite's full scans with an allow-list of expected open ports. |
| `lib/kube-cluster/tests/vm/data-plane.nix`: NodePort does not answer on the underlay address; any `kubectl expose --type=NodePort` or NodePort Service in a suite | Misses the fabric path; the admission policy refuses the type | K08, K13, K17 as verdicts. Suites use type LoadBalancer, or label their namespace `clan.lol/service-sources=any` when the test is about something else. |
| `lib/kube-cluster/tests/eval-tests.nix` (`test_manualClusterBgpRequiresFabric`) | Tests a deleted mode | Deleted. |

Use `suite-snapshot` / `suite-compare` only for pure refactors. These changes alter node derivations on purpose; say so in each PR.

## 6. Hostile-suite verdicts

Body: `lib/kube-cluster/tests/vm/hostile.nix`. "outsider" = A1, "mallory" = A2. The first table is in the prototype's suite and ran.

| ID | Attacker | What it does | Safe outcome | k3s and rke2 |
|---|---|---|---|---|
| K05d | outsider, after `eth1` (the node LAN) was added to Cilium's `devices` and the agents restarted | `ip route add <pod4>/32 via <node LAN addr>; nc -z -w 3 <pod4> 8080`, for a pod on each node | fails | SAFE |
| K06d | same | `ping -c 2 -W 1 <pod4>` | fails | SAFE |
| K05o | same, the pod labelled `clan.lol/outside=allow` | `nc -z` | connects (the path is open; the policy closed it) | reachable (info) |
| K08 | outsider | `nc -z -w 3 <underlay addr> <nodeport>` | fails (was info) | SAFE |
| K10n | mallory | full TCP scan of each node address, both families | no NodePort and no LoadBalancer port open (was info) | SAFE (run 1 found the ClusterMesh API Service's NodePort open: §3.5 part 4) |
| K11f | mallory, `wg set … allowed-ips 0.0.0.0/0,::/0` and `ip route replace <pod>/32 dev <its fabric link> src <its fabric addr>` | `nc -z -w 3 -s <its fabric addr> <pod> 8080`, for a pod on the spine and a pod on a leaf, both families | fails | SAFE |
| K13 | mallory | `nc -z -w 3 <node addr> <nodeport>`, both families, both nodes | fails (was info) | SAFE |
| K13m | a member host | the NodePort on another member | connects | SAFE |
| K13p | a pod | the NodePort on a member | connects | SAFE |
| K17 | mallory | the LoadBalancer port (Node IPAM gives it the node addresses) | fails | SAFE |
| K18 | cluster user | `kubectl expose --type=NodePort`; a LoadBalancer Service with `0.0.0.0/0` | both refused by `clan-service-sources` | SAFE |
| K20, K21 | pod | scan each node address | open on a server: `[6443]`; on an agent: `[]`; Service fronts allowed | SAFE |
| K27 | member, mallory; `ss` on the node | `nc -z -w 3 <node addr> 7443` (rke2: and 8443) | fails; `ss -Hltn` shows `127.0.0.1` and `[::1]` only | SAFE |
| K34 | on each node | token files; the journal | every token starts with `K10`; no "does not include a CA hash" line | SAFE |
| K41 | members | `nc -z <other member> 4240`, both families; `cilium-dbg status` | connects; `Cluster health: 2/2 reachable` | SAFE |
| K42 | operator | `kubectl exec` and `kubectl logs` on a pod of the agent | work | SAFE |
| K50 | cluster user | a privileged pod, a host-network pod, in a fresh namespace | refused with `violates PodSecurity "baseline:latest"` | SAFE |
| K51 | cluster user | a plain pod in a fresh namespace | admitted, with a warning that names `restricted` | SAFE |
| K52 | cluster user | a privileged pod in a namespace labelled `pod-security.kubernetes.io/enforce=privileged` | admitted | SAFE |
| K53 | – | `kubectl -n kube-system get pods` | every pod Running | SAFE |

Positive controls: what shows that a `SAFE` above is not empty.

| Verdict | Its control |
|---|---|
| K05d, K06d | K05o in the same phase: the labelled pod answers on the same path. And `k3s-probe-net` phase B: without the policy the same command connects |
| K11f | `k3s-probe-net`: the same forced route connects in phases A and B, and still reaches the labelled pod in phase C. In the hostile suite itself only "the listener answers a pod" is asserted: add K11o |
| K10n, K13, K17 | K13m and K13p in the same phase (a member and a pod connect). `k3s-probe-net` `lb-open` and `lb-mallory`: mallory connects when the ranges allow it |
| K18 | The suite's own `web` Service is admitted as type LoadBalancer in the same phase |
| K27 | The node itself joined and runs through that front; `ss` shows the listener |
| K34 | `k3s-probe-net` run 3: a pin that does not match is refused |
| K50 | K51 and K52 in the same phase |
| K08 | In the suite since round 63: K13m and K13p (a member and a pod reach the same NodePort on a node address). A NodePort never answered on an underlay address (D69 limits NodePorts to the node addresses); the verdict does not prove the source ranges |
| K20, K21 | The scan finds 6443 on a server, so the scan works |

Still to add (NOT-RUN):

| ID | Attacker | Command | Safe outcome |
|---|---|---|---|
| K11o | mallory, pod labelled `clan.lol/outside=allow` behind a LoadBalancer Service whose ranges hold mallory, ETP Local | `nc -z -w 3 <vip> <port>` | connects (positive control for both opt-ins together) |
| K13a | mallory, after `nodePorts.allowedSources` holds its address (a second cluster fixture or a specialisation) and a Service names it | `nc -z` to the NodePort | connects |
| K13u | mallory | a UDP Service front | no answer |
| K13x | mallory | IPv6 with a hop-by-hop or destination-options header before TCP to a NodePort | fails |
| K28 | pod and mallory | `nc -z -w 3 <node addr> <beaconPort>` | fails |
| K28a | compromised agent (root on beta) | read the beacon of alpha: gets one word; write to it: ignored | no data beyond the one word |
| K29 | pod | `wget -T3 https://<server>:6443/v1-k3s/server-bootstrap` (rke2: `:9345/v1-rke2/…`) without and with a wrong token | 401 on k3s; no connection on rke2 |
| K35 | compromised agent (beta, root) | `nc -z alpha 2379`, `2380`; `curl -k --cert <kubelet cert> https://alpha:6443/api/v1/secrets` | etcd fails; API answers 403 |
| K36 | compromised agent | join a second node as a **server** with the agent token | refused |
| K40 | outsider | full TCP scan and UDP probes (51820-range, 4789, 8472) of the underlay address after all changes | only the fabric WireGuard port is `open|filtered` |

Every GAP in `runs/*-hostile.verdicts.txt` is SAFE on the prototype: K05, K06, K20, K21.

## 7. Failure modes and stability

| Event | Behaviour in the target design | Proof |
|---|---|---|
| Init server lost (powered off) | Other servers keep quorum. Every node's HAProxy marks it down and uses the others. Nothing at runtime needs the init server. Bundle changes wait until it is back or `clusterInit` moves. | `<distro>-ha`: `alpha.crash()`, then beta and gamma Ready, `kubectl create configmap` through beta, restart of the server unit on beta succeeds. NOT-RUN on the prototype. |
| Init server back with its data | Decider sees the etcd directory, starts. | same suite: alpha boots, rejoins, three etcd members. |
| Init server back **without** data | Beacons answer `data`. Decider refuses with the rejoin text. No second cluster. | same suite: wipe `server/db`, start fails, message names the peers; `kubectl get nodes` on beta unchanged. NOT-RUN. |
| Rejoin | Operator deletes the node and its node-password secret, creates the marker. Decider writes the drop-in; the server joins. Next start: data exists, drop-in removed. | The upstream half is probe P4 (§9). The decider half: NOT-RUN. |
| Init server without data, peers' services stopped | Beacons still answer `data` (socket activation). Refuses. This is the K-A3 case. | NOT-RUN. |
| First install, all members empty | Every beacon says `empty`. Founds with no operator step. | `<distro>-ha` boot phase. NOT-RUN. |
| First install, a peer not installed yet | Silent peer. Waits 300 s, refuses, names the marker. Fail-closed, as today. | NOT-RUN. |
| Cold boot of all nodes | Every server has data: deciders pass at once, etcd forms quorum when two are up. HAProxy starts without the fabric (loopback) and retries backends. Kubelets retry. | In every suite of this round HAProxy started before the fabric held the node address, marked the backends down, then up (journal lines in `probes/kube/runs/`). The full phase (crash all, start all): NOT-RUN. |
| One-server cluster, server disk lost, agents alive | Agents answer `joined`. Refuses. Operator restores a snapshot or creates the found marker knowingly. | NOT-RUN. |
| Token var regenerated without rotation | Stamp check refuses the next server start with the runbook line. The running server is untouched. | NOT-RUN. |
| A token with a pin that does not match the served CA | The node trusts no root, fails at `/cacerts`, retries every 2 s, never sends the secret, never joins. The servers are untouched. | VERIFIED-VM `k3s-probe-net` run 3. |
| Agent token changed | Running agents keep working (node passwords). New joins need the new token on servers and the joiner. | Doc only. |
| Partial deploy, member added | Old members do not list the new address yet: its joins and beacons are refused there. No port opens. Deploy old members first. The default source ranges of Services that exist do not hold it either (§3.5). | nix-unit: member set per node; doc. |
| Partial deploy, member removed | Its address stays allowed on undeployed nodes until they are deployed. | Doc: deploy all members after a removal. |
| HAProxy down on a node | That node's kubelet and Cilium agent lose the API; the datapath keeps forwarding; `Restart=always` brings it back. Other nodes are unaffected. | `<distro>-join`: `systemctl kill haproxy` on beta; a pod-to-pod connection across nodes keeps working; node Ready again. NOT-RUN. |
| A server's API down | Every HAProxy fails over within `fall 3 × inter 5s`. Sessions to it are cut (`on-marked-down shutdown-sessions`). | exists in `<distro>-ha`. |
| Cilium agent restarts on a node | For some seconds a device may hand packets to the stack instead of delivering them. L1 then judges them; L2 judges them when delivery is back. Pod traffic keeps flowing. | `k3s-probe-net` run 1 (alpha, phase B). |
| An admission policy cannot be evaluated | `failurePolicy: Fail`: Service writes in judged namespaces are refused until it can. Running Services keep working. | By construction; NOT-RUN as a phase. |
| Policy objects deleted by a cluster admin | S3 falls back to L1; S5 falls back to nothing for new Services. The bundle re-applies them on the next deploy that changes the bundle. | Doc. |

## 8. Implementation order

Each step: SPEC and `documentation/` first (hard rule 3), then code, `fmt`, `check`, the named suites with `--remote --rebuild`. One PR per step. `probes/kube/prototype.patch` holds working code for steps 1, 4, 6 (tokens), 7, 8 and 9 (Pod Security); cut each step out of it. The prototype did **not** run `check`: every step must fix the nix-unit tests of §5 that it breaks.

1. **Land the hostile suites and the minimal prototype.** **Done in round 63 (SPEC.md D74).** `patches/fixes-fabric-kube.patch` (L1, supervisor front member-only; its routed-fabric and gateway parts landed with fabric steps 1 and 2 as D73) and `patches/fix-rke2-package.patch` (K-A1) with its nix-unit test from `reviews/kube.md` (both distros: `test_packageOverrideIsRuntime`). K-A10 text fixed (SPEC.md §6.6, §6.12, the two-server runbook line).
   Files: `lib/kube-cluster/{service,network-facts,firewall}.nix`, `services/rke2/default.nix`, `lib/kube-cluster/tests/vm/hostile.nix`, `services/{k3s,rke2}/tests/vm/hostile.nix`.
   The suite merges the kube prototype and the fabric prototype's additions (`mallory` as an `access = "client"` leaf, K40a, K40, K41, P5, P6). Every verdict group has a `control(...)` that gates the suite. What a later step closes is an `info` line naming the step, and that step turns it into a verdict: K10n, K13, K17, K18 (step 8); K11f to a pod on the spine, K41, K05d, K05o (step 7); K27 loopback binds, a member that reaches another member's front (step 4); K20 and K21 narrow from `[6443, 7443, 10250, 4240]` to `[6443]` (step 4); K34 (step 6); K50–K53 (step 9).
   Proof: `k3s-hostile`, `rke2-hostile` print no GAP and no failed control.
2. **Probes.** Done on 2026-11-27; results in §9. Record the facts in `documentation/docs/reference/upstream-facts.md` (the wording is in the session report). The probe suites `<distro>-probe-net` and `<distro>-probe-rejoin` are throwaway: do not land them.
3. **Delete manual mode, type the options** (f, h, K-A4, K-A5, K-A7, K-A8). Rewrite READMEs on a one-machine fabric; add the README-evaluates test. **Done in round 67 (SPEC.md D76)**, in one PR with step 4. The quick start is `services/<distro>/tests/readme-inventory.nix`, shown verbatim in the README (`test_readmeQuickStart`). The kube guard table is rendered on every member.
   Files: `lib/kube-cluster/{cluster-interface,node-interface,service,assertions,firewall}.nix`, both READMEs, the nix-unit fixtures.
   Proof: `check`; every existing suite still passes (they all use a fabric).
4. **HAProxy on loopback, the firewall matrix, kubelet and health rows, no 2381, no `trustedInterfaces`** (c, j, a, i). **Done in round 67 (SPEC.md D76).** `k3s-hostile` and `rke2-hostile`: K20 and K21 allow `[6443]` on a server and nothing on an agent; K27 is three verdict groups with controls (loopback binds, a member does not reach another member's front, a fabric leaf outside the cluster does not reach a front). The `ha` suite's "peers refuse" phase points the guard at a port the peers reset (2399) until step 5.
   Files: `lib/kube-cluster/haproxy.nix` (binds, `source`), `lib/kube-cluster/firewall.nix` (`matrix`, `renderMatrix`; delete `mkInputRules`), `lib/kube-cluster/default.nix` (exports), `lib/kube-cluster/service.nix` (`extraInputRules`, `extraHosts`, no `trustedInterfaces`, no `after = ["ifstate.service"]` on HAProxy, option `firewall.kubeletFromPods`), `lib/kube-cluster/tests/vm/{hostile,join}.nix`.
   Tests that change: the firewall, HAProxy and `extraHosts` rows of §5; the `ha.nix` phase on port 2381.
   Also in this step: the rke2 agent's supervisor front on 9345 (`haproxySupervisorPort` in `service.nix`, §3.6).
   Proof: K20, K21, K27, K41, K42 in `<distro>-hostile`; `<distro>-single`, `-join` (pass on the prototype), `-ha`, `-data-plane`, `-clustermesh`.
5. **State beacon and decider** (d), with the `<distro>-ha` and `-join` phases of §7.
   Files: `lib/kube-cluster/nixos.nix` (`mkInitGuard` becomes the decider; a new `mkStateBeacon`), `lib/kube-cluster/service.nix` (`beaconPort`, the units on every member, `PEERS` = all members), `lib/kube-cluster/firewall.nix` (row `state-beacon`), `services/k3s/default.nix` (`clusterInit = false`, in the prototype).
   Proof: those phases; K28, K28a.
6. **Tokens with the CA pin, and the token stamp** (e).
   Files: `lib/kube-cluster/vars.nix` (both generators, the `ca-hash` comment), `lib/kube-cluster/nixos.nix` (the stamp unit), `lib/kube-cluster/service.nix`.
   Note for existing vars: a changed generator script does not regenerate a var. No deployment exists, so nothing migrates; the suites generate fresh vars.
   Proof: K34, `<distro>-join`, the stamp phase.
7. **The outside-to-pods policy** (L2).
   Files: `lib/kube-cluster/bundle.nix` (`mkOutsidePolicyResource`, the custom type, `outsidePolicy`), `lib/kube-cluster/mesh.nix` (the pod label), `lib/kube-cluster/cluster-interface.nix` (`outsideIngress.policy`), `lib/kube-cluster/service.nix`, both READMEs (the label).
   Proof: K05d, K06d, K05o, K11f in `<distro>-hostile`; every clustermesh suite.
8. **Service fronts by source** (L3). No org-pkgs PR.
   Files: `lib/kube-cluster/cilium.nix` (`extraConfig`, `contradictions`), `lib/kube-cluster/bundle.nix` (`profilePatches`, `knownProfilePaths`, `mkServiceSourceResources`, `serviceSources`, `expectedType`), `lib/kube-cluster/mesh.nix` (`sourceRanges`, the Service patch), `lib/kube-cluster/cluster-interface.nix` (`nodePorts.allowedSources`, `nodePorts.admission`), `lib/kube-cluster/service.nix`, `lib/kube-cluster/tests/vm/{hostile,clustermesh-nodeport}.nix`, both READMEs.
   Tests that change: every suite that creates a NodePort Service (§5); the bundle and mesh nix-unit tests on the Service type.
   Proof: K08, K10n, K13, K13m, K13p, K17, K18, then K11o, K13a, K13u, K13x; `<distro>-clustermesh`, `-clustermesh-nodeport`, `-clustermesh-external`, `-clustermesh-selective`, `-data-plane`.
9. **Pod Security default, audit, the `rke2-cis` suite** (g, i).
   Files: `lib/kube-cluster/cluster-interface.nix` (`podSecurity.enforce`, `audit.enable`), `lib/kube-cluster/service.nix` (the file, the list merge for `kube-apiserver-arg`), `services/{k3s,rke2}/default.nix` (`serverConfig`), `lib/kube-cluster/assertions.nix` (the refusal list, parity), a new `services/rke2/tests/vm/cis.nix`.
   Proof: K50–K53; `rke2-cis`; the audit log exists and rotates.

Steps 3–6 are independent of steps 7–9. Steps 7 and 8 are independent of each other, but the READMEs must explain both gates together (§3.4).

## 9. Probes and open risks

Probe results. Evidence: `specs/probes/2026-11-27/kube.md` and `probes/kube/runs/`.

| ID | Question | Result |
|---|---|---|
| P1 | Is BPF host routing active, and does A1 reach a pod through a link that is a Cilium device, past the nft table? | **VERIFIED-VM** `k3s-probe-net` phases A, B: `Host: BPF`; `CONNECTS` with the table present; the netfilter counters do not move. §3.1. |
| P2 | Does a clusterwide policy with only `ingressDeny: world` and `enableDefaultDeny.ingress: false` (a) drop outside-to-pod, (b) change no other traffic, (c) let mesh peers and members through, (d) do the label selectors work? | **VERIFIED-VM** (a), (b), (d): `k3s-probe-net` C, C2; (c): `k3s-clustermesh-nodeport`. Also closes O2. §3.4. |
| P3 | tcx ordering of a custom guard ahead of Cilium. | **NOT-RUN, withdrawn.** Owner decision O3: no custom eBPF. Replaced by §3.5, which is VERIFIED-VM. |
| O3 | Do source ranges with `bpf-lb-source-range-all-types=true` hold on NodePort and LoadBalancer fronts, and can admission require them? | **VERIFIED-VM** `k3s-probe-net` D, E; `k3s-hostile`. One form **REFUTED**: `ApplyConfiguration` cannot set the field; `JSONPatch` does. §3.5. |
| P4 | Does a drop-in `config.yaml.d/90-rejoin.yaml` beat `cluster-init: true`; does a wiped server rejoin; does `services.k3s.clusterInit = false` with `cluster-init: true` in the file found a cluster? | **VERIFIED-VM** on both distros, with one condition (delete the node object first) and two rules for the decider that the draft had wrong (**REFUTED**, §3.7). Steps below this table. |
| P5 | Do both distros take full-format tokens on the founding server and on joiners; what is the pin; does a join against a wrong CA fail? | **VERIFIED-VM** on both (`<distro>-hostile` K34, `<distro>-probe-rejoin`). The pin: **REFUTED** as drafted, it is the root's DER hash (`ca-hash`). A wrong pin fails closed: `k3s-probe-net` run 3. §3.8. |
| P6 | Do 4240 from members only and 10250 from servers only suffice? | **VERIFIED-VM** `k3s-hostile` and `rke2-hostile` K41, K42. On rke2 `logs` and `exec` also need the agent's tunnel (§3.6). |
| P7 | Do host-network pods read the node's `/etc/hosts`, so the kubeapi name resolves to loopback in the Cilium agent and operator? Does anything else dial a front? | **VERIFIED-VM** `k3s-probe-net` (`grep kubeapi /etc/hosts` in the agent); every suite of this round runs Cilium through the loopback front. **REFUTED** for rke2 agents: their tunnel dials the servers on the join URL's port (§3.6). |
| O4 | Does a Pod Security default through the distro's admission configuration work, with `kube-system` exempt and the label as opt-out? | **VERIFIED-VM** `k3s-hostile` and `rke2-hostile` K50–K53. §3.11. |

Probe P4 in steps, both distros (`k3s-probe-rejoin` run 3, `rke2-probe-rejoin` run 1). Three servers; the init server alpha is stopped, its `server/db` is removed, the machine is powered off and started.

| Step | k3s | rke2 |
|---|---|---|
| The drop-in (`server:`, `cluster-init: false`) makes the init server a joiner | VERIFIED-VM: `Managed etcd cluster not yet initialized`, then a request for `/v1-k3s/server-bootstrap` | VERIFIED-VM: `Managed etcd cluster not yet initialized`. rke2 does not know the key `cluster-init` at all (`Unknown flag --cluster-init found in config.yaml, skipping`): a server founds when it has no `server:`. The `server:` line of the drop-in is what counts |
| The first starts fail until the node's HAProxy has a backend; the unit restarts | VERIFIED-VM (`…/server-bootstrap": EOF`, twice) | VERIFIED-VM (three starts) |
| The node object is still there | `etcd cluster join failed: duplicate node name found, please use a unique name for this node`, at every start. etcd keeps its three old members, alpha is `NotReady`. No new cluster | the same lines |
| `kubectl delete node alpha` on a live server, nothing else | The node-password secret is gone with it. A live server removes the stale etcd member. alpha joins at its next restart: `Adding member alpha-237d5231=… to etcd cluster [beta-… gamma-…]`; three members; three Ready nodes; the first cluster's ConfigMap reads `first` on alpha | the same: `Adding member alpha-2a7ea013=… to etcd cluster [gamma-… beta-…]`; three members; three Ready nodes; `first` |
| Restart with data, the drop-in left in place | `restart rc=0; API back: YES` | `restart rc=0; API back: YES` |
| Restart with data, the drop-in removed by hand | `restart rc=0; API back: YES`, the same three members | the same |
| The guard removes the drop-in when the etcd directory exists (earlier draft) | REFUTED, run 2: `Starting etcd for new cluster, cluster-reset=false` after a failed join | not run again; the rule is gone |

The existing suites on the prototype: `k3s-join` (365 s), `k3s-single` (428 s), `k3s-clustermesh-nodeport` (550 s), `rke2-join`, `rke2-single` pass. `<distro>-ha`, `-data-plane`, the other clustermesh suites and every gateway and netif suite that boots a cluster: NOT-RUN on the prototype.

rke2, on the same prototype:

| What | Result |
|---|---|
| `rke2-hostile` | **VERIFIED-VM**, run 2: 109 verdicts safe, no gap, `RKE2_HOSTILE_OK`. That includes K05d, K06d, K08, K10n, K11f, K13, K13m, K13p, K17, K18, K20, K21, K24, K27, K34, K41, K42, K50–K53 |
| Loopback fronts | **REFUTED** as first drafted: an agent's tunnel dials `<server>:<port of its join URL>` (§3.6). Fixed by giving an agent's supervisor front the port 9345; then VERIFIED-VM |
| Full-format tokens | **VERIFIED-VM**: the founding server and the agent (`rke2-hostile` K34), three servers (`rke2-probe-rejoin`). The pin `46c47609…` is not the file hash `59f59df1…` |
| A wrong pin on rke2 | NOT-RUN (the probe's hand-started agent stopped earlier, on `no default routes found`). rke2 uses the k3s client package [k3s-src]; k3s is VERIFIED-VM |
| Pod Security through `pod-security-admission-config-file` | **VERIFIED-VM** K50–K53, with the same messages as k3s |
| The policy, the source ranges and the admission policies | **VERIFIED-VM** through the hostile verdicts. The phase-by-phase probe (`rke2-probe-net`) is NOT-RUN: the Cilium build and its configuration are the same on both distros |
| `rke2-join`, `rke2-single` | **VERIFIED-VM**: both pass on the prototype (479 s, 359 s). `join.nix` now expects the agent's join URL on port 9345 (§3.6) |
| `rke2-clustermesh-nodeport`, `rke2-ha`, `rke2-data-plane` on the prototype | NOT-RUN |
| `profile = "cis"` | **VERIFIED-VM** that it boots (`rke2-probe-cis`, one server): the unit runs `rke2 server --profile=cis`, the node and the Cilium agent become Ready, etcd runs as the user `etcd`, the API server has the audit flags and our `--admission-control-config-file`, a plain pod runs in a fresh namespace and a privileged one is refused. The profile also creates `default-network-policy` objects in `default`, `kube-public` and `kube-system`, which Cilium enforces. A multi-node suite (`rke2-cis`, step 9): NOT-RUN |

Side findings of the probes (not part of this design; each is one line in a config renderer):
- rke2 ignores two keys the service renders: `Unknown flag --cluster-init found in config.yaml, skipping` and `Unknown flag --disable-helm-controller found in config.yaml, skipping`.
- A k3s server ignores `disable-apiserver-lb`: `Unknown flag --disable-apiserver-lb found in config.yaml, skipping`.

Verified in code or source (no probe needed):
- Only host-network Cilium pods use the API front. [code, manifest]
- NodePort DNAT precedes the host firewall; host policy covers host destinations only. [cilium-src]
- The service path has a per-Service source check only. [cilium-src]
- `enable-tcx: "true"`, `enable-host-firewall: "false"`, `bpf-lb-external-clusterip: "false"` are the manifest's values; the bundle now sets `bpf-lb-source-range-all-types: "true"`. [manifest, prototype]

Open risks:
- **L2 changes how exposure works.** An unlabelled backend behind a Service whose ranges hold an outside source answers on some nodes only. The READMEs must lead with the label.
- **The admission policy changes how Services are written.** `type: NodePort` is refused; charts that create one need `type: LoadBalancer` or a namespace labelled `clan.lol/service-sources=any`. List it beside the other switches.
- **`cilium clustermesh status` does not work on node-port exposure** (§3.5). Owner decision O10 (SPEC.md H22): keep the LoadBalancer Service with ranges on every exposure mode; `cilium-dbg status` replaces it there. The plain NodePort behind mTLS is rejected.
- **Spines.** A spine can forge member sources. No rule here stops it; TLS, tokens and mTLS do. State this in SPEC §6.12. A spine is also the node that answers a LoadBalancer address for a leaf's traffic and judges its ranges.
- **Day-2 workloads** that need a privileged pod, the kubelet from a pod (metrics-server), a NodePort, or traffic from outside now need an explicit option or label. That is the intent; list the switches in one README table: `pod-security.kubernetes.io/enforce` (namespace), `firewall.kubeletFromPods` (option), `clan.lol/service-sources=any` (namespace), `nodePorts.allowedSources` (option), `clan.lol/outside=allow` (pod or namespace).
- **k3s serves the supervisor on 6443**, which pods must reach for the API. The token is the only guard there (K29). No design here changes that.
- **The prototype never ran `check`.** nix-unit tests that pin the old rows, binds, token length and Service type fail on it (§5).
