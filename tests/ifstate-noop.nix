# The shared "changes nothing" helper (specs/netif.md §7, invariant 5).
# A Python snippet for a VM test script: interpolate it once at the top,
# then call `assert_ifstate_noop(machine)`.
#
# It asserts both halves of the definition:
# 1. `ifstatecli check` proposes no change. Its exit status is not a
#    signal, so the output is parsed (format pinned against IfState 2.5.1:
#    an indented `<object>  <operation>` line per object, where `ok`,
#    `= <value>` and `orphan` mean "unchanged");
# 2. the kernel state is the same before and after a real reapply:
#    links, addresses, routes in every table, rules and named network
#    namespaces, with counters, lifetimes and timers stripped.
''
  import json as _noop_json
  import re as _noop_re


  _NOOP_VOLATILE = {
      "valid_life_time",
      "preferred_life_time",
      "expires",
      "stats",
      "stats64",
      "cache",
      "used",
      "age",
  }


  def _noop_strip(value):
      if isinstance(value, dict):
          return {
              key: _noop_strip(item)
              for key, item in sorted(value.items())
              if key not in _NOOP_VOLATILE and not key.endswith("_timer")
          }
      if isinstance(value, list):
          return [_noop_strip(item) for item in value]
      return value


  def ifstate_snapshot(machine):
      """Kernel network state that an IfState reapply must not change."""
      snapshot = {}
      for name, command in [
          ("links", "ip -j -d link show"),
          ("addresses", "ip -j addr show"),
          ("routes4", "ip -j -4 route show table all"),
          ("routes6", "ip -j -6 route show table all"),
          ("rules4", "ip -j -4 rule show"),
          ("rules6", "ip -j -6 rule show"),
      ]:
          snapshot[name] = _noop_strip(_noop_json.loads(machine.succeed(command) or "[]"))
      snapshot["netns"] = sorted(machine.succeed("ip netns list").split("\n"))
      return snapshot


  def ifstate_proposed_changes(machine):
      """The object lines of `ifstatecli check` that are not 'unchanged'."""
      output = machine.succeed("ifstatecli --config /etc/ifstate/ifstate.yaml check 2>&1")
      changes = []
      for line in output.split("\n"):
          match = _noop_re.match(r"^\s{2,}(\S.*?)\s{2,}(\S.*)$", line)
          if match is None:
              continue
          operation = match.group(2).strip()
          if operation in ("ok", "orphan") or operation.startswith("= "):
              continue
          changes.append(line.strip())
      return changes


  def assert_ifstate_noop(machine):
      # Duplicate address detection is the kernel's work in progress, not
      # a change: wait for it, so "tentative" is in neither snapshot.
      machine.wait_until_succeeds('test -z "$(ip -6 addr show tentative)"', timeout=30)
      proposed = ifstate_proposed_changes(machine)
      assert proposed == [], f"{machine.name}: ifstatecli check proposes changes: {proposed}"
      before = ifstate_snapshot(machine)
      machine.succeed("systemctl restart ifstate.service")
      machine.wait_until_succeeds('test -z "$(ip -6 addr show tentative)"', timeout=30)
      after = ifstate_snapshot(machine)
      for section, state in before.items():
          if state != after[section]:
              old = {_noop_json.dumps(item, sort_keys=True) for item in state}
              new = {_noop_json.dumps(item, sort_keys=True) for item in after[section]}
              raise AssertionError(
                  f"{machine.name}: an IfState reapply changed {section}: "
                  f"removed {sorted(old - new)} added {sorted(new - old)}"
              )
''
