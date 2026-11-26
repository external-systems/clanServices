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
      systemPackages = [
        pkgs.curl
        pkgs.dig
        pkgs.netcat
        pkgs.tcpdump
        pkgs.python3
        pkgs.conntrack-tools
      ];
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


    def counted(machine, chain, comment):
        """Packets that a rule of the gateway's own table counted."""
        rule = machine.succeed(f"nft list chain inet nat64 {chain} | grep '{comment}'")
        return first_int(r"counter packets (\d+)", rule)


    def refused_private(machine):
        return counted(machine, "forward", "nat64-private")


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


    def ruleset(machine, table=None, handles=True):
        """The ruleset with handles, without the rate limit's dynamic sets:
        their elements come and go with the clients' flows."""
        flags = "-j -a" if handles else "-j"
        listed = json.loads(machine.succeed(f"nft {flags} list ruleset" if table is None else f"nft {flags} list table inet {table}"))["nftables"]
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
            before = counted(machine, "forward", "nat64-undeclared")
            outsider.fail(cmd)
            dropped[shape] = counted(machine, "forward", "nat64-undeclared") - before
        # G24: nor the beacon
        for shape, flags in [("beacon udp", ""), ("beacon tcp", "+tcp")]:
            before = counted(machine, "input", "beacon-undeclared")
            outsider.fail(f"dig {flags} +short +time=2 +tries=1 AAAA ipv4only.arpa @{gateway.addr}")
            dropped[shape] = counted(machine, "input", "beacon-undeclared") - before
        print(f"FINDING {machine.name} dropped from the undeclared source: {dropped}")
        # two echo requests, one datagram, one query; TCP repeats its SYN
        assert dropped["ping"] == 2 and dropped["udp"] == 1 and dropped["beacon udp"] == 1, dropped
        assert 1 <= dropped["tcp"] <= 6 and 1 <= dropped["beacon tcp"] <= 6, dropped
        # G5: a private IPv4 destination is refused behind the translator
        for private in PRIVATE:
            before = refused_private(machine)
            client.fail(f"ping -c1 -W2 {embed(gateway, private)}")
            assert refused_private(machine) == before + 1, f"{machine.name} did not refuse {private}"
        # The translator is no way into the gateway's own IPv4 ports: a
        # /96 destination that embeds Jool's link address or the public
        # address is delivered to the gateway, and refused there
        for own in ["192.0.0.1", gateway.v4]:
            before = counted(machine, "input", "nat64-host")
            client.fail(http(embed(gateway, own), limit=3))
            assert counted(machine, "input", "nat64-host") > before, f"{machine.name} let {own} in through its translator"
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
            gw1.succeed("nft flush chain inet nat64 forward")
            try:
                outsider.succeed(f"ping -c2 -W2 {G1.server}")
            finally:
                gw1.succeed("systemctl restart nftables.service")
            before = counted(gw1, "forward", "nat64-undeclared")
            outsider.fail(f"ping -c2 -W1 {G1.server}")
            assert counted(gw1, "forward", "nat64-undeclared") == before + 2
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

        with subtest("§14.1 point 4: a rate limit per source, two tiers"):
            # gw2's `default` tier: 5 new flows a second, a burst of 10.
            # The client opens 40 at once and loses most; the trusted
            # client does the same and loses none.
            before = counted(gw2, "forward", "nat64-flows-default")
            got = int(client.succeed(f"python3 /etc/suite/shapes.py burst {G2.server} 9002 40").strip())
            dropped = counted(gw2, "forward", "nat64-flows-default") - before
            print(f"FINDING default tier: {got} of 40 connections at once answered, {dropped} SYNs dropped")
            # dropped SYNs are sent again after 1 s and 3 s, and the limit
            # lets 5 a second through: about 25 of 40 get through in 3 s
            assert got <= 32 and dropped >= 10, (got, dropped)
            before = counted(gw2, "forward", "nat64-flows-trusted")
            got = int(trusted.succeed(f"python3 /etc/suite/shapes.py burst {G2.server} 9002 40").strip())
            assert got == 40 and counted(gw2, "forward", "nat64-flows-trusted") == before, got
            # packets: 2000 datagrams a second for 3 s, against a burst of
            # 1000 and 500 a second: about 3500 of 6000 must go
            before = counted(gw2, "forward", "nat64-packets-default")
            sent = int(client.succeed(f"python3 /etc/suite/shapes.py flood {G2.server} 9001 2000 3").strip())
            dropped = counted(gw2, "forward", "nat64-packets-default") - before
            print(f"FINDING default tier: {dropped} of {sent} datagrams dropped (2000/s for 3 s against 500/s, burst 1000)")
            assert sent >= 5000 and dropped >= 1500, (sent, dropped)
            before = counted(gw2, "forward", "nat64-packets-trusted")
            sent = int(trusted.succeed(f"python3 /etc/suite/shapes.py flood {G2.server} 9001 2000 3").strip())
            assert sent >= 5000 and counted(gw2, "forward", "nat64-packets-trusted") == before, sent
            # a minute of quiet later nothing is held against the client
            client.wait_until_succeeds(http(G2.server), timeout=30)
            # gw1 keeps the default limits: the same burst passes there
            got = int(client.succeed(f"python3 /etc/suite/shapes.py burst {G1.server} 9002 40").strip())
            assert got == 40, got
            # §14.5 point 3: `capped` has a packet limit of its own (500 a
            # second, burst 1000) on gw1, where the tiers would let the
            # flood pass; its own meters count it, the tiers' do not
            before = {name: counted(gw1, "forward", name) for name in ["nat64-packets-client-capped", "nat64-packets-default", "nat64-packets-trusted"]}
            sent = int(capped.succeed(f"python3 /etc/suite/shapes.py flood {G1.server} 9001 2000 3").strip())
            grown = {name: counted(gw1, "forward", name) - value for name, value in before.items()}
            print(f"FINDING capped client: {grown} of {sent} datagrams dropped (2000/s for 3 s against its own 500/s, burst 1000)")
            assert sent >= 5000 and grown["nat64-packets-client-capped"] >= 1500, (sent, grown)
            assert grown["nat64-packets-default"] == grown["nat64-packets-trusted"] == 0, grown
            # its new flows keep the tier's numbers: a burst of 40 passes
            got = int(capped.succeed(f"python3 /etc/suite/shapes.py burst {G1.server} 9002 40").strip())
            assert got == 40, got
            print("NAT_GATEWAY_LIMITS_OK")

        with subtest("nftables ownership: a restart of the firewall or of Jool leaves other tables alone"):
            tables = sorted(gw2.succeed("nft list tables").strip().split("\n"))
            print(f"FINDING nftables tables on a gateway: {tables}")
            assert "table inet nat64" in tables, tables
            assert gw2.succeed("ip netns exec nat64 nft list ruleset").strip() == ""
            gw2.succeed("nft 'add table inet foreign; add chain inet foreign forward { type filter hook forward priority 10; }; add rule inet foreign forward ip6 daddr 2001:db8:ffff::/64 counter'")
            foreign = gw2.succeed("nft -a -s list table inet foreign")
            owned = ruleset(gw2, "nat64", handles=False)
            gw2.succeed("systemctl restart nftables.service")
            assert gw2.succeed("nft -a -s list table inet foreign") == foreign
            assert ruleset(gw2, "nat64", handles=False) == owned
            everything = ruleset(gw2)
            gw2.succeed("systemctl restart nat64-jool.service")
            assert ruleset(gw2) == everything
            gw2.succeed("nft delete table inet foreign")
            assert_gateway(G2)

        with subtest("G2: an IfState apply keeps the namespaces, the Jool instances and the units"):
            assert_ifstate_noop(gw2)
            gw2.wait_for_unit("nat64-jool.service", timeout=60)
            assert_gateway(G2)
            before = moves()
            gateway = clat_gateway()
            assert_ifstate_noop(client)
            client.wait_for_unit("clat.service", timeout=60)
            client.wait_for_unit("clat-follow.service", timeout=60)
            out = client.succeed(http("198.51.100.80")).strip()
            assert out == gateway.v4, out
            # the restarted follower keeps its gateway
            assert clat_gateway() is gateway and moves() == before
            print("NAT_GATEWAY_IFSTATE_OK")


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
                for target in every:
                    server4.succeed(f"ip addr add {target}/32 dev eth1")
            for gateway in [G1, G2]:
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
            machine.succeed("journalctl -b -u nat64-health -o cat --no-pager | tail -n 1 | grep 'resumed up' >/dev/null")
            state = json.loads(machine.succeed("cat /run/nat64-gateway/health.json"))
            print(f"FINDING the health state file: {state}")
            assert state["state"] == "up" and len(state["targets"]) == 3, state
            pid = machine.succeed("systemctl show -p MainPID --value nat64-health.service").strip()
            machine.succeed("systemctl kill -s KILL --kill-whom=main nat64-health.service")
            machine.wait_until_succeeds(f"pid=$(systemctl show -p MainPID --value nat64-health.service); test \"$pid\" -gt 0 && test \"$pid\" -ne {pid}", timeout=30)
            took = seconds_until(client, names_prefix(gateway), limit=60)
            assert took is not None and took < 20, took

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

    print("${
      if phases == "function"
      then "NAT_GATEWAY_OK"
      else "NAT_GATEWAY_FAILOVER_OK"
    }")
  '';
}
