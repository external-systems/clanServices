# The CLAT of specs/gateway.md G23: Jool SIIT in a namespace of its own
# (Jool never translates packets the host itself sends, so the host
# routes them into the namespace), `192.0.0.1` on the host side, an IPv4
# default route with MTU 1480, one explicit address mapping for the
# host, and the follower that keeps pool6 on a live gateway.
#
# Set by services/nat-gateway (role `client`). One CLAT per machine.
# The link `clat0` is IfState's, so an apply or a restart of the unit
# never removes and re-adds it (§14.3: Cilium attaches late to a link
# that was made again).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.clanServices.gateway.clat;
  names = import ./names.nix;
  inherit (names.clat) host inside netns instance;
  followScript = pkgs.writeText "clat-follow.py" (builtins.readFile ./clat-follow.py);
  followConfig = pkgs.writeText "clat-follow.json" (builtins.toJSON {
    inherit (cfg) beacons;
    need = cfg.followNeed;
    inherit netns instance;
  });
in {
  options.clanServices.gateway.clat = {
    enable = lib.mkEnableOption "the CLAT of specs/gateway.md G23";
    interface = mkOption {
      type = types.str;
      default = host;
      readOnly = true;
      description = "The host side of the CLAT link (Cilium `devices`, SPEC.md D71).";
    };
    address = mkOption {
      type = types.str;
      example = "2001:db8:c::c1a7";
      description = "The CLAT's own IPv6 address: routed to the machine, or answered for by proxy NDP.";
    };
    pool6 = mkOption {
      type = types.str;
      description = "The /96 the CLAT starts on: a gateway's pool6. The follower moves it.";
    };
    beacons = mkOption {
      type = types.listOf types.str;
      description = "The gateways' beacon addresses (G24), asked for `ipv4only.arpa`.";
    };
    followNeed = mkOption {
      type = types.ints.positive;
      default = 8;
      description = "Failed rounds in a row before the follower moves the CLAT (G23).";
    };
    proxyNdp = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Links on which the machine answers for the CLAT address by proxy NDP (an advertised, not routed, /64).";
    };
    mtu = mkOption {
      type = types.ints.positive;
      default = 1480;
      description = "MTU of the IPv4 default route: an IPv4 packet grows by 20 bytes when it becomes IPv6.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.beacons != [];
        message = "nat-gateway: the CLAT has no gateway to follow";
      }
      {
        assertion = !(config.boot.kernelPackages.jool.meta.broken or false);
        message = "nat-gateway: Jool is marked broken for kernel ${config.boot.kernelPackages.kernel.version}";
      }
    ];

    boot = {
      extraModulePackages = [config.boot.kernelPackages.jool];
      kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
    };
    # the CLAT forwards IPv6, so netif renders accept_ra 2
    clan._networkFacts.forwarding = true;
    environment.systemPackages = [pkgs.jool-cli];

    networking.ifstate.settings = {
      interfaces.${host} = {
        addresses = [
          "192.0.0.1/29"
          "fd00:c1a7::1/64"
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
            "192.0.0.2/29"
            "fd00:c1a7::2/64"
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
            via = "fd00:c1a7::1";
          }
          {
            to = "0.0.0.0/0";
            via = "192.0.0.1";
          }
        ];
      };
      routing.routes = [
        {
          to = "0.0.0.0/0";
          via = "192.0.0.2";
        }
        {
          to = "${cfg.address}/128";
          via = "fd00:c1a7::2";
        }
      ];
    };

    systemd.services = {
      # Idempotent: an IfState apply restarts it (Requires), and the
      # instance, its pool6 (the follower's choice) and its mapping stay.
      ${names.clat.jool} = {
        description = "CLAT: Jool SIIT in the ${netns} namespace (specs/gateway.md G23)";
        wantedBy = ["multi-user.target"];
        after = ["ifstate.service"];
        requires = ["ifstate.service"];
        path = [
          pkgs.iproute2
          pkgs.kmod
          pkgs.jool-cli
          pkgs.procps
          pkgs.gnugrep
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          modprobe jool_siit
          ip netns exec ${netns} sysctl -w net.ipv4.conf.all.forwarding=1 net.ipv6.conf.all.forwarding=1
          if ! ip netns exec ${netns} jool_siit instance display | grep -w ${instance} >/dev/null; then
            ip netns exec ${netns} jool_siit instance add ${instance} --netfilter --pool6 ${cfg.pool6}
          fi
          if ! ip netns exec ${netns} jool_siit -i ${instance} eamt display --csv | grep -F '${cfg.address}/128,192.0.0.1/32' >/dev/null; then
            ip netns exec ${netns} jool_siit -i ${instance} eamt add ${cfg.address} 192.0.0.1
          fi
          ip route replace default via 192.0.0.2 dev ${host} mtu ${toString cfg.mtu}
          ${lib.concatMapStrings (link: ''
              sysctl -w net.ipv6.conf.${link}.proxy_ndp=1
              ip -6 neigh replace proxy ${cfg.address} dev ${link}
            '')
            cfg.proxyNdp}
        '';
      };

      ${names.clat.follow} = {
        description = "CLAT follower: pool6 on a live gateway (specs/gateway.md G23)";
        wantedBy = ["multi-user.target"];
        after = ["${names.clat.jool}.service"];
        requires = ["${names.clat.jool}.service"];
        path = [
          pkgs.iproute2
          pkgs.jool-cli
          pkgs.dig
        ];
        serviceConfig = {
          ExecStart = "${lib.getExe pkgs.python3} -u ${followScript} ${followConfig}";
          Restart = "always";
          RestartSec = 1;
        };
        unitConfig.StartLimitIntervalSec = 0;
      };
    };
  };
}
