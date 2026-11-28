# The CLAT of specs/gateway.md G23: Jool SIIT in a namespace of its own
# (Jool never translates packets the host itself sends, so the host
# routes them into the namespace), `192.0.0.1` on the host side, an IPv4
# default route with MTU 1480, one explicit address mapping for the
# host, and the follower that keeps pool6 on a live gateway.
#
# Set by services/nat-gateway (role `client`). One CLAT per machine.
# The link `clat0` is IfState's, so an apply or a restart of the unit
# never removes and re-adds it (§14.3: Cilium attaches late to a link
# that was made again).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.clanServices.gateway.clat;
  names = import ./names.nix;
  inherit (names.clat) host inside netns instance table;
  sandbox = import ./sandbox.nix;
  ranges = import ./private.nix {inherit lib;};
  inner4 = "192.0.0.2";
  inner6 = "fd00:c1a7::2";
  quoted = links: "{ ${lib.concatMapStringsSep ", " (link: ''"${link}"'') links} }";
  errors6 = "destination-unreachable, packet-too-big, time-exceeded, parameter-problem";
  # Links between which the machine forwards IPv6 by another service's
  # rules (a cluster's pod links, a fabric's links, a router's zones)
  forwardLinks = lib.unique (config.clan.networkFacts.forwardLinks ++ cfg.forwardLinks);
  # The namespace's own ruleset (specs/design-gateway.md §3.5), as in
  # nat64.nix: what Jool handed back to the kernel goes nowhere, and
  # only a translated packet leaves. It does not name pool6, so the
  # follower's moves need no reload.
  guard = import ./guard.nix {inherit pkgs;} "clat-guard.nft" ''
    table inet ${names.guard}
    delete table inet ${names.guard}
    table inet ${names.guard} {
      chain leftover {
        type filter hook prerouting priority 0; policy drop;
        iifname "${inside}" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } ip6 hoplimit 255 accept
        # link chatter (MLD, router solicitations, LLMNR): not addressed
        # to the namespace, so not something Jool handed back
        meta pkttype != host counter drop comment "guard-noise-in"
        counter comment "guard-leftover"
      }
      chain leaving {
        type filter hook postrouting priority 0; policy drop;
        # IPv4 that became IPv6: the CLAT's one source
        oifname "${inside}" ip6 saddr ${cfg.address} accept
        # IPv6 that became IPv4: the host's CLAT address only
        oifname "${inside}" ip daddr 192.0.0.1 accept
        oifname "${inside}" ip6 saddr ${inner6} meta l4proto ipv6-icmp accept
        oifname "${inside}" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept
        # the namespace kernel's own MLD reports and router solicitations
        ip6 daddr ff00::/8 counter drop comment "guard-noise-out"
        counter comment "guard-leaving"
      }
    }
  '';
  followScript = pkgs.writeText "clat-follow.py" (builtins.readFile ./clat-follow.py);
  followConfig = pkgs.writeText "clat-follow.json" (builtins.toJSON {
    inherit (cfg) beacons;
    missing = cfg.followAfter;
    inherit netns instance;
  });
in {
  options.clanServices.gateway.clat = {
    enable = lib.mkEnableOption "the CLAT of specs/gateway.md G23";
    interface = mkOption {
      type = types.str;
      default = host;
      readOnly = true;
      description = "The host side of the CLAT link (Cilium `devices`, SPEC.md D71).";
    };
    address = mkOption {
      type = types.str;
      example = "2001:db8:c::c1a7";
      description = "The CLAT's own IPv6 address: routed to the machine, or answered for by proxy NDP.";
    };
    pool6 = mkOption {
      type = types.str;
      description = "The /96 the CLAT starts on: a gateway's pool6. The follower moves it.";
    };
    beacons = mkOption {
      type = types.listOf (types.submodule {
        options = {
          address = mkOption {
            type = types.str;
            description = "The gateway's beacon address (G24), asked for `ipv4only.arpa`.";
          };
          pool6 = mkOption {
            type = types.str;
            description = "The gateway's /96. An answer that names another prefix is no proof: the follower never moves the CLAT to a prefix the inventory does not know.";
          };
        };
      });
      description = "The gateways: each one's beacon address and its /96.";
    };
    followAfter = mkOption {
      type = types.ints.positive;
      default = 60;
      description = "Seconds without an answer from the current gateway's beacon before the follower moves the CLAT to one that answers (specs/gateway.md §14.5 point 4).";
    };
    proxyNdp = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Links on which the machine answers for the CLAT address by proxy NDP (an advertised, not routed, /64).";
    };
    forwardLinks = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["docker0"];
      description = "More links between which the machine forwards IPv6 (a container bridge). A CLAT host forwards IPv6 for its CLAT only, and for the links a service declares in `clan.networkFacts.forwardLinks` (specs/design-gateway.md §3.5).";
    };
    mtu = mkOption {
      type = types.ints.positive;
      default = 1480;
      description = "MTU of the IPv4 default route: an IPv4 packet grows by 20 bytes when it becomes IPv6, so the uplink's MTU less 20 (services/nat-gateway sets it).";
    };
    files = mkOption {
      type = types.attrsOf types.package;
      internal = true;
      readOnly = true;
      description = "The rendered files of the CLAT (the namespace's guard), for the eval tests.";
    };
  };

  config = lib.mkIf cfg.enable {
    clanServices.gateway.clat.files = {inherit guard;};
    assertions = [
      {
        assertion = cfg.beacons != [];
        message = "nat-gateway: the CLAT has no gateway to follow";
      }
      {
        assertion = !(config.boot.kernelPackages.jool.meta.broken or false);
        message = "nat-gateway: Jool is marked broken for kernel ${config.boot.kernelPackages.kernel.version}";
      }
    ];

    boot = {
      extraModulePackages = [config.boot.kernelPackages.jool];
      kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
    };
    # the CLAT forwards IPv6, so netif renders accept_ra 2
    clan._networkFacts = {
      forwarding = true;
      # D73: this link's hosts may reach a fabric's addresses through
      # this machine (routed-fabric's guard reads the fact)
      fabricInside = [names.clat.host];
    };
    environment.systemPackages = [pkgs.jool-cli];

    # specs/design-gateway.md §3.5. The forward chain has no conntrack:
    # Cilium attaches to `${host}` and the uplink on a kube node, and
    # conntrack in FORWARD is not reliable there (specs/gateway.md §16.4).
    networking.nftables.enable = true;
    networking.nftables.tables.${table} = {
      family = "inet";
      content = ''
        set gateways {
          type ipv6_addr; flags interval; auto-merge;
          elements = { ${lib.concatMapStringsSep ", " (beacon: beacon.pool6) cfg.beacons} }
        }
        ${ranges.sets}
        chain forward {
          type filter hook forward priority -10; policy accept;
          meta nfproto != ipv6 accept
          oifname "${host}" jump to_clat
          iifname "${host}" jump from_clat
          # O7: the CLAT needs IPv6 forwarding on, machine-wide. The
          # machine still forwards IPv6 for its CLAT only, and between
          # the links a service that forwards has declared.
          ${lib.optionalString (forwardLinks != []) ''
          iifname ${quoted forwardLinks} accept
          oifname ${quoted forwardLinks} accept
        ''}
          counter drop comment "clat-forward"
        }
        chain to_clat {
          ip6 daddr != ${cfg.address} counter drop comment "clat-not-address"
          # an ICMPv6 error of a router on the path to a gateway (path
          # MTU discovery): any source, as on every IPv6 host
          ip6 saddr != @gateways icmpv6 type { ${errors6} } accept
          # only a gateway's /96 is translated; another source would
          # come back out of the namespace untranslated
          ip6 saddr != @gateways counter drop comment "clat-foreign-source"
          # a forged /96 source that embeds a private IPv4 address would
          # arrive on the host as a pod or a LAN address
          ip6 saddr & ::ffff:ffff @private6 counter drop comment "clat-private-source"
          accept
        }
        chain from_clat {
          ip6 saddr != ${cfg.address} counter drop comment "clat-spoof"
          ip6 daddr != @gateways counter drop comment "clat-not-gateway"
          accept
        }
        chain input {
          type filter hook input priority -10; policy accept;
          # A stateful NAT64 opens no flow inwards: only answers to the
          # host's own flows arrive as IPv4 on this link
          iifname "${host}" ct state established,related accept
          iifname "${host}" meta nfproto ipv4 counter drop comment "clat-unsolicited"
          iifname "${host}" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept
          iifname "${host}" counter drop comment "clat-host6"
        }
      '';
    };

    networking.ifstate.settings = {
      interfaces.${host} = {
        addresses = [
          "192.0.0.1/29"
          "fd00:c1a7::1/64"
        ];
        link = {
          kind = "veth";
          state = "up";
          peer = inside;
          peer_netns = netns;
        };
      };
      namespaces.${netns} = {
        interfaces.${inside} = {
          addresses = [
            "${inner4}/29"
            "${inner6}/64"
          ];
          link = {
            kind = "veth";
            state = "up";
            peer = host;
            peer_netns = null;
          };
        };
        routing.routes = [
          {
            to = "::/0";
            via = "fd00:c1a7::1";
          }
          # No IPv4 default route: the only IPv4 destination the CLAT
          # emits is the host's 192.0.0.1, on the link. The second layer
          # under the guard: a packet to the CLAT address that Jool did
          # not translate (a source outside pool6) ends here.
          {
            to = "${cfg.address}/128";
            type = "unreachable";
          }
        ];
      };
      routing.routes = [
        {
          to = "0.0.0.0/0";
          via = "192.0.0.2";
        }
        {
          to = "${cfg.address}/128";
          via = "fd00:c1a7::2";
        }
      ];
    };

    systemd.services = {
      # I22: the links come up behind loaded tables
      ifstate.after = ["nftables.service"];
      # Idempotent: an IfState apply restarts it (PartOf; not `requires`,
      # see nat64.nix: a missing other link must not stop the CLAT), and the
      # instance, its pool6 (the follower's choice) and its mapping stay.
      ${names.clat.jool} = {
        description = "CLAT: Jool SIIT in the ${netns} namespace (specs/gateway.md G23)";
        wantedBy = ["multi-user.target"];
        after = ["ifstate.service"];
        wants = ["ifstate.service"];
        partOf = ["ifstate.service"];
        path = [
          pkgs.iproute2
          pkgs.kmod
          pkgs.jool-cli
          pkgs.procps
          pkgs.gnugrep
          pkgs.python3
          pkgs.nftables
        ];
        # G8: a failure at boot is tried again; the script is idempotent
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 5;
        };
        script = ''
          modprobe jool_siit
          # the guard first, in one transaction (nat64.nix)
          ip netns exec ${netns} nft -f ${guard}
          # Jool translates in prerouting and sends with dst_output(): it
          # needs no forwarding in the namespace (probe P2). Off, the
          # namespace's kernel cannot forward what Jool hands back.
          ip netns exec ${netns} sysctl -w net.ipv4.conf.all.forwarding=0 net.ipv6.conf.all.forwarding=0
          if ! ip netns exec ${netns} jool_siit instance display | grep -w ${instance} >/dev/null; then
            ip netns exec ${netns} jool_siit instance add ${instance} --netfilter --pool6 ${cfg.pool6}
          fi
          # The host's mapping, compared as addresses, never as strings.
          # One that changed in the configuration replaces the old one.
          wanted=$(python3 -c 'import ipaddress, sys; print(ipaddress.IPv6Address(sys.argv[1]))' ${lib.escapeShellArg cfg.address})
          if ! ip netns exec ${netns} jool_siit -i ${instance} eamt display --csv --no-headers | grep -Fx "$wanted/128,192.0.0.1/32" >/dev/null; then
            ip netns exec ${netns} jool_siit -i ${instance} eamt flush
            ip netns exec ${netns} jool_siit -i ${instance} eamt add "$wanted" 192.0.0.1
          fi
          ip route replace default via 192.0.0.2 dev ${host} mtu ${toString cfg.mtu}
          ${lib.concatMapStrings (link: ''
              sysctl -w net.ipv6.conf.${link}.proxy_ndp=1
              ip -6 neigh replace proxy ${cfg.address} dev ${link}
            '')
            cfg.proxyNdp}
        '';
      };

      # G1 (specs/gateway.md §17): `wants`, not `requires`. The CLAT unit
      # is a oneshot that every IfState apply restarts; with `requires`
      # one failed restart stopped the follower for good ("dependency
      # failed" is no failure that `Restart` covers). The follower waits
      # by itself while there is no CLAT instance.
      ${names.clat.follow} = {
        description = "CLAT follower: pool6 on a live gateway (specs/gateway.md G23)";
        wantedBy = ["multi-user.target"];
        after = ["${names.clat.jool}.service"];
        wants = ["${names.clat.jool}.service"];
        path = [
          pkgs.iproute2
          pkgs.jool-cli
          pkgs.dig
        ];
        # G14: root for `ip netns exec`, little else
        serviceConfig =
          sandbox
          // {
            ExecStart = "${lib.getExe pkgs.python3} -u ${followScript} ${followConfig}";
            Restart = "always";
            RestartSec = 1;
            CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_SYS_ADMIN"];
          };
        unitConfig.StartLimitIntervalSec = 0;
      };
    };
  };
}
