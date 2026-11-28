# gateway-wan (specs/gateway.md PR5, §10.4; specs/netif.md N43, N44).
#
#   isp eth1 ── vlan 1 ── router `wan`   (found by its permanent MAC, presents another MAC)
#   isp eth2.0 ─ vlan 2 ── router `wan0` (the ISP speaks only frames tagged with VLAN 0)
#
# The suite pins:
#   - N43: a physical link found by its permanent MAC presents another
#     MAC. IfState sets it before dhcpcd starts, the DHCPv4 and DHCPv6
#     servers see only the presented MAC, and the MAC and the lease hold
#     across an IfState apply and a reboot. An apply changes nothing.
#   - N44: IfState renders a VLAN child with id 0, DHCPv4 runs over it
#     and every frame on the wire carries the VLAN 0 tag. Without the
#     child nothing is answered in either direction: the router hears
#     the tagged frames, but its untagged answers are dropped.
{inputs, ...}: let
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  # the driver's MAC for node 2 (router) on vlan 1
  permanent = "52:54:00:12:01:02";
  presented = "02:00:5e:10:00:01";
  # a VLAN child does not inherit the parent's MAC
  childMac = "02:00:5e:10:00:02";

  sockets = interfaces: {
    inherit interfaces;
    service-sockets-max-retries = 30;
    service-sockets-retry-wait-time = 1000;
  };
  memfile = {
    type = "memfile";
    persist = false;
  };
in {
  name = "gateway-wan";

  clan = {
    directory = ./.;
    test.useContainers = false;
    inventory = {
      machines = {
        isp = {};
        router = {};
      };
      instances.wan = {
        module.name = "netif";
        module.input = "self";
        roles.default.machines.router.settings.links = {
          wan = {
            match.mac = permanent;
            # the IPv6 default comes from the ISP's advertisement (N48)
            ra = true;
            zone = "wan";
            dhcp = {
              ipv4 = true;
              ipv6 = true;
            };
            mac = presented;
          };
          ont = {
            interface = "eth2";
            ra = false;
          };
          wan0 = {
            vlan = {
              id = 0;
              parent = "ont";
            };
            mac = childMac;
            zone = "wan";
            dhcp.ipv4 = true;
            defaultRoute = {
              ipv4 = false;
              ipv6 = false;
            };
          };
        };
      };
    };
  };

  nodes = {
    router = {pkgs, ...}: {
      virtualisation = {
        cores = 1;
        memorySize = 1024;
        vlans = [
          1
          2
        ];
      };
      environment.systemPackages = [
        pkgs.jq
        pkgs.tcpdump
        pkgs.ethtool
      ];
    };

    isp = {pkgs, ...}: {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          inherit ifstateOverlay;
          addresses = [
            "192.0.2.1/24"
            "2001:db8::1/64"
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
      environment.systemPackages = [pkgs.tcpdump];
      boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
      networking = {
        firewall.enable = false;
        ifstate.settings.interfaces = {
          eth2.link = {
            kind = "physical";
            state = "up";
          };
          "eth2.0" = {
            addresses = ["198.51.100.1/24"];
            link = {
              kind = "vlan";
              link = "eth2";
              vlan_id = 0;
              state = "up";
            };
          };
        };
      };
      services = {
        kea = {
          dhcp4 = {
            enable = true;
            settings = {
              interfaces-config = sockets [
                "eth1"
                "eth2.0"
              ];
              lease-database = memfile;
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
                      data = "192.0.2.1";
                    }
                  ];
                }
                {
                  id = 2;
                  subnet = "198.51.100.0/24";
                  interface = "eth2.0";
                  pools = [{pool = "198.51.100.100 - 198.51.100.150";}];
                  option-data = [
                    {
                      name = "domain-name-servers";
                      data = "198.51.100.1";
                    }
                  ];
                }
              ];
            };
          };
          dhcp6 = {
            enable = true;
            settings = {
              interfaces-config = sockets ["eth1"];
              lease-database = memfile;
              subnet6 = [
                {
                  id = 1;
                  subnet = "2001:db8::/64";
                  interface = "eth1";
                  pools = [{pool = "2001:db8::100-2001:db8::1ff";}];
                }
              ];
            };
          };
        };
        radvd = {
          enable = true;
          config = ''
            interface eth1 {
              AdvSendAdvert on;
              AdvManagedFlag on;
              AdvOtherConfigFlag on;
              prefix 2001:db8::/64 { AdvAutonomous off; };
            };
          '';
        };
      };
    };
  };

  testScript = ''
    ${import ../../../../tests/suite-lib.nix}
    ${import ../../../../tests/ifstate-noop.nix}
    import json
    import re

    PRESENTED = "${presented}"
    PERMANENT = "${permanent}"
    CHILD_MAC = "${childMac}"
    # the EUI-64 link-local address of the presented MAC: the source of
    # every DHCPv6 message
    LINK_LOCAL = "fe80::5eff:fe10:1"
    FRAMES = "icmp or arp or (vlan and (icmp or arp))"
    KEA = "journalctl --no-pager -u kea-dhcp4-server.service -u kea-dhcp6-server.service"


    def link(machine, name):
        return json.loads(machine.succeed(f"ip -j -d link show {name}"))[0]


    def lease(family, device, prefix):
        router.wait_until_succeeds(f"ip -{family} -o addr show dev {device} scope global | grep ' {prefix}' >/dev/null", timeout=120)
        return router.succeed(f"ip -{family} -o addr show dev {device} scope global").split()[3].split("/")[0]


    def journal(machine, units):
        out = machine.succeed(f"journalctl -b --no-pager -o json {units}")
        entries = [json.loads(line) for line in out.splitlines() if line.strip()]
        return [entry for entry in entries if isinstance(entry.get("MESSAGE"), str)]


    def kea_count(pattern):
        return int(isp.succeed(f"{KEA} | grep -c -E '{pattern}' || true").strip())


    SEEN4 = f"DHCP4_LEASE_ALLOC \\[hwtype=1 {PRESENTED}\\].* lease 192\\.0\\.2\\."
    SEEN6 = f"DHCP6_PACKET_RECEIVED .* received from {LINK_LOCAL} "


    def assert_presented(tag):
        """The WAN link shows the presented MAC, and so does everything
        the ISP knows about the router."""
        lease4 = lease(4, "wan", "192.0.2.1")
        lease6 = lease(6, "wan", "2001:db8::1")
        wan = link(router, "wan")
        assert wan["address"] == PRESENTED, f"{tag}: wan presents {wan['address']}"
        assert wan.get("permaddr") == PERMANENT, f"{tag}: permanent MAC {wan.get('permaddr')}"
        assert PERMANENT in router.succeed("ethtool -P wan").lower(), f"{tag}: ethtool -P"
        assert router.succeed("cat /sys/class/net/wan/address").strip() == PRESENTED
        # the ISP's neighbour table: both leases sit behind the presented MAC
        router.succeed("ping -c1 -W2 192.0.2.1 >/dev/null")
        router.succeed("ping -c1 -W2 2001:db8::1 >/dev/null")
        neighbours = {entry["dst"]: entry.get("lladdr") for entry in json.loads(isp.succeed("ip -j neigh show dev eth1"))}
        print(f"FINDING {tag}: the ISP's neighbours on the WAN port: {neighbours}")
        assert neighbours.get(lease4) == PRESENTED, f"{tag}: {lease4} is at {neighbours.get(lease4)}"
        assert neighbours.get(lease6) == PRESENTED, f"{tag}: {lease6} is at {neighbours.get(lease6)}"
        assert PERMANENT not in neighbours.values(), f"{tag}: the ISP saw the permanent MAC"
        # the DHCP servers: a lease for the presented MAC, never a
        # message that names the permanent one
        assert kea_count(SEEN4) >= 1, f"{tag}: no DHCPv4 lease for {PRESENTED}"
        assert kea_count(SEEN6) >= 1, f"{tag}: no DHCPv6 message from {LINK_LOCAL}"
        assert kea_count(PERMANENT) == 0, f"{tag}: a DHCP server saw {PERMANENT}"
        return lease4, lease6


    def assert_mac_before_dhcp(tag):
        """This boot's journal: IfState changed the WAN link before
        dhcpcd started on it."""
        assert "ifstate.service" in router.succeed("systemctl show -p After --value netif-dhcpcd-wan.service").split()
        current = None
        set_at = None
        dhcp_at = None
        for entry in journal(router, "-u ifstate.service -u netif-dhcpcd-wan.service"):
            message = entry["MESSAGE"]
            stamp = int(entry["__MONOTONIC_TIMESTAMP"])
            if entry.get("SYSLOG_IDENTIFIER") == "ifstatecli":
                if message.startswith("configure"):
                    current = None
                elif re.match(r"^\s*\S+\s*$", message):
                    current = message.strip()
                elif current == "wan" and set_at is None and re.match(r"^\s*link\s+change\s*$", message):
                    set_at = stamp
            elif entry.get("SYSLOG_IDENTIFIER") == "dhcpcd" and dhcp_at is None:
                dhcp_at = stamp
        assert set_at is not None, f"{tag}: IfState logged no change of the wan link"
        assert dhcp_at is not None, f"{tag}: dhcpcd logged nothing on wan"
        print(f"FINDING {tag}: IfState set the MAC {(dhcp_at - set_at) / 1000:.0f} ms before dhcpcd's first line")
        assert set_at < dhcp_at, f"{tag}: dhcpcd started before IfState set the MAC"


    def duids():
        found = {}
        for unit in ["netif-dhcpcd-wan", "netif-dhcpcd-eth2.0"]:
            lines = [entry["MESSAGE"] for entry in journal(router, f"-u {unit}.service") if entry["MESSAGE"].startswith("DUID ")]
            assert lines, f"{unit}: no DUID in the journal"
            found[unit] = lines[0].split()[1]
        return found


    def capture(machine, name):
        machine.succeed(
            f"systemd-run --quiet --unit=capture-{name} /bin/sh -c "
            f"\"exec $(command -v tcpdump) -l -U -e -n -i eth2 '{FRAMES}' > /tmp/{name}.txt 2>&1\""
        )
        machine.wait_until_succeeds(f"grep 'listening on eth2' /tmp/{name}.txt >/dev/null", timeout=30)


    def frames(machine, name):
        machine.succeed(f"systemctl stop capture-{name}.service")
        out = machine.succeed(f"cat /tmp/{name}.txt")
        print(f"FINDING frames on {machine.name}'s port ({name}):\n{out.rstrip()}")
        return [line for line in out.splitlines() if re.match(r"^\d\d:\d\d:\d\d\.\d+ ", line)]


    with state_dump_on_failure([router, isp], extra=["journalctl -b --no-pager -u ifstate -u 'netif-dhcpcd*' | tail -n 80"]):
        start_all()
        isp.wait_for_unit("multi-user.target", timeout=300)
        router.wait_for_unit("multi-user.target", timeout=300)
        isp.wait_until_succeeds("ss -uln | grep ':547 ' >/dev/null", timeout=60)

        with subtest("versions"):
            print_versions(router, ["kernel", "ifstate"])
            print_versions(isp, ["kernel", "kea"])
            observe("dhcpcd as netif runs it", router, "journalctl -b --no-pager -u netif-dhcpcd-wan.service | grep -o 'dhcpcd-[0-9.]* starting' | head -n1")

        with subtest("N43: a physical link found by its permanent MAC presents another MAC"):
            first4, first6 = assert_presented("first boot")
            assert_mac_before_dhcp("first boot")
            print("GATEWAY_WAN_MAC_OK")

        with subtest("N43: an IfState apply proposes no change and keeps the MAC and the leases"):
            assert_ifstate_noop(router)
            assert assert_presented("after an apply") == (first4, first6)

        with subtest("N43: a reboot keeps the MAC and the leases"):
            before = (kea_count(SEEN4), kea_count(SEEN6))
            duid_before = duids()
            router.shutdown()
            router.start()
            router.wait_for_unit("multi-user.target", timeout=300)
            after4, after6 = assert_presented("after a reboot")
            print(f"FINDING leases before the reboot {first4} {first6}, after {after4} {after6}")
            assert (after4, after6) == (first4, first6), "the reboot changed a lease"
            assert_mac_before_dhcp("after a reboot")
            # the servers heard the router again, from the presented MAC
            assert kea_count(SEEN4) > before[0], "no DHCPv4 exchange after the reboot"
            assert kea_count(SEEN6) > before[1], "no DHCPv6 exchange after the reboot"
            assert_ifstate_noop(router)
            assert assert_presented("after a reboot and an apply") == (first4, first6)
            print("GATEWAY_WAN_REBOOT_OK")

        with subtest("N33: one DUID for both dhcpcd instances, and it is not tied to the presented MAC"):
            duid_after = duids()
            print(f"FINDING DUID before the reboot {duid_before}, after {duid_after}")
            # Both instances read one DUID file. The first boot writes it
            # from whichever link's dhcpcd starts first, so the MAC in it
            # is not asserted (specs/netif.md N33 owns the identity).
            assert len(set(duid_after.values())) == 1, f"the instances use different DUIDs: {duid_after}"
            assert duid_after == duid_before, "the reboot changed the DUID"
            holder = {PRESENTED: "the presented MAC", CHILD_MAC: "the VLAN child's MAC", PERMANENT: "the permanent MAC"}
            embedded = duid_after["netif-dhcpcd-wan"][-17:]
            print(f"FINDING the DUID embeds {embedded}: {holder.get(embedded, 'another MAC')}")

        with subtest("N44: IfState renders the VLAN 0 child and DHCPv4 runs over it"):
            router.succeed("grep 'vlan_id: 0' /etc/ifstate/ifstate.yaml >/dev/null")
            child = link(router, "eth2.0")
            assert child["linkinfo"]["info_kind"] == "vlan", child["linkinfo"]
            assert child["linkinfo"]["info_data"]["id"] == 0, child["linkinfo"]
            assert child["linkinfo"]["info_data"]["protocol"] == "802.1Q", child["linkinfo"]
            assert child["link"] == "eth2", child["link"]
            assert child["address"] == CHILD_MAC, child["address"]
            router.succeed("systemctl is-active netif-dhcpcd-eth2.0.service")
            child4 = lease(4, "eth2.0", "198.51.100.1")
            print(f"FINDING the lease over the VLAN 0 child: {child4}")
            # the ISP's server listens on its own VLAN 0 child only
            assert kea_count(f"DHCP4_LEASE_ALLOC \\[hwtype=1 {CHILD_MAC}\\].* lease 198\\.51\\.100\\.") >= 2, "no lease per boot over VLAN 0"
            # the parent carries no address of its own
            assert router.succeed("ip -4 -o addr show dev eth2").strip() == "", "the parent has an IPv4 address"

        with subtest("N44: every frame on the wire carries the VLAN 0 tag"):
            capture(isp, "tagged")
            router.succeed("ping -c2 -W2 198.51.100.1")
            isp.wait_until_succeeds("test \"$(grep -c 'ICMP echo reply' /tmp/tagged.txt)\" -ge 2", timeout=30)
            seen = frames(isp, "tagged")
            assert len(seen) >= 4, f"too few frames: {seen}"
            untagged = [line for line in seen if "ethertype 802.1Q (0x8100)" not in line or "vlan 0, p 0," not in line]
            assert untagged == [], f"frames without the VLAN 0 tag: {untagged}"
            for wanted in ["ICMP echo request", "ICMP echo reply"]:
                assert any(wanted in line for line in seen), f"no {wanted} in the capture"
            print("GATEWAY_WAN_VLAN0_OK")

        with subtest("N44: without the VLAN 0 child nothing is answered in either direction for 10 s each"):
            router.succeed("systemctl stop netif-dhcpcd-eth2.0.service; ip link del eth2.0; ip addr add 198.51.100.3/24 dev eth2")
            isp.succeed("ip neigh flush dev eth2.0")
            capture(isp, "plain")
            capture(router, "plain")
            holds_for(router, "! ping -c1 -W1 198.51.100.1 >/dev/null", 10)
            # the router's frames reach the ISP's port, untagged
            request_out = "Request who-has 198.51.100.1 tell 198.51.100.3"
            isp.wait_until_succeeds(f"grep -v 'vlan' /tmp/plain.txt | grep '{request_out}' >/dev/null", timeout=30)
            holds_for(isp, "! ping -c1 -W1 198.51.100.3 >/dev/null", 10)
            # the ISP's frames reach the router's port, tagged
            request_in = "Request who-has 198.51.100.3 tell 198.51.100.1"
            router.wait_until_succeeds(f"grep 'vlan 0, p 0, ethertype ARP' /tmp/plain.txt | grep '{request_in}' >/dev/null", timeout=30)
            at_isp = frames(isp, "plain")
            at_router = frames(router, "plain")
            both = at_isp + at_router
            # nothing is answered in either direction
            assert not any("ICMP echo reply" in line for line in both), "an echo was answered without the child"
            # the ISP's port ignores every untagged frame
            assert not any("Reply 198.51.100.1 is-at" in line for line in both), "the ISP answered an untagged ARP request"
            # the router sends only untagged frames, the ISP only tagged ones
            ours = [line for line in both if " 52:54:00:12:02:02 > " in line]
            theirs = [line for line in both if " 52:54:00:12:02:02 > " not in line]
            assert ours and not any("802.1Q" in line for line in ours), f"a tagged frame from the router: {ours}"
            assert theirs and all("vlan 0, p 0," in line for line in theirs), f"an untagged frame from the ISP: {theirs}"
            # FINDING contradicts specs/gateway.md §10.4 ("the kernel did
            # not answer the ISP's tagged ARP on the plain link"): Linux
            # takes a frame tagged with VLAN 0 on a link without a VLAN 0
            # child as untagged. The router hears the ISP and answers its
            # ARP request, untagged, and the ISP's port drops the answer.
            assert any("Reply 198.51.100.3 is-at" in line and "802.1Q" not in line for line in both), "the router did not answer the ISP's tagged ARP request"
            print("GATEWAY_WAN_NO_CHILD_OK")

        print("GATEWAY_WAN_OK")
  '';
}
