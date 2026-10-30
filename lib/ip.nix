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

  normalizeIpv6 = value: let
    withoutZone = builtins.head (lib.splitString "%" value);
    halves = lib.splitString "::" withoutZone;
    groups = part: builtins.filter (group: group != "") (lib.splitString ":" part);
    left = groups (builtins.head halves);
    right =
      if builtins.length halves == 2
      then groups (builtins.elemAt halves 1)
      else [];
    validGroup = group: builtins.match "[0-9A-Fa-f]{1,4}" group != null;
    missing = 8 - builtins.length left - builtins.length right;
    expanded =
      if builtins.length halves == 2
      then left ++ (lib.genList (_: "0") missing) ++ right
      else left;
  in
    if
      builtins.length halves
      <= 2
      && lib.all validGroup (left ++ right)
      && (
        if builtins.length halves == 2
        then missing >= 1
        else builtins.length left == 8
      )
    then lib.concatStringsSep ":" (map lib.toLower expanded)
    else null;

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
  isIpv6 = value: !(lib.hasInfix "%" value) && normalizeIpv6 value != null;
  isLiteral = value: isIpv4 value || isIpv6 value;
  addressFromCIDR = value: builtins.head (lib.splitString "/" value);
  normalizeAddress = value:
    if isIpv4 value
    then value
    else normalizeIpv6 value;
}
