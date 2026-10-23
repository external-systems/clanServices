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

  mkCiliumManifests =
    {
      settings,
    }:
    let
      resolved = resolveCidrs settings;
      podCidrs = lib.splitString "," resolved.clusterCidr;
      podCidr4 = builtins.elemAt podCidrs 0;
      podCidr6 = builtins.elemAt podCidrs 1;
    in
    [
      {
        apiVersion = "cilium.io/v2alpha1";
        kind = "CiliumPodIPPool";
        metadata.name = "default";
        spec = {
          ipv4 = {
            cidrs = [ podCidr4 ];
            maskSize = 24;
          };
          ipv6 = {
            cidrs = [ podCidr6 ];
            maskSize = 64;
          };
        };
      }
    ];
}
