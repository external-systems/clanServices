# fleet-routing

`fleet-routing` is the flat-L3 clanService for Kubernetes and ordinary
NixOS machines. It replaces the legacy `wireguard-mesh` transport and the
BIRD-based phase-5 design with per-pair WireGuard and one FRR routing
stack per host.

## Roles

- **`member`** — encrypted dual-stack flat-L3 membership, FRR/BFD/Zebra,
  and automatic native pod routes on Kubernetes nodes.
- **`client`** — member plus cluster VIP routes and the instance-zone DNS
  stub.
- **`admin`** — client plus explicit pod/ClusterIP routes and svc/pod DNS
  zones; kamrui-h1 is the canonical dual-role example.
- **`router`** — member plus upstream peers, owned-prefix filtering,
  forwarding, and optional proxy-NDP.

## Data plane

Every machine has stable loopback `/32` and `/128` addresses. Every remote
machine gets exactly one point-to-point WireGuard interface with one peer.
This preserves cryptokey correctness and kernel ECMP across interfaces.
`AllowedIPs` and FRR route filters derive from one route policy.

FRR exchanges eBGP routes per address family, uses BFD on every fabric
path, and installs accepted routes through Zebra. Cilium peers only with
local FRR over `::1`; FRR rewrites its next hop before redistribution.
Cilium native routing then forwards remote pod traffic through the kernel
FIB.

Node-owned `node-bgp` pools advertise only from their owner. `shared-bgp`
pools advertise from every healthy eligible node and use ECMP. Ordinary
clients receive VIPs only; admin explicitly receives pod and ClusterIP
routes. External BGP peers are declared by the `router` role, not duplicated
in cluster settings.

See [Fleet routing architecture](../architecture/fleet-routing.md) and
[Networking](../architecture/networking.md) for the full contract.

## Status

Round-14 target, planned for phases 5R1–5R3. The BIRD implementation at
checkpoint `2995ac3` is legacy and is not accepted as this service's FRR /
native-routing implementation.
