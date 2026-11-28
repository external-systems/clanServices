# nat-gateway: the service on two gateways and two clients
# (specs/gateway.md G2–G6, G23, G24, §14.1, §14.3, §14.5). Ported from
# the removed fixture suite gateway-nat64: the same proofs on the code a
# machine runs, without DNS64 (removed, §14.5 point 1), with the
# decisions of round G5 (the rate limit per source in two tiers, several
# health targets per gateway) and of round G8 (stability over fast
# failover, a client's own limit). Timing bounds are the defaults:
# withdrawn after 30 s, back after 120 s, a client moves after 60 s.
#
#   client  ─┐                      ┌─ gw1 ─┐
#   trusted ─┤                      │       │
#   capped  ─┼─ vlan 1, IPv6 only ──┤       ├─ vlan 2, IPv4 only ── server4
#   outsider─┘   2001:db8:c::/64    └─ gw2 ─┘    198.51.100.0/24
#
# netif renders every machine's links. `client` is a `default`-tier
# client, `trusted` a `trusted`-tier one, `capped` a client with a packet
# limit of its own, `outsider` is no client. gw2 has low `default`
# limits so the suite can cross them.
#
# Two suites share this file (the topology and the helpers):
#   nat-gateway           `phases = "function"`: the translator, the
#                         allowlist, the limits, reconciliation;
#   nat-gateway-failover  `phases = "failover"`: loss, flaps, dead
#                         targets and gateways, restarts and reboots.
#   nat-gateway-hostile   `phases = "hostile"`: hostile actors (an
#                         undeclared host, a declared client, the IPv4
#                         side) against the translator and the CLAT.
#                         Every attack is one `verdict`; the suite
#                         fails at the end when any is a gap.
{phases}: {lib, ...}: let
  pool1 = "2001:db8:a1:0:64::/96";
  # Printed with `::` in the middle of every address inside it: the
  # follower must not cut the /96 out of an answer as a string.
  pool2 = "2001:db8:a2::/96";
  # 198.51.100.80 inside each pool
  server1 = "2001:db8:a1:0:64:0:c633:6450";
  server2 = "2001:db8:a2::c633:6450";
  clientAddr = "2001:db8:c::10";
  clatAddr = "2001:db8:c::c1a7";
  trustedAddr = "2001:db8:c::20";
  trustedClat = "2001:db8:c::c1a8";
  outsiderAddr = "2001:db8:c::66";
  cappedAddr = "2001:db8:c::30";
  cappedClat = "2001:db8:c::c1a9";
  # Three health targets per gateway, each its own /32 on server4, so
  # one can die while the server stays (§14.3).
  targets = {
    gw1 = ["198.51.100.90" "198.51.100.91" "198.51.100.92"];
    gw2 = ["198.51.100.93" "198.51.100.94" "198.51.100.95"];
  };
  # gw2's `default` tier, low enough to cross in a test
  lowLimits = {
    newFlows = 5;
    newFlowsBurst = 10;
    packets = 500;
    packetsBurst = 1000;
  };
  # the defaults of lib/gateway (specs/gateway.md §14.5 point 4)
  down = 30;
  up = 120;
  followAfter = 60;

  # Both gateways' prefixes are routed to the gateway, as a provider
  # routes a machine's /64.
  poolRoutes = [
    {
      destination = "2001:db8:a1::/64";
      gateway = "2001:db8:c::1";
    }
    {
      destination = "2001:db8:a2::/64";
      gateway = "2001:db8:c::2";
    }
  ];
  v6link = address: {
    interface = "eth1";
    zone = "wan";
    static.ipv6 = ["${address}/64"];
    routes = poolRoutes;
    ra = false;
  };
  gatewayLinks = n: {
    inside = {
      interface = "eth1";
      zone = "inside";
      static.ipv6 = ["2001:db8:c::${n}/64"];
      ra = false;
    };
    # the public IPv4, and an IPv4 default route as a real gateway has:
    # without one the kernel drops a private destination before the
    # firewall sees it
    wan = {
      interface = "eth2";
      zone = "wan";
      static.ipv4 = ["198.51.100.${n}/24"];
      gateway.ipv4 = "198.51.100.80";
      ra = false;
    };
  };

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
          sock.listen(512)
          while True:
              conn, _ = sock.accept()
              threading.Thread(target=serve, args=(conn,), daemon=True).start()


      def udp_echo():
          sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
          sock.bind(("0.0.0.0", 9001))
          while True:
              data, peer = sock.recvfrom(65535)
              sock.sendto(data, peer)


      threading.Thread(target=listen, args=(9002, echo), daemon=True).start()
      threading.Thread(target=udp_echo, daemon=True).start()
      http.server.ThreadingHTTPServer(("0.0.0.0", 80), Handler).serve_forever()
    '';

  # Client side of the traffic shapes.
  shapes = ''
    import os
    import socket
    import sys
    import time

    mode, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    if mode == "udp":
        sock = socket.socket(family, socket.SOCK_DGRAM)
        sock.settimeout(3)
        data = os.urandom(int(sys.argv[4]))
        sock.sendto(data, (host, port))
        reply, _ = sock.recvfrom(65535)
        sys.exit(0 if reply == data else 1)
    # `burst HOST PORT N`: open N connections at once; print how many
    # were answered within 3 s
    if mode == "burst":
        count = int(sys.argv[4])
        socks = []
        for _ in range(count):
            sock = socket.socket(family, socket.SOCK_STREAM)
            sock.setblocking(False)
            sock.connect_ex((host, port))
            socks.append(sock)
        time.sleep(3)
        done = 0
        for sock in socks:
            try:
                sock.send(b"x")
                done += 1
            except OSError:
                pass
            sock.close()
        print(done)
    # `flood HOST PORT RATE SECONDS`: datagrams at RATE a second, paced in
    # batches every 10 ms (a burst at full speed overruns the sender's
    # own queue); prints how many were sent
    if mode == "flood":
        sock = socket.socket(family, socket.SOCK_DGRAM)
        rate, seconds = int(sys.argv[4]), float(sys.argv[5])
        sent = 0
        started = time.monotonic()
        while time.monotonic() - started < seconds:
            due = int((time.monotonic() - started) * rate)
            while sent < due:
                try:
                    sock.sendto(b"x" * 64, (host, port))
                    sent += 1
                except BlockingIOError:
                    break
            time.sleep(0.01)
        print(sent)
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
          ip6 daddr 2001:db8:a1:0:65::/96 counter comment "${name} v6 to host pool6"
          ip daddr 198.51.100.80 counter comment "${name} v4 to server"
        }
      '')
      hooks
    );
  };

  vm = {pkgs, ...}: {
    virtualisation = {
      cores = 1;
      memorySize = 1024;
    };
    environment = {
      systemPackages =
        [
          pkgs.curl
          pkgs.dig
          pkgs.netcat
          pkgs.tcpdump
          (
            if phases == "hostile"
            then pkgs.python3.withPackages (ps: [ps.scapy])
            else pkgs.python3
          )
          pkgs.conntrack-tools
        ]
        # the other two suites' machines stay as they are
        ++ lib.optional (phases == "hostile") pkgs.nmap;
      etc."suite/shapes.py".text = shapes;
    };
  };
  v6host = {
    imports = [vm];
    virtualisation.vlans = [1];
  };
  gateway = pool: {
    imports = [vm];
    virtualisation.vlans = [1 2];
    networking.nftables.tables.suite = hooksTable pool;
  };
in {
  name =
    if phases == "function"
    then "nat-gateway"
    else "nat-gateway-${phases}";

  clan = {
    directory = ./.;
    test.useContainers = false;
    inventory = {
      machines = lib.genAttrs ["client" "trusted" "capped" "outsider" "gw1" "gw2" "server4"] (_: {});
      instances = {
        links = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines = {
            client.settings.links.wan = v6link clientAddr;
            trusted.settings.links.wan = v6link trustedAddr;
            capped.settings.links.wan = v6link cappedAddr;
            outsider.settings.links.wan = v6link outsiderAddr;
            gw1.settings.links = gatewayLinks "1";
            gw2.settings.links = gatewayLinks "2";
            # the health targets are /32s: deleting one leaves the /24
            server4.settings.links.wan = {
              interface = "eth1";
              zone = "wan";
              static.ipv4 = ["198.51.100.80/24"] ++ map (address: "${address}/32") (targets.gw1 ++ targets.gw2);
              ra = false;
            };
          };
        };
        nat64 = {
          module.name = "nat-gateway";
          module.input = "self";
          roles = {
            gateway.machines = {
              gw1.settings = {
                pool6 = pool1;
                address = "2001:db8:c::1";
                health.targets = targets.gw1;
              };
              gw2.settings = {
                pool6 = pool2;
                address = "2001:db8:c::2";
                health.targets = targets.gw2;
                limits.default = lowLimits;
              };
            };
            client.machines = {
              client.settings.clat.address = clatAddr;
              # §14.5 point 3: a packet limit of its own on every
              # gateway; its other numbers are its tier's
              capped.settings = {
                clat.address = cappedClat;
                limits = {
                  packets = 500;
                  packetsBurst = 1000;
                };
              };
              trusted.settings = {
                clat.address = trustedClat;
                tier = "trusted";
              };
            };
          };
        };
      };
    };
  };

  nodes = {
    client = v6host;
    trusted = v6host;
    capped = v6host;
    outsider = v6host;
    gw1 = gateway pool1;
    gw2 = gateway pool2;
    server4 = {pkgs, ...}: {
      imports = [vm];
      virtualisation.vlans = [2];
      networking.firewall.enable = false;
      systemd.services.server4 = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${httpServer pkgs}";
      };
    };
  };

  testScript = {nodes, ...}: let
    followScript = "${nodes.client.systemd.services.clat-follow.serviceConfig.ExecStart}";
  in ''
    import ipaddress
    import json
    import re
    import time

    ${import ../../../../tests/suite-lib.nix}
    ${import ../../../../tests/ifstate-noop.nix}

    def embed(gateway, ipv4):
        return str(ipaddress.IPv6Address(int(gateway.pool.network_address) | int(ipaddress.IPv4Address(ipv4))))


    class Gateway:
        def __init__(self, machine, addr, pool, v4, targets):
            self.machine, self.addr, self.v4, self.targets = machine, addr, v4, targets
            self.pool = ipaddress.IPv6Network(pool)
            self.server = embed(self, "198.51.100.80")
            # RFC 7050: what `ipv4only.arpa` must answer
            self.named = sorted(embed(self, known) for known in ["192.0.0.170", "192.0.0.171"])


    G1 = Gateway(gw1, "2001:db8:c::1", "${pool1}", "198.51.100.1", ${builtins.toJSON targets.gw1})
    G2 = Gateway(gw2, "2001:db8:c::2", "${pool2}", "198.51.100.2", ${builtins.toJSON targets.gw2})
    assert (G1.server, G2.server) == ("${server1}", "${server2}")
    SERVER_HOST = "2001:db8:a1:0:65:0:c633:6450"
    PRIVATE = ["10.0.0.1", "100.64.0.1", "169.254.0.1", "172.16.0.1", "192.168.1.1"]
    # specs/gateway.md §14.5 point 4: withdrawn when DOWN of the last
    # 2 x DOWN rounds are bad, back when the last UP rounds are clean, a
    # client moves after FOLLOW_AFTER s without its beacon
    DOWN = ${toString down}
    UP = ${toString up}
    FOLLOW_AFTER = ${toString followAfter}
    FOLLOW = "${followScript}".split()
    FOLLOW_MOVES = "journalctl -b -u clat-follow -o cat --no-pager | grep -c 'clat-follow: pool6 ->'"


    def first_int(pattern, text):
        found = re.search(pattern, text)
        assert found is not None, f"{pattern} not in {text}"
        return int(found.group(1))


    def other(gateway):
        return G2 if gateway is G1 else G1


    def http(target, path="", limit=5):
        host = f"[{target}]" if ":" in target else target
        return f"curl -sg --max-time {limit} 'http://{host}/{path}'"


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


    def counted(machine, comment, table="nat64"):
        """Packets that a rule of the machine's own table counted. The rule
        is found by its comment, whichever chain holds it."""
        rule = machine.succeed(f"nft list table inet {table} | grep -F 'comment \"{comment}\"'")
        return first_int(r"counter packets (\d+)", rule)


    def refused_private(machine):
        return counted(machine, "nat64-private")


    def guard(machine, netns):
        """The default-deny table inside a translator's namespace: its
        counters by comment. It must hold both chains."""
        shown = machine.succeed(f"ip netns exec {netns} nft list table inet guard")
        assert "hook prerouting priority filter; policy drop;" in shown and "hook postrouting priority filter; policy drop;" in shown, shown
        return {name: int(packets) for packets, name in re.findall(r'counter packets (\d+) bytes \d+ (?:drop )?comment "(guard-[a-z-]+)"', shown)}


    def guard_quiet(machine, netns, when):
        """Nothing legitimate ever meets the guard: after real traffic its
        two counters are 0 (specs/design-gateway.md R1)."""
        dropped = guard(machine, netns)
        print(f"FINDING P6 {machine.name} {netns} guard counters {when}: {dropped}")
        assert dropped["guard-leftover"] == 0 and dropped["guard-leaving"] == 0, f"{machine.name}: the {netns} guard dropped packets {when}: {dropped}\n" + machine.succeed(f"ip netns exec {netns} nft list table inet guard")
        return dropped


    def names_prefix(gateway):
        return f"dig +short +time=1 +tries=1 AAAA ipv4only.arpa @{gateway.addr} | grep -Fx '{gateway.named[0]}' >/dev/null"


    def beacon_closed(gateway, flags=""):
        """The beacon answers a query with an error at once, not with
        silence. dig exits 9 then, and the driver's shell runs with
        pipefail."""
        return f"(dig {flags} +time=2 +tries=1 AAAA ipv4only.arpa @{gateway.addr} 2>&1 || true) | grep -i 'connection refused' >/dev/null"


    def clat_gateway(machine=client):
        shown = machine.succeed("ip netns exec clat jool_siit -i clat global display | grep pool6")
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


    def ruleset(machine, table=None, handles=True, netns=None):
        """The ruleset with handles, without the rate limit's dynamic sets:
        their elements come and go with the clients' flows."""
        flags = "-j -a" if handles else "-j"
        nft = "nft" if netns is None else f"ip netns exec {netns} nft"
        listed = json.loads(machine.succeed(f"{nft} {flags} list ruleset" if table is None else f"{nft} {flags} list table inet {table}"))["nftables"]
        dynamic = lambda item: "set" in item and item["set"]["name"].startswith(("flows_", "packets_"))
        kept = [item for item in listed if not dynamic(item) and "metainfo" not in item]

        def normal(value):
            # counters change with traffic; handles only matter when asked
            if isinstance(value, dict):
                if "counter" in value and isinstance(value["counter"], dict):
                    return {"counter": "COUNTER"}
                return {key: normal(item) for key, item in value.items() if handles or key != "handle"}
            if isinstance(value, list):
                return [normal(item) for item in value]
            return value

        return json.dumps(normal(kept), sort_keys=True)


    def echoes(log):
        return int(client.succeed(f"grep -c echo {log} || true").strip())


    def pool4_state(machine):
        """What the health check last read of pool4 (round G11, G4)."""
        return json.loads(machine.succeed("cat /run/nat64-gateway/health.json")).get("pool4") or {}


    def gateway_ready(gateway):
        machine = gateway.machine
        machine.wait_for_unit("multi-user.target", timeout=300)
        for unit in ["nat64-jool.service", "nat64-health.service", "nftables.service"]:
            machine.wait_for_unit(unit, timeout=60)
        client.wait_until_succeeds(f"ping -c1 -W2 {gateway.addr}", timeout=60)
        # the health check has answered through the translator for UP
        # rounds: only then does it start the beacon
        machine.wait_until_succeeds("systemctl is-active nat64-beacon.service >/dev/null", timeout=UP + 180)
        client.wait_until_succeeds(names_prefix(gateway), timeout=60)


    def assert_gateway(gateway):
        """What one gateway must do, whatever happened to it before."""
        machine, server = gateway.machine, gateway.server
        # G2: the Jool instance and its pool4 live in the namespace only
        machine.succeed(f"ip netns exec nat64 jool -i default global display | grep -F 'pool6: {gateway.pool}' >/dev/null")
        machine.fail("jool -i default global display")
        for proto in ["tcp", "udp", "icmp"]:
            pool4 = machine.succeed(f"ip netns exec nat64 jool pool4 display --{proto} --csv")
            assert pool4.count("192.0.0.2,1100,65535") == 1, pool4
        # a declared source is translated, behind the gateway's own IPv4:
        # TCP, ICMP and UDP, from both tiers
        for source in [client, trusted]:
            out = source.succeed(http(server)).strip()
            assert out == gateway.v4, out
            source.succeed(f"ping -c2 -W2 {server}")
            source.succeed(udp(server))
        # G24: the beacon names the /96 and answers nothing else
        answer = sorted(client.succeed(f"dig @{gateway.addr} ipv4only.arpa AAAA +short").split())
        assert answer == gateway.named, answer
        for flags in ["", "+tcp"]:
            status = client.succeed(f"dig {flags} +time=2 +tries=1 AAAA example.org @{gateway.addr} | grep -o 'status: [A-Z]*'").strip()
            assert status == "status: REFUSED", f"{flags}: {status}"
        # G2: an undeclared source reaches the gateway, but not the
        # translator, with any protocol. Every packet is counted.
        outsider.succeed(f"ping -c1 -W2 {gateway.addr}")
        dropped = {}
        for shape, cmd in [("ping", f"ping -c2 -W1 {server}"), ("tcp", http(server, limit=3)), ("udp", udp(server))]:
            before = counted(machine, "nat64-undeclared")
            outsider.fail(cmd)
            dropped[shape] = counted(machine, "nat64-undeclared") - before
        # G24: nor the beacon
        for shape, flags in [("beacon udp", ""), ("beacon tcp", "+tcp")]:
            before = counted(machine, "beacon-undeclared")
            outsider.fail(f"dig {flags} +short +time=2 +tries=1 AAAA ipv4only.arpa @{gateway.addr}")
            dropped[shape] = counted(machine, "beacon-undeclared") - before
        print(f"FINDING {machine.name} dropped from the undeclared source: {dropped}")
        # two echo requests, one datagram, one query; TCP repeats its SYN
        assert dropped["ping"] == 2 and dropped["udp"] == 1 and dropped["beacon udp"] == 1, dropped
        assert 1 <= dropped["tcp"] <= 6 and 1 <= dropped["beacon tcp"] <= 6, dropped
        # G5: a private IPv4 destination is refused, before the
        # translator: loopback, Jool's own link and pool4 address too.
        # The client is told at once (ICMPv6, not a timeout).
        for private in PRIVATE + ["127.0.0.1", "192.0.0.1", "192.0.0.2"]:
            before = refused_private(machine)
            client.fail(f"ping -c1 -W2 {embed(gateway, private)}")
            assert refused_private(machine) == before + 1, f"{machine.name} did not refuse {private}"
        status, _ = client.execute(http(embed(gateway, "10.0.0.1"), limit=5))
        assert status == 7, f"{machine.name}: curl to a private destination ended with {status}, not with a refusal at once (7)"
        # nothing private ever came out of the translator
        assert counted(machine, "nat64-private-post") == 0
        # The translator is no way into the gateway's own IPv4 ports: a
        # /96 destination that embeds the public address is translated,
        # delivered to the gateway, and refused there
        before = counted(machine, "nat64-host")
        client.fail(http(embed(gateway, gateway.v4), limit=3))
        assert counted(machine, "nat64-host") > before, f"{machine.name} let {gateway.v4} in through its translator"
        # the namespace is default deny: the guard is loaded, and no
        # packet was dropped on its way out
        assert guard(machine, "nat64")["guard-leaving"] == 0
        assert json.loads(machine.succeed("cat /run/nat64-gateway/health.json"))["guard"] is True
        # the gateway's own IPv4 traffic does not pass the translator
        out = machine.succeed(http("198.51.100.80")).strip()
        assert out == gateway.v4, out


    def function_phases():
        """The translator, the allowlist, the limits: nothing here waits for a failover."""
        with subtest("G2, G5, G24: each gateway translates declared sources only, every protocol"):
            for gateway in [G1, G2]:
                assert_gateway(gateway)
                size = client.succeed(http(gateway.server, "big", 30) + " -o /dev/null -w '%{size_download}'").strip()
                assert size == "2000000", size
            observe("gw2's own table", gw2, "nft list table inet nat64")
            observe("gw2's namespace guard", gw2, "ip netns exec nat64 nft list table inet guard")
            observe("the client's own table", client, "nft list table inet clat")
            for gateway in [G1, G2]:
                guard_quiet(gateway.machine, "nat64", "after every protocol from both tiers and a 2 MB download")
            print("NAT_GATEWAY_BASIC_OK")

        with subtest("G2: the forward chain and conntrack see a namespaced Jool"):
            counters = ["pre_filter v6 to pool6", "forward v6 to pool6", "post v6 to pool6", "forward v4 to server", "post v4 to server"]
            bytes_before = {comment: hook(gw1, comment, "bytes") for comment in counters}
            before_input = hook(gw1, "input v6 to pool6")
            # one upload of 300 kB from the client: every hook must count it
            client.succeed(upload(G1.server))
            for comment in counters:
                grown = hook(gw1, comment, "bytes") - bytes_before[comment]
                print(f"FINDING gw1 hook counter '{comment}': {grown} bytes for an upload of 300000")
                assert grown >= 300000, f"{comment}: {grown}"
            # the translator is another machine to the host: nothing is input
            assert hook(gw1, "input v6 to pool6") == before_input == 0
            gw1.succeed("conntrack -L -p tcp 2>/dev/null | grep 'dst=198.51.100.80' | grep 'src=192.0.0.2' >/dev/null")

        with subtest("G2: Jool's pool4 cannot overlap the namespace's ephemeral ports"):
            status, out = gw1.execute("ip netns exec nat64 jool pool4 add 192.0.0.2 1024-65535 --tcp 2>&1")
            print(f"FINDING pool4 add 1024-65535: rc={status}\n{out.rstrip()}")
            assert status != 0 and "ephemeral" in out, out
            out = gw1.succeed("ip netns exec nat64 sysctl -n net.ipv4.ip_local_port_range").split()
            assert out == ["1024", "1099"], out
            # P2: Jool needs no forwarding in its namespace; it is off
            for machine, netns in [(gw1, "nat64"), (gw2, "nat64"), (client, "clat")]:
                out = machine.succeed(f"ip netns exec {netns} sysctl -n net.ipv4.conf.all.forwarding net.ipv6.conf.all.forwarding").split()
                assert out == ["0", "0"], f"{machine.name}: {out}"

        with subtest("G2 negative proof: Jool in the host namespace bypasses the forward chain"):
            gw1.succeed("jool instance add hostns --netfilter --pool6 2001:db8:a1:0:65::/96")
            try:
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
            # the allowlist goes, the masquerade of the same table stays
            gw1.succeed("nft flush chain inet nat64 to_translator")
            try:
                # the allowlist alone is gone: the translator's answers to
                # a source that is not declared are still refused
                before = counted(gw1, "nat64-return-undeclared")
                outsider.fail(f"ping -c2 -W1 {G1.server}")
                assert counted(gw1, "nat64-return-undeclared") == before + 2
                gw1.succeed("nft flush chain inet nat64 from_translator")
                outsider.succeed(f"ping -c2 -W2 {G1.server}")
            finally:
                gw1.succeed("systemctl restart nftables.service")
            before = counted(gw1, "nat64-undeclared")
            outsider.fail(f"ping -c2 -W1 {G1.server}")
            assert counted(gw1, "nat64-undeclared") == before + 2
            client.succeed(f"ping -c2 -W2 {G1.server}")

        with subtest("G23: the follower derives the /96 by address arithmetic and refuses what is not one"):
            parse = f"{FOLLOW[0]} {FOLLOW[2]} prefix"
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
            assert moves() == 0

        with subtest("G23: the CLAT carries IPv4 literals from an IPv6-only host, on both clients"):
            for machine in [client, trusted]:
                gateway = clat_gateway(machine)
                assert gateway is G1
                assert "default via 192.0.0.2 dev clat0 mtu 1480" in machine.succeed("ip -4 route show default")
                out = machine.succeed(http("198.51.100.80")).strip()
                assert out == gateway.v4, out
                machine.succeed("ping -c2 -W2 198.51.100.80")
            assert "${clatAddr}/128" in client.succeed("ip netns exec clat jool_siit -i clat eamt display --csv")
            # proxy NDP answers for the CLAT address on the uplink
            assert "${clatAddr}" in client.succeed("ip -6 neigh show proxy dev eth1")
            size = client.succeed(http("198.51.100.80", "big", 30) + " -o /dev/null -w '%{size_download}'").strip()
            assert size == "2000000", size
            observe("client addresses and routes", client, "ip -br addr; ip -4 route; ip -6 route; ip netns exec clat ip -4 route; ip netns exec clat ip -6 route")
            for machine in [client, trusted]:
                guard_quiet(machine, "clat", "after pages, pings and a 2 MB download through the CLAT")
            guard_quiet(G1.machine, "nat64", "after the CLAT clients' traffic")

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
            # G23's known limit: Jool SIIT drops fragmented ICMP
            shapes["clat: ping with 1200 bytes"] = works("ping -c2 -W2 -s 1200 198.51.100.80")
            shapes["clat: ping with 1300 bytes"] = works("ping -c1 -W2 -s 1300 198.51.100.80")
            gateway.machine.succeed("ip route replace 198.51.100.80/32 dev eth2 mtu 1400")
            try:
                client.succeed("ip -6 route flush cache; ip -4 route flush cache")
                shapes["nat64: TCP upload across a 1400 byte hop"] = works(upload(server))
                shapes["nat64: path MTU the client learned"] = learned(f"ip -6 route get {server}")
                shapes["clat: TCP upload across a 1400 byte hop"] = works(upload("198.51.100.80"))
                shapes["clat: path MTU the client learned"] = learned("ip -4 route get 198.51.100.80")
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
            # P6: fragments, path MTU discovery and Jool's own ICMP errors
            # pass the guard's two chains; nothing of them is dropped there
            print(f"FINDING P6 {gateway.machine.name} guard after fragments and path MTU discovery: {guard(gateway.machine, 'nat64')}; Jool's own ICMPv6 errors forwarded: {counted(gateway.machine, 'nat64-jool-error')}")
            print(f"FINDING P6 client CLAT guard after fragments and path MTU discovery: {guard(client, 'clat')}")
            assert guard(gateway.machine, "nat64")["guard-leaving"] == 0
            assert guard(client, "clat")["guard-leaving"] == 0

        with subtest("§14.1 point 4: a rate limit per source, two tiers"):
            # gw2's `default` tier: 5 new flows a second, a burst of 10.
            # The client opens 40 at once and loses most; the trusted
            # client does the same and loses none.
            before = counted(gw2, "nat64-flows-default")
            got = int(client.succeed(f"python3 /etc/suite/shapes.py burst {G2.server} 9002 40").strip())
            dropped = counted(gw2, "nat64-flows-default") - before
            print(f"FINDING default tier: {got} of 40 connections at once answered, {dropped} SYNs dropped")
            # dropped SYNs are sent again after 1 s and 3 s, and the limit
            # lets 5 a second through: about 25 of 40 get through in 3 s
            assert got <= 32 and dropped >= 10, (got, dropped)
            before = counted(gw2, "nat64-flows-trusted")
            got = int(trusted.succeed(f"python3 /etc/suite/shapes.py burst {G2.server} 9002 40").strip())
            assert got == 40 and counted(gw2, "nat64-flows-trusted") == before, got
            # packets: 2000 datagrams a second for 3 s, against a burst of
            # 1000 and 500 a second: about 3500 of 6000 must go
            before = counted(gw2, "nat64-packets-default")
            sent = int(client.succeed(f"python3 /etc/suite/shapes.py flood {G2.server} 9001 2000 3").strip())
            dropped = counted(gw2, "nat64-packets-default") - before
            print(f"FINDING default tier: {dropped} of {sent} datagrams dropped (2000/s for 3 s against 500/s, burst 1000)")
            assert sent >= 5000 and dropped >= 1500, (sent, dropped)
            before = counted(gw2, "nat64-packets-trusted")
            sent = int(trusted.succeed(f"python3 /etc/suite/shapes.py flood {G2.server} 9001 2000 3").strip())
            assert sent >= 5000 and counted(gw2, "nat64-packets-trusted") == before, sent
            # a minute of quiet later nothing is held against the client
            client.wait_until_succeeds(http(G2.server), timeout=30)
            # gw1 keeps the default limits: the same burst passes there
            got = int(client.succeed(f"python3 /etc/suite/shapes.py burst {G1.server} 9002 40").strip())
            assert got == 40, got
            # §14.5 point 3: `capped` has a packet limit of its own (500 a
            # second, burst 1000) on gw1, where the tiers would let the
            # flood pass; its own meters count it, the tiers' do not
            before = {name: counted(gw1, name) for name in ["nat64-packets-client-capped", "nat64-packets-default", "nat64-packets-trusted"]}
            sent = int(capped.succeed(f"python3 /etc/suite/shapes.py flood {G1.server} 9001 2000 3").strip())
            grown = {name: counted(gw1, name) - value for name, value in before.items()}
            print(f"FINDING capped client: {grown} of {sent} datagrams dropped (2000/s for 3 s against its own 500/s, burst 1000)")
            assert sent >= 5000 and grown["nat64-packets-client-capped"] >= 1500, (sent, grown)
            assert grown["nat64-packets-default"] == grown["nat64-packets-trusted"] == 0, grown
            # its new flows keep the tier's numbers: a burst of 40 passes
            got = int(capped.succeed(f"python3 /etc/suite/shapes.py burst {G1.server} 9002 40").strip())
            assert got == 40, got
            for gateway in [G1, G2]:
                guard_quiet(gateway.machine, "nat64", "after the rate limit floods")
            print("NAT_GATEWAY_LIMITS_OK")

        with subtest("nftables ownership: a restart of the firewall or of Jool leaves other tables alone"):
            tables = sorted(gw2.succeed("nft list tables").strip().split("\n"))
            print(f"FINDING nftables tables on a gateway: {tables}")
            assert "table inet nat64" in tables, tables
            # the namespace holds the guard and nothing else
            assert gw2.succeed("ip netns exec nat64 nft list tables").strip() == "table inet guard"
            guarded = ruleset(gw2, "guard", handles=False, netns="nat64")
            # a flow that is open across every restart below goes on
            trusted.succeed(f"rm -f /tmp/talk-own; systemd-run --unit=talk-own python3 /etc/suite/shapes.py talk {G2.server} 9002 /tmp/talk-own")
            trusted.wait_until_succeeds("test \"$(grep -c echo /tmp/talk-own)\" -ge 2", timeout=30)
            gw2.succeed("nft 'add table inet foreign; add chain inet foreign forward { type filter hook forward priority 10; }; add rule inet foreign forward ip6 daddr 2001:db8:ffff::/64 counter'")
            foreign = gw2.succeed("nft -a -s list table inet foreign")
            owned = ruleset(gw2, "nat64", handles=False)
            gw2.succeed("systemctl restart nftables.service")
            assert gw2.succeed("nft -a -s list table inet foreign") == foreign
            assert ruleset(gw2, "nat64", handles=False) == owned
            # a restart of the host's firewall does not touch the namespace
            assert ruleset(gw2, "guard", handles=False, netns="nat64") == guarded
            everything = ruleset(gw2)
            gw2.succeed("systemctl restart nat64-jool.service")
            assert ruleset(gw2) == everything
            # a start of the Jool unit loads the same guard again
            assert ruleset(gw2, "guard", handles=False, netns="nat64") == guarded
            gw2.succeed("nft delete table inet foreign")
            heard = int(trusted.succeed("grep -c echo /tmp/talk-own").strip())
            trusted.wait_until_succeeds(f"test \"$(grep -c echo /tmp/talk-own)\" -ge {heard + 3}", timeout=30)
            trusted.fail("grep -E 'error|silent' /tmp/talk-own")
            trusted.succeed("systemctl stop talk-own.service")
            print("NAT_GATEWAY_GUARD_RESTARTS_OK")
            assert_gateway(G2)

        with subtest("G2: an IfState apply keeps the namespaces, the Jool instances and the units"):
            guarded = ruleset(gw2, "guard", handles=False, netns="nat64")
            assert_ifstate_noop(gw2)
            gw2.wait_for_unit("nat64-jool.service", timeout=60)
            assert ruleset(gw2, "guard", handles=False, netns="nat64") == guarded
            assert_gateway(G2)
            guarded = ruleset(client, "guard", handles=False, netns="clat")
            before = moves()
            gateway = clat_gateway()
            assert_ifstate_noop(client)
            client.wait_for_unit("clat.service", timeout=60)
            client.wait_for_unit("clat-follow.service", timeout=60)
            assert ruleset(client, "guard", handles=False, netns="clat") == guarded
            out = client.succeed(http("198.51.100.80")).strip()
            assert out == gateway.v4, out
            # the restarted follower keeps its gateway
            assert clat_gateway() is gateway and moves() == before
            print("NAT_GATEWAY_IFSTATE_OK")

        with subtest("G1, G8 (round G11): a failed start of the CLAT unit stops no follower; the unit tries again by itself, and the follower still moves"):
            pid = follower_pid()
            before = moves()
            client.succeed("mkdir -p /run/systemd/system/clat.service.d && printf '[Service]\\nExecStartPre=/run/current-system/sw/bin/false\\n' > /run/systemd/system/clat.service.d/fail.conf && systemctl daemon-reload")
            try:
                tries = int(client.succeed("systemctl show -p NRestarts --value clat.service").strip())
                # an IfState apply restarts the CLAT unit (PartOf); its start fails
                status, out = client.execute("systemctl restart ifstate.service 2>&1")
                print(f"FINDING an IfState restart while the CLAT unit cannot start: rc={status} {out.strip()}")
                client.wait_until_succeeds(f"test \"$(systemctl show -p NRestarts --value clat.service)\" -gt {tries}", timeout=30)
                client.fail("systemctl is-active clat.service")
                # the follower runs on, the same process
                client.succeed("systemctl is-active clat-follow.service")
                assert follower_pid() == pid
            finally:
                client.succeed("rm -f /run/systemd/system/clat.service.d/fail.conf && systemctl daemon-reload")
            # nobody starts it: Restart=on-failure does
            client.wait_until_succeeds("systemctl is-active clat.service", timeout=30)
            client.wait_until_succeeds(http("198.51.100.80"), timeout=30)
            assert follower_pid() == pid and moves() == before
            # the follower still moves: a /96 no beacon names
            client.succeed("ip netns exec clat jool_siit -i clat global update pool6 2001:db8:eeee::/96")
            moved = time.time()
            client.wait_until_succeeds(f"test \"$({FOLLOW_MOVES})\" -eq {before + 1}", timeout=FOLLOW_AFTER + 30)
            since = round(time.time() - moved, 1)
            print(f"FINDING the follower moved a CLAT off a /96 nobody names after {since} s")
            assert FOLLOW_AFTER - 5 <= since, since
            client.wait_until_succeeds(http("198.51.100.80"), timeout=30)
            assert follower_pid() == pid
            print("NAT_GATEWAY_CLAT_RETRY_OK")


        with subtest("a pool6 or a CLAT address that changed is reconciled at the next start, compared as addresses"):
            # the gateway: a live instance with another pool6 is replaced
            gw2.succeed("ip netns exec nat64 jool instance remove default && ip netns exec nat64 jool instance add default --netfilter --pool6 2001:db8:ffff::/96")
            gw2.succeed("systemctl restart nat64-jool.service")
            gw2.succeed("journalctl -b -u nat64-jool -o cat --no-pager | grep -F 'the instance is made again' >/dev/null")
            made = int(gw2.succeed("journalctl -b -u nat64-jool -o cat --no-pager | grep -cF 'the instance is made again'").strip())
            client.wait_until_succeeds(http(G2.server), timeout=30)
            # the same pool6 again: nothing is replaced, sessions stay
            gw2.succeed("systemctl restart nat64-jool.service")
            assert int(gw2.succeed("journalctl -b -u nat64-jool -o cat --no-pager | grep -cF 'the instance is made again'").strip()) == made
            assert_gateway(G2)
            # the client: a mapping for another address is replaced
            client.succeed("ip netns exec clat jool_siit -i clat eamt flush && ip netns exec clat jool_siit -i clat eamt add 2001:db8:c::dead 192.0.0.1")
            client.fail(http("198.51.100.80", limit=3))
            client.succeed("systemctl restart clat.service")
            mapping = client.succeed("ip netns exec clat jool_siit -i clat eamt display --csv --no-headers").strip()
            assert mapping == "${clatAddr}/128,192.0.0.1/32", mapping
            client.wait_until_succeeds(http("198.51.100.80"), timeout=30)
            print("NAT_GATEWAY_RECONCILE_OK")

        with subtest("G3, G4 (round G11): a full pool4 shows in the health state and the journal and the beacon stays; a start makes pool4 whole again"):
            machine = G2.machine
            first = pool4_state(machine)
            print(f"FINDING gw2's pool4 as its health check reads it: {first}")
            assert all(first[proto]["ports"] == 64436 for proto in ["tcp", "udp", "icmp"]), first
            machine.succeed("journalctl -b -u nat64-health -o cat --no-pager | grep -F 'pool4 below 50 %' >/dev/null")
            # ten UDP ports left; the trusted client opens twenty flows
            machine.succeed("ip netns exec nat64 jool pool4 remove 192.0.0.2 1100-65535 --udp && ip netns exec nat64 jool pool4 add 192.0.0.2 1100-1109 --udp")
            guard_before = guard(machine, "nat64")
            trusted.succeed(f"for i in $(seq 20); do python3 /etc/suite/shapes.py udp {G2.server} 9001 10 || true; done")
            # P3: what Jool does with a new flow on a full pool4
            print(f"FINDING P3 gw2 guard before and after ten flows too many on a full pool4: {guard_before} -> {guard(machine, 'nat64')}")
            assert guard(machine, "nat64")["guard-leaving"] == 0
            machine.wait_until_succeeds("journalctl -b -u nat64-health -o cat --no-pager | grep -F 'pool4 95 % or more' >/dev/null", timeout=30)
            full = pool4_state(machine)
            print(f"FINDING gw2's pool4 with ten UDP ports and twenty flows: {full}")
            assert full["udp"] == {"ports": 10, "used": 10, "percent": 100.0}, full
            # never a reason to withdraw: that would fill the other gateway
            machine.succeed("systemctl is-active nat64-beacon.service")
            client.succeed(names_prefix(G2))
            # G3: the next start repairs it, and a flushed pool4 too
            remade = "journalctl -b -u nat64-jool -o cat --no-pager | grep -cF 'pool4 is not the one range' || true"
            made = int(machine.succeed(remade).strip())
            for broken in ["true", "ip netns exec nat64 jool pool4 flush"]:
                machine.succeed(broken)
                machine.succeed("systemctl restart nat64-jool.service")
                assert_gateway(G2)
            assert int(machine.succeed(remade).strip()) == made + 2
            # a whole pool4 is left alone
            machine.succeed("systemctl restart nat64-jool.service")
            assert int(machine.succeed(remade).strip()) == made + 2
            machine.wait_until_succeeds("journalctl -b -u nat64-health -o cat --no-pager | tail -n 20 | grep -F 'pool4 below 50 %' >/dev/null", timeout=30)
            print("NAT_GATEWAY_POOL4_OK")

        with subtest("G23: a beacon that names a /96 that is not its gateway's is no proof; the follower ignores it"):
            current = clat_gateway()
            liar = other(current)
            before = moves()
            records = liar.machine.succeed("cat /run/nat64-gateway/ipv4only.hosts")
            liar.machine.succeed("printf '2001:db8:bad::c000:aa ipv4only.arpa\\n2001:db8:bad::c000:ab ipv4only.arpa\\n' > /run/nat64-gateway/ipv4only.hosts")
            try:
                trusted.wait_until_succeeds(f"dig +short AAAA ipv4only.arpa @{liar.addr} | grep -F '2001:db8:bad::' >/dev/null", timeout=30)
                # a follower that starts asks every beacon
                client.succeed("systemctl restart clat-follow.service")
                client.succeed("ip netns exec clat jool_siit -i clat global update pool6 2001:db8:eeee::/96")
                client.wait_until_succeeds(f"journalctl -b -u clat-follow -o cat --no-pager | grep -F \"{liar.addr} names 2001:db8:bad::/96, not its gateway's {liar.pool}: ignored\" >/dev/null", timeout=30)
                assert moves() == before
            finally:
                liar.machine.succeed(f"printf '%s' '{records}' > /run/nat64-gateway/ipv4only.hosts")
                client.succeed(f"ip netns exec clat jool_siit -i clat global update pool6 {current.pool}")
            client.wait_until_succeeds(names_prefix(liar), timeout=30)
            client.wait_until_succeeds(http("198.51.100.80"), timeout=30)
            print("NAT_GATEWAY_FOREIGN_PREFIX_OK")


    def failover_phases():
        """Loss, flaps, dead targets, dead gateways, restarts and reboots (§14.5 point 4)."""
        first = clat_gateway()
        second = other(first)
        assert first is G1

        with subtest("G23, §14.5 point 4: 90 s on a gateway with 30 % packet loss towards the clients, the follower does not move"):
            client.succeed(f"systemd-run --unit=idle python3 /etc/suite/shapes.py idle {second.server} 9002 /tmp/idle-go /tmp/idle")
            client.wait_until_succeeds("grep open /tmp/idle >/dev/null", timeout=30)
            before = moves()
            first.machine.succeed("tc qdisc add dev eth1 root netem loss 30%")
            try:
                holds_for(client, stays(first, before), 90, interval=2)
                client.wait_until_succeeds(http("198.51.100.80"), timeout=60)
            finally:
                first.machine.succeed("tc qdisc del dev eth1 root")

        with subtest("§12.1: a TCP flow that was idle for 40 s still passes the translator"):
            client.succeed("touch /tmp/idle-go")
            client.wait_until_succeeds("grep ok /tmp/idle >/dev/null", timeout=30)
            idle = int(client.succeed("cat /tmp/idle").split()[1])
            assert idle >= 40, idle

        def talk_stalled(count):
            return f"test \"$(grep -c echo /tmp/talk)\" -eq {count} && ! grep error /tmp/talk >/dev/null && systemctl is-active talk.service >/dev/null && ss -tn state established | grep ':9002' >/dev/null"

        with subtest("G6, G23: a gateway dies; a flow that is sending stalls for 20 s without a reset, the CLAT moves"):
            dead, live = first, second
            client.succeed(f"systemd-run --unit=talk python3 /etc/suite/shapes.py talk {dead.server} 9002 /tmp/talk")
            client.wait_until_succeeds("test \"$(grep -c echo /tmp/talk)\" -ge 3", timeout=30)
            assert clat_gateway() is dead
            before = moves()
            dead.machine.crash()
            crashed = time.time()
            heard = echoes("/tmp/talk")
            took = seconds_until(client, http("198.51.100.80", limit=2), limit=FOLLOW_AFTER + 90, wanted=live.v4)
            since = round(time.time() - crashed, 1)
            print(f"FINDING an IPv4 literal works through the live gateway {since} s after the crash")
            # the follower waits FOLLOW_AFTER s without the beacon
            assert took is not None and FOLLOW_AFTER - 5 <= since < FOLLOW_AFTER + 30, since
            assert clat_gateway() is live and moves() == before + 1
            # the trusted client's CLAT followed too
            trusted.wait_until_succeeds(clat_on(live), timeout=60)
            capped.wait_until_succeeds(clat_on(live), timeout=60)
            holds_for(client, talk_stalled(heard), 20)
            print("NAT_GATEWAY_CRASH_OK")

        with subtest("G23: the follower restarts on a /96 that is not its first one and stays for 15 s"):
            before = moves()
            pid = follower_pid()
            client.succeed("systemctl restart clat-follow.service")
            client.wait_until_succeeds(f"journalctl -b -u clat-follow -o cat --no-pager | tail -n 2 | grep -F 'is named by {second.addr}' >/dev/null", timeout=30)
            assert follower_pid() != pid
            holds_for(client, stays(second, before), 15, interval=2)

        with subtest("G23: the CLAT instance is created again with its first /96; the follower moves it to the live gateway"):
            before = moves()
            client.succeed("ip netns exec clat jool_siit instance remove clat")
            client.succeed("systemctl restart clat.service")
            created = time.time()
            assert clat_gateway() is first
            took = seconds_until(client, http("198.51.100.80", limit=2), limit=FOLLOW_AFTER + 90, wanted=second.v4)
            since = round(time.time() - created, 1)
            print(f"FINDING the follower corrected a CLAT that came back on the dead gateway's /96 after {since} s")
            assert took is not None and since < FOLLOW_AFTER + 30, since
            assert clat_gateway() is second and moves() == before + 1
            client.wait_for_unit("clat-follow.service", timeout=30)

        with subtest("G2, G23: the gateway boots again and translates; the follower stays where it is for 10 s"):
            before = moves()
            first.machine.start()
            gateway_ready(first)
            first.machine.succeed("nft 'add table inet probe; add chain inet probe forward { type filter hook forward priority -20; }; add rule inet probe forward oifname \"jool0\" ip6 saddr ${clientAddr} tcp dport 9002 counter comment \"old-flow-in\"; add rule inet probe forward iifname \"jool0\" ip daddr 198.51.100.80 tcp dport 9002 counter comment \"old-flow-translated\"'")
            assert_gateway(first)
            holds_for(client, stays(second, before), 10, interval=2)

        with subtest("G6: the gateway is back without state; the flow that kept sending is neither carried nor reset"):
            took = seconds_until(first.machine, "nft list chain inet probe forward | grep old-flow-in | grep -v 'packets 0 ' >/dev/null", limit=400, interval=2)
            print(f"FINDING the old flow's next packet reached the gateway {took} s after it was back")
            assert took is not None
            holds_for(client, talk_stalled(heard), 10)
            probe = first.machine.succeed("nft list chain inet probe forward")
            translated = first_int(r'counter packets (\d+) bytes \d+ comment "old-flow-translated"', probe)
            assert translated == 0, probe
            client.succeed("systemctl stop talk.service")
            first.machine.succeed("nft delete table inet probe")

        with subtest("§14.3, §14.5 point 4: one health target dies; the gateway stays healthy for 75 s"):
            current = clat_gateway()
            before = moves()
            server4.succeed(f"ip addr del {current.targets[0]}/32 dev eth1")
            try:
                holds_for(client, names_prefix(current) + " && " + stays(current, before), 2 * DOWN + 15, interval=1)
                current.machine.succeed("systemctl is-active nat64-beacon.service")
            finally:
                server4.succeed(f"ip addr add {current.targets[0]}/32 dev eth1")

        with subtest("G23, §14.3: every target of a gateway dies; it withdraws its beacon and the CLATs move"):
            sick, healthy = clat_gateway(), other(clat_gateway())
            before = moves()
            for target in sick.targets:
                server4.succeed(f"ip addr del {target}/32 dev eth1")
            cut = time.time()
            try:
                closed = seconds_until(client, beacon_closed(sick), limit=DOWN + 60)
                print(f"FINDING the gateway withdrew its beacon {closed} s after its last target died")
                assert closed is not None and DOWN - 5 <= closed < DOWN + 20, closed
                client.succeed(beacon_closed(sick, "+tcp"))
                took = seconds_until(client, http("198.51.100.80", limit=2), limit=FOLLOW_AFTER + 90, wanted=healthy.v4)
                since = round(time.time() - cut, 1)
                print(f"FINDING an IPv4 literal works through the healthy gateway {since} s after the targets died")
                assert took is not None and since < DOWN + FOLLOW_AFTER + 40, since
                assert clat_gateway() is healthy and moves() == before + 1
                trusted.wait_until_succeeds(clat_on(healthy), timeout=60)
            finally:
                for target in sick.targets:
                    server4.succeed(f"ip addr add {target}/32 dev eth1")
            took = seconds_until(client, names_prefix(sick), limit=UP + 90)
            print(f"FINDING the gateway served its beacon again {took} s after its targets returned")
            # never early: UP clean rounds first
            assert took is not None and UP - 10 <= took < UP + 40, took
            before = moves()
            holds_for(client, stays(healthy, before), 10, interval=2)

        with subtest("§14.3: a gateway whose own translator fails withdraws its beacon; the CLATs move"):
            sick, healthy = clat_gateway(), other(clat_gateway())
            before = moves()
            sick.machine.succeed("ip netns exec nat64 jool instance remove default")
            try:
                closed = seconds_until(client, beacon_closed(sick), limit=DOWN + 60)
                print(f"FINDING the gateway withdrew its beacon {closed} s after its translator was removed")
                assert closed is not None and DOWN - 5 <= closed < DOWN + 20, closed
                took = seconds_until(client, http("198.51.100.80", limit=2), limit=FOLLOW_AFTER + 90, wanted=healthy.v4)
                assert took is not None
                assert clat_gateway() is healthy and moves() == before + 1
            finally:
                sick.machine.succeed("systemctl restart nat64-jool.service")
            sick.machine.succeed("ip netns exec nat64 jool instance display | grep -w default >/dev/null")
            client.wait_until_succeeds(names_prefix(sick), timeout=UP + 90)
            assert_gateway(sick)

        def flap(machine, unit, on, off, rounds):
            """A unit that runs `off`, waits 5 s, runs `on`, waits 5 s, `rounds` times."""
            shell = machine.succeed("readlink -f $(command -v sh)").strip()
            # a transient unit has no PATH of the system: name it
            machine.succeed(f"systemd-run --unit={unit} {shell} -c 'export PATH=/run/current-system/sw/bin; for i in $(seq {rounds}); do {off}; sleep 5; {on}; sleep 5; done'")
            machine.succeed(f"systemctl is-active {unit}.service >/dev/null")

        with subtest("§14.5 point 4: 80 % loss on a gateway's upstream: it withdraws, the CLATs move once, and it stays withdrawn while lossy and while its upstream flaps"):
            sick, healthy = clat_gateway(), other(clat_gateway())
            before = moves()
            tc = sick.machine.succeed("readlink -f $(command -v tc)").strip()
            sick.machine.succeed(f"{tc} qdisc add dev eth2 root netem loss 80%")
            try:
                closed = seconds_until(client, beacon_closed(sick), limit=2 * DOWN + 60)
                print(f"FINDING the gateway withdrew its beacon {closed} s after 80 % loss began on its upstream")
                assert closed is not None and closed < 2 * DOWN + 30, closed
                took = seconds_until(client, http("198.51.100.80", limit=2), limit=FOLLOW_AFTER + 90, wanted=healthy.v4)
                assert took is not None
                assert clat_gateway() is healthy and moves() == before + 1
                # still lossy: a lucky round never brings it back
                holds_for(client, beacon_closed(sick), UP + 30, interval=5)
            finally:
                sick.machine.succeed(f"{tc} qdisc del dev eth2 root")
            # an upstream that is gone 5 s and back 5 s: still sick
            flap(sick.machine, "flap-upstream", f"{tc} qdisc del dev eth2 root", f"{tc} qdisc add dev eth2 root netem loss 100%", 15)
            try:
                holds_for(client, beacon_closed(sick) + " && " + stays(healthy, before + 1), 140, interval=5)
            finally:
                sick.machine.succeed(f"systemctl stop flap-upstream.service 2>/dev/null || true; {tc} qdisc del dev eth2 root 2>/dev/null || true")
            # a known start for the clock: 10 s of total loss, then clean.
            # The window forgives up to UP / 20 bad rounds, so the flap's
            # last seconds alone could bring the beacon back early
            sick.machine.succeed(f"{tc} qdisc add dev eth2 root netem loss 100%")
            time.sleep(10)
            sick.machine.succeed(f"{tc} qdisc del dev eth2 root")
            took = seconds_until(client, names_prefix(sick), limit=UP + 90)
            print(f"FINDING the gateway served its beacon again {took} s after its upstream was clean")
            assert took is not None and UP - 10 <= took < UP + 40, took
            assert clat_gateway() is healthy and moves() == before + 1
            print("NAT_GATEWAY_LOSSY_OK")

        with subtest("§14.5 point 4: one target of the current gateway flaps every 5 s for 100 s; the gateway stays up and nobody moves"):
            current = clat_gateway()
            before = moves()
            target = current.targets[0]
            ip = server4.succeed("readlink -f $(command -v ip)").strip()
            flap(server4, "flap-target", f"{ip} addr add {target}/32 dev eth1", f"{ip} addr del {target}/32 dev eth1", 10)
            try:
                holds_for(client, names_prefix(current) + " && " + stays(current, before), 100, interval=2)
            finally:
                server4.succeed(f"systemctl stop flap-target.service 2>/dev/null || true; ip addr add {target}/32 dev eth1 2>/dev/null || true")
            current.machine.succeed("systemctl is-active nat64-beacon.service")
            print("NAT_GATEWAY_FLAPPING_OK")

        with subtest("G23: every target of both gateways dies; both withdraw; the follower stays for 20 s and CLAT flows go on"):
            current = clat_gateway()
            client.succeed("systemd-run --unit=talk-clat python3 /etc/suite/shapes.py talk 198.51.100.80 9002 /tmp/talk-clat")
            client.wait_until_succeeds("test \"$(grep -c echo /tmp/talk-clat)\" -ge 3", timeout=30)
            before = moves()
            pid = follower_pid()
            every = G1.targets + G2.targets
            for target in every:
                server4.succeed(f"ip addr del {target}/32 dev eth1")
            try:
                for gateway in [G1, G2]:
                    took = seconds_until(client, beacon_closed(gateway), limit=DOWN + 60)
                    assert took is not None, gateway.machine.name
                heard_clat = echoes("/tmp/talk-clat")
                holds_for(client, stays(current, before) + " && ! grep error /tmp/talk-clat >/dev/null", 20, interval=2)
                grown = echoes("/tmp/talk-clat") - heard_clat
                print(f"FINDING the flow through the CLAT got {grown} echoes in 20 s with both beacons withdrawn")
                assert grown >= 15, grown
                assert follower_pid() == pid
                client.succeed("journalctl -b -u clat-follow -o cat --no-pager | tail -n 1 | grep -F 'no beacon answers ipv4only.arpa' >/dev/null")
            finally:
                # The current gateway's targets first, the other's 15 s
                # later: a silent round no longer resets the follower's
                # clock (round G11), so a gateway that came back five
                # rounds before the current one would win the client
                for target in current.targets:
                    server4.succeed(f"ip addr add {target}/32 dev eth1")
                time.sleep(15)
                for target in other(current).targets:
                    server4.succeed(f"ip addr add {target}/32 dev eth1")
            for gateway in [current, other(current)]:
                client.wait_until_succeeds(names_prefix(gateway), timeout=UP + 90)
            holds_for(client, stays(current, before) + " && ! grep error /tmp/talk-clat >/dev/null", 10, interval=2)
            client.succeed("systemctl stop talk-clat.service")

        with subtest("health check fail-safe: the beacon stops with the health check; a restart resumes its state (a deploy does not look like sickness)"):
            gateway = other(clat_gateway())
            machine = gateway.machine
            machine.succeed("systemctl stop nat64-health.service")
            took = seconds_until(client, beacon_closed(gateway), limit=30)
            print(f"FINDING {machine.name} closed its beacon {took} s after its health check was stopped")
            assert took is not None and took < 5, took
            machine.fail("systemctl is-active nat64-beacon.service")
            machine.succeed("systemctl start nat64-health.service")
            took = seconds_until(client, names_prefix(gateway), limit=60)
            assert took is not None and took < 20, took
            # in this run of the unit (its first line; a pool4 line follows since round G11)
            machine.succeed("journalctl -o cat --no-pager _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value nat64-health.service) | grep nat64-health: | sed -n 1p | grep 'resumed up' >/dev/null")
            state = json.loads(machine.succeed("cat /run/nat64-gateway/health.json"))
            print(f"FINDING the health state file: {state}")
            assert state["state"] == "up" and len(state["targets"]) == 3, state
            pid = machine.succeed("systemctl show -p MainPID --value nat64-health.service").strip()
            machine.succeed("systemctl kill -s KILL --kill-whom=main nat64-health.service")
            machine.wait_until_succeeds(f"pid=$(systemctl show -p MainPID --value nat64-health.service); test \"$pid\" -gt 0 && test \"$pid\" -ne {pid}", timeout=30)
            took = seconds_until(client, names_prefix(gateway), limit=60)
            assert took is not None and took < 20, took

        with subtest("§14.5 point 4 (round G11): the current gateway's beacon goes silent and 10 % of the packets towards the other are lost; the CLAT moves in about a minute"):
            current, candidate = clat_gateway(), other(clat_gateway())
            before = moves()
            # silent, not refused: the queries vanish
            current.machine.succeed(f"nft 'add table inet silence; add chain inet silence input {{ type filter hook input priority -50; }}; add rule inet silence input ip6 daddr {current.addr} meta l4proto {{ tcp, udp }} th dport 53 drop'")
            candidate.machine.succeed("tc qdisc add dev eth1 root netem loss 10%")
            try:
                took = seconds_until(client, clat_on(candidate), limit=FOLLOW_AFTER + 120, interval=1)
                print(f"FINDING the CLAT moved {took} s after its beacon went silent, with 10 % loss towards the other gateway")
                # the first rule needed about 40 answers in a row: many minutes
                assert took is not None and FOLLOW_AFTER - 5 <= took < FOLLOW_AFTER + 30, took
                assert moves() == before + 1
                trusted.wait_until_succeeds(clat_on(candidate), timeout=60)
            finally:
                current.machine.succeed("nft delete table inet silence")
                candidate.machine.succeed("tc qdisc del dev eth1 root")
            # the old gateway answers again: no move back
            client.wait_until_succeeds(names_prefix(current), timeout=30)
            holds_for(client, stays(candidate, before + 1), 15, interval=2)
            client.wait_until_succeeds(http("198.51.100.80", limit=2), timeout=60)
            print("NAT_GATEWAY_LOSSY_CANDIDATE_OK")

        with subtest("a reboot of a gateway and of a client: everything comes back"):
            gateway = other(clat_gateway())
            gateway.machine.shutdown()
            gateway.machine.start()
            gateway_ready(gateway)
            current = clat_gateway()
            client.shutdown()
            client.start()
            client.wait_for_unit("clat-follow.service", timeout=300)
            # the CLAT starts on the first gateway; both are healthy, so it stays
            client.wait_until_succeeds(http("198.51.100.80"), timeout=60)
            assert clat_gateway() is G1
            client.fail("systemctl --failed --no-legend | grep .")


    def hostile_phases():
        """Hostile actors against the translator and the CLAT. Every attack
        ends in one verdict; all run, and any gap fails the suite. A new
        attack is a new verdict; never delete one to make the suite pass."""
        results = []

        def verdict(key, safe, detail=""):
            results.append((key, bool(safe), detail))
            print(f"HOSTILE {'SAFE' if safe else 'GAP '} {key}: {detail}")

        def scan(machine, target):
            family = "-6" if ":" in target else ""
            out = machine.succeed(f"nmap {family} -n -Pn -sS -p- --min-rate 3000 --max-retries 1 -oG - {target} 2>&1")
            found = []
            for line in out.splitlines():
                if "Ports:" in line:
                    found += [int(p.split("/")[0].strip()) for p in line.split("Ports:")[1].split(",") if "/open/" in p]
            return sorted(found)

        def count_on(machine, expr, hook="forward", priority=-300, name="hostile", netns=None):
            """Count what matches `expr` at a hook of the machine (or of one
            of its namespaces). Priority -300: before every other table
            (what arrived). Priority -5: behind the machine's own table at
            -10 (what it let through); in a translator's namespace, behind
            Jool at -75 and before the guard at 0 (what Jool handed back)."""
            nft = "nft" if netns is None else f"ip netns exec {netns} nft"
            machine.succeed(
                f"{nft} delete table inet {name} 2>/dev/null || true; {nft} add table inet {name}; "
                f"{nft} 'add chain inet {name} c {{ type filter hook {hook} priority {priority}; }}'; "
                f"{nft} 'add rule inet {name} c {expr} counter'"
            )

        def counted_on(machine, name="hostile", netns=None):
            nft = "nft" if netns is None else f"ip netns exec {netns} nft"
            return first_int(r"counter packets (\d+)", machine.succeed(f"{nft} list table inet {name}"))

        def scapy(machine, packets, count=1):
            """Send forged packets from a machine: Scapy expressions, on eth1."""
            machine.succeed(f"cat > /tmp/forge.py <<'EOF'\nfrom scapy.all import *\nfor packet in [{packets}]:\n    send(packet, iface=\"eth1\", count={count}, verbose=False)\nEOF")
            machine.succeed("python3 /tmp/forge.py")

        def raw253(target):
            return f"python3 -c 'import socket; s = socket.socket(socket.AF_INET6, socket.SOCK_RAW, 253); s.sendto(b\"x\", (\"{target}\", 0))'"

        def health(machine):
            return json.loads(machine.succeed("cat /run/nat64-gateway/health.json"))

        with subtest("hostile: full scans of a gateway, from every side"):
            found = scan(outsider, G1.addr)
            verdict("N01 an undeclared host finds no TCP port open on the gateway", not found, f"open: {found}")
            found = scan(client, G1.addr)
            verdict("N02 a declared client finds only the beacon (53) open on the gateway", [p for p in found if p != 53] == [], f"open: {found}")
            found = scan(server4, G1.v4)
            verdict("N03 the IPv4 side finds no TCP port open on the gateway", not found, f"open: {found}")
            server4.succeed(f"ip route add 192.0.0.0/24 via {G1.v4}")
            found = scan(server4, "192.0.0.2")
            verdict("N04 the IPv4 side reaches no port of the translator's pool4 address", not found, f"open: {found}")
            server4.succeed("ip route del 192.0.0.0/24")

        with subtest("hostile: the translator is no relay to loopback, private or the gateway's own addresses"):
            for target in ["127.0.0.1", "10.0.0.1", "169.254.169.254", "172.16.0.1", "192.168.1.1", "100.64.0.1", "192.0.0.1", G1.v4, "224.0.0.1"]:
                code, _ = client.execute(http(embed(G1, target), limit=2))
                ping, _ = client.execute(f"ping -c1 -W1 {embed(G1, target)}")
                verdict(f"N05 a declared client reaches nothing at {target} through the translator", code != 0 and ping != 0, f"curl rc={code}, ping rc={ping}")
            refused = {name: counted(gw1, name) for name in ["nat64-private", "nat64-private-post", "nat64-host"]}
            leaving = guard(gw1, "nat64")
            verdict("N05 every private destination was refused while the packet was IPv6: nothing private came out of the translator, the guard dropped nothing", refused["nat64-private"] >= 16 and refused["nat64-private-post"] == 0 and leaving["guard-leaving"] == 0 and leaving["guard-leftover"] == 0, f"{refused}, guard {leaving}")

        with subtest("hostile: a packet the CLAT does not translate does not loop"):
            count_on(client, "ip6 daddr ${clatAddr} icmpv6 type echo-request")
            count_on(client, "ip6 daddr ${clatAddr} icmpv6 type echo-request", priority=-5, name="passed")
            before = counted(client, "clat-foreign-source", table="clat")
            outsider.execute("ping -c1 -W2 -t 64 ${clatAddr}")
            crossings = counted_on(client)
            assert crossings >= 1, "the echo request never reached the client: the attack did not run"
            verdict("N06 a foreign packet to a CLAT address crosses the client once", crossings <= 1, f"{crossings} crossings of one echo request with hop limit 64")
            verdict("N06 the client's own table refuses the foreign packet: it never enters the CLAT namespace", counted_on(client, "passed") == 0 and counted(client, "clat-foreign-source", table="clat") == before + 1, f"let through: {counted_on(client, 'passed')}, clat-foreign-source +{counted(client, 'clat-foreign-source', table='clat') - before}")
            # the layers below, each alone: the client's table lets everything
            # into the CLAT (an emptied chain would end at `clat-forward`)
            client.succeed("nft flush chain inet clat to_clat; nft add rule inet clat to_clat accept")
            try:
                was = guard(client, "clat")["guard-leftover"]
                outsider.execute("ping -c1 -W2 -t 64 ${clatAddr}")
                verdict("N06 without the client's table the namespace guard drops the foreign packet: one more crossing, no loop", counted_on(client) == 2 and guard(client, "clat")["guard-leftover"] == was + 1, f"{counted_on(client)} crossings of two echo requests, guard-leftover +{guard(client, 'clat')['guard-leftover'] - was}")
                client.succeed("ip netns exec clat nft delete table inet guard")
                outsider.execute("ping -c1 -W2 -t 64 ${clatAddr}")
                verdict("N06 without the table and without the guard the namespace still forwards nothing (forwarding is off there, and the CLAT address is an unreachable route): one more crossing, no loop", counted_on(client) == 3, f"{counted_on(client)} crossings of three echo requests")
            finally:
                client.succeed("systemctl restart nftables.service clat.service")
            client.succeed("nft delete table inet passed")
            guard(client, "clat")
            client.wait_until_succeeds(http("198.51.100.80"), timeout=30)

        with subtest("hostile: a protocol the translator does not translate does not loop"):
            count_on(gw1, "ip6 daddr ${pool1} meta l4proto 253")
            count_on(gw1, "ip6 daddr ${pool1} meta l4proto 253", priority=-5, name="passed")
            before = counted(gw1, "nat64-protocol")
            client.succeed(raw253(G1.server))
            gw1.succeed("sleep 2")
            crossings = counted_on(gw1)
            assert crossings >= 1, "the packet never reached the gateway: the attack did not run"
            verdict("N07 an untranslatable packet to pool6 crosses the gateway once", crossings <= 1, f"{crossings} crossings of one packet")
            verdict("N07 the gateway's own table refuses the protocol: it never enters the translator namespace", counted_on(gw1, "passed") == 0 and counted(gw1, "nat64-protocol") == before + 1, f"let through: {counted_on(gw1, 'passed')}, nat64-protocol +{counted(gw1, 'nat64-protocol') - before}")
            gw1.succeed("nft delete table inet passed")

        with subtest("hostile: one client cannot inject into another client's mapping (hairpin)"):
            trusted.succeed("rm -f /tmp/hairpin")
            listener = (
                "import socket, time\n"
                "s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)\n"
                "s.bind((\"::\", 40000))\n"
                f"s.sendto(b\"hello\", (\"{G1.server}\", 9001))\n"
                "s.settimeout(1)\n"
                "end = time.time() + 25\n"
                "out = open(\"/tmp/hairpin\", \"w\")\n"
                "while time.time() < end:\n"
                "    try:\n"
                "        data, peer = s.recvfrom(100)\n"
                "        out.write(f\"{data!r} from {peer[0]}\\n\")\n"
                "        out.flush()\n"
                "    except TimeoutError:\n"
                "        pass\n"
            )
            trusted.succeed(f"cat > /tmp/listener.py <<'EOF'\n{listener}EOF")
            trusted.succeed("systemd-run --unit=hairpin-listener python3 /tmp/listener.py")
            trusted.wait_until_succeeds("grep hello /tmp/hairpin >/dev/null", timeout=15)
            bib = gw1.succeed("ip netns exec nat64 jool bib display --udp --numeric --csv --no-headers")
            lines = [line.split(",") for line in bib.splitlines() if "${trustedAddr}" in line and ",40000," in line]
            assert lines, f"no mapping for the trusted client's flow:\n{bib}"
            mapped = lines[0][4]
            target = embed(G1, "192.0.0.2")
            before = counted(gw1, "nat64-private")
            client.execute(f"python3 -c 'import socket; s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM); [s.sendto(b\"evil\", (\"{target}\", {mapped})) for _ in range(3)]'")
            trusted.succeed("sleep 3")
            got = trusted.succeed("cat /tmp/hairpin")
            verdict("N08 a client's datagram to another client's mapped port is not delivered", "evil" not in got, got.strip().replace("\n", " | "))
            verdict("N09 the translator's own pool4 address is refused before translation (no hairpin inside Jool)", counted(gw1, "nat64-private") >= before + 3, f"nat64-private +{counted(gw1, 'nat64-private') - before} for three datagrams to {target}")
            trusted.execute("systemctl stop hairpin-listener")

        with subtest("hostile: the layers under the gateway's table, each alone; a gateway without its guard is not healthy"):
            # N10: no Jool instance. The host table lets a declared
            # client's ping pass; the guard ends it.
            count_on(gw1, "ip6 daddr ${pool1} icmpv6 type echo-request ip6 saddr ${clientAddr}")
            count_on(gw1, "ip6 saddr ${clientAddr}", hook="prerouting", priority=-5, name="handed", netns="nat64")
            count_on(gw1, 'oifname "jool1"', hook="postrouting", priority=5, name="left", netns="nat64")
            was = guard(gw1, "nat64")["guard-leftover"]
            gw1.succeed("ip netns exec nat64 jool instance remove default")
            try:
                client.execute(f"ping -c1 -W1 -t 64 {G1.server}")
                crossings, handed, left, grown = counted_on(gw1), counted_on(gw1, "handed", "nat64"), counted_on(gw1, "left", "nat64"), guard(gw1, "nat64")["guard-leftover"] - was
            finally:
                gw1.succeed("systemctl restart nat64-jool.service")
            # the health check's own pings end at the guard too while there is no instance
            verdict("N10 with no Jool instance a declared client's packet crosses the gateway once and ends at the guard", crossings == 1 and handed == 1 and left == 0 and grown >= 1, f"{crossings} crossings of one echo request; Jool handed {handed} packet of the client back to the kernel; {left} packets left the namespace behind the guard; guard-leftover +{grown} (with the health check's pings)")
            gw1.succeed("ip netns exec nat64 nft delete table inet handed; ip netns exec nat64 nft delete table inet left")
            client.wait_until_succeeds(f"ping -c1 -W2 {G1.server}", timeout=30)

            # N11: the host table and the guard are taken away; the
            # unreachable route alone ends an untranslatable packet. The
            # health check sees the missing guard and has it loaded again.
            count_on(gw1, "ip6 daddr ${pool1} meta l4proto 253")
            gw1.succeed("nft flush chain inet nat64 to_translator")
            removed = time.time()
            gw1.succeed("ip netns exec nat64 nft delete table inet guard")
            try:
                client.succeed(raw253(G1.server))
                gw1.succeed("sleep 2")
                crossings = counted_on(gw1)
            finally:
                gw1.succeed("systemctl restart nftables.service")
            verdict("N11 without the gateway's table and without the guard the namespace still forwards nothing (forwarding is off there, and pool6 is an unreachable route): one crossing", crossings == 1, f"{crossings} crossings of one packet")
            seen = seconds_until(gw1, "grep -F '\"guard\": false' /run/nat64-gateway/health.json", limit=30, interval=0.2)
            back = seconds_until(gw1, "ip netns exec nat64 nft list table inet guard", limit=75)
            since = round(time.time() - removed, 1)
            asked = gw1.succeed("journalctl -b -u nat64-health -o cat --no-pager | grep -cF 'is not loaded: the gateway is not healthy' || true").strip()
            verdict("N11 a deleted guard shows in the health state and is loaded again without an operator", seen is not None and back is not None and asked == "1", f"health.json said guard false after {seen} s; the guard was back {since} s after it was deleted; journal lines: {asked}")
            gw1.wait_until_succeeds("grep -F '\"guard\": true' /run/nat64-gateway/health.json", timeout=30)
            verdict("N11 a guard that is back within the down window never withdraws the beacon", gw1.execute("systemctl is-active nat64-beacon.service")[0] == 0 and client.execute(names_prefix(G1))[0] == 0, f"health: {health(gw1)['state']}, bad rounds of the last 60: {health(gw1)['bad_of_last_2down']}")
            gw1.succeed("nft delete table inet hostile")

            # N11 on the other gateway (no client is on it): the Jool unit
            # cannot start, so nobody loads the guard again
            gw2.succeed("mkdir -p /run/systemd/system/nat64-jool.service.d && printf '[Service]\\nExecStartPre=/run/current-system/sw/bin/false\\n' > /run/systemd/system/nat64-jool.service.d/fail.conf && systemctl daemon-reload")
            removed = time.time()
            gw2.succeed("ip netns exec nat64 nft delete table inet guard")
            try:
                took = seconds_until(client, beacon_closed(G2), limit=DOWN + 60)
                state = health(gw2)
                words = gw2.succeed("journalctl -b -u nat64-health -o cat --no-pager | grep -F 'beacon withdrawn' | tail -n 1").strip()
                verdict("N11 a gateway that cannot load its guard withdraws its beacon", took is not None and state["state"] == "down" and state["guard"] is False and "guard is not loaded" in words, f"beacon closed {took} s after the guard was deleted; health: state {state['state']}, guard {state['guard']}; journal: {words}")
                # its translator still translates: only the beacon tells clients
                verdict("N11 INFO the gateway without its guard still translates (the host table and the unreachable route remain)", True, f"ping through it: rc={client.execute(f'ping -c1 -W2 {G2.server}')[0]}")
            finally:
                gw2.succeed("rm -f /run/systemd/system/nat64-jool.service.d/fail.conf && systemctl daemon-reload")
            # nobody starts the unit: Restart=on-failure does, the guard returns
            gw2.wait_until_succeeds("ip netns exec nat64 nft list table inet guard >/dev/null", timeout=60)
            took = seconds_until(client, names_prefix(G2), limit=UP + 90, interval=2)
            verdict("N11 the gateway advertises itself again once its guard is back and UP rounds were good", took is not None, f"beacon back after {took} s")
            assert moves() == 0, "a client moved during the hostile phases"

        with subtest("hostile: what Jool cannot translate, forged errors, fragments and the IPv4 side"):
            # N12: ICMPv6 types without an IPv4 twin, to a pool6 address
            count_on(gw1, "ip6 daddr ${pool1} meta l4proto ipv6-icmp ip6 saddr ${clientAddr}", priority=-5, name="passed")
            before = counted(gw1, "nat64-icmp-type")
            scapy(client, ", ".join(f'IPv6(src="${clientAddr}", dst="{G1.server}", hlim=64)/{kind}' for kind in [f'ICMPv6ND_NS(tgt="{G1.server}")', "ICMPv6ND_RS()", "ICMPv6MLQuery()"]))
            gw1.succeed("sleep 1")
            grown = counted(gw1, "nat64-icmp-type") - before
            verdict("N12 neighbour discovery and MLD towards pool6 never enter the translator", grown == 3 and counted_on(gw1, "passed") == 0, f"nat64-icmp-type +{grown}, let through: {counted_on(gw1, 'passed')}")

            # N13: a forged ICMPv6 error about no flow, from an undeclared host
            count_on(gw1, "ip6 daddr ${pool1} ip6 saddr ${outsiderAddr}", priority=-5, name="passed")
            before = counted(gw1, "nat64-undeclared")
            scapy(outsider, f'IPv6(src="${outsiderAddr}", dst="{G1.server}")/ICMPv6PacketTooBig(mtu=1280)/IPv6(src="{G1.server}", dst="${clientAddr}")/TCP(sport=80, dport=40000)')
            gw1.succeed("sleep 1")
            grown = counted(gw1, "nat64-undeclared") - before
            verdict("N13 a forged ICMPv6 error from an undeclared host is not `related`: dropped", grown == 1 and counted_on(gw1, "passed") == 0, f"nat64-undeclared +{grown}, let through: {counted_on(gw1, 'passed')}")

            # N15: fragments. An allowed destination is delivered; a
            # private one is refused as one reassembled packet.
            private = embed(G1, "10.0.0.1")
            count_on(gw1, f"ip6 daddr {private}", priority=-5, name="passed")
            before = refused_private(gw1)
            delivered = client.execute(udp(G1.server, 3000))[0] == 0
            client.execute(udp(private, 3000))
            grown = refused_private(gw1) - before
            verdict("N15 a fragmented datagram is delivered to an allowed destination and refused to a private one before translation", delivered and grown == 1 and counted_on(gw1, "passed") == 0, f"3000 bytes echoed: {delivered}; nat64-private +{grown}; let through: {counted_on(gw1, 'passed')}")
            gw1.succeed("nft delete table inet passed")

            # N14: the IPv4 side, from an address no flow goes to
            trusted.succeed("rm -f /tmp/hairpin; systemd-run --unit=hairpin-listener2 python3 /tmp/listener.py")
            trusted.wait_until_succeeds("grep hello /tmp/hairpin >/dev/null", timeout=15)
            bib = gw1.succeed("ip netns exec nat64 jool bib display --udp --numeric --csv --no-headers")
            mapped = [line.split(",") for line in bib.splitlines() if "${trustedAddr}" in line and ",40000," in line][0][4]
            count_on(gw1, 'oifname "jool0" ip saddr 198.51.100.95', priority=-300)
            server4.succeed(f"python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((\"198.51.100.95\", 9003)); [s.sendto(b\"evil4\", (\"{G1.v4}\", port)) for port in [{mapped}, *range(1100, 1200)]]'")
            server4.succeed(f"nmap -n -Pn -sS -S 198.51.100.95 -e eth1 -p {mapped},1100-1120 --max-retries 0 {G1.v4} >/dev/null 2>&1 || true")
            trusted.succeed("sleep 2")
            got = trusted.succeed("cat /tmp/hairpin")
            verdict("N14 the IPv4 side opens no flow into the translator: nothing unsolicited reaches the translator's link or a client's mapping", counted_on(gw1) == 0 and "evil4" not in got, f"IPv4 packets from the stranger towards jool0: {counted_on(gw1)}; nat64-unsolicited4: {counted(gw1, 'nat64-unsolicited4')}; the client heard: {got.strip()}")
            trusted.execute("systemctl stop hairpin-listener2")
            gw1.succeed("nft delete table inet hostile")

        with subtest("hostile: a full pool4 (P3)"):
            # N16: ten UDP ports, 300 new flows from the trusted client
            # (its tier's flow limit is far above 300)
            client.succeed(f"rm -f /tmp/talk-full; systemd-run --unit=talk-full python3 /etc/suite/shapes.py talk {G1.server} 9002 /tmp/talk-full")
            client.wait_until_succeeds("test \"$(grep -c echo /tmp/talk-full)\" -ge 2", timeout=30)
            gw1.succeed("ip netns exec nat64 jool pool4 remove 192.0.0.2 1100-65535 --udp && ip netns exec nat64 jool pool4 add 192.0.0.2 1100-1109 --udp")
            count_on(gw1, "ip6 daddr ${pool1} ip6 saddr ${trustedAddr} udp dport 9001", priority=-5)
            count_on(gw1, 'iifname "jool0" ip6 daddr ${trustedAddr} meta l4proto ipv6-icmp', name="errors")
            stats = "ip netns exec nat64 jool -i default stats display --all --csv --no-headers"
            numbers = lambda text: {line.split(",")[0]: int(line.split(",")[1]) for line in text.splitlines() if line.count(",") == 1 and line.split(",")[1].strip().isdigit()}
            stats_before, guard_before = numbers(gw1.succeed(stats)), guard(gw1, "nat64")
            try:
                trusted.succeed(f"python3 -c 'import socket; [socket.socket(socket.AF_INET6, socket.SOCK_DGRAM).sendto(b\"x\", (\"{G1.server}\", 9001)) for _ in range(300)]'")
                gw1.succeed("sleep 2")
                stats_after, guard_after = numbers(gw1.succeed(stats)), guard(gw1, "nat64")
                grown = {key: value - stats_before.get(key, 0) for key, value in stats_after.items() if value != stats_before.get(key, 0)}
                crossings, errors = counted_on(gw1), counted_on(gw1, "errors")
                print(f"FINDING P3 a full pool4 (10 UDP ports) and 300 new flows: {crossings} packets crossed towards the translator; Jool counters that moved: {grown}; guard {guard_before} -> {guard_after}; ICMPv6 errors back to the client: {errors}")
                heard = echoes("/tmp/talk-full")
                client.wait_until_succeeds(f"test \"$(grep -c echo /tmp/talk-full)\" -ge {heard + 3}", timeout=30)
                verdict("N16 on a full pool4 every new flow crosses the gateway once, an open flow of another client goes on, the beacon stays", crossings == 300 and guard_after["guard-leaving"] == 0 and client.execute("grep error /tmp/talk-full")[0] != 0 and gw1.execute("systemctl is-active nat64-beacon.service")[0] == 0, f"{crossings} crossings of 300 datagrams; guard-leftover +{guard_after['guard-leftover'] - guard_before['guard-leftover']}; ICMPv6 errors to the client: {errors}")
            finally:
                gw1.succeed("systemctl restart nat64-jool.service")
                client.execute("systemctl stop talk-full.service")
            gw1.succeed("nft delete table inet hostile; nft delete table inet errors")
            client.wait_until_succeeds(f"ping -c1 -W2 {G1.server}", timeout=30)

        with subtest("hostile: forged sources, forged router advertisements and other links against a CLAT host"):
            target = "${clatAddr}"
            # C01: a gateway's /96 with a private IPv4 address inside
            count_on(client, f"ip6 daddr {target}", priority=-5, name="passed")
            before = counted(client, "clat-private-source", table="clat")
            scapy(outsider, f'IPv6(src="{embed(G1, "10.0.0.1")}", dst="{target}")/UDP(sport=53, dport=53)/b"x"')
            client.succeed("sleep 1")
            grown = counted(client, "clat-private-source", table="clat") - before
            verdict("C01 a forged gateway source that embeds a private IPv4 address never enters the CLAT", grown == 1 and counted_on(client, "passed") == 0, f"clat-private-source +{grown}, let through: {counted_on(client, 'passed')}")

            # C02, C03, C07: a forged gateway source that embeds a public
            # IPv4 address is translated once; the host takes nothing
            # unsolicited from it (TCP, UDP to an open port, a ping)
            client.succeed("rm -f /tmp/heard; systemd-run --unit=udp-open python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((\"0.0.0.0\", 40001)); open(\"/tmp/heard\", \"w\").write(repr(s.recvfrom(100)))'")
            client.wait_until_succeeds("ss -uln | grep ':40001 ' >/dev/null", timeout=15)
            forged = embed(G1, "198.51.100.77")
            count_on(client, 'iifname "clat0"', priority=-300)
            count_on(client, 'oifname "clat0" ip daddr 198.51.100.77', hook="output", priority=-300, name="answers")
            before = counted(client, "clat-unsolicited", table="clat")
            scapy(outsider, f'IPv6(src="{forged}", dst="{target}")/TCP(sport=4444, dport=22, flags="S"), IPv6(src="{forged}", dst="{target}")/UDP(sport=4444, dport=40001)/b"evil", IPv6(src="{forged}", dst="{target}", hlim=64)/ICMPv6EchoRequest()')
            client.succeed("sleep 2")
            grown = counted(client, "clat-unsolicited", table="clat") - before
            heard = client.execute("test -s /tmp/heard")[0] == 0
            verdict("C02 C03 C07 forged packets from a gateway's /96 are translated once and the host takes nothing unsolicited: no answer, no datagram to an open port, no loop", grown == 3 and counted_on(client, "passed") == 3 and not heard and counted_on(client, "answers") == 0 and counted_on(client) == 0, f"let through to the CLAT: {counted_on(client, 'passed')}; clat-unsolicited +{grown}; the open UDP port heard something: {heard}; answers sent: {counted_on(client, 'answers')}; packets forwarded back from clat0: {counted_on(client)}")
            client.execute("systemctl stop udp-open.service")
            client.succeed("nft delete table inet passed; nft delete table inet answers; nft delete table inet hostile")

            # C04: a forged router advertisement with a NAT64 prefix (PREF64)
            # and a default route of high preference
            pool_before = clat_gateway()
            routes_before = client.succeed("ip -6 route show default").strip()
            pref64 = "bytes([0x07, 0x08]) + bytes.fromhex(\"20010db80bad006400000000\")"
            scapy(outsider, f'IPv6(dst="ff02::1")/ICMPv6ND_RA(prf=1, routerlifetime=1800)/ICMPv6NDOptSrcLLAddr(lladdr=get_if_hwaddr("eth1"))/ICMPv6NDOptUnknown(type=38, len=2, data={pref64})/ICMPv6NDOptPrefixInfo(prefix="2001:db8:bad::", prefixlen=64)', count=3)
            holds_for(client, clat_on(pool_before), 20, interval=2)
            routes_after = client.succeed("ip -6 route show default").strip()
            verdict("C04 a forged router advertisement with a NAT64 prefix does not move the CLAT (20 s)", clat_gateway() is pool_before and moves() == 0, f"pool6 stays {pool_before.pool}")
            print(f"HOSTILE INFO C04 the default route after the forged advertisement (netif's area): before [{routes_before}] after [{routes_after}]")

            # C06: no CLAT instance: the host's IPv4 packet enters the
            # namespace once and ends at the guard
            count_on(client, 'oifname "clat0" ip daddr 198.51.100.80 icmp type echo-request', hook="output", priority=-300, name="sent")
            count_on(client, 'iifname "clat0" ip daddr 198.51.100.80', hook="prerouting", priority=-300, name="returned")
            was = guard(client, "clat")["guard-leftover"]
            client.succeed("ip netns exec clat jool_siit instance remove clat")
            try:
                client.execute("ping -c1 -W1 198.51.100.80")
                sent, returned, grown = counted_on(client, "sent"), counted_on(client, "returned"), guard(client, "clat")["guard-leftover"] - was
            finally:
                client.succeed("systemctl restart clat.service")
            verdict("C06 with no CLAT instance the host's packet crosses the link once and ends at the guard", sent == 1 and returned == 0 and grown == 1, f"sent {sent}, came back {returned}, guard-leftover +{grown}")
            client.succeed("nft delete table inet sent; nft delete table inet returned")
            client.wait_until_succeeds(http("198.51.100.80"), timeout=FOLLOW_AFTER + 60)

            # C08 (O7): the CLAT turns IPv6 forwarding on, machine-wide.
            # A second link of the client (a namespace `lan` behind a
            # veth) must not become reachable through it, either way.
            client.succeed(
                "ip netns add lan && ip link add lan0 type veth peer name lan1 netns lan && "
                "ip addr add 2001:db8:d::1/64 dev lan0 nodad && ip link set lan0 up && "
                "ip -n lan addr add 2001:db8:d::2/64 dev lan1 nodad && ip -n lan link set lan1 up && ip -n lan link set lo up && "
                "ip -n lan -6 route add default via 2001:db8:d::1"
            )
            outsider.succeed("ip -6 route add 2001:db8:d::/64 via ${clientAddr}")
            client.wait_until_succeeds("ping -c1 -W2 2001:db8:d::2", timeout=15)
            before = counted(client, "clat-forward", table="clat")
            inwards = outsider.execute("ping -c2 -W1 2001:db8:d::2")[0]
            outwards = client.execute("ip netns exec lan ping -c2 -W1 ${outsiderAddr}")[0]
            grown = counted(client, "clat-forward", table="clat") - before
            verdict("C08 a CLAT host forwards IPv6 for its CLAT only: a second link is not reachable through it, in either direction", inwards != 0 and outwards != 0 and grown == 4, f"outsider to the second link: rc={inwards}; second link to the outsider: rc={outwards}; clat-forward +{grown}")
            # the negative proof: without the client's table the same pings pass
            client.succeed("nft delete table inet clat")
            try:
                opened = (outsider.execute("ping -c2 -W1 2001:db8:d::2")[0], client.execute("ip netns exec lan ping -c2 -W1 ${outsiderAddr}")[0])
            finally:
                client.succeed("systemctl restart nftables.service")
            print(f"HOSTILE INFO C08 negative proof: without table inet clat the same pings end with rc={opened} (0, 0: the machine forwards between its links)")
            assert opened == (0, 0), opened
            client.succeed("ip link del lan0; ip netns del lan")
            outsider.succeed("ip -6 route del 2001:db8:d::/64")
            out = client.succeed(http("198.51.100.80")).strip()
            verdict("C08 the CLAT still carries IPv4 with forwarding refused for every other link", out == clat_gateway().v4, f"the page says {out}")

        with subtest("hostile: after every attack the guards let nothing leave that was not translated"):
            # N17: the Jool units were started again above (their counters
            # start at 0 then), so each attack read its own delta
            final = {"gw1": guard(gw1, "nat64"), "gw2": guard(gw2, "nat64"), "client": guard(client, "clat"), "trusted": guard(trusted, "clat")}
            verdict("N17 no guard dropped a packet on its way out of a namespace: the host tables refused every attack first", all(found["guard-leaving"] == 0 for found in final.values()), f"{final}")

        print("HOSTILE SUMMARY")
        for key, safe, detail in results:
            print(f"  {'SAFE' if safe else 'GAP '} {key}" + (f" [{detail}]" if not safe else ""))
        gaps = [key for key, safe, _ in results if not safe]
        assert not gaps, f"{len(gaps)} gap(s): {gaps}"


    with state_dump_on_failure([client, gw1, gw2, server4], extra=["ip netns exec nat64 jool instance display", "ip netns exec nat64 jool pool4 display", "ip netns exec clat jool_siit -i clat global display", "journalctl -b --no-pager -u clat-follow -u nat64-health -u nat64-jool -u nat64-beacon | tail -n 80"]):
        with subtest("boot and versions"):
            start_all()
            for machine in [client, trusted, outsider, server4]:
                machine.wait_for_unit("multi-user.target", timeout=300)
            server4.wait_until_succeeds("ss -tln | grep ':80 ' >/dev/null", timeout=60)
            for machine in [client, trusted, capped]:
                machine.wait_for_unit("clat.service", timeout=60)
                machine.wait_for_unit("clat-follow.service", timeout=60)
            for gateway in [G1, G2]:
                gateway_ready(gateway)
            print_versions(gw1, ["kernel", "jool", "ifstate", "nftables", "coredns"])
            print_versions(client, ["kernel", "jool", "ifstate"])
            for machine in [client, trusted, capped, outsider, gw1, gw2, server4]:
                machine.fail("systemctl --failed --no-legend | grep .")

        ${phases}_phases()

        with subtest("the end state: both gateways pass every assertion again"):
            for gateway in [G1, G2]:
                assert_gateway(gateway)

    print("NAT_GATEWAY${lib.optionalString (phases != "function") "_${lib.toUpper phases}"}_OK")
  '';
}
