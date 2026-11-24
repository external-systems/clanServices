# The edge of a LAN (specs/gateway.md G8, G11, G12, G14, G15, G20, G22):
# zones with default deny between them, NAT44 to one WAN, DHCPv4 per
# zone (kea), router advertisements (corerad) from the delegated prefix,
# one resolver address per zone (CoreDNS), and the prefix hook that
# follows a change of the delegated prefix.
#
# Set by services/router. Every link, address and the delegation itself
# are netif's (invariant 1): the service resolves zone names into links
# and addresses and sets this module. One router per machine: the units,
# tables and runtime files have fixed names.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.clanServices.gateway.router;
  quoted = names: "{ ${lib.concatMapStringsSep ", " (n: ''"${n}"'') names} }";
  lanZones = lib.filterAttrs (_: zone: zone.interfaces != []) cfg.zones;
  lanLinks = lib.concatMap (zone: zone.interfaces) (builtins.attrValues lanZones);
  zonesOf = names: lib.concatMap (name: cfg.zones.${name}.interfaces) names;
  wan = quoted [cfg.wan];
  lans = quoted lanLinks;
  # zones with a delegated /64: the hook advertises them
  advertised = lib.filterAttrs (_: zone: zone.subnet != null) lanZones;

  hookConfig = pkgs.writeText "router-prefix.json" (builtins.toJSON {
    pd = "/run/netif/pd/${cfg.wan}";
    zones = lib.listToAttrs (lib.concatMap (zone:
      map (link: {
        name = link;
        value = {
          inherit (zone) subnet;
          dns = zone.dns.ipv6;
        };
      })
      zone.interfaces) (builtins.attrValues advertised));
    service = {
      inherit (cfg.servicePrefix) subnet stable;
    };
    inherit lans;
    inherit wan;
    inherit (cfg) domain pref64;
  });
  hook = pkgs.writers.writePython3 "router-prefix" {flakeIgnore = ["E501"];} (builtins.readFile ./router-prefix.py);

  expose =
    lib.concatMapStrings (entry: ''
      ip6 daddr ${entry.address} meta l4proto ${entry.protocol} th dport { ${lib.concatMapStringsSep ", " toString entry.ports} } accept comment "service pinhole"
    '')
    cfg.servicePrefix.expose;

  zoneRules = lib.concatStrings (lib.mapAttrsToList (name: zone: let
    links = quoted zone.interfaces;
  in
    lib.optionalString zone.internet ''
      iifname ${links} oifname ${wan} accept comment "zone ${name}: internet"
    ''
    + lib.optionalString (zone.allowTo != []) ''
      iifname ${links} oifname ${quoted (zonesOf zone.allowTo)} accept comment "zone ${name}: ${lib.concatStringsSep ", " zone.allowTo}"
    '')
  lanZones);

  dnsRules = lib.concatStrings (lib.mapAttrsToList (name: zone: let
    links = quoted zone.interfaces;
  in
    lib.optionalString (zone.dns.ipv4 != null) ''
      iifname ${links} ip daddr ${zone.dns.ipv4} meta l4proto { tcp, udp } th dport 53 accept comment "DNS, zone ${name}"
    ''
    + lib.optionalString (zone.dns.ipv6 != null) ''
      iifname ${links} ip6 daddr ${zone.dns.ipv6} meta l4proto { tcp, udp } th dport 53 accept comment "DNS, zone ${name}"
    '')
  lanZones);

  dhcpZones = lib.filterAttrs (_: zone: zone.dhcp4 != null) lanZones;
  binds = lib.concatMap (zone: lib.filter (address: address != null) [zone.dns.ipv4 zone.dns.ipv6]) (builtins.attrValues lanZones);
  corefile = lib.concatStringsSep "\n" (
    [
      ". {"
      "  bind ${lib.concatStringsSep " " binds}"
    ]
    ++ lib.optionals (cfg.dns.records != {}) (
      ["  hosts {"]
      ++ lib.mapAttrsToList (name: address: "    ${address} ${name}") cfg.dns.records
      ++ [
        "    fallthrough"
        "  }"
      ]
    )
    ++ lib.optionals (cfg.dns.blocklist != null) [
      "  hosts ${cfg.dns.blocklist} {"
      "    fallthrough"
      "  }"
    ]
    ++ [
      "  forward . ${lib.concatStringsSep " " cfg.dns.upstream}${lib.optionalString (cfg.dns.forwardOptions != []) " {"}"
    ]
    ++ map (line: "    ${line}") cfg.dns.forwardOptions
    ++ lib.optional (cfg.dns.forwardOptions != []) "  }"
    ++ [
      "  prometheus [::1]:9153"
      "  cache 30"
      "  errors"
      "}"
      ""
    ]
  );
in {
  options.clanServices.gateway.router = {
    enable = lib.mkEnableOption "the router of specs/gateway.md G8";
    wan = mkOption {
      type = types.str;
      description = "The WAN link (the netif link of the `wan` zone) that carries the delegation.";
    };
    zones = mkOption {
      description = "LAN zones, resolved to links and addresses.";
      type = types.attrsOf (types.submodule {
        options = {
          interfaces = mkOption {type = types.listOf types.str;};
          internet = mkOption {type = types.bool;};
          allowTo = mkOption {type = types.listOf types.str;};
          subnet = mkOption {
            type = types.nullOr types.int;
            description = "The subnet id of the delegated prefix on this zone (netif N16), null for none.";
          };
          dns = {
            ipv4 = mkOption {type = types.nullOr types.str;};
            ipv6 = mkOption {type = types.nullOr types.str;};
          };
          dhcp4 = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                subnet = mkOption {type = types.str;};
                router = mkOption {type = types.str;};
                pool = mkOption {type = types.str;};
              };
            });
          };
          ssh = mkOption {type = types.bool;};
        };
      });
    };
    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The DNS search domain advertised (DNSSL).";
    };
    pref64 = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "A NAT64 prefix advertised (PREF64). Part of IPv6-mostly (G9, frozen): off by default.";
    };
    dns = {
      upstream = mkOption {type = types.listOf types.str;};
      forwardOptions = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Lines of the `forward` block, such as `tls_servername`.";
      };
      blocklist = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "A hosts file of blocked names (G14).";
      };
      records = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Static records: name to address.";
      };
    };
    servicePrefix = {
      subnet = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
      stable = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      expose = mkOption {
        type = types.listOf (types.submodule {
          options = {
            address = mkOption {type = types.str;};
            protocol = mkOption {type = types.enum ["tcp" "udp"];};
            ports = mkOption {type = types.listOf types.port;};
          };
        });
        default = [];
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      lib.mapAttrsToList (name: zone: {
        assertion = lib.all (other: cfg.zones ? ${other}) zone.allowTo;
        message = "router: zone '${name}' may reach unknown zones (allowTo = ${toString zone.allowTo})";
      })
      cfg.zones
      ++ [
        {
          assertion = (cfg.servicePrefix.subnet == null) == (cfg.servicePrefix.stable == null);
          message = "router: servicePrefix needs both 'subnet' and 'stable', or neither (specs/gateway.md G20)";
        }
      ];

    clan._networkFacts.forwarding = true;
    boot.kernel.sysctl = {
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
      # CoreDNS binds each zone's address before DAD has finished
      "net.ipv6.ip_nonlocal_bind" = 1;
    };
    environment.systemPackages = [
      pkgs.conntrack-tools
      pkgs.dig
    ];

    networking = {
      # The router's own table is the firewall: default deny between
      # zones, nothing inbound from the WAN (invariants 2, 3).
      firewall.enable = false;
      nftables = {
        enable = true;
        tables.router = {
          family = "inet";
          content = ''
            chain postrouting {
              type nat hook postrouting priority srcnat;
              oifname ${wan} meta nfproto ipv4 masquerade
            }
            chain input {
              type filter hook input priority filter; policy drop;
              iifname "lo" accept
              ct state established,related accept
              meta l4proto { icmp, ipv6-icmp } accept
              iifname ${wan} udp dport { 68, 546 } accept
              ${lib.optionalString (dhcpZones != {}) "iifname ${quoted (zonesOf (builtins.attrNames dhcpZones))} udp dport 67 accept"}
              ${dnsRules}
              ${lib.optionalString (lib.any (zone: zone.ssh) (builtins.attrValues lanZones)) ''iifname ${quoted (lib.concatMap (zone: zone.interfaces) (lib.filter (zone: zone.ssh) (builtins.attrValues lanZones)))} tcp dport 22 accept comment "ssh"''}
              counter comment "input dropped"
            }
            chain forward {
              type filter hook forward priority filter; policy drop;
              ct state established,related accept
              ct state invalid drop
              ${zoneRules}
              ${expose}
              counter comment "forward dropped"
            }
          '';
        };
      };
    };

    services = {
      kea.dhcp4 = lib.mkIf (dhcpZones != {}) {
        enable = true;
        settings = {
          interfaces-config = {
            interfaces = lib.concatMap (zone: zone.interfaces) (builtins.attrValues dhcpZones);
            service-sockets-max-retries = 30;
            service-sockets-retry-wait-time = 1000;
          };
          lease-database = {
            type = "memfile";
            persist = true;
            name = "/var/lib/kea/dhcp4.leases";
          };
          subnet4 = lib.imap1 (id: name: let
            zone = dhcpZones.${name};
          in {
            inherit id;
            inherit (zone.dhcp4) subnet;
            interface = builtins.head zone.interfaces;
            pools = [{inherit (zone.dhcp4) pool;}];
            option-data =
              [
                {
                  name = "routers";
                  data = zone.dhcp4.router;
                }
              ]
              ++ lib.optional (zone.dns.ipv4 != null) {
                name = "domain-name-servers";
                data = zone.dns.ipv4;
              }
              ++ lib.optional (cfg.domain != null) {
                name = "domain-search";
                data = cfg.domain;
              };
          }) (builtins.attrNames dhcpZones);
        };
      };
      # G22: corerad's configuration is the hook's runtime file
      corerad = lib.mkIf (advertised != {}) {
        enable = true;
        configFile = "/run/router/corerad.toml";
      };
      # G14: one resolver address per zone, the blocklist, static records
      coredns = {
        enable = true;
        config = corefile;
      };
    };

    systemd = {
      tmpfiles.rules = [
        "d /run/router 0755 root root -"
        "d /var/lib/router 0755 root root -"
      ];
      paths.router-prefix = lib.mkIf (advertised != {}) {
        wantedBy = ["multi-user.target"];
        pathConfig.PathChanged = "/run/netif/pd/${cfg.wan}";
      };
      services = {
        coredns.after = ["ifstate.service"];
        corerad = lib.mkIf (advertised != {}) {
          after = [
            "ifstate.service"
            "router-prefix.service"
          ];
          wants = ["router-prefix.service"];
          # The hook restarts corerad once per change; with the default
          # limit the sixth restart within 10 s leaves it down.
          unitConfig.StartLimitIntervalSec = 0;
        };
        router-prefix = lib.mkIf (advertised != {}) {
          description = "Router prefix hook (specs/gateway.md G22)";
          wantedBy = ["multi-user.target"];
          after = [
            "nftables.service"
            "systemd-tmpfiles-setup.service"
          ];
          path = [
            pkgs.nftables
            config.systemd.package
          ];
          # every change of the file must get its run
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${hook} ${hookConfig}";
          };
        };
      };
    };
  };
}
