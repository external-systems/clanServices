{
  config,
  lib,
  ...
}: let
  t = lib.types;
  schema = readOnly: let
    fact = type: default: description:
      lib.mkOption {
        inherit
          type
          default
          description
          readOnly
          ;
      };
    str = fact t.str "";
    strList = fact (t.listOf t.str) [];
    nullableStr = fact (t.nullOr t.str) null;
    nullableInt = fact (t.nullOr t.int) null;
    bool = fact t.bool false;
    attrs = fact (t.attrsOf t.anything) {};
    edge = t.submodule {
      options = {
        from = str "Source node or cluster name.";
        to = str "Destination node or cluster name.";
        kind = str "Declared relationship kind.";
      };
    };
    graph = fact (t.listOf edge) [];
    adjacency = t.submodule {
      options = {
        interface = str "Point-to-point WireGuard interface name.";
        remote = str "Remote machine name.";
        ipv4 = nullableStr "Local transfer IPv4 address.";
        ipv6 = nullableStr "Local transfer IPv6 address.";
        prefix4 = str "Transfer IPv4 prefix.";
        prefix6 = str "Transfer IPv6 prefix.";
        port = nullableInt "Local UDP listen port.";
        mtu = nullableInt "Derived WireGuard MTU.";
        endpoint = nullableStr "Remote public endpoint when declared; null means outbound-only or unknown.";
        allowedIPs = strList "WireGuard crypto ACL derived from the route policy.";
        externalTransit = bool "Whether default entries are allowed only as a crypto ACL.";
        sourceReturn = bool "Whether a separate source-return policy table is declared.";
      };
    };
    link = t.submodule {
      options = {
        kind = str "Physical, VLAN, bond, or bridge.";
        interface = nullableStr "Resolved interface name.";
        mtu = nullableInt "Declared effective MTU.";
        addresses = strList "Declared static addresses; dynamic addresses are not invented.";
        dhcp4 = bool "Whether DHCPv4 is declared.";
        dhcp6 = bool "Whether DHCPv6 is declared.";
        ra = fact t.bool true "Whether IPv6 router advertisements are accepted.";
        gateway4 = nullableStr "Declared IPv4 gateway.";
        gateway6 = nullableStr "Declared IPv6 gateway.";
        gatewayInMain = bool "Whether this link declares a main-table default route.";
        nameservers = strList "Declared DNS servers.";
        routes = fact (t.listOf t.attrs) [] "Declared static route objects.";
        routingPolicy = attrs "Declared underlay policy-routing intent.";
        trusted = bool "Whether the link is firewall-trusted.";
        endpoint = bool "Whether static addresses are exported as peer endpoints.";
      };
    };
  in {
    schemaVersion = fact t.ints.positive 2 "Network facts schema version.";
    node = {
      name = str "Clan machine identity.";
    };
    netif = lib.mkOption {
      type = t.attrsOf (
        t.submodule {
          options = {
            endpoint = nullableStr "Resolved deploy or fabric endpoint when declared.";
            mtu = nullableInt "Smallest declared underlay MTU in this instance.";
            links = lib.mkOption {
              type = t.attrsOf link;
              default = {};
              inherit readOnly;
              description = "Declared underlay links keyed by logical name.";
            };
          };
        }
      );
      default = {};
      inherit readOnly;
      description = "Declared netif instances and their underlay attachments.";
    };
    fabric = lib.mkOption {
      type = t.attrsOf (
        t.submodule {
          options = {
            topology = str "Leaf or spine topology role.";
            access = str "Member, client, or admin route-consumption access.";
            asn = nullableInt "Deterministic private node ASN.";
            ipv4 = nullableStr "Stable fabric IPv4 address.";
            ipv6 = nullableStr "Stable fabric IPv6 address.";
            loopback = str "Stable-address dummy interface.";
            border = {
              enabled = bool "Whether external transit is declared.";
              ownedPrefixes = strList "Authorized external/fabric prefixes.";
              upstreamPeers = fact (t.listOf t.attrs) [] "Declared external BGP peers.";
              ndpInterfaces = strList "Interfaces with declared proxy-NDP intent.";
            };
            adjacencies = lib.mkOption {
              type = t.attrsOf adjacency;
              default = {};
              inherit readOnly;
              description = "Declared routed adjacencies keyed by remote machine.";
            };
          };
        }
      );
      default = {};
      inherit readOnly;
      description = "Declared routed-fabric memberships and adjacencies.";
    };
    clusters = lib.mkOption {
      type = t.attrsOf (
        t.submodule {
          options = {
            distro = str "k3s or rke2.";
            ciliumId = nullableInt "Resolved Cilium cluster identity.";
            podCIDRv4 = nullableStr "Declared IPv4 pod CIDR.";
            podCIDRv6 = nullableStr "Declared IPv6 pod CIDR.";
            serviceCIDRv4 = nullableStr "Declared IPv4 Service CIDR.";
            serviceCIDRv6 = nullableStr "Declared IPv6 Service CIDR.";
            clusterDNS = nullableStr "Declared cluster DNS address.";
            fabric = {
              service = nullableStr "Fabric service name.";
              instance = nullableStr "Fabric instance and trust-domain name.";
            };
            nodeIPAM = fact t.bool true "Whether classless LoadBalancer Services use Node IPAM.";
            pools = attrs "Declared pool scope, delivery, owner, blocks, and selectors.";
            meshPeers =
              fact (t.nullOr (
                t.listOf t.str
              ))
              null "Explicit symmetric mesh peers, or null for full peering.";
            controlDomain = {
              role = str "Standalone, hub, or spoke control-domain role.";
            };
            api = {
              endpoints = strList "Declared API transport endpoints.";
              mirror = nullableStr "Declared API mirror Service name when exported.";
            };
          };
        }
      );
      default = {};
      inherit readOnly;
      description = "Declared Kubernetes cluster and native datapath facts.";
    };
    graphs = {
      underlay = graph "Declared netif underlay edges.";
      fabric = graph "Declared routed-fabric adjacency edges.";
      clusterMesh = graph "Declared ClusterMesh peering edges.";
      controlDomain = graph "Declared GitOps control-domain edges.";
    };
  };
in {
  options.clan = {
    _networkFacts = schema false;
    networkFacts = lib.mkOption {
      type = t.submodule {options = schema false;};
      default = config.clan._networkFacts;
      readOnly = true;
      description = "Read-only, non-secret projection of declared build-time networking facts.";
    };
  };
}
