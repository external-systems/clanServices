# Mode scoping for the services that render into a machine
# (specs/netif.md N4): `routed-fabric`, `k3s`, `rke2`.
# Each has a per-machine `modes` setting. In the other modes of the
# machine the service renders nothing; what clan reads from the parent
# configuration stays.
{lib}: let
  # What stays in every mode: vars generators, facts and the eval seams
  # (`clan`), the checks, and the package set.
  always = [
    "clan"
    "assertions"
    "warnings"
    "nixpkgs"
  ];
in rec {
  # The setting, the same on every service.
  option = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    example = ["developer"];
    description = ''
      The machine's modes this instance is active in ('default' is the
      parent configuration; see the 'modes' service). Empty means every
      mode. In the other modes the service renders no unit, link, route,
      firewall rule or sysctl on this machine; its vars, exports, facts
      and checks stay (specs/netif.md N4).
    '';
  };

  # Whether this configuration is one of the instance's modes.
  active = config: modes: modes == [] || lib.elem config.clanServices.networking.mode.name modes;

  # Split one service's configuration (a plain attribute set): `clan`,
  # the checks and the package set in every mode, the rest only in the
  # instance's modes.
  scope = isActive: configuration:
    lib.mkMerge [
      (lib.filterAttrs (name: _: lib.elem name always) configuration)
      (lib.mkIf isActive (removeAttrs configuration always))
    ];

  # The checks every scoped service makes. `everyMode` is null, or why
  # this machine may not be limited to some modes (a spine, a border, an
  # etcd voter of a cluster with other machines).
  assertions = {
    service,
    instanceName,
    machineName,
    config,
    modes,
    everyMode ? null,
  }: let
    inherit (config.clanServices.networking) mode;
    known = lib.unique (["default"] ++ builtins.attrNames config.clanServices.networking.modes);
    unknown = builtins.filter (name: !(lib.elem name known)) modes;
    missing = builtins.filter (name: !(lib.elem name modes)) known;
    name = "${service}/${instanceName}: machine '${machineName}'";
  in [
    {
      assertion = unknown == [];
      message = "${name} limits this instance to mode(s) it does not have: ${lib.concatStringsSep ", " unknown}. Its modes are ${lib.concatStringsSep ", " known}; declare the mode in the 'modes' service or fix the name (N4)";
    }
    {
      assertion = !(active config modes) || mode.manager == "ifstate";
      message = "${name} is active in mode '${mode.name}', which uses NetworkManager; ${service} needs IfState. Limit the instance to the machine's IfState modes with 'modes = [ ... ]' in its settings, or give the mode 'manager = \"ifstate\"' (N4)";
    }
    {
      assertion = everyMode == null || modes == [] || missing == [];
      message = "${name} is ${toString everyMode} and must be active in every mode, but 'modes' leaves out ${lib.concatStringsSep ", " missing}: other machines depend on it whatever this machine boots into. Remove 'modes', or move the role to another machine (N4)";
    }
  ];
}
