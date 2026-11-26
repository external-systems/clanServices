# The router's prefix hook (specs/gateway.md G20, G22). netif writes the
# delegated prefixes to /run/netif/pd/<wan> (netif N16); a path unit runs
# this on a change. Ported from the fixture of gateway-router.
#   - The file is a set. The current prefix stays current while it is
#     listed; otherwise the first listed one is. A prefix that was
#     current and is no longer listed is retired: advertised as
#     deprecated for 2 h. No file: no delegation, so the current prefix
#     is retired and the service rule goes. But not on the first run
#     after a boot: dhcpcd has not answered yet, so the prefix on disk
#     stays current for 45 s and the hook then looks again (§16.3).
#   - Its own nftables tables hold the service rewrite (G20) and the set
#     of delegated prefixes: IPv6 from a LAN zone to the WAN with another
#     source is rejected on the LAN links' ingress (`netdev router_src`),
#     so the error leaves by the link the packet came from.
#   - It converges on what is loaded, not on a file diff: each table
#     carries its generation, corerad's is recorded after the restart was
#     queued. A run that failed half way is repaired by the next.
#   - Each table loads in a transaction of its own (round G11): a LAN
#     link that is not there yet fails `router_src` (its netdev chain
#     names the links), not the service rewrite. The run then fails and
#     systemd runs it again (`Restart=on-failure`).
#   - The WAN never brings a source inside a delegated prefix
#     (`router_svc`, chain `wan`).
#   - systemd drops a path event that fires while the hook runs, so the
#     hook reads the file again before it exits and repeats until it has
#     handled what is there.
# A subnet id that does not fit the delegation gets nothing.
import hashlib
import ipaddress
import json
import os
import subprocess
import sys
import time

CONFIG = json.load(open(sys.argv[1]))
PD = CONFIG["pd"]
STATE = "/var/lib/router/prefix.json"
CONF = "/run/router/corerad.toml"
APPLIED = "/run/router/corerad.applied"
ZONES = {link: (zone["subnet"], zone["dns"]) for link, zone in CONFIG["zones"].items()}
SERVICE_SUBNET = CONFIG["service"]["subnet"]
STABLE = CONFIG["service"]["stable"]
LANS = CONFIG["lans"]
WAN = CONFIG["wan"]
DOMAIN = CONFIG["domain"]
PREF64 = CONFIG["pref64"]
TABLES = ["inet router_svc", "netdev router_src"]
RETIRED_FOR = 7200
# The first run after a boot (/run is new): netif's file is not there
# yet, because dhcpcd has not had its first reply. That is not a lost
# delegation. The prefix on disk stays current for GRACE seconds, then
# the hook runs once more and believes what it finds.
BOOT = "/run/router/first-run-done"
GRACE = 45


def subnet(prefix, number):
    """The /64 with that subnet id, or None: the delegation has no room for it."""
    network = ipaddress.ip_network(prefix)
    if network.prefixlen > 64 or number >= 2 ** (64 - network.prefixlen):
        return None
    return str(ipaddress.ip_network((int(network.network_address) + (number << 64), 64)))


def read(path):
    try:
        with open(path) as handle:
            return handle.read()
    except OSError:
        return None


def write(path, text):
    """Replace the file: whole and on disk, or not at all."""
    with open(path + ".tmp", "w") as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    os.rename(path + ".tmp", path)
    directory = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def load_state():
    """The state on disk. A lost, empty or damaged file is no state."""
    text = read(STATE)
    try:
        state = json.loads(text or "")
        current, retired = state["current"], state["retired"]
        if current is not None:
            current = str(ipaddress.IPv6Network(str(current) if isinstance(current, str) else ""))
        retired = {str(ipaddress.IPv6Network(prefix if isinstance(prefix, str) else "")): float(since) for prefix, since in retired.items()}
        return {"current": current, "retired": retired}
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        if text is not None:
            print(f"router-prefix: the state file is unusable ({type(error).__name__}), starting without")
        return {"current": None, "retired": {}}


def delegated(text):
    """The prefixes in netif's file, in its order; anything else is skipped."""
    found = []
    for word in (text or "").split():
        try:
            prefix = str(ipaddress.IPv6Network(word))
        except ValueError:
            continue
        if prefix not in found:
            found.append(prefix)
    return found


def corerad(state):
    out = ["[debug]", 'address = "[::1]:9430"', "prometheus = true", ""]
    for name, (number, dns) in ZONES.items():
        out += [
            "[[interfaces]]", f'name = "{name}"', "advertise = true",
            "  [[interfaces.prefix]]", '  prefix = "::/64"',
            '  preferred_lifetime = "45m"', '  valid_lifetime = "90m"',
        ]
        for old in [subnet(prefix, number) for prefix in sorted(state["retired"])]:
            if old:
                out += [
                    "  [[interfaces.prefix]]", f'  prefix = "{old}"',
                    "  deprecated = true", '  preferred_lifetime = "1s"', '  valid_lifetime = "2h"',
                ]
        if dns:
            out += ["  [[interfaces.rdnss]]", f'  servers = ["{dns}"]']
        if DOMAIN:
            out += ["  [[interfaces.dnssl]]", f'  domain_names = ["{DOMAIN}"]']
        if PREF64:
            out += ["  [[interfaces.pref64]]", f'  prefix = "{PREF64}"']
        out += [""]
    return "\n".join(out)


def handle(text):
    prefixes = delegated(text)
    state = load_state()
    now = time.time()
    first = not os.path.exists(BOOT)
    if first:
        write(BOOT, "")
    if first and not prefixes and state["current"]:
        waiting = subprocess.run(
            ["systemd-run", "--quiet", "--collect", f"--on-active={GRACE}", "--unit=router-prefix-recheck",
             "systemctl", "start", "--no-block", "router-prefix.service"],
            capture_output=True, text=True,
        )
        if waiting.returncode == 0:
            prefixes = [state["current"]]
            print(f"router-prefix: no delegation yet after the boot; {state['current']} stays current for {GRACE} s", flush=True)
        else:
            print(f"router-prefix: could not schedule the recheck ({waiting.stderr.strip()}); no delegation means none", flush=True)
    current = state["current"] if state["current"] in prefixes else (prefixes[0] if prefixes else None)
    if state["current"] and state["current"] != current:
        state["retired"][state["current"]] = now
    state["current"] = current
    state["retired"] = {prefix: since for prefix, since in state["retired"].items() if prefix not in prefixes and now - since < RETIRED_FOR}
    # the intent first: a run that dies below is finished by the next
    wanted = json.dumps(state, sort_keys=True)
    if read(STATE) != wanted:
        write(STATE, wanted)

    conf = corerad(state)
    if read(CONF) != conf:
        write(CONF, conf)

    public = subnet(current, SERVICE_SUBNET) if current and SERVICE_SUBNET is not None else None
    rule = f"dnat ip6 prefix to ip6 daddr map {{ {public} : {STABLE} }}" if public else ""
    elements = f"elements = {{ {', '.join(prefixes)} }}" if prefixes else ""
    delegated_set = f"  set delegated {{ type ipv6_addr; flags interval; auto-merge; {elements} }}"
    exempt = ", ".join(["::", "fe80::/10"] + ([STABLE] if STABLE else []))
    bodies = {
        "inet router_svc": "\n".join([
            delegated_set,
            "  chain prerouting {",
            "    type nat hook prerouting priority dstnat;",
            f"    {rule}",
            "  }",
            "  chain wan {",
            "    type filter hook prerouting priority raw;",
            f'    iifname {WAN} ip6 saddr @delegated counter drop comment "WAN spoofed source"',
            "  }",
            "  chain egress {",
            "    type filter hook forward priority filter - 10;",
            f'    iifname {LANS} oifname {WAN} meta nfproto ipv6 ct direction original ip6 saddr != @delegated counter reject with icmpv6 policy-fail comment "egress source, forward"',
            "  }",
            # §14.3: a LAN host that calls a public service address gets
            # the reply through the router, also from its own zone or
            # from the backend itself; WAN clients keep their address
            "  chain hairpin {",
            "    type nat hook postrouting priority srcnat;",
            f'    iifname {LANS} meta nfproto ipv6 ct status dnat counter masquerade comment "service hairpin"',
            "  }",
        ]),
        "netdev router_src": "\n".join([
            delegated_set,
            "  chain lan {",
            f"    type filter hook ingress devices = {LANS} priority filter;",
            f'    meta protocol ip6 ip6 saddr != @delegated ip6 saddr != {{ {exempt} }} fib daddr oifname {WAN} counter reject with icmpv6 policy-fail comment "egress source"',
            "  }",
        ]),
    }
    replaced, failed = [], []
    for name in TABLES:
        generation = hashlib.sha256(bodies[name].encode()).hexdigest()[:16]
        loaded = subprocess.run(["nft", "list", "table", *name.split()], capture_output=True, text=True, timeout=30)
        if loaded.returncode == 0 and f'comment "generation {generation}"' in loaded.stdout:
            continue
        # one transaction per table: a table is never half there
        table = f'table {name}\ndelete table {name}\ntable {name} {{\n  comment "generation {generation}"\n{bodies[name]}\n}}\n'
        done = subprocess.run(["nft", "-f", "-"], input=table.encode(), capture_output=True, timeout=30)
        if done.returncode == 0:
            replaced.append(name)
        else:
            failed.append(name)
            print(f"router-prefix: table {name} did not load: {done.stderr.decode().strip()}", flush=True)

    if failed:
        # corerad waits for the run that loads every table, as before
        sys.exit(f"router-prefix: tables {failed} did not load; systemd runs the hook again")

    digest = hashlib.sha256(conf.encode()).hexdigest()
    restarted = read(APPLIED) != digest
    if restarted:
        # --no-block: corerad is ordered after this unit, so waiting for
        # its restart from inside this unit never returns
        subprocess.run(["systemctl", "--no-block", "try-restart", "corerad.service"], check=True, timeout=30)
        write(APPLIED, digest)
    print(f"router-prefix: current {current}, retired {sorted(state['retired'])}, service {public}, corerad {'restarted' if restarted else 'unchanged'}, delegated {prefixes}, table {'replaced' if replaced else 'unchanged'}{' ' + ', '.join(replaced) if replaced else ''}", flush=True)


for _ in range(100):
    seen = read(PD)
    handle(seen)
    if read(PD) == seen:
        sys.exit(0)
sys.exit("router-prefix: the prefix file keeps changing")
