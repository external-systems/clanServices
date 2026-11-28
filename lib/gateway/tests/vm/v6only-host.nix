# netif-v6only (specs/netif.md N45, U13; specs/gateway.md G4, G23, §10.6).
#
#   static  ── vlan 1 ── provider ── vlan 2 ── server4 (IPv4 only)
#   slaac   ── vlan 3 ──────┘
#
# `static` is a cloud machine as a provider hands it out: one /64, the
# gateway fe80::1, no router advertisement, no DHCP. `slaac` learns its
# address and default route from router advertisements. Both use the
# provider's DNS64 and NAT64 (G4) and run a CLAT (G23) for IPv4 literals.
#
# The suite pins, for both machines, after boot, after an IfState apply
# and after a reboot:
#   - N45: netif brings a machine with no IPv4 on its NIC online: an
#     IPv6 default route, IPv6 nameservers only, the guard content with
#     a link-local gateway, nothing failed, an apply changes nothing.
#   - G4: a name with only an A record is reached through DNS64 and
#     NAT64 (ping, 2 MB down and up).
#   - G23: an IPv4 literal is reached through the CLAT (the same), and
#     what the path MTU is through both translators.
# The CLAT address of `static` is routed to it by the provider; the one
# of `slaac` is answered for by proxy NDP, because nobody routes a
# second address to a machine on an advertised /64.
{
  inputs,
  lib,
  ...
}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  base = import ../../../ifstate.nix {inherit ifstateOverlay;};
  echo = import ./echo.nix;
  pool = "2001:db8:64:0:64::/96";
  dns = "2001:db8:64::53";

  # `udp-echo ADDRESS SIZE`: one datagram to port 7 that must come back
  # whole. The kernel may fragment it (no DF).
  udpEcho = pkgs:
    pkgs.writers.writePython3Bin "udp-echo" {} ''
      import socket
      import sys

      address, size = sys.argv[1], int(sys.argv[2])
      family = socket.AF_INET6 if ":" in address else socket.AF_INET
      sock = socket.socket(family, socket.SOCK_DGRAM)
      if family == socket.AF_INET:
          # IP_MTU_DISCOVER = IP_PMTUDISC_DONT
          sock.setsockopt(socket.IPPROTO_IP, 10, 0)
      sock.settimeout(3)
      sock.sendto(b"x" * size, (address, 7))
      got = sock.recv(65535)
      assert len(got) == size, f"sent {size} bytes, got {len(got)}"
      print(f"{size} bytes echoed")
    '';
  udpServer = pkgs:
    pkgs.writers.writePython3 "udp-echo-server" {} ''
      import socket

      sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
      sock.bind(("0.0.0.0", 7))
      while True:
          data, peer = sock.recvfrom(65535)
          sock.sendto(data, peer)
    '';

  clatAddress = {
    static = "2001:db8:aa::c1a7";
    slaac = "2001:db8:bb::c1a7";
  };

  # A machine that netif renders, plus the CLAT of specs/gateway.md G23:
  # Jool SIIT in a namespace of its own, because Jool translates in
  # PREROUTING and never sees packets the host itself generates.
  machine = {
    address,
    proxy,
  }: {
    pkgs,
    config,
    ...
  }: {
    virtualisation = {
      cores = 1;
      memorySize = 1024;
    };
    boot = {
      extraModulePackages = [config.boot.kernelPackages.jool];
      kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
    };
    # the CLAT forwards IPv6, so netif renders accept_ra 2
    clan._networkFacts.forwarding = true;
    services.openssh.enable = true;
    environment.systemPackages = [
      pkgs.curl
      pkgs.dig
      pkgs.jq
      pkgs.jool-cli
      pkgs.tcpdump
      (udpEcho pkgs)
    ];
    networking.ifstate.settings = {
      interfaces.clat0 = {
        addresses = [
          "192.0.0.1/29"
          "fd00:c1a7::1/64"
        ];
        link = {
          kind = "veth";
          state = "up";
          peer = "clat1";
          peer_netns = "clat";
        };
      };
      namespaces.clat = {
        interfaces.clat1 = {
          addresses = [
            "192.0.0.2/29"
            "fd00:c1a7::2/64"
          ];
          link = {
            kind = "veth";
            state = "up";
            peer = "clat0";
            peer_netns = null;
          };
        };
        routing.routes = [
          {
            to = "::/0";
            via = "fd00:c1a7::1";
          }
        ];
      };
      routing.routes = [
        {
          to = "0.0.0.0/0";
          via = "192.0.0.2";
        }
        {
          to = "${address}/128";
          via = "fd00:c1a7::2";
        }
      ];
    };
    # Idempotent: an IfState apply restarts it (Requires), and the
    # instance is still there.
    systemd.services.clat = {
      wantedBy = ["multi-user.target"];
      after = ["ifstate.service"];
      requires = ["ifstate.service"];
      path = [
        pkgs.iproute2
        pkgs.kmod
        pkgs.jool-cli
        pkgs.procps
        pkgs.gnugrep
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        modprobe jool_siit
        ip netns exec clat sysctl -w net.ipv4.conf.all.forwarding=1 net.ipv6.conf.all.forwarding=1
        if ! ip netns exec clat jool_siit instance display | grep clat >/dev/null; then
          ip netns exec clat jool_siit instance add clat --netfilter --pool6 ${pool}
          ip netns exec clat jool_siit -i clat eamt add ${address} 192.0.0.1
        fi
        # an IPv4 packet grows by 20 bytes when it becomes IPv6
        ip route replace default via 192.0.0.2 dev clat0 mtu 1480
        ${lib.optionalString proxy ''
          sysctl -w net.ipv6.conf.eth1.proxy_ndp=1
          ip -6 neigh replace proxy ${address} dev eth1
        ''}
      '';
    };
  };
in {
  name = "netif-v6only";

  clan = {
    directory = ./.;
    test.useContainers = false;
    inventory = {
      machines = {
        static = {};
        slaac = {};
        provider = {};
        server4 = {};
      };
      instances.uplink = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines = {
          static.settings.links.uplink = {
            interface = "eth1";
            static.ipv6 = ["2001:db8:aa::1/64"];
            gateway.ipv6 = "fe80::1";
            nameservers = [dns];
            ra = false;
          };
          slaac.settings.links.uplink = {
            interface = "eth1";
            # address and default from the provider's advertisement (N48)
            ra = true;
            nameservers = [dns];
          };
        };
      };
    };
  };

  nodes = {
    static = {
      imports = [
        (machine {
          address = clatAddress.static;
          proxy = false;
        })
      ];
      virtualisation.vlans = [1];
      # specs/netif.md N25: a change that drops the IPv6 default. The
      # CLAT's IPv4 default still answers, so only the guard's record of
      # the last good defaults catches it.
      specialisation.nogw6.configuration = {
        clanServices.netif.links.eth1.gateway6 = lib.mkForce null;
        networking.ifstate.settings.routing.routes = lib.mkForce [
          {
            to = "0.0.0.0/0";
            via = "192.0.0.2";
          }
          {
            to = "${clatAddress.static}/128";
            via = "fd00:c1a7::2";
          }
        ];
      };
    };
    slaac = {
      imports = [
        (machine {
          address = clatAddress.slaac;
          proxy = true;
        })
      ];
      virtualisation.vlans = [3];
      # specs/netif.md N25: a change that takes the RA link down; its
      # default goes, the CLAT's IPv4 default stays and answers.
      specialisation.down.configuration.networking.ifstate.settings.interfaces.eth1.link.state = lib.mkForce "down";
    };

    provider = {
      imports = [
        (import ./nat64-gateway.nix {
          inherit base pool;
          allow = "{ 2001:db8:aa::/64, 2001:db8:bb::/64 }";
          inside = ["fe80::1/64"];
          outside = ["198.51.100.1/24"];
          routes = [
            {
              to = "2001:db8:aa::/64";
              dev = "eth1";
            }
            # the cloud routes the machine's CLAT address to the machine
            {
              to = "${clatAddress.static}/128";
              via = "2001:db8:aa::1";
            }
          ];
          corefile = ''
            . {
              bind ${dns}
              hosts {
                198.51.100.80 web.test
              }
              dns64 {
                prefix ${pool}
              }
              errors
            }
          '';
        })
      ];
      virtualisation.vlans = lib.mkForce [
        1
        2
        3
      ];
      networking.ifstate.settings.interfaces = {
        eth3 = {
          addresses = ["2001:db8:bb::1/64"];
          link = {
            kind = "physical";
            state = "up";
          };
        };
        dns0 = {
          addresses = ["${dns}/128"];
          link = {
            kind = "dummy";
            state = "up";
          };
        };
      };
      services.radvd = {
        enable = true;
        config = ''
          interface eth3 {
            AdvSendAdvert on;
            prefix 2001:db8:bb::/64 { };
          };
        '';
      };
    };

    server4 = {pkgs, ...}: {
      imports = [base];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [2];
      };
      networking = {
        firewall.enable = false;
        ifstate.settings.interfaces.eth1 = {
          addresses = ["198.51.100.80/24"];
          link = {
            kind = "physical";
            state = "up";
          };
        };
      };
      systemd.services = {
        echo = {
          wantedBy = ["multi-user.target"];
          serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [80]}";
        };
        udp-echo = {
          wantedBy = ["multi-user.target"];
          serviceConfig.ExecStart = udpServer pkgs;
        };
      };
    };
  };

  testScript = ''
    ${import ../../../../tests/suite-lib.nix}
    ${import ../../../../tests/ifstate-noop.nix}
    import json
    import time

    DNS = "${dns}"
    SERVER4 = "198.51.100.80"
    # web.test has only an A record: what DNS64 makes of it
    MAPPED = "2001:db8:64:0:64:0:c633:6450"
    # the server sees the gateway's public IPv4 address on both paths
    SEEN = "::ffff:198.51.100.1"
    PREFIX = {"static": "2001:db8:aa::1/", "slaac": "2001:db8:bb:"}
    BY_NAME = "-6 http://web.test"
    LITERAL = f"http://{SERVER4}"


    def jool_stats(machine, command):
        lines = machine.succeed(f"{command} stats display").splitlines()
        pairs = (line.rpartition(":") for line in lines if ":" in line)
        return {key.strip(): int(value) for key, _, value in pairs if value.strip().isdigit()}


    def clat_translated(machine):
        return jool_stats(machine, "ip netns exec clat jool_siit -i clat").get("JSTAT_SUCCESS", 0)


    def nameservers(machine, path):
        return machine.succeed(f"awk '$1 == \"nameserver\" {{print $2}}' {path}").split()


    def two_megabytes(machine, tag, target):
        """2 MB down and up; the bound is far above the 0.06 s sample of
        specs/gateway.md §10.1."""
        size, seconds = machine.succeed(
            f"curl -sS --max-time 30 -o /dev/null -w '%{{size_download}} %{{time_total}}' {target}/big"
        ).split()
        assert size == "2000000", f"{tag}: downloaded {size} bytes from {target}"
        assert float(seconds) < 10, f"{tag}: 2 MB down took {seconds} s"
        got, sent = machine.succeed(
            f"head -c 2000000 /dev/zero | curl -sS --max-time 30 -H 'Expect:' --data-binary @- -w ' %{{time_total}}' {target}/"
        ).split()
        assert got == "2000000", f"{tag}: the server received {got} bytes through {target}"
        assert float(sent) < 10, f"{tag}: 2 MB up took {sent} s"
        print(f"FINDING {tag}: 2 MB through {target}: down {seconds} s, up {sent} s")


    def assert_online(machine, tag):
        """N45: no IPv4 on the NIC, and netif is content."""
        name = machine.name
        machine.wait_until_succeeds(f"ip -6 -o addr show dev eth1 scope global | grep '{PREFIX[name]}' >/dev/null", timeout=120)
        machine.wait_until_succeeds("systemctl is-active clat.service >/dev/null", timeout=120)
        machine.wait_until_succeeds("ip -6 route show default | grep 'dev eth1' >/dev/null", timeout=60)
        observe(f"{tag}: addresses and routes", machine, "ip -br addr; echo v4:; ip -4 route; echo v6:; ip -6 route | grep -v '^fe80'")
        assert machine.succeed("ip -4 -o addr show dev eth1").strip() == "", f"{tag}: an IPv4 address on the NIC"
        ipv4 = sorted(
            (link["ifname"], info["local"])
            for link in json.loads(machine.succeed("ip -j -4 addr show"))
            for info in link["addr_info"]
        )
        assert ipv4 == [("clat0", "192.0.0.1"), ("lo", "127.0.0.1")], f"{tag}: IPv4 addresses {ipv4}"
        default4 = " ".join(machine.succeed("ip -4 route show default").split())
        assert default4 == "default via 192.0.0.2 dev clat0 mtu 1480", f"{tag}: IPv4 default route: {default4}"
        default6 = json.loads(machine.succeed("ip -j -6 route show default"))
        assert len(default6) == 1, f"{tag}: IPv6 default routes {default6}"
        route = default6[0]
        assert route["dev"] == "eth1" and route["metric"] == 100, f"{tag}: {route}"
        if name == "static":
            assert route["gateway"] == "fe80::1" and route.get("protocol") != "ra", f"{tag}: {route}"
        else:
            assert route["gateway"].startswith("fe80::") and route.get("protocol") == "ra", f"{tag}: {route}"
        # the guard accepts a link-local gateway, and nothing failed
        machine.wait_until_succeeds("journalctl -b --no-pager -u netif-guard.service | grep 'gateways and targets answer' >/dev/null", timeout=120)
        machine.succeed("systemctl is-active netif-guard.service")
        failed = machine.succeed("systemctl --failed --no-legend --plain").strip()
        assert failed == "", f"{tag}: failed units: {failed}"
        # DNS: IPv6 nameservers only
        machine.wait_until_succeeds(f"grep '{DNS}' /run/systemd/resolve/resolv.conf >/dev/null", timeout=60)
        uplink = nameservers(machine, "/run/systemd/resolve/resolv.conf")
        assert uplink == [DNS], f"{tag}: nameservers {uplink}"
        stub = nameservers(machine, "/etc/resolv.conf")
        print(f"FINDING {tag}: /etc/resolv.conf names {stub}, systemd-resolved asks {uplink}")
        assert all(":" in server or server.startswith("127.") for server in stub), f"{tag}: an IPv4 nameserver: {stub}"
        # after a boot the first query can meet a nameserver that the
        # machine cannot reach yet
        machine.wait_until_succeeds(f"dig +short AAAA web.test | grep '{MAPPED}' >/dev/null", timeout=60)
        observe(f"{tag}: systemd-resolved and its fallback servers", machine, "journalctl -b --no-pager -u systemd-resolved.service | grep -i 'fallback\\|degraded' | tail -n 3")
        assert machine.succeed("dig +short AAAA web.test").split() == [MAPPED], f"{tag}: DNS64"
        assert machine.succeed("dig +short A web.test").split() == [SERVER4], f"{tag}: the A record"
        assert MAPPED in machine.succeed("getent ahosts web.test"), f"{tag}: getent"


    def assert_reaches_ipv4(machine, tag):
        """G4: a name through DNS64 and NAT64. G23: a literal through the CLAT."""
        before = clat_translated(machine)
        machine.wait_until_succeeds(f"curl -sS --max-time 5 {BY_NAME}/ >/dev/null", timeout=60)
        assert machine.succeed(f"curl -sS --max-time 10 {BY_NAME}/").strip() == SEEN, f"{tag}: by name"
        machine.succeed("ping -6 -c2 -W2 web.test >/dev/null")
        two_megabytes(machine, tag, BY_NAME)
        # the name leads to the mapped IPv6 address, not into the CLAT
        # (the CLAT's counters are no proof: systemd-resolved may try
        # its IPv4 fallback servers through it in the background)
        remote = machine.succeed(f"curl -sS --max-time 10 -o /dev/null -w '%{{remote_ip}}' {BY_NAME}/").strip()
        assert remote == MAPPED, f"{tag}: the name led to {remote}"

        machine.wait_until_succeeds(f"curl -sS --max-time 5 {LITERAL}/ >/dev/null", timeout=60)
        assert machine.succeed(f"curl -sS --max-time 10 {LITERAL}/").strip() == SEEN, f"{tag}: literal"
        machine.succeed(f"ping -c2 -W2 {SERVER4} >/dev/null")
        two_megabytes(machine, tag, LITERAL)
        # a program that picks the A record itself is served by the CLAT
        assert machine.succeed("curl -4 -sS --max-time 10 http://web.test/").strip() == SEEN, f"{tag}: the A record"
        moved = clat_translated(machine) - before
        print(f"FINDING {tag}: the CLAT translated {moved} packets")
        assert moved > 0, f"{tag}: the literal did not go through the CLAT"


    hosts = [static, slaac]

    with state_dump_on_failure(
        [static, slaac, provider, server4],
        extra=[
            "ip netns exec clat jool_siit -i clat stats display",
            "ip netns exec nat64 jool -i default stats display",
            "ip -6 neigh show proxy",
        ],
    ):
        start_all()
        for machine in [provider, server4, static, slaac]:
            machine.wait_for_unit("multi-user.target", timeout=300)
        provider.wait_for_unit("jool-netns.service", timeout=60)
        provider.wait_for_unit("coredns.service", timeout=60)

        with subtest("versions"):
            print_versions(static, ["kernel", "ifstate", "jool"])
            print_versions(provider, ["kernel", "ifstate", "jool", "coredns", "nftables"])

        for machine in hosts:
            with subtest(f"{machine.name}: N45: a machine with no IPv4 on its NIC is online"):
                assert_online(machine, machine.name)
                observe(f"{machine.name}: listening sockets", machine, "ss -tlnH | awk '{print $4}' | sort -u")
            with subtest(f"{machine.name}: G4, G23: a name through DNS64 and NAT64, a literal through the CLAT"):
                assert_reaches_ipv4(machine, machine.name)
        print("NETIF_V6ONLY_BOOT_OK")

        for machine in hosts:
            name = machine.name
            with subtest(f"{name}: path MTU through the translators, every link at 1500"):
                # Jool cuts what it translates to IPv6 at `lowest-ipv6-mtu`
                # (1280) and drops a fragmented ICMP message. An echo of
                # 1232 bytes is the largest that is 1280 bytes of IPv6.
                for flag in ["do", "dont"]:
                    machine.succeed(f"ping -M {flag} -c2 -W2 -s 1232 {SERVER4} >/dev/null")
                # by name the machine reassembles the answer itself
                for size in [1232, 1233, 1452]:
                    machine.succeed(f"ping -6 -M do -c2 -W2 -s {size} web.test >/dev/null")
                # FINDING specs/gateway.md §12.1 (untested): one byte more
                # through the CLAT gets no answer. NAT64 fragments the
                # reply at 1280 and the CLAT drops the fragments
                # (JSTAT64_FRAGMENTED_ICMP).
                dropped = jool_stats(machine, "ip netns exec clat jool_siit -i clat").get("JSTAT64_FRAGMENTED_ICMP", 0)
                for flag, size in [("do", 1233), ("do", 1452), ("dont", 1472)]:
                    machine.fail(f"ping -M {flag} -c2 -W1 -s {size} {SERVER4}")
                now = jool_stats(machine, "ip netns exec clat jool_siit -i clat").get("JSTAT64_FRAGMENTED_ICMP", 0)
                print(f"FINDING {name}: the CLAT dropped {now - dropped} fragmented ICMP packets")
                assert now > dropped, f"{name}: the CLAT did not count the dropped echo replies"
                # more than the IPv4 default route's MTU does not leave the machine
                for size in [1453, 1473]:
                    status, out = machine.execute(f"ping -M do -c1 -W2 -s {size} {SERVER4} 2>&1")
                    print(f"FINDING {name}: ping -M do -s {size}: rc={status}\n{out.rstrip()}")
                    assert status != 0 and "Message too long" in out, f"{name}: {size + 28} bytes of IPv4 with DF: {out}"
                # UDP: whole datagrams, and one the stack fragments
                for size in [1200, 1400, 1452, 4000]:
                    machine.succeed(f"udp-echo {SERVER4} {size}")
                    machine.succeed(f"udp-echo {MAPPED} {size}")
                # recorded, not asserted: a datagram of 2000 bytes got no
                # answer on either path in the first run, 4000 did
                for target in [SERVER4, MAPPED]:
                    observe(f"{name}: MTU: UDP datagram of 2000 bytes to {target}", machine, f"udp-echo {target} 2000")
                observe(f"{name}: MTU: IPv6 echo -s 2000 through NAT64", machine, "ping -6 -c2 -W2 -s 2000 web.test")
                observe(f"{name}: MTU: CLAT counters", machine, "ip netns exec clat jool_siit -i clat stats display")
                observe(f"{name}: MTU: NAT64 counters", provider, "ip netns exec nat64 jool -i default stats display")
                observe(f"{name}: MTU: Jool's MTU settings", machine, "ip netns exec clat jool_siit -i clat global display | grep -i 'mtu'")
        print("NETIF_V6ONLY_MTU_OK")

        with subtest("static: path MTU discovery when the IPv4 hop behind NAT64 is 1400"):
            provider.succeed("ip link set eth2 mtu 1400")
            try:
                static.succeed("ip route flush cache; ip -6 route flush cache")
                # the gateway's "fragmentation needed" crosses NAT64 and the CLAT
                status, out = static.execute(f"ping -M do -c3 -W2 -s 1232 {SERVER4} 2>&1; ping -M do -c2 -W2 -s 1452 {SERVER4} 2>&1")
                print(f"FINDING a 1480 byte echo with DF:\n{out.rstrip()}")
                assert "Frag needed and DF set (mtu = 1400)" in out, "no ICMP error came back through the translators"
                learned = static.succeed(f"ip route get {SERVER4}")
                assert "mtu 1400" in learned, f"the machine did not learn the path MTU: {learned}"
                two_megabytes(static, "IPv4 hop of 1400", LITERAL)
                two_megabytes(static, "IPv4 hop of 1400", BY_NAME)
                learned6 = static.succeed(f"ip -6 route get {MAPPED}")
                print(f"FINDING the IPv6 path MTU to the mapped address: {learned6.strip()}")
                assert "mtu 1420" in learned6, f"no IPv6 path MTU by name: {learned6}"
            finally:
                provider.succeed("ip link set eth2 mtu 1500")
                static.succeed("ip route flush cache; ip -6 route flush cache")

        with subtest("static: path MTU discovery when the IPv6 hop to the machine is 1400"):
            provider.succeed("ip link set eth1 mtu 1400")
            try:
                server4.succeed("ip route flush cache")
                two_megabytes(static, "IPv6 hop of 1400", LITERAL)
                two_megabytes(static, "IPv6 hop of 1400", BY_NAME)
                # "packet too big" became "fragmentation needed" for the server
                learned = server4.succeed("ip route get 198.51.100.1")
                print(f"FINDING the path MTU the IPv4 server learned: {learned.strip()}")
                assert "mtu 1380" in learned, f"the server did not learn the path MTU: {learned}"
            finally:
                provider.succeed("ip link set eth1 mtu 1500")
                server4.succeed("ip route flush cache")
                static.succeed("ip route flush cache; ip -6 route flush cache")
            assert_reaches_ipv4(static, "static, links back at 1500")

        for machine in hosts:
            with subtest(f"{machine.name}: an IfState apply changes nothing and keeps IPv4 reachable"):
                assert_ifstate_noop(machine)
                assert_online(machine, f"{machine.name} after an apply")
                assert_reaches_ipv4(machine, f"{machine.name} after an apply")
        print("NETIF_V6ONLY_APPLY_OK")

        for machine in hosts:
            with subtest(f"{machine.name}: a reboot keeps all of it"):
                machine.shutdown()
                machine.start()
                machine.wait_for_unit("multi-user.target", timeout=300)
                assert_online(machine, f"{machine.name} after a reboot")
                assert_reaches_ipv4(machine, f"{machine.name} after a reboot")
                assert_ifstate_noop(machine)
        print("NETIF_V6ONLY_REBOOT_OK")

        with subtest("reaching the machine over IPv6"):
            banner = provider.succeed("timeout 5 bash -c 'exec 3<>/dev/tcp/2001:db8:aa::1/22; head -c 8 <&3'")
            assert banner.startswith("SSH-2.0"), banner
            provider.fail("timeout 5 bash -c 'exec 3<>/dev/tcp/2001:db8:aa::1/8080'")

        with subtest("N25: the guard over IPv6 notices a gateway that stops answering"):
            static.succeed("systemctl restart netif-guard.service")
            provider.succeed("ip link set eth1 down")
            started = time.time()
            static.fail("systemctl restart netif-guard.service")
            took = round(time.time() - started, 1)
            print(f"FINDING the guard gave up on the gateway after {took} s")
            # the sample was 31.4 s
            assert took < 95, f"the guard took {took} s"
            assert static.succeed("systemctl show -p Result --value netif-guard.service").strip() == "exit-code"
            static.succeed("journalctl -b --no-pager -u netif-guard.service | grep 'no answer from fe80::1 on eth1' >/dev/null")
            static.succeed("journalctl -b --no-pager -u netif-guard.service | grep 'no earlier network configuration to roll back to' >/dev/null")
            # a link that went down lost its addresses and routes: reapply
            provider.succeed("ip link set eth1 up; systemctl restart ifstate.service")
            provider.wait_until_succeeds("systemctl is-active jool-netns.service >/dev/null", timeout=60)
            static.wait_until_succeeds("ping -c1 -W1 fe80::1%eth1 >/dev/null", timeout=60)
            static.succeed("systemctl restart netif-guard.service")
            for machine in hosts:
                assert_reaches_ipv4(machine, f"{machine.name} after the gateway came back")

        for machine, special, gateway in [(slaac, "down", "proto ra"), (static, "nogw6", "via fe80::1")]:
            with subtest(f"{machine.name}: N25: a change that loses the IPv6 default is rolled back"):
                machine.succeed("systemctl restart netif-guard.service")
                machine.succeed("grep -x '6 eth1' /var/lib/netif/guard/last-good-defaults")
                kept = machine.succeed("readlink /var/lib/netif/guard/last-good").strip()
                status, out = machine.execute(f"/run/booted-system/specialisation/{special}/bin/switch-to-configuration test 2>&1")
                print(out)
                assert status != 0, f"{machine.name}: the switch to {special} must fail"
                machine.wait_until_succeeds("journalctl --sync; journalctl -b --no-pager -u netif-guard.service | grep 'no IPv6 default route on eth1' >/dev/null", timeout=30)
                machine.wait_until_succeeds(f"ip -6 route show default | grep 'dev eth1' | grep '{gateway}' >/dev/null", timeout=60)
                assert machine.succeed("readlink /var/lib/netif/guard/last-good").strip() == kept
                status, out = machine.execute("/run/booted-system/bin/switch-to-configuration test 2>&1")
                assert status == 0, out
                assert_online(machine, f"{machine.name} after the rollback")
        print("NETIF_V6ONLY_GUARD_OK")

        print("NETIF_V6ONLY_OK")
  '';
}
