# The NAT64 gateway's health check (specs/gateway.md G23, G24, §14.3).
#
# Every round it pings each target through the gateway's own translator
# (the target's IPv4 address inside pool6). A round is healthy when any
# target answers. After `failures` unhealthy rounds in a row the beacon
# is withdrawn: the hosts file is emptied and the beacon unit stopped,
# so a client's query is refused at once. One healthy round restores
# both. The ruleset of systemd is the only record: every round checks
# that the beacon runs while healthy.
import ipaddress
import json
import os
import subprocess
import sys
import time

config = json.load(open(sys.argv[1]))
POOL = ipaddress.IPv6Network(config["pool6"])
TARGETS = [ipaddress.IPv4Address(target) for target in config["targets"]]
FAILURES = int(config["failures"])
HOSTS = config["hosts"]
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


def main():
    write("")
    fails = 0
    state = "unknown"
    while True:
        started = time.monotonic()
        alive = answering(TARGETS)
        if alive:
            fails = 0
            running = beacon("is-active")
            if state != "up" or not running:
                write(RECORDS)
                beacon("start")
                state = "up"
                print(f"nat64-health: {len(alive)}/{len(TARGETS)} targets answer ({', '.join(alive)}), beacon up")
        else:
            fails += 1
            if fails >= FAILURES and state != "down":
                write("")
                beacon("stop")
                state = "down"
                print(f"nat64-health: no target answered for {fails} rounds, beacon withdrawn")
        time.sleep(max(0.0, started + 1 - time.monotonic()))


main()
