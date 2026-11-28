{ifstateOverlay}: {
  config,
  lib,
  pkgs,
  ...
}: let
  ip = import ./ip.nix {inherit lib;};
  baseline = import ./sysctl-baseline.nix;
  # One manager per configuration (N2): IfState, or NetworkManager.
  inherit (config.clanServices.networking) mode;
  ifstateMode = mode.manager == "ifstate";
  # What only IfState can render: anything but a plain physical link.
  ifstateOnly =
    builtins.attrNames (
      lib.filterAttrs (_: interface: (interface.link.kind or null) != "physical") (config.networking.ifstate.settings.interfaces or {})
    )
    ++ lib.optional ((config.networking.ifstate.settings.routing.rules or []) != []) "policy-routing rules";
  cidr = import ./kube-cluster/cidr.nix {inherit lib;};
  addressValue = address:
    ip.addressFromCIDR (
      if builtins.isString address
      then address
      else address.address
    );
  # IfState 2.5.1 only warns when a declared physical NIC is missing and
  # exits 0. netif makes that loud (specs/netif.md P3a): the unit fails
  # and the journal names the link.
  physicalNames = builtins.attrNames (
    lib.filterAttrs (_: interface: (interface.link.kind or null) == "physical") (config.networking.ifstate.settings.interfaces or {})
  );
  physicalCheck = pkgs.writeShellScript "ifstate-physical-links-present" ''
    missing=""
    for name in ${lib.escapeShellArgs physicalNames}; do
      [ -e "/sys/class/net/$name" ] || missing="$missing $name"
    done
    if [ -n "$missing" ]; then
      echo "netif: declared physical links missing after IfState apply:$missing" >&2
      exit 1
    fi
  '';
  wireguardInterfaces = builtins.filter (
    interface: (interface.link.kind or null) == "wireguard" && (interface.wireguard.listen_port or null) != null
  ) (builtins.attrValues (config.networking.ifstate.settings.interfaces or {}));
  wireguardPortClaims = map (interface: interface.wireguard.listen_port) wireguardInterfaces;
  wireguardPorts = lib.sort builtins.lessThan (lib.unique wireguardPortClaims);
  fabricAddresses = lib.concatMap (
    fabric:
      [
        fabric.ipv4
        fabric.ipv6
      ]
      ++ lib.concatMap (adjacency: [adjacency.ipv4 adjacency.ipv6]) (
        builtins.attrValues fabric.adjacencies
      )
  ) (builtins.attrValues config.clan.networkFacts.fabric);
  wireguardAddresses = lib.concatMap (interface: map addressValue (interface.addresses or [])) wireguardInterfaces;
  overlayAddresses = map ip.normalizeAddress (
    builtins.filter builtins.isString (fabricAddresses ++ wireguardAddresses)
  );
  targetHost = config.clan.core.networking.targetHost or null;
  targetAddress =
    if targetHost == null
    then null
    else ip.normalizeAddress (ip.targetHostAddress targetHost);
  targetHostOnOverlay = targetAddress != null && lib.elem targetAddress overlayAddresses;
  allocationPools = config.clan.networkFacts.allocationPools or {};
  poolClaims = lib.concatMap (
    owner: map (pool: pool // {inherit owner;}) allocationPools.${owner}
  ) (builtins.attrNames allocationPools);
  crossPoolOverlaps = lib.unique (
    lib.concatMap (
      first:
        lib.concatMap (
          second:
            lib.optional (first.owner != second.owner && cidr.overlap first.cidr second.cidr)
            "${first.owner}/${first.name}=${first.cidr} overlaps ${second.owner}/${second.name}=${second.cidr}"
        )
        poolClaims
    )
    poolClaims
  );
in {
  key = "clanServices:lib/ifstate.nix";

  # The registry renders parameters.ignore; modes pick the manager (N24).
  imports = [
    ./ownership.nix
    ./modes.nix
  ];

  options.clanServices.networking.reservedPorts = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    example = ["30000-32767"];
    description = "Additional ports or ranges reserved against ephemeral allocation alongside every WireGuard listen port.";
  };

  config = {
    assertions = [
      {
        assertion = !config.systemd.network.enable;
        message = "clanServices networking is IfState-only; systemd-networkd must stay disabled";
      }
      {
        assertion = !config.networking.useDHCP;
        message = "clanServices networking is IfState-only; declare DHCP per link in netif (dhcp.ipv4, dhcp.ipv6) instead of networking.useDHCP";
      }
      {
        assertion = !ifstateMode || lib.versionAtLeast config.networking.ifstate.package.version "2.5";
        message = "clanServices requires IfState >= 2.5; apply inputs.org-pkgs.overlays.ifstate or provide an equivalent newer package";
      }
      {
        assertion = ifstateMode || ifstateOnly == [];
        message = "clanServices: mode '${mode.name}' uses NetworkManager, which renders plain wired links only, but this configuration declares ${lib.concatStringsSep ", " ifstateOnly}. VLANs, bonds, bridges, tunnels, fabric links and policy routing need an IfState mode: limit the instance to one with its 'modes' setting, or give this mode 'manager = \"ifstate\"' (specs/netif.md N2, N4)";
      }
      {
        assertion = lib.length wireguardPortClaims == lib.length wireguardPorts;
        message = "clanServices: WireGuard listen ports must be unique across all interfaces on a machine; got ${lib.concatStringsSep ", " (map toString wireguardPortClaims)}";
      }
      {
        assertion = !targetHostOnOverlay;
        message = "clanServices: clan.core.networking.targetHost '${toString targetHost}' resolves to a fabric, transfer, or tunnel address; keep the deploy target on the underlay";
      }
      {
        assertion = crossPoolOverlaps == [];
        message = "clanServices: allocation pools overlap across instances/services on one host: ${lib.concatStringsSep "; " crossPoolOverlaps}; set disjoint pool settings";
      }
    ];

    # The version envelope (specs/netif.md N35): the networking packages
    # the VM suites last passed with. A newer minor is not an error; the
    # warning says which suites to run again.
    warnings =
      lib.concatMap (
        p:
          lib.optional (ifstateMode && lib.versionAtLeast p.version p.next)
          "clanServices networking: ${p.name} ${p.version} is newer than the proven ${p.proven}.x; rerun the netif VM suites (vm-test --all --remote --rebuild) and update lib/ifstate.nix"
      ) [
        {
          name = "IfState";
          inherit (config.networking.ifstate.package) version;
          proven = "2.5";
          next = "2.6";
        }
        {
          name = "dhcpcd";
          version = pkgs.dhcpcd_latest.version or "0";
          proven = "10.5";
          next = "10.6";
        }
      ];

    nixpkgs.overlays = lib.mkAfter [ifstateOverlay];

    # DNS goes through systemd-resolved in every mode (specs/netif.md N9).
    services.resolved.enable = true;

    # The sysctl baseline (specs/netif.md N47), in every mode: `all`
    # and `default`, and the glob for links that exist before
    # systemd-sysctl runs, belong to another owner or appear later (udev
    # runs systemd-sysctl for each new link). Router advertisements are
    # off by `default` only (N48): no glob, so hot-plug links and the
    # links of iwd and NetworkManager keep their own setting.
    boot.kernel.sysctl = lib.mkMerge (
      [
        {
          "net.ipv4.ip_local_reserved_ports" = lib.concatStringsSep "," (
            lib.unique (config.clanServices.networking.reservedPorts ++ map toString wireguardPorts)
          );
        }
        (lib.mapAttrs' (key: value: lib.nameValuePair "net.ipv6.conf.default.${key}" (lib.mkDefault value)) baseline.raOff6)
      ]
      ++ lib.concatMap (scope: [
        (lib.mapAttrs' (key: value: lib.nameValuePair "net.ipv4.conf.${scope}.${key}" (lib.mkDefault value)) baseline.everyLink4)
        (lib.mapAttrs' (key: value: lib.nameValuePair "net.ipv6.conf.${scope}.${key}" (lib.mkDefault value)) baseline.everyLink6)
      ]) ["all" "default" "*"]
    );

    networking = {
      ifstate.enable = ifstateMode;

      interfaces = lib.mkForce {};
      networkmanager.enable = lib.mkForce (!ifstateMode);
      useDHCP = lib.mkForce false;
      useNetworkd = lib.mkForce false;
    };

    systemd = {
      network.enable = lib.mkForce false;
      # the unit exists only in an IfState mode
      services = lib.mkIf ifstateMode {
        ifstate.serviceConfig = {
          KillMode = "process";
          ExecStartPost = lib.mkIf (physicalNames != []) [physicalCheck];
        };
      };
    };
  };
}
