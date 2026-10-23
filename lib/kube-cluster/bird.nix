# The vendored BIRD named-fragment assembler (D19).
#
# Multiple clanServices contribute named blocks to ONE BIRD daemon per
# host. The NixOS side lives in bird-module.nix (the `clan.bird` options);
# this file is the pure assembler (nix-unit tested).
#
# Contribution model:
#   fragments = {
#     "<service>-<instance>/<name>" = {
#       config    = ''...'';          # main block text (protocols, ...)
#       filters   = { fname = ''<filter body>''; };   # rendered as `filter fname { ... }`
#       functions = { fname = ''<full function def>''; };  # rendered verbatim
#     };
#   }
# Keys MUST be namespace-prefixed per contributing instance (documented;
# the assembler cannot know its caller). Same-key fragments MERGE by text
# concatenation (the NixOS module's `lines` type does this) — legal for
# deliberate splits, silently wrong when accidental: avoid.
#
# `routerId` is set exactly once per host (a conflicting second definition
# is a NixOS eval error natively); fragments present with no routerId is an
# eval error here.
#
# The assembled single bird.conf is validated by `bird -p` at BUILD time
# (the nixpkgs services.bird checkConfig hook) — stronger than a pre-start
# check, and the same validator.
{ lib }:
{
  assemble =
    {
      routerId,
      fragments,
    }:
    if fragments != { } && routerId == null then
      throw "clan.bird: fragments present but routerId is unset (set clan.bird.routerId exactly once per host)"
    else
      let
        keys = builtins.sort builtins.lessThan (builtins.attrNames fragments);

        renderFragment =
          key:
          let
            f = fragments.${key};
            filterKeys = builtins.sort builtins.lessThan (builtins.attrNames (f.filters or { }));
            functionKeys = builtins.sort builtins.lessThan (builtins.attrNames (f.functions or { }));
          in
          ''
            # ---- fragment ${key} ----
          ''
          + lib.concatMapStringsSep "\n" (fname: ''
            filter ${fname} {
            ${f.filters.${fname}}
            }
          '') filterKeys
          + lib.concatMapStringsSep "\n" (fname: f.functions.${fname}) functionKeys
          + (f.config or "");
      in
      ''
        # bird.conf — assembled by lib/kube-cluster (D19 vendored
        # named-fragment pattern). Contributors: ${lib.concatStringsSep ", " keys}.
        router id ${routerId};

      ''
      + lib.concatMapStringsSep "\n" renderFragment keys;
}
