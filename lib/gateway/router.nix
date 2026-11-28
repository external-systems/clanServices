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
#
# Ownership by link (specs/gateway.md G25): the router's table judges a
# packet only when it enters or leaves through a router link (the WAN
# or a zone's link). Every other link of the machine (a fabric's
# WireGuard links, Cilium's links, a VPN) is "unzoned": the machine's
# own firewall (the NixOS one, which other services fill) judges it, so
# a router can also be a Kubernetes node. The NixOS firewall stays on;
# on a router link a packet must pass both.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.clanServices.gateway.router;
  c = import ../kube-cluster/cidr.nix {inherit lib;};
  quoted = names: "{ ${lib.concatMapStringsSep ", " (n: ''"${n}"'') names} }";
  lanZones = lib.filterAttrs (_: zone: zone.interfaces != []) cfg.zones;
  lanLinks = lib.concatMap (zone: zone.interfaces) (builtins.attrValues lanZones);
  zonesOf = names: lib.concatMap (name: cfg.zones.${name}.interfaces) names;
  wan = quoted [cfg.wan];
  lans = quoted lanLinks;
  # the links the router judges
  mine = quoted ([cfg.wan] ++ lanLinks);
  ports = list: "{ ${lib.concatMapStringsSep ", " toString list} }";
  # What the machine opens to everyone (other services' declarations):
  # a zone with `hostPorts` may reach it; the WAN never does.
  fw = config.networking.firewall;
  ranges = map (range: "${toString range.from}-${toString range.to}");
  hostTcp = map toString fw.allowedTCPPorts ++ ranges fw.allowedTCPPortRanges;
  hostUdp = map toString fw.allowedUDPPorts ++ ranges fw.allowedUDPPortRanges;
  hostPortLinks = lib.concatMap (zone: zone.interfaces) (lib.filter (zone: zone.hostPorts) (builtins.attrValues lanZones));
  hostPortRules = lib.optionalString (hostPortLinks != []) (
    lib.optionalString (hostTcp != []) ''
      iifname ${quoted hostPortLinks} tcp dport { ${lib.concatStringsSep ", " hostTcp} } accept comment "host ports"
    ''
    + lib.optionalString (hostUdp != []) ''
      iifname ${quoted hostPortLinks} udp dport { ${lib.concatStringsSep ", " hostUdp} } accept comment "host ports"
    ''
  );
  wanPortRules =
    lib.optionalString (cfg.wanPorts.tcp != []) ''
      iifname ${wan} tcp dport ${ports cfg.wanPorts.tcp} accept comment "WAN port"
    ''
    + lib.optionalString (cfg.wanPorts.udp != []) ''
      iifname ${wan} udp dport ${ports cfg.wanPorts.udp} accept comment "WAN port"
    '';
  # Flows between a zone and the unzoned side (specs/gateway.md G25,
  # `router-kube`).
  # - A flow from the zone is masqueraded behind the router's address
  #   on the unzoned link: a fabric's WireGuard accepts cluster sources
  #   only, and the answer then returns through this machine's stack.
  # - The accept for packets from the zone is stateless and ahead of the
  #   connection tracking rules: Cilium sends a local pod's own packets
  #   straight out of the zone's link, past netfilter, so for a flow a
  #   pod opened conntrack sees the answers only and calls them invalid.
  unzonedLinks = quoted (zonesOf cfg.unzoned.zones);
  unzonedIn = lib.optionalString (cfg.unzoned.zones != []) ''
    iifname ${unzonedLinks} oifname != ${mine} accept comment "zone to unzoned: ${lib.concatStringsSep ", " cfg.unzoned.zones}"
  '';
  # The source a zone's flow gets on the unzoned side: the address the
  # owner names (a node's fabric address), else the outgoing link's.
  unzonedNat = lib.optionalString (cfg.unzoned.zones != []) (lib.concatMapStrings (family: let
    address = cfg.unzoned.source.${family};
    proto =
      if family == "ipv4"
      then "ip"
      else "ip6";
  in ''
    iifname ${unzonedLinks} oifname != ${mine} meta nfproto ${family} ${
      if address == null
      then "masquerade"
      else "snat ${proto} to ${address}"
    } comment "zone to unzoned"
  '') ["ipv4" "ipv6"]);
  unzonedRules =
    ''
      iifname != ${mine} oifname ${wan} accept comment "unzoned: internet"
    ''
    + lib.optionalString (cfg.unzoned.zones != []) ''
      iifname != ${mine} oifname ${unzonedLinks} accept comment "unzoned to zone: ${lib.concatStringsSep ", " cfg.unzoned.zones}"
    '';
  # zones with a delegated /64: the hook advertises them
  advertised = lib.filterAttrs (_: zone: zone.subnet != null) lanZones;

  # specs/gateway.md §17 (G14): a packet from the WAN never has a source
  # that is the router's own (a zone's static prefixes, the stable
  # service /64; the delegated prefix is the hook's), a loopback or a
  # multicast address. The machine-wide reverse path filter is off (the
  # hook's tables answer a wrong LAN source with an error), so this is
  # the WAN's own check.
  ownPrefixes = family:
    lib.sort builtins.lessThan (lib.filter (prefix: lib.hasInfix ":" prefix == (family == "ipv6")) (
      lib.concatMap (zone: zone.prefixes) (builtins.attrValues lanZones)
      ++ lib.optional (cfg.servicePrefix.stable != null) cfg.servicePrefix.stable
    ));
  spoofed = {
    ipv4 = ["127.0.0.0/8" "224.0.0.0/4" "240.0.0.0/4"] ++ ownPrefixes "ipv4";
    ipv6 = ["::1" "ff00::/8"] ++ ownPrefixes "ipv6";
  };

  # G13: a zone's DHCPv4 subnet id comes from its name, so a new zone
  # renumbers no other zone's leases
  subnetId = name: lib.fromHexString (builtins.substring 0 7 (builtins.hashString "sha256" name)) + 1;

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
  outsideStable = map (entry: entry.address) (lib.filter (entry: let
    inside = builtins.tryEval (c.contains cfg.servicePrefix.stable "${entry.address}/128");
  in
    cfg.servicePrefix.stable == null || !(inside.success && inside.value))
  cfg.servicePrefix.expose);
  # G10: no address, no resolver
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
          prefixes = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "The networks of the zone link's static addresses, IPv4 and IPv6. The WAN never brings a source inside them.";
          };
          hostPorts = mkOption {
            type = types.bool;
            default = false;
            description = "The zone may reach the ports the machine opens to everyone (`networking.firewall.allowedTCPPorts` and the like): what other services on the machine declared.";
          };
          fabric = mkOption {
            type = types.bool;
            default = false;
            description = "The zone's links are declared inside a fabric (`clan.networkFacts.fabricInside`, SPEC.md D73): its hosts may reach fabric addresses through this machine.";
          };
        };
      });
    };
    wanPorts = {
      tcp = mkOption {
        type = types.listOf types.port;
        default = [];
        description = "TCP ports of the router itself that the WAN may reach. Empty: none (invariant 3).";
      };
      udp = mkOption {
        type = types.listOf types.port;
        default = [];
        description = "UDP ports of the router itself that the WAN may reach.";
      };
    };
    unzoned = {
      zones = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Zones that exchange flows with the unzoned links (a cluster's pods and services), in both directions.";
      };
      source = {
        ipv4 = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The IPv4 source a zone's flow gets on the unzoned side; null: the outgoing link's address.";
        };
        ipv6 = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The IPv6 source a zone's flow gets on the unzoned side; null: the outgoing link's address.";
        };
      };
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
          assertion = lib.all (other: cfg.zones ? ${other}) cfg.unzoned.zones;
          message = "router: 'unzoned.zones' names unknown zones (${toString cfg.unzoned.zones})";
        }
        {
          # G25: on a router link a packet must pass both firewalls; a
          # disabled NixOS firewall would also void every other
          # service's rules on the machine
          assertion = config.networking.firewall.enable;
          message = "router: networking.firewall.enable must stay true: the router's table judges its own links only, the NixOS firewall judges the rest of the machine (specs/gateway.md G25)";
        }
        {
          assertion = (cfg.servicePrefix.subnet == null) == (cfg.servicePrefix.stable == null);
          message = "router: servicePrefix needs both 'subnet' and 'stable', or neither (specs/gateway.md G20)";
        }
        {
          # specs/gateway.md §17 (G14): a pinhole is into the stable /64
          assertion = outsideStable == [];
          message = "router: servicePrefix.expose address(es) ${toString outsideStable} are not inside servicePrefix.stable (${toString cfg.servicePrefix.stable}); the WAN reaches the service /64 only (specs/gateway.md G20)";
        }
        {
          assertion = lib.length (lib.unique (map subnetId (builtins.attrNames dhcpZones))) == lib.length (builtins.attrNames dhcpZones);
          message = "router: two zones' names give the same DHCPv4 subnet id; rename one (specs/gateway.md §17, G13)";
        }
      ];

    clan._networkFacts = {
      forwarding = true;
      # D73 (specs/gateway.md H3): a zone reaches a fabric's addresses
      # through this machine only when the owner says so; routed-fabric's
      # guard reads the fact
      fabricInside = zonesOf (builtins.attrNames (lib.filterAttrs (_: zone: zone.fabric) lanZones));
    };
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
      # The router's own table is the firewall of its links: default
      # deny between zones, nothing inbound from the WAN (invariants 2,
      # 3). The NixOS firewall stays on for the rest of the machine
      # (G25); here it gets what the router's table accepts on a router
      # link, because a packet must pass both.
      firewall = {
        # a WAN is scanned all day
        logRefusedConnections = lib.mkDefault false;
        # The prefix hook's tables answer a wrong source with an error
        # at once (G22); a reverse path filter would drop it in silence.
        checkReversePath = lib.mkDefault false;
        extraReversePathFilterRules = "iifname ${lans} accept";
        interfaces = lib.genAttrs lanLinks (link: let
          zone = lib.findFirst (zone: lib.elem link zone.interfaces) null (builtins.attrValues lanZones);
          dns = zone.dns.ipv4 != null || zone.dns.ipv6 != null;
        in {
          allowedTCPPorts = lib.optional dns 53;
          allowedUDPPorts = lib.optional dns 53 ++ lib.optional (zone.dhcp4 != null) 67;
        });
        # only rendered when another service filters forwarding there
        extraForwardRules = ''
          iifname ${mine} accept
          oifname ${mine} accept
        '';
      };
      nftables = {
        enable = true;
        tables.router = {
          family = "inet";
          content = ''
            chain postrouting {
              type nat hook postrouting priority srcnat;
              oifname ${wan} meta nfproto ipv4 masquerade
              ${unzonedNat}
            }
            chain wan {
              type filter hook prerouting priority raw;
              iifname ${wan} ip saddr { ${lib.concatStringsSep ", " spoofed.ipv4} } counter drop comment "WAN spoofed source"
              iifname ${wan} ip6 saddr { ${lib.concatStringsSep ", " spoofed.ipv6} } counter drop comment "WAN spoofed source"
            }
            chain input {
              type filter hook input priority filter; policy drop;
              iifname != ${mine} accept comment "not a router link: the machine's firewall decides"
              ct state established,related accept
              meta l4proto { icmp, ipv6-icmp } accept
              iifname ${wan} udp dport { 68, 546 } accept
              ${wanPortRules}
              ${hostPortRules}
              ${lib.optionalString (dhcpZones != {}) "iifname ${quoted (zonesOf (builtins.attrNames dhcpZones))} udp dport 67 accept"}
              ${dnsRules}
              ${lib.optionalString (lib.any (zone: zone.ssh) (builtins.attrValues lanZones)) ''iifname ${quoted (lib.concatMap (zone: zone.interfaces) (lib.filter (zone: zone.ssh) (builtins.attrValues lanZones)))} tcp dport 22 accept comment "ssh"''}
              counter comment "input dropped"
            }
            chain forward {
              type filter hook forward priority filter; policy drop;
              iifname != ${mine} oifname != ${mine} accept comment "no router link: not the router's"
              ${unzonedIn}
              ct state established,related accept
              ct state invalid counter drop comment "forward invalid"
              ${zoneRules}
              ${unzonedRules}
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
          subnet4 = map (name: let
            zone = dhcpZones.${name};
          in {
            id = subnetId name;
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
      coredns = lib.mkIf (binds != []) {
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
        coredns = lib.mkIf (binds != []) {after = ["ifstate.service"];};
        # G14: the hook's tables go when the hook goes (a removed router,
        # or no zone with a delegated /64). Not restarted on a change:
        # its stop would drop the live tables until the next change of
        # the delegation.
        router-prefix-tables = lib.mkIf (advertised != {}) {
          description = "Router prefix hook tables: removed when the hook is (specs/gateway.md §17)";
          wantedBy = ["multi-user.target"];
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
            # `-`: a table that is not there is no failure
            ExecStop = [
              "-${lib.getExe pkgs.nftables} delete table inet router_svc"
              "-${lib.getExe pkgs.nftables} delete table netdev router_src"
            ];
          };
        };
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
          # after IfState: the hook's netdev chain names the LAN links
          after = [
            "nftables.service"
            "systemd-tmpfiles-setup.service"
            "ifstate.service"
          ];
          path = [
            pkgs.nftables
            config.systemd.package
          ];
          # every change of the file must get its run
          unitConfig.StartLimitIntervalSec = 0;
          # G7: a run that failed (a LAN link not there yet) is tried
          # again; each table loads on its own
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${hook} ${hookConfig}";
            Restart = "on-failure";
            RestartSec = 10;
          };
        };
      };
    };
  };
}
