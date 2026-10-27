{ lib, ... }:
import ../../../../lib/kube-cluster/tests/vm/selective.nix {
  inherit lib;
  distro = "rke2";
  profile = "tunnel";
}
