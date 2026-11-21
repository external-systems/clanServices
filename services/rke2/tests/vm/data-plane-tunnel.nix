# rke2-data-plane-tunnel: the Data-plane suite on the wireguard-mesh tunnel
# transport (lib/kube-cluster/tests/vm/data-plane-tunnel.nix).
{inputs}:
import ../../../../lib/kube-cluster/tests/vm/data-plane-tunnel.nix {
  inherit inputs;
  distro = "rke2";
}
