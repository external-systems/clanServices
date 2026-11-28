# hostile-fabric: a hostile actor against the routed fabric. Hermetic:
# four VMs on one test VLAN, no real network.
#
#   outsider  192.168.1.66, on the underlay LAN, holds no key
#   hub, hub2 spines
#   victim    leaf on both spines
#   rogue     leaf on both spines: a real member (valid keys, valid BGP
#             sessions) whose root user turns hostile
#
# Every attack ends in one `verdict(id, safe, detail)`. The suite runs
# all of them, prints a `HOSTILE SAFE|GAP <id>` line each, and fails at
# the end when any is a gap. A new attack is a new verdict; never
# delete one to make the suite pass.
#
# Every group of verdicts has a positive control: `control(id, worked,
# detail)` shows that the attack is real (it works without the guard,
# with `guard_off`), or that its packets arrive, or that the same
# probe finds what it looks for on a legal target. A SAFE without a
# working control proves nothing, so a control that did not work fails
# the suite as a gap does.
#
# The design and the invariants: specs/design-routed-fabric.md §2 and §6
# (SPEC.md D73).
{
  lib,
  inputs,
  nodes,
  ...
}: let
  fleet = name: nodes.${name}.clan.networkFacts.fabric.fleet;
  adj = name: remote: (fleet name).adjacencies.${remote};
  members = {
    hub = "192.168.1.1";
    victim = "192.168.1.2";
    rogue = "192.168.1.3";
    hub2 = "192.168.1.4";
  };
  stable = lib.mapAttrs (name: _: {inherit (fleet name) ipv4 ipv6;}) members;
  outsider = "192.168.1.66";
in {
  name = "hostile-fabric";

  clan = {
    directory = ./.;
    test.useContainers = false;

    inventory = {
      machines =
        lib.mapAttrs (_: _: {}) members
        // {
          outsider = {};
        };

      instances = {
        underlay = {
          module.name = "internet";
          roles.default.machines = lib.mapAttrs (_: host: {settings = {inherit host;};}) members;
        };

        fleet = {
          module.name = "routed-fabric";
          module.input = "self";
          roles = {
            spine.settings = {
              site = "lab";
              endpointSources = [
                {
                  service = "clan-core/internet";
                  instance = "underlay";
                }
              ];
            };
            leaf.settings.site = "lab";
            spine.machines = {
              hub = {};
              hub2 = {};
            };
            leaf.machines = {
              victim = {};
              rogue = {};
            };
          };
        };
      };
    };
  };

  nodes =
    lib.mapAttrs
    (_name: address: {pkgs, ...}: {
      imports = [
        (import ../../../../tests/ifstate-vm.nix {
          ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
          addresses = ["${address}/24"];
        })
      ];
      environment.systemPackages = [
        pkgs.tcpdump
        pkgs.nmap
        pkgs.netcat-openbsd
        pkgs.iperf3
      ];
      virtualisation = {
        cores = 1;
        memorySize = 1536;
      };
    })
    members
    // {
      outsider = {pkgs, ...}: {
        imports = [
          (import ../../../../tests/ifstate-vm.nix {
            ifstateOverlay = inputs.org-pkgs.overlays.ifstate;
            addresses = ["${outsider}/24"];
            withBase = true;
          })
        ];
        networking.firewall.enable = false;
        boot.kernelModules = ["wireguard"];
        environment.systemPackages = [
          pkgs.tcpdump
          pkgs.nmap
          pkgs.netcat-openbsd
          pkgs.wireguard-tools
          pkgs.iputils
        ];
        virtualisation = {
          cores = 2;
          memorySize = 1024;
        };
      };
    };

  testScript = ''
    import json

    ${import ../../../../tests/suite-lib.nix}

    fabric = [hub, hub2, victim, rogue]
    underlay = ${builtins.toJSON members}
    stable = ${builtins.toJSON stable}
    hub_victim = "${(adj "hub" "victim").interface}"
    hub_rogue = "${(adj "hub" "rogue").interface}"
    victim_hub = "${(adj "victim" "hub").interface}"
    rogue_hub = "${(adj "rogue" "hub").interface}"
    hub_on_rogue_link4 = "${(adj "hub" "rogue").ipv4}"
    hub_on_rogue_link6 = "${(adj "hub" "rogue").ipv6}"
    rogue_on_hub_link4 = "${(adj "rogue" "hub").ipv4}"
    rogue_on_hub_link6 = "${(adj "rogue" "hub").ipv6}"
    victim_hub2 = "${(adj "victim" "hub2").interface}"
    rogue_hub2 = "${(adj "rogue" "hub2").interface}"
    hub2_victim = "${(adj "hub2" "victim").interface}"
    hub2_rogue = "${(adj "hub2" "rogue").interface}"
    hub_on_victim_link4 = "${(adj "hub" "victim").ipv4}"
    hub2_on_victim_link4 = "${(adj "hub2" "victim").ipv4}"
    hub2_on_rogue_link4 = "${(adj "hub2" "rogue").ipv4}"
    victim_on_hub_link4 = "${(adj "victim" "hub").ipv4}"
    victim_on_hub_link6 = "${(adj "victim" "hub").ipv6}"
    contract = ${builtins.toJSON (lib.genAttrs ["hub" "hub2" "victim" "rogue"] (name: lib.mapAttrs (_: a: {inherit (a) sources destinations allowedIPs;}) (fleet name).adjacencies))}
    outsider_ip = "${outsider}"

    RESULTS = []


    def verdict(key, safe, detail=""):
        RESULTS.append((key, bool(safe), detail))
        print(f"HOSTILE {'SAFE' if safe else 'GAP '} {key}: {detail}")


    def capture(machine, unit, iface, direction, expr):
        machine.execute(f"systemctl stop {unit} 2>/dev/null; systemctl reset-failed {unit} 2>/dev/null; rm -f /tmp/{unit}")
        machine.succeed(f"systemd-run --unit={unit} $(command -v tcpdump) -pUni {iface} -Q {direction} -w /tmp/{unit} '{expr}'")
        machine.wait_until_succeeds(f"test -s /tmp/{unit}", timeout=20)


    def captured(machine, unit):
        """The packets a capture saw, one text line each."""
        machine.execute("sleep 1")
        machine.execute(f"systemctl stop {unit}")
        out = machine.succeed(f"tcpdump -nr /tmp/{unit} 2>/dev/null || true")
        return [line for line in out.splitlines() if line.strip()]


    def open_ports(target, family=""):
        """Open TCP ports of one address, as the outsider sees them."""
        out = outsider.succeed(f"nmap {family} -n -Pn -sS -p- --min-rate 3000 --max-retries 1 -oG - {target} 2>&1")
        found = []
        for line in out.splitlines():
            if "Ports:" in line:
                found += [p.split("/")[0].strip() for p in line.split("Ports:")[1].split(",") if "/open/" in p]
        return found


    CONTROLS = []


    def control(key, worked, detail=""):
        """A positive control: the attack of a verdict group is real."""
        CONTROLS.append((key, bool(worked), detail))
        print(f"HOSTILE CONTROL {'OK  ' if worked else 'FAIL'} {key}: {detail}")


    def guard_drops(machine, comment):
        return drops(machine, "inet routed-fabric-fleet", comment)


    def guard_off(machine):
        """For a positive control: the same attack without the guard."""
        machine.succeed("nft delete table inet routed-fabric-fleet")


    def guard_on(machine):
        machine.succeed("systemctl reload nftables")
        machine.succeed("nft list table inet routed-fabric-fleet >/dev/null")


    def established(machine):
        return int(machine.succeed("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' || true").strip())


    def uptimes(machine):
        """Milliseconds each BGP session of a machine has been up."""
        out = json.loads(machine.succeed("vtysh -c 'show bgp summary json'"))
        result = {}
        for family in out.values():
            for peer, data in family.get("peers", {}).items():
                result[peer] = data.get("peerUptimeEstablishedEpoch", 0) if data.get("state") == "Established" else -1
        return result


    def restarted(before, after):
        """Sessions that are down or came up anew. FRR derives the epoch
        from "now minus uptime", so it moves by a second between reads."""
        return sorted(peer for peer in before if after.get(peer, -1) < 0 or abs(after[peer] - before[peer]) > 5)


    def bfd_up(machine):
        out = json.loads(machine.succeed("vtysh -c 'show bfd peers json'"))
        return sorted((p.get("peer"), p.get("status"), p.get("uptime", 0) > 0) for p in out)


    def widen(machine, link, extra):
        """A hostile root adds prefixes to its own WireGuard ACL."""
        peer, allowed = machine.succeed(f"wg show {link} allowed-ips").strip().split("\t")
        machine.succeed(f"wg set {link} peer {peer} allowed-ips {allowed.replace(' ', ',')},{extra}")


    def bgp_routes(machine, family, neighbor):
        """The prefixes one machine ACCEPTED from one neighbor."""
        out = machine.succeed(f"vtysh -c 'show bgp {family} unicast neighbors {neighbor} routes json'")
        return sorted(json.loads(out).get("routes", {}).keys())


    try:
        start_all()
        outsider.wait_for_unit("multi-user.target")

        with subtest("the fabric is up before any attack"):
            for machine in fabric:
                machine.wait_for_unit("frr.service", timeout=180)
            for machine, sessions in [(hub, 6), (hub2, 6), (victim, 4), (rogue, 4)]:
                machine.wait_until_succeeds(
                    f"vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^{sessions}$' >/dev/null",
                    timeout=240,
                )
            for source in fabric:
                for target in stable:
                    if target != source.name:
                        source.wait_until_succeeds(f"ping -c 2 -W 2 {stable[target]['ipv4']}", timeout=120)
                        source.wait_until_succeeds(f"ping -6 -c 2 -W 2 {stable[target]['ipv6']}", timeout=120)
            link_local = {
                machine.name: machine.succeed("ip -6 -o addr show dev eth1 scope link | awk '{print $4}' | cut -d/ -f1").strip()
                for machine in fabric
            }
            asn = {
                machine.name: machine.succeed("vtysh -c 'show running-config' | awk '/^router bgp/ {print $3; exit}'").strip()
                for machine in fabric
            }
            link_local_outsider = outsider.succeed("ip -6 -o addr show dev eth1 scope link | awk '{print $4}' | cut -d/ -f1").strip()
            print(f"link-local: {link_local}; outsider {link_local_outsider}; asn: {asn}")

        # ------------------------------------------------------------------
        # The outsider: on the underlay LAN, no key
        # ------------------------------------------------------------------
        with subtest("outsider: a full TCP scan of every member's underlay address, both families"):
            # control: the same scan finds a port the hub opens on purpose
            hub.succeed("nft insert rule inet nixos-fw input-allow iifname eth1 tcp dport { 4444, 4445 } accept")
            hub.succeed("systemd-run --unit=listen-4444 $(command -v nc) -4 -lk 4444")
            hub.succeed("systemd-run --unit=listen-4445 $(command -v nc) -6 -lk 4445")
            hub.wait_until_succeeds("ss -tln | grep ':4444 ' >/dev/null && ss -tln | grep ':4445 ' >/dev/null", timeout=20)
            seen4, seen6 = open_ports(underlay["hub"]), open_ports(f"{link_local['hub']}%eth1", "-6")
            control("F01/F02 the scan finds the ports the hub opened on its underlay", "4444" in seen4 and "4445" in seen6, f"IPv4 {seen4}, IPv6 {seen6}")
            hub.succeed("systemctl stop listen-4444 listen-4445")
            hub.succeed("nft delete rule inet nixos-fw input-allow handle $(nft -a list chain inet nixos-fw input-allow | awk '/4445/ {print $NF}')")
            for name, address in underlay.items():
                found = open_ports(address)
                verdict(f"F01 no TCP port open on the underlay ({name}, IPv4)", not found, f"open: {found}")
                found = open_ports(f"{link_local[name]}%eth1", "-6")
                verdict(f"F02 no TCP port open on the underlay ({name}, IPv6 link-local)", not found, f"open: {found}")

        with subtest("outsider: BGP is not reachable from the underlay, directly or through the spine"):
            # every fabric address by way of the spine's underlay address
            outsider.succeed("ip route add 198.18.0.0/15 via 192.168.1.1")
            outsider.succeed(f"ip -6 route add fd00::/8 via {link_local['hub']} dev eth1")
            capture(hub, "cap-f03", "eth1", "in", f"tcp port 179 and src host {outsider_ip}")
            for name in stable:
                code, _ = outsider.execute(f"nc -z -w 3 {stable[name]['ipv4']} 179")
                verdict(f"F03 BGP (179) of {name}'s fabric address refuses the outsider (IPv4)", code != 0)
                code, _ = outsider.execute(f"nc -z -w 3 {stable[name]['ipv6']} 179")
                verdict(f"F04 BGP (179) of {name}'s fabric address refuses the outsider (IPv6)", code != 0)
            syns = captured(hub, "cap-f03")
            control("F03 the outsider's connects to 179 arrive on the spine's underlay", len(syns) >= len(stable), f"{len(syns)} packets")

        with subtest("outsider: its own address cannot enter the fabric through the spine"):
            capture(hub, "cap-f05", hub_victim, "out", f"host {outsider_ip}")
            code, _ = outsider.execute(f"ping -c 3 -W 1 {stable['victim']['ipv4']}")
            forwarded = captured(hub, "cap-f05")
            verdict("F05 the spine does not forward underlay traffic into a fabric link", not forwarded, f"{len(forwarded)} packets forwarded: {forwarded[:2]}")
            verdict("F06 a member does not answer the outsider on its fabric address through the spine", code != 0)
            code, _ = outsider.execute(f"ping -c 3 -W 1 {stable['hub']['ipv4']}")
            verdict("F07 the spine does not answer the outsider on its fabric address", code != 0)
            capture(hub, "cap-f05c", hub_victim, "out", f"host {outsider_ip}")
            guard_off(hub)
            outsider.execute(f"ping -c 3 -W 1 {stable['victim']['ipv4']}")
            code, _ = outsider.execute(f"ping -c 3 -W 1 {stable['hub']['ipv4']}")
            guard_on(hub)
            forwarded = captured(hub, "cap-f05c")
            control("F05..F07 without the spine's guard table it forwards the outsider into a fabric link and answers on its fabric address", forwarded and code == 0, f"{len(forwarded)} packets forwarded; ping of the hub's loopback rc={code}")

        with subtest("outsider: a forged fabric source cannot enter the fabric through the spine"):
            for family, flag, key in [("IPv4", "", "ipv4"), ("IPv6", "-6", "ipv6")]:
                forged, target = stable["rogue"][key], stable["victim"][key]
                outsider.succeed(f"ip addr add {forged} dev lo")
                capture(victim, "cap-f08", victim_hub, "in", f"src host {forged} and (icmp or icmp6)")
                capture(rogue, "cap-f09", rogue_hub, "in", f"src host {target} and (icmp or icmp6)")
                outsider.execute(f"ping {flag} -c 3 -W 1 -I {forged} {target}")
                arrived = [l for l in captured(victim, "cap-f08") if "echo request" in l]
                reflected = [l for l in captured(rogue, "cap-f09") if "echo reply" in l]
                verdict(f"F08 a packet with a forged member source does not reach a member ({family})", not arrived, f"{len(arrived)} forged echo requests arrived at victim")
                verdict(f"F09 a member is not made to answer a forged source ({family})", not reflected, f"{len(reflected)} unasked echo replies reached the forged member")
                capture(victim, "cap-f08c", victim_hub, "in", f"src host {forged} and (icmp or icmp6)")
                guard_off(hub)
                outsider.execute(f"ping {flag} -c 3 -W 1 -I {forged} {target}")
                guard_on(hub)
                arrived = [l for l in captured(victim, "cap-f08c") if "echo request" in l]
                control(f"F08/F09 without the spine's guard table the forged source reaches a member ({family})", arrived, f"{len(arrived)} forged echo requests arrived at victim")
                outsider.succeed(f"ip addr del {forged} dev lo")

        with subtest("outsider: WireGuard does not answer an unknown key"):
            port = hub.succeed(f"wg show {hub_rogue} listen-port").strip()
            public = hub.succeed(f"wg show {hub_rogue} public-key").strip()
            capture(hub, "cap-f10", "eth1", "in", f"udp port {port} and src host {outsider_ip}")
            outsider.succeed(
                "umask 077; wg genkey > /tmp/key; ip link add wgx type wireguard; "
                f"wg set wgx private-key /tmp/key peer {public} endpoint 192.168.1.1:{port} allowed-ips 0.0.0.0/0 persistent-keepalive 1; "
                "ip link set wgx up; sleep 8"
            )
            handshake = outsider.succeed("wg show wgx latest-handshakes").split()
            verdict("F10 WireGuard completes no handshake with an unknown key", handshake[1] == "0", f"latest handshake: {handshake[1]}")
            initiations = captured(hub, "cap-f10")
            control("F10 the outsider's handshake initiations arrive at the spine's WireGuard port", initiations, f"{len(initiations)} packets")
            outsider.succeed("ip link del wgx")

        # ------------------------------------------------------------------
        # The rogue member: valid keys and sessions, hostile root
        # ------------------------------------------------------------------
        with subtest("rogue: forged sources on its own link"):
            # control: the same ping with the rogue's own source arrives
            capture(hub, "cap-f11c", hub_rogue, "in", f"src host {stable['rogue']['ipv4']} and icmp")
            rogue.execute(f"ping -c 3 -W 1 -I {stable['rogue']['ipv4']} {stable['hub']['ipv4']}")
            arrived = [l for l in captured(hub, "cap-f11c") if "echo request" in l]
            control("F11 the rogue's echo requests with its own source arrive at the spine", len(arrived) == 3, f"{len(arrived)} of 3")
            cases = [
                ("another member's address", stable["victim"]["ipv4"], ""),
                ("another member's address", stable["victim"]["ipv6"], "-6"),
                ("an address outside the fabric", "203.0.113.9", ""),
            ]
            for label, forged, flag in cases:
                target = stable["hub"]["ipv6" if flag else "ipv4"]
                rogue.succeed(f"ip addr add {forged} dev lo")
                capture(hub, "cap-f11", hub_rogue, "in", f"src host {forged} and (icmp or icmp6)")
                rogue.execute(f"ping {flag} -c 3 -W 1 -I {forged} {target}")
                arrived = [l for l in captured(hub, "cap-f11") if "echo request" in l]
                rogue.succeed(f"ip addr del {forged} dev lo")
                verdict(f"F11 the spine drops {label} as a source on a leaf link ({forged})", not arrived, f"{len(arrived)} forged echo requests accepted by hub")

        with subtest("rogue: BGP hijacks are not accepted"):
            own4, own6 = stable["rogue"]["ipv4"] + "/32", stable["rogue"]["ipv6"] + "/128"
            hijack4 = [stable["victim"]["ipv4"] + "/32", stable["hub"]["ipv4"] + "/32", "0.0.0.0/0", "10.66.0.0/16", "198.18.0.0/15"]
            hijack6 = [stable["victim"]["ipv6"] + "/128", stable["hub"]["ipv6"] + "/128", "::/0", "fd66::/48"]
            assert bgp_routes(hub, "ipv4", rogue_on_hub_link4) == [own4], "precondition: the rogue's own /32 only"
            before4 = victim.succeed("ip -4 route show table all | grep -v ' expires ' | sort")
            before6 = victim.succeed("ip -6 route show table all | grep -v ' expires ' | sort")
            commands = ["conf t", "route-map EVIL permit 10", "exit", f"router bgp {asn['rogue']}", "no bgp network import-check"]
            commands += ["address-family ipv4 unicast", f"neighbor {hub_on_rogue_link4} route-map EVIL out"]
            commands += [f"network {prefix}" for prefix in hijack4] + ["exit-address-family"]
            commands += ["address-family ipv6 unicast", f"neighbor {hub_on_rogue_link6} route-map EVIL out"]
            commands += [f"network {prefix}" for prefix in hijack6] + ["exit-address-family"]
            rogue.succeed("vtysh " + " ".join(f"-c '{c}'" for c in commands))
            rogue.succeed("vtysh -c 'clear bgp * soft out'")
            # the attack is real: the rogue advertises every hijack
            for family, neighbor, hijacks in [("ipv4", hub_on_rogue_link4, hijack4), ("ipv6", hub_on_rogue_link6, hijack6)]:
                rogue.wait_until_succeeds(
                    f"vtysh -c 'show bgp {family} unicast neighbors {neighbor} advertised-routes json' | grep -F '\"{hijacks[0]}\"' >/dev/null",
                    timeout=60,
                )
                sent = json.loads(rogue.succeed(f"vtysh -c 'show bgp {family} unicast neighbors {neighbor} advertised-routes json'"))
                missing = [p for p in hijacks if p not in sent.get("advertisedRoutes", {})]
                control(f"F12..F16 the rogue advertises every hijack ({family})", not missing, f"not advertised: {missing}")
            hub.succeed("sleep 15")
            got4 = bgp_routes(hub, "ipv4", rogue_on_hub_link4)
            got6 = bgp_routes(hub, "ipv6", rogue_on_hub_link6)
            verdict("F12 the spine accepts only the leaf's own /32 from it", got4 == [own4], f"accepted: {got4}")
            verdict("F13 the spine accepts only the leaf's own /128 from it", got6 == [own6], f"accepted: {got6}")
            route = hub.succeed(f"ip route get {stable['victim']['ipv4']}")
            verdict("F14 the spine still routes the victim's address to the victim", hub_victim in route, route.strip())
            after4 = victim.succeed("ip -4 route show table all | grep -v ' expires ' | sort")
            after6 = victim.succeed("ip -6 route show table all | grep -v ' expires ' | sort")
            verdict("F15 the victim's IPv4 routes did not change", before4 == after4, "" if before4 == after4 else f"before:\n{before4}\nafter:\n{after4}")
            verdict("F16 the victim's IPv6 routes did not change", before6 == after6, "" if before6 == after6 else f"before:\n{before6}\nafter:\n{after6}")
            victim.succeed(f"ping -c 2 -W 2 {stable['hub']['ipv4']}")
            hub.succeed(f"ping -c 2 -W 2 {stable['victim']['ipv4']}")
            # the rogue takes its hijacks back: a locally originated /32 of
            # another member replaced its own learned route to that member
            undo = ["conf t", f"router bgp {asn['rogue']}", "address-family ipv4 unicast"]
            undo += [f"no network {prefix}" for prefix in hijack4] + ["exit-address-family", "address-family ipv6 unicast"]
            undo += [f"no network {prefix}" for prefix in hijack6] + ["exit-address-family"]
            rogue.succeed("vtysh " + " ".join(f"-c '{c}'" for c in undo))
            rogue.wait_until_succeeds(f"ping -c 2 -W 2 {stable['victim']['ipv4']}", timeout=60)
            rogue.wait_until_succeeds(f"ping -6 -c 2 -W 2 {stable['victim']['ipv6']}", timeout=60)

        with subtest("rogue: the spine is not its router to the underlay"):
            # a hostile root widens its own WireGuard ACL first
            peer, allowed = rogue.succeed(f"wg show {rogue_hub} allowed-ips").strip().split("\t")
            rogue.succeed(f"wg set {rogue_hub} peer {peer} allowed-ips {allowed.replace(' ', ',')},{outsider_ip}/32")
            rogue.succeed(f"ip route add {outsider_ip}/32 via {hub_on_rogue_link4} dev {rogue_hub}")
            capture(outsider, "cap-f17", "eth1", "in", f"src host {stable['rogue']['ipv4']} and icmp")
            rogue.execute(f"ping -c 3 -W 1 -I {stable['rogue']['ipv4']} {outsider_ip}")
            leaked = [l for l in captured(outsider, "cap-f17") if "echo request" in l]
            verdict("F17 the spine does not forward fabric traffic out to the underlay", not leaked, f"{len(leaked)} packets with a fabric source left on the underlay")
            capture(outsider, "cap-f17c", "eth1", "in", f"src host {stable['rogue']['ipv4']} and icmp")
            guard_off(hub)
            rogue.execute(f"ping -c 3 -W 1 -I {stable['rogue']['ipv4']} {outsider_ip}")
            guard_on(hub)
            leaked = [l for l in captured(outsider, "cap-f17c") if "echo request" in l]
            control("F17 without the spine's guard table the rogue's packets leave on the underlay", leaked, f"{len(leaked)} packets")
            rogue.succeed(f"ip route del {outsider_ip}/32")

        # ------------------------------------------------------------------
        # The link contract (D73): one value per adjacency
        # ------------------------------------------------------------------
        with subtest("contract: the two ends of every adjacency mirror, and WireGuard carries exactly the sources"):
            mirrored, acl = [], []
            for name, links in contract.items():
                for remote, own in links.items():
                    other = contract[remote][name]
                    host = lambda cidrs: sorted(c for c in cidrs if not c.startswith("198.19.") and ":1:" not in c)
                    if host(own["sources"]) != host(other["destinations"]):
                        mirrored.append(f"{name}<-{remote}")
                    if sorted(own["allowedIPs"]) != sorted(own["sources"]):
                        acl.append(f"{name}<-{remote}")
            verdict("C01 what one end accepts as a source is what the other end is sent routes for", not mirrored, f"differ: {mirrored}")
            verdict("C02 the WireGuard ACL of every link equals its source contract", not acl, f"differ: {acl}")
            live = sorted(hub.succeed(f"wg show {hub_rogue} allowed-ips").split("\t")[1].split())
            verdict("C03 the running ACL of hub's link to rogue is the rogue's own addresses and its transfer address", live == sorted(contract["hub"]["rogue"]["sources"]), f"live: {live}")
            zero = [f"{n}<-{r}" for n, links in contract.items() for r, own in links.items() if any(c.endswith("/0") for c in own["allowedIPs"])]
            verdict("C04 no fabric link has a 0/0 ACL", not zero, f"{zero}")

        with subtest("rogue: a destination it has no route for is refused on the spine"):
            # the victim's transfer address on the hub-victim link: hub has a
            # connected route for it, the rogue is sent no route for it
            widen(rogue, rogue_hub, f"{victim_on_hub_link4}/32,{victim_on_hub_link6}/128,{underlay['victim']}/32")
            for label, target, flag in [("IPv4", victim_on_hub_link4, ""), ("IPv6", victim_on_hub_link6, "-6")]:
                via = hub_on_rogue_link4 if not flag else hub_on_rogue_link6
                rogue.succeed(f"ip {flag} route add {target} via {via} dev {rogue_hub}")
                before = guard_drops(hub, "rogue: destination outside its contract")
                capture(victim, "cap-f18", victim_hub, "in", f"src host {stable['rogue']['ipv6' if flag else 'ipv4']} and (icmp or icmp6)")
                code, _ = rogue.execute(f"ping {flag} -c 3 -W 1 -I {stable['rogue']['ipv6' if flag else 'ipv4']} {target}")
                arrived = [l for l in captured(victim, "cap-f18") if "echo request" in l]
                after = guard_drops(hub, "rogue: destination outside its contract")
                rogue.succeed(f"ip {flag} route del {target}")
                verdict(f"F18 a leaf does not reach an address it is sent no route for ({label})", code != 0 and not arrived and after >= before + 3, f"ping rc={code}, {len(arrived)} arrived, hub dropped {after - before}")
            # control: without the spine's guard the same packets arrive
            rogue.succeed(f"ip route add {victim_on_hub_link4} via {hub_on_rogue_link4} dev {rogue_hub}")
            capture(victim, "cap-f18c", victim_hub, "in", f"src host {stable['rogue']['ipv4']} and icmp")
            guard_off(hub)
            rogue.execute(f"ping -c 3 -W 1 -I {stable['rogue']['ipv4']} {victim_on_hub_link4}")
            guard_on(hub)
            arrived_c = [l for l in captured(victim, "cap-f18c") if "echo request" in l]
            rogue.succeed(f"ip route del {victim_on_hub_link4}")
            control("F18 without the spine's guard table the echo requests reach the victim's transfer address", len(arrived_c) == 3, f"{len(arrived_c)} of 3")
            # an underlay address of another member, through the spine
            rogue.succeed(f"ip route add {underlay['victim']}/32 via {hub_on_rogue_link4} dev {rogue_hub}")
            capture(victim, "cap-f19", "eth1", "in", f"src host {stable['rogue']['ipv4']} and icmp")
            before = guard_drops(hub, "rogue: destination outside its contract")
            rogue.execute(f"ping -c 3 -W 1 -I {stable['rogue']['ipv4']} {underlay['victim']}")
            leaked = [l for l in captured(victim, "cap-f19") if "echo request" in l]
            after = guard_drops(hub, "rogue: destination outside its contract")
            capture(victim, "cap-f19c", "eth1", "in", f"src host {stable['rogue']['ipv4']} and icmp")
            guard_off(hub)
            rogue.execute(f"ping -c 3 -W 1 -I {stable['rogue']['ipv4']} {underlay['victim']}")
            guard_on(hub)
            leaked_c = [l for l in captured(victim, "cap-f19c") if "echo request" in l]
            control("F19 without the spine's guard table the rogue's packets reach the victim's underlay address", len(leaked_c) == 3, f"{len(leaked_c)} of 3")
            rogue.succeed(f"ip route del {underlay['victim']}/32")
            verdict("F19 the spine is not a leaf's router to another member's underlay address", not leaked and after >= before + 3, f"{len(leaked)} leaked, hub dropped {after - before}")

        with subtest("outsider: ARP for a fabric address on the underlay"):
            # D75 (H16): arp_ignore = 1, arp_announce = 2 on every member
            answers = {}
            for name in stable:
                code, out = outsider.execute(f"arping -c 3 -w 4 -I eth1 {stable[name]['ipv4']} 2>&1")
                answers[name] = "Unicast reply" in out
            code, own = outsider.execute(f"arping -c 2 -w 3 -I eth1 {underlay['hub']} 2>&1")
            control("F20 a member still answers ARP for its underlay address", "Unicast reply" in own, own.strip().splitlines()[-1:] if own.strip() else code)
            # control: the attack is real; with the kernel default the hub
            # answers ARP for its fabric loopback on the underlay
            hub.succeed("sysctl -w net.ipv4.conf.all.arp_ignore=0 net.ipv4.conf.eth1.arp_ignore=0")
            code, without = outsider.execute(f"arping -c 3 -w 4 -I eth1 {stable['hub']['ipv4']} 2>&1")
            hub.succeed("sysctl -w net.ipv4.conf.all.arp_ignore=1")
            control("F20 with arp_ignore = 0 the hub answers ARP for its fabric loopback on the underlay", "Unicast reply" in without, without.strip().splitlines()[-1:] if without.strip() else code)
            verdict("F20 no member answers ARP for its fabric address on the underlay", not any(answers.values()), f"answered: {answers}")
            keys = ["net.ipv4.conf.{}.accept_redirects", "net.ipv4.conf.{}.send_redirects", "net.ipv4.conf.{}.accept_source_route", "net.ipv6.conf.{}.accept_ra", "net.ipv6.conf.{}.accept_redirects"]
            values = {link: hub.succeed("sysctl -n " + " ".join(key.format(link) for key in keys)).split() for link in [hub_rogue]}
            print(f"FINDING A8 sysctls IfState set on a fabric link of hub: {values}")
            verdict("F20c a fabric link takes no redirect, no source route and no router advertisement", all(v == ["0"] * len(keys) for v in values.values()), f"{values}")

        with subtest("victim: a fabric destination never leaves by the underlay"):
            # what a rogue DHCP server would push: a more specific route
            victim.succeed(f"ip route add {stable['rogue']['ipv4']}/32 via {outsider_ip} metric 1")
            route = victim.succeed(f"ip route get {stable['rogue']['ipv4']}")
            assert "eth1" in route, route
            capture(outsider, "cap-f22", "eth1", "in", f"dst host {stable['rogue']['ipv4']}")
            before = guard_drops(victim, "fabric destination on a link outside the fabric")
            code, out = victim.execute(f"ping -c 3 -W 1 {stable['rogue']['ipv4']} 2>&1")
            leaked = captured(outsider, "cap-f22")
            after = guard_drops(victim, "fabric destination on a link outside the fabric")
            # control: without the member's guard the same ping leaves by the underlay
            capture(outsider, "cap-f22c", "eth1", "in", f"dst host {stable['rogue']['ipv4']}")
            guard_off(victim)
            victim.execute(f"ping -c 3 -W 1 {stable['rogue']['ipv4']} 2>&1")
            guard_on(victim)
            leaked_c = captured(outsider, "cap-f22c")
            control("F22 without the member's guard table the packets for a fabric address arrive on the LAN gateway", len(leaked_c) >= 3, f"{len(leaked_c)} packets")
            victim.succeed(f"ip route del {stable['rogue']['ipv4']}/32 via {outsider_ip} metric 1")
            verdict("F22 a bogus more-specific route does not send fabric traffic to the underlay", not leaked and after >= before + 3, f"{len(leaked)} leaked, victim dropped {after - before}; ping: {out.strip().splitlines()[-1] if out.strip() else code}")

            # its fabric links are gone and the LAN offers a default route
            victim.succeed(f"ip route add default via {outsider_ip}")
            victim.succeed(f"ip -6 route add default via {link_local_outsider} dev eth1")
            victim.succeed(f"ip link set {victim_hub} down; ip link set {victim_hub2} down")
            victim.wait_until_fails(f"ip route show {stable['rogue']['ipv4']} | grep via >/dev/null", timeout=30)
            victim.wait_until_fails(f"ip -6 route show {stable['rogue']['ipv6']} | grep via >/dev/null", timeout=30)
            unreachable = victim.succeed("ip route show type unreachable; ip -6 route show type unreachable").strip().splitlines()
            print("FINDING P2 unreachable routes on victim: " + " | ".join(unreachable))
            # layer 1, the unreachable aggregates (D75): the lookup fails
            capture(outsider, "cap-f21", "eth1", "in", f"dst host {stable['rogue']['ipv4']} or dst host {stable['rogue']['ipv6']}")
            route = victim.succeed(f"ip route get {stable['rogue']['ipv4']} 2>&1 || true").strip()
            code4, out4 = victim.execute(f"ping -c 3 -W 1 {stable['rogue']['ipv4']} 2>&1")
            code6, out6 = victim.execute(f"ping -6 -c 3 -W 1 {stable['rogue']['ipv6']} 2>&1")
            print("FINDING P2 a ping to a withdrawn fabric address with a LAN default route: " + " | ".join((out4.strip().splitlines() + out6.strip().splitlines())[:4]))
            leaked = captured(outsider, "cap-f21")
            refused = lambda out: "unreachable" in out.lower() or "no route" in out.lower()
            verdict("F21 with its fabric links down a member answers a fabric address with 'No route to host'", not leaked and code4 != 0 and code6 != 0 and refused(route) and refused(out4) and refused(out6), f"{len(leaked)} leaked; route: {' '.join(route.split())}; ping: {out4.strip().splitlines()[-1:]} {out6.strip().splitlines()[-1:]}")
            # layer 2, and the control of layer 1: without the aggregates
            # the kernel routes a fabric address to the LAN gateway, and
            # the guard's egress chain drops it
            for line in unreachable:
                family = "-6" if ":" in line.split()[1] else "-4"
                victim.succeed(f"ip {family} route del {line}")
            route = victim.succeed(f"ip route get {stable['rogue']['ipv4']} 2>&1 || true").strip()
            control("F21 without the unreachable aggregates the member routes a fabric address to the LAN default route", f"via {outsider_ip}" in route, " ".join(route.split()))
            capture(outsider, "cap-f21b", "eth1", "in", f"dst host {stable['rogue']['ipv4']}")
            before = guard_drops(victim, "fabric destination on a link outside the fabric")
            code, out = victim.execute(f"ping -c 3 -W 1 {stable['rogue']['ipv4']} 2>&1")
            leaked = captured(outsider, "cap-f21b")
            after = guard_drops(victim, "fabric destination on a link outside the fabric")
            verdict("F21b without the aggregates the guard still keeps fabric traffic off the default route", not leaked and after >= before + 3, f"{len(leaked)} leaked; victim dropped {after - before}; ping: {out.strip().splitlines()[-1] if out.strip() else code}")
            victim.succeed(f"ip route del default via {outsider_ip}")
            victim.succeed(f"ip -6 route del default via {link_local_outsider} dev eth1")
            # a link that went down lost its IPv6 addresses: IfState puts them back
            victim.succeed("systemctl restart ifstate.service")
            victim.wait_until_succeeds(
                "vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^4$' >/dev/null",
                timeout=180,
            )
            victim.wait_until_succeeds(f"ping -c 2 -W 2 {stable['rogue']['ipv4']}", timeout=60)

        with subtest("rogue and outsider: BGP and BFD answer the link's peer address only"):
            sessions, bfd = established(hub), bfd_up(hub)
            times = uptimes(hub)
            code_loopback, _ = rogue.execute(f"nc -z -w 2 {stable['hub']['ipv4']} 179")
            code_source, _ = rogue.execute(f"nc -z -w 2 -s {stable['rogue']['ipv4']} {hub_on_rogue_link4} 179")
            code_other, _ = rogue.execute(f"nc -z -w 2 -s {rogue_on_hub_link4} {stable['hub']['ipv6']} 179")
            verdict("F23 BGP refuses a member on the spine's loopback and from a source that is not the link's peer address", code_loopback != 0 and code_source != 0 and code_other != 0, f"loopback rc={code_loopback}, loopback source rc={code_source}, v6 loopback rc={code_other}")
            # control: the forged packets must arrive, or "nothing changed" proves nothing
            capture(hub, "cap-f24", hub_rogue, "in", f"udp and (port 4784 or (port 3784 and (ip[8] == 64 or src host {stable['rogue']['ipv4']})))")
            capture(hub, "cap-f24u", "eth1", "in", f"udp port 3784 and src host {outsider_ip}")
            outsider.execute(f"nping --udp -p 3784 --ttl 255 -c 5 --delay 100ms {underlay['hub']} >/dev/null 2>&1")
            rogue.execute(f"nping --udp -p 3784 --ttl 64 -c 5 --delay 100ms -S {rogue_on_hub_link4} {hub_on_rogue_link4} >/dev/null 2>&1")
            rogue.execute(f"nping --udp -p 4784 --ttl 255 -c 5 --delay 100ms -S {rogue_on_hub_link4} {hub_on_rogue_link4} >/dev/null 2>&1")
            rogue.execute(f"nping --udp -p 3784 --ttl 255 -c 5 --delay 100ms -S {stable['rogue']['ipv4']} {stable['hub']['ipv4']} >/dev/null 2>&1")
            hub.succeed("sleep 3")
            forged_seen = len(captured(hub, "cap-f24")) + len(captured(hub, "cap-f24u"))
            control("F24 the forged BFD packets arrive on the spine", forged_seen >= 15, f"{forged_seen} of 20")
            fw = hub.succeed("nft list chain inet nixos-fw input-allow")
            verdict("F24 forged BFD packets change no session", forged_seen >= 15 and bfd_up(hub) == bfd and established(hub) == sessions and "4784" not in fw, f"{forged_seen} forged packets arrived on hub; bfd before={len(bfd)} after={len(bfd_up(hub))}; 4784 open: {'4784' in fw}")
            verdict("F23b the spine's sessions did not reset", not restarted(times, uptimes(hub)), f"restarted: {restarted(times, uptimes(hub))}")
            # a control, last: the one legal path is the peer's own address
            # on its own link. With graceful restart FRR reads a second
            # TCP connection from an established peer as "the peer
            # restarted": a member can reset its own session, nobody else's.
            code_legal, _ = rogue.execute(f"nc -z -w 2 -s {rogue_on_hub_link4} {hub_on_rogue_link4} 179")
            hub.succeed("sleep 3")
            after_legal = uptimes(hub)
            moved = restarted(times, after_legal)
            print(f"FINDING I9 a TCP connect to 179 from the peer's own address on its own link: rc={code_legal}; sessions that restarted: {moved} (the rogue's own IPv4 session is {rogue_on_hub_link4})")
            control("F23 the same connect from the peer's own address on its own link succeeds", code_legal == 0, f"rc={code_legal}")
            verdict("F23d a member can disturb no BGP session but its own", set(moved) <= {rogue_on_hub_link4}, f"restarted: {moved}")
            hub.wait_until_succeeds("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^6$' >/dev/null", timeout=120)
            kinds = json.loads(hub.succeed("vtysh -c 'show bfd peers json'"))
            single = [p.get("peer") for p in kinds if not p.get("multihop") and p.get("status") == "up" and p.get("interface")]
            verdict("F24b every BFD session of the spine is single hop, bound to its link, and up", len(single) == 6 and len(kinds) == 6, f"{len(single)} of {len(kinds)}")

        with subtest("outsider: a forged member source to a member's underlay address is not answered into the fabric"):
            # control: with its own source the outsider is answered
            outsider.succeed(f"ping -c 2 -W 2 {underlay['hub']}")
            forged = stable["victim"]["ipv4"]
            outsider.succeed(f"ip addr add {forged} dev lo")
            # the reply would leave the hub by its link to the victim (the
            # victim's WireGuard then drops it: the hub's underlay address is
            # no source of that link), so the hub's side is what is watched
            capture(hub, "cap-f25", hub_victim, "out", f"icmp and dst host {forged}")
            before = guard_drops(hub, "fabric source from outside the fabric")
            outsider.execute(f"ping -c 3 -W 1 -I {forged} {underlay['hub']}")
            reflected = [l for l in captured(hub, "cap-f25") if "echo reply" in l]
            after = guard_drops(hub, "fabric source from outside the fabric")
            capture(hub, "cap-f25c", hub_victim, "out", f"icmp and dst host {forged}")
            guard_off(hub)
            outsider.execute(f"ping -c 3 -W 1 -I {forged} {underlay['hub']}")
            guard_on(hub)
            reflected_c = [l for l in captured(hub, "cap-f25c") if "echo reply" in l]
            control("F25 without the hub's guard table it sends echo replies into the victim's link", reflected_c, f"{len(reflected_c)} echo replies")
            outsider.succeed(f"ip addr del {forged} dev lo")
            verdict("F25 a member does not answer a forged fabric source that arrives on its underlay", not reflected and after >= before + 3, f"{len(reflected)} replies reflected, hub dropped {after - before}")

        with subtest("stability: reloading the guard resets no session"):
            before = uptimes(hub)
            hub.succeed("systemctl reload nftables")
            hub.succeed("sleep 5")
            after = uptimes(hub)
            verdict("F27 reloading nftables keeps every BGP session", not restarted(before, after) and established(hub) == 6, f"restarted: {restarted(before, after)}; {len(after)} sessions")
            hub.succeed("systemctl restart nftables")
            hub.succeed("sleep 5")
            again = uptimes(hub)
            print(f"FINDING I15 a restart (not reload) of nftables.service keeps the sessions: {not restarted(before, again)}; frr active: {hub.succeed('systemctl is-active frr').strip()}; guard present: {hub.execute('nft list table inet routed-fabric-fleet >/dev/null')[0] == 0}")

        with subtest("stability: the two directions of a flow through different spines"):
            for machine in [victim, rogue]:
                machine.succeed("nft insert rule inet nixos-fw input-allow tcp dport 5201 accept")
            victim.succeed(
                f"ip route add {stable['rogue']['ipv4']}/32 metric 5 src {stable['victim']['ipv4']} "
                f"nexthop via {hub_on_victim_link4} dev {victim_hub} weight 255 nexthop via {hub2_on_victim_link4} dev {victim_hub2} weight 1"
            )
            rogue.succeed(
                f"ip route add {stable['victim']['ipv4']}/32 metric 5 src {stable['rogue']['ipv4']} "
                f"nexthop via {hub_on_rogue_link4} dev {rogue_hub} weight 1 nexthop via {hub2_on_rogue_link4} dev {rogue_hub2} weight 255"
            )
            rogue.succeed("systemd-run --unit=iperf-s01 $(command -v iperf3) -s -1")
            rogue.wait_until_succeeds("ss -tln | grep ':5201 ' >/dev/null", timeout=20)
            capture(hub, "cap-s01-hub-fwd", hub_victim, "in", "tcp port 5201")
            capture(hub, "cap-s01-hub-rev", hub_victim, "out", "tcp port 5201")
            capture(hub2, "cap-s01-hub2-fwd", hub2_victim, "in", "tcp port 5201")
            capture(hub2, "cap-s01-hub2-rev", hub2_victim, "out", "tcp port 5201")
            code, out = victim.execute(f"iperf3 -c {stable['rogue']['ipv4']} -t 5 2>&1")
            counts = {
                "hub victim->rogue": len(captured(hub, "cap-s01-hub-fwd")),
                "hub rogue->victim": len(captured(hub, "cap-s01-hub-rev")),
                "hub2 victim->rogue": len(captured(hub2, "cap-s01-hub2-fwd")),
                "hub2 rogue->victim": len(captured(hub2, "cap-s01-hub2-rev")),
            }
            asymmetric = counts["hub victim->rogue"] > 0 and counts["hub rogue->victim"] == 0 and counts["hub2 rogue->victim"] > 0 and counts["hub2 victim->rogue"] == 0
            print(f"FINDING S01 packets per spine and direction: {counts}; asymmetric: {asymmetric}")
            control("S01 the two directions of the stream use different spines", asymmetric, f"{counts}")
            victim.succeed(f"ip route del {stable['rogue']['ipv4']}/32 metric 5")
            rogue.succeed(f"ip route del {stable['victim']['ipv4']}/32 metric 5")
            verdict("S01 a TCP stream whose directions use different spines completes", code == 0 and asymmetric, f"iperf rc={code}; {counts}; {out.strip().splitlines()[-3:] if code else None}")

        with subtest("stability: a path-MTU error from the spine arrives inside the contract"):
            for spine, link in [(hub, hub_rogue), (hub2, hub2_rogue)]:
                spine.succeed(f"ip link set {link} mtu 1300")
            victim.succeed("ip route flush cache; ip -6 route flush cache")
            capture(victim, "cap-s03", "any", "in", "(icmp and icmp[0] == 3) or (icmp6 and ip6[40] == 2)")
            code4, out4 = victim.execute(f"ping -M do -c 2 -W 2 -s 1340 {stable['rogue']['ipv4']} 2>&1")
            code6, out6 = victim.execute(f"ping -6 -M do -c 2 -W 2 -s 1320 {stable['rogue']['ipv6']} 2>&1")
            errors = captured(victim, "cap-s03")
            print(f"FINDING A7 path-MTU errors seen on victim: {errors[:4]}")
            control("S03 the packets are too big for the spine's link to the rogue", code4 != 0 and code6 != 0, f"ping rc IPv4={code4} IPv6={code6}")
            for spine, link in [(hub, hub_rogue), (hub2, hub2_rogue)]:
                spine.succeed(f"ip link set {link} mtu 1404")
            verdict("S03 'fragmentation needed' from the spine reaches the sender (IPv4)", "mtu" in out4.lower() and any("unreachable" in e or "need to frag" in e for e in errors), out4.strip().splitlines()[1] if len(out4.strip().splitlines()) > 1 else out4)
            verdict("S03 'packet too big' from the spine reaches the sender (IPv6)", "mtu" in out6.lower() or "too big" in out6.lower(), out6.strip().splitlines()[1] if len(out6.strip().splitlines()) > 1 else out6)
            victim.succeed("ip route flush cache; ip -6 route flush cache")

        with subtest("fail closed: FRR does not start without the guard table"):
            boot = {
                m.name: m.succeed("systemctl show -p ActiveEnterTimestampMonotonic --value nftables.service").strip()
                + " " + m.succeed("systemctl show -p ExecMainStartTimestampMonotonic --value frr.service").strip()
                for m in fabric
            }
            print(f"FINDING A4 boot order, monotonic microseconds: nftables active, frr started: {boot}")
            victim.wait_until_succeeds("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^4$' >/dev/null", timeout=120)
            state = victim.execute("systemctl is-active frr")[1].strip()
            control("F26 FRR runs with its four sessions before the guard table is deleted", state == "active", f"frr is {state}")
            routes_before = int(victim.succeed("ip route show proto bgp | wc -l").strip())
            victim.succeed("nft delete table inet routed-fabric-fleet")
            victim.succeed("systemctl restart --no-block frr")
            victim.succeed("sleep 15")
            state = victim.execute("systemctl is-active frr")[1].strip()
            daemons = victim.succeed("pgrep -c -x 'bgpd|zebra|bfdd' || true").strip()
            routes_after = int(victim.succeed("ip route show proto bgp | wc -l").strip())
            print(f"FINDING I14 frr 15 s after a restart without the guard table: {state}, {daemons} routing daemons; kernel BGP routes before {routes_before}, after {routes_after} (zebra -r keeps them)")
            hub.wait_until_succeeds("vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^4$' >/dev/null", timeout=120)
            verdict("F26 FRR does not run while the guard table is missing", state != "active" and daemons == "0", f"frr is {state}, {daemons} daemons")
            # the guard comes back: FRR starts by itself, nobody resets a start limit
            victim.succeed("systemctl reload nftables")
            victim.succeed("nft list table inet routed-fabric-fleet >/dev/null")
            recovered = seconds_until(victim, "systemctl is-active frr | grep '^active$'", limit=120)
            victim.wait_until_succeeds(
                "vtysh -c 'show bgp neighbors' | grep -c 'BGP state = Established' | grep '^4$' >/dev/null",
                timeout=180,
            )
            victim.wait_until_succeeds(f"ping -c 2 -W 2 {stable['rogue']['ipv4']}", timeout=60)
            verdict("F26b with the guard back FRR starts by itself and the fabric recovers", recovered is not None, f"active {recovered} s after the guard loaded")

        with subtest("stability: a spine dies during a TCP stream"):
            rogue.succeed("systemd-run --unit=iperf-s02 $(command -v iperf3) -s -1")
            rogue.wait_until_succeeds("ss -tln | grep ':5201 ' >/dev/null", timeout=20)
            victim.succeed(f"systemd-run --unit=iperf-s02c --property=StandardOutput=file:/tmp/s02.json $(command -v iperf3) -c {stable['rogue']['ipv4']} -t 20 -P 4 -J")
            # ECMP hashes on the two addresses only, so every flow between two
            # members takes one spine: the spine that dies must be the one
            # this stream uses, or the verdict proves nothing
            path = victim.succeed(f"ip route get {stable['rogue']['ipv4']} from {stable['victim']['ipv4']}")
            dying = hub if victim_hub in path else hub2
            capture(dying, "cap-s02", "any", "in", "tcp port 5201")
            victim.succeed("sleep 5")
            on_hub = len(captured(dying, "cap-s02"))
            control("S02 the spine that dies carries the stream", on_hub > 0, f"the stream leaves the victim through {dying.name}; {on_hub} of its packets were seen there before it dies")
            dying.crash()
            victim.wait_until_fails("systemctl is-active iperf-s02c >/dev/null", timeout=90)
            result = json.loads(victim.succeed("cat /tmp/s02.json"))
            stalled = [round(i["sum"]["start"]) for i in result.get("intervals", []) if i["sum"]["bytes"] == 0]
            tail = [i["sum"]["bytes"] for i in result.get("intervals", [])[-3:]]
            print(f"FINDING S02 seconds with no bytes after the spine died: {stalled}; last intervals: {tail}; error: {result.get('error')}")
            verdict("S02 a TCP stream survives the loss of one spine", on_hub > 0 and "error" not in result and all(tail) and len(stalled) <= 5, f"{on_hub} packets of the stream crossed {dying.name} before it died; stalled seconds {stalled}")

        print("HOSTILE SUMMARY")
        for key, safe, detail in RESULTS:
            print(f"  {'SAFE' if safe else 'GAP '} {key}" + (f" [{detail}]" if not safe else ""))
        for key, worked, detail in CONTROLS:
            print(f"  {'CONTROL OK  ' if worked else 'CONTROL FAIL'} {key}" + (f" [{detail}]" if not worked else ""))
        gaps = [key for key, safe, _ in RESULTS if not safe]
        failed = [key for key, worked, _ in CONTROLS if not worked]
        assert not gaps, f"{len(gaps)} gap(s): {gaps}"
        assert not failed, f"{len(failed)} positive control(s) did not work, so their verdicts prove nothing: {failed}"
        print("HOSTILE_FABRIC_OK")
    except Exception:
        for machine in fabric:
            machine.execute("nft list ruleset >&2; ip route >&2; wg show >&2; vtysh -c 'show bgp summary' >&2")
        raise
  '';
}
