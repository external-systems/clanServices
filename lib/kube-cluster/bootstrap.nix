# The bootstrap-apply oneshot (D40). Renders the bundle into a clan-owned
# etc path (NEVER the distro's watched manifests dir — §6.12) and a systemd
# oneshot on the clusterInit node that waits for local apiserver health and
# applies the bundle once via SSA. SSA is a no-op when the cluster state
# already matches, so re-running (boots, retries) is safe.
#
# Retry note: the Cilium CRDs are created by the cilium operator at runtime
# (the chart ships no crds/ dir), so the pool/pod-pool CRs fail their first
# apply pass; kubectl still applies everything else and exits non-zero, and
# Restart=on-failure re-runs until the whole bundle sticks.
_: {
  mkBootstrapApply =
    {
      pkgs,
      instanceName,
      # unit name prefix, e.g. "k3s" -> k3s-<instance>-bootstrap-apply
      namePrefix,
      # the distro's server unit: "k3s.service" / "rke2-server.service"
      serverUnit,
      # the distro's admin kubeconfig (loopback apiserver endpoint):
      # /etc/rancher/k3s/k3s.yaml / /etc/rancher/rke2/rke2.yaml
      kubeconfigPath,
      # the rendered bundle (derivation or path)
      bundle,
    }:
    let
      unitName = "${namePrefix}-${instanceName}-bootstrap-apply";
      kubectl = "${pkgs.kubectl}/bin/kubectl";
    in
    {
      environment.etc."clan-bootstrap/${instanceName}/bundle.yaml".source = bundle;

      systemd.services."${unitName}" = {
        description = "Apply the ${instanceName} kubenix bootstrap bundle (SSA, idempotent)";
        wantedBy = [ "multi-user.target" ];
        after = [ serverUnit ];
        requires = [ serverUnit ];
        # oneshot retries: never give up because of rate limiting — the
        # bundle must land for the cluster to be functional.
        unitConfig.StartLimitIntervalSec = 0;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 10;
          ExecStart = pkgs.writeShellScript unitName ''
            set -euo pipefail
            export KUBECONFIG="${kubeconfigPath}"
            # Wait for the LOCAL apiserver (the distro kubeconfig points at
            # loopback, not the per-node haproxy LB).
            i=0
            while [ "$i" -lt 120 ]; do
              if ${kubectl} get --raw=/readyz >/dev/null 2>&1; then
                break
              fi
              i=$((i + 1))
              ${pkgs.coreutils}/bin/sleep 5
            done
            ${kubectl} get --raw=/readyz >/dev/null
            ${kubectl} apply --server-side --field-manager=clan-bootstrap \
              -f /etc/clan-bootstrap/${instanceName}/bundle.yaml
          '';
        };
      };
    };
}
