# netif-guard (specs/netif.md N25, N36; phase P8). A headless machine
# whose gateway drops pings. A change that loses the gateway must be
# rolled back and reported; a good change must be kept.
#
#   gw (192.168.1.1, 2001:db8:1::1; no ICMP echo; sshd) ── vlan 1 ── host
{
  inputs,
  lib,
  ...
}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  # The uplink as IfState sees it, for the generations the test switches to.
  uplink = {
    address,
    gateway,
    extra ? [],
  }: {
    interfaces.eth1.addresses = lib.mkForce ([address "2001:db8:1::2/64"] ++ extra);
    routing.routes = lib.mkForce [
      {
        to = "0.0.0.0/0";
        via = gateway;
        dev = "eth1";
        preference = 100;
      }
      {
        to = "::/0";
        via = "2001:db8:1::1";
        dev = "eth1";
        preference = 100;
      }
    ];
  };
in {
  name = "netif-guard";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines = {
        gw = {};
        host = {};
      };
      instances.lan = {
        module.name = "netif";
        module.input = "self";
        # Node order (gw, host) gives the host 192.168.1.2.
        roles.default.machines.host.settings.links.uplink = {
          interface = "eth1";
          static = {
            ipv4 = ["192.168.1.2/24"];
            ipv6 = ["2001:db8:1::2/64"];
          };
          gateway = {
            ipv4 = "192.168.1.1";
            ipv6 = "2001:db8:1::1";
          };
          ra = false;
        };
      };
    };
  };

  nodes = {
    gw = {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          inherit ifstateOverlay;
          addresses = [
            "192.168.1.1/24"
            "2001:db8:1::1/64"
          ];
          withBase = true;
        })
      ];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
      };
      # A gateway that drops pings: the guard must not depend on them.
      boot.kernel.sysctl = {
        "net.ipv4.icmp_echo_ignore_all" = 1;
        "net.ipv6.icmp.echo_ignore_all" = 1;
      };
      networking.firewall.enable = false;
      services.openssh.enable = true;
    };
    host = {pkgs, ...}: {
      virtualisation = {
        cores = 1;
        memorySize = 1024;
      };
      environment.systemPackages = [
        pkgs.iputils
        pkgs.jq
      ];
      clanServices.netif.guard = {
        timeout = 8;
        # N36: the machine one deploys from must still accept SSH
        targets = [
          {
            address = "192.168.1.1";
            port = 22;
          }
        ];
      };
      specialisation = {
        # A change that moves the machine off its subnet: the gateway is gone.
        bad.configuration.networking.ifstate.settings = uplink {
          address = "192.168.5.2/24";
          gateway = "192.168.5.1";
        };
        # A harmless change.
        good.configuration.networking.ifstate.settings = uplink {
          address = "192.168.1.2/24";
          gateway = "192.168.1.1";
          extra = ["192.168.1.3/24"];
        };
        # The network is fine, a declared target does not answer.
        deaf.configuration.clanServices.netif.guard.targets = [
          {
            address = "192.168.1.1";
            port = 81;
          }
        ];
        # Only the firewall changes.
        firewall.configuration.networking.firewall.allowedTCPPorts = [8443];
      };
    };
  };

  testScript = ''
    import time

    ${import ../../../../tests/suite-lib.nix}

    LAST_GOOD = "/var/lib/netif/guard/last-good"

    def last_good():
        return host.succeed(f"readlink {LAST_GOOD}").strip()

    def result():
        return host.succeed("systemctl show -p Result --value netif-guard.service").strip()

    def guard_done():
        """Wait for the guard run that an apply started; return its result."""
        host.wait_until_succeeds("systemctl show -p ActiveState --value netif-guard.service | grep -E '^(active|failed)$' >/dev/null", timeout=60)
        return result()

    def switch(name):
        system = "/run/booted-system" + (f"/specialisation/{name}" if name else "")
        return host.execute(f"systemctl reset-failed ifstate.service; {system}/bin/switch-to-configuration test 2>&1")

    def journal(pattern):
        # journald writes behind the unit: sync, or a line the guard just
        # printed is missing under load
        host.succeed(f"journalctl --sync; journalctl -b -u netif-guard.service --no-pager | grep '{pattern}' >/dev/null")

    try:
        start_all()
        gw.wait_for_unit("multi-user.target", timeout=180)
        host.wait_for_unit("multi-user.target", timeout=180)
        host.wait_until_succeeds("test $(systemctl show -p ExecMainExitTimestampMonotonic --value ifstate.service) != 0", timeout=120)
        assert guard_done() == "success"

        with subtest("versions"):
            print_versions(host, ["kernel", "ifstate", "nftables"])
            print_versions(gw, ["kernel", "ifstate"])

        with subtest("boot: the gateway answers at layer 2 though it drops pings (N25)"):
            host.fail("ping -c1 -W2 192.168.1.1")
            host.succeed("arping -c1 -w2 -I eth1 192.168.1.1")
            assert result() == "success", result()
            first = last_good()
            assert first == host.succeed("readlink -f /etc/ifstate/ifstate.yaml").strip(), first
            host.succeed("test \"$(readlink /nix/var/nix/gcroots/netif-guard-last-good)\" = " + first)
            journal("gateways and targets answer; kept")
            print("NETIF_GUARD_BOOT_OK")

        with subtest("a change that loses the gateway is rolled back and reported (N25)"):
            started = time.time()
            status, output = switch("bad")
            print(output)
            assert status != 0, "the switch must report the failure"
            assert time.time() - started < 40
            assert result() != "success", result()
            journal("no answer from 192.168.5.1 on eth1")
            journal("rolled back")
            host.succeed("ip -4 addr show eth1 | grep '192.168.1.2/24' >/dev/null")
            host.fail("ip -4 addr show eth1 | grep '192.168.5.2' >/dev/null")
            host.succeed("ip route show default | grep 'via 192.168.1.1' >/dev/null")
            host.succeed("arping -c1 -w2 -I eth1 192.168.1.1")
            assert last_good() == first
            # the running generation still names the bad configuration:
            # a plain restart tries it again and rolls back again
            assert host.succeed("readlink -f /etc/ifstate/ifstate.yaml").strip() != first
            # ifstate.service queues a guard run and returns: wait for that
            # run to start, or `guard_done` reads the result of the one before
            invocation = "systemctl show -p InvocationID --value netif-guard.service"
            before_restart = host.succeed(invocation).strip()
            host.succeed("systemctl restart ifstate.service")
            host.wait_until_succeeds(f"test \"$({invocation})\" != '{before_restart}'", timeout=60)
            assert guard_done() != "success"
            host.succeed("ip -4 addr show eth1 | grep '192.168.1.2/24' >/dev/null")
            print("NETIF_GUARD_ROLLBACK_OK")

        with subtest("a good change is kept and becomes the new last-good"):
            status, output = switch("good")
            print(output)
            assert status == 0, output
            assert result() == "success", result()
            host.succeed("ip -4 addr show eth1 | grep '192.168.1.3/24' >/dev/null")
            second = last_good()
            assert second != first
            print("NETIF_GUARD_KEPT_OK")

        with subtest("a declared target that stops answering fails the apply (N36)"):
            status, output = switch("deaf")
            assert status != 0, output
            journal("no answer from 192.168.1.1 port 81")
            # the network itself was fine: the last-good configuration is back
            host.succeed("ip route show default | grep 'via 192.168.1.1' >/dev/null")
            assert last_good() == second
            print("NETIF_GUARD_TARGET_OK")

        with subtest("the targets are checked after a firewall reload (N36)"):
            status, output = switch(None)
            assert status == 0, output
            status, output = switch("firewall")
            print(output)
            assert status == 0, output
            host.succeed("nft list ruleset | grep 8443 >/dev/null")
            host.succeed("journalctl -b -u nftables.service --no-pager | grep 'targets answer after the firewall change' >/dev/null")
            print("NETIF_GUARD_FIREWALL_OK")

        with subtest("no earlier configuration: fail loudly, nothing to roll back to"):
            host.succeed(f"rm {LAST_GOOD}")
            status, output = switch("bad")
            assert status != 0, output
            journal("no earlier network configuration to roll back to")
            host.succeed("ip -4 addr show eth1 | grep '192.168.5.2/24' >/dev/null")
            print("NETIF_GUARD_FIRST_BOOT_OK")

        print("NETIF_GUARD_OK")
    except Exception:
        for command in [
            "ip -br addr >&2; ip route >&2; ip -6 route >&2",
            "ls -l /var/lib/netif/guard /nix/var/nix/gcroots >&2",
            "journalctl -b -u ifstate.service -u netif-guard.service -u nftables.service --no-pager | tail -n 150 >&2",
            "systemctl status netif-guard.service --no-pager -l >&2",
        ]:
            host.execute(command)
        raise
  '';
}
