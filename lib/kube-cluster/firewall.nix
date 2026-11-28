# The node firewall of a cluster member (SPEC.md §6.12): which hosts
# may reach the Kubernetes ports in the input hook.
#
# Every rule names its sources, so it holds on fabric links (routed-fabric
# never trusts them, D75) and in manual-address clusters,
# where the node addresses sit on an underlay that may face the
# Internet:
#   - the cluster ports (the API, the API's HAProxy front, the kubelet,
#     Cilium's health port) from the members' node addresses and the
#     cluster's pod CIDRs (a pod's traffic to a node address keeps its
#     pod source inside ipv4NativeRoutingCIDR);
#   - etcd (2379, 2380) on servers only, from the servers' node
#     addresses. 2381 (etcd metrics) listens on loopback only; its rule
#     exists so the `ha` suite reads a refusal, and goes with kube step 4
#     (specs/design-kube.md §3.2);
#   - `memberOnlyPorts` (the rke2 supervisor and its HAProxy front) from
#     the members only: a pod never joins (K-A2).
# Nothing else from a pod reaches the host: a pod is a source like any
# other. On a fabric the rules also require a fabric link or a local pod
# link (`lxc*`, `cilium*`); a manual cluster has no named underlay.
{lib}: let
  setOf = xs: "{ ${lib.concatStringsSep ", " xs} }";
  quoted = map (i: ''"${i}"'');
  portSet = ports: setOf (map toString ports);
in {
  mkInputRules = {
    # the fabric links of this machine; [] = a manual-address cluster
    transportInterfaces,
    # every member: { role, ipv4, ipv6 }
    members,
    # the cluster's pod CIDRs (nulls are dropped)
    podCIDRv4,
    podCIDRv6,
    isServer,
    # open to members and pods
    clusterPorts,
    # open to members only
    memberOnlyPorts ? [],
    etcdPorts ? [
      2379
      2380
      2381
    ],
  }: let
    nonNull = lib.filter (x: x != null);
    guard = lib.optionalString (transportInterfaces != []) "iifname ${
      setOf (quoted transportInterfaces ++ quoted ["lxc*" "cilium*"])
    } ";
    servers = lib.filter (m: m.role == "server") members;
    rule = family: sources: ports:
      lib.optionalString (sources != [] && ports != [])
      "${guard}${family} saddr ${setOf sources} tcp dport ${portSet ports} accept";
    v4 = ms: nonNull (map (m: m.ipv4) ms);
    v6 = ms: nonNull (map (m: m.ipv6) ms);
  in
    lib.concatStringsSep "\n" (
      lib.filter (r: r != "") [
        (rule "ip" (v4 members ++ nonNull [podCIDRv4]) clusterPorts)
        (rule "ip6" (v6 members ++ nonNull [podCIDRv6]) clusterPorts)
        (rule "ip" (v4 members) memberOnlyPorts)
        (rule "ip6" (v6 members) memberOnlyPorts)
      ]
      ++ lib.optionals isServer (
        lib.filter (r: r != "") [
          (rule "ip" (v4 servers) etcdPorts)
          (rule "ip6" (v6 servers) etcdPorts)
        ]
      )
    )
    + "\n";
}
