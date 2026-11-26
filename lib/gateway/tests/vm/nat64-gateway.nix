# A provider's NAT64 gateway for VM suites (netif-v6only,
# <distro>-v6only, k3s-clat-mapped), built as specs/gateway.md G2 says: Jool in
# a namespace of its own that IfState declares, an allowlist in a table of
# its own (`inet nat64`) that runs before the NixOS firewall, and a
# masquerade to the public IPv4 address.
#
# Why a table of its own: the NixOS `forward-allow` chain accepts every
# ICMPv6 message before `extraForwardRules`, so an allowlist there lets an
# undeclared source ping (and tunnel) through the translator.
#
# eth1 faces the IPv6 clients, eth2 the IPv4 internet. `corefile` is the
# provider's DNS64 (`v6only-host.nix`): a provider network may offer one.
# Our own DNS64 is removed (specs/gateway.md §14.5 point 1); the services
# never run one.
{
  base,
  pool,
  # nftables expression for the sources that may use the gateway
  allow,
  inside,
  outside,
  routes ? [],
  corefile ? null,
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
    pkgs.coredns
  ];
  networking = {
    nftables.enable = true;
    firewall = {
      enable = true;
      filterForward = true;
      # The NixOS chains have a policy of drop, so they must accept what
      # `inet nat64` let pass. They are not the allowlist: `forward-allow`
      # accepts ICMPv6 from anyone before these rules.
      extraForwardRules = ''
        iifname != "eth2" oifname "j0" ip6 daddr ${pool} ip6 saddr ${allow} accept
        iifname "j0" oifname "eth2" accept
      '';
      extraInputRules = ''
        ip6 saddr ${allow} meta l4proto { tcp, udp } th dport 53 accept
      '';
    };
    # The gateway's own table (one table per owner), hooked before the
    # NixOS firewall (priority filter = 0). A drop here is final.
    nftables.tables.nat64 = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority -10; policy accept;
          # Every protocol: nothing reaches the translator from a source
          # that is not declared. An ICMPv6 error about an open flow
          # (packet too big from a router on the path) is `related`.
          oifname "j0" ip6 saddr != ${allow} ct state != related counter drop comment "nat64-undeclared"
          # a /96 destination that embeds a private IPv4 address is not the
          # internet (specs/gateway.md G5): refuse it after translation
          iifname "j0" ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } counter reject with icmp type net-prohibited comment "nat64-private"
        }
        chain input {
          type filter hook input priority -10; policy accept;
          # the DNS64 listener, UDP and TCP
          meta l4proto { tcp, udp } th dport 53 ip6 saddr != ${allow} counter drop comment "dns64-undeclared"
        }
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
