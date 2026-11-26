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
