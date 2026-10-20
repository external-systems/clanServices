# MkDocs documentation site + reveal.js slides for the spec.
# Build: nix build .#documentation / .#slides
# Preview: nix run .#watch-documentation / .#serve-slides
{ inputs, ... }:
{
  imports = [ inputs.presenting.flakeModules.default ];

  perSystem = {
    documentation = {
      mkdocs-root = ./.;
      # Broken links / missing nav pages fail the build instead of warning.
      strict = true;
    };

    presenting.slides = {
      dir = ./slides;
      # The serve app looks for live files by this name from the CWD.
      serveDirName = "documentation/slides";
    };
  };
}
