# CIDR parsing and overlap checks (pure Nix, eval-time). Used by the pool
# assertions (D8: blocks non-overlapping). Ranges compare as integers for
# IPv4 and as 8×16-bit group lists for IPv6 (lexicographic).
{lib}: let
  inherit
    (builtins)
    match
    length
    elemAt
    foldl'
    genList
    ;

  inherit (lib) stringToCharacters;

  hexVal = c: let
    m = match "([0-9a-fA-F])" c;
    digits = stringToCharacters "0123456789abcdef";
    idx = lib.findFirst (i: elemAt digits i == lib.toLower c) (-1) (genList (x: x) 16);
  in
    if m == null || idx == -1
    then throw "cidr.nix: bad hex digit '${c}'"
    else idx;

  parseHexGroup = s: foldl' (acc: c: acc * 16 + hexVal c) 0 (stringToCharacters s);

  parseV4 = addr: let
    parts = map fromJSON' (lib.splitString "." addr);
    fromJSON' = s: builtins.fromJSON s;
  in
    if length parts != 4 || lib.any (p: p > 255) parts
    then throw "cidr.nix: bad IPv4 address '${addr}'"
    else foldl' (acc: p: acc * 256 + p) 0 parts;

  parseV6 = addr: let
    halves = lib.splitString "::" addr;
    expand = groups: pad: let
      parsed = map (g:
        if g == ""
        then 0
        else parseHexGroup g)
      groups;
    in
      parsed ++ genList (_: 0) pad;
    groups =
      if length halves == 1
      then expand (lib.splitString ":" addr) 0
      else if length halves == 2
      then let
        left =
          if head' halves == ""
          then []
          else lib.splitString ":" (head' halves);
        right =
          if elemAt halves 1 == ""
          then []
          else lib.splitString ":" (elemAt halves 1);
        pad = 8 - length left - length right;
      in
        expand left pad ++ map parseHexGroup right
      else throw "cidr.nix: bad IPv6 address '${addr}'";
    head' = xs: elemAt xs 0;
  in
    if length groups != 8
    then throw "cidr.nix: bad IPv6 address '${addr}' (expanded to ${toString (length groups)} groups)"
    else groups;

  # 2^bits - 1 style host mask, as int (v4) or group list (v6).
  parse = cidr: let
    m = match "^([^/]+)/([0-9]+)$" cidr;
  in
    if m == null
    then throw "cidr.nix: bad CIDR '${cidr}'"
    else let
      addr = elemAt m 0;
      prefix = builtins.fromJSON (elemAt m 1);
    in
      if lib.hasInfix ":" addr
      then let
        groups = parseV6 addr;
        start =
          lib.imap1 (
            i: g: let
              keep = prefix - (i - 1) * 16;
              keepBits =
                if keep >= 16
                then 16
                else if keep <= 0
                then 0
                else keep;
              shift = 16 - keepBits;
            in
              g - lib.mod g (pow2 shift)
          )
          groups;
        end =
          lib.imap1 (
            i: g: let
              keep = prefix - (i - 1) * 16;
              keepBits =
                if keep >= 16
                then 16
                else if keep <= 0
                then 0
                else keep;
              shift = 16 - keepBits;
            in
              g + (pow2 shift - 1)
          )
          groups;
      in
        if prefix > 128
        then throw "cidr.nix: bad prefix in '${cidr}'"
        else {
          family = 6;
          inherit start end;
        }
      else let
        base = parseV4 addr;
        hostBits = 32 - prefix;
        start = base - lib.mod base (pow2 hostBits);
        end = start + pow2 hostBits - 1;
      in
        if prefix > 32
        then throw "cidr.nix: bad prefix in '${cidr}'"
        else {
          family = 4;
          inherit start end;
        };

  pow2 = n:
    foldl' (acc: _: acc * 2) 1 (genList (x: x) (
      if n < 0
      then 0
      else n
    ));

  leq = a: b:
    if builtins.isInt a
    then a <= b
    else let
      cmp =
        foldl' (
          acc: i:
            if acc != 0
            then acc
            else let
              x = elemAt a i;
              y = elemAt b i;
            in
              if x < y
              then -1
              else if x > y
              then 1
              else 0
        )
        0 (genList (x: x) (length a));
    in
      cmp <= 0;
in rec {
  inherit parse;

  # Render an int as a dotted-quad IPv4 address.
  v4ToString = n: let
    inherit (builtins) div;
    inherit (lib) mod;
  in "${toString (div n 16777216)}.${toString (mod (div n 65536) 256)}.${toString (mod (div n 256) 256)}.${toString (mod n 256)}";

  # The address at `offset` inside an IPv4 CIDR (e.g. the 10th address of
  # the service CIDR is the derived clusterDNS, §6.2). IPv6 CIDRs throw:
  # clusterDNS is IPv4 by contract.
  addressAt = cidr: offset: let
    p = parse cidr;
  in
    if p.family != 4
    then throw "cidr.nix: addressAt only supports IPv4 CIDRs ('${cidr}')"
    else v4ToString (p.start + offset);

  # Render an 8×16-bit group list as a full-form IPv6 address (no `::`
  # compression — always valid, and parse-normalized by consumers).
  v6ToString = groups: lib.concatStringsSep ":" (map (g: lib.toLower (lib.toHexString g)) groups);

  # The address at `offset` inside an IPv6 CIDR (group-wise carry; offset
  # must be small — used for well-known addresses inside derived blocks).
  addressAtV6 = cidr: offset: let
    p = parse cidr;
    addCarry = groups: off: idx:
      if idx < 0
      then groups
      else let
        g = elemAt groups idx;
        carry = off / 65536;
        digit = lib.mod off 65536;
        sum = g + digit;
        newGroups = lib.imap1 (i: x:
          if i - 1 == idx
          then lib.mod sum 65536
          else x)
        groups;
      in
        addCarry newGroups (carry + sum / 65536) (idx - 1);
  in
    if p.family != 6
    then throw "cidr.nix: addressAtV6 only supports IPv6 CIDRs ('${cidr}')"
    else if offset < 0 || offset >= 4294967296
    then throw "cidr.nix: addressAtV6 offset out of supported range (${toString offset})"
    else v6ToString (addCarry p.start offset 7);

  validV4Pool = value: let
    parts = lib.splitString "/" value;
    canonical = "${addressAt value 0}/${builtins.elemAt parts 1}";
    result = builtins.tryEval (
      value == canonical && (parse value).end - (parse value).start >= 3
    );
  in
    result.success && result.value;

  # Is `child` fully contained in `parent`? Different families → false.
  contains = parent: child: let
    pp = parse parent;
    pc = parse child;
  in
    pp.family == pc.family && leq pp.start pc.start && leq pc.end pp.end;

  # Do two CIDRs overlap? Different families never overlap.
  overlap = a: b: let
    pa = parse a;
    pb = parse b;
  in
    pa.family == pb.family && leq pa.start pb.end && leq pb.start pa.end;

  # Any overlap in a list of CIDRs? O(n²) pairwise — pool sets are small.
  anyOverlap = cidrs: let
    after = x: xs: let
      go = ys:
        if ys == []
        then []
        else if builtins.head ys == x
        then lib.tail ys
        else go (lib.tail ys);
    in
      go xs;
    pairs = lib.concatMap (a: map (b: {inherit a b;}) (after a cidrs)) cidrs;
  in
    lib.filter (p: overlap p.a p.b) pairs;
}
