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
  ip = import ../../lib/ip.nix {inherit lib;};
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
  # Links that may hold the main-table default of a family (N21).
  may4 = lib.attrNames (lib.filterAttrs (_: l: l.default4) cfg.links);
  may6 = lib.attrNames (lib.filterAttrs (_: l: l.default6) cfg.links);

  yaml = config.environment.etc."ifstate/ifstate.yaml".source;
  generation = "${yaml}:${toString cfg.dhcpcdConfs}";
  # The rollback applies the last configuration that passed, with the
  # ignore lists of the running generation added: what an owner got in
  # the failed generation (Cilium's links, a fabric's) is still running
  # and must not be deleted (specs/netif.md N6, N25). YAML tags such as
  # `!include` pass through unchanged.
  mergeIgnore = pkgs.writers.writePython3 "netif-guard-merge-ignore" {libraries = [pkgs.python3Packages.pyyaml];} ''
    import sys
    import yaml


    class Tagged:
        def __init__(self, tag, value):
            self.tag, self.value = tag, value


    def construct(loader, suffix, node):
        return Tagged("!" + suffix, loader.construct_scalar(node))


    def represent(dumper, item):
        return dumper.represent_scalar(item.tag, item.value)


    yaml.SafeLoader.add_multi_constructor("!", construct)
    yaml.SafeDumper.add_representer(Tagged, represent)

    previous, running, out = sys.argv[1:4]
    with open(previous) as file:
        config = yaml.load(file, Loader=yaml.SafeLoader)
    with open(running) as file:
        live = yaml.load(file, Loader=yaml.SafeLoader)
    ignore = (live.get("parameters") or {}).get("ignore") or {}
    kept = config.setdefault("parameters", {}).setdefault("ignore", {})
    for key, entries in ignore.items():
        have = kept.get(key) or []
        kept[key] = have + [entry for entry in entries if entry not in have]
    with open(out, "w") as file:
        yaml.dump(config, file, Dumper=yaml.SafeDumper)
  '';

  # dhcpcd for a link whose DHCP client the failed generation dropped
  # (a DHCP link made static): a transient unit with the kept
  # configuration, bound to the link like netif's own (N25).
  dhcpcd = lib.getExe pkgs.dhcpcd_latest;
  ipExe = lib.getExe' pkgs.iproute2 "ip";

  script = pkgs.writeShellApplication {
    name = "netif-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.iproute2
      pkgs.iputils
      pkgs.jq
      pkgs.ndisc6
      pkgs.netcat
      pkgs.systemd
      # ifstatecli mounts a namespace's /run/netns entry: without mount a
      # rollback of a configuration with a namespace fails
      pkgs.util-linux
    ];
    text = ''
      mode=$1
      config=''${2:-}
      dhcp=''${3:-}
      state=/var/lib/netif/guard
      run=/run/netif-guard
      timeout=${toString guard.timeout}
      # what this generation declares; every element is one shell word
      links=(${lib.escapeShellArgs (lib.attrNames cfg.links)})
      extra=(${lib.escapeShellArgs extraTargets})
      static=(${lib.escapeShellArgs gatewayTargets})
      dhcp_defaults=(${lib.escapeShellArgs dhcpDefaults})
      may4=(${lib.escapeShellArgs may4})
      may6=(${lib.escapeShellArgs may6})

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
      member() { # word list...
        local word=$1 item
        shift
        for item in "$@"; do
          if [ "$item" = "$word" ]; then
            return 0
          fi
        done
        return 1
      }
      # a main-table default route of this family on this link
      has_default() { # family interface
        ip -j "-$1" route show default dev "$2" 2> /dev/null | jq -e 'length > 0' > /dev/null
      }
      # the defaults netif's links hold now, one "<family> <link>" a line:
      # from IfState, DHCP or an RA, not from a routing daemon (N25)
      own_defaults() {
        local dev family
        for dev in "''${links[@]}"; do
          for family in 4 6; do
            if ip -j "-$family" route show default dev "$dev" 2> /dev/null \
              | jq -e 'any(.[]; (.protocol // "boot") as $p | ["boot", "dhcp", "ra"] | index($p))' > /dev/null; then
              echo "$family $dev"
            fi
          done
        done
      }

      # One check, bounded by one deadline. In: the arrays `required`
      # ("<family> <link>": a default route that must be there) and
      # `targets`, and `gateways` (1: also every default gateway in the
      # main table, whatever its source). Out: `failed` (the reasons),
      # `missing` (1: a default route never came) and `silent` (the
      # targets that did not answer).
      check() {
        local deadline family dev target kind address interface port answered
        local all=()
        failed=""
        missing=0
        silent=()
        deadline=$(( $(date +%s) + timeout ))
        # a link can be required twice (DHCP and last good): judge it once
        while read -r family dev <&3; do
          [ -n "$family" ] || continue
          until has_default "$family" "$dev"; do
            if [ "$(date +%s)" -ge "$deadline" ]; then
              failed="$failed; no IPv$family default route on $dev"
              missing=1
              break
            fi
            sleep 1
          done
        done 3< <(printf '%s\n' "''${required[@]}" | sort -u)
        all=("''${targets[@]}")
        if [ "$gateways" = 1 ]; then
          mapfile -t -O "''${#all[@]}" all < <(
            ip -j -4 route show default | jq -r '.[] | select(.gateway) | "neigh4|\(.gateway)|\(.dev)|"'
            ip -j -6 route show default | jq -r '.[] | select(.gateway) | "neigh6|\(.gateway)|\(.dev)|"'
          )
        fi
        while IFS= read -r target <&3; do
          [ -n "$target" ] || continue
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
          if [ "$answered" = 0 ]; then
            failed="$failed; no answer from $(label "$kind" "$address" "$interface" "$port")"
            silent+=("$target")
          fi
        done 3< <(printf '%s\n' "''${all[@]}" | sort -u)
      }

      # The DHCP clients back to this generation's configuration: no kept
      # file, no transient client, no rollback marker.
      reset_dhcpcd() {
        ${resetDhcpcd}
      }
      start_client() { # interface configuration
        local device
        device=$(systemd-escape --path --suffix=device "/sys/subsystem/net/devices/$1")
        mkdir -p /run/dhcpcd /var/lib/dhcpcd /run/netif-dns /run/netif/pd
        systemctl stop "netif-guard-dhcpcd-$1.service" 2> /dev/null || true
        systemctl reset-failed "netif-guard-dhcpcd-$1.service" 2> /dev/null || true
        systemd-run --no-block --collect --unit "netif-guard-dhcpcd-$1" \
          --description "netif-guard: dhcpcd on $1 with the configuration that passed" \
          -p "BindsTo=$device" -p "After=$device" -p Restart=on-failure -p RestartSec=2 \
          -p "ExecStopPost=${ipExe} -4 addr flush dev $1 dynamic" \
          ${dhcpcd} -B -f "$2" "$1"
      }

      if [ "$mode" = firewall ]; then
        required=()
        targets=("''${extra[@]}")
        gateways=0
        check
        if [ -n "$failed" ]; then
          echo "netif-guard: after the firewall change''${failed#;}. The firewall was not rolled back; fix the rules or 'clanServices.netif.guard.targets' (specs/netif.md N36)" >&2
          exit 1
        fi
        echo "netif-guard: targets answer after the firewall change"
        exit 0
      fi

      mkdir -p "$state" "$run"
      this="$config $dhcp"
      # After a rollback the kernel holds the last good configuration, not
      # this one: a second run must not judge it and record this one (N25).
      if [ "$(cat "$run/rolled-back" 2> /dev/null || true)" = "$this" ]; then
        echo "netif-guard: the network is still rolled back from $config; nothing is checked or recorded. Restart ifstate.service to try it again, or deploy a corrected configuration (specs/netif.md N25)" >&2
        exit 1
      fi
      # Not applied yet: switch-to-configuration started this run before
      # ifstate.service. The run that follows the apply judges it.
      if [ "$(cat "$run/applying" 2> /dev/null || true)" != "$config" ]; then
        echo "netif-guard: $config is not applied yet; the run after ifstate.service judges it"
        exit 0
      fi

      # A DHCPv4 link that owns the default is checked against the
      # gateway it learns. A link that held a default when the last
      # configuration passed must hold one again, unless this generation
      # takes the default away from it ('defaultRoute') (N25).
      required=()
      for dev in "''${dhcp_defaults[@]}"; do
        required+=("4 $dev")
      done
      if [ -r "$state/last-good-defaults" ]; then
        while read -r family dev; do
          if { [ "$family" = 4 ] && member "$dev" "''${may4[@]}"; } || { [ "$family" = 6 ] && member "$dev" "''${may6[@]}"; }; then
            required+=("$family $dev")
          fi
        done < "$state/last-good-defaults"
      fi
      targets=("''${extra[@]}" "''${static[@]}")
      gateways=1
      check

      if [ -z "$failed" ] && [ "$(systemctl show -p Result --value ifstate.service)" != success ]; then
        echo "netif-guard: gateways and targets answer, but ifstate.service did not apply cleanly; $config is not recorded as good"
        exit 0
      fi
      if [ -z "$failed" ]; then
        ln -sfn "$config" "$state/last-good"
        ln -sfn "$config" /nix/var/nix/gcroots/netif-guard-last-good
        if [ -n "$dhcp" ]; then
          ln -sfn "$dhcp" "$state/last-good-dhcpcd"
          ln -sfn "$dhcp" /nix/var/nix/gcroots/netif-guard-last-good-dhcpcd
        else
          rm -f "$state/last-good-dhcpcd" /nix/var/nix/gcroots/netif-guard-last-good-dhcpcd
        fi
        own_defaults > "$state/last-good-defaults.new"
        mv "$state/last-good-defaults.new" "$state/last-good-defaults"
        # the units already run this generation's own files
        systemctl stop 'netif-guard-dhcpcd-*.service' 2> /dev/null || true
        rm -rf "$run/dhcpcd" "$run/generation" "$run/rolled-back" "$run/rollback.yaml"
        echo "netif-guard: gateways and targets answer; kept $config"
        exit 0
      fi

      echo "netif-guard:''${failed#;}" >&2
      first=("''${silent[@]}")
      previous=$(readlink "$state/last-good" 2> /dev/null || true)
      previous_dhcp=$(readlink "$state/last-good-dhcpcd" 2> /dev/null || true)
      rolled=0
      links_rolled=0
      tried=0
      # The DHCP clients go back to the configuration that passed, for
      # as long as this generation runs.
      reset_dhcpcd
      clients=()
      if [ -n "$previous_dhcp" ] && [ "$previous_dhcp" != "$dhcp" ] && [ -d "$previous_dhcp" ]; then
        for kept in "$previous_dhcp"/*.conf; do
          [ -e "$kept" ] || continue
          name=$(basename "$kept" .conf)
          if [ -n "$dhcp" ] && [ -e "$dhcp/$name.conf" ]; then
            if ! cmp -s "$kept" "$dhcp/$name.conf"; then
              mkdir -p "$run/dhcpcd"
              ln -sfn "$(readlink -f "$kept")" "$run/dhcpcd/$name.conf"
              echo ${lib.escapeShellArg generation} > "$run/generation"
              echo "netif-guard: dhcpcd on $name goes back to the configuration that passed" >&2
              # not its Wants=ifstate.service: that would start an apply,
              # whose first step ends this rollback
              systemctl restart --no-block --job-mode=ignore-requirements "netif-dhcpcd-$name.service"
              rolled=1
            fi
          else
            # this generation runs no DHCP client on the link (N25)
            clients+=("$name")
          fi
        done
      fi
      if [ -n "$previous" ] && [ "$previous" != "$config" ] && [ -e "$previous" ]; then
        echo "netif-guard: re-applying the last network configuration that passed: $previous" >&2
        rollback=$previous
        if ${mergeIgnore} "$previous" "$config" "$run/rollback.yaml" >&2; then
          rollback=$run/rollback.yaml
        else
          echo "netif-guard: could not add the running ignore lists; applying $previous as it is" >&2
        fi
        tried=1
        if ${ifstatecli} --config "$rollback" apply >&2; then
          rolled=1
          links_rolled=1
        else
          echo "netif-guard: the rollback itself failed; the network is in the state above" >&2
        fi
      fi
      for name in "''${clients[@]}"; do
        if [ -e "/sys/class/net/$name" ]; then
          echo "netif-guard: this generation runs no DHCP client on $name; starting one with the configuration that passed" >&2
          start_client "$name" "$(readlink -f "$previous_dhcp/$name.conf")"
          rolled=1
        fi
      done

      if [ "$rolled" = 0 ]; then
        [ "$tried" = 0 ] || exit 1
        # none, or the last one that passed is this one
        echo "netif-guard: there is no earlier network configuration to roll back to; the failed one stays applied (specs/netif.md N25)" >&2
        exit 1
      fi
      echo "$this" > "$run/rolled-back"

      # Is the fault outside the machine (N25)? Ask again, now with the
      # last good configuration in place: its defaults, every gateway it
      # has, and the declared targets.
      required=()
      if [ -r "$state/last-good-defaults" ]; then
        mapfile -t required < "$state/last-good-defaults"
      fi
      targets=("''${extra[@]}")
      gateways=1
      check
      if [ -z "$failed" ]; then
        echo "netif-guard: rolled back. The running generation still names the failed configuration; deploy a corrected one (specs/netif.md N25)" >&2
        exit 1
      fi
      outside=1
      [ "$missing" = 0 ] || outside=0
      for target in "''${silent[@]}"; do
        member "$target" "''${first[@]}" || outside=0
      done
      if [ "$outside" = 1 ]; then
        echo "netif-guard: with the last good configuration too''${failed#;}: the fault is outside this machine. Re-applying $config, which stays unrecorded (specs/netif.md N25)" >&2
        rm -f "$run/rolled-back"
        reset_dhcpcd
        if [ "$links_rolled" = 1 ] && ! ${ifstatecli} --config "$config" apply >&2; then
          echo "netif-guard: re-applying $config failed; the network is in the state above" >&2
        fi
        exit 1
      fi
      echo "netif-guard: rolled back, and with the last good configuration''${failed#;}. It stays applied (specs/netif.md N25)" >&2
      exit 1
    '';
  };

  # The DHCP clients back to this generation's configuration: no kept
  # file, no transient client (N25).
  resetDhcpcd = pkgs.writeShellScript "netif-guard-reset-dhcpcd" ''
    run=/run/netif-guard
    ${lib.getExe' pkgs.systemd "systemctl"} stop 'netif-guard-dhcpcd-*.service' 2> /dev/null || true
    units=()
    if [ -d "$run/dhcpcd" ]; then
      for kept in "$run/dhcpcd"/*.conf; do
        [ -e "$kept" ] && units+=("netif-dhcpcd-$(${lib.getExe' pkgs.coreutils "basename"} "$kept" .conf).service")
      done
    fi
    rm -rf "$run/dhcpcd" "$run/generation"
    if [ "''${#units[@]}" -gt 0 ]; then
      # not their Wants=ifstate.service: that would start another apply
      ${lib.getExe' pkgs.systemd "systemctl"} restart --no-block --job-mode=ignore-requirements "''${units[@]}" || true
    fi
    exit 0
  '';
  # The ifstate.service steps around an apply. Before it: note which
  # configuration this apply is of, so a guard run that starts before it
  # (switch-to-configuration starts both) does not judge the old network
  # under the new name; end a rollback and the guard's DHCP clients.
  # After a failed apply: a guard run all the same, since ExecStartPost
  # runs only after a clean one (N25).
  beforeApply = pkgs.writeShellScript "netif-guard-before-apply" ''
    run=/run/netif-guard
    ${lib.getExe' pkgs.coreutils "mkdir"} -p "$run"
    rm -f "$run/rolled-back"
    echo ${yaml} > "$run/applying"
    exec ${resetDhcpcd}
  '';
  guardAfterFailure = pkgs.writeShellScript "netif-guard-after-failure" ''
    if [ "''${SERVICE_RESULT:-success}" != success ]; then
      exec ${lib.getExe' pkgs.systemd "systemctl"} restart --no-block netif-guard.service
    fi
  '';
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
    script = mkOption {
      internal = true;
      readOnly = true;
      type = types.package;
      default = script;
      defaultText = lib.literalMD "the guard's shell script";
      description = "The guard's script, for the eval tests.";
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
              type = ip.types.address;
              description = "IPv4 or IPv6 address.";
            };
            interface = mkOption {
              type = types.nullOr (types.strMatching "[^[:space:]/:|]{1,15}");
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

  config = lib.mkIf (cfg.links != {} && guard.enable && config.clanServices.networking.mode.manager == "ifstate") {
    clanServices.netif.guardGeneration = generation;
    systemd = {
      tmpfiles.rules = ["d /var/lib/netif/guard 0755 root root -"];
      services = {
        netif-guard = {
          description = "netif: roll the network back when the gateways stop answering";
          wantedBy = ["multi-user.target"];
          after = ["ifstate.service"] ++ map (interface: "netif-dhcpcd-${interface}.service") dhcpLinks;
          # a changed network configuration restarts the guard with it, so
          # a deploy waits for the verdict and reports a failure
          restartTriggers = [generation];
          # every apply runs it once; ifstate.service is the limit
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${lib.getExe guard.script} apply ${yaml} ${toString cfg.dhcpcdConfs}";
          };
        };
        # every apply is followed by a guard run, also a manual restart,
        # and also one whose ExecStart failed (N25)
        ifstate.serviceConfig = {
          ExecStartPre = lib.mkBefore [beforeApply];
          ExecStartPost = [
            "${lib.getExe' pkgs.systemd "systemctl"} restart --no-block netif-guard.service"
          ];
          ExecStopPost = [guardAfterFailure];
        };
        nftables.serviceConfig.ExecReload = lib.mkIf (guard.targets != []) (
          lib.mkAfter ["${lib.getExe script} firewall"]
        );
      };
    };
  };
}
