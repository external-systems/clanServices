# Probes PR2 and PR7 (specs/gateway.md §6; G2, G4, G6, G23).
#
#   client   ─┐                      ┌─ gw1 (Jool in the host namespace) ─┐
#   outsider ─┼─ vlan 1, IPv6 only ──┤                                    ├─ vlan 2, IPv4 only ── server4
#             │   2001:db8:c::/64    └─ gw2 (Jool in its own namespace) ──┘    198.51.100.0/24
#
# Questions:
#   - Jool beside the nftables firewall: which hooks see the traffic, and
#     where can a source allowlist sit? (G2)
#   - Does a namespace of its own for Jool survive an IfState apply?
#   - Two off-path gateways with their own /96 and DNS64: how long does a
#     client take to move, and what happens to cached names and open
#     flows? (G4, G6)
#   - A CLAT (Jool SIIT) on an IPv6-only host for IPv4 literals. (G5)
#
# A probe records more than it asserts: lines that start with FINDING are
# the result. Only the basic NAT64 path is asserted.
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
  clientAddr = "2001:db8:c::10";
  clatAddr = "2001:db8:c::c1a7";
  clients = "{ ${clientAddr}, ${clatAddr} }";

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
  # Counters at every hook: which of them see NAT64 traffic?
  probeTable = pool: {
    family = "inet";
    content = lib.concatStrings (
      lib.mapAttrsToList (name: hook: ''
        chain ${name} {
          type filter hook ${hook};
          ip6 daddr ${pool} counter comment "${name} v6 to pool6"
          ip6 saddr ${pool} counter comment "${name} v6 from pool6"
          ip daddr 198.51.100.80 counter comment "${name} v4 to server"
          ip saddr 198.51.100.80 counter comment "${name} v4 from server"
        }
      '')
      hooks
    );
  };

  # CoreDNS binds one address: netif runs systemd-resolved on every
  # machine (N9), and its stub holds 127.0.0.53:53.
  corefile = address: pool: ''
    . {
      bind ${address}
      hosts {
        198.51.100.80 web.long.test fresh.long.test web.short.test
        192.0.0.170 ipv4only.arpa
        192.0.0.171 ipv4only.arpa
        2001:db8:c::66 six.long.test
        ttl 3600
      }
      rewrite ttl suffix short.test. 5
      dns64 {
        prefix ${pool}
      }
      errors
    }
  '';

  gateway = {
    pkgs,
    config,
    ...
  }: {
    imports = [base];
    virtualisation = {
      cores = 1;
      memorySize = 1024;
      vlans = [
        1
        2
      ];
    };
    boot = {
      extraModulePackages = [config.boot.kernelPackages.jool];
      kernel.sysctl = {
        "net.ipv4.conf.all.forwarding" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
        # CoreDNS binds one IPv6 address. Right after IfState adds it,
        # the address is still tentative (duplicate address detection)
        # and bind() fails with "cannot assign requested address".
        "net.ipv6.ip_nonlocal_bind" = 1;
      };
    };
    environment.systemPackages = [
      pkgs.jool-cli
      pkgs.curl
      pkgs.dig
      pkgs.tcpdump
      pkgs.conntrack-tools
    ];
    networking = {
      nftables.enable = true;
      firewall = {
        enable = true;
        # default deny between interfaces: does NAT64 still pass?
        filterForward = true;
        # DNS64 only for the declared clients
        extraInputRules = ''
          ip6 saddr ${clients} meta l4proto { tcp, udp } th dport 53 accept
        '';
      };
    };
    services.coredns.enable = true;
    systemd.services.coredns.after = ["ifstate.service"];
  };

  httpServer = pkgs:
    pkgs.writeText "server4.py" ''
      import http.server
      import socket
      import threading
      import time


      class Handler(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              if self.path == "/big":
                  body = b"x" * 2000000
              else:
                  body = (self.client_address[0] + "\n").encode()
              self.send_response(200)
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def log_message(self, *args):
              pass


      def tick(conn):
          try:
              while True:
                  conn.sendall(b"tick\n")
                  time.sleep(1)
          except OSError:
              pass


      def ticker():
          sock = socket.socket()
          sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
          sock.bind(("0.0.0.0", 9000))
          sock.listen()
          while True:
              conn, _ = sock.accept()
              threading.Thread(target=tick, args=(conn,), daemon=True).start()


      threading.Thread(target=ticker, daemon=True).start()
      http.server.ThreadingHTTPServer(("0.0.0.0", 80), Handler).serve_forever()
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
      nameservers = [
        "2001:db8:c::1"
        "2001:db8:c::2"
      ];
      ifstate.settings = {
        interfaces.eth1 = phys ["${address}/64"];
        routing.routes = poolRoutes;
      };
    };
  };
in {
  name = "probe-nat64";

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
      environment.systemPackages = [pkgs.jool-cli];
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
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          modprobe jool_siit
          ip netns exec clat sysctl -w net.ipv4.conf.all.forwarding=1 net.ipv6.conf.all.forwarding=1
          ip netns exec clat jool_siit instance add clat --netfilter --pool6 ${pool1}
          ip netns exec clat jool_siit -i clat eamt add ${clatAddr} 192.0.0.1
          # an IPv4 packet grows by 20 bytes when it becomes IPv6
          ip route replace default via 192.0.0.2 dev clat0 mtu 1480
        '';
      };
      # PR7: the CLAT follows a live gateway. Each nameserver is asked for
      # ipv4only.arpa (RFC 7050); the first answer names that gateway's
      # /96, and a ping through it shows that it translates.
      systemd.services.clat-follow = {
        wantedBy = ["multi-user.target"];
        after = ["clat.service"];
        requires = ["clat.service"];
        path = [
          pkgs.iproute2
          pkgs.jool-cli
          pkgs.dig
          pkgs.iputils
          pkgs.gnused
          pkgs.gnugrep
          pkgs.coreutils
        ];
        serviceConfig.Restart = "always";
        script = ''
          current=${pool1}
          while sleep 2; do
            for ns in 2001:db8:c::1 2001:db8:c::2; do
              answer=$(dig +short +time=1 +tries=1 AAAA ipv4only.arpa @"$ns" | grep -i 'c000:aa$' | head -1) || true
              [ -n "$answer" ] || continue
              prefix="$(echo "$answer" | sed 's/c000:aa$//')/96"
              # the server's address inside that prefix must answer
              ping -c1 -W1 "$(echo "$answer" | sed 's/c000:aa$/c633:6450/')" >/dev/null 2>&1 || continue
              if [ "$prefix" != "$current" ]; then
                ip netns exec clat jool_siit -i clat global update pool6 "$prefix"
                echo "clat-follow: pool6 $current -> $prefix (nameserver $ns)"
                current=$prefix
              fi
              break
            done
          done
        '';
      };
    };

    outsider = v6host "2001:db8:c::66";

    # Jool in the host namespace (the stock NixOS module). The allowlist
    # sits before Jool's hook (priority -75), in a table of its own.
    gw1 = {
      imports = [gateway];
      networking = {
        jool = {
          enable = true;
          nat64.default.global.pool6 = pool1;
        };
        nftables.tables = {
          probe = probeTable pool1;
          nat64acl = {
            family = "inet";
            content = ''
              chain prerouting {
                type filter hook prerouting priority -300;
                ip6 daddr ${pool1} ip6 saddr != ${clients} counter drop
              }
            '';
          };
        };
        ifstate.settings = {
          interfaces = {
            eth1 = phys ["2001:db8:c::1/64"];
            eth2 = phys ["198.51.100.1/24"];
          };
          routing.routes = [
            {
              to = "${clatAddr}/128";
              via = clientAddr;
            }
          ];
        };
      };
      services.coredns.config = corefile "2001:db8:c::1" pool1;
    };

    # Jool in a namespace of its own, declared in IfState. The host
    # forwards to it, so the ordinary forward chain filters, and the host
    # masquerades Jool's private IPv4 address to the public one.
    gw2 = {pkgs, ...}: {
      imports = [gateway];
      networking = {
        nftables.tables.probe = probeTable pool2;
        firewall.extraForwardRules = ''
          iifname "eth1" oifname "j0" ip6 daddr ${pool2} ip6 saddr ${clients} accept
          iifname "j0" oifname "eth2" accept
        '';
        nat = {
          enable = true;
          internalInterfaces = ["j0"];
          externalInterface = "eth2";
        };
        ifstate.settings = {
          interfaces = {
            eth1 = phys ["2001:db8:c::2/64"];
            eth2 = phys ["198.51.100.2/24"];
            j0 = {
              addresses = [
                "10.64.0.1/30"
                "fd64::1/64"
              ];
              link = {
                kind = "veth";
                state = "up";
                peer = "j1";
                peer_netns = "nat64";
              };
            };
          };
          namespaces.nat64 = {
            interfaces.j1 = {
              addresses = [
                "10.64.0.2/30"
                "fd64::2/64"
              ];
              link = {
                kind = "veth";
                state = "up";
                peer = "j0";
                peer_netns = null;
              };
            };
            routing.routes = [
              {
                to = "::/0";
                via = "fd64::1";
              }
              {
                to = "0.0.0.0/0";
                via = "10.64.0.1";
              }
            ];
          };
          routing.routes = [
            {
              to = pool2;
              via = "fd64::2";
            }
            {
              to = "${clatAddr}/128";
              via = clientAddr;
            }
          ];
        };
      };
      services.coredns.config = corefile "2001:db8:c::2" pool2;
      systemd.services.jool-netns = {
        wantedBy = ["multi-user.target"];
        after = ["ifstate.service"];
        requires = ["ifstate.service"];
        path = [
          pkgs.iproute2
          pkgs.kmod
          pkgs.jool-cli
          pkgs.procps
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          modprobe jool
          ip netns exec nat64 sysctl -w net.ipv4.conf.all.forwarding=1 net.ipv6.conf.all.forwarding=1
          ip netns exec nat64 jool instance add default --netfilter --pool6 ${pool2}
          # Jool refuses a pool4 range that overlaps the namespace's
          # ephemeral ports. Nothing opens a socket in this namespace, so
          # its ephemeral range shrinks and Jool gets the rest.
          ip netns exec nat64 sysctl -w net.ipv4.ip_local_port_range="1024 1099"
          for proto in tcp udp icmp; do
            ip netns exec nat64 jool pool4 add 10.64.0.2 1100-65535 --$proto
          done
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
        ifstate.settings.interfaces.eth1 = phys ["198.51.100.80/24"];
      };
      systemd.services.server4 = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${httpServer pkgs}";
      };
    };
  };

  testScript = ''
    import time

    S1 = "${server1}"
    S2 = "${server2}"

    def observe(label, machine, cmd):
        status, out = machine.execute(cmd + " 2>&1")
        print(f"FINDING {label}: rc={status}\n{out.rstrip()}")
        return status, out.strip()

    def seconds_until(machine, cmd, limit=120):
        start = time.time()
        while time.time() - start < limit:
            status, out = machine.execute(cmd + " 2>/dev/null")
            if status == 0:
                return round(time.time() - start, 1), out.strip()
            time.sleep(0.5)
        return None, ""

    start_all()
    for machine in [client, outsider, gw1, gw2, server4]:
        machine.wait_for_unit("multi-user.target", timeout=300)
    server4.wait_until_succeeds("ss -tln | grep ':80 ' >/dev/null", timeout=60)
    gw1.wait_for_unit("jool-nat64-default.service", timeout=60)
    gw2.wait_for_unit("jool-netns.service", timeout=60)
    client.wait_for_unit("clat.service", timeout=60)
    for gw in [gw1, gw2]:
        gw.wait_for_unit("coredns.service", timeout=60)
        gw.wait_until_succeeds("ss -uln | grep ':53 ' >/dev/null", timeout=60)

    with subtest("NAT64 through each gateway"):
        client.wait_until_succeeds("ping -c1 -W2 2001:db8:c::1 && ping -c1 -W2 2001:db8:c::2", timeout=60)
        out = client.wait_until_succeeds(f"curl -sg --max-time 5 'http://[{S1}]/'", timeout=60).strip()
        assert out == "198.51.100.1", out
        out = client.wait_until_succeeds(f"curl -sg --max-time 5 'http://[{S2}]/'", timeout=60).strip()
        assert out == "198.51.100.2", out
        observe("ping through gw1", client, f"ping -c2 -W2 {S1}")
        observe("ping through gw2", client, f"ping -c2 -W2 {S2}")
        observe("2 MB through gw1", client, f"curl -sg --max-time 30 -o /dev/null -w '%{{size_download}} bytes %{{time_total}}s' 'http://[{S1}]/big'")
        observe("2 MB through gw2", client, f"curl -sg --max-time 30 -o /dev/null -w '%{{size_download}} bytes %{{time_total}}s' 'http://[{S2}]/big'")
        print("PROBE_NAT64_BASIC_OK")

    with subtest("which nftables hooks see NAT64 traffic"):
        observe("gw1 (host namespace Jool) hook counters", gw1, "nft list table inet probe | grep counter")
        observe("gw2 (namespace Jool) hook counters", gw2, "nft list table inet probe | grep counter")
        observe("gw1 forward chain of the NixOS firewall", gw1, "nft list chain inet nixos-fw forward; nft list chain inet nixos-fw forward-allow")
        observe("gw1 conntrack", gw1, "conntrack -L 2>&1 | head -20")
        observe("gw2 conntrack", gw2, "conntrack -L 2>&1 | head -20")

    with subtest("Jool facts"):
        observe("gw1 jool global", gw1, "jool global display")
        observe("gw1 jool pool4", gw1, "jool pool4 display")
        observe("gw1 jool stats", gw1, "jool stats display")
        observe("gw1 local ports", gw1, "sysctl net.ipv4.ip_local_port_range net.ipv4.ip_local_reserved_ports")
        observe("gw2 jool pool4", gw2, "ip netns exec nat64 jool pool4 display")
        observe("gw2 jool in the host namespace", gw2, "jool instance display")
        observe("gw1 own IPv4", gw1, "curl -s --max-time 5 http://198.51.100.80/")
        observe("gw2 own IPv4", gw2, "curl -s --max-time 5 http://198.51.100.80/")

    with subtest("the allowlist: an undeclared source"):
        observe("outsider through gw1 (raw allowlist)", outsider, f"curl -sg --max-time 5 'http://[{S1}]/'")
        observe("outsider through gw2 (forward chain)", outsider, f"curl -sg --max-time 5 'http://[{S2}]/'")
        observe("outsider DNS64 on gw1", outsider, "dig +time=2 +tries=1 @2001:db8:c::1 web.long.test AAAA +short")
        observe("gw1 allowlist counter", gw1, "nft list table inet nat64acl | grep counter")
        # without the raw rule, the NixOS firewall alone does not stop it
        gw1.succeed("nft delete table inet nat64acl")
        observe("outsider through gw1 WITHOUT the raw allowlist (forward policy is drop)", outsider, f"curl -sg --max-time 5 'http://[{S1}]/'")
        gw1.succeed("systemctl restart nftables.service")
        observe("outsider through gw1, allowlist restored", outsider, f"curl -sg --max-time 5 'http://[{S1}]/'")
        observe("client through gw1 after nftables restart", client, f"curl -sg --max-time 5 'http://[{S1}]/'")

    with subtest("an IfState apply keeps the Jool namespace"):
        observe("gw2 ifstatecli check", gw2, "ifstatecli check")
        gw2.succeed("systemctl restart ifstate.service")
        observe("gw2 instance after apply", gw2, "ip netns exec nat64 jool instance display")
        observe("client through gw2 after apply", client, f"curl -sg --max-time 5 'http://[{S2}]/'")
        observe("client ifstatecli check", client, "ifstatecli check")
        client.succeed("systemctl restart ifstate.service")
        observe("client CLAT instance after apply", client, "ip netns exec clat jool_siit instance display; ip netns exec clat jool_siit -i clat eamt display; ip -4 route")

    with subtest("DNS64"):
        observe("AAAA long from gw1", client, "dig @2001:db8:c::1 web.long.test AAAA +noall +answer")
        observe("AAAA short from gw1", client, "dig @2001:db8:c::1 web.short.test AAAA +noall +answer")
        observe("AAAA of a name with a real AAAA", client, "dig @2001:db8:c::1 six.long.test AAAA +noall +answer")
        observe("AAAA long from gw2", client, "dig @2001:db8:c::2 web.long.test AAAA +noall +answer")
        observe("client resolved", client, "resolvectl status | head -20")
        observe("by name", client, "curl -s --max-time 10 http://web.long.test/")
        observe("by name, short", client, "curl -s --max-time 10 http://web.short.test/")

    with subtest("CLAT: an IPv4 literal from an IPv6-only host"):
        observe("client addresses", client, "ip -br addr; ip -4 route; ip -6 route")
        observe("IPv4 literal", client, "curl -s --max-time 10 http://198.51.100.80/")
        observe("IPv4 ping", client, "ping -c2 -W2 198.51.100.80")
        observe("2 MB over the CLAT", client, "curl -s --max-time 30 -o /dev/null -w '%{size_download} bytes %{time_total}s' http://198.51.100.80/big")
        observe("CLAT stats", client, "ip netns exec clat jool_siit -i clat stats display")

    with subtest("gateway failure"):
        observe("ipv4only.arpa from each gateway", client, "dig +short AAAA ipv4only.arpa @2001:db8:c::1; dig +short AAAA ipv4only.arpa @2001:db8:c::2")
        observe("the follower before the failure", client, "systemctl is-active clat-follow; journalctl -u clat-follow --no-pager | tail -3")
        client.succeed(f"systemd-run --unit=stream sh -c '/run/current-system/sw/bin/nc {S1} 9000 > /tmp/stream'")
        client.wait_until_succeeds("test $(wc -l < /tmp/stream) -ge 3", timeout=30)
        client.succeed("curl -s --max-time 10 http://web.long.test/ && curl -s --max-time 10 http://web.short.test/")
        gw1.crash()
        crashed = time.time()
        took, out = seconds_until(client, "curl -s --max-time 5 http://fresh.long.test/")
        print(f"FINDING a name not in the cache works after {took}s, answer {out}")
        took, out = seconds_until(client, "curl -s --max-time 5 http://web.short.test/")
        print(f"FINDING a cached name with a 5 s TTL works {took}s later ({round(time.time() - crashed, 1)}s after the crash), answer {out}")
        observe("a cached name with a 3600 s TTL", client, "curl -s --max-time 5 http://web.long.test/")
        observe("the same after resolvectl flush-caches", client, "resolvectl flush-caches; curl -s --max-time 10 http://web.long.test/")
        before = client.succeed("wc -l < /tmp/stream").strip()
        time.sleep(20)
        after = client.succeed("wc -l < /tmp/stream").strip()
        observe(f"open flow: {before} lines, 20 s later {after} lines; the client's connection", client, "systemctl is-active stream.service; ss -tni | grep -A1 ':9000'")
        took, out = seconds_until(client, "curl -s --max-time 3 http://198.51.100.80/")
        print(f"FINDING an IPv4 literal works again {took}s later ({round(time.time() - crashed, 1)}s after the crash) with the CLAT follower, answer {out}")
        observe("the follower's log", client, "journalctl -u clat-follow --no-pager | tail -5; ip netns exec clat jool_siit -i clat global display | grep pool6")
        observe("client resolved after failover", client, "resolvectl status | head -12")

    print("PROBE_NAT64_OK")
  '';
}
