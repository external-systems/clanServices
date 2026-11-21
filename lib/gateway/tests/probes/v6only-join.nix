# Probe PR4 (specs/gateway.md §6; SPEC.md D67): the <distro>-join suite,
# unchanged, on machines whose only NIC address is IPv6. Node addresses
# stay the dual-stack fabric addresses; the WireGuard endpoints are the
# IPv6 underlay addresses. The suite's own test script is the assertion.
{
  lib,
  inputs,
  distro,
}: let
  body = import ../../../kube-cluster/tests/vm/join.nix {inherit lib inputs distro;};
  underlay = {
    alpha = "2001:db8:1::1";
    beta = "2001:db8:1::2";
  };
in
  lib.recursiveUpdate body {
    name = "probe-${distro}-v6only";

    clan.inventory.instances.underlay.roles.default.machines =
      lib.mapAttrs (_: host: {settings = {inherit host;};}) underlay;

    nodes =
      lib.mapAttrs (name: address: {
        imports = [body.nodes.${name}];
        networking.ifstate.settings.interfaces.eth1.addresses = lib.mkForce ["${address}/64"];
      })
      underlay;
  }
