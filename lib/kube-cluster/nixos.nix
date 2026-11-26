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
  # The first-server guard (specs/gateway.md §16.3): a `clusterInit`
  # server whose etcd directory is gone (a reinstall, a lost disk) would
  # start a second cluster with the same CAs, and the other nodes'
  # HAProxy would accept it. Before the server starts without data, the
  # guard asks every other server's API for half a minute (the fabric
  # needs that long after a boot). Any answer: refuse to start.
  mkInitGuard = {
    pkgs,
    namePrefix,
    beforeUnit,
    etcdDir,
    # the other servers' API hosts, bracketed when IPv6
    peers,
    port ? 6443,
  }: let
    unitName = "${namePrefix}-init-guard";
  in {
    systemd.services."${unitName}" = {
      description = "Refuse to start a second cluster on a first server without data";
      before = [beforeUnit];
      requiredBy = [beforeUnit];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript unitName ''
          set -u
          if [ -d "${etcdDir}" ]; then
            exit 0
          fi
          tries=0
          while [ "$tries" -lt 10 ]; do
            for peer in ${pkgs.lib.escapeShellArgs peers}; do
              code=$(${pkgs.curl}/bin/curl -ks -o /dev/null -w '%{http_code}' --max-time 2 "https://$peer:${toString port}/readyz" || true)
              if [ -n "$code" ] && [ "$code" != 000 ]; then
                echo "${unitName}: this machine is the clusterInit server and has no etcd data, but the server at $peer answers. Starting would create a second cluster. Move 'clusterInit' to a server that has the data, so this one joins it." >&2
                exit 1
              fi
            done
            tries=$((tries + 1))
            ${pkgs.coreutils}/bin/sleep 3
          done
        '';
      };
    };
  };

  mkPkiSync = {
    pkgs,
    # config.clan.core.vars.generators."rancher-pki-<instance>"
    pkiGenerator,
    # e.g. "/var/lib/rancher/rke2/server/tls"
    tlsDir,
    # e.g. "rke2-server.service"
    beforeUnit,
    # unit name prefix, e.g. "rke2-<instance>" -> rke2-<instance>-pki-sync-tls
    namePrefix,
  }: let
    unitName = "${namePrefix}-pki-sync-tls";
    install = pkgs.coreutils + "/bin/install";
  in {
    systemd.paths."${unitName}" = {
      description = "Watch the ${namePrefix} PKI files for changes";
      wantedBy = ["multi-user.target"];
      pathConfig.PathChanged = [pkiGenerator.files."server-ca.key".path];
    };

    systemd.services."${unitName}" = {
      description = "Sync pre-generated custom CA certificates to the server TLS directory";
      wantedBy = ["multi-user.target"];
      before = [beforeUnit];
      requiredBy = [beforeUnit];
      # The server CA key is a SECRET var file: its .path is the runtime
      # deployment path (/run/secrets/...). An assertion, not a
      # condition: a skipped condition satisfies `requiredBy`, and the
      # server would then start and generate CAs of its own, which no
      # other node trusts (specs/gateway.md §16.3).
      unitConfig.AssertPathExists = pkiGenerator.files."server-ca.key".path;
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
