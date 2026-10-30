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

D63 requires every member pair to have an endpoint on at least one side,
rejects overlapping `extraAllowedIPs` between peers, and rejects listen-port
clashes with routed-fabric on the same host. Every WireGuard listen port is
reserved in `net.ipv4.ip_local_reserved_ports`.
