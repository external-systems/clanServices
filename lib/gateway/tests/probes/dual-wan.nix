# Probe for specs/gateway.md G16 and netif N21 (U16): one router, two
# WANs, upstream failure with the cable still plugged in.
#
#   client ── vlan 3 ── router ── vlan 1 ── isp1 ── vlan 4 ──┐
#                          └───── vlan 2 ── isp2 ── vlan 5 ── internet
#
# The mechanism under test changes no route: each WAN has its own routing
# table (netif's `routingPolicy.table`), IfState declares one fwmark rule
# per WAN, and one nftables rule marks traffic for the active WAN. A
# health check that pings through each WAN replaces that one rule.
# IPv6 keeps the primary's prefix inside; on the backup the source prefix
# is rewritten.
#
# Addresses are static: the probe is about failover, not leases.
#
# Lines that start with FINDING are the result.
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

  # An ISP: eth1 faces the customer, eth2 the internet.
  isp = {
    n,
    block,
  }: {
    imports = [base];
    virtualisation = {
      cores = 1;
      memorySize = 1024;
    };
    boot.kernel.sysctl = {
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };
    networking = {
      firewall.enable = false;
      ifstate.settings = {
        interfaces = {
          eth1 = phys [
            (
              if n == 1
              then "192.0.2.1/24"
              else "198.51.100.1/24"
            )
            "2001:db8:${
              if n == 1
              then "a"
              else "b"
            }::1/64"
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
            via = "2001:db8:${
              if n == 1
              then "a"
              else "b"
            }::2";
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
    static = {
      ipv4 = ["${v4}.2/24"];
      ipv6 = ["${v6}::2/64"];
    };
    gateway = {
      ipv4 = "${v4}.1";
      ipv6 = "${v6}::1";
    };
    # the gateway lands in this table, not in main
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
in {
  name = "probe-dual-wan";

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
        pkgs.jq
      ];
      networking = {
        firewall.enable = false;
        # one rule per WAN and family; which mark a packet carries is
        # the only thing that changes on failover
        # The router's own sockets need a route when they connect, before
        # any packet reaches the output hook that sets the mark: the
        # primary's default stays in main (first run: without it the
        # router's own traffic failed at once, and replies failed the
        # reverse-path check).
        ifstate.settings.routing.routes = [
          {
            to = "0.0.0.0/0";
            via = "192.0.2.1";
            preference = 100;
          }
          {
            to = "::/0";
            via = "2001:db8:a::1";
            preference = 100;
          }
        ];
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
                iifname "eth3" fib daddr type != local counter jump steer
              }
              chain output {
                type route hook output priority mangle;
                meta mark 0x0 fib daddr type != local counter jump steer
              }
              chain postrouting {
                type nat hook postrouting priority srcnat;
                oifname { "eth1", "eth2" } meta nfproto ipv4 counter masquerade
                oifname "eth2" counter snat ip6 prefix to ip6 saddr map { 2001:db8:1000::/60 : 2001:db8:2000::/60 }
                # the router's own IPv6 traffic, bound to the primary's address
                oifname "eth2" ip6 saddr 2001:db8:a::2 counter masquerade
              }
            '';
          };
        };
      };
      # Three failed pings in a row move traffic off a WAN; three good
      # ones move it back to the primary.
      systemd.services.wan-health = {
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
            ping -c1 -W1 -m 1 203.0.113.80 >/dev/null 2>&1 && ok1=1
            ping -c1 -W1 -m 2 203.0.113.80 >/dev/null 2>&1 && ok2=1
            want=$active
            if [ $ok1 = 1 ]; then bad=0; good=$((good + 1)); else good=0; bad=$((bad + 1)); fi
            if [ $active = 1 ] && [ $bad -ge 3 ] && [ $ok2 = 1 ]; then want=2; fi
            if [ $active = 2 ] && [ $good -ge 3 ]; then want=1; fi
            if [ $want != $active ]; then
              printf 'flush chain inet router steer\nadd rule inet router steer meta mark set %s\n' "$want" | nft -f -
              conntrack -F >/dev/null 2>&1 || true
              echo "wan-health: active WAN $active -> $want (wan1 ok=$ok1, wan2 ok=$ok2)"
              active=$want
            fi
          done
        '';
      };
    };

    client = {pkgs, ...}: {
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [3];
      };
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];
    };

    isp1 = {
      imports = [
        (isp {
          n = 1;
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
      systemd.services.echo = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [80]}";
      };
    };
  };

  testScript = ''
    import time

    V4 = "curl -s --max-time 2 http://203.0.113.80/"
    V6 = "curl -s --max-time 2 'http://[2001:db8:f::80]/'"

    def observe(label, machine, cmd):
        status, out = machine.execute(cmd + " 2>&1")
        print(f"FINDING {label}: rc={status}\n{out.rstrip()}")
        return status, out.strip()

    def seconds_until(cmd, wanted, started, limit=60):
        while time.time() - started < limit:
            status, out = client.execute(cmd + " 2>/dev/null")
            if status == 0 and wanted in out:
                return round(time.time() - started, 1)
            time.sleep(0.5)
        return None

    def both(label, v4, v6, started):
        a = seconds_until(V4, v4, started)
        b = seconds_until(V6, v6, started)
        print(f"FINDING {label}: IPv4 answered from {v4} after {a}s, IPv6 from {v6} after {b}s (None: not within 60 s)")

    start_all()
    for machine in [internet, isp1, isp2, router, client]:
        machine.wait_for_unit("multi-user.target", timeout=300)
    internet.wait_until_succeeds("ss -tln | grep ':80 ' >/dev/null", timeout=60)
    router.wait_for_unit("wan-health.service", timeout=60)

    with subtest("both WANs up: traffic leaves through the primary"):
        observe("router rules and tables", router, "ip rule; ip -6 rule; ip route show table 301; ip route show table 302; ip -6 route show table 301; ip -6 route show table 302; echo main:; ip route; ip -6 route | grep -v fe80")
        observe("ifstatecli check", router, "ifstatecli check | grep -v ' ok$\\|^$\\|= \\|orphan\\|\\.\\.\\.$\\|^ [a-z0-9.]*$'")
        observe("client routes", client, "ip -br addr; ip route; ip -6 route | grep -v fe80; ping -c1 -W1 192.168.10.1 | tail -2; ping -c1 -W1 2001:db8:1000:1::1 | tail -2")
        observe("one try each, verbose", client, "curl -sS --max-time 3 http://203.0.113.80/; curl -sS --max-time 3 'http://[2001:db8:f::80]/'")
        observe("router counters and sysctls", router, "nft list table inet router | grep counter; sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.eth1.rp_filter net.ipv4.conf.all.forwarding net.ipv6.conf.all.forwarding net.ipv6.conf.eth3.forwarding; ip route get 203.0.113.80 from 192.168.10.10 iif eth3 mark 1; ip -6 route get 2001:db8:f::80 from 2001:db8:1000:1::10 iif eth3 mark 1")
        both("primary", "192.0.2.2", "2001:db8:1000:1::10", time.time())
        observe("the router's own traffic", router, V4 + "; " + V6)
        observe("health pings through each WAN", router, "ping -c1 -W1 -m 1 203.0.113.80 | head -2; ping -c1 -W1 -m 2 203.0.113.80 | head -2; ping -c1 -W1 -m 2 2001:db8:f::80 | head -2")

    with subtest("the primary's upstream dies, its link stays up"):
        isp1.succeed("sysctl -w net.ipv4.conf.all.forwarding=0 net.ipv6.conf.all.forwarding=0")
        both("failover", "198.51.100.2", "2001:db8:2000:1::10", time.time())
        observe("the health check", router, "journalctl -u wan-health --no-pager | grep wan-health: | tail -3; nft list chain inet router steer | grep mark")
        observe("the router's own traffic on the backup", router, V4 + "; " + V6)
        observe("ULA source on the backup", client, "curl -s --max-time 2 --interface fd00:10:1::10 'http://[2001:db8:f::80]/'")
        router.succeed("systemctl restart ifstate.service")
        observe("after an IfState apply, still on the backup", client, V4 + "; " + V6)
        observe("rules after the apply", router, "ip rule | grep fwmark; ip -6 rule | grep fwmark")

    with subtest("the primary returns"):
        isp1.succeed("sysctl -w net.ipv4.conf.all.forwarding=1 net.ipv6.conf.all.forwarding=1")
        both("failback", "192.0.2.2", "2001:db8:1000:1::10", time.time())
        observe("the health check", router, "journalctl -u wan-health --no-pager | grep wan-health: | tail -3")

    with subtest("the primary's cable is pulled"):
        isp1.succeed("ip link set eth1 down")
        both("failover on a dead link", "198.51.100.2", "2001:db8:2000:1::10", time.time())
        observe("guard and units on the router", router, "systemctl --failed --no-legend; journalctl -u netif-guard --no-pager | tail -3")

    print("PROBE_DUAL_WAN_OK")
  '';
}
