{ lib }:
{
  mkCoreDNSValues =
    {
      settings,
    }:
    lib.recursiveUpdate (lib.optionalAttrs (settings.coredns.rewrites != [ ]) {
      extraVolumes = [
        {
          name = "custom-config-volume";
          configMap = {
            name = "coredns-custom";
            optional = true;
            defaultMode = 420;
          };
        }
      ];
      extraVolumeMounts = [
        {
          name = "custom-config-volume";
          mountPath = "/etc/coredns/custom";
          readOnly = true;
        }
      ];
      extraConfig.import.parameters = "/etc/coredns/custom/*.server";
      servers = [
        {
          zones = [
            {
              zone = ".";
              use_tcp = true;
            }
          ];
          port = 53;
          plugins = [
            { name = "errors"; }
            {
              name = "health";
              configBlock = "lameduck 10s";
            }
            { name = "ready"; }
            {
              name = "kubernetes";
              parameters = "in-addr.arpa ip6.arpa";
              configBlock = "pods insecure\nfallthrough in-addr.arpa ip6.arpa\nttl 30";
            }
            {
              name = "prometheus";
              parameters = "0.0.0.0:9153";
            }
            {
              name = "import";
              parameters = "/etc/coredns/custom/*.override";
            }
            {
              name = "forward";
              parameters = ". /etc/resolv.conf";
            }
            {
              name = "cache";
              parameters = "30";
            }
            { name = "loop"; }
            { name = "reload"; }
            { name = "loadbalance"; }
          ];
        }
      ];
    }) settings.coredns.helmValues;

  mkCoreDNSManifests =
    {
      settings,
      instanceName,
      manifestLabels,
    }:
    lib.optionalAttrs (settings.coredns.rewrites != [ ]) {
      coredns-custom = {
        enable = true;
        content = {
          apiVersion = "v1";
          kind = "ConfigMap";
          metadata = {
            name = "coredns-custom";
            namespace = "kube-system";
            inherit manifestLabels;
          };
          data."${instanceName}.override" = lib.concatStringsSep "\n" (
            map (r: "rewrite ${r}") settings.coredns.rewrites
          );
        };
      };
    };
}
