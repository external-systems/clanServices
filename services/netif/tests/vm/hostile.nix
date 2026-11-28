# netif-hostile: hostile neighbours on the links of a netif machine
# (specs/netif.md N46, N47, N48; specs/design-netif.md §6). Hermetic:
# test VLANs only, no real network.
#
#   gw        192.168.1.1, 2001:db8:1::1: the real gateway (VLAN 1)
#   victim    netif. eth1 `uplink` (static, owns both defaults); eth2
#             `side` (static, no default); eth3 `ral` (`ra = true`, no
#             default); eth5 `trunk` (a VLAN parent without addressing)
#             and `v10` on it; `br0` (guest ports) with a guest port in
#             a namespace; the hot-plug prefix `enx` with a veth "dock"
#   attacker  on VLANs 1 to 5: scans, a router-advertisement fixture
#             (radvd) on eth1 and eth3, scapy advertisements, a forged
#             ICMP redirect, spoofed sources
#
# Every attack ends in one `verdict(id, safe, detail)`. The suite runs
# all of them, prints a `HOSTILE SAFE|GAP <id>` line each, and fails at
# the end when any is a gap. A new attack is a new verdict; never
# delete one to make the suite pass.
#
# Every group of verdicts has a positive control: `control(id, worked,
# detail)` shows that the attack is real (it works without the
# baseline), that its packets arrive, or that the same probe finds what
# it looks for on a legal target. A SAFE without a working control
# proves nothing (two RA verdicts were empty that way: radvd refused its
# configuration and sent nothing), so a control that did not work fails
# the suite as a gap does (SPEC.md H19).
#
# `info(...)` lines report behaviour that a later step of the design
# closes (specs/design-netif.md §8). Each names its step. That step
# turns the line into a verdict; until then it never fails the suite.
# `FINDING` lines record how the baseline reaches each link (P3, P10).
{
  inputs,
  lib,
  ...
}: let
  fixture = addresses:
    import ../../../../tests/ifstate-vm.nix {
      ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
      inherit addresses;
      withBase = true;
    };
  vlans = [1 2 3 4 5];
in {
  name = "netif-hostile";

  clan = {
    directory = ./.;
    test.useContainers = false;
    inventory = {
      machines = lib.genAttrs ["attacker" "gw" "victim"] (_: {});
      instances.lan = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.victim.settings.links = {
          uplink = {
            interface = "eth1";
            static = {
              ipv4 = ["192.168.1.2/24"];
              ipv6 = ["2001:db8:1::2/64"];
            };
            gateway = {
              ipv4 = "192.168.1.1";
              ipv6 = "2001:db8:1::1";
            };
          };
          side = {
            interface = "eth2";
            static.ipv4 = ["198.51.100.2/24"];
            defaultRoute = {
              ipv4 = false;
              ipv6 = false;
            };
          };
          # takes router advertisements, does not own the IPv6 default
          ral = {
            interface = "eth3";
            ra = true;
            defaultRoute.ipv6 = false;
          };
          trunk = {
            interface = "eth5";
            defaultRoute.ipv6 = false;
          };
          v10 = {
            vlan = {
              id = 10;
              parent = "trunk";
            };
            static.ipv6 = ["2001:db8:10::2/64"];
            defaultRoute.ipv6 = false;
          };
          br0 = {
            kind = "bridge";
            bridge.guestPorts = true;
            static.ipv4 = ["192.0.2.1/24"];
            defaultRoute.ipv6 = false;
          };
        };
      };
    };
  };

  nodes = {
    gw = {pkgs, ...}: {
      imports = [(fixture ["192.168.1.1/24" "2001:db8:1::1/64"])];
      virtualisation = {
        cores = 1;
        memorySize = 768;
      };
      networking.firewall.enable = false;
      # H01 control: a legal target with an open port
      environment.systemPackages = [pkgs.python3];
    };
    victim = {pkgs, ...}: {
      virtualisation = {
        cores = 2;
        memorySize = 1536;
        inherit vlans;
      };
      environment.systemPackages = [
        pkgs.tcpdump
        pkgs.wireguard-tools
        # the guest's advertisement (H15)
        (pkgs.python3.withPackages (ps: [ps.scapy]))
      ];
      clanServices.netif.hotplug.interfaces = ["^enx"];
    };
    attacker = {pkgs, ...}: {
      imports = [(fixture ["192.168.1.66/24" "2001:db8:1::66/64"])];
      virtualisation = {
        cores = 2;
        memorySize = 1024;
        inherit vlans;
      };
      networking = {
        firewall.enable = false;
        ifstate.settings.interfaces = {
          eth2 = {
            addresses = ["198.51.100.66/24"];
            link = {
              kind = "physical";
              state = "up";
            };
          };
          eth3 = {
            addresses = ["2001:db8:3::66/64"];
            link = {
              kind = "physical";
              state = "up";
            };
          };
          eth5.link = {
            kind = "physical";
            state = "up";
          };
        };
      };
      # A node that sends router advertisements forwards (specs/netif.md §7).
      boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
      environment.systemPackages = [
        pkgs.nmap
        pkgs.iputils
        (pkgs.python3.withPackages (ps: [ps.scapy]))
      ];
      # The router-advertisement fixture of H02-H04 (eth1) and H16 (eth3).
      # radvd refuses an interface whose MinRtrAdvInterval is not between
      # 3 s and 3/4 of MaxRtrAdvInterval, and then sends nothing while its
      # unit is active: the controls below prove the advertisement arrived.
      services.radvd = {
        enable = true;
        config = ''
          interface eth1 {
            AdvSendAdvert on;
            AdvDefaultPreference high;
            MaxRtrAdvInterval 4;
            MinRtrAdvInterval 3;
            prefix 2001:db8:bad::/64 {};
            route 2001:db8:f00d::/48 {};
          };
          interface eth3 {
            AdvSendAdvert on;
            AdvDefaultPreference high;
            MaxRtrAdvInterval 4;
            MinRtrAdvInterval 3;
            AdvLinkMTU 1280;
            AdvCurHopLimit 1;
            prefix 2001:db8:bad3::/64 {};
            route 2001:db8:f00d::/48 {};
          };
        '';
      };
      # started by the test
      systemd.services.radvd.wantedBy = lib.mkForce [];
    };
  };

  testScript = ''
    import json

    ${import ../../../../tests/suite-lib.nix}

    RESULTS = []
    CONTROLS = []
    # boot links of the VM that no instance declares (design §3.4 residual)
    UNDECLARED_AT_BOOT = ["eth0", "eth4"]


    def verdict(key, safe, detail=""):
        RESULTS.append((key, bool(safe), detail))
        print(f"HOSTILE {'SAFE' if safe else 'GAP '} {key}: {detail}")


    def control(key, worked, detail=""):
        """A positive control: the attack of a verdict group is real."""
        CONTROLS.append((key, bool(worked), detail))
        print(f"HOSTILE CONTROL {'OK  ' if worked else 'FAIL'} {key}: {detail}")


    def info(key, detail):
        print(f"HOSTILE INFO {key}: {detail}")


    def finding(key, detail):
        print(f"FINDING {key}: {detail}")


    def sysctl(machine, path):
        return machine.succeed(f"cat /proc/sys/net/{path}").strip()


    def scan(target, ports="-"):
        """Open TCP ports of one address, as the attacker sees them."""
        family = "-6" if ":" in target else ""
        out = attacker.succeed(f"nmap {family} -n -Pn -sS -p{ports} --min-rate 3000 --max-retries 1 -oG - {target} 2>&1")
        found = []
        for line in out.splitlines():
            if "Ports:" in line:
                found += [int(p.split("/")[0].strip()) for p in line.split("Ports:")[1].split(",") if "/open/" in p]
        return sorted(found)


    def capture(unit, iface, expr, seconds, direction="inout", flags=""):
        """Packets on one link of the victim, read back with `captured`."""
        victim.succeed(
            f"systemd-run --unit {unit} sh -c \"PATH=/run/current-system/sw/bin; timeout {seconds} tcpdump -l -p -n {flags} -Q {direction} -i {iface} '{expr}' > /tmp/{unit}.txt 2>&1\""
        )
        victim.succeed("sleep 2")


    def captured(unit):
        victim.wait_until_fails(f"systemctl is-active {unit}.service", timeout=60)
        return victim.succeed(f"cat /tmp/{unit}.txt")


    def routes6(match):
        """IPv6 routes of every table that contain `match`, also routes an
        advertisement installed (they carry `expires`)."""
        out = victim.succeed("ip -6 route show table all")
        return [line.strip() for line in out.splitlines() if match in line]


    def global6(link):
        """The global IPv6 addresses of one link, one line."""
        return " ".join(victim.succeed(f"ip -6 -o addr show dev {link} scope global | awk '{{print $4}}' | sort").split())


    def default6(link):
        """Gateways of the IPv6 default routes that leave by one link."""
        return [route.get("gateway") for route in json.loads(victim.succeed("ip -j -6 route show default")) if route.get("dev") == link]


    def ra_keys(link, **keys):
        """Set router-advertisement keys of one link by hand (a control)."""
        victim.succeed("sysctl -w " + " ".join(f"net.ipv6.conf.{link}.{key}={value}" for key, value in keys.items()) + " >/dev/null")


    def forget_ra(link):
        """Remove what an advertisement left on a link: its routes, its
        addresses and the prefix routes."""
        victim.succeed(
            f"ip -6 route flush dev {link} proto ra; ip -6 addr flush dev {link} scope global dynamic;"
            f" for p in $(ip -6 route show dev {link} proto kernel | awk '/expires/ {{print $1}}'); do ip -6 route del $p dev {link}; done; true"
        )


    def ensure_guest():
        """A guest in a namespace behind the guest port gp0 of br0."""
        victim.succeed(
            "ip netns list | grep -w guest >/dev/null || (ip netns add guest && ip link add gp0 type veth peer name g0 netns guest"
            " && ip link set gp0 master br0 up && ip -n guest link set g0 up && ip -n guest link set lo up)"
        )


    def redirect_moves(route):
        """The forged redirect: the gateway's address tells the victim to
        reach 203.0.113.9 through the attacker. Its inner packet is a UDP
        flow the victim really sent, so the firewall lets it in as related
        traffic and only the redirect sysctls decide."""
        victim.succeed("ping -c 1 -W 2 192.168.1.66 >/dev/null")
        victim.succeed(
            "python3 -c \"import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); "
            "s.bind(('192.168.1.2', 40000)); s.sendto(b'x', ('203.0.113.9', 40001))\""
        )
        attacker.succeed(
            "python3 -c \"from scapy.all import *; "
            "send(IP(src='192.168.1.1', dst='192.168.1.2')/ICMP(type=5, code=1, gw='192.168.1.66')"
            "/IP(src='192.168.1.2', dst='203.0.113.9')/UDP(sport=40000, dport=40001), count=3, verbose=0)\""
        )
        victim.succeed("sleep 1")
        got = victim.succeed(f"ip route get {route}").strip()
        return "via 192.168.1.66" in got, got


    start_all()
    for machine in [gw, victim, attacker]:
        machine.wait_for_unit("multi-user.target", timeout=300)
    victim.wait_until_succeeds("ping -c 1 -W 2 192.168.1.1", timeout=120)
    victim.wait_until_succeeds("ping -6 -c 1 -W 2 2001:db8:1::1", timeout=120)
    attacker.wait_until_succeeds("ping -c 1 -W 2 198.51.100.2", timeout=120)
    link_local = victim.succeed("ip -6 -o addr show dev eth1 scope link | awk '{print $4}' | cut -d/ -f1").strip()

    with subtest("a full TCP scan of the netif machine, every address"):
        gw.succeed("systemd-run --unit h01-listener python3 -m http.server --bind :: 8080")
        gw.wait_until_succeeds("ss -tln | grep ':8080 ' >/dev/null", timeout=30)
        for label, target in [("IPv4", "192.168.1.1"), ("IPv6", "2001:db8:1::1")]:
            found = scan(target, "8080")
            control(f"H01 the scan finds an open port on a legal target ({label})", found == [8080], f"open on the gateway: {found}")
        for label, target in [("IPv4", "192.168.1.2"), ("IPv6", "2001:db8:1::2"), ("IPv6 link-local", f"{link_local}%eth1"), ("IPv4 of side", "198.51.100.2")]:
            found = scan(target)
            verdict(f"H01 no TCP port open on an untrusted link ({label})", not found, f"open: {found}")

    with subtest("a rogue router advertisement beside a static IPv6 gateway"):
        capture("h02", "eth1", "icmp6 and ip6[40] == 134", 15, "in", "-v")
        attacker.succeed("systemctl restart radvd")
        seen = captured("h02")
        control(
            "H02-H04 the fixture's advertisement reaches eth1 with a prefix and a route-information option",
            "router advertisement" in seen and "2001:db8:bad::/64" in seen and "2001:db8:f00d::/48" in seen,
            " ".join(seen.split())[:400] if seen.strip() else "nothing captured",
        )
        victim.succeed("sleep 10")
        defaults = default6("eth1")
        verdict("H02 the IPv6 default stays on the declared gateway only", defaults == ["2001:db8:1::1"], f"default via {defaults}")
        addresses = global6("eth1")
        verdict("H03 no address from the rogue prefix", "2001:db8:bad:" not in addresses, addresses)
        found = routes6("2001:db8:bad:")
        verdict("H04 no route for the rogue prefix", found == [], f"{found}")
        found = routes6("2001:db8:f00d")
        verdict("H04 no route-information route from the advertisement", found == [], f"{found}")
        # The controls: eth1 with the keys of a link that declares `ra`
        # and owns the default, plus route information, and the same
        # advertisement installs each thing the verdicts looked for.
        ra_keys("eth1", accept_ra=1, autoconf=1, accept_ra_pinfo=1, accept_ra_defrtr=1, accept_ra_rt_info_max_plen=64)
        took = seconds_until(victim, "ip -6 route show default dev eth1 proto ra | grep fe80 && ip -6 route show table all | grep 2001:db8:f00d", limit=30)
        control("H02 the same advertisement adds a default router when eth1 takes one", default6("eth1") != ["2001:db8:1::1"], f"default via {default6('eth1')} after {took} s")
        control("H03 the same advertisement adds an address when eth1 takes prefixes", "2001:db8:bad:" in global6("eth1"), global6("eth1"))
        control("H04 the same advertisement adds the prefix route and the route-information route", routes6("2001:db8:bad:") != [] and routes6("2001:db8:f00d") != [], f"{routes6('2001:db8:')}")
        attacker.succeed("systemctl stop radvd")
        ra_keys("eth1", accept_ra=0, autoconf=0, accept_ra_pinfo=0, accept_ra_defrtr=0, accept_ra_rt_info_max_plen=0)
        forget_ra("eth1")
        assert default6("eth1") == ["2001:db8:1::1"], default6("eth1")

    with subtest("a rogue advertisement on a link that declared `ra`: prefixes only"):
        attacker.succeed("systemctl restart radvd")
        took = seconds_until(victim, "ip -6 -o addr show dev eth3 scope global | grep 2001:db8:bad3:", limit=60)
        control("H16 the link with `ra = true` takes the advertised prefix", took is not None, f"{global6('eth3')} after {took} s")
        victim.succeed("sleep 8")
        routes = routes6("dev eth3")
        defaults = default6("eth3")
        mtu = sysctl(victim, "ipv6/conf/eth3/mtu")
        hop = sysctl(victim, "ipv6/conf/eth3/hop_limit")
        verdict("H16a no default router from an `ra` link that does not own the IPv6 default", defaults == [], f"default via {defaults}")
        verdict("H16b no route-information route from an advertisement", [route for route in routes if "f00d" in route] == [], f"{routes}")
        verdict("H16c an advertisement does not shrink the MTU", mtu == "1500", f"mtu {mtu}")
        verdict("H16d an advertisement does not lower the hop limit", hop == "64", f"hop_limit {hop}")
        # The controls: the four keys that the baseline holds, opened by
        # hand, and the same advertisement does each thing.
        ra_keys("eth3", accept_ra_defrtr=1, accept_ra_rt_info_max_plen=64, accept_ra_mtu=1, accept_ra_min_hop_limit=1)
        seconds_until(
            victim,
            "ip -6 route show default dev eth3 | grep fe80 && ip -6 route show table all dev eth3 | grep 2001:db8:f00d"
            " && test $(cat /proc/sys/net/ipv6/conf/eth3/mtu) = 1280 && test $(cat /proc/sys/net/ipv6/conf/eth3/hop_limit) = 1",
            limit=30,
        )
        control("H16a the advertisement carries a default router (taken with accept_ra_defrtr 1)", default6("eth3") != [], f"default via {default6('eth3')}")
        control("H16b the advertisement carries route information (taken with accept_ra_rt_info_max_plen 64)", [route for route in routes6("dev eth3") if "f00d" in route] != [], f"{routes6('dev eth3')}")
        control("H16c the advertisement carries MTU 1280 (taken with accept_ra_mtu 1)", sysctl(victim, "ipv6/conf/eth3/mtu") == "1280", sysctl(victim, "ipv6/conf/eth3/mtu"))
        control("H16d the advertisement carries hop limit 1 (taken with accept_ra_min_hop_limit 1)", sysctl(victim, "ipv6/conf/eth3/hop_limit") == "1", sysctl(victim, "ipv6/conf/eth3/hop_limit"))
        attacker.succeed("systemctl stop radvd")
        ra_keys("eth3", accept_ra_defrtr=0, accept_ra_rt_info_max_plen=0, accept_ra_mtu=0, accept_ra_min_hop_limit=64, mtu=1500, hop_limit=64)
        forget_ra("eth3")

    with subtest("a forged ICMP redirect in the gateway's name"):
        moved, route = redirect_moves("203.0.113.9")
        verdict("H05 a forged IPv4 redirect does not move a route", not moved, route)
        values = {
            name: sysctl(victim, name)
            for name in [
                "ipv4/conf/all/accept_redirects",
                "ipv4/conf/eth1/accept_redirects",
                "ipv4/conf/all/secure_redirects",
                "ipv4/conf/eth1/secure_redirects",
                "ipv6/conf/all/accept_redirects",
                "ipv6/conf/eth1/accept_redirects",
                "ipv4/conf/all/accept_source_route",
                "ipv4/conf/eth1/accept_source_route",
                "ipv6/conf/all/accept_source_route",
                "ipv6/conf/eth1/accept_source_route",
            ]
        }
        # IPv4 takes a redirect when `all` OR the link says so: both must be 0
        v4 = values["ipv4/conf/all/accept_redirects"] == "0" and values["ipv4/conf/eth1/accept_redirects"] == "0"
        verdict("H06 IPv4 redirects are not accepted on the link", v4, f"{values}")
        v6 = values["ipv6/conf/all/accept_redirects"] == "0" and values["ipv6/conf/eth1/accept_redirects"] == "0"
        verdict("H07 IPv6 redirects are not accepted on the link", v6, f"{values}")
        source_route = all(values[f"{family}/conf/{scope}/accept_source_route"] in ("0", "-1") for family in ["ipv4", "ipv6"] for scope in ["all", "eth1"])
        verdict("H08 source-routed packets are not accepted", source_route, f"{values}")
        # The control: the link's key alone at 1 (the kernel's default
        # before the baseline) and the same redirect moves the route.
        victim.succeed("sysctl -w net.ipv4.conf.eth1.accept_redirects=1 >/dev/null")
        moved, route = redirect_moves("203.0.113.9")
        control("H05-H08 the same redirect moves the route when eth1 accepts redirects", moved, route)
        victim.succeed("sysctl -w net.ipv4.conf.eth1.accept_redirects=0 >/dev/null && ip route flush cache")
        victim.wait_until_succeeds("! ip route get 203.0.113.9 | grep 192.168.1.66 >/dev/null", timeout=30)

    with subtest("a spoofed source address"):
        capture("h14", "any", "icmp[icmptype] == icmp-echoreply", 10)
        attacker.succeed("ping -c 2 -W 1 192.168.1.2")
        attacker.succeed(
            "python3 -c \"from scapy.all import *; "
            "sendp(Ether(dst=getmacbyip('192.168.1.2'))/IP(src='198.51.100.10', dst='192.168.1.2')/ICMP(), iface='eth1', count=3, verbose=0)\""
        )
        seen = captured("h14")
        control("H14 an honest echo is answered", "192.168.1.2 > 192.168.1.66" in seen, seen.strip()[-300:])
        verdict("H14 a packet with a source of another link gets no answer (reverse path)", "> 198.51.100.10" not in seen, seen.strip().replace("\n", " | ")[-300:])

    with subtest("P3, P10: the sysctl baseline on links netif does not declare"):
        keys = ["ipv4/conf/{}/accept_redirects", "ipv4/conf/{}/secure_redirects", "ipv4/conf/{}/send_redirects", "ipv4/conf/{}/accept_source_route", "ipv6/conf/{}/accept_redirects", "ipv6/conf/{}/accept_source_route"]

        def show(link):
            return {key.format("X"): sysctl(victim, key.format(link)) for key in keys}

        finding("P3 eth0, present at boot, not declared (only the glob can reach it)", show("eth0"))
        finding("P3 scope all", show("all"))
        finding("P10 scope default", show("default"))
        # a guest port, a hot-plugged dock, a veth pair with one end in a
        # bridge, a dummy and a WireGuard link, all added after boot
        ensure_guest()
        victim.succeed(
            "ip netns add dock && ip link add dockpeer netns dock type veth peer name enxdock && ip -n dock link set dockpeer up"
            " && ip link add vt0 type veth peer name vt1 && ip link add dm0 type dummy && ip link add brx type bridge"
            " && ip link set vt1 master brx && ip link add wg9 type wireguard && udevadm settle"
        )
        for link in ["gp0", "enxdock", "vt0", "vt1", "dm0", "brx", "wg9"]:
            finding(f"P10 {link}, added after boot", show(link))
        # which sink reaches a new link: the kernel's copy of `default`, or
        # udev running systemd-sysctl with the glob?
        victim.succeed("sysctl -w net.ipv4.conf.default.accept_redirects=1 net.ipv6.conf.default.accept_redirects=1 >/dev/null && ip link add dm1 type dummy && udevadm settle && sleep 1")
        finding("P3 dm1, added while `default` was 1 (0 = udev applied the glob to the new link)", show("dm1"))
        victim.succeed("sysctl -w net.ipv4.conf.default.accept_redirects=0 net.ipv6.conf.default.accept_redirects=0 >/dev/null")
        victim.succeed("sysctl -w net.ipv4.conf.dm0.accept_redirects=1 >/dev/null && systemctl restart systemd-sysctl.service")
        finding("P3 dm0, set to 1, after a systemd-sysctl restart (0 = the glob reaches an existing link)", show("dm0"))

    with subtest("a guest on the guest-ports bridge sends a router advertisement"):
        ensure_guest()
        victim.wait_until_succeeds("ip -n guest -6 addr show dev g0 scope link | grep -v tentative | grep fe80 >/dev/null", timeout=30)
        capture("h15", "br0", "icmp6 and ip6[40] == 134", 12, "in", "-v")
        victim.succeed(
            "ip netns exec guest python3 -c \"from scapy.all import *; "
            "sendp(Ether(dst='33:33:00:00:00:01')/IPv6(dst='ff02::1')/ICMPv6ND_RA(routerlifetime=1800)"
            "/ICMPv6NDOptPrefixInfo(prefix='2001:db8:bad0::', prefixlen=64, L=1, A=1), iface='g0', count=4, inter=1, verbose=0)\""
        )
        seen = captured("h15")
        control("H15 the guest's advertisement reaches br0", "router advertisement" in seen and "2001:db8:bad0::/64" in seen, " ".join(seen.split())[:300])
        victim.succeed("sleep 2")
        state = victim.succeed("ip -6 addr show; ip -6 route show table all")
        values = {link: sysctl(victim, f"ipv6/conf/{link}/accept_ra") for link in ["br0", "gp0"]}
        verdict("H15 a guest's router advertisement gives the host no address and no route", "2001:db8:bad0" not in state and set(values.values()) == {"0"}, f"accept_ra {values}")

    with subtest("a rogue advertisement on a VLAN parent that has no addressing"):
        capture("h23", "eth5", "icmp6 and ip6[40] == 134", 12, "in", "-v")
        attacker.succeed(
            "python3 -c \"from scapy.all import *; "
            "sendp(Ether(dst='33:33:00:00:00:01')/IPv6(dst='ff02::1')/ICMPv6ND_RA(routerlifetime=1800)"
            "/ICMPv6NDOptPrefixInfo(prefix='2001:db8:bad5::', prefixlen=64, L=1, A=1), iface='eth5', count=4, inter=1, verbose=0)\""
        )
        seen = captured("h23")
        control("H23 the advertisement reaches the VLAN parent", "router advertisement" in seen and "2001:db8:bad5::/64" in seen, " ".join(seen.split())[:300])
        victim.succeed("sleep 2")
        state = victim.succeed("ip -6 addr show; ip -6 route show table all")
        parent = sysctl(victim, "ipv6/conf/eth5/accept_ra")
        verdict("H23 a VLAN parent without addressing takes nothing from an advertisement", "2001:db8:bad5" not in state and parent == "0", f"accept_ra {parent}")

    with subtest("every link of the machine"):
        survey = (
            "for f in /proc/sys/net/ipv4/conf/*/accept_redirects /proc/sys/net/ipv4/conf/*/secure_redirects /proc/sys/net/ipv4/conf/*/send_redirects"
            " /proc/sys/net/ipv4/conf/*/accept_source_route /proc/sys/net/ipv6/conf/*/accept_redirects /proc/sys/net/ipv6/conf/*/accept_source_route; do"
            " case $f in */lo/*) continue ;; esac; v=$(cat $f); [ \"$v\" = 0 ] || echo \"$f=$v\"; done"
        )
        links = victim.succeed("ls /sys/class/net").split()
        wanted = ["eth0", "eth1", "eth2", "eth3", "eth5", "br0", "gp0", "enxdock", "vt0", "vt1", "dm0", "dm1", "brx", "wg9"]
        vlan = [link for link in links if link.startswith("eth5.")]
        # the control: the survey sees every kind of link and finds a key
        # that is not 0
        victim.succeed("sysctl -w net.ipv4.conf.dm1.send_redirects=1 >/dev/null")
        planted = victim.succeed(survey).strip()
        victim.succeed("sysctl -w net.ipv4.conf.dm1.send_redirects=0 >/dev/null")
        control(
            "H20 the survey covers declared, VLAN, guest-port, hot-plug, veth, bridge, dummy and WireGuard links and finds a key set to 1",
            all(link in links for link in wanted) and vlan != [] and "/proc/sys/net/ipv4/conf/dm1/send_redirects=1" in planted.splitlines(),
            f"links: {links}; planted: {planted!r}",
        )
        bad = victim.succeed(survey).strip()
        verdict("H20 no redirect and no source route on any link (declared, guest port, hot-plug, veth, bridge, WireGuard)", bad == "", f"links: {' '.join(links)}; not 0: {bad}")
        # I8: router advertisements only where declared. Allowed: `ral`,
        # hot-plug links, and links that exist before systemd-sysctl runs
        # and that nobody declares (the measured residual of design §3.4:
        # `default` cannot reach them and the RA keys have no glob). `all`
        # has no effect on a link for IPv6.
        taking = {}
        for line in victim.succeed("for f in /proc/sys/net/ipv6/conf/*/accept_ra; do echo \"$f $(cat $f)\"; done").splitlines():
            path, value = line.split()
            if value != "0":
                taking[path.split("/")[-2]] = value
        control("H20 the RA survey finds the declared `ra` link taking advertisements", taking.get("eth3") == "1", f"{taking}")
        allowed = ["lo", "all", "eth3", *UNDECLARED_AT_BOOT]
        wrong = {link: value for link, value in taking.items() if link not in allowed and not link.startswith("enx")}
        verdict("H20 router advertisements only on the declared `ra` link and hot-plug links", wrong == {}, f"taking RAs: {taking}")

    print("HOSTILE SUMMARY")
    for key, safe, detail in RESULTS:
        print(f"  {'SAFE' if safe else 'GAP '} {key}" + (f" [{detail}]" if not safe else ""))
    for key, worked, detail in CONTROLS:
        print(f"  {'CONTROL OK  ' if worked else 'CONTROL FAIL'} {key}" + (f" [{detail}]" if not worked else ""))
    gaps = [key for key, safe, _ in RESULTS if not safe]
    failed = [key for key, worked, _ in CONTROLS if not worked]
    assert not gaps, f"{len(gaps)} gap(s): {gaps}"
    assert not failed, f"{len(failed)} positive control(s) did not work, so their verdicts prove nothing: {failed}"
    print("NETIF_HOSTILE_OK")
  '';
}
