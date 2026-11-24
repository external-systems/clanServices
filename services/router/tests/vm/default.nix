# router: the `router` service on the topology of the fixture suite
# gateway-router (specs/gateway.md §10.2, §10.3, §10.7; decisions G8,
# G10, G11, G14, G15, G20, G22; specs/netif.md N16, N39). The same
# proofs on the code a machine runs (§5, §14.1 point 1).
#
#   isp ── vlan 1 ── router ── vlan 2 ── client   (zone home, netif)
#                       │          └──── laptop   (zone home, NetworkManager)
#                       └───── vlan 3 ── node     (zone servers; stands in
#                                                  for a cluster node)
#
# netif renders the router's links (WAN DHCPv4, DHCPv6 and a delegated
# prefix; a /64 of it on each zone). The router service renders the
# rest from netif's facts: nftables zones and NAT44, kea, corerad,
# CoreDNS and the prefix hook. The suite adds test seams to the hook.
#
# It pins:
#   - G15: corerad advertises the delegated /64, the ULA /64, RDNSS,
#     DNSSL and PREF64; a stop withdraws the default route.
#   - G8, G10, G11, G14: NAT44, source address choice beside a ULA,
#     default deny between zones, a blocklist of 300 000 names.
#   - G20: a service /64 of the delegated prefix rewritten to a stable
#     ULA /64, and that it follows a prefix change with one rule.
#   - G22: the prefix hook from end to end. A live change by a restart of
#     dhcpcd and by a renewal of dhcpcd itself, two changes in a row, a
#     /56, a /64 that has no room for the zones, a change while the
#     router was off, with and without the hook's state on disk. The file
#     as a set, no file, an event while the hook runs, a run that fails
#     half way, a damaged state file. The hook never holds up a boot.
#   - G22: IPv6 leaves for the internet from a delegated prefix only; a
#     retired prefix or a ULA as the source gets an ICMPv6 error at once.
#   - G14: each zone's resolver answers in that zone only.
#   - nftables ownership (specs/gateway.md §12.2): one table per owner;
#     a restart of one owner leaves the other tables byte-equal.
#   - An IfState apply changes nothing.
{
  inputs,
  lib,
  ...
}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  echo = import ../../../../lib/gateway/tests/vm/echo.nix;

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
  name = "router";

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
        edge = {
          module.name = "router";
          module.input = "self";
          roles.router.machines.router.settings = {
            zones = {
              home = {};
              servers = {};
            };
            domain = "home.test";
            pref64 = "64:ff9b::/96";
            dns.upstream = ["192.0.2.1"];
            servicePrefix = {
              subnet = subnets.service;
              stable = "fd00:10:5::/64";
              expose = [
                {
                  address = "fd00:10:5::80";
                  protocol = "tcp";
                  ports = [80];
                }
              ];
            };
          };
        };
      };
    };
  };

  nodes = {
    # The router is the service. What stays here is the suite's: the
    # test seams of the hook (its `nft` and `systemctl` wait or fail on
    # request), a blocklist of 300 000 names, and the eval-time half of
    # "the subnet ids fit the delegation".
    router = {pkgs, ...}: let
      blocklist = pkgs.runCommand "blocklist-300k" {} ''
        seq 1 300000 | sed 's/.*/0.0.0.0 ad&.block.test/' > $out
      '';
      # Each waits while /run/router-test/hold-<name> exists and fails
      # while /run/router-test/fail-<name> exists; otherwise it is the tool.
      fault = name: package:
        pkgs.writeShellScriptBin name ''
          if [ -e /run/router-test/hold-${name} ]; then
            : > /run/router-test/held-${name}
            while [ -e /run/router-test/hold-${name} ]; do ${lib.getExe' pkgs.coreutils "sleep"} 0.1; done
          fi
          if [ -e /run/router-test/fail-${name} ]; then
            echo "${name}: failure injected by the test" >&2
            exit 1
          fi
          exec ${lib.getExe' package name} "$@"
        '';
      faults = pkgs.symlinkJoin {
        name = "router-prefix-faults";
        paths = [
          (fault "nft" pkgs.nftables)
          (fault "systemctl" pkgs.systemd)
        ];
      };
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
      assertions = [
        {
          assertion = fits delegations.first.length;
          message = "router: a subnet id of the router does not fit the /${toString delegations.first.length} it asks for (specs/gateway.md G22)";
        }
        {
          assertion = !(fits delegations.single.length);
          message = "router: the /64 phase needs a subnet id that does not fit a /64";
        }
      ];
      environment.systemPackages = [
        pkgs.jq
        pkgs.tcpdump
        pkgs.curl
        pkgs.coredns
      ];
      clanServices.gateway.router.dns.blocklist = lib.mkForce blocklist;
      systemd = {
        tmpfiles.rules = ["d /run/router-test 0755 root root -"];
        # the hook's nft and systemctl, behind the test seams
        services.router-prefix.path = lib.mkBefore [faults];
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
        pkgs.python3
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
        pkgs.dig
        pkgs.ndisc6
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
        pkgs.dig
        pkgs.nftables
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
                192.0.2.1 dual.test
                2001:db8::1 dual.test
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
    import re
    import time

    # the blocks the ISP delegates from, in the order of the phases
    FIRST, RENUMBER, WIDE, SINGLE = BLOCKS = ["2001:db8:1000", "2001:db8:2000", "2001:db8:3000", "2001:db8:4000"]
    ISP = "2001:db8::1"
    STABLE = "fd00:10:5::80"
    HOOK_TABLES = ["inet router_svc", "netdev router_src"]
    ROUTER_WAN_LL = "${routerWanLinkLocal}"
    PD = "/run/netif/pd/eth1"

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

    def timed(machine, cmd):
        """(status, output, seconds) of a command."""
        started = time.time()
        status, out = machine.execute(cmd + " 2>&1")
        return status, out.strip(), round(time.time() - started, 2)

    def counter(machine, table, comment):
        """The packets on the counter of the rule with that comment."""
        for line in machine.succeed(f"nft list table {table if ' ' in table else 'inet ' + table}").splitlines():
            if f'comment "{comment}"' in line and "counter packets " in line:
                return int(line.split("counter packets ")[1].split()[0])
        raise AssertionError(f"{machine.name}: no counter '{comment}' in table {table}")

    def isp_saw(source):
        """Packets that reached the ISP from the router with a source in that
        block ("ula": in fd00::/8)."""
        return counter(isp, "watch", source)

    def address(machine, prefix):
        """An address of the machine in that prefix, deprecated or not."""
        for info in json.loads(machine.succeed("ip -j -6 addr show dev eth1 scope global"))[0]["addr_info"]:
            if info.get("local", "").startswith(prefix):
                return info["local"]
        raise AssertionError(f"{machine.name} has no address in {prefix}")

    def delegated_set():
        """The prefixes that the router lets out to the WAN as a source."""
        sets = [sorted(re.findall(r"[0-9a-f:]+::/[0-9]+", router.succeed(f"nft list set {table} delegated"))) for table in HOOK_TABLES]
        assert sets[0] == sets[1], f"the hook's two tables differ: {sets}"
        return sets[0]

    def drop_hook_tables():
        router.succeed("".join(f"nft delete table {table}; " for table in HOOK_TABLES))

    def egress_refused(label, machine, source_address, seen):
        """IPv6 to the internet from that source is answered with an error by
        the router at once, and never reaches the ISP."""
        rejected, leaked = counter(router, "netdev router_src", "egress source"), isp_saw(seen)
        status, out, took = timed(machine, f"curl -sS --max-time 5 --interface {source_address} 'http://[{ISP}]/'")
        rejects, leaks = counter(router, "netdev router_src", "egress source") - rejected, isp_saw(seen) - leaked
        print(f"FINDING {label}: {machine.name} from {source_address}: curl rc={status} after {took}s (bound 1s): {out}; the router rejected {rejects} packets, the ISP saw {leaks}")
        assert status == 7 and took < 1, f"{label}: expected an error at once, got rc={status} after {took}s: {out}"
        assert rejects >= 1 and leaks == 0, f"{label}: rejected {rejects}, the ISP saw {leaks}"
        return took

    def advertisement(machine=None):
        """One solicited router advertisement on the machine's zone (default:
        the client, zone home), parsed from rdisc6."""
        out = (machine or client).wait_until_succeeds("rdisc6 -1 -w 3000 eth1", timeout=30)
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

    def wait_advertised(label, current, retired, timeout=30):
        """`assert_advertised` once corerad's restart (queued, not awaited by
        the hook) is on the wire."""
        deadline = time.time() + timeout
        while True:
            try:
                return assert_advertised(label, current, retired)
            except AssertionError:
                if time.time() >= deadline:
                    raise

    def pd_write(*prefixes):
        """Stand in for netif's exit script while dhcpcd is stopped: the file
        replaced by a rename, or removed."""
        if prefixes:
            router.succeed(f"printf '%s\\n' {' '.join(prefixes)} > /run/netif/pd/.eth1.test && mv /run/netif/pd/.eth1.test {PD}")
        else:
            router.succeed(f"rm -f {PD}")

    def wait_hook(current, retired, delegated, timeout=30):
        """The hook is done: its state on disk names this current prefix and
        these retired ones, and its tables let these prefixes out."""
        want = json.dumps([current, sorted(retired)])
        deadline = time.time() + timeout
        while True:
            status, _ = router.execute(f"test \"$(systemctl show router-prefix.service -P ActiveState)\" = inactive && jq -e --argjson want '{want}' '[.current, (.retired | keys)] == $want' /var/lib/router/prefix.json >/dev/null")
            if status == 0 and delegated_set() == sorted(delegated):
                break
            assert time.time() < deadline, f"the hook did not reach {want} with {delegated}: {hook_state()}, {delegated_set()}, {hook_lines()[-2:]}"
            # the polling interval of this loop; `deadline` bounds it
            time.sleep(0.3)
        assert router.succeed("systemctl show router-prefix.service -P Result").strip() == "success"

    def wait_hook_failed(timeout=30):
        router.wait_until_succeeds("test \"$(systemctl show router-prefix.service -P ActiveState)\" = failed", timeout=timeout)
        assert router.succeed("systemctl show router-prefix.service -P Result").strip() == "exit-code"

    def hook_runs():
        return int(router.succeed("journalctl -u router-prefix --no-pager | grep -c 'router-prefix: current' || true").strip())

    def hook_state():
        return json.loads(router.succeed("cat /var/lib/router/prefix.json"))

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

    def refused(label, machine, url, chain=None):
        """A flow that the firewall drops: no answer, no reset. With `chain`,
        the drop counter of that chain of the router's table counted it."""
        before = counter(router, "router", f"{chain} dropped") if chain else 0
        status, out = machine.execute(f"curl -sS --max-time 3 '{url}' 2>&1")
        dropped = counter(router, "router", f"{chain} dropped") - before if chain else None
        print(f"FINDING {label}: curl rc={status} {out.strip()}; packets on the {chain} drop counter: {dropped}")
        assert status == 28, f"{label}: expected a silent drop (curl 28), got {status}: {out}"
        assert dropped is None or dropped >= 1, f"{label}: the {chain} drop counter did not move"

    def dns_refused(label, machine, server, tcp):
        """A DNS query that the router's input chain drops: a timeout, and
        the input drop counter counted it."""
        before = counter(router, "router", "input dropped")
        status, out = machine.execute(f"dig +time=2 +tries=1 +short {'+tcp' if tcp else '+notcp'} web.test @{server} 2>&1")
        dropped = counter(router, "router", "input dropped") - before
        print(f"FINDING {label}: {machine.name} to {server} over {'TCP' if tcp else 'UDP'}: dig rc={status}, packets on the input drop counter: {dropped}")
        assert status == 9 and "timed out" in out, f"{label}: {server}: expected a timeout, got {status}: {out}"
        assert dropped >= 1, f"{label}: {server}: the input drop counter did not move"

    def router_addresses(link):
        """The router's global IPv6 addresses on `link`."""
        return {info["local"] for info in json.loads(router.succeed(f"ip -j -6 addr show dev {link} scope global"))[0]["addr_info"]}

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
            # §14.3: a LAN zone reaches the service through the hairpin
            # rewrite, so the node sees the router's address on its link
            answer = client.succeed(f"curl -sS --max-time 5 'http://[{base}80]/'").strip()
            assert answer in router_addresses("eth3"), f"{label}: the home zone reached the service as {answer}"
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
            "ls -la /run/netif/pd /run/router /run/router-test; systemctl status router-prefix.service router-prefix.path --no-pager -l",
            "nft list table inet watch",
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
            # what the ISP receives from the router, counted per source block
            watch = "".join(f'iifname "eth1" ip6 saddr {block}::/48 counter comment "{block}"; ' for block in BLOCKS)
            isp.succeed(f"echo 'table inet watch {{ chain prerouting {{ type filter hook prerouting priority raw; iifname \"eth1\" ip6 saddr fd00::/8 counter comment \"ula\"; {watch} }}; }}' | nft -f -")

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
            print("ROUTER_LINKS_OK")

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
            servers_ra = advertisement(node)
            print(f"FINDING the advertisement on the servers zone: {servers_ra}")
            assert (servers_ra["rdnss"], servers_ra["pref64"]) == (["fd00:10:2::1"], ["64:ff9b::/96"]), servers_ra
            assert set(servers_ra["prefixes"]) == {f"{FIRST}:2::/64", "fd00:10:2::/64"}, servers_ra
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
            print("ROUTER_RA_OK")

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
            # home to the router: DNS is allowed (above); from the wan it is
            # not, in either family, over UDP or TCP
            status, out = isp.execute(f"dig +time=2 +tries=1 +short web.test @{wan_v4} 2>&1")
            assert status == 9 and "timed out" in out, (status, out)
            wan_v6 = [info["local"] for info in json.loads(router.succeed("ip -j -6 addr show dev eth1 scope global"))[0]["addr_info"] if info.get("prefixlen") == 128][0]
            for server in [wan_v4, wan_v6]:
                for tcp in [False, True]:
                    dns_refused("wan to the router's WAN address", isp, server, tcp)
            # a neighbour on the WAN segment that routes the zone's resolver
            # addresses to the router gets no answer either
            isp.succeed(f"ip route add 192.168.10.1/32 via {wan_v4} dev eth1 && ip -6 route add fd00:10:1::1/128 via {ROUTER_WAN_LL} dev eth1")
            for server in ["192.168.10.1", "fd00:10:1::1"]:
                for tcp in [False, True]:
                    dns_refused("wan to the home zone's resolver address", isp, server, tcp)
            isp.succeed("ip route del 192.168.10.1/32 && ip -6 route del fd00:10:1::1/128")
            # each refused flow moves the drop counter of its chain
            refused("home to servers over IPv4", client, "http://192.168.20.10/", "forward")
            refused("home to servers over IPv6", client, f"http://[{node_v6}]/", "forward")
            refused("servers to home over IPv4", node, f"http://{client_v4}/", "forward")
            refused("servers to home over IPv6", node, f"http://[{client_v6}]/", "forward")
            refused("wan to home, a client's public IPv6 address", isp, f"http://[{client_v6}]/", "forward")
            refused("wan to servers, a node's public IPv6 address", isp, f"http://[{node_v6}]/", "forward")
            observe("drop counters", router, "nft list table inet router | grep counter")
            for chain in ["input", "forward"]:
                router.succeed(f"nft list table inet router | grep 'counter packets [1-9][0-9]* .*{chain} dropped' >/dev/null")

        with subtest("G14: each zone's advertised resolver answers in that zone, and in that zone only"):
            resolvers = {"home": (client, ["192.168.10.1", "fd00:10:1::1"]), "servers": (node, ["192.168.20.1", "fd00:10:2::1"])}
            observe("CoreDNS sockets and the DNS rules of the input chain", router, "ss -Hlnup 'sport = :53'; nft list chain inet router input | grep DNS")
            for zone, (machine, own) in resolvers.items():
                for server in own:
                    for tcp in ["+notcp", "+tcp"]:
                        answer = machine.succeed(f"dig +time=3 +tries=1 +short {tcp} web.test @{server}").strip()
                        assert answer == "192.0.2.1", f"zone {zone}: {server} {tcp} answered {answer}"
                for other, (_, foreign) in resolvers.items():
                    if other != zone:
                        for server in foreign:
                            for tcp in [False, True]:
                                dns_refused(f"zone {zone} to the resolver of zone {other}", machine, server, tcp)
            # no resolver on a public address of the router
            for tcp in [False, True]:
                dns_refused("home to the router's public address", client, f"{FIRST}:1::1", tcp)

        with subtest("G20: a service /64 of the delegated prefix rewritten to a stable ULA /64"):
            service_routes()
            service_checks("first prefix", FIRST)
            # §14.3: the hairpin. The servers zone calls the public service
            # address; its one host is the service itself. The router
            # rewrites the source, so the reply comes back through it.
            status, out, took = timed(node, f"curl -sS --max-time 3 'http://[{FIRST}:f::80]/'")
            print(f"FINDING hairpin: the servers zone to the public service address: curl rc={status} after {took}s: {out}")
            assert status == 0 and out.strip() in router_addresses("eth3"), (status, out)
            router.succeed("nft list chain inet router_svc hairpin | grep -E 'counter packets [1-9]' >/dev/null")

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
            print(f"FINDING nftables tables on the router: {tables}; 'inet router' is nftables.service's (zones, NAT44, pinholes), 'inet router_svc' (the service rewrite) and 'netdev router_src' (the egress source filter) are the prefix hook's")
            assert tables == ["inet router", "inet router_svc", "netdev router_src"], tables
            # a third owner, as Cilium or a dual-WAN steering unit would be
            router.succeed("printf 'table inet foreign { chain forward { type filter hook forward priority 10; counter comment \"another owner\"; }; }\\n' | nft -f -")

            def snapshot():
                return {name: router.succeed(f"nft -s list table {name}") for name in ["inet router", "inet router_svc", "netdev router_src", "inet foreign"]}

            before = snapshot()
            assert "dnat ip6 prefix" in before["inet router_svc"] and "another owner" in before["inet foreign"] and "egress source" in before["netdev router_src"], before
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
            # the monitor ran and saw the change: the route of the new prefix
            client.succeed(f"grep '^{RENUMBER}:1::/64 dev eth1' /tmp/routes.txt >/dev/null")
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

        with subtest("G22: the ISP changes the prefix and the router renews by itself; dhcpcd is not restarted"):
            dhcpcd = router.succeed("systemctl show netif-dhcpcd-eth1.service -P MainPID -P NRestarts -P ActiveEnterTimestampMonotonic")
            runs = hook_runs()
            isp.succeed("tcpdump -l -n -vv -i eth1 ip6 and udp port 547 > /tmp/dhcp6.txt 2>&1 & echo $! > /tmp/tcpdump.pid")
            isp_delegates("renumber")
            changed = time.time()
            # kea hands out T1 = 60 s and T2 = 96 s for its 120 s / 240 s lease
            took = seconds_until(router, f"grep -x '{RENUMBER}::/60' {PD} >/dev/null", limit=150)
            renewed = time.time()
            isp.succeed("kill $(cat /tmp/tcpdump.pid)")
            observe("in-place renewal: DHCPv6 on the wire since the ISP changed its pool", isp, "grep -E 'dhcp6 (renew|rebind|reply|solicit|advertise|request)' /tmp/dhcp6.txt | tail -n 8")
            observe("in-place renewal: dhcpcd's variables for the reply (the exit script sees them as new_<name>)", router, "dhcpcd -6 -U -f /etc/netif/dhcpcd/eth1.conf eth1 | grep -E '^dhcp6_ia_pd'")
            observe("in-place renewal: dhcpcd", router, "journalctl -b -u netif-dhcpcd-eth1 --no-pager | tail -n 12")
            print(f"FINDING in-place renewal: netif's file had the new prefix {took}s after the ISP changed its pool (bound 150s)")
            assert took is not None, "the router did not renew into the new prefix by itself"
            assert router.succeed("systemctl show netif-dhcpcd-eth1.service -P MainPID -P NRestarts -P ActiveEnterTimestampMonotonic") == dhcpcd, "dhcpcd was restarted"
            # the old prefix is no longer the delegation: the file lists the new one only
            assert router.succeed(f"cat {PD}") == f"{RENUMBER}::/60\n"
            took = settle("in-place renewal", client, renewed, RENUMBER, [FIRST, WIDE], 20)
            settle("in-place renewal", laptop, renewed, RENUMBER, [FIRST, WIDE], 30)
            assert_advertised("in-place renewal", RENUMBER, [FIRST, WIDE])
            lines = hook_lines()
            assert hook_runs() == runs + 1, lines
            assert f"current {RENUMBER}::/60, retired ['{FIRST}::/60', '{WIDE}::/56'], service {RENUMBER}:f::/64, corerad restarted, delegated ['{RENUMBER}::/60'], table replaced" in lines[-1], lines
            for zone, interface in [(1, "eth2"), (2, "eth3")]:
                router.succeed(f"ip -6 -o addr show dev {interface} scope global | grep '{RENUMBER}:{zone}::1/64' >/dev/null")
                router.fail(f"ip -6 -o addr show dev {interface} scope global | grep '{WIDE}:'")
            router.succeed(f"ip -6 route show proto dhcp | grep '^unreachable {RENUMBER}::/60 dev lo' >/dev/null")
            # the service address moved with it
            service_checks("in-place renewal", RENUMBER, full=False)
            refused(f"the service address of the retired {WIDE}", isp, f"http://[{WIDE}:f::80]/")

        with subtest("G22: IPv6 leaves for the internet from a delegated prefix only; another source gets an error at once"):
            observe("the hook's tables", router, "nft list table inet router_svc; nft list table netdev router_src")
            assert delegated_set() == [f"{RENUMBER}::/60"], delegated_set()
            # in every phase up to here
            assert isp_saw("ula") == 0, "the ISP saw a ULA source"
            retired_source, ula_source = address(client, f"{WIDE}:1:"), address(client, "fd00:10:1:")
            egress_refused("a retired prefix as the source", client, retired_source, WIDE)
            egress_refused("a retired prefix as the source", node, address(node, f"{WIDE}:2:"), WIDE)
            egress_refused("the ULA as the source", client, ula_source, "ula")
            # The ingress rule lets the stable service prefix pass, for the
            # service's answers. A new connection from it to the internet is
            # stopped in the forward hook; that error is routed, here back
            # to the node.
            rejected, leaked = counter(router, "router_svc", "egress source, forward"), isp_saw("ula")
            status, out, took = timed(node, f"curl -sS --max-time 5 --interface {STABLE} 'http://[{ISP}]/'")
            print(f"FINDING the stable service address as the source of a new connection: curl rc={status} after {took}s: {out}")
            assert status == 7 and took < 1 and counter(router, "router_svc", "egress source, forward") > rejected and isp_saw("ula") == leaked, (status, out, took)
            # the delegated prefix passes, and so do the answers of the service
            answer = source(client)
            assert answer is not None and answer.startswith(f"{RENUMBER}:1:"), answer
            service_checks("with the egress filter", RENUMBER, full=False)
            # Without the hook's table, as before the filter: the packets
            # leave, the ISP sees them and nothing answers.
            drop_hook_tables()
            for label, source_address, seen in [("a retired prefix", retired_source, WIDE), ("the ULA", ula_source, "ula")]:
                leaked = isp_saw(seen)
                status, out, took = timed(client, f"curl -sS --max-time 3 --interface {source_address} 'http://[{ISP}]/'")
                print(f"FINDING without the egress filter, {label} as the source: curl rc={status} after {took}s: {out}; the ISP saw {isp_saw(seen) - leaked} packets")
                assert status == 28 and isp_saw(seen) > leaked, (status, out)
            # The hook reads what is loaded: a run puts its table back.
            runs = hook_runs()
            router.succeed("systemctl start router-prefix.service")
            lines = hook_lines()
            assert hook_runs() == runs + 1 and "corerad unchanged" in lines[-1] and "table replaced" in lines[-1], lines
            assert delegated_set() == [f"{RENUMBER}::/60"], delegated_set()
            egress_refused("a retired prefix as the source, the table is back", client, retired_source, WIDE)
            service_checks("the table is back", RENUMBER, full=False)
            ula_leaks = isp_saw("ula")

        with subtest("G22: the hook: the file is a set, a missing file, an event while it runs, a run that fails half way"):
            first, renumber, wide = f"{FIRST}::/60", f"{RENUMBER}::/60", f"{WIDE}::/56"
            # dhcpcd is stopped, so that only this subtest writes the file;
            # the stop leaves the file (specs/netif.md N16)
            router.succeed("systemctl stop netif-dhcpcd-eth1.service")
            assert router.succeed(f"cat {PD}") == f"{renumber}\n"

            # a second prefix beside the current one: the current one stays
            pd_write(first, renumber)
            wait_hook(renumber, [wide], [first, renumber])
            assert f"{{ {RENUMBER}:f::/64 : fd00:10:5::/64 }}" in router.succeed("nft list table inet router_svc")
            # the current one leaves the set: the first of the rest is current
            pd_write(first, wide)
            wait_hook(first, [renumber], [first, wide])
            # a line that is no prefix is skipped
            pd_write("not-a-prefix", wide)
            wait_hook(wide, [first, renumber], [wide])
            print(f"FINDING the hook on a set of prefixes: {hook_lines()[-3:]}")

            # An event while the hook runs. The hook's nft waits, so the
            # second write falls into the first run.
            router.succeed("touch /run/router-test/hold-nft")
            pd_write(renumber)
            router.wait_until_succeeds("test -e /run/router-test/held-nft", timeout=30)
            invocation = router.succeed("systemctl show router-prefix.service -P InvocationID").strip()
            pd_write(first)
            assert router.succeed("systemctl show router-prefix.service -P ActiveState").strip() == "activating"
            router.succeed("rm /run/router-test/hold-nft /run/router-test/held-nft")
            wait_hook(first, [renumber, wide], [first])
            lines = hook_lines()
            # the run that was under way handled both: the hook's own loop,
            # whatever systemd did with the event
            handled = router.succeed(f"journalctl _SYSTEMD_INVOCATION_ID={invocation} --no-pager -o cat | grep 'router-prefix: current'").splitlines()
            again = router.succeed("systemctl show router-prefix.service -P InvocationID").strip() != invocation
            print(f"FINDING an event while the hook runs: the run under way printed {handled}; systemd started the unit again for the second write: {again}")
            assert len(handled) == 2 and f"current {renumber}," in handled[0] and f"current {first}, retired ['{renumber}', '{wide}'], service {FIRST}:f::/64" in handled[1], handled
            assert f"current {first}, retired ['{renumber}', '{wide}'], service {FIRST}:f::/64" in lines[-1], lines
            wait_advertised("an event while the hook runs", None, [RENUMBER, WIDE])

            # The restart of corerad fails once. The file does not change
            # again; the next run still has to restart corerad.
            router.succeed("touch /run/router-test/fail-systemctl")
            pd_write(wide)
            wait_hook_failed()
            observe("the failed run", router, "journalctl -b -u router-prefix --no-pager | tail -n 6")
            # the intent is on disk and the table is loaded, corerad still has the old configuration
            assert hook_state()["current"] == wide and delegated_set() == [wide], (hook_state(), delegated_set())
            assert_advertised("the restart of corerad failed", None, [RENUMBER, WIDE])
            router.succeed("rm /run/router-test/fail-systemctl && systemctl start router-prefix.service")
            wait_hook(wide, [first, renumber], [wide])
            assert "corerad restarted" in hook_lines()[-1] and "table unchanged" in hook_lines()[-1], hook_lines()[-1]
            wait_advertised("the run after the failed restart of corerad", None, [FIRST, RENUMBER])

            # nft fails once: the table and corerad are both behind
            router.succeed("touch /run/router-test/fail-nft")
            pd_write(renumber)
            wait_hook_failed()
            assert hook_state()["current"] == renumber
            router.succeed("rm /run/router-test/fail-nft")
            assert delegated_set() == [wide], delegated_set()
            router.succeed("systemctl start router-prefix.service")
            wait_hook(renumber, [first, wide], [renumber])
            assert "corerad restarted" in hook_lines()[-1] and "table replaced" in hook_lines()[-1], hook_lines()[-1]
            wait_advertised("the run after the failed nft", None, [FIRST, WIDE])

            # no file: no delegation. The current prefix is retired, the
            # service rule goes, nothing leaves for the internet over IPv6.
            pd_write()
            wait_hook(None, [first, renumber, wide], [])
            assert "dnat" not in router.succeed("nft list table inet router_svc")
            assert "current None" in hook_lines()[-1] and "service None" in hook_lines()[-1], hook_lines()[-1]
            wait_advertised("no delegation", None, [FIRST, RENUMBER, WIDE])
            egress_refused("no delegation", client, address(client, f"{RENUMBER}:1:"), RENUMBER)

            # dhcpcd again: the delegation is back
            router.succeed("systemctl start netif-dhcpcd-eth1.service")
            router.wait_until_succeeds(f"grep -x '{renumber}' {PD} >/dev/null", timeout=120)
            started = time.time()
            wait_hook(renumber, [first, wide], [renumber])
            settle("the delegation is back", client, started, RENUMBER, [FIRST, WIDE], 20)
            settle("the delegation is back", laptop, started, RENUMBER, [FIRST, WIDE], 30)
            assert_advertised("the delegation is back", RENUMBER, [FIRST, WIDE])
            # this subtest restarted corerad eight times within seconds
            router.succeed("systemctl is-active corerad.service")
            assert router.succeed("systemctl show corerad.service -P StartLimitIntervalUSec").strip() == "0"
            service_checks("the delegation is back", RENUMBER, full=False)
            print("ROUTER_HOOK_OK")

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
            # The run at boot and dhcpcd's first reply race; whichever came
            # first, the hook ends on what the file says.
            assert f"current {FIRST}::/60, retired ['{RENUMBER}::/60', '{WIDE}::/56'], service {FIRST}:f::/64" in lines[-1], lines
            state = hook_state()
            assert state["current"] == f"{FIRST}::/60" and sorted(state["retired"]) == [f"{RENUMBER}::/60", f"{WIDE}::/56"], state
            assert router.succeed(f"cat {PD}") == f"{FIRST}::/60\n" and delegated_set() == [f"{FIRST}::/60"], delegated_set()
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

        with subtest("G22: an empty or damaged state file is no state: the hook runs and takes the delegated prefix"):
            saved = router.succeed("cat /var/lib/router/prefix.json")
            for label, content in [("empty", ""), ("cut off", '{"current": "2001:db8:1000::/60", "reti'), ("another shape", "[1, 2]"), ("wrong types", '{"current": 5, "retired": []}'), ("no prefix", '{"current": "x", "retired": {}}')]:
                router.succeed(f"printf '%s' '{content}' > /var/lib/router/prefix.json && systemctl start router-prefix.service")
                state = hook_state()
                print(f"FINDING a state file that is {label}: the hook wrote {state}: {hook_lines()[-1]}")
                assert state == {"current": f"{FIRST}::/60", "retired": {}}, f"{label}: {state}"
                assert router.succeed("systemctl show router-prefix.service -P Result").strip() == "success"
            # what the hook forgot is no longer advertised as deprecated
            wait_advertised("the state was damaged", FIRST, [])
            service_checks("the state was damaged", FIRST, full=False)
            # the suite goes on with the state from before
            router.succeed(f"printf '%s' '{saved}' > /var/lib/router/prefix.json && systemctl start router-prefix.service")
            wait_advertised("the state is back", FIRST, [RENUMBER, WIDE])

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
            # one. The router refuses that source with an ICMPv6 error, so a
            # connection fails at once and a fetch by name goes on over IPv4;
            # without the refusal the packets left and nothing answered.
            # FINDING a gap in specs/gateway.md G22 ("keeps the last prefix on
            # disk"): that file is all that retires a prefix after a reboot.
            wan_v4 = json.loads(router.succeed("ip -j -4 addr show dev eth1 scope global"))[0]["addr_info"][0]["local"]
            by_name = "python3 -c 'import socket, time; t = time.time(); s = socket.create_connection((\"dual.test\", 80), timeout=5); print(s.getpeername()[0], round(time.time() - t, 2))'"
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
                rejected, leaked = counter(router, "netdev router_src", "egress source"), isp_saw(FIRST)
                status, out, took = timed(machine, f"curl -sS --max-time 5 'http://[{ISP}]/'")
                print(f"FINDING state lost: {machine.name} to the ISP's IPv6 address from the old prefix: curl rc={status} after {took}s (bound 1s): {out}")
                assert status == 7 and took < 1, f"{machine.name}: expected an error at once, got rc={status} after {took}s: {out}"
                assert counter(router, "netdev router_src", "egress source") > rejected and isp_saw(FIRST) == leaked, "the old prefix left for the ISP"
                # by name, with both families: IPv4 takes over
                status, out, took = timed(machine, "curl -sS --max-time 5 http://dual.test/")
                print(f"FINDING state lost: {machine.name} fetches a dual-stack name with curl: rc={status} after {took}s (bound 2s), the ISP saw {out}")
                assert status == 0 and out == f"::ffff:{wan_v4}" and took < 2, (status, out, took)
            # a client that tries one address after the other, no happy eyeballs
            status, out, took = timed(client, by_name)
            print(f"FINDING state lost: a sequential connect by name on the client reached '{out}' after {took}s (bound 2s)")
            assert status == 0 and out.startswith("192.0.2.1 ") and took < 2, (status, out, took)
            # the same without the hook's table, as before the filter
            drop_hook_tables()
            status, out, took = timed(client, f"curl -sS --max-time 3 'http://[{ISP}]/'")
            print(f"FINDING state lost, without the egress filter: the client to the ISP's IPv6 address: curl rc={status} after {took}s: {out}")
            assert status == 28, (status, out)
            status, out, took = timed(client, "curl -sS --max-time 5 http://dual.test/")
            print(f"FINDING state lost, without the egress filter: the client fetches a dual-stack name with curl: rc={status} after {took}s, the ISP saw {out}")
            status, out, took = timed(client, by_name)
            print(f"FINDING state lost, without the egress filter: a sequential connect by name on the client reached '{out}' after {took}s (5 s is the test's timeout per address; the kernel's own is about 130 s)")
            assert status == 0 and out.startswith("192.0.2.1 ") and took >= 5, (status, out, took)
            router.succeed("systemctl start router-prefix.service")
            assert delegated_set() == [f"{RENUMBER}::/60"], delegated_set()
            assert_advertised("state lost", RENUMBER, [])
            service_routes()
            service_checks("state lost", RENUMBER, full=False, home=False)

        with subtest("the ISP never saw a ULA source, but for the two probes without the egress filter"):
            observe("what the ISP received from the router, per source block", isp, "nft list table inet watch")
            assert isp_saw("ula") == ula_leaks, f"the ISP saw {isp_saw('ula') - ula_leaks} more packets from a ULA"

        print("ROUTER_OK")
  '';
}
