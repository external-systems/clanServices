{ lib }:
let
  cidr = import ./cidr.nix { inherit lib; };

  hexVal =
    char:
    let
      digits = lib.stringToCharacters "0123456789abcdef";
      index = lib.findFirst (i: builtins.elemAt digits i == char) (-1) (lib.genList (x: x) 16);
    in
    if index == -1 then throw "routed-fabric: invalid hexadecimal digit '${char}'" else index;

  hexByte =
    hash: index:
    hexVal (builtins.substring index 1 hash) * 16 + hexVal (builtins.substring (index + 1) 1 hash);

  hash32 =
    value:
    lib.foldl' (acc: char: acc * 16 + hexVal char) 0 (
      lib.stringToCharacters (builtins.substring 0 8 (builtins.hashString "sha256" value))
    );

  stableHash =
    instanceName: machineName: builtins.hashString "sha256" "${instanceName}:${machineName}";

  adjacencyKey =
    instanceName: a: b:
    "${instanceName}:${
      lib.concatStringsSep ":" (
        lib.sort builtins.lessThan [
          a
          b
        ]
      )
    }";
in
rec {
  stableIpv4 =
    instanceName: machineName:
    let
      hash = stableHash instanceName machineName;
    in
    "192.168.${toString (hexByte hash 0)}.${toString (hexByte hash 1)}";

  stableIpv6 =
    instanceName: machineName:
    let
      hash = stableHash instanceName machineName;
    in
    "fd77:${builtins.substring 0 4 hash}:${builtins.substring 4 4 hash}:${builtins.substring 8 4 hash}::${builtins.substring 12 4 hash}";

  nodeAsn =
    instanceName: machineName:
    4200000000 + lib.mod (hash32 "routed-fabric-node:${instanceName}:${machineName}") 94967294;

  adjacencyName = key: "rf${builtins.substring 0 13 (builtins.hashString "sha256" key)}";

  adjacencyPort = basePort: key: basePort + lib.mod (hash32 "routed-fabric-port:${key}") 10000;

  adjacencyMtu = underlayMtu: lib.max 1280 (underlayMtu - 96);

  transferAddresses =
    instanceName: a: b:
    let
      key = adjacencyKey instanceName a b;
      endpoints = lib.sort builtins.lessThan [
        a
        b
      ];
      hash = builtins.hashString "sha256" key;
      ipv4Base = 1681915904 + lib.mod (hash32 "routed-fabric-v4:${key}") 4194304 * 2;
      ipv6Groups = lib.imap1 (
        index: _:
        let
          group = lib.foldl' (acc: char: acc * 16 + hexVal char) 0 (
            lib.stringToCharacters (builtins.substring ((index - 1) * 4) 4 hash)
          );
        in
        if index == 7 then group - lib.mod group 2 else group
      ) (lib.genList (x: x) 7);
      ipv6Base = "fd76:${
        lib.concatStringsSep ":" (map (group: lib.toLower (lib.toHexString group)) ipv6Groups)
      }";
    in
    {
      inherit key;
      ordered = endpoints;
      localFirst = {
        ipv4 = cidr.v4ToString ipv4Base;
        ipv6 = cidr.addressAtV6 "${ipv6Base}/127" 0;
      };
      localSecond = {
        ipv4 = cidr.v4ToString (ipv4Base + 1);
        ipv6 = cidr.addressAtV6 "${ipv6Base}/127" 1;
      };
      prefixes = {
        ipv4 = "${cidr.v4ToString ipv4Base}/31";
        ipv6 = "${ipv6Base}/127";
      };
    };

  inherit adjacencyKey;
}
