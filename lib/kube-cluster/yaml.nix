# Pure-Nix parser for the YAML subset that `helm template` emits (D26:
# zero IFD — kubenix's own importYAML/kubernetes.imports shell out to yq
# via a derivation, which is import-from-derivation and forbidden in
# clanServices eval). This parser exists to ingest the artifact flake's
# COMMITTED base manifest into kubenix's typed resource tree.
#
# Supported subset (validated against yq on the pinned
# manifests/cilium/<version>.yaml):
#   - block mappings/sequences by indentation
#   - plain, double-quoted (JSON escape rules) and single-quoted scalars
#   - int/float/true/false/null scalar resolution
#   - literal (|) and folded (>) block scalars with -/+/clip chomping
#   - empty flow collections {} and []
#   - full-line and trailing (# ...) comments
#   - multi-document streams split on column-0 "---"
#
# NOT supported (helm template output never contains these): anchors and
# aliases, tags, general flow collections, complex (?) keys, multi-line
# quoted scalars, tabs. These throw at eval rather than misparse.
{lib}: let
  inherit
    (builtins)
    head
    length
    substring
    stringLength
    match
    elemAt
    concatStringsSep
    fromJSON
    foldl'
    genList
    ;

  inherit (lib) stringToCharacters;

  inherit (lib.lists) drop;

  # --- line utilities ---------------------------------------------------

  indentOf = s: let
    m = match "^([ ]*).*$" s;
  in
    if m == null
    then 0
    else stringLength (head m);

  # Blank or full-line comment.
  isIgnorable = s: let
    t = lib.trim s;
  in
    t == "" || lib.hasPrefix "#" t;

  # Scan `chars` for the first ':' (wantColon=true) or '#' preceded by a
  # space (wantColon=false) outside single/double quotes. Returns the index
  # or -1.
  scanOutsideQuotes = chars: wantColon: let
    len = length chars;
    scan = i: state:
      if i >= len
      then -1
      else let
        c = elemAt chars i;
      in
        if state == "sq"
        then
          if c == "'"
          then scan (i + 1) "none"
          else scan (i + 1) "sq"
        else if state == "dq"
        then
          if c == "\\"
          then scan (i + 2) "dq"
          else if c == "\""
          then scan (i + 1) "none"
          else scan (i + 1) "dq"
        else if c == "'"
        then scan (i + 1) "sq"
        else if c == "\""
        then scan (i + 1) "dq"
        else if wantColon && c == ":" && (i + 1 >= len || elemAt chars (i + 1) == " ")
        then i
        else if !wantColon && c == "#" && i > 0 && elemAt chars (i - 1) == " "
        then i
        else scan (i + 1) "none";
  in
    scan 0 "none";

  # Strip a trailing " # comment"; safe inside quoted regions.
  stripTrailingComment = s: let
    cut = scanOutsideQuotes (stringToCharacters s) false;
  in
    if cut == -1
    then s
    else lib.trim (substring 0 cut s);

  # --- scalars ----------------------------------------------------------

  parseScalar = raw: let
    s = stripTrailingComment (lib.trim raw);
    n = stringLength s;
    isDq = lib.hasPrefix "\"" s && lib.hasSuffix "\"" s && n >= 2;
    isSq = lib.hasPrefix "'" s && lib.hasSuffix "'" s && n >= 2;
  in
    if s == "" || s == "~" || s == "null"
    then null
    else if s == "{}"
    then {}
    else if s == "[]"
    then []
    else if isDq
    then
      # YAML double-quoted scalars follow JSON string rules closely enough
      # for helm output; fromJSON decodes the escapes.
      fromJSON s
    else if isSq
    then builtins.replaceStrings ["''"] ["'"] (substring 1 (n - 2) s)
    else if s == "true"
    then true
    else if s == "false"
    then false
    else if match "^0[0-7]+$" s != null
    then
      # Legacy YAML octal (e.g. defaultMode: 0400) — go-yaml/k8s decode
      # leading-zero numbers as octal.
      foldl' (acc: c: acc * 8 + (fromJSON c)) 0 (drop 1 (stringToCharacters s))
    else if match "^-?(0|[1-9][0-9]*)$" s != null || match "^-?[0-9]+\\.[0-9]+([eE][+-]?[0-9]+)?$" s != null
    then fromJSON s
    else s;

  # --- structural parser --------------------------------------------------
  #
  # Input: a list of raw lines (one document). Parse functions take a line
  # index and return { v = <value>; i = <next unconsumed line index>; }.
  # Blank/comment lines are skipped between structures; block scalars
  # consume raw lines (including blanks) by indentation.

  parseDoc = lines: let
    n = length lines;

    indentAt = i: indentOf (elemAt lines i);

    skipIgnored = i:
      if i >= n
      then i
      else if isIgnorable (elemAt lines i)
      then skipIgnored (i + 1)
      else i;

    contentAt = i: substring (indentAt i) (stringLength (elemAt lines i) - indentAt i) (elemAt lines i);

    isSeqLine = content: lib.hasPrefix "- " content || content == "-";

    isBlockIndicator = s: match "^[|>][+-]?$" s != null;

    # Collect a block scalar whose header is line `hi`; `parentInd` is the
    # indent of the key/dash that owns it.
    parseBlockScalar = hi: parentInd: indicator: let
      collect = i: acc:
        if i >= n
        then {
          ls = acc;
          inherit i;
        }
        else let
          l = elemAt lines i;
          blank = match "^[ ]*$" l != null;
        in
          if blank || indentOf l > parentInd
          then collect (i + 1) (acc ++ [l])
          else {
            ls = acc;
            inherit i;
          };
      collected = collect (hi + 1) [];
      firstNonBlank = lib.findFirst (l: match "^[ ]*$" l == null) null collected.ls;
      blockInd =
        if firstNonBlank == null
        then parentInd + 1
        else indentOf firstNonBlank;
      stripLine = l:
        if match "^[ ]*$" l != null
        then ""
        else substring blockInd (stringLength l - blockInd) l;
      stripped = map stripLine collected.ls;
      dropTrailingBlanks = xs: let
        n = length xs;
        lastContent = foldl' (acc: idx:
          if elemAt xs idx != ""
          then idx
          else acc) (-1) (genList (x: x) n);
      in
        if lastContent == -1
        then []
        else lib.take (lastContent + 1) xs;
      chomped =
        if lib.hasSuffix "+" indicator
        then stripped
        else dropTrailingBlanks stripped;
      body =
        if lib.hasPrefix ">" indicator
        then
          # fold: non-blank runs join with spaces, blank lines are
          # paragraph breaks (helm output here only uses "|")
          let
            step = acc: l:
              if l == ""
              then {
                out = acc.out + "\n";
                atText = false;
              }
              else {
                out =
                  acc.out
                  + (
                    if acc.atText
                    then " "
                    else ""
                  )
                  + l;
                atText = true;
              };
            folded =
              foldl' step {
                out = "";
                atText = false;
              }
              chomped;
          in
            folded.out
        else concatStringsSep "\n" chomped;
    in {
      v =
        if lib.hasSuffix "-" indicator
        then body
        else body + "\n";
      inherit (collected) i;
    };

    # Split "key: rest" at the first ':' followed by space or EOL.
    splitKey = content: let
      chars = stringToCharacters content;
      ki = scanOutsideQuotes chars true;
    in
      if ki == -1
      then throw "yaml.nix: not a mapping line: '${content}'"
      else let
        rawKey = lib.trim (substring 0 ki content);
        key =
          if lib.hasPrefix "\"" rawKey && lib.hasSuffix "\"" rawKey
          then fromJSON rawKey
          else if lib.hasPrefix "'" rawKey && lib.hasSuffix "'" rawKey
          then builtins.replaceStrings ["''"] ["'"] (substring 1 (stringLength rawKey - 2) rawKey)
          else rawKey;
        rest = lib.trim (substring (ki + 1) (stringLength content - ki - 1) content);
      in {
        inherit key rest;
      };

    # One mapping entry: `content` is the "key: rest" text of line `li`;
    # continuation content sits at indents > parentInd.
    parseMapEntry = li: parentInd: content: let
      kv = splitKey content;
      inherit (kv) key rest;
    in
      if isBlockIndicator rest
      then let
        b = parseBlockScalar li parentInd rest;
      in {
        inherit key;
        inherit (b) v i;
      }
      else if rest == ""
      then let
        # A block sequence may sit at the SAME indent as its parent key
        # (helm emits `rules:` + `- apiGroups:` at equal indentation).
        j = skipIgnored (li + 1);
        child =
          if j < n && indentAt j == parentInd && isSeqLine (contentAt j)
          then parseSeq j parentInd
          else parseNode (li + 1) (parentInd + 1);
      in {
        inherit key;
        inherit (child) v i;
      }
      else {
        inherit key;
        v = parseScalar rest;
        i = li + 1;
      };

    # Block mapping whose entries sit at indent `ind`, seeded with the
    # entries already parsed (a sequence's inline "- key: value" start).
    parseMapFrom = i: ind: seed: let
      loop = cur: acc: let
        j = skipIgnored cur;
      in
        if j >= n
        then {
          v = acc;
          i = j;
        }
        else let
          ind2 = indentAt j;
          content = contentAt j;
        in
          if ind2 != ind || isSeqLine content
          then {
            v = acc;
            i = j;
          }
          else let
            e = parseMapEntry j ind content;
          in
            loop e.i (acc // {"${e.key}" = e.v;});
    in
      loop i seed;

    parseMap = i: ind: parseMapFrom i ind {};

    # Block sequence whose dashes sit at indent `ind`.
    parseSeq = i: ind: let
      loop = cur: acc: let
        j = skipIgnored cur;
      in
        if j >= n
        then {
          v = acc;
          i = j;
        }
        else let
          ind2 = indentAt j;
          content = contentAt j;
        in
          if ind2 != ind || !isSeqLine content
          then {
            v = acc;
            i = j;
          }
          else if content == "-"
          then let
            child = parseNode (j + 1) (ind + 1);
          in
            loop child.i (acc ++ [child.v])
          else let
            rest = lib.trim (substring 2 (stringLength content - 2) content);
            itemInd = ind + 2;
            # Inline mapping start ("- key: ...")? The key must look
            # like an identifier; plain scalars containing ':' (URLs,
            # flags like --config-dir=...) must stay scalars.
            keyTry = builtins.tryEval (
              let
                kv = splitKey rest;
              in
                match "^[A-Za-z0-9_./-]+$" kv.key != null
            );
          in
            if isBlockIndicator rest
            then let
              b = parseBlockScalar j ind rest;
            in
              loop b.i (acc ++ [b.v])
            else if keyTry.success && keyTry.value
            then let
              e = parseMapEntry j itemInd rest;
              more = parseMapFrom e.i itemInd {"${e.key}" = e.v;};
            in
              loop more.i (acc ++ [more.v])
            else loop (j + 1) (acc ++ [(parseScalar rest)]);
    in
      loop i [];

    parseNode = i: minInd: let
      j = skipIgnored i;
    in
      if j >= n
      then {
        v = null;
        i = j;
      }
      else let
        ind = indentAt j;
        content = contentAt j;
      in
        if ind < minInd
        then {
          v = null;
          i = j;
        }
        else if isSeqLine content
        then parseSeq j ind
        else parseMap j ind;

    start = skipIgnored 0;
  in
    if start >= n
    then null
    else let
      r = parseNode start 0;
      rest = skipIgnored r.i;
    in
      if rest < n
      then throw "yaml.nix: trailing unparseable content at line ${toString (rest + 1)}: '${elemAt lines rest}'"
      else r.v;
in {
  # Parse a single-document YAML string.
  fromYAML = text: let
    lines = lib.splitString "\n" text;
  in
    parseDoc lines;

  # Parse a multi-document stream: documents split on column-0 '---' lines
  # (safe: block-scalar content is always indented, so a column-0 separator
  # is never content). Empty/comment-only documents are dropped.
  fromYAMLMulti = text: let
    lines = lib.splitString "\n" text;
    splitDocs = i: cur: acc:
      if i >= length lines
      then acc ++ [cur]
      else let
        l = elemAt lines i;
      in
        if match "^---($| .*)" l != null
        then splitDocs (i + 1) [] (acc ++ [cur])
        else splitDocs (i + 1) (cur ++ [l]) acc;
    docs = splitDocs 0 [] [];
    parsed = map (d:
      if lib.all isIgnorable d
      then null
      else parseDoc d)
    docs;
  in
    lib.filter (d: d != null) parsed;
}
