# gateway-nat64: two off-path NAT64 gateways, DNS64 and a client's CLAT
# (specs/gateway.md G2, G3, G4, G5, G6, G23; §10.1, §10.9, §12.2).
#
#   client   ─┐                      ┌─ gw1 ─┐
#   outsider ─┼─ vlan 1, IPv6 only ──┤       ├─ vlan 2, IPv4 only ── server4
#             │   2001:db8:c::/64    └─ gw2 ─┘    198.51.100.0/24
#
# Both gateways are `nat64-gateway.nix`: Jool in a namespace of its own
# that IfState declares, a table `inet nat64` as the source allowlist, a
# /96 and a DNS64 each. The suite pins:
#   - G2: the gateway's own table filters the translator for every
#     protocol; the NixOS forward chain alone lets ICMPv6 through (shown
#     on gw1 without the table); Jool in the host namespace would bypass
#     the forward hook (shown on gw1 with a second instance); the Jool
#     unit is idempotent across an IfState apply and a reboot; Jool's
#     pool4 limit; who owns which nftables table.
#   - G3/G4: DNS64 only for the allowlist, over UDP and TCP, synthesis
#     only for names without an AAAA record, the TTL cap.
#   - G5: a /96 destination that embeds a private IPv4 address is refused.
#   - G6: a dead gateway stalls a flow that is sending, without a reset,
#     also after it booted again without state; new flows go through the
#     other one within a bound.
#   - G23: the CLAT, and its follower with hysteresis. Jool's `pool6` is
#     the follower's only state. It stays on a lossy gateway, leaves a
#     dead one and a sick one (the gateway's own health check withdraws
#     `ipv4only.arpa` and closes its DNS64), moves only to a gateway that
#     answers, stays when none answers, and never moves back while the
#     current gateway is healthy.
#   - §12.1: fragments, path MTU discovery and an idle TCP flow through
#     the translators.
{
  inputs,
  lib,
  ...
}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  base = import ../../../ifstate.nix {inherit ifstateOverlay;};

  pool1 = "2001:db8:a1:0:64::/96";
  # Printed with `::` in the middle of every address inside it: the
  # follower must not cut the /96 out of an answer as a string.
  pool2 = "2001:db8:a2::/96";
  # 198.51.100.80 inside each pool
  server1 = "2001:db8:a1:0:64:0:c633:6450";
  server2 = "2001:db8:a2::c633:6450";
  # The health target of both gateways, 198.51.100.90 inside each pool:
  # an address of its own, so it can die while the server stays.
  healthAddr = "198.51.100.90";
  target1 = "2001:db8:a1:0:64:0:c633:645a";
  target2 = "2001:db8:a2::c633:645a";
  # A second /96 of gw1's prefix, for a Jool instance in the host
  # namespace: the negative proof of G2.
  poolHost = "2001:db8:a1:0:65::/96";
  serverHost = "2001:db8:a1:0:65:0:c633:6450";
  clientAddr = "2001:db8:c::10";
  clatAddr = "2001:db8:c::c1a7";
  clients = "{ ${clientAddr}, ${clatAddr} }";
  nameservers = [
    "2001:db8:c::1"
    "2001:db8:c::2"
  ];

  phys = addresses: {
    inherit addresses;
    link = {
      kind = "physical";
      state = "up";
    };
  };

  # Both gateways' prefixes are "routed to the gateway", as a provider
  # routes a machine's /64.
  poolRoutes = [
    {
      to = "2001:db8:a1::/64";
      via = "2001:db8:c::1";
    }
    {
      to = "2001:db8:a2::/64";
      via = "2001:db8:c::2";
    }
  ];

  hooks = {
    pre_raw = "prerouting priority -300";
    pre_filter = "prerouting priority 0";
    input = "input priority 0";
    forward = "forward priority 0";
    output = "output priority 0";
    post = "postrouting priority 0";
  };
  # Counters at every hook: which of them see NAT64 traffic? (G2)
  hooksTable = pool: {
    family = "inet";
    content = lib.concatStrings (
      lib.mapAttrsToList (name: hook: ''
        chain ${name} {
          type filter hook ${hook};
          ip6 daddr ${pool} counter comment "${name} v6 to pool6"
          ip6 daddr ${poolHost} counter comment "${name} v6 to host pool6"
          ip daddr 198.51.100.80 counter comment "${name} v4 to server"
        }
      '')
      hooks
    );
  };

  # CoreDNS binds one address: netif runs systemd-resolved on every
  # machine (N9), and its stub holds 127.0.0.53:53. `ipv4only.arpa`
  # comes from the file that the gateway's health check writes.
  corefile = address: pool: ''
    . {
      bind ${address}
      hosts /run/nat64-health/ipv4only.hosts {
        198.51.100.80 web.long.test fresh.long.test web.short.test sick.long.test back.long.test
        2001:db8:c::66 six.long.test
        ttl 3600
        reload 1s
      }
      rewrite ttl suffix short.test. 5
      dns64 {
        prefix ${pool}
      }
      errors
    }
  '';

  gateway = n: pool: target: {
    imports = [
      (import ./nat64-gateway.nix {
        inherit base pool;
        allow = clients;
        inside = ["2001:db8:c::${n}/64"];
        outside = ["198.51.100.${n}/24"];
        healthTarget = target;
        routes = [
          {
            to = "${clatAddr}/128";
            via = clientAddr;
          }
          # an IPv4 default route, as a real gateway has: without one the
          # kernel drops a private destination before the firewall sees it
          {
            to = "0.0.0.0/0";
            via = "198.51.100.80";
          }
        ];
        corefile = corefile "2001:db8:c::${n}" pool;
      })
    ];
    networking.nftables.tables.suite = hooksTable pool;
  };

  # The CLAT follower moves after this many failed rounds in a row. A
  # round is one query with a 1 s timeout to the gateway in use, and a
  # failed round lasts 1.5 s. With 30 % loss a run of 8 has a chance of
  # 0.3^8 = 0.007 %; a dead or sick gateway costs 12 s.
  followNeed = 8;

  httpServer = pkgs:
    pkgs.writeText "server4.py" ''
      import http.server
      import socket
      import threading
      import time


      class Handler(http.server.BaseHTTPRequestHandler):
          def reply(self, body):
              self.send_response(200)
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def do_GET(self):
              if self.path == "/big":
                  self.reply(b"x" * 2000000)
              else:
                  self.reply((self.client_address[0] + "\n").encode())

          # answers the number of bytes it received
          def do_POST(self):
              left = int(self.headers.get("Content-Length", "0"))
              got = 0
              while left > 0:
                  chunk = self.rfile.read(min(65536, left))
                  if not chunk:
                      break
                  got += len(chunk)
                  left -= len(chunk)
              self.reply((str(got) + "\n").encode())

          def log_message(self, *args):
              pass


      def tick(conn):
          try:
              while True:
                  conn.sendall(b"tick\n")
                  time.sleep(1)
          except OSError:
              pass


      def echo(conn):
          try:
              while data := conn.recv(65536):
                  conn.sendall(data)
          except OSError:
              pass


      def listen(port, serve):
          sock = socket.socket()
          sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
          sock.bind(("0.0.0.0", port))
          sock.listen()
          while True:
              conn, _ = sock.accept()
              threading.Thread(target=serve, args=(conn,), daemon=True).start()


      def udp_echo():
          sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
          sock.bind(("0.0.0.0", 9001))
          while True:
              data, peer = sock.recvfrom(65535)
              sock.sendto(data, peer)


      threading.Thread(target=listen, args=(9000, tick), daemon=True).start()
      threading.Thread(target=listen, args=(9002, echo), daemon=True).start()
      threading.Thread(target=udp_echo, daemon=True).start()
      http.server.ThreadingHTTPServer(("0.0.0.0", 80), Handler).serve_forever()
    '';

  # Client side of the traffic shapes: one UDP datagram that must come
  # back whole, and a TCP flow that stays silent until a file appears.
  shapes = ''
    import os
    import socket
    import sys
    import time

    mode, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
    if mode == "udp":
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        sock = socket.socket(family, socket.SOCK_DGRAM)
        sock.settimeout(3)
        data = os.urandom(int(sys.argv[4]))
        sock.sendto(data, (host, port))
        reply, _ = sock.recvfrom(65535)
        sys.exit(0 if reply == data else 1)
    if mode == "idle":
        go, result = sys.argv[4], sys.argv[5]
        sock = socket.create_connection((host, port), timeout=10)
        sock.sendall(b"a")
        assert sock.recv(1) == b"a"
        with open(result, "w") as file:
            file.write("open\n")
        started = time.time()
        while not os.path.exists(go):
            time.sleep(0.5)
        idle = time.time() - started
        sock.sendall(b"b")
        assert sock.recv(1) == b"b"
        with open(result, "w") as file:
            file.write(f"ok {idle:.0f}\n")
    # A flow that sends one byte a second and logs what comes back: a
    # reset, a timeout or an end shows as an "error" line.
    if mode == "talk":
        log = open(sys.argv[4], "a", buffering=1)
        sock = socket.create_connection((host, port), timeout=10)
        sock.settimeout(1)
        count = 0
        while True:
            count += 1
            try:
                sock.sendall(b"x")
                if sock.recv(65536):
                    log.write(f"echo {count}\n")
                else:
                    log.write(f"error end of stream at {count}\n")
                    break
            except TimeoutError:
                log.write(f"silent {count}\n")
            except OSError as error:
                log.write(f"error {error} at {count}\n")
                break
            time.sleep(1)
  '';

  # The CLAT follower (G23). Jool's `pool6` is its only state: every
  # round reads it and asks whether a nameserver still names that /96.
  follower = ''
    import ipaddress
    import re
    import subprocess
    import sys
    import time

    NAMESERVERS = "${toString nameservers}".split()
    NEED = ${toString followNeed}
    WELL_KNOWN = {ipaddress.IPv4Address("192.0.0.170"), ipaddress.IPv4Address("192.0.0.171")}
    JOOL = ["ip", "netns", "exec", "clat", "jool_siit", "-i", "clat", "global"]


    def prefix_of_answer(text):
        """The /96 that one AAAA answer for ipv4only.arpa names (RFC 7050).
        Raises ValueError for anything else."""
        address = ipaddress.IPv6Address(text.strip())
        if ipaddress.IPv4Address(int(address) & 0xFFFFFFFF) not in WELL_KNOWN:
            raise ValueError(f"{text}: does not end in a well-known IPv4 address")
        prefix = ipaddress.IPv6Network((int(address) >> 32 << 32, 96))
        first = prefix.network_address
        if first.is_unspecified or first.is_loopback or first.is_link_local or first.is_multicast:
            raise ValueError(f"{text}: {prefix} is not a prefix to route to")
        return prefix


    def prefix_of(nameserver):
        """The one /96 that a nameserver names, or None: no answer, an
        answer that is not an address, or answers that disagree."""
        query = ["dig", "+short", "+time=1", "+tries=1", "AAAA", "ipv4only.arpa", "@" + nameserver]
        try:
            lines = subprocess.run(query, capture_output=True, text=True, timeout=5).stdout.splitlines()
            found = {prefix_of_answer(line) for line in lines}
        except (ValueError, subprocess.TimeoutExpired):
            return None
        return found.pop() if len(found) == 1 else None


    def live_pool6():
        """(instance exists, its pool6 or None): Jool is the truth."""
        shown = subprocess.run([*JOOL, "display"], capture_output=True, text=True)
        if shown.returncode != 0:
            return False, None
        found = re.search(r"^\s*pool6:\s*(\S+)", shown.stdout, re.MULTILINE)
        try:
            return True, ipaddress.IPv6Network(found.group(1))
        except (AttributeError, ValueError):
            return True, None


    def pace(started, period):
        time.sleep(max(0.0, started + period - time.monotonic()))


    def follow():
        fails = 0
        owner = None
        said = None
        while True:
            started = time.monotonic()
            exists, pool6 = live_pool6()
            if not exists:
                if said != "missing":
                    print("clat-follow: no CLAT instance, waiting")
                    said = "missing"
                pace(started, 1)
                continue
            # the nameserver that named pool6 last time is asked first
            answers = {}
            for nameserver in sorted(NAMESERVERS, key=lambda item: item != owner):
                answers[nameserver] = prefix_of(nameserver)
                if answers[nameserver] is not None and answers[nameserver] == pool6:
                    break
            else:
                nameserver = None
            if nameserver is not None:
                if said != "healthy" or nameserver != owner:
                    print(f"clat-follow: pool6 {pool6} is named by {nameserver}")
                owner, fails, said = nameserver, 0, "healthy"
                pace(started, 2)
                continue
            proven = [(server, prefix) for server, prefix in answers.items() if prefix is not None]
            if not proven:
                # nowhere to go: stay, and do not count against the gateway
                if said != "alone":
                    print(f"clat-follow: no nameserver answers ipv4only.arpa, pool6 stays {pool6}")
                fails, said = 0, "alone"
                pace(started, 1.5)
                continue
            said = "failing"
            fails += 1
            server, prefix = proven[0]
            print(f"clat-follow: check {fails}/{NEED} failed: nobody names pool6 {pool6}, {server} names {prefix}")
            if fails >= NEED:
                update = subprocess.run([*JOOL, "update", "pool6", str(prefix)], capture_output=True, text=True)
                if update.returncode == 0:
                    print(f"clat-follow: pool6 -> {prefix} (nameserver {server}, was {pool6})")
                    owner, fails = server, 0
                else:
                    print(f"clat-follow: pool6 update to {prefix} failed: {update.stderr.strip()}")
            pace(started, 1.5)


    if sys.argv[1:2] == ["prefix"]:
        try:
            print(prefix_of_answer(sys.argv[2]))
        except ValueError as error:
            sys.exit(str(error))
    else:
        follow()
  '';

  v6host = address: {pkgs, ...}: {
    imports = [base];
    virtualisation = {
      cores = 1;
      memorySize = 1024;
      vlans = [1];
    };
    environment = {
      systemPackages = [
        pkgs.curl
        pkgs.dig
        pkgs.netcat
        pkgs.tcpdump
        pkgs.python3
      ];
      etc."suite/shapes.py".text = shapes;
    };
    networking = {
      firewall.enable = false;
      inherit nameservers;
      ifstate.settings = {
        interfaces.eth1 = phys ["${address}/64"];
        routing.routes = poolRoutes;
      };
    };
  };
in {
  name = "gateway-nat64";

  clan = {
    directory = ./.;
    test.useContainers = false;
    inventory.machines = {
      client = {};
      outsider = {};
      gw1 = {};
      gw2 = {};
      server4 = {};
    };
  };

  nodes = {
    # IPv6 only, with a CLAT: Jool SIIT in a namespace, because Jool
    # translates in PREROUTING and never sees locally generated packets.
    client = {
      pkgs,
      config,
      ...
    }: {
      imports = [(v6host clientAddr)];
      boot = {
        extraModulePackages = [config.boot.kernelPackages.jool];
        kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
      };
      environment = {
        systemPackages = [pkgs.jool-cli];
        etc."suite/clat-follow.py".text = follower;
      };
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
            to = "${clatAddr}/128";
            via = "fd00:c1a7::2";
          }
        ];
      };
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
          # idempotent: an IfState apply restarts this unit, and the
          # instance is still there
          if ! ip netns exec clat jool_siit instance display | grep clat >/dev/null; then
            ip netns exec clat jool_siit instance add clat --netfilter --pool6 ${pool1}
            ip netns exec clat jool_siit -i clat eamt add ${clatAddr} 192.0.0.1
          fi
          # an IPv4 packet grows by 20 bytes when it becomes IPv6
          ip route replace default via 192.0.0.2 dev clat0 mtu 1480
        '';
      };
      # The CLAT follows a live gateway (G23), with hysteresis (§12.2).
      # A gateway is healthy while its nameserver answers `ipv4only.arpa`
      # (RFC 7050) with addresses that name one /96: the gateway withdraws
      # the record and closes its DNS64 when its own check through the
      # translator fails, so the client needs no target on the internet.
      #
      # Every round the follower reads the CLAT's live `pool6` from Jool.
      # While a nameserver names that /96 it does nothing. A round counts
      # as failed when nobody names it and another nameserver names a
      # /96 of its own; after `followNeed` such rounds in a row it moves
      # there. When no nameserver answers there is nowhere to go: it
      # stays, and the count starts again. It keeps no file: a CLAT
      # instance that came back with its first /96 is found and moved.
      systemd.services.clat-follow = {
        wantedBy = ["multi-user.target"];
        after = ["clat.service"];
        requires = ["clat.service"];
        path = [
          pkgs.iproute2
          pkgs.jool-cli
          pkgs.dig
        ];
        serviceConfig = {
          Restart = "always";
          ExecStart = "${lib.getExe pkgs.python3} -u /etc/suite/clat-follow.py";
        };
      };
    };

    outsider = v6host "2001:db8:c::66";

    gw1 = gateway "1" pool1 target1;
    gw2 = gateway "2" pool2 target2;

    # IPv4 only. It is also the gateways' IPv4 default router, and it
    # routes nothing.
    server4 = {pkgs, ...}: {
      imports = [base];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [2];
      };
      networking = {
        firewall.enable = false;
        # the health target is a /32: deleting it leaves the /24 alone
        ifstate.settings.interfaces.eth1 = phys [
          "198.51.100.80/24"
          "${healthAddr}/32"
        ];
      };
      systemd.services.server4 = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${httpServer pkgs}";
      };
    };
  };

  testScript = ''
    import ipaddress
    import re
    import time

    ${import ../../../../tests/suite-lib.nix}
    ${import ../../../../tests/ifstate-noop.nix}

    def embed(gateway, ipv4):
        return str(ipaddress.IPv6Address(int(gateway.pool.network_address) | int(ipaddress.IPv4Address(ipv4))))


    class Gateway:
        def __init__(self, machine, addr, pool, v4):
            self.machine, self.addr, self.v4 = machine, addr, v4
            self.pool = ipaddress.IPv6Network(pool)
            self.server = embed(self, "198.51.100.80")
            # RFC 7050: what `ipv4only.arpa` must answer
            self.named = sorted(embed(self, known) for known in ["192.0.0.170", "192.0.0.171"])


    G1 = Gateway(gw1, "2001:db8:c::1", "${pool1}", "198.51.100.1")
    G2 = Gateway(gw2, "2001:db8:c::2", "${pool2}", "198.51.100.2")
    assert (G1.server, G2.server) == ("${server1}", "${server2}")
    assert (embed(G1, "${healthAddr}"), embed(G2, "${healthAddr}")) == ("${target1}", "${target2}")
    SERVER_HOST = "${serverHost}"
    PRIVATE = ["10.0.0.1", "100.64.0.1", "169.254.0.1", "172.16.0.1", "192.168.1.1"]
    NEED = ${toString followNeed}
    FOLLOW_MOVES = "journalctl -b -u clat-follow -o cat --no-pager | grep -c 'clat-follow: pool6 ->'"


    def first_int(pattern, text):
        found = re.search(pattern, text)
        assert found is not None, f"{pattern} not in {text}"
        return int(found.group(1))


    def other(gateway):
        return G2 if gateway is G1 else G1


    def http(target, path="", limit=5, family=""):
        host = f"[{target}]" if ":" in target else target
        return f"curl -sg {family} --max-time {limit} 'http://{host}/{path}'"


    def http6(name, path="", limit=5):
        """By name over IPv6 only: DNS64 and NAT64, never the A record and the CLAT."""
        return http(name, path, limit, family="-6")


    def upload(target, size=300000):
        """Succeeds when the server counted every byte."""
        host = f"[{target}]" if ":" in target else target
        return f"test \"$(head -c {size} /dev/zero | curl -sg --max-time 15 -H 'Expect:' --data-binary @- 'http://{host}/')\" = {size}"


    def udp(target, size=100):
        return f"python3 /etc/suite/shapes.py udp {target} 9001 {size}"


    def hook(machine, comment, what="packets"):
        table = machine.succeed("nft list table inet suite")
        pattern = r"counter packets (\d+) bytes \d+" if what == "packets" else r"counter packets \d+ bytes (\d+)"
        return first_int(rf'{pattern} comment "{comment}"', table)


    def counted(machine, chain, comment):
        """Packets that a rule of the gateway's own table refused."""
        rule = machine.succeed(f"nft list chain inet nat64 {chain} | grep '{comment}'")
        return first_int(r"counter packets (\d+)", rule)


    def refused_private(machine):
        return counted(machine, "forward", "nat64-private")


    def names_prefix(gateway):
        return f"dig +short +time=1 +tries=1 AAAA ipv4only.arpa @{gateway.addr} | grep -Fx '{gateway.named[0]}' >/dev/null"


    def dns_closed(gateway, flags=""):
        """The listener answers a query with an error at once, not with silence.
        dig exits 9 then, and the driver's shell runs with pipefail."""
        return f"(dig {flags} +time=2 +tries=1 AAAA six.long.test @{gateway.addr} 2>&1 || true) | grep -i 'connection refused' >/dev/null"


    def clat_gateway():
        shown = client.succeed("ip netns exec clat jool_siit -i clat global display | grep pool6")
        pool6 = ipaddress.IPv6Network(shown.split()[-1])
        assert pool6 in (G1.pool, G2.pool), shown
        return G1 if pool6 == G1.pool else G2


    def clat_on(gateway):
        return f"ip netns exec clat jool_siit -i clat global display | grep -F 'pool6: {gateway.pool}' >/dev/null"


    def moves():
        return int(client.succeed(f"{FOLLOW_MOVES} || true").strip())


    def stays(gateway, count):
        """The follower has moved `count` times and the CLAT is on `gateway`."""
        return f"test \"$({FOLLOW_MOVES})\" -eq {count} && {clat_on(gateway)}"


    def follower_pid():
        return client.succeed("systemctl show -p MainPID --value clat-follow.service").strip()


    def resolver():
        return client.succeed("resolvectl status | grep 'Current DNS Server'").split()[-1]


    def echoes(log):
        return int(client.succeed(f"grep -c echo {log} || true").strip())


    def gateway_ready(gateway):
        machine = gateway.machine
        machine.wait_for_unit("multi-user.target", timeout=300)
        for unit in ["jool-netns.service", "nat64-health.service", "nftables.service"]:
            machine.wait_for_unit(unit, timeout=60)
        client.wait_until_succeeds(f"ping -c1 -W2 {gateway.addr}", timeout=60)
        # the health check has answered through the translator: only then
        # does it start CoreDNS
        machine.wait_until_succeeds("systemctl is-active coredns.service >/dev/null", timeout=60)
        client.wait_until_succeeds(names_prefix(gateway), timeout=60)


    def assert_gateway(gateway):
        """What one gateway must do, whatever happened to it before."""
        machine, server = gateway.machine, gateway.server
        # G2: the Jool instance and its pool4 live in the namespace only
        machine.succeed(f"ip netns exec nat64 jool -i default global display | grep -F 'pool6: {gateway.pool}' >/dev/null")
        machine.fail("jool -i default global display")
        for proto in ["tcp", "udp", "icmp"]:
            pool4 = machine.succeed(f"ip netns exec nat64 jool pool4 display --{proto} --csv")
            assert pool4.count("10.64.0.2,1100,65535") == 1, pool4
        # a declared source is translated, behind the gateway's own IPv4:
        # TCP, ICMP and UDP
        out = client.succeed(http(server)).strip()
        assert out == gateway.v4, out
        client.succeed(f"ping -c2 -W2 {server}")
        client.succeed(udp(server))
        # G4: DNS64 inside the gateway's /96, over UDP and TCP
        for flags in ["", "+tcp"]:
            out = client.succeed(f"dig {flags} +short +time=2 +tries=1 AAAA web.long.test @{gateway.addr}").strip()
            assert out == server, f"{flags}: {out}"
        # G2: an undeclared source reaches the gateway, but not the
        # translator, with any protocol. Every packet is counted.
        outsider.succeed(f"ping -c1 -W2 {gateway.addr}")
        dropped = {}
        for shape, cmd in [("ping", f"ping -c2 -W1 {server}"), ("tcp", http(server, limit=3)), ("udp", udp(server))]:
            before = counted(machine, "forward", "nat64-undeclared")
            outsider.fail(cmd)
            dropped[shape] = counted(machine, "forward", "nat64-undeclared") - before
        # G4: nor the DNS64 listener
        for shape, flags in [("dns udp", ""), ("dns tcp", "+tcp")]:
            before = counted(machine, "input", "dns64-undeclared")
            outsider.fail(f"dig {flags} +short +time=2 +tries=1 AAAA web.long.test @{gateway.addr}")
            dropped[shape] = counted(machine, "input", "dns64-undeclared") - before
        print(f"FINDING {machine.name} dropped from the undeclared source: {dropped}")
        # two echo requests, one datagram, one query; TCP repeats its SYN
        assert dropped["ping"] == 2 and dropped["udp"] == 1 and dropped["dns udp"] == 1, dropped
        assert 1 <= dropped["tcp"] <= 6 and 1 <= dropped["dns tcp"] <= 6, dropped
        # G5: a private IPv4 destination is refused behind the translator
        for private in PRIVATE:
            before = refused_private(machine)
            client.fail(f"ping -c1 -W2 {embed(gateway, private)}")
            assert refused_private(machine) == before + 1, f"{machine.name} did not refuse {private}"
        # the gateway's own IPv4 traffic does not pass the translator
        out = machine.succeed(http("198.51.100.80")).strip()
        assert out == gateway.v4, out


    with state_dump_on_failure([client, gw1, gw2, server4], extra=["ip netns exec nat64 jool instance display", "ip netns exec nat64 jool pool4 display", "ip netns exec clat jool_siit -i clat global display", "resolvectl status", "journalctl -b --no-pager -u clat-follow -u nat64-health -u jool-netns -u coredns | tail -n 80"]):
        with subtest("boot and versions"):
            start_all()
            for machine in [client, outsider, server4]:
                machine.wait_for_unit("multi-user.target", timeout=300)
            server4.wait_until_succeeds("ss -tln | grep ':80 ' >/dev/null", timeout=60)
            client.wait_for_unit("clat.service", timeout=60)
            client.wait_for_unit("clat-follow.service", timeout=60)
            for gateway in [G1, G2]:
                gateway_ready(gateway)
            print_versions(gw1, ["kernel", "jool", "ifstate", "nftables", "coredns"])
            print_versions(client, ["kernel", "jool", "ifstate"])

        with subtest("G2, G4, G5: each gateway translates declared sources only, every protocol"):
            for gateway in [G1, G2]:
                assert_gateway(gateway)
                size = client.succeed(http(gateway.server, "big", 30) + " -o /dev/null -w '%{size_download}'").strip()
                assert size == "2000000", size
            observe("gw2's own table", gw2, "nft list table inet nat64")
            print("GATEWAY_NAT64_BASIC_OK")

        with subtest("G2: the forward chain and conntrack see a namespaced Jool"):
            counters = ["pre_filter v6 to pool6", "forward v6 to pool6", "post v6 to pool6", "forward v4 to server", "post v4 to server"]
            bytes_before = {comment: hook(gw2, comment, "bytes") for comment in counters}
            before_input = hook(gw2, "input v6 to pool6")
            # one upload of 300 kB from the client: every hook must count it
            client.succeed(upload(G2.server))
            for comment in counters:
                grown = hook(gw2, comment, "bytes") - bytes_before[comment]
                print(f"FINDING gw2 hook counter '{comment}': {grown} bytes for an upload of 300000")
                assert grown >= 300000, f"{comment}: {grown}"
            # the translator is another machine to the host: nothing is input
            assert hook(gw2, "input v6 to pool6") == before_input == 0
            gw2.succeed("conntrack -L -p tcp 2>/dev/null | grep 'dst=198.51.100.80' | grep 'src=10.64.0.2' >/dev/null")
            observe("gw2 conntrack", gw2, "conntrack -L 2>/dev/null | head -n 12")

        with subtest("G2: Jool's pool4 cannot overlap the namespace's ephemeral ports"):
            status, out = gw2.execute("ip netns exec nat64 jool pool4 add 10.64.0.2 1024-65535 --tcp 2>&1")
            print(f"FINDING pool4 add 1024-65535: rc={status}\n{out.rstrip()}")
            assert status != 0 and "ephemeral" in out, out
            out = gw2.succeed("ip netns exec nat64 sysctl -n net.ipv4.ip_local_port_range").split()
            assert out == ["1024", "1099"], out
            observe("gw2 jool global", gw2, "ip netns exec nat64 jool global display")

        with subtest("G2 negative proof: Jool in the host namespace bypasses the forward chain"):
            gw1.succeed("jool instance add hostns --netfilter --pool6 ${poolHost}")
            try:
                # the forward policy is drop and no rule names this /96
                out = outsider.succeed(http(SERVER_HOST)).strip()
                assert out == G1.v4, out
                seen = {name: hook(gw1, f"{name} v6 to host pool6") for name in ["pre_raw", "pre_filter", "input", "forward", "output", "post"]}
                print(f"FINDING gw1 hooks that saw IPv6 towards a host namespace Jool: {seen}")
                assert seen["pre_raw"] > 0, seen
                assert seen["pre_filter"] == seen["input"] == seen["forward"] == seen["output"] == seen["post"] == 0, seen
            finally:
                gw1.succeed("jool instance remove hostns")
            outsider.fail(http(SERVER_HOST, limit=3))
            outsider.fail(http(G1.server, limit=3))

        with subtest("G2 negative proof: the NixOS forward chain alone lets an undeclared source ping through the translator"):
            # Without the gateway's own table the allowlist is the rule in
            # `extraForwardRules`. `forward-allow` accepts ICMPv6 before it.
            gw1.succeed("nft delete table inet nat64")
            try:
                observe("gw1 forward-allow", gw1, "nft list chain inet nixos-fw forward-allow")
                outsider.succeed(f"ping -c2 -W2 {G1.server}")
                # the rule does stop what reaches it
                outsider.fail(http(G1.server, limit=3))
                outsider.fail(udp(G1.server))
            finally:
                gw1.succeed("systemctl restart nftables.service")
            before = counted(gw1, "forward", "nat64-undeclared")
            outsider.fail(f"ping -c2 -W1 {G1.server}")
            assert counted(gw1, "forward", "nat64-undeclared") == before + 2
            client.succeed(f"ping -c2 -W2 {G1.server}")

        with subtest("G4: DNS64 synthesises only what has no AAAA record, with a capped TTL"):
            for gateway in [G1, G2]:
                addr, server = gateway.addr, gateway.server
                answer = client.succeed(f"dig @{addr} web.long.test AAAA +noall +answer").split()
                print(f"FINDING synthesised answer from {addr}: {answer}")
                assert answer[3:] == ["AAAA", server] and int(answer[1]) <= 600, answer
                answer = client.succeed(f"dig @{addr} web.short.test AAAA +noall +answer").split()
                assert answer[3:] == ["AAAA", server] and int(answer[1]) <= 5, answer
                # a real AAAA record is not rewritten
                answer = client.succeed(f"dig @{addr} six.long.test AAAA +short").split()
                assert answer == ["2001:db8:c::66"], answer
                # the A record stays what it is
                answer = client.succeed(f"dig @{addr} web.long.test A +short").split()
                assert answer == ["198.51.100.80"], answer
                # RFC 7050: the well-known name names this gateway's /96
                answer = sorted(client.succeed(f"dig @{addr} ipv4only.arpa AAAA +short").split())
                assert answer == gateway.named, answer
            # by name, through systemd-resolved and whichever gateway it uses
            used = G1 if resolver() == G1.addr else G2
            for name in ["web.long.test", "web.short.test"]:
                out = client.succeed(http6(name)).strip()
                assert out == used.v4, f"{name}: {out}"

        with subtest("G23: the follower derives the /96 by address arithmetic and refuses what is not one"):
            parse = "python3 /etc/suite/clat-follow.py prefix"
            for given, prefix in {
                "64:ff9b::c000:aa": "64:ff9b::/96",
                "2001:db8:a1:0:64:1234:c000:aa": "2001:db8:a1:0:64:1234::/96",
                "2001:db8:a2::c000:ab": "2001:db8:a2::/96",
                G1.named[0]: str(G1.pool),
            }.items():
                out = client.succeed(f"{parse} {given}").strip()
                assert out == prefix, f"{given}: {out}"
            for given in ["2001:db8:a2::1", "::c000:aa", "fe80::c000:aa", "ff02::c000:aa", "192.0.0.170", "refused", "2001:db8:a2::c000:aa/96"]:
                client.fail(f"{parse} '{given}'")
            # what the follower found at boot, read from Jool and from DNS
            observe("the follower's log", client, "journalctl -b -u clat-follow -o cat --no-pager | tail -n 5")
            assert moves() == 0

        with subtest("G23: the CLAT carries IPv4 literals from an IPv6-only host"):
            gateway = clat_gateway()
            assert gateway is G1
            assert "default via 192.0.0.2 dev clat0 mtu 1480" in client.succeed("ip -4 route show default")
            assert "2001:db8:c::c1a7/128" in client.succeed("ip netns exec clat jool_siit -i clat eamt display --csv")
            out = client.succeed(http("198.51.100.80")).strip()
            assert out == gateway.v4, out
            client.succeed("ping -c2 -W2 198.51.100.80")
            size = client.succeed(http("198.51.100.80", "big", 30) + " -o /dev/null -w '%{size_download}'").strip()
            assert size == "2000000", size
            observe("client addresses and routes", client, "ip -br addr; ip -4 route; ip -6 route")

        with subtest("traffic shapes: fragments and path MTU discovery through NAT64 and the CLAT"):
            gateway = clat_gateway()
            server = gateway.server
            shapes = {}

            def works(cmd):
                return client.execute(f"{cmd} >/dev/null 2>&1")[0] == 0

            def learned(cmd):
                found = re.findall(r"mtu (\d+)", client.succeed(cmd))
                return int(found[-1]) if found else None

            for path, target in [("nat64", server), ("clat", "198.51.100.80")]:
                shapes[f"{path}: ping with 1400 bytes"] = works(f"ping -c2 -W2 -s 1400 {target}")
                shapes[f"{path}: ping with 3000 bytes (fragments)"] = works(f"ping -c2 -W2 -s 3000 {target}")
                shapes[f"{path}: UDP datagram of 3000 bytes echoed (fragments)"] = works(udp(target, 3000))
            # FINDING not in specs/gateway.md: a large ping through the CLAT
            # gets no answer. The gateway's Jool fragments what it sends
            # towards IPv6 at `lowest-ipv6-mtu` (1280) when the IPv4 packet
            # allows fragmentation, as an echo reply does. Jool SIIT drops a
            # fragmented ICMP packet: it cannot translate the checksum
            # (RFC 7915). UDP and TCP are not affected.
            shapes["clat: ping with 1200 bytes"] = works("ping -c2 -W2 -s 1200 198.51.100.80")
            dropped = "ip netns exec clat jool_siit -i clat stats display | grep JSTAT64_FRAGMENTED_ICMP"
            before = first_int(r"JSTAT64_FRAGMENTED_ICMP: (\d+)", client.succeed(dropped))
            shapes["clat: ping with 1300 bytes"] = works("ping -c1 -W2 -s 1300 198.51.100.80")
            assert first_int(r"JSTAT64_FRAGMENTED_ICMP: (\d+)", client.succeed(dropped)) > before
            lowest = gateway.machine.succeed("ip netns exec nat64 jool global display | grep lowest-ipv6-mtu").strip()
            assert lowest == "lowest-ipv6-mtu: 1280", lowest
            # A hop behind the translator with an MTU of 1400: its ICMP
            # "fragmentation needed" must cross the translator(s) as
            # "packet too big" for the sender to shrink its packets.
            gateway.machine.succeed("ip route replace 198.51.100.80/32 dev eth2 mtu 1400")
            try:
                client.succeed("ip -6 route flush cache; ip -4 route flush cache")
                shapes["nat64: TCP upload across a 1400 byte hop"] = works(upload(server))
                shapes["nat64: path MTU the client learned"] = learned(f"ip -6 route get {server}")
                shapes["nat64: don't-fragment ping above the path MTU fails"] = not works(f"ping -c1 -W2 -M do -s 1440 {server}")
                shapes["nat64: don't-fragment ping of 1420 bytes passes"] = works(f"ping -c1 -W2 -M do -s 1372 {server}")
                shapes["clat: TCP upload across a 1400 byte hop"] = works(upload("198.51.100.80"))
                shapes["clat: path MTU the client learned"] = learned("ip -4 route get 198.51.100.80")
                shapes["clat: don't-fragment ping above the path MTU fails"] = not works("ping -c1 -W2 -M do -s 1440 198.51.100.80")
                shapes["clat: don't-fragment ping of 1200 bytes passes"] = works("ping -c1 -W2 -M do -s 1172 198.51.100.80")
            finally:
                gateway.machine.succeed("ip route del 198.51.100.80/32 dev eth2")
                client.succeed("ip -6 route flush cache; ip -4 route flush cache")
            for shape, result in shapes.items():
                print(f"FINDING {shape}: {result}")
            expected = {shape: True for shape in shapes} | {
                "nat64: path MTU the client learned": 1420,
                "clat: path MTU the client learned": 1400,
                "clat: ping with 1300 bytes": False,
                "clat: ping with 1400 bytes": False,
                "clat: ping with 3000 bytes (fragments)": False,
            }
            wrong = {shape: result for shape, result in shapes.items() if result != expected[shape]}
            assert not wrong, wrong

        with subtest("nftables ownership: a restart of the firewall or of Jool leaves other tables alone"):
            tables = sorted(gw2.succeed("nft list tables").strip().split("\n"))
            print(f"FINDING nftables tables on a gateway: {tables}")
            # nat64: the gateway's allowlist. suite: this suite's counters.
            # nixos-fw and nixos-nat: the NixOS firewall and masquerade.
            # nftables.service applies all four, each as a table of its own.
            assert tables == ["table inet nat64", "table inet nixos-fw", "table inet suite", "table ip nixos-nat"], tables
            # Jool hooks into netfilter itself and owns no table
            assert gw2.succeed("ip netns exec nat64 nft list ruleset").strip() == ""
            # another owner's table, as Cilium or a router would add
            gw2.succeed("nft 'add table inet foreign; add chain inet foreign forward { type filter hook forward priority 10; }; add rule inet foreign forward ip6 daddr 2001:db8:ffff::/64 counter'")
            client.succeed(f"systemd-run --unit=stream-nft sh -c '/run/current-system/sw/bin/nc {G2.server} 9000 > /tmp/stream-nft'")
            client.wait_until_succeeds("test $(wc -l < /tmp/stream-nft) -ge 2", timeout=30)

            def grows():
                lines = int(client.succeed("wc -l < /tmp/stream-nft"))
                client.wait_until_succeeds(f"test $(wc -l < /tmp/stream-nft) -gt {lines + 1}", timeout=20)

            # with handles: a table that was deleted and added again differs
            foreign = gw2.succeed("nft -a -s list table inet foreign")
            list_owned = "nft -s list table inet nat64; nft -s list table inet nixos-fw; nft -s list table ip nixos-nat; nft -s list table inet suite"
            owned = gw2.succeed(list_owned)
            assert "nat64-undeclared" in owned and "nat64-private" in owned and "dns64-undeclared" in owned, owned
            gw2.succeed("systemctl restart nftables.service")
            assert gw2.succeed("nft -a -s list table inet foreign") == foreign
            assert gw2.succeed(list_owned) == owned
            assert sorted(gw2.succeed("nft list tables").strip().split("\n")) == sorted([*tables, "table inet foreign"])
            grows()
            everything = gw2.succeed("nft -a -s list ruleset")
            gw2.succeed("systemctl restart jool-netns.service")
            assert gw2.succeed("nft -a -s list ruleset") == everything
            assert gw2.succeed("ip netns exec nat64 nft list ruleset").strip() == ""
            # the instance and its sessions are still there
            grows()
            client.succeed("systemctl stop stream-nft.service")
            gw2.succeed("nft delete table inet foreign")
            assert_gateway(G2)

        with subtest("G2: an IfState apply keeps the namespaces, the Jool instances and the units"):
            assert_ifstate_noop(gw2)
            gw2.wait_for_unit("jool-netns.service", timeout=60)
            assert_gateway(G2)
            before = moves()
            gateway = clat_gateway()
            assert_ifstate_noop(client)
            client.wait_for_unit("clat.service", timeout=60)
            client.wait_for_unit("clat-follow.service", timeout=60)
            assert "clat" in client.succeed("ip netns exec clat jool_siit instance display")
            out = client.succeed(http("198.51.100.80")).strip()
            assert out == gateway.v4, out
            # the restarted follower keeps its gateway
            assert clat_gateway() is gateway and moves() == before
            print("GATEWAY_NAT64_IFSTATE_OK")

        first = clat_gateway()
        second = other(first)
        assert first is G1

        with subtest("G23 hysteresis: 40 s on a gateway with 30 % packet loss, the follower does not move"):
            client.succeed(f"systemd-run --unit=idle python3 /etc/suite/shapes.py idle {second.server} 9002 /tmp/idle-go /tmp/idle")
            client.wait_until_succeeds("grep open /tmp/idle >/dev/null", timeout=30)
            before = moves()
            first.machine.succeed("tc qdisc add dev eth1 root netem loss 30%")
            try:
                out = client.execute(f"ping -c 50 -i 0.1 -W1 {first.addr}")[1]
                loss = first_int(r"(\d+)% packet loss", out)
                print(f"FINDING measured loss towards the lossy gateway: {loss} %")
                assert loss >= 8, out
                holds_for(client, stays(first, before), 40, interval=2)
                observe("failed checks during the loss", client, "journalctl -b -u clat-follow -o cat --no-pager | grep -c 'check .* failed'; journalctl -b -u clat-follow -o cat --no-pager | grep 'check .* failed' | tail -n 5")
                # and the gateway still carries traffic
                client.wait_until_succeeds(http("198.51.100.80"), timeout=60)
            finally:
                first.machine.succeed("tc qdisc del dev eth1 root")

        with subtest("§12.1: a TCP flow that was idle for 40 s still passes the translator"):
            client.succeed("touch /tmp/idle-go")
            client.wait_until_succeeds("grep ok /tmp/idle >/dev/null", timeout=30)
            idle = int(client.succeed("cat /tmp/idle").split()[1])
            print(f"FINDING a TCP flow through NAT64 answered after {idle} s of silence")
            assert idle >= 40, idle
            timers = second.machine.succeed("ip netns exec nat64 jool global display | grep timeout; sysctl net.netfilter.nf_conntrack_tcp_timeout_established")
            print(f"FINDING what bounds an idle flow on a gateway:\n{timers}")
            assert "tcp-est-timeout: 2:00:00" in timers and "nf_conntrack_tcp_timeout_established = 432000" in timers, timers

        # The flow of G6: it sends a byte a second through `first`, so a
        # reset from anywhere would end it with an "error" line.
        def talk_stalled(count):
            return f"test \"$(grep -c echo /tmp/talk)\" -eq {count} && ! grep error /tmp/talk >/dev/null && systemctl is-active talk.service >/dev/null && ss -tn state established | grep ':9002' >/dev/null"

        with subtest("G6, G23: a gateway dies; a flow that is sending stalls for 20 s without a reset, new flows use the other one"):
            dead, live = first, second
            client.succeed(f"systemd-run --unit=talk python3 /etc/suite/shapes.py talk {dead.server} 9002 /tmp/talk")
            client.wait_until_succeeds("test \"$(grep -c echo /tmp/talk)\" -ge 3", timeout=30)
            # The resolver must be on the gateway that is about to die, or
            # the crash proves nothing about names.
            if resolver() != dead.addr:
                client.succeed(f"ip -6 route add unreachable {live.addr}/128")
                try:
                    client.wait_until_succeeds(f"resolvectl flush-caches; resolvectl query web.long.test >/dev/null 2>&1; resolvectl status | grep -F 'Current DNS Server: {dead.addr}' >/dev/null", timeout=30)
                finally:
                    client.succeed(f"ip -6 route del unreachable {live.addr}/128")
            client.succeed(http6("web.long.test") + " && " + http6("web.short.test"))
            assert resolver() == dead.addr, resolver()
            assert clat_gateway() is dead
            before = moves()
            dead.machine.crash()
            crashed = time.time()
            heard = echoes("/tmp/talk")
            # G4: the next nameserver, and with it the next /96
            took = seconds_until(client, http6("fresh.long.test"), limit=60, wanted=live.v4)
            print(f"FINDING a name that was not cached works through the live gateway after {took} s")
            assert took is not None and took < 30, took
            assert resolver() == live.addr
            # systemd-resolved flushed its cache when it changed server
            for name in ["web.short.test", "web.long.test"]:
                out = client.succeed(http6(name)).strip()
                assert out == live.v4, f"{name}: {out}"
            # G23: the follower moves the CLAT by itself
            took = seconds_until(client, http("198.51.100.80", limit=2), limit=90, wanted=live.v4)
            since = round(time.time() - crashed, 1)
            print(f"FINDING an IPv4 literal works through the live gateway {since} s after the crash")
            assert took is not None and since < 45, since
            assert clat_gateway() is live and moves() == before + 1
            # §12.2: an IPv4-only name (GitHub) with one gateway down
            size = client.succeed(http6("fresh.long.test", "big", 30) + " -o /dev/null -w '%{size_download}'").strip()
            assert size == "2000000", size
            # G6: nothing resets the flow through the dead gateway, though
            # the client keeps sending into it
            holds_for(client, talk_stalled(heard), 20)
            observe("the stalled flow", client, "ss -tni | grep -A1 ':9002'; tail -n 3 /tmp/talk")
            print("GATEWAY_NAT64_FAILOVER_OK")

        with subtest("G23: the follower restarts on a /96 that is not its first one and stays for 15 s"):
            before = moves()
            pid = follower_pid()
            client.succeed("systemctl restart clat-follow.service")
            client.wait_until_succeeds("journalctl -b -u clat-follow -o cat --no-pager | tail -n 2 | grep -F 'is named by ${builtins.elemAt nameservers 1}' >/dev/null", timeout=30)
            assert follower_pid() != pid
            # longer than the 12 s that a move takes
            holds_for(client, stays(second, before), 15, interval=2)
            out = client.succeed(http("198.51.100.80")).strip()
            assert out == second.v4, out

        with subtest("G23: the CLAT instance is created again with its first /96; the follower moves it to the live gateway"):
            before = moves()
            client.succeed("ip netns exec clat jool_siit instance remove clat")
            client.succeed("systemctl restart clat.service")
            created = time.time()
            # clat.service knows only the first gateway, and that one is dead
            assert clat_gateway() is first
            client.fail(http("198.51.100.80", limit=2))
            took = seconds_until(client, http("198.51.100.80", limit=2), limit=90, wanted=second.v4)
            since = round(time.time() - created, 1)
            print(f"FINDING the follower corrected a CLAT that came back on the dead gateway's /96 after {since} s")
            assert took is not None and since < 45, since
            assert clat_gateway() is second and moves() == before + 1
            client.wait_for_unit("clat-follow.service", timeout=30)

        with subtest("G2, G23: the gateway boots again and translates; the follower stays where it is for 10 s"):
            before = moves()
            first.machine.start()
            gateway_ready(first)
            # what does the gateway do with the old flow's packets?
            first.machine.succeed("nft 'add table inet probe; add chain inet probe forward { type filter hook forward priority -20; }; add rule inet probe forward oifname \"j0\" ip6 saddr ${clientAddr} tcp dport 9002 counter comment \"old-flow-in\"; add rule inet probe forward iifname \"j0\" ip daddr 198.51.100.80 tcp dport 9002 counter comment \"old-flow-translated\"'")
            assert_gateway(first)
            holds_for(client, stays(second, before), 10, interval=2)

        with subtest("G6: the gateway is back without state; the flow that kept sending is neither carried nor reset"):
            # TCP has backed off: the next retransmission can be 2 min away
            took = seconds_until(first.machine, "nft list chain inet probe forward | grep old-flow-in | grep -v 'packets 0 ' >/dev/null", limit=400, interval=2)
            print(f"FINDING the old flow's next packet reached the gateway {took} s after it was back")
            assert took is not None
            # time for an answer, if there were one
            holds_for(client, talk_stalled(heard), 10)
            probe = first.machine.succeed("nft list chain inet probe forward")
            translated = first_int(r'counter packets (\d+) bytes \d+ comment "old-flow-translated"', probe)
            print(f"FINDING the gateway without state saw the old flow:\n{probe}")
            observe("Jool's counters on the gateway", first.machine, "ip netns exec nat64 jool stats display | grep -v ': 0$'")
            observe("the flow on the client", client, "ss -tni | grep -A1 ':9002'; grep -c silent /tmp/talk")
            # Jool has no session for it and drops it; nobody tells the client
            assert translated == 0, probe
            client.succeed("systemctl stop talk.service")
            first.machine.succeed("nft delete table inet probe")

        with subtest("§12.2 health target: a gateway without IPv4 upstream closes its DNS64 and withdraws ipv4only.arpa; names and the CLAT move"):
            sick, healthy = second, first
            assert clat_gateway() is sick and resolver() == sick.addr
            # a name in the resolver's cache, through the gateway about to be sick
            client.succeed("resolvectl flush-caches")
            out = client.succeed(http6("web.long.test")).strip()
            assert out == sick.v4, out
            before = moves()
            sick.machine.succeed("tc qdisc add dev eth2 root netem loss 100%")
            cut = time.time()
            try:
                closed = seconds_until(client, dns_closed(sick), limit=60)
                print(f"FINDING the gateway closed its DNS64 {closed} s after its IPv4 upstream died")
                assert closed is not None and closed < 20, closed
                # it is alive on IPv6; UDP and TCP are refused, not dropped
                client.succeed(f"ping -c1 -W2 {sick.addr}")
                client.succeed(dns_closed(sick, "+tcp"))
                client.fail(names_prefix(sick))
                sick.machine.fail("systemctl is-active coredns.service")
                # The limit: nothing told the resolver yet, so a name it
                # cached through the sick gateway still points into the
                # dead /96, until its next query to that server.
                assert resolver() == sick.addr
                client.fail(http6("web.long.test", limit=2))
                # the first lookup that is not cached moves the resolver
                took = seconds_until(client, http6("sick.long.test", limit=2), limit=60, wanted=healthy.v4)
                since = round(time.time() - cut, 1)
                print(f"FINDING an IPv4-only name that was not cached works through the healthy gateway {took} s after the listener closed, {since} s after the upstream died")
                assert took is not None and took < 6 and since < 25, (took, since)
                assert resolver() == healthy.addr
                # and the resolver flushed: the cached name follows
                out = client.succeed(http6("web.long.test")).strip()
                assert out == healthy.v4, out
                took = seconds_until(client, http("198.51.100.80", limit=2), limit=90, wanted=healthy.v4)
                since = round(time.time() - cut, 1)
                print(f"FINDING an IPv4 literal works through the healthy gateway {since} s after the upstream died")
                assert took is not None and since < 60, since
                assert clat_gateway() is healthy and moves() == before + 1
            finally:
                sick.machine.succeed("tc qdisc del dev eth2 root")
            took = seconds_until(client, names_prefix(sick), limit=60)
            print(f"FINDING the gateway served ipv4only.arpa again {took} s after its upstream returned")
            assert took is not None and took < 20, took
            out = client.succeed(f"dig +short +time=2 +tries=1 AAAA six.long.test @{sick.addr}").strip()
            assert out == "2001:db8:c::66", out
            client.wait_until_succeeds(http6("fresh.long.test"), timeout=30)
            # the follower prefers its current gateway while that is healthy
            before = moves()
            holds_for(client, stays(healthy, before), 10, interval=2)

        with subtest("G23: the shared health target dies; both gateways close; the follower stays for 20 s and CLAT flows go on; the target returns"):
            current = clat_gateway()
            client.succeed("systemd-run --unit=talk-clat python3 /etc/suite/shapes.py talk 198.51.100.80 9002 /tmp/talk-clat")
            client.wait_until_succeeds("test \"$(grep -c echo /tmp/talk-clat)\" -ge 3", timeout=30)
            before = moves()
            pid = follower_pid()
            server4.succeed("ip addr del ${healthAddr}/32 dev eth1")
            try:
                for gateway in [G1, G2]:
                    took = seconds_until(client, dns_closed(gateway), limit=60)
                    print(f"FINDING {gateway.machine.name} closed its DNS64 {took} s after the health target died")
                    assert took is not None, gateway.machine.name
                heard_clat = echoes("/tmp/talk-clat")
                # longer than the 12 s that a move takes
                holds_for(client, stays(current, before) + " && ! grep error /tmp/talk-clat >/dev/null", 20, interval=2)
                grown = echoes("/tmp/talk-clat") - heard_clat
                print(f"FINDING the flow through the CLAT got {grown} echoes in 20 s with both gateways closed")
                assert grown >= 15, grown
                # both still translate, and the CLAT still works
                for gateway in [G1, G2]:
                    out = client.succeed(http(gateway.server)).strip()
                    assert out == gateway.v4, out
                out = client.succeed(http("198.51.100.80")).strip()
                assert out == current.v4, out
                # the follower waits; it did not crash or restart
                assert follower_pid() == pid
                client.succeed("journalctl -b -u clat-follow -o cat --no-pager | tail -n 1 | grep -F 'no nameserver answers ipv4only.arpa' >/dev/null")
                # The price of a health target that both gateways share:
                # no name resolves, though both gateways translate.
                client.fail(http6("back.long.test", limit=3))
            finally:
                server4.succeed("ip addr add ${healthAddr}/32 dev eth1")
            for gateway in [G1, G2]:
                took = seconds_until(client, names_prefix(gateway), limit=60)
                print(f"FINDING {gateway.machine.name} served ipv4only.arpa again {took} s after the health target returned")
                assert took is not None and took < 20, took
            holds_for(client, stays(current, before) + " && ! grep error /tmp/talk-clat >/dev/null", 10, interval=2)
            assert follower_pid() == pid
            out = client.wait_until_succeeds(http6("back.long.test"), timeout=30).strip()
            assert out in (G1.v4, G2.v4), out
            client.succeed("systemctl stop talk-clat.service")

        with subtest("health check fail-safe: CoreDNS keeps a hosts file that disappeared, so the listener stops with the health check"):
            gateway = other(clat_gateway())
            machine = gateway.machine
            # The upstream fact, on a CoreDNS of its own: `hosts` follows a
            # changed file within its reload time, and keeps the records
            # of a deleted one.
            ask = "dig +short +time=1 +tries=1 -p 5399 @127.0.0.1 stale.test"
            machine.succeed("mkdir -p /tmp/stale && printf '192.0.2.7 stale.test\\n' >/tmp/stale/hosts && printf '.:5399 {\\n  bind 127.0.0.1\\n  hosts /tmp/stale/hosts {\\n    reload 1s\\n  }\\n}\\n' >/tmp/stale/Corefile")
            machine.succeed("systemd-run --unit=stale-coredns /run/current-system/sw/bin/coredns -conf /tmp/stale/Corefile")
            machine.wait_until_succeeds(f"{ask} | grep -Fx 192.0.2.7 >/dev/null", timeout=30)
            machine.succeed("printf '192.0.2.8 stale.test\\n' >/tmp/stale/hosts")
            machine.wait_until_succeeds(f"{ask} | grep -Fx 192.0.2.8 >/dev/null", timeout=30)
            machine.succeed("rm /tmp/stale/hosts")
            holds_for(machine, f"{ask} | grep -Fx 192.0.2.8 >/dev/null", 10)
            machine.succeed("systemctl stop stale-coredns.service")
            # so: the health check stops, and the listener with it
            machine.succeed("systemctl stop nat64-health.service")
            took = seconds_until(client, dns_closed(gateway), limit=30)
            print(f"FINDING {machine.name} closed its DNS64 {took} s after its health check was stopped")
            assert took is not None and took < 5, took
            machine.fail("systemctl is-active coredns.service")
            machine.fail("test -e /run/nat64-health/ipv4only.hosts")
            holds_for(client, dns_closed(gateway) + " && ! " + names_prefix(gateway), 5)
            machine.succeed("systemctl start nat64-health.service")
            took = seconds_until(client, names_prefix(gateway), limit=60)
            print(f"FINDING {machine.name} served ipv4only.arpa again {took} s after its health check was started")
            assert took is not None and took < 20, took
            # the health check is killed: systemd starts it again, and the
            # gateway serves again
            pid = machine.succeed("systemctl show -p MainPID --value nat64-health.service").strip()
            started = machine.succeed("systemctl show -p ActiveEnterTimestampMonotonic --value coredns.service").strip()
            machine.succeed("systemctl kill -s KILL --kill-whom=main nat64-health.service")
            machine.wait_until_succeeds(f"pid=$(systemctl show -p MainPID --value nat64-health.service); test \"$pid\" -gt 0 && test \"$pid\" -ne {pid}", timeout=30)
            took = seconds_until(client, names_prefix(gateway), limit=60)
            again = machine.succeed("systemctl show -p ActiveEnterTimestampMonotonic --value coredns.service").strip()
            print(f"FINDING {machine.name} served ipv4only.arpa {took} s after its health check was killed; CoreDNS was restarted with it: {again != started}")
            assert took is not None and took < 20, took
            machine.succeed("systemctl is-active coredns.service nat64-health.service >/dev/null")

        with subtest("the end state: both gateways pass every assertion again"):
            for gateway in [G1, G2]:
                assert_gateway(gateway)
            observe("the follower's log", client, "journalctl -b -u clat-follow -o cat --no-pager | grep -v 'check .* failed'")

    print("GATEWAY_NAT64_OK")
  '';
}
