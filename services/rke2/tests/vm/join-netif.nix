# rke2-join-netif: the shared join suite with the nodes' underlay declared
# through the netif service (see lib/kube-cluster/tests/vm/join.nix).
{
  lib,
  inputs,
  ...
}:
import ../../../../lib/kube-cluster/tests/vm/join.nix {
  inherit lib inputs;
  distro = "rke2";
  underlay = "netif";
}
