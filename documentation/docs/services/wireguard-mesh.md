# wireguard-mesh (legacy)

`wireguard-mesh` is the implemented phase-4 transport: a dual-stack
WireGuard full mesh on one multi-peer interface per member. Its VM suite
proves basic pairwise host connectivity.

Round 15 supersedes this interface model. `routed-fabric` now owns stable
loopback addressing, one point-to-point WireGuard interface per declared
adjacency, FRR/BFD/Zebra, and native-routed cluster traffic. The old model
cannot represent shared-VIP ECMP because overlapping `AllowedIPs` across
peers on one interface select only one cryptokey.

The service remains temporarily while consumers migrate in phase 5R1. It
is not the target transport and is **deleted outright** once
`routed-fabric` reaches parity — not archived or commented out; the
historical docs record it. New inventory should follow the round-15
contract, not add the retired auxiliary routed-interface pattern.
