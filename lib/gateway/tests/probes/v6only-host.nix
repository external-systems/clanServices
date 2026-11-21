# Probe for specs/netif.md N45 and U13: a machine with no IPv4 at all.
#
#   static  ── vlan 1 ── provider ── vlan 2 ── server4 (IPv4 only)
#   slaac   ── vlan 3 ──────┘
#
# `static` is a cloud machine as a provider hands it out: one /64, the
# gateway fe80::1, no router advertisement, no DHCP. `slaac` learns its
# address and default route from router advertisements. Both use the
# provider's DNS64 and NAT64 (specs/gateway.md G4).
#
# Questions: does netif bring such a machine "online", does the lockout
# guard accept a link-local gateway, does anything expect IPv4, and what
# does reaching IPv4 look like without a CLAT?
#
# Lines that start with FINDING are the result.
{
  inputs,
  lib,
  ...
}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  base = import ../../../ifstate.nix {inherit ifstateOverlay;};
  echo = import ./echo.nix;
  pool = "2001:db8:64:0:64::/96";
  dns = "2001:db8:64::53";

  machine = {pkgs, ...}: {
    virtualisation = {
      cores = 1;
      memorySize = 1024;
    };
    services.openssh.enable = true;
    environment.systemPackages = [
      pkgs.curl
      pkgs.dig
      pkgs.jq
    ];
  };
in {
  name = "probe-v6only-host";

  clan = {
    directory = ./.;
    test.useContainers = false;
    inventory = {
      machines = {
        static = {};
        slaac = {};
        provider = {};
        server4 = {};
      };
      instances.uplink = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines = {
          static.settings.links.uplink = {
            interface = "eth1";
            static.ipv6 = ["2001:db8:aa::1/64"];
            gateway.ipv6 = "fe80::1";
            nameservers = [dns];
            ra = false;
          };
          slaac.settings.links.uplink = {
            interface = "eth1";
            nameservers = [dns];
          };
        };
      };
    };
  };

  nodes = {
    static = {
      imports = [machine];
      virtualisation.vlans = [1];
    };
    slaac = {
      imports = [machine];
      virtualisation.vlans = [3];
    };

    provider = {
      imports = [
        (import ./nat64-gateway.nix {
          inherit base pool;
          allow = "{ 2001:db8:aa::/64, 2001:db8:bb::/64 }";
          inside = ["fe80::1/64"];
          outside = ["198.51.100.1/24"];
          routes = [
            {
              to = "2001:db8:aa::/64";
              dev = "eth1";
            }
          ];
          corefile = ''
            . {
              bind ${dns}
              hosts {
                198.51.100.80 web.test
              }
              dns64 {
                prefix ${pool}
              }
              errors
            }
          '';
        })
      ];
      virtualisation.vlans = lib.mkForce [
        1
        2
        3
      ];
      networking.ifstate.settings.interfaces = {
        eth3 = {
          addresses = ["2001:db8:bb::1/64"];
          link = {
            kind = "physical";
            state = "up";
          };
        };
        dns0 = {
          addresses = ["${dns}/128"];
          link = {
            kind = "dummy";
            state = "up";
          };
        };
      };
      services.radvd = {
        enable = true;
        config = ''
          interface eth3 {
            AdvSendAdvert on;
            prefix 2001:db8:bb::/64 { };
          };
        '';
      };
    };

    server4 = {pkgs, ...}: {
      imports = [base];
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [2];
      };
      networking = {
        firewall.enable = false;
        ifstate.settings.interfaces.eth1 = {
          addresses = ["198.51.100.80/24"];
          link = {
            kind = "physical";
            state = "up";
          };
        };
      };
      systemd.services.echo = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [80]}";
      };
    };
  };

  testScript = ''
    def observe(label, machine, cmd):
        status, out = machine.execute(cmd + " 2>&1")
        print(f"FINDING {label}: rc={status}\n{out.rstrip()}")
        return status, out.strip()

    start_all()
    for machine in [provider, server4, static, slaac]:
        machine.wait_for_unit("multi-user.target", timeout=300)
    provider.wait_for_unit("jool-netns.service", timeout=60)
    provider.wait_for_unit("coredns.service", timeout=60)

    for machine, address in [(static, "2001:db8:aa::1"), (slaac, "2001:db8:bb:")]:
        with subtest(f"{machine.name}: an IPv6-only machine under netif"):
            machine.wait_until_succeeds(f"ip -6 -o addr show dev eth1 scope global | grep '{address}' >/dev/null", timeout=120)
            observe(f"{machine.name}: addresses and routes", machine, "ip -br addr; echo v4:; ip -4 route; echo v6:; ip -6 route | grep -v '^fe80'")
            observe(f"{machine.name}: units", machine, "systemctl is-active ifstate netif-online netif-guard network-online.target; systemctl --failed --no-legend; systemctl show -p Result --value ifstate netif-guard netif-online")
            observe(f"{machine.name}: guard and online journal", machine, "journalctl -b --no-pager -u netif-guard -u netif-online | tail -8")
            observe(f"{machine.name}: DNS", machine, "resolvectl status eth1 | head -8; resolvectl query web.test")
            observe(f"{machine.name}: what a name lookup returns", machine, "getent ahosts web.test; getent ahostsv4 web.test")
            observe(f"{machine.name}: an IPv4-only site by name", machine, "curl -s --max-time 10 http://web.test/")
            observe(f"{machine.name}: an IPv4 literal without a CLAT", machine, "curl -sS --max-time 5 http://198.51.100.80/")
            observe(f"{machine.name}: an apply changes nothing", machine, "ifstatecli check | grep -v ' ok$\\|^$\\|= \\|orphan\\|\\.\\.\\.$\\|^ [a-z0-9.]*$'")
            observe(f"{machine.name}: listening sockets", machine, "ss -tlnH | awk '{print $4}' | sort -u")
            observe(f"{machine.name}: evaluation and boot warnings that mention IPv4", machine, "journalctl -b --no-pager -p warning | grep -i 'ipv4\\|inet \\|0\\.0\\.0\\.0' | head -10")

    with subtest("reaching the machine over IPv6"):
        observe("SSH port of the static machine from the provider", provider, "timeout 5 bash -c 'exec 3<>/dev/tcp/2001:db8:aa::1/22; head -c 20 <&3'")
        observe("an unopened port", provider, "timeout 5 bash -c 'exec 3<>/dev/tcp/2001:db8:aa::1/8080' ; echo rc=$?")

    with subtest("the guard: a gateway that stops answering"):
        observe("guard run with the gateway present", static, "systemctl restart netif-guard.service; journalctl -u netif-guard --no-pager | tail -3")
        provider.succeed("ip link set eth1 down")
        observe("guard run with the gateway gone", static, "systemctl restart netif-guard.service; systemctl show -p Result --value netif-guard; journalctl -u netif-guard --no-pager | tail -6")
        provider.succeed("ip link set eth1 up")

    print("PROBE_V6ONLY_HOST_OK")
  '';
}
