{ lib, inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      nix-unit.tests.kube-cluster = import ./tests/eval-tests.nix {
        inherit lib inputs pkgs;
      };
    };
}
