{
  clanLib,
  config,
  lib,
  ...
}:
let
  interfaceName =
    instanceName: settings:
    if settings.interface == null then "wg-${instanceName}" else settings.interface;

  domainName =
    instanceName: settings: if settings.domain == null then instanceName else settings.domain;

  resolveHostValue =
    hostItem:
    hostItem.plain or (
      if hostItem ? var then
        clanLib.getPublicValue (hostItem.var // { default = ""; })
      else
        throw "wireguard-mesh: unknown peer host value: ${builtins.toJSON hostItem}"
    );

  resolveEndpoint =
    {
      exports,
      sources,
      machineName,
    }:
    let
      hostsForSource =
        source:
        let
          matches = lib.attrValues (
            clanLib.selectExports (
              scope:
              scope.serviceName == source.service
              && scope.instanceName == source.instance
              && scope.machineName == machineName
            ) exports
          );
        in
        lib.concatMap (value: value.peer.hosts or [ ]) matches;
      values = lib.filter (value: value != "" && value != null) (
        map (host: lib.trim (resolveHostValue host)) (lib.concatMap hostsForSource sources)
      );
    in
    if values == [ ] then null else builtins.head values;

  endpointString =
    {
      host,
      port,
    }:
    if host == null then
      null
    else if lib.hasInfix ":" host then
      "[${host}]:${toString port}"
    else
      "${host}:${toString port}";
in
{
  _class = "clan.service";
  manifest = {
    name = "wireguard-mesh";
    description = "Dual-stack host-level WireGuard full mesh with composable endpoint discovery";
    categories = [ "Network" ];
    readme = builtins.readFile ./README.md;
    exports = {
      inputs = [ "peer" ];
      out = [
        "networking"
        "peer"
        "node_transport"
      ];
    };
  };

  exports = lib.mapAttrs' (instanceName: _: {
    name = clanLib.buildScopeKey {
      inherit instanceName;
      serviceName = config.manifest.name;
    };
    value.networking.priority = 1000;
  }) config.instances;

  roles.peer = {
    description = "A dual-stack member that connects directly to every other member of the mesh";
    interface =
      { lib, ... }:
      {
        options = {
          ipv4 = lib.mkOption {
            type = lib.types.str;
            example = "192.168.77.1";
            description = "The machine's mesh IPv4 host address, without a prefix length.";
          };
          ipv6 = lib.mkOption {
            type = lib.types.str;
            example = "fd00:77::1";
            description = "The machine's mesh IPv6 host address, without a prefix length.";
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
            default = [ ];
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
            default = [ ];
            example = [ "10.77.10.0/24" ];
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

    perInstance =
      {
        instanceName,
        settings,
        machine,
        roles,
        exports,
        mkExports,
        ...
      }:
      let
        generatorName = "wireguard-mesh-${instanceName}";
        interface = interfaceName instanceName settings;
        allMembers = roles.peer.machines;
        peerMembers = lib.filterAttrs (name: _: name != machine.name) allMembers;

        endpointOf =
          name:
          let
            memberSettings = allMembers.${name}.settings;
          in
          if memberSettings.endpoint != null then
            memberSettings.endpoint
          else
            resolveEndpoint {
              inherit exports;
              sources = memberSettings.endpointSources;
              machineName = name;
            };

        peerEntries = lib.mapAttrsToList (name: member: {
          inherit name;
          inherit (member.settings)
            ipv4
            ipv6
            extraAllowedIPs
            persistentKeepalive
            ;
          endpoint = endpointString {
            host = endpointOf name;
            port = member.settings.port;
          };
        }) peerMembers;

        hostEntries = lib.concatMapStringsSep "\n" (
          name:
          let
            memberSettings = allMembers.${name}.settings;
            hostname = "${name}.${domainName instanceName memberSettings}";
          in
          "${memberSettings.ipv4} ${hostname}\n${memberSettings.ipv6} ${hostname}"
        ) (lib.attrNames allMembers);
      in
      {
        exports = mkExports {
          peer.hosts = [
            {
              plain = "${machine.name}.${domainName instanceName settings}";
            }
          ];
          node_transport = {
            inherit (settings)
              ipv4
              ipv6
              port
              mtu
              ;
            inherit interface;
            instance = instanceName;
            endpoint = endpointString {
              host = endpointOf machine.name;
              inherit (settings) port;
            };
          };
        };

        nixosModule =
          {
            config,
            pkgs,
            lib,
            ...
          }:
          let
            privateKeyFile = config.clan.core.vars.generators.${generatorName}.files.privatekey.path;
            netdevName = "40-wireguard-mesh-${instanceName}";

            publicKeyOf =
              name:
              lib.trim (
                clanLib.getPublicValue {
                  generator = generatorName;
                  machine = name;
                  file = "publickey";
                  flake = config.clan.core.settings.directory;
                  default = throw "wireguard-mesh/${instanceName}: no public key for peer '${name}'; run 'clan vars generate ${name} --generator ${generatorName}'";
                }
              );

            wireguardPeers = map (
              peer:
              {
                PublicKey = publicKeyOf peer.name;
                AllowedIPs = [
                  "${peer.ipv4}/32"
                  "${peer.ipv6}/128"
                ]
                ++ peer.extraAllowedIPs;
              }
              // lib.optionalAttrs (peer.endpoint != null) { Endpoint = peer.endpoint; }
              // lib.optionalAttrs (peer.persistentKeepalive != null) {
                PersistentKeepalive = peer.persistentKeepalive;
              }
            ) peerEntries;

            peerRoutes = lib.concatMap (
              peer:
              [
                { Destination = "${peer.ipv4}/32"; }
                { Destination = "${peer.ipv6}/128"; }
              ]
              ++ map (prefix: { Destination = prefix; }) peer.extraAllowedIPs
            ) peerEntries;

            allV4s = map (name: allMembers.${name}.settings.ipv4) (lib.attrNames allMembers);
            allV6s = map (name: allMembers.${name}.settings.ipv6) (lib.attrNames allMembers);
            endpoints = map endpointOf (lib.attrNames allMembers);
          in
          {
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
                assertion = !lib.hasInfix "/" settings.ipv4 && !lib.hasInfix ":" settings.ipv4;
                message = "wireguard-mesh/${instanceName}: ipv4 must be an IPv4 host address without a prefix length";
              }
              {
                assertion = !lib.hasInfix "/" settings.ipv6 && lib.hasInfix ":" settings.ipv6;
                message = "wireguard-mesh/${instanceName}: ipv6 must be an IPv6 host address without a prefix length";
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
                assertion =
                  lib.length (lib.attrNames allMembers) <= 1 || lib.any (endpoint: endpoint != null) endpoints;
                message = "wireguard-mesh/${instanceName}: a multi-member mesh needs at least one explicit endpoint or endpointSources match";
              }
            ];

            networking = {
              useNetworkd = true;
              firewall = {
                allowedUDPPorts = lib.optionals settings.firewall.openPort [ settings.port ];
                trustedInterfaces = lib.optionals settings.firewall.trust [ interface ];
              };
              networkmanager.unmanaged = [ interface ];
              extraHosts = hostEntries;
            };

            clan.core.vars.generators.${generatorName} = {
              files.privatekey = {
                owner = "systemd-network";
                group = "systemd-network";
                mode = "0400";
                restartUnits = [ "systemd-networkd.service" ];
              };
              files.publickey = {
                secret = false;
                deploy = false;
              };
              runtimeInputs = [ pkgs.wireguard-tools ];
              script = ''
                wg genkey > "$out"/privatekey
                wg pubkey < "$out"/privatekey > "$out"/publickey
              '';
            };

            environment.systemPackages = [ pkgs.wireguard-tools ];

            systemd.network = {
              enable = true;
              netdevs.${netdevName} = {
                netdevConfig = {
                  Kind = "wireguard";
                  Name = interface;
                  MTUBytes = settings.mtu;
                };
                wireguardConfig = {
                  PrivateKeyFile = privateKeyFile;
                  ListenPort = settings.port;
                };
                inherit wireguardPeers;
              };
              networks.${netdevName} = {
                matchConfig.Name = interface;
                address = [
                  "${settings.ipv4}/32"
                  "${settings.ipv6}/128"
                ];
                routes = peerRoutes;
              };
            };
          };
      };
  };

  perMachine =
    { instances, machine, ... }:
    {
      nixosModule =
        { lib, ... }:
        let
          memberships = lib.filterAttrs (
            _: instance: instance.roles ? peer && instance.roles.peer.machines ? ${machine.name}
          ) instances;
          members = lib.mapAttrsToList (instanceName: instance: {
            inherit instanceName;
            settings = instance.roles.peer.machines.${machine.name}.settings;
          }) memberships;
          interfaces = map (member: interfaceName member.instanceName member.settings) members;
          ports = map (member: member.settings.port) members;
        in
        {
          assertions = [
            {
              assertion = lib.length (lib.unique interfaces) == lib.length interfaces;
              message = "wireguard-mesh: machine '${machine.name}' has duplicate interface names across mesh instances: ${lib.concatStringsSep ", " interfaces}";
            }
            {
              assertion = lib.length (lib.unique ports) == lib.length ports;
              message = "wireguard-mesh: machine '${machine.name}' has duplicate WireGuard listen ports across mesh instances: ${lib.concatStringsSep ", " (map toString ports)}";
            }
          ];
        };
    };
}
