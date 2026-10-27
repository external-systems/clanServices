{ lib, ... }:
import ../../../../lib/kube-cluster/tests/vm/external.nix {
  inherit lib;
  distro = "k3s";
  profile = "tunnel";
}
