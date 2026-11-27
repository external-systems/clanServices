# The k3s clan service: lib/kube-cluster/service.nix with what is k3s's
# own (K13, hard rule 4). Everything shared lives in lib/kube-cluster.
{inputs}:
import ../../lib/kube-cluster/service.nix {
  inherit inputs;
  distro = {
    name = "k3s";
    displayName = "k3s";
    readme = ./README.md;
    # k3s serves joins on the API port: no separate supervisor front.
    supervisor = false;
    serverUnit = "k3s.service";
    agentUnit = "k3s.service";

    extraOptions = _: {};
    extraOwnedKeys = [];

    corednsHelmValuesMessage = "k3s uses its bundled CoreDNS with coredns.rewrites";

    imagesPackage = {
      package,
      arch,
    }:
      package."airgap-images-${arch}-tar-zst";

    # distroDefaults (D42): servicelb/klipper is disabled in BOTH
    # modes — Cilium Node IPAM (D41) replaces it. In the minimal base
    # (the default) the distro's packaged add-ons AND the embedded
    # helm-controller are disabled: the kubenix bootstrap bundle
    # (D40) replaced helm-controller delivery in phase 3. The distro
    # CoreDNS is disabled too (D46): the bundle renders the uniform
    # clan CoreDNS for cluster.local instead.
    # distroDefaults.enable = true refrains so stock components
    # (including the distro CoreDNS) deploy via the distro's own
    # helm-controller (day-2 concern) — and the bundle skips its
    # cluster.local CoreDNS (mode-exclusive).
    disabledAddons = settings:
      [
        "servicelb"
      ]
      ++ (
        if settings.distroDefaults.enable
        then []
        else [
          "coredns"
          "traefik"
          "local-storage"
          "metrics-server"
        ]
      );

    serverConfig = {kubeapiPort, ...}: {
      https-listen-port = kubeapiPort;
      disable-apiserver-lb = true;
      flannel-backend = "none";
      disable-network-policy = true;
      # K9: Secrets encrypted at rest in etcd, as rke2 does by default
      secrets-encryption = true;
    };

    agentConfig = _: {
      disable-apiserver-lb = true;
    };

    # k3s seeds the CA tree once, on the init server.
    pkiGeneratorOn = "init";

    nixos = {
      lib,
      role,
      isServer,
      isInit,
      joinUrl,
      serverTokenPath,
      agentTokenPath,
      nodeIPv4,
      nodeIPv6,
      computedNodeLabels,
      effectivePackage,
      effectiveImages,
      configPath,
      adminKubeconfigPath,
      ...
    }: {
      services.k3s = {
        enable = true;
        package = effectivePackage;
        inherit role;
        clusterInit = isInit;
        serverAddr =
          if isInit
          then ""
          else joinUrl;
        tokenFile =
          if isServer
          then serverTokenPath
          else agentTokenPath;
        agentTokenFile = lib.mkIf isServer agentTokenPath;
        nodeIP = "${nodeIPv4},${nodeIPv6}";
        nodeLabel = computedNodeLabels;
        images = effectiveImages;
        # NO services.k3s.manifests / services.k3s.charts: clan
        # manifests are delivered by the bootstrap bundle only (D40;
        # §6.12 eval-rejects the distro manifests dir for clan
        # manifests — structurally enforced by never writing there).
      };

      environment.etc."rancher/k3s/config.yaml".source = configPath;

      systemd.tmpfiles.rules = lib.optionals isServer [
        "L+ /etc/rancher/k3s/admin-kubeconfig - - - - ${adminKubeconfigPath}"
      ];
    };

    # The init server seeds the custom CA tree into k3s's tls dir
    # before k3s first starts; joining servers get it from the
    # cluster.
    pki = {
      lib,
      pkgs,
      instanceName,
      isInit,
      pkiGenerator,
      ...
    }:
      lib.mkIf isInit {
        systemd.services."k3s-${instanceName}-pki-seed" = {
          description = "Seed the initial k3s custom CA certificates";
          wantedBy = ["multi-user.target"];
          before = ["k3s.service"];
          requiredBy = ["k3s.service"];
          # an assertion, not a condition: see lib/kube-cluster/nixos.nix
          unitConfig.AssertPathExists =
            pkiGenerator.files."server-ca.key".path;
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            ExecStart = pkgs.writeShellScript "k3s-${instanceName}-pki-seed" ''
              set -euo pipefail
              TLS_DIR=/var/lib/rancher/k3s/server/tls
              if [ -e "$TLS_DIR/service.current.key" ] || [ -e "$TLS_DIR/server-ca.nochain.crt" ]; then
                exit 0
              fi
              mkdir -p "$TLS_DIR/etcd"
              chmod 700 "$TLS_DIR" "$TLS_DIR/etcd"
              ${pkgs.coreutils}/bin/install -Dm644 ${
                pkiGenerator.files."server-ca.crt".path
              } "$TLS_DIR/server-ca.crt"
              ${pkgs.coreutils}/bin/install -Dm600 ${
                pkiGenerator.files."server-ca.key".path
              } "$TLS_DIR/server-ca.key"
              ${pkgs.coreutils}/bin/install -Dm644 ${
                pkiGenerator.files."client-ca.crt".path
              } "$TLS_DIR/client-ca.crt"
              ${pkgs.coreutils}/bin/install -Dm600 ${
                pkiGenerator.files."client-ca.key".path
              } "$TLS_DIR/client-ca.key"
              ${pkgs.coreutils}/bin/install -Dm644 ${
                pkiGenerator.files."request-header-ca.crt".path
              } "$TLS_DIR/request-header-ca.crt"
              ${pkgs.coreutils}/bin/install -Dm600 ${
                pkiGenerator.files."request-header-ca.key".path
              } "$TLS_DIR/request-header-ca.key"
              ${pkgs.coreutils}/bin/install -Dm644 ${
                pkiGenerator.files."etcd-peer-ca.crt".path
              } "$TLS_DIR/etcd/peer-ca.crt"
              ${pkgs.coreutils}/bin/install -Dm600 ${
                pkiGenerator.files."etcd-peer-ca.key".path
              } "$TLS_DIR/etcd/peer-ca.key"
              ${pkgs.coreutils}/bin/install -Dm644 ${
                pkiGenerator.files."etcd-server-ca.crt".path
              } "$TLS_DIR/etcd/server-ca.crt"
              ${pkgs.coreutils}/bin/install -Dm600 ${
                pkiGenerator.files."etcd-server-ca.key".path
              } "$TLS_DIR/etcd/server-ca.key"
              ${pkgs.coreutils}/bin/install -Dm600 ${
                pkiGenerator.files."service.key".path
              } "$TLS_DIR/service.key"
            '';
          };
        };
      };
  };
}
