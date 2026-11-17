# modes

Gives a machine more than one network mode, each with exactly one
network manager (`specs/netif.md` N3, N24). At most one instance per
clan.

```nix
inventory.instances.modes = {
  module.name = "modes";
  roles.default.machines.deck.settings.modes = {
    default.manager = "networkmanager"; # the normal boot: Steam, Wi-Fi from the UI
    developer.manager = "ifstate"; # a boot-menu entry: netif, tunnels, clusters
  };
};
```

- `default` is the machine's normal configuration. Every other mode
  becomes a NixOS specialisation: an extra entry in the boot menu.
- Modes are switched by rebooting, never at run time.
- A machine without an entry has one mode, `default`, with IfState.
- Every configuration gets the read-only option
  `clanServices.networking.mode = { name; manager; }`. Use it to add
  what belongs to one mode:
  `lib.mkIf (config.clanServices.networking.mode.name == "developer") { … }`.
- netif renders IfState in an `ifstate` mode and NetworkManager
  profiles in a `networkmanager` mode. A netif instance can be limited
  to some modes with its `modes` setting.
- Deploy without switching modes: `clan machines update <machine>`
  activates the default mode; `--specialisation <mode>` re-activates
  the mode the machine is booted into.
