{
  lib,
  inputs,
  ...
}:
import ../../../../lib/kube-cluster/tests/vm/clustermesh-tunnel.nix {
  inherit lib inputs;
  distro = "rke2";
}
