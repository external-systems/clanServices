# The gateway side of specs/gateway.md G2, G4, G6, G23 and G24: stateful
# NAT64 with Jool in a network namespace of its own, a source allowlist
# with a rate limit per source in a table of its own, a masquerade of
# Jool's private IPv4 to the uplink, a health check through the
# translator, and the health beacon (`ipv4only.arpa` only, no DNS64).
#
# Set by services/nat-gateway (role `gateway`). One translator per
# machine: the namespace, the veth pair and the table have fixed names,
# and the service asserts one gateway instance per machine.
#
# Why a namespace: in the host namespace Jool takes a packet in
# PREROUTING and emits the translated one in POSTROUTING; the forward
# chain never sees it (§10.1). Why a table of its own: the NixOS
# `forward-allow` chain accepts every ICMPv6 type before
# `extraForwardRules` (§13.1).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.clanServices.gateway.nat64;
  names = import ./names.nix;
  inherit (names.nat64) host inside netns table;
  c = import ../kube-cluster/cidr.nix {inherit lib;};
  ip = import ../ip.nix {inherit lib;};
  sandbox = import ./sandbox.nix;

  # IPv4 destinations the translator refuses (G5, `nat64-private`)
  private = ["0.0.0.0/8" "10.0.0.0/8" "100.64.0.0/10" "127.0.0.0/8" "169.254.0.0/16" "172.16.0.0/12" "192.0.0.0/24" "192.168.0.0/16" "198.18.0.0/15" "224.0.0.0/3"];
  # G9: a pool6 is a /96 with no host bits, outside the special ranges
  pool6Parts = lib.splitString "/" cfg.pool6;
  pool6Valid = let
    parsed = builtins.tryEval (
      lib.length pool6Parts
      == 2
      && ip.isIpv6 (builtins.head pool6Parts)
      && lib.last pool6Parts == "96"
      && (c.parse cfg.pool6).start == (c.parse "${builtins.head pool6Parts}/128").start
      && !(lib.any (special: c.overlap special cfg.pool6) ["::/8" "fe80::/10" "ff00::/8"])
    );
  in
    parsed.success && parsed.value;
  addressInPool6 = pool6Valid && ip.isIpv6 cfg.address && c.contains cfg.pool6 "${cfg.address}/128";
  privateTargets = builtins.filter (target: !(ip.isIpv4 target) || lib.any (range: c.contains range "${target}/32") private) cfg.health.targets;
  # G5: a meter holds one entry per /64
  per64 = "ip6 saddr & ffff:ffff:ffff:ffff::";

  limitType = types.submodule {
    options = {
      newFlows = mkOption {
        type = types.ints.positive;
        description = "New flows per second from one source /64, above the burst.";
      };
      newFlowsBurst = mkOption {
        type = types.ints.positive;
        description = "New flows one source /64 may open at once before the rate applies.";
      };
      packets = mkOption {
        type = types.ints.positive;
        description = "Packets per second from one source /64 towards the translator, above the burst.";
      };
      packetsBurst = mkOption {
        type = types.ints.positive;
        description = "Packets one source /64 may send at once before the rate applies.";
      };
    };
  };

  set = elements:
    if elements == []
    then ""
    else "elements = { ${lib.concatStringsSep ", " elements} }";

  # The health check and the beacon (G23, G24). Python: the /96
  # arithmetic is done on addresses, never on strings.
  healthScript = pkgs.writeText "nat64-health.py" (builtins.readFile ./nat64-health.py);
  healthConfig = pkgs.writeText "nat64-health.json" (builtins.toJSON {
    inherit (cfg) pool6;
    inherit (cfg.health) targets quorum down up resume;
    inherit netns;
    hosts = "/run/${names.nat64.runtime}/ipv4only.hosts";
    state = "/run/${names.nat64.runtime}/health.json";
    beacon = "${names.nat64.beacon}.service";
  });
  corefile = pkgs.writeText "nat64-beacon.Corefile" ''
    ipv4only.arpa:53 {
      bind ${cfg.address}
      hosts /run/${names.nat64.runtime}/ipv4only.hosts {
        ttl 30
        reload 1s
      }
      errors
    }
  '';
in {
  options.clanServices.gateway.nat64 = {
    enable = lib.mkEnableOption "the NAT64 gateway of specs/gateway.md G2";
    pool6 = mkOption {
      type = types.str;
      example = "2001:db8:a1:0:64::/96";
      description = "The gateway's own /96, inside a prefix routed to the machine (G4).";
    };
    address = mkOption {
      type = types.str;
      example = "2001:db8:a1::1";
      description = "An IPv6 address of the gateway that clients reach; the health beacon binds it (G24).";
    };
    uplinks = mkOption {
      type = types.listOf types.str;
      description = "The links that carry the public IPv4 (netif zone links). The masquerade leaves through them.";
    };
    allow = {
      default = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "IPv6 sources (addresses or prefixes) of the `default` tier.";
      };
      trusted = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "IPv6 sources of the `trusted` tier.";
      };
    };
    custom = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.strMatching "[A-Za-z0-9_-]+";
            description = "The client's name, in the rules' comments (`nat64-flows-client-<name>`).";
          };
          sources = mkOption {
            type = types.listOf types.str;
            description = "The client's IPv6 sources; they are in no tier.";
          };
          limits = mkOption {
            type = limitType;
            description = "The client's own rate limit per source.";
          };
        };
      });
      default = [];
      description = "Clients with a limit of their own (specs/gateway.md §14.5 point 3): allowed, with meters of their own, before the tiers.";
    };
    limits = {
      default = mkOption {
        type = limitType;
        description = "The rate limit of each `default` source.";
      };
      trusted = mkOption {
        type = limitType;
        description = "The rate limit of each `trusted` source.";
      };
    };
    health = {
      targets = mkOption {
        type = types.listOf types.str;
        description = "IPv4 addresses the gateway pings through its own translator, one round a second.";
      };
      quorum = mkOption {
        type = types.ints.positive;
        default = 2;
        description = "Targets that must answer for a round to be good (all of them when fewer are set).";
      };
      down = mkOption {
        type = types.ints.positive;
        default = 30;
        description = "The beacon is withdrawn when this many of the last 2 x `down` rounds are bad: a dead upstream after `down` rounds (specs/gateway.md §14.5 point 4).";
      };
      up = mkOption {
        type = types.ints.positive;
        default = 120;
        description = "A withdrawn or new beacon comes up when the last `up` rounds hold at most 5 % bad ones (specs/gateway.md §14.5 point 4).";
      };
      resume = mkOption {
        type = types.ints.positive;
        default = 60;
        description = "A restart of the health check alone resumes an `up` state written less than this many seconds before.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasSuffix "/96" cfg.pool6;
        message = "nat-gateway: pool6 '${cfg.pool6}' is not a /96 (specs/gateway.md G4)";
      }
      {
        # specs/gateway.md §17 (G9)
        assertion = pool6Valid;
        message = "nat-gateway: pool6 '${cfg.pool6}' is not a /96 network with its host bits zero outside ::/8, fe80::/10 and ff00::/8 (specs/gateway.md G4)";
      }
      {
        assertion = ip.isIpv6 cfg.address && !addressInPool6;
        message = "nat-gateway: the gateway's address '${cfg.address}' is not an IPv6 address outside its pool6 ${cfg.pool6}: inside its pool6 it is routed into the translator (specs/gateway.md G24)";
      }
      {
        assertion = privateTargets == [];
        message = "nat-gateway: health target(s) ${toString privateTargets} are not public IPv4 addresses: the translator refuses them (`nat64-private`), so the gateway would never be healthy (specs/gateway.md §14.3)";
      }
      {
        assertion = cfg.uplinks != [];
        message = "nat-gateway: the gateway has no uplink link; give the netif link that carries the public IPv4 the uplink zone";
      }
      {
        assertion = lib.length cfg.health.targets >= 3;
        message = "nat-gateway: a health check needs three or more targets in different networks (specs/gateway.md §14.3); got ${toString (lib.length cfg.health.targets)}";
      }
      {
        # specs/gateway.md §12.2 point 8: the kernel the machine runs
        assertion = !(config.boot.kernelPackages.jool.meta.broken or false);
        message = "nat-gateway: Jool is marked broken for kernel ${config.boot.kernelPackages.kernel.version}";
      }
    ];

    boot = {
      extraModulePackages = [config.boot.kernelPackages.jool];
      kernel.sysctl = {
        "net.ipv4.conf.all.forwarding" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
        # the beacon binds the gateway's address before DAD has finished
        "net.ipv6.ip_nonlocal_bind" = 1;
      };
    };
    # netif renders accept_ra 2 on a forwarding machine
    clan._networkFacts.forwarding = true;

    environment.systemPackages = [
      pkgs.jool-cli
      pkgs.conntrack-tools
    ];

    networking = {
      nftables.enable = true;
      firewall = {
        enable = true;
        filterForward = true;
        # The NixOS chains have a policy of drop, so they accept what
        # `inet nat64` let pass. They are not the allowlist.
        extraForwardRules = ''
          oifname "${host}" ip6 daddr ${cfg.pool6} accept
          iifname "${host}" oifname { ${lib.concatMapStringsSep ", " (link: ''"${link}"'') cfg.uplinks} } accept
        '';
        extraInputRules = ''
          ip6 daddr ${cfg.address} meta l4proto { tcp, udp } th dport 53 accept
        '';
      };
      nftables.tables.${table} = {
        family = "inet";
        content = ''
          set trusted {
            type ipv6_addr; flags interval; auto-merge;
            ${set cfg.allow.trusted}
          }
          set default {
            type ipv6_addr; flags interval; auto-merge;
            ${set cfg.allow.default}
          }
          set custom {
            type ipv6_addr; flags interval; auto-merge;
            ${set (lib.concatMap (client: client.sources) cfg.custom)}
          }
          # One entry per source /64 (specs/gateway.md §17, G5), forgotten
          # after a minute of quiet. The source sets above merge what
          # overlaps: a CLAT address inside a declared prefix loads (G6).
          set flows_trusted { type ipv6_addr; size 65535; flags dynamic,timeout; timeout 1m; }
          set flows_default { type ipv6_addr; size 65535; flags dynamic,timeout; timeout 1m; }
          set packets_trusted { type ipv6_addr; size 65535; flags dynamic,timeout; timeout 1m; }
          set packets_default { type ipv6_addr; size 65535; flags dynamic,timeout; timeout 1m; }
          ${lib.concatImapStrings (index: _: ''
              set flows_c${toString index} { type ipv6_addr; size 65535; flags dynamic,timeout; timeout 1m; }
              set packets_c${toString index} { type ipv6_addr; size 65535; flags dynamic,timeout; timeout 1m; }
            '')
            cfg.custom}

          chain forward {
            type filter hook forward priority -10; policy accept;
            # Every protocol: nothing reaches the translator from a source
            # that is not declared. An ICMPv6 error about an open flow is
            # `related`.
            oifname "${host}" ip6 saddr != @trusted ip6 saddr != @default ip6 saddr != @custom ct state != related counter drop comment "nat64-undeclared"
            # A meter holds one entry per live source /64. When it is
            # full the `update` fails and its rule does not match: the
            # rule after each meter drops a source that has no entry, so
            # a full meter refuses new sources instead of letting them
            # pass unlimited (specs/gateway.md §16.3).
            # specs/gateway.md §14.5 point 3: a client's own limit first
            ${lib.concatImapStrings (index: client: let
              sources = "{ ${lib.concatStringsSep ", " client.sources} }";
              c = "c${toString index}";
            in ''
              oifname "${host}" ip6 saddr ${sources} ct state new update @flows_${c} { ${per64} limit rate over ${toString client.limits.newFlows}/second burst ${toString client.limits.newFlowsBurst} packets } counter drop comment "nat64-flows-client-${client.name}"
              oifname "${host}" ip6 saddr ${sources} ct state new ${per64} != @flows_${c} counter drop comment "nat64-flows-client-${client.name}-full"
              oifname "${host}" ip6 saddr ${sources} update @packets_${c} { ${per64} limit rate over ${toString client.limits.packets}/second burst ${toString client.limits.packetsBurst} packets } counter drop comment "nat64-packets-client-${client.name}"
              oifname "${host}" ip6 saddr ${sources} ${per64} != @packets_${c} counter drop comment "nat64-packets-client-${client.name}-full"
            '')
            cfg.custom}
            # specs/gateway.md §14.1 point 4: a limit per source, two tiers
            oifname "${host}" ip6 saddr @trusted ct state new update @flows_trusted { ${per64} limit rate over ${toString cfg.limits.trusted.newFlows}/second burst ${toString cfg.limits.trusted.newFlowsBurst} packets } counter drop comment "nat64-flows-trusted"
            oifname "${host}" ip6 saddr @trusted ct state new ${per64} != @flows_trusted counter drop comment "nat64-flows-trusted-full"
            oifname "${host}" ip6 saddr @trusted update @packets_trusted { ${per64} limit rate over ${toString cfg.limits.trusted.packets}/second burst ${toString cfg.limits.trusted.packetsBurst} packets } counter drop comment "nat64-packets-trusted"
            oifname "${host}" ip6 saddr @trusted ${per64} != @packets_trusted counter drop comment "nat64-packets-trusted-full"
            oifname "${host}" ip6 saddr @default ct state new update @flows_default { ${per64} limit rate over ${toString cfg.limits.default.newFlows}/second burst ${toString cfg.limits.default.newFlowsBurst} packets } counter drop comment "nat64-flows-default"
            oifname "${host}" ip6 saddr @default ct state new ${per64} != @flows_default counter drop comment "nat64-flows-default-full"
            oifname "${host}" ip6 saddr @default update @packets_default { ${per64} limit rate over ${toString cfg.limits.default.packets}/second burst ${toString cfg.limits.default.packetsBurst} packets } counter drop comment "nat64-packets-default"
            oifname "${host}" ip6 saddr @default ${per64} != @packets_default counter drop comment "nat64-packets-default-full"
            # A /96 destination that embeds a non-global IPv4 address is
            # not the internet (G5): refused after translation.
            iifname "${host}" ip daddr { ${lib.concatStringsSep ", " private} } counter reject with icmp type net-prohibited comment "nat64-private"
          }
          chain input {
            type filter hook input priority -10; policy accept;
            # the health beacon answers declared clients only (G24)
            ip6 daddr ${cfg.address} meta l4proto { tcp, udp } th dport 53 ip6 saddr != @trusted ip6 saddr != @default ip6 saddr != @custom counter drop comment "beacon-undeclared"
            # A /96 destination that embeds one of the gateway's own IPv4
            # addresses (Jool's link or the public one) is delivered here,
            # not forwarded: the translator is no way into the gateway
            # itself. Nothing legitimate arrives as IPv4 on this link (the
            # health check's answers are IPv6).
            iifname "${host}" meta nfproto ipv4 counter reject with icmp type host-prohibited comment "nat64-host"
          }
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            iifname "${host}" oifname { ${lib.concatMapStringsSep ", " (link: ''"${link}"'') cfg.uplinks} } masquerade comment "nat64-masquerade"
          }
        '';
      };

      # G2: the namespace and the veth pair are IfState's, so an apply
      # keeps them; the Jool instance lives inside.
      ifstate.settings = {
        interfaces.${host} = {
          addresses = [
            "192.0.0.1/30"
            "fd64::1/64"
          ];
          link = {
            kind = "veth";
            state = "up";
            peer = inside;
            peer_netns = netns;
          };
        };
        namespaces.${netns} = {
          interfaces.${inside} = {
            addresses = [
              "192.0.0.2/30"
              "fd64::2/64"
            ];
            link = {
              kind = "veth";
              state = "up";
              peer = host;
              peer_netns = null;
            };
          };
          routing.routes = [
            {
              to = "::/0";
              via = "fd64::1";
            }
            {
              to = "0.0.0.0/0";
              via = "192.0.0.1";
            }
          ];
        };
        routing.routes = [
          {
            to = cfg.pool6;
            via = "fd64::2";
          }
        ];
      };
    };

    systemd.services = {
      # Idempotent: an IfState apply restarts it (PartOf), and the
      # instance is still there (`instance add` fails on an existing one).
      # Not `requires`: IfState's unit also fails when some other
      # declared link is missing, after it applied this namespace; the
      # translator must not go down with an absent second NIC.
      ${names.nat64.jool} = {
        description = "Jool NAT64 in the ${netns} namespace (specs/gateway.md G2)";
        wantedBy = ["multi-user.target"];
        after = ["ifstate.service"];
        wants = ["ifstate.service"];
        partOf = ["ifstate.service"];
        path = [
          pkgs.iproute2
          pkgs.kmod
          pkgs.jool-cli
          pkgs.procps
          pkgs.gnugrep
          pkgs.gnused
          pkgs.python3
        ];
        # G8: a failure at boot (or one failed `jool` call) is tried
        # again; the script is idempotent
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 5;
        };
        script = ''
          canon() { python3 -c 'import ipaddress, sys; print(ipaddress.IPv6Network(sys.argv[1], strict=False))' "$1"; }
          modprobe jool
          ip netns exec ${netns} sysctl -w net.ipv4.conf.all.forwarding=1 net.ipv6.conf.all.forwarding=1
          # Jool refuses a pool4 range that overlaps the namespace's
          # ephemeral ports; nothing opens a socket in the namespace.
          ip netns exec ${netns} sysctl -w net.ipv4.ip_local_port_range="1024 1099"
          # A pool6 that changed in the configuration: the live instance
          # is replaced (a NAT64 instance's pool6 cannot be updated).
          # Compared as networks, never as strings.
          live=$(ip netns exec ${netns} jool -i default global display 2>/dev/null | sed -n 's/^ *pool6: *//p' || true)
          if [ -n "$live" ] && [ "$(canon "$live")" != "$(canon ${lib.escapeShellArg cfg.pool6})" ]; then
            echo "nat64-jool: pool6 was $live, the configuration says ${cfg.pool6}: the instance is made again"
            ip netns exec ${netns} jool instance remove default
          fi
          if ! ip netns exec ${netns} jool instance display | grep -w default >/dev/null; then
            ip netns exec ${netns} jool instance add default --netfilter --pool6 ${cfg.pool6}
          fi
          # G3: pool4 is checked at every start, not only when the
          # instance is made: a start killed half way or one failed `add`
          # left Jool on its fallback of a few thousand ports. Each
          # protocol holds exactly the one range, or all are made again.
          whole=1
          for proto in tcp udp icmp; do
            entries=$(ip netns exec ${netns} jool pool4 display --$proto --csv --no-headers)
            if [ "$(printf '%s\n' "$entries" | grep -c .)" != 1 ] || ! printf '%s\n' "$entries" | grep -F '192.0.0.2,1100,65535' >/dev/null; then
              whole=0
            fi
          done
          if [ "$whole" != 1 ]; then
            echo "nat64-jool: pool4 is not the one range 192.0.0.2 1100-65535 per protocol: made again"
            ip netns exec ${netns} jool pool4 flush
            for proto in tcp udp icmp; do
              ip netns exec ${netns} jool pool4 add 192.0.0.2 1100-65535 --$proto
            done
          fi
        '';
      };

      # G23, §14.5 point 4: hysteresis on both sides, over windows of
      # rounds (`down` and `up`, nat64-health.py). While
      # healthy the beacon runs and names the /96; while unhealthy it is
      # stopped, so a query is refused at once. The runtime directory
      # outlives a restart: the state file lets a deploy resume.
      ${names.nat64.health} = {
        description = "NAT64 health check through the translator (specs/gateway.md G23)";
        wantedBy = ["multi-user.target"];
        after = ["${names.nat64.jool}.service"];
        wants = ["${names.nat64.jool}.service"];
        path = [
          pkgs.iputils
          pkgs.iproute2
          pkgs.jool-cli
          config.systemd.package
        ];
        # G14: root for `systemctl` and `ip netns exec`, little else
        serviceConfig =
          sandbox
          // {
            ExecStart = "${lib.getExe pkgs.python3} -u ${healthScript} ${healthConfig}";
            Restart = "always";
            RestartSec = 1;
            RuntimeDirectory = names.nat64.runtime;
            RuntimeDirectoryPreserve = true;
            # ping
            CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_NET_RAW" "CAP_SYS_ADMIN"];
          };
        unitConfig.StartLimitIntervalSec = 0;
      };

      # G24: the beacon serves `ipv4only.arpa` and nothing else. It is
      # bound to the health check: CoreDNS keeps the records of a hosts
      # file that disappeared, so a dead check must take it down.
      ${names.nat64.beacon} = {
        description = "NAT64 health beacon: ipv4only.arpa only (specs/gateway.md G24)";
        bindsTo = ["${names.nat64.health}.service"];
        after = ["${names.nat64.health}.service" "ifstate.service"];
        serviceConfig = {
          ExecStart = "${lib.getExe pkgs.coredns} -conf ${corefile}";
          DynamicUser = true;
          AmbientCapabilities = ["CAP_NET_BIND_SERVICE"];
          CapabilityBoundingSet = ["CAP_NET_BIND_SERVICE"];
          NoNewPrivileges = true;
        };
      };
    };
  };
}
