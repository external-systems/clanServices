# Import a remote flake without using builtins.getFlake.
#
# Fetches only the source tree via fetchTree, then resolves inputs:
#   - Inputs provided in `inputOverrides` use the local version (e.g., your nixpkgs)
#   - All other inputs are fetched from the remote flake.lock
#   - "follows" references are resolved correctly, so overridden inputs
#     propagate into transitive dependencies
#
# Usage:
#   importFlake {
#     src = { type = "github"; owner = "foo"; repo = "bar"; rev = "..."; };
#     inputOverrides = { nixpkgs = inputs.nixpkgs; };
#   }
#
{
  # fetchTree-compatible attrset for the flake source
  src,
  # Attrset of input name -> flake outputs to use instead of fetching from lock
  inputOverrides ? { },
}:
let
  sourceTree = builtins.fetchTree src;

  lock = builtins.fromJSON (builtins.readFile (sourceTree + "/flake.lock"));
  rootInputDefs = lock.nodes.${lock.root}.inputs or { };

  # Resolve a "follows" path (e.g. ["nixpkgs"] or ["flake-parts", "nixpkgs-lib"])
  # against the already-resolved root inputs.
  resolveFollows =
    path:
    if builtins.length path == 1 then
      resolvedRootInputs.${builtins.elemAt path 0}
    else if builtins.length path == 2 then
      (resolveNode (builtins.elemAt path 0)).inputs.${builtins.elemAt path 1}
    else
      throw "import-flake: follows path depth > 2 not supported: ${builtins.toJSON path}";

  # Resolve a single node from the lock into a flake-like attrset.
  resolveNode =
    nodeName:
    let
      node = lock.nodes.${nodeName};
      nodeSource = builtins.fetchTree node.locked;
      hasFlake = builtins.pathExists (nodeSource + "/flake.nix");
      nodeFlakeNix = import (nodeSource + "/flake.nix");

      # Resolve this node's own inputs (handling follows)
      nodeInputDefs = node.inputs or { };
      nodeInputs = builtins.mapAttrs (
        _name: ref: if builtins.isList ref then resolveFollows ref else resolveNode ref
      ) nodeInputDefs;

      outputs =
        let
          out = nodeFlakeNix.outputs (
            nodeInputs
            // {
              self = out // {
                outPath = nodeSource;
                sourceInfo = node.locked;
                inputs = nodeInputs;
              };
            }
          );
        in
        out;
    in
    if hasFlake then
      outputs
      // {
        outPath = nodeSource;
        sourceInfo = node.locked;
        inputs = nodeInputs;
      }
    else
      # Plain source input (e.g. systems)
      nodeSource;

  # Resolve all root-level inputs, applying overrides
  resolvedRootInputs = builtins.mapAttrs (
    name: ref:
    if builtins.hasAttr name inputOverrides then
      inputOverrides.${name}
    else if builtins.isList ref then
      resolveFollows ref
    else
      resolveNode ref
  ) rootInputDefs;

  # Build the root flake outputs
  flakeNix = import (sourceTree + "/flake.nix");
  outputs =
    let
      out = flakeNix.outputs (
        resolvedRootInputs
        // {
          self = out // {
            outPath = sourceTree;
            sourceInfo = src;
            inputs = resolvedRootInputs;
          };
        }
      );
    in
    out;
in
outputs
// {
  outPath = sourceTree;
  sourceInfo = src;
  inputs = resolvedRootInputs;
}
