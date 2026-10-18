{ lib, ... }:
{
  perSystem = _: {
    nix-unit.tests.rancher-cluster = import ./tests/eval-tests.nix { inherit lib; };
  };
}
