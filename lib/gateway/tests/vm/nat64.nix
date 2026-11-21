# gateway-nat64: two off-path NAT64 gateways, DNS64 and a client's CLAT
# (specs/gateway.md G2, G3, G4, G5, G6, G23; §10.1, §10.9, §12.2).
#
#   client   ─┐                      ┌─ gw1 ─┐
#   outsider ─┼─ vlan 1, IPv6 only ──┤       ├─ vlan 2, IPv4 only ── server4
#             │   2001:db8:c::/64    └─ gw2 ─┘    198.51.100.0/24
#
# Both gateways are `nat64-gateway.nix`: Jool in a namespace of its own
# that IfState declares, the forward chain as the source allowlist, a /96
# and a DNS64 each. The suite pins:
#   - G2: the forward chain filters the translator; Jool in the host
#     namespace would bypass it (shown on gw1 with a second instance);
#     the Jool unit is idempotent across an IfState apply and a reboot;
#     Jool's pool4 limit; who owns which nftables table.
#   - G3/G4: DNS64 only for the allowlist, synthesis only for names
#     without an AAAA record, the TTL cap.
#   - G5: a /96 destination that embeds a private IPv4 address is refused.
#   - G6: a dead gateway stalls its open flows without a reset, and new
#     flows go through the other one within a bound.
#   - G23: the CLAT, and its follower with hysteresis: it stays on a
#     lossy gateway, leaves a dead one and one that withdrew
#     `ipv4only.arpa` (the gateway's own health check), and never moves
#     back while the current gateway is healthy.
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
  pool2 = "2001:db8:a2:0:64::/96";
  # 198.51.100.80 inside each pool
  server1 = "2001:db8:a1:0:64:0:c633:6450";
  server2 = "2001:db8:a2:0:64:0:c633:6450";
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
        198.51.100.80 web.long.test fresh.long.test web.short.test
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

  # The CLAT follower moves after this many failed checks in a row. A
  # check is one query with a 1 s timeout. With 30 % loss a run of 8 has
  # a chance of 0.3^8 = 0.007 %; a dead gateway costs 8 to 12 s.
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
  '';

  v6host = address: {pkgs, ...}: {
    imports = [base];
    virtualisation = {
      cores = 1;
      memorySize = 1024;
      vlans = [1];
    };
    environment.systemPackages = [
      pkgs.curl
      pkgs.dig
      pkgs.netcat
      pkgs.tcpdump
    ];
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
        systemPackages = [
          pkgs.jool-cli
          pkgs.python3
        ];
        etc."suite/shapes.py".text = shapes;
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
      # (RFC 7050) with an address that names its /96: the gateway
      # withdraws the record when its own check through the translator
      # fails, so the client needs no target on the internet. The
      # follower stays on its gateway while that one is healthy, and
      # moves only after `followNeed` failed checks in a row.
      systemd.services.clat-follow = {
        wantedBy = ["multi-user.target"];
        after = ["clat.service"];
        requires = ["clat.service"];
        path = [
          pkgs.iproute2
          pkgs.jool-cli
          pkgs.dig
          pkgs.gnugrep
          pkgs.coreutils
        ];
        serviceConfig = {
          Restart = "always";
          # the gateway in use survives a restart of the unit
          RuntimeDirectory = "clat-follow";
          RuntimeDirectoryPreserve = true;
        };
        script = ''
          # prints the /96 that a nameserver names, or fails
          prefix_of() {
            answer=$(dig +short +time=1 +tries=1 AAAA ipv4only.arpa @"$1" | grep -E '^[0-9a-f:]+:c000:aa$' | head -n1)
            [ -n "$answer" ] || return 1
            # 2001:db8:a2:0:64:0:c000:aa -> 2001:db8:a2:0:64:0::/96
            echo "''${answer%c000:aa}:/96"
          }
          # the CLAT starts on the first gateway's /96 (clat.service)
          current=${builtins.head nameservers}
          [ ! -s /run/clat-follow/current ] || current=$(cat /run/clat-follow/current)
          fails=0
          while :; do
            if prefix_of "$current" >/dev/null; then
              fails=0
              sleep 2
              continue
            fi
            fails=$((fails + 1))
            echo "clat-follow: check $fails/${toString followNeed} of $current failed"
            if [ "$fails" -ge ${toString followNeed} ]; then
              for ns in ${toString nameservers}; do
                [ "$ns" != "$current" ] || continue
                if prefix=$(prefix_of "$ns"); then
                  ip netns exec clat jool_siit -i clat global update pool6 "$prefix"
                  echo "clat-follow: pool6 -> $prefix (nameserver $ns, was $current)"
                  current=$ns
                  echo "$current" >/run/clat-follow/current
                  fails=0
                  break
                fi
              done
            fi
            sleep 0.5
          done
        '';
      };
    };

    outsider = v6host "2001:db8:c::66";

    gw1 = gateway "1" pool1 server1;
    gw2 = gateway "2" pool2 server2;

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
        ifstate.settings.interfaces.eth1 = phys ["198.51.100.80/24"];
      };
      systemd.services.server4 = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${httpServer pkgs}";
      };
    };
  };

  testScript = ''
    import re
    import time

    ${import ../../../../tests/suite-lib.nix}
    ${import ../../../../tests/ifstate-noop.nix}

    class Gateway:
        def __init__(self, machine, addr, prefix, v4, server):
            self.machine, self.addr, self.prefix, self.v4, self.server = machine, addr, prefix, v4, server


    G1 = Gateway(gw1, "2001:db8:c::1", "2001:db8:a1:0:64:0:", "198.51.100.1", "${server1}")
    G2 = Gateway(gw2, "2001:db8:c::2", "2001:db8:a2:0:64:0:", "198.51.100.2", "${server2}")
    SERVER_HOST = "${serverHost}"
    PRIVATE = ["10.0.0.1", "100.64.0.1", "169.254.0.1", "172.16.0.1", "192.168.1.1"]
    NEED = ${toString followNeed}


    def first_int(pattern, text):
        found = re.search(pattern, text)
        assert found is not None, f"{pattern} not in {text}"
        return int(found.group(1))


    def embed(gateway, ipv4):
        a, b, c, d = (int(part) for part in ipv4.split("."))
        return f"{gateway.prefix}{a << 8 | b:x}:{c << 8 | d:x}"


    def other(gateway):
        return G2 if gateway is G1 else G1


    def http(target, path="", limit=5, family=""):
        host = f"[{target}]" if ":" in target else target
        return f"curl -sg {family} --max-time {limit} 'http://{host}/{path}'"


    def http6(name, path="", limit=5):
        """By name over IPv6 only: DNS64 and NAT64, never the A record and the CLAT."""
        return http(name, path, limit, family="-6")


    def hook(machine, comment):
        table = machine.succeed("nft list table inet suite")
        return first_int(rf'counter packets (\d+) bytes \d+ comment "{comment}"', table)


    def refused_private(machine):
        rule = machine.succeed("nft list chain inet nixos-fw forward-allow | grep nat64-private")
        return first_int(r"counter packets (\d+)", rule)


    def names_prefix(gateway):
        return f"dig +short +time=1 +tries=1 AAAA ipv4only.arpa @{gateway.addr} | grep -i '^{gateway.prefix}c000:aa$' >/dev/null"


    def clat_gateway():
        pool6 = client.succeed("ip netns exec clat jool_siit -i clat global display | grep pool6").strip()
        if "2001:db8:a1:" in pool6:
            return G1
        assert "2001:db8:a2:" in pool6, pool6
        return G2


    def clat_on(gateway):
        tag = gateway.prefix.split(":")[2]
        return f"ip netns exec clat jool_siit -i clat global display | grep 'pool6: 2001:db8:{tag}:' >/dev/null"


    def moves():
        return int(client.succeed("journalctl -b -u clat-follow -o cat --no-pager | grep -c 'clat-follow: pool6 ->' || true").strip())


    def resolver():
        return client.succeed("resolvectl status | grep 'Current DNS Server'").split()[-1]


    def gateway_ready(gateway):
        machine = gateway.machine
        machine.wait_for_unit("multi-user.target", timeout=300)
        for unit in ["jool-netns.service", "coredns.service", "nat64-health.service", "nftables.service"]:
            machine.wait_for_unit(unit, timeout=60)
        client.wait_until_succeeds(f"ping -c1 -W2 {gateway.addr}", timeout=60)
        # the health check has answered through the translator
        client.wait_until_succeeds(names_prefix(gateway), timeout=60)


    def assert_gateway(gateway):
        """What one gateway must do, whatever happened to it before."""
        machine, server = gateway.machine, gateway.server
        # G2: the Jool instance and its pool4 live in the namespace only
        machine.succeed("ip netns exec nat64 jool -i default global display | grep 'pool6: 2001:db8:' >/dev/null")
        machine.fail("jool -i default global display")
        for proto in ["tcp", "udp", "icmp"]:
            pool4 = machine.succeed(f"ip netns exec nat64 jool pool4 display --{proto} --csv")
            assert pool4.count("10.64.0.2,1100,65535") == 1, pool4
        # a declared source is translated, behind the gateway's own IPv4
        out = client.succeed(http(server)).strip()
        assert out == gateway.v4, out
        client.succeed(f"ping -c2 -W2 {server}")
        # G4: DNS64 inside the gateway's /96
        out = client.succeed(f"dig +short +time=2 +tries=1 AAAA web.long.test @{gateway.addr}").strip()
        assert out == server, out
        # G2, G4: an undeclared source reaches the gateway, but neither
        # the translator nor the DNS64 listener
        outsider.succeed(f"ping -c1 -W2 {gateway.addr}")
        outsider.fail(http(server, limit=3))
        outsider.fail(f"dig +short +time=2 +tries=1 AAAA web.long.test @{gateway.addr}")
        # G5: a private IPv4 destination is refused behind the translator
        for private in PRIVATE:
            before = refused_private(machine)
            client.fail(f"ping -c1 -W2 {embed(gateway, private)}")
            assert refused_private(machine) > before, f"{machine.name} did not refuse {private}"
        # the gateway's own IPv4 traffic does not pass the translator
        out = machine.succeed(http("198.51.100.80")).strip()
        assert out == gateway.v4, out


    with state_dump_on_failure([client, gw1, gw2, server4], extra=["ip netns exec nat64 jool instance display", "ip netns exec nat64 jool pool4 display", "journalctl -b --no-pager -u clat-follow -u nat64-health -u jool-netns -u coredns | tail -n 60"]):
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

        with subtest("G2, G4, G5: each gateway translates declared sources only"):
            for gateway in [G1, G2]:
                assert_gateway(gateway)
                size = client.succeed(http(gateway.server, "big", 30) + " -o /dev/null -w '%{size_download}'").strip()
                assert size == "2000000", size
            print("GATEWAY_NAT64_BASIC_OK")

        with subtest("G2: the forward chain and conntrack see a namespaced Jool"):
            for comment in ["pre_filter v6 to pool6", "forward v6 to pool6", "post v6 to pool6", "forward v4 to server", "post v4 to server"]:
                count = hook(gw2, comment)
                print(f"FINDING gw2 hook counter '{comment}': {count} packets")
                assert count > 0, comment
            # the translator is another machine to the host: nothing is input
            assert hook(gw2, "input v6 to pool6") == 0
            client.succeed(http(G2.server))
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
                assert answer == [gateway.prefix + "c000:aa", gateway.prefix + "c000:ab"], answer
            # by name, through systemd-resolved and whichever gateway it uses
            used = G1 if resolver() == G1.addr else G2
            for name in ["web.long.test", "web.short.test"]:
                out = client.succeed(http6(name)).strip()
                assert out == used.v4, f"{name}: {out}"

        with subtest("G23: the CLAT carries IPv4 literals from an IPv6-only host"):
            gateway = clat_gateway()
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

            upload = "test \"$(head -c 300000 /dev/zero | curl -sg --max-time 15 -H 'Expect:' --data-binary @- 'http://{}/')\" = 300000"
            for path, target in [("nat64", server), ("clat", "198.51.100.80")]:
                shapes[f"{path}: ping with 1400 bytes"] = works(f"ping -c2 -W2 -s 1400 {target}")
                shapes[f"{path}: ping with 3000 bytes (fragments)"] = works(f"ping -c2 -W2 -s 3000 {target}")
                shapes[f"{path}: UDP datagram of 3000 bytes echoed (fragments)"] = works(f"python3 /etc/suite/shapes.py udp {target} 9001 3000")
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
                host = f"[{server}]"
                shapes["nat64: TCP upload across a 1400 byte hop"] = works(upload.format(host))
                shapes["nat64: path MTU the client learned"] = learned(f"ip -6 route get {server}")
                shapes["nat64: don't-fragment ping above the path MTU fails"] = not works(f"ping -c1 -W2 -M do -s 1440 {server}")
                shapes["nat64: don't-fragment ping of 1420 bytes passes"] = works(f"ping -c1 -W2 -M do -s 1372 {server}")
                shapes["clat: TCP upload across a 1400 byte hop"] = works(upload.format("198.51.100.80"))
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
            # suite: this suite's counters. nixos-fw and nixos-nat: the
            # NixOS firewall and masquerade, both applied by nftables.service.
            assert tables == ["table inet nixos-fw", "table inet suite", "table ip nixos-nat"], tables
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
            owned = gw2.succeed("nft -s list table inet nixos-fw; nft -s list table ip nixos-nat; nft -s list table inet suite")
            gw2.succeed("systemctl restart nftables.service")
            assert gw2.succeed("nft -a -s list table inet foreign") == foreign
            assert gw2.succeed("nft -s list table inet nixos-fw; nft -s list table ip nixos-nat; nft -s list table inet suite") == owned
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
                holds_for(client, f"test \"$(journalctl -b -u clat-follow -o cat --no-pager | grep -c 'clat-follow: pool6 ->')\" -eq {before} && {clat_on(first)}", 40, interval=2)
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

        with subtest("G6, G23: a gateway dies; its open flow stalls for 20 s without a reset, new flows use the other one"):
            dead, live = first, second
            client.succeed(f"systemd-run --unit=stream sh -c '/run/current-system/sw/bin/nc {dead.server} 9000 > /tmp/stream'")
            client.wait_until_succeeds("test $(wc -l < /tmp/stream) -ge 3", timeout=30)
            client.succeed(http("web.long.test") + " && " + http("web.short.test"))
            before = moves()
            dead.machine.crash()
            crashed = time.time()
            lines = int(client.succeed("wc -l < /tmp/stream"))
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
            # G6: nothing resets the flow through the dead gateway
            holds_for(client, f"test $(wc -l < /tmp/stream) -eq {lines} && systemctl is-active stream.service >/dev/null && ss -tn state established | grep ':9000' >/dev/null", 20)
            observe("the stalled flow", client, "ss -tni | grep -A1 ':9000'")
            client.succeed("systemctl stop stream.service")
            print("GATEWAY_NAT64_FAILOVER_OK")

        with subtest("G2, G23: the gateway boots again and translates; the follower stays where it is for 10 s"):
            before = moves()
            first.machine.start()
            gateway_ready(first)
            assert_gateway(first)
            holds_for(client, f"test \"$(journalctl -b -u clat-follow -o cat --no-pager | grep -c 'clat-follow: pool6 ->')\" -eq {before} && {clat_on(second)}", 10, interval=2)

        with subtest("§12.2 health target: a gateway without IPv4 upstream withdraws ipv4only.arpa and the CLAT leaves it"):
            sick, healthy = second, first
            assert clat_gateway() is sick and resolver() == sick.addr
            before = moves()
            sick.machine.succeed("tc qdisc add dev eth2 root netem loss 100%")
            cut = time.time()
            try:
                took = seconds_until(client, "! " + names_prefix(sick), limit=60)
                print(f"FINDING the gateway withdrew ipv4only.arpa {took} s after its IPv4 upstream died")
                assert took is not None and took < 20, took
                # it is alive on IPv6, and its DNS still answers
                client.succeed(f"ping -c1 -W2 {sick.addr}")
                out = client.succeed(f"dig +short +time=2 +tries=1 AAAA six.long.test @{sick.addr}").strip()
                assert out == "2001:db8:c::66", out
                took = seconds_until(client, http("198.51.100.80", limit=2), limit=90, wanted=healthy.v4)
                since = round(time.time() - cut, 1)
                print(f"FINDING an IPv4 literal works through the healthy gateway {since} s after the upstream died")
                assert took is not None and since < 60, since
                assert clat_gateway() is healthy and moves() == before + 1
                # FINDING contradicts specs/gateway.md §12.2 ("the client
                # needs no internet target"): that holds for the CLAT only.
                # The sick gateway's DNS64 still answers, so systemd-resolved
                # stays on it and names resolve into the /96 that is dead.
                assert resolver() == sick.addr
                out = client.succeed(f"dig +short +time=2 +tries=1 AAAA fresh.long.test @{sick.addr}").strip()
                assert out == sick.server, out
                client.fail(http6("fresh.long.test"))
                # A host with a CLAT still gets there: the application
                # falls back to the A record, which leaves through the
                # CLAT and the healthy gateway.
                out = client.succeed(http("fresh.long.test")).strip()
                assert out == healthy.v4, out
            finally:
                sick.machine.succeed("tc qdisc del dev eth2 root")
            took = seconds_until(client, names_prefix(sick), limit=60)
            print(f"FINDING the gateway served ipv4only.arpa again {took} s after its upstream returned")
            assert took is not None and took < 20, took
            client.wait_until_succeeds(http6("fresh.long.test"), timeout=30)
            # the follower prefers its current gateway while that is healthy
            before = moves()
            holds_for(client, f"test \"$(journalctl -b -u clat-follow -o cat --no-pager | grep -c 'clat-follow: pool6 ->')\" -eq {before} && {clat_on(healthy)}", 10, interval=2)

        with subtest("the end state: both gateways pass every assertion again"):
            for gateway in [G1, G2]:
                assert_gateway(gateway)
            observe("the follower's log", client, "journalctl -b -u clat-follow -o cat --no-pager | grep 'pool6 ->'")

    print("GATEWAY_NAT64_OK")
  '';
}
