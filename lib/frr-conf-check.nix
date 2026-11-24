# `vtysh --dryrun` over one frr.conf: the derivation builds when FRR
# accepts every line and fails, printing vtysh's errors, when it does not.
# Shared by the NixOS module (lib/frr-check.nix) and `checks.frr-conf`.
# Syntax only: vtysh parses each line against its command tree; names
# (neighbors, route-maps, prefix-lists) are not resolved.
{pkgs}: {
  name ? "frr-conf-check",
  conf,
}:
pkgs.runCommand name {nativeBuildInputs = [pkgs.frr];} ''
  mkdir etc
  echo 'service integrated-vtysh-config' > etc/vtysh.conf
  cp ${conf} etc/frr.conf
  if ! vtysh --config_dir "$PWD/etc" --dryrun --inputfile "$PWD/etc/frr.conf" > log 2>&1; then
    cat log >&2
    echo "frr.conf: FRR rejects the rendered config (vtysh --dryrun); see the lines above" >&2
    exit 1
  fi
  touch $out
''
