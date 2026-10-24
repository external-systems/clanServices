# wireguard-mesh (legacy)

`wireguard-mesh` is the implemented phase-4 transport: a dual-stack
WireGuard full mesh on one multi-peer interface per member. Its VM suite
proves basic pairwise host connectivity.

Round 14 supersedes this interface model. `fleet-routing` now owns stable
loopback addressing, one point-to-point WireGuard interface per node pair,
FRR/BFD/Zebra, and native-routed cluster traffic. The old model cannot
represent shared-VIP ECMP because overlapping `AllowedIPs` across peers on
one interface select only one cryptokey.

The service remains temporarily while consumers migrate in phase 5R1. It
is not the target transport and will be removed after per-pair
fleet-routing reaches parity. New inventory should follow the round-14
contract, not add the retired auxiliary routed-interface pattern.
