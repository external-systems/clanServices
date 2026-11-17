# Glossary

The words the netif pages use. One word per thing. The agent edition is
§10 of
[`specs/netif.md`](https://github.com/external-systems/clanServices/blob/main/specs/netif.md).

| Word | Meaning |
|---|---|
| **Apply, reapply** | One run of IfState. It makes the kernel's network state match the configuration. A reapply is a run with nothing changed; it must change nothing. |
| **Contract gate** | netif is stable in this repo: every phase done and proven in VM tests. |
| **Decision** | A numbered rule in the contract: `N1` to `N30`. |
| **Default route owner** | The one netif link per address family that may install the default route. |
| **Deploy target** | Where clan connects to deploy. Always an underlay address or a name. |
| **Endpoint** | An address other machines dial to reach this one. |
| **Fabric** | The routed WireGuard and FRR network between machines. It runs on top of the underlay and belongs to `routed-fabric`. |
| **Field gate** | home runs netif on real machines. |
| **Field-checked** | Verified on a real machine because no VM test can do it. |
| **Gate** | A check a phase must pass. If it fails, the phase stops and the owner decides. |
| **Guest port** | A bridge port a hypervisor made for a VM. |
| **Instance** | One netif entry in the inventory: one network segment and the machines on it. |
| **Interface** | The Linux name of a link, such as `eth1` or `wan`. At most 15 characters. |
| **Link** | One network attachment of one machine: a NIC, a VLAN, a bond or a bridge. Its inventory key is its logical name. |
| **Lockout guard** | Rolls the network back when the gateways stop answering after an apply. |
| **Manager** | The software that configures links in a mode: IfState or NetworkManager. One per mode. |
| **Mode** | A NixOS specialisation, or the parent configuration (`default`). You switch by rebooting. |
| **Owner** | A daemon in the ownership registry, with the kernel objects that are its. |
| **Phase** | A delivery step, written `P0` to `P8` ("phase P2"). Decisions are `N…`, so the two never share a label. |
| **Preset** | An owner that switches on when its daemon is enabled. |
| **Probe** | A throwaway VM test that checks an idea before it is built. |
| **Renderer** | The part of netif that writes one manager's configuration. |
| **Runtime fact** | A value that only exists on the running machine, such as a delegated prefix. |
| **Segment** | The network an instance describes. Its settings are defaults for its links. |
| **Session unit** | A daemon with a long-lived connection. It starts after the network is online. |
| **Suite** | A registered VM test. "VM-proven" means a suite passes. |
| **Trust** | Whether the firewall accepts everything that arrives on a link. Off unless declared. |
| **Underlay** | The network a machine is plugged into: its NICs, Wi-Fi and their addresses. netif's territory. |
| **Use case** | A machine class, `U1` to `U11`. |
| **Zone** | A label on a link (`wan`, `lan`) that other modules read. netif gives it no meaning. |
