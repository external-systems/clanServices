# The NAT64 gateway's health check (specs/gateway.md G23, G24, §14.5
# point 4: stability over fast failover).
#
# Every second it pings each target through the gateway's own translator
# (the target's IPv4 address inside pool6). A round is good when `quorum`
# targets answer. Hysteresis on both sides, over windows of rounds, so a
# lossy gateway cannot hide behind a lucky round:
#   - down: half of the last 2 x `down` rounds are bad. A dead upstream
#     is withdrawn after `down` rounds, a lossy one soon after. The
#     beacon is withdrawn (hosts file emptied, unit stopped), so a
#     client's query is refused at once;
#   - up: the last `up` rounds hold at most 5 % bad ones. A clean
#     recovery comes back after `up` rounds; one lucky ping never does.
# The state is written to a file (state, since, the last round): a
# restart of this unit alone (a deploy) resumes a state younger than
# `resume` seconds, and a later exporter reads it (G18, planned). A
# reboot starts from cold. While up, every round checks that the beacon
# runs; a beacon that does not stay up is started again at most every
# BEACON_RETRY seconds and logged once a minute (round G11).
#
# pool4 (specs/gateway.md §17, G4): every POOL_EVERY rounds the check
# reads how many of pool4's ports Jool holds per protocol (its BIB
# entries) and its session count, writes them to the state file and logs
# a change of band (50, 80, 95 % of a protocol's ports). A full pool4
# never withdraws the beacon: that would move every client to the
# other gateway and fill that one.
import collections
import ipaddress
import json
import os
import subprocess
import sys
import time

config = json.load(open(sys.argv[1]))
POOL = ipaddress.IPv6Network(config["pool6"])
TARGETS = [ipaddress.IPv4Address(target) for target in config["targets"]]
QUORUM = min(int(config["quorum"]), len(TARGETS))
DOWN = int(config["down"])
UP = int(config["up"])
RESUME = float(config["resume"])
HOSTS = config["hosts"]
STATE = config["state"]
BEACON = config["beacon"]
JOOL = ["ip", "netns", "exec", config["netns"], "jool", "-i", "default"]
POOL_EVERY = 10
BANDS = [50, 80, 95]
BEACON_RETRY = 10


def embed(ipv4):
    return ipaddress.IPv6Address(int(POOL.network_address) | int(ipv4))


# RFC 7050: ipv4only.arpa names the /96 with these two addresses
RECORDS = "".join(f"{embed(ipaddress.IPv4Address(known))} ipv4only.arpa\n" for known in ["192.0.0.170", "192.0.0.171"])


def answering(targets):
    """The targets that answer one ping, asked at once: a round lasts
    about a second, however many targets there are. A ping that hangs
    is killed and counts as no answer."""
    pings = {
        target: subprocess.Popen(["ping", "-c1", "-W1", str(embed(target))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for target in targets
    }
    alive = []
    for target, ping in pings.items():
        try:
            if ping.wait(timeout=3) == 0:
                alive.append(str(target))
        except subprocess.TimeoutExpired:
            ping.kill()
            ping.wait()
    return alive


def lines(command):
    """The non-empty lines a command prints, or None when it fails or hangs."""
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=5)
    except subprocess.TimeoutExpired:
        return None
    if done.returncode != 0:
        return None
    return [line for line in done.stdout.splitlines() if line.strip()]


def pool4():
    """Per protocol: pool4's ports and the ones Jool holds (BIB entries);
    and the sessions. None when Jool does not answer."""
    usage = {}
    for proto in ["tcp", "udp", "icmp"]:
        ranges = lines([*JOOL, "pool4", "display", f"--{proto}", "--csv", "--no-headers"])
        held = lines([*JOOL, "bib", "display", f"--{proto}", "--numeric", "--csv", "--no-headers"])
        if ranges is None or held is None:
            return None
        ports = 0
        # Jool 4.1: Mark,Protocol,Address,Min port,Max port,Iterations,Iterations fixed
        for entry in ranges:
            fields = entry.split(",")
            try:
                ports += int(fields[4]) - int(fields[3]) + 1
            except (ValueError, IndexError):
                continue
        usage[proto] = {"ports": ports, "used": len(held), "percent": round(100 * len(held) / ports, 1) if ports else None}
    stats = lines([*JOOL, "stats", "display", "--all", "--csv", "--no-headers"]) or []
    for entry in stats:
        name, _, value = entry.partition(",")
        if name == "JSTAT_SESSIONS":
            usage["sessions"] = int(value) if value.strip().isdigit() else None
    return usage


def band(usage):
    """The highest band a protocol's use of pool4 has reached, 0 for none."""
    worst = max((entry["percent"] or 0 for key, entry in usage.items() if key != "sessions"), default=0)
    return max((limit for limit in BANDS if worst >= limit), default=0)


def write(content):
    with open(HOSTS + ".new", "w") as file:
        file.write(content)
    os.replace(HOSTS + ".new", HOSTS)


def beacon(action):
    try:
        return subprocess.run(["systemctl", action, BEACON], capture_output=True, timeout=10).returncode == 0
    except subprocess.TimeoutExpired:
        return False


def save(state, since, alive, good, bad, usage, beacon_starts):
    """The state for a restart and for an exporter, replaced whole.
    good: good rounds of the last `up`; bad: bad rounds of the last 2 x `down`."""
    record = {
        "state": state,
        "since": since,
        "written": time.time(),
        "answered": alive,
        "targets": [str(target) for target in TARGETS],
        "good_of_last_up": good,
        "bad_of_last_2down": bad,
        # pool4 and sessions (G4), read every POOL_EVERY rounds
        "pool4": usage,
        # starts of a beacon that did not stay up, since the last up
        "beacon_restarts": beacon_starts,
    }
    with open(STATE + ".new", "w") as file:
        json.dump(record, file)
    os.replace(STATE + ".new", STATE)


def resumed():
    """'up' when the last run left 'up' less than RESUME seconds ago."""
    try:
        with open(STATE) as file:
            record = json.load(file)
        if record["state"] == "up" and time.time() - float(record["written"]) < RESUME:
            return "up", float(record["since"])
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return "unknown", time.time()


def main():
    state, since = resumed()
    rounds = collections.deque(maxlen=max(2 * DOWN, UP))  # True: a good round
    usage, shown, count = None, None, 0
    restarts, tried, told = 0, 0.0, 0.0
    if state == "up":
        write(RECORDS)
        beacon("start")
        print(f"nat64-health: resumed up (since {time.ctime(since)}), beacon up")
    else:
        write("")
    while True:
        started = time.monotonic()
        if count % POOL_EVERY == 0:
            read = pool4()
            if read is not None:
                usage = read
                now = band(usage)
                if now != shown:
                    summary = ", ".join(f"{proto} {entry['used']}/{entry['ports']}" for proto, entry in usage.items() if proto != "sessions")
                    level = f"{now} % or more of a protocol's ports held" if now else f"below {BANDS[0]} % of every protocol's ports"
                    print(f"nat64-health: pool4 {level} ({summary}; {usage.get('sessions')} sessions); the beacon stays")
                    shown = now
        count += 1
        alive = answering(TARGETS)
        rounds.append(len(alive) >= QUORUM)
        recent = list(rounds)[-2 * DOWN:]
        bad = recent.count(False)
        last = list(rounds)[-UP:]
        healthy = len(last) == UP and last.count(False) <= UP // 20
        if state != "down" and bad >= DOWN:
            write("")
            beacon("stop")
            state, since = "down", time.time()
            rounds.clear()
            print(f"nat64-health: {bad} of the last {len(recent)} rounds bad (fewer than {QUORUM} of {len(TARGETS)} targets answer), beacon withdrawn")
        elif state != "up" and healthy:
            write(RECORDS)
            beacon("start")
            state, since = "up", time.time()
            restarts, told = 0, 0.0
            print(f"nat64-health: {UP - last.count(False)} of the last {UP} rounds good ({len(alive)}/{len(TARGETS)} targets answer: {', '.join(alive)}), beacon up")
        elif state == "up" and time.monotonic() - tried >= BEACON_RETRY and not beacon("is-active"):
            # G14: a beacon that cannot bind dies at once; it is started
            # again every BEACON_RETRY s and logged once a minute
            write(RECORDS)
            beacon("start")
            restarts, tried = restarts + 1, time.monotonic()
            if time.monotonic() - told >= 60:
                print(f"nat64-health: the beacon was not running, started ({restarts} starts since it was last up)")
                told = time.monotonic()
        save(state, since, alive, list(rounds)[-UP:].count(True), bad, usage, restarts)
        time.sleep(max(0.0, started + 1 - time.monotonic()))


main()
