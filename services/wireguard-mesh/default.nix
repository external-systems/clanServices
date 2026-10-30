{ifstateOverlay}: {
  clanLib,
  config,
  directory,
  lib,
  ...
}: let
  cidr = import ../../lib/kube-cluster/cidr.nix {inherit lib;};

  pairs = values:
    lib.concatMap (
      i:
        map (j: {
          first = builtins.elemAt values i;
          second = builtins.elemAt values j;
        }) (lib.range (i + 1) (builtins.length values - 1))
    ) (lib.range 0 (builtins.length values - 2));

  interfaceName = instanceName: settings:
    if settings.interface == null
    then "wg-${instanceName}"
    else settings.interface;

  domainName = instanceName: settings:
    if settings.domain == null
    then instanceName
    else settings.domain;

  resolveHostValue = hostItem:
    hostItem.plain or (
      if hostItem ? var
      then clanLib.getPublicValue (hostItem.var // {default = "";})
      else throw "wireguard-mesh: unknown peer host value: ${builtins.toJSON hostItem}"
    );

  resolveEndpoint = {
    exports,
    sources,
    machineName,
  }: let
    hostsForSource = source: let
      matches = lib.attrValues (
        clanLib.selectExports (
          scope:
            scope.serviceName
            == source.service
            && scope.instanceName == source.instance
            && scope.machineName == machineName
        )
        exports
      );
    in
      lib.concatMap (value: value.peer.hosts or []) matches;
    values = lib.filter (value: value != "" && value != null) (
      map (host: lib.trim (resolveHostValue host)) (lib.concatMap hostsForSource sources)
    );
  in
    if values == []
    then null
    else builtins.head values;

  endpointString = {
    host,
    port,
  }:
    if host == null
    then null
    else if lib.hasInfix ":" host
    then "[${host}]:${toString port}"
    else "${host}:${toString port}";
in {
  _class = "clan.service";
  manifest = {
    name = "wireguard-mesh";
    description = "Dual-stack host-level WireGuard full mesh with composable endpoint discovery";
    categories = ["Network"];
    readme = builtins.readFile ./README.md;
    exports = {
      inputs = ["peer"];
      out = [
        "networking"
        "peer"
        "node_transport"
      ];
    };
  };

  exports =
    lib.mapAttrs' (instanceName: _: {
      name = clanLib.buildScopeKey {
        inherit instanceName;
        serviceName = config.manifest.name;
      };
      value.networking.priority = 1000;
    })
    config.instances;

  roles.peer = {
    description = "A dual-stack member that connects directly to every other member of the mesh";
    interface = {lib, ...}: {
      options = {
        ipv4 = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "198.18.128.1";
          description = ''
            The machine's mesh IPv4 host address, without a prefix
            length. Null reads the public node allocation.
          '';
        };
        ipv6 = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "fd64:6464:6464::1";
          description = ''
            The machine's mesh IPv6 host address, without a prefix
            length. Null reads the public node allocation.
          '';
        };
        ipv4Pool = lib.mkOption {
          type = lib.types.str;
          default = "198.18.128.0/17";
          description = "Member-uniform IPv4 allocation pool recorded by the shared prefix generator.";
        };
        interface = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "The WireGuard interface name. Null derives wg-<instanceName>.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 51820;
          description = "The machine's WireGuard UDP listen port.";
        };
        mtu = lib.mkOption {
          type = lib.types.ints.positive;
          default = 1420;
          description = "The WireGuard link MTU. Dual-stack meshes require at least 1280.";
        };
        domain = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "DNS suffix for mesh hostnames. Null uses the instance name.";
        };
        endpoint = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "vpn.example.com";
          description = "Explicit externally reachable hostname or address, without brackets or a port.";
        };
        endpointSources = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                service = lib.mkOption {
                  type = lib.types.str;
                  description = "The exporting service's manifest name.";
                };
                instance = lib.mkOption {
                  type = lib.types.str;
                  description = "The exporting service instance name.";
                };
              };
            }
          );
          default = [];
          example = [
            {
              service = "clan-core/internet";
              instance = "internet";
            }
          ];
          description = "Ordered export sources whose peer.hosts values provide endpoints.";
        };
        persistentKeepalive = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = 25;
          description = "Keepalive interval in seconds for this machine's peer entries; null disables it.";
        };
        extraAllowedIPs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = ["10.77.10.0/24"];
          description = "Additional prefixes other members route to this machine through WireGuard.";
        };
        firewall = {
          openPort = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Open the WireGuard UDP port in the NixOS firewall.";
          };
          trust = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Trust traffic arriving on the WireGuard interface.";
          };
        };
      };
    };

    perInstance = {
      instanceName,
      settings,
      machine,
      roles,
      exports,
      mkExports,
      ...
    }: let
      generatorName = "wireguard-mesh-${instanceName}";
      prefixGenerator = "wireguard-mesh-${instanceName}-prefixes";
      nodeGenerator = "wireguard-mesh-${instanceName}-node";
      interface = interfaceName instanceName settings;
      allMembers = roles.peer.machines;
      peerMembers = lib.filterAttrs (name: _: name != machine.name) allMembers;

      allocation = {
        generator,
        file,
        machineName ? null,
        generateMachine ? machine.name,
      }:
        lib.trim (
          clanLib.getPublicValue {
            inherit generator file;
            flake = directory;
            machine = machineName;
            default = throw "wireguard-mesh/${instanceName}: no allocation for ${
              if machineName == null
              then generateMachine
              else machineName
            } (${generator}/${file}); run: clan vars generate ${generateMachine} --generator ${generator}";
          }
        );

      resolvedAddr = name: let
        memberSettings = allMembers.${name}.settings;
      in {
        ipv4 =
          if memberSettings.ipv4 != null
          then memberSettings.ipv4
          else
            allocation {
              generator = nodeGenerator;
              machineName = name;
              generateMachine = name;
              file = "ipv4";
            };
        ipv6 =
          if memberSettings.ipv6 != null
          then memberSettings.ipv6
          else
            allocation {
              generator = nodeGenerator;
              machineName = name;
              generateMachine = name;
              file = "ipv6";
            };
      };
      ownAddr = resolvedAddr machine.name;

      endpointOf = name: let
        memberSettings = allMembers.${name}.settings;
      in
        if memberSettings.endpoint != null
        then memberSettings.endpoint
        else
          resolveEndpoint {
            inherit exports;
            sources = memberSettings.endpointSources;
            machineName = name;
          };

      peerEntries =
        lib.mapAttrsToList (name: member: {
          inherit name;
          inherit (resolvedAddr name) ipv4 ipv6;
          inherit
            (member.settings)
            extraAllowedIPs
            persistentKeepalive
            ;
          endpoint = endpointString {
            host = endpointOf name;
            port = member.settings.port;
          };
        })
        peerMembers;

      unreachablePeers =
        builtins.filter (
          peer: peer.endpoint == null && endpointOf machine.name == null
        )
        peerEntries;
      allowedIPClaims = lib.concatMap (
        name:
          map (prefix: {
            peer = name;
            inherit prefix;
          })
          allMembers.${name}.settings.extraAllowedIPs
      ) (builtins.attrNames allMembers);
      overlappingExtraAllowedIPs = builtins.filter (
        pair:
          pair.first.peer
          != pair.second.peer
          && cidr.overlap pair.first.prefix pair.second.prefix
      ) (pairs allowedIPClaims);

      hostEntries = lib.concatMapStringsSep "\n" (
        name: let
          memberSettings = allMembers.${name}.settings;
          addr = resolvedAddr name;
          hostname = "${name}.${domainName instanceName memberSettings}";
        in "${addr.ipv4} ${hostname}\n${addr.ipv6} ${hostname}"
      ) (lib.attrNames allMembers);
    in {
      exports = mkExports {
        peer.hosts = [
          {
            plain = "${machine.name}.${domainName instanceName settings}";
          }
        ];
        node_transport = {
          schemaVersion = 2;
          inherit (ownAddr) ipv4 ipv6;
          inherit (settings) port;
          instance = instanceName;
          interfaces = {
            ${interface} = {
              inherit (settings) mtu;
            };
          };
          directRoutingDevice = interface;
          endpoint = endpointString {
            host = endpointOf machine.name;
            inherit (settings) port;
          };
          datapath = {
            mode = "tunnel";
            tunnelProtocol = "vxlan";
          };
          native.routeExchange = null;
          internalLoadBalancer = false;
          nodePort = true;
        };
      };

      nixosModule = {
        config,
        pkgs,
        lib,
        ...
      }: let
        privateKeyFile = config.clan.core.vars.generators.${generatorName}.files.privatekey.path;

        publicKeyOf = name:
          lib.trim (
            clanLib.getPublicValue {
              generator = generatorName;
              machine = name;
              file = "publickey";
              flake = config.clan.core.settings.directory;
              default = throw "wireguard-mesh/${instanceName}: no public key for peer '${name}'; run 'clan vars generate ${name} --generator ${generatorName}'";
            }
          );

        wireguardPeers = lib.listToAttrs (
          map (peer: {
            name = publicKeyOf peer.name;
            value =
              {
                allowedips =
                  [
                    "${peer.ipv4}/32"
                    "${peer.ipv6}/128"
                  ]
                  ++ peer.extraAllowedIPs;
              }
              // lib.optionalAttrs (peer.endpoint != null) {inherit (peer) endpoint;}
              // lib.optionalAttrs (peer.persistentKeepalive != null) {
                persistent_keepalive_interval = peer.persistentKeepalive;
              };
          })
          peerEntries
        );

        peerRoutes =
          lib.concatMap (
            peer:
              [
                {
                  to = "${peer.ipv4}/32";
                  dev = interface;
                }
                {
                  to = "${peer.ipv6}/128";
                  dev = interface;
                }
              ]
              ++ map (prefix: {
                to = prefix;
                dev = interface;
              })
              peer.extraAllowedIPs
          )
          peerEntries;

        allV4s = map (name: (resolvedAddr name).ipv4) (lib.attrNames allMembers);
        allV6s = map (name: (resolvedAddr name).ipv6) (lib.attrNames allMembers);
      in {
        assertions = [
          {
            assertion = lib.stringLength interface <= 15;
            message = "wireguard-mesh/${instanceName}: interface '${interface}' exceeds the 15-character kernel limit; set a shorter interface name";
          }
          {
            assertion = builtins.match "[A-Za-z0-9_.-]+" interface != null;
            message = "wireguard-mesh/${instanceName}: interface '${interface}' contains unsupported characters";
          }
          {
            assertion = settings.mtu >= 1280;
            message = "wireguard-mesh/${instanceName}: dual-stack operation requires mtu >= 1280";
          }
          {
            assertion = !lib.hasInfix "/" ownAddr.ipv4 && !lib.hasInfix ":" ownAddr.ipv4;
            message = "wireguard-mesh/${instanceName}: ipv4 must be an IPv4 host address without a prefix length (got '${ownAddr.ipv4}' for machine '${machine.name}')";
          }
          {
            assertion = !lib.hasInfix "/" ownAddr.ipv6 && lib.hasInfix ":" ownAddr.ipv6;
            message = "wireguard-mesh/${instanceName}: ipv6 must be an IPv6 host address without a prefix length (got '${ownAddr.ipv6}' for machine '${machine.name}')";
          }
          {
            assertion = lib.length (lib.unique allV4s) == lib.length allV4s;
            message = "wireguard-mesh/${instanceName}: mesh IPv4 addresses must be unique; got ${lib.concatStringsSep ", " allV4s}";
          }
          {
            assertion = lib.length (lib.unique allV6s) == lib.length allV6s;
            message = "wireguard-mesh/${instanceName}: mesh IPv6 addresses must be unique; got ${lib.concatStringsSep ", " allV6s}";
          }
          {
            assertion = unreachablePeers == [];
            message = "wireguard-mesh/${instanceName}: every member pair needs an endpoint on at least one side; unreachable from '${machine.name}' to ${
              lib.concatMapStringsSep ", " (peer: peer.name) unreachablePeers
            }";
          }
          {
            assertion = overlappingExtraAllowedIPs == [];
            message = "wireguard-mesh/${instanceName}: extraAllowedIPs overlap between peers: ${
              lib.concatMapStringsSep "; " (
                pair: "${pair.first.peer}=${pair.first.prefix} overlaps ${pair.second.peer}=${pair.second.prefix}"
              )
              overlappingExtraAllowedIPs
            }";
          }
        ];

        networking = {
          ifstate.settings = {
            interfaces.${interface} = {
              addresses = [
                "${ownAddr.ipv4}/32"
                "${ownAddr.ipv6}/128"
              ];
              link = {
                kind = "wireguard";
                state = "up";
                inherit (settings) mtu;
              };
              wireguard = {
                private_key = "!include ${privateKeyFile}";
                listen_port = settings.port;
                peers = wireguardPeers;
              };
            };
            routing.routes = peerRoutes;
          };
          firewall = {
            allowedUDPPorts = lib.optionals settings.firewall.openPort [settings.port];
            trustedInterfaces = lib.optionals settings.firewall.trust [interface];
          };
          extraHosts = hostEntries;
        };

        clan.core.vars.generators = {
          ${generatorName} = {
            files.privatekey = {
              owner = "root";
              group = "root";
              mode = "0400";
              restartUnits = ["ifstate.service"];
            };
            files.publickey = {
              secret = false;
              deploy = false;
            };
            runtimeInputs = [pkgs.wireguard-tools];
            script = ''
              wg genkey > "$out"/privatekey
              wg pubkey < "$out"/privatekey > "$out"/publickey
            '';
          };
          ${prefixGenerator} = {
            share = true;
            files = lib.genAttrs ["ula48" "ipv4-pool"] (_: {
              secret = false;
              deploy = false;
            });
            validation.ipv4Pool = settings.ipv4Pool;
            runtimeInputs = [pkgs.python3];
            script = ''
              python3 - <<'PY'
              import ipaddress
              import os
              import secrets
              from pathlib import Path

              out = Path(os.environ["out"])
              ula = f"fd{secrets.randbits(40):010x}"
              (out / "ula48").write_text(f"{ula[:4]}:{ula[4:8]}:{ula[8:12]}::/48\n")
              (out / "ipv4-pool").write_text("${settings.ipv4Pool}\n")
              PY
            '';
          };
          ${nodeGenerator} = {
            dependencies = [prefixGenerator];
            files = lib.genAttrs ["ipv4" "ipv6"] (_: {
              secret = false;
              deploy = false;
            });
            runtimeInputs = [pkgs.python3];
            script = ''
              python3 - <<'PY'
              import ipaddress
              import os
              import secrets
              from pathlib import Path

              inputs = Path(os.environ["in"]) / "${prefixGenerator}"
              out = Path(os.environ["out"])
              ula = ipaddress.IPv6Network((inputs / "ula48").read_text().strip())
              pool = ipaddress.IPv4Network((inputs / "ipv4-pool").read_text().strip())
              if pool.num_addresses < 4:
                  raise ValueError("ipv4Pool must contain at least four addresses")
              ipv4 = pool.network_address + 1 + secrets.randbelow(pool.num_addresses - 2)
              loopback6 = ipaddress.IPv6Network((int(ula.network_address), 64))
              ipv6 = loopback6.network_address + secrets.randbits(64)
              (out / "ipv4").write_text(f"{ipv4}\n")
              (out / "ipv6").write_text(f"{ipv6}\n")
              PY
            '';
          };
        };

        environment.systemPackages = [pkgs.wireguard-tools];
      };
    };
  };

  perMachine = {
    instances,
    machine,
    ...
  }: {
    nixosModule = {
      config,
      lib,
      ...
    }: let
      memberships =
        lib.filterAttrs (
          _: instance: instance.roles ? peer && instance.roles.peer.machines ? ${machine.name}
        )
        instances;
      members =
        lib.mapAttrsToList (instanceName: instance: {
          inherit instanceName;
          settings = instance.roles.peer.machines.${machine.name}.settings;
        })
        memberships;
      interfaces = map (member: interfaceName member.instanceName member.settings) members;
      ports = map (member: member.settings.port) members;
      routedFabricPorts = lib.concatMap (
        fabric: map (adjacency: adjacency.port) (builtins.attrValues fabric.adjacencies)
      ) (builtins.attrValues config.clan.networkFacts.fabric);
      routedFabricPortClashes = lib.intersectLists ports routedFabricPorts;
    in {
      imports = [
        (import ../../lib/ifstate.nix {inherit ifstateOverlay;})
        ../../lib/kube-cluster/network-facts.nix
      ];

      assertions = [
        {
          assertion = lib.length (lib.unique interfaces) == lib.length interfaces;
          message = "wireguard-mesh: machine '${machine.name}' has duplicate interface names across mesh instances: ${lib.concatStringsSep ", " interfaces}";
        }
        {
          assertion = lib.length (lib.unique ports) == lib.length ports;
          message = "wireguard-mesh: machine '${machine.name}' has duplicate WireGuard listen ports across mesh instances: ${lib.concatStringsSep ", " (map toString ports)}";
        }
        {
          assertion = routedFabricPortClashes == [];
          message = "wireguard-mesh: machine '${machine.name}' has WireGuard listen-port clashes with routed-fabric: ${lib.concatStringsSep ", " (map toString routedFabricPortClashes)}";
        }
      ];
    };
  };
}
