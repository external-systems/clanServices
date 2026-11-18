# netif-desktop (specs/netif.md N14: the third load, a desktop
# specialisation; N2, N3, N5, N18). A KDE Plasma machine with two
# modes, booted into each in turn:
#
#   default    NetworkManager: a static IPv4 and IPv6 link from a profile
#              netif wrote, a wired network it has never seen (ad hoc, by
#              DHCP), Tailscale
#   developer  IfState: the same static link, Tailscale, KDE still there
#
# Addresses on the first VLAN are the test driver's own (desk .1, gw .2),
# so node names resolve.
{inputs, ...}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  headscale = import ../../../../tests/headscale-vm.nix {name = "gw";};
in {
  name = "netif-desktop";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        desk = {};
        gw = {};
      };
      instances = {
        modes = {
          module.name = "modes";
          module.input = "self";
          roles.default.machines.desk.settings.modes = {
            default.manager = "networkmanager";
            developer.manager = "ifstate";
          };
        };
        home = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines.desk.settings.links.lan = {
            interface = "eth1";
            static = {
              ipv4 = ["192.168.1.1/24"];
              ipv6 = ["2001:db8:1::1/64"];
            };
            gateway = {
              ipv4 = "192.168.1.2";
              ipv6 = "2001:db8:1::2";
            };
            ra = false;
            nameservers = ["192.168.1.2"];
          };
        };
      };
    };
  };

  nodes = {
    desk = {
      config,
      pkgs,
      ...
    }: {
      imports = [headscale.client];
      virtualisation = {
        cores = 4;
        memorySize = 4096;
        vlans = [
          1
          2
        ];
      };
      environment = {
        systemPackages = [pkgs.jq];
        etc."netif-mode".text = config.clanServices.networking.mode.name;
      };
      # the test's own management NIC is nobody's link
      networking.networkmanager.unmanaged = ["interface-name:eth0"];
      # the desktop is the same in both modes: only the network manager differs
      services = {
        desktopManager.plasma6.enable = true;
        displayManager = {
          sddm = {
            enable = true;
            wayland.enable = true;
          };
          defaultSession = "plasma";
          autoLogin = {
            enable = true;
            user = "alice";
          };
        };
        tailscale.enable = true;
      };
      users.users.alice = {
        isNormalUser = true;
        password = "alice";
        extraGroups = ["networkmanager"];
      };
    };

    gw = {
      imports = [
        headscale.server
        headscale.client
        (import ../../../../tests/ifstate-vm.nix {
          inherit ifstateOverlay;
          addresses = [
            "192.168.1.2/24"
            "2001:db8:1::2/64"
          ];
          withBase = true;
        })
      ];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [
          1
          2
        ];
      };
      networking = {
        firewall.enable = false;
        # a network the desk has never seen
        ifstate.settings.interfaces.eth2 = {
          addresses = ["198.51.100.1/24"];
          link = {
            kind = "physical";
            state = "up";
          };
        };
      };
      services = {
        tailscale.enable = true;
        kea.dhcp4 = {
          enable = true;
          settings = {
            interfaces-config = {
              interfaces = ["eth2"];
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
                subnet = "198.51.100.0/24";
                interface = "eth2";
                pools = [{pool = "198.51.100.100 - 198.51.100.150";}];
                option-data = [
                  {
                    name = "routers";
                    data = "198.51.100.1";
                  }
                ];
              }
            ];
          };
        };
      };
    };
  };

  testScript = {nodes, ...}: let
    developer = "${nodes.desk.system.build.toplevel}/specialisation/developer";
  in ''
    import json
    import os

    ${import ../../../../tests/ifstate-noop.nix}

    def boot(mode_init):
        """Boot the desk into one mode, as the boot menu does."""
        desk.shutdown()
        if mode_init:
            os.environ["QEMU_KERNEL_PARAMS"] = f"init={mode_init}"
        else:
            os.environ.pop("QEMU_KERNEL_PARAMS", None)
        desk.start()
        desk.wait_for_unit("multi-user.target", timeout=300)

    def defaults(family):
        routes = json.loads(desk.succeed(f"ip -j -{family} route show default"))
        return sorted((r["dev"], r["gateway"], r["metric"]) for r in routes)

    def kde():
        desk.wait_for_unit("display-manager.service", timeout=300)
        desk.wait_until_succeeds("pgrep -u alice -f plasmashell >/dev/null", timeout=600)
        desk.succeed("pgrep -u alice -f kwin_wayland >/dev/null")

    def static_link():
        """The declared link: the same addresses, gateway, metric and DNS in every mode."""
        desk.wait_until_succeeds("ip -4 -o addr show dev eth1 | grep -F '192.168.1.1/24' >/dev/null", timeout=120)
        desk.wait_until_succeeds("ip -6 -o addr show dev eth1 scope global | grep -F '2001:db8:1::1/64' >/dev/null", timeout=60)
        desk.wait_until_succeeds("ping -c 1 -W 2 192.168.1.2", timeout=60)
        desk.wait_until_succeeds("ping -6 -c 1 -W 2 2001:db8:1::2", timeout=60)
        assert ("eth1", "192.168.1.2", 100) in defaults(4), defaults(4)
        assert defaults(6) == [("eth1", "2001:db8:1::2", 100)], defaults(6)
        desk.wait_until_succeeds("resolvectl dns eth1 | grep -F 192.168.1.2 >/dev/null", timeout=60)

    def tailnet():
        desk.wait_for_unit("tailscaled.service", timeout=120)
        desk.wait_until_succeeds(f"tailscale ping --c 3 {gw_ip}", timeout=120)

    def network_manager_mode():
        assert desk.succeed("cat /etc/netif-mode").strip() == "default"
        desk.succeed("systemctl is-active NetworkManager.service")
        # exactly one manager: there is no IfState unit at all
        desk.fail("systemctl cat ifstate.service")
        desk.fail("test -e /etc/ifstate/ifstate.yaml")
        static_link()
        desk.succeed("nmcli -t -f NAME,DEVICE connection show --active | grep '^netif-eth1:eth1$' >/dev/null")
        methods = desk.succeed("nmcli -g ipv4.method,ipv6.method connection show netif-eth1").split()
        assert methods == ["manual", "manual"], methods
        # the desktop user sees the link netif declared
        desk.succeed("su - alice -c 'nmcli -t -f NAME connection show --active' | grep '^netif-eth1$' >/dev/null")

    try:
        gw.start()
        gw.wait_for_unit("headscale.service", timeout=120)
        gw.wait_for_open_port(443)
        gw.wait_for_unit("kea-dhcp4-server.service", timeout=120)
        gw.succeed("headscale users create test")
        authkey = gw.succeed("headscale preauthkeys -u 1 create --reusable").strip().splitlines()[-1]
        up = f"tailscale up --login-server https://gw --auth-key {authkey}"
        gw.wait_for_unit("tailscaled.service")
        gw.succeed(up)
        gw_ip = gw.wait_until_succeeds("tailscale ip -4").strip()
        desk.start()
        desk.wait_for_unit("multi-user.target", timeout=300)

        with subtest("KDE on NetworkManager: a static IPv4 and IPv6 profile (N2, N14)"):
            kde()
            network_manager_mode()
            print("NETIF_DESKTOP_STATIC_OK")

        with subtest("a wired network never seen before is joined ad hoc, behind the declared link (N18)"):
            desk.wait_until_succeeds("ip -4 -o addr show dev eth2 | grep -F '198.51.100.1' >/dev/null", timeout=120)
            desk.succeed("nmcli -t -f DEVICE,STATE device | grep '^eth2:connected$' >/dev/null")
            assert defaults(4) == [("eth1", "192.168.1.2", 100), ("eth2", "198.51.100.1", 200)], defaults(4)
            desk.succeed("ip route get 203.0.113.9 | grep 'dev eth1' >/dev/null")
            # the declared link gone: the ad hoc one carries the default with no reconfiguration
            desk.succeed("nmcli device disconnect eth1")
            desk.succeed("ip route get 203.0.113.9 | grep 'dev eth2' >/dev/null")
            desk.succeed("nmcli connection up netif-eth1")
            desk.wait_until_succeeds("ip route get 203.0.113.9 | grep 'dev eth1' >/dev/null", timeout=60)
            print("NETIF_DESKTOP_ADHOC_OK")

        with subtest("Tailscale beside NetworkManager (N6)"):
            desk.wait_for_unit("tailscaled.service", timeout=120)
            desk.succeed(up)
            tailnet()
            desk.succeed("nmcli -t -f DEVICE,STATE device | grep '^tailscale0:unmanaged$' >/dev/null")
            print("NETIF_DESKTOP_TAILSCALE_OK")

        with subtest("rebooted into the developer mode: KDE on IfState, the same link, Tailscale (N3)"):
            boot("${developer}/init")
            assert desk.succeed("cat /etc/netif-mode").strip() == "developer"
            desk.succeed("test $(systemctl show -p Result --value ifstate.service) = success")
            desk.fail("systemctl cat NetworkManager.service")
            kde()
            static_link()
            tailnet()
            status = json.loads(desk.succeed("netif-status --json"))
            assert [l["interface"] for l in status["links"]] == ["eth1"], status
            desk.succeed("netif-preview | grep 'would change nothing' >/dev/null")
            assert_ifstate_noop(desk)
            tailnet()
            print("NETIF_DESKTOP_IFSTATE_OK")

        with subtest("back in the default mode: NetworkManager again (N3)"):
            boot(None)
            kde()
            network_manager_mode()
            tailnet()
            print("NETIF_DESKTOP_BACK_OK")

        print("NETIF_DESKTOP_OK")
    except Exception:
        for command in [
            "cat /etc/netif-mode >&2; ip -br link >&2; ip -br addr >&2; ip route >&2; ip -6 route >&2",
            "systemctl --failed --no-pager >&2",
            "nmcli device >&2; nmcli connection show >&2",
            "tailscale status >&2",
            "journalctl -b --no-pager | grep -E 'NetworkManager|ifstate|netif|sddm|tailscaled' | tail -n 150 >&2",
        ]:
            desk.execute(command)
        raise
  '';
}
