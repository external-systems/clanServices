# The data-plane suite's workload and pools that do not depend on BGP:
# the go-httpbin image and Deployment, the floating and dataplane pools.
# BGP-delivered Services and pools (shared-bgp, node-bgp) live in
# data-plane.nix (SPEC.md D8). Native routing on routed-fabric only
# (D72).
{
  lib,
  inputs,
  distro,
}: let
  kube = import ../../../../lib/kube-cluster {inherit lib;};
  httpbinVersions = import (inputs.org-pkgs + "/pkgs/go-httpbin/versions.nix");
  dualStack = {
    ipFamilies = [
      "IPv4"
      "IPv6"
    ];
    ipFamilyPolicy = "RequireDualStack";
  };
in rec {
  httpbinImageRef = "go-httpbin:v${httpbinVersions.version}";
  httpbinImage = inputs.org-pkgs.packages.x86_64-linux.image-go-httpbin;
  # RKE2's runtime-image loader scans the top level of the images dir, so
  # RKE2 nodes add the top-level symlink (same pattern as rke2-single).
  rke2ImageLink = image: "L+ /var/lib/rancher/rke2/agent/images/${builtins.unsafeDiscardStringContext (baseNameOf image)} - - - - ${image}";

  manifestLabels = kube.render.mkManifestLabels {
    instanceName = distro;
    component = "data-plane-test";
  };

  # go-httpbin everywhere (DaemonSet) for the pool services.
  httpbinDaemonSet = {
    apiVersion = "apps/v1";
    kind = "DaemonSet";
    metadata.name = "httpbin";
    spec = {
      selector.matchLabels.app = "httpbin";
      template = {
        metadata.labels.app = "httpbin";
        spec.containers = [
          {
            name = "httpbin";
            image = httpbinImageRef;
            ports = [
              {
                name = "http";
                containerPort = 8080;
              }
            ];
          }
        ];
      };
    };
  };

  # Pool-allocation probe via the lib's LB Service helper (invariants 5/6:
  # ETP Local + io.cilium/bgp-control-plane pinned automatically).
  poolService = kube.render.mkLBService {
    name = "httpbin-pool";
    inherit manifestLabels;
    labels."clan.lol/pool" = "dataplane";
    ports = [
      {
        port = 80;
        targetPort = 8080;
      }
    ];
    selector.app = "httpbin";
    extraSpec = dualStack;
  };

  # The floating-pool probe (D8): allocated from the floating pool (class
  # io.cilium/bgp-control-plane — never BGP-advertised). With no runtime controller
  # in the VM, the test places the VIP on beta by hand and documents the
  # blackhole window when beta dies.
  floatService = kube.render.mkLBService {
    name = "httpbin-float";
    inherit manifestLabels;
    labels."clan.lol/pool" = "floaty";
    annotations."lbipam.cilium.io/ips" = "192.0.2.100,fd20:db8:1::100";
    ports = [
      {
        port = 82;
        targetPort = 8080;
      }
    ];
    selector.app = "httpbin";
    extraSpec = dualStack;
  };

  # The classless probe: backend pinned to beta only — Node IPAM must
  # advertise ONLY beta's addresses (ETP-Local candidate restriction).
  httpbinPinned = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata.name = "httpbin-pinned";
    spec = {
      replicas = 1;
      selector.matchLabels.app = "httpbin-pinned";
      template = {
        metadata.labels.app = "httpbin-pinned";
        spec = {
          nodeSelector."kubernetes.io/hostname" = "beta";
          containers = [
            {
              name = "httpbin";
              image = httpbinImageRef;
              ports = [
                {
                  name = "http";
                  containerPort = 8080;
                }
              ];
            }
          ];
        };
      };
    };
  };

  # Classless (no loadBalancerClass) ⇒ Node IPAM (D41). Not via the lib
  # helper — that one pins the pool class by design.
  classlessService = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "httpbin-nodeipam";
      labels = manifestLabels;
    };
    spec =
      {
        type = "LoadBalancer";
        externalTrafficPolicy = "Local";
        selector.app = "httpbin-pinned";
        ports = [
          {
            port = 81;
            targetPort = 8080;
          }
        ];
      }
      // dualStack;
  };

  pools = {
    # external-class needs no delivery machinery for an allocation proof.
    dataplane = {
      blocks = [
        "192.0.2.240/28"
        "fd20:db8::/120"
      ];
      serviceSelector."clan.lol/pool" = "dataplane";
      delivery = "external-class";
    };
    # No runtime controller: the VM proves the floating blackhole window.
    floaty = {
      blocks = [
        "192.0.2.96/28"
        "fd20:db8:1::/112"
      ];
      serviceSelector."clan.lol/pool" = "floaty";
      delivery = "floating";
      candidates = [
        "alpha"
        "beta"
      ];
    };
  };
}
