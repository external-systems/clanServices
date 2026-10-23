# The canonical Cilium profile (SPEC §6.4). mkCiliumValues produces the
# profile tree; the admin's cilium.helmValues merge on top (override hatch).
# The profile is the intermediate language only — it is translated into
# kubenix typed-tree patches (cilium-config ConfigMap data + KPR env) by
# bundle.nix profilePatches; the chart is never re-run (D26: zero IFD).
{ lib, cidrs }:
let
  # Resolve CIDRs from explicit options or derive them from cilium.id.
  resolveCidrs =
    settings:
    let
      derived = cidrs settings.cilium.id;
    in
    {
      clusterCidr =
        if settings.network.podCIDRv4 != null || settings.network.podCIDRv6 != null then
          lib.concatStringsSep "," (
            lib.filter (x: x != null) [
              settings.network.podCIDRv4
              settings.network.podCIDRv6
            ]
          )
        else
          derived.clusterCidr;
      serviceCidr =
        if settings.network.serviceCIDRv4 != null || settings.network.serviceCIDRv6 != null then
          lib.concatStringsSep "," (
            lib.filter (x: x != null) [
              settings.network.serviceCIDRv4
              settings.network.serviceCIDRv6
            ]
          )
        else
          derived.serviceCidr;
      inherit (derived) clusterDNS;
    };
in
{
  inherit resolveCidrs;

  mkCiliumValues =
    {
      settings,
      transportFacts,
      instanceName,
      k8sServiceHost,
      k8sServicePort ? 6443,
    }:
    lib.recursiveUpdate {
      cluster = {
        name = instanceName;
        inherit (settings.cilium) id;
      };
      kubeProxyReplacement = true;
      inherit k8sServiceHost k8sServicePort;
      routingMode = "tunnel";
      tunnelProtocol = "vxlan";
      ipv4NativeRoutingCIDR = "10.0.0.0/8";
      ipv6NativeRoutingCIDR = "fd10::/16";
      devices = lib.concatStringsSep " " (lib.unique [ transportFacts.interface ]);
      nodePort.directRoutingDevice = transportFacts.interface;
      MTU = transportFacts.mtu - 50;
      ipam.mode = "multi-pool";
      # D41: Node IPAM is the default classless LoadBalancer mechanism
      # (replaces servicelb, which stays permanently disabled — D42).
      defaultLBServiceIPAM = "nodeipam";
      nodeIPAM.enabled = true;
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
