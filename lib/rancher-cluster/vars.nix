# Distro-neutral clan vars generators for a Rancher cluster (rke2/k3s):
# join tokens, the pre-generated cluster PKI, the per-node kube-apiserver
# load balancer (haproxy) healthcheck material, the admin kubeconfig, and
# the Sealed Secrets signing keypair.
#
# Every generator is SHARED (share = true): one CA tree / token set /
# keypair per cluster instance, generated once, consumed by every member.
# Zero user input — `clan vars generate` derives everything.
#
# Role placement is the distro service's decision:
#   - tokens + haproxy material: EVERY node (agents join/serve through
#     their local haproxy; the healthcheck client cert deploys to all);
#   - PKI, admin kubeconfig, sealed-secrets keypair: servers only (the CA
#     keys never leave the control plane; the sealed-secrets key manifest
#     syncs into the server manifests dir).
#
# Naming is distro-neutral: rancher-<what>-<instance>. The PKI layout the
# certificates are synced INTO differs per distro (rke2 vs k3s tls dirs) —
# that is nixos.mkPkiSync's parameter, not the generator's.
{ lib }:
{
  # Join tokens: plain random secrets, one per role.
  mkTokenGenerators =
    { pkgs, instanceName }:
    {
      "rancher-server-token-${instanceName}" = {
        share = true;
        files.server-token = { };
        runtimeInputs = [ pkgs.openssl ];
        script = ''
          openssl rand -hex 16 > $out/server-token
        '';
      };
      "rancher-agent-token-${instanceName}" = {
        share = true;
        files.agent-token = { };
        runtimeInputs = [ pkgs.openssl ];
        script = ''
          openssl rand -hex 16 > $out/agent-token
        '';
      };
    };

  # The cluster PKI: a root CA + intermediate CA (kept out of the deployed
  # machine set — deploy = false, generator inputs only) and the leaf CAs
  # rke2/k3s consume: server, client, request-header, etcd peer, etcd
  # server, plus the service-account signing key. The leaf .crt files are
  # full chains (leaf + intermediate + root). ca-hash is the root CA's DER
  # sha256 (the K10 token pin, available for consumers that want it).
  mkPkiGenerator =
    { pkgs, instanceName }:
    {
      "rancher-pki-${instanceName}" = {
        share = true;
        files = {
          "root-ca.pem" = {
            secret = false;
            deploy = false;
          };
          "root-ca.key" = {
            secret = true;
            deploy = false;
          };
          "intermediate-ca.pem" = {
            secret = false;
            deploy = false;
          };
          "intermediate-ca.key" = {
            secret = true;
            deploy = false;
          };
          "ca-hash" = {
            secret = false;
            deploy = false;
          };
          "server-ca.crt".secret = false;
          "server-ca.key".secret = true;
          "client-ca.crt".secret = false;
          "client-ca.key".secret = true;
          "request-header-ca.crt".secret = false;
          "request-header-ca.key".secret = true;
          "etcd-peer-ca.crt".secret = false;
          "etcd-peer-ca.key".secret = true;
          "etcd-server-ca.crt".secret = false;
          "etcd-server-ca.key".secret = true;
          "service.key".secret = true;
        };
        runtimeInputs = with pkgs; [
          openssl
          coreutils
          gawk
        ];
        script = ''
          set -euo pipefail
          # Scratch inside $out: the vars executor sandbox has no writable
          # TMPDIR; the trap removes it before vars are consumed.
          WORK_DIR=$(mktemp -d "$out/.work.XXXXXXXX")
          trap 'rm -rf "$WORK_DIR"' EXIT
          mkdir -p "$WORK_DIR/certs"
          touch "$WORK_DIR/index"
          echo "01" > "$WORK_DIR/serial"
          cat > "$WORK_DIR/ca.cnf" << 'EOF'
          [ca]
          default_ca = ca_default
          [ca_default]
          dir = ./
          database = index
          serial = serial
          new_certs_dir = certs
          default_md = sha256
          policy = policy_anything
          unique_subject = no
          [policy_anything]
          commonName = supplied
          [req]
          distinguished_name = req_distinguished_name
          [req_distinguished_name]
          [v3_ca]
          subjectKeyIdentifier = hash
          authorityKeyIdentifier = keyid:always
          basicConstraints = critical, CA:true
          keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign
          EOF
          cd "$WORK_DIR"
          openssl genrsa -out "$out/service.key" 2048
          openssl genrsa -out "$out/root-ca.key" 4096
          openssl req -x509 -new -nodes -sha256 -days 7300 \
            -subj "/CN=${instanceName}-root-ca" \
            -key "$out/root-ca.key" \
            -out "$out/root-ca.pem" \
            -config ca.cnf \
            -extensions v3_ca
          openssl x509 -in "$out/root-ca.pem" -outform DER | sha256sum | cut -d' ' -f1 | tr -d '\n' > "$out/ca-hash"
          openssl genrsa -out "$out/intermediate-ca.key" 4096
          openssl req -new -nodes \
            -subj "/CN=${instanceName}-intermediate-ca" \
            -key "$out/intermediate-ca.key" | \
          openssl ca -batch -notext -days 3700 \
            -in /dev/stdin \
            -out "$out/intermediate-ca.pem" \
            -keyfile "$out/root-ca.key" \
            -cert "$out/root-ca.pem" \
            -config ca.cnf \
            -extensions v3_ca
          for TYPE in client server request-header etcd-peer etcd-server; do
            NAME="${instanceName}-''${TYPE}-ca"
            openssl ecparam -name prime256v1 -genkey -noout -out "$out/''${TYPE}-ca.key"
            openssl req -new -nodes \
              -subj "/CN=''${NAME}" \
              -key "$out/''${TYPE}-ca.key" | \
            openssl ca -batch -notext -days 3700 \
              -in /dev/stdin \
              -out "$WORK_DIR/''${TYPE}-ca.pem" \
              -keyfile "$out/intermediate-ca.key" \
              -cert "$out/intermediate-ca.pem" \
              -config ca.cnf \
              -extensions v3_ca
            cat "$WORK_DIR/''${TYPE}-ca.pem" \
                "$out/intermediate-ca.pem" \
                "$out/root-ca.pem" > "$out/''${TYPE}-ca.crt"
          done
        '';
      };
    };

  # Per-node kube-apiserver LB (haproxy) material:
  #   kubeapi-ca.crt      = the PKI's server-ca chain (public; consumed via
  #                         the store path, not deployed)
  #   kubeapi-client.pem  = the /readyz healthcheck client cert, signed by
  #                         the PKI's CLIENT ca (any authenticated user may
  #                         GET /readyz via system:public-info-viewer).
  #                         Secret — deployed 0400 owner haproxy.
  #   password-hash-haproxy = the stats-page password hash (public,
  #                         eval-consumed via getPublicValue to render the
  #                         userlist).
  mkHaproxyGenerator =
    { pkgs, instanceName }:
    {
      "rancher-haproxy-${instanceName}" = {
        share = true;
        dependencies = [ "rancher-pki-${instanceName}" ];
        files = {
          "kubeapi-ca.crt" = {
            secret = false;
            deploy = false;
          };
          "kubeapi-client.pem" = {
            owner = "haproxy";
            group = "haproxy";
            mode = "0400";
            restartUnits = [ "haproxy.service" ];
          };
          "password-hash-haproxy" = {
            secret = false;
            deploy = false;
          };
        };
        runtimeInputs = with pkgs; [
          openssl
          coreutils
        ];
        script = ''
          set -euo pipefail
          cp "$in/rancher-pki-${instanceName}/server-ca.crt" "$out/kubeapi-ca.crt"
          # Scratch inside $out: the vars executor sandbox has no writable
          # TMPDIR; the trap removes it before vars are consumed.
          WORK_DIR=$(mktemp -d "$out/.work.XXXXXXXX")
          trap 'rm -rf "$WORK_DIR"' EXIT
          openssl ecparam -name prime256v1 -genkey -noout -out "$WORK_DIR/haproxy.key"
          openssl req -new \
            -key "$WORK_DIR/haproxy.key" \
            -subj "/CN=haproxy-healthcheck" \
            -out "$WORK_DIR/haproxy.csr"
          printf "keyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n" \
            > "$WORK_DIR/ext.cnf"
          # -set_serial: -CAcreateserial would write next to the read-only
          # $in CA. Serial 3: 1/2 are taken by the admin/agent client certs
          # (the leaf client CA's serials must be unique).
          openssl x509 -req -days 3650 \
            -in "$WORK_DIR/haproxy.csr" \
            -CA "$in/rancher-pki-${instanceName}/client-ca.crt" \
            -CAkey "$in/rancher-pki-${instanceName}/client-ca.key" \
            -set_serial 3 \
            -extfile "$WORK_DIR/ext.cnf" \
            -out "$WORK_DIR/haproxy.crt"
          cat "$WORK_DIR/haproxy.crt" "$WORK_DIR/haproxy.key" > "$out/kubeapi-client.pem"
          PASSWORD=$(openssl rand -hex 16)
          echo -n "$PASSWORD" | openssl passwd -6 -stdin > "$out/password-hash-haproxy"
        '';
      };
    };

  # Admin kubeconfig: an operator client cert (CN admin, O system:masters
  # -> cluster-admin) signed by the vars client CA, with `server` as the
  # API endpoint (the distro service passes the per-node haproxy endpoint:
  # https://<kubeapi FQDN>:<kubeapi LB port>). Fully derived from the
  # rancher-pki vars — no prompts.
  mkAdminKubeconfigGenerator =
    {
      pkgs,
      instanceName,
      server,
    }:
    {
      "rancher-admin-kubeconfig-${instanceName}" = {
        share = true;
        dependencies = [ "rancher-pki-${instanceName}" ];
        files."kubeconfig.yaml" = {
          secret = true;
          deploy = true;
        };
        runtimeInputs = with pkgs; [
          openssl
          coreutils
        ];
        script = ''
          set -euo pipefail
          # Scratch inside $out: the vars executor sandbox has no writable
          # TMPDIR; the trap removes it before vars are consumed.
          WORK_DIR=$(mktemp -d "$out/.work.XXXXXXXX")
          trap 'rm -rf "$WORK_DIR"' EXIT
          openssl genrsa -out "$WORK_DIR/admin.key" 2048
          openssl req -new \
            -key "$WORK_DIR/admin.key" \
            -subj "/O=system:masters/CN=admin" \
            -out "$WORK_DIR/admin.csr"
          printf "keyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n" \
            > "$WORK_DIR/admin-ext.cnf"
          # -set_serial: -CAcreateserial would write next to the read-only
          # $in CA. Serial 1 is unique among certs from this leaf client CA
          # (serial 2 is reserved for a future reduced-RBAC agent
          # kubeconfig; 3 is the haproxy healthcheck client cert).
          openssl x509 -req -sha256 -days 3650 \
            -in "$WORK_DIR/admin.csr" \
            -CA "$in/rancher-pki-${instanceName}/client-ca.crt" \
            -CAkey "$in/rancher-pki-${instanceName}/client-ca.key" \
            -set_serial 1 \
            -extfile "$WORK_DIR/admin-ext.cnf" \
            -out "$WORK_DIR/admin.crt"
          CRT=$(base64 -w0 "$WORK_DIR/admin.crt")
          KEY=$(base64 -w0 "$WORK_DIR/admin.key")
          CA=$(base64 -w0 "$in/rancher-pki-${instanceName}/server-ca.crt")
          cat > "$out/kubeconfig.yaml" <<KUBECONFIG_EOF
          apiVersion: v1
          kind: Config
          preferences: {}
          clusters:
            - name: ${instanceName}
              cluster:
                server: ${server}
                certificate-authority-data: $CA
          users:
            - name: admin
              user:
                client-certificate-data: $CRT
                client-key-data: $KEY
          contexts:
            - name: admin@${instanceName}
              context:
                cluster: ${instanceName}
                user: admin
                namespace: default
          current-context: admin@${instanceName}
          KUBECONFIG_EOF
        '';
      };
    };

  # Sealed Secrets signing keypair, pre-generated so the cluster never
  # creates its own (key rotation / loss on reinstall). tls.crt is PUBLIC
  # plaintext (the offline sealing key — committing it is by design);
  # tls.key and the rendered Secret manifest stay secret. The manifest is
  # synced into the distro's manifests dir by nixos.mkSecretManifestSync
  # (never through the Nix store).
  mkSealedSecretsGenerator =
    {
      pkgs,
      instanceName,
      labels ? { },
    }:
    let
      labelsYaml = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "      ${k}: ${v}") (
          {
            "sealedsecrets.bitnami.com/sealed-secrets-key" = "active";
          }
          // labels
        )
      );
    in
    {
      "rancher-sealed-secrets-${instanceName}" = {
        share = true;
        files = {
          "sealed-secrets-key.yaml" = {
            secret = true;
          };
          "tls.key" = {
            secret = true;
            deploy = false;
          };
          "tls.crt" = {
            secret = false;
            deploy = false;
          };
        };
        runtimeInputs = [ pkgs.openssl ];
        script = ''
          openssl genrsa -traditional -out $out/tls.key 4096
          openssl req -new -x509 -days 36500 -key $out/tls.key -out $out/tls.crt -subj "/CN=sealed-secrets-key"
          CRT=$(base64 -w0 $out/tls.crt)
          KEY=$(base64 -w0 $out/tls.key)
          cat > $out/sealed-secrets-key.yaml <<SEALED_SECRETS_EOF
          apiVersion: v1
          kind: Secret
          metadata:
            name: sealed-secrets-key
            namespace: kube-system
            labels:
          ${labelsYaml}
          type: kubernetes.io/tls
          data:
            tls.crt: $CRT
            tls.key: $KEY
          SEALED_SECRETS_EOF
        '';
      };
    };
}
