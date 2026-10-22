# wireguard-mesh

`wireguard-mesh` creates a host-level, dual-stack WireGuard full mesh over
systemd-networkd. It has no Kubernetes dependency — it provides private node
transport for ordinary NixOS machines as well as rke2, k3s, or other
clanServices.

One inventory instance is one independent mesh. Each member gets one `/32`
IPv4 and one `/128` IPv6 on its WireGuard interface; the default peer
`AllowedIPs` contain only those host addresses, and no pod, service, or LAN
prefix is routed implicitly. Per-machine keys come from clan vars
(`clan vars generate <machine>`); private keys deploy only to their own
machine.

Endpoint discovery is decoupled: the `peer` role consumes `peer.hosts`
exports from an underlay service (for example clan-core's `internet`
service) via `endpointSources`, or an explicit `endpoint`. NAT or
outbound-only members may leave endpoints empty and dial reachable members;
a 25-second keepalive maintains the path.

The service publishes `node_transport` exports (addresses, interface, port,
MTU, endpoint) — exactly what a cluster service needs to derive node IPs
and its tunnel MTU budget without depending on WireGuard internals. This is
the host WireGuard full mesh that the cluster services use as their only
tested node transport (SPEC.md §6.3).

For options, exports, and firewall details see the service's own
`services/wireguard-mesh/README.md` in the repo.

## Status

Implemented. The nix-unit suite covers rendering, exports, endpoint
selection, and validation; the hermetic VM suite proves dual-stack
connectivity between every pair of three ordinary machines through real
WireGuard handshakes.
