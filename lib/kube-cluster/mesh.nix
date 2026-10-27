# ClusterMesh placement and exposure resolution (SPEC.md §6.5, D54/D60).
#
# One resolution seam shared by both distro services: the bundle (apiserver
# Deployment/Service patches + peer remote configs), the cert SANs (clan
# vars), and the kube_cluster export all see the same facts.
#
#   placement = voters (default) | workers | all | labels
#   exposure  = auto (default) | internal-load-balancer | node-port |
#               external-load-balancer   (ETP Local on EVERY method)
#
# Full peering within one mesh group is the default; explicit mesh.peers is
# selective (symmetric + same-group, fleet-asserted in fleet-checks.nix).
# Peers dial a cluster through its PUBLISHED endpoints:
#   internal-load-balancer → the pinned IPv4 VIP at fabric-pool offset 79
#   node-port              → every selected node's stable IPv4 address
#   external-load-balancer → the explicit dnsName (DNS resolution is a
#                            runtime prerequisite)
#
# Group uniformity (datapath mode, tunnel protocol, maxConnectedClusters) is
# NOT checked here — it needs every group member's export and lives in
# fleet-checks.nix.
{ lib }:
let
  cidrLib = import ./cidr.nix { inherit lib; };
  bgpLib = import ./bgp.nix { inherit lib; };

  # D10-locked host offset of the internal clustermesh-apiserver IPv4 VIP.
  vipOffset = 79;

  defaultNodePort = 32379;

  # Every cluster node's clan-declared + generated labels (the only labels
  # selectable by placement = labels, D60).
  effectiveLabels =
    {
      instanceName,
      role,
      machineName,
      settings,
    }:
    {
      cluster = instanceName;
      inherit role machineName;
      "topology.kubernetes.io/region" =
        if settings.topology.region != null then settings.topology.region else instanceName;
      "topology.kubernetes.io/zone" =
        if settings.topology.zone != null then settings.topology.zone else instanceName;
    }
    // settings.nodeLabels;

  isIp = s: builtins.match "[0-9.]+" s != null || builtins.match "[0-9a-fA-F:]+" s != null;
in
rec {
  inherit effectiveLabels defaultNodePort;

  # The pinned internal IPv4 VIP (D60): host offset 79 of the
  # <instance>-fabric pool's IPv4 block (D10).
  meshVips =
    { ciliumId, settings }:
    let
      blocks = bgpLib.fabricBlocks { inherit ciliumId settings; };
    in
    {
      ipv4 = cidrLib.addressAt blocks.v4 vipOffset;
    };

  # Select the placement-eligible member machines (D60). roleMembers:
  # [ { machineName, role, settings } ] (settings.nodeLabels included).
  selectEligible =
    {
      instanceName,
      settings,
      roleMembers,
    }:
    let
      roleOf = r: lib.filter (m: m.role == r) roleMembers;
      matches =
        m:
        let
          labels = effectiveLabels {
            inherit instanceName;
            inherit (m) role machineName settings;
          };
        in
        lib.all (k: labels ? ${k} && labels.${k} == settings.mesh.placementLabels.${k}) (
          builtins.attrNames settings.mesh.placementLabels
        );
    in
    if settings.mesh.placement == "voters" then
      map (m: m.machineName) (roleOf "server")
    else if settings.mesh.placement == "workers" then
      map (m: m.machineName) (roleOf "agent")
    else if settings.mesh.placement == "all" then
      map (m: m.machineName) roleMembers
    else
    # labels: only clan-declared/generated labels are selectable; the
    # selector must match at least one member (zero matches = eval error).
    if settings.mesh.placementLabels == { } then
      throw "kube-cluster/${instanceName}: mesh.placement = labels requires a non-empty mesh.placementLabels selector (D60)"
    else
      map (m: m.machineName) (lib.filter matches roleMembers);

  # The complete mesh resolution. members: [ { machineName, role, ipv4,
  # ipv6, settings } ] (roleMembers enriched with addresses). transport: the
  # cluster's (uniform) transport profile from transport.nix. peers:
  # { name = <peer kube_cluster export> } of same-group clusters (self
  # excluded; defensive about missing exports — fleet-checks diagnoses).
  # fabricBlocks: { v4, v6 } of this cluster's fabric pool (null when
  # fabric.enable = false).
  resolve =
    {
      instanceName,
      settings,
      ciliumId,
      domain,
      members,
      transport,
      peers,
      fabricBlocks ? null,
    }:
    let
      inherit (settings) mesh;
      eligible = selectEligible {
        inherit instanceName settings;
        roleMembers = members;
      };

      who = "kube-cluster/${instanceName}";

      # --- exposure ------------------------------------------------------
      externalClassOk =
        mesh.external.loadBalancerClass != null
        && !(lib.hasPrefix "io.cilium/" mesh.external.loadBalancerClass);
      dnsNameOk =
        mesh.external.dnsName != null
        && !(isIp mesh.external.dnsName)
        && builtins.match "^[a-zA-Z0-9.-]+$" mesh.external.dnsName != null;

      method =
        if mesh.exposure == "external-load-balancer" then
          if !externalClassOk then
            throw "${who}: mesh.exposure = external-load-balancer requires mesh.external.loadBalancerClass naming a non-clan class (io.cilium/* is clan-internal, D60)"
          else if !dnsNameOk then
            throw "${who}: mesh.exposure = external-load-balancer requires mesh.external.dnsName (DNS name ONLY — literal IPs are rejected, D60)"
          else
            "external-load-balancer"
        else if mesh.exposure == "internal-load-balancer" then
          if !transport.internalLoadBalancer then
            throw "${who}: mesh.exposure = internal-load-balancer requires the internalLoadBalancer transport capability (D58/D60); use auto or node-port on this transport"
          else
            "internal-load-balancer"
        else if mesh.exposure == "node-port" then
          if !transport.nodePort then
            throw "${who}: mesh.exposure = node-port requires the nodePort transport capability (D58/D60)"
          else
            "node-port"
        else if mesh.exposure == "auto" then
          # D60: auto picks internal-load-balancer when the transport
          # exposes that capability, ELSE node-port. The internal method
          # also needs the private fabric pool (its VIPs draw from it) —
          # without the pool (fabric.enable = false) auto falls back to
          # node-port. NodePort is the universal fallback (a Kubernetes
          # primitive — manual-address clusters included); only EXPLICIT
          # unsupported selections eval-error.
          if transport.internalLoadBalancer && fabricBlocks != null then
            "internal-load-balancer"
          else
            "node-port"
        else
          throw "${who}: unsupported mesh.exposure '${mesh.exposure}'";

      internal = method == "internal-load-balancer";
      nodePort = method == "node-port";
      external = method == "external-load-balancer";

      # --- placement / replicas ------------------------------------------
      eligible' =
        if eligible == [ ] then
          throw "${who}: mesh placement '${mesh.placement}' (labels ${builtins.toJSON mesh.placementLabels}) matches zero cluster nodes (D60: zero matches is an eval error)"
        else
          eligible;

      # Forced on every path (replicas pins it into the result): a
      # zero-match placement must throw regardless of the exposure method.
      eligibleCount = builtins.length eligible';

      replicas =
        if nodePort then
          if mesh.replicas != null then
            throw "${who}: mesh.replicas is FORBIDDEN on node-port exposure — the Deployment replicas equal the selected node count (${toString eligibleCount}, D60)"
          else
            eligibleCount
        else if mesh.replicas != null then
          if mesh.replicas > eligibleCount then
            throw "${who}: mesh.replicas = ${toString mesh.replicas} exceeds the eligible node count ${toString eligibleCount} (placement '${mesh.placement}')"
          else
            mesh.replicas
        else
          lib.min 3 eligibleCount;

      # --- internal VIPs ---------------------------------------------------
      vips =
        if internal then
          if fabricBlocks == null then
            throw "${who}: mesh.exposure = internal-load-balancer requires the private fabric pool (D10/D60: the VIPs draw from <instance>-fabric by lbipam projection) — fabric.enable = false removes the method"
          else
            meshVips { inherit ciliumId settings; }
        else
          null;

      vipContained =
        if vips == null then
          true
        else
          assert
            cidrLib.contains fabricBlocks.v4 "${vips.ipv4}/32"
            || throw "${who}: internal ClusterMesh VIP ${vips.ipv4} escapes the fabric pool IPv4 block (${fabricBlocks.v4}) — the offset-79 VIP must be pool-contained (D60)";
          true;

      # Cilium 1.20.3's clustermesh-apiserver listens on IPv4 only. The mesh
      # data plane stays dual-stack, but control-plane endpoints do not
      # advertise unreachable IPv6 addresses (D60 amended 2026-10-26).
      eligibleAddrs = lib.concatMap (m: lib.optional (m.ipv4 != null) m.ipv4) (
        lib.filter (m: lib.elem m.machineName eligible') members
      );

      port =
        if nodePort then (if mesh.nodePort != null then mesh.nodePort else defaultNodePort) else 2379;

      published =
        if internal then
          [ "https://${vips.ipv4}:2379" ]
        else if external then
          [ "https://${mesh.external.dnsName}:2379" ]
        else
          map (a: "https://${a}:${toString port}") eligibleAddrs;

      sanIps = lib.unique (
        [
          "127.0.0.1"
          "::1"
        ]
        ++ (
          if internal then
            [ vips.ipv4 ]
          else if nodePort then
            eligibleAddrs
          else
            [ ]
        )
      );
      sanDns = lib.unique (
        [ "${instanceName}.mesh.${domain}" ] ++ lib.optional external mesh.external.dnsName
      );

      # --- peers (defensive lookup; fleet-checks diagnoses the details) ----
      peerConfigs = lib.filter (p: p != null) (
        lib.mapAttrsToList (
          name: peer:
          let
            ep = peer.mesh.exposure.published or [ ];
          in
          if name == instanceName || ep == [ ] || (mesh.peers != null && !(lib.elem name mesh.peers)) then
            null
          else
            {
              inherit name;
              endpoints = ep;
            }
        ) peers
      );
    in
    builtins.deepSeq vipContained {
      inherit
        method
        eligible
        replicas
        port
        published
        sanIps
        sanDns
        peerConfigs
        ;
      vip4 = if internal then vips.ipv4 else null;
      pool = if internal then "${instanceName}-fabric" else null;
      dnsName = if external then mesh.external.dnsName else null;
      loadBalancerClass =
        if external then
          mesh.external.loadBalancerClass
        else if internal then
          "io.cilium/bgp-control-plane"
        else
          null;
      annotations =
        if external then
          # external-dns is day-2 (D60): the dnsName renders into the
          # export/cert SANs, never into a clan-managed DNS record.
          mesh.external.annotations
        else if internal then
          { "lbipam.cilium.io/ips" = vips.ipv4; }
        else
          { };
      # Pod scheduling: exact nodeSelector for the uniform placements;
      # nodeAffinity matchExpressions where the selection needs In/AND over
      # arbitrary labels (node-port's per-machine set, labels placement).
      selector =
        if nodePort || mesh.placement == "labels" then
          null
        else if mesh.placement == "voters" then
          {
            "kubernetes.io/os" = "linux";
            cluster = instanceName;
            role = "server";
          }
        else if mesh.placement == "workers" then
          {
            "kubernetes.io/os" = "linux";
            cluster = instanceName;
            role = "agent";
          }
        else
          {
            "kubernetes.io/os" = "linux";
            cluster = instanceName;
          };
      machineAffinityTerms =
        if nodePort then
          [
            {
              matchExpressions = [
                {
                  key = "machine";
                  operator = "In";
                  values = eligible';
                }
              ];
            }
          ]
        else if mesh.placement == "labels" then
          [
            {
              matchExpressions = lib.mapAttrsToList (k: v: {
                key = k;
                operator = "In";
                values = [ v ];
              }) ({ cluster = instanceName; } // mesh.placementLabels);
            }
          ]
        else
          null;
      rollingUpdate = {
        maxSurge = 0;
        maxUnavailable = 1;
      };
      antiAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = [
          {
            labelSelector.matchLabels."k8s-app" = "clustermesh-apiserver";
            topologyKey = "kubernetes.io/hostname";
          }
        ];
      };
    };

  # One remote-cluster entry of the cilium-clustermesh / cilium-kvstoremesh
  # secrets: the etcd client config the agents/kvstoremesh read from the
  # projected /var/lib/cilium/clustermesh volume. mTLS identity comes from
  # the common-etcd-client cert (the local cluster's remote cert, CN
  # remote-<instance>, authorized on the peer by its users.yaml entry).
  remoteClusterConfig =
    { endpoints }:
    lib.concatStringsSep "\n" (
      [ "endpoints:" ]
      ++ map (e: "- ${e}") endpoints
      ++ [
        "trusted-ca-file: /var/lib/cilium/clustermesh/common-etcd-client-ca.crt"
        "key-file: /var/lib/cilium/clustermesh/common-etcd-client.key"
        "cert-file: /var/lib/cilium/clustermesh/common-etcd-client.crt"
      ]
    );

  # The clustermesh-remote-users configmap (mounted into the apiserver's
  # etcd-users-config volume): one etcd user per peer cluster, all bound to
  # the shared read-only `remote` role the etcdinit creates (upstream
  # format: users: [{name: remote-<cluster>, role: remote}]).
  remoteUsersYaml =
    peerConfigs:
    lib.concatStringsSep "\n" (
      [ "users:" ]
      ++ lib.concatMap (p: [
        "- name: remote-${p.name}"
        "  role: remote"
      ]) peerConfigs
    )
    + "\n";

  # --- bundle fragments (kubenix typed tree) -------------------------------

  # The clustermesh-apiserver Deployment patches over the committed base
  # manifest object: placement (nodeSelector/nodeAffinity), required
  # hostname anti-affinity, replicas, and the D60 rolling update
  # (maxSurge=0 / maxUnavailable=1). The --max-connected-clusters args are
  # patched post-render in bundle.nix (list-surgical, chart-bump safe).
  apiserverDeploymentPatch =
    { mesh }:
    {
      "apps"."v1".Deployment."clustermesh-apiserver".spec = {
        replicas = lib.mkForce mesh.replicas;
        strategy = lib.mkForce {
          type = "RollingUpdate";
          inherit (mesh) rollingUpdate;
        };
        template.spec = {
          affinity = lib.mkForce (
            {
              podAntiAffinity = mesh.antiAffinity;
            }
            // lib.optionalAttrs (mesh.machineAffinityTerms != null) {
              nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms =
                mesh.machineAffinityTerms;
            }
          );
          nodeSelector = lib.mkForce (
            if mesh.selector != null then mesh.selector else { "kubernetes.io/os" = "linux"; }
          );
        };
      };
    };

  # The clustermesh-apiserver Service per exposure method (ETP Local on
  # EVERY method, D60/invariant 5). loadBalancerClass renders ONLY on
  # LoadBalancer methods (the apiserver rejects it on NodePort services).
  apiserverServicePatch =
    { mesh }:
    {
      "core"."v1".Service."clustermesh-apiserver" = {
        metadata = {
          annotations = lib.mkForce mesh.annotations;
          labels = lib.optionalAttrs (mesh.pool != null) {
            "clan.lol/pool" = mesh.pool;
          };
        };
        spec = {
          type = lib.mkForce (if mesh.method == "node-port" then "NodePort" else "LoadBalancer");
          externalTrafficPolicy = lib.mkForce "Local";
          ports = lib.mkForce [
            (
              {
                name = "etcd";
                port = 2379;
                targetPort = 2379;
                protocol = "TCP";
              }
              // lib.optionalAttrs (mesh.method == "node-port") {
                nodePort = mesh.port;
              }
            )
          ];
          ipFamilies = lib.mkForce [ "IPv4" ];
          ipFamilyPolicy = lib.mkForce "SingleStack";
        }
        // lib.optionalAttrs (mesh.method != "node-port") {
          loadBalancerClass = lib.mkForce mesh.loadBalancerClass;
        };
      };
    };

  # The peer remote configs: one key per peered cluster in BOTH the agent's
  # cilium-clustermesh secret and the kvstoremesh's cilium-kvstoremesh
  # secret. These secrets carry endpoint config ONLY (no key material — the
  # mTLS client cert projects from clustermesh-apiserver-remote-cert), so
  # they render into the bundle.
  peerSecrets =
    { manifestLabels, peerConfigs }:
    {
      "core"."v1".Secret."cilium-clustermesh" = {
        metadata = {
          namespace = "kube-system";
          labels = manifestLabels;
        };
        stringData = lib.listToAttrs (
          map (p: {
            inherit (p) name;
            value = remoteClusterConfig { inherit (p) endpoints; };
          }) peerConfigs
        );
      };
      "core"."v1".Secret."cilium-kvstoremesh" = {
        metadata = {
          namespace = "kube-system";
          labels = manifestLabels;
        };
        stringData = lib.listToAttrs (
          map (p: {
            inherit (p) name;
            value = remoteClusterConfig { inherit (p) endpoints; };
          }) peerConfigs
        );
      };
    };

  # The eval-visible exposure facts (kube_cluster.mesh.exposure, schema 4).
  exportFacts =
    { mesh }:
    {
      inherit (mesh)
        method
        replicas
        vip4
        dnsName
        loadBalancerClass
        published
        ;
      nodePort = if mesh.method == "node-port" then mesh.port else null;
    };
}
