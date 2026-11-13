# k3s-data-plane: the shared Data-plane suite (lib/kube-cluster/tests/vm/data-plane.nix).
{inputs}:
import ../../../../lib/kube-cluster/tests/vm/data-plane.nix {
  inherit inputs;
  distro = "k3s";
}
