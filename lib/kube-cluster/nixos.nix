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
{lib, ...}: {
  # The first-server guard (specs/gateway.md §16.3, SPEC.md §6.10): a
  # `clusterInit` server whose etcd directory is gone (a reinstall, a lost
  # disk) would start a second cluster with the same CAs, and the other
  # nodes' HAProxy would accept it. Before the server starts without
  # data, the guard dials every other server's API port, after IfState
  # and FRR (the peers are fabric addresses):
  #   - a connection (anything listens): a cluster is alive -> refuse;
  #   - "Connection refused" from every peer: reachable, no cluster ->
  #     start;
  #   - anything else (timeout, no route): unknown -> keep trying until
  #     the deadline, then refuse.
  # It fails closed: a first server whose peers stay unreachable does not
  # start. The operator who knows no cluster is alive creates
  # `overrideFile` and restarts the server; the guard deletes the file
  # when it lets the server start, so a later data loss is checked again.
  mkInitGuard = {
    pkgs,
    namePrefix,
    beforeUnit,
    etcdDir,
    # the other servers' API addresses (plain, IPv6 without brackets)
    peers,
    port ? 6443,
    # created by the operator to allow a start without the check
    overrideFile,
    # seconds to wait for every peer to answer
    waitSeconds ? 300,
  }: let
    unitName = "${namePrefix}-init-guard";
  in {
    systemd.services."${unitName}" = {
      description = "Refuse to start a second cluster on a first server without data";
      before = [beforeUnit];
      requiredBy = [beforeUnit];
      # the peers are fabric addresses: IfState and FRR come first
      after = [
        "network-online.target"
        "ifstate.service"
        "frr.service"
      ];
      wants = ["network-online.target"];
      # the suites override these in a drop-in to run the guard beside
      # a live cluster
      environment = {
        INIT_GUARD_ETCD_DIR = etcdDir;
        INIT_GUARD_PORT = toString port;
        INIT_GUARD_PEERS = lib.concatStringsSep " " peers;
        INIT_GUARD_OVERRIDE = overrideFile;
        INIT_GUARD_WAIT = toString waitSeconds;
      };
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "infinity";
        ExecStart = pkgs.writeShellScript unitName ''
          set -u
          export LC_ALL=C
          if [ -d "$INIT_GUARD_ETCD_DIR" ]; then
            exit 0
          fi
          if [ -e "$INIT_GUARD_OVERRIDE" ]; then
            echo "${unitName}: $INIT_GUARD_OVERRIDE exists: starting a new cluster without the check" >&2
            rm -f "$INIT_GUARD_OVERRIDE"
            exit 0
          fi
          deadline=$(( $(${pkgs.coreutils}/bin/date +%s) + INIT_GUARD_WAIT ))
          while :; do
            unknown=""
            for peer in $INIT_GUARD_PEERS; do
              err=$(${pkgs.coreutils}/bin/timeout 5 ${pkgs.bash}/bin/bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$peer" "$INIT_GUARD_PORT" 2>&1)
              rc=$?
              if [ "$rc" -eq 0 ]; then
                echo "${unitName}: this machine is the clusterInit server and has no etcd data, but the server at $peer answers on port $INIT_GUARD_PORT. Starting would create a second cluster. Move 'clusterInit' to a server that has the data, so this one joins it." >&2
                exit 1
              fi
              case "$err" in
                *"Connection refused"*) ;;
                *) unknown="$unknown $peer" ;;
              esac
            done
            if [ -z "$unknown" ]; then
              exit 0
            fi
            if [ "$(${pkgs.coreutils}/bin/date +%s)" -ge "$deadline" ]; then
              echo "${unitName}: this machine is the clusterInit server and has no etcd data, and these servers did not answer for $INIT_GUARD_WAIT s:$unknown. A cluster may be alive behind them. If no cluster is alive, create $INIT_GUARD_OVERRIDE and restart ${beforeUnit}." >&2
              exit 1
            fi
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
