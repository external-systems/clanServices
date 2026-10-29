{
  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: let
    vmTest = pkgs.writeShellApplication {
      name = "vm-test";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.git
        pkgs.nix
      ];
      text = ''
        suites=(${lib.escapeShellArgs (builtins.attrNames config.legacyPackages.vmTests)})

        if [[ $# -eq 1 && $1 == --list ]]; then
          printf '%s\n' "''${suites[@]}"
          exit 0
        fi

        if [[ $# -ne 1 ]]; then
          printf 'usage: vm-test [--list | <suite>]\n' >&2
          exit 2
        fi

        suite=$1
        valid=0
        for candidate in "''${suites[@]}"; do
          if [[ $candidate == "$suite" ]]; then
            valid=1
            break
          fi
        done
        if [[ $valid -eq 0 ]]; then
          printf 'unknown VM suite: %s\nuse --list to see available suites\n' "$suite" >&2
          exit 2
        fi

        repo_root=$(git rev-parse --show-toplevel)
        cd "$repo_root"
        log_dir=".baton-pass/vm-logs/$suite"
        mkdir -p "$log_dir"
        n=0
        while [[ -e "$log_dir/logs-$n" ]]; do
          ((n += 1))
        done
        log="$log_dir/logs-$n"

        set +e
        nix build ".#legacyPackages.${pkgs.stdenv.hostPlatform.system}.vmTests.$suite" --no-link -L 2>&1 | tee "$log"
        status=''${PIPESTATUS[0]}
        set -e
        printf 'VM build log: %s\n' "$log"
        exit "$status"
      '';
    };
  in {
    apps.vm-test = {
      type = "app";
      program = lib.getExe vmTest;
      meta.description = "Build one VM suite and save its numbered log";
    };
  };
}
