# The CLAT follower (specs/gateway.md G23, G24, §14.5 point 4).
#
# A CLAT has one pool6, so it follows one gateway. Every round the
# follower reads the CLAT's live pool6 from Jool (its only state) and
# asks the gateways' beacons for `ipv4only.arpa` (RFC 7050). An answer
# is proof only when it names that gateway's own /96 (the inventory's):
# a forged or wrong answer never moves the CLAT to an unknown prefix.
# While a beacon names the CLAT's /96 it does nothing. When none has
# named it for `missing` seconds and another beacon names its own /96,
# it moves there. When no beacon answers there is nowhere to go: it stays, and
# the clock starts again. It never moves back on its own, and there is
# no hold after a move (the gateways' own hysteresis keeps a flapping
# gateway from attracting clients).
#
# `clat-follow prefix ADDRESS` prints the /96 an answer names, or fails.
import ipaddress
import json
import re
import subprocess
import sys
import time

WELL_KNOWN = {ipaddress.IPv4Address("192.0.0.170"), ipaddress.IPv4Address("192.0.0.171")}


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
    """(instance exists, its pool6 or None): Jool is the truth."""
    shown = subprocess.run([*jool, "display"], capture_output=True, text=True)
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
    missing = float(config["missing"])
    jool = ["ip", "netns", "exec", config["netns"], "jool_siit", "-i", config["instance"], "global"]
    lost = None  # when the current /96 was last named, if it is not now
    owner = None
    said = None
    while True:
        started = time.monotonic()
        exists, pool6 = live_pool6(jool)
        if not exists:
            if said != "missing":
                print("clat-follow: no CLAT instance, waiting")
                said = "missing"
            pace(started, 1)
            continue
        # the beacon that named pool6 last time is asked first
        answers = {}
        for beacon in sorted(beacons, key=lambda item: item != owner):
            answers[beacon] = prefix_of(beacon, beacons[beacon])
            if answers[beacon] is not None and answers[beacon] == pool6:
                break
        else:
            beacon = None
        if beacon is not None:
            if said != "healthy" or beacon != owner:
                print(f"clat-follow: pool6 {pool6} is named by {beacon}")
            owner, lost, said = beacon, None, "healthy"
            pace(started, 2)
            continue
        proven = [(server, prefix) for server, prefix in answers.items() if prefix is not None]
        if not proven:
            if said != "alone":
                print(f"clat-follow: no beacon answers ipv4only.arpa, pool6 stays {pool6}")
            lost, said = None, "alone"
            pace(started, 1.5)
            continue
        if lost is None:
            lost = started
        said = "failing"
        server, prefix = proven[0]
        gone = started - lost
        print(f"clat-follow: nobody has named pool6 {pool6} for {gone:.0f}/{missing:.0f} s, {server} names {prefix}")
        if gone >= missing:
            update = subprocess.run([*jool, "update", "pool6", str(prefix)], capture_output=True, text=True)
            if update.returncode == 0:
                print(f"clat-follow: pool6 -> {prefix} (beacon {server}, was {pool6})")
                owner, lost = server, None
            else:
                print(f"clat-follow: pool6 update to {prefix} failed: {update.stderr.strip()}")
        pace(started, 1.5)


if sys.argv[1:2] == ["prefix"]:
    try:
        print(prefix_of_answer(sys.argv[2]))
    except ValueError as error:
        sys.exit(str(error))
else:
    follow(json.load(open(sys.argv[1])))
