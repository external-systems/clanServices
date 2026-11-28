# hostile-router: hostile actors against the `router` service. Hermetic:
# three test VLANs, no real network. The topology is the `router`
# suite's, smaller.
#
#   isp ── vlan 1 ── router ── vlan 2 ── client    (zone home, the victim)
#   (hostile WAN)       │          └──── intruder  (zone home, hostile)
#                       └───── vlan 3 ── node      (zone servers)
#
# The ISP is the router's real upstream (DHCPv4, DHCPv6 with a delegated
# prefix, router advertisements) and the attacker on the WAN at once.
#
# Every attack ends in one `verdict(id, safe, detail)`. The suite runs
# all of them, prints a `HOSTILE SAFE|GAP <id>` line each, and fails at
# the end when any is a gap. `info(...)` lines report behaviour the
# owner decides on. A new attack is a new verdict; never delete one to
# make the suite pass.
{
  inputs,
  lib,
  ...
}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  echo = import ../../../../lib/gateway/tests/vm/echo.nix;
  # the driver gives node N on vlan V the MAC 52:54:00:12:0V:0N; the
  # nodes sort as client, intruder, isp, node, router
  routerWanLinkLocal = "fe80::5054:ff:fe12:105";
  prefix = "2001:db8:1000";
  tools = pkgs: [
    pkgs.nmap
    pkgs.netcat-openbsd
    pkgs.curl
    pkgs.dig
    pkgs.tcpdump
    pkgs.jq
  ];
  lanHost = vlan: {pkgs, ...}: {
    virtualisation = {
      cores = 1;
      memorySize = 1024;
      vlans = [vlan];
    };
    networking.firewall.enable = false;
    environment.systemPackages = tools pkgs;
    systemd.services.echo = {
      wantedBy = ["multi-user.target"];
      serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [80]}";
    };
  };
in {
  name = "hostile-router";

  clan = {
    directory = ./.;
    test.useContainers = false;
    inventory = {
      machines = lib.genAttrs ["client" "intruder" "isp" "node" "router"] (_: {});
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
            intruder.settings.links.uplink = {
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
        edge = {
          module.name = "router";
          module.input = "self";
          roles.router.machines.router.settings = {
            zones = {
              home = {};
              servers = {};
            };
            domain = "home.test";
            dns.upstream = ["192.0.2.1"];
          };
        };
      };
    };
  };

  nodes = {
    router = {pkgs, ...}: {
      virtualisation = {
        cores = 2;
        memorySize = 2048;
        vlans = [1 2 3];
      };
      environment.systemPackages = tools pkgs;
    };
    client = lanHost 2;
    node = lanHost 3;
    intruder = {pkgs, ...}: {
      imports = [(lanHost 2)];
      # a rogue router advertisement, started by the test. radvd is a
      # fixture here only: the router's RA daemon is CoreRAD (SPEC.md H23)
      services.radvd = {
        enable = true;
        config = ''
          interface eth1 {
            AdvSendAdvert on;
            AdvDefaultPreference high;
            # radvd refuses an interface whose Min is not between 3 s and
            # 3/4 of Max; its default Min (a third of Max) is 1.3 s here,
            # so without this line no advertisement was ever sent (R15)
            MinRtrAdvInterval 3;
            MaxRtrAdvInterval 4;
            prefix 2001:db8:bad::/64 {};
            route ::/0 {};
          };
        '';
      };
      systemd.services.radvd.wantedBy = lib.mkForce [];
      environment.systemPackages = [pkgs.radvd];
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
              to = "${prefix}::/48";
              via = routerWanLinkLocal;
              dev = "eth1";
            }
          ];
          withBase = true;
        })
      ];
      virtualisation = {
        cores = 2;
        memorySize = 1024;
        vlans = [1];
      };
      environment.systemPackages = tools pkgs;
      boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
      networking.firewall.enable = false;
      systemd.services = {
        echo = {
          wantedBy = ["multi-user.target"];
          serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [80]}";
        };
        coredns.after = ["ifstate.service"];
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
          dhcp6 = {
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
                      prefix = "${prefix}::";
                      prefix-len = 56;
                      delegated-len = 60;
                    }
                  ];
                }
              ];
            };
          };
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
    };
  };

  testScript = ''
    import json

    ISP = "2001:db8::1"
    PREFIX = "${prefix}"
    ROUTER_WAN_LL = "${routerWanLinkLocal}"
    everyone = [isp, router, client, intruder, node]
    RESULTS = []


    def verdict(key, safe, detail=""):
        RESULTS.append((key, bool(safe), detail))
        print(f"HOSTILE {'SAFE' if safe else 'GAP '} {key}: {detail}")


    def info(key, detail):
        print(f"HOSTILE INFO {key}: {detail}")


    def scan(machine, target, ports="-", flags="-sS"):
        """Open ports of one address, as `machine` sees them."""
        family = "-6" if ":" in target else ""
        out = machine.succeed(f"nmap {family} -n -Pn {flags} -p{ports} --min-rate 3000 --max-retries 1 -oG - {target} 2>&1")
        found = []
        for line in out.splitlines():
            if "Ports:" in line:
                found += [int(p.split("/")[0].strip()) for p in line.split("Ports:")[1].split(",") if "/open/" in p]
        return sorted(found)


    def capture(machine, unit, iface, expr):
        machine.execute(f"systemctl stop {unit} 2>/dev/null; systemctl reset-failed {unit} 2>/dev/null; rm -f /tmp/{unit}")
        machine.succeed(f"systemd-run --unit={unit} $(command -v tcpdump) -pUni {iface} -Q in -w /tmp/{unit} '{expr}'")
        machine.wait_until_succeeds(f"test -s /tmp/{unit}", timeout=20)


    def captured(machine, unit):
        machine.execute("sleep 1")
        machine.execute(f"systemctl stop {unit}")
        out = machine.succeed(f"tcpdump -nr /tmp/{unit} 2>/dev/null || true")
        return [line for line in out.splitlines() if line.strip()]


    def global6(machine, iface, start):
        for entry in json.loads(machine.succeed(f"ip -j -6 addr show dev {iface} scope global"))[0]["addr_info"]:
            if entry.get("local", "").startswith(start):
                return entry["local"]
        raise AssertionError(f"{machine.name}: no address in {start} on {iface}")


    start_all()
    try:
        with subtest("the router and its hosts are up before any attack"):
            for machine in everyone:
                machine.wait_for_unit("multi-user.target", timeout=300)
            router.wait_until_succeeds(f"grep -x '{PREFIX}::/60' /run/netif/pd/eth1 >/dev/null", timeout=120)
            router.wait_until_succeeds(f"ip -6 -o addr show dev eth2 scope global | grep '{PREFIX}:1::1/64' >/dev/null", timeout=60)
            for host in [client, intruder, node]:
                host.wait_until_succeeds(f"curl -sS --max-time 5 'http://[{ISP}]/'", timeout=180)
                host.wait_until_succeeds("curl -sS --max-time 5 http://192.0.2.1/", timeout=60)
            wan_v4 = json.loads(router.succeed("ip -j -4 addr show dev eth1 scope global"))[0]["addr_info"][0]["local"]
            wan_v6 = global6(router, "eth1", "2001:db8::")
            client_v4 = json.loads(client.succeed("ip -j -4 addr show dev eth1 scope global"))[0]["addr_info"][0]["local"]
            client_v6 = client.succeed(f"curl -sS --max-time 5 'http://[{ISP}]/'").strip()
            node_v6 = node.succeed(f"curl -sS --max-time 5 'http://[{ISP}]/'").strip()
            print(f"router WAN {wan_v4} {wan_v6}; client {client_v4} {client_v6}; node {node_v6}")
            # the targets answer: a closed port below is the router's doing
            client.succeed("curl -sS --max-time 5 http://127.0.0.1/")

        # ------------------------------------------------------------------
        # The hostile WAN
        # ------------------------------------------------------------------
        with subtest("wan: full scans of the router's WAN addresses"):
            found = scan(isp, wan_v4)
            verdict("R01 no TCP port open on the router's WAN address (IPv4)", not found, f"open: {found}")
            found = scan(isp, wan_v6)
            verdict("R02 no TCP port open on the router's WAN address (IPv6)", not found, f"open: {found}")
            found = scan(isp, f"{ROUTER_WAN_LL}%eth1")
            verdict("R03 no TCP port open on the router's WAN link-local address", not found, f"open: {found}")
            for server in [wan_v4, wan_v6]:
                code, out = isp.execute(f"dig +time=2 +tries=1 +short web.test @{server}")
                verdict(f"R04 the router's resolver does not answer the WAN ({server})", code != 0 or not out.strip(), out.strip())

        with subtest("wan: the LAN behind the router"):
            isp.succeed(f"ip route add 192.168.10.0/24 via {wan_v4}; ip route add 192.168.20.0/24 via {wan_v4}")
            isp.succeed(f"ip -6 route add fd00:10::/32 via {ROUTER_WAN_LL} dev eth1")
            targets = [
                ("the client's private IPv4 address", client_v4),
                ("the client's public IPv6 address", client_v6),
                ("the node's private IPv4 address", "192.168.20.10"),
                ("the node's public IPv6 address", node_v6),
                ("the router's home address (IPv4)", "192.168.10.1"),
                ("the router's home address (ULA)", "fd00:10:1::1"),
                ("the router's home address (delegated)", f"{PREFIX}:1::1"),
            ]
            for label, target in targets:
                found = scan(isp, target)
                verdict(f"R05 the WAN reaches no TCP port of {label}", not found, f"{target} open: {found}")
            for label, target in targets[:4]:
                flag = "-6" if ":" in target else ""
                code, _ = isp.execute(f"ping {flag} -c 2 -W 1 {target}")
                verdict(f"R06 the WAN gets no ping reply from {label}", code != 0, target)
            # an ACK without a flow, and UDP
            capture(client, "cap-r07", "eth1", f"src host {ISP}")
            isp.execute(f"nmap -6 -n -Pn -sA -p80,443 --max-retries 0 {client_v6} >/dev/null 2>&1")
            isp.execute(f"nmap -6 -n -Pn -sU -p53,123,5353 --max-retries 0 {client_v6} >/dev/null 2>&1")
            seen = captured(client, "cap-r07")
            verdict("R07 no unasked packet from the WAN reaches a LAN host (TCP ACK, UDP)", not seen, f"{len(seen)} packets: {seen[:2]}")

        with subtest("wan: a forged LAN source"):
            isp.succeed(f"ip -6 addr add {PREFIX}:1::bad/128 dev lo; ip addr add 192.168.10.66/32 dev lo")
            capture(node, "cap-r08", "eth1", "(icmp or icmp6) and (src net 192.168.10.0/24 or src net ${prefix}:1::/64)")
            isp.execute(f"ping -6 -c 2 -W 1 -I {PREFIX}:1::bad {node_v6}")
            isp.execute("ping -c 2 -W 1 -I 192.168.10.66 192.168.20.10")
            seen = captured(node, "cap-r08")
            verdict("R08 a packet from the WAN with a home-zone source does not reach the servers zone", not seen, f"{len(seen)} packets: {seen[:2]}")
            isp.succeed(f"ip -6 addr del {PREFIX}:1::bad/128 dev lo; ip addr del 192.168.10.66/32 dev lo")

        # ------------------------------------------------------------------
        # The intruder: a hostile host in the home zone
        # ------------------------------------------------------------------
        with subtest("intruder: the router's own addresses"):
            for label, target, allowed in [
                ("its zone's router address (IPv4)", "192.168.10.1", [53]),
                ("its zone's router address (ULA)", "fd00:10:1::1", [53]),
                ("the other zone's router address (IPv4)", "192.168.20.1", []),
                ("the other zone's router address (ULA)", "fd00:10:2::1", []),
                ("the router's WAN address (IPv4)", wan_v4, []),
                ("the router's WAN address (IPv6)", wan_v6, []),
            ]:
                found = scan(intruder, target)
                extra = [p for p in found if p not in allowed]
                verdict(f"R10 a home host reaches only DNS on {label}", not extra, f"{target} open: {found}")

        with subtest("intruder: the other zone"):
            for label, target in [("IPv4", "192.168.20.10"), ("IPv6", node_v6)]:
                found = scan(intruder, target)
                verdict(f"R11 a home host reaches no TCP port of a servers-zone host ({label})", not found, f"open: {found}")
                flag = "-6" if ":" in target else ""
                code, _ = intruder.execute(f"ping {flag} -c 2 -W 1 {target}")
                verdict(f"R12 a home host gets no ping reply from a servers-zone host ({label})", code != 0)

        with subtest("intruder: forged sources"):
            intruder.succeed("ip addr add 192.168.20.77/32 dev lo; ip -6 addr add 2001:db8:dead::1/128 dev lo")
            capture(isp, "cap-r13", "eth1", "(icmp or icmp6) and (src net 192.168.0.0/16 or src net 2001:db8:dead::/48)")
            capture(node, "cap-r14", "eth1", "icmp and src host 192.168.20.77")
            intruder.execute("ping -c 2 -W 1 -I 192.168.20.77 192.0.2.1")
            intruder.execute(f"ping -6 -c 2 -W 1 -I 2001:db8:dead::1 {ISP}")
            intruder.execute("ping -c 2 -W 1 -I 192.168.20.77 192.168.20.10")
            leaked = captured(isp, "cap-r13")
            verdict("R13 a forged or private source from the LAN never reaches the ISP", not leaked, f"{len(leaked)} packets: {leaked[:2]}")
            forged = captured(node, "cap-r14")
            verdict("R14 a home host cannot send into the servers zone with a servers-zone source", not forged, f"{len(forged)} packets: {forged[:2]}")
            intruder.succeed("ip addr del 192.168.20.77/32 dev lo; ip -6 addr del 2001:db8:dead::1/128 dev lo")

        with subtest("intruder: a rogue router advertisement on the LAN"):
            before = router.succeed("ip -6 route show table all | grep -v ' expires ' | sort; ip -6 -o addr show scope global | awk '{print $2, $4}' | sort")
            # the router hears every advertisement the intruder sends on
            # the home link (inbound only: CoreRAD's own are outbound)
            capture(router, "cap-r15", "eth2", "icmp6 and ip6[40] == 134 and src host fe80::5054:ff:fe12:202")
            intruder.succeed("sysctl -w net.ipv6.conf.all.forwarding=1; systemctl start radvd")
            # the controls: the rogue advertisement reached the router's
            # link, and a LAN neighbour that listens took its prefix.
            # Without them the attack did not run, and "safe" below would
            # mean nothing.
            arrived = client.execute("for i in $(seq 30); do ip -6 -o addr show dev eth1 scope global | grep 2001:db8:bad >/dev/null && exit 0; sleep 1; done; exit 1")[0] == 0
            router.succeed("sleep 15")
            heard = captured(router, "cap-r15")
            info("R15 control: rogue advertisements captured on the router's home link, and a LAN neighbour took the rogue prefix", f"{len(heard)} captured; neighbour: {arrived}; radvd: " + intruder.execute("systemctl is-active radvd; journalctl -b -u radvd -o cat --no-pager | tail -n 3")[1].strip().replace("\n", " | "))
            assert heard and arrived, f"R15: the rogue router advertisement did not run (captured {len(heard)}, neighbour took the prefix: {arrived})"
            after = router.succeed("ip -6 route show table all | grep -v ' expires ' | sort; ip -6 -o addr show scope global | awk '{print $2, $4}' | sort")
            verdict("R15 the router takes no route or address from a router advertisement on a LAN link", before == after, "" if before == after else f"before:\n{before}\nafter:\n{after}")
            rogue = client.succeed("ip -6 route show default; ip -6 -o addr show dev eth1 scope global | grep 2001:db8:bad || true")
            info("R16 what a LAN neighbour took from the rogue advertisement (layer 2; a switch's RA guard stops it)", rogue.strip().replace("\n", " | "))
            intruder.succeed("systemctl stop radvd")

        print("HOSTILE SUMMARY")
        for key, safe, detail in RESULTS:
            print(f"  {'SAFE' if safe else 'GAP '} {key}" + (f" [{detail}]" if not safe else ""))
        gaps = [key for key, safe, _ in RESULTS if not safe]
        assert not gaps, f"{len(gaps)} gap(s): {gaps}"
        print("HOSTILE_ROUTER_OK")
    except Exception:
        router.execute("nft list ruleset >&2; ip -br addr >&2; ip -6 route >&2")
        raise
  '';
}
