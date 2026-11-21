# Probes PR3, PR6 and PR8 (specs/gateway.md §6; G8, G10, G11, G14, G15, G20, G22).
#
#   isp ── vlan 1 ── router ── vlan 2 ── client   (zone home)
#                       └───── vlan 3 ── node     (zone servers; stands in
#                                                  for a cluster node)
#
# netif renders the router's links (WAN DHCPv4, DHCPv6 and a delegated
# /60; a /64 of it on each zone). Everything else is the prototype of
# `services/router`: nftables zones and NAT44, kea, corerad, CoreDNS.
#
# Questions:
#   - corerad with a delegated prefix that appears after it starts, a ULA
#     beside it, RDNSS, DNSSL and PREF64; what a client sees when the ISP
#     changes the prefix. (PR3)
#   - A service /64 of the delegated prefix rewritten to a stable ULA /64:
#     is the host part kept, does the client address survive, are unused
#     addresses and closed ports refused, what happens on a prefix
#     change. (PR6)
#   - Zones: default deny, read from netif's zone seam. (G11)
#   - The prefix hook from end to end: netif's prefix file, a path unit,
#     corerad restarted with the old prefix retired, the service rule
#     moved; also when the prefix changed while the router was off. (PR8)
#   - CoreDNS with a blocklist of 300 000 names in the hosts plugin. (G14)
#
# Lines that start with FINDING are the result.
{
  inputs,
  lib,
  ...
}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  echo = import ./echo.nix;

  # The router's WAN NIC: the driver gives node N on vlan V the MAC
  # 52:54:00:12:0V:0N, and the nodes sort as client, isp, node, router.
  routerWanLinkLocal = "fe80::5054:ff:fe12:104";

  kea6 = pdPrefix: {
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
      preferred-lifetime = 120;
      valid-lifetime = 240;
      subnet6 = [
        {
          id = 1;
          subnet = "2001:db8::/64";
          interface = "eth1";
          pools = [{pool = "2001:db8::100-2001:db8::1ff";}];
          pd-pools = [
            {
              prefix = pdPrefix;
              prefix-len = 56;
              delegated-len = 60;
            }
          ];
        }
      ];
    };
  };
in {
  name = "probe-router";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        client = {};
        isp = {};
        node = {};
        router = {};
      };
      instances = {
        wan = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.router.settings.links.wan = {
            interface = "eth1";
            zone = "wan";
            dhcp = {
              ipv4 = true;
              ipv6 = true;
              prefixDelegation = {
                enable = true;
                hint = 60;
                assign = [
                  {
                    instance = "lan";
                    link = "home";
                    subnet = 1;
                  }
                  {
                    instance = "lan";
                    link = "servers";
                    subnet = 2;
                  }
                ];
              };
            };
          };
        };
        lan = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines = {
            router.settings.links = {
              home = {
                interface = "eth2";
                zone = "home";
                static = {
                  ipv4 = ["192.168.10.1/24"];
                  ipv6 = ["fd00:10:1::1/64"];
                };
                ra = false;
              };
              servers = {
                interface = "eth3";
                zone = "servers";
                static = {
                  ipv4 = ["192.168.20.1/24"];
                  ipv6 = ["fd00:10:2::1/64"];
                };
                ra = false;
              };
            };
            client.settings.links.uplink = {
              interface = "eth1";
              dhcp.ipv4 = true;
            };
            node.settings.links.uplink = {
              interface = "eth1";
              static.ipv4 = ["192.168.20.10/24"];
              gateway.ipv4 = "192.168.20.1";
            };
          };
        };
      };
    };
  };

  nodes = {
    router = {
      pkgs,
      config,
      ...
    }: let
      inherit (config.clanServices.netif) zones;
      set = names: "{ ${lib.concatMapStringsSep ", " (n: ''"${n}"'') names} }";
      wan = set zones.wan;
      lans = set (zones.home ++ zones.servers);
      blocklist = pkgs.runCommand "blocklist-300k" {} ''
        seq 1 300000 | sed 's/.*/0.0.0.0 ad&.block.test/' > $out
      '';
      # The prefix hook (specs/gateway.md G22). netif writes the delegated
      # prefix to /run/netif/pd/<wan>; a path unit runs this on a change.
      # It retires the old prefix in corerad's configuration, moves the
      # service prefix rule, and remembers the prefix across a reboot.
      prefixHook = pkgs.writers.writePython3 "router-prefix" {flakeIgnore = ["E501"];} ''
        import ipaddress
        import json
        import os
        import subprocess
        import time

        PD = "/run/netif/pd/eth1"
        STATE = "/var/lib/router/prefix.json"
        CONF = "/run/router/corerad.toml"
        ZONES = {"eth2": (1, "fd00:10:1::1"), "eth3": (2, "fd00:10:2::1")}
        SERVICE_SUBNET = 15
        STABLE = "fd00:10:5::/64"


        def subnet(prefix, number):
            return str(list(ipaddress.ip_network(prefix).subnets(new_prefix=64))[number])


        def replace(path, text):
            if os.path.exists(path) and open(path).read() == text:
                return False
            with open(path + ".tmp", "w") as handle:
                handle.write(text)
            os.rename(path + ".tmp", path)
            return True


        try:
            state = json.load(open(STATE))
        except (OSError, ValueError):
            state = {"current": None, "retired": {}}
        new = None
        if os.path.exists(PD):
            lines = open(PD).read().split()
            new = lines[0] if lines else None
        now = time.time()
        if new:
            if state["current"] and state["current"] != new:
                state["retired"][state["current"]] = now
            state["retired"].pop(new, None)
            state["current"] = new
        state["retired"] = {p: t for p, t in state["retired"].items() if now - t < 7200}

        out = ["[debug]", 'address = "[::1]:9430"', "prometheus = true", ""]
        for name, (number, dns) in ZONES.items():
            out += [
                "[[interfaces]]", f'name = "{name}"', "advertise = true",
                "  [[interfaces.prefix]]", '  prefix = "::/64"',
                '  preferred_lifetime = "45m"', '  valid_lifetime = "90m"',
            ]
            for old in state["retired"]:
                out += [
                    "  [[interfaces.prefix]]", f'  prefix = "{subnet(old, number)}"',
                    "  deprecated = true", '  preferred_lifetime = "1s"', '  valid_lifetime = "2h"',
                ]
            out += [
                "  [[interfaces.rdnss]]", f'  servers = ["{dns}"]',
                "  [[interfaces.dnssl]]", '  domain_names = ["home.test"]',
                "  [[interfaces.pref64]]", '  prefix = "64:ff9b::/96"', "",
            ]
        changed = replace(CONF, "\n".join(out))
        if new:
            public = subnet(new, SERVICE_SUBNET)
            rules = f"flush chain inet router svc_dnat\nadd rule inet router svc_dnat dnat ip6 prefix to ip6 daddr map {{ {public} : {STABLE} }}\n"
            subprocess.run(["nft", "-f", "-"], input=rules.encode(), check=True)
        replace(STATE, json.dumps(state))
        if changed:
            subprocess.run(["systemctl", "try-restart", "corerad.service"], check=True)
        print(f"router-prefix: current {state['current']}, retired {sorted(state['retired'])}, corerad {'restarted' if changed else 'unchanged'}")
      '';
    in {
      virtualisation = {
        cores = 2;
        memorySize = 2048;
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
        "net.ipv6.ip_nonlocal_bind" = 1;
      };
      environment = {
        systemPackages = [
          pkgs.jq
          pkgs.conntrack-tools
          pkgs.tcpdump
          pkgs.curl
          pkgs.dig
        ];
        etc."blocklist".source = blocklist;
      };
      networking = {
        firewall.enable = false;
        nftables = {
          enable = true;
          tables.router = {
            family = "inet";
            content = ''
              chain svc_dnat {
                type nat hook prerouting priority dstnat;
              }
              chain postrouting {
                type nat hook postrouting priority srcnat;
                oifname ${wan} meta nfproto ipv4 masquerade
              }
              chain input {
                type filter hook input priority filter; policy drop;
                iifname "lo" accept
                ct state established,related accept
                meta l4proto { icmp, ipv6-icmp } accept
                iifname ${wan} udp dport { 68, 546 } accept
                iifname ${lans} udp dport { 53, 67 } accept
                iifname ${lans} tcp dport 53 accept
                counter comment "input dropped"
              }
              chain forward {
                type filter hook forward priority filter; policy drop;
                ct state established,related accept
                ct state invalid drop
                iifname ${lans} oifname ${wan} accept comment "internet"
                ip6 daddr fd00:10:5::80 tcp dport 80 accept comment "service pinhole"
                counter comment "forward dropped"
              }
            '';
          };
        };
      };
      services = {
        kea.dhcp4 = {
          enable = true;
          settings = {
            interfaces-config = {
              interfaces = ["eth2"];
              service-sockets-max-retries = 30;
              service-sockets-retry-wait-time = 1000;
            };
            lease-database = {
              type = "memfile";
              persist = false;
            };
            subnet4 = [
              {
                id = 1;
                subnet = "192.168.10.0/24";
                interface = "eth2";
                pools = [{pool = "192.168.10.100 - 192.168.10.150";}];
                option-data = [
                  {
                    name = "routers";
                    data = "192.168.10.1";
                  }
                  {
                    name = "domain-name-servers";
                    data = "192.168.10.1";
                  }
                ];
              }
            ];
          };
        };
        corerad = {
          enable = true;
          # written by the prefix hook: a retired prefix is listed there
          configFile = "/run/router/corerad.toml";
        };
        coredns = {
          enable = true;
          config = ''
            . {
              bind 192.168.10.1 fd00:10:1::1
              hosts /etc/blocklist {
                fallthrough
              }
              forward . 192.0.2.1
              prometheus [::1]:9153
              errors
            }
          '';
        };
      };
      systemd = {
        tmpfiles.rules = [
          "d /run/router 0755 root root -"
          "d /var/lib/router 0755 root root -"
        ];
        paths.router-prefix = {
          wantedBy = ["multi-user.target"];
          pathConfig.PathChanged = "/run/netif/pd/eth1";
        };
        services = {
          coredns.after = ["ifstate.service"];
          corerad = {
            after = [
              "ifstate.service"
              "router-prefix.service"
            ];
            wants = ["router-prefix.service"];
          };
          router-prefix = {
            wantedBy = ["multi-user.target"];
            after = [
              "nftables.service"
              "systemd-tmpfiles-setup.service"
            ];
            path = [
              pkgs.nftables
              pkgs.systemd
            ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = prefixHook;
            };
          };
        };
      };
    };

    client = {pkgs, ...}: {
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [2];
      };
      networking.firewall.enable = false;
      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
        pkgs.dig
        pkgs.ndisc6
        pkgs.tcpdump
      ];
      systemd.services.echo = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [80]}";
      };
    };

    node = {pkgs, ...}: {
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [3];
      };
      networking.firewall.enable = false;
      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
        pkgs.tcpdump
      ];
      systemd.services.echo = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [80 8080]}";
      };
    };

    isp = {pkgs, ...}: {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          inherit ifstateOverlay;
          addresses = [
            "192.0.2.1/24"
            "2001:db8::1/64"
          ];
          # kea installs no route for what it delegates
          routes = [
            {
              to = "2001:db8:1000::/48";
              via = routerWanLinkLocal;
              dev = "eth1";
            }
            {
              to = "2001:db8:2000::/48";
              via = routerWanLinkLocal;
              dev = "eth1";
            }
          ];
          withBase = true;
        })
      ];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [1];
      };
      environment.systemPackages = [
        pkgs.tcpdump
        pkgs.curl
      ];
      boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
      networking.firewall.enable = false;
      # The ISP renumbers: the same server delegates from another block.
      specialisation.renumber.configuration.services.kea.dhcp6 = lib.mkForce (kea6 "2001:db8:2000::");
      systemd.services.echo = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [80]}";
      };
      services = {
        coredns = {
          enable = true;
          config = ''
            . {
              bind 192.0.2.1
              hosts {
                192.0.2.1 web.test
              }
              errors
            }
          '';
        };
        kea = {
          dhcp4 = {
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
              subnet4 = [
                {
                  id = 1;
                  subnet = "192.0.2.0/24";
                  interface = "eth1";
                  pools = [{pool = "192.0.2.100 - 192.0.2.150";}];
                  option-data = [
                    {
                      name = "routers";
                      data = "192.0.2.1";
                    }
                    {
                      name = "domain-name-servers";
                      data = "192.0.2.1";
                    }
                  ];
                }
              ];
            };
          };
          dhcp6 = kea6 "2001:db8:1000::";
        };
        radvd = {
          enable = true;
          config = ''
            interface eth1 {
              AdvSendAdvert on;
              AdvManagedFlag on;
              AdvOtherConfigFlag on;
              prefix 2001:db8::/64 { AdvAutonomous off; };
            };
          '';
        };
      };
      systemd.services.coredns.after = ["ifstate.service"];
    };
  };

  testScript = ''
    import json
    import time

    def observe(label, machine, cmd):
        status, out = machine.execute(cmd + " 2>&1")
        print(f"FINDING {label}: rc={status}\n{out.rstrip()}")
        return status, out.strip()

    def timed(label, machine, cmd):
        start = time.time()
        status, out = machine.execute(cmd + " 2>&1")
        print(f"FINDING {label}: rc={status} after {round(time.time() - start, 1)}s\n{out.rstrip()}")
        return status, out.strip()

    def global6(machine, dev, prefix):
        for info in json.loads(machine.succeed(f"ip -j -6 addr show dev {dev} scope global"))[0]["addr_info"]:
            if info.get("local", "").startswith(prefix) and not info.get("deprecated"):
                return info["local"]
        return None

    start_all()
    for machine in [isp, router, client, node]:
        machine.wait_for_unit("multi-user.target", timeout=300)
    isp.wait_until_succeeds("ss -uln | grep ':547 ' >/dev/null", timeout=60)

    with subtest("the router's links: leases and the delegated prefix"):
        router.wait_until_succeeds("ip -4 -o addr show dev eth1 scope global | grep 192.0.2.1 >/dev/null", timeout=120)
        router.wait_until_succeeds("ip -6 -o addr show dev eth2 scope global | grep '2001:db8:10[0-9a-f][0-9a-f]:1::1/64' >/dev/null", timeout=120)
        router.wait_until_succeeds("ip -6 -o addr show dev eth3 scope global | grep '2001:db8:10[0-9a-f][0-9a-f]:2::1/64' >/dev/null", timeout=60)
        observe("router addresses", router, "ip -br addr")
        observe("router IPv6 routes (what did dhcpcd install for the /60?)", router, "ip -6 route show table all | grep -v '^local\\|^multicast\\|fe80'")
        observe("zone seam and units", router, "systemctl is-active corerad coredns kea-dhcp4-server nftables")
        observe("corerad start order", router, "journalctl -u corerad --no-pager | tail -30")
        print("PROBE_ROUTER_LINKS_OK")

    with subtest("PR3: what a client learns from corerad"):
        client.wait_until_succeeds("ip -4 -o addr show dev eth1 scope global | grep 192.168.10.1 >/dev/null", timeout=120)
        client.wait_until_succeeds("ip -6 -o addr show dev eth1 scope global | grep '2001:db8:10' >/dev/null", timeout=120)
        observe("client addresses and routes", client, "ip -br addr; ip -6 route; ip -4 route")
        observe("router advertisement as rdisc6 prints it", client, "rdisc6 -1 -w 3000 eth1")
        client.execute("tcpdump -i eth1 -vv -c1 'icmp6 and ip6[40] == 134' > /tmp/ra.txt 2>&1 &")
        client.execute("sleep 1; rdisc6 -1 -w 3000 eth1 >/dev/null 2>&1; sleep 2")
        observe("router advertisement as tcpdump prints it", client, "cat /tmp/ra.txt")
        observe("client DNS (netif does not read RDNSS, N39)", client, "resolvectl status eth1")
        observe("corerad metrics", router, "curl -s http://[::1]:9430/metrics | grep '^corerad' | head -40")
        node.wait_until_succeeds("ip -6 -o addr show dev eth1 scope global | grep '2001:db8:10' >/dev/null", timeout=120)
        observe("node addresses and routes", node, "ip -br addr; ip -6 route")
        print("PROBE_ROUTER_RA_OK")

    with subtest("NAT44, native IPv6 and source address choice with a ULA beside the public prefix"):
        observe("client to the ISP over IPv4 (NAT44)", client, "curl -s --max-time 5 http://192.0.2.1/")
        observe("client to the ISP over IPv6 (no NAT; which source?)", client, "curl -s --max-time 5 'http://[2001:db8::1]/'")
        observe("client to the router's ULA (which source?)", client, "ip -6 route get fd00:10:1::1")
        observe("DNS through the router's CoreDNS", client, "dig +short web.test @192.168.10.1; dig +short web.test @fd00:10:1::1; dig +short web.test")
        observe("a blocked name", client, "dig +short ad299999.block.test @192.168.10.1; dig +noall +answer +stats ad150000.block.test @192.168.10.1 | grep -i 'IN\\|Query time'")
        observe("CoreDNS with 300 000 hosts entries: memory and start", router, "systemctl show coredns -p MemoryCurrent -p MemoryPeak -p ExecMainStartTimestamp -p ActiveEnterTimestamp; journalctl -u coredns --no-pager | tail -5; wc -l /etc/blocklist")

    with subtest("zones: default deny"):
        client_v6 = global6(client, "eth1", "2001:db8:10")
        node_v6 = global6(node, "eth1", "2001:db8:10")
        client_v4 = json.loads(client.succeed("ip -j -4 addr show dev eth1 scope global"))[0]["addr_info"][0]["local"]
        observe("home to servers over IPv4", client, "curl -s --max-time 4 http://192.168.20.10/")
        observe("home to servers over IPv6", client, f"curl -s --max-time 4 'http://[{node_v6}]/'")
        observe("servers to home over IPv4", node, f"curl -s --max-time 4 http://{client_v4}/")
        observe("servers to home over IPv6", node, f"curl -s --max-time 4 'http://[{client_v6}]/'")
        observe("the ISP to a client's public IPv6 address", isp, f"curl -s --max-time 4 'http://[{client_v6}]/'")
        observe("the ISP to the router's own WAN address, port 53", isp, "dig +time=2 +tries=1 +short web.test @$(ip -4 neigh show dev eth1 | awk '/192.0.2.1[0-9][0-9]/{print $1; exit}')")
        observe("forward and input counters", router, "nft list table inet router | grep counter")

    def service_checks(tag):
        delegated = router.succeed("cat /run/netif/pd/eth1").strip()
        base = delegated.split("::/")[0] + ":f::"
        print(f"FINDING {tag}: netif's prefix file says {delegated}; the service prefix is {base}/64")
        observe(f"{tag}: the rewrite rule", router, "nft list chain inet router svc_dnat")
        timed(f"{tag}: the ISP to the service address (the answer is the client address the node saw)", isp, f"curl -s --max-time 5 'http://[{base}80]/'")
        timed(f"{tag}: 2 MB", isp, f"curl -s --max-time 20 -o /dev/null -w '%{{size_download}} bytes' 'http://[{base}80]/big'")
        timed(f"{tag}: a closed port on the service address", isp, f"curl -s --max-time 5 'http://[{base}80]:8080/'")
        timed(f"{tag}: an unused address of the service prefix", isp, f"curl -sS --max-time 5 'http://[{base}81]/'")
        timed(f"{tag}: ping an unused address", isp, f"ping -c1 -W3 {base}81")
        timed(f"{tag}: an unassigned subnet of the delegated prefix", isp, f"ping -c1 -W3 {base.replace(':f::', ':7::')}1")
        timed(f"{tag}: the home zone to the service address", client, f"curl -s --max-time 5 'http://[{base}80]/'")
        observe(f"{tag}: conntrack", router, "conntrack -L -f ipv6 2>/dev/null | grep 'dport=80 ' | head -5")
        return base

    with subtest("PR6: a service /64 rewritten to a stable ULA /64"):
        # the stand-in for a /128 that Cilium announces through FRR
        node.succeed("ip -6 addr add fd00:10:5::80/128 dev lo")
        # proto bgp, as FRR would install it: IfState ignores it on an apply
        router.succeed("ip -6 route add fd00:10:5::80/128 via fd00:10:2::10 dev eth3 proto bgp")
        node.succeed("ip -6 addr add fd00:10:2::10/64 dev eth1 nodad")
        router.succeed("ip -6 route add unreachable fd00:10:5::/64 metric 4096 proto bgp")
        old_base = service_checks("first prefix")

    def client_state(new):
        """(has a preferred address in the new prefix, every other public address is deprecated)"""
        fresh = False
        stale = False
        for info in json.loads(client.succeed("ip -j -6 addr show dev eth1 scope global"))[0]["addr_info"]:
            local = info.get("local", "")
            if not local.startswith("2001:"):
                continue
            if local.startswith(new):
                fresh = fresh or not info.get("deprecated")
            elif not info.get("deprecated"):
                stale = True
        return fresh, stale

    def settle(label, new, started):
        """Seconds until the client prefers the new prefix, has retired the others and reaches the internet."""
        done = None
        while time.time() - started < 90:
            fresh, stale = client_state(new)
            if fresh and not stale and client.execute("curl -s --max-time 3 'http://[2001:db8::1]/' >/dev/null")[0] == 0:
                done = round(time.time() - started, 1)
                break
            time.sleep(1)
        print(f"FINDING {label}: the client was on the new prefix, with the old one retired and the internet reachable, after {done}s (None: not within 90 s)")
        observe(f"{label}: client addresses", client, "ip -6 addr show dev eth1 scope global | grep -v valid_lft; ip -6 route show default")
        observe(f"{label}: the hook", router, "journalctl -u router-prefix --no-pager | grep router-prefix: | tail -4; cat /var/lib/router/prefix.json; echo; grep -B1 -A4 deprecated /run/router/corerad.toml")
        observe(f"{label}: corerad", router, "systemctl is-active corerad; journalctl -u corerad --no-pager | grep -i 'deprecated\\|starting with' | tail -4")
        return done

    def hook_runs():
        return int(router.succeed("journalctl -u router-prefix --no-pager | grep -c 'router-prefix: current' || true").strip())

    with subtest("PR8: a restart of dhcpcd that changes nothing does not fire the hook"):
        before = hook_runs()
        router.succeed("systemctl restart netif-dhcpcd-eth1.service")
        router.wait_until_succeeds("ip -6 -o addr show dev eth2 scope global | grep '2001:db8:10' >/dev/null", timeout=120)
        time.sleep(5)
        print(f"FINDING hook runs before the restart {before}, after {hook_runs()}; prefix file: {router.succeed('cat /run/netif/pd/eth1').strip()}")
        observe("the default route on the client across a corerad restart", client, "ip -6 route show default")

    with subtest("PR8: the ISP changes the prefix while the router runs"):
        isp.succeed("/run/current-system/specialisation/renumber/bin/switch-to-configuration test >&2")
        isp.wait_until_succeeds("ss -uln | grep ':547 ' >/dev/null", timeout=60)
        router.succeed("systemctl restart netif-dhcpcd-eth1.service")
        router.wait_until_succeeds("ip -6 -o addr show dev eth2 scope global | grep '2001:db8:20[0-9a-f][0-9a-f]:1::1/64' >/dev/null", timeout=120)
        settle("live change", "2001:db8:20", time.time())
        timed("the old service address", isp, f"curl -sS --max-time 5 'http://[{old_base}80]/'")
        second_base = service_checks("second prefix")

    with subtest("PR8: the ISP changes the prefix while the router is off"):
        router.shutdown()
        isp.succeed("/run/booted-system/bin/switch-to-configuration test >&2")
        isp.wait_until_succeeds("ss -uln | grep ':547 ' >/dev/null", timeout=60)
        router.start()
        router.wait_for_unit("multi-user.target", timeout=300)
        router.wait_until_succeeds("ip -6 -o addr show dev eth2 scope global | grep '2001:db8:10[0-9a-f][0-9a-f]:1::1/64' >/dev/null", timeout=120)
        settle("change across a reboot", "2001:db8:10", time.time())
        node.succeed("ip -6 addr replace fd00:10:5::80/128 dev lo")
        router.succeed("ip -6 route replace fd00:10:5::80/128 via fd00:10:2::10 dev eth3 proto bgp; ip -6 route replace unreachable fd00:10:5::/64 metric 4096 proto bgp")
        timed("the second service address", isp, f"curl -sS --max-time 5 'http://[{second_base}80]/'")
        service_checks("third prefix")

    print("PROBE_ROUTER_OK")
  '';
}
