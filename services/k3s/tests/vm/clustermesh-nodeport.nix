{
  lib,
  inputs,
  ...
}:
import ../../../../lib/kube-cluster/tests/vm/clustermesh-nodeport.nix {
  inherit lib inputs;
  distro = "k3s";
}
