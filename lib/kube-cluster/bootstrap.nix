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
{ lib }: {
  # The digest-alias oneshot (D26/D40 airgap). The bundle references every
  # image digest-pinned (repo:tag@digest — the artifact invariant), but
  # tarball preloads (services.k3s.images / rke2's images dir) register
  # only repo:tag, and containerd's CRI looks digested references up under
  # the canonical name@digest form — offline, every pinned pod would
  # ImagePullBackOff. Tagging each preloaded image under its name@digest
  # alias makes the CRI lookup resolve (probe-verified: crictl inspecti
  # succeeds for tag@digest, name@digest, and fqdn forms once the alias
  # exists). Runs on every node after the distro runtime is up; retries
  # until all preloaded sources are tagged (import finishes inside distro
  # startup, so the source tag may land a few seconds after us).
  mkImageDigestAliases =
    {
      pkgs,
      instanceName,
      # the distro's runtime unit: "k3s.service" / "rke2-server.service" /
      # "rke2-agent.service"
      runtimeUnit,
      # the pinned image triples matching the bundle's references:
      # [ { repo, tag, digest } ]
      images,
    }:
    let
      unitName = "kube-cluster-${instanceName}-image-digest-aliases";
      ctr = "${pkgs.containerd}/bin/ctr --address /run/k3s/containerd/containerd.sock --namespace k8s.io";
      aliasOf = img: {
        source = "${img.repo}:${img.tag}";
        alias = "${img.repo}@${img.digest}";
      };
      aliases = map aliasOf images;
    in
    {
      systemd.services.${unitName} = {
        description = "Tag preloaded ${instanceName} images with their name@digest aliases (offline digest refs)";
        wantedBy = [ "multi-user.target" ];
        after = [ runtimeUnit ];
        # The runtime is enough — no requires: a node whose distro service
        # failed has no containerd to tag into anyway.
        unitConfig.StartLimitIntervalSec = 0;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 5;
          ExecStart =
            # passthru.aliases pins the rendered alias set for eval tests
            # (the script text itself is not eval-inspectable).
            (pkgs.writeShellScript unitName ''
              set -euo pipefail
              i=0
              while [ "$i" -lt 120 ]; do
                # The containerd socket appears inside the distro runtime's
                # startup (after=k3s.service only orders on process start);
                # a ctr failure here just means "not yet" — treat as pending.
                names=$(${ctr} images list -q 2>/dev/null || true)
                pending=0
                ${lib.concatMapStringsSep "\n" (a: ''
                  if ! printf '%s\n' "$names" | ${pkgs.gnugrep}/bin/grep -Fxq '${a.alias}'; then
                    if printf '%s\n' "$names" | ${pkgs.gnugrep}/bin/grep -Fxq '${a.source}'; then
                      ${ctr} images tag --force '${a.source}' '${a.alias}' || pending=1
                    else
                      pending=1
                    fi
                  fi
                '') aliases}
                if [ "$pending" -eq 0 ]; then
                  exit 0
                fi
                i=$((i + 1))
                ${pkgs.coreutils}/bin/sleep 5
              done
              echo "${unitName}: timed out waiting for preloaded images to appear" >&2
              exit 1
            '').overrideAttrs
              (_: {
                passthru = {
                  inherit aliases;
                };
              });
        };
      };
    };

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
