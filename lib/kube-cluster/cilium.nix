# The canonical Cilium profile (SPEC §6.4). mkCiliumValues produces the
# profile tree; the admin's cilium.helmValues merge on top (override hatch).
# The profile is the intermediate language only — it is translated into
# kubenix typed-tree patches (cilium-config ConfigMap data + KPR env) by
# bundle.nix profilePatches; the chart is never re-run (D26: zero IFD).
{
  lib,
  cidrs,
  hashCiliumId,
  cidrLib,
}:
let
  # Resolve CIDRs from explicit options or derive them from the RESOLVED
  # cilium id (hashed default or explicit pin, §6.2). Returns the combined
  # dual-stack strings (distro config) plus the per-family components and
  # clusterDNS (exports/pools/assertions consume the structure).
  #
  # clusterDNS: the 10th address of the service v4 CIDR when explicit,
  # else derived from the resolved id (10.<2id>.0.10 — identical to the
  # derivation when the service CIDR is derived).
  resolveCidrs =
    { settings, ciliumId }:
    let
      derived = cidrs ciliumId;
      explicitPod = settings.network.podCIDRv4 != null || settings.network.podCIDRv6 != null;
      explicitService = settings.network.serviceCIDRv4 != null || settings.network.serviceCIDRv6 != null;

      podCIDRv4 =
        if explicitPod then settings.network.podCIDRv4 else "10.${toString (ciliumId * 2 - 1)}.0.0/16";
      podCIDRv6 =
        if explicitPod then settings.network.podCIDRv6 else "fd10:${toString (ciliumId * 2 - 1)}::/56";
      serviceCIDRv4 =
        if explicitService then settings.network.serviceCIDRv4 else "10.${toString (ciliumId * 2)}.0.0/16";
      serviceCIDRv6 =
        if explicitService then settings.network.serviceCIDRv6 else "fd10:${toString (ciliumId * 2)}::/112";

      join = lib.concatStringsSep ",";
    in
    {
      clusterCidr = join (
        lib.filter (x: x != null) [
          podCIDRv4
          podCIDRv6
        ]
      );
      serviceCidr = join (
        lib.filter (x: x != null) [
          serviceCIDRv4
          serviceCIDRv6
        ]
      );
      clusterDNS =
        if settings.network.serviceCIDRv4 != null then
          cidrLib.addressAt settings.network.serviceCIDRv4 10
        else
          derived.clusterDNS;
      inherit
        podCIDRv4
        podCIDRv6
        serviceCIDRv4
        serviceCIDRv6
        ;
    };
in
{
  inherit resolveCidrs;

  mkCiliumValues =
    {
      settings,
      # fabric device facts: { interfaces = [ ... ]; mtu = <smallest
      # adjacency MTU>; } — devices covers EVERY fabric adjacency interface
      # of this machine (D49/D51) and the MTU is the smallest adjacency MTU
      # (native routing uses the WG MTU directly; no VXLAN -50, D51).
      transportFacts,
      instanceName,
      k8sServiceHost,
      k8sServicePort ? 6443,
    }:
    lib.recursiveUpdate {
      cluster = {
        name = instanceName;
        id = if settings.cilium.id != null then settings.cilium.id else hashCiliumId instanceName;
      };
      kubeProxyReplacement = true;
      inherit k8sServiceHost k8sServicePort;
      # D49: native routing is mandatory; auto-direct-node-routes stays
      # false — FRR/Zebra owns remote pod-pool routes (§6.4).
      routingMode = "native";
      autoDirectNodeRoutes = false;
      # Cilium 1.20 requires its datapath rules for KPR/BPF masquerade;
      # iptables-nft keeps them on the host's nftables backend (D55).
      extraConfig."install-iptables-rules" = true;
      ipv4NativeRoutingCIDR = "10.0.0.0/8";
      ipv6NativeRoutingCIDR = "fd10::/16";
      devices = lib.concatStringsSep " " (lib.unique transportFacts.interfaces);
      nodePort.directRoutingDevice = builtins.head transportFacts.interfaces;
      MTU = transportFacts.mtu;
      ipam.mode = "multi-pool";
      # D41: Node IPAM is the default classless LoadBalancer mechanism
      # (replaces servicelb, which stays permanently disabled — D42).
      defaultLBServiceIPAM = "nodeipam";
      nodeIPAM.enabled = true;
      # D41: explicit pools use the BGP class for LB-IPAM allocation even
      # without BGP resources; D9's bgp.enable controls those resources.
      bgpControlPlane.enabled = true;
      ipv4.enabled = true;
      ipv6.enabled = true;
      enableIPv4Masquerade = true;
      enableIPv6Masquerade = true;
      bpf = {
        masquerade = true;
        tproxy = true;
      };
      cni = {
        chainingMode = "none";
        exclusive = true;
      };
      operator.replicas = 1;
      gatewayAPI.enabled = false;
      ingressController.enabled = false;
      loadBalancer.algorithm = "maglev";
      pmtuDiscovery.enabled = true;
    } settings.cilium.helmValues;
}
