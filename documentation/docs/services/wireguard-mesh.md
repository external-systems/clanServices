# wireguard-mesh

`wireguard-mesh` is the tunnel-profile transport (D58): dual-stack
WireGuard transport consumed through the same generic `node_transport`
export as routed-fabric, paired with Cilium **tunnel mode (VXLAN)** and the
`nodePort` exposure capability. IfState owns the interface, peers, and
routes. Its VM suite proves real handshakes and pairwise connectivity;
all dependent tunnel ClusterMesh suites are also green.

The service retains its existing interface model: **ONE shared full-mesh
multi-peer WireGuard interface** with one peer per remote machine and
stable `/32`+`/128` addresses per member. It does **not** adopt
routed-fabric's one-interface-per-adjacency model — that cryptokey/ECMP
shape is a routed-fabric property. The generic `node_transport` export
(schemaVersion 2) describes that single interface: Linux-name-keyed
datapath interfaces with MTU, one `directRoutingDevice`,
`datapath.mode = tunnel` with sibling `datapath.tunnelProtocol` (VXLAN),
and the `nodePort` exposure capability.

Round 17 ends the "pending migration/removal" status: `wireguard-mesh` is
a **supported profile**, not a retiring service. The legacy
`services/fleet-routing/` code and the `lib/import-flake/` adapter were
deleted in the round-17 cleanup.

Pick the profile by datapath need (native + internal LoadBalancer via
`routed-fabric`, or tunnel/VXLAN + nodePort via `wireguard-mesh`) and let
the generic `node_transport` export carry the facts to the distro services.

## Allocation (D64)

Run `clan vars generate <machine>` after changing membership and before eval.
Independent shared generators hold an RFC 4193 ULA /48 and the member-uniform
`ipv4Pool` (default `198.18.128.0/17`, disjoint from routed-fabric's default
loopback pool). Pool edits cannot re-roll the ULA. Evaluation checks that the
recorded pool equals the setting and that allocated hosts remain inside their
pool or ULA `/64`. Each machine's public node generator allocates its IPv4
host from that pool and its IPv6 host from the ULA's `:0::/64`. Explicit
`ipv4` and `ipv6` settings win. Evaluation rejects missing values, duplicate
addresses, unequal pools, foreign-pool and underlay/cluster overlaps, and
collisions with other rendered WireGuard configuration. Duplicate messages
name both machines and direct `--regenerate` at the newer machine. Renaming a
machine creates a new identity and new vars, with no migration shim.

D63 requires every member pair to have an endpoint on at least one side,
rejects overlapping `extraAllowedIPs` between peers, and rejects listen-port
clashes between any WireGuard interfaces on the same host. Every listen port
is reserved in `net.ipv4.ip_local_reserved_ports`; additional ports or ranges
can be supplied through `clanServices.networking.reservedPorts`.
