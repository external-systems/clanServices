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
        masquerade = lib.hasInfix ''oifname { "eth1" } masquerade'' (table gw1);
        beacon = lib.hasInfix ''comment "beacon-undeclared"'' (table gw1);
        defaultRate = lib.hasInfix "limit rate over 50/second burst 200 packets" (table gw1);
        trustedRate = lib.hasInfix "limit rate over 1000/second burst 4000 packets" (table gw1);
        override = lib.hasInfix "limit rate over 5/second burst 200 packets" (table gw2);
        trustedSet = lib.hasInfix "elements = { 2001:db8:d::c1a7, 2001:db8:d::/64 }" (table gw1);
      };
      expected = {
        undeclared = true;
        private = true;
        masquerade = true;
        beacon = true;
        defaultRate = true;
        trustedRate = true;
        override = true;
        trustedSet = true;
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

  client = {
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
        beacons = ["2001:db8:c::1" "2001:db8:c::2"];
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
