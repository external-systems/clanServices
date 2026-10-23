# The vendored BIRD named-fragment NixOS module (D19). Path-imported by
# every clanService that contributes BIRD config (kube-cluster distros,
# fleet-routing in campaign B) so the NixOS module system dedups it and all
# contributions land in ONE bird daemon per host (invariant 9).
#
# Same-key fragments merge by text concatenation (types.lines) — documented
# as avoid. `routerId` accepts exactly one value per host: a conflicting
# second definition is a native NixOS eval error.
#
# The assembled config is validated by `bird -p` at BUILD time via the
# nixpkgs module's checkConfig hook (D19's validator).
{
  lib,
  config,
  pkgs,
  ...
}:
let
  birdLib = import ./bird.nix { inherit lib; };
  cfg = config.clan.bird;
in
{
  options.clan.bird = {
    fragments = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            config = lib.mkOption {
              type = lib.types.lines;
              default = "";
              description = ''
                The fragment's main BIRD config text (protocols, ...).
              '';
            };
            filters = lib.mkOption {
              type = lib.types.attrsOf lib.types.lines;
              default = { };
              description = ''
                Named BIRD filters: each value is a filter BODY rendered as
                `filter <name> { ... }` at the top of the fragment. Same-name
                filters across fragments concatenate (avoid).
              '';
            };
            functions = lib.mkOption {
              type = lib.types.attrsOf lib.types.lines;
              default = { };
              description = ''
                Named BIRD functions: each value is a FULL function
                definition rendered verbatim at the top of the fragment.
                Same-name functions across fragments concatenate (almost
                certainly a syntax error — caught by the bird -p build-time
                check; avoid).
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        Named BIRD config fragments, one entry per contributing
        clanService instance. Keys MUST be namespace-prefixed per
        contributor ("kube-cluster-<instance>", "fleet-routing-<instance>",
        D19). All fragments run in ONE bird daemon per host.
      '';
    };

    routerId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The host's BIRD router id (an IPv4 address). Set exactly once per
        host — by convention the host's cluster/transport IPv4; a
        conflicting second definition fails evaluation (D19). Required when
        any fragment is present.
      '';
    };
  };

  config = lib.mkIf (cfg.fragments != { }) {
    assertions = [
      {
        assertion = cfg.routerId != null;
        message = "clan.bird: fragments present but routerId is unset — set clan.bird.routerId exactly once per host (D19)";
      }
      {
        # Invariant 9: one BGP stack per host.
        assertion = !(config.services.frr.bgpd.enable or false);
        message = "clan.bird: one BGP stack per host (invariant 9) — FRR bgpd is enabled alongside the clan BIRD fabric";
      }
    ];

    services.bird = {
      enable = true;
      package = pkgs.bird2;
      # bird -p at build time (D19's validator, stronger than pre-start).
      checkConfig = true;
      config = birdLib.assemble {
        inherit (cfg) routerId fragments;
      };
    };
  };
}
