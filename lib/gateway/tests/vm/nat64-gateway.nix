# A NAT64 gateway for VM suites, built as specs/gateway.md G2 says: Jool in
# a namespace of its own that IfState declares, the host's forward chain
# as the allowlist, and a masquerade to the public IPv4 address.
#
# eth1 faces the IPv6 clients, eth2 the IPv4 internet.
{
  base,
  pool,
  # nftables expression for the sources that may use the gateway
  allow,
  inside,
  outside,
  routes ? [],
  corefile ? null,
  # Health target (specs/gateway.md §12.2): an address inside `pool`
  # (the /96 plus an IPv4 address upstream). The gateway pings it through
  # its own translator and serves `ipv4only.arpa` only while it answers,
  # so a client's CLAT follower needs no internet target of its own. The
  # Corefile reads the records with `hosts /run/nat64-health/ipv4only.hosts`.
  healthTarget ? null,
}: {
  pkgs,
  config,
  lib,
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
      "net.ipv6.ip_nonlocal_bind" = 1;
    };
  };
  environment.systemPackages = [
    pkgs.jool-cli
    pkgs.tcpdump
    pkgs.conntrack-tools
    pkgs.curl
    pkgs.dig
  ];
  networking = {
    nftables.enable = true;
    firewall = {
      enable = true;
      filterForward = true;
      extraForwardRules = ''
        iifname != "eth2" oifname "j0" ip6 daddr ${pool} ip6 saddr ${allow} accept
        # a /96 destination that embeds a private IPv4 address is not the
        # internet (specs/gateway.md G5): refuse it after translation
        iifname "j0" ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } counter reject with icmp type net-prohibited comment "nat64-private"
        iifname "j0" oifname "eth2" accept
      '';
      extraInputRules = ''
        ip6 saddr ${allow} meta l4proto { tcp, udp } th dport 53 accept
      '';
    };
    nat = {
      enable = true;
      internalInterfaces = ["j0"];
      externalInterface = "eth2";
    };
    ifstate.settings = {
      interfaces = {
        eth1 = {
          addresses = inside;
          link = {
            kind = "physical";
            state = "up";
          };
        };
        eth2 = {
          addresses = outside;
          link = {
            kind = "physical";
            state = "up";
          };
        };
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
      routing.routes =
        [
          {
            to = pool;
            via = "fd64::2";
          }
        ]
        ++ routes;
    };
  };
  services.coredns = lib.mkIf (corefile != null) {
    enable = true;
    config = corefile;
  };
  systemd.services = {
    coredns = lib.mkIf (corefile != null) {after = ["ifstate.service"];};
    # Three failed pings in a row withdraw the records; one answer
    # restores them. CoreDNS rereads the file (`reload` of `hosts`).
    nat64-health = lib.mkIf (healthTarget != null) {
      wantedBy = ["multi-user.target"];
      after = ["jool-netns.service"];
      path = [
        pkgs.iputils
        pkgs.coreutils
      ];
      serviceConfig = {
        Restart = "always";
        RuntimeDirectory = "nat64-health";
      };
      script = ''
        file=/run/nat64-health/ipv4only.hosts
        fails=0
        state=unknown
        while :; do
          if ping -c1 -W1 ${healthTarget} >/dev/null 2>&1; then
            fails=0
            if [ "$state" != up ]; then
              printf '192.0.0.170 ipv4only.arpa\n192.0.0.171 ipv4only.arpa\n' >"$file.new"
              mv "$file.new" "$file"
              state=up
              echo "nat64-health: ${healthTarget} answers, ipv4only.arpa served"
            fi
          else
            fails=$((fails + 1))
            if [ "$fails" -ge 3 ] && [ "$state" != down ]; then
              : >"$file.new"
              mv "$file.new" "$file"
              state=down
              echo "nat64-health: ${healthTarget} is silent, ipv4only.arpa withdrawn"
            fi
          fi
          sleep 1
        done
      '';
    };
    # Idempotent: an IfState apply restarts it (Requires), and the
    # instance is still there.
    jool-netns = {
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
        modprobe jool
        ip netns exec nat64 sysctl -w net.ipv4.conf.all.forwarding=1 net.ipv6.conf.all.forwarding=1
        # Jool refuses a pool4 range that overlaps the namespace's
        # ephemeral ports; nothing opens a socket here.
        ip netns exec nat64 sysctl -w net.ipv4.ip_local_port_range="1024 1099"
        if ! ip netns exec nat64 jool instance display | grep default >/dev/null; then
          ip netns exec nat64 jool instance add default --netfilter --pool6 ${pool}
          for proto in tcp udp icmp; do
            ip netns exec nat64 jool pool4 add 10.64.0.2 1100-65535 --$proto
          done
        fi
      '';
    };
  };
}
