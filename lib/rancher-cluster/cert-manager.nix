{ lib }:
{
  mkCertManagerManifests =
    {
      settings,
      domain,
      manifestLabels,
    }:
    lib.optionals settings.certManager.enabled (
      [
        {
          apiVersion = "cert-manager.io/v1";
          kind = "ClusterIssuer";
          metadata = {
            name = "selfsigned";
            inherit manifestLabels;
          };
          spec.selfSigned = { };
        }
        {
          apiVersion = "cert-manager.io/v1";
          kind = "Certificate";
          metadata = {
            name = "rancher-ca";
            namespace = "kube-system";
            inherit manifestLabels;
          };
          spec = {
            isCA = true;
            commonName = "rancher-ca.${domain}";
            secretName = "rancher-ca";
            privateKey = {
              algorithm = "ECDSA";
              size = 256;
            };
            duration = "87600h";
            issuerRef = {
              name = "selfsigned";
              kind = "ClusterIssuer";
              group = "cert-manager.io";
            };
          };
        }
        {
          apiVersion = "cert-manager.io/v1";
          kind = "ClusterIssuer";
          metadata = {
            name = "rancher-ca";
            inherit manifestLabels;
          };
          spec.ca.secretName = "rancher-ca";
        }
      ]
      ++ map (c: {
        apiVersion = "cert-manager.io/v1";
        kind = "Certificate";
        metadata = {
          name = c.secretName;
          namespace = "kube-system";
          inherit manifestLabels;
        };
        spec = {
          inherit (c) secretName dnsNames;
          issuerRef = {
            inherit (c.issuer) name;
            kind = if c.issuer.kind == "cluster-issuer" then "ClusterIssuer" else "Issuer";
            group = "cert-manager.io";
          };
        }
        // lib.optionalAttrs (c.renewBefore != null) {
          inherit (c) renewBefore;
        };
      }) settings.certManager.certificates
    );
}
