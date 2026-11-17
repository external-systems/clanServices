# Probe (2026-11-16, proof session): N23 VM hosts (bridge MAC,
# bridge over a VLAN, guest ports) and N26 NIC matching by path.
{
  pkgs,
  lib,
  ...
}: {
  name = "netif-vmhost-probe";
  nodes = {
    host = {
      virtualisation = {
        vlans = [1 2 3 4];
        # Two extra NICs on fixed PCI slots: an e1000 and a virtio one.
        qemu.options = [
          "-netdev user,id=x1 -device e1000,netdev=x1,addr=0x10"
          "-netdev user,id=x2 -device virtio-net-pci,netdev=x2,addr=0x11"
        ];
      };
      # udev renames the NIC in slot 0x11 by path, before IfState runs.
      systemd.network.links."10-cloud1" = {
        matchConfig.Path = "pci-0000:00:11.0";
        linkConfig.Name = "cloud1";
      };
      networking = {
        interfaces = lib.mkForce {};
        useDHCP = false;
        firewall.enable = false;
        ifstate = {
          enable = true;
          settings = {
            parameters.ignore.ifname = ["^br-[\\da-f]{12}" "^docker\\d+" "^ppp\\d+$" "^veth" "^virbr\\d+" "^tap" "^vnet" "!include /run/netif/guest-ports.yaml"];
            parameters.ignore.netns = ["^guest$"];
            interfaces = {
              eth1 = {
                addresses = ["192.168.1.1/24"];
                link = {
                  kind = "physical";
                  state = "up";
                };
              };
              eth2 = {
                link = {
                  kind = "physical";
                  state = "up";
                  master = "br0";
                };
                identify.perm_address = "52:54:00:12:02:01";
              };
              br0 = {
                addresses = ["192.168.2.1/24"];
                link = {
                  kind = "bridge";
                  state = "up";
                  address = "52:54:00:12:02:01";
                };
              };
              eth3 = {
                link = {
                  kind = "physical";
                  state = "up";
                };
              };
              "eth3.100" = {
                link = {
                  kind = "vlan";
                  link = "eth3";
                  vlan_id = 100;
                  state = "up";
                  master = "br1";
                };
              };
              br1 = {
                addresses = ["192.168.3.1/24"];
                link = {
                  kind = "bridge";
                  state = "up";
                };
              };
              cloud1 = {
                addresses = ["192.168.11.1/24"];
                link = {
                  kind = "physical";
                  state = "up";
                };
              };
            };
          };
        };
      };
      environment.systemPackages = [pkgs.jq pkgs.ethtool pkgs.yq-go];
      # Prototype of netif's step: before every apply, write ONE regex that
      # names the undeclared ports of each guest-ports bridge (here br0,
      # declared member eth2). A regex that matches nothing when there are none.
      systemd.services.ifstate.serviceConfig.ExecStartPre = lib.mkForce [
        "-${pkgs.systemd}/bin/udevadm settle --timeout=180"
        (pkgs.writeShellScript "netif-guest-ports" ''
          export PATH=${lib.makeBinPath [pkgs.coreutils pkgs.gnused]}
          mkdir -p /run/netif
          names=""
          for p in /sys/class/net/br0/brif/*; do
            [ -e "$p" ] || continue
            n=$(basename "$p")
            [ "$n" = eth2 ] && continue
            names="$names|$(printf '%s' "$n" | sed 's/[.]/\\\\./g')"
          done
          if [ -n "$names" ]; then printf '"^(%s)$"\n' "''${names#|}"; else printf '"^$"\n'; fi > /run/netif/guest-ports.yaml
        '')
      ];
    };
    peer = {
      virtualisation.vlans = [2 3];
      networking = {
        firewall.enable = false;
        interfaces.eth1 = lib.mkForce {
          ipv4.addresses = [
            {
              address = "192.168.2.2";
              prefixLength = 24;
            }
          ];
        };
        interfaces.eth2 = lib.mkForce {};
        vlans.v100 = {
          id = 100;
          interface = "eth2";
        };
        interfaces.v100.ipv4.addresses = [
          {
            address = "192.168.3.2";
            prefixLength = 24;
          }
        ];
      };
    };
  };

  testScript = ''
    def show(cmd):
        rc, out = host.execute(cmd + " 2>&1")
        print(f"=== {cmd}\n{out}")
        return out
    def fact(name, value):
        print(f"FACT {name}: {value}")
    def ok(m, cmd):
        return m.execute(cmd)[0] == 0
    def jl(name, field):
        return host.execute(f"ip -d -j link show {name} | jq -r '.[0].{field}'")[1].strip()

    start_all()
    host.wait_for_unit("multi-user.target")
    peer.wait_for_unit("multi-user.target")
    show("journalctl -u ifstate --no-pager | tail -30; ip -br link; ip -br addr")

    with subtest("N23: bridge takes the uplink MAC"):
        fact("bridge_mac", jl("br0", "address"))
        fact("member_perm_mac", host.succeed("ethtool -P eth2 | awk '{print $3}'").strip())
        fact("bridge_mac_equals_member_mac", jl("br0", "address") == host.succeed("ethtool -P eth2 | awk '{print $3}'").strip())
        fact("peer_reaches_bridge", ok(peer, "ping -c2 -W2 192.168.2.1"))
        fact("peer_neigh_for_bridge", peer.succeed("ip neigh show 192.168.2.1").strip())
        host.succeed("systemctl restart ifstate.service")
        fact("bridge_mac_after_reapply", jl("br0", "address"))
        show("ifstatecli --config /etc/ifstate/ifstate.yaml check")

    with subtest("N23: bridge over a VLAN"):
        fact("vlan_member_master", jl("eth3.100", "master"))
        fact("peer_reaches_vlan_bridge", ok(peer, "ping -c2 -W2 192.168.3.1"))
        fact("vlan_bridge_mac", jl("br1", "address"))

    with subtest("N23: guest ports, name-based ignore (^tap)"):
        host.succeed("ip tuntap add dev tap0 mode tap && ip link set tap0 master br0 up")
        host.succeed("systemctl restart ifstate.service; systemctl restart ifstate.service")
        fact("tap_named_port_survives", ok(host, "ip link show tap0"))
        fact("tap_named_port_master", jl("tap0", "master"))
        fact("tap_named_port_up", "UP" in jl("tap0", "flags"))

    with subtest("N23: guest port with an arbitrary name, static config"):
        def guest(ip):
            host.succeed(f"(ip link del gp0 || true; ip netns del guest || true) 2>/dev/null; sleep 1; ip netns add guest; ip link add gp0 type veth peer name gp0p netns guest; ip link set gp0 master br0 up; ip -n guest addr add {ip}/24 dev gp0p; ip -n guest link set gp0p up; ip -n guest link set lo up")
        guest("192.168.2.50")
        peer.wait_until_succeeds("ping -c1 -W2 192.168.2.50", timeout=20)
        show("ifstatecli --config /etc/ifstate/ifstate.yaml check | tail -20")
        host.succeed("systemctl restart ifstate.service")
        fact("arbitrary_port_on_guest_bridge_survives_one_apply", ok(host, "ip link show gp0"))
        fact("ignored_netns_survives", ok(host, "ip netns list | grep guest"))
        host.execute("true")

    with subtest("N23: per-bridge guest ports through the NixOS module and a run-time include"):
        show("grep -n -B2 -A12 'ignore:' /etc/ifstate/ifstate.yaml; cat /run/netif/guest-ports.yaml")
        fact("module_renders_include_tag_in_list", ok(host, "grep -- \"- !include '/run/netif/guest-ports.yaml'\" /etc/ifstate/ifstate.yaml"))
        fact("empty_guest_file_at_boot", host.succeed("cat /run/netif/guest-ports.yaml").strip())
        guest("192.168.2.51")
        peer.wait_until_succeeds("ping -c1 -W2 192.168.2.51", timeout=20)
        # a port on br1, which is not a guest-ports bridge
        host.succeed("ip link add gp1 type dummy; ip link set gp1 master br1 up")
        host.succeed("systemctl restart ifstate.service; systemctl restart ifstate.service")
        show("cat /run/netif/guest-ports.yaml; journalctl -u ifstate --no-pager | tail -12")
        fact("guest_file_after_apply", host.succeed("cat /run/netif/guest-ports.yaml").strip())
        fact("include_port_survives", ok(host, "ip link show gp0"))
        fact("include_port_master", jl("gp0", "master"))
        fact("include_guest_connectivity", ok(peer, "ping -c2 -W2 192.168.2.51"))
        fact("port_on_plain_bridge_deleted", not ok(host, "ip link show gp1"))
        show("ifstatecli --config /etc/ifstate/ifstate.yaml check | tail -15")
        # guest gone: the next apply shrinks the list again
        host.succeed("ip link del gp0; systemctl restart ifstate.service")
        fact("guest_file_after_guest_left", host.succeed("cat /run/netif/guest-ports.yaml").strip())
        fact("include_file_missing_fails", not ok(host, "mv /run/netif/guest-ports.yaml /run/netif/x; ifstatecli --config /etc/ifstate/ifstate.yaml check; rc=$?; mv /run/netif/x /run/netif/guest-ports.yaml; exit $rc"))

    with subtest("N26: what identifies a NIC"):
        show("ifstatecli identify || ifstatecli --help")
        show("for n in /sys/class/net/*; do b=$(basename $n); echo \"$b driver=$(basename $(readlink $n/device/driver 2>/dev/null) 2>/dev/null) parentdev=$(ip -d -j link show $b | jq -r '.[0].parentdev') parentbus=$(ip -d -j link show $b | jq -r '.[0].parentbus') ID_PATH=$(udevadm info -q property $n | grep '^ID_PATH=' | cut -d= -f2)\"; done")
        show("ls /sys/bus/virtio/devices/ | while read d; do echo \"$d -> $(basename $(readlink /sys/bus/virtio/devices/$d/driver)) $(readlink -f /sys/bus/virtio/devices/$d | sed 's#.*/pci0000:00/##')\"; done")
        e1000 = host.succeed("for n in /sys/class/net/*; do [ \"$(basename $(readlink $n/device/driver 2>/dev/null) 2>/dev/null)\" = e1000 ] && basename $n; done; true").strip()
        fact("e1000_kernel_name", e1000)
        fact("e1000_parent_dev_name", jl(e1000, "parentdev"))
        fact("virtio_parent_dev_name_eth4", jl("eth4", "parentdev"))
        fact("virtio_parent_bus_eth4", jl("eth4", "parentbus"))
        fact("udev_link_rename_by_path", ok(host, "ip link show cloud1"))
        fact("udev_renamed_nic_configured_by_ifstate", "192.168.11.1" in host.succeed("ip -br addr show cloud1 || true"))
        fact("cloud1_parentdev", jl("cloud1", "parentdev"))

    with subtest("N26: IfState identify.parent_dev_name renames"):
        pci = jl(e1000, "parentdev")
        vio = jl("eth4", "parentdev")
        host.succeed(f"""
          yq '.interfaces.pcinic = {{"addresses": ["192.168.9.1/24"], "link": {{"kind": "physical", "state": "up"}}, "identify": {{"parent_dev_name": "{pci}"}}}} | .interfaces.vionic = {{"addresses": ["192.168.8.1/24"], "link": {{"kind": "physical", "state": "up"}}, "identify": {{"parent_dev_name": "{vio}"}}}}' /etc/ifstate/ifstate.yaml -o=json > /run/netif/match.yaml
        """)
        rc, out = host.execute("ifstatecli --config /run/netif/match.yaml apply 2>&1")
        print(out)
        fact("identify_pci_renamed", ok(host, "ip -br addr show pcinic | grep 192.168.9.1"))
        fact("identify_virtio_renamed", ok(host, "ip -br addr show vionic | grep 192.168.8.1"))
        show("ip -br link")
    print("NETIF_VMHOST_PROBE_DONE")
  '';
}
