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
# - IPv6 keeps the primary's prefix inside; on the backup the source
#   prefix is rewritten (stateful, so inbound stays closed).
# - Only the flows of the WAN that was left are deleted from conntrack.
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
    environment.systemPackages = [pkgs.nftables];
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


      def note(text):
          with open(log, "a") as file:
              file.write(text + "\n")


      try:
          sock = socket.create_connection((host, 7007), timeout=5)
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
        firewall.enable = false;
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
        nftables = {
          enable = true;
          tables.router = {
            family = "inet";
            content = ''
              chain steer {
                meta mark set 0x1
              }
              chain prerouting {
                type filter hook prerouting priority mangle;
                # Only what main would send to a WAN is steered. Marking
                # everything sent the router's own answers to LAN hosts
                # (neighbour advertisements too) out of the WAN, because
                # a WAN's table has no LAN route.
                iifname "eth3" fib daddr type unicast fib daddr oifname { "eth1", "eth2" } counter jump steer
                # a flow remembers the WAN it started on: a failover
                # deletes those flows and no other
                ct state new meta mark != 0x0 ct mark set meta mark
              }
              chain output {
                type route hook output priority mangle;
                ip6 daddr fe80::/10 return
                meta mark 0x0 fib daddr type unicast oifname { "eth1", "eth2" } counter jump steer
                ct state new meta mark != 0x0 ct mark set meta mark
              }
              chain forward {
                type filter hook forward priority filter; policy drop;
                ct state established,related accept
                iifname "eth3" oifname { "eth1", "eth2" } accept comment "internet"
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
        wan-health = {
          wantedBy = ["multi-user.target"];
          after = [
            "nftables.service"
            "ifstate.service"
          ];
          path = [
            pkgs.iputils
            pkgs.nftables
            pkgs.conntrack-tools
            pkgs.coreutils
          ];
          serviceConfig.Restart = "always";
          script = ''
            active=1; bad=0; good=0
            while sleep 1; do
              ok1=0; ok2=0
              ping -c1 -W1 -I eth1 -m 1 203.0.113.80 >/dev/null 2>&1 && ok1=1
              ping -c1 -W1 -I eth2 -m 2 203.0.113.80 >/dev/null 2>&1 && ok2=1
              want=$active
              if [ $ok1 = 1 ]; then bad=0; good=$((good + 1)); else good=0; bad=$((bad + 1)); fi
              if [ $active = 1 ] && [ $bad -ge 3 ] && [ $ok2 = 1 ]; then want=2; fi
              if [ $active = 2 ] && [ $good -ge 3 ]; then want=1; fi
              if [ $want != $active ]; then
                printf 'flush chain inet router steer\nadd rule inet router steer meta mark set %s\n' "$want" | nft -f -
                # only the flows that started on the WAN that was left
                conntrack -D -f ipv4 -m "$active" >/dev/null 2>&1 || true
                conntrack -D -f ipv6 -m "$active" >/dev/null 2>&1 || true
                echo "wan-health: active WAN $active -> $want (wan1 ok=$ok1, wan2 ok=$ok2)"
                active=$want
              fi
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
    MAIN_DEFAULTS = [("eth1", "dhcp", 100), ("eth2", "dhcp", 200)]

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
        return int(re.findall(r"meta mark set 0x0*([0-9a-f]+)", router.succeed("nft list chain inet router steer"))[0], 16)

    def snapshot():
        """Rules and routes: the steering must never change one."""
        return router.succeed("ip -4 rule; ip -6 rule; for t in main 301 302; do echo \"table $t\"; ip -4 route show table $t; ip -6 route show table $t; done")

    def main_defaults():
        return [(r["dev"], r["protocol"], r["metric"]) for r in json.loads(router.succeed("ip -j -4 route show default"))]

    def transitions():
        return int(router.succeed("journalctl -b -u wan-health --no-pager | grep -c 'wan-health: active WAN' || true").strip())

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

    def flow_start(name, host):
        client.succeed(f"systemd-run --unit flow-{name} /run/current-system/sw/bin/python3 /etc/flow.py '{host}' /tmp/flow-{name}.log")
        client.wait_until_succeeds(f"grep '^ok 2$' /tmp/flow-{name}.log >/dev/null", timeout=30)

    def flow_alive(name):
        """The same connection still carries data."""
        last = client.succeed(f"tail -n1 /tmp/flow-{name}.log").strip()
        assert last.startswith("ok "), f"flow {name}: {last}"
        client.wait_until_succeeds(f"test \"$(tail -n1 /tmp/flow-{name}.log | cut -d' ' -f2)\" -gt {last.split()[1]}", timeout=10)

    def flow_entry(family, source, target):
        """The conntrack id of the flow: equal ids, the same entry."""
        out = router.succeed(f"conntrack -L -f {family} -p tcp --dport 7007 -s {source} -d {target} -o id 2>/dev/null")
        ids = re.findall(r"\bid=(\d+)", out)
        assert len(ids) == 1, out
        return ids[0]

    def dropped(comment):
        out = router.succeed("nft list chain inet router forward")
        return int(re.findall(r"counter packets (\d+) bytes \d+ drop comment \"" + comment + "\"", out)[0])

    def primary_upstream(alive):
        """The ISP's box answers (DHCP, neighbours); nothing behind it does."""
        isp1.succeed(f"sysctl -w net.ipv4.conf.all.forwarding={alive} net.ipv6.conf.all.forwarding={alive}")

    def primary_box(alive):
        """The ISP's box is dead, the cable still has a carrier."""
        if alive:
            isp1.succeed("nft delete table netdev dead && systemctl start kea-dhcp4-server.service")
        else:
            isp1.succeed("systemctl stop kea-dhcp4-server.service && nft -f - <<< 'table netdev dead { chain deaf { type filter hook ingress device eth1 priority 0; policy drop; }; }'")

    with state_dump_on_failure([router, client, isp1, isp2, internet], extra=["journalctl -b --no-pager -u wan-health -u wan-routes -u netif-guard -u netif-online -u 'netif-dhcpcd*' | tail -n 80"]):
        start_all()
        for machine in [internet, isp1, isp2, router, client]:
            machine.wait_for_unit("multi-user.target", timeout=300)

        with subtest("versions"):
            print_versions(router, ["kernel", "ifstate", "dhcpcd", "nftables"])
            print_versions(isp1, ["kernel", "kea"])

        with subtest("both WANs have a lease; its gateway is in the WAN's table"):
            internet.wait_until_succeeds("ss -tln | grep ':80 ' >/dev/null", timeout=60)
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

        with subtest("both WANs up: traffic leaves through the primary"):
            # At boot the health check can see the backup's lease first and
            # start on the backup; three good checks bring it to the primary.
            router.wait_until_succeeds("nft list chain inet router steer | grep 'mark set 0x00000001' >/dev/null", timeout=30)
            boot = transitions()
            print(f"FINDING steering changes while the leases arrived at boot: {boot}")
            assert boot in (0, 2), boot
            both("primary", PRIMARY, 30)
            on(PRIMARY)
            router_own("::ffff:192.0.2.2", "2001:db8:a::2")
            # a ULA source is rewritten to the primary's prefix, host part kept
            assert client.succeed(ULA).strip() == "2001:db8:1000:1::10"
            # the health check reaches the target through each WAN
            router.succeed("ping -c1 -W1 -I eth1 -m 1 203.0.113.80 && ping -c1 -W1 -I eth2 -m 2 203.0.113.80 && ping -c1 -W1 -I eth2 -m 2 2001:db8:f::80")
            # Known gap (G16, open before code): a neighbour on the backup's
            # own subnet is steered to the primary.
            router.fail("ping -c1 -W1 198.51.100.1")

        with subtest("an IfState apply with both WANs up changes nothing"):
            apply_keeps(PRIMARY, 1)

        with subtest("long-lived flows: two to the router, one through the primary"):
            flow_start("router4", "192.168.10.1")
            flow_start("router6", "2001:db8:1000:1::1")
            flow_start("wan", "203.0.113.80")
            entries = (flow_entry("ipv4", "192.168.10.10", "192.168.10.1"), flow_entry("ipv6", "2001:db8:1000:1::10", "2001:db8:1000:1::1"))
            router.succeed("conntrack -L -f ipv4 -p tcp --dport 7007 -m 1 2>/dev/null | grep 203.0.113.80 >/dev/null")

        steady = snapshot()

        with subtest("the primary's upstream dies, its link and its DHCP stay: backup within 20 s"):
            primary_upstream(0)
            both("failover, dead upstream", BACKUP, 20)
            assert steer_mark() == 2, steer_mark()
            assert transitions() == boot + 1, transitions()
            router.succeed("journalctl -b -u wan-health --no-pager | grep 'active WAN 1 -> 2 (wan1 ok=0, wan2 ok=1)' >/dev/null")
            # the steering changed no rule and no route
            assert snapshot() == steady, f"{steady}\n---\n{snapshot()}"
            # IPv6 on the backup is the backup's prefix with the host part
            # kept (G16), also from a ULA source; the router's own follows
            on(BACKUP)
            assert client.succeed(ULA).strip() == "2001:db8:2000:1::10"
            router_own("::ffff:198.51.100.2", "2001:db8:b::2")

        with subtest("the failover cuts the flow through the dead WAN and no other"):
            for name in ["router4", "router6"]:
                flow_alive(name)
            now = (flow_entry("ipv4", "192.168.10.10", "192.168.10.1"), flow_entry("ipv6", "2001:db8:1000:1::10", "2001:db8:1000:1::1"))
            assert now == entries, f"conntrack entries of the flows to the router: {entries} before, {now} after"
            client.wait_until_succeeds("grep '^dead ' /tmp/flow-wan.log >/dev/null", timeout=60)
            observe("how the flow through the dead WAN ended", client, "tail -n2 /tmp/flow-wan.log")
            # no flow that started on the primary is left
            for family in ["ipv4", "ipv6"]:
                left = router.succeed(f"conntrack -L -f {family} -p tcp -m 1 2>/dev/null").strip()
                assert left == "", left

        with subtest("inbound from the backup's ISP is refused: real prefix, translated prefix, IPv4"):
            client.wait_until_succeeds("ss -tln | grep ':8080 ' >/dev/null", timeout=60)
            # the listener answers from inside
            router.succeed("curl -s --max-time 3 'http://[2001:db8:1000:1::10]:8080/' && curl -s --max-time 3 http://192.168.10.10:8080/")
            # an ISP that routes the inside prefixes at the router
            isp2.succeed("ip -6 route replace 2001:db8:1000::/60 via 2001:db8:b::2 && ip route replace 192.168.10.0/24 via 198.51.100.2")
            lan, transit = dropped("wan to lan"), dropped("wan to wan")
            for target in ["[2001:db8:1000:1::10]", "192.168.10.10"]:
                isp2.fail(f"curl -s --max-time 2 'http://{target}:8080/'")
            isp2.fail("ping -c1 -W1 2001:db8:1000:1::10")
            isp2.fail("ping -c1 -W1 192.168.10.10")
            lan_now = dropped("wan to lan")
            assert lan_now >= lan + 4, f"wan to lan drops: {lan} -> {lan_now}"
            # The translated address has no route to the LAN: the rewrite is
            # source-only and stateful. Main sends it to the other WAN, and
            # the router must not be a transit between its WANs.
            isp2.fail("curl -s --max-time 2 'http://[2001:db8:2000:1::10]:8080/'")
            isp2.fail("ping -c1 -W1 2001:db8:2000:1::10")
            transit_now = dropped("wan to wan")
            assert transit_now >= transit + 2, f"wan to wan drops: {transit} -> {transit_now}"
            assert dropped("wan to lan") == lan_now, "a packet to the translated prefix was routed to the LAN"
            print(f"FINDING inbound from the backup ISP: {lan_now - lan} packets dropped towards the LAN, {transit_now - transit} towards the other WAN")
            isp2.succeed("ip -6 route del 2001:db8:1000::/60 && ip route del 192.168.10.0/24")
            on(BACKUP)

        with subtest("an IfState apply while failed over changes nothing"):
            apply_keeps(BACKUP, 2)

        with subtest("a DHCP renewal on each WAN while failed over changes nothing"):
            wait_renewal("eth1")
            wait_renewal("eth2")
            assert snapshot() == steady, f"{steady}\n---\n{snapshot()}"
            assert steer_mark() == 2, steer_mark()
            on(BACKUP)

        with subtest("traffic stays on the backup for 8 s"):
            holds_for(client, f"{V4} | grep 198.51.100.2 >/dev/null && {V6} | grep 2001:db8:2000:1::10 >/dev/null", 8)
            assert transitions() == boot + 1, transitions()

        with subtest("the primary returns: primary within 15 s"):
            primary_upstream(1)
            both("failback", PRIMARY, 15)
            assert steer_mark() == 1, steer_mark()
            assert transitions() == boot + 2, transitions()
            assert snapshot() == steady, f"{steady}\n---\n{snapshot()}"
            on(PRIMARY)
            router_own("::ffff:192.0.2.2", "2001:db8:a::2")
            for name in ["router4", "router6"]:
                flow_alive(name)
            now = (flow_entry("ipv4", "192.168.10.10", "192.168.10.1"), flow_entry("ipv6", "2001:db8:1000:1::10", "2001:db8:1000:1::1"))
            assert now == entries, f"{entries} before, {now} after"

        with subtest("a primary that flaps every 3 s for 24 s: at most 1 steering change"):
            before = transitions()
            for _ in range(4):
                primary_upstream(0)
                time.sleep(3)
                primary_upstream(1)
                time.sleep(3)
            changes = transitions() - before
            print(f"FINDING 3 s down, 3 s up, 4 times: {changes} steering changes")
            assert changes <= 1, changes

        with subtest("a primary that returns for 1 s in every 8 s, 3 times: at most 1 steering change"):
            both("primary before the second pattern", PRIMARY, 15)
            before = transitions()
            for _ in range(3):
                primary_upstream(0)
                time.sleep(7)
                primary_upstream(1)
                time.sleep(1)
            changes = transitions() - before
            print(f"FINDING 7 s down, 1 s up, 3 times: {changes} steering changes")
            assert changes <= 1, changes
            both("failback after the flapping", PRIMARY, 15)
            assert snapshot() == steady, f"{steady}\n---\n{snapshot()}"

        with subtest("the primary's cable is pulled: backup within 20 s, primary within 60 s of the carrier"):
            router.send_monitor_command("set_link vlan1 off")
            # IPv4 moves before the health check does: dhcpcd empties the
            # primary's table, and a marked packet falls through to main
            both("failover, no carrier", BACKUP, 20)
            assert main_defaults() == MAIN_DEFAULTS[1:], main_defaults()
            # netif's guard stays green with a WAN down
            router.fail("systemctl is-failed netif-guard.service")
            router.send_monitor_command("set_link vlan1 on")
            both("failback, carrier", PRIMARY, 60)
            router.wait_until_succeeds("ip -4 route show table 301 default | grep 'via 192.0.2.1 dev eth1 proto dhcp' >/dev/null", timeout=30)
            assert main_defaults() == MAIN_DEFAULTS, main_defaults()

        with subtest("the primary's ISP dies, DHCP too: backup within 20 s, and it holds when the lease expires"):
            before = transitions()
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
            holds_for(client, f"{V4} | grep 198.51.100.2 >/dev/null && {V6} | grep 2001:db8:2000:1::10 >/dev/null", 8)
            router_own("::ffff:198.51.100.2", "2001:db8:b::2")
            assert steer_mark() == 2, steer_mark()
            assert transitions() == before + 1, f"{transitions()} steering changes, {before} before the ISP died"

        with subtest("why main keeps the backup's default: without it IPv4 is dead once the lease is gone"):
            router.succeed("systemctl stop wan-routes.service && ip -4 route del default dev eth2 metric 200")
            client.fail(V4)
            router.fail(V4)
            assert client.succeed(V6).strip() == BACKUP[1]
            router.succeed("systemctl start wan-routes.service")
            both("with the default back", BACKUP, 20)

        with subtest("a reboot with the primary's ISP dead: the router comes up on the backup within 30 s"):
            router.shutdown()
            router.start()
            router.wait_for_unit("wan-health.service", timeout=300)
            both("after the reboot, from the start of the health check", BACKUP, 30)
            router.wait_until_succeeds("journalctl -b -u wan-health --no-pager | grep 'active WAN 1 -> 2' >/dev/null", timeout=30)
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
            router_own("::ffff:192.0.2.2", "2001:db8:a::2")
            # the rules and routes of the first boot, and the guard is green again
            assert snapshot() == steady, f"{steady}\n---\n{snapshot()}"
            apply_keeps(PRIMARY, 1)
            assert router.succeed("systemctl --failed --no-legend --plain").strip() == ""

    print("GATEWAY_DUAL_WAN_OK")
  '';
}
