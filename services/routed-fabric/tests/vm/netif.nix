# routed-fabric-netif: the routed-fabric suite with every machine's
# underlay declared through the netif service instead of the bare IfState
# fixture (specs/netif.md N14: netif proven under FRR alone, with no
# Kubernetes on the machines). Everything the fabric suite asserts must
# hold unchanged, on links netif does not firewall-trust.
{lib, ...}: {
  imports = [(import ./suite.nix {underlay = "netif";})];

  clan.inventory.instances.lan = {
    module.name = "netif";
    module.input = "self";
    roles.default.machines =
      lib.mapAttrs (_: address: {
        settings.links.uplink = {
          interface = "eth1";
          static.ipv4 = ["${address}/24"];
        };
      }) {
        spine-b = "192.168.1.5";
        alpha = "192.168.1.1";
        beta = "192.168.1.2";
        gamma = "192.168.1.3";
      }
      // {
        # the border's main-table default (N18: metric 100)
        spine-a.settings.links.uplink = {
          interface = "eth1";
          static.ipv4 = ["192.168.1.4/24"];
          gateway.ipv4 = "192.168.1.254";
        };
      };
  };

  # spine-a's gateway is the upstream peer, which this suite does not
  # boot: the lockout guard (N25) would rightly roll every apply back.
  nodes.spine-a.clanServices.netif.guard.enable = false;
}
