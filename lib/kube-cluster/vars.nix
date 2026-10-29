# Distro-neutral clan vars generators for a Kubernetes cluster (rke2/k3s):
# join tokens, the pre-generated cluster PKI, the per-node kube-apiserver
# load balancer (haproxy) healthcheck material, and the admin kubeconfig.
# Bootstrap plane only (SPEC.md D35): no application-plane secrets.
#
# Every generator is SHARED (share = true): one CA tree / token set per
# cluster instance, generated once, consumed by every member.
# Zero user input — `clan vars generate` derives everything.
#
# Role placement is the distro service's decision:
#   - tokens + haproxy material: EVERY node (agents join/serve through
#     their local haproxy; the healthcheck client cert deploys to all);
#   - PKI, admin kubeconfig: servers only (the CA keys never leave the
#     control plane).
#
# Naming is distro-neutral: rancher-<what>-<instance>. The PKI layout the
# certificates are synced INTO differs per distro (rke2 vs k3s tls dirs) —
# that is nixos.mkPkiSync's parameter, not the generator's.
{lib}: {
  # Join tokens: plain random secrets, one per role.
  mkTokenGenerators = {
    pkgs,
    instanceName,
  }: {
    "rancher-server-token-${instanceName}" = {
      share = true;
      files.server-token = {};
      runtimeInputs = [pkgs.openssl];
      script = ''
        openssl rand -hex 16 > $out/server-token
      '';
    };
    "rancher-agent-token-${instanceName}" = {
      share = true;
      files.agent-token = {};
      runtimeInputs = [pkgs.openssl];
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
  mkPkiGenerator = {
    pkgs,
    instanceName,
  }: {
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
  mkHaproxyGenerator = {
    pkgs,
    instanceName,
  }: {
    "rancher-haproxy-${instanceName}" = {
      share = true;
      dependencies = ["rancher-pki-${instanceName}"];
      files = {
        "kubeapi-ca.crt" = {
          secret = false;
          deploy = false;
        };
        "kubeapi-client.pem" = {
          owner = "haproxy";
          group = "haproxy";
          mode = "0400";
          restartUnits = ["haproxy.service"];
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

  # ClusterMesh mTLS material (D60): ONE shared CA per mesh group
  # (share = true across the group; the generator name carries the group so
  # same-group instances merge the identical definition) and per-cluster
  # dependent leaf certs. The etcdinit's user/role scheme pins the client
  # CNs: remote-<cluster> (the user every PEER dials with, authorized by
  # the peer's clustermesh-remote-users entry), local-<cluster> (the local
  # agents/kvstoremesh reader), admin-<cluster> (root role).
  #
  # SANs are eval-computed (every exported member address + the published
  # endpoint set + the fan-in name + the external dnsName): the endpoint
  # set is a public validation input — membership/placement changes re-run
  # `clan vars generate` before advertise. CA/cert material never reaches
  # exports, helm, or the Nix store: only the CA key stays deploy = false;
  # the clusterInit node's secrets-apply oneshot reads leaf runtime paths.
  mkMeshCaGenerator = {
    pkgs,
    group,
  }: {
    "rancher-clustermesh-ca-${group}" = {
      share = true;
      files = {
        "ca.crt" = {
          secret = false;
          deploy = false;
        };
        "ca.key" = {
          secret = true;
          deploy = false;
        };
      };
      runtimeInputs = [pkgs.openssl];
      script = ''
        openssl genrsa -out "$out/ca.key" 4096
        openssl req -x509 -new -nodes -sha256 -days 3650 \
          -subj "/CN=clustermesh-${group}-ca" \
          -key "$out/ca.key" \
          -out "$out/ca.crt" \
          -addext "basicConstraints=critical,CA:true" \
          -addext "keyUsage=critical,keyCertSign,cRLSign"
      '';
    };
  };

  # The per-cluster leaf set: server (etcd/apiserver serverAuth, the SANs),
  # remote/local/admin (etcd clientAuth CNs — see above).
  mkMeshCertGenerator = {
    pkgs,
    instanceName,
    group,
    # { dns = [ ... ]; ip = [ ... ] } — eval-computed SANs (D60).
    sans,
  }: let
    sanLine = lib.optionalString (sans.ip != [] || sans.dns != []) (
      lib.concatStringsSep "," (map (ip: "IP:${ip}") sans.ip ++ map (d: "DNS:${d}") sans.dns)
    );
    leaves = [
      {
        name = "server";
        cn = "${instanceName}-clustermesh-server";
        usage = "serverAuth";
      }
      {
        name = "remote";
        cn = "remote-${instanceName}";
        usage = "clientAuth";
      }
      {
        name = "local";
        cn = "local-${instanceName}";
        usage = "clientAuth";
      }
      {
        name = "admin";
        cn = "admin-${instanceName}";
        usage = "clientAuth";
      }
    ];
  in {
    "rancher-clustermesh-${instanceName}" = {
      share = true;
      dependencies = ["rancher-clustermesh-ca-${group}"];
      validation.endpoints = builtins.toJSON sans;
      files = lib.listToAttrs (
        lib.concatMap (l: [
          {
            name = "${l.name}.crt";
            value.secret = false;
          }
          {
            name = "${l.name}.key";
            value.secret = true;
          }
        ])
        leaves
        ++ [
          {
            name = "ca.crt";
            value.secret = false;
          }
        ]
      );
      runtimeInputs = with pkgs; [
        openssl
        coreutils
      ];
      script = ''
        set -euo pipefail
        WORK_DIR=$(mktemp -d "$out/.work.XXXXXXXX")
        trap 'rm -rf "$WORK_DIR"' EXIT
        cp "$in/rancher-clustermesh-ca-${group}/ca.crt" "$out/ca.crt"
        ${lib.concatMapStringsSep "\n" (l: ''
            openssl ecparam -name prime256v1 -genkey -noout -out "$out/${l.name}.key"
            openssl req -new \
              -key "$out/${l.name}.key" \
              -subj "/CN=${l.cn}" \
              -out "$WORK_DIR/${l.name}.csr"
            {
              echo "basicConstraints=CA:false"
              echo "keyUsage=digitalSignature,keyEncipherment"
              echo "extendedKeyUsage=${l.usage}"
              ${lib.optionalString (sanLine != "" && l.name == "server") ''
              echo "subjectAltName=${sanLine}"
            ''}
            } > "$WORK_DIR/${l.name}.ext"
            openssl x509 -req -sha256 -days 3650 \
              -in "$WORK_DIR/${l.name}.csr" \
              -CA "$in/rancher-clustermesh-ca-${group}/ca.crt" \
              -CAkey "$in/rancher-clustermesh-ca-${group}/ca.key" \
              -CAcreateserial \
              -extfile "$WORK_DIR/${l.name}.ext" \
              -out "$out/${l.name}.crt"
          '')
          leaves}
      '';
    };
  };

  # Admin kubeconfig: an operator client cert (CN admin, O system:masters
  # -> cluster-admin) signed by the vars client CA, with `server` as the
  # API endpoint (the distro service passes the per-node haproxy endpoint:
  # https://<kubeapi FQDN>:<kubeapi LB port>). Fully derived from the
  # rancher-pki vars — no prompts.
  mkAdminKubeconfigGenerator = {
    pkgs,
    instanceName,
    server,
  }: {
    "rancher-admin-kubeconfig-${instanceName}" = {
      share = true;
      dependencies = ["rancher-pki-${instanceName}"];
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
}
