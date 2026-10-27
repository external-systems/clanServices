{ lib, ... }:
import ../../../../lib/kube-cluster/tests/vm/selective.nix {
  inherit lib;
  distro = "k3s";
  profile = "tunnel";
}
