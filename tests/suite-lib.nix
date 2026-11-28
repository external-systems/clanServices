# Shared helpers for VM test scripts (specs/gateway.md §12.4). A Python
# snippet: interpolate it once at the top of a `testScript`.
#
#   observe(label, machine, cmd)      run, print a FINDING block, never fail
#   print_versions(machine, [...])    VERSION lines: ties a regression to a bump
#   seconds_until(machine, cmd, ...)  how long until a command succeeds
#   holds_for(machine, cmd, seconds)  a command keeps succeeding for a stated time
#   state_dump_on_failure([...])      `with` block: dump network state, then re-raise
#   drops(machine, table, comment)    packets counted by the rules of one nft
#                                     table whose comment matches
#
# A suite asserts facts with `assert`, `succeed`, `fail` and the
# `wait_until_*` calls. `observe` is context for the reader of a log.
''
  import contextlib as _suite_contextlib
  import time as _suite_time


  def observe(label, machine, cmd):
      status, out = machine.execute(cmd + " 2>&1")
      print(f"FINDING {label}: rc={status}\n{out.rstrip()}")
      return status, out.strip()


  _SUITE_VERSIONS = {
      "kernel": "uname -r",
      "ifstate": "ifstatecli --version",
      "dhcpcd": "dhcpcd --version | head -n1",
      "jool": "modinfo -F version jool",
      "frr": "vtysh -c 'show version' | head -n1",
      "cilium": "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg version | head -n1",
      "wireguard": "wg --version",
      "nftables": "nft --version",
      "coredns": "coredns -version | head -n1",
      "corerad": "journalctl -b -u corerad --no-pager | grep -o 'CoreRAD v[0-9.]*' | head -n1",
      "kea": "kea-dhcp4 -v",
      "k3s": "k3s --version | head -n1",
      "rke2": "rke2 --version | head -n1",
  }


  def print_versions(machine, names):
      """One VERSION line per component that the machine has."""
      for name in names:
          status, out = machine.execute(f"({_SUITE_VERSIONS[name]}) 2>&1")
          version = out.strip().replace("\n", " ") if status == 0 and out.strip() else "not found"
          print(f"VERSION {machine.name} {name}: {version}")


  def seconds_until(machine, cmd, limit=120, wanted=None, interval=0.5):
      """Seconds until `cmd` succeeds (and prints `wanted`), or None."""
      started = _suite_time.time()
      while _suite_time.time() - started < limit:
          status, out = machine.execute(cmd + " 2>/dev/null")
          if status == 0 and (wanted is None or wanted in out):
              return round(_suite_time.time() - started, 1)
          _suite_time.sleep(interval)
      return None


  def holds_for(machine, cmd, seconds, interval=1.0):
      """`cmd` must succeed on every check during `seconds`: proves that
      something does not happen. Say the time in the subtest name."""
      started = _suite_time.time()
      while _suite_time.time() - started < seconds:
          machine.succeed(cmd)
          _suite_time.sleep(interval)


  def drops(machine, table, comment):
      """Packets counted by every rule of the nft table `table` (for
      example "inet routed-fabric-fleet") whose line has `comment`. Find a
      rule by its comment, never by a set or chain name. Counters reset
      when the table reloads: read before and after an attack with no
      deploy between."""
      rules = machine.succeed(f"nft list table {table}")
      lines = [line for line in rules.splitlines() if comment in line and "counter packets" in line]
      assert lines, f"no rule with comment {comment!r} in {table} on {machine.name}"
      return sum(int(line.split("counter packets ")[1].split()[0]) for line in lines)


  _SUITE_DUMP = [
      "systemctl --failed --no-pager",
      "ip -br link",
      "ip -br addr",
      "ip -4 route show table all",
      "ip -6 route show table all",
      "ip -4 rule; ip -6 rule",
      "ip netns list",
      "nft list ruleset",
      "journalctl -b --no-pager -p warning | tail -n 60",
  ]


  @_suite_contextlib.contextmanager
  def state_dump_on_failure(machines, extra=()):
      try:
          yield
      except Exception:
          for machine in machines:
              for cmd in [*_SUITE_DUMP, *extra]:
                  try:
                      status, out = machine.execute(f"({cmd}) 2>&1", timeout=30)
                      print(f"DUMP {machine.name}: {cmd}: rc={status}\n{out.rstrip()}")
                  except Exception as error:  # a dead VM must not hide the failure
                      print(f"DUMP {machine.name}: {cmd}: {error}")
          raise
''
