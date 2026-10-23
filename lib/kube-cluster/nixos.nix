# NixOS fragment builders — the systemd pieces of the pre-generated PKI
# design. Distro-parameterized: rke2 syncs into
# /var/lib/rancher/rke2/server/tls before rke2-server.service; k3s has its
# own tls dir and unit name. Returns plain attrsets for the caller to
# mkMerge into its node config.
#
# The PKI sync installs the rancher-pki-<instance> var files (deployed by
# the clan vars machinery) into the distro's tls dir BEFORE the server
# starts: rke2/k3s then adopt the pre-generated CAs instead of generating
# their own (the "custom CA" flow), keeping every server on one CA tree
# and making the admin kubeconfig / haproxy healthcheck certs verifiable
# cluster-wide. A path unit re-syncs when the CA material changes (vars
# regeneration).
_: {
  mkPkiSync =
    {
      pkgs,
      # config.clan.core.vars.generators."rancher-pki-<instance>"
      pkiGenerator,
      # e.g. "/var/lib/rancher/rke2/server/tls"
      tlsDir,
      # e.g. "rke2-server.service"
      beforeUnit,
      # unit name prefix, e.g. "rke2-<instance>" -> rke2-<instance>-pki-sync-tls
      namePrefix,
    }:
    let
      unitName = "${namePrefix}-pki-sync-tls";
      install = pkgs.coreutils + "/bin/install";
    in
    {
      systemd.paths."${unitName}" = {
        description = "Watch the ${namePrefix} PKI files for changes";
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathChanged = [ pkiGenerator.files."server-ca.key".path ];
      };

      systemd.services."${unitName}" = {
        description = "Sync pre-generated custom CA certificates to the server TLS directory";
        wantedBy = [ "multi-user.target" ];
        before = [ beforeUnit ];
        requiredBy = [ beforeUnit ];
        # The server CA key is a SECRET var file: its .path is the runtime
        # deployment path (/run/secrets/...), so the condition is a real
        # runtime guard — the sync runs only once the vars are deployed.
        unitConfig.ConditionPathExists = pkiGenerator.files."server-ca.key".path;
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          ExecStart = pkgs.writeShellScript unitName ''
            set -euo pipefail
            TLS_DIR="${tlsDir}"
            mkdir -p "$TLS_DIR/etcd"
            chmod 700 "$TLS_DIR" "$TLS_DIR/etcd"
            ${install} -Dm644 ${pkiGenerator.files."server-ca.crt".path} "$TLS_DIR/server-ca.crt"
            ${install} -Dm600 ${pkiGenerator.files."server-ca.key".path} "$TLS_DIR/server-ca.key"
            ${install} -Dm644 ${pkiGenerator.files."client-ca.crt".path} "$TLS_DIR/client-ca.crt"
            ${install} -Dm600 ${pkiGenerator.files."client-ca.key".path} "$TLS_DIR/client-ca.key"
            ${install} -Dm644 ${
              pkiGenerator.files."request-header-ca.crt".path
            } "$TLS_DIR/request-header-ca.crt"
            ${install} -Dm600 ${
              pkiGenerator.files."request-header-ca.key".path
            } "$TLS_DIR/request-header-ca.key"
            ${install} -Dm644 ${pkiGenerator.files."etcd-peer-ca.crt".path} "$TLS_DIR/etcd/peer-ca.crt"
            ${install} -Dm600 ${pkiGenerator.files."etcd-peer-ca.key".path} "$TLS_DIR/etcd/peer-ca.key"
            ${install} -Dm644 ${pkiGenerator.files."etcd-server-ca.crt".path} "$TLS_DIR/etcd/server-ca.crt"
            ${install} -Dm600 ${pkiGenerator.files."etcd-server-ca.key".path} "$TLS_DIR/etcd/server-ca.key"
            ${install} -Dm600 ${pkiGenerator.files."service.key".path} "$TLS_DIR/service.key"
          '';
        };
      };
    };
}
