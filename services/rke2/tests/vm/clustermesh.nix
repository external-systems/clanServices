{
  lib,
  inputs,
  ...
}:
import ../../../../lib/kube-cluster/tests/vm/clustermesh.nix {
  inherit lib inputs;
  distro = "rke2";
}
