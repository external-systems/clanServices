# The per-machine half of netif (specs/netif.md N9, N16, N31–N33): what
# runs beside IfState on a machine. netif's perMachine module fills
# `clanServices.netif.links` from every instance; this module renders
#
# - one supervised dhcpcd unit per DHCP link, with its own config;
# - `netif-dns.service`, the one writer of per-link DNS into resolved;
# - `netif-online.service`, which defines "online" for DHCP links.
#
# IfState stays the only writer of links, static addresses and routes.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.clanServices.netif;

  inherit (cfg) links;
  dhcpLinks = lib.filterAttrs (_: l: l.dhcp4 || l.dhcp6) links;
  dnsLinks = lib.attrNames links;
  onlineLinks = lib.filterAttrs (_: l: l.requiredForOnline && (l.dhcp4 || l.dhcp6)) links;

  runtimeDir = "/run/netif-dns";
  # One file per delegating link: the delegated prefixes that the ISP
  # prefers, one per line, sorted (N16). Consumers watch it; it changes
  # only when that set does, and is absent while there is none.
  pdDir = "/run/netif/pd";
  path = lib.makeBinPath [
    pkgs.coreutils
    pkgs.systemd
    pkgs.iproute2
    pkgs.gnugrep
    pkgs.gnused
  ];

  deviceUnit = interface: "${utils.escapeSystemdPath "/sys/subsystem/net/devices/${interface}"}.device";
  dhcpcdUnit = interface: "netif-dhcpcd-${interface}";

  # A stable 28-bit identity association id per link (N33): it does not
  # change when the link's MAC address does.
  iaidOf = l: toString (lib.fromHexString (builtins.substring 0 7 (builtins.hashString "sha256" "${l.instance}/${l.logical}")));

  # The idempotent DNS writer (N9). For each link: static servers joined
  # with the lease files; set them in resolved when the link has carrier,
  # revert the link otherwise.
  dnsApply = pkgs.writeShellScript "netif-dns-apply" ''
    export PATH=${path}
    for l in ''${*:-${lib.escapeShellArgs dnsLinks}}; do
      [ -e "/sys/class/net/$l" ] || continue
      dns="$(cat "/etc/netif/dns/$l.dns" "${runtimeDir}/$l.dhcp4.dns" "${runtimeDir}/$l.dhcp6.dns" 2>/dev/null | tr '\n' ' ')"
      dom="$(cat "${runtimeDir}/$l.dhcp4.domain" "${runtimeDir}/$l.dhcp6.domain" 2>/dev/null | tr '\n' ' ')"
      if [ "$(cat "/sys/class/net/$l/carrier" 2>/dev/null)" = 1 ] && [ -n "''${dns// }" ]; then
        # shellcheck disable=SC2086
        resolvectl dns "$l" $dns || true
        if [ -n "''${dom// }" ]; then
          # shellcheck disable=SC2086
          resolvectl domain "$l" $dom || true
        fi
      else
        resolvectl revert "$l" 2>/dev/null || true
      fi
    done
    exit 0
  '';

  linkPattern = lib.concatMapStringsSep "|" (l: "*\" ${l}:\"*|*\" ${l}@\"*") dnsLinks;
  dnsWatch = pkgs.writeShellScript "netif-dns-watch" ''
    export PATH=${path}
    ${dnsApply}
    ip -o monitor link | while read -r line; do
      case "$line" in
        ${linkPattern}) ${dnsApply} ;;
      esac
    done
    # `ip monitor` ended: fail, so systemd restarts the watcher.
    exit 1
  '';

  # dhcpcd's `script` (N16). Setting it replaces dhcpcd-run-hooks, so no
  # stock hook runs. It hands the lease's DNS to the writer above.
  dhcpcdScript = pkgs.writeShellScript "netif-dhcpcd-exit" ''
    export PATH=${path}
    d=${runtimeDir}
    # shellcheck disable=SC2154,SC2086
    case "$reason" in
      BOUND|RENEW|REBIND|REBOOT|INFORM)
        printf '%s\n' $new_domain_name_servers > "$d/$interface.dhcp4.dns"
        printf '%s\n' $new_domain_name $new_domain_search > "$d/$interface.dhcp4.domain" ;;
      EXPIRE|NAK|RELEASE|STOP|NOCARRIER|STOPPED)
        rm -f "$d/$interface.dhcp4.dns" "$d/$interface.dhcp4.domain" ;;&
      BOUND6|RENEW6|REBIND6|REBOOT6|INFORM6)
        printf '%s\n' $new_dhcp6_name_servers > "$d/$interface.dhcp6.dns"
        printf '%s\n' $new_dhcp6_domain_search > "$d/$interface.dhcp6.domain" ;;
      EXPIRE6|RELEASE6|STOP6|NOCARRIER|STOPPED)
        rm -f "$d/$interface.dhcp6.dns" "$d/$interface.dhcp6.domain" ;;
    esac
    # The delegated prefixes as a runtime file (N16): the prefixes of the
    # last reply that the ISP still prefers, one per line, sorted. A
    # prefix with a preferred lifetime of 0 is on its way out (an ISP
    # that renumbers sends the old prefix that way beside the new one)
    # and is not listed. Written only when the content changes, by a
    # rename, so a path unit fires once per change. Removed when a reply
    # leaves no such prefix and when the lease expires. A stop or a
    # restart of dhcpcd leaves it: that is not a prefix change.
    # shellcheck disable=SC2154
    case "$reason" in
      BOUND6|RENEW6|REBIND6|REBOOT6)
        tmp="${pdDir}/.$interface.tmp"
        for name in $(env | sed -n 's/^\(new_dhcp6_ia_pd[0-9]*_prefix[0-9]*\)=.*/\1/p'); do
          eval "prefix=\$$name; length=\$''${name}_length; preferred=\$''${name}_pltime; valid=\$''${name}_vltime"
          if [ -n "$prefix" ] && [ -n "$length" ] && [ "$preferred" != 0 ] && [ "$valid" != 0 ]; then
            echo "$prefix/$length"
          fi
        done | LC_ALL=C sort -u > "$tmp"
        if [ ! -s "$tmp" ]; then
          rm -f "$tmp" "${pdDir}/$interface"
        elif [ "$(cat "$tmp")" != "$(cat "${pdDir}/$interface" 2>/dev/null)" ]; then
          mv "$tmp" "${pdDir}/$interface"
        else
          rm -f "$tmp"
        fi ;;
      EXPIRE6)
        rm -f "${pdDir}/$interface" ;;
    esac
    # shellcheck disable=SC2154
    ${dnsApply} "$interface"
  '';

  dhcpcdConf = interface: l: let
    iaid = iaidOf l;
    pd = l.prefixDelegation;
  in
    pkgs.writeText "netif-dhcpcd-${interface}.conf" (
      lib.concatLines (
        [
          "# netif/${l.instance} link '${l.logical}' (specs/netif.md N16)"
          "duid"
          "hostname"
          "option domain_name_servers, domain_name, domain_search, classless_static_routes"
          "option dhcp6_name_servers, dhcp6_domain_search"
          "require dhcp_server_identifier"
          # IfState owns router advertisements; dhcpcd never reads one.
          "noipv6rs"
          "noipv4ll"
          "metric ${toString cfg.routeMetric}"
          "backoff_cutoff ${toString cfg.dhcpBackoffCutoff}"
          "script ${dhcpcdScript}"
        ]
        # Keep the lease and its classless routes, drop the router (N21).
        ++ lib.optional (!l.default4) "nogateway"
        ++ lib.optional (!l.dhcp6) "ipv4only"
        ++ lib.optional (!l.dhcp4) "ipv6only"
        ++ [
          "interface ${interface}"
          "iaid ${iaid}"
        ]
        ++ lib.optional l.dhcp6 "ia_na ${iaid}"
        ++ lib.optional pd.enable (
          "ia_pd ${iaid}/::/${toString pd.hint}"
          + lib.concatMapStrings (a: " ${a.interface}/${toString a.subnet}/${toString a.length}") pd.assign
        )
      )
    );

  # dhcpcd sets addresses, routes and per-link sysctls and opens raw and
  # packet sockets. Nothing else.
  dhcpcdSandbox = {
    CapabilityBoundingSet = [
      "CAP_NET_ADMIN"
      "CAP_NET_RAW"
      "CAP_NET_BIND_SERVICE"
      "CAP_CHOWN"
    ];
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ReadWritePaths = [
      "/run/dhcpcd"
      "/var/lib/dhcpcd"
      runtimeDir
      pdDir
    ];
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
      "AF_NETLINK"
      "AF_PACKET"
    ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = ["@system-service"];
  };
  dhcpcdDirs = [
    "d ${runtimeDir} 0755 root root -"
    "d /run/netif 0755 root root -"
    "d ${pdDir} 0755 root root -"
    "d /run/dhcpcd 0755 root root -"
    "d /var/lib/dhcpcd 0755 root root -"
  ];

  # Hot-plugged wired links (N12): a dock or a USB adapter that is not
  # there when IfState runs. One config for all of them.
  inherit (cfg) hotplug;
  hotplugMetric = cfg.routeMetric + 100;
  hotplugConf = pkgs.writeText "netif-dhcpcd-hotplug.conf" (
    lib.concatLines [
      "# netif hot-plugged wired links (specs/netif.md N12)"
      "duid"
      "hostname"
      "option domain_name_servers, domain_name, domain_search, classless_static_routes"
      "require dhcp_server_identifier"
      # the kernel reads router advertisements on these links
      "noipv6rs"
      "noipv4ll"
      "ipv4only"
      "metric ${toString hotplugMetric}"
      "backoff_cutoff ${toString cfg.dhcpBackoffCutoff}"
      "script ${dhcpcdScript}"
    ]
  );
  hotplugPrefixes = map (lib.removePrefix "^") hotplug.interfaces;
  hotplugBadPatterns =
    builtins.filter (
      regex: !(lib.hasPrefix "^" regex && builtins.match "[A-Za-z0-9_.-]+" (lib.removePrefix "^" regex) != null)
    )
    hotplug.interfaces;
  hotplugUp = pkgs.writeShellScript "netif-hotplug-up" ''
    export PATH=${path}
    # an advertised IPv6 default sits where the DHCPv4 one does (N18)
    echo ${toString hotplugMetric} > "/proc/sys/net/ipv6/conf/$1/ra_defrtr_metric"
    # A hot-plug link takes router advertisements (N48): `default` has
    # them off, so turn on what a dock needs before the link is up. The
    # route-information, MTU and hop-limit keys stay as `default` set them.
    # A machine that forwards IPv6 only accepts advertisements with 2.
    if [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" = 1 ]; then
      echo 2 > "/proc/sys/net/ipv6/conf/$1/accept_ra"
    else
      echo 1 > "/proc/sys/net/ipv6/conf/$1/accept_ra"
    fi
    for key in autoconf accept_ra_pinfo accept_ra_defrtr; do
      echo 1 > "/proc/sys/net/ipv6/conf/$1/$key"
    done
    ip link set dev "$1" up
  '';
  hotplugCleanup = pkgs.writeShellScript "netif-hotplug-cleanup" ''
    export PATH=${path}
    ip -4 addr flush dev "$1" dynamic 2>/dev/null || true
    rm -f "${runtimeDir}/$1".dhcp4.* "${runtimeDir}/$1".dhcp6.*
    resolvectl revert "$1" 2>/dev/null || true
  '';

  # Guest ports (N23, N37). IfState's cleanup knows interface names
  # only, never a port's bridge. So before every apply netif lists the
  # ports of each guest-ports bridge, drops the members it declares
  # itself, and writes one regex naming the rest. IfState reads it
  # through an `!include` in `parameters.ignore.ifname`. After the apply
  # every listed port must still be on its bridge.
  guestPortsFile = "/run/netif/guest-ports.yaml";
  guestPortsList = "/run/netif/guest-ports.list";
  guestPortsBefore = pkgs.writeShellScript "netif-guest-ports" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnused
      ]
    }
    mkdir -p /run/netif
    : > ${guestPortsList}.new
    names=""
    ${lib.concatStrings (
      lib.mapAttrsToList (bridge: members: ''
        for p in /sys/class/net/${lib.escapeShellArg bridge}/brif/*; do
          [ -e "$p" ] || continue
          n=$(basename "$p")
          case " ${lib.concatStringsSep " " members} " in *" $n "*) continue ;; esac
          echo "$n ${bridge}" >> ${guestPortsList}.new
          names="$names|$(printf '%s' "$n" | sed 's/[.]/\\\\./g')"
        done
      '')
      cfg.guestBridges
    )}
    if [ -n "$names" ]; then
      printf '"^(%s)$"\n' "''${names#|}" > ${guestPortsFile}.new
    else
      # no guest port: a regex that matches no name
      printf '"^$"\n' > ${guestPortsFile}.new
    fi
    mv ${guestPortsFile}.new ${guestPortsFile}
    mv ${guestPortsList}.new ${guestPortsList}
  '';
  guestPortsAfter = pkgs.writeShellScript "netif-guest-ports-check" ''
    export PATH=${lib.makeBinPath [pkgs.coreutils]}
    lost=""
    while read -r port bridge; do
      [ -n "$port" ] || continue
      if [ "$(basename "$(readlink "/sys/class/net/$port/master" 2>/dev/null)" 2>/dev/null)" != "$bridge" ]; then
        lost="$lost $port($bridge)"
      fi
    done < ${guestPortsList}
    if [ -n "$lost" ]; then
      echo "netif: guest ports that were on a guest-ports bridge before the apply are gone or detached:$lost. If no guest stopped during the apply, IfState removed them: check 'bridge.guestPorts' and the ownership registry (specs/netif.md N37)" >&2
      exit 1
    fi
  '';

  # "Online" for DHCP links (N32): wait for an address of each family the
  # link asks for, then give up with a warning so a pulled cable never
  # blocks a boot.
  onlineChecks = lib.concatLists (
    lib.mapAttrsToList (
      interface: l:
        lib.optional l.dhcp4 "has -4 ${lib.escapeShellArg interface} || return 1"
        ++ lib.optional l.dhcp6 "has -6 ${lib.escapeShellArg interface} || return 1"
    )
    onlineLinks
  );
  onlineWait = pkgs.writeShellScript "netif-online-wait" ''
    export PATH=${path}
    has() { [ -n "$(ip -o "$1" addr show dev "$2" scope global 2>/dev/null)" ]; }
    ready() {
      ${lib.concatStringsSep "\n  " onlineChecks}
      return 0
    }
    deadline=$(( $(date +%s) + ${toString cfg.onlineTimeout} ))
    until ready; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "netif: no DHCP address on a required link after ${toString cfg.onlineTimeout}s; continuing (links: ${lib.concatStringsSep " " (lib.attrNames onlineLinks)})" >&2
        exit 0
      fi
      sleep 0.5
    done
  '';
in {
  options.clanServices.networking.links = mkOption {
    readOnly = true;
    description = ''
      Every netif link of this machine by instance and logical name,
      with its resolved interface name, its zone label and its kind
      (specs/netif.md N10). Read-only: modules reference a link here
      and never the inventory.
    '';
    type = types.attrsOf (
      types.attrsOf (
        types.submodule {
          options = {
            interface = mkOption {type = types.str;};
            zone = mkOption {type = types.nullOr types.str;};
            kind = mkOption {type = types.str;};
          };
        }
      )
    );
  };

  options.clanServices.netif = {
    guardGeneration = mkOption {
      internal = true;
      type = types.str;
      default = "";
      description = "What the guard judges as one unit: the IfState configuration and the dhcpcd configurations of this generation.";
    };
    dhcpcdConfs = mkOption {
      internal = true;
      type = types.nullOr types.path;
      default = null;
      description = "A directory of this generation's dhcpcd configurations, one per DHCP link. The guard keeps the last one that passed (specs/netif.md N25).";
    };
    links = mkOption {
      default = {};
      description = "Every netif link of this machine, keyed by interface name, with its resolved facts (addresses, zone, DHCP modes, the delegation's assignments). Set by netif's perMachine module. Other services on the machine read it and never set it: the `router` service takes each zone's addresses and subnet id from here (specs/netif.md N10, specs/gateway.md §16.3).";
      type = types.attrsOf (
        types.submodule {
          options = {
            instance = mkOption {type = types.str;};
            logical = mkOption {type = types.str;};
            dhcp4 = mkOption {type = types.bool;};
            dhcp6 = mkOption {type = types.bool;};
            nameservers = mkOption {type = types.listOf types.str;};
            requiredForOnline = mkOption {type = types.bool;};
            default4 = mkOption {type = types.bool;};
            kind = mkOption {type = types.str;};
            zone = mkOption {type = types.nullOr types.str;};
            trusted = mkOption {type = types.bool;};
            gateway4 = mkOption {type = types.nullOr types.str;};
            gateway6 = mkOption {type = types.nullOr types.str;};
            default6 = mkOption {type = types.bool;};
            ra = mkOption {type = types.bool;};
            mtu = mkOption {type = types.nullOr types.int;};
            addresses = mkOption {type = types.listOf types.str;};
            matchMac = mkOption {type = types.nullOr types.str;};
            routes = mkOption {type = types.listOf types.attrs;};
            prefixDelegation = {
              enable = mkOption {type = types.bool;};
              hint = mkOption {type = types.int;};
              assign = mkOption {
                type = types.listOf (
                  types.submodule {
                    options = {
                      interface = mkOption {type = types.str;};
                      subnet = mkOption {type = types.int;};
                      length = mkOption {type = types.int;};
                    };
                  }
                );
              };
            };
          };
        }
      );
    };
    zones = mkOption {
      readOnly = true;
      description = ''
        The seam for router and gateway modules (specs/netif.md N10):
        zone name to the interface names of the netif links that carry
        it, sorted. A module writes
        'config.clanServices.netif.zones.wan' and never an interface
        name.
      '';
      type = types.attrsOf (types.listOf types.str);
    };
    otherModeInterfaces = mkOption {
      internal = true;
      default = [];
      description = "Physical NICs that netif declares for other modes of this machine only. Set by netif's perMachine module.";
      type = types.listOf types.str;
    };
    guestBridges = mkOption {
      internal = true;
      default = {};
      description = "Guest-ports bridges of this machine: interface name to the member interfaces netif declares. Set by netif's perMachine module.";
      type = types.attrsOf (types.listOf types.str);
    };
    routeMetric = mkOption {
      type = types.ints.positive;
      default = 100;
      description = "Metric of every default route netif installs or lets dhcpcd install (specs/netif.md N18).";
    };
    dhcpBackoffCutoff = mkOption {
      type = types.ints.between 1 64;
      default = 16;
      description = "Longest wait in seconds between two DHCPv4 tries (dhcpcd 'backoff_cutoff', specs/netif.md N34).";
    };
    hotplug.interfaces = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [
        "^enx"
        "^enp0s20f0u"
      ];
      description = ''
        Name prefixes ('^prefix') of wired links that come and go, such
        as a USB-C dock. In an IfState mode IfState leaves them alone and
        netif runs a DHCP client on each while it is plugged in. Their
        default routes sit behind netif's own links and ahead of Wi-Fi
        (metric 'routeMetric' + 100). A NetworkManager mode needs
        nothing: NetworkManager does this itself (specs/netif.md N12).
      '';
    };
    onlineTimeout = mkOption {
      type = types.ints.positive;
      default = 30;
      description = ''
        Seconds 'network-online.target' waits for a DHCP address on the
        links that are required for online. After that the machine counts
        as online and logs a warning (specs/netif.md N32).
      '';
    };
  };

  config = lib.mkMerge [
    {
      clanServices = {
        netif.zones = lib.mapAttrs (_: lib.sort builtins.lessThan) (
          lib.groupBy' (acc: entry: acc ++ [entry.interface]) [] (entry: entry.zone) (
            lib.mapAttrsToList (interface: l: {
              inherit interface;
              inherit (l) zone;
            }) (lib.filterAttrs (_: l: l.zone != null) links)
          )
        );
        networking.links = lib.mapAttrs (_: lib.listToAttrs) (
          lib.groupBy' (acc: entry: acc ++ [entry.value]) [] (entry: entry.instance) (
            lib.mapAttrsToList (interface: l: {
              inherit (l) instance;
              value = lib.nameValuePair l.logical {
                inherit interface;
                inherit (l) zone kind;
              };
            })
            links
          )
        );
      };
    }
    # What follows runs beside IfState; a NetworkManager mode has its own
    # renderer (networkmanager.nix).
    (lib.mkIf (links != {} && config.clanServices.networking.mode.manager == "ifstate") {
      assertions = [
        {
          assertion = !(config.services.cloud-init.enable && config.services.cloud-init.network.enable);
          message = "netif: 'services.cloud-init.network.enable' would make cloud-init a second writer of the links netif owns; turn it off and match the NICs with 'match.path' or 'match.mac' (specs/netif.md N26)";
        }
        {
          assertion = dhcpLinks == {} || lib.versionAtLeast pkgs.dhcpcd_latest.version "10.5.0";
          message = "netif: DHCP links need dhcpcd 10.5.0 or newer as pkgs.dhcpcd_latest (got ${pkgs.dhcpcd_latest.version}); apply inputs.org-pkgs.overlays.ifstate (specs/netif.md N30)";
        }
      ];

      environment = {
        etc =
          lib.mapAttrs' (
            interface: l:
              lib.nameValuePair "netif/dns/${interface}.dns" {
                text = lib.concatLines l.nameservers;
              }
          )
          (lib.filterAttrs (_: l: l.nameservers != []) links)
          // lib.mapAttrs' (
            interface: l: lib.nameValuePair "netif/dhcpcd/${interface}.conf" {source = dhcpcdConf interface l;}
          )
          dhcpLinks;
        systemPackages = lib.optional (dhcpLinks != {}) pkgs.dhcpcd_latest;
      };
      clanServices.netif.dhcpcdConfs = lib.mkIf (dhcpLinks != {}) (
        pkgs.linkFarm "netif-dhcpcd-confs" (
          lib.mapAttrsToList (interface: _: {
            name = "${interface}.conf";
            path = config.environment.etc."netif/dhcpcd/${interface}.conf".source;
          })
          dhcpLinks
        )
      );

      boot.kernel.sysctl."net.ipv6.conf.default.ra_defrtr_metric" = cfg.routeMetric;

      # One included string in the ignore list: valid for the build-time
      # schema check, a regex at run time (N23).
      networking.ifstate.settings.parameters.ignore.ifname = lib.optional (cfg.guestBridges != {}) "!include ${guestPortsFile}";

      # Links are untrusted by default (N19), so netif opens what its own
      # DHCPv6 client needs: replies arrive on UDP 546. DHCPv4 needs no
      # port, dhcpcd reads it from a packet socket.
      networking.firewall.interfaces = lib.mapAttrs (_: _: {allowedUDPPorts = [546];}) (
        lib.filterAttrs (_: l: l.dhcp6) links
      );

      services.udev.extraRules = lib.concatMapStrings (interface: ''
        SUBSYSTEM=="net", ACTION=="add", NAME=="${interface}", ENV{SYSTEMD_WANTS}+="${dhcpcdUnit interface}.service"
      '') (lib.attrNames dhcpLinks);

      systemd = {
        tmpfiles.rules = dhcpcdDirs;

        services =
          {
            netif-dns = {
              description = "netif: per-link DNS in systemd-resolved";
              wantedBy = ["multi-user.target"];
              after = [
                "systemd-resolved.service"
                "ifstate.service"
              ];
              partOf = ["systemd-resolved.service"];
              serviceConfig = {
                ExecStart = dnsWatch;
                Restart = "always";
                RestartSec = 1;
              };
            };

            # RA defaults get netif's metric too (N18). IfState's schema has
            # no key for this sysctl, so it is written before each apply,
            # while a new link is still down; links IfState creates take the
            # 'default' value set below.
            ifstate.serviceConfig.ExecStartPre =
              [
                (pkgs.writeShellScript "netif-ra-metric" ''
                  for f in /proc/sys/net/ipv6/conf/*/ra_defrtr_metric; do${
                    lib.optionalString (hotplugPrefixes != []) ''

                      # a hot-plugged link keeps the metric its own unit wrote (N12)
                      n=''${f%/ra_defrtr_metric}
                      case "''${n##*/}" in
                        ${lib.concatMapStringsSep "|" (prefix: "${prefix}*") hotplugPrefixes}) continue ;;
                      esac''
                  }
                    [ -w "$f" ] && echo ${toString cfg.routeMetric} > "$f"
                  done
                  exit 0
                '')
              ]
              ++ lib.optional (cfg.guestBridges != {}) guestPortsBefore;

            ifstate.serviceConfig.ExecStartPost =
              lib.optional (cfg.guestBridges != {}) guestPortsAfter
              ++ [dnsApply]
              ++ lib.optional (dhcpLinks != {}) (
                # Only for a link that is there: a start job for an absent
                # one waits 90 s for its device and holds up every unit
                # ordered after the client (N31).
                pkgs.writeShellScript "netif-dhcpcd-start" ''
                  for interface in ${lib.escapeShellArgs (lib.attrNames dhcpLinks)}; do
                    if [ -e "/sys/class/net/$interface" ]; then
                      ${lib.getExe' pkgs.systemd "systemctl"} start --no-block "${dhcpcdUnit "$interface"}.service"
                    fi
                  done
                  exit 0
                ''
              );

            netif-online = lib.mkIf (onlineLinks != {}) {
              description = "netif: wait for DHCP addresses on the links required for online";
              wantedBy = ["network-online.target"];
              before = ["network-online.target"];
              after = ["ifstate.service"] ++ map (interface: "${dhcpcdUnit interface}.service") (lib.attrNames onlineLinks);
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = onlineWait;
              };
            };
          }
          // lib.mapAttrs' (
            interface: l:
              lib.nameValuePair (dhcpcdUnit interface) {
                description = "netif: dhcpcd on ${interface} (netif/${l.instance} link ${l.logical})";
                # Bound to the link: stopped when the link goes away. Started
                # by IfState after every apply, at boot too, when the link
                # is there, and by udev when the link appears later (a
                # dock). IfState has finished with the link before dhcpcd
                # touches it. Not wanted by multi-user.target: that start
                # job would wait 90 s for an absent NIC and hold up
                # network-online.target (N31).
                bindsTo = [(deviceUnit interface)];
                after = [
                  (deviceUnit interface)
                  "ifstate.service"
                  "systemd-tmpfiles-setup.service"
                  "systemd-resolved.service"
                ];
                wants = ["ifstate.service"];
                restartTriggers = [config.environment.etc."netif/dhcpcd/${interface}.conf".source];
                unitConfig.StartLimitIntervalSec = 0;
                serviceConfig =
                  {
                    # After a rollback of this generation the guard leaves
                    # the last configuration that passed in /run; it is
                    # used only while this same generation runs (N25).
                    ExecStart = pkgs.writeShellScript "netif-dhcpcd-${interface}" ''
                      conf=/etc/netif/dhcpcd/${interface}.conf
                      kept=/run/netif-guard/dhcpcd/${interface}.conf
                      if [ -e "$kept" ] && [ "$(${lib.getExe' pkgs.coreutils "cat"} /run/netif-guard/generation 2>/dev/null)" = ${lib.escapeShellArg config.clanServices.netif.guardGeneration} ]; then
                        conf=$kept
                      fi
                      exec ${lib.getExe pkgs.dhcpcd_latest} -B -f "$conf" ${interface}
                    '';
                    # A clean slate after every stop, crash or not: a dhcpcd
                    # that found its address already on the link does not
                    # remove it on exit. IPv4 only; IPv6 "dynamic" addresses
                    # include the kernel's own SLAAC ones.
                    ExecStopPost = pkgs.writeShellScript "netif-dhcpcd-cleanup" ''
                      export PATH=${path}
                      ip -4 addr flush dev ${lib.escapeShellArg interface} dynamic 2>/dev/null || true
                      rm -f ${runtimeDir}/${lib.escapeShellArg interface}.dhcp4.* ${runtimeDir}/${lib.escapeShellArg interface}.dhcp6.*
                      ${dnsApply} ${lib.escapeShellArg interface}
                    '';
                    Restart = "on-failure";
                    RestartSec = 2;
                  }
                  // dhcpcdSandbox;
              }
          )
          dhcpLinks;
      };
    })
    # Hot-plugged wired links (N12), IfState modes only.
    (lib.mkIf (hotplug.interfaces != [] && config.clanServices.networking.mode.manager == "ifstate") {
      assertions = [
        {
          assertion = hotplugBadPatterns == [];
          message = "netif: 'clanServices.netif.hotplug.interfaces' takes plain name prefixes such as '^enx' (udev matches them as 'enx*'); got ${lib.concatStringsSep ", " hotplugBadPatterns} (specs/netif.md N12)";
        }
        {
          assertion = lib.versionAtLeast pkgs.dhcpcd_latest.version "10.5.0";
          message = "netif: hot-plugged links need dhcpcd 10.5.0 or newer as pkgs.dhcpcd_latest (got ${pkgs.dhcpcd_latest.version}); apply inputs.org-pkgs.overlays.ifstate (specs/netif.md N30)";
        }
      ];

      # IfState never touches them: the links, their addresses and routes
      # are this owner's (N6). A declared link with such a name is an
      # eval error from the registry.
      clanServices.networking.owners.wired-hotplug.interfaces = hotplug.interfaces;

      environment.etc."netif/dhcpcd/hotplug.conf".source = hotplugConf;

      # udev starts the client when such a link appears, under the name
      # udev gave it or, with no rename, the kernel's.
      services.udev.extraRules =
        lib.concatMapStrings (prefix: ''
          SUBSYSTEM=="net", ACTION=="add", NAME=="${prefix}*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="netif-hotplug@$name.service"
          SUBSYSTEM=="net", ACTION=="add", NAME=="", KERNEL=="${prefix}*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="netif-hotplug@%k.service"
        '')
        hotplugPrefixes;

      systemd = {
        tmpfiles.rules = lib.mkIf (links == {}) dhcpcdDirs;
        services."netif-hotplug@" = {
          description = "netif: dhcpcd on the hot-plugged link %I";
          # Bound to the link: unplugging stops the client.
          bindsTo = ["sys-subsystem-net-devices-%i.device"];
          after = [
            "sys-subsystem-net-devices-%i.device"
            "ifstate.service"
            "systemd-tmpfiles-setup.service"
            "systemd-resolved.service"
          ];
          restartTriggers = [hotplugConf];
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig =
            {
              ExecStartPre = "${hotplugUp} %I";
              ExecStart = "${lib.getExe pkgs.dhcpcd_latest} -B -f /etc/netif/dhcpcd/hotplug.conf %I";
              ExecStopPost = "${hotplugCleanup} %I";
              Restart = "on-failure";
              RestartSec = 2;
            }
            // dhcpcdSandbox;
        };
      };
    })
  ];
}
