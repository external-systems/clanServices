#!/usr/bin/env bash
# suite-snapshot OUT [--pin BASE] [suite...]: per suite, every node's system
# derivation (OUT/<suite>.nodes.json), the rendered testScript
# (<suite>.script.py) and the clan.directory store path (<suite>.dir).
# Default: every suite, 4 evaluations at a time (about 3 GB each).
# --pin BASE evaluates each suite with clan.directory forced to BASE's copy
# (VM_SUITE_DIR, --impure), so node derivations compare across edits.
# Take BASE before you edit; compare with suite-compare.
set -euo pipefail
usage="usage: suite-snapshot OUT [--pin BASE] [suite...]"
case "${1:-}" in
  "" | -*) echo "$usage" >&2; exit 2 ;;
esac
out=$1
shift
pin=""
if [ "${1:-}" = --pin ]; then
  pin=$(realpath "${2:?--pin needs a snapshot dir}")
  shift 2
fi
root=$(git rev-parse --show-toplevel)
cd "$root"
mkdir -p "$out"
out=$(realpath "$out")
suites=("$@")
if [ ${#suites[@]} -eq 0 ]; then
  mapfile -t suites < <(nix run .#vm-test -- --list 2>/dev/null)
fi
system=$(nix eval --raw --impure --expr builtins.currentSystem)
export out pin system
snap() {
  local s=$1 a=".#legacyPackages.$system.vmTests.$1"
  local impure=()
  if [ -n "$pin" ]; then
    VM_SUITE_DIR=$(cat "$pin/$s.dir")
    export VM_SUITE_DIR
    impure=(--impure)
  fi
  if nix eval "${impure[@]}" --json "$a.nodes" \
    --apply 'ns: builtins.mapAttrs (_: n: n.system.build.toplevel.drvPath) ns' > "$out/$s.nodes.json" 2> "$out/$s.err" &&
    nix eval "${impure[@]}" --raw "$a.config.testScriptString" > "$out/$s.script.py" 2>> "$out/$s.err" &&
    nix eval "${impure[@]}" --raw "$a.config.clan.directory" > "$out/$s.dir" 2>> "$out/$s.err"; then
    echo "snapshot: $s"
  else
    echo "snapshot: $s FAILED, see $out/$s.err" >&2
    return 1
  fi
}
export -f snap
printf '%s\n' "${suites[@]}" | xargs -P 4 -I{} bash -c 'snap "$@"' _ {}
