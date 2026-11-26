{lib}: let
  isIpv4 = value: let
    parts = lib.splitString "." value;
    octet = part:
      builtins.match "[0-9]+" part
      != null
      && builtins.stringLength part <= 3
      && (part == "0" || !lib.hasPrefix "0" part)
      && (builtins.fromJSON part) >= 0
      && (builtins.fromJSON part) <= 255;
  in
    builtins.length parts == 4 && lib.all octet parts;

  # The canonical spelling of an IPv6 address (zone dropped), or null
  # when the value is not one: eight groups of lower-case hex without
  # leading zeros, `::` expanded, an IPv4 tail ('::ffff:192.0.2.1') as
  # two groups. Two spellings of one address normalize to one string.
  normalizeIpv6 = value: let
    withoutZone = builtins.head (lib.splitString "%" value);
    halves = lib.splitString "::" withoutZone;
    compressed = builtins.length halves == 2;
    # "" is no group: one side of '::' may be empty, a group may not
    groups = part:
      if part == ""
      then []
      else lib.splitString ":" part;
    rawLeft = groups (builtins.head halves);
    rawRight =
      if compressed
      then groups (builtins.elemAt halves 1)
      else [];
    # a dotted IPv4 tail is the last two groups
    tailOf = list:
      if list != [] && isIpv4 (lib.last list)
      then let
        octets = map lib.toInt (lib.splitString "." (lib.last list));
        hex = high: low: lib.toLower (lib.toHexString (high * 256 + low));
      in
        lib.init list
        ++ [
          (hex (builtins.elemAt octets 0) (builtins.elemAt octets 1))
          (hex (builtins.elemAt octets 2) (builtins.elemAt octets 3))
        ]
      else list;
    left =
      if compressed
      then rawLeft
      else tailOf rawLeft;
    right = tailOf rawRight;
    validGroup = group: builtins.match "[0-9A-Fa-f]{1,4}" group != null;
    canonical = group: let
      stripped = lib.toLower (lib.removePrefix "0" (lib.removePrefix "0" (lib.removePrefix "0" group)));
    in
      if stripped == ""
      then "0"
      else stripped;
    missing = 8 - builtins.length left - builtins.length right;
    expanded =
      if compressed
      then left ++ (lib.genList (_: "0") missing) ++ right
      else left;
  in
    if
      builtins.length halves
      <= 2
      && lib.all validGroup (left ++ right)
      && (
        if compressed
        then missing >= 1
        else builtins.length left == 8
      )
    then lib.concatStringsSep ":" (map canonical expanded)
    else null;

  # "address/length" with a prefix length that fits the family.
  isCidrOf = isAddress: bits: value: let
    parts = lib.splitString "/" value;
    length = builtins.elemAt parts 1;
  in
    builtins.length parts
    == 2
    && isAddress (builtins.head parts)
    && builtins.match "0|[1-9][0-9]{0,2}" length != null
    && lib.toInt length <= bits;
  isIpv6Plain = value: !(lib.hasInfix "%" value) && normalizeIpv6 value != null;

  targetHostAddress = target: let
    withoutUser = lib.last (lib.splitString "@" target);
    bracketed = lib.hasPrefix "[" withoutUser && lib.hasInfix "]" withoutUser;
    bracketedAddress = builtins.head (
      lib.splitString "]" (builtins.substring 1 (builtins.stringLength withoutUser) withoutUser)
    );
    withPort = builtins.match "^(.+):[0-9]+$" withoutUser;
  in
    if bracketed
    then bracketedAddress
    else if normalizeIpv6 withoutUser != null
    then withoutUser
    else if withPort != null
    then builtins.head withPort
    else withoutUser;
in rec {
  inherit isIpv4 normalizeIpv6 targetHostAddress;

  reservedPolicyTables = [0 200 201 253 254 255 2004 2005];

  # 2^n for small non-negative n.
  pow2 = n: builtins.foldl' (acc: _: acc * 2) 1 (lib.range 1 n);
  isIpv6 = isIpv6Plain;
  isLiteral = value: isIpv4 value || isIpv6 value;
  isIpv4Cidr = isCidrOf isIpv4 32;
  isIpv6Cidr = isCidrOf isIpv6Plain 128;
  isCidr = value: isIpv4Cidr value || isIpv6Cidr value;

  # Option types for addresses (round G11): a typo or a prefix length
  # in the wrong place fails at evaluation, not in the guard or IfState.
  types = let
    check = description: predicate: lib.types.addCheck lib.types.str predicate // {inherit description;};
  in {
    ipv4 = check "IPv4 address" isIpv4;
    ipv6 = check "IPv6 address" isIpv6Plain;
    address = check "IPv4 or IPv6 address" isLiteral;
    ipv4Cidr = check "IPv4 address with prefix length" isIpv4Cidr;
    ipv6Cidr = check "IPv6 address with prefix length" isIpv6Cidr;
    cidr = check "IPv4 or IPv6 prefix" isCidr;
  };
  addressFromCIDR = value: builtins.head (lib.splitString "/" value);
  normalizeAddress = value:
    if isIpv4 value
    then value
    else normalizeIpv6 value;
}
