# Modes and reboots

!!! note "Status (2026-11-17)"
    Built and tested for netif itself: the `modes` service, the
    NetworkManager and IfState renderers, and limiting a netif instance
    to some modes. The test `netif-modes` boots one machine into each
    mode in turn. Not built yet: limiting tunnels and clusters to a
    mode, Wi-Fi settings for IfState modes, hot-plugged dock Ethernet.

A mode is a NixOS specialisation. The parent configuration is the default
boot entry; every other mode is an extra entry in the boot menu. On
kamrui-h1:

| Boot entry | Mode | Network manager | Networking |
|---|---|---|---|
| NixOS (default) | gaming | NetworkManager | Wi-Fi, Tailscale |
| NixOS (developer) | developer | IfState | Wi-Fi, Tailscale, FRR fabric leaf with admin routes |
| NixOS (kubernetes) | kubernetes | IfState | developer + single-node k3s |

## Where modes are declared (planned, phase P4)

One small service, `modes`, names each machine's modes and the network
manager of each:

```nix
instances.modes = {
  module.name = "modes";
  module.input = "clanServices";
  roles.default.machines.kamrui-h1.settings.modes = {
    default.manager = "networkmanager";
    developer.manager = "ifstate";
    kubernetes.manager = "ifstate";
  };
};
```

- `default` is the parent configuration. It may use either manager.
- A machine that is not listed has one mode, with IfState.
- The service creates the boot entries and sets a read-only option,
  `clanServices.networking.mode`, in each. netif, the fabric and the
  cluster services read it. Your machine configuration reads it too, to
  add KDE or Steam to a mode.

A machine's modes can differ in kind: a headless server in one, a
gamescope box in another.

A prototype of this service was evaluated on 2026-11-16, both ways
round: NetworkManager by default with IfState modes, and IfState by
default with a NetworkManager mode. Each configuration got exactly one
manager and passed every NixOS assertion. One change in the shared
IfState base is needed: it must switch IfState on only in IfState
modes. Today it forces IfState on everywhere.

## One manager per mode

Each mode has exactly one network manager. A mode with both NetworkManager
and IfState fails evaluation. netif uses the stock nixpkgs modules for both,
so nothing is forked.

The NetworkManager renderer covers what a gaming machine needs: wired links
(static or DHCP) as declarative profiles, Wi-Fi through iwd, and unmanaged
marks for interfaces that other software owns. WireGuard, VLANs, bonds,
bridges, policy routing and the fabric need IfState, so a mode that uses
them must be an IfState mode.

## Switch by reboot

You switch modes by rebooting and picking an entry. Live switching between
modes is not supported. Every mode starts from a clean network state, so
nothing has to be cleaned up when you move between them.

## Deploying to a machine with modes

A plain `clan machines update` activates the default mode, so a deploy while
you are in developer mode would drop you into gaming. Use one of these
instead:

```bash
# re-activate the mode you are in
clan machines update kamrui-h1 --specialisation developer

# or install the new generation and apply it on the next reboot
nixos-rebuild boot --flake .#kamrui-h1 --target-host <host>
```

## Which services follow modes

Each networking or cluster service instance names the modes it runs in.
Its secrets and published facts exist in every mode; its units, links and
firewall openings exist only in the modes you name.

- A fabric leaf, a Kubernetes agent and a single-node cluster can be limited
  to some modes.
- A spine, a border or an etcd voter of a shared cluster must run in every
  mode of its machine. Turning one off would cut transit or quorum for other
  machines, so evaluation rejects it.
- The fabric, k3s and RKE2 need IfState, so they only run in
  IfState modes.
