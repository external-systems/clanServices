# The bootstrap-apply oneshot (D40). Renders the bundle into a clan-owned
# etc path (NEVER the distro's watched manifests dir — §6.12) and a systemd
# oneshot on the clusterInit node that waits for local apiserver health and
# applies the bundle via SSA at every server start and on every deploy that
# changes it, then prunes the labelled objects it applied before that the
# bundle no longer has (D40, revised round G11). SSA is a no-op when the
# cluster state already matches, so re-running (boots, retries) is safe.
#
# The Cilium CRDs are created by the cilium operator at runtime (the chart
# ships no crds/ dir): the unit applies the non-CR documents, waits until
# the CRDs are Established, then applies the custom resources.
{lib}: {
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
  mkImageDigestAliases = {
    pkgs,
    instanceName,
    # the distro's runtime unit: "k3s.service" / "rke2-server.service" /
    # "rke2-agent.service"
    runtimeUnit,
    # the pinned image triples matching the bundle's references:
    # [ { repo, tag, digest } ]
    images,
  }: let
    unitName = "kube-cluster-${instanceName}-image-digest-aliases";
    ctr = "${pkgs.containerd}/bin/ctr --address /run/k3s/containerd/containerd.sock --namespace k8s.io";
    aliasOf = img: {
      source = "${img.repo}:${img.tag}";
      alias = "${img.repo}@${img.digest}";
    };
    aliases = map aliasOf images;
  in {
    systemd.services.${unitName} = {
      description = "Tag preloaded ${instanceName} images with their name@digest aliases (offline digest refs)";
      wantedBy = ["multi-user.target"];
      after = [runtimeUnit];
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
              '')
              aliases}
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

  mkBootstrapApply = {
    pkgs,
    # the node's NixOS config: the unit re-runs when the DEPLOYED bundle
    # file changes, whatever put it there (restartTriggers below)
    config,
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
  }: let
    unitName = "${namePrefix}-${instanceName}-bootstrap-apply";
    etcName = "clan-bootstrap/${instanceName}/bundle.yaml";
    kubectl = "${pkgs.kubectl}/bin/kubectl";
    jq = "${pkgs.jq}/bin/jq";
    sleep = "${pkgs.coreutils}/bin/sleep";
    apply = "${kubectl} apply --server-side --force-conflicts --field-manager=clan-bootstrap";
    selector = "clan.lol/cluster=${instanceName}";
    # jq: a document's API group ("" for the core group)
    groupOf = ''(.apiVersion | split("/") | if length == 1 then "" else .[0] end)'';
    # jq: a custom resource is a document of a non-builtin group (dotted,
    # not *.k8s.io); its CRD must be Established before it applies
    isCr = ''(${groupOf} | contains(".") and (endswith("k8s.io") | not))'';
    # jq: group, kind, namespace and name of an object, joined by "|"
    # (never tabs: `read` collapses empty tab fields such as the core
    # group's "", and no Kubernetes name holds a "|")
    identity = ''[${groupOf}, .kind, (.metadata.namespace // ""), .metadata.name] | join("|")'';
  in {
    environment.etc.${etcName}.source = bundle;

    systemd.services."${unitName}" = {
      description = "Apply the ${instanceName} kubenix bootstrap bundle (SSA, idempotent, prunes its own objects)";
      wantedBy = ["multi-user.target"];
      after = [serverUnit];
      requires = [serverUnit];
      # D40 (K4): a deploy that changes the deployed bundle re-runs the
      # apply; the server keeps running.
      restartTriggers = [config.environment.etc.${etcName}.source];
      # D40 (K5): bounded, growing retries (10 s up to 2 min, at most 12
      # starts an hour), then the unit stays failed and visible.
      unitConfig = {
        StartLimitIntervalSec = 3600;
        StartLimitBurst = 12;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 10;
        RestartSteps = 5;
        RestartMaxDelaySec = 120;
        ExecStart = pkgs.writeShellScript unitName ''
          set -euo pipefail
          export KUBECONFIG="${kubeconfigPath}"
          bundle=/etc/${etcName}
          work=$(${pkgs.coreutils}/bin/mktemp -d)
          trap '${pkgs.coreutils}/bin/rm -rf "$work"' EXIT
          # Wait for the LOCAL apiserver (the distro kubeconfig points at
          # loopback, not the per-node haproxy LB).
          i=0
          while [ "$i" -lt 120 ]; do
            if ${kubectl} get --raw=/readyz >/dev/null 2>&1; then
              break
            fi
            i=$((i + 1))
            ${sleep} 5
          done
          ${kubectl} get --raw=/readyz >/dev/null

          ${pkgs.yq-go}/bin/yq eval-all -o=json '[.] | map(select(. != null))' "$bundle" > "$work/all.json"
          ${jq} '{apiVersion: "v1", kind: "List", items: [.[] | select(${isCr} | not)]}' "$work/all.json" > "$work/base.json"
          ${jq} '{apiVersion: "v1", kind: "List", items: [.[] | select(${isCr})]}' "$work/all.json" > "$work/crs.json"

          # 1. Everything but the custom resources.
          ${apply} -f "$work/base.json"

          # 2. The Cilium operator creates its CRDs at runtime (the chart
          # ships no crds/ dir): wait until each CR's CRD is Established.
          crds=$(${jq} -r '[.items[] | ((.kind | ascii_downcase | if endswith("y") then .[:-1] + "ies" else . + "s" end) + "." + ${groupOf})] | unique | .[]' "$work/crs.json")
          deadline=$((SECONDS + 900))
          for crd in $crds; do
            until ${kubectl} wait --for=condition=Established --timeout=10s "crd/$crd" >/dev/null 2>&1; do
              if [ "$SECONDS" -ge "$deadline" ]; then
                echo "${unitName}: CRD $crd is not Established after 15 minutes" >&2
                exit 1
              fi
              ${sleep} 5
            done
          done

          # 3. The custom resources.
          if [ "$(${jq} '.items | length' "$work/crs.json")" -gt 0 ]; then
            ${apply} -f "$work/crs.json"
          fi

          # 4. Prune (D40): delete what this unit applied before and the
          # bundle no longer has. Only objects labelled ${selector} that
          # carry a clan-bootstrap managed-fields entry; a document
          # without a namespace keeps its name in every namespace.
          ${jq} -r '.[] | ${identity}' "$work/all.json" | ${pkgs.coreutils}/bin/sort -u > "$work/keep"
          # an unavailable aggregated API makes discovery partial, not empty
          if ! ${kubectl} api-resources --verbs=list,delete -o name > "$work/resources"; then
            echo "${unitName}: API discovery is partial; pruning the listed resources only" >&2
          fi
          while read -r resource; do
            if ! ${kubectl} get "$resource" -A -l '${selector}' --show-managed-fields -o json > "$work/listed.json" 2>/dev/null; then
              echo "${unitName}: cannot list $resource; not pruned" >&2
              continue
            fi
            ${jq} -r --arg r "$resource" '.items[] | select(any(.metadata.managedFields[]?; .manager == "clan-bootstrap")) | (${identity}) + "|" + $r' "$work/listed.json"
          done < "$work/resources" | while IFS="|" read -r group kind ns name resource; do
            if ${pkgs.gnugrep}/bin/grep -Fxq "$group|$kind|$ns|$name" "$work/keep" \
              || ${pkgs.gnugrep}/bin/grep -Fxq "$group|$kind||$name" "$work/keep"; then
              continue
            fi
            echo "${unitName}: pruning $resource $ns/$name (no longer in the bundle)"
            if [ -n "$ns" ]; then
              ${kubectl} delete "$resource" -n "$ns" "$name" --ignore-not-found --wait=false
            else
              ${kubectl} delete "$resource" "$name" --ignore-not-found --wait=false
            fi
          done
        '';
      };
    };
  };

  # The ClusterMesh apiserver TLS secrets (D60): this oneshot supplies the
  # clan vars material on the clusterInit node (the shared mesh group CA +
  # the per-cluster leaf set; SANs carry the cluster's published endpoints).
  # Key material never enters the bundle/Nix store: the unit reads the
  # deployed vars files and base64-encodes them at runtime.
  #
  # The four secrets are exactly what the upstream Deployment mounts:
  #   clustermesh-apiserver-server-cert  (etcd server + apiserver serverAuth)
  #   clustermesh-apiserver-admin-cert   (etcd admin client, root role)
  #   clustermesh-apiserver-remote-cert  (projected as common-etcd-client —
  #                                      what PEERS dial with, CN remote-<cluster>)
  #   clustermesh-apiserver-local-cert   (local agents/kvstoremesh reader)
  mkClustermeshSecretsApply = {
    pkgs,
    instanceName,
    namePrefix,
    # unit ordering after the bootstrap-apply unit (same name the distro
    # passes to mkBootstrapApply): the bundle creates the apiserver
    # objects; the secrets must follow so the pods mount real material.
    bootstrapUnit,
    serverUnit,
    kubeconfigPath,
    # the rancher-clustermesh-<instance> generator's files attrset
    files,
  }: let
    unitName = "${namePrefix}-${instanceName}-clustermesh-secrets";
    kubectl = "${pkgs.kubectl}/bin/kubectl";
    jq = "${pkgs.jq}/bin/jq";
    leaves = [
      "server"
      "admin"
      "remote"
      "local"
    ];
    # K8: jq reads the files itself (--rawfile) and encodes them, so no
    # key material ever reaches a command line (/proc/<pid>/cmdline is
    # world-readable).
    secret = name: cert: ''
      test -s ${files."ca.crt".path}
      test -s ${files."${cert}.crt".path}
      test -s ${files."${cert}.key".path}
      ${jq} -n \
        --arg name "${name}" \
        --rawfile ca ${files."ca.crt".path} \
        --rawfile crt ${files."${cert}.crt".path} \
        --rawfile key ${files."${cert}.key".path} \
        '{apiVersion:"v1",kind:"Secret",metadata:{name:$name,namespace:"kube-system"},type:"kubernetes.io/tls",data:{"ca.crt":($ca|@base64),"tls.crt":($crt|@base64),"tls.key":($key|@base64)}}'
    '';
  in {
    # D40 (K4): a regenerated leaf key re-runs this unit on deploy (the
    # public certificates are store paths in the script, so a new one
    # changes the unit itself). Set here, on the clusterInit node that
    # has the unit, not in the shared generator.
    clan.core.vars.generators."rancher-clustermesh-${instanceName}".files = lib.genAttrs (map (l: "${l}.key") leaves) (_: {
      restartUnits = ["${unitName}.service"];
    });

    systemd.services."${unitName}" = {
      description = "Apply the ${instanceName} ClusterMesh apiserver TLS secrets (clan vars material, idempotent)";
      wantedBy = ["multi-user.target"];
      after = [
        serverUnit
        bootstrapUnit
      ];
      requires = [serverUnit];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 10;
        ExecStart = pkgs.writeShellScript unitName ''
          set -euo pipefail
          export KUBECONFIG="${kubeconfigPath}"
          i=0
          while [ "$i" -lt 120 ]; do
            if ${kubectl} get --raw=/readyz >/dev/null 2>&1; then
              break
            fi
            i=$((i + 1))
            ${pkgs.coreutils}/bin/sleep 5
          done
          ${kubectl} get --raw=/readyz >/dev/null
          {
            ${secret "clustermesh-apiserver-server-cert" "server"}
            ${secret "clustermesh-apiserver-admin-cert" "admin"}
            ${secret "clustermesh-apiserver-remote-cert" "remote"}
            ${secret "clustermesh-apiserver-local-cert" "local"}
          } | ${jq} -s '{apiVersion:"v1",kind:"List",items:.}' \
            | ${kubectl} apply --server-side --field-manager=clan-clustermesh -f -
          # The chart-generated Secret objects are absent from the bundle,
          # so apiserver pods start only after this unit supplies their
          # mounts. The pods must run the vars-issued certificates, so the
          # pod template carries the digest of the public certificates:
          # a new set changes the template, which rolls the pods. Only a
          # change rolls (a rollout drops every mesh peer's session,
          # specs/gateway.md §16.3), and a run that died after the apply
          # still rolls next time, because the digest is the state (K8).
          digest=$(${pkgs.coreutils}/bin/cat ${
            lib.concatMapStringsSep " " (l: files."${l}.crt".path) leaves
          } ${files."ca.crt".path} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -c1-32)
          current=$(${kubectl} get deployment/clustermesh-apiserver -n kube-system \
            -o jsonpath='{.spec.template.metadata.annotations.clan\.lol/mesh-secrets}')
          if [ "$current" != "$digest" ]; then
            ${kubectl} patch deployment/clustermesh-apiserver -n kube-system --type=merge \
              -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"clan.lol/mesh-secrets\":\"$digest\"}}}}}"
          else
            echo "${unitName}: the ClusterMesh certificates are unchanged; no rollout"
          fi
          ${kubectl} rollout status deployment/clustermesh-apiserver -n kube-system --timeout=300s
        '';
      };
    };
  };
}
