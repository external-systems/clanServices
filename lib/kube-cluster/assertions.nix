{ lib }:
{
  mkClusterAssertions =
    {
      instanceName,
      roleMembers,
      settings,
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
    in
    [
      {
        assertion = builtins.length clusterInitMembers == 1;
        message = "kube-cluster/${instanceName}: exactly one server must set clusterInit = true (found ${toString (builtins.length clusterInitMembers)})";
      }
      {
        assertion =
          transportFacts != null
          || lib.all (m: m.settings.network.ipv4 != null && m.settings.network.ipv6 != null) roleMembers;
        message = "kube-cluster/${instanceName}: network.transport is null, so every member must set network.ipv4 and network.ipv6";
      }
      {
        assertion =
          builtins.length (lib.unique (lib.filter (x: x != null) memberIpv4s))
          == builtins.length (lib.filter (x: x != null) memberIpv4s);
        message = "kube-cluster/${instanceName}: every cluster member needs a unique IPv4 address";
      }
      {
        assertion =
          builtins.length (lib.unique (lib.filter (x: x != null) memberIpv6s))
          == builtins.length (lib.filter (x: x != null) memberIpv6s);
        message = "kube-cluster/${instanceName}: every cluster member needs a unique IPv6 address";
      }
      {
        assertion = lib.all (r: r != "" && !lib.hasInfix "\n" r) settings.coredns.rewrites;
        message = "kube-cluster/${instanceName}: every coredns.rewrites entry must be a single non-empty line";
      }
    ];
}
