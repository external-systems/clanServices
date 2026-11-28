# The rke2 clan service: lib/kube-cluster/service.nix with what is rke2's
# own (K13, hard rule 4). Everything shared lives in lib/kube-cluster.
{inputs}: let
  # `profile` reaches config.yaml unless it is "cis" (cisHardening).
  profileConfig = settings:
    if settings.profile != null && settings.profile != "cis"
    then {inherit (settings) profile;}
    else {};
in
  import ../../lib/kube-cluster/service.nix {
    inherit inputs;
    distro = {
      name = "rke2";
      displayName = "RKE2";
      readme = ./README.md;
      # rke2 joins through the supervisor (9345), behind its own LB front.
      supervisor = true;
      serverUnit = "rke2-server.service";
      agentUnit = "rke2-agent.service";

      extraOptions = lib: {
        profile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "cis";
          description = ''
            RKE2 profile passed to the runtime (e.g. `"cis"`).
            The value `"cis"` is mapped to the nixpkgs
            `services.rke2.cisHardening` option; any other non-null
            value is written to `config.yaml` as the `profile` key.
          '';
        };
      };
      # `profile` has its typed option
      extraOwnedKeys = ["profile"];

      corednsHelmValuesMessage = "the HelmChartConfig machinery was removed in phase 3 — the distro's CoreDNS is configured by the operator (distroDefaults) or day-2";

      imagesPackage = {
        package,
        arch,
      }:
        package."images-core-linux-${arch}-tar-zst";

      # distroDefaults (D42): in the minimal base (the default) the
      # distro's packaged add-ons AND the embedded helm-controller are
      # disabled — the kubenix bootstrap bundle (D40) replaced
      # helm-controller delivery in phase 3. The bundled rke2-cilium and
      # rke2-coredns charts are disabled in BOTH modes: canonical Cilium
      # comes from the bundle (§6.4) and cluster.local DNS comes from the
      # uniform clan-rendered CoreDNS in the bundle (D46;
      # distroDefaults=true restores the distro's stock CoreDNS and the
      # bundle skips its own — mode-exclusive). RKE2 ships no
      # servicelb/klipper.
      disabledAddons = settings:
        [
          "rke2-cilium"
          "rke2-coredns"
        ]
        ++ (
          if settings.distroDefaults.enable
          then []
          else [
            "rke2-ingress-nginx"
            "rke2-metrics-server"
            "rke2-snapshot-controller"
            "rke2-snapshot-validation-webhook"
          ]
        );

      serverConfig = {
        settings,
        resolvedCidrs,
        ...
      }:
        {
          cluster-dns = resolvedCidrs.clusterDNS;
          # BYO CNI: canonical Cilium comes from the bootstrap bundle,
          # not the bundled rke2-cilium chart (§6.4).
          cni = "none";
        }
        // (
          if settings.distroDefaults.enable
          then {}
          else {ingress-controller = "none";}
        )
        // profileConfig settings;

      agentConfig = {settings}: profileConfig settings;

      # rke2 syncs the CA tree on every server, so each one has the var.
      pkiGeneratorOn = "server";

      nixos = {
        lib,
        role,
        isServer,
        isInit,
        settings,
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
        services.rke2 = {
          enable = true;
          # K-A1: `packages.rke2` is the runtime, not only the image
          # source; a mismatch asks for image tags the preloaded tarball
          # does not hold.
          package = effectivePackage;
          inherit role;
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
          cisHardening = settings.profile == "cis";
          # NO services.rke2.manifests: clan manifests are delivered
          # by the bootstrap bundle only (D40; §6.12 eval-rejects the
          # distro manifests dir for clan manifests — structurally
          # enforced by never writing there).
        };

        # Keep /etc/rancher/rke2 under NixOS's etc machinery so the
        # directory exists and is writable; rke2 writes its Pod
        # Security Admission config (rke2-pss.yaml) there at runtime.
        # rke2 reads /etc/rancher/rke2/config.yaml by default (the
        # nixpkgs module adds --config only when its configPath is
        # set), so the etc entry IS the config.
        environment.etc."rancher/rke2/config.yaml".source = configPath;

        # RKE2's runtime-image loader scans /var/lib/rancher/rke2/agent/images
        # for tarballs at the top level. The nixpkgs rke2 module links images
        # into a `nixos/` subdirectory, so we add top-level symlinks plus the
        # `.cache.json` marker that airgap imports expect.
        systemd.tmpfiles.rules =
          [
            "f /var/lib/rancher/rke2/agent/images/.cache.json 0600 root root -"
          ]
          # Admin kubeconfig (clan var) at the documented path.
          ++ lib.optionals isServer [
            "L+ /etc/rancher/rke2/admin-kubeconfig - - - - ${adminKubeconfigPath}"
          ]
          ++ map (
            img: "L+ /var/lib/rancher/rke2/agent/images/${builtins.unsafeDiscardStringContext (baseNameOf img)} - - - - ${toString img}"
          )
          effectiveImages;
      };

      # PKI sync (servers only): the pre-generated rancher-pki CA tree
      # lands in rke2's tls dir BEFORE rke2-server starts, so rke2 adopts
      # the custom CAs instead of generating its own.
      pki = {
        lib,
        kube,
        pkgs,
        instanceName,
        isServer,
        pkiGenerator,
        ...
      }:
        lib.mkIf isServer (
          kube.nixos.mkPkiSync {
            inherit pkgs pkiGenerator;
            tlsDir = "/var/lib/rancher/rke2/server/tls";
            beforeUnit = "rke2-server.service";
            namePrefix = "rke2-${instanceName}";
          }
        );
    };
  }
