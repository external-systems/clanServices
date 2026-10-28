final: prev:
let
  ifstateSrc = final.fetchFromCodeberg {
    owner = "routerkit";
    repo = "ifstate";
    tag = "2.5.1";
    hash = "sha256-wRIFQQYSCsEmK7epFponyVEh9BrkjJWW8t34tDz7Ofg=";
  };
in
{
  # IfState 2.5 moved to the src/ Python layout and uv_build. The pure
  # pyroute2 variant avoids the optional Rust accelerator.
  ifstate = prev.ifstate.overridePythonAttrs (old: {
    version = "2.5.1";
    src = ifstateSrc;
    build-system = [ final.python3Packages.uv-build ];
    postPatch = ''
      substituteInPlace src/libifstate/paths.py \
        --replace-fail '/usr/share/iproute2' '${final.iproute2}/share/iproute2' \
        --replace-fail "/usr/sbin/ethtool" "${final.lib.getExe final.ethtool}"
      substituteInPlace src/libifstate/hook/wrapper.sh \
        --replace-fail ' ip ' ' ${final.lib.getExe' final.iproute2 "ip"} '
    '';
    passthru = old.passthru // {
      jsonschema = "${ifstateSrc}/schema/2/ifstate.conf.schema.json";
    };
  });
}
