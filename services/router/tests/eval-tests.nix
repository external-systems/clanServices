{
  module,
  netifModule,
  exportInterfaces,
  clanLib,
  lib,
  ...
}: let
  machineConfigs = {
    router.nixpkgs.hostPlatform = "x86_64-linux";
  };

  baseInventory = {
    instances = {
      wan = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.router.settings.links.wan = {
          interface = "enp1s0";
          zone = "wan";
          dhcp = {
            ipv4 = true;
            ipv6 = true;
            prefixDelegation = {
              enable = true;
              hint = 60;
              assign = [
                {
                  instance = "lan";
                  link = "home";
                  subnet = 1;
                }
                {
                  instance = "lan";
                  link = "servers";
                  subnet = 2;
                }
              ];
            };
          };
        };
      };
      lan = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.router.settings.links = {
          home = {
            interface = "enp2s0";
            zone = "home";
            static = {
              ipv4 = ["192.168.10.1/24"];
              ipv6 = ["fd00:10:1::1/64"];
            };
            ra = false;
          };
          servers = {
            interface = "enp3s0";
            zone = "servers";
            static = {
              ipv4 = ["192.168.20.1/24"];
              ipv6 = ["fd00:10:2::1/64"];
            };
            ra = false;
          };
          mgmt = {
            interface = "enp4s0";
            zone = "mgmt";
            static.ipv4 = ["192.168.99.1/24"];
            ra = false;
          };
        };
      };
      edge = {
        module.name = "router";
        module.input = "self";
        roles.router.machines.router.settings = {
          zones = {
            home.allowTo = ["servers"];
            servers.dhcp = false;
            mgmt.internet = false;
          };
          domain = "home.test";
          servicePrefix = {
            subnet = 15;
            stable = "fd00:10:5::/64";
            expose = [
              {
                address = "fd00:10:5::80";
                protocol = "tcp";
                ports = [80 443];
              }
            ];
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
        router = module;
        netif = netifModule;
      };
    };
  router = inventory: (mkEvaled inventory).config.nixosConfigurations.router.config;
  base = router baseInventory;
  cfg = base.clanServices.gateway.router;
  table = base.networking.nftables.tables.router.content;
  failedAssertion = config: needle:
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) config.assertions;
  with' = patch: router (lib.recursiveUpdate baseInventory patch);
in {
  # Zones resolve from netif: links, the router's addresses, the subnet
  # id of the delegation, the DHCPv4 pool (upper half).
  test_zonesFromNetif = {
    expr = {
      inherit (cfg) wan;
      home = cfg.zones.home;
      servers = {inherit (cfg.zones.servers) subnet dhcp4 dns;};
      mgmt = {inherit (cfg.zones.mgmt) subnet dns internet;};
    };
    expected = {
      wan = "enp1s0";
      home = {
        interfaces = ["enp2s0"];
        internet = true;
        allowTo = ["servers"];
        ssh = true;
        subnet = 1;
        dns = {
          ipv4 = "192.168.10.1";
          ipv6 = "fd00:10:1::1";
        };
        dhcp4 = {
          subnet = "192.168.10.0/24";
          router = "192.168.10.1";
          pool = "192.168.10.128 - 192.168.10.254";
        };
      };
      servers = {
        subnet = 2;
        dhcp4 = null;
        dns = {
          ipv4 = "192.168.20.1";
          ipv6 = "fd00:10:2::1";
        };
      };
      mgmt = {
        subnet = null;
        dns = {
          ipv4 = "192.168.99.1";
          ipv6 = null;
        };
        internet = false;
      };
    };
  };
  # G11: default deny; each allowed flow is one rule; G20's pinhole.
  test_forwardRules = {
    expr = {
      homeInternet = lib.hasInfix ''iifname { "enp2s0" } oifname { "enp1s0" } accept comment "zone home: internet"'' table;
      homeServers = lib.hasInfix ''iifname { "enp2s0" } oifname { "enp3s0" } accept comment "zone home: servers"'' table;
      mgmtInternet = lib.hasInfix ''zone mgmt: internet'' table;
      serversHome = lib.hasInfix ''zone servers: home'' table;
      pinhole = lib.hasInfix ''ip6 daddr fd00:10:5::80 meta l4proto tcp th dport { 80, 443 } accept'' table;
      dropPolicy = lib.hasInfix "type filter hook forward priority filter; policy drop;" table;
      nat = lib.hasInfix ''oifname { "enp1s0" } meta nfproto ipv4 masquerade'' table;
      firewall = base.networking.firewall.enable;
    };
    expected = {
      homeInternet = true;
      homeServers = true;
      mgmtInternet = false;
      serversHome = false;
      pinhole = true;
      dropPolicy = true;
      nat = true;
      firewall = false;
    };
  };
  # G14: a resolver per zone, port 53 only from that zone
  test_dns = {
    expr = {
      bind = lib.hasInfix "bind 192.168.10.1 fd00:10:1::1 192.168.99.1 192.168.20.1 fd00:10:2::1" base.services.coredns.config;
      tls = lib.hasInfix "tls_servername cloudflare-dns.com" base.services.coredns.config;
      homeDns = lib.hasInfix ''iifname { "enp2s0" } ip6 daddr fd00:10:1::1 meta l4proto { tcp, udp } th dport 53 accept'' table;
    };
    expected = {
      bind = true;
      tls = true;
      homeDns = true;
    };
  };
  test_dhcp = {
    expr = map (subnet: {inherit (subnet) subnet interface pools;}) base.services.kea.dhcp4.settings.subnet4;
    expected = [
      {
        subnet = "192.168.10.0/24";
        interface = "enp2s0";
        pools = [{pool = "192.168.10.128 - 192.168.10.254";}];
      }
      {
        subnet = "192.168.99.0/24";
        interface = "enp4s0";
        pools = [{pool = "192.168.99.128 - 192.168.99.254";}];
      }
    ];
  };
  # G22: the hook and corerad's runtime file
  test_hook = {
    expr = {
      path = base.systemd.paths.router-prefix.pathConfig.PathChanged;
      corerad = base.services.corerad.configFile;
      startLimit = base.systemd.services.corerad.unitConfig.StartLimitIntervalSec;
    };
    expected = {
      path = "/run/netif/pd/enp1s0";
      corerad = "/run/router/corerad.toml";
      startLimit = 0;
    };
  };
  test_unknownZone = {
    expr = failedAssertion (with' {instances.edge.roles.router.machines.router.settings.zones.iot = {};}) "no netif link in zone(s) iot";
    expected = true;
  };
  test_unknownAllowTo = {
    expr = failedAssertion (with' {instances.edge.roles.router.machines.router.settings.zones.mgmt.allowTo = ["guest"];}) "zone 'mgmt' may reach unknown zones";
    expected = true;
  };
  test_serviceSubnetOnALink = {
    expr = failedAssertion (with' {instances.edge.roles.router.machines.router.settings.servicePrefix.subnet = 2;}) "servicePrefix.subnet 2 is also assigned";
    expected = true;
  };
}
