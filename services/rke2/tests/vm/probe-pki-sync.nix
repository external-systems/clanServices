# rke2-probe-pki-sync (throwaway probe, K10): what does rke2 do when the
# PathChanged unit copies a regenerated CA set into the live TLS dir of a
# running server? The probe boots the rke2-single cluster, writes a new CA
# set over the deployed rancher-pki files (what `clan vars generate
# --regenerate` plus a deploy does), and prints FINDING lines: did the
# path unit copy it, do the old client certificates still work, does the
# node stay Ready, does rke2-server start again.
{
  lib,
  inputs,
  ...
}: let
  single = import ../../../../lib/kube-cluster/tests/vm/single.nix {
    inherit lib inputs;
    distro = "rke2";
  };
  suiteLib = import ../../../../tests/suite-lib.nix;
in
  single
  // {
    name = "rke2-probe-pki-sync";
    nodes.alpha = {pkgs, ...}: {
      imports = [single.nodes.alpha];
      environment.systemPackages = [pkgs.openssl];
    };
    testScript = ''
      ${suiteLib}
      import time

      start_all()
      alpha.wait_for_unit("rke2-server.service", timeout=600)
      alpha.wait_until_succeeds("kubectl wait --for=condition=Ready node/alpha --timeout=60s", timeout=900)
      alpha.wait_until_succeeds(
          "systemctl show -p Result --value rke2-rke2-bootstrap-apply | grep '^success$' >/dev/null", timeout=900
      )
      print_versions(alpha, ["rke2"])

      key = alpha.succeed("sed -n 's/^PathChanged=//p' /etc/systemd/system/rke2-rke2-pki-sync-tls.path").strip()
      d = key.rsplit("/", 1)[0]
      observe("vars dir", alpha, f"ls -la {d}")
      observe("live client CA before", alpha, "openssl x509 -noout -subject -fingerprint -in /var/lib/rancher/rke2/server/tls/client-ca.crt")
      observe("sync runs before", alpha, "systemctl show -p NRestarts,ExecMainStartTimestamp rke2-rke2-pki-sync-tls.service")

      # A regenerated CA set: new keys and certificates for every CA file.
      alpha.succeed(f"""
        set -e
        w=$(mktemp -d)
        for t in server client request-header etcd-peer etcd-server; do
          openssl ecparam -name prime256v1 -genkey -noout -out $w/$t-ca.key
          openssl req -x509 -new -key $w/$t-ca.key -days 3650 -subj /CN=probe-$t-ca -out $w/$t-ca.crt \
            -addext basicConstraints=critical,CA:true -addext keyUsage=critical,keyCertSign,cRLSign,digitalSignature
        done
        for f in client-ca.crt client-ca.key request-header-ca.crt request-header-ca.key \
                 etcd-peer-ca.crt etcd-peer-ca.key etcd-server-ca.crt etcd-server-ca.key server-ca.crt; do
          if [ -L {d}/$f ]; then rm -f {d}/$f; fi
          cat $w/$f > {d}/$f
        done
        cat $w/server-ca.key > {key}
      """)
      time.sleep(5)
      observe("sync runs after write", alpha, "systemctl show -p ExecMainStartTimestamp,Result rke2-rke2-pki-sync-tls.service; journalctl -u rke2-rke2-pki-sync-tls.path -u rke2-rke2-pki-sync-tls.service --no-pager | tail -n 20")
      observe("live client CA after", alpha, "openssl x509 -noout -subject -in /var/lib/rancher/rke2/server/tls/client-ca.crt")

      for wait in [10, 30, 60, 120]:
          time.sleep(wait)
          observe(f"old admin kubeconfig readyz +{wait}s", alpha, "timeout 20 kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get --raw /readyz")
          observe(f"clan admin kubeconfig +{wait}s", alpha, "timeout 20 kubectl --kubeconfig /etc/rancher/rke2/admin-kubeconfig get --raw /readyz")
          observe(f"node Ready +{wait}s", alpha, "timeout 20 kubectl get node alpha --no-headers")
          observe(f"haproxy backend +{wait}s", alpha, "echo show stat | socat - UNIX-CONNECT:/run/haproxy/haproxy.sock | grep '^rke2_api' | cut -d, -f1,2,18")
      observe("apiserver log after swap", alpha, "journalctl -u rke2-server --no-pager --since '-6min' | grep -iE 'x509|certificate|unauthor|client-ca|ca bundle|datastore' | tail -n 30")

      status, _ = alpha.execute("timeout 400 systemctl restart rke2-server")
      print(f"FINDING restart rke2-server: rc={status}")
      time.sleep(60)
      observe("rke2-server after restart", alpha, "systemctl show -p ActiveState,SubState,NRestarts rke2-server")
      observe("rke2-server log after restart", alpha, "journalctl -u rke2-server --no-pager --since '-3min' | grep -iE 'datastore|bootstrap|newer|certificate|x509|fatal|level=error' | tail -n 40")
      observe("live client CA after restart", alpha, "openssl x509 -noout -subject -in /var/lib/rancher/rke2/server/tls/client-ca.crt")
      observe("old admin kubeconfig after restart", alpha, "timeout 20 kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get --raw /readyz")
      observe("node after restart", alpha, "timeout 20 kubectl get node alpha --no-headers")
      print("RKE2_PROBE_PKI_SYNC_OK")
    '';
  }
