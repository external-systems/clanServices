{
  lib,
  inputs,
  ...
}:
import ../../../../lib/kube-cluster/tests/vm/single.nix {
  inherit lib inputs;
  distro = "rke2";
}
