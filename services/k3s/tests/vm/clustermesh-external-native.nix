{
  lib,
  inputs,
  ...
}:
import ../../../../lib/kube-cluster/tests/vm/external.nix {
  inherit lib inputs;
  distro = "k3s";
  profile = "native";
}
