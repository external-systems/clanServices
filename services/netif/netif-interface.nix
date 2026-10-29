# Export interface `netif`: the resolved underlay facts one netif
# instance gives a machine (D53). Consumed by routed-fabric for adjacency
# endpoint selection and WireGuard MTU derivation, and (planned, D57) by
# the per-node `clan.networkFacts` underlay graph.
#
# Declared here and registered via `clan.exportInterfaces.netif` so every
# clan context (flake-module, eval tests, consumers) shares one schema.
# Every leaf has a safe default: the clan CLI deep-evaluates exports
# during `clan machines install/update`, and an undefined leaf would fail
# there with "accessed but has no value defined".
{lib, ...}: let
  inherit (lib) mkOption types;
in {
  options = {
    schemaVersion = mkOption {
      type = types.int;
      default = 1;
      description = "Schema version of this export; bumped on breaking changes.";
    };
    endpoint = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        The machine's resolved deploy/fabric endpoint (explicit
        'endpoint', then 'endpointSources', then null). This is the
        address routed-fabric dials for WireGuard adjacencies when no
        per-adjacency override exists.
      '';
    };
    mtu = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        Effective underlay MTU: the smallest resolved per-link MTU of
        this instance (null when no link sets an MTU). Consumers derive
        transport MTUs from it (WireGuard: underlay minus overhead).
      '';
    };
    links = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            kind = mkOption {
              type = types.str;
              default = "";
              description = "Resolved link kind: physical, vlan, bond, or bridge.";
            };
            interface = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Resolved interface name (netdev name for vlan/bond/bridge).";
            };
            mtu = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "Effective link MTU (segment default merged).";
            };
            addresses = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Static addresses with prefix lengths (IPv4 then IPv6 as declared).";
            };
            dhcp4 = mkOption {
              type = types.bool;
              default = false;
              description = "DHCPv4 addressing mode.";
            };
            dhcp6 = mkOption {
              type = types.bool;
              default = false;
              description = "DHCPv6 addressing mode.";
            };
            ra = mkOption {
              type = types.bool;
              default = true;
              description = "IPv6 router-advertisement acceptance.";
            };
            gateway4 = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Effective IPv4 default gateway (segment default merged).";
            };
            gateway6 = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Effective IPv6 default gateway (segment default merged).";
            };
            gatewayInMain = mkOption {
              type = types.bool;
              default = false;
              description = ''
                True when this link renders a default route into the main
                routing table (DHCP lease default, or a static gateway
                without policy routing). At most one link per machine has
                this set (D53).
              '';
            };
            nameservers = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Effective DNS servers for this link (segment default merged).";
            };
            routes = mkOption {
              type = types.listOf (
                types.submodule {
                  options = {
                    destination = mkOption {
                      type = types.str;
                      default = "";
                      description = "Route destination CIDR.";
                    };
                    gateway = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "Route gateway (null for a directly connected route).";
                    };
                    onLink = mkOption {
                      type = types.bool;
                      default = false;
                      description = "The route gateway is rendered on-link.";
                    };
                  };
                }
              );
              default = [];
              description = "Static routes rendered on this link.";
            };
            endpoint = mkOption {
              type = types.bool;
              default = false;
              description = "This link's static addresses are exported as peer hosts.";
            };
          };
        }
      );
      default = {};
      description = "Resolved links keyed by their logical per-machine name.";
    };
  };
}
