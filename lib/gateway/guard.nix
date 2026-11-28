# The ruleset of a translator namespace (specs/design-gateway.md §3.4): a
# file that the Jool unit loads with `ip netns exec <netns> nft -f`, before
# an instance exists. It replaces the table in one transaction. The build
# checks it the way NixOS checks the host's ruleset.
{pkgs}: name: text:
pkgs.writeTextFile {
  inherit name text;
  checkPhase = ''
    export NIX_REDIRECTS=/etc/protocols=${pkgs.buildPackages.iana-etc}/etc/protocols:/etc/services=${pkgs.buildPackages.iana-etc}/etc/services
    LD_PRELOAD="${pkgs.buildPackages.libredirect}/lib/libredirect.so ${pkgs.buildPackages.lklWithFirewall.lib}/lib/liblkl-hijack.so" \
      ${pkgs.buildPackages.nftables}/bin/nft --check --file "$target"
  '';
}
