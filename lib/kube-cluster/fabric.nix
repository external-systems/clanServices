{lib}: rec {
  adjacencyKey = instanceName: a: b: "${instanceName}:${
    lib.concatStringsSep ":" (
      lib.sort builtins.lessThan [
        a
        b
      ]
    )
  }";

  adjacencyName = key: "rf${builtins.substring 0 13 (builtins.hashString "sha256" key)}";

  adjacencyMtu = underlayMtu: lib.max 1280 (underlayMtu - 96);
}
