# netif's operator tools (specs/netif.md N38, N41, N42). All three are
# read-only: none of them changes the network.
#
# - `netif-preview [system]`: what an apply would change, for the running
#   configuration or for another built system. Exit 0: nothing; 2: changes.
# - `netif-drift.service` and its timer: the same dry run on a schedule.
#   The unit fails when the network no longer matches the configuration.
# - `netif-status [--json]`: every netif link with its live state.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.clanServices.netif;
  ifstatecli = lib.getExe' config.networking.ifstate.package "ifstatecli";
  linksJson = pkgs.writeText "netif-links.json" (builtins.toJSON cfg.links);

  # `ifstatecli check` always exits 0, so its output is read: an indented
  # `<object>  <operation>` line per object, where `ok`, `= <value>` and
  # `orphan` mean "unchanged" (format pinned against IfState 2.5.1; the
  # VM suites' no-op helper reads it the same way).
  preview = pkgs.writeShellApplication {
    name = "netif-preview";
    # IfState calls `mount` and `ip` when named network namespaces exist.
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.iproute2
      pkgs.util-linux
    ];
    text = ''
      config=/etc/ifstate/ifstate.yaml
      case "''${1:-}" in
        -h | --help)
          echo "usage: netif-preview [system]"
          echo "  Show what applying the network configuration would change."
          echo "  system: a built NixOS system (./result, a profile generation);"
          echo "          default: the running configuration."
          echo "  Exit status: 0 nothing would change, 2 changes, 1 the dry run failed."
          exit 0
          ;;
        "") ;;
        *)
          config="$1/etc/ifstate/ifstate.yaml"
          [ -r "$config" ] || config="$1"
          ;;
      esac
      if [ ! -r "$config" ]; then
        echo "netif-preview: cannot read $config (run as root; pass a built system or an IfState config)" >&2
        exit 1
      fi
      if ! out=$(${ifstatecli} --config "$config" check 2>&1); then
        printf '%s\n' "$out" >&2
        echo "netif-preview: the dry run failed; see the lines above" >&2
        exit 1
      fi
      changes=$(printf '%s\n' "$out" | awk '
        /^  / {
          n = split($0, f, /  +/)
          if (n < 3) next
          if (f[3] == "ok" || f[3] == "orphan" || f[3] ~ /^= /) next
          sub(/^ +/, "")
          print "  " $0
        }')
      if [ -z "$changes" ]; then
        echo "netif-preview: applying $config would change nothing"
        exit 0
      fi
      echo "netif-preview: applying $config would change:"
      printf '%s\n' "$changes"
      exit 2
    '';
  };

  drift = pkgs.writeShellApplication {
    name = "netif-drift";
    runtimeInputs = [pkgs.systemd];
    text = ''
      # An apply in progress is not drift.
      if [ "$(systemctl show -p ActiveState --value ifstate.service)" = activating ]; then
        echo "netif-drift: ifstate.service is applying; skipped"
        exit 0
      fi
      status=0
      ${lib.getExe preview} || status=$?
      if [ "$status" = 2 ]; then
        echo "netif-drift: the network differs from the configuration. Nothing was changed. Run 'systemctl restart ifstate.service' to reapply, or find the other writer first (specs/netif.md N38)." >&2
        exit 1
      fi
      exit "$status"
    '';
  };

  status = pkgs.writeShellApplication {
    name = "netif-status";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.iproute2
      pkgs.jq
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      case "''${1:-}" in
        -h | --help)
          echo "usage: netif-status [--json]"
          echo "  Every netif link of this machine with its live state. Read-only."
          exit 0
          ;;
      esac

      unit() { systemctl show -p "$2" --value "$1" 2>/dev/null || true; }
      dns_of() { resolvectl dns "$1" 2>/dev/null | cut -d: -f2- | xargs || true; }

      dns=$(jq -r 'keys[]' ${linksJson} | while read -r l; do
        jq -n --arg l "$l" --arg d "$(dns_of "$l")" '{($l): ($d | split(" ") | map(select(. != "")))}'
      done | jq -s 'add // {}')
      dhcp=$(jq -r 'to_entries[] | select(.value.dhcp4 or .value.dhcp6) | .key' ${linksJson} | while read -r l; do
        jq -n --arg l "$l" --arg s "$(unit "netif-dhcpcd-$l.service" ActiveState)" '{($l): $s}'
      done | jq -s 'add // {}')

      report=$(jq -n \
        --slurpfile links ${linksJson} \
        --argjson addr "$(ip -j addr show)" \
        --argjson r4 "$(ip -j -4 route show default)" \
        --argjson r6 "$(ip -j -6 route show default)" \
        --argjson dns "$dns" \
        --argjson dhcp "$dhcp" \
        --arg ifstate "$(unit ifstate.service Result)" \
        --arg applied "$(unit ifstate.service ExecMainExitTimestamp)" \
        --arg drift "$(unit netif-drift.service Result)" \
        --arg driftRan "$(unit netif-drift.service ExecMainExitTimestamp)" \
        '{
          ifstate: {result: $ifstate, applied: $applied},
          drift: (if $driftRan == "" then "not run yet" elif $drift == "success" then "none" else "DRIFT" end),
          defaultRoutes: {
            ipv4: [$r4[] | {dev, gateway, metric, protocol}],
            ipv6: [$r6[] | {dev, gateway, metric, protocol}]
          },
          links: [
            $links[0] | to_entries[] | .key as $if | .value as $l
            | ($addr[] | select(.ifname == $if)) as $live
            | {
                instance: $l.instance,
                link: $l.logical,
                interface: $if,
                kind: $l.kind,
                zone: $l.zone,
                trusted: $l.trusted,
                present: true,
                state: $live.operstate,
                mtu: $live.mtu,
                addresses: [$live.addr_info[] | select(.scope == "global") | "\(.local)/\(.prefixlen)"],
                dhcp: (if $l.dhcp4 or $l.dhcp6 then ($dhcp[$if] // "unknown") else null end),
                dns: ($dns[$if] // [])
              }
          ] + [
            $links[0] | to_entries[] | .key as $if | .value as $l
            | select(([$addr[] | select(.ifname == $if)] | length) == 0)
            | {instance: $l.instance, link: $l.logical, interface: $if, kind: $l.kind, zone: $l.zone, trusted: $l.trusted, present: false, state: "MISSING", mtu: null, addresses: [], dhcp: null, dns: []}
          ]
        }')

      if [ "''${1:-}" = --json ]; then
        printf '%s\n' "$report"
        exit 0
      fi

      printf '%s\n' "$report" | jq -r '
        "ifstate.service: \(.ifstate.result)  (last apply: \(.ifstate.applied))",
        "drift: \(.drift)",
        "default route ipv4: \(.defaultRoutes.ipv4 | map("via \(.gateway) dev \(.dev) metric \(.metric) (\(.protocol))") | join("; ") | if . == "" then "none" else . end)",
        "default route ipv6: \(.defaultRoutes.ipv6 | map("via \(.gateway) dev \(.dev) metric \(.metric) (\(.protocol))") | join("; ") | if . == "" then "none" else . end)",
        "",
        (["LINK", "INTERFACE", "STATE", "ZONE", "TRUST", "DHCP", "ADDRESSES", "DNS"] | @tsv),
        (.links | sort_by(.instance, .link)[] | [
          "\(.instance)/\(.link)", .interface, .state, (.zone // "-"),
          (if .trusted then "trusted" else "untrusted" end), (.dhcp // "-"),
          (.addresses | join(",") | if . == "" then "-" else . end),
          (.dns | join(",") | if . == "" then "-" else . end)
        ] | @tsv)
      ' | column -t -s "$(printf '\t')" -o '  ' -c 0 || true
    '';
  };
in {
  options.clanServices.netif.driftInterval = mkOption {
    type = types.str;
    default = "1h";
    example = "15min";
    description = ''
      How often 'netif-drift.service' compares the network with the
      configuration (a systemd time span). The check is a dry run and
      never changes anything (specs/netif.md N38).
    '';
  };

  config = lib.mkIf (cfg.links != {}) {
    environment.systemPackages = [
      preview
      status
    ];

    systemd = {
      services.netif-drift = {
        description = "netif: fail when the network differs from the configuration";
        after = ["ifstate.service"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe drift;
        };
      };
      timers.netif-drift = {
        description = "netif: drift watch";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "15min";
          OnUnitActiveSec = cfg.driftInterval;
          RandomizedDelaySec = "5min";
        };
      };
    };
  };
}
