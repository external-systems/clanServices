# Digest-locked cert-manager airgap images.
# Keep in sync with the cert-manager chart version pinned in flake.nix.
rec {
  certManagerVersion = "v1.21.2";

  images = [
    {
      imageName = "quay.io/jetstack/cert-manager-cainjector";
      finalImageTag = "v1.21.2";
      imageDigest = "sha256:c85268c64f2e0e76684bf5fe8906caff34b82523561c6affe0fae3546bd87562";
      sha256 = "sha256-b3O8trqxnwVPOTiKOJuBUSZIIcXn0Lzc2XINHLB+NU4=";
    }
    {
      imageName = "quay.io/jetstack/cert-manager-controller";
      finalImageTag = "v1.21.2";
      imageDigest = "sha256:70f532fd9cfde0b09d55687200942399d89838bc2d5d5b45152eb799a15912b8";
      sha256 = "sha256-PQrjeF5Oy+T44S9+BHCwdbSwXU4+EsrCu8AdCuWKWdE=";
    }
    {
      imageName = "quay.io/jetstack/cert-manager-webhook";
      finalImageTag = "v1.21.2";
      imageDigest = "sha256:a60e2dac46dbb8a7f3df95c54ce941012f54c2fe022f0ee55aaa1ab40ed957ae";
      sha256 = "sha256-gbv5LNTgIzRZgLnaNzIdLYEexlEcJfP+rb2zzscHNEA=";
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
