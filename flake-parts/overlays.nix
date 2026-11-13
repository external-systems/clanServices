# Re-export the org artifact overlays (ifstate, kubernetes, ...) so
# consumers of the services can apply the same package versions.
{inputs, ...}: {
  flake.overlays = inputs.org-pkgs.overlays;
}
