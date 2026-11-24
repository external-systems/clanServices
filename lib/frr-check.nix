# A build-time check of the rendered frr.conf (SPEC.md D72). FRR's
# reload exits 0 when vtysh refuses the new file, so a broken config
# deploys green and only the journal shows it (upstream-facts.md, FRR).
# This check parses the exact file /etc/frr/frr.conf gets with
# `vtysh --dryrun` (lib/frr-conf-check.nix); a line FRR rejects fails
# the system build, before anything is switched.
{
  config,
  lib,
  pkgs,
  ...
}: let
  frrConf = config.environment.etc."frr/frr.conf".source or null;
in {
  options.clanServices.frr.checkConfig = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Parse the rendered frr.conf with `vtysh --dryrun` at build time and
      fail the system build when FRR rejects a line. Turn it off only in
      a test that must deploy a broken config on purpose.
    '';
  };

  config = lib.mkIf (config.clanServices.frr.checkConfig && frrConf != null) {
    system.checks = [(import ./frr-conf-check.nix {inherit pkgs;} {conf = frrConf;})];
  };
}
