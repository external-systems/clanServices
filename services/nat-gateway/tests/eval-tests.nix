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
        forward = true;
        clean = true;
      };
    };
    # The table holds the allowlist, the tiers, the private refusal and
    # the masquerade; the defaults and an override reach it.
    test_table = {
      expr = {
        undeclared = lib.hasInfix ''comment "nat64-undeclared"'' (table gw1);
        private = lib.hasInfix ''comment "nat64-private"'' (table gw1);
        # the translator is no way into the gateway's own IPv4 ports
        host = lib.hasInfix ''iifname "jool0" meta nfproto ipv4 counter reject with icmp type host-prohibited comment "nat64-host"'' (table gw1);
        masquerade = lib.hasInfix ''oifname { "eth1" } masquerade'' (table gw1);
        # a full meter refuses a source it holds no entry for
        full = lib.hasInfix ''ip6 saddr @default ct state new ip6 saddr & ffff:ffff:ffff:ffff:: != @flows_default counter drop comment "nat64-flows-default-full"'' (table gw1) && lib.hasInfix ''comment "nat64-packets-trusted-full"'' (table gw1);
        beacon = lib.hasInfix ''comment "beacon-undeclared"'' (table gw1);
        defaultRate = lib.hasInfix "limit rate over 50/second burst 200 packets" (table gw1);
        trustedRate = lib.hasInfix "limit rate over 200/second burst 4000 packets" (table gw1);
        override = lib.hasInfix "limit rate over 5/second burst 200 packets" (table gw2);
        trustedSet = lib.hasInfix "elements = { 2001:db8:d::c1a7, 2001:db8:d::/64 }" (table gw1);
      };
      expected = {
        undeclared = true;
        private = true;
        host = true;
        masquerade = true;
        full = true;
        beacon = true;
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
        elements = lib.hasInfix "elements" (table alone);
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
    in {
      expr = {
        inherit ((machine eval "gw1").clanServices.gateway.nat64.health) quorum down up;
        defaults = {inherit (gw1.clanServices.gateway.nat64.health) quorum down up;};
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
