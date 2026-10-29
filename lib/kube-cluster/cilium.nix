# The canonical Cilium profile (SPEC §6.4). mkCiliumValues produces the
# profile tree; the admin's cilium.helmValues merge on top (override hatch).
# The profile is the intermediate language only — it is translated into
# kubenix typed-tree patches (cilium-config ConfigMap data + KPR env) by
# bundle.nix profilePatches; the chart is never re-run (D26: zero IFD).
#
# D58: the datapath mode, tunnel protocol, devices, directRoutingDevice and
# MTU derive from the generic node_transport export (via transport.nix) and
# admin overrides cannot contradict them — post-merge violations throw here.
{
  lib,
  cidrs,
  hashCiliumId,
  cidrLib,
}: let
  # Resolve CIDRs from explicit options or derive them from the RESOLVED
  # cilium id (hashed default or explicit pin, §6.2). Returns the combined
  # dual-stack strings (distro config) plus the per-family components and
  # clusterDNS (exports/pools/assertions consume the structure).
  #
  # clusterDNS: the 10th address of the service v4 CIDR when explicit,
  # else derived from the resolved id (10.<2id>.0.10 — identical to the
  # derivation when the service CIDR is derived).
  resolveCidrs = {
    settings,
    ciliumId,
  }: let
    derived = cidrs ciliumId;
    explicitPod = settings.network.podCIDRv4 != null || settings.network.podCIDRv6 != null;
    explicitService = settings.network.serviceCIDRv4 != null || settings.network.serviceCIDRv6 != null;

    podCIDRv4 =
      if explicitPod
      then settings.network.podCIDRv4
      else "10.${toString (ciliumId * 2 - 1)}.0.0/16";
    podCIDRv6 =
      if explicitPod
      then settings.network.podCIDRv6
      else "fd10:${toString (ciliumId * 2 - 1)}::/56";
    serviceCIDRv4 =
      if explicitService
      then settings.network.serviceCIDRv4
      else "10.${toString (ciliumId * 2)}.0.0/16";
    serviceCIDRv6 =
      if explicitService
      then settings.network.serviceCIDRv6
      else "fd10:${toString (ciliumId * 2)}::/112";

    join = lib.concatStringsSep ",";
  in {
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
      if settings.network.serviceCIDRv4 != null
      then cidrLib.addressAt settings.network.serviceCIDRv4 10
      else derived.clusterDNS;
    inherit
      podCIDRv4
      podCIDRv6
      serviceCIDRv4
      serviceCIDRv6
      ;
  };

  # Post-merge invariant (D58 / invariant 23): admin helm-values overrides
  # cannot contradict the transport-derived mode, protocol, devices,
  # directRoutingDevice or MTU, and cannot disable the ClusterMesh subsystem
  # or desync maxConnectedClusters from the mesh setting (D60 uniformity).
  contradictions = {
    instanceName,
    merged,
    transportFacts,
    maxConnectedClusters,
  }: let
    mergedDevices = lib.splitString " " (merged.devices or "");
    droppedDevices = lib.filter (d: !(lib.elem d mergedDevices)) transportFacts.interfaces;
  in
    lib.concatStringsSep "; " (
      lib.optional (merged.routingMode != transportFacts.mode)
      "routingMode '${merged.routingMode}' contradicts the transport-derived mode '${transportFacts.mode}' (D58)"
      ++ lib.optional ((merged.tunnelProtocol or null) != (transportFacts.tunnelProtocol or null))
      "tunnelProtocol ${
        builtins.toJSON (merged.tunnelProtocol or null)
      } contradicts the transport-derived protocol ${
        builtins.toJSON (transportFacts.tunnelProtocol or null)
      } (D58)"
      ++ lib.optional (merged.MTU != transportFacts.mtu)
      "MTU ${toString merged.MTU} contradicts the transport-derived MTU ${toString transportFacts.mtu} (D58)"
      ++ lib.optional (merged.nodePort.directRoutingDevice != transportFacts.directRoutingDevice)
      "nodePort.directRoutingDevice '${merged.nodePort.directRoutingDevice}' contradicts the transport-derived device '${transportFacts.directRoutingDevice}' (D58)"
      ++ lib.optional (droppedDevices != [])
      "devices '${merged.devices}' drops transport datapath interface(s): ${lib.concatStringsSep ", " droppedDevices} (D58)"
      ++ lib.optional (!(merged.clusterMesh.enable or false))
      "clusterMesh.enable cannot be disabled — every cluster runs the clustermesh plane from first boot (D60)"
      ++ lib.optional
      ((merged.clusterMesh.maxConnectedClusters or maxConnectedClusters) != maxConnectedClusters)
      "clusterMesh.maxConnectedClusters must match mesh.maxConnectedClusters (${toString maxConnectedClusters}) — group uniformity is fleet-asserted (D60)"
    );
in {
  inherit resolveCidrs contradictions;

  mkCiliumValues = {
    settings,
    # transport facts from transport.nix resolve (D58):
    # { interfaces = [ <linux names> ]; mtu = <derived>; mode = native |
    # tunnel; tunnelProtocol = null | vxlan; directRoutingDevice; } —
    # devices covers EVERY exported datapath interface (one per adjacency
    # on native fabrics) and the MTU is the derived profile MTU (native:
    # minimum interface MTU; VXLAN: minimum minus 50).
    transportFacts,
    instanceName,
    k8sServiceHost,
    k8sServicePort ? 6443,
  }: let
    merged =
      lib.recursiveUpdate {
        cluster = {
          name = instanceName;
          id =
            if settings.cilium.id != null
            then settings.cilium.id
            else hashCiliumId instanceName;
        };
        kubeProxyReplacement = true;
        inherit k8sServiceHost k8sServicePort;
        # D49/D58: native routing on native transports, VXLAN tunnel on
        # tunnel transports; auto-direct-node-routes stays false — remote
        # pod routes ride the transport (FRR/Zebra on native, encapsulation
        # on tunnel).
        routingMode = transportFacts.mode;
        inherit (transportFacts) tunnelProtocol;
        autoDirectNodeRoutes = false;
        # Cilium 1.20 requires its datapath rules for KPR/BPF masquerade;
        # iptables-nft keeps them on the host's nftables backend (D55).
        extraConfig."install-iptables-rules" = true;
        ipv4NativeRoutingCIDR =
          if transportFacts.mode == "native"
          then "10.0.0.0/8"
          else "";
        ipv6NativeRoutingCIDR =
          if transportFacts.mode == "native"
          then "fd10::/16"
          else "";
        devices = lib.concatStringsSep " " (lib.unique transportFacts.interfaces);
        nodePort.directRoutingDevice = transportFacts.directRoutingDevice;
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
        # D60: the ClusterMesh control plane is part of the canonical
        # profile — every eligible cluster runs it from first boot
        # (singletons peer with nobody). maxConnectedClusters is
        # group-uniform (fleet-asserted).
        clusterMesh = {
          enable = true;
          inherit (settings.mesh) maxConnectedClusters;
        };
      }
      settings.cilium.helmValues;

    bad = contradictions {
      inherit instanceName merged transportFacts;
      maxConnectedClusters = settings.mesh.maxConnectedClusters;
    };
  in
    if bad != ""
    then throw "kube-cluster/${instanceName}: cilium.helmValues contradicts the transport-derived profile: ${bad}"
    else merged;
}
