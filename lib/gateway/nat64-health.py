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
# runs.
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


def embed(ipv4):
    return ipaddress.IPv6Address(int(POOL.network_address) | int(ipv4))


# RFC 7050: ipv4only.arpa names the /96 with these two addresses
RECORDS = "".join(f"{embed(ipaddress.IPv4Address(known))} ipv4only.arpa\n" for known in ["192.0.0.170", "192.0.0.171"])


def answering(targets):
    """The targets that answer one ping, asked at once: a round lasts
    about a second, however many targets there are."""
    pings = {
        target: subprocess.Popen(["ping", "-c1", "-W1", str(embed(target))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for target in targets
    }
    return [str(target) for target, ping in pings.items() if ping.wait() == 0]


def write(content):
    with open(HOSTS + ".new", "w") as file:
        file.write(content)
    os.replace(HOSTS + ".new", HOSTS)


def beacon(action):
    return subprocess.run(["systemctl", action, BEACON], capture_output=True).returncode == 0


def save(state, since, alive, good, bad):
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
    if state == "up":
        write(RECORDS)
        beacon("start")
        print(f"nat64-health: resumed up (since {time.ctime(since)}), beacon up")
    else:
        write("")
    while True:
        started = time.monotonic()
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
            print(f"nat64-health: {UP - last.count(False)} of the last {UP} rounds good ({len(alive)}/{len(TARGETS)} targets answer: {', '.join(alive)}), beacon up")
        elif state == "up" and not beacon("is-active"):
            write(RECORDS)
            beacon("start")
            print("nat64-health: the beacon was not running, started")
        save(state, since, alive, list(rounds)[-UP:].count(True), bad)
        time.sleep(max(0.0, started + 1 - time.monotonic()))


main()
