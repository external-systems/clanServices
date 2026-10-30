{
  module,
  clanLib,
  exportInterfaces,
  lib,
  ...
}: let
  ip = import ../../../lib/ip.nix {inherit lib;};

  machineConfigs =
    lib.genAttrs
    [
      "edge-1"
      "kamrui-h1"
      "nas"
    ]
    (_: {
      nixpkgs.hostPlatform = "x86_64-linux";
    });

  baseInventory = {
    instances = {
      # Site LAN: DHCP wifi + static ethernet on one host, DHCP NAS.
      home-net = {
        module.name = "netif";
        module.input = "self";
        roles.default = {
          settings = {
            mtu = 1500;
            nameservers = ["192.168.10.1"];
          };
          machines = {
            kamrui-h1.settings = {
              targetHost = true;
              links = {
                wifi = {
                  interface = "wlp2s0";
                  dhcp.ipv4 = true; # inherits the site mtu default
                };
                eth = {
                  interface = "enp3s0";
                  static = {
                    ipv4 = ["192.168.10.10/24"];
                    ipv6 = ["2001:db8:10::10/64"];
                  };
                  endpoint = true;
                };
              };
            };
            nas.settings.links.eth = {
              interface = "enp3s0";
              dhcp.ipv4 = true;
            };
          };
        };
      };

      # Multi-NIC router: one SFP+ link per uplink instance, one default
      # route across the whole host (docs example shape).
      uplink-a = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.edge-1.settings.links.sfp0 = {
          interface = "enp1s0f0np0";
          static.ipv4 = ["203.0.113.2/30"];
          gateway.ipv4 = "203.0.113.1";
          endpoint = true;
          routes = [
            {
              destination = "10.42.0.0/16";
              gateway = "203.0.113.1";
            }
          ];
        };
      };
      uplink-b = {
        module.name = "netif";
        module.input = "self";
        roles.default.settings.mtu = 9000; # segment-wide default
        roles.default.machines.edge-1.settings.links.sfp1 = {
          interface = "enp1s0f1np1";
          static.ipv4 = ["198.51.100.2/30"]; # no gateway: cross-instance check
        };
      };

      # Second netif instance on kamrui-h1: endpoint discovery from the
      # home-net peer export (netif -> netif, routed-fabric pattern).
      mgmt = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.kamrui-h1.settings = {
          endpointSources = [
            {
              service = "netif";
              instance = "home-net";
            }
          ];
          links.mgmt0 = {
            interface = "enp6s0";
            static.ipv4 = ["10.99.0.2/24"];
          };
        };
      };

      # Link-kind kitchen sink on edge-1: bare VLAN parent, VLAN child,
      # bond with member NICs, and an empty provider-MAC bridge.
      dmz-net = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.edge-1.settings.links = {
          trunk = {
            interface = "enp2s0";
          };
          dmz10 = {
            vlan = {
              id = 10;
              parent = "trunk";
            };
            static.ipv4 = ["10.10.10.1/24"];
          };
          nic0 = {
            interface = "enp4s0";
          };
          nic1 = {
            interface = "enp5s0";
          };
          agg0 = {
            bond.members = [
              "nic0"
              "nic1"
            ];
            static.ipv4 = ["10.20.0.1/24"];
          };
          virbr0 = {
            kind = "bridge";
            static.ipv4 = ["10.30.0.1/24"];
          };
          # Underlay policy routing (D53: netif owns underlay policy):
          # /32 on an L3-only segment, gateway on-link in table 300.
          vswitch = {
            interface = "enp7s0";
            static.ipv4 = ["192.0.2.10/32"];
            gateway = {
              ipv4 = "192.0.2.1";
              onLink = true;
            };
            routingPolicy = {
              table = 300;
              from = ["192.0.2.10/32"];
            };
          };
        };
      };
    };
  };

  mkEvaledWith = machines: inventory:
    clanLib.clan {
      self = {};
      directory = ./.;
      inherit exportInterfaces machines inventory;
      modules.netif = module;
    };

  mkEvaled = mkEvaledWith machineConfigs;

  evaled = mkEvaled baseInventory;
  forwardingEval =
    mkEvaledWith (
      machineConfigs
      // {
        kamrui-h1 = {
          nixpkgs.hostPlatform = "x86_64-linux";
          clan._networkFacts.forwarding = true;
        };
      }
    )
    baseInventory;
  kam = evaled.config.nixosConfigurations.kamrui-h1.config;
  edge = evaled.config.nixosConfigurations.edge-1.config;

  kamIfstate = kam.networking.ifstate.settings;
  edgeIfstate = edge.networking.ifstate.settings;
  kamInterfaces = kamIfstate.interfaces;
  edgeInterfaces = edgeIfstate.interfaces;

  memberExport = machineName: instanceName:
    clanLib.getExport {
      serviceName = "netif";
      inherit instanceName;
      roleName = "default";
      inherit machineName;
    }
    evaled.config.exports;

  instanceExports = instanceName:
    lib.attrValues (
      clanLib.selectExports (
        scope: scope.serviceName == "netif" && scope.instanceName == instanceName && scope.machineName == ""
      )
      evaled.config.exports
    );

  failedAssertion = machineConfig: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) machineConfig.assertions;

  explicitEndpointEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mgmt.roles.default.machines.kamrui-h1.settings.endpoint = "mgmt.test";
    }
  );
  explicitEndpointExport =
    clanLib.getExport {
      serviceName = "netif";
      instanceName = "mgmt";
      roleName = "default";
      machineName = "kamrui-h1";
    }
    explicitEndpointEval.config.exports;

  # --- negatives: cross-instance conflicts (perMachine) ---
  ownershipConflictEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mgmt.roles.default.machines.kamrui-h1.settings.links.dup = {
        interface = "enp3s0"; # already home-net's eth on kamrui-h1
      };
    }
  );
  duplicateDefaultRouteEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.home-net.roles.default.machines.kamrui-h1.settings.links.eth.gateway.ipv4 = "192.168.10.1"; # wifi DHCP already owns the default
    }
  );
  dnsConflictEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mgmt.roles.default.settings.nameservers = [
        "192.168.10.1"
        "1.1.1.1"
      ]; # overlaps home-net but differs
    }
  );
  policyTableConflictEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.home-net.roles.default.machines.kamrui-h1.settings.links.eth.routingPolicy = {
        table = 300;
        from = ["192.168.10.10/32"];
        priority = 200;
      };
      instances.mgmt.roles.default.machines.kamrui-h1.settings.links.mgmt0.routingPolicy = {
        table = 300;
        from = ["10.99.0.2/32"];
        priority = 300;
      };
    }
  );
  rulePriorityConflictEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.home-net.roles.default.machines.kamrui-h1.settings.links.eth.routingPolicy = {
        table = 301;
        from = ["192.168.10.10/32"];
        priority = 100;
      };
      instances.mgmt.roles.default.machines.kamrui-h1.settings.links.mgmt0.routingPolicy = {
        table = 302;
        from = ["10.99.0.2/32"];
        priority = 100;
      };
    }
  );
  policyDisjointEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.home-net.roles.default.machines.kamrui-h1.settings.links.eth.routingPolicy = {
        table = 301;
        from = ["192.168.10.10/32"];
        priority = 200;
      };
      instances.mgmt.roles.default.machines.kamrui-h1.settings.links.mgmt0.routingPolicy = {
        table = 302;
        from = ["10.99.0.2/32"];
        priority = 300;
      };
    }
  );
  reservedPolicyTableEvals = lib.genAttrs (map toString ip.reservedPolicyTables) (
    table:
      mkEvaled (
        lib.recursiveUpdate baseInventory {
          instances.dmz-net.roles.default.machines.edge-1.settings.links.vswitch.routingPolicy.table = builtins.fromJSON table;
        }
      )
  );

  # --- negatives: malformed links (perInstance) ---
  vlanWithoutParentEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.dmz-net.roles.default.machines.edge-1.settings.links.badvlan = {
        vlan.id = 99;
        static.ipv4 = ["10.99.99.1/24"];
      };
    }
  );
  physicalNoInterfaceEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.home-net.roles.default.machines.kamrui-h1.settings.links.foo = {
        static.ipv4 = ["10.1.1.1/24"];
      };
    }
  );
  dhcpStaticConflictEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.home-net.roles.default.machines.nas.settings.links.eth.static.ipv4 = [
        "192.168.10.99/24"
      ];
    }
  );
  memberAddressingEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.dmz-net.roles.default.machines.edge-1.settings.links.nic0.static.ipv4 = [
        "10.20.0.11/24"
      ];
    }
  );
  endpointWithoutStaticEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.home-net.roles.default.machines.nas.settings.links.eth.endpoint = true;
    }
  );
in {
  rendering = {
    test_multiNicWifiDhcp = {
      expr = {
        inherit (kamInterfaces.wlp2s0.link) kind mtu;
        dhcp = kamInterfaces.wlp2s0.hooks;
        ra = kamInterfaces.wlp2s0.sysctl.ipv6;
        dns = lib.unique kam.networking.nameservers;
      };
      expected = {
        kind = "physical";
        mtu = 1500;
        dhcp = [
          {
            name = "netif-dhcp-home-net-wifi";
            args = {
              ipv4 = "true";
              ipv6 = "false";
            };
            timeout = 15;
          }
        ];
        ra = {
          accept_ra = 1;
          autoconf = 1;
        };
        dns = ["192.168.10.1"];
      };
    };
    test_dhcpHookRegistrationMatchesLinkReference = {
      expr = lib.attrNames kamIfstate.parameters.hooks;
      expected = ["netif-dhcp-home-net-wifi"];
    };
    test_forwardingAcceptsRouterAdvertisements = {
      expr = let
        interfaces = forwardingEval.config.nixosConfigurations.kamrui-h1.config.networking.ifstate.settings.interfaces;
      in {
        dhcp = interfaces.wlp2s0.sysctl.ipv6.accept_ra;
        static = interfaces.enp3s0.sysctl.ipv6.accept_ra;
      };
      expected = {
        dhcp = 2;
        static = 2;
      };
    };
    test_multiNicStatic = {
      expr = kamInterfaces.enp3s0.addresses;
      expected = [
        "192.168.10.10/24"
        "2001:db8:10::10/64"
      ];
    };
    # SFP+-shaped physical names on the router uplinks.
    test_sfpPlusPhysicalNames = {
      expr = lib.filter (name: lib.hasPrefix "enp1s0f" name) (builtins.attrNames edgeInterfaces);
      expected = [
        "enp1s0f0np0"
        "enp1s0f1np1"
      ];
    };
    test_sfpPlusNamesAreAccepted = {
      expr = failedAssertion edge "15-character kernel limit";
      expected = false;
    };
    test_uplinkDefaultRoute = {
      expr = {
        routes = builtins.filter (r: r.dev == "enp1s0f0np0") edgeIfstate.routing.routes;
        sfp1Mtu = edgeInterfaces.enp1s0f1np1.link.mtu;
      };
      expected = {
        routes = [
          {
            to = "0.0.0.0/0";
            via = "203.0.113.1";
            dev = "enp1s0f0np0";
          }
          {
            to = "10.42.0.0/16";
            dev = "enp1s0f0np0";
            via = "203.0.113.1";
          }
        ];
        sfp1Mtu = 9000;
      };
    };
    test_policyRouting = {
      expr = {
        rules = edgeIfstate.routing.rules;
        routes = builtins.filter (r: (r.table or null) == 300) edgeIfstate.routing.routes;
      };
      expected = {
        rules = [
          {
            from = "192.0.2.10/32";
            table = 300;
            priority = 100;
          }
        ];
        routes = [
          {
            to = "0.0.0.0/0";
            via = "192.0.2.1";
            dev = "enp7s0";
            table = 300;
            onlink = true;
          }
        ];
      };
    };
    test_vlanLink = {
      expr = edgeInterfaces."enp2s0.10".link;
      expected = {
        kind = "vlan";
        state = "up";
        link = "enp2s0";
        vlan_id = 10;
      };
    };
    test_bondLink = {
      expr = {
        inherit (edgeInterfaces.agg0.link) kind bond_mode bond_miimon;
        members = map (name: edgeInterfaces.${name}.link.master) [
          "enp4s0"
          "enp5s0"
        ];
      };
      expected = {
        kind = "bond";
        bond_mode = "802.3ad";
        bond_miimon = 100;
        members = [
          "agg0"
          "agg0"
        ];
      };
    };
    test_bridgeLink = {
      expr = {
        inherit (edgeInterfaces.virbr0.link) kind state;
        inherit (edgeInterfaces.virbr0) addresses;
      };
      expected = {
        kind = "bridge";
        state = "up";
        addresses = ["10.30.0.1/24"];
      };
    };
    test_ifstateOnly = {
      expr = {
        enabled = kam.networking.ifstate.enable;
        version = kam.networking.ifstate.package.version;
        networkd = kam.systemd.network.enable;
        useNetworkd = kam.networking.useNetworkd;
        interfaces = kam.networking.interfaces;
        killMode = kam.systemd.services.ifstate.serviceConfig.KillMode;
      };
      expected = {
        enabled = true;
        version = "2.5.1";
        networkd = false;
        useNetworkd = false;
        interfaces = {};
        killMode = "process";
      };
    };
    test_multiInstanceInterfaces = {
      expr = lib.all (name: kamInterfaces ? ${name}) [
        "wlp2s0"
        "enp3s0"
        "enp6s0"
      ];
      expected = true;
    };
    test_noMtuLeavesMtuUnset = {
      expr = kamInterfaces.enp6s0.link ? mtu;
      expected = false;
    };
    test_firewallTrust = {
      expr = lib.all (i: lib.elem i kam.networking.firewall.trustedInterfaces) [
        "wlp2s0"
        "enp3s0"
        "enp6s0"
      ];
      expected = true;
    };
    # Deploy target: endpoint-enabled link's static IPv4, default user.
    test_targetHost = {
      expr = kam.clan.core.networking.targetHost;
      expected = "root@192.168.10.10";
    };
  };

  exports = {
    # peer.hosts: endpoint-enabled links export static addresses (v4 then v6).
    test_peerHosts = {
      expr = (memberExport "kamrui-h1" "home-net").peer.hosts;
      expected = [
        {
          plain = "192.168.10.10";
        }
        {
          plain = "2001:db8:10::10";
        }
      ];
    };
    test_peerUser = {
      expr = (memberExport "kamrui-h1" "home-net").peer.user;
      expected = "root";
    };
    # netif export: versioned, resolved link/interface/address/MTU facts.
    test_netifExport = {
      expr = (memberExport "kamrui-h1" "home-net").netif;
      expected = {
        schemaVersion = 1;
        endpoint = null;
        mtu = 1500;
        links = {
          wifi = {
            kind = "physical";
            interface = "wlp2s0";
            mtu = 1500;
            nameservers = ["192.168.10.1"];
            endpoint = false;
            addresses = [];
            dhcp4 = true;
            dhcp6 = false;
            ra = true;
            gateway4 = null;
            gateway6 = null;
            routes = [];
            gatewayInMain = true; # DHCP lease default
          };
          eth = {
            kind = "physical";
            interface = "enp3s0";
            mtu = 1500;
            nameservers = ["192.168.10.1"];
            endpoint = true;
            addresses = [
              "192.168.10.10/24"
              "2001:db8:10::10/64"
            ];
            dhcp4 = false;
            dhcp6 = false;
            ra = true;
            gateway4 = null;
            gateway6 = null;
            routes = [];
            gatewayInMain = false;
          };
        };
      };
    };
    # netif -> netif endpoint discovery via ordered endpointSources.
    test_endpointSources = {
      expr = (memberExport "kamrui-h1" "mgmt").netif.endpoint;
      expected = "192.168.10.10";
    };
    test_mgmtPeerHosts = {
      expr = (memberExport "kamrui-h1" "mgmt").peer.hosts;
      expected = [
        {
          plain = "192.168.10.10";
        }
      ];
    };
    test_explicitEndpointPrecedesSources = {
      expr = {
        inherit (explicitEndpointExport.netif) endpoint;
        inherit (explicitEndpointExport.peer) hosts;
      };
      expected = {
        endpoint = "mgmt.test";
        hosts = [{plain = "mgmt.test";}];
      };
    };
    test_networkFactsDeepEvalAndParity = {
      expr = {
        deep = builtins.deepSeq kam.clan.networkFacts true;
        node = kam.clan.networkFacts.node.name;
        mtu = kam.clan.networkFacts.netif.home-net.mtu;
        interface = kam.clan.networkFacts.netif.home-net.links.eth.interface;
        graphEdges = builtins.length kam.clan.networkFacts.graphs.underlay;
      };
      expected = {
        deep = true;
        node = "kamrui-h1";
        mtu = 1500;
        interface = "enp3s0";
        graphEdges = 3;
      };
    };
    # Uplink facts for routed-fabric: gateway-in-main + null MTU when unset.
    test_uplinkExport = {
      expr = {
        sfp0 = {
          gatewayInMain = (memberExport "edge-1" "uplink-a").netif.links.sfp0.gatewayInMain;
          gateway4 = (memberExport "edge-1" "uplink-a").netif.links.sfp0.gateway4;
        };
        mtu = (memberExport "edge-1" "uplink-a").netif.mtu;
      };
      expected = {
        sfp0 = {
          gatewayInMain = true;
          gateway4 = "203.0.113.1";
        };
        mtu = null;
      };
    };
    # Instance-scope networking priority for the deploy chain.
    test_networkPriority = {
      expr = (builtins.head (instanceExports "home-net")).networking.priority;
      expected = 1100;
    };
  };

  validation = {
    # Cross-instance conflicts (perMachine).
    test_linkOwnershipConflictRejected = {
      expr = failedAssertion ownershipConflictEval.config.nixosConfigurations.kamrui-h1.config "owned by exactly one instance";
      expected = true;
    };
    test_duplicateDefaultRouteRejected = {
      expr = failedAssertion duplicateDefaultRouteEval.config.nixosConfigurations.kamrui-h1.config "more than one IPv4 default route";
      expected = true;
    };
    test_dnsConflictRejected = {
      expr = failedAssertion dnsConflictEval.config.nixosConfigurations.kamrui-h1.config "conflicting DNS nameservers";
      expected = true;
    };
    test_policyTableCollisionRejected = {
      expr = failedAssertion policyTableConflictEval.config.nixosConfigurations.kamrui-h1.config "routingPolicy table collisions: 300";
      expected = true;
    };
    test_rulePriorityCollisionRejected = {
      expr = failedAssertion rulePriorityConflictEval.config.nixosConfigurations.kamrui-h1.config "rule-priority collisions: 100";
      expected = true;
    };
    test_disjointPolicyClaimsAccepted = {
      expr = failedAssertion policyDisjointEval.config.nixosConfigurations.kamrui-h1.config "collisions";
      expected = false;
    };
    test_reservedPolicyTablesRejected = {
      expr = lib.all (
        eval: failedAssertion eval.config.nixosConfigurations.edge-1.config "reserved kernel/Cilium routingPolicy table"
      ) (builtins.attrValues reservedPolicyTableEvals);
      expected = true;
    };
    # Malformed per-instance link definitions.
    test_vlanWithoutParentRejected = {
      expr = failedAssertion vlanWithoutParentEval.config.nixosConfigurations.edge-1.config "must name an existing physical, bond, or bridge 'vlan.parent' link";
      expected = true;
    };
    test_physicalWithoutInterfaceRejected = {
      expr = failedAssertion physicalNoInterfaceEval.config.nixosConfigurations.kamrui-h1.config "physical link 'foo' of machine 'kamrui-h1' must set 'interface'";
      expected = true;
    };
    test_dhcpStaticConflictRejected = {
      expr = failedAssertion dhcpStaticConflictEval.config.nixosConfigurations.nas.config "sets both 'dhcp.ipv4' and static IPv4 addresses";
      expected = true;
    };
    test_memberAddressingRejected = {
      expr = failedAssertion memberAddressingEval.config.nixosConfigurations.edge-1.config "member link 'nic0' of machine 'edge-1' is consumed by 'agg0' and must not set";
      expected = true;
    };
    test_endpointWithoutStaticRejected = {
      expr = failedAssertion endpointWithoutStaticEval.config.nixosConfigurations.nas.config "'endpoint = true' without static addresses";
      expected = true;
    };
    # The positive inventory is clean.
    test_baseInventoryHasNoFailedAssertions = {
      expr = map (c: failedAssertion c "netif") [
        kam
        edge
        evaled.config.nixosConfigurations.nas.config
      ];
      expected = [
        false
        false
        false
      ];
    };
  };
}
