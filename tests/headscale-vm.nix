# An offline Headscale for VM suites that prove Tailscale beside netif
# (specs/netif.md N6, N11). `name` is the control server's node name:
# clients log in with `tailscale up --login-server https://<name>`.
{name ? "headscale"}: let
  certs = pkgs:
    pkgs.runCommand "headscale-test-certs" {nativeBuildInputs = [pkgs.openssl];} ''
      openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
        -out cert.pem -keyout key.pem -subj '/CN=${name}' \
        -addext "subjectAltName=DNS:${name}"
      mkdir -p $out
      cp key.pem cert.pem $out
    '';
in {
  # The control server: Headscale behind nginx with a self-signed
  # certificate, and its own DERP relay.
  server = {pkgs, ...}: {
    environment.systemPackages = [pkgs.headscale];
    services = {
      headscale = {
        enable = true;
        port = 8080;
        settings = {
          server_url = "https://${name}";
          ip_prefixes = ["100.64.0.0/10"];
          derp = {
            server = {
              enabled = true;
              region_id = 999;
              stun_listen_addr = "0.0.0.0:3478";
            };
            urls = [];
          };
          dns = {
            base_domain = "tailnet";
            override_local_dns = false;
          };
        };
      };
      nginx = {
        enable = true;
        virtualHosts.${name} = {
          addSSL = true;
          sslCertificate = "${certs pkgs}/cert.pem";
          sslCertificateKey = "${certs pkgs}/key.pem";
          locations."/" = {
            proxyPass = "http://127.0.0.1:8080";
            proxyWebsockets = true;
          };
        };
      };
    };
  };

  # A machine that logs in to it trusts its certificate.
  client = {pkgs, ...}: {
    security.pki.certificateFiles = ["${certs pkgs}/cert.pem"];
  };
}
