{ lib, inputs, ... }:
import ../../../../lib/kube-cluster/tests/vm/selective.nix {
  inherit lib inputs;
  distro = "rke2";
  profile = "tunnel";
}
