{
  description = "Fixture flake used by tests/flake-module.nix to exercise clan-community.inputs resolution.";

  outputs =
    { self }:
    {
      nixosModules.hello =
        { lib, ... }:
        {
          environment.etc."hello-from-fixture".text = "hi from the fixture flake";
        };
    };
}
