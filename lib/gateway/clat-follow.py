# The CLAT follower (specs/gateway.md G23, G24).
#
# A CLAT has one pool6, so it follows one gateway. Every round the
# follower reads the CLAT's live pool6 from Jool (its only state) and
# asks the gateways' beacons for `ipv4only.arpa` (RFC 7050). While a
# beacon names that /96 it does nothing. A round fails when nobody names
# it and another beacon names a /96 of its own; after NEED such rounds
# in a row it moves there. When no beacon answers there is nowhere to
# go: it stays, and the count starts again.
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


def prefix_of(beacon):
    """The one /96 that a beacon names, or None: no answer, an answer
    that is not an address, or answers that disagree."""
    query = ["dig", "+short", "+time=1", "+tries=1", "AAAA", "ipv4only.arpa", "@" + beacon]
    try:
        lines = subprocess.run(query, capture_output=True, text=True, timeout=5).stdout.splitlines()
        found = {prefix_of_answer(line) for line in lines}
    except (ValueError, subprocess.TimeoutExpired):
        return None
    return found.pop() if len(found) == 1 else None


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
    beacons = config["beacons"]
    need = int(config["need"])
    jool = ["ip", "netns", "exec", config["netns"], "jool_siit", "-i", config["instance"], "global"]
    fails = 0
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
            answers[beacon] = prefix_of(beacon)
            if answers[beacon] is not None and answers[beacon] == pool6:
                break
        else:
            beacon = None
        if beacon is not None:
            if said != "healthy" or beacon != owner:
                print(f"clat-follow: pool6 {pool6} is named by {beacon}")
            owner, fails, said = beacon, 0, "healthy"
            pace(started, 2)
            continue
        proven = [(server, prefix) for server, prefix in answers.items() if prefix is not None]
        if not proven:
            if said != "alone":
                print(f"clat-follow: no beacon answers ipv4only.arpa, pool6 stays {pool6}")
            fails, said = 0, "alone"
            pace(started, 1.5)
            continue
        said = "failing"
        fails += 1
        server, prefix = proven[0]
        print(f"clat-follow: check {fails}/{need} failed: nobody names pool6 {pool6}, {server} names {prefix}")
        if fails >= need:
            update = subprocess.run([*jool, "update", "pool6", str(prefix)], capture_output=True, text=True)
            if update.returncode == 0:
                print(f"clat-follow: pool6 -> {prefix} (beacon {server}, was {pool6})")
                owner, fails = server, 0
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
