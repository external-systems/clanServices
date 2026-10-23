{ lib, ... }:
{
  perSystem = _: {
    nix-unit.tests.kube-cluster = import ./tests/eval-tests.nix { inherit lib; };
  };
}
