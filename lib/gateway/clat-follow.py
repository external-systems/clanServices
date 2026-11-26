# The CLAT follower (specs/gateway.md G23, G24, §14.5 point 4).
#
# A CLAT has one pool6, so it follows one gateway. Every round the
# follower reads the CLAT's live pool6 from Jool (its only state) and
# asks the gateways' beacons for `ipv4only.arpa` (RFC 7050). An answer
# is proof only when it names that gateway's own /96 (the inventory's):
# a forged or wrong answer never moves the CLAT to an unknown prefix.
#
# The rule (§14.5 point 4, amended in round G11):
#   - while a beacon names the CLAT's /96 it does nothing;
#   - the clock starts at the first round in which none names it, and
#     only a round in which one names it again stops it. A round in
#     which no beacon answers at all is silence too: it does not reset
#     the clock (the first rule did, so one lost answer from the other
#     gateway restarted the wait);
#   - after `missing` seconds it moves to a beacon that named its own
#     /96 in NEEDED of the last WINDOW rounds (a lossy path to a live
#     gateway still counts), the one with the most answers;
#   - it never moves back on its own, and there is no hold after a move
#     (the gateways' own hysteresis keeps a flapping gateway from
#     attracting clients).
#
# The decision is `Follower.step`, which does no I/O of its own; the
# rule is proven by lib/gateway/tests/clat-follow-sim.py.
#
# `clat-follow prefix ADDRESS` prints the /96 an answer names, or fails.
import collections
import ipaddress
import json
import re
import subprocess
import sys
import time

WELL_KNOWN = {ipaddress.IPv4Address("192.0.0.170"), ipaddress.IPv4Address("192.0.0.171")}
# §14.5 point 4: a candidate named its /96 in NEEDED of the last WINDOW rounds
WINDOW = 10
NEEDED = 5


def prefix_of_answer(text):
    """The /96 that one AAAA answer for ipv4only.arpa names (RFC 7050).
    Raises ValueError for anything else."""
    address = ipaddress.IPv6Address(text.strip())
    if ipaddress.IPv4Address(int(address) & 0xFFFFFFFF) not in WELL_KNOWN:
        raise ValueError(f"{text}: does not end in a well-known IPv4 address")
    prefix = ipaddress.IPv6Network((int(address) >> 32 << 32, 96))
    first = prefix.network_address
    if first.is_unspecified or first.is_loopback or first.is_link_local or first.is_multicast:
        raise ValueError(f"{text}: {prefix} is not a prefix to route to")
    return prefix


class Follower:
    """The rule. `step` gets the time, the live pool6 and a function that
    asks one beacon (its own /96 when it names it, else None) and returns
    (beacon, prefix) to move to, or None. The caller reports the outcome
    with `moved` or `failed`."""

    def __init__(self, beacons, missing, log=print):
        self.beacons = dict(beacons)
        self.missing = float(missing)
        self.log = log
        # per beacon: did it name its own /96, over the last silent rounds
        self.heard = {beacon: collections.deque(maxlen=WINDOW) for beacon in self.beacons}
        self.owner = None  # the beacon that named pool6 last
        self.lost = None  # (pool6, when it was first not named)
        self.said = None

    def say(self, state, text):
        if self.said != state:
            self.log(text)
        self.said = state

    def forget(self):
        self.lost = None
        for heard in self.heard.values():
            heard.clear()

    def missing_instance(self):
        self.forget()
        self.say("missing", "clat-follow: no CLAT instance, waiting")

    def step(self, now, pool6, ask):
        # the beacon that named pool6 last time is asked first
        answers = {}
        for beacon in sorted(self.beacons, key=lambda item: item != self.owner):
            answers[beacon] = ask(beacon)
            if answers[beacon] is not None and answers[beacon] == pool6:
                if self.said != "healthy" or beacon != self.owner:
                    self.log(f"clat-follow: pool6 {pool6} is named by {beacon}")
                self.owner, self.said = beacon, "healthy"
                self.forget()
                return None
        # Silence: every beacon was asked and none named pool6. A /96
        # changed under the follower (the CLAT made again) starts a new
        # clock.
        for beacon, heard in self.heard.items():
            heard.append(answers[beacon] is not None)
        if self.lost is None or self.lost[0] != pool6:
            self.lost = (pool6, now)
        gone = now - self.lost[1]
        if all(answer is None for answer in answers.values()):
            self.say("alone", f"clat-follow: no beacon answers ipv4only.arpa, pool6 stays {pool6}")
            return None
        count, server = min((-sum(heard), beacon) for beacon, heard in self.heard.items() if self.beacons[beacon] != pool6)
        count = -count
        self.said = "failing"
        self.log(f"clat-follow: nobody has named pool6 {pool6} for {gone:.0f}/{self.missing:.0f} s, {server} named {self.beacons[server]} in {count} of the last {len(self.heard[server])} rounds")
        if gone >= self.missing and count >= NEEDED:
            return server, self.beacons[server]
        return None

    def moved(self, server, prefix, was):
        self.log(f"clat-follow: pool6 -> {prefix} (beacon {server}, was {was})")
        self.owner = server
        self.forget()

    def failed(self, prefix, error):
        self.log(f"clat-follow: pool6 update to {prefix} failed: {error}")


foreign = set()  # (beacon, prefix) pairs already reported


def prefix_of(beacon, expected):
    """The /96 that a beacon names when it is `expected`, its gateway's
    own; else None: no answer, an answer that is not an address, answers
    that disagree, or a prefix that is not the gateway's."""
    query = ["dig", "+short", "+time=1", "+tries=1", "AAAA", "ipv4only.arpa", "@" + beacon]
    try:
        lines = subprocess.run(query, capture_output=True, text=True, timeout=5).stdout.splitlines()
        found = {prefix_of_answer(line) for line in lines}
    except (ValueError, subprocess.TimeoutExpired):
        return None
    if len(found) != 1:
        return None
    named = found.pop()
    if named != expected:
        if (beacon, named) not in foreign:
            foreign.add((beacon, named))
            print(f"clat-follow: {beacon} names {named}, not its gateway's {expected}: ignored")
        return None
    return named


def live_pool6(jool):
    """(instance exists, its pool6 or None): Jool is the truth. A call
    that hangs counts as no instance this round."""
    try:
        shown = subprocess.run([*jool, "display"], capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        return False, None
    if shown.returncode != 0:
        return False, None
    found = re.search(r"^\s*pool6:\s*(\S+)", shown.stdout, re.MULTILINE)
    try:
        return True, ipaddress.IPv6Network(found.group(1))
    except (AttributeError, ValueError):
        return True, None


def pace(started, period):
    time.sleep(max(0.0, started + period - time.monotonic()))


def follow(config):
    beacons = {entry["address"]: ipaddress.IPv6Network(entry["pool6"]) for entry in config["beacons"]}
    follower = Follower(beacons, config["missing"])
    jool = ["ip", "netns", "exec", config["netns"], "jool_siit", "-i", config["instance"], "global"]
    while True:
        started = time.monotonic()
        exists, pool6 = live_pool6(jool)
        if not exists:
            follower.missing_instance()
            pace(started, 1)
            continue
        move = follower.step(started, pool6, lambda beacon: prefix_of(beacon, beacons[beacon]))
        if move is not None:
            server, prefix = move
            try:
                update = subprocess.run([*jool, "update", "pool6", str(prefix)], capture_output=True, text=True, timeout=10)
                error = update.stderr.strip() if update.returncode != 0 else None
            except subprocess.TimeoutExpired:
                error = "timed out"
            if error is None:
                follower.moved(server, prefix, pool6)
            else:
                follower.failed(prefix, error)
        pace(started, 2 if follower.said == "healthy" else 1.5)


if __name__ == "__main__":
    if sys.argv[1:2] == ["prefix"]:
        try:
            print(prefix_of_answer(sys.argv[2]))
        except ValueError as error:
            sys.exit(str(error))
    else:
        with open(sys.argv[1]) as file:
            follow(json.load(file))
