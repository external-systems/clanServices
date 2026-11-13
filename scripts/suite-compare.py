"""Compare two suite snapshots (suite-snapshot) and prove a test refactor faithful.

Usage: suite-compare BASE AFTER

Per suite in BASE:
- nodes: every node's system derivation must be equal. Take AFTER with
  `suite-snapshot AFTER --pin BASE` so each suite's clan.directory is the
  baseline copy; otherwise any edit in a test directory changes every node.
- script: the rendered testScript must equal the baseline after removing
  the refactors this repo allows: `with subtest(...)` lines (and the
  4-space indent under them) and `| grep -[flags]q PAT` -> `| grep [-flags] PAT >/dev/null`.
  Any other difference is printed for review.
Exit 1 when a suite differs.
"""

import difflib
import json
import pathlib
import re
import sys

GREP_Q = re.compile(r"""\| grep -(\w*)q(\w*) ('[^']*'|[^\s"]+)""")


def baseline_lines(text):
    def rewrite(m):
        rest = m.group(1) + m.group(2)
        flags = f"-{rest} " if rest else ""
        return f"| grep {flags}{m.group(3)} >/dev/null"

    return [GREP_Q.sub(rewrite, line) for line in text.split("\n")]


def after_lines(text):
    out, stack = [], []
    for line in text.split("\n"):
        indent = len(line) - len(line.lstrip(" "))
        if line.strip():
            while stack and indent <= stack[-1]:
                stack.pop()
        if line.strip().startswith("with subtest("):
            stack.append(indent)
            continue
        if line.strip():
            line = line[4 * len(stack) :]
        out.append(line)
    return out


def significant(diff):
    return [
        d
        for d in diff
        if d[:1] in "+-" and d[:3] not in ("+++", "---") and d[1:].strip()
    ]


def main(base, after):
    base, after = pathlib.Path(base), pathlib.Path(after)
    failed = 0
    for script in sorted(base.glob("*.script.py")):
        suite = script.name.removesuffix(".script.py")
        problems = []
        b_nodes = base / f"{suite}.nodes.json"
        a_nodes = after / f"{suite}.nodes.json"
        if not a_nodes.exists():
            problems.append("missing from AFTER")
        else:
            bn, an = json.loads(b_nodes.read_text()), json.loads(a_nodes.read_text())
            for node in sorted(set(bn) | set(an)):
                if bn.get(node) != an.get(node):
                    problems.append(f"node {node}: {bn.get(node)} -> {an.get(node)}")
            diff = significant(
                difflib.unified_diff(
                    baseline_lines(script.read_text()),
                    after_lines((after / script.name).read_text()),
                    lineterm="",
                    n=0,
                )
            )
            problems += [f"script {d}" for d in diff]
        status = "same" if not problems else f"DIFFERS ({len(problems)})"
        print(f"{suite:36} {status}")
        for p in problems[:40]:
            print(f"    {p}")
        failed += bool(problems)
    print(f"{failed} suite(s) differ" if failed else "every suite is faithful")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
