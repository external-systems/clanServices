{
  ...
}:
{
  imports = [
    ../lib/inputs-module.nix
  ]
  ++ (
    let
      dirContents = builtins.readDir ./.;

      validModuleDirs = builtins.filter (
        name:
        name != "result"
        && dirContents.${name} == "directory"
        && builtins.pathExists (./. + "/${name}/flake-module.nix")
      ) (builtins.attrNames dirContents);
    in
    map (name: ./. + "/${name}/flake-module.nix") validModuleDirs
  );
}
