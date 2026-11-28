{
  lib,
  inputs,
  nodes,
  ...
}:
import ../../../../lib/kube-cluster/tests/vm/hostile.nix {
  inherit lib inputs nodes;
  distro = "k3s";
}
