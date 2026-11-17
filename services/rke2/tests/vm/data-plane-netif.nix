# rke2-data-plane-netif: the shared Data-plane suite with the nodes'
# underlay declared through the netif service instead of the bare IfState
# fixture (specs/netif.md N14: netif proven under Cilium Kubernetes and
# FRR). Everything the data-plane suite asserts must hold unchanged, on
# links netif does not firewall-trust.
{inputs}: {
  imports = [
    (import ../../../../lib/kube-cluster/tests/vm/data-plane.nix {
      inherit inputs;
      distro = "rke2";
      underlay = "netif";
    })
  ];

  clan.inventory.instances.lan = {
    module.name = "netif";
    module.input = "self";
    roles.default.machines = {
      alpha.settings.links.uplink = {
        interface = "eth1";
        static = {
          ipv4 = ["192.168.1.1/24"];
          ipv6 = ["2001:db8:1::1/64"];
        };
      };
      beta.settings.links.uplink = {
        interface = "eth1";
        static = {
          ipv4 = ["192.168.1.2/24"];
          ipv6 = ["2001:db8:1::2/64"];
        };
      };
    };
  };
}
