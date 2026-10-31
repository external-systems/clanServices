{ifstateOverlay}: {
  config,
  lib,
  ...
}: let
  ip = import ./ip.nix {inherit lib;};
  cidr = import ./kube-cluster/cidr.nix {inherit lib;};
  addressValue = address:
    ip.addressFromCIDR (
      if builtins.isString address
      then address
      else address.address
    );
  wireguardInterfaces = builtins.filter (
    interface: (interface.link.kind or null) == "wireguard" && (interface.wireguard.listen_port or null) != null
  ) (builtins.attrValues config.networking.ifstate.settings.interfaces);
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
  poolClaims = lib.concatMap (
    owner: map (pool: pool // {inherit owner;}) config.clan.networkFacts.allocationPools.${owner}
  ) (builtins.attrNames config.clan.networkFacts.allocationPools);
  crossPoolOverlaps =
    lib.concatMap (
      first:
        lib.concatMap (
          second:
            lib.optional (first.owner != second.owner && cidr.overlap first.cidr second.cidr)
            "${first.owner}/${first.name}=${first.cidr} overlaps ${second.owner}/${second.name}=${second.cidr}"
        )
        poolClaims
    )
    poolClaims;
in {
  key = "clanServices:lib/ifstate.nix";

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
        message = "clanServices networking is IfState-only; use per-link IfState DHCP hooks instead of networking.useDHCP";
      }
      {
        assertion = lib.versionAtLeast config.networking.ifstate.package.version "2.5";
        message = "clanServices requires IfState >= 2.5; apply inputs.pkgs.overlays.ifstate or provide an equivalent newer package";
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

    nixpkgs.overlays = lib.mkAfter [ifstateOverlay];

    boot.kernel.sysctl."net.ipv4.ip_local_reserved_ports" = lib.concatStringsSep "," (
      lib.unique (config.clanServices.networking.reservedPorts ++ map toString wireguardPorts)
    );

    networking = {
      ifstate = {
        enable = true;
        settings = {
          parameters.ignore = {
            ifname = [
              "^cilium"
              "^lxc"
              "^tap"
              "^vnet"
            ];
            routes = [
              {dev = "^cilium";}
              {dev = "^lxc";}
            ];
            rules = [{table = 200;}];
          };
        };
      };

      interfaces = lib.mkForce {};
      networkmanager.enable = lib.mkForce false;
      useDHCP = lib.mkForce false;
      useNetworkd = lib.mkForce false;
    };

    systemd = {
      network.enable = lib.mkForce false;
      services.ifstate.serviceConfig.KillMode = "process";
    };
  };
}
