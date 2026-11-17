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
  path = lib.makeBinPath [
    pkgs.coreutils
    pkgs.systemd
    pkgs.iproute2
    pkgs.gnugrep
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
    links = mkOption {
      internal = true;
      default = {};
      description = "Every netif link of this machine, keyed by interface name. Set by netif's perMachine module.";
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
    (lib.mkIf (links != {}) {
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

      boot.kernel.sysctl."net.ipv6.conf.default.ra_defrtr_metric" = cfg.routeMetric;

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
        tmpfiles.rules = [
          "d ${runtimeDir} 0755 root root -"
          "d /run/dhcpcd 0755 root root -"
          "d /var/lib/dhcpcd 0755 root root -"
        ];

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
            ifstate.serviceConfig.ExecStartPre = [
              (pkgs.writeShellScript "netif-ra-metric" ''
                for f in /proc/sys/net/ipv6/conf/*/ra_defrtr_metric; do
                  [ -w "$f" ] && echo ${toString cfg.routeMetric} > "$f"
                done
                exit 0
              '')
            ];

            ifstate.serviceConfig.ExecStartPost =
              [dnsApply]
              ++ lib.optional (dhcpLinks != {}) (
                pkgs.writeShellScript "netif-dhcpcd-start" ''
                  exec ${lib.getExe' pkgs.systemd "systemctl"} start --no-block ${
                    lib.escapeShellArgs (map (interface: "${dhcpcdUnit interface}.service") (lib.attrNames dhcpLinks))
                  }
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
                # at boot, by udev when the link appears later (a dock), and
                # by IfState after it created or renamed the link. IfState
                # has finished with the link before dhcpcd touches it.
                wantedBy = ["multi-user.target"];
                bindsTo = [(deviceUnit interface)];
                after = [
                  (deviceUnit interface)
                  "ifstate.service"
                  "systemd-tmpfiles-setup.service"
                  "systemd-resolved.service"
                ];
                wants = ["ifstate.service"];
                restartTriggers = [(dhcpcdConf interface l)];
                unitConfig.StartLimitIntervalSec = 0;
                serviceConfig = {
                  ExecStart = "${lib.getExe pkgs.dhcpcd_latest} -B -f /etc/netif/dhcpcd/${interface}.conf ${interface}";
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
                  # dhcpcd sets addresses, routes and per-link sysctls and
                  # opens raw and packet sockets. Nothing else.
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
              }
          )
          dhcpLinks;
      };
    })
  ];
}
