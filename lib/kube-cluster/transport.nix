# The generic node_transport consumer (SPEC.md D58). k3s/rke2 (and this
# shared lib) consume ONLY the neutral schemaVersion 2 `node_transport`
# export — never provider service names or provider-specific exports.
# This module validates the transport profile and derives the
# Cilium-facing facts:
#
#   native transports (routed-fabric)  → routing-mode native, no tunnel,
#     native.routeExchange = local-router, MTU = min interface MTU
#   tunnel transports (wireguard-mesh) → routing-mode tunnel,
#     datapath.tunnelProtocol = vxlan, MTU = min interface MTU minus 50
#
# Unsupported profiles (unknown mode/protocol/route exchange, empty
# interface set, directRoutingDevice not naming an exported interface,
# schemaVersion != 2) throw at eval — the schema is open but only validated
# profiles are consumable until implemented and tested (D58).
{ lib }:
let
  inherit (builtins) attrNames;

  minOf = xs: lib.foldl' lib.min 65535 xs;

  sorted = lib.sort builtins.lessThan;
in
rec {
  # Validate one machine's node_transport export and derive the facts.
  # transport: the export value (node_transport subtree), or null.
  resolve =
    {
      instanceName,
      machineName,
      transport,
    }:
    if transport == null then
      null
    else
      let
        who = "kube-cluster/${instanceName}/${machineName}";

        version = transport.schemaVersion or 0;
        interfaces = transport.interfaces or { };
        ifaceNames = attrNames interfaces;
        mtuOf = name: interfaces.${name}.mtu or 0;
        mtus = map mtuOf ifaceNames;
        mode = transport.datapath.mode or "";
        tunnelProtocol = transport.datapath.tunnelProtocol or null;
        routeExchange = transport.native.routeExchange or null;
        directRoutingDevice = transport.directRoutingDevice or "";
        minMtu = minOf mtus;

        problems = lib.concatStringsSep "; " (
          lib.optional (
            version != 2
          ) "unsupported node_transport schemaVersion ${toString version} (only 2 is consumable, D58)"
          ++ lib.optional (ifaceNames == [ ]) "no datapath interfaces exported"
          ++ lib.optional (
            mtus == [ ] || lib.any (m: !(m > 0)) mtus
          ) "every exported interface needs a positive MTU"
          ++ lib.optional (
            !(lib.elem mode [
              "native"
              "tunnel"
            ])
          ) "unsupported datapath mode '${mode}' (native | tunnel)"
          ++ lib.optional (
            mode == "native" && tunnelProtocol != null
          ) "native transports must not set datapath.tunnelProtocol"
          ++
            lib.optional (mode == "native" && routeExchange != "local-router")
              "unsupported native.routeExchange ${builtins.toJSON routeExchange} (only local-router is implemented, D58)"
          ++ lib.optional (
            mode == "tunnel" && tunnelProtocol != "vxlan"
          ) "unsupported tunnel protocol ${builtins.toJSON tunnelProtocol} (only vxlan is implemented, D58)"
          ++ lib.optional (
            mode == "tunnel" && routeExchange != null
          ) "tunnel transports must not set native.routeExchange"
          ++
            lib.optional (!(lib.elem directRoutingDevice ifaceNames))
              "directRoutingDevice '${directRoutingDevice}' does not name an exported interface (${lib.concatStringsSep ", " ifaceNames})"
          ++ lib.optional (
            minMtu <= 50 && mode == "tunnel"
          ) "VXLAN MTU derivation underflows (min interface MTU ${toString minMtu} - 50 <= 0)"
        );
      in
      if problems != "" then
        throw "${who}: unsupported node_transport profile: ${problems}"
      else
        {
          inherit
            mode
            tunnelProtocol
            routeExchange
            directRoutingDevice
            minMtu
            ;
          nativeRouting = mode == "native";
          # Cilium MTU: native uses the minimum interface MTU directly;
          # VXLAN tunnel mode subtracts 50 (D58, invariant 21).
          mtu = if mode == "tunnel" then minMtu - 50 else minMtu;
          interfaces = sorted ifaceNames;
          endpoint = transport.endpoint or null;
          port = transport.port or null;
          instance = transport.instance or null;
          inherit (transport) ipv4 ipv6;
          internalLoadBalancer = transport.internalLoadBalancer or false;
          nodePort = transport.nodePort or false;
        };

  # The Cilium devices string (space-separated, unique). Supersets are
  # allowed post-merge (extra NICs for VIP ingress); dropping a transport
  # device contradicts the transport and is rejected post-merge.
  devicesString = profile: lib.concatStringsSep " " (lib.unique profile.interfaces);

  # The cluster-uniform projection of a transport profile (D58): one
  # transport instance must present ONE datapath mode, tunnel protocol,
  # route-exchange profile and exposure capability set to every member.
  # (Interfaces/MTU legitimately vary per machine — the cluster MTU is the
  # minimum across members, computed by the caller.) The `or` fallbacks
  # keep hand-built fact trees (assertion tests, older publishers)
  # evaluable.
  uniformityKey =
    profile:
    if profile == null then
      null
    else
      {
        mode = profile.mode or null;
        tunnelProtocol = profile.tunnelProtocol or null;
        routeExchange = profile.routeExchange or null;
        internalLoadBalancer = profile.internalLoadBalancer or false;
        nodePort = profile.nodePort or false;
      };
}
