{
  lib,
  inputs,
  ...
}:
import ../../../../lib/kube-cluster/tests/vm/ha-fabric.nix {
  inherit lib inputs;
  distro = "k3s";
}
