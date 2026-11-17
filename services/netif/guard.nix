# netif's lockout guard (specs/netif.md N25, N36). IfState has no
# rollback, and a bad change on a headless machine cuts the only way in.
#
# After every apply the guard asks each default gateway for a layer-2
# answer (ARP, neighbour discovery: gateways may drop pings) and checks
# the extra targets the machine declares. When one stays silent it
# re-applies the last network configuration that passed, and fails. It
# rolls back the network only, never the NixOS generation.
#
# It is its own unit, `netif-guard.service`, ordered after
# `ifstate.service` and the dhcpcd units: a DHCP gateway is learned only
# after dhcpcd runs, and dhcpcd starts after `ifstate.service` is done.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.clanServices.netif;
  inherit (cfg) guard;
  ifstatecli = lib.getExe' config.networking.ifstate.package "ifstatecli";
  isV6 = lib.hasInfix ":";

  # "<kind>|<address>|<interface>|<port>" per target.
  gatewayTargets = lib.concatLists (
    lib.mapAttrsToList (
      interface: l:
        lib.optional (l.gateway4 != null) "neigh4|${l.gateway4}|${interface}|"
        ++ lib.optional (l.gateway6 != null) "neigh6|${l.gateway6}|${interface}|"
    )
    cfg.links
  );
  extraTargets =
    map (
      t:
        if t.port != null
        then "tcp|${t.address}||${toString t.port}"
        else if t.interface != null
        then "${
          if isV6 t.address
          then "neigh6"
          else "neigh4"
        }|${t.address}|${t.interface}|"
        else "ping|${t.address}||"
    )
    guard.targets;
  dhcpLinks = lib.attrNames (lib.filterAttrs (_: l: l.dhcp4 || l.dhcp6) cfg.links);
  # DHCPv4 links that own the default: their gateway is learned.
  dhcpDefaults = lib.attrNames (lib.filterAttrs (_: l: l.dhcp4 && l.default4) cfg.links);

  script = pkgs.writeShellApplication {
    name = "netif-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.iproute2
      pkgs.iputils
      pkgs.jq
      pkgs.ndisc6
      pkgs.netcat
      pkgs.systemd
    ];
    text = ''
      mode=$1
      config=''${2:-}
      state=/var/lib/netif/guard
      deadline=$(( $(date +%s) + ${toString guard.timeout} ))

      probe() { # kind address interface port
        case "$1" in
          neigh4) arping -q -c1 -w1 -I "$3" "$2" ;;
          neigh6) ndisc6 -q -1 -r1 -w1000 "$2" "$3" > /dev/null ;;
          ping) ping -q -c1 -W1 "$2" > /dev/null ;;
          tcp) nc -z -w1 "$2" "$4" ;;
        esac
      }
      label() { # kind address interface port
        case "$1" in
          tcp) echo "$2 port $4" ;;
          ping) echo "$2 (ping)" ;;
          *) echo "$2 on $3" ;;
        esac
      }

      targets="${lib.concatStringsSep " " extraTargets}"
      failed=""
      if [ "$mode" = apply ]; then
        targets="$targets ${lib.concatStringsSep " " gatewayTargets}"
        # a DHCP link is checked against the gateway it learns
        dhcp_links="${lib.concatStringsSep " " dhcpDefaults}"
        for dev in $dhcp_links; do
          until ip -j -4 route show default dev "$dev" | jq -e 'any(.[]; .gateway)' > /dev/null; do
            if [ "$(date +%s)" -ge "$deadline" ]; then
              failed="$failed; no DHCP default route on $dev"
              break
            fi
            sleep 1
          done
        done
        # every default gateway in the main table, whatever its source
        targets="$targets $(ip -j -4 route show default | jq -r '.[] | select(.gateway) | "neigh4|\(.gateway)|\(.dev)|"')"
        targets="$targets $(ip -j -6 route show default | jq -r '.[] | select(.gateway) | "neigh6|\(.gateway)|\(.dev)|"')"
      fi

      # shellcheck disable=SC2086
      for target in $(printf '%s\n' $targets | sort -u); do
        IFS='|' read -r kind address interface port <<< "$target"
        answered=0
        while :; do
          if probe "$kind" "$address" "$interface" "$port"; then
            answered=1
            break
          fi
          [ "$(date +%s)" -lt "$deadline" ] || break
          sleep 1
        done
        [ "$answered" = 1 ] || failed="$failed; no answer from $(label "$kind" "$address" "$interface" "$port")"
      done

      if [ "$mode" = firewall ]; then
        if [ -n "$failed" ]; then
          echo "netif-guard: after the firewall change''${failed#;}. The firewall was not rolled back; fix the rules or 'clanServices.netif.guard.targets' (specs/netif.md N36)" >&2
          exit 1
        fi
        echo "netif-guard: targets answer after the firewall change"
        exit 0
      fi

      mkdir -p "$state"
      if [ -z "$failed" ] && [ "$(systemctl show -p Result --value ifstate.service)" != success ]; then
        echo "netif-guard: gateways and targets answer, but ifstate.service did not apply cleanly; $config is not recorded as good"
        exit 0
      fi
      if [ -z "$failed" ]; then
        ln -sfn "$config" "$state/last-good"
        ln -sfn "$config" /nix/var/nix/gcroots/netif-guard-last-good
        echo "netif-guard: gateways and targets answer; kept $config"
        exit 0
      fi
      echo "netif-guard:''${failed#;}" >&2
      previous=$(readlink "$state/last-good" 2> /dev/null || true)
      if [ -n "$previous" ] && [ "$previous" != "$config" ] && [ -e "$previous" ]; then
        echo "netif-guard: re-applying the last network configuration that passed: $previous" >&2
        if ${ifstatecli} --config "$previous" apply >&2; then
          echo "netif-guard: rolled back. The running generation still names the failed configuration; deploy a corrected one (specs/netif.md N25)" >&2
        else
          echo "netif-guard: the rollback itself failed; the network is in the state above" >&2
        fi
      else
        echo "netif-guard: there is no earlier network configuration to roll back to; the failed one stays applied (specs/netif.md N25)" >&2
      fi
      exit 1
    '';
  };
in {
  options.clanServices.netif.guard = {
    enable = mkOption {
      type = types.bool;
      default = !(config.services.xserver.enable || config.services.displayManager.enable || config.programs.gamescope.enable);
      defaultText = lib.literalExpression "true on a machine without a display manager or gamescope";
      description = ''
        Check after every network apply that the default gateways still
        answer, and roll the network back to the last configuration
        that passed when they do not (specs/netif.md N25). On by
        default on headless machines, where a bad change cuts the only
        way in; off where someone sits in front of the machine.
      '';
    };
    timeout = mkOption {
      type = types.ints.positive;
      default = 30;
      description = "Seconds the guard waits for every gateway and target to answer. A good apply returns as soon as all answered.";
    };
    targets = mkOption {
      default = [];
      example = lib.literalExpression ''[{address = "192.0.2.10"; port = 22;}]'';
      description = ''
        Addresses that must answer besides the gateways, for example
        the machine you deploy from (specs/netif.md N36). With 'port'
        the guard opens a TCP connection; with 'interface' it asks for
        a layer-2 answer on that link; with neither it pings. These are
        also checked after a firewall reload, where a failure is
        reported and nothing is rolled back.
      '';
      type = types.listOf (
        types.submodule {
          options = {
            address = mkOption {
              type = types.str;
              description = "IPv4 or IPv6 address.";
            };
            interface = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Link to ask for a layer-2 answer on (an on-link address).";
            };
            port = mkOption {
              type = types.nullOr types.port;
              default = null;
              description = "TCP port that must accept a connection.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf (cfg.links != {} && guard.enable) {
    systemd = {
      tmpfiles.rules = ["d /var/lib/netif/guard 0755 root root -"];
      services = {
        netif-guard = {
          description = "netif: roll the network back when the gateways stop answering";
          wantedBy = ["multi-user.target"];
          after = ["ifstate.service"] ++ map (interface: "netif-dhcpcd-${interface}.service") dhcpLinks;
          # a changed network configuration restarts the guard with it, so
          # a deploy waits for the verdict and reports a failure
          restartTriggers = [config.environment.etc."ifstate/ifstate.yaml".source];
          # every apply runs it once; ifstate.service is the limit
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${lib.getExe script} apply ${config.environment.etc."ifstate/ifstate.yaml".source}";
          };
        };
        # every apply is followed by a guard run, also a manual restart
        ifstate.serviceConfig.ExecStartPost = [
          "${lib.getExe' pkgs.systemd "systemctl"} restart --no-block netif-guard.service"
        ];
        nftables.serviceConfig.ExecReload = lib.mkIf (guard.targets != []) (
          lib.mkAfter ["${lib.getExe script} firewall"]
        );
      };
    };
  };
}
