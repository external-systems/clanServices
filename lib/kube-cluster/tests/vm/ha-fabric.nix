# <distro>-ha-fabric: the <distro>-ha contract on the routed fabric
# (routed-fabric, FRR, per-pair WireGuard, Cilium native routing) instead
# of the wireguard-mesh tunnel transport. Same machines, same node
# addresses, same test script: only the transport and the name of the
# link that holds the node address differ.
#
# alpha and beta are spines, gamma is a leaf attached to both. The
# manager that dies (beta) is a spine, so the survivors also prove that
# the fabric routes around a dead spine.
{
  lib,
  inputs,
  distro,
}: let
  body = import ./ha.nix {inherit lib inputs distro;};
  loopback = "rflo${builtins.substring 0 10 (builtins.hashString "sha256" "mesh")}";
  member = n: {
    settings = {
      ipv4 = "192.168.77.${toString n}";
      ipv6 = "fd00:77::${toString n}";
      endpointSources = [
        {
          service = "clan-core/internet";
          instance = "underlay";
        }
      ];
    };
  };
  inherit (body.clan) inventory;
in
  body
  // {
    name = "${distro}-ha-fabric";

    clan =
      body.clan
      // {
        modules.routed-fabric = lib.modules.importApply ../../../../services/routed-fabric/default.nix {
          ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
        };
        exportInterfaces = {
          routed_fabric = ../../../../services/routed-fabric/routed-fabric-interface.nix;
          node_transport = ../../../node-transport-interface.nix;
        };
        inventory =
          inventory
          // {
            instances =
              inventory.instances
              // {
                mesh = {
                  module.name = "routed-fabric";
                  module.input = "self";
                  roles = {
                    spine.machines = {
                      alpha = member 1;
                      beta = member 2;
                    };
                    leaf.machines.gamma = member 3;
                  };
                };
                ${distro} = lib.recursiveUpdate inventory.instances.${distro} {
                  roles.server.settings.network.fabric.service = "routed-fabric";
                };
              };
          };
      };

    # Fail the evaluation when the `ha` script no longer has a string
    # replaced here: a miss would leave a mesh check in a fabric suite,
    # or drop the marker, without a red run.
    testScript = assert lib.all (pattern: lib.hasInfix pattern body.testScript) [
      "ip -br addr show wg-mesh"
      "dual-stack full mesh over wg-mesh"
      "print(\"${lib.toUpper distro}_HA_OK\")"
    ];
      builtins.replaceStrings
      [
        "ip -br addr show wg-mesh"
        "dual-stack full mesh over wg-mesh"
        "print(\"${lib.toUpper distro}_HA_OK\")"
      ]
      [
        "ip -br addr show ${loopback}"
        "dual-stack node addresses over the routed fabric"
        "print(\"${lib.toUpper distro}_HA_FABRIC_OK\")"
      ]
      body.testScript;
  }
