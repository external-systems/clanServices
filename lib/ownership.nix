# Ownership registry (specs/netif.md N6, N7, N11). Every kernel object
# on a machine has one owner: netif's renderer or one registry owner.
# Owners render into IfState `parameters.ignore` so a reapply never
# deletes or downs them. Presets switch on from the NixOS option that
# enables their daemon. Imported by the shared IfState base.
{
  config,
  lib,
  ...
}: let
  inherit (lib) types mkOption;
  cidr = import ./kube-cluster/cidr.nix {inherit lib;};
  cfg = config.clanServices.networking;
  ifstate = config.networking.ifstate.settings;

  owners = lib.filterAttrs (_: owner: owner.enable) cfg.owners;
  ownerList = lib.mapAttrsToList (name: owner: owner // {inherit name;}) owners;

  # IfState matches with Python re.match: anchored at the start only.
  # Owner regexes are POSIX ERE so the same test runs at eval time.
  regexMatches = regex: name: builtins.match "(${regex}).*" name != null;

  # --- claims rendered by netif and the other IfState writers ---
  declaredInterfaces = builtins.attrNames (ifstate.interfaces or {});
  declaredNetns = builtins.attrNames (ifstate.namespaces or {});
  declaredRoutes = ifstate.routing.routes or [];
  declaredRules = ifstate.routing.rules or [];
  declaredTables = lib.unique (
    lib.concatMap (object: lib.optional ((object.table or null) != null) object.table) (declaredRoutes ++ declaredRules)
  );
  declaredPriorities = lib.unique (
    lib.concatMap (rule: lib.optional ((rule.priority or null) != null) rule.priority) declaredRules
  );

  conflicts =
    lib.concatMap (
      owner:
        map (name: "interface '${name}' matches owner '${owner.name}'") (
          builtins.filter (name: lib.any (regex: regexMatches regex name) owner.interfaces) declaredInterfaces
        )
        ++ map (name: "netns '${name}' matches owner '${owner.name}'") (
          builtins.filter (name: lib.any (regex: regexMatches regex name) owner.netns) declaredNetns
        )
        ++ map (table: "table ${toString table} is owned by '${owner.name}'") (
          lib.intersectLists owner.tables declaredTables
        )
        ++ map (priority: "rule priority ${toString priority} is owned by '${owner.name}'") (
          lib.intersectLists owner.rulePriorities declaredPriorities
        )
    )
    ownerList;

  ifstateMode = config.clanServices.networking.mode.manager == "ifstate";
  nmOwners = lib.concatMap (owner: owner.interfaces) (builtins.filter (owner: owner.name != "iwd") ownerList);
  isPrefix' = regex: lib.hasPrefix "^" regex && builtins.match "[A-Za-z0-9_.-]+" (lib.removePrefix "^" regex) != null;
  nmUnmanaged = builtins.filter isPrefix' nmOwners;
  nmUnmanageable = builtins.filter (regex: !(isPrefix' regex)) nmOwners;

  # Invariant 4 (N5): iwd owns every Wi-Fi link, in every mode.
  wifiInterfaces = builtins.filter (regexMatches "^wl") declaredInterfaces;

  # Daemons that create links, rules or namespaces IfState would remove,
  # with no preset yet (N6). Defining owners.<name> by hand accepts one.
  unownedDaemons = lib.filter (daemon: daemon.enabled && !(cfg.owners ? ${daemon.name})) [
    {
      name = "netbird";
      option = "services.netbird";
      enabled = (config.services.netbird.enable or false) || (config.services.netbird.clients or {}) != {};
    }
    {
      name = "cloudflare-warp";
      option = "services.cloudflare-warp.enable";
      enabled = config.services.cloudflare-warp.enable or false;
    }
    {
      name = "zerotierone";
      option = "services.zerotierone.enable";
      enabled = config.services.zerotierone.enable or false;
    }
    {
      name = "wireguard";
      option = "networking.wireguard.interfaces (scripted WireGuard; use wireguard-mesh or routed-fabric)";
      enabled = (config.networking.wireguard.interfaces or {}) != {};
    }
    {
      name = "wg-quick";
      option = "networking.wg-quick.interfaces (scripted WireGuard; use wireguard-mesh or routed-fabric)";
      enabled = (config.networking.wg-quick.interfaces or {}) != {};
    }
  ];

  # --- N11: Tailscale's CGNAT ranges against every declared range ---
  tailscaleRanges = [
    "100.64.0.0/10"
    "fd7a:115c:a1e0::/48"
  ];
  addressString = address:
    if builtins.isString address
    then address
    else address.address or null;
  isPrefix = value: builtins.isString value && builtins.match "[0-9a-fA-F:.]+/[0-9]+" value != null;
  notDefault = value: !(lib.hasSuffix "/0" value);
  facts = config.clan.networkFacts or {};
  clusterRanges = lib.concatMap (
    cluster:
      builtins.filter (value: value != null) [
        (cluster.podCIDRv4 or null)
        (cluster.podCIDRv6 or null)
        (cluster.serviceCIDRv4 or null)
        (cluster.serviceCIDRv6 or null)
      ]
  ) (builtins.attrValues (facts.clusters or {}));
  poolRanges = lib.concatMap (map (pool: pool.cidr)) (builtins.attrValues (facts.allocationPools or {}));
  declaredRanges =
    lib.concatMap (interface: map addressString (interface.addresses or [])) (builtins.attrValues (ifstate.interfaces or {}))
    ++ map (route: route.to or null) declaredRoutes
    ++ clusterRanges
    ++ poolRanges;
  cgnatOverlaps = lib.unique (
    lib.concatMap (
      range: lib.concatMap (tailnet: lib.optional (cidr.overlap range tailnet) "${range} overlaps ${tailnet}") tailscaleRanges
    ) (builtins.filter (value: isPrefix value && notDefault value) declaredRanges)
  );
  # --- N22: Docker's and Podman's default address pools ---
  dockerOn = config.virtualisation.docker.enable or false;
  podmanOn = config.virtualisation.podman.enable or false;
  dockerBip = config.virtualisation.docker.daemon.settings.bip or null;
  containerRanges =
    lib.optional dockerOn (
      if dockerBip != null
      then dockerBip
      else "172.17.0.0/16"
    )
    ++ map (pool: pool.base) (lib.optionals dockerOn (config.virtualisation.docker.daemon.settings.default-address-pools or []))
    ++ lib.optionals podmanOn (
      map (network: network.subnet) (
        config.virtualisation.podman.defaultNetwork.settings.subnets or [{subnet = "10.88.0.0/16";}]
      )
    );
  containerOverlaps = lib.unique (
    lib.concatMap (
      range: lib.concatMap (pool: lib.optional (cidr.overlap range pool) "${range} overlaps ${pool}") containerRanges
    ) (builtins.filter (value: isPrefix value && notDefault value) declaredRanges)
  );
  # Docker forwards IPv6 only when its daemon is configured for it.
  dockerIpv6 = dockerOn && (config.virtualisation.docker.daemon.settings.ipv6 or false);
  tailscaleFlags = (config.services.tailscale.extraUpFlags or []) ++ (config.services.tailscale.extraSetFlags or []);
  acceptsRoutes = lib.any (flag: flag == "--accept-routes" || flag == "--accept-routes=true") tailscaleFlags;
  fabricMember = (facts.fabric or {}) != {};

  owner = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this owner's claims are rendered.";
      };
      interfaces = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["^tailscale"];
        description = "Interface-name regexes (POSIX ERE, matched from the start). Routes on these links are the owner's too.";
      };
      netns = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Named network namespace regexes.";
      };
      tables = mkOption {
        type = types.listOf types.ints.unsigned;
        default = [];
        description = "Routing tables: their routes and the rules that look them up.";
      };
      rulePriorities = mkOption {
        type = types.listOf types.ints.unsigned;
        default = [];
        description = "Policy-rule priorities.";
      };
      routes = mkOption {
        type = types.listOf (types.attrsOf types.anything);
        default = [];
        description = "Extra IfState route-ignore selectors.";
      };
      rules = mkOption {
        type = types.listOf (types.attrsOf types.anything);
        default = [];
        description = "Extra IfState rule-ignore selectors.";
      };
      sessionUnits = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["tailscaled.service"];
        description = "Units holding long-lived network sessions; they wait for network-online.target (N7).";
      };
    };
  };
in {
  key = "clanServices:lib/ownership.nix";

  imports = [
    ./kube-cluster/network-facts.nix
    ./modes.nix
  ];

  options.clanServices.networking.owners = mkOption {
    type = types.attrsOf owner;
    default = {};
    description = "Ownership registry (specs/netif.md N6): objects on this machine that belong to a daemon other than netif's renderer.";
  };

  config = {
    clanServices.networking.owners = {
      iwd = {
        enable = lib.mkDefault config.networking.wireless.iwd.enable;
        interfaces = ["^wl"];
      };
      tailscale = {
        enable = lib.mkDefault config.services.tailscale.enable;
        interfaces = ["^tailscale"];
        tables = [52];
        rulePriorities = [
          5210
          5230
          5250
          5270
        ];
        sessionUnits = ["tailscaled.service"];
      };
      cilium = {
        enable = lib.mkDefault ((config.services.k3s.enable or false) || (config.services.rke2.enable or false));
        interfaces = [
          "^cilium"
          "^lxc"
        ];
        tables = [200];
      };
      # Docker and rootful Podman (N22). Everything is named, so netif
      # does not depend on IfState's built-in list. Podman puts each
      # container in a named namespace, which IfState would delete.
      containers = {
        enable = lib.mkDefault (dockerOn || podmanOn);
        interfaces = [
          "^docker"
          "^br-"
          "^podman"
          "^veth"
        ];
        netns = ["^netns-"];
      };
      vm = {
        enable = lib.mkDefault ((config.virtualisation.libvirtd.enable or false) || (config.virtualisation.incus.enable or false));
        interfaces = [
          "^tap"
          "^vnet"
        ];
      };
    };

    assertions = [
      {
        assertion = conflicts == [];
        message = "clanServices: IfState declares objects the ownership registry gives to another owner (specs/netif.md N6): ${lib.concatStringsSep "; " conflicts}";
      }
      {
        assertion = ifstateMode || nmUnmanageable == [];
        message = "clanServices: mode '${config.clanServices.networking.mode.name}' uses NetworkManager, which takes interface-name globs, not regexes. These owner patterns are not a plain '^prefix': ${lib.concatStringsSep ", " nmUnmanageable}. Write them as '^prefix' (specs/netif.md N2, N6)";
      }
      {
        assertion = wifiInterfaces == [];
        message = "clanServices: Wi-Fi links belong to iwd, never IfState (specs/netif.md N5): ${lib.concatStringsSep ", " wifiInterfaces}";
      }
      {
        assertion = unownedDaemons == [];
        message = "clanServices: ${lib.concatMapStringsSep "; " (daemon: "${daemon.name} (${daemon.option})") unownedDaemons} has no ownership-registry preset; IfState would remove its objects. Declare clanServices.networking.owners.<name> for it (specs/netif.md N6)";
      }
      {
        assertion = !(owners ? containers) || containerOverlaps == [];
        message = "clanServices: a declared range overlaps a container address pool (specs/netif.md N22): ${lib.concatStringsSep "; " containerOverlaps}. Move the pool ('virtualisation.docker.daemon.settings.bip', 'virtualisation.podman.defaultNetwork.settings.subnets') or the declared range";
      }
      {
        assertion = !(owners ? tailscale) || cgnatOverlaps == [];
        message = "clanServices: Tailscale's ranges overlap declared ranges (specs/netif.md N11): ${lib.concatStringsSep "; " cgnatOverlaps}";
      }
    ];

    # Docker turns IPv6 forwarding on when its daemon does IPv6; RA
    # handling depends on it (accept_ra 2 on a forwarding machine).
    clan._networkFacts.forwarding = lib.mkIf dockerIpv6 true;

    warnings = lib.optional (owners ? tailscale && acceptsRoutes && fabricMember) "clanServices: this fabric member accepts Tailscale subnet routes; Tailscale's rule 5270 sits before main, so an accepted route wins over a fabric route for the same prefix (specs/netif.md N11)";

    # In a NetworkManager mode the same owners are marked unmanaged (N2).
    # iwd is the exception: NetworkManager drives it as its Wi-Fi backend.
    networking.networkmanager.unmanaged = lib.mkIf (!ifstateMode) (
      map (regex: "interface-name:${lib.removePrefix "^" regex}*") nmUnmanaged
    );

    networking.ifstate.settings.parameters.ignore = {
      ifname = lib.concatMap (owner: owner.interfaces) ownerList;
      netns = lib.concatMap (owner: owner.netns) ownerList;
      routes =
        lib.concatMap (
          owner:
            map (regex: {dev = regex;}) owner.interfaces
            ++ map (table: {inherit table;}) owner.tables
            ++ owner.routes
        )
        ownerList;
      rules =
        lib.concatMap (
          owner:
            map (table: {inherit table;}) owner.tables
            ++ map (priority: {inherit priority;}) owner.rulePriorities
            ++ owner.rules
        )
        ownerList;
    };

    systemd.services = lib.mkMerge (
      [
        (lib.mkIf ifstateMode {
          # N7: an IfState mode is online once IfState has converged.
          ifstate = {
            before = ["network-online.target"];
            wantedBy = ["network-online.target"];
          };
        })
      ]
      ++ map (
        unit: {
          ${lib.removeSuffix ".service" unit} = {
            after = ["network-online.target"];
            wants = ["network-online.target"];
          };
        }
      ) (lib.concatMap (owner: owner.sessionUnits) ownerList)
    );
  };
}
