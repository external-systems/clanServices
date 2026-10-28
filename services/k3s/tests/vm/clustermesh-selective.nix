{ lib, inputs, ... }:
import ../../../../lib/kube-cluster/tests/vm/selective.nix {
  inherit lib inputs;
  distro = "k3s";
}
