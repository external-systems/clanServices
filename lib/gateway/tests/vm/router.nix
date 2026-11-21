# The router's building blocks as a regression suite (specs/gateway.md
# §10.2, §10.3, §10.7; decisions G8, G10, G11, G14, G15, G20, G22;
# specs/netif.md N16, N39).
#
#   isp ── vlan 1 ── router ── vlan 2 ── client   (zone home, netif)
#                       │          └──── laptop   (zone home, NetworkManager)
#                       └───── vlan 3 ── node     (zone servers; stands in
#                                                  for a cluster node)
#
# netif renders the router's links (WAN DHCPv4, DHCPv6 and a delegated
# prefix; a /64 of it on each zone). Everything else is the fixture that
# stands in for `services/router`: nftables zones and NAT44, kea,
# corerad, CoreDNS and the prefix hook.
#
# It pins:
#   - G15: corerad advertises the delegated /64, the ULA /64, RDNSS,
#     DNSSL and PREF64; a stop withdraws the default route.
#   - G8, G10, G11, G14: NAT44, source address choice beside a ULA,
#     default deny between zones, a blocklist of 300 000 names.
#   - G20: a service /64 of the delegated prefix rewritten to a stable
#     ULA /64, and that it follows a prefix change with one rule.
#   - G22: the prefix hook from end to end. A live change, two changes in
#     a row, a /56, a /64 that has no room for the zones, a change while
#     the router was off, with and without the hook's state on disk. The
#     hook never holds up a boot.
#   - nftables ownership (specs/gateway.md §12.2): one table per owner;
#     a restart of one owner leaves the other tables byte-equal.
#   - An IfState apply changes nothing.
{
  inputs,
  lib,
  ...
}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  echo = import ./echo.nix;

  # The router's WAN NIC: the driver gives node N on vlan V the MAC
  # 52:54:00:12:0V:0N, and the nodes sort as client, isp, laptop, node,
  # router.
  routerWanLinkLocal = "fe80::5054:ff:fe12:105";

  # Subnet ids of the delegated prefix: one per zone (netif assigns
  # them, N16) and one for the service prefix (G20).
  subnets = {
    home = 1;
    servers = 2;
    service = 15;
  };
  # Do the subnet ids fit a delegated prefix of that length?
  fits = length: lib.all (id: id < lib.foldl' (n: _: n * 2) 1 (lib.range 1 (64 - length))) (lib.attrValues subnets);

  # What the ISP delegates: at boot `first`, the others as
  # specialisations of the ISP (it renumbers by a switch).
  delegations = {
    first = {
      prefix = "2001:db8:1000::";
      poolLength = 56;
      length = 60;
    };
    renumber = {
      prefix = "2001:db8:2000::";
      poolLength = 56;
      length = 60;
    };
    wide = {
      prefix = "2001:db8:3000::";
      poolLength = 48;
      length = 56;
    };
    # no room for a zone
    single = {
      prefix = "2001:db8:4000::";
      poolLength = 56;
      length = 64;
    };
  };

  kea6 = delegation: {
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
              inherit (delegation) prefix;
              prefix-len = delegation.poolLength;
              delegated-len = delegation.length;
            }
          ];
        }
      ];
    };
  };
in {
  name = "gateway-router";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        client = {};
        isp = {};
        laptop = {};
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
                    subnet = subnets.home;
                  }
                  {
                    instance = "lan";
                    link = "servers";
                    subnet = subnets.servers;
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
      # A subnet id that does not fit the delegation gets nothing: no
      # retired prefix, no rule. The rule lives in the hook's own table,
      # so a restart of nftables.service does not remove it.
      prefixHook = pkgs.writers.writePython3 "router-prefix" {flakeIgnore = ["E501"];} ''
        import ipaddress
        import json
        import os
        import subprocess
        import time

        PD = "/run/netif/pd/eth1"
        STATE = "/var/lib/router/prefix.json"
        CONF = "/run/router/corerad.toml"
        ZONES = {"eth2": (${toString subnets.home}, "fd00:10:1::1"), "eth3": (${toString subnets.servers}, "fd00:10:2::1")}
        SERVICE_SUBNET = ${toString subnets.service}
        STABLE = "fd00:10:5::/64"


        def subnet(prefix, number):
            """The /64 with that subnet id, or None: the delegation has no room for it."""
            network = ipaddress.ip_network(prefix)
            if network.prefixlen > 64 or number >= 2 ** (64 - network.prefixlen):
                return None
            return str(ipaddress.ip_network((int(network.network_address) + (number << 64), 64)))


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
            for old in [subnet(p, number) for p in state["retired"]]:
                if old:
                    out += [
                        "  [[interfaces.prefix]]", f'  prefix = "{old}"',
                        "  deprecated = true", '  preferred_lifetime = "1s"', '  valid_lifetime = "2h"',
                    ]
            out += [
                "  [[interfaces.rdnss]]", f'  servers = ["{dns}"]',
                "  [[interfaces.dnssl]]", '  domain_names = ["home.test"]',
                "  [[interfaces.pref64]]", '  prefix = "64:ff9b::/96"', "",
            ]
        changed = replace(CONF, "\n".join(out))
        public = subnet(new, SERVICE_SUBNET) if new else None
        rule = f"dnat ip6 prefix to ip6 daddr map {{ {public} : {STABLE} }}" if public else ""
        # one transaction: the table is never half there
        table = f"table inet router_svc\ndelete table inet router_svc\ntable inet router_svc {{\n  chain prerouting {{\n    type nat hook prerouting priority dstnat;\n    {rule}\n  }}\n}}\n"
        subprocess.run(["nft", "-f", "-"], input=table.encode(), check=True)
        replace(STATE, json.dumps(state))
        if changed:
            # --no-block: corerad is ordered after this unit, so waiting
            # for its restart from inside this unit never returns
            subprocess.run(["systemctl", "--no-block", "try-restart", "corerad.service"], check=True)
        print(f"router-prefix: current {state['current']}, retired {sorted(state['retired'])}, service {public}, corerad {'restarted' if changed else 'unchanged'}")
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
      # The evaluation-time half of "the zones fit the delegation"; the
      # hook is the run-time half.
      assertions = [
        {
          assertion = fits delegations.first.length;
          message = "gateway-router: a subnet id of the router does not fit the /${toString delegations.first.length} it asks for (specs/gateway.md G22)";
        }
        {
          assertion = !(fits delegations.single.length);
          message = "gateway-router: the /64 phase needs a subnet id that does not fit a /64";
        }
      ];
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
          pkgs.coredns
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

    # A NetworkManager client in the home zone: it reads router
    # advertisements itself, not through the kernel.
    laptop = {pkgs, ...}: {
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [2];
      };
      networking = {
        firewall.enable = false;
        # the test driver's static addresses would hide what
        # NetworkManager configures
        interfaces = lib.mkForce {};
        networkmanager = {
          enable = true;
          unmanaged = ["interface-name:eth0"];
        };
      };
      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
      ];
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
          routes =
            map (delegation: {
              to = "${delegation.prefix}/48";
              via = routerWanLinkLocal;
              dev = "eth1";
            })
            (lib.attrValues delegations);
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
      specialisation =
        lib.mapAttrs (_: delegation: {
          configuration.services.kea.dhcp6 = lib.mkForce (kea6 delegation);
        })
        (removeAttrs delegations ["first"]);
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
          dhcp6 = kea6 delegations.first;
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
    ${import ../../../../tests/suite-lib.nix}
    ${import ../../../../tests/ifstate-noop.nix}
    import json
    import time

    # the blocks the ISP delegates from, in the order of the phases
    FIRST, RENUMBER, WIDE, SINGLE = BLOCKS = ["2001:db8:1000", "2001:db8:2000", "2001:db8:3000", "2001:db8:4000"]
    ISP = "2001:db8::1"
    STABLE = "fd00:10:5::80"

    def blocks(machine):
        """Per delegated block, what the machine has on eth1: (blocks with a
        preferred address, blocks with deprecated addresses only)."""
        fresh, old = set(), set()
        links = json.loads(machine.succeed("ip -j -6 addr show dev eth1 scope global"))
        for info in links[0]["addr_info"] if links else []:
            for block in BLOCKS:
                if info.get("local", "").startswith(block + ":"):
                    (old if info.get("deprecated") else fresh).add(block)
        return fresh, old - fresh

    def source(machine):
        """The address the ISP sees for the machine's IPv6 traffic, or None."""
        status, out = machine.execute(f"curl -s --max-time 3 'http://[{ISP}]/'")
        return out.strip() if status == 0 else None

    def seconds_since(started, check, limit):
        while time.time() - started < limit:
            if check():
                return round(time.time() - started, 1)
            time.sleep(0.5)
        return None

    def settle(label, machine, started, fresh, old, bound):
        """The machine prefers `fresh` only, has retired `old`, and its traffic
        to the ISP leaves from `fresh`: within `bound` seconds of `started`."""
        def check():
            answer = source(machine) if blocks(machine) == ({fresh}, set(old)) else None
            return answer is not None and answer.startswith(fresh + ":")
        took = seconds_since(started, check, bound)
        observe(f"{label}: {machine.name} addresses", machine, "ip -6 addr show dev eth1 scope global | grep inet6; ip -6 route show default")
        print(f"FINDING {label}: {machine.name} preferred {fresh}, had retired {sorted(old)} and reached the ISP from the new prefix after {took}s (bound {bound}s)")
        assert took is not None, f"{label}: {machine.name} did not follow the prefix change within {bound}s: {blocks(machine)}, source {source(machine)}"
        return took

    def advertisement():
        """One solicited router advertisement on the home zone, parsed from rdisc6."""
        out = client.wait_until_succeeds("rdisc6 -1 -w 3000 eth1", timeout=30)
        ra = {"prefixes": {}, "rdnss": [], "dnssl": [], "pref64": [], "lifetime": None}
        prefix = None
        for line in out.splitlines():
            key, _, value = line.partition(":")
            key, value = key.strip(), value.strip()
            if key == "Prefix":
                prefix = value
                ra["prefixes"][prefix] = {}
            elif key in ("Valid time", "Pref. time") and prefix:
                ra["prefixes"][prefix][key] = int(value.split()[0])
            elif key == "Router lifetime":
                ra["lifetime"] = int(value.split()[0])
            elif key == "Recursive DNS server":
                ra["rdnss"].append(value)
            elif key == "DNS search list":
                ra["dnssl"].append(value)
            elif key == "NAT64 prefix":
                ra["pref64"].append(value)
        return ra

    def assert_advertised(label, current, retired):
        """On the wire: the ULA and the current /64 with the full preferred
        lifetime, every retired /64 with none, nothing else. corerad counts
        a deprecated prefix down from its configured 1 s and 2 h, so a
        retired prefix shows a preferred lifetime of 1 or 0."""
        ra = advertisement()
        got = {prefix: times["Pref. time"] for prefix, times in ra["prefixes"].items()}
        want = {"fd00:10:1::/64": 2700}
        if current:
            want[f"{current}:1::/64"] = 2700
        for block in retired:
            want[f"{block}:1::/64"] = 0
        print(f"FINDING {label}: advertised prefixes and preferred lifetimes {got}")
        assert {prefix: 0 if seconds <= 1 else seconds for prefix, seconds in got.items()} == want, f"{label}: advertised {got}, expected {want}"
        for block in retired:
            times = ra["prefixes"][f"{block}:1::/64"]
            assert times["Pref. time"] <= 1 and 3600 < times["Valid time"] <= 7200, ra
        assert ra["lifetime"] == 1800, ra
        return ra

    def hook_runs():
        return int(router.succeed("journalctl -u router-prefix --no-pager | grep -c 'router-prefix: current' || true").strip())

    def hook_lines():
        """What the hook printed in this boot, oldest first."""
        return router.succeed("journalctl -b -u router-prefix --no-pager -o cat | grep 'router-prefix: current'").splitlines()

    def isp_delegates(name):
        """The ISP renumbers: its DHCPv6 server delegates from another block."""
        system = "/run/booted-system" + ("" if name == "first" else f"/specialisation/{name}")
        isp.succeed(f"{system}/bin/switch-to-configuration test >&2")
        isp.wait_until_succeeds("ss -uln | grep ':547 ' >/dev/null", timeout=60)

    def router_renews(block, length):
        """The router's next DHCPv6 exchange (forced: a restart of dhcpcd).
        Returns the time at which netif's file had the new prefix."""
        router.succeed("systemctl restart netif-dhcpcd-eth1.service")
        router.wait_until_succeeds(f"grep -x '{block}::/{length}' /run/netif/pd/eth1 >/dev/null", timeout=120)
        return time.time()

    def assert_boot(label):
        """The hook must not hold up a boot (specs/gateway.md §10.7: a hook
        that waited for corerad's restart hung the next boot for 300 s)."""
        router.wait_for_unit("multi-user.target", timeout=300)
        seconds = round(int(router.succeed("systemctl show multi-user.target -P ActiveEnterTimestampMonotonic")) / 1e6, 1)
        print(f"FINDING {label}: the router reached multi-user.target {seconds}s after the kernel started (bound 90s)")
        assert seconds < 90, f"{label}: the boot took {seconds}s"
        state = router.execute("timeout 60 systemctl is-system-running --wait")[1].strip()
        failed = router.succeed("systemctl --failed --no-legend --plain").strip()
        jobs = router.succeed("systemctl list-jobs --no-legend").strip()
        assert (state, failed, jobs) == ("running", "", ""), f"{label}: system {state}, failed units: {failed}, queued jobs: {jobs}"
        router.succeed("systemctl is-active corerad.service router-prefix.path nftables.service coredns.service kea-dhcp4-server.service")
        assert router.succeed("systemctl show router-prefix.service -P Result").strip() == "success"

    def service_routes():
        # the stand-in for a /128 that Cilium announces through FRR
        node.succeed(f"ip -6 addr replace {STABLE}/128 dev lo; ip -6 addr replace fd00:10:2::10/64 dev eth1 nodad")
        # proto bgp, as FRR would install it: IfState ignores it on an apply
        router.succeed(f"ip -6 route replace {STABLE}/128 via fd00:10:2::10 dev eth3 proto bgp; ip -6 route replace unreachable fd00:10:5::/64 metric 4096 proto bgp")

    def refused(label, machine, url):
        """A flow that the firewall drops: no answer, no reset."""
        status, out = machine.execute(f"curl -sS --max-time 3 '{url}' 2>&1")
        print(f"FINDING {label}: curl rc={status} {out.strip()}")
        assert status == 28, f"{label}: expected a silent drop (curl 28), got {status}: {out}"

    def service_checks(label, block, full=True, home=True):
        """G20 on the service prefix of `block` (subnet id f)."""
        base = f"{block}:f::"
        table = router.succeed("nft list table inet router_svc")
        print(f"FINDING {label}: the hook's table\n{table}")
        # the service moves with one rule, replaced as a whole
        assert table.count("dnat ip6 prefix") == 1 and f"{{ {base}/64 : fd00:10:5::/64 }}" in table, table
        # the visitor's address is kept: the node saw the ISP's own address
        answer = isp.succeed(f"curl -sS --max-time 5 'http://[{base}80]/'").strip()
        assert answer == ISP, f"{label}: the node saw {answer}"
        # the host part is kept: <public>::80 became <stable>::80
        router.succeed(f"conntrack -L -f ipv6 2>/dev/null | grep 'src={ISP} dst={base}80 .*src={STABLE} dst={ISP} ' >/dev/null")
        if home:
            answer = client.succeed(f"curl -sS --max-time 5 'http://[{base}80]/'").strip()
            assert answer.startswith(f"{block}:1:"), f"{label}: the home zone reached the service as {answer}"
        if not full:
            return
        size, seconds = isp.succeed(f"curl -s --max-time 20 -o /dev/null -w '%{{size_download}} %{{time_total}}' 'http://[{base}80]/big'").split()
        print(f"FINDING {label}: {size} bytes through the rewrite in {seconds}s (bound 5s)")
        assert size == "2000000" and float(seconds) < 5, (size, seconds)
        refused(f"{label}: a port without a pinhole", isp, f"http://[{base}80]:8080/")
        started = time.time()
        status, out = isp.execute(f"curl -sS --max-time 5 'http://[{base}81]/' 2>&1")
        took = round(time.time() - started, 1)
        print(f"FINDING {label}: an unused address of the service prefix: curl rc={status} after {took}s (bound 2s) {out.strip()}")
        assert status == 7 and took < 2, (status, took, out)
        for what, target in [("an unused address of the service prefix", f"{base}81"), ("an unassigned subnet of the delegated prefix", f"{block}:7::1")]:
            status, out = isp.execute(f"ping -c1 -W3 {target} 2>&1")
            print(f"FINDING {label}: {what}: ping rc={status}\n{out.strip()}")
            assert status != 0 and "Destination unreachable: No route" in out, out

    start_all()
    with state_dump_on_failure(
        [isp, router, client, laptop, node],
        extra=[
            "journalctl -u router-prefix -u corerad --no-pager | tail -n 60",
            "cat /run/netif/pd/eth1 /var/lib/router/prefix.json /run/router/corerad.toml",
        ],
    ):
        with subtest("versions; the first boot is not held up"):
            for machine in [isp, router, client, laptop, node]:
                machine.wait_for_unit("multi-user.target", timeout=300)
            print_versions(router, ["kernel", "ifstate", "dhcpcd", "nftables", "coredns", "kea"])
            # suite-lib's corerad command finds no version: corerad prints it only when it starts
            print(f"VERSION router corerad: {router.succeed('journalctl -b -u corerad --no-pager -o cat | grep -m1 -o \"CoreRAD v[0-9.]*\"').strip()}")
            print_versions(isp, ["kernel", "kea"])
            print_versions(client, ["kernel", "ifstate", "dhcpcd"])
            print(f"VERSION laptop networkmanager: {laptop.succeed('NetworkManager --version').strip()}")
            assert_boot("first boot")
            isp.wait_until_succeeds("ss -uln | grep ':547 ' >/dev/null", timeout=60)

        with subtest("N16: the router's links: leases, the delegated /60 and dhcpcd's routes"):
            router.wait_until_succeeds(f"grep -x '{FIRST}::/60' /run/netif/pd/eth1 >/dev/null", timeout=120)
            router.wait_until_succeeds("ip -4 -o addr show dev eth1 scope global | grep 192.0.2.1 >/dev/null", timeout=120)
            router.wait_until_succeeds(f"ip -6 -o addr show dev eth2 scope global | grep '{FIRST}:1::1/64' >/dev/null", timeout=60)
            router.wait_until_succeeds(f"ip -6 -o addr show dev eth3 scope global | grep '{FIRST}:2::1/64' >/dev/null", timeout=60)
            observe("router addresses", router, "ip -br addr")
            observe("router IPv6 routes", router, "ip -6 route show table all | grep -v '^local\\|^multicast\\|fe80'")
            # an unassigned subnet is refused without any rule (G20)
            router.succeed(f"ip -6 route show proto dhcp | grep '^unreachable {FIRST}::/60 dev lo' >/dev/null")
            router.succeed(f"ip -6 route show proto dhcp | grep '^{FIRST}:1::/64 dev eth2' >/dev/null")
            router.succeed(f"ip -6 route show proto dhcp | grep '^{FIRST}:2::/64 dev eth3' >/dev/null")
            print("GATEWAY_ROUTER_LINKS_OK")

        with subtest("G15: corerad advertises the delegated /64, the ULA, RDNSS, DNSSL and PREF64"):
            for machine, zone in [(client, 1), (laptop, 1), (node, 2)]:
                machine.wait_until_succeeds(f"ip -6 -o addr show dev eth1 scope global -deprecated | grep '{FIRST}:{zone}:' >/dev/null", timeout=120)
                machine.wait_until_succeeds(f"ip -6 -o addr show dev eth1 scope global -deprecated | grep 'fd00:10:{zone}:' >/dev/null", timeout=60)
                machine.wait_until_succeeds("ip -6 route show default | grep 'via fe80::.* proto ra' >/dev/null", timeout=60)
                observe(f"{machine.name} addresses and routes", machine, "ip -br addr; ip -6 route; ip -4 route")
            client.wait_until_succeeds("ip -4 -o addr show dev eth1 scope global | grep 192.168.10.1 >/dev/null", timeout=120)
            ra = assert_advertised("first prefix", FIRST, [])
            print(f"FINDING the advertisement on the home zone: {ra}")
            assert ra["prefixes"][f"{FIRST}:1::/64"] == {"Valid time": 5400, "Pref. time": 2700}, ra
            assert (ra["rdnss"], ra["dnssl"], ra["pref64"]) == (["fd00:10:1::1"], ["home.test"], ["64:ff9b::/96"]), ra
            # the metrics name each prefix
            metrics = router.succeed("curl -sS http://[::1]:9430/metrics")
            for interface, prefix in [("eth2", f"{FIRST}:1::/64"), ("eth2", "fd00:10:1::/64"), ("eth3", f"{FIRST}:2::/64"), ("eth3", "fd00:10:2::/64")]:
                assert f'corerad_advertiser_prefix_autonomous{{interface="{interface}",prefix="{prefix}"}} 1' in metrics, metrics
            # corerad started before the prefix was delegated and was not restarted for it
            started = int(router.succeed("date -d \"$(systemctl show corerad.service -P ActiveEnterTimestamp)\" +%s"))
            delegated = int(router.succeed("stat -c %Y /run/netif/pd/eth1"))
            lines = hook_lines()
            print(f"FINDING corerad started {delegated - started}s before the prefix was delegated; the hook: {lines}")
            assert started <= delegated, (started, delegated)
            assert f"current {FIRST}::/60, retired [], service {FIRST}:f::/64, corerad unchanged" in lines[-1], lines
            assert router.succeed("journalctl -b -u corerad --no-pager | grep -c 'starting with configuration'").strip() == "1"
            # netif clients take DNS from DHCP, not from RDNSS (specs/netif.md N39)
            dns = client.succeed("resolvectl dns eth1")
            assert "192.168.10.1" in dns and "fd00:10:1::1" not in dns, dns
            print("GATEWAY_ROUTER_RA_OK")

        with subtest("G15: stopping corerad withdraws the default route, a start brings it back"):
            router.succeed("systemctl stop corerad.service")
            took = seconds_until(client, "test -z \"$(ip -6 route show default)\"", limit=15)
            print(f"FINDING the client lost its default route {took}s after corerad stopped (bound 15s)")
            assert took is not None
            router.succeed("systemctl start corerad.service")
            for machine in [client, laptop, node]:
                machine.wait_until_succeeds("ip -6 route show default | grep 'via fe80::.* proto ra' >/dev/null", timeout=60)

        with subtest("G8, G10, G14: NAT44, native IPv6, source address choice beside a ULA, DNS and the blocklist"):
            wan_v4 = json.loads(router.succeed("ip -j -4 addr show dev eth1 scope global"))[0]["addr_info"][0]["local"]
            answer = client.succeed("curl -sS --max-time 5 http://192.0.2.1/").strip()
            assert answer == f"::ffff:{wan_v4}", f"NAT44: the ISP saw {answer}"
            client_v6 = client.succeed(f"curl -sS --max-time 5 'http://[{ISP}]/'").strip()
            assert client_v6.startswith(f"{FIRST}:1:"), f"native IPv6: the ISP saw {client_v6}"
            # to a public address the public source, to the ULA the ULA source
            client.succeed("ip -6 route get fd00:10:1::1 | grep 'src fd00:10:1:' >/dev/null")
            for server in ["@192.168.10.1", "@fd00:10:1::1", ""]:
                assert client.succeed(f"dig +short web.test {server}").strip() == "192.0.2.1", server
            assert client.succeed("dig +short ad299999.block.test @192.168.10.1").strip() == "0.0.0.0"
            millis = int(client.succeed("dig +noall +stats ad150000.block.test @192.168.10.1 | sed -n 's/.*Query time: \\([0-9]*\\) msec.*/\\1/p'"))
            peak = int(router.succeed("systemctl show coredns.service -P MemoryPeak"))
            print(f"FINDING CoreDNS with 300 000 blocked names: a blocked name answered in {millis} ms (bound 100 ms), memory peak {peak >> 20} MiB (bound 420 MiB)")
            assert millis < 100 and peak < 420 << 20, (millis, peak)

        with subtest("G11: default deny between zones, one allowed and one refused flow per direction"):
            client_v4 = json.loads(client.succeed("ip -j -4 addr show dev eth1 scope global"))[0]["addr_info"][0]["local"]
            # servers to wan: allowed in both families (home to wan is above)
            assert node.succeed("curl -sS --max-time 5 http://192.0.2.1/").strip() == f"::ffff:{wan_v4}"
            node_v6 = node.succeed(f"curl -sS --max-time 5 'http://[{ISP}]/'").strip()
            assert node_v6.startswith(f"{FIRST}:2:"), node_v6
            # home to the router: DNS is allowed (above); from the wan it is not
            status, out = isp.execute(f"dig +time=2 +tries=1 +short web.test @{wan_v4} 2>&1")
            assert status == 9 and "timed out" in out, (status, out)
            refused("home to servers over IPv4", client, "http://192.168.20.10/")
            refused("home to servers over IPv6", client, f"http://[{node_v6}]/")
            refused("servers to home over IPv4", node, f"http://{client_v4}/")
            refused("servers to home over IPv6", node, f"http://[{client_v6}]/")
            refused("wan to home, a client's public IPv6 address", isp, f"http://[{client_v6}]/")
            refused("wan to servers, a node's public IPv6 address", isp, f"http://[{node_v6}]/")
            observe("drop counters", router, "nft list table inet router | grep counter")
            for chain in ["input", "forward"]:
                router.succeed(f"nft list table inet router | grep 'counter packets [1-9][0-9]* .*{chain} dropped' >/dev/null")

        with subtest("G20: a service /64 of the delegated prefix rewritten to a stable ULA /64"):
            service_routes()
            service_checks("first prefix", FIRST)

        with subtest("an IfState apply on the router proposes no change and changes nothing"):
            rules = router.succeed("nft -s list ruleset")
            runs = hook_runs()
            assert_ifstate_noop(router)
            assert router.succeed("nft -s list ruleset") == rules
            assert hook_runs() == runs
            router.succeed(f"ip -6 route show proto bgp | grep '^{STABLE} ' >/dev/null")
            service_checks("after an IfState apply", FIRST, full=False)
            answer = source(client)
            assert answer is not None and answer.startswith(f"{FIRST}:1:"), answer

        with subtest("nftables: one table per owner; a restart of one owner leaves the other tables byte-equal"):
            tables = sorted(router.succeed("nft -j list tables | jq -r '.nftables[] | select(.table) | .table | .family + \" \" + .name'").splitlines())
            print(f"FINDING nftables tables on the router: {tables}; 'inet router' is nftables.service's (zones, NAT44, pinholes), 'inet router_svc' is the prefix hook's (the service rewrite)")
            assert tables == ["inet router", "inet router_svc"], tables
            # a third owner, as Cilium or a dual-WAN steering unit would be
            router.succeed("printf 'table inet foreign { chain forward { type filter hook forward priority 10; counter comment \"another owner\"; }; }\\n' | nft -f -")

            def snapshot():
                return {name: router.succeed(f"nft -s list table inet {name}") for name in ["router", "router_svc", "foreign"]}

            before = snapshot()
            assert "dnat ip6 prefix" in before["router_svc"] and "another owner" in before["foreign"], before
            # why a table has one owner: a rule that a second writer adds to
            # the owner's table is gone after the owner's restart
            router.succeed("nft add rule inet router forward counter comment '\"not the owner\"'")
            router.succeed("systemctl restart nftables.service")
            after = snapshot()
            assert after == before, f"a restart of nftables.service changed a table: {before} -> {after}"
            service_checks("after a restart of nftables.service", FIRST, full=False)
            router.succeed("systemctl restart router-prefix.service")
            after = snapshot()
            assert after == before, f"a run of the prefix hook changed a table: {before} -> {after}"
            # nothing that the two owners run flushes the ruleset
            router.succeed(
                "files=$(systemctl cat nftables.service router-prefix.service | grep -Eo '/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+/-]*' | sort -u); "
                "more=$( (grep -EhIso '/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+/-]*' $files || true) | sort -u); "
                "for file in $files $more; do if test -f \"$file\"; then echo \"$file\"; fi; done | sort -u > /tmp/nft-owner-files"
            )
            searched = router.succeed("cat /tmp/nft-owner-files").split()
            ruleset = router.execute("grep -Il 'table inet router {' $(cat /tmp/nft-owner-files)")[1].split()
            flushes = router.execute("grep -EIl 'flush[[:space:]]+ruleset' $(cat /tmp/nft-owner-files)")[1].split()
            print(f"FINDING searched {len(searched)} files of the two owners for 'flush ruleset'; the router's table is in {ruleset}; found in {flushes}")
            assert any(name.endswith("router-prefix") for name in searched) and ruleset, searched
            assert flushes == [], flushes
            router.succeed("nft delete table inet foreign")

        with subtest("G22: a restart of dhcpcd that brings the same prefix does not run the hook, watched for 5 s"):
            before = hook_runs()
            count = "journalctl -b -u netif-dhcpcd-eth1 --no-pager | grep -c 'delegated prefix'"
            leases = int(router.succeed(f"{count} || true"))
            router.succeed("systemctl restart netif-dhcpcd-eth1.service")
            router.wait_until_succeeds(f"test \"$({count})\" -gt {leases}", timeout=120)
            router.wait_until_succeeds(f"ip -6 -o addr show dev eth2 scope global | grep '{FIRST}:1::1/64' >/dev/null", timeout=60)
            holds_for(router, f"test \"$(journalctl -u router-prefix --no-pager | grep -c 'router-prefix: current')\" -eq {before} && grep -x '{FIRST}::/60' /run/netif/pd/eth1 >/dev/null", 5)
            # the restart is followed by an IfState apply: routes of proto bgp stay
            router.succeed(f"ip -6 route show proto bgp | grep '^{STABLE} ' >/dev/null")
            service_checks("after a restart of dhcpcd", FIRST, full=False)

        with subtest("G22: the ISP changes the prefix while the router runs"):
            client.succeed("ip -6 monitor route > /tmp/routes.txt 2>&1 & echo $! > /tmp/monitor.pid")
            isp_delegates("renumber")
            first_change = router_renews(RENUMBER, 60)
            took = settle("live change", client, first_change, RENUMBER, [FIRST], 20)
            settle("live change", laptop, first_change, RENUMBER, [FIRST], 30)
            assert_advertised("live change", RENUMBER, [FIRST])
            lines = hook_lines()
            assert f"current {RENUMBER}::/60, retired ['{FIRST}::/60'], service {RENUMBER}:f::/64, corerad restarted" in lines[-1], lines
            router.succeed(f"journalctl -b -u corerad --no-pager | grep '{FIRST}:1::/64 \\[DEPRECATED, on-link, autonomous\\], preferred: 1s, valid: 2h0m0s' >/dev/null")
            router.succeed("systemctl is-active corerad.service")
            # the restart of corerad never withdrew the client's default route
            client.succeed("kill $(cat /tmp/monitor.pid)")
            observe("route changes on the client during the change", client, "cat /tmp/routes.txt")
            client.fail("grep -i 'deleted.*default' /tmp/routes.txt")
            service_checks("second prefix", RENUMBER, full=False)

        with subtest("G22: a second change right after the first, to a /56: both older prefixes end up retired"):
            isp_delegates("wide")
            second_change = router_renews(WIDE, 56)
            print(f"FINDING the second prefix change reached the router {round(second_change - first_change, 1)}s after the first")
            settle("second change", client, second_change, WIDE, [FIRST, RENUMBER], 20)
            settle("second change", laptop, second_change, WIDE, [FIRST, RENUMBER], 30)
            assert_advertised("second change", WIDE, [FIRST, RENUMBER])
            state = json.loads(router.succeed("cat /var/lib/router/prefix.json"))
            assert state["current"] == f"{WIDE}::/56" and sorted(state["retired"]) == [f"{FIRST}::/60", f"{RENUMBER}::/60"], state
            for zone, interface in [(1, "eth2"), (2, "eth3")]:
                router.succeed(f"ip -6 -o addr show dev {interface} scope global | grep '{WIDE}:{zone}::1/64' >/dev/null")
            router.succeed(f"ip -6 route show proto dhcp | grep '^unreachable {WIDE}::/56 dev lo' >/dev/null")
            service_checks("a /56", WIDE)
            # a subnet id that a /60 does not have
            status, out = isp.execute(f"ping -c1 -W3 {WIDE}:80::1 2>&1")
            assert status != 0 and "Destination unreachable: No route" in out, out
            for block in [FIRST, RENUMBER]:
                refused(f"the service address of the retired {block}", isp, f"http://[{block}:f::80]/")

        with subtest("G22: the prefix changes while the router is off; the hook's state is on disk; the boot is not held up"):
            router.shutdown()
            isp_delegates("first")
            router.start()
            assert_boot("reboot with a prefix change")
            router.wait_until_succeeds(f"grep -x '{FIRST}::/60' /run/netif/pd/eth1 >/dev/null", timeout=120)
            started = time.time()
            settle("change across a reboot", client, started, FIRST, [RENUMBER, WIDE], 20)
            settle("change across a reboot", laptop, started, FIRST, [RENUMBER, WIDE], 30)
            assert_advertised("change across a reboot", FIRST, [RENUMBER, WIDE])
            lines = hook_lines()
            print(f"FINDING the hook in this boot: {lines}")
            # first the state from disk, then the new prefix
            assert f"current {WIDE}::/56, retired ['{FIRST}::/60', '{RENUMBER}::/60'], service None" in lines[0], lines
            assert f"current {FIRST}::/60, retired ['{RENUMBER}::/60', '{WIDE}::/56'], service {FIRST}:f::/64" in lines[-1], lines
            service_routes()
            service_checks("after the reboot", FIRST, full=False)
            refused(f"the service address of the retired {WIDE}", isp, f"http://[{WIDE}:f::80]/")

        with subtest("G22: a delegated /64 has no room for a zone: nothing of it is advertised, the old prefix is retired"):
            isp_delegates("single")
            started = router_renews(SINGLE, 64)
            retired = {FIRST, RENUMBER, WIDE}
            took = seconds_since(started, lambda: blocks(client) == (set(), retired), 20)
            print(f"FINDING a /64: the client had no preferred public address {took}s after the router had the prefix (bound 20s); blocks {blocks(client)}")
            assert took is not None
            took = seconds_since(started, lambda: blocks(laptop) == (set(), retired), 30)
            assert took is not None, blocks(laptop)
            assert_advertised("a /64", None, sorted(retired))
            observe("a /64: dhcpcd", router, "journalctl -b -u netif-dhcpcd-eth1 --no-pager | tail -n 25")
            observe("a /64: the router's addresses and dhcpcd's routes", router, "ip -6 -br addr; ip -6 route show proto dhcp")
            # never a wrong prefix: no address of the /64 on a zone, no rule
            router.fail(f"ip -6 -o addr show scope global | grep '{SINGLE}:'")
            # dhcpcd refuses the subnets ("invalid prefix") and rejects the whole /64
            assert router.succeed("ip -6 route show proto dhcp").strip().startswith(f"unreachable {SINGLE}::/64 dev lo"), "dhcpcd left a route into a zone"
            lines = hook_lines()
            assert f"current {SINGLE}::/64, retired ['{FIRST}::/60', '{RENUMBER}::/60', '{WIDE}::/56'], service None, corerad restarted" in lines[-1], lines
            assert "dnat" not in router.succeed("nft list table inet router_svc")
            assert router.succeed("systemctl show router-prefix.service -P Result").strip() == "success"
            router.succeed("systemctl is-active corerad.service")
            refused(f"the service address of the retired {FIRST}", isp, f"http://[{FIRST}:f::80]/")
            # IPv4 and the ULA are untouched
            assert client.succeed("curl -sS --max-time 5 http://192.0.2.1/").strip() == f"::ffff:{wan_v4}"
            client.succeed("ip -6 -o addr show dev eth1 scope global -deprecated | grep 'fd00:10:1:' >/dev/null")

        with subtest("G22: after the /64 a /60 again: the zones and the service come back"):
            isp_delegates("first")
            started = router_renews(FIRST, 60)
            settle("back to a /60", client, started, FIRST, [RENUMBER, WIDE], 20)
            settle("back to a /60", laptop, started, FIRST, [RENUMBER, WIDE], 30)
            # the /64 is retired too, and has no /64 for a zone to list
            assert_advertised("back to a /60", FIRST, [RENUMBER, WIDE])
            service_checks("back to a /60", FIRST, full=False)

        with subtest("G22: the prefix changes while the router is off and the hook's state is lost"):
            router.succeed("rm /var/lib/router/prefix.json")
            router.shutdown()
            isp_delegates("renumber")
            router.start()
            assert_boot("reboot without the hook's state")
            router.wait_until_succeeds(f"grep -x '{RENUMBER}::/60' /run/netif/pd/eth1 >/dev/null", timeout=120)
            # The hook cannot retire a prefix it does not know. A client keeps
            # the old prefix as preferred beside the new one, until the
            # advertised preferred lifetime (45 min) runs out, and picks its
            # source by the longest match with the destination: here the old
            # one, so IPv6 to the internet is dead meanwhile.
            # FINDING a gap in specs/gateway.md G22 ("keeps the last prefix on
            # disk"): that file is all that retires a prefix after a reboot.
            for machine in [client, laptop]:
                took = seconds_since(time.time(), lambda: blocks(machine) == ({FIRST, RENUMBER}, {WIDE}), 30)
                observe(f"state lost: {machine.name} addresses", machine, "ip -6 addr show dev eth1 scope global; ip -6 route get 2001:db8::1")
                assert took is not None, f"{machine.name}: {blocks(machine)}"
                stale = [
                    info["preferred_life_time"]
                    for info in json.loads(machine.succeed("ip -j -6 addr show dev eth1 scope global"))[0]["addr_info"]
                    if info.get("local", "").startswith(FIRST + ":")
                ]
                print(f"FINDING state lost: {machine.name} still prefers the old prefix, for another {stale} s (bound 2700 s)")
                assert stale and max(stale) <= 2700, stale
                machine.succeed(f"ip -6 route get {ISP} | grep 'src {FIRST}:1:' >/dev/null")
                answer = source(machine)
                assert answer is None, f"{machine.name} reached the ISP as {answer}"
            assert_advertised("state lost", RENUMBER, [])
            service_routes()
            service_checks("state lost", RENUMBER, full=False, home=False)

        print("GATEWAY_ROUTER_OK")
  '';
}
