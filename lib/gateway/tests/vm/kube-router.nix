# router-kube (specs/gateway.md G25, §14.5 point 7): a `router` that is
# also a Kubernetes node, the owner's home box.
#
#   internet (IPv4 and IPv6) ── vlan 2, WAN ── alpha ── vlan 3, zone home ── client
#                                               │
#                                 vlan 1, zone servers
#                                   ├── beta    (k3s agent)
#                                   └── router  (the data-plane body's foreign
#                                                FRR host: here a machine in
#                                                zone servers that is no node)
#
#   alpha: k3s server, routed-fabric spine, and the `router` service:
#          NAT44 and default deny for the zones, DHCPv4 and a resolver.
#
# The <distro>-data-plane topology on netif: routed-fabric, FRR, per-pair
# WireGuard, Cilium native routing (SPEC.md D72). The cluster's `devices`
# come from the services (D71).
#
# What the suite pins:
#   - both firewalls are loaded on alpha, and the cluster comes up
#     through them: the fabric's WireGuard arrives on a zone link
#     (`hostPorts`), BGP and the API on unzoned links;
#   - D71: the router's WAN is a Cilium device, so alpha's pods leave
#     with the WAN address;
#   - the zones still work with Cilium on the WAN: NAT44 for a LAN
#     client, a node and a node's pod; routed IPv6; DHCPv4 and DNS
#     through both firewalls;
#   - default deny holds: zone to zone, the WAN to the router's and the
#     cluster's ports, a zone that is not in `unzoned.zones` to a pod; a
#     zone with it (and `fabric = true`, so routed-fabric's guard lets
#     it into the fabric links, SPEC.md D73) reaches pods on both nodes;
#   - a NodePort does not answer on the WAN address (D69);
#   - a restart of nftables and an IfState apply leave all of it working.
{inputs}: {
  lib,
  nodes,
  ...
}: let
  distro = "k3s";
  ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
  base = import ../../../ifstate.nix {inherit ifstateOverlay;};
  echo = import ./echo.nix;
  plain = import ../../../kube-cluster/tests/vm/data-plane.nix {
    inherit inputs distro;
    underlay = "netif";
  } {inherit lib nodes;};
  # D71: nothing is hand-set; the data-plane topology's own `devices` goes
  dropDevices = settings:
    settings
    // {
      cilium =
        settings.cilium
        // {
          helmValues = removeAttrs settings.cilium.helmValues ["devices"];
        };
    };
  roleSettings = lib.genAttrs ["server" "agent"] (role: {
    settings = dropDevices plain.clan.inventory.instances.${distro}.roles.${role}.settings;
  });
  body =
    lib.recursiveUpdateUntil (
      path: _: _:
        lib.elem path (map (role: ["clan" "inventory" "instances" distro "roles" role "settings"]) ["server" "agent"])
    )
    plain {
      clan.inventory.instances.${distro}.roles = roleSettings;
    };
  kubeconfig = "/etc/rancher/${distro}/${distro}.yaml";

  wan4 = "198.51.100.1";
  wan6 = "2001:db8:2::1";
  internet4 = "198.51.100.80";
  internet6 = "2001:db8:2::80";
  clientAddr4 = "192.168.10.10";
  clientAddr6 = "2001:db8:3::10";

  phys = addresses: {
    inherit addresses;
    link = {
      kind = "physical";
      state = "up";
    };
  };

  node = name: {pkgs, ...}: {
    imports = [body.nodes.${name}];
    environment.systemPackages = [
      pkgs.curl
      pkgs.tcpdump
      pkgs.jq
      pkgs.python3
      pkgs.conntrack-tools
      pkgs.dig
      pkgs.netcat
    ];
  };
  host = {pkgs, ...}: {
    imports = [base];
    virtualisation = {
      cores = 1;
      memorySize = 1024;
    };
    networking.firewall.enable = false;
    environment.systemPackages = [
      pkgs.curl
      pkgs.dig
      pkgs.netcat
      pkgs.busybox
    ];
  };
in
  lib.recursiveUpdate body {
    name = "router-kube";

    clan.inventory = {
      machines = {
        internet = {};
        client = {};
      };
      instances = {
        links = {
          module.name = "netif";
          module.input = "self";
          roles.default.machines = {
            alpha.settings.links = {
              servers = {
                interface = "eth1";
                zone = "servers";
                static = {
                  ipv4 = ["192.168.1.1/24"];
                  ipv6 = ["2001:db8:1::1/64"];
                };
                ra = false;
              };
              wan = {
                interface = "eth2";
                zone = "wan";
                static = {
                  ipv4 = ["${wan4}/24"];
                  ipv6 = ["${wan6}/64"];
                };
                gateway = {
                  ipv4 = internet4;
                  ipv6 = internet6;
                };
                ra = false;
              };
              home = {
                interface = "eth3";
                zone = "home";
                static = {
                  ipv4 = ["192.168.10.1/24"];
                  ipv6 = ["2001:db8:3::1/64"];
                };
                ra = false;
              };
            };
            # A node behind the router: its default routes point at it.
            # Its uplink is eth2, a name no zone link of alpha has: the
            # cluster's one `devices` list is a list of names (G25).
            beta.settings.links.uplink = {
              interface = "eth2";
              zone = "lan";
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
        edge = {
          module.name = "router";
          module.input = "self";
          roles.router.machines.alpha.settings = {
            zones = {
              # the other nodes: the fabric's WireGuard arrives here
              servers = {
                dhcp = false;
                hostPorts = true;
              };
              # D73: the home zone's link is inside the fabric, so
              # routed-fabric's guard lets its flows into the fabric links
              home.fabric = true;
            };
            dns = {
              upstream = [internet4];
              records."service.test" = internet4;
            };
            # the home zone may reach the cluster's pods and services;
            # the source such flows get is alpha's fabric address, which
            # the router reads from the fabric's export
            unzoned.zones = ["home"];
          };
        };
        # no upstream BGP peer: a home network has none
        mesh.roles = {
          spine.machines.alpha.settings.border = null;
          leaf.machines.beta.settings.border = null;
        };
      };
    };

    nodes = {
      alpha = {
        imports = [(node "alpha")];
        virtualisation.vlans = [
          1
          2
          3
        ];
        # a listener on every address: what the WAN must not reach
        services.openssh.enable = true;
      };
      beta = {
        imports = [(node "beta")];
        # eth1 is on a network of its own and stays unused
        virtualisation.vlans = [
          9
          1
        ];
      };
      # the body's foreign FRR host: here a machine in zone servers
      router = {pkgs, ...}: {
        imports = [body.nodes.router];
        environment.systemPackages = [pkgs.netcat];
      };
      internet = {pkgs, ...}: {
        imports = [host];
        virtualisation.vlans = [2];
        networking.ifstate.settings = {
          interfaces.eth1 = phys ["${internet4}/24" "${internet6}/64"];
          # the zones' IPv6 is routed, as an ISP routes a delegation
          routing.routes = [
            {
              to = "2001:db8:1::/64";
              via = wan6;
            }
            {
              to = "2001:db8:3::/64";
              via = wan6;
            }
          ];
        };
        systemd.services.echo = {
          wantedBy = ["multi-user.target"];
          serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echo pkgs [80]}";
        };
      };
      client = {
        imports = [host];
        virtualisation.vlans = [3];
        networking.ifstate.settings = {
          interfaces.eth1 = phys ["${clientAddr4}/24" "${clientAddr6}/64"];
          routing.routes = [
            {
              to = "0.0.0.0/0";
              via = "192.168.10.1";
            }
            {
              to = "::/0";
              via = "2001:db8:3::1";
            }
          ];
        };
      };
    };

    testScript = ''
      import ipaddress
      import json
      import re

      ${import ../../../../tests/suite-lib.nix}
      ${import ../../../../tests/ifstate-noop.nix}

      K = "KUBECONFIG=${kubeconfig}"
      NODES = {"alpha": alpha, "beta": beta}
      WAN4 = "${wan4}"
      WAN6 = "${wan6}"
      INTERNET4 = "${internet4}"
      INTERNET6 = "${internet6}"
      CLIENT4 = "${clientAddr4}"
      CLIENT6 = "${clientAddr6}"
      # the fabric peer and Cilium's local session, both address families
      BGP_ALL_UP = "vtysh -c 'show bgp summary json' | jq -e '[.[] | (.peers // {}) | to_entries[] | .value.state] | length >= 2 and all(. == \"Established\")' >/dev/null"
      ips: dict[str, list[str]] = {}


      def address(text):
          parsed = ipaddress.ip_address(text.strip().strip("[]").split("%")[0])
          return getattr(parsed, "ipv4_mapped", None) or parsed


      def kubectl(args, timeout=60):
          return alpha.succeed(f"{K} timeout {timeout} kubectl {args}")


      def pod_exec(node, command, timeout=40):
          status, out = alpha.execute(f"{K} timeout {timeout} kubectl exec anchor-{node} -- {command} 2>&1")
          return status, out.strip()


      def anchor(node):
          """A pod pinned to `node` that serves HTTP on 8080; records its addresses."""
          overrides = json.dumps({"spec": {"nodeSelector": {"kubernetes.io/hostname": node}}})
          kubectl(f"run anchor-{node} --restart=Never --image=busybox:1.36.1 --image-pull-policy=Never --labels=app=anchor-{node} --overrides='{overrides}' -- httpd -f -p 8080")
          alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready pod/anchor-{node} --timeout=60s", timeout=300)
          pod = json.loads(kubectl(f"get pod anchor-{node} -o json"))
          assert pod["spec"]["nodeName"] == node, pod["spec"]["nodeName"]
          ips[node] = [ip["ip"] for ip in pod["status"]["podIPs"]]


      def pod4(node):
          return next(ip for ip in ips[node] if ":" not in ip)


      def agent(node, command):
          pod = kubectl(f"-n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName={node} -o name").strip()
          return kubectl(f"-n kube-system exec {pod} -c cilium-agent -- {command}")


      def masquerade_devices(node):
          lines = [line.strip() for line in agent(node, "cilium-dbg status --verbose").splitlines() if line.strip().startswith("Masquerading:")]
          assert len(lines) == 1 and "BPF" in lines[0], lines
          print(f"FINDING {node}: {lines[0]}")
          match = re.search(r"\[([^\]]*)\]", lines[0])
          assert match is not None, lines[0]
          return sorted(device.strip() for device in match.group(1).split(","))


      def page(target):
          host = f"[{target}]" if ":" in target else target
          return f"curl -sg --max-time 8 http://{host}/"


      def seen_by_internet(machine, target=INTERNET4):
          """The source address the internet host saw."""
          return address(machine.succeed(page(target)).splitlines()[-1])


      def pod_seen(node):
          status, out = pod_exec(node, f"wget -T 8 -qO- http://{INTERNET4}/")
          assert status == 0, f"pod on {node}: rc={status}\n{out}"
          return address(out.splitlines()[-1])


      def egress(when):
          """Everything behind the router leaves with the WAN's IPv4
          address; IPv6 is routed with the sender's own address."""
          wan = address(WAN4)
          got = {
              "alpha's pod": pod_seen("alpha"),
              "beta's host": seen_by_internet(beta),
              "beta's pod": pod_seen("beta"),
              "the home client": seen_by_internet(client),
              "alpha itself": seen_by_internet(alpha),
          }
          assert all(seen == wan for seen in got.values()), f"{when}: the IPv4 internet saw {got}"
          seen = seen_by_internet(client, INTERNET6)
          assert seen == address(CLIENT6), f"{when}: the IPv6 internet saw the home client as {seen}"
          seen = seen_by_internet(beta, INTERNET6)
          assert seen == address("2001:db8:1::2"), f"{when}: the IPv6 internet saw beta as {seen}"


      def refusals(when):
          """Default deny, with a cluster on the router."""
          # zone to zone: home may not open flows to servers
          router.succeed("ping -c1 -W2 192.168.1.2")
          client.fail("ping -c1 -W2 192.168.1.2")
          # the WAN reaches nothing of the router or of the cluster
          for port in [22, 53, 6443, 10250, 2379]:
              internet.fail(f"nc -z -w3 {WAN4} {port}")
              internet.fail(f"nc -z -w3 {WAN6} {port}")
          # a zone reaches the router's SSH and its own resolver, and not
          # the cluster's ports: those are open on the fabric only
          router.succeed("nc -z -w3 192.168.1.1 22")
          client.succeed("nc -z -w3 192.168.10.1 22")
          answer = router.succeed("dig +short +time=2 +tries=2 service.test @192.168.1.1").strip()
          assert answer == INTERNET4, f"{when}: {answer}"
          for port in [6443, 10250, 2379]:
              router.fail(f"nc -z -w3 192.168.1.1 {port}")
              client.fail(f"nc -z -w3 192.168.10.1 {port}")
          # the home zone reaches pods on both nodes (`unzoned.zones`)
          for name in NODES:
              alpha.succeed("rm -f /tmp/trace; systemd-run --unit=trace -p StandardOutput=file:/tmp/trace /run/current-system/sw/bin/timeout 12 /run/current-system/sw/bin/tcpdump -ni any -c 40 tcp port 8080 and host " + CLIENT4)
              status, out = client.execute(f"curl -s --max-time 8 -o /dev/null -w '%{{http_code}}' http://{pod4(name)}:8080/")
              if status != 0 or out.strip() not in ("200", "404"):
                  alpha.execute("sleep 5")
                  print(f"FINDING {when}: the home client to the pod on {name}: rc={status} {out!r}; alpha saw:\n" + alpha.execute("cat /tmp/trace")[1])
                  print(agent("alpha", "cilium-dbg bpf ct list global 2>/dev/null | grep -F " + CLIENT4 + " | head -n 10 || true"))
                  print(alpha.execute("conntrack -L 2>/dev/null | grep -F " + CLIENT4 + "; nft list chain inet router forward; ip route get " + CLIENT4 + " from " + pod4(name) + " iif cilium_host")[1])
              alpha.execute("systemctl stop trace.service 2>/dev/null")
              assert status == 0 and out.strip() in ("200", "404"), f"{when}: the home client to the pod on {name}: rc={status}, HTTP {out}"
          # zone servers has no such permission: a host there that is no
          # node does not reach a pod, though it has a route
          for name in NODES:
              router.succeed(f"ip route replace {pod4(name)}/32 via 192.168.1.1")
              router.fail(f"curl -s --max-time 4 -o /dev/null http://{pod4(name)}:8080/")


      with state_dump_on_failure(
          [alpha, beta, client, internet],
          extra=[
              f"{K} kubectl get nodes,pods -A -o wide",
              "nft list table inet router",
              "nft list table inet nixos-fw",
              "vtysh -c 'show bgp summary'",
              "wg show",
              "conntrack -L 2>/dev/null | tail -n 40",
          ],
      ):
          start_all()

          with subtest("versions; both firewalls are loaded on the router"):
              for machine in [internet, client]:
                  machine.wait_for_unit("multi-user.target", timeout=300)
              internet.wait_until_succeeds("ss -tln | grep ':80 ' >/dev/null", timeout=120)
              for machine in NODES.values():
                  machine.wait_for_unit("multi-user.target", timeout=300)
                  print_versions(machine, ["kernel", "ifstate", "${distro}", "frr", "nftables"])
              for unit in ["nftables.service", "coredns.service", "kea-dhcp4-server.service"]:
                  alpha.wait_for_unit(unit, timeout=120)
              tables = sorted(alpha.succeed("nft list tables").strip().split("\n"))
              print(f"FINDING nftables tables on a router that is a node: {tables}")
              for table in ["table inet router", "table inet nixos-fw"]:
                  assert table in tables, tables
              observe("the router's table", alpha, "nft list table inet router")

          with subtest("the cluster comes up through the router's firewall; the WAN is a Cilium device (D71)"):
              alpha.wait_for_unit("k3s.service", timeout=600)
              beta.wait_for_unit("k3s.service", timeout=600)
              alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s", timeout=900)
              alpha.wait_until_succeeds(f"{K} kubectl wait -n kube-system --for=condition=Ready pod -l k8s-app=cilium --timeout=120s", timeout=300)
              alpha.wait_until_succeeds(f"{K} kubectl get serviceaccount default", timeout=120)
              for machine in NODES.values():
                  machine.wait_until_succeeds(BGP_ALL_UP, timeout=300)
              config = json.loads(kubectl("-n kube-system get configmap cilium-config -o json"))["data"]
              devices = config["devices"].split()
              print(f"FINDING Cilium devices: {devices}")
              assert "eth2" in devices, devices
              # a zone link is not the cluster's: the router judges it
              assert "eth1" not in devices and "eth3" not in devices, devices
              # beta's default-route link (eth2 there) carries its pods
              assert "eth2" in masquerade_devices("beta")
              assert "eth2" in masquerade_devices("alpha")
              # the fabric's WireGuard arrived on the zone link
              hits = alpha.succeed("nft list chain inet router input | grep 'host ports'")
              print(f"FINDING the router's host-port rules:\n{hits.rstrip()}")
              print("ROUTER_KUBE_CLUSTER_OK")

          with subtest("IPv4 leaves with the WAN address: pods, nodes and a LAN client; IPv6 is routed"):
              for name in NODES:
                  anchor(name)
              print(f"FINDING pod addresses: {ips}")
              egress("first")
              # which of the two masquerades carried beta's pod
              flows = alpha.succeed(f"conntrack -L -p tcp --dst {INTERNET4} 2>/dev/null | tail -n 12 || true")
              print(f"FINDING alpha's conntrack entries towards the internet host:\n{flows.rstrip()}")
              for name in NODES:
                  status, out = pod_exec(name, f"wget -T 8 -qO- http://[{INTERNET6}]/")
                  print(f"FINDING IPv6 from the pod on {name}: rc={status}, the internet saw {out.splitlines()[-1] if out else None!r}")
              print("ROUTER_KUBE_EGRESS_OK")

          with subtest("default deny holds with a cluster on the router: zones, the WAN, pods"):
              refusals("first")
              print("ROUTER_KUBE_DENY_OK")

          with subtest("DHCPv4 and the zone's resolver answer through both firewalls"):
              out = client.succeed("busybox udhcpc -i eth1 -n -q -f -t 5 -T 2 -s /run/current-system/sw/bin/true 2>&1")
              print(f"FINDING udhcpc on the home zone:\n{out.rstrip()}")
              assert "lease of 192.168.10." in out, out
              answer = client.succeed("dig +short +time=2 +tries=2 service.test @192.168.10.1").strip()
              assert answer == INTERNET4, answer
              answer = client.succeed("dig +tcp +short +time=2 +tries=2 service.test @192.168.10.1").strip()
              assert answer == INTERNET4, answer
              # the other zone's resolver address is not this zone's
              client.fail("dig +short +time=2 +tries=1 service.test @192.168.1.1")
              internet.fail(f"dig +short +time=2 +tries=1 service.test @{WAN4}")

          with subtest("a NodePort does not answer on the WAN address (D69)"):
              kubectl("expose pod anchor-alpha --port=8080 --type=NodePort --name=np")
              kubectl("patch service np --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":30080}]'")
              config = json.loads(kubectl("-n kube-system get configmap cilium-config -o json"))["data"]
              print(f"FINDING Cilium nodeport-addresses: {config.get('nodeport-addresses')!r}")
              assert WAN4 not in config.get("nodeport-addresses", ""), config.get("nodeport-addresses")
              code = "curl -s --max-time 4 -o /dev/null -w '%{http_code}' "
              internal = [ip for ip in kubectl("get node alpha -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'").split() if ":" not in ip]
              assert internal, "alpha has no IPv4 node address"
              for ip in internal:
                  answer = beta.wait_until_succeeds(f"{code}http://{ip}:30080/ | grep -v '^000$'", timeout=60).strip()
                  print(f"FINDING the NodePort on {ip} answered beta with HTTP {answer}")
              status, answer = internet.execute(f"{code}http://{WAN4}:30080/")
              print(f"FINDING the NodePort on the WAN address from the internet: rc={status} code={answer!r}")
              assert answer.strip() == "000", answer
              kubectl("delete service np")

          with subtest("a restart of nftables and an IfState apply on the router: the cluster and the zones still work"):
              owned = alpha.succeed("nft -s list table inet router")
              alpha.succeed("systemctl restart nftables.service")
              assert alpha.succeed("nft -s list table inet router") == owned
              for machine in NODES.values():
                  machine.wait_until_succeeds(BGP_ALL_UP, timeout=120)
              alpha.wait_until_succeeds(f"{K} kubectl exec anchor-beta -- wget -T 5 -qO- http://{INTERNET4}/", timeout=120)
              egress("after an nftables restart")
              refusals("after an nftables restart")
              assert_ifstate_noop(alpha)
              egress("after an IfState apply")
              alpha.wait_until_succeeds(f"{K} kubectl wait --for=condition=Ready node/alpha node/beta --timeout=60s", timeout=120)
              for machine in [alpha, beta]:
                  machine.fail("systemctl --failed --no-legend | grep .")

      for machine in [alpha, beta]:
          print(f"FINDING guard drops on {machine.name} at the end of the suite: " + " | ".join(l.strip() for l in machine.succeed("nft list ruleset | awk '/^table inet (routed-fabric|kube)-/,/^}/' | grep 'counter packets [1-9]' || true").splitlines()))
      print("ROUTER_KUBE_OK")
    '';
  }
