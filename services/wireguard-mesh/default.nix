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
      inputs = [
        "peer"
        "netif"
        "kube_cluster"
      ];
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
      ulaGenerator = "wireguard-mesh-${instanceName}-ula";
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

      prefixFile = file:
        allocation {
          generator = prefixGenerator;
          inherit file;
        };
      ulaBase = builtins.head (
        lib.splitString "::" (
          allocation {
            generator = ulaGenerator;
            file = "ula48";
          }
        )
      );
      poolRecordDrift = prefixFile "ipv4-pool" != settings.ipv4Pool;
      allocationMembershipErrors = lib.concatMap (
        name: let
          memberSettings = allMembers.${name}.settings;
          address = resolvedAddr name;
        in
          lib.optional (
            memberSettings.ipv4 == null && !cidr.contains settings.ipv4Pool "${address.ipv4}/32"
          ) "${name}/ipv4=${address.ipv4} outside ipv4Pool=${settings.ipv4Pool}; run: clan vars generate ${name} --generator ${nodeGenerator} --regenerate"
          ++ lib.optional (
            memberSettings.ipv6 == null && !cidr.contains "${ulaBase}:0::/64" "${address.ipv6}/128"
          ) "${name}/ipv6=${address.ipv6} outside ${ulaBase}:0::/64; run: clan vars generate ${name} --generator ${nodeGenerator} --regenerate"
      ) (builtins.attrNames allMembers);
      allocationPools = [
        {
          name = "ipv4Pool";
          cidr = prefixFile "ipv4-pool";
        }
        {
          name = "loopback6";
          cidr = "${ulaBase}:0::/64";
        }
      ];
      memberNames = builtins.attrNames allMembers;
      memberNetifExports = lib.attrValues (
        clanLib.selectExports (
          scope: scope.serviceName == "netif" && builtins.elem scope.machineName memberNames
        )
        exports
      );
      underlayCidrs = lib.unique (
        lib.concatMap (
          value: lib.concatMap (link: link.addresses) (builtins.attrValues value.netif.links)
        )
        memberNetifExports
      );
      clusterList = map (value: value.kube_cluster) (
        builtins.filter (
          value: let
            facts = value.kube_cluster or null;
            reference =
              if facts == null
              then null
              else facts.network.fabric or facts.transport;
          in
            facts
            != null
            && reference.service
            != null
            && reference.instance != null
            && reference.service == "wireguard-mesh"
            && reference.instance == instanceName
        ) (lib.attrValues (clanLib.selectExports (_: true) exports))
      );
      memberClusterList =
        builtins.filter (
          facts: lib.any (name: facts.members ? ${name}) memberNames
        )
        clusterList;
      clusterCidrs = lib.unique (
        lib.concatMap (
          facts:
            [
              facts.network.podCIDRv4
              facts.network.podCIDRv6
              facts.network.serviceCIDRv4
              facts.network.serviceCIDRv6
            ]
            ++ lib.optionals facts.fabric.enabled [
              facts.fabric.ipv4Block
              facts.fabric.ipv6Block
            ]
        )
        memberClusterList
      );
      externalPoolOverlaps =
        lib.concatMap (
          pool:
            map (prefix: {inherit pool prefix;}) (
              builtins.filter (other: cidr.overlap pool.cidr other) (underlayCidrs ++ clusterCidrs)
            )
        )
        allocationPools;
      internalPoolOverlaps = builtins.filter (
        pair: cidr.overlap pair.first.cidr pair.second.cidr
      ) (pairs allocationPools);

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

        collidingMachines = selector:
          builtins.filter (
            name: name != machine.name && selector name == selector machine.name
          ) (builtins.attrNames allMembers);
        ipv4CollisionMachines = collidingMachines (name: (resolvedAddr name).ipv4);
        ipv6CollisionMachines = collidingMachines (name: (resolvedAddr name).ipv6);
        unequalPoolMembers = builtins.filter (
          name: allMembers.${name}.settings.ipv4Pool != settings.ipv4Pool
        ) (builtins.attrNames allMembers);
        ownPoolKey = "wireguard-mesh/${instanceName}";
        foreignPools = lib.concatMap (
          owner: map (pool: pool // {inherit owner;}) config.clan.networkFacts.allocationPools.${owner}
        ) (builtins.attrNames (removeAttrs config.clan.networkFacts.allocationPools [ownPoolKey]));
        explicitAddressOverlaps =
          lib.concatMap (
            claim: let
              otherPools = builtins.filter (pool: pool.name != claim.ownPool) allocationPools;
              candidates =
                map (pool: pool // {owner = ownPoolKey;}) otherPools
                ++ foreignPools
                ++ map (prefix: {
                  name = "underlay/cluster";
                  cidr = prefix;
                  owner = "member underlay/cluster";
                }) (underlayCidrs ++ clusterCidrs);
            in
              map (pool: "${claim.setting}=${claim.cidr} overlaps ${pool.owner}/${pool.name}=${pool.cidr}") (
                builtins.filter (pool: cidr.overlap claim.cidr pool.cidr) candidates
              )
          ) (
            lib.optional (settings.ipv4 != null) {
              setting = "ipv4";
              cidr = "${ownAddr.ipv4}/32";
              ownPool = "ipv4Pool";
            }
            ++ lib.optional (settings.ipv6 != null) {
              setting = "ipv6";
              cidr = "${ownAddr.ipv6}/128";
              ownPool = "loopback6";
            }
          );
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
            assertion = ipv4CollisionMachines == [];
            message = "wireguard-mesh/${instanceName}: mesh IPv4 ${ownAddr.ipv4} collides on owners ${machine.name}, ${
              lib.concatStringsSep ", " ipv4CollisionMachines
            }; regenerate the newer machine: clan vars generate <newer-machine> --generator ${nodeGenerator} --regenerate";
          }
          {
            assertion = ipv6CollisionMachines == [];
            message = "wireguard-mesh/${instanceName}: mesh IPv6 ${ownAddr.ipv6} collides on owners ${machine.name}, ${
              lib.concatStringsSep ", " ipv6CollisionMachines
            }; regenerate the newer machine: clan vars generate <newer-machine> --generator ${nodeGenerator} --regenerate";
          }
          {
            assertion = allocationMembershipErrors == [];
            message = "wireguard-mesh/${instanceName}: allocated values escaped their pools: ${
              lib.concatStringsSep "; " allocationMembershipErrors
            }";
          }
          {
            assertion = !poolRecordDrift;
            message = "wireguard-mesh/${instanceName}: recorded ipv4Pool differs from the setting; run: clan vars generate ${machine.name} --generator ${prefixGenerator} --regenerate (ULA is unchanged)";
          }
          {
            assertion = cidr.validV4Pool settings.ipv4Pool;
            message = "wireguard-mesh/${instanceName}: ipv4Pool must be a canonical IPv4 CIDR with host bits clear and at least four addresses";
          }
          {
            assertion = unequalPoolMembers == [];
            message = "wireguard-mesh/${instanceName}: ipv4Pool differs on ${
              lib.concatStringsSep ", " unequalPoolMembers
            }; set ipv4Pool identically on every member";
          }
          {
            assertion = internalPoolOverlaps == [];
            message = "wireguard-mesh/${instanceName}: allocation pools overlap (${
              lib.concatMapStringsSep "; " (
                pair: "${pair.first.name}=${pair.first.cidr} with ${pair.second.name}=${pair.second.cidr}"
              )
              internalPoolOverlaps
            }); set ipv4Pool to a member-uniform CIDR disjoint from the ULA";
          }
          {
            assertion = externalPoolOverlaps == [];
            message = "wireguard-mesh/${instanceName}: allocation pools overlap underlay or cluster CIDRs (${
              lib.concatMapStringsSep "; " (
                overlap: "${overlap.pool.name}=${overlap.pool.cidr} with ${overlap.prefix}"
              )
              externalPoolOverlaps
            }); move the conflicting prefix or set ipv4Pool away from it; a deliberate ULA renumber requires: clan vars generate ${machine.name} --generator ${ulaGenerator} --regenerate";
          }
          {
            assertion = explicitAddressOverlaps == [];
            message = "wireguard-mesh/${instanceName}: explicit addresses overlap foreign pools or member underlay/cluster CIDRs: ${
              lib.concatStringsSep "; " explicitAddressOverlaps
            }; choose addresses outside those prefixes";
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
          ${ulaGenerator} = {
            share = true;
            files.ula48 = {
              secret = false;
              deploy = false;
            };
            runtimeInputs = [pkgs.python3];
            script = ''
              python3 - <<'PY'
              import os
              import secrets
              from pathlib import Path

              out = Path(os.environ["out"])
              ula = f"fd{secrets.randbits(40):010x}"
              (out / "ula48").write_text(f"{ula[:4]}:{ula[4:8]}:{ula[8:12]}::/48\n")
              PY
            '';
          };
          ${prefixGenerator} = {
            share = true;
            files.ipv4-pool = {
              secret = false;
              deploy = false;
            };
            validation.ipv4Pool = settings.ipv4Pool;
            runtimeInputs = [pkgs.python3];
            script = ''
              python3 - <<'PY'
              import os
              from pathlib import Path

              out = Path(os.environ["out"])
              (out / "ipv4-pool").write_text("${settings.ipv4Pool}\n")
              PY
            '';
          };
          ${nodeGenerator} = {
            dependencies = [ulaGenerator prefixGenerator];
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

              inputs = Path(os.environ["in"])
              out = Path(os.environ["out"])
              ula = ipaddress.IPv6Network((inputs / "${ulaGenerator}" / "ula48").read_text().strip())
              pool = ipaddress.IPv4Network((inputs / "${prefixGenerator}" / "ipv4-pool").read_text().strip())
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

        clan._networkFacts.allocationPools."wireguard-mesh/${instanceName}" = allocationPools;
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
