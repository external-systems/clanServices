# Kube probes, 2026-11-27

Probe engineer's record for `specs/design-kube.md`. Every run was a NixOS
VM suite on the remote builder, on the prototype in `prototype.patch`
(base: main `deeaba4`, plus `patches/fixes-fabric-kube.patch` and
`patches/fix-rke2-package.patch`). Versions: Kubernetes 1.37.1, Cilium
1.20.3, kernel 6.18. Test ranges only.

- `runs/`: the `FINDING` and `HOSTILE` lines of every run, as printed.
- `manifests/`: the objects that work, as files.
- `prototype.patch`: `git diff --cached origin/main` of the probe worktree.

Result marks: **VERIFIED-VM**, **REFUTED** (the design changed),
**NOT-RUN**.

## 1. Results on k3s, one row per probe

| ID | Question | Result | Suite | Log lines (file in `runs/`) |
|---|---|---|---|---|
| P1 | Is BPF host routing active? | VERIFIED-VM | `k3s-probe-net` | `Routing: Network: Native   Host: BPF`, `Attach Mode: TCX` on both nodes (`k3s-probe-net.run1`, `.run4`) |
| P1 | With the node LAN link as a Cilium device and the nft table `kube-<i>` present: does the outsider reach a pod? | VERIFIED-VM: yes, it does. The nft table is bypassed | `k3s-probe-net` B | `FINDING B (eth1 IS a Cilium device, nft table present) outsider -> pod on beta, routed to beta's LAN address: CONNECTS`; `outsider ping -> pod on beta: ANSWERS`; `-> pod on alpha, routed to alpha's LAN address: CONNECTS` (`.run4`, `.run5`) |
| P1 | Which path bypasses netfilter? | VERIFIED-VM | `k3s-probe-net` A, B | Counter `ip saddr 192.168.1.66 ip daddr 10.1.0.0/16 … "outsider-pre"` at `prerouting priority -500` on beta: 11 packets in phase A (blocked), 11 in phase B (connects). The table's drop counter: 11 and 11. `bpftool net show dev eth1`: `tcx/ingress cil_from_netdev`. Source: `bpf_host.c:788-822`, `ipv4_local_delivery` |
| P1 | A pod on another node (the packet enters at alpha, the pod is on beta)? | VERIFIED-VM: blocked by the nft table | `k3s-probe-net` B | `FINDING B outsider -> pod on beta via alpha: blocked`; alpha's drop counter rises by 3 |
| P1 | Timing after an agent restart | observed | `k3s-probe-net` B (`.run1`) | alpha, seconds after the Cilium restart: `outsider -> pod on alpha: blocked`, nft counter 3 → 6. With a 30 s wait (`.run4`): `CONNECTS`, counter stays |
| O2 | Does a fabric member outside the cluster reach a pod on the spine, and through the spine, on main and on the minimal prototype? | VERIFIED-VM: yes (the gap) | `k3s-probe-net` A | `mallory (forced route) -> pod on alpha, the spine [O2] ipv4: CONNECTS`, `ipv6: CONNECTS`, `mallory ping -> pod on alpha: ANSWERS`, `-> pod on beta, through the spine ipv4: CONNECTS` |
| P2 / O2 | Does `ingressDeny: fromEntities: [world]` with `enableDefaultDeny: false` close K05/K06 on a Cilium device and the O2 case? | VERIFIED-VM | `k3s-probe-net` C, C2; `k3s-hostile` K05d, K06d, K11f | Phase C2 (nft table removed): every attack line `blocked` except the labelled pods. `cilium_drop_count_total direction=INGRESS reason=Policy denied by denylist 22`. `192.168.77.3 maps to identity identity=9` (world-ipv4), `192.168.77.2 … identity=6` (remote-node) |
| P2 | Does the policy leave the rest working? | VERIFIED-VM | `k3s-probe-net` C, D; `k3s-hostile` | `FINDING C pod on beta -> pod on beta: CONNECTS`, `pod on alpha -> pod on beta ipv4/ipv6`, `host beta -> its own pod`, `host alpha -> pod on beta ipv4/ipv6`, `host beta -> pod on alpha`, `-> ClusterIP of web`, `-> the API ClusterIP`, `-> NodePort on alpha`, `host alpha -> NodePort on beta`, `pod on beta -> the outsider (a reply comes back)`: all `CONNECTS`. DNS answers. `kubectl logs`/`exec` work. `Cluster health: 2/2 reachable` (K41) |
| P2 | Do the pod label and the namespace label opt out? | VERIFIED-VM | `k3s-probe-net` C; `k3s-hostile` K05o | `outsider -> labelled pod on beta: CONNECTS`, `outsider -> pod in a labelled namespace on beta: CONNECTS` |
| P2 | Does ClusterMesh still form? | VERIFIED-VM | `k3s-clustermesh-nodeport` | passed (550 s): `peering established on both sides`, `cross-cluster pod ping over native routing`, `global Service merges backends from both clusters` |
| O3 | Does a NodePort Service take source ranges? | VERIFIED-VM: no | `k3s-probe-net` D | `spec.LoadBalancerSourceRanges: Forbidden: may only be used when type is 'LoadBalancer'`; `metadata.annotations[service.beta.kubernetes.io/load-balancer-source-ranges]: Forbidden: may only be used when type is 'LoadBalancer'` |
| O3 | Cilium default: do ranges guard the NodePort of a LoadBalancer Service? | VERIFIED-VM: no | `k3s-probe-net` D | `all-types=false lb-cluster`: `mallory->alpha:vip4=blocked mallory->alpha:nodeport4=CONNECTS … nodeport6=CONNECTS` |
| O3 | With `bpf-lb-source-range-all-types=true`? | VERIFIED-VM: every front, both families, ETP Cluster and Local | `k3s-probe-net` D | `all-types=true lb-cluster` and `lb-local`: every `mallory->…` is `blocked`; `host-alpha`, `host-beta`, `pod-alpha`, `pod-beta` all `CONNECTS` (ETP Local: on the node with the backend) |
| O3 | Who do ranges restrict? | VERIFIED-VM: outside sources only | `k3s-probe-net` D | `lb-mallory` (ranges hold only mallory): mallory connects; every host and pod line is `CONNECTS` too (socket load balancing) |
| O3 | Unlabelled backend, source inside the ranges | VERIFIED-VM: answers on some fronts only | `k3s-probe-net` D | `lb-unlabelled`: `mallory->alpha:vip4=CONNECTS … mallory->beta:vip4=CONNECTS mallory->beta:nodeport4=blocked` |
| O3 | A NodePort-type Service with the flag on | VERIFIED-VM: still open | `k3s-probe-net` D | `NodePort Service …, mallory -> alpha: CONNECTS` |
| O3 | Which admission kinds are served? | VERIFIED-VM | `k3s-probe-net` | `validatingadmissionpolicies admissionregistration.k8s.io/v1`, `mutatingadmissionpolicies admissionregistration.k8s.io/v1` |
| O3 | Does the ValidatingAdmissionPolicy work? | VERIFIED-VM | `k3s-probe-net` E; `k3s-hostile` K18 | `VAP a NodePort Service: REFUSED: … denied request: type NodePort cannot carry source ranges`; `without ranges: REFUSED`; `range outside the allowed set: REFUSED`; `0.0.0.0/0: REFUSED`; `member ranges: ADMITTED`; `ClusterIP: ADMITTED`; `externalIPs: REFUSED`; labelled namespace and `kube-system`: `ADMITTED`; `an update of an existing NodePort Service`: refused |
| O3 | Does a MutatingAdmissionPolicy default the ranges? | REFUTED as `ApplyConfiguration`, VERIFIED-VM as `JSONPatch` | `k3s-probe-net` E (`.run5`); `k3s-hostile` | `error applying patch: invalid ApplyConfiguration: may not mutate atomic arrays, maps or structs: .spec.loadBalancerSourceRanges`. With JSONPatch: `HOSTILE INFO the default source ranges of a LoadBalancer Service: ["192.168.77.1/32","fd00:77::1/128","192.168.77.2/32","fd00:77::2/128","10.1.0.0/16","fd10:1::/56"]` |
| O3 | End to end in the hostile suite | VERIFIED-VM | `k3s-hostile` (`prototype.run2`) | K08, K10n, K13 (both families, both nodes), K13m, K13p, K17, K18: SAFE |
| O3 | The ClusterMesh API Service | VERIFIED-VM | `k3s-hostile` run 1 → run 2; `k3s-clustermesh-nodeport` | Run 1 GAP: `K10n … alpha … (ipv4): open: [31368]` (the Service's NodePort, no ranges). After the change: `open: []`. Node-port exposure as LoadBalancer with class `clan.lol/node-port`: `FINDING O3 the ClusterMesh API Service's source ranges: ["192.168.77.1/32","192.168.77.2/32","192.168.77.4/32","192.168.77.3/32","10.1.0.0/16","10.3.0.0/16"]`, the mesh forms |
| O3 | `cilium clustermesh status` on a Service without address | REFUTED as a check | `k3s-clustermesh-nodeport` run 1 | `Error: Unable to determine status:  unable to derive service IPs automatically`. Use `cilium-dbg status` (`ClusterMesh: 1/1 remote clusters ready`) |
| O3 | UDP and SCTP fronts; IPv6 extension headers | NOT-RUN | – | – |
| P3 | tcx guard ahead of Cilium | NOT-RUN, withdrawn (owner decision O3) | – | – |
| P7 | HAProxy fronts on loopback: join, Cilium agent and operator, kubelet | VERIFIED-VM | `k3s-hostile` K27; `k3s-probe-net`; `k3s-clustermesh-nodeport`; `k3s-probe-rejoin` (three servers) | `LISTEN … 127.0.0.1:7443`, `LISTEN … [::1]:7443`; inside the Cilium agent: `127.0.0.1 kubeapi-k3s.test.clan`, `::1 kubeapi-k3s.test.clan`; HAProxy: `Server k3s_api/alpha-4 is DOWN … Network is unreachable` at 9 s, `is UP … Layer7 check passed, code: 200` at 30 s |
| P6 | Kubelet 10250 for servers only, 4240 for members only | VERIFIED-VM | `k3s-hostile` K41, K42 | `K42 kubectl exec reaches a pod on the agent`, `K42 kubectl logs reaches the kubelets of both nodes`, `K41 … reaches Cilium's health port … (ipv4/ipv6)`, `K41 Cilium reports every node reachable: Cluster health: 2/2 reachable` |
| – | `trustedInterfaces` removed; K20/K21 after | VERIFIED-VM | `k3s-hostile` | `K20 a pod on beta reaches only the cluster ports of alpha's node address: unexpected: []; all open: [6443, 8080, 31092, …]` (8080 and the NodePort are the suite's Service); agent: `all open: []`; `K21 … (IPv6): all open: [6443]` |
| P5 | Full-format tokens on the founding server and on joiners | VERIFIED-VM | `k3s-hostile` K34; `k3s-probe-rejoin` | `K34 every join token of alpha carries the CA pin: prefixes: ['K10']`, `K34 alpha joined with a verified CA: 0 warning line(s)`; three servers: `server-token: K10c5a47eea5... server length 141`, three etcd members |
| P5 | What is the pin? | REFUTED: not the hash of the `server-ca.crt` file. It is the SHA-256 of the DER of the root certificate (the PKI's `ca-hash`) | `k3s-probe-net` run 3 (`.run3.wrong-pin`); `k3s-probe-rejoin` | With the file hash as pin: `Failed to validate connection to cluster at https://kubeapi-k3s.test.clan:7443: CA cert validation failed: … x509: certificate signed by unknown authority`, 294 times, the agent never joined. File hash `ec49934f…`, token pin `c5a47eea…`. Source: k3s `pkg/clientaccess/token.go` `hashCA`, `appendCertsFromPEM` |
| P5 | A join against a CA that does not match the pin | VERIFIED-VM: fails closed, before the secret is sent | `k3s-probe-net` run 3 | same lines: the node stops at `/cacerts` |
| P4 | `services.k3s.clusterInit = false` with `cluster-init: true` in the config file founds a cluster | VERIFIED-VM | every k3s suite of this round | `ExecStart=…/bin/k3s server \` without `--cluster-init`; `"cluster-init":true` in `config.yaml` |
| P4 | A drop-in `config.yaml.d/90-rejoin.yaml` (`server:`, `cluster-init: false`) beats `cluster-init: true` | VERIFIED-VM | `k3s-probe-rejoin` | `Managed etcd cluster not yet initialized`, then `Get "https://kubeapi-k3s.test.clan:7443/v1-k3s/server-bootstrap"`: the server joins, it does not found |
| P4 | A wiped server rejoins as a new etcd member | VERIFIED-VM, with one condition: its node object is deleted first | `k3s-probe-rejoin` run 3 | Before the delete, again and again: `etcd cluster join failed: duplicate node name found, please use a unique name for this node`. After `kubectl delete node alpha`: beta logs `Removing etcd member from cluster due to node delete`, alpha logs `Adding member alpha-237d5231=https://192.168.77.1:2380 to etcd cluster [beta-… gamma-…]`; three members, `FINDING P4b Ready nodes seen from alpha: 3`, the first cluster's ConfigMap reads `first` |
| P4 | The node-password secret needs its own delete | REFUTED: it goes with the node object | `k3s-probe-rejoin` | `Error from server (NotFound): secrets "alpha.node-password.k3s" not found` after the node delete |
| P4 | The guard may let a rejoining server start once | REFUTED | `k3s-probe-rejoin` run 1 | First start: `failed to bootstrap cluster data: Get "…/v1-k3s/server-bootstrap": EOF` (no HAProxy backend yet). Second guard run: `this machine is the clusterInit server and has no etcd data, but the server at 192.168.77.2 answers on port 6443`: refused for good |
| P4 | "The etcd directory exists" means "I have the data" | REFUTED | `k3s-probe-rejoin` run 2 | After the failed join the guard removed the drop-in (`this server has its data again: removing …`). Next start: `Managed etcd cluster initializing`, `Starting etcd for new cluster, cluster-reset=false`, then a loop of `no bootstrap data found in datastore - check server token value and verify datastore integrity` |
| P4 | A joined init server with the drop-in left in place; and with the drop-in removed by hand | VERIFIED-VM | `k3s-probe-rejoin` run 3 | `P4c restart with data and the drop-in left in place: restart rc=0; API back: YES`; `P4d restart with data, without the drop-in: restart rc=0; API back: YES`; three members both times |
| O4 | Pod Security default through the admission configuration | VERIFIED-VM | `k3s-hostile` K50–K53 | `pods "privileged" is forbidden: violates PodSecurity "baseline:latest": privileged`; `violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true)`; `Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false`; K52 admitted; `K53 every pod of kube-system runs: 0 pod(s) not running` |
| – | The state beacon and the decider (design §3.7) | NOT-RUN: new code. The prototype guard only got the `rejoinDropin` rule | – | – |
| – | Token stamp (T4), audit log, `nodePorts.allowedSources` in a suite, K11o, K13a, K13u, K13x, K28, K29, K35, K36, K40 | NOT-RUN | – | – |

## 2. Results on rke2

| ID | Question | Result | Suite | Log lines (file in `runs/`) |
|---|---|---|---|---|
| all | The hostile suite on the full prototype | VERIFIED-VM: 109 verdicts SAFE, no GAP | `rke2-hostile` (`prototype.run2`) | `RKE2_HOSTILE_OK`; K05d, K06d, K08, K10n, K11f, K13, K13m, K13p, K17, K18, K20, K21, K24, K27, K34, K41, K42, K50–K53 all SAFE |
| P7 | Loopback fronts on rke2 | REFUTED as drafted, then VERIFIED-VM after a design change | `rke2-hostile` run 1 → run 2 | Run 1, on the agent: `Connecting to proxy url="wss://192.168.77.1:8443/v1-rke2/connect"`, `Failed to connect to proxy. Empty dialer response error="dial tcp 192.168.77.1:8443: connect: connection timed out"`; on the server: `failed to find Session for client beta`; `kubectl exec`: `error dialing backend: proxy error from 127.0.0.1:9345 while dialing 192.168.77.2:10250, code 502: 502 Bad Gateway`. Run 2, with the agent's supervisor front on 9345: `Remotedialer connected to proxy url="wss://192.168.77.1:9345/v1-rke2/connect"`, `K42 … SAFE`, `K27 the front 9345 of beta listens on loopback only: binds: ['127.0.0.1', '[::1]']` |
| P5 | Full-format tokens, founding server, joining servers and agent | VERIFIED-VM | `rke2-hostile` K34; `rke2-probe-rejoin` | `server-token: K1046c47609f... server length 141`; file hash `59f59df1…` is not the pin `46c47609…`; three etcd members |
| P5 | A wrong pin on rke2 | NOT-RUN | `rke2-probe-rejoin` | The hand-started agent stopped earlier: `failed to get node name and addresses: no default routes found`. rke2 uses the k3s client package |
| P4 | The drop-in makes the init server a joiner | VERIFIED-VM | `rke2-probe-rejoin` | `Managed etcd cluster not yet initialized`. Also: `Unknown flag --cluster-init found in config.yaml, skipping`: rke2 does not know the key; `server:` alone decides |
| P4 | Node object kept | VERIFIED-VM: no join, no new cluster | `rke2-probe-rejoin` | `etcd cluster join failed: duplicate node name found, please use a unique name for this node`; etcd keeps `alpha-cf1c7507`, alpha `NotReady` |
| P4 | After `kubectl delete node alpha` | VERIFIED-VM | `rke2-probe-rejoin` | `secrets "alpha.node-password.rke2" not found`; `Adding member alpha-2a7ea013=https://192.168.77.1:2380 to etcd cluster [gamma-68cfb59a=… beta-4a1023d0=…]`; three members; three Ready nodes; ConfigMap reads `first` |
| P4 | Restart with data: drop-in in place; drop-in removed | VERIFIED-VM | `rke2-probe-rejoin` | `P4c … restart rc=0; API back: YES`; `P4d … restart rc=0; API back: YES` |
| O4 | Pod Security through `pod-security-admission-config-file` | VERIFIED-VM | `rke2-hostile` K50–K53 | the same messages as on k3s |
| P1, P2, O3 | The phase-by-phase network probe | NOT-RUN on rke2 | – | `rke2-probe-net` exists and evaluates; the end state is proven by `rke2-hostile` |
| – | `profile = "cis"` boots | VERIFIED-VM (one server) | `rke2-probe-cis` | `ExecStart=…/bin/rke2 server \` ` --profile=cis`; `the node became Ready: YES`; `the Cilium agent became Ready: YES`; `etcd  etcd --config-file=…`, `drwx------ 3 etcd etcd … /var/lib/rancher/rke2/server/db/etcd`; `--admission-control-config-file=/etc/rancher/rke2/pod-security.yaml`, `--audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log`; `default-network-policy` in `default`, `kube-public`, `kube-system`; `plain 1/1 Running`; `pods "privileged" is forbidden: violates PodSecurity "baseline:latest"` |

Existing suites on the full prototype (both distros where named):

| Suite | Result | File in `runs/` |
|---|---|---|
| `k3s-hostile` | passed (1497 s), 105 SAFE, no GAP | `k3s-hostile.prototype.run2.verdicts.txt` (run 1: one GAP, K10n, the ClusterMesh API Service's NodePort) |
| `rke2-hostile` | passed (1463 s), 109 SAFE, no GAP | `rke2-hostile.prototype.run2.verdicts.txt` (run 1 stopped at `kubectl exec`: the agent tunnel) |
| `k3s-clustermesh-nodeport` | passed (550 s) | `k3s-clustermesh-nodeport.prototype.txt` |
| `k3s-join`, `rke2-join` | passed (365 s, 479 s) | `k3s-join.prototype.txt`, `rke2-join.prototype.txt` |
| `k3s-single`, `rke2-single` | passed (428 s, 359 s) | `k3s-single.prototype.txt`, `rke2-single.prototype.txt` |
| `<distro>-ha`, `-data-plane`, the other clustermesh suites, the gateway and netif suites that boot a cluster | NOT-RUN on the prototype | – |

Side findings (not part of the design):

- rke2 ignores two keys the service renders: `Unknown flag --cluster-init found in config.yaml, skipping`, `Unknown flag --disable-helm-controller found in config.yaml, skipping`. The helm-controller runs on rke2 (`helm-install-rke2-…` pods in `rke2-probe-cis`).
- A k3s server ignores `disable-apiserver-lb`: `Unknown flag --disable-apiserver-lb found in config.yaml, skipping`.
- The current guard's override file allows one start. A server that fails once after it (for any reason) needs the file again.

## 3. Positive controls of the new verdicts

A `SAFE` is only worth something when the attack is seen to work somewhere.

| Verdict | Control |
|---|---|
| K05d, K06d | K05o in the same phase (the labelled pod answers on the same path); `k3s-probe-net` phase B (the same command connects without the policy) |
| K11f | `k3s-probe-net`: the forced route connects in phases A and B and reaches the labelled pod in phase C. In the hostile suite only "the listener answers a pod" is asserted. Add K11o |
| K10n, K13, K17 | K13m, K13p in the same phase; `k3s-probe-net` `lb-open`, `lb-mallory` (mallory connects when ranges allow) |
| K18 | the suite's `web` Service is admitted as LoadBalancer in the same phase |
| K27 | the node joined through that front; `ss` shows the listener |
| K34 | `k3s-probe-net` run 3 (a wrong pin is refused) |
| K50 | K51, K52 |
| K08 | **none**: a NodePort never answered on an underlay address (D69). The verdict states a fact, it proves nothing about source ranges |
| K20, K21 | the scan finds 6443 on a server |

## 4. Contracts from the other probe rounds

Written into `specs/design-kube.md` §3.12, not run here: `clan.networkFacts.forwardLinks = ["cilium*" "lxc*"]` on every cluster member (a CLAT host forwards IPv6 by default-deny); `fabricInside` (CLAT and NAT64 links always, a router zone only with `fabric = true`); the netif unit names and the opt-in `ra = true`.

One open point between this round and the gateway round: `router-kube` showed that a zone with `fabric = true` reaches pods. It ran without the clusterwide policy. For Cilium a zone host is `world`, so with the policy it reaches labelled pods only. Both together: NOT-RUN.

## 5. What the prototype is, and what it is not

`prototype.patch` holds, beside the hostile suites and the minimal fixes:

- `lib/kube-cluster/haproxy.nix`: fronts on loopback, `source` on server lines. `service.nix`: an rke2 agent's supervisor front on 9345.
- `lib/kube-cluster/firewall.nix`, `default.nix`, `service.nix`: the matrix; kubelet for servers, 4240 for members, no 2381, no front ports, no `trustedInterfaces`; loopback `extraHosts`.
- `lib/kube-cluster/vars.nix`: tokens `K10<ca-hash>::server|node:<64 hex>`.
- `lib/kube-cluster/bundle.nix`, `cilium.nix`, `mesh.nix`, `cluster-interface.nix`, `service.nix`: the clusterwide policy, `bpf-lb-source-range-all-types`, the two admission policies and their bindings, the ClusterMesh API Service with ranges, the options `outsideIngress.policy`, `nodePorts.allowedSources`, `nodePorts.admission`, `podSecurity.enforce`.
- `lib/kube-cluster/service.nix`, `services/{k3s,rke2}/default.nix`: the Pod Security admission file.
- `lib/kube-cluster/nixos.nix`: the guard's `rejoinDropin` rule. `services/k3s/default.nix`: `clusterInit = false`.
- Suites: `hostile.nix` (new verdicts), `join.nix` and `clustermesh-nodeport.nix` (adapted), and the throwaway probes `probe-net.nix`, `probe-rejoin.nix`, `services/rke2/tests/vm/probe-cis.nix`.

It is not mergeable as it is:

- `check` never ran. nix-unit tests that pin the old firewall rows, HAProxy binds, token length, `clusterInit` and the mesh Service type will fail.
- `lib/kube-cluster/tests/vm/ha.nix` still has its init-guard phase on port 2381, which is closed now.
- Suites that create a NodePort Service (`data-plane`, others) were not run; the admission policy refuses that type.
- On k3s the service owns `kube-apiserver-arg`, so `configOverrides` cannot set it (design §3.10).
- The probe suites must not land.
