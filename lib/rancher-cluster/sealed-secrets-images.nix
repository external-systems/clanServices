# Digest-locked Sealed Secrets controller airgap image.
# Keep in sync with the sealed-secrets chart version pinned in flake.nix
# (bitnami chart 2.19.3, appVersion 0.39.1).
rec {
  sealedSecretsVersion = "0.39.1";

  images = [
    {
      imageName = "bitnami/sealed-secrets-controller";
      finalImageTag = "0.39.1";
      imageDigest = "sha256:0e5ecab23801caa61b79420488d005377a7264b278c969ee8f78d937daec6931";
      sha256 = "sha256-qI/A0vps1wycA3aFGv4H+1n9e8gilTCFn/f8CkEhQeA=";
    }
  ];

  # Build the containerd-importable image set as a list of docker archives.
  # The rke2/k3s NixOS modules link these into /var/lib/rancher/*/agent/images/nixos/
  # and the runtime imports them before reaching any registry.
  mkImages =
    { pkgs }:
    map (
      img:
      pkgs.dockerTools.pullImage {
        inherit (img)
          imageName
          finalImageTag
          imageDigest
          sha256
          ;
      }
    ) images;
}
