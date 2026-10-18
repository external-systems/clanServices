# wireguard-mesh

`wireguard-mesh` creates a host-level, dual-stack WireGuard full mesh. Every
member connects directly to every other member through systemd-networkd. The
service has no Kubernetes dependency and can provide private node transport for
ordinary NixOS machines, rke2, k3s, or other clanServices.

One inventory instance is one independent mesh. Each member receives one `/32`
IPv4 and one `/128` IPv6 on its WireGuard interface. The default peer
`AllowedIPs` contain only those host addresses; no pod, service, or LAN prefix
is routed implicitly.

## Quick start

This example uses clan-core's `internet` service for endpoint discovery. Its
`peer.hosts` exports are consumed by `endpointSources`; no WireGuard-specific
endpoint code is needed in the underlay service.

```nix
inventory.instances = {
  underlay = {
    module.name = "internet";
    roles.default.machines = {
      alpha.settings.host = "203.0.113.10";
      beta.settings.host = "203.0.113.11";
      gamma.settings.host = "203.0.113.12";
    };
  };

  mesh = {
    module = {
      name = "wireguard-mesh";
      input = "clan-community";
    };
    roles.peer = {
      settings.endpointSources = [
        {
          service = "clan-core/internet";
          instance = "underlay";
        }
      ];
      machines = {
        alpha.settings = {
          ipv4 = "192.168.77.1";
          ipv6 = "fd00:77::1";
        };
        beta.settings = {
          ipv4 = "192.168.77.2";
          ipv6 = "fd00:77::2";
        };
        gamma.settings = {
          ipv4 = "192.168.77.3";
          ipv6 = "fd00:77::3";
        };
      };
    };
  };
};
```

Generate the per-machine keys after changing membership:

```console
clan vars generate alpha
clan vars generate beta
clan vars generate gamma
```

The private key is deployed only to its own machine. Peer public keys are
public vars consumed during evaluation.

## Roles

### `peer`

A dual-stack mesh member. Every peer renders all other members as WireGuard
peers. Role settings apply to every member; per-machine settings under
`roles.peer.machines.<name>.settings` override them.

A multi-member mesh needs at least one reachable endpoint, not an endpoint on
every member. A NAT or outbound-only member may leave `endpoint` and
`endpointSources` empty while dialing reachable members. The default 25-second
keepalive maintains that path.

## Options

| Option | Default | Purpose |
|---|---|---|
| `ipv4` | required | Mesh IPv4 host address, without `/32`. Unique within the instance. |
| `ipv6` | required | Mesh IPv6 host address, without `/128`. Unique within the instance. |
| `interface` | `null` | Interface name. `null` derives `wg-<instanceName>`; the kernel limit is 15 characters. |
| `port` | `51820` | UDP listen port for this machine. Peers use each target's own port. |
| `mtu` | `1420` | WireGuard link MTU. Must be at least 1280 for dual-stack operation. |
| `domain` | `null` | Mesh hostname suffix. `null` uses the instance name. |
| `endpoint` | `null` | Explicit hostname or IP, without brackets or port. Overrides `endpointSources`. |
| `endpointSources` | `[]` | Ordered `{ service, instance }` export sources. The first non-empty `peer.hosts` value wins. |
| `persistentKeepalive` | `25` | Keepalive seconds on this machine's peer entries. Set `null` to disable. |
| `extraAllowedIPs` | `[]` | Additional prefixes other members route to this machine through the mesh. |
| `firewall.openPort` | `true` | Open this machine's WireGuard UDP port. |
| `firewall.trust` | `true` | Add the WireGuard interface to `networking.firewall.trustedInterfaces`. |

To use BORG's `lan` service instead of clan-core `internet`, select its manifest
name and instance explicitly, for example `{ service = "lan"; instance =
"robot-base"; }`.

`extraAllowedIPs` is a generic routing escape hatch. For each remote member,
the service adds those prefixes to both WireGuard `AllowedIPs` and kernel
routes. It does not enable IP forwarding, BGP, Cilium native routing, or any
other routing control plane.

## Exports

The service declares `peer` as an input and publishes:

- `networking.priority = 1000` at instance scope;
- `peer.hosts = [ "<machine>.<domain>" ]` per member, retaining the standard
  peer port semantics (SSH port 22, not the WireGuard UDP port);
- `node_transport` per member: `ipv4`, `ipv6`, `interface`, `port`, `mtu`,
  `endpoint` (nullable), and `instance`.

Consumers should use `clanLib.getExport` or `clanLib.selectExports`, never raw
export scope keys. The mesh addresses, interface, and MTU are sufficient for a
Kubernetes service to derive node IPs and its tunnel budget without depending
on WireGuard internals.

## Firewall and forwarding

By default the UDP listen port is open and the mesh interface is trusted.
Disable either behavior through the `firewall` options when a consumer needs a
more restrictive posture. The service does not enable IPv4 or IPv6 forwarding;
ordinary host-to-host mesh traffic does not require it.

## Tests

The nix-unit suite covers rendering, exports, endpoint selection, validation,
and multi-instance collisions. The hermetic NixOS VM suite boots three ordinary
machines and proves dual-stack connectivity between every pair through real
WireGuard handshakes. Test keys are generated by the clan test harness; no fleet
secrets are used.

```console
nix build .#checks.x86_64-linux.wireguard-mesh
nix build .#checks.x86_64-linux.coverage
```
