# The size of the pod block Cilium's multi-pool IPAM hands each node
# (the default CiliumPodIPPool, bundle.nix) and therefore the length of
# every per-node pod route on the fabric (frr.nix). One source for both,
# published in the kube_cluster facts as network.podMaskSizeV4/V6.
{
  ipv4 = 24;
  ipv6 = 64;
}
