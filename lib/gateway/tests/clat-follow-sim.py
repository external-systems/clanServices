# A simulation of the CLAT follower (specs/gateway.md §14.5 point 4,
# round G11): the real `follow()` loop of clat-follow.py runs against a
# fake clock, fake beacons and a fake Jool. A dig that gets no answer
# costs 1 s (`+time=1`), as on a machine.
#
#   python3 clat-follow-sim.py <clat-follow.py>
#
# Prints one FINDING line per case and fails on the first broken rule.
import ipaddress
import json
import os
import random
import subprocess
import sys
import tempfile
import time

SCRIPT = sys.argv[1]
A, B = "2001:db8:c::1", "2001:db8:c::2"
POOLS = {A: "2001:db8:a1::/96", B: "2001:db8:a2::/96"}
MISSING = 60


class Done(Exception):
    pass


def run(answers, horizon, start=A):
    """Runs the follower until `horizon` s. `answers(t, beacon)` says what
    a beacon does at time t: True (names its own /96), False (silent) or
    a prefix string (names that). Returns the moves: (time, prefix)."""
    clock = {"t": 0.0}
    pool6 = {"live": POOLS[start]}
    moves = []

    def advance(seconds):
        clock["t"] += seconds
        if clock["t"] > horizon:
            raise Done

    def fake_run(command, **_):
        if command[0] == "dig":
            beacon = command[-1][1:]
            said = answers(clock["t"], beacon)
            if said is False:
                advance(1.0)
                return subprocess.CompletedProcess(command, 9, "", "")
            advance(0.01)
            prefix = ipaddress.IPv6Network(POOLS[beacon] if said is True else said)
            lines = "".join(f"{ipaddress.IPv6Address(int(prefix.network_address) | int(ipaddress.IPv4Address(known)))}\n" for known in ["192.0.0.170", "192.0.0.171"])
            return subprocess.CompletedProcess(command, 0, lines, "")
        if command[-1] == "display":
            return subprocess.CompletedProcess(command, 0, f"  pool6: {pool6['live']}\n", "")
        if command[-3:-1] == ["update", "pool6"]:
            moves.append((round(clock["t"], 1), command[-1]))
            pool6["live"] = command[-1]
            return subprocess.CompletedProcess(command, 0, "", "")
        raise AssertionError(f"unexpected command {command}")

    real = subprocess.run, time.monotonic, time.sleep, sys.argv, sys.stdout
    with tempfile.TemporaryDirectory() as scratch:
        config = os.path.join(scratch, "follow.json")
        with open(config, "w") as file:
            json.dump({"beacons": [{"address": b, "pool6": POOLS[b]} for b in (A, B)], "missing": MISSING, "netns": "clat", "instance": "clat"}, file)
        subprocess.run = fake_run
        time.monotonic = lambda: clock["t"]
        time.sleep = advance
        sys.argv = [SCRIPT, config]
        sys.stdout = open(os.devnull, "w")
        try:
            with open(SCRIPT) as file:
                exec(compile(file.read(), SCRIPT, "exec"), {"__name__": "__main__"})
        except Done:
            pass
        finally:
            sys.stdout.close()
            subprocess.run, time.monotonic, time.sleep, sys.argv, sys.stdout = real
    return moves


def check(name, ok, detail):
    print(f"FINDING {name}: {detail}")
    if not ok:
        sys.exit(f"clat-follow-sim: {name} broke the rule: {detail}")


# 1. A healthy gateway: nobody moves in an hour.
moves = run(lambda t, b: True, 3600)
check("healthy", moves == [], moves)

# 2. The round G11 case: A dies at 10 s, 10 % of the rounds towards B
#    are lost. A move within 60 s + a few rounds, in every seeded run.
worst = 0.0
for seed in range(200):
    rng = random.Random(seed)
    moves = run(lambda t, b: t < 10 if b == A else rng.random() >= 0.10, 400)
    if not (len(moves) == 1 and moves[0][1] == POOLS[B] and moves[0][0] <= 10 + MISSING + 15):
        check(f"10 % loss to B, seed {seed}", False, moves)
    worst = max(worst, moves[0][0] - 10)
check("10 % loss to B, 200 runs", worst <= MISSING + 15, f"slowest move {worst:.1f} s after A died")

# 3. A dies; B answers only 4 of every 10 rounds: never enough.
rounds = {"n": 0}


def four_of_ten(t, b):
    if b == A:
        return t < 10
    rounds["n"] += 1
    return rounds["n"] % 10 < 4


moves = run(four_of_ten, 900)
check("B answers 4 of 10", moves == [], moves)

# 4. Both silent from 10 s to 200 s, then B is back, A stays dead. The
#    silent rounds do not reset the clock: the move follows within a few
#    rounds of B's return, not 60 s after it.
moves = run(lambda t, b: t < 10 or (b == B and t >= 200), 400)
check("silence does not reset the clock", len(moves) == 1 and 200 < moves[0][0] <= 215, moves)

# 5. After a move the old gateway comes back: no move back.
moves = run(lambda t, b: (t < 10 or t > 150) if b == A else True, 1200)
check("never back on its own", len(moves) == 1 and moves[0][1] == POOLS[B], moves)

# 6. A is silent for 50 s twice, named in between: the clock starts again.
moves = run(lambda t, b: not (10 <= t < 60 or 70 <= t < 120) if b == A else True, 400)
check("a gap shorter than 60 s", moves == [], moves)

# 7. A dies; B names a foreign /96: no proof, no move.
moves = run(lambda t, b: t < 10 if b == A else "2001:db8:bad::/96", 400)
check("a foreign prefix", moves == [], moves)

print("CLAT_FOLLOW_SIM_OK")
