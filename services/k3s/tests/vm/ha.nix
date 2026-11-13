{
  lib,
  inputs,
  ...
}:
import ../../../../lib/kube-cluster/tests/vm/ha.nix {
  inherit lib inputs;
  distro = "k3s";
}
