{lib, ...}: let
  t = lib.types;
in {
  options = {
    schemaVersion = lib.mkOption {
      type = t.ints.positive;
      default = 2;
      description = "routed_fabric export schema version; version 2 is the leaf/spine topology (SPEC.md D59).";
    };
    asn = lib.mkOption {
      type = t.nullOr t.ints.positive;
      default = null;
      description = "Deterministic private 32-bit node ASN.";
    };
    ipv4 = lib.mkOption {
      type = t.nullOr t.str;
      default = null;
      description = "Stable fabric IPv4 address.";
    };
    ipv6 = lib.mkOption {
      type = t.nullOr t.str;
      default = null;
      description = "Stable fabric IPv6 address.";
    };
    topology = lib.mkOption {
      type = t.enum [
        "leaf"
        "spine"
        ""
      ];
      default = "";
      description = "Topology role; empty is the deep-eval default.";
    };
    access = lib.mkOption {
      type = t.enum [
        "member"
        "client"
        "admin"
      ];
      default = "member";
      description = "Route-consumption access level.";
    };
    border = {
      enabled = lib.mkOption {
        type = t.bool;
        default = false;
        description = "Whether external transit is configured.";
      };
      ownedPrefixes = lib.mkOption {
        type = t.listOf t.str;
        default = [];
        description = "Prefixes authorized for external transit.";
      };
    };
    loopback = lib.mkOption {
      type = t.str;
      default = "";
      description = "Stable-address dummy interface name.";
    };
    adjacencies = lib.mkOption {
      type = t.attrsOf (
        t.submodule {
          options = {
            name = lib.mkOption {
              type = t.str;
              default = "";
              description = "Point-to-point WireGuard interface name.";
            };
            ipv4 = lib.mkOption {
              type = t.nullOr t.str;
              default = null;
              description = "Local transfer IPv4 address.";
            };
            ipv6 = lib.mkOption {
              type = t.nullOr t.str;
              default = null;
              description = "Local transfer IPv6 address.";
            };
            port = lib.mkOption {
              type = t.nullOr t.port;
              default = null;
              description = "UDP listen port.";
            };
            mtu = lib.mkOption {
              type = t.nullOr t.ints.positive;
              default = null;
              description = "Derived WireGuard MTU.";
            };
            timerProfile = lib.mkOption {
              type = t.enum [
                "site"
                "wan"
                ""
              ];
              default = "";
              description = "Symmetric FRR stability profile for this adjacency.";
            };
            endpoint = lib.mkOption {
              type = t.nullOr t.str;
              default = null;
              description = "Remote endpoint when reachable.";
            };
            allowedIPs = lib.mkOption {
              type = t.listOf t.str;
              default = [];
              description = "WireGuard crypto ACL derived from route policy.";
            };
            prefixes = {
              ipv4 = lib.mkOption {
                type = t.str;
                default = "";
                description = "Transfer IPv4 /31 prefix.";
              };
              ipv6 = lib.mkOption {
                type = t.str;
                default = "";
                description = "Transfer IPv6 /127 prefix.";
              };
            };
          };
        }
      );
      default = {};
      description = "Resolved per-remote adjacency facts keyed by remote machine.";
    };
  };
}
