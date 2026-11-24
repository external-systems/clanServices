# gateway-dual-wan: one router, two WANs, upstream failure with the
# cable still plugged in (specs/gateway.md G16 and its mechanism, §10.10;
# specs/netif.md N21, U16).
#
#   client ── vlan 3 ── router ── vlan 1 ── isp1 ── vlan 4 ──┐
#                          └───── vlan 2 ── isp2 ── vlan 5 ── internet
#
# What the suite pins:
# - Failover changes no route. Each WAN has its own routing table (netif's
#   `routingPolicy.table`), IfState declares one fwmark rule per WAN and
#   family, and one nftables rule marks traffic for the active WAN. A
#   health check that pings through each WAN replaces that one rule.
# - That rule is the only record of the active WAN. It lives in a table
#   that the health check owns (`inet wan_steer`); `nftables.service`
#   never touches it. Every check reads the rule first, so a firewall
#   reload, a restart of the health check, a failed `nft` or a deleted
#   table cannot leave the rule and the health check disagreeing.
# - A flow keeps the WAN it started on: `ct mark` is restored into the
#   packet mark before anything is steered, and a flow that arrives on a
#   WAN is marked with that WAN (0x11, 0x12), so its replies leave there
#   whichever WAN is active. Only flows without a mark are steered.
# - Traffic to a WAN's own subnet is never steered.
# - The NixOS firewall is on, with `checkReversePath = "loose"`.
# - IPv6 keeps the primary's prefix inside; on the backup the source
#   prefix is rewritten (stateful, so inbound stays closed).
# - Only the steered flows of the WAN that was left are deleted from
#   conntrack (mark 1 or 2); flows that arrived on a WAN stay.
# - The WANs get their IPv4 address and gateway from DHCP (dhcpcd under
#   netif); IPv6 on the WANs is static. `wan-routes` stands in for the
#   amended N21: it copies a lease's gateway into the WAN's table and
#   keeps the backup's default in the main table at a higher metric.
# - A dead upstream, a dead ISP whose lease expires, a pulled cable, a
#   flapping primary, a reboot with the primary dead, IfState applies.
{
  inputs,
  lib,
  ...
}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  base = import ../../../ifstate.nix {inherit ifstateOverlay;};
  echo = import ./echo.nix;

  phys = addresses: {
    inherit addresses;
    link = {
      kind = "physical";
      state = "up";
    };
  };

  # An ISP: eth1 faces the customer, eth2 the internet. It hands out one
  # IPv4 address with a short lease, so a renewal and an expiry happen
  # inside the test.
  isp = {
    n,
    v4,
    v6,
    block,
  }: {pkgs, ...}: {
    imports = [base];
    virtualisation = {
      cores = 1;
      memorySize = 1024;
    };
    boot.kernel.sysctl = {
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };
    environment = {
      etc = {
        "flow.py".source = flow pkgs;
        "probe.py".source = probe pkgs;
      };
      systemPackages = [
        pkgs.curl
        pkgs.nftables
        pkgs.python3
        pkgs.tcpdump
      ];
    };
    services.kea.dhcp4 = {
      enable = true;
      settings = {
        interfaces-config = {
          interfaces = ["eth1"];
          service-sockets-max-retries = 30;
          service-sockets-retry-wait-time = 1000;
        };
        lease-database = {
          type = "memfile";
          persist = false;
        };
        valid-lifetime = 30;
        subnet4 = [
          {
            id = 1;
            subnet = "${v4}.0/24";
            interface = "eth1";
            # one address: the router's source rule names it
            pools = [{pool = "${v4}.2 - ${v4}.2";}];
            option-data = [
              {
                name = "routers";
                data = "${v4}.1";
              }
            ];
          }
        ];
      };
    };
    networking = {
      firewall.enable = false;
      ifstate.settings = {
        interfaces = {
          eth1 = phys [
            "${v4}.1/24"
            "${v6}::1/64"
          ];
          eth2 = phys [
            "10.${toString n}.0.1/30"
            "fd0${toString n}::1/64"
          ];
        };
        routing.routes = [
          {
            to = "203.0.113.80/32";
            via = "10.${toString n}.0.2";
          }
          {
            to = "2001:db8:f::80/128";
            via = "fd0${toString n}::2";
          }
          {
            to = "${block}::/60";
            via = "${v6}::2";
          }
        ];
      };
    };
  };

  wan = {
    interface,
    v4,
    v6,
    table,
  }: {
    inherit interface;
    zone = "wan";
    ra = false;
    # IPv4 from DHCP; netif renders no table default for a lease's
    # gateway today (N21, to amend): `wan-routes` on the router does.
    dhcp.ipv4 = true;
    static.ipv6 = ["${v6}::2/64"];
    # the static gateway lands in this table, not in main
    gateway.ipv6 = "${v6}::1";
    routingPolicy = {
      inherit table;
      # each link owns priority..priority+99
      priority = (table - 300) * 1000;
      from = [
        "${v4}.2/32"
        "${v6}::2/128"
      ];
    };
  };

  # One long-lived TCP connection: a line every half second, echoed back.
  # It never reconnects, so a growing count is the same flow.
  tcpEcho = pkgs: {
    wantedBy = ["multi-user.target"];
    serviceConfig.ExecStart = "${lib.getExe pkgs.socat} TCP6-LISTEN:7007,fork,reuseaddr EXEC:${lib.getExe' pkgs.coreutils "cat"}";
  };
  flow = pkgs:
    pkgs.writeText "flow.py" ''
      import socket
      import sys
      import time

      host, log = sys.argv[1], sys.argv[2]
      source = (sys.argv[3], 0) if len(sys.argv) > 3 else None


      def note(text):
          with open(log, "a") as file:
              file.write(text + "\n")


      try:
          sock = socket.create_connection((host, 7007), timeout=5, source_address=source)
          sock.settimeout(20)
          count = 0
          while True:
              sock.sendall(b"x\n")
              if not sock.recv(16):
                  raise ConnectionError("closed by the peer")
              count += 1
              note(f"ok {count}")
              time.sleep(0.5)
      except OSError as error:
          note(f"dead {type(error).__name__}: {error}")
    '';
  # One short TCP connection to the echo port, from a chosen source
  # address ("-": the kernel's choice). Prints what came back.
  probe = pkgs:
    pkgs.writeText "probe.py" ''
      import socket
      import sys

      target, source = sys.argv[1], sys.argv[2]
      sock = socket.create_connection((target, 7007), timeout=3, source_address=None if source == "-" else (source, 0))
      sock.settimeout(3)
      sock.sendall(b"hi\n")
      print(sock.recv(16).decode().strip())
    '';

  # The steering table. The health check owns it and loads it whole, with
  # the active WAN's mark in place of @MARK@; `nftables.service` deletes
  # and loads only the tables it declares, so it never touches this one.
  #
  # Marks: 1 and 2 are a flow steered out through WAN 1 or 2; 0x11 and
  # 0x12 a flow that arrived on WAN 1 or 2. The low four bits are the
  # packet mark that the fwmark rules read.
  steerTable = pkgs:
    pkgs.writeText "wan-steer.nft" ''
      table inet wan_steer
      delete table inet wan_steer
      table inet wan_steer {
        set wan4 {
          type ipv4_addr
          flags interval
          elements = { 192.0.2.0/24, 198.51.100.0/24 }
        }
        set wan6 {
          type ipv6_addr
          flags interval
          elements = { 2001:db8:a::/64, 2001:db8:b::/64 }
        }
        # the one rule that a failover replaces
        chain active {
          meta mark set @MARK@
        }
        chain steer {
          counter jump active
          # a flow remembers the WAN it started on
          ct mark set meta mark
        }
        chain prerouting {
          type filter hook prerouting priority mangle;
          # A flow that arrives on a WAN is answered through that WAN. The
          # packet itself gets no mark: a WAN's table has no LAN route.
          iifname { "eth1", "eth2" } ct state new ct mark set iifname map { "eth1" : 0x11, "eth2" : 0x12 }
          iifname { "eth1", "eth2" } return
          # a WAN's own subnet: where main sends it, whichever WAN is active
          ip daddr @wan4 return
          ip6 daddr @wan6 return
          # a flow keeps its WAN until the health check deletes its entry
          ct mark != 0x0 meta mark set ct mark and 0xf
          # Only what has no mark yet, and only what main would send to a
          # WAN, is steered. Marking everything sent the router's own
          # answers to LAN hosts (neighbour advertisements too) out of the
          # WAN, because a WAN's table has no LAN route.
          meta mark 0x0 fib daddr type unicast fib daddr oifname { "eth1", "eth2" } jump steer
        }
        chain output {
          type route hook output priority mangle;
          ip6 daddr fe80::/10 return
          ip daddr @wan4 return
          ip6 daddr @wan6 return
          ct mark != 0x0 meta mark set ct mark and 0xf
          meta mark 0x0 fib daddr type unicast oifname { "eth1", "eth2" } jump steer
          # a socket's own mark (the health check's pings)
          ct mark 0x0 meta mark != 0x0 ct mark set meta mark
        }
      }
    '';

  # Fault injection for the suite: `echo read` (or `write`) into the file
  # makes the health check's next listing (or next `nft -f`) fail once.
  nftOnce = pkgs:
    pkgs.writeShellScriptBin "nft" ''
      fail=/run/wan-health-nft-fail
      if [ -e "$fail" ]; then
        case "$(cat "$fail") $1" in
          "read list" | "write -f")
            rm "$fail"
            echo "nft: a failure injected by the suite" >&2
            exit 1
            ;;
        esac
      fi
      exec ${lib.getExe pkgs.nftables} "$@"
    '';
in {
  name = "gateway-dual-wan";

  clan = {
    directory = ./.;
    test.useContainers = false;
    inventory = {
      machines = {
        client = {};
        internet = {};
        isp1 = {};
        isp2 = {};
        router = {};
      };
      instances = {
        wan1 = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.router.settings.links.wan1 = wan {
            interface = "eth1";
            v4 = "192.0.2";
            v6 = "2001:db8:a";
            table = 301;
          };
        };
        wan2 = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.router.settings = {
            defaultRoute = {
              ipv4 = false;
              ipv6 = false;
            };
            links.wan2 = wan {
              interface = "eth2";
              v4 = "198.51.100";
              v6 = "2001:db8:b";
              table = 302;
            };
          };
        };
        lan = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines = {
            router.settings = {
              defaultRoute = {
                ipv4 = false;
                ipv6 = false;
              };
              links.lan = {
                interface = "eth3";
                zone = "home";
                ra = false;
                firewall.trust = true;
                static = {
                  ipv4 = ["192.168.10.1/24"];
                  ipv6 = [
                    "2001:db8:1000:1::1/64"
                    "fd00:10:1::1/64"
                  ];
                };
              };
            };
            client.settings.links.uplink = {
              interface = "eth1";
              ra = false;
              static = {
                ipv4 = ["192.168.10.10/24"];
                ipv6 = [
                  "2001:db8:1000:1::10/64"
                  "fd00:10:1::10/64"
                ];
              };
              gateway = {
                ipv4 = "192.168.10.1";
                ipv6 = "2001:db8:1000:1::1";
              };
            };
          };
        };
      };
    };
  };

  nodes = {
    router = {pkgs, ...}: {
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [
          1
          2
          3
        ];
      };
      clan._networkFacts.forwarding = true;
      boot.kernel.sysctl = {
        "net.ipv4.conf.all.forwarding" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
      };
      environment.systemPackages = [
        pkgs.conntrack-tools
        pkgs.curl
        pkgs.dhcpcd_latest
        pkgs.jq
      ];
      networking = {
        # A real router has a firewall. Loose reverse-path check: the
        # strict one looks the source up with the packet's mark and wants
        # the arrival link back. A steered packet from the LAN carries a
        # WAN's mark, and that WAN's table has no LAN route; a packet that
        # arrives on the backup has the primary's default in main. Strict
        # drops both (asserted below).
        firewall = {
          enable = true;
          checkReversePath = "loose";
          # the echo listener, also on the WANs: replies must leave by
          # the WAN that the connection came in on
          allowedTCPPorts = [7007];
        };
        # The router's own sockets need a route when they connect, before
        # any packet reaches the output hook that sets the mark: the
        # primary's default stays in main (first run: without it the
        # router's own traffic failed at once, and replies failed the
        # reverse-path check). IPv4: dhcpcd installs the primary's, and
        # `wan-routes` the backup's behind it.
        ifstate.settings.routing.routes = [
          {
            to = "::/0";
            via = "2001:db8:a::1";
            preference = 100;
          }
        ];
        # one rule per WAN and family; which mark a packet carries is
        # the only thing that changes on failover
        ifstate.settings.routing.rules = lib.concatMap (w:
          map (family: {
            inherit family;
            inherit (w) fwmark table;
            priority = 90;
          }) [
            "inet"
            "inet6"
          ]) [
          {
            fwmark = 1;
            table = 301;
          }
          {
            fwmark = 2;
            table = 302;
          }
        ];
        # `nftables.service` owns the zones and the NAT, and nothing of
        # the steering: a reload cannot move traffic.
        nftables = {
          enable = true;
          tables.router = {
            family = "inet";
            content = ''
              chain port-forward {
                type nat hook prerouting priority dstnat;
                iifname { "eth1", "eth2" } meta nfproto ipv4 tcp dport 8081 counter dnat ip to 192.168.10.10:8080
              }
              chain forward {
                type filter hook forward priority filter; policy drop;
                ct state established,related accept
                iifname "eth3" oifname { "eth1", "eth2" } accept comment "internet"
                iifname { "eth1", "eth2" } oifname "eth3" ct status dnat accept comment "port forward"
                iifname { "eth1", "eth2" } oifname "eth3" counter drop comment "wan to lan"
                iifname { "eth1", "eth2" } oifname { "eth1", "eth2" } counter drop comment "wan to wan"
              }
              chain postrouting {
                type nat hook postrouting priority srcnat;
                oifname { "eth1", "eth2" } meta nfproto ipv4 counter masquerade
                oifname "eth2" counter snat ip6 prefix to ip6 saddr map { 2001:db8:1000::/60 : 2001:db8:2000::/60, fd00:10:1::/64 : 2001:db8:2000:1::/64 }
                oifname "eth1" counter snat ip6 prefix to ip6 saddr map { fd00:10:1::/64 : 2001:db8:1000:1::/64 }
                # the router's own IPv6 traffic, bound to the primary's address
                oifname "eth2" ip6 saddr 2001:db8:a::2 counter masquerade
              }
            '';
          };
        };
      };
      systemd.services = {
        tcp-echo = tcpEcho pkgs;
        # Stands in for netif (N21, to amend). A lease's gateway goes
        # into the WAN's own table, and the backup's also into main
        # behind the primary's: when the primary's lease is gone, main
        # still has a default, which the steering rule and the
        # reverse-path check need. `proto dhcp`: IfState leaves it alone.
        wan-routes = {
          wantedBy = ["multi-user.target"];
          after = ["ifstate.service"];
          path = [
            pkgs.dhcpcd_latest
            pkgs.iproute2
            pkgs.gnugrep
            pkgs.gnused
            pkgs.coreutils
          ];
          serviceConfig.Restart = "always";
          script = ''
            sync() { # interface table [metric in main]
              [ -n "$(ip -4 -o addr show dev "$1" scope global)" ] || return 0
              gw=$(dhcpcd -f "/etc/netif/dhcpcd/$1.conf" -U -4 "$1" 2>/dev/null | sed -n "s/^routers='\{0,1\}\([0-9.]*\).*/\1/p" | head -n1)
              [ -n "$gw" ] || return 0
              ip -4 route show table "$2" default 2>/dev/null | grep "via $gw " >/dev/null \
                || ip -4 route replace default via "$gw" dev "$1" table "$2" proto dhcp || true
              [ -n "''${3:-}" ] || return 0
              ip -4 route show default dev "$1" | grep "metric $3" >/dev/null \
                || ip -4 route replace default via "$gw" dev "$1" metric "$3" proto dhcp || true
            }
            while :; do
              sync eth1 301
              sync eth2 302 200
              sleep 2
            done
          '';
        };
        # Three failed pings in a row move traffic off the primary; three
        # good ones move it back (the hysteresis). A ping is bound to its
        # WAN's link: with the mark alone it would fall through to main
        # when the WAN's table is empty, and a WAN without a lease would
        # look healthy.
        #
        # The rule in `chain active` is the state. Every round reads it,
        # so the check and the ruleset cannot disagree; the script keeps
        # only the two counters. A missing table is loaded again with the
        # WAN last seen. When `nft` fails, nothing else happens in that
        # round (no conntrack entry is deleted) and the next round tries
        # again.
        #
        # Start: on a boot (no table yet) failures do not count until the
        # primary has its first lease, or for `grace` seconds; a primary
        # that is dead at boot still fails over then. A restart finds the
        # table and counts at once.
        wan-health = {
          wantedBy = ["multi-user.target"];
          after = [
            "nftables.service"
            "ifstate.service"
          ];
          path = [
            (nftOnce pkgs)
            pkgs.iputils
            pkgs.iproute2
            pkgs.conntrack-tools
            pkgs.coreutils
            pkgs.gnused
          ];
          serviceConfig.Restart = "always";
          script = ''
            grace=20
            bad=0; good=0; last=1; loaded=0; counting=0
            started=$(date +%s)
            fill() { # mark
              sed "s/@MARK@/$1/" ${steerTable pkgs} | nft -f -
            }
            live() { # prints 1, 2 or none; fails when nft fails
              tables=$(nft list tables) || return 1
              case "$tables" in
                *"table inet wan_steer"*) ;;
                *)
                  echo none
                  return 0
                  ;;
              esac
              rule=$(nft list chain inet wan_steer active) || return 1
              case "$rule" in
                *"meta mark set 0x00000001"*) echo 1 ;;
                *"meta mark set 0x00000002"*) echo 2 ;;
                *) echo none ;;
              esac
            }
            while :; do
              if ! active=$(live); then
                echo "wan-health: nft failed, nothing read; trying again"
                sleep 1
                continue
              fi
              if [ "$active" = none ] || [ $loaded = 0 ]; then
                if [ "$active" != none ]; then
                  # a restart: the rules are loaded again, the active WAN stays
                  last=$active
                  counting=1
                fi
                if fill "$last"; then
                  loaded=1
                  echo "wan-health: steering table loaded, active WAN $last"
                else
                  echo "wan-health: nft failed, steering table not loaded; trying again"
                  sleep 1
                fi
                continue
              fi
              last=$active
              if [ $counting = 0 ]; then
                waited=$(( $(date +%s) - started ))
                if [ -n "$(ip -4 -o addr show dev eth1 scope global)" ]; then
                  counting=1
                  echo "wan-health: the primary has its lease after $waited s; failures count from now"
                elif [ $waited -ge $grace ]; then
                  counting=1
                  echo "wan-health: no lease on the primary after $grace s; failures count from now"
                fi
              fi
              ok1=0; ok2=0
              ping -c1 -W1 -I eth1 -m 1 203.0.113.80 >/dev/null 2>&1 && ok1=1
              ping -c1 -W1 -I eth2 -m 2 203.0.113.80 >/dev/null 2>&1 && ok2=1
              if [ $ok1 = 1 ]; then bad=0; good=$((good + 1)); else good=0; bad=$((bad + counting)); fi
              want=$active
              if [ "$active" = 1 ] && [ $bad -ge 3 ] && [ $ok2 = 1 ]; then want=2; fi
              if [ "$active" = 2 ] && [ $good -ge 3 ]; then want=1; fi
              if [ "$want" != "$active" ]; then
                if printf 'flush chain inet wan_steer active\nadd rule inet wan_steer active meta mark set %s\n' "$want" | nft -f -; then
                  # only the flows that were steered out through the WAN
                  # that was left; a flow that arrived on a WAN (0x11,
                  # 0x12) keeps its entry
                  conntrack -D -f ipv4 -m "$active" >/dev/null 2>&1 || true
                  conntrack -D -f ipv6 -m "$active" >/dev/null 2>&1 || true
                  echo "wan-health: active WAN $active -> $want (wan1 ok=$ok1, wan2 ok=$ok2)"
                else
                  echo "wan-health: nft failed, the active WAN is still $active; trying again"
                fi
              fi
              sleep 1
            done
          '';
        };
      };
    };

    client = {pkgs, ...}: {
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [3];
      };
      environment = {
        etc."flow.py".source = flow pkgs;
        systemPackages = [
          pkgs.curl
          pkgs.jq
          pkgs.python3
        ];
      };
      # a listener that a WAN must never reach
      networking.firewall.allowedTCPPorts = [8080];
      systemd.services.echo = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [8080]}";
      };
    };

    isp1 = {
      imports = [
        (isp {
          n = 1;
          v4 = "192.0.2";
          v6 = "2001:db8:a";
          block = "2001:db8:1000";
        })
      ];
      virtualisation.vlans = [
        1
        4
      ];
    };
    isp2 = {
      imports = [
        (isp {
          n = 2;
          v4 = "198.51.100";
          v6 = "2001:db8:b";
          block = "2001:db8:2000";
        })
      ];
      virtualisation.vlans = [
        2
        5
      ];
    };

    internet = {pkgs, ...}: {
      imports = [base];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [
          4
          5
        ];
      };
      networking = {
        firewall.enable = false;
        ifstate.settings = {
          interfaces = {
            eth1 = phys [
              "10.1.0.2/30"
              "fd01::2/64"
            ];
            eth2 = phys [
              "10.2.0.2/30"
              "fd02::2/64"
            ];
            svc0 = {
              addresses = [
                "203.0.113.80/32"
                "2001:db8:f::80/128"
              ];
              link = {
                kind = "dummy";
                state = "up";
              };
            };
          };
          routing.routes = [
            {
              to = "192.0.2.0/24";
              via = "10.1.0.1";
            }
            {
              to = "198.51.100.0/24";
              via = "10.2.0.1";
            }
            {
              to = "2001:db8:a::/64";
              via = "fd01::1";
            }
            {
              to = "2001:db8:1000::/48";
              via = "fd01::1";
            }
            {
              to = "2001:db8:b::/64";
              via = "fd02::1";
            }
            {
              to = "2001:db8:2000::/48";
              via = "fd02::1";
            }
          ];
        };
      };
      systemd.services = {
        echo = {
          wantedBy = ["multi-user.target"];
          serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [80]}";
        };
        tcp-echo = tcpEcho pkgs;
      };
    };
  };

  testScript = ''
    import json
    import re
    import time

    ${import ../../../../tests/suite-lib.nix}

    V4 = "curl -s --max-time 2 http://203.0.113.80/"
    V6 = "curl -s --max-time 2 'http://[2001:db8:f::80]/'"
    ULA = "curl -s --max-time 2 --interface fd00:10:1::10 'http://[2001:db8:f::80]/'"
    # what the server sees of the client: (IPv4, IPv6)
    PRIMARY = ("::ffff:192.0.2.2", "2001:db8:1000:1::10")
    BACKUP = ("::ffff:198.51.100.2", "2001:db8:2000:1::10")
    ON_BACKUP = f"{V4} | grep 198.51.100.2 >/dev/null && {V6} | grep 2001:db8:2000:1::10 >/dev/null"
    MAIN_DEFAULTS = [("eth1", "dhcp", 100), ("eth2", "dhcp", 200)]
    # Per WAN: its ISP, the router's addresses on it, the ISP's addresses
    # beyond the WAN's subnet, and the inside block that this ISP does not
    # route to the router by itself.
    WANS = [
        (isp1, "192.0.2.2", "2001:db8:a::2", "10.1.0.1", "fd01::1", "2001:db8:2000::/60"),
        (isp2, "198.51.100.2", "2001:db8:b::2", "10.2.0.1", "fd02::1", "2001:db8:1000::/60"),
    ]
    # the flows to the router, and the flows that arrived on a WAN: a
    # failover must keep them
    KEPT = [
        (client, "router4", "ipv4", "192.168.10.10", "192.168.10.1"),
        (client, "router6", "ipv6", "2001:db8:1000:1::10", "2001:db8:1000:1::1"),
        (isp1, "in1", "ipv4", "10.1.0.1", "192.0.2.2"),
        (isp2, "in2", "ipv4", "10.2.0.1", "198.51.100.2"),
    ]
    FLOW_PACKETS = "tcp port 7007 and (host 203.0.113.80 or host 2001:db8:f::80)"
    HEALTH_LOG = "journalctl -b -u wan-health --no-pager -o cat"

    def both(label, wanted, limit):
        """Seconds until the client leaves through a WAN in both families."""
        started = time.time()
        first = seconds_until(client, V4, limit=limit, wanted=wanted[0])
        assert first is not None, f"{label}: IPv4 not from {wanted[0]} within {limit} s"
        assert seconds_until(client, V6, limit=limit, wanted=wanted[1]) is not None, f"{label}: IPv6 not from {wanted[1]} within {limit} s"
        total = round(time.time() - started, 1)
        print(f"FINDING {label}: IPv4 from {wanted[0]} after {first} s, IPv6 from {wanted[1]} after {total} s (bound {limit} s each)")

    def on(wanted):
        """The client leaves through this WAN now, in both families."""
        seen = (client.succeed(V4).strip(), client.succeed(V6).strip())
        assert seen == wanted, f"the server saw {seen}, wanted {wanted}"

    def router_own(v4, v6):
        seen = (router.succeed(V4).strip(), router.succeed(V6).strip())
        assert seen == (v4, v6), f"the router's own traffic: the server saw {seen}"

    def steer_mark():
        return int(re.findall(r"meta mark set 0x0*([0-9a-f]+)", router.succeed("nft list chain inet wan_steer active"))[0], 16)

    def set_rule(mark):
        """What the health check does on a move, without the conntrack delete."""
        router.succeed(f"printf 'flush chain inet wan_steer active\\nadd rule inet wan_steer active meta mark set {mark}\\n' | nft -f -")

    def steering():
        """The health check's table, without its counters."""
        return router.succeed("nft -s list table inet wan_steer")

    def snapshot():
        """Rules and routes: the steering must never change one."""
        return router.succeed("ip -4 rule; ip -6 rule; for t in main 301 302; do echo \"table $t\"; ip -4 route show table $t; ip -6 route show table $t; done")

    def main_defaults():
        return [(r["dev"], r["protocol"], r["metric"]) for r in json.loads(router.succeed("ip -j -4 route show default"))]

    def moves():
        """Every change of the active WAN since the boot, in order."""
        return re.findall(r"active WAN (\d -> \d)", router.succeed(HEALTH_LOG))

    def health_log(text):
        return int(router.succeed(f"{HEALTH_LOG} | grep -c '{text}' || true").strip())

    def health_log_grows(text, count, timeout=30):
        router.wait_until_succeeds(f"test \"$({HEALTH_LOG} | grep -c '{text}')\" -gt {count}", timeout=timeout)

    def health_pid():
        return router.succeed("systemctl show -p MainPID --value wan-health.service").strip()

    def guard_passes():
        return int(router.succeed("journalctl -b -u netif-guard --no-pager | grep -c 'gateways and targets answer; kept' || true").strip())

    def apply_keeps(wanted, mark):
        """An IfState apply leaves the steering alone; netif's guard passes."""
        # stopped, so it cannot put back a route that the apply removed
        router.succeed("systemctl stop wan-routes.service")
        before, passes = snapshot(), guard_passes()
        router.succeed("systemctl restart ifstate.service")
        after = snapshot()
        router.succeed("systemctl start wan-routes.service")
        assert after == before, f"an IfState apply changed rules or routes:\n{before}\n---\n{after}"
        assert steer_mark() == mark, steer_mark()
        on(wanted)
        router.wait_until_succeeds(f"test \"$(journalctl -b -u netif-guard --no-pager | grep -c 'gateways and targets answer; kept')\" -gt {passes}", timeout=90)
        router.fail("systemctl is-failed netif-guard.service")

    def lifetime(dev):
        return json.loads(router.succeed(f"ip -j -4 addr show dev {dev} scope global"))[0]["addr_info"][0]["valid_life_time"]

    def wait_renewal(dev, limit=45):
        """A lease's remaining lifetime only grows when it is renewed."""
        last, end = lifetime(dev), time.time() + limit
        while time.time() < end:
            time.sleep(1)
            now = lifetime(dev)
            if now > last:
                return
            last = now
        raise AssertionError(f"no DHCP renewal on {dev} within {limit} s")

    def flow_start(machine, name, host, source=""):
        machine.succeed(f"systemd-run --unit flow-{name} /run/current-system/sw/bin/python3 /etc/flow.py '{host}' /tmp/flow-{name}.log {source}")
        machine.wait_until_succeeds(f"grep '^ok 2$' /tmp/flow-{name}.log >/dev/null", timeout=30)

    def flow_alive(machine, name, more=1):
        """The same connection still carries data: `more` further echoes."""
        last = machine.succeed(f"tail -n1 /tmp/flow-{name}.log").strip()
        assert last.startswith("ok "), f"flow {name}: {last}"
        machine.wait_until_succeeds(f"test \"$(tail -n1 /tmp/flow-{name}.log | cut -d' ' -f2)\" -ge {int(last.split()[1]) + more}", timeout=10 + more)

    def flow_entry(family, source, target):
        """The conntrack id of the flow: equal ids, the same entry."""
        # established only: the short probes from the same address leave
        # closed entries behind for two minutes
        out = router.succeed(f"conntrack -L -f {family} -p tcp --state ESTABLISHED --dport 7007 -s {source} -d {target} -o id 2>/dev/null")
        ids = re.findall(r"\bid=(\d+)", out)
        assert len(ids) == 1, out
        return ids[0]

    def kept_entries():
        return [flow_entry(family, source, target) for _, _, family, source, target in KEPT]

    def kept_alive():
        for machine, name, _, _, _ in KEPT:
            flow_alive(machine, name)

    def capture_start(isp, name):
        """The packets of the two flows through a WAN, on the ISP's side of it."""
        isp.succeed(f"systemd-run --unit cap-{name} /run/current-system/sw/bin/tcpdump -i eth1 -n -U -w /tmp/cap-{name}.pcap '{FLOW_PACKETS}'")
        isp.wait_until_succeeds(f"journalctl -u cap-{name} --no-pager | grep 'listening on eth1' >/dev/null", timeout=30)

    def capture_stop(isp, name):
        isp.succeed(f"systemctl stop cap-{name}")
        return int(isp.succeed(f"tcpdump -n -r /tmp/cap-{name}.pcap 2>/dev/null | wc -l").strip())

    def wan_addresses_answer(label):
        """A TCP connection to the router's address on each WAN, from the
        ISP's address on that WAN and from an address beyond it; and a
        port forward to the LAN host through each WAN."""
        for isp, v4, v6, far4, far6, _ in WANS:
            for target, source in [(v4, "-"), (v6, "-"), (v4, far4), (v6, far6)]:
                status, out = isp.execute(f"python3 /etc/probe.py {target} {source} 2>&1")
                assert status == 0 and out.strip() == "hi", f"{label}: {isp.name} to {target} from {source}: rc={status} {out}"
            seen = isp.succeed(f"curl -s --max-time 3 --interface {far4} http://{v4}:8081/").strip()
            assert seen == f"::ffff:{far4}", f"{label}: the port forward on {v4} from {far4}: the LAN host saw {seen}"
        print(f"FINDING {label}: both WANs' addresses answered TCP in both families, from on-link and routed sources, and the port forward answered on both")

    def own_subnets_answer():
        """Each WAN's own subnet, from the router and from a LAN host."""
        for machine in [router, client]:
            for target in ["192.0.2.1", "198.51.100.1", "2001:db8:a::1", "2001:db8:b::1"]:
                machine.succeed(f"ping -c1 -W2 {target}")

    def dropped(comment):
        out = router.succeed("nft list chain inet router forward")
        return int(re.findall(r"counter packets (\d+) bytes \d+ drop comment \"" + comment + "\"", out)[0])

    def inbound_refused(label, wan):
        """An ISP that routes the inside prefixes at the router gets nothing."""
        isp, v4, v6, _, _, block = wan
        client.wait_until_succeeds("ss -tln | grep ':8080 ' >/dev/null", timeout=60)
        # the listener answers from inside
        router.succeed("curl -s --max-time 3 'http://[2001:db8:1000:1::10]:8080/' && curl -s --max-time 3 http://192.168.10.10:8080/")
        isp.succeed(f"ip -6 route replace {block} via {v6} && ip route replace 192.168.10.0/24 via {v4}")
        lan, transit = dropped("wan to lan"), dropped("wan to wan")
        for target in ["[2001:db8:1000:1::10]", "192.168.10.10"]:
            isp.fail(f"curl -s --max-time 2 'http://{target}:8080/'")
        isp.fail("ping -c1 -W1 2001:db8:1000:1::10")
        isp.fail("ping -c1 -W1 192.168.10.10")
        lan_now = dropped("wan to lan")
        assert lan_now >= lan + 4, f"{label}: wan to lan drops: {lan} -> {lan_now}"
        # The translated address has no route to the LAN: the rewrite is
        # source-only and stateful. Main sends it to a WAN, and the router
        # must not be a transit between its WANs.
        isp.fail("curl -s --max-time 2 'http://[2001:db8:2000:1::10]:8080/'")
        isp.fail("ping -c1 -W1 2001:db8:2000:1::10")
        transit_now = dropped("wan to wan")
        assert transit_now >= transit + 2, f"{label}: wan to wan drops: {transit} -> {transit_now}"
        assert dropped("wan to lan") == lan_now, "a packet to the translated prefix was routed to the LAN"
        print(f"FINDING inbound from {isp.name}, {label}: {lan_now - lan} packets dropped towards the LAN, {transit_now - transit} towards a WAN")
        isp.succeed(f"ip -6 route del {block} && ip route del 192.168.10.0/24")

    def primary_upstream(alive):
        """The ISP's box answers (DHCP, neighbours); nothing behind it does."""
        isp1.succeed(f"sysctl -w net.ipv4.conf.all.forwarding={alive} net.ipv6.conf.all.forwarding={alive}")

    def flap(times, down, up):
        """The pattern runs on the ISP: a slow test driver cannot stretch it."""
        switch = "sysctl -qw net.ipv4.conf.all.forwarding={0} net.ipv6.conf.all.forwarding={0}"
        isp1.succeed(f"for i in $(seq {times}); do {switch.format(0)}; sleep {down}; {switch.format(1)}; sleep {up}; done")

    def primary_box(alive):
        """The ISP's box is dead, the cable still has a carrier."""
        if alive:
            isp1.succeed("nft delete table netdev dead && systemctl start kea-dhcp4-server.service")
        else:
            isp1.succeed("systemctl stop kea-dhcp4-server.service && nft -f - <<< 'table netdev dead { chain deaf { type filter hook ingress device eth1 priority 0; policy drop; }; }'")

    with state_dump_on_failure([router, client, isp1, isp2, internet], extra=["journalctl -b --no-pager -u wan-health -u wan-routes -u netif-guard -u netif-online -u 'netif-dhcpcd*' | tail -n 80"]):
        # The ISPs first: the router's boot is then the boot of a router
        # with two live WANs, and the start state can be asserted.
        for machine in [internet, isp1, isp2]:
            machine.start()
        for machine in [internet, isp1, isp2]:
            machine.wait_for_unit("multi-user.target", timeout=300)
        for machine in [isp1, isp2]:
            machine.wait_for_unit("kea-dhcp4-server.service", timeout=60)
        internet.wait_until_succeeds("ss -tln | grep ':80 ' >/dev/null", timeout=60)
        router.start()
        client.start()
        for machine in [router, client]:
            machine.wait_for_unit("multi-user.target", timeout=300)

        with subtest("versions"):
            print_versions(router, ["kernel", "ifstate", "dhcpcd", "nftables"])
            print_versions(isp1, ["kernel", "kea"])

        with subtest("both WANs have a lease; its gateway is in the WAN's table"):
            for unit in ["wan-health", "wan-routes", "tcp-echo"]:
                router.wait_for_unit(f"{unit}.service", timeout=60)
            observe("the lease as dhcpcd dumps it", router, "dhcpcd -f /etc/netif/dhcpcd/eth2.conf -U -4 eth2")
            router.wait_until_succeeds("ip -4 route show table 301 default | grep 'via 192.0.2.1 dev eth1 proto dhcp' >/dev/null", timeout=120)
            router.wait_until_succeeds("ip -4 route show table 302 default | grep 'via 198.51.100.1 dev eth2 proto dhcp' >/dev/null", timeout=120)
            router.succeed("ip -4 -o addr show dev eth1 | grep '192.0.2.2/24' >/dev/null && ip -4 -o addr show dev eth2 | grep '198.51.100.2/24' >/dev/null")
            router.succeed("ip -6 route show table 301 default | grep 'via 2001:db8:a::1 dev eth1' >/dev/null && ip -6 route show table 302 default | grep 'via 2001:db8:b::1 dev eth2' >/dev/null")
            # main: the primary's default from dhcpcd, the backup's behind it
            router.wait_until_succeeds("ip -4 route show default | grep 'dev eth2 proto dhcp metric 200' >/dev/null", timeout=30)
            assert main_defaults() == MAIN_DEFAULTS, main_defaults()
            router.succeed("grep -x nogateway /etc/netif/dhcpcd/eth2.conf && ! grep -x nogateway /etc/netif/dhcpcd/eth1.conf")
            for family in ["-4", "-6"]:
                rules = router.succeed(f"ip {family} rule")
                assert "fwmark 0x1 lookup 301" in rules and "fwmark 0x2 lookup 302" in rules, rules
            observe("router rules and tables", router, "ip rule; ip -6 rule; ip route show table 301; ip route show table 302; ip -6 route show table 301; ip -6 route show table 302; echo main:; ip route; ip -6 route | grep -v fe80")

        with subtest("start: no move while the leases arrived; failures count from the primary's first lease"):
            router.wait_until_succeeds(f"{HEALTH_LOG} | grep 'the primary has its lease after' >/dev/null", timeout=60)
            observe("the health check's start", router, f"{HEALTH_LOG} | head -n 5")
            router.wait_until_succeeds("nft list chain inet wan_steer active | grep 'mark set 0x00000001' >/dev/null", timeout=30)
            assert moves() == [], moves()
            assert health_log("steering table loaded, active WAN 1") == 1, router.succeed(HEALTH_LOG)

        with subtest("the firewall is on, its reverse-path check loose; one nftables table per owner"):
            tables = sorted(router.succeed("nft -j list tables | jq -r '.nftables[] | select(.table) | .table | .family + \" \" + .name'").splitlines())
            assert tables == ["inet nixos-fw", "inet router", "inet wan_steer"], tables
            # loose: the lookup has the source and the mark, not the arrival link
            rule = router.succeed("nft list chain inet nixos-fw rpfilter | grep 'fib saddr'").strip()
            assert rule.startswith("fib saddr . mark ") and rule.endswith("exists accept") and "iif" not in rule, rule
            router.succeed("nft list chain inet nixos-fw input | grep 'policy drop' >/dev/null")
            observe("the firewall's input rules", router, "nft list chain inet nixos-fw input; nft list chain inet nixos-fw input-allow")
            rp = {name: int(router.succeed(f"sysctl -n net.ipv4.conf.{name}.rp_filter").strip()) for name in ["all", "default", "eth1", "eth2", "eth3"]}
            print(f"FINDING the kernel's rp_filter on the router: {rp}; src_valid_mark: {router.succeed('sysctl -n net.ipv4.conf.all.src_valid_mark').strip()}")
            # the kernel uses the higher of `all` and the link's value; 1 is strict
            for dev in ["eth1", "eth2", "eth3"]:
                assert max(rp["all"], rp[dev]) != 1, rp

        with subtest("both WANs up: traffic leaves through the primary"):
            both("primary", PRIMARY, 30)
            on(PRIMARY)
            router_own("::ffff:192.0.2.2", "2001:db8:a::2")
            # a ULA source is rewritten to the primary's prefix, host part kept
            assert client.succeed(ULA).strip() == "2001:db8:1000:1::10"
            # the health check reaches the target through each WAN
            router.succeed("ping -c1 -W1 -I eth1 -m 1 203.0.113.80 && ping -c1 -W1 -I eth2 -m 2 203.0.113.80 && ping -c1 -W1 -I eth2 -m 2 2001:db8:f::80")

        with subtest("primary active: a WAN's own subnet answers the router and a LAN host, on both WANs"):
            own_subnets_answer()

        with subtest("primary active: each WAN's address answers on that WAN; a port forward too"):
            wan_addresses_answer("primary active")

        with subtest("why ct mark is restored: without that rule, a connection to the backup's address dies"):
            loads = health_log("steering table loaded")
            router.succeed("nft delete rule inet wan_steer output handle $(nft -a list chain inet wan_steer output | sed -n 's/.*meta mark set ct mark.*# handle \\([0-9]*\\)$/\\1/p')")
            # the answer is steered to the primary, with the backup's source
            isp2.fail("python3 /etc/probe.py 198.51.100.2 10.2.0.1")
            isp2.fail("python3 /etc/probe.py 2001:db8:b::2 fd02::1")
            # the primary's own address still answers: main sends it there
            isp1.succeed("python3 /etc/probe.py 192.0.2.2 10.1.0.1")
            # a restart of the health check loads its table again
            before = steering()
            router.succeed("systemctl restart wan-health.service")
            health_log_grows("steering table loaded, active WAN 1", loads)
            assert steering() != before, "the restart did not load the table again"
            wan_addresses_answer("primary active, after a restart of the health check")
            assert moves() == [], moves()
            on(PRIMARY)

        with subtest("primary active: inbound from the primary's ISP is refused: real prefix, translated prefix, IPv4"):
            inbound_refused("primary active", WANS[0])
            on(PRIMARY)

        with subtest("an IfState apply with both WANs up changes nothing"):
            apply_keeps(PRIMARY, 1)

        with subtest("long-lived flows: two to the router, one arriving on each WAN, two through the primary"):
            flow_start(client, "router4", "192.168.10.1")
            flow_start(client, "router6", "2001:db8:1000:1::1")
            flow_start(isp1, "in1", "192.0.2.2", "10.1.0.1")
            flow_start(isp2, "in2", "198.51.100.2", "10.2.0.1")
            flow_start(client, "wan", "203.0.113.80")
            flow_start(client, "wan6", "2001:db8:f::80")
            entries = kept_entries()
            # steered flows carry the WAN's number, arriving flows 0x11 and 0x12
            router.succeed("conntrack -L -f ipv4 -p tcp --dport 7007 -m 1 2>/dev/null | grep 203.0.113.80 >/dev/null")
            router.succeed("conntrack -L -f ipv6 -p tcp --dport 7007 -m 1 2>/dev/null | grep 2001:db8:f::80 >/dev/null")
            router.succeed("conntrack -L -f ipv4 -p tcp --dport 7007 -m 17 2>/dev/null | grep 10.1.0.1 >/dev/null")
            router.succeed("conntrack -L -f ipv4 -p tcp --dport 7007 -m 18 2>/dev/null | grep 10.2.0.1 >/dev/null")

        steady = snapshot()

        with subtest("the rule changes and no entry is deleted: an established flow keeps its WAN, a new one takes the other"):
            router.succeed("systemctl stop wan-health.service")
            loads = health_log("steering table loaded")
            capture_start(isp1, "keep")
            capture_start(isp2, "keep")
            set_rule(2)
            on(BACKUP)
            for name in ["wan", "wan6"]:
                flow_alive(client, name, more=6)
            kept_alive()
            set_rule(1)
            on(PRIMARY)
            through = (capture_stop(isp1, "keep"), capture_stop(isp2, "keep"))
            print(f"FINDING packets of the two established flows while the rule said backup: {through[0]} through the primary's ISP, {through[1]} through the backup's")
            assert through[0] > 0 and through[1] == 0, through
            router.succeed("systemctl start wan-health.service")
            health_log_grows("steering table loaded, active WAN 1", loads)
            assert moves() == [], moves()

        with subtest("the primary's upstream dies, its link and its DHCP stay: backup within 20 s"):
            primary_upstream(0)
            both("failover, dead upstream", BACKUP, 20)
            assert steer_mark() == 2, steer_mark()
            assert moves() == ["1 -> 2"], moves()
            router.succeed(f"{HEALTH_LOG} | grep 'active WAN 1 -> 2 (wan1 ok=0, wan2 ok=1)' >/dev/null")
            # the steering changed no rule and no route
            assert snapshot() == steady, f"{steady}\n---\n{snapshot()}"
            # IPv6 on the backup is the backup's prefix with the host part
            # kept (G16), also from a ULA source; the router's own follows
            on(BACKUP)
            assert client.succeed(ULA).strip() == "2001:db8:2000:1::10"
            router_own("::ffff:198.51.100.2", "2001:db8:b::2")

        with subtest("the failover resets the flows through the dead WAN within 30 s and cuts no other"):
            kept_alive()
            now = kept_entries()
            assert now == entries, f"conntrack entries of the flows to the router and from the WANs: {entries} before, {now} after"
            for name in ["wan", "wan6"]:
                took = seconds_until(client, f"grep '^dead ' /tmp/flow-{name}.log", limit=30)
                assert took is not None, f"flow {name} was not cut within 30 s"
                last = client.succeed(f"tail -n1 /tmp/flow-{name}.log").strip()
                print(f"FINDING flow {name} through the dead WAN ended {took} s after the failover was seen: {last}")
                # a reset from the server, not a timeout
                assert last.startswith("dead ConnectionResetError"), last
            # no flow that was steered to the primary is left
            for family in ["ipv4", "ipv6"]:
                left = router.succeed(f"conntrack -L -f {family} -p tcp -m 1 2>/dev/null").strip()
                assert left == "", left

        with subtest("backup active: each WAN's address answers on that WAN; a WAN's own subnet too"):
            wan_addresses_answer("backup active")
            own_subnets_answer()

        with subtest("backup active: inbound from the backup's ISP is refused: real prefix, translated prefix, IPv4"):
            inbound_refused("backup active", WANS[1])
            on(BACKUP)

        with subtest("why the reverse-path check is loose: the strict rule drops steered traffic"):
            router.succeed("nft insert rule inet nixos-fw rpfilter fib saddr . mark . iif oif missing counter drop comment '\"strict\"'")
            client.fail(V4)
            client.fail(V6)
            observe("what the strict rule dropped", router, "nft list chain inet nixos-fw rpfilter")
            router.succeed("nft delete rule inet nixos-fw rpfilter handle $(nft -a list chain inet nixos-fw rpfilter | sed -n 's/.*comment \"strict\" # handle \\([0-9]*\\)$/\\1/p')")
            both("with the loose check back", BACKUP, 10)
            assert moves() == ["1 -> 2"], moves()

        with subtest("an IfState apply while failed over changes nothing"):
            apply_keeps(BACKUP, 2)

        with subtest("a DHCP renewal on each WAN while failed over changes nothing"):
            wait_renewal("eth1")
            wait_renewal("eth2")
            assert snapshot() == steady, f"{steady}\n---\n{snapshot()}"
            assert steer_mark() == 2, steer_mark()
            on(BACKUP)

        with subtest("traffic stays on the backup for 8 s"):
            holds_for(client, ON_BACKUP, 8)
            assert moves() == ["1 -> 2"], moves()

        with subtest("the primary returns: primary within 15 s; the flow that arrived on the backup stays"):
            primary_upstream(1)
            both("failback", PRIMARY, 15)
            assert steer_mark() == 1, steer_mark()
            assert moves() == ["1 -> 2", "2 -> 1"], moves()
            assert snapshot() == steady, f"{steady}\n---\n{snapshot()}"
            on(PRIMARY)
            router_own("::ffff:192.0.2.2", "2001:db8:a::2")
            kept_alive()
            now = kept_entries()
            assert now == entries, f"{entries} before, {now} after"

        with subtest("nft fails once on the swap: the failover happens a check later, within 25 s"):
            pid = health_pid()
            router.succeed("echo write > /run/wan-health-nft-fail")
            primary_upstream(0)
            both("failover, nft failed once", BACKUP, 25)
            router.succeed(f"{HEALTH_LOG} | grep 'nft failed, the active WAN is still 1' >/dev/null && test ! -e /run/wan-health-nft-fail")
            assert moves() == ["1 -> 2", "2 -> 1", "1 -> 2"], moves()
            assert steer_mark() == 2, steer_mark()
            assert health_pid() == pid, "the health check restarted"

        with subtest("nft fails once on a read: nothing moves"):
            fails = health_log("nft failed, nothing read")
            router.succeed("echo read > /run/wan-health-nft-fail")
            health_log_grows("nft failed, nothing read", fails)
            on(BACKUP)
            assert steer_mark() == 2, steer_mark()
            assert health_pid() == pid, "the health check restarted"

        with subtest("nftables.service reloads and restarts while failed over: traffic stays on the backup for 6 s"):
            table = steering()
            for verb in ["reload", "restart"]:
                router.succeed(f"systemctl {verb} nftables.service")
                assert steering() == table, f"a {verb} of nftables.service changed the steering table"
                on(BACKUP)
            holds_for(client, ON_BACKUP, 6)
            assert steer_mark() == 2, steer_mark()
            flow_alive(isp2, "in2")
            wan_addresses_answer("backup active, after a restart of nftables.service")

        with subtest("the health check restarts while failed over, the primary still dead: traffic stays on the backup for 8 s"):
            loads = health_log("steering table loaded, active WAN 2")
            router.succeed("systemctl restart wan-health.service")
            holds_for(client, ON_BACKUP, 8)
            assert health_log("steering table loaded, active WAN 2") == loads + 1, router.succeed(HEALTH_LOG)
            assert steering() == table, "the restart loaded a different table"
            pid = health_pid()

        with subtest("the steering table is deleted while failed over: loaded again with the backup within 10 s"):
            router.succeed("nft delete table inet wan_steer")
            took = seconds_until(router, "nft list chain inet wan_steer active | grep 'mark set 0x00000002'", limit=10)
            assert took is not None, "the steering table did not come back within 10 s"
            print(f"FINDING the deleted steering table was loaded again with the backup's mark after {took} s (bound 10 s)")
            both("after the table was deleted", BACKUP, 10)
            assert steering() == table
            assert health_pid() == pid, "the health check restarted"
            assert moves() == ["1 -> 2", "2 -> 1", "1 -> 2"], moves()

        with subtest("the primary recovers while the health check is stopped: started again, it moves back within 15 s"):
            router.succeed("systemctl stop wan-health.service")
            primary_upstream(1)
            router.wait_until_succeeds("ping -c1 -W1 -I eth1 -m 1 203.0.113.80", timeout=30)
            # the rule is the state: nobody moved it
            on(BACKUP)
            router.succeed("systemctl start wan-health.service")
            both("failback after a start on the backup", PRIMARY, 15)
            assert steer_mark() == 1, steer_mark()
            assert moves() == ["1 -> 2", "2 -> 1", "1 -> 2", "2 -> 1"], moves()
            assert snapshot() == steady, f"{steady}\n---\n{snapshot()}"
            router_own("::ffff:192.0.2.2", "2001:db8:a::2")

        with subtest("a primary that flaps every 3 s for 24 s: no steering change"):
            before = moves()
            flap(4, 3, 3)
            changes = moves()[len(before):]
            print(f"FINDING 3 s down, 3 s up, 4 times: steering changes {changes}")
            assert changes == [], changes
            on(PRIMARY)

        with subtest("a primary that returns for 1 s in every 8 s, 3 times: one move to the backup, one back after it"):
            before = moves()
            flap(3, 7, 1)
            both("failback after the flapping", PRIMARY, 15)
            changes = moves()[len(before):]
            print(f"FINDING 7 s down, 1 s up, 3 times, then up: steering changes {changes}")
            assert changes == ["1 -> 2", "2 -> 1"], changes
            assert snapshot() == steady, f"{steady}\n---\n{snapshot()}"

        with subtest("the primary's cable is pulled: backup within 20 s"):
            router.send_monitor_command("set_link vlan1 off")
            # IPv4 moves before the health check does: dhcpcd empties the
            # primary's table, and a marked packet falls through to main
            both("failover, no carrier", BACKUP, 20)
            assert main_defaults() == MAIN_DEFAULTS[1:], main_defaults()
            router.wait_until_succeeds("nft list chain inet wan_steer active | grep 'mark set 0x00000002' >/dev/null", timeout=20)
            # Nothing has run netif's guard since the cable went: it runs at
            # boot and after an IfState apply. Its state says nothing yet.
            router.fail("systemctl is-failed netif-guard.service")

        with subtest("the cable out and an IfState apply: the guard fails, rolls nothing back, traffic stays on the backup"):
            router.succeed("systemctl stop wan-routes.service")
            before = snapshot()
            status, out = router.execute("systemctl restart ifstate.service 2>&1")
            after = snapshot()
            router.succeed("systemctl start wan-routes.service")
            print(f"FINDING an IfState apply with the primary's cable out: rc={status} {out.strip()}")
            assert status == 0, out
            assert after == before, f"the apply changed rules or routes:\n{before}\n---\n{after}"
            took = seconds_until(router, "systemctl is-failed netif-guard.service", limit=90)
            assert took is not None, "netif-guard did not fail within 90 s"
            print(f"FINDING netif-guard failed {took} s after the apply (bound 90 s)")
            observe("the guard's verdict", router, "journalctl -b -u netif-guard --no-pager | tail -n 8")
            router.succeed("journalctl -b -u netif-guard --no-pager | grep 'no DHCP default route on eth1; no answer from 2001:db8:a::1 on eth1' >/dev/null")
            router.succeed("journalctl -b -u netif-guard --no-pager | grep 'there is no earlier network configuration to roll back to' >/dev/null")
            assert snapshot() == before, f"the guard changed rules or routes:\n{before}\n---\n{snapshot()}"
            assert steer_mark() == 2, steer_mark()
            on(BACKUP)

        with subtest("the cable returns: primary within 60 s; the guard stays failed until the next apply"):
            router.send_monitor_command("set_link vlan1 on")
            both("failback, carrier", PRIMARY, 60)
            router.wait_until_succeeds("ip -4 route show table 301 default | grep 'via 192.0.2.1 dev eth1 proto dhcp' >/dev/null", timeout=30)
            assert main_defaults() == MAIN_DEFAULTS, main_defaults()
            router.succeed("systemctl is-failed netif-guard.service")
            apply_keeps(PRIMARY, 1)

        with subtest("the primary's ISP dies, DHCP too: backup within 20 s, and it holds when the lease expires"):
            before = moves()
            primary_box(False)
            both("failover, dead ISP", BACKUP, 20)
            expired = seconds_until(router, "test -z \"$(ip -4 -o addr show dev eth1 scope global)\"", limit=90)
            assert expired is not None, "the primary's lease did not expire within 90 s"
            print(f"FINDING the primary's lease (30 s) expired {expired} s after the failover")
            # the lease took its address, its default in main and its table's default
            assert router.succeed("ip -4 route show table 301").strip() == "", router.succeed("ip -4 route show table 301")
            assert main_defaults() == MAIN_DEFAULTS[1:], main_defaults()
            for family in ["-4", "-6"]:
                rules = router.succeed(f"ip {family} rule")
                assert "fwmark 0x1 lookup 301" in rules and "fwmark 0x2 lookup 302" in rules, rules
            holds_for(client, ON_BACKUP, 8)
            router_own("::ffff:198.51.100.2", "2001:db8:b::2")
            assert steer_mark() == 2, steer_mark()
            assert moves() == [*before, "1 -> 2"], f"{moves()}, {before} before the ISP died"

        with subtest("why main keeps the backup's default: without it IPv4 is dead once the lease is gone"):
            router.succeed("systemctl stop wan-routes.service && ip -4 route del default dev eth2 metric 200")
            client.fail(V4)
            router.fail(V4)
            assert client.succeed(V6).strip() == BACKUP[1]
            router.succeed("systemctl start wan-routes.service")
            both("with the default back", BACKUP, 20)

        with subtest("a reboot with the primary's ISP dead: no lease for 20 s, then the backup, within 75 s"):
            router.shutdown()
            router.start()
            router.wait_for_unit("wan-health.service", timeout=300)
            # IPv4 falls through to main at once (the primary's table is
            # empty); IPv6 waits for the health check: 20 s without a
            # lease, then three failed checks
            both("after the reboot, from the start of the health check", BACKUP, 75)
            router.wait_until_succeeds(f"{HEALTH_LOG} | grep 'active WAN 1 -> 2' >/dev/null", timeout=30)
            router.succeed(f"{HEALTH_LOG} | grep 'no lease on the primary after 20 s; failures count from now' >/dev/null")
            assert moves() == ["1 -> 2"], moves()
            assert steer_mark() == 2, steer_mark()
            on(BACKUP)
            router_own("::ffff:198.51.100.2", "2001:db8:b::2")
            router.wait_for_unit("multi-user.target", timeout=300)
            assert main_defaults() == MAIN_DEFAULTS[1:], main_defaults()
            # FINDING contradicts specs/gateway.md §10.10 ("netif's guard
            # stayed green with a WAN down"): that holds while the dead
            # WAN's gateway still answers its neighbours. With the ISP's box
            # dead the guard fails: it wants a DHCP default on the primary
            # and an answer from every gateway. Here the configuration is
            # the last good one, so nothing is rolled back; a new one would
            # be.
            router.wait_until_succeeds("systemctl is-failed netif-guard.service", timeout=90)
            router.succeed("journalctl -b -u netif-guard --no-pager | grep 'no DHCP default route on eth1; no answer from 2001:db8:a::1 on eth1' >/dev/null")
            failed = router.succeed("systemctl --failed --no-legend --plain | cut -d' ' -f1").split()
            assert failed == ["netif-guard.service"], failed
            on(BACKUP)

        with subtest("the primary's ISP returns: lease, table and primary within 90 s"):
            primary_box(True)
            both("failback, new lease", PRIMARY, 90)
            router.succeed("ip -4 route show table 301 default | grep 'via 192.0.2.1 dev eth1 proto dhcp' >/dev/null")
            assert main_defaults() == MAIN_DEFAULTS, main_defaults()
            assert steer_mark() == 1, steer_mark()
            assert moves() == ["1 -> 2", "2 -> 1"], moves()
            router_own("::ffff:192.0.2.2", "2001:db8:a::2")
            # the rules and routes of the first boot, and the guard is green again
            assert snapshot() == steady, f"{steady}\n---\n{snapshot()}"
            apply_keeps(PRIMARY, 1)
            assert router.succeed("systemctl --failed --no-legend --plain").strip() == ""

        with subtest("only the health check's one target is down, both WANs fine: no move in 10 s"):
            before = moves()
            internet.succeed("sysctl -w net.ipv4.icmp_echo_ignore_all=1")
            router.wait_until_fails("ping -c1 -W1 -I eth1 -m 1 203.0.113.80", timeout=10)
            router.fail("ping -c1 -W1 -I eth2 -m 2 203.0.113.80")
            holds_for(client, f"{V4} | grep 192.0.2.2 >/dev/null && {V6} | grep 2001:db8:1000:1::10 >/dev/null", 10)
            assert moves() == before, moves()
            assert steer_mark() == 1, steer_mark()
            internet.succeed("sysctl -w net.ipv4.icmp_echo_ignore_all=0")
            router.wait_until_succeeds("ping -c1 -W1 -I eth1 -m 1 203.0.113.80", timeout=10)

        with subtest("report: 30 % packet loss behind the primary for 60 s"):
            before = moves()
            isp1.succeed("tc qdisc add dev eth2 root netem loss 30% && sleep 60; tc qdisc del dev eth2 root")
            changes = moves()[len(before):]
            print(f"FINDING 30 % loss towards the internet behind the primary for 60 s: {len(changes)} steering changes {changes} (reported, not asserted)")
            both("after the loss", PRIMARY, 30)
            assert snapshot() == steady, f"{steady}\n---\n{snapshot()}"
            assert router.succeed("systemctl --failed --no-legend --plain").strip() == ""

    print("GATEWAY_DUAL_WAN_OK")
  '';
}
