{lib, ...}: let
  t = lib.types;
in {
  options = {
    schemaVersion = lib.mkOption {
      type = t.ints.positive;
      default = 2;
      description = "Node transport schema version; version 2 is the generic neutral transport seam (SPEC.md D58).";
    };
    ipv4 = lib.mkOption {
      type = t.nullOr t.str;
      default = null;
      description = "Stable dual-stack node IPv4 address on the transport.";
    };
    ipv6 = lib.mkOption {
      type = t.nullOr t.str;
      default = null;
      description = "Stable dual-stack node IPv6 address on the transport.";
    };
    instance = lib.mkOption {
      type = t.nullOr t.str;
      default = null;
      description = "Transport instance (trust domain) name.";
    };
    asn = lib.mkOption {
      type = t.nullOr t.ints.u32;
      default = null;
      description = "Allocated host routing ASN for the local-router profile; null on tunnel transports.";
    };
    endpoint = lib.mkOption {
      type = t.nullOr t.str;
      default = null;
      description = "Reachable transport endpoint (host and port) when one exists; null is outbound-only or unknown.";
    };
    port = lib.mkOption {
      type = t.nullOr t.port;
      default = null;
      description = "Base transport UDP port.";
    };
    interfaces = lib.mkOption {
      type = t.attrsOf (
        t.submodule {
          options = {
            mtu = lib.mkOption {
              type = t.ints.unsigned;
              default = 0;
              description = "Effective MTU of this datapath interface; zero is the deep-eval default and is rejected by consumers.";
            };
          };
        }
      );
      default = {};
      description = "Every datapath interface keyed by its actual Linux interface name, each with its MTU.";
    };
    directRoutingDevice = lib.mkOption {
      type = t.str;
      default = "";
      description = "Exactly one direct-routing device, naming one of the exported interfaces; empty is the deep-eval default.";
    };
    datapath = {
      mode = lib.mkOption {
        type = t.enum [
          ""
          "native"
          "tunnel"
        ];
        default = "";
        description = "Datapath mode: native routing or tunnel; empty is the deep-eval default.";
      };
      tunnelProtocol = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "Tunnel protocol for tunnel mode; the schema is open, while consumers reject protocols without a validated implementation.";
      };
    };
    native = {
      routeExchange = lib.mkOption {
        type = t.nullOr t.str;
        default = null;
        description = "Daemon-neutral route-exchange profile on native transports; the schema is open, while consumers reject profiles without a validated implementation.";
      };
    };
    internalLoadBalancer = lib.mkOption {
      type = t.bool;
      default = false;
      description = "Whether the transport exposes the internal LoadBalancer capability.";
    };
    nodePort = lib.mkOption {
      type = t.bool;
      default = false;
      description = "Whether the transport exposes the NodePort capability.";
    };
  };
}
