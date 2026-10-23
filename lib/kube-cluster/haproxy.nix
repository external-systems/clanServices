# Per-node kube-apiserver / optional supervisor load balancer (haproxy)
# rendering.
#
# The design (ported from the BORG fleet, VM-proven there): EVERY node —
# servers and agents — runs a local haproxy bound to the node's own
# transport addresses (both families). The kubeapi FQDN resolves to the
# node's OWN address via /etc/hosts, so the kubelet's bootstrap, Cilium's
# API endpoint (k8sServiceHost) and every joining server/agent all talk to
# the LOCAL haproxy, which balances across the servers' transport
# addresses with TLS /readyz healthchecks.
#
# The kube-apiserver owns :<kubeapiPort> on every address, so the LB listens
# on the derived lbKubeapiPort. RKE2 additionally enables a supervisor LB on
# lbSupervisorPort; k3s disables it with enableSupervisor = false. The
# healthcheck connects with TLS (check-ssl) while the DATA path stays raw TCP
# (end-to-end TLS to the apiserver): `check` ENABLES checks (check-ssl alone
# does not imply it), `check ssl` would wrap the DATA path in haproxy's own
# TLS and break clients. The check verifies the serving chain with the PKI's
# server CA and presents the healthcheck client cert (any authenticated user
# may GET /readyz).
#
# When enabled, the supervisor backend checks /readyz THROUGH the real API
# port (check port <kubeapiPort>) — the anti-deadlock: a JOINING server's
# supervisor is L4-up but cannot serve joins (no etcd access), so an L4 port
# check would keep a dead-end backend UP. The L7 check marks it DOWN until
# the local apiserver is ready; `option allbackups` then routes the join to a
# healthy server.
{ lib }:
{
  mkHaproxyConfig =
    {
      instanceName,
      # This node's own addresses (the haproxy bind addresses).
      nodeIPv4,
      nodeIPv6,
      # One entry per server-role member:
      #   { name, ipv4, ipv6, backup = bool }
      # (a server lists ITSELF normally and the remote servers as backups;
      # agents list every server plain).
      backends,
      # The real apiserver / supervisor ports (backend targets).
      kubeapiPort ? 6443,
      supervisorPort ? 9345,
      # The LB frontend ports this node's haproxy binds.
      lbKubeapiPort,
      lbSupervisorPort ? lbKubeapiPort + 1000,
      enableSupervisor ? true,
      # Deployed vars paths for the TLS healthchecks.
      caCrtPath,
      clientPemPath,
      # sha512-crypt hash for the stats page (public var value, eval-time).
      statsPasswordHash,
      statsPort ? 8404,
      # SNI the healthcheck presents; must be a serving-cert SAN (the
      # kubeapi FQDN).
      healthCheckSni,
    }:
    let
      safeName = lib.replaceStrings [ "-" ] [ "_" ] instanceName;
      serverLines =
        port:
        lib.concatMapStringsSep "\n" (
          b:
          let
            backup = lib.optionalString b.backup " backup";
          in
          "    server ${b.name}-4 ${b.ipv4}:${toString port}${backup}\n"
          + "    server ${b.name}-6 [${b.ipv6}]:${toString port}${backup}"
        ) backends;
      checkArgs = "check check-ssl verify required ca-file ${caCrtPath} crt ${clientPemPath} sni str(${healthCheckSni}) inter 5s fall 3 rise 2 fastinter 1s downinter 10s on-marked-down shutdown-sessions";
      supervisorConfig = lib.optionalString enableSupervisor ''
        # HAProxy 3.3 forbids a frontend and backend sharing a name — the
        # supervisor LB gets distinct names (the kubeapi pair already
        # differs: _kubeapi frontend -> _api backend).
        frontend ${safeName}_supervisor
            bind ${nodeIPv4}:${toString lbSupervisorPort}
            bind [${nodeIPv6}]:${toString lbSupervisorPort}
            mode tcp
            option tcplog
            default_backend ${safeName}_supervisor_lb

        backend ${safeName}_supervisor_lb
            mode tcp
            balance roundrobin
            option allbackups
            # L7 /readyz THROUGH the supervisor (it proxies to the local
            # apiserver) — the ANTI-DEADLOCK check: a JOINING server's
            # supervisor is L4-up but cannot serve joins (no etcd access),
            # so an L4 port check keeps the local backend UP and the join
            # loops into its own dead-end backend. The L7 check marks it
            # DOWN until the local apiserver is ready and `option
            # allbackups` routes the join to a healthy server. The check
            # probes the REAL API PORT (check port <kubeapiPort>) with TLS —
            # the supervisor itself does not serve /readyz.
            option httpchk GET /readyz
            http-check expect status 200
            default-server check check-ssl port ${toString kubeapiPort} verify required ca-file ${caCrtPath} crt ${clientPemPath} sni str(${healthCheckSni}) inter 5s fall 3 rise 2 fastinter 1s downinter 10s on-marked-down shutdown-sessions
        ${serverLines supervisorPort}
      '';
    in
    ''
      global
          log /dev/log local0
          log /dev/log local1 notice

      defaults
          log     global
          mode    tcp
          option  tcplog
          option  dontlognull
          retries 3
          timeout connect 5s
          timeout client  1m
          timeout server  1m

      userlist stats_users
          user admin password ${statsPasswordHash}

      listen stats
          mode http
          bind ${nodeIPv4}:${toString statsPort}
          bind [${nodeIPv6}]:${toString statsPort}
          stats enable
          stats uri /stats
          stats refresh 60s
          http-request auth unless { http_auth(stats_users) }
          stats admin if { http_auth(stats_users) }

      frontend ${safeName}_kubeapi
          bind ${nodeIPv4}:${toString lbKubeapiPort}
          bind [${nodeIPv6}]:${toString lbKubeapiPort}
          mode tcp
          option tcplog
          default_backend ${safeName}_api

      backend ${safeName}_api
          mode tcp
          balance roundrobin
          option allbackups
          option httpchk GET /readyz
          http-check expect status 200
          default-server ${checkArgs}
      ${serverLines kubeapiPort}

      ${supervisorConfig}
    '';
}
