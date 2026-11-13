{
  lib,
  inputs,
  ...
}:
import ../../../../lib/kube-cluster/tests/vm/join.nix {
  inherit lib inputs;
  distro = "rke2";
}
