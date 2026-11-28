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
      # Site LAN: DHCP dock ethernet + static ethernet on one host, DHCP NAS.
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
                dock = {
                  interface = "enp4s0";
                  dhcp.ipv4 = true; # inherits the site mtu default
                };
                eth = {
                  interface = "enp3s0";
                  static = {
                    ipv4 = ["192.168.10.10/24"];
                    ipv6 = ["2001:db8:10::10/64"];
                  };
                  endpoint = true;
                  # dock owns both defaults (N21)
                  defaultRoute.ipv6 = false;
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
        roles.default.settings = {
          mtu = 9000; # segment-wide default
          defaultRoute.ipv6 = false; # uplink-a owns the default (N21)
        };
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
          defaultRoute.ipv6 = false;
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
        # A segment that never carries the default route says so once.
        roles.default.settings.defaultRoute.ipv6 = false;
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
    raBaseInventory;
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
      instances.home-net.roles.default.machines.kamrui-h1.settings.links.eth.gateway.ipv4 = "192.168.10.1"; # dock DHCP already owns the default
    }
  );
  # The base inventory with RAs on both links of kamrui-h1 (N48: opt-in).
  raBaseInventory = lib.recursiveUpdate baseInventory {
    instances.home-net.roles.default.machines.kamrui-h1.settings.links = {
      dock.ra = true;
      eth.ra = true;
    };
  };
  # One default route per family, chosen explicitly (N21).
  privateLink = privateLinkOn baseInventory;
  privateLinkOn = inventory: extra:
    (mkEvaled (
      lib.recursiveUpdate inventory {
        instances.cloud-private = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.kamrui-h1.settings.links.priv0 =
            {
              interface = "enp7s0";
              dhcp.ipv4 = true;
            }
            // extra;
        };
      }
    )).config.nixosConfigurations.kamrui-h1.config;
  privateNoDefault = privateLink {
    ra = true;
    defaultRoute = {
      ipv4 = false;
      ipv6 = false;
    };
  };
  privateSecondV4 = privateLink {defaultRoute.ipv6 = false;};
  privateSecondRa = privateLinkOn raBaseInventory {
    defaultRoute.ipv4 = false;
    ra = true;
  };
  privateNoRa = privateLink {
    defaultRoute.ipv4 = false;
    ra = false;
  };
  staticNoDefaultEdge =
    (mkEvaled (
      lib.recursiveUpdate baseInventory {
        instances.uplink-b.roles.default.machines.edge-1.settings.links.sfp1 = {
          gateway.ipv4 = "198.51.100.1";
          defaultRoute.ipv4 = false;
          routes = [
            {
              destination = "10.50.0.0/16";
              gateway = "198.51.100.1";
            }
          ];
        };
      }
    )).config.nixosConfigurations.edge-1.config;
  # Trust (N19) and zones (N10).
  trustEdge =
    (mkEvaled (
      lib.recursiveUpdate baseInventory {
        instances.dmz-net.roles.default = {
          settings.firewall.trust = true;
          machines.edge-1.settings.links.virbr0.firewall.trust = false;
        };
      }
    )).config.nixosConfigurations.edge-1.config;
  zoneInventory = lib.recursiveUpdate baseInventory {
    instances = {
      uplink-a.roles.default.machines.edge-1.settings.links.sfp0.zone = "wan";
      uplink-b.roles.default.machines.edge-1.settings.links.sfp1.zone = "lan";
      dmz-net.roles.default.machines.edge-1.settings.links.agg0.zone = "lan";
    };
  };
  zoneEvaled = mkEvaled zoneInventory;
  zoneEdge = zoneEvaled.config.nixosConfigurations.edge-1.config;
  zoneExport = instanceName:
    clanLib.getExport {
      serviceName = "netif";
      inherit instanceName;
      roleName = "default";
      machineName = "edge-1";
    }
    zoneEvaled.config.exports;
  badZoneEdge =
    (mkEvaled (
      lib.recursiveUpdate baseInventory {
        instances.uplink-a.roles.default.machines.edge-1.settings.links.sfp0.zone = "WAN side";
      }
    )).config.nixosConfigurations.edge-1.config;
  # Per-link DNS cannot conflict between instances (N9): overlapping but
  # different server sets on two instances are fine.
  dnsOverlapEval = mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mgmt.roles.default.settings.nameservers = [
        "192.168.10.1"
        "1.1.1.1"
      ];
    }
  );
  # Prefix delegation (N16): edge-1's uplink-a asks for a /60 and gives
  # subnet 1 to uplink-b's link, which lives in another instance.
  pdSettings = extra:
    lib.recursiveUpdate baseInventory {
      instances.uplink-a.roles.default.machines.edge-1.settings.links.sfp0.dhcp =
        lib.recursiveUpdate {
          ipv6 = true;
          prefixDelegation = {
            enable = true;
            hint = 60;
            assign = [
              {
                instance = "uplink-b";
                link = "sfp1";
                subnet = 1;
              }
            ];
          };
        }
        extra;
    };
  pdEdge = (mkEvaled (pdSettings {})).config.nixosConfigurations.edge-1.config;
  pdBroken = extra: (mkEvaled (pdSettings extra)).config.nixosConfigurations.edge-1.config;
  confOf = machineConfig: interface: machineConfig.environment.etc."netif/dhcpcd/${interface}.conf".source.text;
  confLines = machineConfig: interface: lib.splitString "\n" (confOf machineConfig interface);
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
  # --- ownership registry (specs/netif.md N6, N7, N11) ---
  withKamrui = extra:
    mkEvaledWith (
      machineConfigs
      // {
        kamrui-h1 = {
          imports = [extra];
          nixpkgs.hostPlatform = "x86_64-linux";
        };
      }
    );
  kamOf = eval: eval.config.nixosConfigurations.kamrui-h1.config;
  # kamrui-h1 with extra links in its home-net instance (design §3.9)
  kamWithLinks = links:
    kamOf (mkEvaled (lib.recursiveUpdate baseInventory {
      instances.home-net.roles.default.machines.kamrui-h1.settings.links = links;
    }));
  raKeys = machineConfig: interface:
    lib.getAttrs ["accept_ra" "autoconf" "accept_ra_pinfo" "accept_ra_defrtr" "accept_ra_rt_info_max_plen" "accept_ra_mtu" "accept_ra_min_hop_limit" "use_tempaddr"]
    machineConfig.networking.ifstate.settings.interfaces.${interface}.sysctl.ipv6;
  raOff = {
    accept_ra = 0;
    autoconf = 0;
    accept_ra_pinfo = 0;
    accept_ra_defrtr = 0;
    accept_ra_rt_info_max_plen = 0;
    accept_ra_mtu = 0;
    accept_ra_min_hop_limit = 64;
    use_tempaddr = 0;
  };
  # N48: a link that takes RAs and the default, one beside a static
  # gateway; a guest-ports bridge and its member.
  raKam = kamWithLinks {
    ral = {
      interface = "enp9s0";
      ra = true;
    };
    rgw = {
      interface = "enp8s0";
      ra = true;
      static.ipv6 = ["2001:db8:8::2/64"];
      gateway.ipv6 = "2001:db8:8::1";
      defaultRoute.ipv6 = false;
    };
    guests = {
      kind = "bridge";
      bridge = {
        guestPorts = true;
        members = ["gport"];
      };
      static.ipv4 = ["192.0.2.1/24"];
      defaultRoute.ipv6 = false;
    };
    gport.interface = "enp7s0";
  };
  tailscaleKam = kamOf (withKamrui {services.tailscale.enable = true;} baseInventory);
  iwdKam = kamOf (withKamrui {networking.wireless.iwd.enable = true;} baseInventory);
  desktopKam = kamOf (withKamrui {services.xserver.enable = true;} baseInventory);
  guardTargetKam = kamOf (withKamrui {
      clanServices.netif.guard.targets = [
        {
          address = "192.0.2.10";
          port = 22;
        }
      ];
    }
    baseInventory);
  # Round G11 (specs/netif.md N25): the guard's script and its steps
  # around ifstate.service.
  guardText = machineConfig: machineConfig.clanServices.netif.guard.script.text;
  hasStep = name: steps: lib.any (step: lib.hasInfix name (toString step)) (lib.toList steps);
  # A bridge over one member, and a segment default gateway, DHCP and
  # DNS that only the bridge may take.
  memberSiteEdge = kamOf (
    mkEvaled (
      lib.recursiveUpdate baseInventory {
        # the bridge owns the IPv4 default (N21)
        instances.home-net.roles.default.machines.kamrui-h1.settings.links.dock.defaultRoute.ipv4 = false;
        instances.vm-net = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.kamrui-h1.settings = {
            gateway.ipv4 = "10.70.0.1";
            nameservers = ["10.70.0.53"];
            dhcp.ipv6 = true;
            defaultRoute.ipv6 = false;
            links = {
              uplink0.interface = "enp9s0";
              br0 = {
                bridge.members = ["uplink0"];
                static.ipv4 = ["10.70.0.2/24"];
              };
            };
          };
        };
      }
    )
  );
  # A bad address in any address option fails at evaluation.
  badValueRejected = settings:
    !(builtins.tryEval (
      let
        machine = kamOf (mkEvaled (lib.recursiveUpdate baseInventory {instances.home-net.roles.default.machines.kamrui-h1.settings = settings;}));
      in
        builtins.deepSeq [machine.networking.ifstate.settings machine.clanServices.netif.links] null
    )).success;
  badTargetRejected = target:
    !(builtins.tryEval (
      builtins.deepSeq (kamOf (withKamrui {clanServices.netif.guard.targets = [target];} baseInventory)).clanServices.netif.guard.targets null
    )).success;
  # Rule 11 (N13): the deploy target on a tunnel address in another
  # spelling than the interface's.
  tunnelTargetKam = spelling:
    kamOf (withKamrui {
        clan.core.networking.targetHost = lib.mkForce "root@[${spelling}]:22";
        networking.ifstate.settings.interfaces.wg7 = {
          addresses = ["2001:db8:77::10/64"];
          link = {
            kind = "wireguard";
            state = "up";
          };
          wireguard.listen_port = 51877;
        };
        clanServices.networking.owners.suite.interfaces = ["^wg7$"];
      }
      baseInventory);
  floatingKam = kamOf (withKamrui {clanServices.networking.owners.failover.addresses = ["192.0.2.96/28"];} baseInventory);
  dockerKam = kamOf (withKamrui {virtualisation.docker.enable = true;} baseInventory);
  podmanKam = kamOf (withKamrui {virtualisation.podman.enable = true;} baseInventory);
  dockerV6Kam = kamOf (withKamrui {
      virtualisation.docker = {
        enable = true;
        daemon.settings = {
          ipv6 = true;
          bip = "10.200.0.1/24";
        };
      };
    }
    raBaseInventory);
  containerInventory = address:
    lib.recursiveUpdate baseInventory {
      instances.mgmt.roles.default.machines.kamrui-h1.settings.links.mgmt0.static.ipv4 = lib.mkForce [address];
    };
  dockerOverlapKam = kamOf (withKamrui {virtualisation.docker.enable = true;} (containerInventory "172.17.5.2/24"));
  podmanOverlapKam = kamOf (withKamrui {virtualisation.podman.enable = true;} (containerInventory "10.88.3.2/24"));
  dockerMovedKam = kamOf (withKamrui {
    virtualisation.docker = {
      enable = true;
      daemon.settings.bip = "10.200.0.1/24";
    };
  } (containerInventory "172.17.5.2/24"));
  k3sKam = kamOf (withKamrui {services.k3s.enable = true;} baseInventory);
  wifiLinkKam = kamOf (mkEvaled (
    lib.recursiveUpdate baseInventory {
      instances.mgmt.roles.default.machines.kamrui-h1.settings.links.wifi = {
        interface = "wlan0";
        dhcp.ipv4 = true;
      };
    }
  ));
  tailscaleTableKam = kamOf (withKamrui {services.tailscale.enable = true;} (
    lib.recursiveUpdate baseInventory {
      instances.home-net.roles.default.machines.kamrui-h1.settings.links.eth.routingPolicy = {
        table = 52;
        from = ["192.168.10.10/32"];
      };
    }
  ));
  tailscaleCgnatKam = kamOf (withKamrui {services.tailscale.enable = true;} (
    lib.recursiveUpdate baseInventory {
      instances.mgmt.roles.default.machines.kamrui-h1.settings.links.mgmt0.static.ipv4 = ["100.100.0.2/24"];
    }
  ));
  zerotierKam = kamOf (withKamrui {services.zerotierone.enable = true;} baseInventory);
  zerotierOwnedKam = kamOf (withKamrui {
      services.zerotierone.enable = true;
      clanServices.networking.owners.zerotierone.interfaces = ["^zt"];
    }
    baseInventory);
  scriptedWireguardKam = kamOf (withKamrui {
      networking.wireguard.interfaces.wg9 = {
        ips = ["10.200.0.1/24"];
        privateKeyFile = "/run/wg9.key";
      };
    }
    baseInventory);
  acceptRoutesKam = kamOf (withKamrui {
      services.tailscale = {
        enable = true;
        extraUpFlags = ["--accept-routes"];
      };
      clan._networkFacts.fabric.lab = {};
    }
    baseInventory);
  # --- underlay coverage (specs/netif.md P3a) ---
  withEdgeLinks = links:
    (mkEvaled (
      lib.recursiveUpdate baseInventory {
        instances.dmz-net.roles.default.machines.edge-1.settings.links = links;
      }
    )).config.nixosConfigurations.edge-1.config;
  macEdge = withEdgeLinks {
    wan0 = {
      match.mac = "52:54:00:12:01:02";
      static.ipv4 = ["10.40.0.2/24"];
      extraSettings.ethtool.features.rx-checksum = false;
    };
  };
  # Cloud NICs by udev path (N26) and the path MTU (N17).
  pathEdge = withEdgeLinks {
    cloud0 = {
      match.path = "pci-0000:00:03.0";
      dhcp.ipv4 = true;
      defaultRoute.ipv4 = false;
      mtu = 1500;
      pathMtu = 1460;
    };
    vswitch.pathMtu = 1400;
  };
  pathAndMacEdge = withEdgeLinks {
    cloud0 = {
      match.path = "pci-0000:00:03.0";
      match.mac = "52:54:00:12:01:02";
    };
  };
  pathOnVlanEdge = withEdgeLinks {
    dmz10.match.path = "pci-0000:00:03.0";
  };
  pathLongNameEdge = withEdgeLinks {
    the-private-cloud-nic.match.path = "pci-0000:00:03.0";
  };
  pathMtuAboveMtuEdge = withEdgeLinks {
    cloud0 = {
      interface = "enp9s0";
      mtu = 1400;
      pathMtu = 1460;
    };
  };
  cloudInitEdge =
    (mkEvaledWith (
        machineConfigs
        // {
          edge-1 = {
            nixpkgs.hostPlatform = "x86_64-linux";
            services.cloud-init = {
              enable = true;
              network.enable = true;
            };
          };
        }
      )
      baseInventory).config.nixosConfigurations.edge-1.config;
  macEdgeOnly =
    (mkEvaled {
      instances.solo = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.edge-1.settings.links.wan0 = {
          interface = "enp9s0";
          static.ipv4 = ["10.40.0.2/24"];
          ra = true;
        };
      };
    }).config.nixosConfigurations.edge-1.config;
  # VM hosts (N23, N37).
  vmHostEdge = withEdgeLinks {
    up0.match.mac = "52:54:00:12:02:01";
    brup = {
      bridge = {
        members = ["up0"];
        guestPorts = true;
      };
      static.ipv4 = ["10.61.0.1/24"];
    };
    brvlan.bridge.members = ["dmz10x"];
    dmz10x.vlan = {
      id = 20;
      parent = "trunk";
    };
    brbond = {
      bridge.members = ["agg1"];
      mac = "02:00:00:00:00:33";
    };
    agg1.bond.members = ["nic9"];
    nic9.interface = "enp9s0";
  };
  bridgeInBridgeEdge = withEdgeLinks {
    outer.bridge.members = ["virbr0"];
  };
  # N43: a WAN port that presents an ISP gateway's MAC, found by its own.
  macOnPhysicalEdge = withEdgeLinks {
    wan9 = {
      match.mac = "52:54:00:12:01:09";
      mac = "02:00:00:00:00:44";
    };
  };
  macOnMemberEdge = withEdgeLinks {
    nic0.mac = "02:00:00:00:00:45";
  };
  guestPortsOnBondEdge = withEdgeLinks {
    agg0.bridge.guestPorts = true;
  };
  macAndInterfaceEdge = withEdgeLinks {
    wan0 = {
      interface = "enp9s0";
      match.mac = "52:54:00:12:01:02";
    };
  };
  macOnVlanEdge = withEdgeLinks {
    dmz10.match.mac = "52:54:00:12:01:02";
  };
  macLongNameEdge = withEdgeLinks {
    uplink-to-the-isp.match.mac = "52:54:00:12:01:02";
  };
  badMacEdge = withEdgeLinks {
    wan0.match.mac = "52-54-00-12-01-02";
  };
  extraCollisionEdge = withEdgeLinks {
    vswitch.extraSettings = {
      link.kind = "dummy";
      addresses = ["192.0.2.99/32"];
    };
  };
in {
  underlay = {
    test_matchMacRendersIdentify = {
      expr = {
        inherit (macEdge.networking.ifstate.settings.interfaces.wan0) identify link addresses;
        ethtool = macEdge.networking.ifstate.settings.interfaces.wan0.ethtool;
      };
      expected = {
        identify.perm_address = "52:54:00:12:01:02";
        link = {
          kind = "physical";
          state = "up";
        };
        addresses = ["10.40.0.2/24"];
        ethtool.features.rx-checksum = false;
      };
    };
    # A NIC matched by udev path: a '.link' file renames it, IfState
    # knows it by its logical name and needs no 'identify'.
    test_matchPathRendersUdevLink = {
      expr = {
        clean = !(failedAssertion pathEdge "netif");
        link = {inherit (pathEdge.systemd.network.links."10-netif-cloud0") matchConfig linkConfig;};
        ifstate = {
          inherit (pathEdge.networking.ifstate.settings.interfaces.cloud0.link) kind;
          identify = pathEdge.networking.ifstate.settings.interfaces.cloud0 ? identify;
        };
        dhcpcd = pathEdge.systemd.services ? netif-dhcpcd-cloud0;
        networkd = pathEdge.systemd.network.enable;
      };
      expected = {
        clean = true;
        link = {
          matchConfig.Path = "pci-0000:00:03.0";
          linkConfig.Name = "cloud0";
        };
        ifstate = {
          kind = "physical";
          identify = false;
        };
        dhcpcd = true;
        networkd = false;
      };
    };
    test_matchPathAndMacRejected = {
      expr = failedAssertion pathAndMacEdge "must set exactly one of 'interface', 'match.mac' and 'match.path'";
      expected = true;
    };
    test_matchPathOnVlanRejected = {
      expr = failedAssertion pathOnVlanEdge "sets 'match.path' but is not a physical link";
      expected = true;
    };
    test_matchPathLongNameRejected = {
      expr = failedAssertion pathLongNameEdge "uses 'match.path'";
      expected = true;
    };
    test_cloudInitNetworkRejected = {
      expr = failedAssertion cloudInitEdge "cloud-init a second writer";
      expected = true;
    };
    # The path MTU is published, never set on the link (N17).
    test_pathMtuExported = {
      expr = {
        facts = {
          inherit (pathEdge.clan.networkFacts.netif.dmz-net) mtu pathMtu;
          link = pathEdge.clan.networkFacts.netif.dmz-net.links.cloud0.pathMtu;
        };
        linkMtu = pathEdge.networking.ifstate.settings.interfaces.cloud0.link.mtu;
      };
      expected = {
        facts = {
          mtu = 1500;
          pathMtu = 1400;
          link = 1460;
        };
        linkMtu = 1500;
      };
    };
    test_pathMtuAboveMtuRejected = {
      expr = failedAssertion pathMtuAboveMtuEdge "sets 'pathMtu' 1460 above its MTU 1400";
      expected = true;
    };
    # The operator tools (N38, N41): a drift timer that only looks, and
    # the two commands on the machine.
    test_operatorTools = {
      expr = {
        driftType = kam.systemd.services.netif-drift.serviceConfig.Type;
        timer = kam.systemd.timers.netif-drift.timerConfig.OnUnitActiveSec;
        wanted = kam.systemd.timers.netif-drift.wantedBy;
        commands = lib.sort builtins.lessThan (
          lib.filter (name: lib.hasPrefix "netif-" name) (map lib.getName kam.environment.systemPackages)
        );
      };
      expected = {
        driftType = "oneshot";
        timer = "1h";
        wanted = ["timers.target"];
        commands = [
          "netif-preview"
          "netif-status"
        ];
      };
    };
    # RA-only machine without any DNS source: a warning, not an error (N39).
    test_raOnlyWithoutDnsWarned = {
      expr = {
        raOnly = lib.any (lib.hasInfix "RDNSS") macEdgeOnly.warnings;
        withDns = lib.any (lib.hasInfix "RDNSS") kam.warnings;
      };
      expected = {
        raOnly = true;
        withDns = false;
      };
    };
    # A bridge over one NIC found by MAC takes that MAC; an explicit
    # 'mac' wins; any other bridge keeps IfState's generated one. Bridge
    # members may be physical, VLAN or bond links.
    test_bridgeMacAndMembers = let
      interfaces = vmHostEdge.networking.ifstate.settings.interfaces;
    in {
      expr = {
        clean = !(failedAssertion vmHostEdge "netif");
        overNic = interfaces.brup.link.address;
        explicit = interfaces.brbond.link.address;
        generated = interfaces.brvlan.link ? address;
        vlanMaster = interfaces."enp2s0.20".link.master;
        bondMaster = interfaces.agg1.link.master;
      };
      expected = {
        clean = true;
        overNic = "52:54:00:12:02:01";
        explicit = "02:00:00:00:00:33";
        generated = false;
        vlanMaster = "brvlan";
        bondMaster = "brbond";
      };
    };
    # Guest ports: one included regex in the ignore list, the bridge and
    # its own members handed to the pre- and post-apply steps.
    test_guestPortsRenderInclude = {
      expr = {
        include = lib.elem "!include /run/netif/guest-ports.yaml" vmHostEdge.networking.ifstate.settings.parameters.ignore.ifname;
        bridges = vmHostEdge.clanServices.netif.guestBridges;
        pre = lib.length vmHostEdge.systemd.services.ifstate.serviceConfig.ExecStartPre;
        none = {
          include = lib.elem "!include /run/netif/guest-ports.yaml" edge.networking.ifstate.settings.parameters.ignore.ifname;
          pre = lib.length edge.systemd.services.ifstate.serviceConfig.ExecStartPre;
        };
      };
      expected = {
        include = true;
        bridges.brup = ["up0"];
        # udev settle, the guard's step before an apply (N25), the RA metric, the guest ports
        pre = 4;
        none = {
          include = false;
          pre = 3;
        };
      };
    };
    test_bridgeInBridgeRejected = {
      expr = failedAssertion bridgeInBridgeEdge "never a bridge inside a bridge";
      expected = true;
    };
    test_macOnPhysical = {
      expr = {
        inherit (macOnPhysicalEdge.networking.ifstate.settings.interfaces.wan9) identify;
        inherit (macOnPhysicalEdge.networking.ifstate.settings.interfaces.wan9.link) address kind;
        rejected = failedAssertion macOnPhysicalEdge "sets 'mac'";
      };
      expected = {
        identify.perm_address = "52:54:00:12:01:09";
        address = "02:00:00:00:00:44";
        kind = "physical";
        rejected = false;
      };
    };
    test_macOnMemberRejected = {
      expr = failedAssertion macOnMemberEdge "a member takes the MAC of the bond or bridge above it";
      expected = true;
    };
    test_guestPortsOnNonBridgeRejected = {
      expr = failedAssertion guestPortsOnBondEdge "sets 'bridge.guestPorts' but is not a bridge";
      expected = true;
    };
    # The lockout guard (N25, N36): on for a headless machine, off where
    # a display manager runs; it sits between starting dhcpcd and the
    # missing-NIC check; the firewall step exists only with targets.
    test_guardDefaults = {
      expr = {
        headless = kam.clanServices.netif.guard.enable;
        desktop = desktopKam.clanServices.netif.guard.enable;
        desktopHasGuard = desktopKam.systemd.services ? netif-guard;
        # after the apply and after dhcpcd, which learns the DHCP gateway
        order = kam.systemd.services.netif-guard.after;
        applyStartsIt = lib.any (lib.hasInfix "restart --no-block netif-guard.service") (
          map toString kam.systemd.services.ifstate.serviceConfig.ExecStartPost
        );
        firewallStep = lib.any (lib.hasInfix "netif-guard") (map toString guardTargetKam.systemd.services.nftables.serviceConfig.ExecReload);
        noFirewallStep = lib.any (lib.hasInfix "netif-guard") (map toString kam.systemd.services.nftables.serviceConfig.ExecReload);
      };
      expected = {
        headless = true;
        desktop = false;
        desktopHasGuard = false;
        order = [
          "ifstate.service"
          "netif-dhcpcd-enp4s0.service"
        ];
        applyStartsIt = true;
        firewallStep = true;
        noFirewallStep = false;
      };
    };
    # Round G11: a second guard run after a rollback records nothing; a
    # link that held a default must hold one again; a DHCP link made
    # static gets a client with the kept configuration; the fault outside
    # the machine re-applies the new configuration; a failed apply still
    # runs the guard; targets are shell words.
    test_guardRollbackHardening = {
      expr = let
        text = guardText kam;
        unit = kam.systemd.services.ifstate.serviceConfig;
      in {
        marker = lib.hasInfix ''"$(cat "$run/rolled-back" 2> /dev/null || true)" = "$this"'' text;
        markerWritten = lib.hasInfix ''echo "$this" > "$run/rolled-back"'' text;
        defaultsRecorded = lib.hasInfix ''own_defaults > "$state/last-good-defaults.new"'' text;
        dhcpWaits = lib.hasInfix "dhcp_defaults=(enp4s0)" text;
        mayHoldDefault = lib.hasInfix "may6=(enp4s0)" text;
        transientClient = lib.hasInfix ''start_client "$name"'' text;
        outside = lib.hasInfix "the fault is outside this machine" text;
        resetFirst = lib.hasInfix "netif-guard-before-apply" (toString (builtins.head unit.ExecStartPre));
        applyingNamed = lib.hasInfix ''> "$run/applying"'' (builtins.head unit.ExecStartPre).text;
        notYetApplied = lib.hasInfix ''"$(cat "$run/applying" 2> /dev/null || true)" != "$config"'' text;
        resetClearsMarker = lib.hasInfix ''rm -f "$run/rolled-back"'' (builtins.head unit.ExecStartPre).text;
        afterFailure = hasStep "netif-guard-after-failure" unit.ExecStopPost;
      };
      expected = {
        marker = true;
        markerWritten = true;
        defaultsRecorded = true;
        dhcpWaits = true;
        mayHoldDefault = true;
        transientClient = true;
        outside = true;
        resetFirst = true;
        applyingNamed = true;
        notYetApplied = true;
        resetClearsMarker = true;
        afterFailure = true;
      };
    };
    # An apply starts the DHCP clients of the links that are there only.
    test_dhcpcdStartedForPresentLinks = {
      expr = lib.any (step: lib.hasInfix ''if [ -e "/sys/class/net/$interface" ]'' (step.text or "")) kam.systemd.services.ifstate.serviceConfig.ExecStartPost;
      expected = true;
    };
    test_guardTargetsAreShellWords = {
      expr = lib.hasInfix "extra=('tcp|192.0.2.10||22')" (guardText guardTargetKam);
      expected = true;
    };
    test_badAddressesRejected = {
      expr = {
        gatewayWithLength = badValueRejected {links.eth.gateway.ipv4 = "192.168.10.1/24";};
        staticWithoutLength = badValueRejected {links.eth.static.ipv4 = ["192.168.10.10"];};
        v6InV4 = badValueRejected {links.eth.static.ipv4 = ["2001:db8::1/64"];};
        lengthTooLong = badValueRejected {links.eth.static.ipv6 = ["2001:db8:10::10/129"];};
        nameserverName = badValueRejected {links.eth.nameservers = ["dns.example"];};
        routeDestination = badValueRejected {
          links.eth.routes = [{destination = "10.20.0.0";}];
        };
        mtu = badValueRejected {links.eth.mtu = 70000;};
        siteGateway = badValueRejected {gateway.ipv6 = "2001:db8::1/64";};
        targetWithPort = badTargetRejected {address = "192.0.2.10:22";};
        targetInterface = badTargetRejected {
          address = "192.0.2.10";
          interface = "eth0 eth1";
        };
        # the inventory as it is still evaluates
        good = badValueRejected {links.eth.gateway.ipv4 = "192.168.10.1";};
      };
      expected = {
        gatewayWithLength = true;
        staticWithoutLength = true;
        v6InV4 = true;
        lengthTooLong = true;
        nameserverName = true;
        routeDestination = true;
        mtu = true;
        siteGateway = true;
        targetWithPort = true;
        targetInterface = true;
        good = false;
      };
    };
    # A bridge member takes none of the segment defaults: one default
    # route, on the bridge; no route and no DHCP client on the member.
    test_memberInheritsNoAddressing = {
      expr = {
        defaults = map (r: r.dev) (builtins.filter (r: r.to == "0.0.0.0/0") memberSiteEdge.networking.ifstate.settings.routing.routes);
        memberRoutes = builtins.filter (r: (r.dev or null) == "enp9s0") memberSiteEdge.networking.ifstate.settings.routing.routes;
        memberClient = memberSiteEdge.systemd.services ? netif-dhcpcd-enp9s0;
        bridgeClient = memberSiteEdge.systemd.services ? netif-dhcpcd-br0;
      };
      expected = {
        defaults = ["br0"];
        memberRoutes = [];
        memberClient = false;
        bridgeClient = true;
      };
    };
    test_normalizeIpv6 = {
      expr = map ip.normalizeIpv6 [
        "2001:0db8::1"
        "2001:DB8:0:0::1"
        "::ffff:192.0.2.1"
        "::FFFF:c000:0201"
        "fe80::1%eth0"
        "1:::2"
        "1::2::3"
        "2001:db8::1/64"
      ];
      expected = [
        "2001:db8:0:0:0:0:0:1"
        "2001:db8:0:0:0:0:0:1"
        "0:0:0:0:0:ffff:c000:201"
        "0:0:0:0:0:ffff:c000:201"
        "fe80:0:0:0:0:0:0:1"
        null
        null
        null
      ];
    };
    test_targetHostOnTunnelInAnySpelling = {
      expr = map (spelling: failedAssertion (tunnelTargetKam spelling) "resolves to a fabric, transfer, or tunnel address") [
        "2001:db8:77::10"
        "2001:0db8:0077:0000::0010"
        "2001:db8:77::11"
      ];
      expected = [
        true
        true
        false
      ];
    };
    test_matchMacCleanInventory = {
      expr = failedAssertion macEdge "netif";
      expected = false;
    };
    test_matchMacAndInterfaceRejected = {
      expr = failedAssertion macAndInterfaceEdge "must set exactly one of 'interface', 'match.mac' and 'match.path'";
      expected = true;
    };
    test_matchMacOnVlanRejected = {
      expr = failedAssertion macOnVlanEdge "sets 'match.mac' but is not a physical link";
      expected = true;
    };
    test_matchMacLongNameRejected = {
      expr = failedAssertion macLongNameEdge "must be at most 15 characters";
      expected = true;
    };
    test_badMacRejected = {
      expr = (builtins.tryEval (builtins.deepSeq badMacEdge.networking.ifstate.settings.interfaces null)).success;
      expected = false;
    };
    test_extraSettingsCollisionRejected = {
      expr = map (needle: failedAssertion extraCollisionEdge needle) [
        "vswitch: link.kind"
        "vswitch: addresses"
      ];
      expected = [
        true
        true
      ];
    };
    test_physicalPresenceCheck = {
      expr = map (c: lib.count (lib.hasInfix "ifstate-physical-links-present") (map toString (lib.toList (c.systemd.services.ifstate.serviceConfig.ExecStartPost or [])))) [
        edge
        macEdge
      ];
      expected = [
        1
        1
      ];
    };
  };

  registry = {
    test_noDaemonNoClaims = {
      expr = kam.networking.ifstate.settings.parameters.ignore.ifname or [];
      expected = [];
    };
    test_ifstateProvidesNetworkOnline = {
      expr = {
        before = lib.elem "network-online.target" kam.systemd.services.ifstate.before;
        wantedBy = lib.elem "network-online.target" kam.systemd.services.ifstate.wantedBy;
      };
      expected = {
        before = true;
        wantedBy = true;
      };
    };
    # Docker or Podman switches the containers preset on (N22): every
    # link pattern and Podman's named namespaces are owned.
    test_containersPreset = {
      expr = {
        docker = {
          inherit (dockerKam.networking.ifstate.settings.parameters.ignore) ifname netns;
        };
        podman = podmanKam.clanServices.networking.owners.containers.enable;
        off = kam.clanServices.networking.owners.containers.enable;
        clean = !(failedAssertion dockerKam "clanServices");
      };
      expected = {
        docker = {
          ifname = [
            "^docker"
            "^br-"
            "^podman"
            "^veth"
          ];
          netns = ["^netns-"];
        };
        podman = true;
        off = false;
        clean = true;
      };
    };
    # A declared range inside a default container pool is rejected;
    # moving the pool clears it.
    test_containerPoolOverlapRejected = {
      expr = {
        docker = failedAssertion dockerOverlapKam "172.17.5.2/24 overlaps 172.17.0.0/16";
        podman = failedAssertion podmanOverlapKam "10.88.3.2/24 overlaps 10.88.0.0/16";
        moved = failedAssertion dockerMovedKam "container address pool";
      };
      expected = {
        docker = true;
        podman = true;
        moved = false;
      };
    };
    # Docker forwards IPv6 only when its daemon does IPv6; then RAs must
    # still be accepted (accept_ra 2).
    test_dockerIpv6SetsForwarding = {
      expr = {
        v6 = dockerV6Kam.clan.networkFacts.forwarding;
        ra = dockerV6Kam.networking.ifstate.settings.interfaces.enp4s0.sysctl.ipv6.accept_ra;
        plain = dockerKam.clan.networkFacts.forwarding;
      };
      expected = {
        v6 = true;
        ra = 2;
        plain = false;
      };
    };
    test_tailscalePreset = {
      expr = let
        ignore = tailscaleKam.networking.ifstate.settings.parameters.ignore;
      in {
        inherit (ignore) ifname rules;
        routes = builtins.filter (route: !(route ? proto)) ignore.routes;
        after = lib.elem "network-online.target" tailscaleKam.systemd.services.tailscaled.after;
        wants = lib.elem "network-online.target" tailscaleKam.systemd.services.tailscaled.wants;
      };
      expected = {
        ifname = ["^tailscale"];
        rules = [
          {table = 52;}
          {priority = 5210;}
          {priority = 5230;}
          {priority = 5250;}
          {priority = 5270;}
        ];
        routes = [
          {dev = "^tailscale";}
          {table = 52;}
        ];
        after = true;
        wants = true;
      };
    };
    test_iwdPreset = {
      expr = iwdKam.networking.ifstate.settings.parameters.ignore.ifname;
      expected = ["^wl"];
    };
    test_ciliumPreset = {
      expr = let
        ignore = k3sKam.networking.ifstate.settings.parameters.ignore;
      in {
        inherit (ignore) ifname rules netns;
      };
      expected = {
        # every pod's named namespace is the CNI's (found by k3s-data-plane-netif)
        netns = ["^cni-"];
        ifname = [
          "^cilium"
          "^lxc"
        ];
        rules = [{table = 200;}];
      };
    };
    # An owner can claim address ranges: addresses a failover controller
    # moves at run time stay through a reapply.
    test_ownerAddressRanges = {
      expr = {
        owned = floatingKam.networking.ifstate.settings.parameters.ignore.ipaddr;
        none = kam.networking.ifstate.settings.parameters.ignore ? ipaddr;
      };
      expected = {
        owned = ["192.0.2.96/28"];
        none = false;
      };
    };
    test_presetsCleanOnBaseInventory = {
      expr = map (c: failedAssertion c "clanServices:") [
        tailscaleKam
        iwdKam
        zerotierOwnedKam
      ];
      expected = [
        false
        false
        false
      ];
    };
    test_wifiLinkRejected = {
      expr = failedAssertion wifiLinkKam "Wi-Fi links belong to iwd, never IfState";
      expected = true;
    };
    test_ownedTableRejected = {
      expr = failedAssertion tailscaleTableKam "table 52 is owned by 'tailscale'";
      expected = true;
    };
    test_unownedDaemonRejected = {
      expr = failedAssertion zerotierKam "zerotierone (services.zerotierone.enable) has no ownership-registry preset";
      expected = true;
    };
    test_scriptedWireguardRejected = {
      expr = failedAssertion scriptedWireguardKam "wireguard (networking.wireguard.interfaces";
      expected = true;
    };
    test_tailscaleCgnatOverlapRejected = {
      expr = failedAssertion tailscaleCgnatKam "100.100.0.2/24 overlaps 100.64.0.0/10";
      expected = true;
    };
    test_fabricAcceptRoutesWarns = {
      expr = map (c: lib.any (lib.hasInfix "accepts Tailscale subnet routes") c.warnings) [
        acceptRoutesKam
        tailscaleKam
      ];
      expected = [
        true
        false
      ];
    };
  };

  rendering = {
    test_multiNicDhcp = {
      expr = {
        inherit (kamInterfaces.enp4s0.link) kind mtu;
        hooks = kamInterfaces.enp4s0 ? hooks;
        ra = kamInterfaces.enp4s0.sysctl.ipv6;
        globalDns = kam.networking.nameservers;
        staticDns = kam.environment.etc."netif/dns/enp4s0.dns".text;
        resolved = kam.services.resolved.enable;
        host = {
          inherit
            (kam.clanServices.netif.links.enp4s0)
            instance
            logical
            dhcp4
            dhcp6
            requiredForOnline
            ;
        };
      };
      expected = {
        kind = "physical";
        mtu = 1500;
        hooks = false;
        # RAs are opt-in (N48)
        ra =
          raOff
          // {
            accept_redirects = 0;
            accept_source_route = 0;
          };
        globalDns = [];
        staticDns = "192.168.10.1\n";
        resolved = true;
        host = {
          instance = "home-net";
          logical = "dock";
          dhcp4 = true;
          dhcp6 = false;
          requiredForOnline = true;
        };
      };
    };
    # One supervised dhcpcd unit per DHCP link, bound to the link's device,
    # running the upstream dhcpcd with netif's own config (N16, N31).
    test_dhcpcdUnitPerDhcpLink = {
      expr = let
        unit = kam.systemd.services."netif-dhcpcd-enp4s0";
      in {
        units = lib.filter (lib.hasPrefix "netif-dhcpcd-") (lib.attrNames kam.systemd.services);
        inherit (unit) bindsTo wantedBy;
        inherit (unit.serviceConfig) Restart NoNewPrivileges ProtectSystem;
        upstream = lib.hasInfix "dhcpcd-10.5" unit.serviceConfig.ExecStart.text;
        # netif's own file, or the one the guard kept after a rollback (N25)
        ownConfig =
          lib.hasInfix "conf=/etc/netif/dhcpcd/enp4s0.conf" unit.serviceConfig.ExecStart.text
          && lib.hasInfix "kept=/run/netif-guard/dhcpcd/enp4s0.conf" unit.serviceConfig.ExecStart.text
          && lib.hasInfix ''-B -f "$conf" enp4s0'' unit.serviceConfig.ExecStart.text;
        ifstateHooks = kamIfstate.parameters.hooks or {};
      };
      expected = {
        units = ["netif-dhcpcd-enp4s0"];
        bindsTo = ["sys-subsystem-net-devices-enp4s0.device"];
        wantedBy = [];
        Restart = "on-failure";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        upstream = true;
        ownConfig = true;
        ifstateHooks = {};
      };
    };
    # dhcpcd's fixed job (N16): no RA handling, no IPv4 link-local, no
    # stock hooks, the N18 metric; IPv6 left alone on a DHCPv4-only link.
    test_dhcpcdConfigDhcp4Only = {
      expr = let
        lines = confLines kam "enp4s0";
        has = line: lib.elem line lines;
      in {
        noipv6rs = has "noipv6rs";
        noipv4ll = has "noipv4ll";
        metric = has "metric 100";
        backoff = has "backoff_cutoff 16";
        ipv4only = has "ipv4only";
        ia_na = lib.any (lib.hasPrefix "ia_na") lines;
        ia_pd = lib.any (lib.hasPrefix "ia_pd") lines;
        script = lib.any (lib.hasPrefix "script /nix/store/") lines;
        iaid = lib.length (lib.filter (lib.hasPrefix "iaid ") lines);
      };
      expected = {
        noipv6rs = true;
        noipv4ll = true;
        metric = true;
        backoff = true;
        ipv4only = true;
        ia_na = false;
        ia_pd = false;
        script = true;
        iaid = 1;
      };
    };
    test_prefixDelegationRendersIaPd = {
      expr = let
        lines = confLines pdEdge "enp1s0f0np0";
        iaid = lib.removePrefix "iaid " (lib.findFirst (lib.hasPrefix "iaid ") "" lines);
      in {
        ia_na = lib.elem "ia_na ${iaid}" lines;
        ia_pd = lib.elem "ia_pd ${iaid}/::/60 enp1s0f1np1/1/64" lines;
        ipv4only = lib.elem "ipv4only" lines;
        ipv6only = lib.elem "ipv6only" lines;
        fact = pdEdge.clan.networkFacts.netif.uplink-a.links.sfp0.prefixDelegation;
      };
      expected = {
        ia_na = true;
        ia_pd = true;
        ipv4only = false;
        ipv6only = true;
        fact = {
          enable = true;
          hint = 60;
          assign = [
            {
              instance = "uplink-b";
              link = "sfp1";
              subnet = 1;
              length = 64;
            }
          ];
          dynamic = true;
        };
      };
    };
    test_onlineWaitsForDhcpLinksOnly = {
      expr = {
        kam = kam.systemd.services ? netif-online;
        after = kam.systemd.services.netif-online.after;
        edge = edge.systemd.services ? netif-online;
      };
      expected = {
        kam = true;
        after = [
          "ifstate.service"
          "netif-dhcpcd-enp4s0.service"
        ];
        edge = false;
      };
    };
    test_forwardingAcceptsRouterAdvertisements = {
      expr = let
        interfaces = forwardingEval.config.nixosConfigurations.kamrui-h1.config.networking.ifstate.settings.interfaces;
      in {
        dhcp = interfaces.enp4s0.sysctl.ipv6.accept_ra;
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
        routes = builtins.filter (r: (r.dev or null) == "enp1s0f0np0") edgeIfstate.routing.routes;
        sfp1Mtu = edgeInterfaces.enp1s0f1np1.link.mtu;
      };
      expected = {
        routes = [
          {
            to = "0.0.0.0/0";
            via = "203.0.113.1";
            dev = "enp1s0f0np0";
            preference = 100; # N18
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
        "enp4s0"
        "enp3s0"
        "enp6s0"
      ];
      expected = true;
    };
    test_noMtuLeavesMtuUnset = {
      expr = kamInterfaces.enp6s0.link ? mtu;
      expected = false;
    };
    # Links are untrusted unless the link or its segment says otherwise
    # (N19): a link value wins over the segment's.
    test_linksUntrustedByDefault = {
      expr = kam.networking.firewall.trustedInterfaces;
      expected = ["lo"]; # the firewall's own default
    };
    test_firewallTrustExplicit = {
      expr = {
        trustedInterfaces = lib.sort builtins.lessThan trustEdge.networking.firewall.trustedInterfaces;
        facts = lib.mapAttrs (_: l: l.trusted) trustEdge.clan.networkFacts.netif.dmz-net.links;
      };
      expected = {
        trustedInterfaces = [
          "agg0"
          "enp2s0"
          "enp2s0.10"
          "enp4s0"
          "enp5s0"
          "enp7s0"
          "lo"
        ];
        facts = {
          agg0 = true;
          dmz10 = true;
          nic0 = true;
          nic1 = true;
          trunk = true;
          virbr0 = false;
          vswitch = true;
        };
      };
    };
    # The DHCPv6 client's port is opened on DHCPv6 links only (N19).
    test_dhcp6PortOpenedPerLink = {
      expr = {
        pd = pdEdge.networking.firewall.interfaces.enp1s0f0np0.allowedUDPPorts;
        dhcp4Only = kam.networking.firewall.interfaces ? enp4s0;
      };
      expected = {
        pd = [546];
        dhcp4Only = false;
      };
    };
    # The zone seam (N10): labels by link, and interfaces by zone.
    test_zoneSeam = {
      expr = {
        inherit (zoneEdge.clanServices.netif) zones;
        link = zoneEdge.clanServices.networking.links.uplink-a.sfp0;
        unlabelled = zoneEdge.clanServices.networking.links.dmz-net.virbr0;
        fact = zoneEdge.clan.networkFacts.netif.uplink-a.links.sfp0.zone;
        export = (zoneExport "uplink-b").netif.links.sfp1.zone;
      };
      expected = {
        zones = {
          lan = [
            "agg0"
            "enp1s0f1np1"
          ];
          wan = ["enp1s0f0np0"];
        };
        link = {
          interface = "enp1s0f0np0";
          zone = "wan";
          kind = "physical";
        };
        unlabelled = {
          interface = "virbr0";
          zone = null;
          kind = "bridge";
        };
        fact = "wan";
        export = "lan";
      };
    };
    test_zoneNameChecked = {
      expr = (builtins.tryEval (builtins.deepSeq badZoneEdge.clanServices.netif.zones true)).success;
      expected = false;
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
        pathMtu = null;
        links = {
          dock = {
            kind = "physical";
            interface = "enp4s0";
            mtu = 1500;
            nameservers = ["192.168.10.1"];
            endpoint = false;
            addresses = [];
            dhcp4 = true;
            dhcp6 = false;
            ra = false; # opt-in (N48)
            gateway4 = null;
            gateway6 = null;
            routes = [];
            gatewayInMain = true; # DHCP lease default
            defaultRoute = {
              ipv4 = true;
              ipv6 = false; # no source: RAs are opt-in (N48)
            };
            trusted = false; # N19
            zone = null;
            pathMtu = null;
            prefixDelegation = {
              enable = false;
              hint = 56;
              assign = [];
              dynamic = true;
            };
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
            ra = false;
            gateway4 = null;
            gateway6 = null;
            routes = [];
            gatewayInMain = false;
            defaultRoute = {
              ipv4 = false;
              ipv6 = false;
            };
            trusted = false;
            zone = null;
            pathMtu = null;
            prefixDelegation = {
              enable = false;
              hint = 56;
              assign = [];
              dynamic = true;
            };
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
    # A second DHCPv4 link is fine once it gives up the default: dhcpcd
    # keeps the lease and drops the router; RAs give no default router.
    test_secondDhcpLinkWithoutDefaultAccepted = {
      expr = {
        clean = !(failedAssertion privateNoDefault "netif");
        nogateway = lib.elem "nogateway" (confLines privateNoDefault "enp7s0");
        ownerKeepsGateway = lib.elem "nogateway" (confLines privateNoDefault "enp4s0");
        ra = privateNoDefault.networking.ifstate.settings.interfaces.enp7s0.sysctl.ipv6;
        facts = privateNoDefault.clan.networkFacts.netif.cloud-private.links.priv0.defaultRoute;
      };
      expected = {
        clean = true;
        nogateway = true;
        ownerKeepsGateway = false;
        ra =
          raOff
          // {
            accept_redirects = 0;
            accept_source_route = 0;
            accept_ra = 1;
            autoconf = 1;
            accept_ra_pinfo = 1;
          };
        facts = {
          ipv4 = false;
          ipv6 = false;
        };
      };
    };
    test_secondDhcp4DefaultRejected = {
      expr = failedAssertion privateSecondV4 "more than one IPv4 default route (links: priv0, dock)";
      expected = true;
    };
    # A link that accepts RAs is a source of an IPv6 default.
    test_secondRaDefaultRejected = {
      expr = failedAssertion privateSecondRa "more than one IPv6 default route (links: priv0, dock)";
      expected = true;
    };
    test_raOffIsNoDefaultSource = {
      expr = failedAssertion privateNoRa "netif";
      expected = false;
    };
    # A static gateway without the default still serves the link's routes.
    test_staticGatewayWithoutDefault = {
      expr = {
        clean = !(failedAssertion staticNoDefaultEdge "netif");
        routes = builtins.filter (r: (r.dev or null) == "enp1s0f1np1") staticNoDefaultEdge.networking.ifstate.settings.routing.routes;
      };
      expected = {
        clean = true;
        routes = [
          {
            to = "10.50.0.0/16";
            dev = "enp1s0f1np1";
            via = "198.51.100.1";
          }
        ];
      };
    };
    # The sysctl baseline (N47): a declared link renders no redirects
    # and no source routes; `all`, `default` and the glob cover every
    # other link.
    test_sysctlBaseline = let
      baselineKeys = lib.concatMap (scope: [
        "net.ipv4.conf.${scope}.accept_redirects"
        "net.ipv4.conf.${scope}.secure_redirects"
        "net.ipv4.conf.${scope}.send_redirects"
        "net.ipv4.conf.${scope}.accept_source_route"
        "net.ipv6.conf.${scope}.accept_redirects"
        "net.ipv6.conf.${scope}.accept_source_route"
      ]) ["all" "default" "*"];
    in {
      expr = {
        ipv4 = kamInterfaces.enp3s0.sysctl.ipv4;
        ipv6 = {
          inherit (kamInterfaces.enp3s0.sysctl.ipv6) accept_redirects accept_source_route;
        };
        kernel = lib.genAttrs baselineKeys (key: kam.boot.kernel.sysctl.${key});
      };
      expected = {
        ipv4 = {
          accept_redirects = 0;
          secure_redirects = 0;
          send_redirects = 0;
          accept_source_route = 0;
        };
        ipv6 = {
          accept_redirects = 0;
          accept_source_route = 0;
        };
        kernel = lib.genAttrs baselineKeys (_: 0);
      };
    };
    # N48: router advertisements only where declared.
    test_raOffByDefault = {
      expr = {
        declared = raKeys kam "enp3s0";
        default = lib.genAttrs ["accept_ra" "autoconf" "accept_ra_defrtr" "accept_ra_pinfo" "accept_ra_rt_info_max_plen" "accept_ra_mtu" "accept_ra_min_hop_limit"] (key: kam.boot.kernel.sysctl."net.ipv6.conf.default.${key}");
        # no glob: it would switch RAs off on hot-plug links at every reload
        glob = kam.boot.kernel.sysctl ? "net.ipv6.conf.*.accept_ra";
      };
      expected = {
        declared = raOff;
        default = {
          accept_ra = 0;
          autoconf = 0;
          accept_ra_defrtr = 0;
          accept_ra_pinfo = 0;
          accept_ra_rt_info_max_plen = 0;
          accept_ra_mtu = 0;
          accept_ra_min_hop_limit = 64;
        };
        glob = false;
      };
    };
    test_raOptIn = {
      expr = raKeys raKam "enp9s0";
      expected =
        raOff
        // {
          accept_ra = 1;
          autoconf = 1;
          accept_ra_pinfo = 1;
          accept_ra_defrtr = 1;
        };
    };
    # A static IPv6 gateway is never joined by an advertised default.
    test_raBesideStaticGateway = {
      expr = (raKeys raKam "enp8s0").accept_ra_defrtr;
      expected = 0;
    };
    test_raOffOnGuestBridgeAndMember = {
      expr = map (interface: (raKeys raKam interface).accept_ra) ["guests" "enp7s0"];
      expected = [0 0];
    };
    # E3: DHCPv6 carries no router.
    test_dhcp6NeedsRouter = {
      expr = failedAssertion (kamWithLinks {
        v6 = {
          interface = "enp9s0";
          dhcp.ipv6 = true;
        };
      }) "DHCPv6 carries no router";
      expected = true;
    };
    test_dhcp6WithRa = {
      expr = failedAssertion (kamWithLinks {
        v6 = {
          interface = "enp9s0";
          dhcp.ipv6 = true;
          ra = true;
        };
      }) "DHCPv6 carries no router";
      expected = false;
    };
    # E4: a member carries no addressing.
    test_raOnMember = {
      expr = failedAssertion (kamWithLinks {
        nic = {
          interface = "enp9s0";
          ra = true;
        };
        br9 = {
          kind = "bridge";
          bridge.members = ["nic"];
          defaultRoute.ipv6 = false;
        };
      }) "a member carries no addressing";
      expected = true;
    };
    # E5: a guest can send advertisements on a guest-ports bridge.
    test_raOnGuestBridgeWarns = {
      expr =
        lib.any (lib.hasInfix "sets 'ra = true': any guest")
        (kamWithLinks {
          guests = {
            kind = "bridge";
            bridge.guestPorts = true;
            ra = true;
            defaultRoute.ipv6 = false;
          };
        }).warnings;
      expected = true;
    };
    # The RA default gets netif's metric: the sysctl default for links
    # IfState creates, and a write before each apply for the others (N18).
    test_raDefaultMetric = {
      expr = {
        sysctl = kam.boot.kernel.sysctl."net.ipv6.conf.default.ra_defrtr_metric";
        pre = lib.length kam.systemd.services.ifstate.serviceConfig.ExecStartPre >= 1;
      };
      expected = {
        sysctl = 100;
        pre = true;
      };
    };
    test_duplicateDefaultRouteRejected = {
      expr = failedAssertion duplicateDefaultRouteEval.config.nixosConfigurations.kamrui-h1.config "more than one IPv4 default route";
      expected = true;
    };
    test_dnsOverlapAcrossInstancesAccepted = {
      expr = failedAssertion dnsOverlapEval.config.nixosConfigurations.kamrui-h1.config "netif";
      expected = false;
    };
    test_prefixDelegationNeedsDhcp6 = {
      expr = failedAssertion (pdBroken {ipv6 = false;}) "enables 'dhcp.prefixDelegation' without 'dhcp.ipv6 = true'";
      expected = true;
    };
    test_prefixDelegationTargetMustExist = {
      expr = failedAssertion (pdBroken {
        prefixDelegation.assign = [
          {
            link = "nowhere";
            subnet = 1;
          }
        ];
      }) "assigns a delegated prefix to a link that does not exist on it: uplink-a/sfp0 -> uplink-a/nowhere";
      expected = true;
    };
    test_prefixDelegationNotToItself = {
      expr = failedAssertion (pdBroken {
        prefixDelegation.assign = [
          {
            link = "sfp0";
            subnet = 1;
          }
        ];
      }) "assigns a delegated prefix to the link that requests it: uplink-a/sfp0";
      expected = true;
    };
    test_prefixDelegationSubnetMustFit = {
      expr = failedAssertion (pdBroken {
        prefixDelegation.assign = [
          {
            instance = "uplink-b";
            link = "sfp1";
            subnet = 16; # a /60 holds /64 subnets 0..15
          }
        ];
      }) "assigns a subnet that does not fit in its delegated prefix";
      expected = true;
    };
    test_prefixDelegationSubnetIdsUnique = {
      expr = failedAssertion (pdBroken {
        prefixDelegation.assign = [
          {
            instance = "uplink-b";
            link = "sfp1";
            subnet = 1;
          }
          {
            instance = "dmz-net";
            link = "vswitch";
            subnet = 1;
          }
        ];
      }) "assigns one subnet id of its delegated prefix twice";
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
      expr = failedAssertion physicalNoInterfaceEval.config.nixosConfigurations.kamrui-h1.config "physical link 'foo' of machine 'kamrui-h1' must set exactly one of 'interface', 'match.mac' and 'match.path'";
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
