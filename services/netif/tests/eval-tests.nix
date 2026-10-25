{
  module,
  clanLib,
  exportInterfaces,
  lib,
  ...
}:
let
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
            nameservers = [ "192.168.10.1" ];
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
                    ipv4 = [ "192.168.10.10/24" ];
                    ipv6 = [ "2001:db8:10::10/64" ];
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
          static.ipv4 = [ "203.0.113.2/30" ];
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
          static.ipv4 = [ "198.51.100.2/30" ]; # no gateway: cross-instance check
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
            static.ipv4 = [ "10.99.0.2/24" ];
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
            static.ipv4 = [ "10.10.10.1/24" ];
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
            static.ipv4 = [ "10.20.0.1/24" ];
          };
          virbr0 = {
            kind = "bridge";
            static.ipv4 = [ "10.30.0.1/24" ];
          };
          # Underlay policy routing (D53: netif owns underlay policy):
          # /32 on an L3-only segment, gateway on-link in table 201.
          vswitch = {
            interface = "enp7s0";
            static.ipv4 = [ "192.0.2.10/32" ];
            gateway = {
              ipv4 = "192.0.2.1";
              onLink = true;
            };
            routingPolicy = {
              table = 201;
              from = [ "192.0.2.10/32" ];
            };
          };
        };
      };
    };
  };

  mkEvaled =
    inventory:
    clanLib.clan {
      self = { };
      directory = ./.;
      inherit exportInterfaces;
      modules.netif = module;
      machines = machineConfigs;
      inherit inventory;
    };

  evaled = mkEvaled baseInventory;
  kam = evaled.config.nixosConfigurations.kamrui-h1.config;
  edge = evaled.config.nixosConfigurations.edge-1.config;

  kamNetworks = kam.systemd.network.networks;
  edgeNetworks = edge.systemd.network.networks;
  edgeNetdevs = edge.systemd.network.netdevs;

  memberExport =
    machineName: instanceName:
    clanLib.getExport {
      serviceName = "netif";
      inherit instanceName;
      roleName = "default";
      inherit machineName;
    } evaled.config.exports;

  instanceExports =
    instanceName:
    lib.attrValues (
      clanLib.selectExports (
        scope: scope.serviceName == "netif" && scope.instanceName == instanceName && scope.machineName == ""
      ) evaled.config.exports
    );

  failedAssertion =
    machineConfig: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) machineConfig.assertions;

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
      instances.home-net.roles.default.machines.kamrui-h1.settings.links.eth.gateway.ipv4 =
        "192.168.10.1"; # wifi DHCP already owns the default
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

  # --- negatives: malformed links (perInstance) ---
  vlanWithoutParentEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.dmz-net.roles.default.machines.edge-1.settings.links.badvlan = {
        vlan.id = 99;
        static.ipv4 = [ "10.99.99.1/24" ];
      };
    }
  );
  physicalNoInterfaceEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.home-net.roles.default.machines.kamrui-h1.settings.links.foo = {
        static.ipv4 = [ "10.1.1.1/24" ];
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
in
{
  rendering = {
    # multi-NIC: two links on kamrui-h1 in home-net, each its own file.
    test_multiNicWifiDhcp = {
      expr = {
        inherit (kamNetworks."40-netif-home-net-wifi".matchConfig) Name;
        inherit (kamNetworks."40-netif-home-net-wifi".networkConfig)
          DHCP
          IPv6AcceptRA
          ;
        inherit (kamNetworks."40-netif-home-net-wifi".linkConfig) MTUBytes;
        dns = kamNetworks."40-netif-home-net-wifi".dns;
      };
      expected = {
        Name = "wlp2s0";
        DHCP = "ipv4";
        IPv6AcceptRA = true;
        MTUBytes = 1500; # site default
        dns = [ "192.168.10.1" ]; # site default
      };
    };
    test_multiNicStatic = {
      expr = {
        inherit (kamNetworks."40-netif-home-net-eth".matchConfig) Name;
        address = kamNetworks."40-netif-home-net-eth".address;
        gateway = kamNetworks."40-netif-home-net-eth".gateway;
      };
      expected = {
        Name = "enp3s0";
        address = [
          "192.168.10.10/24"
          "2001:db8:10::10/64"
        ];
        gateway = [ ]; # no gateway on this link
      };
    };
    # SFP+-shaped physical names on the router uplinks.
    test_sfpPlusPhysicalNames = {
      expr = map (n: edgeNetworks.${n}.matchConfig.Name) [
        "40-netif-uplink-a-sfp0"
        "40-netif-uplink-b-sfp1"
      ];
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
        gateway = edgeNetworks."40-netif-uplink-a-sfp0".gateway;
        staticRoutes = map (r: {
          inherit (r)
            Destination
            Gateway
            ;
        }) edgeNetworks."40-netif-uplink-a-sfp0".routes;
        sfp1Mtu = edgeNetworks."40-netif-uplink-b-sfp1".linkConfig.MTUBytes;
        sfp1Gateway = edgeNetworks."40-netif-uplink-b-sfp1".gateway;
      };
      expected = {
        gateway = [ "203.0.113.1" ];
        staticRoutes = [
          {
            Destination = "10.42.0.0/16";
            Gateway = "203.0.113.1";
          }
        ];
        sfp1Mtu = 9000; # uplink-b segment default
        sfp1Gateway = [ ]; # no second default route
      };
    };
    # Underlay policy routing: gateway on-link in table 201, ip rule from.
    test_policyRouting = {
      expr = {
        gateway = edgeNetworks."40-netif-dmz-net-vswitch".gateway;
        rules = map (r: {
          inherit (r)
            Family
            From
            Table
            Priority
            ;
        }) edgeNetworks."40-netif-dmz-net-vswitch".routingPolicyRules;
        routes = map (r: {
          inherit (r)
            Gateway
            Table
            GatewayOnLink
            ;
        }) edgeNetworks."40-netif-dmz-net-vswitch".routes;
      };
      expected = {
        gateway = [ ]; # policy table owns the gateway
        rules = [
          {
            Family = "ipv4";
            From = "192.0.2.10/32";
            Table = 201;
            Priority = 100;
          }
        ];
        routes = [
          {
            Gateway = "192.0.2.1";
            Table = 201;
            GatewayOnLink = true;
          }
        ];
      };
    };
    # VLAN: derived sub-interface name + drop-in on the parent.
    test_vlanNetdev = {
      expr = {
        inherit (edgeNetdevs."40-netif-dmz-net-dmz10".netdevConfig)
          Kind
          Name
          ;
        inherit (edgeNetdevs."40-netif-dmz-net-dmz10".vlanConfig) Id;
      };
      expected = {
        Kind = "vlan";
        Name = "enp2s0.10"; # derived '<parent>.<id>'
        Id = 10;
      };
    };
    test_vlanDropIn = {
      expr =
        edge.environment.etc."systemd/network/40-netif-dmz-net-trunk.network.d/50-vlan-dmz10.conf".text;
      expected = ''
        [Network]
        VLAN=enp2s0.10
      '';
    };
    # Bond: derived netdev name, default mode, member claim files.
    test_bondNetdev = {
      expr = {
        inherit (edgeNetdevs."40-netif-dmz-net-agg0".netdevConfig)
          Kind
          Name
          ;
        inherit (edgeNetdevs."40-netif-dmz-net-agg0".bondConfig) Mode;
      };
      expected = {
        Kind = "bond";
        Name = "agg0";
        Mode = "802.3ad";
      };
    };
    test_bondMembers = {
      expr = map (n: edgeNetworks.${n}.networkConfig.Bond) [
        "40-netif-dmz-net-nic0"
        "40-netif-dmz-net-nic1"
      ];
      expected = [
        "agg0"
        "agg0"
      ];
    };
    # Bridge: explicit empty kind (provider-MAC plumbing) with static addr.
    test_bridgeNetdev = {
      expr = {
        inherit (edgeNetdevs."40-netif-dmz-net-virbr0".netdevConfig)
          Kind
          Name
          ;
        address = edgeNetworks."40-netif-dmz-net-virbr0".address;
      };
      expected = {
        Kind = "bridge";
        Name = "virbr0";
        address = [ "10.30.0.1/24" ];
      };
    };
    # Instance-namespaced and deterministic unit names: netif's rendered
    # units on kamrui-h1 carry the instance name (the 99-* catch-all
    # networks are NixOS useNetworkd defaults, not netif units).
    test_instanceNamespacedUnits = {
      expr = lib.filter (n: lib.hasPrefix "40-netif-" n) (lib.attrNames kamNetworks);
      expected = [
        "40-netif-home-net-eth"
        "40-netif-home-net-wifi"
        "40-netif-mgmt-mgmt0"
      ];
    };
    # Multi-instance rendering on one host: home-net + mgmt files coexist.
    test_multiInstanceFiles = {
      expr = lib.all (n: kamNetworks ? ${n}) [
        "40-netif-home-net-wifi"
        "40-netif-home-net-eth"
        "40-netif-mgmt-mgmt0"
      ];
      expected = true;
    };
    # mgmt has no MTU anywhere: no linkConfig on its link.
    test_noMtuNoLinkConfig = {
      expr = kamNetworks."40-netif-mgmt-mgmt0".linkConfig;
      expected = { };
    };
    # Firewall trust + unmanaged interfaces from link facts.
    test_firewallTrust = {
      expr = {
        trusted = lib.all (i: lib.elem i kam.networking.firewall.trustedInterfaces) [
          "wlp2s0"
          "enp3s0"
          "enp6s0"
        ];
        unmanaged = lib.all (i: lib.elem i kam.networking.networkmanager.unmanaged) [
          "wlp2s0"
          "enp3s0"
          "enp6s0"
        ];
      };
      expected = {
        trusted = true;
        unmanaged = true;
      };
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
            nameservers = [ "192.168.10.1" ];
            endpoint = false;
            addresses = [ ];
            dhcp4 = true;
            dhcp6 = false;
            ra = true;
            gateway4 = null;
            gateway6 = null;
            routes = [ ];
            gatewayInMain = true; # DHCP lease default
          };
          eth = {
            kind = "physical";
            interface = "enp3s0";
            mtu = 1500;
            nameservers = [ "192.168.10.1" ];
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
            routes = [ ];
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
