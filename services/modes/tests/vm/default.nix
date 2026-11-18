# netif-modes (specs/netif.md N2, N3, N4, N24; phases P2 and P4). One
# machine with two modes, booted into each in turn:
#
#   default    NetworkManager: the wired link by DHCP from a profile
#   developer  IfState: the same link through netif's dhcpcd, plus a VLAN
#              that only an IfState mode can render, and a routed-fabric
#              leaf (WireGuard, FRR) towards the spine on gw (N4)
#
# Modes are switched by rebooting. The test boots a mode the way the boot
# menu does: the kernel gets that mode's init.
{
  inputs,
  lib,
  ...
}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
in {
  name = "netif-modes";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        deck = {};
        gw = {};
      };
      instances = {
        modes = {
          module.name = "modes";
          module.input = "self";
          roles.default.machines.deck.settings.modes = {
            default.manager = "networkmanager";
            developer.manager = "ifstate";
          };
        };
        home = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.deck.settings.links.wired = {
            interface = "eth1";
            dhcp.ipv4 = true;
            # a fabric member says how large its path is (N17)
            pathMtu = 1500;
          };
        };
        # gw's fabric endpoint: a literal underlay address
        underlay = {
          module.name = "internet";
          roles.default.machines.gw.settings.host = "192.0.2.1";
        };
        # The deck is a fabric leaf in its developer mode only (N4). It
        # has no endpoint of its own: a roaming machine dials out.
        fleet = {
          module.name = "routed-fabric";
          module.input = "self";
          roles = {
            spine.machines.gw.settings.endpointSources = [
              {
                service = "clan-core/internet";
                instance = "underlay";
              }
            ];
            leaf.machines.deck.settings.modes = ["developer"];
          };
        };
        lab = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.deck.settings = {
            modes = ["developer"];
            defaultRoute.ipv6 = false;
            links = {
              trunk.interface = "eth2";
              lab10 = {
                vlan = {
                  id = 10;
                  parent = "trunk";
                };
                static.ipv4 = ["10.10.10.2/24"];
              };
            };
          };
        };
      };
    };
  };

  nodes = {
    deck = {
      config,
      pkgs,
      ...
    }: {
      virtualisation = {
        cores = 2;
        memorySize = 2048;
        vlans = [
          1
          2
        ];
      };
      environment.systemPackages = [pkgs.jq];
      # the test's own management NIC is nobody's link
      networking.networkmanager.unmanaged = ["interface-name:eth0"];
      # what a consumer does: something that belongs to one mode (N24)
      environment.etc."netif-mode".text = config.clanServices.networking.mode.name;
      services.openssh.enable = lib.mkIf (config.clanServices.networking.mode.name == "developer") true;
    };
    gw = {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          inherit ifstateOverlay;
          addresses = ["192.0.2.1/24"];
          withBase = true;
        })
      ];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
      };
      networking.firewall.enable = false;
      services.kea.dhcp4 = {
        enable = true;
        settings = {
          interfaces-config = {
            interfaces = ["eth1"];
            service-sockets-max-retries = 30;
            service-sockets-retry-wait-time = 1000;
          };
          lease-database = {
            type = "memfile";
            persist = false;
          };
          valid-lifetime = 600;
          subnet4 = [
            {
              id = 1;
              subnet = "192.0.2.0/24";
              interface = "eth1";
              pools = [{pool = "192.0.2.100 - 192.0.2.150";}];
              option-data = [
                {
                  name = "routers";
                  data = "192.0.2.1";
                }
                {
                  name = "domain-name-servers";
                  data = "192.0.2.53";
                }
              ];
            }
          ];
        };
      };
    };
  };

  testScript = {nodes, ...}: let
    developer = "${nodes.deck.system.build.toplevel}/specialisation/developer";
    spine = nodes.gw.clan.networkFacts.fabric.fleet;
    leaf = nodes.deck.clan.networkFacts.fabric.fleet;
  in ''
    import json
    import os

    def boot(mode_init):
        """Boot the deck into one mode, as the boot menu does."""
        deck.shutdown()
        if mode_init:
            os.environ["QEMU_KERNEL_PARAMS"] = f"init={mode_init}"
        else:
            os.environ.pop("QEMU_KERNEL_PARAMS", None)
        deck.start()
        deck.wait_for_unit("multi-user.target", timeout=240)

    def lease():
        deck.wait_until_succeeds("ip -4 -o addr show dev eth1 scope global | grep 192.0.2.1 >/dev/null", timeout=120)
        routes = json.loads(deck.succeed("ip -j -4 route show default dev eth1"))
        assert [(r["gateway"], r["metric"]) for r in routes] == [("192.0.2.1", 100)], routes
        deck.wait_until_succeeds("resolvectl dns eth1 | grep 192.0.2.53 >/dev/null", timeout=60)

    def network_manager_mode():
        assert deck.succeed("cat /etc/netif-mode").strip() == "default"
        deck.succeed("systemctl is-active NetworkManager.service")
        # exactly one manager: there is no IfState unit at all, and none of what runs beside it
        deck.fail("systemctl cat ifstate.service")
        deck.fail("systemctl cat netif-dhcpcd-eth1.service")
        deck.fail("systemctl cat netif-guard.service")
        # the fabric belongs to the developer mode: no FRR, no tunnel, no fabric address (N4)
        deck.fail("systemctl cat frr.service")
        assert deck.succeed("ip -o link show type wireguard").strip() == "", "a fabric tunnel in the NetworkManager mode"
        deck.fail("ip -o addr | grep -F '${leaf.ipv4}' >/dev/null")
        deck.fail("test -e /etc/ifstate/ifstate.yaml")
        lease()
        deck.succeed("nmcli -t -f NAME,DEVICE connection show --active | grep '^netif-eth1:eth1$' >/dev/null")
        deck.succeed("nmcli -t -f DEVICE,STATE device | grep '^eth0:unmanaged$' >/dev/null")
        # netif's profile is the only one on its link; the other mode's NIC is left alone
        deck.fail("nmcli -t -f NAME connection show | grep '^Wired connection' >/dev/null")
        deck.succeed("nmcli -t -f DEVICE,STATE device | grep '^eth2:unmanaged$' >/dev/null")
        assert deck.succeed("nmcli -g connection.interface-name,ipv4.method connection show netif-eth1").split() == ["eth1", "auto"]
        # the VLAN belongs to the developer mode only
        deck.fail("ip link show eth2.10")
        deck.fail("systemctl is-active sshd.service")
        # iwd is the Wi-Fi backend in every mode (N5)
        deck.succeed("NetworkManager --print-config | grep 'wifi.backend=iwd' >/dev/null")
        deck.succeed("systemctl cat iwd.service >/dev/null")

    try:
        gw.start()
        gw.wait_for_unit("kea-dhcp4-server.service", timeout=120)
        deck.start()
        deck.wait_for_unit("multi-user.target", timeout=240)

        with subtest("the default mode runs NetworkManager and nothing of IfState (N2)"):
            network_manager_mode()
            print("NETIF_MODES_NETWORKMANAGER_OK")

        with subtest("rebooted into the developer mode: IfState, netif's dhcpcd, the scoped VLAN (N3, N4)"):
            boot("${developer}/init")
            assert deck.succeed("cat /etc/netif-mode").strip() == "developer"
            deck.succeed("test $(systemctl show -p Result --value ifstate.service) = success")
            deck.fail("systemctl is-active NetworkManager.service")
            deck.fail("systemctl cat NetworkManager.service")
            deck.succeed("systemctl is-active netif-dhcpcd-eth1.service")
            lease()
            deck.wait_until_succeeds("ip -4 addr show eth2.10 | grep '10.10.10.2/24' >/dev/null", timeout=60)
            deck.wait_until_succeeds("systemctl show -p ActiveState --value netif-guard.service | grep '^active$' >/dev/null", timeout=60)
            status = json.loads(deck.succeed("netif-status --json"))
            assert sorted(l["interface"] for l in status["links"]) == ["eth1", "eth2", "eth2.10"], status
            deck.succeed("netif-preview | grep 'would change nothing' >/dev/null")
            deck.succeed("systemctl is-active sshd.service")
            print("NETIF_MODES_IFSTATE_OK")

        with subtest("the developer mode is a fabric leaf: WireGuard, BGP and BFD to the spine (N4)"):
            deck.wait_for_unit("frr.service", timeout=180)
            deck.succeed("ip -br addr show ${leaf.loopback} | grep -F '${leaf.ipv4}/32' >/dev/null")
            for machine in [deck, gw]:
                machine.wait_until_succeeds(
                    "vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^2$' >/dev/null",
                    timeout=240,
                )
            deck.wait_until_succeeds("vtysh -c 'show bfd peers brief' | grep -c ' up ' | grep '^2$' >/dev/null", timeout=120)
            # the leaf dials out from a DHCP address; both ends reach the other's fabric address
            deck.wait_until_succeeds("ping -c 2 -W 2 ${spine.ipv4}", timeout=120)
            deck.wait_until_succeeds("ping -6 -c 2 -W 2 ${spine.ipv6}", timeout=120)
            gw.wait_until_succeeds("ping -c 2 -W 2 ${leaf.ipv4}", timeout=120)
            gw.wait_until_succeeds("ping -6 -c 2 -W 2 ${leaf.ipv6}", timeout=120)
            # the fabric's links and routes are its own: netif proposes no change
            deck.succeed("netif-preview | grep 'would change nothing' >/dev/null")
            print("NETIF_MODES_FABRIC_OK")

        with subtest("back in the default mode: a fresh kernel state, NetworkManager again (N3)"):
            boot(None)
            network_manager_mode()
            # the spine keeps its side; the leaf is simply away
            gw.wait_until_fails(
                "vtysh -c 'show bgp neighbors' | grep 'BGP state = Established' >/dev/null",
                timeout=120,
            )
            gw.fail("ping -c 1 -W 2 ${leaf.ipv4}")
            print("NETIF_MODES_BACK_OK")

        print("NETIF_MODES_OK")
    except Exception:
        for command in [
            "cat /etc/netif-mode >&2; ip -br link >&2; ip -br addr >&2; ip route >&2",
            "systemctl --failed --no-pager >&2",
            "nmcli device >&2; nmcli connection show >&2",
            "journalctl -b --no-pager | grep -E 'NetworkManager|ifstate|netif|dhcpcd' | tail -n 150 >&2",
            "wg show >&2; vtysh -c 'show bgp summary' >&2; vtysh -c 'show bfd peers brief' >&2",
        ]:
            deck.execute(command)
        raise
  '';
}
