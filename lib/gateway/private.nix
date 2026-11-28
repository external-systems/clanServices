# The IPv4 ranges that are not the internet (specs/gateway.md G5), and
# the same ranges as the low 32 bits of an IPv6 address: a /96 embeds
# its IPv4 address there (RFC 6052), so a rule can refuse a private
# destination, or a private source, while the packet is still IPv6:
#
#   ip6 daddr & ::ffff:ffff @private6
#
# One list renders both sets, so they cannot drift.
{lib}: let
  private = ["0.0.0.0/8" "10.0.0.0/8" "100.64.0.0/10" "127.0.0.0/8" "169.254.0.0/16" "172.16.0.0/12" "192.0.0.0/24" "192.168.0.0/16" "198.18.0.0/15" "224.0.0.0/3"];
  # "127.0.0.0/8" -> "::7f00:0/104"
  embedded = range: let
    parts = lib.splitString "/" range;
    octets = map lib.toInt (lib.splitString "." (builtins.head parts));
    at = builtins.elemAt octets;
    hex = n: lib.toLower (lib.toHexString n);
  in "::${hex (at 0 * 256 + at 1)}:${hex (at 2 * 256 + at 3)}/${toString (96 + lib.toInt (lib.last parts))}";
in {
  inherit private embedded;
  private6 = map embedded private;
  # the two sets, as nft text for a table
  sets = ''
    set private4 {
      type ipv4_addr; flags interval;
      elements = { ${lib.concatStringsSep ", " private} }
    }
    set private6 {
      type ipv6_addr; flags interval;
      elements = { ${lib.concatMapStringsSep ", " embedded private} }
    }
  '';
}
