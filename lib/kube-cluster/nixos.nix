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
# cluster-wide. A later, different CA set is staged, never copied into a
# live TLS dir (K10: rke2 then refuses to start; rotation is
# `rke2 certificate rotate-ca`).
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
    # K10: a CA set that differs from the live one goes here, never into
    # the live TLS dir (the layout `rke2 certificate rotate-ca --path`
    # reads).
    stagedDir = "${tlsDir}-staged";
    coreutils = "${pkgs.coreutils}/bin";
    files = [
      {
        from = "server-ca.crt";
        to = "server-ca.crt";
        mode = "644";
      }
      {
        from = "server-ca.key";
        to = "server-ca.key";
        mode = "600";
      }
      {
        from = "client-ca.crt";
        to = "client-ca.crt";
        mode = "644";
      }
      {
        from = "client-ca.key";
        to = "client-ca.key";
        mode = "600";
      }
      {
        from = "request-header-ca.crt";
        to = "request-header-ca.crt";
        mode = "644";
      }
      {
        from = "request-header-ca.key";
        to = "request-header-ca.key";
        mode = "600";
      }
      {
        from = "etcd-peer-ca.crt";
        to = "etcd/peer-ca.crt";
        mode = "644";
      }
      {
        from = "etcd-peer-ca.key";
        to = "etcd/peer-ca.key";
        mode = "600";
      }
      {
        from = "etcd-server-ca.crt";
        to = "etcd/server-ca.crt";
        mode = "644";
      }
      {
        from = "etcd-server-ca.key";
        to = "etcd/server-ca.key";
        mode = "600";
      }
      {
        from = "service.key";
        to = "service.key";
        mode = "600";
      }
    ];
    installInto = dir:
      pkgs.lib.concatMapStringsSep "\n" (
        f: "${coreutils}/install -Dm${f.mode} ${pkiGenerator.files.${f.from}.path} \"${dir}/${f.to}\""
      )
      files;
  in {
    # No path unit (K10): the probe rke2-probe-pki-sync showed that a CA
    # copied into the live TLS dir of a running server makes its next
    # start fatal ("newer than datastore and could cause a cluster
    # outage"). The sync runs before every server start instead.
    systemd.services."${unitName}" = {
      description = "Install the pre-generated custom CAs before the first server start; stage a changed set";
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
          STAGED_DIR="${stagedDir}"
          ${coreutils}/rm -rf "$STAGED_DIR"
          ${coreutils}/mkdir -p "$STAGED_DIR/etcd"
          ${coreutils}/chmod 700 "$STAGED_DIR" "$STAGED_DIR/etcd"
          ${installInto "$STAGED_DIR"}
          if [ ! -e "$TLS_DIR/server-ca.crt" ]; then
            # First start of this server: the vars CAs become the live set.
            ${coreutils}/mkdir -p "$TLS_DIR/etcd"
            ${coreutils}/chmod 700 "$TLS_DIR" "$TLS_DIR/etcd"
            ${coreutils}/cp -a "$STAGED_DIR/." "$TLS_DIR/"
            ${coreutils}/rm -rf "$STAGED_DIR"
            exit 0
          fi
          changed=""
          ${pkgs.lib.concatMapStringsSep "\n" (f: ''
            if ! ${pkgs.diffutils}/bin/cmp -s "$STAGED_DIR/${f.to}" "$TLS_DIR/${f.to}"; then
              changed="$changed ${f.to}"
            fi'')
          files}
          if [ -z "$changed" ]; then
            ${coreutils}/rm -rf "$STAGED_DIR"
            exit 0
          fi
          # The live CAs stay; the server keeps the datastore's set.
          echo "${unitName}: the clan vars CAs differ from the live ones ($changed). The live set stays; the vars set is staged in $STAGED_DIR. To rotate, follow the CA rotation runbook: rke2 certificate rotate-ca --path=$STAGED_DIR" >&2
        '';
      };
    };
  };
}
