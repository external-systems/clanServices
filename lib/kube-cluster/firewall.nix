# The node firewall of a cluster member (SPEC.md §6.12, D76;
# specs/design-kube.md §3.2): which hosts may reach the Kubernetes
# ports in the input hook. One matrix of rows, rendered by source.
#
# A row names its ports and the classes of sources it opens them to
# (`members`, `servers`, `pods`), never addresses: the caller resolves
# the classes. Every rule also requires a fabric link or a local pod
# link (`lxc*`, `cilium*`): routed-fabric never trusts a fabric link
# (D75), and a pod is a source like any other.
#
# Not in the matrix:
#   - the HAProxy fronts: they bind loopback (§3.6), so no host and no
#     pod reaches them;
#   - etcd's metrics port 2381: it listens on loopback only;
#   - BGP and BFD: routed-fabric's (D73);
#   - Service fronts (NodePorts, LoadBalancer addresses): Cilium serves
#     them in eBPF before netfilter (§3.5).
{lib}: let
  setOf = xs: "{ ${lib.concatStringsSep ", " xs} }";
  quoted = map (i: ''"${i}"'');
  portSet = ports: setOf (map toString ports);
in {
  # One row per listener, filtered to the rows this node has.
  matrix = {
    isServer,
    # the distro has its own supervisor port (rke2)
    supervisor,
    kubeapiPort,
    supervisorPort,
    # `firewall.kubeletFromPods`: a metrics scraper in a pod reads the
    # kubelet
    kubeletFromPods ? false,
  }:
    lib.filter (row: row.on) [
      {
        # every member's HAProxy; pods through the `kubernetes` ClusterIP
        # (the translation keeps the pod source)
        name = "api";
        ports = [kubeapiPort];
        from = ["members" "pods"];
        on = isServer;
      }
      {
        # joins through the joiner's loopback HAProxy, and an rke2
        # agent's tunnel (`kubectl logs` and `exec` ride it)
        name = "supervisor";
        ports = [supervisorPort];
        from = ["members"];
        on = isServer && supervisor;
      }
      {
        # the API server reads logs and runs exec
        name = "kubelet";
        ports = [10250];
        from = ["servers"] ++ lib.optional kubeletFromPods "pods";
        on = true;
      }
      {
        # Cilium's node-to-node health probe
        name = "cilium-health";
        ports = [4240];
        from = ["members"];
        on = true;
      }
      {
        # etcd client and peer
        name = "etcd";
        ports = [2379 2380];
        from = ["servers"];
        on = isServer;
      }
    ];

  # The nft rules of the rows. sources = { <class> = { v4 = [..]; v6 = [..]; }; }.
  renderMatrix = {
    rows,
    sources,
    # this machine's fabric links; never empty (D76: a member always has
    # a fabric)
    guardInterfaces,
  }:
    assert lib.assertMsg (guardInterfaces != []) "kube-cluster firewall: a member without fabric links has no guarded rule (D76)"; let
      guard = "iifname ${setOf (quoted (guardInterfaces ++ ["lxc*" "cilium*"]))} ";
      line = family: key: row: let
        from = lib.unique (lib.concatMap (class: sources.${class}.${key}) row.from);
      in
        lib.optionalString (from != [])
        "${guard}${family} saddr ${setOf from} tcp dport ${portSet row.ports} accept";
    in
      lib.concatStringsSep "\n" (
        lib.filter (l: l != "") (lib.concatMap (row: [(line "ip" "v4" row) (line "ip6" "v6" row)]) rows)
      )
      + "\n";
}
