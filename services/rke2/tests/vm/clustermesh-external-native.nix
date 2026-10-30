{
  lib,
  inputs,
  ...
}:
import ../../../../lib/kube-cluster/tests/vm/external.nix {
  inherit lib inputs;
  distro = "rke2";
  profile = "native";
}
