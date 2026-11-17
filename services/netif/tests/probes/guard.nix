# Probe (2026-11-16, proof session): N25 lockout guard prototype.
#
{
  pkgs,
  lib,
  ...
}: let
  settings = {
    address,
    gateway,
    extra ? [],
  }: {
    interfaces.eth1 = {
      addresses = [address "2001:db8:1::2/64"] ++ extra;
      link = {
        kind = "physical";
        state = "up";
      };
    };
    routing.routes = [
      {
        to = "0.0.0.0/0";
        via = gateway;
      }
      {
        to = "::/0";
        via = "2001:db8:1::1";
      }
    ];
  };
  # ExecStartPost of ifstate.service. Arguments: this generation's rendered
  # config, then "<family>:<gateway>:<dev>" targets known at build time.
  guard = pkgs.writeShellScript "netif-guard" ''
    export PATH=${lib.makeBinPath [pkgs.coreutils pkgs.iputils pkgs.ndisc6 pkgs.iproute2 pkgs.jq]}
    state=/var/lib/netif-guard
    cfg=$1; shift
    wait=''${NETIF_GUARD_WAIT:-30}
    mkdir -p $state
    probe() { # family gateway dev
      if [ "$1" = 4 ]; then arping -q -c1 -w1 -I "$3" "$2"; else ndisc6 -q -1 -r1 -w1000 "$2" "$3" >/dev/null; fi
    }
    # static targets from the config, plus every learned default gateway
    targets="$* $(ip -j -4 route show default | jq -r '.[] | select(.gateway) | "4|\(.gateway)|\(.dev)"') $(ip -j -6 route show default | jq -r '.[] | select(.gateway) | "6|\(.gateway)|\(.dev)"')"
    targets=$(printf '%s\n' $targets | sort -u)
    failed=""
    for t in $targets; do
      IFS='|' read -r fam gw dev <<<"$t"
      end=$(( $(date +%s) + wait )); good=0
      while [ "$(date +%s)" -lt "$end" ]; do probe "$fam" "$gw" "$dev" && { good=1; break; }; sleep 1; done
      [ $good = 1 ] || failed="$failed $gw%$dev"
    done
    if [ -z "$failed" ]; then
      ln -sfn "$cfg" $state/last-good
      ln -sfn "$cfg" /nix/var/nix/gcroots/netif-guard-last-good
      echo "netif-guard: gateways answer; kept $cfg"
      exit 0
    fi
    echo "netif-guard: no layer-2 answer from:$failed" >&2
    prev=$(readlink $state/last-good 2>/dev/null || true)
    if [ -n "$prev" ] && [ "$prev" != "$cfg" ] && [ -e "$prev" ]; then
      echo "netif-guard: re-applying previous network config $prev" >&2
      ${lib.getExe pkgs.ifstate} --config "$prev" apply >&2
      echo "netif-guard: rolled back" >&2
    else
      echo "netif-guard: no previous network config to roll back to" >&2
    fi
    exit 1
  '';
  withGuard = {config, ...}: {
    systemd.services.ifstate.serviceConfig = {
      KillMode = "process";
      Environment = "NETIF_GUARD_WAIT=8";
      ExecStartPost = [
        "${guard} ${config.environment.etc."ifstate/ifstate.yaml".source} ${
          lib.concatMapStringsSep " " (r: "${
            if lib.hasInfix ":" r.via
            then "6"
            else "4"
          }|${r.via}|eth1")
          config.networking.ifstate.settings.routing.routes
        }"
      ];
    };
  };
in {
  name = "netif-guard-probe";
  nodes = {
    gw = {
      virtualisation.vlans = [1];
      boot.kernel.sysctl."net.ipv4.icmp_echo_ignore_all" = 1;
      networking = {
        firewall.enable = false;
        interfaces.eth1 = lib.mkForce {
          ipv4.addresses = [
            {
              address = "192.168.1.1";
              prefixLength = 24;
            }
          ];
          ipv6.addresses = [
            {
              address = "2001:db8:1::1";
              prefixLength = 64;
            }
          ];
        };
      };
    };
    host = {
      imports = [withGuard];
      virtualisation.vlans = [1];
      networking = {
        interfaces = lib.mkForce {};
        useDHCP = false;
        firewall.enable = false;
        ifstate = {
          enable = true;
          settings = lib.mkDefault (settings {
            address = "192.168.1.2/24";
            gateway = "192.168.1.1";
          });
        };
      };
      # A change that moves the machine off its subnet: the gateway is gone.
      specialisation.bad.configuration.networking.ifstate.settings = settings {
        address = "192.168.5.2/24";
        gateway = "192.168.5.1";
      };
      # A harmless change.
      specialisation.good.configuration.networking.ifstate.settings = settings {
        address = "192.168.1.2/24";
        gateway = "192.168.1.1";
        extra = ["192.168.1.3/24"];
      };
      environment.systemPackages = [pkgs.iputils pkgs.ndisc6 pkgs.jq];
    };
  };

  testScript = ''
    import time
    def show(cmd):
        rc, out = host.execute(cmd + " 2>&1")
        print(f"=== {cmd}\n{out}")
        return out
    def fact(name, value):
        print(f"FACT {name}: {value}")
    def ok(cmd):
        return host.execute(cmd)[0] == 0

    start_all()
    gw.wait_for_unit("multi-user.target")
    host.wait_for_unit("multi-user.target")
    show("journalctl -u ifstate --no-pager | tail -20; ip -br addr; ip route; ip -6 route; ls -l /var/lib/netif-guard /nix/var/nix/gcroots/")

    with subtest("layer-2 test works where ping does not"):
        fact("ping_gateway", ok("ping -c1 -W2 192.168.1.1"))
        fact("arping_gateway", ok("arping -c1 -w2 -I eth1 192.168.1.1"))
        fact("ndisc6_gateway", ok("ndisc6 -1 -r1 -w2000 2001:db8:1::1 eth1"))
        fact("boot_last_good_recorded", ok("test -L /var/lib/netif-guard/last-good"))
        first = host.succeed("readlink /var/lib/netif-guard/last-good").strip()
        fact("boot_unit_result", host.succeed("systemctl show -p Result --value ifstate.service").strip())

    with subtest("a bad change is rolled back"):
        t = time.time()
        rc, out = host.execute("/run/current-system/specialisation/bad/bin/switch-to-configuration test 2>&1")
        print(out)
        fact("bad_switch_exit_status", rc)
        fact("bad_switch_seconds", round(time.time() - t))
        show("journalctl -u ifstate --no-pager | tail -25; ip -br addr; ip route")
        fact("bad_unit_result", host.succeed("systemctl show -p Result --value ifstate.service").strip())
        fact("bad_old_address_back", ok("ip -4 addr show eth1 | grep 192.168.1.2/24"))
        fact("bad_new_address_gone", not ok("ip -4 addr show eth1 | grep 192.168.5.2"))
        fact("bad_default_route_back", ok("ip route show default | grep 'via 192.168.1.1'"))
        fact("bad_gateway_reachable_again", ok("arping -c1 -w2 -I eth1 192.168.1.1"))
        fact("bad_last_good_unchanged", host.succeed("readlink /var/lib/netif-guard/last-good").strip() == first)
        fact("bad_etc_points_at_bad_config", host.succeed("readlink -f /etc/ifstate/ifstate.yaml").strip() != first)
        # A plain restart re-tries the bad config and rolls back again.
        rc, _ = host.execute("systemctl restart ifstate.service")
        fact("bad_restart_fails_again_and_rolls_back", rc != 0 and ok("ip -4 addr show eth1 | grep 192.168.1.2/24"))

    with subtest("a good change is kept"):
        rc, out = host.execute("/run/booted-system/specialisation/good/bin/switch-to-configuration test 2>&1")
        print(out)
        fact("good_switch_exit_status", rc)
        fact("good_unit_result", host.succeed("systemctl show -p Result --value ifstate.service").strip())
        fact("good_new_address_present", ok("ip -4 addr show eth1 | grep 192.168.1.3/24"))
        fact("good_last_good_updated", host.succeed("readlink /var/lib/netif-guard/last-good").strip() != first)
        show("journalctl -u ifstate --no-pager | tail -8; ls -l /var/lib/netif-guard")

    with subtest("no previous config: fail loudly only"):
        host.succeed("rm /var/lib/netif-guard/last-good")
        rc, out = host.execute("/run/booted-system/specialisation/bad/bin/switch-to-configuration test 2>&1")
        fact("first_boot_bad_unit_result", host.succeed("systemctl show -p Result --value ifstate.service").strip())
        fact("first_boot_bad_stays_applied", ok("ip -4 addr show eth1 | grep 192.168.5.2"))
        show("journalctl -u ifstate --no-pager | tail -6")
    print("NETIF_GUARD_PROBE_DONE")
  '';
}
