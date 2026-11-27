# Best-design target: k3s / rke2 services (`lib/kube-cluster`, `services/{k3s,rke2}`)

> **Status: target design, not implemented** (SPEC.md round 61). Nothing
> here was run unless a line says "VERIFIED-VM" or names a suite verdict.
> Parts marked "owner decides" are proposals. The index, the cross-area
> contracts and the build order are in `specs/target-design.md`.
> Evidence named here (`reviews/`, `runs/`, the `fix-probe` and
> `fix-nat64` prototypes, patches) is session evidence of the review of
> 2026-11-27. It is not in the repo; the session handoff maps it.

Base: main at `4d9c1aa`. Read-only review. Nothing was built, evaluated or booted.
Paths are relative to `the repo root`.
Builds on `reviews/kube.md` (K-A1..K-A10), the hostile verdicts in `runs/`, and the prototype worktree `fix-probe`.

Owner rule for this design: no consumers, no deployed machines. Tests, option names and code structure are free to change. Only safety behaviour is fixed.

## 0. How to read the evidence marks

- **[code]**: read in this repo at the given file:line.
- **[cilium-src]**: read in the Cilium 1.20.3 datapath source. It ships inside the agent image in the Nix store. To read it again:
  - image: `/nix/store/7f9vkaf6cf3hdn4a25fv5b0f8q85j9v5-docker-image-quay.io-cilium-cilium-v1.20.3.tar`
  - layer: `8eabe133386e20fe581c46c12d04197b25f19ea9a0bec01115f55e60aff044e4.tar`
  - files: `var/lib/cilium/bpf/bpf_host.c`, `lib/nodeport.h`, `lib/lb.h`, `lib/host_firewall.h`, `lib/nat.h`
  - command: `tar xOf <image> <layer> | tar x --wildcards 'var/lib/cilium/bpf/*'` (into a scratch directory).
- **[manifest]**: read in the committed Cilium manifest, `<org-pkgs>/manifests/cilium/1.20.3.yaml` (`cilium-config`).
- **[suite]**: a verdict of the hostile suites in `runs/`.
- **[assumed]**: upstream behaviour I could not read. Each one has a probe in §9.

The Go side of Cilium (the agent) is not in the store as source. Every claim about agent behaviour is **[assumed]**.

## 1. Threat model

| ID | Attacker | Has | Does not have |
|---|---|---|---|
| A1 | Outsider on a node's LAN | L2 access to an underlay link. Can route any destination to the node's underlay address. Can forge any source address. | Any key, token or certificate. No WireGuard key. |
| A2 | Fabric member outside the cluster (a leaf) | A valid fabric identity. Can send any destination over its fabric links. Its source is limited to its own prefixes (WireGuard AllowedIPs at the spine, prototype H1 in `services/routed-fabric/default.nix`). | Cluster credentials. A member source address. |
| A3 | Hostile pod | Code execution in an unprivileged pod. The default service account token. A pod-CIDR source address. | Host access. Other service accounts. |
| A4 | Compromised agent node | Root on one agent: the agent token, the kubelet credentials, the HAProxy health-check client certificate (`CN=haproxy-healthcheck`, no group, `vars.nix:220`), a member source address. | The server token, any CA key, the admin kubeconfig, etcd access. |

Trusted, out of scope:
- Servers. They hold the CA keys.
- Spines. A spine forwards for everyone and can forge a member source. Against a spine only TLS, tokens and mTLS hold. By-source rules do not.
- The operator and the deploy path.

## 2. Invariants

Each one is a hostile-suite verdict or a suite assertion. "Outside" means: not a member of this cluster, not one of its pods, not a ClusterMesh peer.

Safety:
- **S1** No TCP or UDP port of a node answers A1 on any underlay address. (K01, K02)
- **S2** No cluster port of a node address answers A1 or A2. Cluster ports: API, supervisor, kubelet, etcd, Cilium health, state beacon. (K03, K04, K10)
- **S3** No pod answers a new connection from outside on its pod address. This holds on every link, also on a link that is a Cilium device. Opt-out per pod or namespace by label. (K05, K06, K11 and the new K05d, K11f)
- **S4** No ClusterIP answers from outside. (K07, K12)
- **S5** A NodePort answers members and `nodePorts.allowedSources` only. (K13 becomes a verdict)
- **S6** A LoadBalancer Service's `loadBalancerSourceRanges` holds on every front of that Service, the NodePort included. (new K17)
- **S7** A pod reaches on a node only: the API on servers (6443). Nothing else, unless `firewall.kubeletFromPods` is on. (K20, K21 tightened)
- **S8** The API and supervisor load-balancer fronts listen on loopback only. No other host and no pod reaches them. (new K27)
- **S9** etcd answers servers only. The etcd metrics port answers nobody. (K24)
- **S10** The kubelet refuses anonymous requests. Its read-only port is closed. The API refuses anonymous reads of resources. The default service account reads nothing. (K22, K23, K25, K26)
- **S11** An agent holds no server token, no CA key, no admin kubeconfig, no mesh key. No secret is in the Nix store, in a process argument, or readable without root. (K30–K33)
- **S12** A joining node verifies the cluster CA before it sends its token. (new K34)
- **S13** A server never founds a second cluster while any member remembers the first one. (new suite phases, §7)
- **S14** BGP and BFD answer the link's peer only. (K20/K21 on 179; owned by routed-fabric, listed here because the kube hostile suite checks it)

Stability:
- **T1** Loss of any one server, the init server included, leaves the API reachable from every other node.
- **T2** A cold boot of all nodes at once brings the cluster back with no operator step.
- **T3** A node's HAProxy does not depend on the fabric being up to start.
- **T4** A changed token var never takes down a running control plane silently at the next restart.
- **T5** A partial deploy (some members on the old member list) never opens a port. It may delay a join.

## 3. Target design

### 3.1 Layers at a glance

| Layer | Mechanism | Closes | Evidence that it can work |
|---|---|---|---|
| L0 | NixOS firewall, input default-drop, by-source accepts rendered from one matrix | S1, S2, S7, S9 | [suite] today |
| L1 | nft table `kube-<i>`, prerouting raw: cluster CIDRs only from inside links | S3, S4 on links that are **not** Cilium devices | [suite] `*-hostile.with-fix` |
| L2 | One CiliumClusterwideNetworkPolicy: pods refuse `world` unless labelled | S3 on **every** link | [cilium-src] why nft cannot; policy semantics [assumed], probe P2 |
| L3 | A small tcx program ahead of Cilium on every Cilium device: NodePort range by source | S5 | [cilium-src] why nothing else can; attach order [assumed], probe P3 |
| L4 | `bpf-lb-source-range-all-types=true` | S6 | [manifest] key exists, [cilium-src] check is per Service |
| L5 | HAProxy fronts on loopback | S8, T3, K-A2 | [code] only host-network clients dial it |
| L6 | State beacon + init decider | S13, T2 | new code; distro behaviour [assumed], probe P4 |
| L7 | CA-pinned tokens | S12 | [assumed], probe P5 |

Why L1 alone is not enough (the key finding of this review):
- Cilium's `bpf_host` runs at tc ingress on every `devices` link. tc runs before every netfilter hook, prerouting raw included (kernel order: tc, then `nf_ingress`, then IP prerouting).
- With BPF host routing, a packet from a device link to a local pod is delivered by eBPF and never enters netfilter: `bpf_host.c:755-791` [cilium-src] (`if (!from_host && !CONFIG(enable_bpf_host_routing)) return CTX_ACT_OK;` then `ipv4_local_delivery`).
- D71 puts the link that holds the default route into `devices` (`lib/kube-cluster/devices.nix:5-10`) [code]. On a real machine that link is the node LAN.
- So on a real node, A1's K05 attack arrives on a Cilium device and the prototype's nft drop never sees it. The hostile suite passes with the prototype only because its underlay link is not a Cilium device.
- Whether BPF host routing is active here is [assumed] (KPR and BPF masquerade are on; no `enable-host-legacy-routing` key in the manifest). Probe P1.

Why the Cilium host firewall is not the answer:
- NodePort DNAT runs before the host firewall: `bpf_host.c:654-674` then `:676-711` [cilium-src].
- Host policy is enforced only when the destination identity is the host: `lib/host_firewall.h:509-511` [cilium-src]. After DNAT the destination is a pod.
- So a host policy never sees NodePort or LoadBalancer traffic. Keep `enable-host-firewall: "false"`.

Why no Cilium setting restricts NodePorts by source cluster-wide:
- The only source check in the service path is per Service: `lib/nodeport.h:2613` calls `lb4_src_range_ok`, which returns true unless the Service has `SVC_FLAG_SOURCE_RANGE` (`lib/lb.h:1798-1816`) [cilium-src].
- Kubernetes allows `loadBalancerSourceRanges` on `type: LoadBalancer` only. A plain NodePort Service cannot carry it.
- `nodePort.addresses` (D69) limits destination addresses, not sources. `node-port-bind-protection` is about `bind()` on the host. `bpf-lb-external-clusterip=false` keeps ClusterIPs unroutable from outside (`lib/nodeport.h:2616`, `DROP_IS_CLUSTER_IP`) and is why K07 and K12 are safe.

### 3.2 L0: the node firewall as one matrix

Keep: NixOS firewall on, nftables, by-source accepts in `extraInputRules`, the `iifname { fabric links, "lxc*", "cilium*" }` guard on every rule (`firewall.nix:42-44`).

Change: `firewall.nix` takes rows of data, not port lists. nix-unit tests assert the rows. The hostile suite asserts the behaviour. No test compares nft text.

Port and source matrix (target):

| Row | Port | On | From | Why |
|---|---|---|---|---|
| `api` | 6443/tcp | servers | members, pod CIDRs | Every member's HAProxy; pods through the `kubernetes` ClusterIP (DNAT keeps the pod source). |
| `supervisor` | 9345/tcp | rke2 servers | members | Joins, through the joiner's loopback HAProxy. |
| `kubelet` | 10250/tcp | every node | servers; pod CIDRs only if `firewall.kubeletFromPods` | The API server reads logs and runs exec. Pods need it only for a metrics scraper. |
| `cilium-health` | 4240/tcp | every node | members | Node-to-node health probe. |
| `etcd` | 2379, 2380/tcp | servers | servers | Client and peer. |
| `state-beacon` | 9442 + cilium id | every node | servers | §3.7. |
| removed | 2381 | – | – | Loopback-only metrics port. It was open only so a suite got a "refused". |
| removed | 7442+id, 8442+id | – | – | HAProxy fronts move to loopback (§3.6). |
| not ours | 179/tcp, 3784, 4784/udp | – | the link's peer | routed-fabric (prototype H1). |
| eBPF | 30000–32767 tcp/udp/sctp | node addresses | members, `nodePorts.allowedSources`, mesh peers when exposure is `node-port` | L3. nft never sees it. |
| eBPF | Service ports on LB VIPs | VIPs | anyone, unless the Service sets `loadBalancerSourceRanges` | The purpose of a LoadBalancer. L4 makes the ranges hold. |

Rendered input rules on an rke2 server, cilium id 1 (placeholders, not real addresses):

```
iifname { "rf…a", "rf…b", "lxc*", "cilium*" } ip  saddr { <members4>, <podCIDRv4> } tcp dport { 6443 } accept
iifname { "rf…a", "rf…b", "lxc*", "cilium*" } ip6 saddr { <members6>, <podCIDRv6> } tcp dport { 6443 } accept
iifname { … } ip  saddr { <members4> } tcp dport { 9345, 4240 } accept
iifname { … } ip6 saddr { <members6> } tcp dport { 9345, 4240 } accept
iifname { … } ip  saddr { <servers4> } tcp dport { 10250, 2379, 2380, 9443 } accept
iifname { … } ip6 saddr { <servers6> } tcp dport { 10250, 2379, 2380, 9443 } accept
```

Sketch, replacing `lib/kube-cluster/firewall.nix:22-66`:

```nix
{lib}: let
  setOf = xs: "{ ${lib.concatStringsSep ", " xs} }";
in {
  # One row per listener. `from` names source classes, never addresses.
  matrix = {
    isServer, supervisor, kubeapiPort, supervisorPort, beaconPort, kubeletFromPods,
  }:
    lib.filter (row: row.on) [
      { name = "api";           ports = [kubeapiPort];    from = ["members" "pods"]; on = isServer; }
      { name = "supervisor";    ports = [supervisorPort]; from = ["members"];        on = isServer && supervisor; }
      { name = "kubelet";       ports = [10250];          from = ["servers"] ++ lib.optional kubeletFromPods "pods"; on = true; }
      { name = "cilium-health"; ports = [4240];           from = ["members"];        on = true; }
      { name = "etcd";          ports = [2379 2380];      from = ["servers"];        on = isServer; }
      { name = "state-beacon";  ports = [beaconPort];     from = ["servers"];        on = true; }
    ];

  # sources = { members = { v4 = [..]; v6 = [..]; }; servers = {..}; pods = {..}; }
  render = { rows, sources, guardInterfaces }: let
    guard = "iifname ${setOf (map (i: ''"${i}"'') (guardInterfaces ++ ["lxc*" "cilium*"]))} ";
    line = family: key: row: let
      from = lib.concatMap (class: sources.${class}.${key}) row.from;
    in
      lib.optionalString (from != [])
      "${guard}${family} saddr ${setOf from} tcp dport ${setOf (map toString row.ports)} accept";
  in
    lib.concatStringsSep "\n" (lib.filter (l: l != "") (
      lib.concatMap (row: [(line "ip" "v4" row) (line "ip6" "v6" row)]) rows
    )) + "\n";
}
```

- `guardInterfaces` is never empty: manual-address mode is deleted (§4 f). Add `assert guardInterfaces != []`.
- Caller: `service.nix:1064-1079` builds `sources` from `roleMembers`/`memberAddr` and `resolvedCidrs`.
- `trustedInterfaces = ["cilium_host" "cilium_net"]` (`service.nix:1060-1063`): remove it. A trusted link accepts every port. K20 on main already shows a pod reaches only the listed ports, so nothing known depends on the trust. Proof: K20 stays safe and `<distro>-single`, `-join`, `-data-plane` stay green. If one fails, put the trust back and record why in `upstream-facts.md`.

### 3.3 L1: the nft table `kube-<instance>`

Take the prototype as it is (`fix-probe`, `lib/kube-cluster/service.nix:1049-1068`, and `clan._networkFacts.fabricInside` in `lib/kube-cluster/network-facts.nix:81`). It renders:

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
- Do not add this node's D71 links to the accept list. If eBPF does not take a packet there, it must not reach a pod.
- Why not `networking.firewall.filterForward = true` instead: the NixOS forward chain drops `ct state invalid` before the extra rules. With BPF host routing, netfilter sees only one direction of some pod flows. A reply that falls back to the stack would be invalid and dropped. That is a stability risk with no safety gain over this table. Rejected for now.
- The table is now always rendered (no `mkIf (transportInterfaces != [])`).

### 3.4 L2: pods refuse the outside (one clusterwide policy)

Rendered into the bootstrap bundle (`lib/kube-cluster/bundle.nix`, beside the Cilium objects; same labels, same prune rule):

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

What it does:
- A new connection from `world` to a pod is dropped at the pod, whatever link it came in on and whether eBPF or the stack delivered it. This closes K05, K06 on Cilium-device links, and a forced route from A2 (K11f).
- It is stateful (Cilium conntrack). Replies to a pod's own outgoing connections pass.
- `enableDefaultDeny: false` keeps every pod in default-allow for everything else. No other traffic changes.
- Members are `host` / `remote-node`. Mesh peers' pods carry cluster identities. Neither is `world`.

What the operator must know (write it in the service READMEs and `documentation/docs/`):
- To expose a workload outside the cluster: create the Service **and** label the pods (or the namespace) `clan.lol/outside: "allow"`.
- With `externalTrafficPolicy: Local` (the documented recipe, SPEC §3.3) the client source is kept. An unlabelled backend drops it. Clear behaviour.
- With `externalTrafficPolicy: Cluster` a node that forwards to a backend on another node rewrites the source to its own address. The backend then sees `remote-node` and accepts. So an unlabelled pod behind an LB Service answers on some nodes and not on others. Fail-safe, but confusing. The README must say: label exposed pods.

Bundle changes that go with it:
- Label the `clustermesh-apiserver` pods `clan.lol/outside: "allow"`. Peer agents connect before the mesh knows them, so they are `world` at that moment. mTLS protects that port.
- Option `outsideIngress.policy` (bool, default `true`) turns the policy off for an operator who owns all policy day-2. Cluster-level.

This is a new decision: SPEC §3.3 says policy is day-2. Record it as a decision ("one exposure guard is part of the data plane") before code (hard rule 3). It stays inside D1: Cilium remains networking-only.

### 3.5 L3: NodePorts by source (a tcx guard ahead of Cilium)

Owner decision: NodePorts answer cluster members by default, plus an opt-in list.

The only place that can enforce it is ahead of Cilium at tc ingress (§3.1). Design:

- One small eBPF program, `nodeport-guard`, attached with **tcx** at the **head** of the ingress chain of every Cilium device of the node (`transportInterfaces` plus this node's D71 devices).
- Rule: `destination in this cluster's node addresses` and `L4 destination port in the NodePort range` and `protocol is TCP, UDP or SCTP` and `source not in the allow set` → drop. Everything else → `TCX_NEXT` (Cilium runs next, unchanged).
- It is stateless and that is safe here:
  - Host ephemeral ports do not overlap the range: Cilium reserves it (`enable-auto-protect-node-port-range: "true"`) [manifest].
  - Cilium's SNAT ports start above the range: `lib/nat.h:31` (`NODEPORT_PORT_MIN_NAT = nodeport_port_max + 1`) [cilium-src].
  - Transit traffic is untouched: the rule needs a destination that is a node address of this cluster.
- It does not filter pod addresses. A stateless source filter there would break replies to pods that talk to an address inside `10.0.0.0/8` that is not masqueraded. L2 does that job with state.

Allow set (rendered at evaluation, written into BPF maps at load):
- every member's node addresses (`memberAddr`, both families);
- the cluster's pod CIDRs (a pod may use a NodePort, as K20 shows today);
- `nodePorts.allowedSources`;
- when `mesh.exposure` resolves to `node-port`: every peer cluster's member addresses (from `peerClusters`, `service.nix:302-314`), because the peers dial 32379.

Kernel side, complete sketch (`lib/kube-cluster/nodeport-guard/guard.bpf.c`):

```c
// SPDX-License-Identifier: GPL-2.0
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

struct key4 { __u32 prefixlen; __u32 addr; };
struct key6 { __u32 prefixlen; __u8 addr[16]; };

#define LPM(name, keytype, max)                         \
  struct {                                              \
    __uint(type, BPF_MAP_TYPE_LPM_TRIE);                \
    __uint(map_flags, BPF_F_NO_PREALLOC);               \
    __uint(max_entries, max);                           \
    __type(key, keytype);                               \
    __type(value, __u8);                                \
  } name SEC(".maps")

LPM(node4, struct key4, 1024);   /* this cluster's node addresses (/32)  */
LPM(node6, struct key6, 1024);   /* (/128)                                */
LPM(allow4, struct key4, 4096);  /* who may reach a NodePort              */
LPM(allow6, struct key6, 4096);

struct { __uint(type, BPF_MAP_TYPE_ARRAY); __uint(max_entries, 2);
         __type(key, __u32); __type(value, __u16); } range SEC(".maps");   /* [0]=min [1]=max, host order */
struct { __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY); __uint(max_entries, 1);
         __type(key, __u32); __type(value, __u64); } drops SEC(".maps");

static __always_inline int in_range(struct __sk_buff *skb, __u32 l4_off, __u8 proto)
{
  __be16 dport; __u32 k0 = 0, k1 = 1; __u16 *lo, *hi;
  if (proto != IPPROTO_TCP && proto != IPPROTO_UDP && proto != IPPROTO_SCTP) return 0;
  if (bpf_skb_load_bytes(skb, l4_off + 2, &dport, sizeof(dport)) < 0) return 0;
  lo = bpf_map_lookup_elem(&range, &k0); hi = bpf_map_lookup_elem(&range, &k1);
  if (!lo || !hi) return 0;
  return bpf_ntohs(dport) >= *lo && bpf_ntohs(dport) <= *hi;
}

static __always_inline int drop(void)
{
  __u32 k = 0; __u64 *c = bpf_map_lookup_elem(&drops, &k);
  if (c) (*c)++;
  return TCX_DROP;
}

static __always_inline int guard(struct __sk_buff *skb, __u32 l3)
{
  if (skb->protocol == bpf_htons(ETH_P_IP)) {
    struct iphdr ip; struct key4 d, s;
    if (bpf_skb_load_bytes(skb, l3, &ip, sizeof(ip)) < 0) return TCX_NEXT;
    d = (struct key4){32, ip.daddr}; s = (struct key4){32, ip.saddr};
    if (!bpf_map_lookup_elem(&node4, &d)) return TCX_NEXT;
    if (bpf_map_lookup_elem(&allow4, &s)) return TCX_NEXT;
    if (ip.frag_off & bpf_htons(0x1fff)) return TCX_NEXT;      /* not the first fragment */
    return in_range(skb, l3 + ip.ihl * 4, ip.protocol) ? drop() : TCX_NEXT;
  }
  if (skb->protocol == bpf_htons(ETH_P_IPV6)) {
    struct ipv6hdr ip; struct key6 d = {128}, s = {128}; __u8 next; __u32 off = l3 + sizeof(ip);
    if (bpf_skb_load_bytes(skb, l3, &ip, sizeof(ip)) < 0) return TCX_NEXT;
    __builtin_memcpy(d.addr, &ip.daddr, 16); __builtin_memcpy(s.addr, &ip.saddr, 16);
    if (!bpf_map_lookup_elem(&node6, &d)) return TCX_NEXT;
    if (bpf_map_lookup_elem(&allow6, &s)) return TCX_NEXT;
    next = ip.nexthdr;
    for (int i = 0; i < 4; i++) {                              /* walk extension headers */
      __u8 h[8];
      if (next != 0 && next != 43 && next != 60 && next != 44) break;
      if (bpf_skb_load_bytes(skb, off, h, sizeof(h)) < 0) return drop();
      if (next == 44) {                                        /* fragment header */
        if ((h[2] << 8 | h[3]) & 0xfff8) return TCX_NEXT;      /* not the first fragment */
        off += 8;
      } else {
        off += (h[1] + 1) * 8;
      }
      next = h[0];
    }
    if (next == 0 || next == 43 || next == 60 || next == 44) return drop();   /* too many headers */
    return in_range(skb, off, next) ? drop() : TCX_NEXT;
  }
  return TCX_NEXT;
}

SEC("tcx/ingress") int guard_l3(struct __sk_buff *skb) { return guard(skb, 0); }        /* WireGuard */
SEC("tcx/ingress") int guard_l2(struct __sk_buff *skb) { return guard(skb, ETH_HLEN); } /* Ethernet  */
char _license[] SEC("license") = "GPL";
```

Host side:
- Build: one derivation (`clang -O2 -g -target bpf`, `libbpf` headers). It belongs in org-pkgs (`pkgs/nodeport-guard`) because formatting and packaging are org-pkgs work; this repo consumes it as `pkgs.nodeport-guard`.
- Loader: a small libbpf program in the same package, `nodeport-guard-attach <pin-dir> <device>`:
  - open the pinned programs and maps under `/sys/fs/bpf/kube-<i>/` (load and pin them on first use);
  - pick `guard_l3` when `/sys/class/net/<device>/type` is 65534, else `guard_l2`;
  - `bpf_program__attach_tcx(prog, ifindex, &opts)` with `opts.flags = BPF_F_BEFORE` and no relative object (the head of the chain);
  - pin the link as `/sys/fs/bpf/kube-<i>/link-<device>`.
- Units, in `service.nix` (new block after the HAProxy block, `service.nix:1110`):
  - `kube-<i>-nodeport-guard-maps.service`: oneshot, before the distro unit. Fills the maps from a JSON file in the store (addresses are not secrets). On a change it rewrites the maps in place; the programs stay attached.
  - `kube-<i>-nodeport-guard@.service`: `BindsTo=sys-subsystem-net-devices-%i.device`, `After=` the same and the maps unit, `ExecStart=nodeport-guard-attach …`. A udev rule adds `SYSTEMD_WANTS` for each device name in the list, so the unit starts whenever IfState creates or recreates the link.
  - `kube-<i>-nodeport-guard-check.service` + timer (every minute, and `ExecStartPost` of the distro unit): for every device, the first program of the tcx ingress chain must be the guard (`bpftool net show dev <d>`). If not, it fails. A failed unit is the alarm; add it to the suite's "no failed units" check.
- Fail mode: if the guard is not attached, NodePorts are open to fabric members as they are today. It cannot fail closed without stopping Cilium. The check unit makes it visible.

Fallback if probe P3 fails (the guard cannot be kept ahead of Cilium):
- A `ValidatingAdmissionPolicy` in the bundle: `type: NodePort` is refused, and `type: LoadBalancer` must set `allocateLoadBalancerNodePorts: false`, except in namespaces labelled `clan.lol/node-ports: "allow"`.
- This restricts by existence, not by source. Say so to the owner; it is a different promise than the decision.

### 3.6 L4, L5: Cilium settings and the HAProxy fronts

Cilium (`lib/kube-cluster/cilium.nix:138-200`):
- Add `extraConfig."bpf-lb-source-range-all-types" = "true";` next to `install-iptables-rules` (`cilium.nix:155`). A Service's source ranges then also guard its NodePort front.
- Keep `nodePort.addresses` (D69, `cilium.nix:162`).
- Keep the host firewall off. Reason in §3.1.
- Add to `contradictions` (`cilium.nix:80-110`): an override may not set `bpf.hostLegacyRouting`, `enableTCX`/`bpf.tc.*`, `nodePort.addresses`, `extraConfig."bpf-lb-external-clusterip"`, `extraConfig."bpf-lb-source-range-all-types"`, `hostFirewall`. Each one moves an enforcement point this design relies on.

HAProxy on loopback (`lib/kube-cluster/haproxy.nix`):
- Who dials the fronts today [code]: the kubelet, the distro's join, and the Cilium agent and operator. Both Cilium pods are `hostNetwork: true` [manifest, lines 1464, 1869] and only they get `KUBERNETES_SERVICE_HOST` (`bundle.nix:182`, checks at `bundle.nix:487-500`). The clan CoreDNS and every normal pod use the `kubernetes` ClusterIP, which goes to the servers' 6443.
- So no pod and no other host needs a front. SPEC §6.6 already says "on loopback"; the code drifted (K-A10).
- Changes:
  - `haproxy.nix:75-76` and `:126-127`: `bind 127.0.0.1:<port>` and `bind [::1]:<port>` for both fronts.
  - `service.nix:1090-1093`: `extraHosts` maps the kubeapi name to `127.0.0.1` and `::1`.
  - Add a source pin to each server line, so the health check and the data path leave with the node address whatever the route says: `server <n>-4 <ip4>:<port> source <nodeIPv4>` and `… source [<nodeIPv6>]` (`haproxy.nix:60-66`). The servers accept members only.
  - `service.nix:1069-1078`: the two front ports leave the firewall (the matrix in §3.2 has no row for them). This closes K-A2 by construction: the supervisor front is unreachable from anywhere but the node itself.
  - `service.nix:1105-1110`: drop the comment about the bind race. `after = ["ifstate.service"]` can go; loopback always exists (T3). Keep `Restart=always` semantics.
- The derived ports (7442 + id, + 1000) stay. They cost nothing and keep `k8sServicePort` stable.
- `tls-san` keeps the kubeapi name (`service.nix:716-730`). Clients verify by name.

### 3.7 L6: bootstrap, join and the init decider

Today (`nixos.nix:31-107`, `service.nix:1125-1142`): the init server without an etcd directory dials the other servers' API port. All "refused" in one pass means "no cluster" and it founds one. A peer whose service is down or still starting looks the same as a peer with no cluster (K-A3). Agents are never asked.

Target rule: **founding needs a positive "I remember no cluster" from every other member.** A closed port proves nothing.

Part 1, the state beacon, on every member (servers and agents):
- `kube-<i>-state.socket`: `ListenStream=<nodeIPv4>:<beaconPort>` and `[<nodeIPv6>]:<beaconPort>`, `FreeBind=true`, `Accept=yes`, `MaxConnections=8`. `beaconPort = 9442 + resolvedCiliumId` (define beside `service.nix:507-508`).
- `kube-<i>-state@.service`: `StandardOutput=socket`, read-only sandbox (`ProtectSystem=strict`, `PrivateNetwork` not set, `NoNewPrivileges`), one line then exit:
  - `data` if `<dataDir>/server/db/etcd` exists;
  - else `joined` if `<dataDir>/agent/client-kubelet.crt` exists;
  - else `empty`.
- It answers whether the distro unit runs or not. It carries no secret. Firewall row `state-beacon`: servers only.

Part 2, the decider (same unit name `<distro>-<i>-init-guard`, still only on the `clusterInit` server, still `requiredBy` the server unit):

```sh
# replaces the loop at lib/kube-cluster/nixos.nix:70-103
if [ -d "$ETCD_DIR" ]; then rm -f "$REJOIN_DROPIN"; exit 0; fi           # I have the data: start
if [ -e "$REJOIN_MARK" ]; then                                           # operator: join the live cluster
  printf 'server: %s\ncluster-init: false\n' "$JOIN_URL" > "$REJOIN_DROPIN"
  rm -f "$REJOIN_MARK"; exit 0
fi
if [ -e "$FOUND_MARK" ]; then rm -f "$FOUND_MARK" "$REJOIN_DROPIN"; exit 0; fi   # operator: found a new one
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
    echo "…no etcd data here, but these members remember a cluster:$remembered. Not founding a second one. To rejoin: delete this node and its node-password secret on a live server, create $REJOIN_MARK, restart. To restore instead: use the distro's cluster-reset with a snapshot." >&2
    exit 1
  fi
  if [ -z "$silent" ]; then rm -f "$REJOIN_DROPIN"; exit 0; fi            # every member said "empty": found
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "…these members did not answer for $WAIT s:$silent. If no cluster exists, create $FOUND_MARK and restart." >&2
    exit 1
  fi
  sleep 3
done
```

- Keep full store paths for every tool, as today.
- `PEERS` = every other member (`roleMembers` minus self), not only servers (`service.nix:1133-1140`).
- `REJOIN_DROPIN` = `/etc/rancher/<distro>/config.yaml.d/90-rejoin.yaml`. `FOUND_MARK` = today's `allow-new-cluster-<i>`. `REJOIN_MARK` = `<dataDir>/server/rejoin-<i>`.
- k3s: `services.k3s.clusterInit` must become `false` (`services/k3s/default.nix:89`), because the nixpkgs module turns it into the `--cluster-init` command-line flag (`nixos/modules/services/cluster/rancher/k3s.nix:12`) and a flag beats the drop-in. `cluster-init: true` is already in the rendered `config.yaml` (`service.nix:739-741`), so nothing is lost. rke2 has no such flag.
- Why agents are asked: in a one-server cluster with agents, a server that lost its disk would found an empty cluster. The agents trust the same CAs, join it, and their kubelets delete every running pod. With the beacon the agents say `joined` and the server refuses.
- Why "rejoin" replaces "move `clusterInit`": moving the option is a config change and a deploy of several machines during an incident. A marker file on the broken node is one step. Moving `clusterInit` still works (the new init server has data and starts).

What stays: PKI seeding (`AssertPathExists`, staged CA set), the bootstrap-apply and clustermesh-secrets units on the init server.

### 3.8 L7: tokens

- Format (after probe P5): `K10<sha256 of the bytes of server-ca.crt>::server:<64 hex>` and `K10<…>::node:<64 hex>`.
- `vars.nix:27-53`: both generators get `dependencies = ["rancher-pki-<i>"]`, read `$in/rancher-pki-<i>/server-ca.crt`, and use `openssl rand -hex 32`.
- Delete `ca-hash` (`vars.nix:84-87`, `:146`): it is the root's DER hash, the wrong value, and nothing reads it.
- T4, a token stamp: a oneshot before the server unit writes `sha256(token file)` to `<dataDir>/server/.token-stamp-<i>` after a good start, and at the next start refuses with a clear message when the etcd directory exists and the stamp differs ("the server token var changed; run `<distro> token rotate --new-token …` on a live server first, runbook …"). The distro would fail anyway, later and less clearly, on every server at its next restart.

### 3.9 Option surface

| Change | Option | Type | Default | Level |
|---|---|---|---|---|
| remove | `network.ipv4`, `network.ipv6` (`node-interface.nix:52-69`) | – | – | manual mode is gone |
| change | `network.fabric` (`cluster-interface.nix:13-42`) | submodule `{service, instance}`, not nullable, no default | required | cluster |
| change | `domain` (`cluster-interface.nix:3-10`) | `nullOr (strMatching "[a-z0-9]([-a-z0-9.]*[a-z0-9])?")` | `null` | cluster |
| change | `network.{pod,service}CIDRv{4,6}` | `nullOr` the CIDR types of `lib/ip.nix` | `null` | cluster |
| change | rke2 `profile` (`services/rke2/default.nix:21-33`) | `nullOr (enum ["cis"])` | `null` | cluster (add to parity) |
| add | `nodePorts.allowedSources` | `listOf` CIDR (both families) | `[]` | cluster |
| add | `outsideIngress.policy` | `bool` | `true` | cluster |
| add | `firewall.kubeletFromPods` | `bool` | `false` | cluster |
| add | `audit.enable` | `bool` | `true` | cluster |
| add | `podSecurity.enforce` | `enum ["privileged" "baseline" "restricted"]` | `"baseline"` (owner decision, §4 g) | cluster |
| keep | `clusterInit` | `bool` | `false` | node. New meaning: the server that founds the cluster when no member remembers one, and that applies the bundle. |
| keep | `configOverrides` | `attrs` | `{}` | add the new owned keys to the refusal list |

Parity: `assertions.nix:126-141` gets `nodePorts`, `outsideIngress`, `firewall`, `audit`, `podSecurity` and `distro.extraOptions` names (K-A8).

### 3.10 Eval assertions (new or changed)

- `network.fabric` is set and every member has a `node_transport` export (already asserted when a fabric is set; now unconditional). Delete `assertions.nix:253-256` (bgp needs fabric) and the manual branches.
- Every `nodePorts.allowedSources` entry parses as a CIDR.
- The node has at least one Cilium device (the guard and the firewall guard need one).
- `cilium.helmValues` contradictions of §3.6.
- `configOverrides` may not set: `kube-apiserver-arg` entries starting with `audit-` or `admission-control-config-file` when the typed options render them; `pod-security-admission-config-file`; `profile`.
- rke2 `profile` equal on every member.
- Keep: one `clusterInit`, never two servers, the instance-name regex, CIDR rules.

## 4. Verdicts on the ideas

| Idea | Verdict | Reasoning | Cost |
|---|---|---|---|
| (a) default-deny node firewall | **Refine.** | Input is already default-deny (NixOS firewall); keep by-source accepts but render them from one matrix (§3.2). The real hole was forwarding to pods, which is default-accept. Make cluster destinations default-deny by inside-link list (§3.3), and make pods default-deny to `world` (§3.4). A full `filterForward` default-deny is rejected: conntrack sees half of the BPF-routed flows. | Small (matrix), small (table, done in prototype), medium (policy). |
| (b) NodePort / LB VIP by source | **Accept, with a new component.** | Verified in Cilium source: nft cannot see it, the host firewall cannot see it, there is no cluster-wide source check. Only a classifier ahead of Cilium can (§3.5). LB VIPs stay open by default and take per-Service ranges, which L4 makes hold on all fronts. | High: C code, a loader, unit lifecycle, an org-pkgs package, probe P3 first. |
| (c) do pods need the API LB front | **No. Remove it from the network.** | Only host-network clients dial it [code, manifest]. Bind loopback (§3.6). | Small. Removes two firewall ports and a bind race. |
| (d) init guard redesign | **Accept: beacon + decider.** | A closed port is not evidence. A member's own statement is. Asking agents protects one-server clusters too. K-A3's "more ports, settle rounds" still founds a second cluster when the peers' services are down. | Medium. One socket unit, one script, suite phases. Probe P4. |
| (e) tokens with CA pin | **Accept after probe.** | The PKI exists before the tokens, so the pin is free. On a fabric the path is WireGuard, so the gain is modest; it also guards against a wrong-cluster join. | Small plus probe P5. |
| (f) manual-address mode | **Delete.** | D72: routed-fabric is the only transport. The mode is unbooted, pinned to `eth0`, has no pod routes, and is where four findings live (K-A4, K-A5, part of K-A7, the unguarded firewall branch). `clustermesh` node-port exposure stays; it is a transport capability, not the manual mode. | Medium: many nix-unit fixtures move to a fabric fixture. Net code removal. |
| (g) rke2 `cis`, Pod Security | **Refine.** | `profile` becomes an enum, cluster-level. It gets a suite (`rke2-cis`) or it is removed: no untested hardening mode. A cluster-wide Pod Security default of `baseline` (exempt `kube-system`, `cilium-secrets`) is a real gain against A3 on both distros, but it is policy: owner decision and a SPEC decision first. | Medium. One suite, one admission config file per distro. |
| (h) typed options | **Accept.** | With (f) the address options vanish. Type the rest (§3.9). | Small. |
| (i) etcd, control plane, kubelet, audit | **Mostly already good; tighten three things.** | etcd: drop 2381. Kubelet: anonymous off and read-only port closed are distro defaults and suite-proven (K22, K23); do not re-set them, keep the verdicts. Open 10250 to servers only, pods by option. Audit: on by default, metadata level, rotated. | Small each. |
| (j) HAProxy vs the distro's client LB | **Keep HAProxy, on loopback.** | It gives one endpoint that is the same on servers and agents (Cilium needs one value in one ConfigMap), checks `/readyz` with mTLS, and makes the first join HA. The distro LB needs a live first server and uses different ports per role. | None beyond (c). |

Own ideas:
- **Token stamp** (§3.8, T4). Small.
- **Remove `trustedInterfaces`** (§3.2). Small, needs suite proof.
- **Guard-order check unit** (§3.5): the alarm for a fail-open mechanism. Small.
- **Deploy order rule** in the runbook: deploy existing members before a new member (T5). A new member's address reaches the old members' source sets only when they are deployed. Doc only.

## 5. Deleted or simplified

Deleted:
- Manual-address mode: `network.ipv4/ipv6`, every `fabric == null` branch (`service.nix:143-154`, `:177-184`, `:214-219`, `:323-332`, `:578-593`), the `["eth0"]` fallbacks, `assertions.nix:253-256`, the unguarded firewall branch (`firewall.nix:42-44` becomes unconditional).
- Firewall rows: 2381, the API front, the supervisor front. `memberOnlyPorts` / `clusterPorts` arguments (replaced by the matrix).
- `ca-hash` in the PKI generator.
- The guard's port probing and `INIT_GUARD_PORT`.
- `trustedInterfaces` for `cilium_host` / `cilium_net` (if the suites agree).
- HAProxy's ordering after `ifstate.service`.
- README quick starts that set `network.fabric = null` (K-A4): rewrite on a one-machine fabric. Keep a nix-unit test that evaluates the README inventory with zero failed assertions.

Tests that pin a mechanism today and should check behaviour instead:

| Today | Problem | Becomes |
|---|---|---|
| `services/rke2/tests/eval-tests.nix:1793` and k3s `:1822`, `:1850` (`test_firewallManualBySource`, `test_firewallFabricAgent`): compare nft rule text | Any renderer change breaks them; one of them pins the K-A2 leak as correct | nix-unit on the matrix rows (data). Behaviour in K10, K20, K24. |
| `test_initGuardWaitsForFabric`: environment variable values | Pins the probe mechanism | Unit ordering only. Behaviour in `<distro>-ha`. |
| `lib/kube-cluster/tests/vm/ha.nix:434-475`: drop-ins that point the guard at port 2381 | Tests the mechanism through a fake | Real phases: stop a peer's service, wipe the init server's etcd directory, see the refusal; then the rejoin (§7). |
| `lib/kube-cluster/tests/vm/single.nix:351-367`: a list of six closed ports | A deny-list | The hostile suite's full scans with an allow-list of expected open ports. |
| `lib/kube-cluster/tests/vm/data-plane.nix:1035-1041`: NodePort does not answer on the underlay address | Misses the fabric path | K08 and K13 as verdicts. |
| `lib/kube-cluster/tests/eval-tests.nix:1820-1840` (`test_manualClusterBgpRequiresFabric`) | Tests a deleted mode | Deleted. |
| Any eval test on HAProxy `bind <node address>` | Pins the address | K27: `ss -ltn` shows loopback only; a remote connect fails. |

Use `suite-snapshot` / `suite-compare` only for pure refactors. These changes alter node derivations on purpose; say so in each PR.

## 6. Hostile-suite verdicts to add

Body: `lib/kube-cluster/tests/vm/hostile.nix` (from `fix-probe`). "outsider" = A1, "mallory" = A2.

| ID | Attacker | Command | Safe outcome |
|---|---|---|---|
| K05d | outsider on a link that **is** a Cilium device (give one node its default route on the LAN link, so D71 adds it) | `ip route add <pod4>/32 via <node LAN addr>; nc -z -w 3 <pod4> 8080` | fails. This is the test that separates L1 from L2. |
| K06d | same | `ping -c1 -W2 <pod4>` | fails |
| K11f | mallory | `ip route add <pod4>/32 dev <its fabric link>; nc -z -w 3 <pod4> 8080` (and v6) | fails. Today's K11 uses mallory's own table, which may hold no route. |
| K11o | mallory, pod labelled `clan.lol/outside=allow` behind an LB Service with ETP Local | `nc -z -w 3 <vip> <port>` | connects (positive control for the opt-in) |
| K13 | mallory | `nc -z -w 3 <node addr> <nodeport>`, both families, TCP and UDP | fails (INFO becomes a verdict) |
| K13a | mallory, after `nodePorts.allowedSources` holds its address (second cluster fixture or a specialisation) | same | connects |
| K13m | a member node | same | connects |
| K13x | mallory | IPv6 with a hop-by-hop or destination-options header before TCP (`nping --hop-limit`/scapy) to a NodePort | fails |
| K17 | mallory, Service `type: LoadBalancer` with `loadBalancerSourceRanges: [<a range without mallory>]` | `nc -z` to the VIP port and to the Service's NodePort on a node address | both fail |
| K20 | pod | scan each node address | open on a server: `[6443]`; on an agent: `[]`. With `kubeletFromPods`: plus 10250. NodePorts allowed. |
| K27 | pod, mallory, a member | `nc -z -w 3 <node addr> 7443` and `8443` | all fail; on the node `ss -Hltn 'sport = :7443'` shows `127.0.0.1` and `[::1]` only |
| K28 | pod and mallory | `nc -z -w 3 <node addr> <beaconPort>` | fails |
| K28a | compromised agent (root on beta) | read beacon of alpha: gets one word; write to it: ignored | no data beyond the one word |
| K29 | pod | `wget -T3 https://<server>:6443/v1-k3s/server-bootstrap` (rke2: `:9345/v1-rke2/…`) without and with a wrong token | 401 on k3s; no connection on rke2 |
| K34 | on a joining node | journal of the join | no "does not include a CA hash" line; token files start with `K10` |
| K35 | compromised agent (beta, root) | `nc -z alpha 2379`, `2380`; `curl -k --cert <kubelet cert> https://alpha:6443/api/v1/secrets` | etcd fails; API answers 403 |
| K36 | compromised agent | join a second node as a **server** with the agent token (`<distro> server --server … --token-file agent-token`) | refused |
| K40 | outsider | full TCP scan and UDP probes (51820-range, 4789, 8472) of the underlay address after all changes | only the fabric WireGuard port is `open|filtered` |

Every GAP in `runs/*-hostile.verdicts.txt` must be SAFE: K05, K06, K20, K21.

## 7. Failure modes and stability

| Event | Behaviour in the target design | Proof |
|---|---|---|
| Init server lost (powered off) | Other servers keep quorum. Every node's HAProxy marks it down and uses the others. Nothing at runtime needs the init server. Bundle changes wait until it is back or `clusterInit` moves. | `<distro>-ha`: `alpha.crash()`, then beta and gamma Ready, `kubectl create configmap` through beta, restart of the server unit on beta succeeds. |
| Init server back with its data | Decider sees the etcd directory, starts. | same suite: alpha boots, rejoins, three etcd members. |
| Init server back **without** data | Beacons answer `data`. Decider refuses with the rejoin text. No second cluster. | same suite: wipe `server/db`, start fails, message names the peers; `kubectl get nodes` on beta unchanged. |
| Rejoin | Operator deletes the node and its node-password secret, creates the marker. Decider writes the drop-in; the server joins. Next start: data exists, drop-in removed. | same suite, next phase: three etcd members, one cluster id. |
| Init server without data, peers' services stopped | Beacons still answer `data` (socket activation). Refuses. This is the K-A3 case. | same suite: `systemctl stop <serverUnit>` on beta and gamma first. |
| First install, all members empty | Every beacon says `empty`. Founds with no operator step. | `<distro>-ha` boot phase (no marker file needed any more). |
| First install, a peer not installed yet | Silent peer. Waits 300 s, refuses, names the marker. Fail-closed, as today. | `<distro>-ha`: one phase with a member down. |
| Cold boot of all nodes | Every server has data: deciders pass at once, etcd forms quorum when two are up. HAProxy starts without the fabric (loopback) and retries backends. Kubelets retry. | New phase in `<distro>-ha`: crash all, start all, all Ready, no failed unit. |
| One-server cluster, server disk lost, agents alive | Agents answer `joined`. Refuses. Operator restores a snapshot or creates the found marker knowingly. | `<distro>-join`: wipe the server's `db`, see the refusal. |
| Token var regenerated without rotation | Stamp check refuses the next server start with the runbook line. The running server is untouched. | `<distro>-single`: overwrite the token file through a test-only drop-in path, restart, see the message. |
| Agent token changed | Running agents keep working (node passwords). New joins need the new token on servers and the joiner. | Doc only. |
| Partial deploy, member added | Old members do not list the new address yet: its joins and beacons are refused there. No port opens. Deploy old members first. | nix-unit: member set per node; doc. |
| Partial deploy, member removed | Its address stays allowed on undeployed nodes until they are deployed. | Doc: deploy all members after a removal. |
| HAProxy down on a node | That node's kubelet and Cilium agent lose the API; the datapath keeps forwarding; `Restart=always` brings it back. Other nodes are unaffected. | `<distro>-join`: `systemctl kill haproxy` on beta; a pod-to-pod connection across nodes keeps working; node Ready again. |
| A server's API down | Every HAProxy fails over within `fall 3 × inter 5s`. Sessions to it are cut (`on-marked-down shutdown-sessions`). | exists in `<distro>-ha`. |
| NodePort guard not attached (link recreated, unit failed) | NodePorts open to fabric members (today's state). Check unit fails within a minute. | Hostile suite: `ip link` recreate of a fabric link, then K13 still safe and the check unit active. |
| Policy object deleted by a cluster admin | S3 falls back to L1. The bundle re-applies it on the next deploy that changes the bundle. | Doc. |

## 8. Implementation order

Each step: SPEC and `documentation/` first (hard rule 3), then code, `fmt`, `check`, the named suites with `--remote --rebuild`. One PR per step.

1. **Land the hostile suites and the prototype.** Take `fix-probe` as it is (L1, supervisor front member-only, routed-fabric H1). Add K-A1 (`package = effectivePackage;` in `services/rke2/default.nix:111`, with `effectivePackage` in the argument set at `:94-110`) and its nix-unit test from `reviews/kube.md`. Fix K-A10 text.
   Proof: `k3s-hostile`, `rke2-hostile` print no GAP (as `runs/*.with-fix.verdicts.txt`).
2. **Probes P1–P5** (§9) as throwaway suites that print `FINDING` lines. No product code. Record results in `upstream-facts.md`.
3. **Delete manual mode, type the options** (f, h, K-A4, K-A5, K-A7, K-A8). Rewrite READMEs on a one-machine fabric; add the README-evaluates test.
   Proof: `check`; every existing suite still passes (they all use a fabric).
4. **HAProxy on loopback, firewall matrix, kubelet and health rows, drop 2381, drop `trustedInterfaces`** (c, j, a, i).
   Proof: K20 tightened, K27, `<distro>-single`, `-join`, `-ha`, `-data-plane`, `-clustermesh`.
5. **State beacon and decider** (d), with the `<distro>-ha` and `-join` phases of §7. Needs P4.
   Proof: those phases; K28.
6. **Tokens with CA pin and the token stamp** (e). Needs P5.
   Proof: K34, `<distro>-join`, the stamp phase.
7. **Outside-to-pods policy and `bpf-lb-source-range-all-types`** (L2, L4). Needs P1, P2.
   Proof: K05d, K06d, K11f, K11o, K17; all clustermesh suites (the apiserver label).
8. **NodePort guard** (L3). Needs P3. org-pkgs PR for the package first, then this repo.
   Proof: K13, K13a, K13m, K13x, the link-recreate phase; `clustermesh-nodeport` and `clustermesh-external` still pass.
9. **Audit, Pod Security default, `rke2-cis` suite** (g, i). Owner decision on Pod Security first.
   Proof: `rke2-cis`; a privileged pod is refused in a fresh namespace and allowed in a namespace labelled `pod-security.kubernetes.io/enforce=privileged`; the audit log exists and rotates.

Steps 3–6 are independent of the Cilium probes and can go first.

## 9. Open risks and probes

Verified in code or source (no probe needed):
- Only host-network Cilium pods use the API front. [code, manifest]
- NodePort DNAT precedes the host firewall; host policy covers host destinations only. [cilium-src]
- The service path has a per-Service source check only. [cilium-src]
- With BPF host routing a device-to-pod packet skips netfilter. [cilium-src]
- Cilium's SNAT ports start above the NodePort range; the range is protected from host ephemeral use. [cilium-src, manifest]
- `enable-tcx: "true"`, `enable-host-firewall: "false"`, `bpf-lb-source-range-all-types: "false"`, `bpf-lb-external-clusterip: "false"` are the current values. [manifest]
- The agent has a tc filter priority flag (string "Priority of TC BPF filter" in the 1.20.3 binary) and the `service.cilium.io/src-ranges-policy` annotation.

Assumed, each with its probe:

| ID | Assumption | Probe (throwaway suite, prints `FINDING`) | If false |
|---|---|---|---|
| P1 | BPF host routing is active on these nodes; A1 reaches a pod through a link that is a Cilium device (K05d is a GAP on main and with the prototype). | In a hostile-suite copy: `cilium-dbg status \| grep 'Host Routing'`; give alpha its default route on the LAN link; run K05d. | If host routing is legacy, L1 already covers device links and L2 is defence in depth only. |
| P2 | A clusterwide policy with only `ingressDeny: world` and `enableDefaultDeny.ingress: false` (a) drops outside-to-pod, (b) changes no other traffic, (c) lets mesh peers and members through, (d) the label selectors on pod and namespace labels work as written. | Apply the object by hand in `<distro>-data-plane` and `-clustermesh`; run K05d, K11f, K11o, the suite's own connectivity checks, `cilium-dbg policy get`. | Use `fromCIDRSet` with `except` lists, or keep L1 only and document the device-link gap as open. |
| P3 | Cilium attaches its tcx programs so that a foreign program at the head stays first; Cilium does not detach foreign tcx links; `TCX_NEXT` hands the packet to Cilium unchanged; links survive an agent restart; a recreated link gets the guard before traffic matters. | Build the guard by hand in a suite; attach; `bpftool net show`; restart the Cilium agent; recreate a fabric link through IfState; run K13 and a member's NodePort each time. | Use the admission-policy fallback (§3.5) and tell the owner it is by existence, not by source. |
| P4 | A drop-in `config.yaml.d/90-rejoin.yaml` with `server:` and `cluster-init: false` beats `cluster-init: true` in `config.yaml` on both distros; a server that lost its data joins as a new etcd member once its node object and node-password secret are deleted; `services.k3s.clusterInit = false` with `cluster-init: true` in the config file founds a cluster as before. | `<distro>-ha` copy: wipe alpha's `db`, write the drop-in by hand, start, count etcd members. | Keep "refuse and move `clusterInit`" as the only recovery; the beacon still stands. |
| P5 | Both distros accept the full `K10…::server:…` / `K10…::node:…` form in `token-file` and `agent-token-file` on the founding server; the pin is the SHA-256 of the served `server-ca.crt` bytes; a join against another CA fails. | As in `reviews/kube.md` K-A6. | Keep bare tokens; lengthen to 32 bytes only. |
| P6 | Node-to-node health needs 4240 from member node addresses only; the API server reaches kubelets with a server node address (or through the agent tunnel). | `<distro>-join` with the tightened rows: `cilium-health status --probe`, `kubectl logs` and `exec` on a pod of the agent. | Widen the row (`members` for 10250; add pod CIDRs to 4240) and record the fact. |
| P7 | Host-network pods read the node's `/etc/hosts`, so the kubeapi name resolves to loopback inside the Cilium agent and operator. (Relied on today for the node address.) | Step 4's suites. | Set `hostAliases` on those two workloads in the bundle. |

Other risks:
- **The guard is new low-level code and fails open.** The check unit and K13 are the net. If the owner prefers no custom eBPF, choose the fallback now.
- **L2 changes how exposure works.** An unlabelled backend behind an LB with ETP Cluster answers on some nodes only. The READMEs must lead with the label.
- **Spines.** A spine can forge member sources. No rule here stops it; TLS, tokens and mTLS do. State this in SPEC §6.12.
- **Day-2 workloads** that need a privileged pod, the kubelet from a pod (metrics-server), or NodePorts from outside now need an explicit option or label. That is the intent; list the three switches in one README table.
- **k3s serves the supervisor on 6443**, which pods must reach for the API. The token is the only guard there (K29). No design here changes that.
