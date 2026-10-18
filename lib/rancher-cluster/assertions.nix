{ lib, ingress }:
let
  dns1123 = name: builtins.match "[a-z0-9]([-a-z0-9]*[a-z0-9])?" name != null;
in
{
  mkClusterAssertions =
    {
      instanceName,
      roleMembers,
      settings,
      members,
      domain,
      transportFacts ? null,
    }:
    let
      serverMembers = lib.filter (m: m.role == "server") roleMembers;
      clusterInitMembers = lib.filter (m: m.settings.clusterInit) serverMembers;

      memberAddrs = map (
        m:
        if transportFacts != null && transportFacts ? ${m.machineName} then
          transportFacts.${m.machineName}
        else
          { inherit (m.settings.network) ipv4 ipv6; }
      ) roleMembers;
      memberIpv4s = map (a: a.ipv4 or null) memberAddrs;
      memberIpv6s = map (a: a.ipv6 or null) memberAddrs;

      traefikInstances =
        if !settings.traefik.enabled then
          [ ]
        else
          ingress.mkTraefikInstances {
            inherit settings members;
            certManagerEnabled = settings.certManager.enabled;
          };
      gatewayInstances = lib.filter (i: i.gatewayAPI.enabled) traefikInstances;
      nodeIpamInstances = lib.filter (
        i: i.service.type == "LoadBalancer" && i.service.loadBalancerClass == "io.cilium/node"
      ) traefikInstances;
    in
    [
      {
        assertion = builtins.length clusterInitMembers == 1;
        message = "rancher-cluster/${instanceName}: exactly one server must set clusterInit = true (found ${toString (builtins.length clusterInitMembers)})";
      }
      {
        assertion =
          transportFacts != null
          || lib.all (m: m.settings.network.ipv4 != null && m.settings.network.ipv6 != null) roleMembers;
        message = "rancher-cluster/${instanceName}: network.transport is null, so every member must set network.ipv4 and network.ipv6";
      }
      {
        assertion =
          builtins.length (lib.unique (lib.filter (x: x != null) memberIpv4s))
          == builtins.length (lib.filter (x: x != null) memberIpv4s);
        message = "rancher-cluster/${instanceName}: every cluster member needs a unique IPv4 address";
      }
      {
        assertion =
          builtins.length (lib.unique (lib.filter (x: x != null) memberIpv6s))
          == builtins.length (lib.filter (x: x != null) memberIpv6s);
        message = "rancher-cluster/${instanceName}: every cluster member needs a unique IPv6 address";
      }
      {
        assertion = builtins.length gatewayInstances <= 1;
        message = "rancher-cluster/${instanceName}: at most one traefik.instances entry may set gatewayAPI.enabled (found: ${
          lib.concatStringsSep ", " (map (i: i.name) gatewayInstances)
        })";
      }
      {
        assertion = lib.all (
          i:
          let
            cps = map (ep: ep.containerPort) i.entrypoints;
            sps = map (ep: ep.servicePort) i.exposedEps;
          in
          builtins.length (lib.unique cps) == builtins.length cps
          && builtins.length (lib.unique sps) == builtins.length sps
          && lib.all (ep: ep.protocol == "HTTPS") (lib.filter (ep: ep.http3) i.entrypoints)
          && lib.all (
            ep:
            lib.elem ep.protocol [
              "HTTPS"
              "TCP"
            ]
          ) (lib.filter (ep: ep.tls.options != null || ep.tls.certSecretNames != [ ]) i.entrypoints)
        ) traefikInstances;
        message = "rancher-cluster/${instanceName}: traefik entrypoints must have unique container/service ports per instance; http3 is HTTPS-only; tls.options/tls.certSecretNames are HTTPS/TCP-only";
      }
      {
        assertion =
          let
            pairs = lib.concatLists (
              map (
                i: lib.concatMap (ep: map (n: "${n}:${toString ep.servicePort}") i.nodes) i.exposedEps
              ) nodeIpamInstances
            );
          in
          builtins.length (lib.unique pairs) == builtins.length pairs;
        message = "rancher-cluster/${instanceName}: io.cilium/node Traefik instances collide on a (node, servicePort) pair";
      }
      {
        assertion = lib.all (i: lib.all (n: lib.elem n members) i.nodes) traefikInstances;
        message = "rancher-cluster/${instanceName}: a traefik instance's nodes entry is not a cluster member";
      }
      {
        assertion = lib.all (i: dns1123 i.name && dns1123 i.namespace) traefikInstances;
        message = "rancher-cluster/${instanceName}: traefik instance names and namespaces must be DNS-1123 labels";
      }
      {
        assertion =
          !settings.certManager.enabled
          || lib.all (
            c:
            lib.elem c.secretName
              (ingress.mkTraefikManifests {
                instances = traefikInstances;
                inherit domain;
                manifestLabels = { };
              }).certConsumedBy
          ) settings.certManager.certificates;
        message = "rancher-cluster/${instanceName}: certManager.certificates entries are rendered but consumed by NO Gateway listener";
      }
      {
        assertion = lib.all (r: r != "" && !lib.hasInfix "\n" r) settings.coredns.rewrites;
        message = "rancher-cluster/${instanceName}: every coredns.rewrites entry must be a single non-empty line";
      }
    ];
}
