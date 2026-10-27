{ lib, ... }:
import ../../../../lib/kube-cluster/tests/vm/external.nix {
  inherit lib;
  distro = "rke2";
  profile = "tunnel";
}
