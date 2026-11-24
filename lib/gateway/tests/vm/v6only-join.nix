# <distro>-v6only (SPEC.md D67; specs/gateway.md §10.5): the <distro>-join
# suite, unchanged, on machines whose only NIC address is IPv6. Node
# addresses stay the dual-stack fabric addresses; the WireGuard endpoints
# are the IPv6 underlay addresses. The join suite's test script is the
# assertion; one more phase pins that no NIC has an IPv4 address and that
# the fabric runs over IPv6 endpoints.
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
    name = "${distro}-v6only";

    clan.inventory.instances.underlay.roles.default.machines =
      lib.mapAttrs (_: host: {settings = {inherit host;};}) underlay;

    nodes =
      lib.mapAttrs (name: address: {
        imports = [body.nodes.${name}];
        networking.ifstate.settings.interfaces.eth1.addresses = lib.mkForce ["${address}/64"];
      })
      underlay;

    # The phase is spliced in before the join suite's marker. Fail the
    # evaluation when that marker is gone: a miss would drop the phase
    # and leave the suite green.
    testScript = assert lib.hasInfix "print(\"${lib.toUpper distro}_JOIN_OK\")" body.testScript;
      builtins.replaceStrings
      ["print(\"${lib.toUpper distro}_JOIN_OK\")"]
      [
        (lib.concatStringsSep "\n    " [
          "with subtest(\"no NIC has an IPv4 address; the fabric runs over IPv6 endpoints (D67)\"):"
          "    for node in [alpha, beta]:"
          "        assert \"inet \" not in node.succeed(\"ip -4 -br addr show dev eth1\"), f\"{node.name}: the NIC has an IPv4 address\""
          "        endpoints = [line.split()[-1] for line in node.succeed(\"wg show all endpoints\").strip().splitlines()]"
          "        assert endpoints and all(endpoint.startswith(\"[2001:db8:1::\") for endpoint in endpoints), f\"{node.name}: {endpoints}\""
          "print(\"${lib.toUpper distro}_V6ONLY_OK\")"
        ])
      ]
      body.testScript;
  }
