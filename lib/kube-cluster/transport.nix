# The generic node_transport consumer (SPEC.md D58). k3s/rke2 (and this
# shared lib) consume ONLY the neutral schemaVersion 2 `node_transport`
# export — never provider service names or provider-specific exports.
# This module validates the transport profile and derives the
# Cilium-facing facts. Every transport is native routing (D72): Cilium
# routing-mode native, native.routeExchange = local-router, MTU = the
# minimum interface MTU.
#
# Unsupported profiles (unknown route exchange, empty interface set,
# directRoutingDevice not naming an exported interface, schemaVersion !=
# 2) throw at eval — the schema is open but only validated profiles are
# consumable until implemented and tested (D58).
{lib}: let
  inherit (builtins) attrNames;

  minOf = xs: lib.foldl' lib.min 65535 xs;

  sorted = lib.sort builtins.lessThan;
in {
  # Validate one machine's node_transport export and derive the facts.
  # transport: the export value (node_transport subtree), or null.
  resolve = {
    instanceName,
    machineName,
    transport,
  }:
    if transport == null
    then null
    else let
      who = "kube-cluster/${instanceName}/${machineName}";

      version = transport.schemaVersion or 0;
      interfaces = transport.interfaces or {};
      ifaceNames = attrNames interfaces;
      mtuOf = name: interfaces.${name}.mtu or 0;
      mtus = map mtuOf ifaceNames;
      routeExchange = transport.native.routeExchange or null;
      directRoutingDevice = transport.directRoutingDevice or "";
      minMtu = minOf mtus;

      problems = lib.concatStringsSep "; " (
        lib.optional (
          version != 2
        ) "unsupported node_transport schemaVersion ${toString version} (only 2 is consumable, D58)"
        ++ lib.optional (ifaceNames == []) "no datapath interfaces exported"
        ++ lib.optional (
          mtus == [] || lib.any (m: !(m > 0)) mtus
        ) "every exported interface needs a positive MTU"
        ++ lib.optional (routeExchange != "local-router")
        "unsupported native.routeExchange ${builtins.toJSON routeExchange} (only local-router is implemented, D58)"
        ++ lib.optional (!(lib.elem directRoutingDevice ifaceNames))
        "directRoutingDevice '${directRoutingDevice}' does not name an exported interface (${lib.concatStringsSep ", " ifaceNames})"
      );
    in
      if problems != ""
      then throw "${who}: unsupported node_transport profile: ${problems}"
      else {
        inherit
          routeExchange
          directRoutingDevice
          minMtu
          ;
        # Cilium MTU: the minimum interface MTU (D58, invariant 21).
        mtu = minMtu;
        interfaces = sorted ifaceNames;
        endpoint = transport.endpoint or null;
        port = transport.port or null;
        service = transport.service or null;
        instance = transport.instance or null;
        asn = transport.asn or null;
        inherit (transport) ipv4 ipv6;
        internalLoadBalancer = transport.internalLoadBalancer or false;
        nodePort = transport.nodePort or false;
      };

  # The Cilium devices string (space-separated, unique). Supersets are
  # allowed post-merge (extra NICs for VIP ingress); dropping a transport
  # device contradicts the transport and is rejected post-merge.
  devicesString = profile: lib.concatStringsSep " " (lib.unique profile.interfaces);

  # The cluster-uniform projection of a transport profile (D58): one
  # transport instance must present ONE route-exchange profile and
  # exposure capability set to every member.
  # (Interfaces/MTU legitimately vary per machine — the cluster MTU is the
  # minimum across members, computed by the caller.) The `or` fallbacks
  # keep hand-built fact trees (assertion tests, older publishers)
  # evaluable.
  uniformityKey = profile:
    if profile == null
    then null
    else {
      routeExchange = profile.routeExchange or null;
      internalLoadBalancer = profile.internalLoadBalancer or false;
      nodePort = profile.nodePort or false;
    };
}
