{
  module,
  netifModule,
  exportInterfaces,
  clanLib,
  lib,
  ...
}: let
  machineConfigs = lib.genAttrs ["gw1" "gw2" "node" "laptop"] (_: {
    nixpkgs.hostPlatform = "x86_64-linux";
  });

  baseInventory = {
    instances = {
      uplink = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines = {
          gw1.settings.links.wan = {
            interface = "eth1";
            zone = "wan";
            static.ipv4 = ["198.51.100.1/24"];
            static.ipv6 = ["2001:db8:c::1/64"];
          };
          gw2.settings.links.wan = {
            interface = "eth1";
            zone = "wan";
            static.ipv4 = ["198.51.100.2/24"];
            static.ipv6 = ["2001:db8:c::2/64"];
          };
          node.settings.links.wan = {
            interface = "enp1s0";
            zone = "wan";
            static.ipv6 = ["2001:db8:c::10/64"];
            gateway.ipv6 = "fe80::1";
          };
          laptop.settings.links.wan = {
            interface = "wlp2s0";
            zone = "wan";
          };
        };
      };
      nat64 = {
        module.name = "nat-gateway";
        module.input = "self";
        roles = {
          gateway.machines = {
            gw1.settings = {
              pool6 = "2001:db8:a1:0:64::/96";
              address = "2001:db8:c::1";
            };
            gw2.settings = {
              pool6 = "2001:db8:a2::/96";
              address = "2001:db8:c::2";
              limits.default.newFlows = 5;
            };
          };
          client.machines = {
            node.settings.clat.address = "2001:db8:c::c1a7";
            laptop.settings = {
              clat.address = "2001:db8:d::c1a7";
              sources = ["2001:db8:d::/64"];
              tier = "trusted";
              proxyNdp = false;
            };
          };
        };
      };
    };
  };

  mkEvaled = inventory:
    clanLib.clan {
      self = {};
      directory = ./.;
      inherit exportInterfaces inventory;
      machines = machineConfigs;
      modules = {
        nat-gateway = module;
        netif = netifModule;
      };
    };
  machine = eval: name: eval.config.nixosConfigurations.${name}.config;
  evaled = mkEvaled baseInventory;
  gw1 = machine evaled "gw1";
  gw2 = machine evaled "gw2";
  node = machine evaled "node";
  laptop = machine evaled "laptop";

  failedAssertion = config: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) config.assertions;
  ours = message: lib.hasInfix "nat-gateway" message;
  clean = config: lib.all (item: item.assertion || !(ours item.message)) config.assertions;
  table = config: config.networking.nftables.tables.nat64.content;
  # the body of one chain of a rendered table, up to the next chain
  chain = text: name: builtins.head (lib.splitString "\n  chain " (lib.last (lib.splitString "chain ${name} {" text)));
  ruleLines = text: lib.filter (line: line != "") (map lib.trim (lib.splitString "\n" text));
  clatTable = config: config.networking.nftables.tables.clat.content;
  ranges = import ../../../lib/gateway/private.nix {inherit lib;};
  at = text: needle: lib.stringLength (builtins.head (lib.splitString needle text));
  units = config: builtins.filter (name: lib.elem name ["nat64-jool" "nat64-health" "nat64-beacon" "clat" "clat-follow"]) (builtins.attrNames config.systemd.services);

  with' = patch: mkEvaled (lib.recursiveUpdate baseInventory patch);
in {
  gateway = {
    # The allowlist is built from the clients: the CLAT address, the
    # static address netif declares on the uplink zone, `sources`.
    test_allowlist = {
      expr = gw1.clanServices.gateway.nat64.allow;
      expected = {
        default = [
          "2001:db8:c::c1a7"
          "2001:db8:c::10"
        ];
        trusted = [
          "2001:db8:d::c1a7"
          "2001:db8:d::/64"
        ];
      };
    };
    test_gatewayRenders = {
      expr = {
        inherit (gw1.clanServices.gateway.nat64) pool6 address uplinks;
        targets = gw1.clanServices.gateway.nat64.health.targets;
        units = units gw1;
        netns = builtins.attrNames gw1.networking.ifstate.settings.namespaces;
        host = gw1.networking.ifstate.settings.interfaces ? jool0;
        poolRoute = lib.any (route: route.to == "2001:db8:a1:0:64::/96" && route.via == "fd64::2") gw1.networking.ifstate.settings.routing.routes;
        # the third layer: pool6 is unreachable inside the namespace
        unreachable = lib.any (route: route.to == "2001:db8:a1:0:64::/96" && (route.type or null) == "unreachable") gw1.networking.ifstate.settings.namespaces.nat64.routing.routes;
        forward = gw1.networking.firewall.filterForward;
        clean = clean gw1;
      };
      expected = {
        pool6 = "2001:db8:a1:0:64::/96";
        address = "2001:db8:c::1";
        uplinks = ["eth1"];
        targets = ["1.1.1.1" "8.8.8.8" "9.9.9.9"];
        units = ["nat64-beacon" "nat64-health" "nat64-jool"];
        netns = ["nat64"];
        host = true;
        poolRoute = true;
        unreachable = true;
        forward = true;
        clean = true;
      };
    };
    # specs/design-gateway.md §3.3: policy before translation. The
    # table's shape: what goes into the namespace is judged in
    # `to_translator` (every meter among it), what comes back out in
    # `from_translator`; the private refusal reads the embedded IPv4.
    test_table = let
      text = table gw1;
      meters = lib.filter (line: lib.hasInfix "comment \"nat64-flows-" line || lib.hasInfix "comment \"nat64-packets-" line) (ruleLines text);
      inside = ruleLines (chain text "to_translator");
    in {
      expr = {
        chains = map (name: lib.hasInfix "chain ${name} {" text) ["forward" "to_translator" "from_translator" "input" "postrouting"];
        jumps = lib.hasInfix ''oifname "jool0" jump to_translator'' (chain text "forward") && lib.hasInfix ''iifname "jool0" jump from_translator'' (chain text "forward");
        # every meter rule is judged before translation
        meters = meters != [] && lib.all (line: lib.elem line inside) meters;
        refusedBefore = map (name: lib.hasInfix ''comment "${name}"'' (chain text "to_translator")) ["nat64-undeclared" "nat64-protocol" "nat64-icmp-type" "nat64-private" "nat64-not-pool6" "nat64-unsolicited4"];
        checkedAfter = map (name: lib.hasInfix ''comment "${name}"'' (chain text "from_translator")) ["nat64-return-undeclared" "nat64-return-source" "nat64-pool4-source" "nat64-not-uplink" "nat64-private-post"];
        privateEmbedded = lib.hasInfix "ip6 daddr & ::ffff:ffff @private6" (chain text "to_translator");
        sets = lib.hasInfix "elements = { ${lib.concatStringsSep ", " ranges.private6} }" text && lib.length ranges.private6 == lib.length ranges.private;
        # the translator is no way into the gateway's own IPv4 ports
        host = lib.hasInfix ''comment "nat64-host"'' (chain text "input") && lib.hasInfix ''comment "nat64-host6"'' (chain text "input");
        beacon = lib.hasInfix ''comment "beacon-undeclared"'' (chain text "input");
        masquerade = lib.hasInfix ''oifname { "eth1" } masquerade'' text;
        # a full meter refuses a source it holds no entry for
        full = lib.hasInfix ''ip6 saddr @default ct state new ip6 saddr & ffff:ffff:ffff:ffff:: != @flows_default counter drop comment "nat64-flows-default-full"'' text && lib.hasInfix ''comment "nat64-packets-trusted-full"'' text;
        defaultRate = lib.hasInfix "limit rate over 50/second burst 200 packets" text;
        trustedRate = lib.hasInfix "limit rate over 200/second burst 4000 packets" text;
        override = lib.hasInfix "limit rate over 5/second burst 200 packets" (table gw2);
        trustedSet = lib.hasInfix "elements = { 2001:db8:d::c1a7, 2001:db8:d::/64 }" text;
      };
      expected = {
        chains = [true true true true true];
        jumps = true;
        meters = true;
        refusedBefore = [true true true true true true];
        checkedAfter = [true true true true true];
        privateEmbedded = true;
        sets = true;
        host = true;
        beacon = true;
        masquerade = true;
        full = true;
        defaultRate = true;
        trustedRate = true;
        override = true;
        trustedSet = true;
      };
    };
    # §14.5 point 3: one client's own numbers; the rest from its tier on
    # each gateway. It leaves its tier's set and gets meters of its own.
    test_clientOverride = let
      eval = with' {
        instances.nat64.roles.client.machines.node.settings.limits.newFlows = 7;
      };
      config = machine eval "gw2";
    in {
      expr = {
        inherit (config.clanServices.gateway.nat64) custom;
        default = config.clanServices.gateway.nat64.allow.default;
        rule = lib.hasInfix ''limit rate over 7/second burst 200 packets } counter drop comment "nat64-flows-client-node"'' (table config);
        packets = lib.hasInfix ''limit rate over 20000/second burst 40000 packets } counter drop comment "nat64-packets-client-node"'' (table config);
        clean = clean config;
      };
      expected = {
        custom = [
          {
            name = "node";
            sources = [
              "2001:db8:c::c1a7"
              "2001:db8:c::10"
            ];
            limits = {
              newFlows = 7;
              newFlowsBurst = 200;
              packets = 20000;
              packetsBurst = 40000;
            };
          }
        ];
        default = [];
        rule = true;
        packets = true;
        clean = true;
      };
    };
    # §14.5 point 3: the role's settings set every gateway's limits once;
    # a machine's own setting still wins.
    test_instanceLimits = let
      eval = with' {
        instances.nat64.roles.gateway.settings.limits.trusted.packets = 1234;
      };
    in {
      expr = {
        gw1 = (machine eval "gw1").clanServices.gateway.nat64.limits.trusted.packets;
        gw2 = (machine eval "gw2").clanServices.gateway.nat64.limits.trusted.packets;
        gw2Default = (machine eval "gw2").clanServices.gateway.nat64.limits.default.newFlows;
      };
      expected = {
        gw1 = 1234;
        gw2 = 1234;
        gw2Default = 5;
      };
    };
    # §14.5 point 4 and 5: the stability defaults, and Jool's private
    # IPv4 out of 10.0.0.0/8 (Cilium's native-routing CIDR).
    test_stability = {
      expr = {
        inherit (gw1.clanServices.gateway.nat64.health) quorum down up resume;
        followAfter = node.clanServices.gateway.clat.followAfter;
        pool4 = gw1.networking.ifstate.settings.namespaces.nat64.interfaces.jool1.addresses;
      };
      expected = {
        quorum = 2;
        down = 30;
        up = 120;
        resume = 60;
        followAfter = 60;
        pool4 = [
          "192.0.0.2/30"
          "fd64::2/64"
        ];
      };
    };
    # A gateway without a client (three managers that are all gateways):
    # it evaluates, and its empty allowlist lets nobody through.
    test_noClients = let
      alone = machine (mkEvaled {
        instances =
          baseInventory.instances
          // {
            nat64 =
              baseInventory.instances.nat64
              // {
                roles = {inherit (baseInventory.instances.nat64.roles) gateway;};
              };
          };
      }) "gw1";
    in {
      expr = {
        clean = clean alone;
        inherit (alone.clanServices.gateway.nat64) allow custom;
        undeclared = lib.hasInfix ''comment "nat64-undeclared"'' (table alone);
        # the allowlist's sets are empty (the private ranges are not)
        elements = lib.any (name: lib.hasInfix "elements" (builtins.head (lib.splitString "}" (lib.last (lib.splitString "set ${name} {" (table alone)))))) ["trusted" "default" "custom"];
      };
      expected = {
        clean = true;
        allow = {
          default = [];
          trusted = [];
        };
        custom = [];
        undeclared = true;
        elements = false;
      };
    };
    test_tooFewTargets = {
      expr = failedAssertion (machine (with' {
        instances.nat64.roles.gateway.machines.gw1.settings.health.targets = ["1.1.1.1"];
      }) "gw1") "three or more targets";
      expected = true;
    };
    test_missingUplinkZone = {
      expr = failedAssertion (machine (with' {
        instances.nat64.roles.gateway.machines.gw1.settings.uplinkZone = "isp";
      }) "gw1") "no netif link in zone 'isp'";
      expected = true;
    };
  };

  # Round G11 (specs/gateway.md §17)
  g11 = {
    # G1, G8: the follower outlives a failed start of the CLAT unit, and
    # the Jool units try again
    test_unitsRetry = {
      expr = {
        followerRequires = node.systemd.services.clat-follow.requires;
        followerWants = lib.elem "clat.service" node.systemd.services.clat-follow.wants;
        followerAfter = lib.elem "clat.service" node.systemd.services.clat-follow.after;
        clat = {inherit (node.systemd.services.clat.serviceConfig) Restart RestartSec;};
        jool = {inherit (gw1.systemd.services.nat64-jool.serviceConfig) Restart RestartSec;};
        # specs/design-gateway.md §3.4: the guard is loaded before an
        # instance can exist, and forwarding is off in both namespaces
        joolGuardFirst = at gw1.systemd.services.nat64-jool.script "nft -f" < at gw1.systemd.services.nat64-jool.script "jool instance add";
        clatGuardFirst = at node.systemd.services.clat.script "nft -f" < at node.systemd.services.clat.script "jool_siit instance add";
        forwardingOff = map (config: lib.hasInfix "net.ipv4.conf.all.forwarding=0 net.ipv6.conf.all.forwarding=0" config) [gw1.systemd.services.nat64-jool.script node.systemd.services.clat.script];
        forwardingOn = map (config: lib.hasInfix "forwarding=1" config) [gw1.systemd.services.nat64-jool.script node.systemd.services.clat.script];
        # I22: links come up behind loaded tables
        ifstateAfter = map (config: lib.elem "nftables.service" config.systemd.services.ifstate.after) [gw1 node];
      };
      expected = {
        followerRequires = [];
        followerWants = true;
        followerAfter = true;
        clat = {
          Restart = "on-failure";
          RestartSec = 5;
        };
        jool = {
          Restart = "on-failure";
          RestartSec = 5;
        };
        joolGuardFirst = true;
        clatGuardFirst = true;
        forwardingOff = [true true];
        forwardingOn = [false false];
        ifstateAfter = [true true];
      };
    };
    # G3: pool4 is reconciled at every start, not only at the instance's
    test_pool4Reconciled = let
      script = gw1.systemd.services.nat64-jool.script;
      at = needle: lib.stringLength (builtins.head (lib.splitString needle script));
    in {
      expr = {
        reads = lib.hasInfix "jool pool4 display" script;
        # the check runs after the block that makes the instance
        outside = at "pool4 display" > at "jool instance add default";
      };
      expected = {
        reads = true;
        outside = true;
      };
    };
    # G4: one source cannot fill one pool4 address within Jool's UDP
    # timeout (300 s) with the trusted defaults
    test_trustedBound = let
      inherit (gw1.clanServices.gateway.nat64.limits.trusted) newFlows newFlowsBurst;
    in {
      expr = {
        inherit newFlows newFlowsBurst;
        fits = newFlowsBurst + newFlows * 300 <= 64435;
      };
      expected = {
        newFlows = 200;
        newFlowsBurst = 4000;
        fits = true;
      };
    };
    # G5: the meters hold one entry per /64, not per address
    test_meterPer64 = {
      expr = {
        update = lib.hasInfix "update @flows_trusted { ip6 saddr & ffff:ffff:ffff:ffff:: limit rate over" (table gw1);
        full = lib.hasInfix "ip6 saddr & ffff:ffff:ffff:ffff:: != @flows_trusted counter drop" (table gw1);
        perAddress = lib.hasInfix "{ ip6 saddr limit rate" (table gw1);
        clientUpdate = lib.hasInfix "update @packets_c1 { ip6 saddr & ffff:ffff:ffff:ffff:: limit" (table (machine (with' {
          instances.nat64.roles.client.machines.node.settings.limits.packets = 9;
        }) "gw1"));
      };
      expected = {
        update = true;
        full = true;
        perAddress = false;
        clientUpdate = true;
      };
    };
    # G6: a CLAT address inside a declared prefix (laptop: its CLAT in
    # its own /64) loads: the source sets merge overlapping intervals
    test_sourceInsidePrefix = {
      expr = {
        merged = lib.length (lib.filter (lib.hasInfix "flags interval; auto-merge;") (lib.splitString "\n" (table gw1)));
        trustedSet = lib.hasInfix "elements = { 2001:db8:d::c1a7, 2001:db8:d::/64 }" (table gw1);
      };
      expected = {
        merged = 3;
        trustedSet = true;
      };
    };
    # G6: a client with its own limit shares no source with another client
    test_customOverlapsTier = {
      expr = failedAssertion (machine (with' {
        instances.nat64.roles.client.machines.node.settings = {
          limits.newFlows = 7;
          sources = ["2001:db8:d::/64"];
        };
      }) "gw1") "overlap";
      expected = true;
    };
    # G9: what a gateway's settings must hold
    test_samePool6 = {
      expr = failedAssertion (machine (with' {
        instances.nat64.roles.gateway.machines.gw2.settings.pool6 = "2001:db8:a1:0:64::/96";
      }) "gw1") "the same pool6";
      expected = true;
    };
    test_addressInPool6 = {
      expr = failedAssertion (machine (with' {
        instances.nat64.roles.gateway.machines.gw1.settings.address = "2001:db8:a1:0:64::1";
      }) "gw1") "inside its pool6";
      expected = true;
    };
    test_addressNotOnMachine = {
      expr = failedAssertion (machine (with' {
        instances.nat64.roles.gateway.machines.gw1.settings.address = "2001:db8:c::99";
      }) "gw1") "not a static address";
      expected = true;
    };
    test_addressOtherSpelling = {
      expr = clean (machine (with' {
        instances.nat64.roles.gateway.machines.gw1.settings.address = "2001:db8:c:0:0::1";
      }) "gw1");
      expected = true;
    };
    test_badPool6 = {
      expr = map (pool6:
        failedAssertion (machine (with' {
          instances.nat64.roles.gateway.machines.gw1.settings.pool6 = pool6;
        }) "gw1") "pool6") ["2001:db8:a1::1/96" "fe80::/96" "2001:db8:a1::/64" "not-an-address/96"];
      expected = [true true true true];
    };
    test_privateTarget = {
      expr = failedAssertion (machine (with' {
        instances.nat64.roles.gateway.machines.gw1.settings.health.targets = ["1.1.1.1" "8.8.8.8" "192.168.1.1"];
      }) "gw1") "192.168.1.1";
      expected = true;
    };
    test_duplicateClat = {
      expr = failedAssertion (machine (with' {
        instances.nat64.roles.client.machines.laptop.settings.clat.address = "2001:db8:c:0::c1a7";
      }) "gw1") "the same clat.address";
      expected = true;
    };
    # G11: the health check's numbers are settings of the service
    test_healthSettings = let
      eval = with' {
        instances.nat64.roles.gateway.settings.health = {
          quorum = 3;
          down = 20;
          up = 90;
        };
      };
      settings = builtins.fromJSON gw1.clanServices.gateway.nat64.files.health.text;
    in {
      expr = {
        inherit ((machine eval "gw1").clanServices.gateway.nat64.health) quorum down up;
        defaults = {inherit (gw1.clanServices.gateway.nat64.health) quorum down up;};
        # specs/design-gateway.md §3.7: a round reads the namespace's
        # guard, and a missing guard asks the Jool unit to load it
        inherit (settings) guard restart netns;
        nft = lib.any (package: lib.getName package == "nftables") gw1.systemd.services.nat64-health.path;
      };
      expected = {
        quorum = 3;
        down = 20;
        up = 90;
        defaults = {
          quorum = 2;
          down = 30;
          up = 120;
        };
        guard = "guard";
        restart = "nat64-jool.service";
        netns = "nat64";
        nft = true;
      };
    };
    # G12: the CLAT route's MTU follows the uplink: 20 bytes less
    test_clatMtu = {
      expr = {
        default = node.clanServices.gateway.clat.mtu;
        uplink =
          (machine (with' {
            instances.uplink.roles.default.machines.node.settings.links.wan.mtu = 1400;
          }) "node").clanServices.gateway.clat.mtu;
        set =
          (machine (with' {
            instances.nat64.roles.client.machines.node.settings.clat.mtu = 1300;
          }) "node").clanServices.gateway.clat.mtu;
      };
      expected = {
        default = 1480;
        uplink = 1380;
        set = 1300;
      };
    };
    # G14: the long-running helpers are sandboxed
    test_sandboxed = let
      hardened = config: unit: {
        inherit (config.systemd.services.${unit}.serviceConfig) NoNewPrivileges ProtectSystem ProtectHome CapabilityBoundingSet;
      };
    in {
      expr = {
        health = hardened gw1 "nat64-health";
        follow = hardened node "clat-follow";
      };
      expected = {
        health = {
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_NET_RAW" "CAP_SYS_ADMIN"];
        };
        follow = {
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_SYS_ADMIN"];
        };
      };
    };
  };

  # Round G12: gateway steps 1 to 3 of the round-61 design
  # (specs/gateway.md §18, specs/design-gateway.md §3.3 to §3.5)
  guards = {
    # the namespace's guard: two chains with policy drop, its link, the
    # gateway's own pool6 and pool4 address as the only sources out
    test_guardText = let
      nat64 = gw1.clanServices.gateway.nat64.files.guard.text;
      clat = node.clanServices.gateway.clat.files.guard.text;
      shape = text: {
        replaced = lib.hasPrefix "table inet guard\ndelete table inet guard\n" text;
        leftover = lib.hasInfix "type filter hook prerouting priority 0; policy drop;" text && lib.hasInfix ''counter comment "guard-leftover"'' text;
        leaving = lib.hasInfix "type filter hook postrouting priority 0; policy drop;" text && lib.hasInfix ''counter comment "guard-leaving"'' text;
      };
    in {
      expr = {
        nat64 = shape nat64;
        clat = shape clat;
        nat64Sources = lib.hasInfix ''oifname "jool1" ip saddr 192.0.0.2 accept'' nat64 && lib.hasInfix ''oifname "jool1" ip6 saddr 2001:db8:a1:0:64::/96 accept'' nat64;
        clatSources = lib.hasInfix ''oifname "clat1" ip6 saddr 2001:db8:c::c1a7 accept'' clat && lib.hasInfix ''oifname "clat1" ip daddr 192.0.0.1 accept'' clat;
        # the CLAT guard does not name pool6: the follower's moves need
        # no reload
        clatPool6 = lib.hasInfix "2001:db8:a1" clat;
      };
      expected = {
        nat64 = {
          replaced = true;
          leftover = true;
          leaving = true;
        };
        clat = {
          replaced = true;
          leftover = true;
          leaving = true;
        };
        nat64Sources = true;
        clatSources = true;
        clatPool6 = false;
      };
    };
    # The Jool globals the limits rest on are set at every start
    test_joolGlobals = {
      expr = map (global: lib.hasInfix "jool -i default global update ${global}" gw1.systemd.services.nat64-jool.script) ["udp-timeout 0:05:00" "icmp-timeout 0:01:00" "address-dependent-filtering true" "drop-externally-initiated-tcp true"];
      expected = [true true true true];
    };
    # one list renders both sets: an IPv4 range as the low 32 bits of a
    # /96 address (RFC 6052)
    test_embedded = {
      expr = map ranges.embedded ["127.0.0.0/8" "224.0.0.0/3" "0.0.0.0/8" "192.168.0.0/16" "100.64.0.0/10"];
      expected = ["::7f00:0/104" "::e000:0/99" "::0:0/104" "::c0a8:0/112" "::6440:0/106"];
    };
    # I7: newFlowsBurst + newFlows x 300 s fits pool4 (64 436 ports per
    # protocol) for every rendered limit; an override over it fails
    test_limitBound = {
      expr = {
        defaults = clean gw1;
        tier = failedAssertion (machine (with' {
          instances.nat64.roles.gateway.machines.gw1.settings.limits.trusted.newFlows = 300;
        }) "gw1") "tier trusted";
        client = failedAssertion (machine (with' {
          instances.nat64.roles.client.machines.node.settings.limits.newFlows = 250;
        }) "gw1") "client node";
      };
      expected = {
        defaults = true;
        tier = true;
        client = true;
      };
    };
    # O7: a plain client forwards IPv6 for its CLAT only; the links a
    # service declares (a kube node's `cilium*` and `lxc*`) and the
    # option's links pass
    test_forwardLinks = let
      declared = machine (clanLib.clan {
        self = {};
        directory = ./.;
        inherit exportInterfaces;
        inventory = baseInventory;
        machines =
          machineConfigs
          // {
            node = {
              nixpkgs.hostPlatform = "x86_64-linux";
              clan._networkFacts.forwardLinks = ["cilium*" "lxc*"];
              clanServices.gateway.clat.forwardLinks = ["docker0"];
            };
          };
        modules = {
          nat-gateway = module;
          netif = netifModule;
        };
      }) "node";
      forward = config: chain (clatTable config) "forward";
    in {
      expr = {
        plain = lib.hasInfix "iifname {" (forward node) || lib.hasInfix "oifname {" (forward node);
        declaredIn = lib.hasInfix ''iifname { "cilium*", "lxc*", "docker0" } accept'' (forward declared);
        declaredOut = lib.hasInfix ''oifname { "cilium*", "lxc*", "docker0" } accept'' (forward declared);
        # the accepts stand ahead of the drop
        order = at (forward declared) "docker0" < at (forward declared) "clat-forward";
      };
      expected = {
        plain = false;
        declaredIn = true;
        declaredOut = true;
        order = true;
      };
    };
  };

  client = {
    # D73: the CLAT and NAT64 host links are always inside a fabric:
    # routed-fabric's guard lets their hosts reach fabric addresses
    test_fabricInside = {
      expr = {
        gateway = gw1.clan.networkFacts.fabricInside;
        client = node.clan.networkFacts.fabricInside;
      };
      expected = {
        gateway = ["jool0"];
        client = ["clat0"];
      };
    };
    # The CLAT starts on the first gateway and knows every beacon.
    test_clat = {
      expr = {
        inherit (node.clanServices.gateway.clat) address pool6 beacons proxyNdp interface;
        units = units node;
        netns = builtins.attrNames node.networking.ifstate.settings.namespaces;
        forwarding = node.boot.kernel.sysctl."net.ipv6.conf.all.forwarding";
        acceptRa = node.clan._networkFacts.forwarding;
        # specs/design-gateway.md §3.5: only a gateway's /96 reaches the
        # CLAT, and other IPv6 forwarding is refused (O7)
        gateways = lib.hasInfix "elements = { 2001:db8:a1:0:64::/96, 2001:db8:a2::/96 }" (clatTable node);
        clatForward = lib.hasInfix ''counter drop comment "clat-forward"'' (chain (clatTable node) "forward");
        rules = map (name: lib.hasInfix ''comment "${name}"'' (clatTable node)) ["clat-not-address" "clat-foreign-source" "clat-private-source" "clat-spoof" "clat-not-gateway" "clat-unsolicited" "clat-host6"];
        # the namespace: the CLAT address unreachable, no IPv4 default
        routes = map (route: route.to) node.networking.ifstate.settings.namespaces.clat.routing.routes;
        unreachable = lib.any (route: route.to == "2001:db8:c::c1a7/128" && (route.type or null) == "unreachable") node.networking.ifstate.settings.namespaces.clat.routing.routes;
        clean = clean node;
      };
      expected = {
        address = "2001:db8:c::c1a7";
        pool6 = "2001:db8:a1:0:64::/96";
        # each beacon with its gateway's /96: the only prefix it may name
        beacons = [
          {
            address = "2001:db8:c::1";
            pool6 = "2001:db8:a1:0:64::/96";
          }
          {
            address = "2001:db8:c::2";
            pool6 = "2001:db8:a2::/96";
          }
        ];
        proxyNdp = ["enp1s0"];
        interface = "clat0";
        units = ["clat" "clat-follow"];
        netns = ["clat"];
        forwarding = 1;
        acceptRa = true;
        gateways = true;
        clatForward = true;
        rules = [true true true true true true true];
        routes = ["::/0" "2001:db8:c::c1a7/128"];
        unreachable = true;
        clean = true;
      };
    };
    test_proxyNdpOff = {
      expr = laptop.clanServices.gateway.clat.proxyNdp;
      expected = [];
    };
    test_export = {
      expr = let
        values = builtins.attrValues (clanLib.selectExports (scope: scope.serviceName == "nat-gateway" && scope.machineName == "node") evaled.config.exports);
      in
        map (value: value.nat_gateway) values;
      expected = [
        {
          schemaVersion = 1;
          clat = {
            interface = "clat0";
            address = "2001:db8:c::c1a7";
          };
          uplinkZone = "wan";
          gateway = false;
        }
      ];
    };
    # a gateway exports its uplink zone for D71 (§14.5 point 5)
    test_gatewayExport = {
      expr = let
        values = builtins.attrValues (clanLib.selectExports (scope: scope.serviceName == "nat-gateway" && scope.machineName == "gw1") evaled.config.exports);
      in
        map (value: {inherit (value.nat_gateway) gateway uplinkZone;}) values;
      expected = [
        {
          gateway = true;
          uplinkZone = "wan";
        }
      ];
    };
    test_bothRoles = {
      expr = failedAssertion (machine (with' {
        instances.nat64.roles.client.machines.gw1.settings.clat.address = "2001:db8:c::c1a8";
      }) "gw1") "both a gateway and a client";
      expected = true;
    };
  };
}
